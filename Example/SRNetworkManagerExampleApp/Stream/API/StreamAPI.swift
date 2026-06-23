import Foundation
import Simorgh

// httpbin.org/stream/:n returns n newline-delimited JSON objects — perfect for SSE demo.
struct StreamRouter: NetworkRouter {
    let count: Int

    var baseURLString: String { "https://httpbin.org" }
    var path: String { "/stream/\(count)" }
    var method: RequestMethod { .get }
    var version: String { "" }
}

// Each line returned by httpbin /stream/:n
struct StreamChunk: Codable, Sendable {
    let id: Int
    let url: String
    let origin: String
}
