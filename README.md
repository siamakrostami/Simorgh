# SRNetworkManager

A comprehensive, thread-safe networking library for Swift applications with support for both Combine and async/await programming models.

## Features

- **Dual Programming Models** — Combine publishers and async/await
- **Thread Safety** — All operations use dedicated dispatch queues for synchronization
- **Configurable Retry Logic** — Pluggable `RetryHandler` protocol for custom retry strategies
- **Upload Support** — Single-file and multipart form data uploads with progress tracking
- **Streaming** — Combine and `AsyncThrowingStream` based streaming responses
- **WebSocket / Realtime** — First-class WebSocket endpoint routing, async events, JSON messages, ping, close, and reconnect policy
- **Subscription Protocol** — Amplify-style `SubscriptionRouter` that handles subscribe/unsubscribe handshakes over WebSocket, with both async/await (`AsyncThrowingStream`) and Combine (`AnyPublisher`) interfaces
- **Network Monitoring** — Real-time connectivity and VPN detection via `NetworkMonitor`
- **Cache Control** — `CacheStrategy` and `CacheConfiguration` for fine-grained cache management
- **Error Handling** — `NetworkError` with `LocalizedError` conformance and convenience properties
- **Logging** — Four log levels (`none`, `minimal`, `standard`, `verbose`)
- **Authentication** — `HeaderHandler` builder for authorization, content-type, and custom headers
- **MIME Detection** — Automatic MIME type detection from file data
- **Download Manager** — Priority queue, true pause/resume, retry, speed/ETA, background sessions

## Requirements

- iOS 13.0+
- macOS 13.0+
- tvOS 13.0+
- watchOS 7.0+
- Swift 5.9+

## Installation

### Swift Package Manager

Add the following dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/aspect-build/SRGenericNetworkLayer.git", from: "1.0.0")
]
```

Or add it directly in Xcode:
1. File > Add Package Dependencies
2. Enter the repository URL
3. Select the version you want to use

## Quick Start

### Define an Endpoint

```swift
import SRNetworkManager

struct GetUsersEndpoint: NetworkRouter {
    var baseURLString: String { "https://api.example.com" }
    var path: String { "/users" }
    var method: RequestMethod? { .get }
}
```

### Combine

```swift
let client = APIClient()

client.request(GetUsersEndpoint())
    .sink(
        receiveCompletion: { completion in
            if case .failure(let error) = completion {
                print("Error: \(error.localizedDescription)")
            }
        },
        receiveValue: { (users: [User]) in
            print("Received \(users.count) users")
        }
    )
    .store(in: &cancellables)
```

### Async/Await

```swift
do {
    let users: [User] = try await client.request(GetUsersEndpoint())
    print("Received \(users.count) users")
} catch {
    print("Error: \(error.localizedDescription)")
}
```

## Core Components

### APIClient

```swift
let client = APIClient(
    configuration: .default,           // optional URLSessionConfiguration
    configurationDelegate: nil,        // optional URLSessionDelegate
    qos: .userInitiated,
    logLevel: .standard,
    defaultCacheStrategy: .useProtocolCachePolicy,
    decoder: JSONDecoder(),
    retryHandler: DefaultRetryHandler(numberOfRetries: 3)
)
```

### NetworkRouter

Define your API endpoints with type safety.

```swift
struct CreateUserEndpoint: NetworkRouter {
    struct Body: Codable {
        let name: String
        let email: String
    }

    var baseURLString: String { "https://api.example.com" }
    var path: String { "/users" }
    var method: RequestMethod? { .post }
    var params: Body? { body }

    private let body: Body
    init(name: String, email: String) {
        self.body = Body(name: name, email: email)
    }
}
```

### Network Monitoring

```swift
let monitor = NetworkMonitor()
monitor.startMonitoring()

// Combine
monitor.status
    .sink { connectivity in
        switch connectivity {
        case .disconnected:
            print("Offline")
        case .connected(let type):
            print("Connected via \(type)")
        }
    }
    .store(in: &cancellables)

// Async/Await
for await connectivity in monitor.statusStream {
    print(connectivity)
}
```

## Logging

Configure `APIClient` with a `LogLevel` to trace all requests, responses, WebSocket events, subscription messages, and stream chunks through a single consistent output format.

```swift
let client = APIClient(logLevel: .verbose)  // .none | .minimal | .standard | .verbose
```

### Log levels

| Level | What you see |
|---|---|
| `.none` | Nothing (default, use in production) |
| `.minimal` | URL + method / WebSocket URL only |
| `.standard` | + headers, status codes, WS connect/disconnect/reconnect, subscription SUBSCRIBE/UNSUBSCRIBE |
| `.verbose` | + request/response bodies, sent/received WebSocket frames, decoded stream chunks, subscription events |

### HTTP requests and responses

```
🚀🚀🚀 REQUEST 🚀🚀🚀
🔈 POST https://api.example.com/users
Headers:
💡 Content-Type: application/json
💡 Authorization: Bearer token123
🔼🔼🔼 END REQUEST 🔼🔼🔼

✅✅✅ SUCCESS RESPONSE ✅✅✅
🔈 https://api.example.com/users
🔈 Status code: 201
🔼🔼🔼 END RESPONSE 🔼🔼🔼
```

### WebSocket events

```
🚀🚀🚀 REQUEST 🚀🚀🚀          ← connect() called, handshake request logged
🔈 GET wss://stream.example.com/ws
🔼🔼🔼 END REQUEST 🔼🔼🔼

🔌🔌🔌 WEBSOCKET CONNECTED 🔌🔌🔌   ← server confirmed handshake (handleDidOpen)
🔈 wss://stream.example.com/ws
🔼🔼🔼 END 🔼🔼🔼

📤 WEBSOCKET SEND                   ← verbose only
🔈 wss://stream.example.com/ws
Body: {"action":"ping"}
🔼🔼🔼 END SEND 🔼🔼🔼

📥 WEBSOCKET RECEIVE                ← verbose only
🔈 wss://stream.example.com/ws
Body: {"action":"pong"}
🔼🔼🔼 END RECEIVE 🔼🔼🔼

🔄🔄🔄 WEBSOCKET RECONNECTING 🔄🔄🔄  ← on network failure
🔈 wss://stream.example.com/ws
💡 Attempt 1, delay: 1.0s
🔼🔼🔼 END 🔼🔼🔼

🔒🔒🔒 WEBSOCKET DISCONNECTED 🔒🔒🔒  ← server or client close
🔈 wss://stream.example.com/ws
💡 Close code: 1000
🔼🔼🔼 END 🔼🔼🔼
```

### Subscription lifecycle

```
📡📡📡 SUBSCRIPTION SUBSCRIBE 📡📡📡   ← sent automatically on connect
🔈 wss://stream.binance.com:9443/ws
Body: {"method":"SUBSCRIBE","params":["btcusdt@trade"],"id":1}
🔼🔼🔼 END 🔼🔼🔼

📡📡📡 SUBSCRIPTION EVENT 📡📡📡       ← verbose only, per decoded event
🔈 wss://stream.binance.com:9443/ws
Body: {"e":"trade","s":"BTCUSDT","p":"65432.10",...}
🔼🔼🔼 END 🔼🔼🔼

📡📡📡 SUBSCRIPTION UNSUBSCRIBE 📡📡📡  ← sent automatically on disconnect()
🔈 wss://stream.binance.com:9443/ws
Body: {"method":"UNSUBSCRIBE","params":["btcusdt@trade"],"id":1}
🔼🔼🔼 END 🔼🔼🔼
```

### HTTP streaming chunks

```
🌊 STREAM CHUNK                     ← verbose only, per decoded NDJSON line
🔈 https://api.example.com/stream
Body: {"token":"Hello","index":0}
🔼🔼🔼 END CHUNK 🔼🔼🔼
```

## Uploads

### Single-File Upload

Upload a single file with automatic MIME type detection and progress tracking.

```swift
// Combine
client.uploadRequest(endpoint, withName: "photo", data: imageData) { progress in
    print("Upload: \(Int(progress * 100))%")
}
.sink(
    receiveCompletion: { _ in },
    receiveValue: { (response: UploadResponse) in
        print("Done: \(response.url)")
    }
)
.store(in: &cancellables)

// Async/Await
let response: UploadResponse = try await client.uploadRequest(
    endpoint, withName: "photo", data: imageData
) { progress in
    print("Upload: \(Int(progress * 100))%")
}
```

### Multipart Form Data Upload

Use `MultipartFormField` to build requests with multiple text and file fields — similar to `curl --form`.

```swift
// Equivalent curl:
// curl -X POST https://api.example.com/upload \
//   --form 'file=@/path/to/file.zip' \
//   --form 'checksum=abc123' \
//   --form 'type=document' \
//   --form 'date=2025-01-01'

let fields: [MultipartFormField] = [
    .file(name: "file", data: fileData, fileName: "file.zip", mimeType: "application/zip"),
    .text(name: "checksum", value: "abc123"),
    .text(name: "type", value: "document"),
    .text(name: "date", value: "2025-01-01"),
]

// Combine
client.uploadRequest(endpoint, formFields: fields) { progress in
    print("Upload: \(Int(progress * 100))%")
}
.sink(
    receiveCompletion: { _ in },
    receiveValue: { (response: UploadResponse) in
        print("Done")
    }
)
.store(in: &cancellables)

// Async/Await
let response: UploadResponse = try await client.uploadRequest(
    endpoint, formFields: fields
) { progress in
    print("Upload: \(Int(progress * 100))%")
}
```

`MultipartFormField` supports two cases:
- `.text(name:value:)` — a plain text field
- `.file(name:data:fileName:mimeType:)` — a file field; `mimeType` is optional and auto-detected from data when `nil`

## Background Sessions

### Downloads — Full Background Support

`DownloadManager` supports true background downloads via `URLSessionConfiguration.background`. The system continues downloads even after the app is killed or suspended.

```swift
// 1. Create manager with background identifier
let manager = try DownloadManager(
    config: DownloadManagerConfig(
        maxConcurrentDownloads: 3,
        backgroundSessionIdentifier: "com.myapp.downloads"  // any unique string
    ),
    logLevel: .standard
)

// 2. Keep a reference at app scope (AppDelegate, @main struct, etc.)
// so the URLSession delegate is alive when background events arrive.
```

**AppDelegate wiring (UIKit):**

```swift
@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var downloadManager: DownloadManager!

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        downloadManager = try! DownloadManager(config: DownloadManagerConfig(
            backgroundSessionIdentifier: "com.myapp.downloads"
        ))
        return true
    }

    // Called by iOS when background download tasks complete while the app was suspended/killed.
    // You MUST call the completionHandler or the OS will terminate the app.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == "com.myapp.downloads" else { return }
        downloadManager.backgroundCompletionHandler = completionHandler
    }
}
```

**SwiftUI (`@main`) wiring:**

```swift
@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.downloadManager)
        }
    }
}
```

> **Important**: With a background session, only `URLSessionDownloadTask` is used — which is exactly what `DownloadManager` uses. All `pause`/`resume`/`cancel` operations work identically in background mode.

---

### Uploads — Foreground + Background

`APIClient` accepts a custom `URLSessionConfiguration`. For short uploads (< a few MB), the default foreground session is fine. For large files that must survive app suspension, use a background configuration with **file-based** upload tasks.

**Why file-based?** Background URL sessions require the upload body to be read from a file on disk, not from an in-memory `Data` object. The OS needs a file path it can re-read after a relaunch.

```swift
// Step 1 — write body to a temp file
func writeTempFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    return url
}

// Step 2 — create a background URLSession config
let bgConfig = URLSessionConfiguration.background(withIdentifier: "com.myapp.uploads")
bgConfig.isDiscretionary = false          // start immediately
bgConfig.sessionSendsLaunchEvents = true  // wake app on completion

// Step 3 — pass config to APIClient
let uploadClient = APIClient(configuration: bgConfig, logLevel: .standard)

// Step 4 — perform upload; progress is delivered via delegate callbacks
// The actual task uses uploadTask(withStreamedRequest:) internally, so
// pair this with a URLSessionTaskDelegate if you need progress in the background.
let response: UploadResponse = try await uploadClient.uploadRequest(
    endpoint,
    withName: "file",
    data: fileData
) { progress in
    print("Upload progress: \(Int(progress * 100))%")
}
```

> **Note**: `APIClient.uploadRequest` currently uses `uploadTask(with:from:)` (data-based). This works while the app is active or in the background (screen off), but will be suspended if the app is killed. For mission-critical uploads that must survive app termination, write the body to a temp file and use `URLSession.uploadTask(with:fromFile:)` directly with the background configuration above.

**AppDelegate wiring for background uploads (UIKit):**

```swift
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    // Store the completionHandler; call it after processing all events
    // Your URLSessionDelegate's urlSessionDidFinishEvents(forBackgroundURLSession:) fires last.
    backgroundUploadCompletionHandlers[identifier] = completionHandler
}
```

---

## Streaming

### HTTP Streaming vs WebSocket vs Subscription

Three distinct real-time mechanisms — pick by protocol requirements:

| | HTTP Streaming | WebSocket | Subscription |
|---|---|---|---|
| Protocol | HTTP/1.1 keep-alive | `ws://` / `wss://` TCP tunnel | `wss://` + JSON handshake |
| Direction | Server → client only | Full-duplex (send and receive) | Full-duplex with subscribe/unsubscribe lifecycle |
| Connection | Single long-lived HTTP response | HTTP upgrade → persistent TCP | HTTP upgrade → subscribe msg → events → unsubscribe msg |
| Server closes | When data ends | Any time | When you unsubscribe or session expires |
| Reconnect | New HTTP request | Automatic (configurable policy) | Automatic + re-sends subscribe message |
| Use case | NDJSON, LLM token streaming, SSE | Chat, multiplayer, raw data feeds | Trade feeds, AppSync/Hasura live queries, Amplify |
| API | `streamRequest` / `asyncStreamRequest` | `webSocketConnection` | `subscription` / `subscribe` |

#### Protocol flow comparison

```
HTTP Streaming
  Client ──GET /stream──────────────────────────────────────► Server
  Client ◄──chunk─────chunk─────chunk─────[connection close]── Server

WebSocket
  Client ──GET /ws (Upgrade: websocket)──────────────────────► Server
  Server ──101 Switching Protocols───────────────────────────► Client
  Client ◄──────────── msg ──────── msg ──────────────────────► (full-duplex)
  Client ──close────────────────────────────────────────────► Server

Subscription (Amplify-style)
  Client ──GET /ws (Upgrade: websocket)──────────────────────► Server
  Server ──101 Switching Protocols───────────────────────────► Client
  Client ──{"action":"subscribe","channel":"prices"}─────────► Server
  Client ◄──event──event──event──event───────────────────────  Server
  Client ──{"action":"unsubscribe","channel":"prices"}───────► Server
  Client ──close────────────────────────────────────────────► Server
```

Choose HTTP streaming when the server owns the entire feed and you only consume it. Choose WebSocket when you need bidirectional messaging. Choose Subscription when the server requires an explicit channel join/leave handshake — which is most real-time APIs in practice.

### AsyncThrowingStream — how it works

`AsyncThrowingStream<T, Error>` is Swift Concurrency's type for a sequence of values that arrive asynchronously over time and can fail. It is the async/await equivalent of `AnyPublisher<T, Error>`.

**Suspension, not polling.** The `for try await` loop suspends the current `Task` after each element. No CPU is consumed between values — the Swift runtime wakes the task only when the producer calls `continuation.yield(_:)`.

**Producer / consumer model.** The stream separates the code that _produces_ values (network layer) from the code that _consumes_ them (your UI or business logic):

```swift
// Producer side — inside the library
let stream = AsyncThrowingStream<DataChunk, Error> { continuation in
    let networkTask = Task {
        do {
            for await chunk in urlSession.bytes(...) {
                let decoded = try decode(chunk)
                continuation.yield(decoded)    // ← resumes the consumer
            }
            continuation.finish()              // ← loop exits cleanly
        } catch {
            continuation.finish(throwing: error) // ← loop exits with throw
        }
    }
    // Called when the consumer's Task is cancelled (e.g. view disappears)
    continuation.onTermination = { @Sendable _ in networkTask.cancel() }
}

// Consumer side — your code
for try await chunk in stream {
    render(chunk)                              // ← resumes here after each yield
}
// Reaches here when continuation.finish() is called
```

**Cancellation propagates automatically.** When you cancel the `Task` containing the `for try await` loop, Swift calls `onTermination`, which cancels the network task. No manual cleanup required.

**`AsyncStream` vs `AsyncThrowingStream`.** `AsyncStream<T>` is infallible — use it only when the source genuinely cannot fail. Network sources always use `AsyncThrowingStream` because they can fail with `URLError`, `DecodingError`, etc.

**Combine equivalent.** For codebases using Combine, `streamRequest` returns an `AnyPublisher<T, NetworkError>`. The two are semantically equivalent; pick the one that matches your existing stack.

### Combine

```swift
client.streamRequest(StreamingEndpoint())
    .sink(
        receiveCompletion: { _ in print("Stream ended") },
        receiveValue: { (chunk: DataChunk) in
            print("Chunk: \(chunk)")
        }
    )
    .store(in: &cancellables)
```

### Async/Await

```swift
for try await chunk: DataChunk in client.asyncStreamRequest(StreamingEndpoint()) {
    print("Chunk: \(chunk)")
}
```

## WebSocket / Realtime

### How it works

`WebSocketConnection` owns its own `URLSession` and registers itself as the `URLSessionWebSocketDelegate`. The `.connected` event fires only after the server confirms the HTTP upgrade handshake — not immediately after calling `connect()`. This means you will not receive `.connected` if the server rejects the handshake.

Each call to `events()` creates an independent `AsyncThrowingStream<WebSocketEvent, Error>`. Multiple subscribers can coexist and each receives every event. The stream finishes when the connection closes cleanly or exhausts its reconnect attempts (in which case it throws).

### Define an endpoint

```swift
struct ChatSocket: WebSocketRouter {
    struct Query: Codable {
        let room: String
    }

    var baseURLString: String { "wss://api.example.com" }
    var path: String { "/chat" }
    var queryParams: Query? { Query(room: "general") }
    var headers: [String: String]? {
        ["Authorization": "Bearer \(token)"]
    }
    var protocols: [String] { ["chat.v1"] }

    private let token: String
}
```

### Connect and handle events

```swift
let connection = try client.webSocketConnection(
    ChatSocket(token: token),
    options: WebSocketOptions(
        pingInterval: 25,
        reconnectPolicy: WebSocketReconnectPolicy(
            maximumAttempts: 3,
            initialDelay: 1,     // seconds before first retry
            multiplier: 2,       // each retry waits 2× longer
            maximumDelay: 30     // cap at 30 seconds
        )
    )
)

connection.connect()

Task {
    do {
        for try await event in connection.events() {
            switch event {
            case .connected:
                // Handshake confirmed by server — safe to send messages
                print("Connected")
            case .message(let message):
                let chat: ChatMessage = try message.decoded()
                print(chat)
            case .pong:
                print("Pong")
            case .reconnecting(let attempt, let delay):
                print("Reconnect \(attempt) in \(delay)s")
            case .disconnected(let code, _):
                print("Disconnected: \(code)")
            }
        }
    } catch {
        // Stream throws when reconnect attempts are exhausted
        print("Socket failed: \(error)")
    }
}
```

### Send messages

```swift
// Raw frames
try await connection.sendText("hello")
try await connection.sendData(binaryData)

// Encodable → JSON UTF-8 text frame (the standard for JSON over WebSocket)
try await connection.send(ChatMessage(text: "hello"))

// Ping/pong
try await connection.ping()

// Close
connection.close()
```

`send(_:encoder:)` encodes the value as JSON and sends it as a **UTF-8 text frame**, which is the WebSocket convention for JSON payloads.

### Typed message stream

`messages(of:)` is a convenience stream that filters out non-message events and decodes each payload directly:

```swift
for try await message in connection.messages(of: ChatMessage.self) {
    print(message)
}
```

### Synchronous state

In addition to the async event stream, the current state is readable synchronously:

```swift
switch connection.state {
case .idle:        break
case .connecting:  break
case .connected:   break
case .reconnecting(let attempt, let delay): break
case .disconnected: break
}
```

### Manual reconnect

```swift
connection.reconnect()  // cancels current task, resets retry counter, reconnects immediately
```

Calling `close()` while an auto-reconnect delay is pending cancels the pending reconnect — it will not override an explicit `close()`.

### Session isolation

Each `WebSocketConnection` creates and owns its own `URLSession`. Closing or deallocating a connection does not affect the `APIClient`'s HTTP session or any requests in flight.

## Subscription Protocol (Amplify-style)

`SubscriptionRouter` adds a protocol layer on top of `WebSocketRouter` for APIs that require a JSON subscribe/unsubscribe handshake over WebSocket — the pattern used by AWS AppSync, Hasura, Binance, and similar real-time services.

### Define a subscription

```swift
struct TradeSubscription: SubscriptionRouter {
    struct Message: Encodable, Sendable {
        let method: String
        let params: [String]
        let id: Int
    }
    typealias Event = TradeEvent

    var baseURLString: String { "wss://stream.example.com" }
    var path: String { "/ws" }

    let symbol: String

    var subscribeMessage: Message {
        Message(method: "SUBSCRIBE", params: ["\(symbol)@trade"], id: 1)
    }
    var unsubscribeMessage: Message? {
        Message(method: "UNSUBSCRIBE", params: ["\(symbol)@trade"], id: 1)
    }

    // Return nil to silently skip ack/keepalive frames
    func decodeEvent(from message: WebSocketMessage, using decoder: JSONDecoder) throws -> TradeEvent? {
        try? message.decoded(as: TradeEvent.self, decoder: decoder)
    }
}
```

The library handles the rest:
1. Connects the WebSocket.
2. Sends `subscribeMessage` when the handshake is confirmed (and after every auto-reconnect).
3. Decodes each incoming message via `decodeEvent` and forwards non-nil results to the caller.
4. Sends `unsubscribeMessage` when the subscription stops.

### Inline — Async/Await

```swift
for try await trade in apiClient.subscribe(
    TradeSubscription(symbol: "btcusdt"),
    options: WebSocketOptions(reconnectPolicy: WebSocketReconnectPolicy(maximumAttempts: 3))
) {
    print(trade)
}
// Cancelling the enclosing Task sends unsubscribeMessage and closes the connection.
```

### Inline — Combine

```swift
apiClient.subscribe(TradeSubscription(symbol: "btcusdt"))
    .receive(on: DispatchQueue.main)
    .sink(
        receiveCompletion: { print($0) },
        receiveValue:      { trade in print(trade) }
    )
    .store(in: &cancellables)
// Cancelling the AnyCancellable sends unsubscribeMessage and closes the connection.
```

### Explicit lifecycle — `SubscriptionConnection`

Use `subscription(_:options:)` when you need direct control over connect/disconnect timing:

```swift
// Create and wire up BEFORE connecting
let sub = try apiClient.subscription(TradeSubscription(symbol: "btcusdt"))

// Async/Await
Task {
    for try await trade in sub.events() { print(trade) }
}

// — OR — Combine
sub.publisher()
    .receive(on: DispatchQueue.main)
    .sink(receiveCompletion: { _ in }, receiveValue: { print($0) })
    .store(in: &cancellables)

// Connect AFTER the consumer is ready
sub.connect()

// Later:
await sub.disconnect()   // sends unsubscribeMessage then closes
sub.reconnect()          // resets counter, reconnects, re-sends subscribeMessage
print(sub.state)         // WebSocketConnectionState
```

### Overriding `decodeEvent`

| Return | Behaviour |
|---|---|
| `.some(event)` | Event is forwarded to the caller |
| `nil` | Message is silently dropped (useful for acks, keepalives) |
| `throw` | Error propagates to the stream / publisher |

The default implementation (when you don't override) decodes every message strictly — if a frame cannot be decoded it throws. Override with `try?` to make decoding lenient:

```swift
func decodeEvent(from message: WebSocketMessage, using decoder: JSONDecoder) throws -> MyEvent? {
    try? message.decoded(as: MyEvent.self, decoder: decoder)  // skip non-decodable frames
}
```

## Cache Control

### CacheStrategy

Set the default cache strategy when initializing the client:

```swift
let client = APIClient(defaultCacheStrategy: .returnCacheDataElseLoad)
```

Available strategies:
- `.useProtocolCachePolicy` (default)
- `.reloadIgnoringLocalCacheData`
- `.returnCacheDataElseLoad`
- `.returnCacheDataDontLoad`
- `.reloadRevalidatingCacheData`

Update at runtime:

```swift
client.updateDefaultCacheStrategy(.reloadIgnoringLocalCacheData)
```

### CacheConfiguration

Configure custom `URLCache` capacities:

```swift
let cacheConfig = CacheConfiguration(
    memoryCapacity: 20 * 1024 * 1024,   // 20 MB
    diskCapacity: 100 * 1024 * 1024,     // 100 MB
    diskPath: nil                         // system default
)
client.updateCacheConfiguration(cacheConfig)
```

## Retry Logic

### Default

```swift
let client = APIClient(retryHandler: DefaultRetryHandler(numberOfRetries: 3))
```

### Custom

```swift
struct CustomRetryHandler: RetryHandler {
    let numberOfRetries: Int

    func shouldRetry(request: URLRequest, error: NetworkError) -> Bool {
        switch error {
        case .urlError(let urlError):
            return urlError.code == .notConnectedToInternet ||
                   urlError.code == .timedOut
        case .customError(let statusCode, _):
            return statusCode >= 500
        default:
            return false
        }
    }

    func modifyRequestForRetry(client: APIClient, request: URLRequest, error: NetworkError) -> (URLRequest, NetworkError?) {
        var newRequest = request
        newRequest.setValue("retry", forHTTPHeaderField: "X-Retry-Attempt")
        return (newRequest, nil)
    }

    // Implement async variants as needed...
}
```

## Headers and Authentication

`HeaderHandler` uses a builder pattern. Each call to `build()` returns the accumulated headers and resets the builder.

```swift
let headers = HeaderHandler.shared
    .addAuthorizationHeader(type: .bearer(token: "your-token"))
    .addContentTypeHeader(type: .applicationJson)
    .addAcceptHeaders(type: .applicationJson)
    .addAcceptLanguageHeaders(type: .en)
    .addAcceptEncodingHeaders(type: .gzip)
    .addCustomHeader(name: "X-API-Key", value: "your-api-key")
    .build()

struct AuthenticatedEndpoint: NetworkRouter {
    var baseURLString: String { "https://api.example.com" }
    var path: String { "/protected" }
    var method: RequestMethod? { .get }
    var headers: [String: String]? { headers }
}
```

## Error Handling

`NetworkError` conforms to `LocalizedError`, so `error.localizedDescription` returns a meaningful message.

```swift
do {
    let data: MyModel = try await client.request(endpoint)
} catch let error as NetworkError {
    // Convenience properties
    print(error.localizedDescription)   // human-readable message
    print(error.statusCode)             // Int? — HTTP status for .customError
    print(error.responseData)           // Data? — response body for .customError

    // Exhaustive matching
    switch error {
    case .urlError(let urlError):
        if urlError.code == .notConnectedToInternet {
            showOfflineMessage()
        }
    case .decodingError(let decodingError):
        print("Decoding failed: \(decodingError)")
    case .customError(let statusCode, let data):
        if statusCode == 401 { handleUnauthorized() }
    case .responseError(let error):
        print("Response error: \(error)")
    case .unknown:
        print("Unknown error")
    }
}
```

## Session Management

Cancel all active requests and clear the retry queue:

```swift
client.cancelAllRequests()
```

Update the session configuration at runtime (invalidates existing sessions by default):

```swift
let newConfig = URLSessionConfiguration.default
newConfig.timeoutIntervalForRequest = 30
client.updateConfiguration(newConfig)
```

## Download Manager

A production-quality multi-task download manager built into the library. Designed to be the most complete iOS download manager available as a Swift package.

### Feature overview

| Feature | Details |
|---|---|
| True pause/resume | `URLSessionDownloadTask.cancel(byProducingResumeData:)` — continues from the exact byte |
| Priority queue | `critical > high > normal > low` — higher priority tasks start first |
| Concurrency cap | Configurable max simultaneous downloads (default 3); excess tasks queue automatically |
| Retry with backoff | Network-level errors (timeout, no connection) are retried with exponential backoff |
| Real-time speed | Sliding 3-second window → actual bytes/sec, not "bytes received this tick" |
| ETA | Calculated from remaining bytes ÷ current speed |
| Duplicate guard | Same URL cannot be enqueued twice while active |
| Background session | Pass `backgroundSessionIdentifier` to survive app suspension |
| Logging | All state transitions logged via `URLSessionLogger` |
| MIME detection | Auto-detected from file bytes; extension added if missing |
| Combine + async | Both APIs available; async stream requires iOS 15+ |

### Quick start

```swift
let manager = try DownloadManager(
    config: DownloadManagerConfig(
        maxConcurrentDownloads: 3,
        retryPolicy: DownloadRetryPolicy(maximumAttempts: 3),
        downloadDirectory: customURL  // defaults to Documents/Downloads
    ),
    logLevel: .standard
)
```

### Enqueue and observe (Combine)

```swift
let id = try manager.enqueue(
    url: URL(string: "https://example.com/video.mp4")!,
    fileName: "video.mp4",
    priority: .high
)

manager.progressPublisher(for: id)
    .receive(on: DispatchQueue.main)
    .sink { progress in
        print("\(Int(progress.fraction * 100))%  \(Int(progress.speed / 1024)) KB/s  ETA \(progress.eta ?? 0)s")
    }
    .store(in: &cancellables)

manager.statePublisher(for: id)
    .sink { state in
        if state == .completed { print("Done: \(manager.tasks.first { $0.id == id }?.localURL)") }
    }
    .store(in: &cancellables)
```

### Enqueue and observe (Async/Await — iOS 15+)

```swift
let stream = try manager.download(
    url: URL(string: "https://example.com/video.mp4")!,
    priority: .high
)

for await progress in stream {
    if progress.isCompleted {
        print("Saved to: \(progress.localURL!)")
        break
    }
    print("\(Int(progress.fraction * 100))%  ETA: \(progress.eta.map { "\(Int($0))s" } ?? "?")")
}
```

### Pause / Resume / Cancel

```swift
manager.pause(id: id)            // saves resume data — continues from same byte
try manager.resume(id: id)        // loads resume data, restarts task from offset
manager.cancel(id: id)            // cancels, deletes file and resume data
manager.removeCompleted()         // clean up finished tasks
```

### Observe all downloads

```swift
// Combine — full task list on every change
manager.tasksPublisher
    .receive(on: DispatchQueue.main)
    .sink { tasks in updateUI(tasks) }
    .store(in: &cancellables)

// Combine — granular events (progress, stateChange, error, added, removed)
manager.eventsPublisher
    .sink { event in
        switch event {
        case .progress(let p):         updateProgressBar(p)
        case .stateChange(let id, let state): print("\(id) → \(state)")
        case .error(let id, let msg):  showError(msg)
        default: break
        }
    }
    .store(in: &cancellables)
```

### Background downloads

```swift
// In your target's DownloadManagerConfig:
let manager = try DownloadManager(config: DownloadManagerConfig(
    backgroundSessionIdentifier: "com.myapp.downloads"
))

// In AppDelegate:
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    downloadManager.backgroundCompletionHandler = completionHandler
}
```

### Retry policy

```swift
DownloadRetryPolicy(
    maximumAttempts: 5,
    initialDelay: 2,      // seconds before first retry
    multiplier: 2,        // doubles each attempt: 2s, 4s, 8s, 16s, 30s (capped)
    maximumDelay: 30
)
```

Only network-level errors are retried (`URLError` codes: `notConnectedToInternet`, `networkConnectionLost`, `timedOut`, `cannotConnectToHost`, `cannotFindHost`, `dnsLookupFailed`). HTTP 4xx responses are not retried.

### DownloadProgress fields

```swift
struct DownloadProgress {
    let taskId: UUID
    let state: DownloadState         // .downloading, .completed, .paused, etc.
    let fraction: Double             // 0.0 – 1.0 (NaN if total size unknown)
    let downloadedBytes: Int64
    let totalBytes: Int64            // 0 if server didn't send Content-Length
    let speed: Double                // bytes/sec, 3-second sliding window
    let eta: TimeInterval?           // nil if total unknown or speed == 0
    let localURL: URL?               // non-nil only when state == .completed
}
```

### Logging output

```
⬇️⬇️⬇️ DOWNLOAD STARTED ⬇️⬇️⬇️
🔈 https://example.com/video.mp4
🔼🔼🔼 END 🔼🔼🔼

⬇️⬇️⬇️ DOWNLOAD PAUSED ⬇️⬇️⬇️
🔈 https://example.com/video.mp4
🔼🔼🔼 END 🔼🔼🔼

⬇️⬇️⬇️ DOWNLOAD RETRY ⬇️⬇️⬇️
🔈 https://example.com/video.mp4
💡 attempt 1, delay 1.0s
🔼🔼🔼 END 🔼🔼🔼

⬇️⬇️⬇️ DOWNLOAD COMPLETED ⬇️⬇️⬇️
🔈 https://example.com/video.mp4
💡 video.mp4
🔼🔼🔼 END 🔼🔼🔼
```

## VPN Detection

VPN detection uses two complementary methods, applied in order:

1. **`getifaddrs()`** — enumerates active network interfaces and checks for VPN-typical prefixes (`utun`, `tun`, `tap`, `ppp`, `ipsec`). Works with IKEv2, WireGuard, OpenVPN, IPsec, and any other protocol that creates a tunnel interface. This is the primary, reliable method.

2. **CFNetwork proxy settings** — fallback for HTTP/SOCKS proxy-based VPNs that don't create tunnel interfaces.

```swift
let vpnChecker = VPNChecker()
if vpnChecker.isVPNActive() {
    print("VPN is active")
}

// Disable checking (always returns false — useful in tests or specific environments)
let bypassChecker = VPNChecker(shouldBypassVpnCheck: true)
```

`NetworkMonitor` integrates VPN detection automatically:

```swift
let monitor = NetworkMonitor(shouldDetectVpnAutomatically: true)
monitor.startMonitoring()

monitor.status
    .sink { connectivity in
        if case .connected(.vpn) = connectivity {
            print("VPN detected")
        }
    }
    .store(in: &cancellables)
```

## Configuration

### Log Levels

```swift
let client = APIClient(logLevel: .verbose) // .none, .minimal, .standard, .verbose
```

### Production Setup

```swift
#if DEBUG
let logLevel: LogLevel = .verbose
let retryHandler = DefaultRetryHandler(numberOfRetries: 3)
#else
let logLevel: LogLevel = .none
let retryHandler = DefaultRetryHandler(numberOfRetries: 1)
#endif

let client = APIClient(
    logLevel: logLevel,
    retryHandler: retryHandler
)
```

## Thread Safety

All operations are thread-safe:

- **APIClient** — Dedicated `DispatchQueue` with barrier flags for read/write synchronization
- **NetworkMonitor** — Thread-safe status updates and async continuation management
- **HeaderHandler** — Synchronized header operations with automatic reset on `build()`
- **UploadProgressDelegate** — Thread-safe progress reporting

## API Reference

### Core Types

| Type | Description |
|------|-------------|
| `APIClient` | Main client for network requests |
| `NetworkRouter` | Protocol for defining API endpoints |
| `NetworkError` | Error enum with `LocalizedError` conformance |
| `MultipartFormField` | Enum for multipart form text and file fields |
| `RetryHandler` | Protocol for custom retry logic |
| `CacheStrategy` | Enum mapping to `URLRequest.CachePolicy` |
| `CacheConfiguration` | Struct for `URLCache` memory/disk capacities |
| `NetworkMonitor` | Real-time network connectivity monitoring |
| `VPNChecker` | VPN connection detection |
| `HeaderHandler` | Builder for HTTP headers |

### Request Methods

`GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `TRACE`

### Content Types

`applicationJson`, `urlEncoded`, `formData`

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

