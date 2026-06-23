import Foundation

// MARK: - SubscriptionRouter

/// Describes a WebSocket subscription endpoint: the transport (URL, headers, query params via
/// `WebSocketRouter`) plus the application-level subscribe/unsubscribe protocol layered on top.
///
/// This mirrors the pattern used by AWS AppSync, Hasura, and similar real-time APIs where:
/// 1. A WebSocket connection is established.
/// 2. A JSON `subscribeMessage` is sent to start receiving events.
/// 3. The server pushes typed data frames.
/// 4. An optional `unsubscribeMessage` is sent to stop the subscription cleanly.
///
/// ## Minimal example
/// ```swift
/// struct PriceSubscription: SubscriptionRouter {
///     struct Message: Encodable, Sendable {
///         let action: String
///         let symbol: String
///     }
///     typealias Event = PriceUpdate
///
///     var baseURLString: String { "wss://prices.example.com" }
///     var path: String { "/stream" }
///     let symbol: String
///
///     var subscribeMessage: Message   { Message(action: "subscribe",   symbol: symbol) }
///     var unsubscribeMessage: Message? { Message(action: "unsubscribe", symbol: symbol) }
/// }
/// ```
///
/// ## Decoding
/// The default `decodeEvent(from:using:)` implementation attempts to decode every incoming
/// message as `Event`. Override when the server also sends acknowledgement, keepalive, or
/// error frames that should be skipped:
/// ```swift
/// func decodeEvent(from message: WebSocketMessage, using decoder: JSONDecoder) throws -> Event? {
///     // Return nil to skip non-data frames; throw to propagate a hard decode failure.
///     return try? message.decoded(as: Event.self, decoder: decoder)
/// }
/// ```
public protocol SubscriptionRouter: WebSocketRouter {
    /// The type sent to start (and optionally stop) the subscription.
    associatedtype SubscribeMessage: Encodable & Sendable

    /// The typed event emitted by this subscription.
    associatedtype Event: Decodable & Sendable

    /// Sent immediately after the WebSocket handshake completes (and after every automatic
    /// reconnect) to register the subscription with the server.
    var subscribeMessage: SubscribeMessage { get }

    /// Sent when the subscription is stopped. Return `nil` when the server does not require
    /// an unsubscribe frame (e.g. closing the connection is sufficient).
    var unsubscribeMessage: SubscribeMessage? { get }

    /// Converts a raw `WebSocketMessage` into a typed `Event`.
    ///
    /// - Return `nil` to silently drop the message (acknowledgements, keepalives, etc.).
    /// - Throw to propagate a decoding failure to the caller's stream.
    func decodeEvent(from message: WebSocketMessage, using decoder: JSONDecoder) throws -> Event?
}

// MARK: - Default implementations

extension SubscriptionRouter {
    public var unsubscribeMessage: SubscribeMessage? { nil }

    /// Attempts to decode every incoming message as `Event`.
    /// Override to return `nil` for non-data frames instead of throwing.
    public func decodeEvent(
        from message: WebSocketMessage,
        using decoder: JSONDecoder
    ) throws -> Event? {
        try message.decoded(as: Event.self, decoder: decoder)
    }
}
