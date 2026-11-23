import Combine
import XCTest
@testable import Simorgh

// MARK: - Stub protocol

/// Serves canned responses per request. The handler decides status and body; an
/// optional delay lets tests cancel a request while it is in flight.
final class StubHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: Data = Data()
        var delay: TimeInterval = 0
    }

    typealias Handler = @Sendable (_ request: URLRequest, _ callIndexForPath: Int) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler = { _, _ in Reply() }
    nonisolated(unsafe) private static var callsByPath: [String: Int] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        callsByPath = [:]
        recorded = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        let index = Self.callsByPath[path, default: 0]
        Self.callsByPath[path] = index + 1
        Self.recorded.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        let reply = handler(request, index)
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stopped = self.stopped
            self.stateLock.unlock()
            guard !stopped, let url = self.request.url else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}

// MARK: - Fixtures

private struct Echo: Codable, Sendable, Equatable {
    let path: String
}

private struct Endpoint: NetworkRouter {
    var path: String
    var method: RequestMethod? = .get
    var baseURLString: String { "https://stub.simorgh.test" }
}

private struct BrokenEndpoint: NetworkRouter {
    func asURLRequest() throws -> URLRequest {
        throw NetworkRouterError.invalidURL
    }
}

private func echoBody(_ request: URLRequest) -> Data {
    try! JSONEncoder().encode(Echo(path: request.url?.path ?? ""))
}

private func makeClient(retries: Int = 0, methods: Set<String> = DefaultRetryHandler.idempotentMethods) -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubHTTPProtocol.self]
    return APIClient(
        configuration: configuration,
        retryHandler: DefaultRetryHandler(
            numberOfRetries: retries, retryableMethods: methods, baseDelay: 0))
}

// MARK: - Tests

final class APIClientTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: Session reuse

    func testRequestsShareOneSession() async throws {
        StubHTTPProtocol.reset { request, _ in .init(body: echoBody(request)) }
        let client = makeClient()

        for index in 0..<25 {
            let echo: Echo = try await client.request(Endpoint(path: "/item/\(index)"))
            XCTAssertEqual(echo.path, "/item/\(index)")
        }
        XCTAssertEqual(client.activeSessionCount, 1)
    }

    func testCombineRequestsShareOneSession() {
        StubHTTPProtocol.reset { request, _ in .init(body: echoBody(request)) }
        let client = makeClient()
        let done = expectation(description: "all finished")
        done.expectedFulfillmentCount = 10

        for index in 0..<10 {
            let publisher: AnyPublisher<Echo, NetworkError> = client.request(Endpoint(path: "/c/\(index)"))
            publisher.sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion { XCTFail("\(error)") }
                    done.fulfill()
                },
                receiveValue: { XCTAssertEqual($0.path, "/c/\(index)") }
            ).store(in: &cancellables)
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(client.activeSessionCount, 1)
    }

    func testUploadSessionsAreReleased() async throws {
        StubHTTPProtocol.reset { request, _ in .init(body: echoBody(request)) }
        let client = makeClient()

        for index in 0..<5 {
            let echo: Echo = try await client.uploadRequest(
                Endpoint(path: "/upload/\(index)", method: .post),
                withName: "file", data: Data("hello".utf8),
                progressCompletion: { _, _, _ in })
            XCTAssertEqual(echo.path, "/upload/\(index)")
        }
        XCTAssertEqual(client.activeSessionCount, 0, "per-upload sessions must be invalidated when done")
    }

    func testCancelAllRequestsClearsSessions() async throws {
        StubHTTPProtocol.reset { request, _ in .init(body: echoBody(request)) }
        let client = makeClient()
        let _: Echo = try await client.request(Endpoint(path: "/x"))
        XCTAssertEqual(client.activeSessionCount, 1)

        client.cancelAllRequests()
        XCTAssertEqual(client.activeSessionCount, 0)

        // The client still works afterwards with a fresh session.
        let echo: Echo = try await client.request(Endpoint(path: "/y"))
        XCTAssertEqual(echo.path, "/y")
        XCTAssertEqual(client.activeSessionCount, 1)
    }

    // MARK: Retry

    func testConcurrentRetriesEachRetryTheirOwnRequest() async throws {
        // Every path fails once with 503, then succeeds.
        StubHTTPProtocol.reset { request, call in
            call == 0 ? .init(status: 503) : .init(body: echoBody(request))
        }
        let client = makeClient(retries: 1)

        let paths = (0..<20).map { "/concurrent/\($0)" }
        let results = try await withThrowingTaskGroup(of: (String, Echo).self) { group in
            for path in paths {
                group.addTask {
                    let echo: Echo = try await client.request(Endpoint(path: path))
                    return (path, echo)
                }
            }
            var collected: [(String, Echo)] = []
            for try await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.count, paths.count)
        for (path, echo) in results {
            XCTAssertEqual(echo.path, path, "a retry must reuse its own request, not another one's")
        }
        XCTAssertEqual(StubHTTPProtocol.requests.count, paths.count * 2)
    }

    func testCombineRetrySucceeds() {
        StubHTTPProtocol.reset { request, call in
            call < 2 ? .init(status: 500) : .init(body: echoBody(request))
        }
        let client = makeClient(retries: 2)
        let done = expectation(description: "finished")

        let publisher: AnyPublisher<Echo, NetworkError> = client.request(Endpoint(path: "/combine-retry"))
        publisher.sink(
            receiveCompletion: { completion in
                if case .failure(let error) = completion { XCTFail("\(error)") }
                done.fulfill()
            },
            receiveValue: { XCTAssertEqual($0.path, "/combine-retry") }
        ).store(in: &cancellables)

        wait(for: [done], timeout: 10)
        XCTAssertEqual(StubHTTPProtocol.requests.count, 3)
    }

    func testRetriesStopAfterLimit() async {
        StubHTTPProtocol.reset { _, _ in .init(status: 503) }
        let client = makeClient(retries: 2)

        do {
            let _: Echo = try await client.request(Endpoint(path: "/always-503"))
            XCTFail("expected failure")
        } catch let error as NetworkError {
            XCTAssertEqual(error.statusCode, 503)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(StubHTTPProtocol.requests.count, 3, "1 attempt + 2 retries")
    }

    func testPostIsNotRetriedByDefault() async {
        StubHTTPProtocol.reset { _, _ in .init(status: 503) }
        let client = makeClient(retries: 3)

        do {
            let _: Echo = try await client.request(Endpoint(path: "/post", method: .post))
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(StubHTTPProtocol.requests.count, 1)
    }

    func testClientErrorsAreNotRetried() async {
        StubHTTPProtocol.reset { _, _ in .init(status: 404) }
        let client = makeClient(retries: 3)

        do {
            let _: Echo = try await client.request(Endpoint(path: "/missing"))
            XCTFail("expected failure")
        } catch let error as NetworkError {
            XCTAssertEqual(error.statusCode, 404)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(StubHTTPProtocol.requests.count, 1)
    }

    func testUploadRetryResendsTheBody() async throws {
        StubHTTPProtocol.reset { request, call in
            call == 0 ? .init(status: 503) : .init(body: echoBody(request))
        }
        let client = makeClient(retries: 1, methods: ["POST"])

        let echo: Echo = try await client.uploadRequest(
            Endpoint(path: "/upload-retry", method: .post),
            formFields: [.text(name: "a", value: "b")],
            progressCompletion: { _, _, _ in })

        XCTAssertEqual(echo.path, "/upload-retry")
        let requests = StubHTTPProtocol.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(
                request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true,
                "every attempt must be a real multipart upload")
        }
        XCTAssertEqual(client.activeSessionCount, 0)
    }

    func testCombineUploadRetries() {
        StubHTTPProtocol.reset { request, call in
            call == 0 ? .init(status: 502) : .init(body: echoBody(request))
        }
        let client = makeClient(retries: 1, methods: ["POST"])
        let done = expectation(description: "finished")

        let publisher: AnyPublisher<Echo, NetworkError> = client.uploadRequest(
            Endpoint(path: "/combine-upload", method: .post),
            withName: "file", data: Data("x".utf8), progressCompletion: { _, _, _ in })
        publisher.sink(
            receiveCompletion: { completion in
                if case .failure(let error) = completion { XCTFail("\(error)") }
                done.fulfill()
            },
            receiveValue: { XCTAssertEqual($0.path, "/combine-upload") }
        ).store(in: &cancellables)

        wait(for: [done], timeout: 10)
        XCTAssertEqual(StubHTTPProtocol.requests.count, 2)
    }

    // MARK: Cancellation

    func testCancellingTaskCancelsRequest() async {
        StubHTTPProtocol.reset { request, _ in .init(body: echoBody(request), delay: 10) }
        let client = makeClient(retries: 3)

        let start = Date()
        let task = Task { () -> Echo in
            try await client.request(Endpoint(path: "/slow"))
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as NetworkError {
            XCTAssertTrue(error.isCancellation, "got \(error)")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "cancellation must not wait for the response")
        XCTAssertEqual(StubHTTPProtocol.requests.count, 1, "a cancelled request must not be retried")
    }

    // MARK: Errors

    func testInvalidRequestIsSurfaced() async {
        let client = makeClient()
        do {
            let _: Echo = try await client.request(BrokenEndpoint())
            XCTFail("expected failure")
        } catch let NetworkError.invalidRequest(underlying) {
            XCTAssertEqual(underlying as? NetworkRouterError, .invalidURL)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCombineInvalidRequestIsSurfaced() {
        let client = makeClient()
        let done = expectation(description: "failed")
        let publisher: AnyPublisher<Echo, NetworkError> = client.request(BrokenEndpoint())
        publisher.sink(
            receiveCompletion: { completion in
                if case .failure(.invalidRequest) = completion {} else { XCTFail("got \(completion)") }
                done.fulfill()
            },
            receiveValue: { _ in XCTFail("no value expected") }
        ).store(in: &cancellables)
        wait(for: [done], timeout: 5)
    }

    func testDecodingErrorIsMapped() async {
        StubHTTPProtocol.reset { _, _ in .init(body: Data("not json".utf8)) }
        let client = makeClient(retries: 2)
        do {
            let _: Echo = try await client.request(Endpoint(path: "/bad-json"))
            XCTFail("expected failure")
        } catch NetworkError.decodingError {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(StubHTTPProtocol.requests.count, 1, "decoding errors are not retried")
    }
}

// MARK: - DefaultRetryHandler

final class DefaultRetryHandlerTests: XCTestCase {
    private func request(_ method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.httpMethod = method
        return request
    }

    func testRetriesTransientErrorsOnIdempotentMethods() {
        let handler = DefaultRetryHandler(numberOfRetries: 1)
        XCTAssertTrue(handler.shouldRetry(request: request("GET"), error: .urlError(URLError(.timedOut))))
        XCTAssertTrue(handler.shouldRetry(request: request("PUT"), error: .customError(503, Data())))
        XCTAssertTrue(handler.shouldRetry(request: request("get"), error: .customError(429, Data())))
    }

    func testDoesNotRetryUnsafeOrPermanentFailures() {
        let handler = DefaultRetryHandler(numberOfRetries: 1)
        XCTAssertFalse(handler.shouldRetry(request: request("POST"), error: .customError(503, Data())))
        XCTAssertFalse(handler.shouldRetry(request: request("GET"), error: .customError(400, Data())))
        XCTAssertFalse(handler.shouldRetry(request: request("GET"), error: .urlError(URLError(.cancelled))))
        XCTAssertFalse(handler.shouldRetry(request: request("GET"), error: .urlError(URLError(.badURL))))
        XCTAssertFalse(handler.shouldRetry(request: request("GET"), error: .unknown))
    }

    func testZeroRetriesNeverRetries() {
        let handler = DefaultRetryHandler(numberOfRetries: 0)
        XCTAssertFalse(handler.shouldRetry(request: request("GET"), error: .customError(503, Data())))
    }

    func testExponentialBackoffWithCap() {
        let handler = DefaultRetryHandler(numberOfRetries: 5, baseDelay: 1, maximumDelay: 5, jitter: false)
        let failed = request("GET")
        let error = NetworkError.customError(503, Data())
        XCTAssertEqual(handler.retryDelay(for: failed, error: error, attempt: 1), 1)
        XCTAssertEqual(handler.retryDelay(for: failed, error: error, attempt: 2), 2)
        XCTAssertEqual(handler.retryDelay(for: failed, error: error, attempt: 3), 4)
        XCTAssertEqual(handler.retryDelay(for: failed, error: error, attempt: 4), 5)
    }

    func testJitterStaysWithinBounds() {
        let handler = DefaultRetryHandler(numberOfRetries: 5, baseDelay: 2, jitter: true)
        for _ in 0..<100 {
            let delay = handler.retryDelay(for: request("GET"), error: .unknown, attempt: 2)
            XCTAssertGreaterThanOrEqual(delay, 2)
            XCTAssertLessThanOrEqual(delay, 4)
        }
    }

    func testProtocolDefaultsForCustomHandlers() async throws {
        struct Minimal: RetryHandler {
            let numberOfRetries = 1
            func shouldRetry(request: URLRequest, error: NetworkError) -> Bool { true }
            func modifyRequestForRetry(client: APIClient, request: URLRequest, error: NetworkError) -> (URLRequest, NetworkError?) {
                (request, .unknown)
            }
        }
        let handler = Minimal()
        let shouldRetry = await handler.shouldRetryAsync(request: request("GET"), error: .unknown)
        XCTAssertTrue(shouldRetry)
        XCTAssertEqual(handler.retryDelay(for: request("GET"), error: .unknown, attempt: 1), 0)
        do {
            _ = try await handler.modifyRequestForRetryAsync(client: APIClient(), request: request("GET"), error: .unknown)
            XCTFail("expected the blocking error to be thrown")
        } catch {}
    }
}
