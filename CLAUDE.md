# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build the package
swift build

# Run all tests
swift test

# Run a single test class
swift test --filter NetworkRouterTests

# Run a single test method
swift test --filter NetworkRouterTests/testRouterWithBothQueryAndBodyParams
```

The package targets Swift 5 and Swift 6 (`swiftLanguageModes: [.v6, .v5]`). The `SPM_SWIFT_6` define flag is active — all public API must be `Sendable`-safe.

## Architecture

**Simorgh** is a Swift Package with one library target (`Sources/`) and one test target (`Tests/`). There is also an `Example/` Xcode project that demonstrates usage but is not part of the package.

### Request flow

```
Consumer code
  → NetworkRouter (endpoint definition, builds URLRequest via asURLRequest())
  → APIClient (executes request, decodes response, manages retry)
      → URLSessionLogger (logs at the configured LogLevel)
      → RetryHandler (shouldRetry / modifyRequestForRetry on failure)
      → NetworkError (maps URLError / DecodingError / HTTP status codes)
```

### Key protocols

| Protocol | Purpose |
|---|---|
| `NetworkRouter` | Defines an HTTP endpoint. Implement `baseURLString`, `path`, `method`, and optionally `params`, `queryParams`, `headers`, `version`. `asURLRequest()` has a default implementation. |
| `WebSocketRouter` | Same shape as `NetworkRouter` minus body params. Validates `ws://` / `wss://` scheme. |
| `RetryHandler` | Controls retry policy. Must implement both sync and async variants of `shouldRetry` and `modifyRequestForRetry`. |

### Threading model

`APIClient` is `@unchecked Sendable`. All mutable state is protected by a private `DispatchQueue` (`apiQueue`) using `.barrier` flags for writes. New `URLSession` instances are created per request and tracked in `_activeSessions`. Combine publishers publish on `DispatchQueue.main`; the underlying work runs on `apiQueue`.

### Source modules (under `Sources/`)

- **Client/** — `APIClient` (all request/upload/stream/WebSocket methods), `CacheStrategy`, `DefaultRetryHandler`, `MultipartFormField`, `RetryHandler` protocol, `SendablePromise`
- **Router/** — `NetworkRouter` protocol + `RequestMethod`, `EmptyParameters`, `NetworkRouterError`
- **WebSocket/** — `WebSocketRouter`, `WebSocketConnection`, `WebSocketMessage`
- **Encoding/** — `JSONEncoding`, `URLEncoding` (query string and form body)
- **HeaderHandler/** — `HeaderHandler` builder (bearer auth, content-type, accept, custom headers)
- **Error/** — `NetworkError` enum (`urlError`, `decodingError`, `customError`, `responseError`, `unknown`)
- **Reachability/** — `NetworkMonitor` (Combine + async stream), `VPNChecker`, `Connectivity`
- **UploadProgress/** — `UploadProgressDelegate` (URLSessionTaskDelegate for progress callbacks)
- **Log/** — `URLSessionLogger` with four log levels (`none`, `minimal`, `standard`, `verbose`)
- **Mime/** — `MimeTypeDetector` (auto-detects MIME from `Data` magic bytes)
- **Data/** — `Data+Extensions` (helpers like `appendString`)
- **Simorgh/** — entry-point file (documentation only, no code)

### Parameter encoding rules (in `NetworkRouter.asURLRequest()`)

- `GET` / `DELETE` / `HEAD`: `queryParams` → URL query string via `URLEncoding(destination: .queryString)`
- `POST` / `PUT` / `PATCH` with `Content-Type: application/x-www-form-urlencoded` header: `params` → body via `URLEncoding(destination: .httpBody)`
- All other mutations: `queryParams` → query string; `params` → JSON body via `JSONEncoding`

### WebSocket usage pattern

```swift
let connection = try client.webSocketConnection(MySocketRouter(), options: WebSocketOptions(pingInterval: 25))
connection.connect()
for try await event in connection.events() { ... }
// or typed:
for try await msg in connection.messages(of: MyModel.self) { ... }
```

`WebSocketOptions` accepts `pingInterval` (seconds, `nil` = no pings) and `reconnectPolicy` (`WebSocketReconnectPolicy(maximumAttempts:)`).

### Streaming vs WebSocket

HTTP streaming (`streamRequest` / `asyncStreamRequest`) is for long-lived server-push responses (newline-delimited JSON). WebSocket is full-duplex. They share no implementation path.
