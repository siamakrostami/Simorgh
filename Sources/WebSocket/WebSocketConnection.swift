import Foundation

/// A reusable WebSocket connection with async send, receive, ping, close, and reconnect support.
public final class WebSocketConnection: @unchecked Sendable {
    public typealias EventStream = AsyncThrowingStream<WebSocketEvent, Error>

    private let request: URLRequest
    private let session: URLSession
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

    internal init(
        request: URLRequest,
        session: URLSession,
        protocols: [String],
        options: WebSocketOptions,
        logLevel: LogLevel
    ) {
        self.request = request
        self.session = session
        self.protocols = protocols
        self.options = options
        self.logLevel = logLevel
    }

    deinit {
        close(code: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    /// Returns an async stream of connection events. Each call creates an independent subscriber.
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

    /// Connects the WebSocket if it is not already connected.
    public func connect() {
        lock.lock()
        if task != nil {
            lock.unlock()
            return
        }

        manuallyClosed = false
        var handshakeRequest = request
        if !protocols.isEmpty {
            handshakeRequest.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }

        let webSocketTask = session.webSocketTask(with: handshakeRequest)
        webSocketTask.maximumMessageSize = options.maximumMessageSize
        task = webSocketTask
        lock.unlock()

        URLSessionLogger.shared.logRequest(request, logLevel: logLevel)
        webSocketTask.resume()
        yield(.connected)
        startReceiveLoop(for: webSocketTask)
        startPingLoopIfNeeded()
    }

    /// Sends a WebSocket message.
    public func send(_ message: WebSocketMessage) async throws {
        guard let task = currentTask() else {
            throw NetworkError.unknown
        }

        do {
            try await task.send(message.taskMessage)
        } catch {
            throw mapError(error)
        }
    }

    /// Sends a text WebSocket message.
    public func sendText(_ text: String) async throws {
        try await send(.text(text))
    }

    /// Sends a binary WebSocket message.
    public func sendData(_ data: Data) async throws {
        try await send(.data(data))
    }

    /// Encodes a value as JSON and sends it as binary data.
    public func send<T: Encodable & Sendable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder()
    ) async throws {
        let data = try encoder.encode(value)
        try await send(.data(data))
    }

    /// Sends a ping frame and emits `.pong` when the server replies.
    public func ping() async throws {
        guard let task = currentTask() else {
            throw NetworkError.unknown
        }

        let _: Void = try await withCheckedThrowingContinuation { continuation in
            task.sendPing { [weak self] error in
                if let error {
                    continuation.resume(throwing: self?.mapError(error) ?? NetworkError.responseError(error))
                } else {
                    self?.yield(.pong)
                    continuation.resume()
                }
            }
        }
    }

    /// Closes the connection. Existing event streams receive `.disconnected` and finish.
    public func close(
        code: URLSessionWebSocketTask.CloseCode = .normalClosure,
        reason: Data? = nil
    ) {
        let activeTask: URLSessionWebSocketTask?
        let activeReceiveTask: Task<Void, Never>?
        let activePingTask: Task<Void, Never>?

        lock.lock()
        manuallyClosed = true
        activeTask = task
        activeReceiveTask = receiveTask
        activePingTask = pingTask
        task = nil
        receiveTask = nil
        pingTask = nil
        lock.unlock()

        activeReceiveTask?.cancel()
        activePingTask?.cancel()
        activeTask?.cancel(with: code, reason: reason)
        yield(.disconnected(code: code, reason: reason))
        finishAll()
    }

    /// Attempts to reconnect immediately and resets automatic reconnect state.
    public func reconnect() {
        cancelCurrentTaskForReconnect()
        lock.lock()
        reconnectAttempts = 0
        manuallyClosed = false
        lock.unlock()
        connect()
    }

    /// Decodes incoming messages of a specific type from the event stream.
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

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func startReceiveLoop(for webSocketTask: URLSessionWebSocketTask) {
        let task = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let message = try await webSocketTask.receive()
                    self.resetReconnectAttempts()
                    self.yield(.message(WebSocketMessage(message)))
                } catch {
                    self.handleReceiveFailure(error)
                    return
                }
            }
        }

        lock.lock()
        receiveTask = task
        lock.unlock()
    }

    private func startPingLoopIfNeeded() {
        guard let interval = options.pingInterval, interval > 0 else { return }

        let task = Task { [weak self] in
            while !Task.isCancelled {
                let nanoseconds = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                try? await self?.ping()
            }
        }

        lock.lock()
        pingTask = task
        lock.unlock()
    }

    private func handleReceiveFailure(_ error: Error) {
        URLSessionLogger.shared.logResponse(nil, data: nil, error: error, logLevel: logLevel)

        lock.lock()
        let shouldStop = manuallyClosed
        task = nil
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil

        if shouldStop {
            lock.unlock()
            return
        }

        let nextAttempt = reconnectAttempts + 1
        let policy = options.reconnectPolicy
        guard nextAttempt <= policy.maximumAttempts else {
            lock.unlock()
            finishAll(throwing: mapError(error))
            return
        }

        reconnectAttempts = nextAttempt
        let delay = reconnectDelay(for: nextAttempt, policy: policy)
        lock.unlock()

        yield(.reconnecting(attempt: nextAttempt, delay: delay))

        Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.connect()
        }
    }

    private func reconnectDelay(for attempt: Int, policy: WebSocketReconnectPolicy) -> TimeInterval {
        let multiplier = pow(policy.multiplier, Double(max(0, attempt - 1)))
        return min(policy.initialDelay * multiplier, policy.maximumDelay)
    }

    private func cancelCurrentTaskForReconnect() {
        let activeTask: URLSessionWebSocketTask?
        let activeReceiveTask: Task<Void, Never>?
        let activePingTask: Task<Void, Never>?

        lock.lock()
        activeTask = task
        activeReceiveTask = receiveTask
        activePingTask = pingTask
        task = nil
        receiveTask = nil
        pingTask = nil
        lock.unlock()

        activeReceiveTask?.cancel()
        activePingTask?.cancel()
        activeTask?.cancel(with: .goingAway, reason: nil)
    }

    private func currentTask() -> URLSessionWebSocketTask? {
        lock.lock()
        let task = task
        lock.unlock()
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
        let activeContinuations = continuations
        continuations.removeAll()
        lock.unlock()

        activeContinuations.values.forEach { continuation in
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func mapError(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError {
            return networkError
        }
        if let urlError = error as? URLError {
            return .urlError(urlError)
        }
        if let decodingError = error as? DecodingError {
            return .decodingError(decodingError)
        }
        return .responseError(error)
    }

    private func resetReconnectAttempts() {
        lock.lock()
        reconnectAttempts = 0
        lock.unlock()
    }
}
