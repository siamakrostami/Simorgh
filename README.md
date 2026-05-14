# SRNetworkManager

A comprehensive, thread-safe networking library for Swift applications with support for both Combine and async/await programming models.

## Features

- **Dual Programming Models** — Combine publishers and async/await
- **Thread Safety** — All operations use dedicated dispatch queues for synchronization
- **Configurable Retry Logic** — Pluggable `RetryHandler` protocol for custom retry strategies
- **Upload Support** — Single-file and multipart form data uploads with progress tracking
- **Streaming** — Combine and `AsyncThrowingStream` based streaming responses
- **Network Monitoring** — Real-time connectivity and VPN detection via `NetworkMonitor`
- **Cache Control** — `CacheStrategy` and `CacheConfiguration` for fine-grained cache management
- **Error Handling** — `NetworkError` with `LocalizedError` conformance and convenience properties
- **Logging** — Four log levels (`none`, `minimal`, `standard`, `verbose`)
- **Authentication** — `HeaderHandler` builder for authorization, content-type, and custom headers
- **MIME Detection** — Automatic MIME type detection from file data

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

## Streaming

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

## VPN Detection

```swift
let vpnChecker = VPNChecker()
if vpnChecker.isVPNActive() {
    print("VPN is active")
}
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


