import XCTest
@testable import SRNetworkManager

final class WebSocketRouterTests: XCTestCase {
    struct ChatSocket: WebSocketRouter {
        struct Query: Codable {
            let room: String
            let token: String
        }

        var baseURLString: String { "wss://api.example.com" }
        var path: String { "/chat" }
        var headers: [String: String]? { ["Authorization": "Bearer abc"] }
        var queryParams: Query? { Query(room: "general", token: "123") }
        var protocols: [String] { ["chat.v1"] }
    }

    struct InvalidSocket: WebSocketRouter {
        var baseURLString: String { "https://api.example.com" }
        var path: String { "/chat" }
    }

    struct VersionedSocket: WebSocketRouter {
        struct Query: Codable {
            let cursor: String
        }

        var baseURLString: String { "wss://api.example.com/" }
        var path: String { "/events" }
        var queryParams: Query? { Query(cursor: "latest") }
        var version: APIVersion? { .custom(path: nil, version: .v2) }
    }

    struct Message: Codable, Equatable {
        let id: Int
        let body: String
    }

    func testWebSocketRouterBuildsURLRequest() throws {
        let request = try ChatSocket().asURLRequest()

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.example.com")
        XCTAssertEqual(request.url?.path, "/chat")

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        XCTAssertTrue(queryItems.contains(URLQueryItem(name: "room", value: "general")))
        XCTAssertTrue(queryItems.contains(URLQueryItem(name: "token", value: "123")))
    }

    func testWebSocketRouterRejectsNonWebSocketSchemes() {
        XCTAssertThrowsError(try InvalidSocket().asURLRequest()) { error in
            guard case WebSocketRouterError.invalidScheme("https") = error else {
                XCTFail("Expected invalidScheme error, got \(error)")
                return
            }
        }
    }

    func testWebSocketMessageDecodesTextJSON() throws {
        let payload = #"{"id":1,"body":"hello"}"#
        let message = WebSocketMessage.text(payload)

        let decoded = try message.decoded(as: Message.self)

        XCTAssertEqual(decoded, Message(id: 1, body: "hello"))
    }

    func testWebSocketMessageDecodesBinaryJSON() throws {
        let data = try JSONEncoder().encode(Message(id: 2, body: "binary"))
        let message = WebSocketMessage.data(data)

        let decoded = try message.decoded(as: Message.self)

        XCTAssertEqual(decoded, Message(id: 2, body: "binary"))
    }

    func testReconnectPolicyClampsInvalidValues() {
        let policy = WebSocketReconnectPolicy(
            maximumAttempts: -1,
            initialDelay: -2,
            multiplier: 0.5,
            maximumDelay: -1
        )

        XCTAssertEqual(policy.maximumAttempts, 0)
        XCTAssertEqual(policy.initialDelay, 0)
        XCTAssertEqual(policy.multiplier, 1)
        XCTAssertEqual(policy.maximumDelay, 0)
    }

    func testWebSocketRouterAppliesAPIVersionBeforePath() throws {
        let request = try VersionedSocket().asURLRequest()

        XCTAssertEqual(request.url?.path, "/v2/events")
        XCTAssertTrue(request.url?.absoluteString.contains("cursor=latest") == true)
    }

    func testAPIClientPropagatesInvalidWebSocketEndpointErrors() {
        let client = APIClient()

        XCTAssertThrowsError(try client.webSocketConnection(InvalidSocket())) { error in
            guard case WebSocketRouterError.invalidScheme("https") = error else {
                XCTFail("Expected invalidScheme error, got \(error)")
                return
            }
        }
    }

    func testWebSocketOptionsPreserveConfiguredValues() {
        let reconnectPolicy = WebSocketReconnectPolicy(
            maximumAttempts: 4,
            initialDelay: 0.5,
            multiplier: 1.5,
            maximumDelay: 10
        )
        let options = WebSocketOptions(
            maximumMessageSize: 2_048,
            pingInterval: 20,
            reconnectPolicy: reconnectPolicy
        )

        XCTAssertEqual(options.maximumMessageSize, 2_048)
        XCTAssertEqual(options.pingInterval, 20)
        XCTAssertEqual(options.reconnectPolicy, reconnectPolicy)
    }
}
