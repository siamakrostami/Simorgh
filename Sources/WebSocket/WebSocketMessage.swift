import Foundation

// MARK: - WebSocketMessage

/// A message received from, or sent to, a WebSocket connection.
public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

extension WebSocketMessage {
    internal init(_ taskMessage: URLSessionWebSocketTask.Message) {
        switch taskMessage {
        case .string(let text):
            self = .text(text)
        case .data(let data):
            self = .data(data)
        @unknown default:
            self = .data(Data())
        }
    }

    internal var taskMessage: URLSessionWebSocketTask.Message {
        switch self {
        case .text(let text):
            return .string(text)
        case .data(let data):
            return .data(data)
        }
    }

    /// Decodes the message as JSON.
    public func decoded<T: Decodable>(
        as type: T.Type = T.self,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        switch self {
        case .text(let text):
            guard let data = text.data(using: .utf8) else {
                throw NetworkError.unknown
            }
            return try decoder.decode(type, from: data)
        case .data(let data):
            return try decoder.decode(type, from: data)
        }
    }
}

// MARK: - WebSocketEvent

/// Lifecycle and data events emitted by a `WebSocketConnection`.
public enum WebSocketEvent: Sendable, Equatable {
    case connected
    case message(WebSocketMessage)
    case pong
    case reconnecting(attempt: Int, delay: TimeInterval)
    case disconnected(code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

// MARK: - WebSocketReconnectPolicy

/// Controls automatic reconnection after unexpected WebSocket failures.
public struct WebSocketReconnectPolicy: Sendable, Equatable {
    public let maximumAttempts: Int
    public let initialDelay: TimeInterval
    public let multiplier: Double
    public let maximumDelay: TimeInterval

    public init(
        maximumAttempts: Int,
        initialDelay: TimeInterval = 1,
        multiplier: Double = 2,
        maximumDelay: TimeInterval = 30
    ) {
        let sanitizedInitialDelay = max(0, initialDelay)
        self.maximumAttempts = max(0, maximumAttempts)
        self.initialDelay = sanitizedInitialDelay
        self.multiplier = max(1, multiplier)
        self.maximumDelay = max(sanitizedInitialDelay, maximumDelay)
    }

    public static let none = WebSocketReconnectPolicy(maximumAttempts: 0)
}

// MARK: - WebSocketOptions

/// Runtime options for a WebSocket connection.
public struct WebSocketOptions: Sendable, Equatable {
    public let maximumMessageSize: Int
    public let pingInterval: TimeInterval?
    public let reconnectPolicy: WebSocketReconnectPolicy

    public init(
        maximumMessageSize: Int = 1_048_576,
        pingInterval: TimeInterval? = nil,
        reconnectPolicy: WebSocketReconnectPolicy = .none
    ) {
        self.maximumMessageSize = maximumMessageSize
        self.pingInterval = pingInterval
        self.reconnectPolicy = reconnectPolicy
    }
}
