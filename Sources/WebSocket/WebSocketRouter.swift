import Foundation

// MARK: - WebSocketRouterError

/// Errors that can occur while building WebSocket requests.
public enum WebSocketRouterError: Error, Sendable {
    case invalidURL
    case invalidScheme(String?)
}

// MARK: - WebSocketRouter

/// A type-safe description of a WebSocket endpoint.
///
/// `WebSocketRouter` intentionally mirrors `NetworkRouter` where that makes sense:
/// base URL, path, headers, API version, and query parameters. Body parameters are
/// excluded because WebSocket handshakes are GET upgrade requests; after connection,
/// data should be sent through `WebSocketConnection.send(...)`.
public protocol WebSocketRouter: Sendable {
    associatedtype QueryParameters: Codable = EmptyParameters

    var baseURLString: String { get }
    var path: String { get }
    var headers: [String: String]? { get }
    var queryParams: QueryParameters? { get }
    var version: APIVersion? { get }
    var protocols: [String] { get }

    func asURLRequest() throws -> URLRequest
}

extension WebSocketRouter {
    public var headers: [String: String]? { nil }
    public var queryParams: QueryParameters? { nil }
    public var version: APIVersion? { nil }
    public var protocols: [String] { [] }

    public func asURLRequest() throws -> URLRequest {
        let fullPath = baseURLString + (version?.path ?? "") + path
        guard let url = URL(string: fullPath) else {
            throw WebSocketRouterError.invalidURL
        }

        guard url.scheme == "ws" || url.scheme == "wss" else {
            throw WebSocketRouterError.invalidScheme(url.scheme)
        }

        var request = URLRequest(url: url)
        request.httpMethod = RequestMethod.get.rawValue.uppercased()
        request.allHTTPHeaderFields = headers

        if let queryParams {
            try URLEncoding(destination: .queryString).encode(&request, with: queryParams)
        }

        return request
    }
}
