# SRNetworkManager 1.1.0

## What's New

### WebSocket (complete rewrite)

The WebSocket layer has been rewritten from the ground up for correctness and reliability.

**Key fixes:**
- `.connected` now fires only after the server confirms the HTTP upgrade handshake (`URLSessionWebSocketDelegate.urlSession(_:webSocketTask:didOpenWithProtocol:)`), not optimistically on `connect()`
- Eliminated the URLSession retain cycle — a separate `_WebSocketDelegate` class holds a `weak` reference back to `WebSocketConnection`, allowing normal `deinit`
- Each `WebSocketConnection` owns its own `URLSession` (created from the same `URLSessionConfiguration` as `APIClient`). Closing a WebSocket no longer affects in-flight HTTP requests
- `close()` is now safe to call during a reconnect delay — the `manuallyClosed` flag prevents the reconnect timer from overriding an explicit close
- JSON payloads sent via `send<T: Encodable>` are now encoded as UTF-8 text frames (`.string`), not binary frames

**New APIs:**
- `WebSocketConnectionState` enum: `.idle`, `.connecting`, `.connected`, `.reconnecting(attempt:delay:)`, `.disconnected`
- `WebSocketConnection.state` property — readable at any time
- `WebSocketConnection.url` property
- `WebSocketConnection.reconnect()` — resets the retry counter and reconnects immediately
- `WebSocketOptions.reconnectPolicy` — exponential backoff with configurable `initialDelay`, `multiplier`, `maximumDelay`, `maximumAttempts`

---

### Subscription Protocol (new)

Amplify-style subscribe/unsubscribe lifecycle over WebSocket. No GraphQL required — works with any JSON-based real-time API (Binance, Hasura, custom backends).

**New protocol:**

```swift
protocol SubscriptionRouter: WebSocketRouter {
    associatedtype SubscribeMessage: Encodable & Sendable
    associatedtype Event: Decodable & Sendable
    var subscribeMessage: SubscribeMessage { get }
    var unsubscribeMessage: SubscribeMessage? { get }       // default: nil
    func decodeEvent(from: WebSocketMessage, using: JSONDecoder) throws -> Event?
}
```

The library handles the full lifecycle automatically:
1. Connects the WebSocket
2. Sends `subscribeMessage` on every (re)connect
3. Decodes frames via `decodeEvent` — `nil` return silently drops the frame (useful for acks)
4. Sends `unsubscribeMessage` when stopped

**Three consumer APIs — all with both async/await and Combine:**

```swift
// Explicit lifecycle
let sub = try apiClient.subscription(MyRouter())
sub.connect()
for try await event in sub.events() { ... }
await sub.disconnect()

// Inline async/await (fire-and-forget)
for try await event in apiClient.subscribe(MyRouter()) { ... }

// Inline Combine (fire-and-forget)
apiClient.subscribe(MyRouter())
    .sink(receiveCompletion: { _ in }, receiveValue: { print($0) })
    .store(in: &cancellables)
```

---

### Comprehensive Logging

All real-time layers now emit structured log output through `URLSessionLogger`, gated by the existing `LogLevel` on `APIClient`.

| Level | Coverage |
|---|---|
| `.minimal` | WebSocket URL on connect |
| `.standard` | + connect/disconnect/reconnect events, SUBSCRIBE/UNSUBSCRIBE messages |
| `.verbose` | + every sent/received WebSocket frame, every decoded stream chunk, every subscription event |

```
🔌🔌🔌 WEBSOCKET CONNECTED 🔌🔌🔌
🔈 wss://stream.example.com/ws
🔼🔼🔼 END 🔼🔼🔼

📡📡📡 SUBSCRIPTION SUBSCRIBE 📡📡📡
🔈 wss://stream.example.com/ws
Body: {"method":"SUBSCRIBE","params":["btcusdt@trade"],"id":1}
🔼🔼🔼 END 🔼🔼🔼

🔄🔄🔄 WEBSOCKET RECONNECTING 🔄🔄🔄
🔈 wss://stream.example.com/ws
💡 Attempt 1, delay: 1.0s
🔼🔼🔼 END 🔼🔼🔼
```

---

## Migration Guide

### WebSocket

No breaking API changes. If you were previously inspecting the `.connected` event timing, note that it now fires slightly later (after the actual server handshake) rather than immediately after `connect()`.

### Streaming

`streamRequest` and `asyncStreamRequest` are unchanged. Verbose logging now emits a `🌊 STREAM CHUNK` line per decoded NDJSON line — no action needed unless you want to filter it.

---

## Compatibility

- Swift 5 and Swift 6 (`swiftLanguageModes: [.v5, .v6]`)
- iOS 13+ · macOS 13+ · tvOS 13+ · watchOS 7+
