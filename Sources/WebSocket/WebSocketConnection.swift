import Foundation

// MARK: - _WebSocketDelegate

/// Private delegate that holds a weak reference to its owner, breaking the URLSession retain cycle.
/// URLSession holds a strong reference to its delegate, so if WebSocketConnection were the delegate
/// directly, it could never deinit while the session is alive.
private final class _WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    weak var connection: WebSocketConnection?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        connection?.handleDidOpen(webSocketTask: webSocketTask, negotiatedProtocol: `protocol`)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        connection?.handleDidClose(webSocketTask: webSocketTask, code: closeCode, reason: reason)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        connection?.handleDidComplete(task: task, error: error)
    }
}

// MARK: - WebSocketConnection

/// A reusable WebSocket connection with async send, receive, ping, close, and reconnect support.
///
/// ## Overview
/// Each call to `events()` returns an independent `AsyncThrowingStream` of `WebSocketEvent` values.
/// Multiple callers can subscribe concurrently — every subscriber receives every event.
///
/// ## Lifecycle
/// ```swift
/// let connection = try client.webSocketConnection(MySocket())
/// connection.connect()
/// for try await event in connection.events() { ... }
/// connection.close()
/// ```
///
/// ## Thread Safety
/// All mutable state is protected by `NSLock`. Delegate callbacks from URLSession arrive on
/// background threads; the lock ensures consistent state across threads.
public final class WebSocketConnection: @unchecked Sendable {
    public typealias EventStream = AsyncThrowingStream<WebSocketEvent, Error>

    // MARK: - Properties

    private let request: URLRequest
    private let session: URLSession
    private let wsDelegate: _WebSocketDelegate
    private let protocols: [String]
    private let options: WebSocketOptions
    private let logLevel: LogLevel
    private let lock = NSLock()

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var continuations: [UUID: EventStream.Continuation] = [:]
    private var reconnectAttempts = 0
    private var manuallyClosed = false
    private var closedByServer = false
    private var _state: WebSocketConnectionState = .idle

    // MARK: - Init

    internal init(
        request: URLRequest,
        configuration: URLSessionConfiguration?,
        protocols: [String],
        options: WebSocketOptions,
        logLevel: LogLevel
    ) {
        self.request = request
        self.protocols = protocols
        self.options = options
        self.logLevel = logLevel

        let sessionConfig: URLSessionConfiguration
        if let configuration {
            sessionConfig = configuration
        } else {
            sessionConfig = URLSessionConfiguration.default
            sessionConfig.timeoutIntervalForRequest = 120
            sessionConfig.timeoutIntervalForResource = 120
        }

        let delegate = _WebSocketDelegate()
        self.wsDelegate = delegate
        self.session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        delegate.connection = self
    }

    // MARK: - Deinit

    deinit {
        lock.lock()
        let activeTask = task
        let activeReceive = receiveTask
        let activePing = pingTask
        let pending = continuations
        task = nil
        receiveTask = nil
        pingTask = nil
        continuations.removeAll()
        lock.unlock()

        activeReceive?.cancel()
        activePing?.cancel()
        activeTask?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        pending.values.forEach { $0.finish() }
    }

    // MARK: - Public API

    /// The WebSocket URL this connection targets.
    public var url: URL? { request.url }

    /// The current lifecycle state of the connection.
    public var state: WebSocketConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// Returns an independent async stream of connection events.
    /// Each call creates a new subscriber — all subscribers receive every event.
    public func events(
        bufferingPolicy: EventStream.Continuation.BufferingPolicy = .unbounded
    ) -> EventStream {
        EventStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    /// Initiates the WebSocket handshake. No-op if already connected or connecting.
    public func connect() {
        lock.lock()
        guard task == nil else {
            lock.unlock()
            return
        }
        manuallyClosed = false
        closedByServer = false
        _state = .connecting

        var handshakeRequest = request
        if !protocols.isEmpty {
            handshakeRequest.setValue(
                protocols.joined(separator: ", "),
                forHTTPHeaderField: "Sec-WebSocket-Protocol"
            )
        }

        let webSocketTask = session.webSocketTask(with: handshakeRequest)
        webSocketTask.maximumMessageSize = options.maximumMessageSize
        task = webSocketTask
        lock.unlock()

        URLSessionLogger.shared.logRequest(request, logLevel: logLevel)
        webSocketTask.resume()
        startPingLoopIfNeeded()
        // .connected is emitted by handleDidOpen(_:) once the server confirms the handshake
    }

    /// Sends a WebSocket message.
    public func send(_ message: WebSocketMessage) async throws {
        guard let task = currentTask() else { throw NetworkError.unknown }
        switch message {
        case .text(let text):
            URLSessionLogger.shared.logWebSocketSend(content: text, url: request.url, logLevel: logLevel)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                URLSessionLogger.shared.logWebSocketSend(content: text, url: request.url, logLevel: logLevel)
            }
        }
        do {
            try await task.send(message.taskMessage)
        } catch {
            throw mapError(error)
        }
    }

    /// Sends a text WebSocket frame.
    public func sendText(_ text: String) async throws {
        try await send(.text(text))
    }

    /// Sends a binary WebSocket frame.
    public func sendData(_ data: Data) async throws {
        try await send(.data(data))
    }

    /// Encodes a value as JSON and sends it as a UTF-8 text frame.
    /// Text frames are the convention for JSON payloads over WebSocket.
    public func send<T: Encodable & Sendable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder()
    ) async throws {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NetworkError.unknown
        }
        try await send(.text(text))
    }

    /// Sends a ping frame and emits `.pong` when the server replies.
    public func ping() async throws {
        guard let task = currentTask() else { throw NetworkError.unknown }
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            // URLSessionWebSocketTask.sendPing can invoke its handler more than once
            // on connection abort (POSIX 53). The nonisolated(unsafe) var is safe here
            // because the flag is only read/written inside the serial sendPing callback.
            nonisolated(unsafe) var resumed = false
            task.sendPing { [weak self] error in
                guard !resumed else { return }
                resumed = true
                if let error {
                    continuation.resume(throwing: self?.mapError(error) ?? NetworkError.responseError(error))
                } else {
                    self?.yield(.pong)
                    continuation.resume()
                }
            }
        }
    }

    /// Closes the connection cleanly. All event streams receive `.disconnected` and finish.
    public func close(
        code: URLSessionWebSocketTask.CloseCode = .normalClosure,
        reason: Data? = nil
    ) {
        lock.lock()
        guard !manuallyClosed else {
            lock.unlock()
            return
        }
        manuallyClosed = true
        _state = .disconnected
        let activeTask = task
        let activeReceive = receiveTask
        let activePing = pingTask
        task = nil
        receiveTask = nil
        pingTask = nil
        lock.unlock()

        activeReceive?.cancel()
        activePing?.cancel()
        activeTask?.cancel(with: code, reason: reason)
        yield(.disconnected(code: code, reason: reason))
        finishAll()
    }

    /// Cancels the current task and reconnects immediately, resetting the retry counter.
    public func reconnect() {
        lock.lock()
        let activeTask = task
        let activeReceive = receiveTask
        let activePing = pingTask
        task = nil
        receiveTask = nil
        pingTask = nil
        reconnectAttempts = 0
        manuallyClosed = false
        closedByServer = false
        lock.unlock()

        activeReceive?.cancel()
        activePing?.cancel()
        activeTask?.cancel(with: .goingAway, reason: nil)
        connect()
    }

    /// Returns a typed stream of decoded messages, skipping all non-message events.
    public func messages<T: Decodable & Sendable>(
        of type: T.Type = T.self,
        decoder: JSONDecoder = JSONDecoder()
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events() {
                        guard case .message(let message) = event else { continue }
                        do {
                            continuation.yield(try message.decoded(as: type, decoder: decoder))
                        } catch {
                            continuation.finish(throwing: mapError(error))
                            return
                        }
                    }
                    continuation.finish()
                } catch let error as NetworkError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Delegate callbacks (called by _WebSocketDelegate)

    /// Called when the server confirms the WebSocket handshake. This is the authoritative
    /// point at which the connection is truly established.
    fileprivate func handleDidOpen(webSocketTask: URLSessionWebSocketTask, negotiatedProtocol: String?) {
        lock.lock()
        guard task === webSocketTask, !manuallyClosed else {
            lock.unlock()
            return
        }
        reconnectAttempts = 0
        _state = .connected
        lock.unlock()

        URLSessionLogger.shared.logWebSocketConnected(url: request.url, webSocketProtocol: negotiatedProtocol, logLevel: logLevel)
        yield(.connected)
        startReceiveLoop(for: webSocketTask)
    }

    /// Called when the server sends a close frame (clean server-initiated shutdown).
    fileprivate func handleDidClose(
        webSocketTask: URLSessionWebSocketTask,
        code: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.lock()
        guard task === webSocketTask, !manuallyClosed else {
            lock.unlock()
            return
        }
        closedByServer = true
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        _state = .disconnected
        lock.unlock()

        URLSessionLogger.shared.logWebSocketDisconnected(url: request.url, code: code, reason: reason, logLevel: logLevel)
        yield(.disconnected(code: code, reason: reason))
        finishAll()
    }

    /// Called when the underlying URLSessionTask finishes — either cleanly (nil error,
    /// already handled by handleDidClose) or due to a network failure.
    fileprivate func handleDidComplete(task urlSessionTask: URLSessionTask, error: Error?) {
        guard let wsTask = urlSessionTask as? URLSessionWebSocketTask else { return }

        lock.lock()
        guard self.task === wsTask, !manuallyClosed, !closedByServer else {
            lock.unlock()
            return
        }
        guard let error else {
            // nil error + not closed by server = task completed cleanly some other way
            lock.unlock()
            return
        }
        self.task = nil
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        lock.unlock()

        handleConnectionFailure(error)
    }

    // MARK: - Private helpers

    private func startReceiveLoop(for webSocketTask: URLSessionWebSocketTask) {
        let receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await webSocketTask.receive()
                    let wsMsg = WebSocketMessage(message)
                    switch wsMsg {
                    case .text(let text):
                        URLSessionLogger.shared.logWebSocketReceive(content: text, url: self.request.url, logLevel: self.logLevel)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            URLSessionLogger.shared.logWebSocketReceive(content: text, url: self.request.url, logLevel: self.logLevel)
                        }
                    }
                    self.yield(.message(wsMsg))
                } catch {
                    // Task cancelled or connection dropped.
                    // handleDidComplete(_:error:) drives reconnect logic.
                    return
                }
            }
        }
        lock.lock()
        self.receiveTask = receiveTask
        lock.unlock()
    }

    private func startPingLoopIfNeeded() {
        guard let interval = options.pingInterval, interval > 0 else { return }
        let pingTask = Task { [weak self] in
            while !Task.isCancelled {
                let nanoseconds = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                try? await self?.ping()
            }
        }
        lock.lock()
        self.pingTask = pingTask
        lock.unlock()
    }

    /// Handles network-level task failures and drives the reconnect policy.
    private func handleConnectionFailure(_ error: Error) {
        URLSessionLogger.shared.logResponse(nil, data: nil, error: error, logLevel: logLevel)

        lock.lock()
        let nextAttempt = reconnectAttempts + 1
        let policy = options.reconnectPolicy
        guard nextAttempt <= policy.maximumAttempts else {
            _state = .disconnected
            lock.unlock()
            finishAll(throwing: mapError(error))
            return
        }
        reconnectAttempts = nextAttempt
        let delay = reconnectDelay(for: nextAttempt, policy: policy)
        _state = .reconnecting(attempt: nextAttempt, delay: delay)
        lock.unlock()

        URLSessionLogger.shared.logWebSocketReconnect(url: request.url, attempt: nextAttempt, delay: delay, logLevel: logLevel)
        yield(.reconnecting(attempt: nextAttempt, delay: delay))

        Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.autoConnect()
        }
    }

    /// Used by the auto-reconnect path only. Respects `manuallyClosed` so an explicit
    /// `close()` call during the reconnect delay is not overridden.
    private func autoConnect() {
        lock.lock()
        guard !manuallyClosed else {
            lock.unlock()
            return
        }
        lock.unlock()
        connect()
    }

    private func reconnectDelay(for attempt: Int, policy: WebSocketReconnectPolicy) -> TimeInterval {
        let multiplier = pow(policy.multiplier, Double(max(0, attempt - 1)))
        return min(policy.initialDelay * multiplier, policy.maximumDelay)
    }

    private func currentTask() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    private func yield(_ event: WebSocketEvent) {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        lock.unlock()
        activeContinuations.forEach { $0.yield(event) }
    }

    private func finishAll(throwing error: Error? = nil) {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.values.forEach { continuation in
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func mapError(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError { return networkError }
        if let urlError = error as? URLError { return .urlError(urlError) }
        if let decodingError = error as? DecodingError { return .decodingError(decodingError) }
        return .responseError(error)
    }
}
