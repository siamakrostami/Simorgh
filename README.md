# SRNetworkManager

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![iOS 13+](https://img.shields.io/badge/iOS-13%2B-blue.svg)](https://developer.apple.com/ios/)
[![SPM Compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A production-grade Swift networking library. One package covers HTTP, WebSocket, downloads, streaming, and real-time network monitoring — with full Combine + async/await APIs and Swift 6 strict concurrency compliance.

---

## What's inside

| Module | Capability |
|---|---|
| `APIClient` | HTTP requests, uploads, multipart, retry, cache |
| `DownloadManager` | Priority queue, pause/resume, background sessions, speed/ETA |
| `WebSocketConnection` | Full-duplex WebSocket with auto-reconnect |
| `SubscriptionRouter` | Amplify/AppSync-style subscribe–unsubscribe handshake over WebSocket |
| `NetworkMonitor` | Real-time WiFi/Cellular/VPN detection via dual `NWPathMonitor` |
| `URLSessionLogger` | 4-level structured logging across all transports |

---

## Requirements

- iOS 13+ · macOS 13+ · tvOS 13+ · watchOS 7+
- Swift 5.9+ (Swift 6 also supported)
- Xcode 15+

---

## Installation

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/siamakrostami/SRGenericNetworkLayer.git", from: "1.0.0")
]
```

Or in Xcode: **File → Add Package Dependencies** → paste the URL above.

---

## Quick Start

### Define an endpoint

```swift
import SRNetworkManager

struct GetUsersEndpoint: NetworkRouter {
    var baseURLString: String { "https://api.example.com" }
    var path: String { "/users" }
    var method: RequestMethod? { .get }
}
```

### Fetch — async/await

```swift
let client = APIClient()
let users: [User] = try await client.request(GetUsersEndpoint())
```

### Fetch — Combine

```swift
client.request(GetUsersEndpoint())
    .sink(
        receiveCompletion: { print($0) },
        receiveValue: { (users: [User]) in print(users) }
    )
    .store(in: &cancellables)
```

---

## APIClient

```swift
let client = APIClient(
    configuration: .default,
    qos: .userInitiated,
    logLevel: .standard,
    defaultCacheStrategy: .useProtocolCachePolicy,
    decoder: JSONDecoder(),
    retryHandler: DefaultRetryHandler(numberOfRetries: 3)
)
```

### POST with body

```swift
struct CreateUserEndpoint: NetworkRouter {
    struct Body: Codable { let name: String; let email: String }
    var baseURLString: String { "https://api.example.com" }
    var path: String { "/users" }
    var method: RequestMethod? { .post }
    var params: Body? { body }
    private let body: Body
    init(name: String, email: String) { body = Body(name: name, email: email) }
}

let user: User = try await client.request(CreateUserEndpoint(name: "Alice", email: "alice@example.com"))
```

### Cancel all

```swift
client.cancelAllRequests()
```

---

## Uploads

### Single file

```swift
// Async/Await
let response: UploadResponse = try await client.uploadRequest(
    endpoint, withName: "photo", data: imageData
) { progress in print("\(Int(progress * 100))%") }

// Combine
client.uploadRequest(endpoint, withName: "photo", data: imageData) { print($0) }
    .sink(receiveCompletion: { _ in }, receiveValue: { print($0) })
    .store(in: &cancellables)
```

### Multipart form data

```swift
let fields: [MultipartFormField] = [
    .file(name: "file", data: fileData, fileName: "archive.zip", mimeType: "application/zip"),
    .text(name: "checksum", value: "abc123"),
    .text(name: "type", value: "document"),
]

let response: UploadResponse = try await client.uploadRequest(endpoint, formFields: fields) {
    print("\(Int($0 * 100))%")
}
```

---

## Download Manager

Production-quality download manager with true pause/resume, priority queuing, background sessions, and per-task speed/ETA.

### Feature overview

| Feature | Details |
|---|---|
| Pause / Resume | `URLSessionDownloadTask.cancel(byProducingResumeData:)` — exact byte offset |
| Priority queue | `critical > high > normal > low` |
| Concurrency cap | Configurable max (default 3); extras queue automatically |
| Retry | Exponential backoff on network errors; HTTP 4xx not retried |
| Speed | 3-second sliding window — actual B/s not per-tick delta |
| ETA | Remaining bytes ÷ current speed |
| Duplicate guard | Same URL blocked while active |
| Background | Pass `backgroundSessionIdentifier` to survive app suspension |
| MIME detection | Auto-detected from file bytes; extension appended if missing |

### Create

```swift
let manager = try DownloadManager(
    config: DownloadManagerConfig(
        maxConcurrentDownloads: 3,
        retryPolicy: DownloadRetryPolicy(maximumAttempts: 3),
        backgroundSessionIdentifier: "com.myapp.downloads"
    ),
    logLevel: .standard
)
```

### Enqueue — async/await (iOS 15+)

```swift
for await progress in try manager.download(url: url, priority: .high) {
    if progress.isCompleted {
        print("Saved: \(progress.localURL!)")
        break
    }
    print("\(Int(progress.fraction * 100))%  ETA \(progress.eta.map { "\(Int($0))s" } ?? "?")")
}
```

### Enqueue — Combine

```swift
let id = try manager.enqueue(url: url, fileName: "video.mp4", priority: .high)

manager.progressPublisher(for: id)
    .receive(on: DispatchQueue.main)
    .sink { p in print("\(Int(p.fraction * 100))%  \(Int(p.speed / 1024)) KB/s") }
    .store(in: &cancellables)
```

### Batch enqueue

```swift
manager.enqueueBatch(urls, priority: .normal)
```

### Controls

```swift
manager.pause(id: id)          // saves byte offset
try manager.resume(id: id)      // restores from offset
manager.cancel(id: id)          // removes file + resume data
manager.removeCompleted()
```

### Background session wiring

```swift
// AppDelegate
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    guard identifier == "com.myapp.downloads" else { return }
    downloadManager.backgroundCompletionHandler = completionHandler
}
```

---

## HTTP Streaming

Long-lived server-push responses (newline-delimited JSON, LLM token streams, SSE).

```swift
// Async/Await
for try await chunk: DataChunk in client.asyncStreamRequest(StreamEndpoint()) {
    render(chunk)
}

// Combine
client.streamRequest(StreamEndpoint())
    .sink(receiveCompletion: { _ in }, receiveValue: { (chunk: DataChunk) in render(chunk) })
    .store(in: &cancellables)
```

---

## WebSocket

Full-duplex WebSocket with typed messages, ping/pong, and automatic reconnect.

### Define endpoint

```swift
struct ChatSocket: WebSocketRouter {
    var baseURLString: String { "wss://api.example.com" }
    var path: String { "/chat" }
    var queryParams: [String: String]? { ["room": "general"] }
    var headers: [String: String]? { ["Authorization": "Bearer \(token)"] }
    private let token: String
}
```

### Connect and receive

```swift
let connection = try client.webSocketConnection(
    ChatSocket(token: token),
    options: WebSocketOptions(
        pingInterval: 25,
        reconnectPolicy: WebSocketReconnectPolicy(maximumAttempts: 3, initialDelay: 1, multiplier: 2, maximumDelay: 30)
    )
)

connection.connect()

Task {
    for try await event in connection.events() {
        switch event {
        case .connected:                           print("Connected")
        case .message(let msg):                    print(try msg.decoded() as ChatMessage)
        case .reconnecting(let attempt, let delay): print("Retry \(attempt) in \(delay)s")
        case .disconnected(let code, _):           print("Closed: \(code)")
        case .pong:                                break
        }
    }
}
```

### Send

```swift
try await connection.send(ChatMessage(text: "hello"))   // Encodable → JSON UTF-8 text frame
try await connection.sendText("raw text")
try await connection.ping()
connection.close()
```

### Typed stream

```swift
for try await message in connection.messages(of: ChatMessage.self) {
    print(message)
}
```

---

## Subscription Protocol (Amplify / AppSync style)

For APIs requiring a JSON subscribe/unsubscribe handshake over WebSocket (Binance, Hasura, AppSync, etc.).

### Define

```swift
struct TradeSubscription: SubscriptionRouter {
    typealias Event = TradeEvent
    var baseURLString: String { "wss://stream.example.com" }
    var path: String { "/ws" }
    let symbol: String

    var subscribeMessage: some Encodable {
        ["method": "SUBSCRIBE", "params": ["\(symbol)@trade"], "id": 1]
    }
    var unsubscribeMessage: (some Encodable)? {
        ["method": "UNSUBSCRIBE", "params": ["\(symbol)@trade"], "id": 1]
    }

    func decodeEvent(from message: WebSocketMessage, using decoder: JSONDecoder) throws -> TradeEvent? {
        try? message.decoded(as: TradeEvent.self, decoder: decoder)
    }
}
```

The library handles: connect → send `subscribeMessage` → decode events → send `unsubscribeMessage` on stop → auto-reconnect with re-subscribe.

### Async/Await

```swift
for try await trade in apiClient.subscribe(TradeSubscription(symbol: "btcusdt")) {
    print(trade)
}
// Cancelling the Task sends unsubscribeMessage and closes cleanly.
```

### Combine

```swift
apiClient.subscribe(TradeSubscription(symbol: "btcusdt"))
    .receive(on: DispatchQueue.main)
    .sink(receiveCompletion: { _ in }, receiveValue: { print($0) })
    .store(in: &cancellables)
```

### Explicit lifecycle

```swift
let sub = try apiClient.subscription(TradeSubscription(symbol: "btcusdt"))
sub.connect()
for try await trade in sub.events() { print(trade) }
await sub.disconnect()
```

---

## Network Monitoring

Real-time detection of WiFi, Cellular, Ethernet, and VPN state changes.

```swift
let monitor = NetworkMonitor(shouldDetectVpnAutomatically: true)
monitor.startMonitoring()

// Combine
monitor.status
    .receive(on: DispatchQueue.main)
    .sink { connectivity in
        switch connectivity {
        case .disconnected:          showOfflineBanner()
        case .connected(.wifi):      print("WiFi")
        case .connected(.cellular):  print("Cellular")
        case .connected(.vpn):       print("VPN active")
        case .connected(.ethernet):  print("Ethernet")
        case .connected(.other):     print("Other")
        }
    }
    .store(in: &cancellables)

// Async/Await
Task {
    for await connectivity in monitor.statusStream() {
        await handleChange(connectivity)
    }
}
```

### VPN live detection

VPN state is detected immediately when VPN connects or disconnects — even when the underlying WiFi path stays active.

Two `NWPathMonitor` instances run in parallel:

1. **General monitor** — fires on WiFi ↔ Cellular, connected ↔ disconnected
2. **Tunnel monitor** (`requiredInterfaceType: .other`) — fires specifically when tunnel interfaces (`utun`, `tun`, `ppp`, `ipsec`) appear or disappear

Both feed a single `evaluate()` function that reads `path.availableInterfaces` directly, eliminating the `getifaddrs()` race window.

### One-shot VPN check

```swift
let checker = VPNChecker()
if checker.isVPNActive() {
    // IKEv2, WireGuard, OpenVPN, IPsec — all detected
}
```

---

## Streaming vs WebSocket vs Subscription

| | HTTP Streaming | WebSocket | Subscription |
|---|---|---|---|
| Protocol | HTTP keep-alive | ws:// / wss:// | wss:// + JSON handshake |
| Direction | Server → client | Full-duplex | Full-duplex + channel lifecycle |
| Reconnect | New HTTP request | Auto (configurable) | Auto + re-sends subscribe |
| Use case | NDJSON, LLM tokens, SSE | Chat, multiplayer, data feeds | Binance, AppSync, Hasura, Amplify |
| API | `streamRequest` / `asyncStreamRequest` | `webSocketConnection` | `subscription` / `subscribe` |

---

## Logging

```swift
let client = APIClient(logLevel: .verbose)
// .none | .minimal | .standard | .verbose
```

| Level | Output |
|---|---|
| `.none` | Silent (production default) |
| `.minimal` | URL + method |
| `.standard` | + headers, status codes, WS connect/disconnect/reconnect |
| `.verbose` | + request/response bodies, WS frames, stream chunks, subscription events |

---

## Headers and Auth

```swift
let headers = HeaderHandler.shared
    .addAuthorizationHeader(type: .bearer(token: "your-token"))
    .addContentTypeHeader(type: .applicationJson)
    .addAcceptHeaders(type: .applicationJson)
    .addCustomHeader(name: "X-API-Key", value: "your-api-key")
    .build()
```

---

## Error Handling

```swift
do {
    let data: MyModel = try await client.request(endpoint)
} catch let error as NetworkError {
    switch error {
    case .urlError(let e) where e.code == .notConnectedToInternet:
        showOfflineMessage()
    case .customError(let statusCode, _) where statusCode == 401:
        handleUnauthorized()
    case .decodingError(let e):
        print(e)
    default:
        print(error.localizedDescription)
    }
}
```

---

## Retry Logic

```swift
// Built-in
APIClient(retryHandler: DefaultRetryHandler(numberOfRetries: 3))

// Custom
struct CustomRetryHandler: RetryHandler {
    func shouldRetry(request: URLRequest, error: NetworkError) -> Bool {
        if case .customError(let code, _) = error { return code >= 500 }
        return false
    }
    func modifyRequestForRetry(client: APIClient, request: URLRequest, error: NetworkError) -> (URLRequest, NetworkError?) {
        (request, nil)
    }
}
```

---

## Cache Control

```swift
let client = APIClient(defaultCacheStrategy: .returnCacheDataElseLoad)

// Runtime update
client.updateDefaultCacheStrategy(.reloadIgnoringLocalCacheData)

// Custom URLCache
client.updateCacheConfiguration(CacheConfiguration(
    memoryCapacity: 20 * 1024 * 1024,
    diskCapacity: 100 * 1024 * 1024
))
```

---

## Background Sessions

### Downloads

```swift
let manager = try DownloadManager(config: DownloadManagerConfig(
    backgroundSessionIdentifier: "com.myapp.downloads"
))

// AppDelegate
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    guard identifier == "com.myapp.downloads" else { return }
    downloadManager.backgroundCompletionHandler = completionHandler
}
```

### Uploads (large files)

Background URL sessions require file-based upload tasks. Write the body to disk first:

```swift
let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try data.write(to: tempURL)

let bgConfig = URLSessionConfiguration.background(withIdentifier: "com.myapp.uploads")
bgConfig.isDiscretionary = false
bgConfig.sessionSendsLaunchEvents = true

let uploadClient = APIClient(configuration: bgConfig)
```

> `APIClient.uploadRequest` uses data-based tasks (works while app is active/backgrounded). For uploads that must survive app termination, use `URLSession.uploadTask(with:fromFile:)` directly with the config above.

---

## Thread Safety

| Component | Mechanism |
|---|---|
| `APIClient` | `DispatchQueue` with `.barrier` writes, `@unchecked Sendable` |
| `DownloadManager` | `NSLock` protecting all mutable state |
| `NetworkMonitor` | `NSLock` + dedicated monitor queue |
| `HeaderHandler` | Synchronized builder, resets on `build()` |

Swift 6 strict concurrency is fully supported (`SPM_SWIFT_6` define active). All public API is `Sendable`-safe.

---

## API Reference

| Type | Role |
|---|---|
| `APIClient` | HTTP requests, uploads, streaming |
| `NetworkRouter` | Endpoint definition protocol |
| `WebSocketRouter` | WebSocket endpoint protocol |
| `SubscriptionRouter` | Subscribe/unsubscribe lifecycle protocol |
| `WebSocketConnection` | Live duplex connection handle |
| `DownloadManager` | Multi-task download engine |
| `DownloadTask` | Task state, metadata, progress |
| `NetworkMonitor` | Connectivity + VPN observer |
| `VPNChecker` | One-shot VPN detection |
| `NetworkError` | Typed error enum with `LocalizedError` |
| `MultipartFormField` | `.file` / `.text` multipart fields |
| `HeaderHandler` | Builder for HTTP request headers |
| `CacheStrategy` | Maps to `URLRequest.CachePolicy` |
| `URLSessionLogger` | Structured request/response logging |

### HTTP methods

`GET` · `POST` · `PUT` · `PATCH` · `DELETE` · `HEAD` · `TRACE`

---

## License

MIT — see [LICENSE](LICENSE).
