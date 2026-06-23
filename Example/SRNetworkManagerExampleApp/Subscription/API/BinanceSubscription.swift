import Foundation
import SRNetworkManager

/// A SubscriptionRouter for Binance live trade data.
///
/// Demonstrates the Amplify-style subscription pattern:
/// - `subscribeMessage` is sent automatically after the WebSocket handshake.
/// - `unsubscribeMessage` is sent automatically when the subscription stops.
/// - `decodeEvent` silently skips subscription-ack frames by using `try?`.
struct BinanceSubscription: SubscriptionRouter {
    struct Message: Encodable, Sendable {
        let method: String
        let params: [String]
        let id: Int
    }

    typealias Event = RealtimeTrade

    var baseURLString: String { "wss://stream.binance.com:9443" }
    var path: String { "/ws" }

    let symbol: String

    var subscribeMessage: Message {
        Message(method: "SUBSCRIBE", params: ["\(symbol.lowercased())@trade"], id: 1)
    }

    var unsubscribeMessage: Message? {
        Message(method: "UNSUBSCRIBE", params: ["\(symbol.lowercased())@trade"], id: 1)
    }

    /// Returns `nil` for subscription-ack frames so they are silently skipped.
    func decodeEvent(from message: WebSocketMessage, using decoder: JSONDecoder) throws -> RealtimeTrade? {
        try? message.decoded(as: RealtimeTrade.self, decoder: decoder)
    }
}
