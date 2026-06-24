import Combine
import Foundation

// MARK: - _SubjectRetainer

/// Wraps a PassthroughSubject as @unchecked Sendable (PassthroughSubject is internally
/// synchronized) and retains the owning SubscriptionConnection so the WebSocket stays
/// alive for the lifetime of the Combine publisher.
private final class _SubjectRetainer<Event: Sendable, Owner: AnyObject>: @unchecked Sendable {
    let subject = PassthroughSubject<Event, NetworkError>()
    let owner: Owner
    init(_ owner: Owner) { self.owner = owner }
}

// MARK: - HandshakeTransport

/// Wraps a `WebSocketConnection` and exposes only the send/receive surface needed
/// during a negotiation phase. Subscribes to the connection's event stream at init
/// time so no messages are missed between creation and the first `receive()` call.
private final class HandshakeTransport: SubscriptionTransport, @unchecked Sendable {
    private let ws: WebSocketConnection
    private var iterator: WebSocketConnection.EventStream.AsyncIterator

    init(ws: WebSocketConnection) {
        self.ws = ws
        self.iterator = ws.events().makeAsyncIterator()
    }

    func send(_ message: WebSocketMessage) async throws {
        try await ws.send(message)
    }

    func receive() async throws -> WebSocketMessage {
        while let event = try await iterator.next() {
            switch event {
            case .message(let msg):
                return msg
            case .disconnected:
                throw NetworkError.unknown
            case .connected, .reconnecting, .pong:
                continue
            }
        }
        throw NetworkError.unknown
    }
}

// MARK: - SubscriptionConnection

/// Manages the lifecycle of a single subscription over a `WebSocketConnection`.
///
/// `SubscriptionConnection` handles:
/// - Sending `router.subscribeMessage` when the WebSocket connects (and on every reconnect).
/// - Filtering and decoding incoming frames via `router.decodeEvent(from:using:)`.
/// - Sending `router.unsubscribeMessage` when `disconnect()` is called.
///
/// ## Typical usage — explicit lifecycle
/// ```swift
/// let sub = try apiClient.subscription(MySubscription())
///
/// // Set up stream BEFORE connecting so no events are missed.
/// Task {
///     for try await event in sub.events() {
///         print(event)
///     }
/// }
/// sub.connect()
///
/// // Later:
/// await sub.disconnect()
/// ```
///
/// ## Convenience (fire-and-forget)
/// Use `APIClient.subscribe(_:options:decoder:)` when you don't need explicit control:
/// ```swift
/// for try await event in apiClient.subscribe(MySubscription()) { ... }         // async/await
/// apiClient.subscribe(MySubscription()).sink { ... }.store(in: &cancellables)  // Combine
/// ```
public final class SubscriptionConnection<R: SubscriptionRouter>: @unchecked Sendable {

    // MARK: - Properties

    private let wsConnection: WebSocketConnection
    private let router: R
    private let decoder: JSONDecoder
    private let logLevel: LogLevel

    // MARK: - Init

    internal init(
        wsConnection: WebSocketConnection,
        router: R,
        decoder: JSONDecoder,
        logLevel: LogLevel = .none
    ) {
        self.wsConnection = wsConnection
        self.router = router
        self.decoder = decoder
        self.logLevel = logLevel
    }

    deinit {
        wsConnection.close()
    }

    // MARK: - Public API

    /// The current WebSocket connection state.
    public var state: WebSocketConnectionState {
        wsConnection.state
    }

    /// Initiates the WebSocket handshake.
    ///
    /// Call this AFTER setting up your `events()` or `publisher()` consumer so that the
    /// `.connected` event — which triggers the subscribe message — is not missed.
    public func connect() {
        wsConnection.connect()
    }

    /// Sends `unsubscribeMessage` (if defined) and closes the WebSocket.
    public func disconnect() async {
        if let msg = router.unsubscribeMessage {
            if let data = try? JSONEncoder().encode(msg), let str = String(data: data, encoding: .utf8) {
                URLSessionLogger.shared.logSubscriptionEvent(label: "UNSUBSCRIBE", url: wsConnection.url, content: str, logLevel: logLevel)
            }
            try? await wsConnection.send(msg)
        }
        wsConnection.close()
    }

    /// Cancels the current task and reconnects immediately, resetting the retry counter.
    /// The subscribe message is re-sent automatically on reconnect.
    public func reconnect() {
        wsConnection.reconnect()
    }

    // MARK: - Async / Await

    /// Returns an `AsyncThrowingStream` of typed subscription events.
    ///
    /// The subscribe message is sent automatically on every `.connected` event (initial
    /// connect and after each automatic reconnect). Frames that `decodeEvent` returns `nil`
    /// for are silently dropped. The stream throws when reconnect attempts are exhausted.
    ///
    /// **Important:** Set up this stream and start your consumer loop before calling
    /// `connect()`, otherwise the initial `.connected` event may be missed.
    public func events() -> AsyncThrowingStream<R.Event, Error> {
        makeEventStream()
    }

    // MARK: - Combine

    /// Returns a Combine publisher of typed subscription events.
    ///
    /// The publisher completes when the connection closes cleanly and fails when
    /// reconnect attempts are exhausted. The subscribe message is sent automatically
    /// on every (re)connect.
    ///
    /// `SubscriptionConnection` is retained for the lifetime of the publisher.
    public func publisher() -> AnyPublisher<R.Event, NetworkError> {
        // _SubjectRetainer is @unchecked Sendable and holds both the PassthroughSubject
        // (which is internally synchronized) and a strong reference to self so the
        // WebSocket is not torn down while the publisher is active.
        let retainer = _SubjectRetainer<R.Event, SubscriptionConnection<R>>(self)
        let stream = makeEventStream()

        let task = Task {
            do {
                for try await event in stream {
                    retainer.subject.send(event)
                }
                retainer.subject.send(completion: .finished)
            } catch let error as NetworkError {
                retainer.subject.send(completion: .failure(error))
            } catch {
                retainer.subject.send(completion: .failure(.responseError(error)))
            }
        }

        return retainer.subject
            .handleEvents(receiveCancel: { [retainer] in
                task.cancel()
                _ = retainer
            })
            .eraseToAnyPublisher()
    }

    // MARK: - Private

    private func makeEventStream() -> AsyncThrowingStream<R.Event, Error> {
        let router = self.router
        let decoder = self.decoder
        let ws = self.wsConnection
        let logLevel = self.logLevel

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in ws.events() {
                        switch event {
                        case .connected:
                            let transport = HandshakeTransport(ws: ws)
                            try await router.negotiate(over: transport)
                            if let data = try? JSONEncoder().encode(router.subscribeMessage),
                               let str = String(data: data, encoding: .utf8) {
                                URLSessionLogger.shared.logSubscriptionEvent(label: "SUBSCRIBE", url: ws.url, content: str, logLevel: logLevel)
                            }
                            try await ws.send(router.subscribeMessage)
                        case .message(let message):
                            if let decoded = try router.decodeEvent(from: message, using: decoder) {
                                if logLevel == .verbose {
                                    let raw: String
                                    switch message {
                                    case .text(let t): raw = t
                                    case .data(let d): raw = String(data: d, encoding: .utf8) ?? "<binary>"
                                    }
                                    URLSessionLogger.shared.logSubscriptionEvent(label: "EVENT", url: ws.url, content: raw, logLevel: logLevel)
                                }
                                continuation.yield(decoded)
                            }
                        case .disconnected:
                            continuation.finish()
                            return
                        case .reconnecting, .pong:
                            // Transparent to subscriber
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
