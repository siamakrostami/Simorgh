import XCTest
@testable import Simorgh

final class QueryEncodingTests: XCTestCase {
    private struct Query: Codable, Sendable {
        let page: Int
        let limit: Int
        let offset: Int
        let flag: Bool
        let other: Bool
        let name: String
    }

    private func encodedQuery(_ query: Query) throws -> [String: String] {
        var request = URLRequest(url: URL(string: "https://api.example.com/files")!)
        try URLEncoding(destination: .queryString).encode(&request, with: query)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    /// `page=1` used to be encoded as `page=true` because `NSNumber(1) as? Bool` succeeds.
    func testIntegersZeroAndOneAreNotEncodedAsBooleans() throws {
        let query = try encodedQuery(Query(page: 1, limit: 100, offset: 0, flag: true, other: false, name: "x"))
        XCTAssertEqual(query["page"], "1")
        XCTAssertEqual(query["limit"], "100")
        XCTAssertEqual(query["offset"], "0")
    }

    func testRealBooleansStillEncodeAsTrueAndFalse() throws {
        let query = try encodedQuery(Query(page: 2, limit: 10, offset: 5, flag: true, other: false, name: "x"))
        XCTAssertEqual(query["flag"], "true")
        XCTAssertEqual(query["other"], "false")
        XCTAssertEqual(query["name"], "x")
    }
}
