import Foundation

struct RealtimeTrade: Codable, Identifiable, Sendable {
    let eventType: String
    let eventTime: Int
    let symbol: String
    let tradeID: Int
    let price: String
    let quantity: String
    let tradeTime: Int
    let isBuyerMarketMaker: Bool

    var id: Int { tradeID }

    var priceValue: Double {
        Double(price) ?? 0
    }

    var quantityValue: Double {
        Double(quantity) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case eventType = "e"
        case eventTime = "E"
        case symbol = "s"
        case tradeID = "t"
        case price = "p"
        case quantity = "q"
        case tradeTime = "T"
        case isBuyerMarketMaker = "m"
    }
}

struct RealtimeSubscriptionRequest: Encodable, Sendable {
    let method: String
    let params: [String]
    let id: Int
}

struct RealtimeSubscriptionAcknowledgement: Decodable, Sendable {
    let result: String?
    let id: Int
}
