import XCTest
@testable import Simorgh

// MARK: - Helpers

private struct AnyEvent: Decodable, Sendable {
    let type: String
}

/// Records whether negotiate was called and what messages were exchanged.
private actor NegotiationSpy {
    var negotiateCalled = false
    var sentMessages: [WebSocketMessage] = []
    var receiveResult: WebSocketMessage = .text("{}")

    func markCalled() { negotiateCalled = true }
    func recordSend(_ msg: WebSocketMessage) { sentMessages.append(msg) }
    func nextReceive() -> WebSocketMessage { receiveResult }
}

private struct MockTransport: SubscriptionTransport {
    let spy: NegotiationSpy

    func send(_ message: WebSocketMessage) async throws {
        await spy.recordSend(message)
    }

    func receive() async throws -> WebSocketMessage {
        await spy.nextReceive()
    }
}

// MARK: - Routers under test

/// Minimal router — does NOT override negotiate (backward-compat case).
private struct MinimalRouter: SubscriptionRouter {
    struct Sub: Encodable, Sendable { let action = "subscribe" }
    typealias Event = AnyEvent

    var baseURLString: String { "wss://example.com" }
    var path: String { "/ws" }
    var subscribeMessage: Sub { Sub() }
}

/// Router that overrides negotiate to perform a two-step handshake.
private struct NegotiatingRouter: SubscriptionRouter {
    struct Sub: Encodable, Sendable { let action: String }
    typealias Event = AnyEvent

    var baseURLString: String { "wss://example.com" }
    var path: String { "/ws" }
    var subscribeMessage: Sub { Sub(action: "subscribe") }
    var unsubscribeMessage: Sub? { Sub(action: "unsubscribe") }

    let spy: NegotiationSpy

    func negotiate(over transport: any SubscriptionTransport) async throws {
        await spy.markCalled()
        try await transport.send(.text(#"{"type":"connection_init"}"#))
        let ack = try await transport.receive()
        guard case .text(let txt) = ack, txt.contains("connection_ack") else {
            throw URLError(.badServerResponse)
        }
    }

    func decodeEvent(from message: WebSocketMessage, using decoder: JSONDecoder) throws -> AnyEvent? {
        try? message.decoded(as: AnyEvent.self, decoder: decoder)
    }
}

/// Router whose negotiate always throws.
private struct FailingNegotiationRouter: SubscriptionRouter {
    struct Sub: Encodable, Sendable { let x = 0 }
    typealias Event = AnyEvent

    var baseURLString: String { "wss://example.com" }
    var path: String { "/ws" }
    var subscribeMessage: Sub { Sub() }

    func negotiate(over transport: any SubscriptionTransport) async throws {
        throw URLError(.timedOut)
    }
}

// MARK: - Tests

final class SubscriptionRouterTests: XCTestCase {

    // MARK: - Backward compatibility

    func testDefaultNegotiateIsNoOp() async throws {
        let router = MinimalRouter()
        let spy = NegotiationSpy()
        let transport = MockTransport(spy: spy)

        // Should complete without error and without touching the transport.
        try await router.negotiate(over: transport)

        let called = await spy.negotiateCalled
        let sent = await spy.sentMessages
        XCTAssertFalse(called, "Default negotiate must not call through to spy")
        XCTAssertTrue(sent.isEmpty, "Default negotiate must send nothing")
    }

    func testMinimalRouterURLRequestBuilds() throws {
        let request = try MinimalRouter().asURLRequest()
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "example.com")
    }

    // MARK: - Custom negotiate

    func testNegotiatingRouterCallsNegotiate() async throws {
        let spy = NegotiationSpy()
        let router = NegotiatingRouter(spy: spy)

        // Wire a transport that returns a valid ack.
        await spy.receiveResult(returning: .text(#"{"type":"connection_ack"}"#))

        let transport = MockTransport(spy: spy)
        try await router.negotiate(over: transport)

        let called = await spy.negotiateCalled
        XCTAssertTrue(called)

        let sent = await spy.sentMessages
        XCTAssertEqual(sent.count, 1)
        if case .text(let txt) = sent[0] {
            XCTAssertTrue(txt.contains("connection_init"))
        } else {
            XCTFail("Expected text message containing connection_init")
        }
    }

    func testNegotiatingRouterThrowsOnBadAck() async throws {
        let spy = NegotiationSpy()
        let router = NegotiatingRouter(spy: spy)
        // Transport returns a non-ack message.
        let transport = MockTransport(spy: spy)  // default receiveResult is "{}" — no "connection_ack"

        do {
            try await router.negotiate(over: transport)
            XCTFail("Expected negotiate to throw on bad ack")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    func testFailingNegotiationRouterPropagatesError() async throws {
        let router = FailingNegotiationRouter()
        let spy = NegotiationSpy()
        let transport = MockTransport(spy: spy)

        do {
            try await router.negotiate(over: transport)
            XCTFail("Expected error propagation")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .timedOut)
        }
    }

    // MARK: - Unsubscribe / decodeEvent defaults

    func testUnsubscribeDefaultIsNil() {
        XCTAssertNil(MinimalRouter().unsubscribeMessage)
    }

    func testNegotiatingRouterUnsubscribeDefined() {
        let router = NegotiatingRouter(spy: NegotiationSpy())
        let msg = router.unsubscribeMessage
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.action, "unsubscribe")
    }

    func testDecodeEventReturnsNilForUnrecognisedFrame() throws {
        let router = NegotiatingRouter(spy: NegotiationSpy())
        let result = try router.decodeEvent(from: .text("not json"), using: JSONDecoder())
        XCTAssertNil(result, "decodeEvent override should return nil for undecodable frames")
    }

    func testDecodeEventDefaultThrowsOnBadJSON() {
        let router = MinimalRouter()
        XCTAssertThrowsError(
            try router.decodeEvent(from: .text("not json"), using: JSONDecoder())
        )
    }
}

// MARK: - NegotiationSpy actor extension

private extension NegotiationSpy {
    func receiveResult(returning msg: WebSocketMessage) {
        receiveResult = msg
    }
}
