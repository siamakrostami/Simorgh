import XCTest
@testable import Simorgh

final class LoggerRedactionTests: XCTestCase {
    func testBearerTokenIsRedactedButSchemeKept() {
        XCTAssertEqual(URLSessionLogger.redactedHeaderValue(name: "Authorization", value: "Bearer abc.def.ghi"), "Bearer <redacted>")
    }

    func testHeaderNameIsCaseInsensitive() {
        XCTAssertEqual(URLSessionLogger.redactedHeaderValue(name: "authorization", value: "Basic dXNlcjpwYXNz"), "Basic <redacted>")
        XCTAssertEqual(URLSessionLogger.redactedHeaderValue(name: "SET-COOKIE", value: "session=1"), "<redacted>")
    }

    func testOtherHeadersArePrintedAsIs() {
        XCTAssertEqual(URLSessionLogger.redactedHeaderValue(name: "Upload-Offset", value: "1024"), "1024")
        XCTAssertEqual(URLSessionLogger.redactedHeaderValue(name: "Content-Type", value: "application/json"), "application/json")
    }
}
