import Foundation
import Simorgh

struct BinanceTradeSocket: WebSocketRouter {
    var baseURLString: String { "wss://stream.binance.com:9443" }
    var path: String { "/ws" }
}
