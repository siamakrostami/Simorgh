import XCTest
@testable import Simorgh

// MARK: - Stub protocol

final class StubUploadProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        let contentType: String?
        let body: Data
        let method: String?
        let url: URL?
    }

    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var captured: [Captured] = []
    private static let lock = NSLock()

    static func reset(status: Int = 200, body: Data = Data()) {
        lock.lock()
        self.status = status
        responseBody = body
        captured = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 65_536)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
        } else if let data = request.httpBody {
            body = data
        }
        Self.lock.lock()
        Self.captured.append(
            Captured(
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: body,
                method: request.httpMethod,
                url: request.url
            )
        )
        let status = Self.status
        let responseBody = Self.responseBody
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !responseBody.isEmpty {
            client?.urlProtocol(self, didLoad: responseBody)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class UploadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simorgh-upload-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StubUploadProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeManager() -> UploadManager {
        UploadManager(config: UploadManagerConfig(
            storageDirectory: directory.appendingPathComponent("store", isDirectory: true),
            foregroundProtocolClasses: [StubUploadProtocol.self]
        ))
    }

    private func makeRequest(file: URL, id: String = UUID().uuidString) -> UploadRequest {
        var url = URLRequest(url: URL(string: "https://upload.test/api/files")!)
        url.httpMethod = "POST"
        url.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        return UploadRequest(
            id: id,
            urlRequest: url,
            textParts: [UploadTextPart(name: "checksum", value: "abc123")],
            fileParts: [UploadFilePart(name: "file", fileURL: file, fileName: "day.zip", mimeType: "application/zip")],
            metadata: ["date": "2026-10-12"]
        )
    }

    // MARK: Multipart writer

    func testWriterStreamsTextAndFileParts() throws {
        let file = try makeFile("payload.bin", contents: "FILE-CONTENT")
        let destination = directory.appendingPathComponent("body.multipart")
        let boundary = try MultipartFileBodyWriter.write(
            textParts: [UploadTextPart(name: "type", value: "SENSOR_DATA")],
            fileParts: [UploadFilePart(name: "file", fileURL: file, fileName: "a.zip", mimeType: "application/zip")],
            to: destination
        )
        let body = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(boundary.hasPrefix("Boundary-"))
        XCTAssertTrue(body.contains("name=\"type\"\r\n\r\nSENSOR_DATA\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"a.zip\""))
        XCTAssertTrue(body.contains("Content-Type: application/zip\r\n\r\nFILE-CONTENT\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
    }

    func testWriterReplacesAnExistingBodyFile() throws {
        let destination = directory.appendingPathComponent("body.multipart")
        try Data("old".utf8).write(to: destination)
        try MultipartFileBodyWriter.write(textParts: [], fileParts: [], to: destination)
        let body = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(body.contains("old"))
    }

    // MARK: Completion rules

    func testCompletionRules() {
        let body = Data("{}".utf8)
        XCTAssertEqual(
            UploadCompletion.evaluate(transportError: false, httpStatusCode: 200, responseBody: body, bytesSent: 10, bytesExpected: 10),
            .success(responseBody: body)
        )
        XCTAssertEqual(
            UploadCompletion.evaluate(transportError: true, transportDescription: "timed out", httpStatusCode: nil, responseBody: nil, bytesSent: 0, bytesExpected: 10),
            .failure(.transport("timed out"))
        )
        XCTAssertEqual(
            UploadCompletion.evaluate(transportError: false, httpStatusCode: 200, responseBody: body, bytesSent: 4, bytesExpected: 10),
            .failure(.incompleteSend(sent: 4, expected: 10))
        )
        XCTAssertEqual(
            UploadCompletion.evaluate(transportError: false, httpStatusCode: 500, responseBody: body, bytesSent: 10, bytesExpected: 10),
            .failure(.httpStatus(500))
        )
        XCTAssertEqual(
            UploadCompletion.evaluate(transportError: false, httpStatusCode: 200, responseBody: Data(), bytesSent: 10, bytesExpected: 10),
            .failure(.missingResponse)
        )
        XCTAssertEqual(
            UploadCompletion.evaluate(transportError: false, httpStatusCode: nil, responseBody: body, bytesSent: 10, bytesExpected: 10),
            .failure(.missingResponse)
        )
    }

    // MARK: Stores

    func testFileJobStoreRoundTrip() {
        let store = FileUploadJobStore(directory: directory)
        store.upsert(UploadJob(id: "a", metadata: ["k": "v"], bodyFileName: "a.multipart"))
        store.upsert(UploadJob(id: "b", metadata: [:], bodyFileName: nil))
        store.upsert(UploadJob(id: "a", metadata: ["k": "v2"], bodyFileName: "a.multipart"))
        XCTAssertEqual(Set(store.loadJobs().map(\.id)), ["a", "b"])
        XCTAssertEqual(store.loadJobs().first { $0.id == "a" }?.metadata["k"], "v2")
        store.remove(id: "a")
        XCTAssertEqual(store.loadJobs().map(\.id), ["b"])
    }

    func testFileResultStoreKeepsFailuresAndBodies() {
        let store = FileUploadResultStore(directory: directory)
        let result = PersistedUploadResult(
            id: "x", metadata: ["date": "d"], statusCode: 500, responseBody: Data("boom".utf8),
            bytesSent: 5, bytesExpected: 9, failure: .httpStatus(500)
        )
        store.save(result)
        XCTAssertEqual(store.loadAll(), [result])
        store.remove(id: "x")
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    // MARK: Manager (foreground session)

    func testForegroundUploadSendsMultipartFromFileAndReturnsResponse() async throws {
        StubUploadProtocol.reset(status: 202, body: Data("{\"ok\":true}".utf8))
        let file = try makeFile("day.zip", contents: "ZIP-BYTES")
        let manager = makeManager()

        let result = try await manager.uploadForeground(makeRequest(file: file))

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.statusCode, 202)
        XCTAssertEqual(result.responseBody, Data("{\"ok\":true}".utf8))
        XCTAssertEqual(result.metadata["date"], "2026-10-12")

        let captured = try XCTUnwrap(StubUploadProtocol.captured.first)
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.url?.path, "/api/files")
        XCTAssertTrue(captured.contentType?.hasPrefix("multipart/form-data; boundary=Boundary-") == true)
        let body = String(decoding: captured.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"checksum\"\r\n\r\nabc123"))
        XCTAssertTrue(body.contains("filename=\"day.zip\""))
        XCTAssertTrue(body.contains("ZIP-BYTES"))
    }

    func testForegroundUploadReportsHTTPFailureWithBody() async throws {
        StubUploadProtocol.reset(status: 500, body: Data("server error".utf8))
        let file = try makeFile("day.zip", contents: "Z")
        let result = try await makeManager().uploadForeground(makeRequest(file: file))

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failure, .httpStatus(500))
        XCTAssertEqual(result.responseBody, Data("server error".utf8))
    }

    func testForegroundUploadWithEmptySuccessBodyIsAFailure() async throws {
        StubUploadProtocol.reset(status: 200, body: Data())
        let file = try makeFile("day.zip", contents: "Z")
        let result = try await makeManager().uploadForeground(makeRequest(file: file))
        XCTAssertEqual(result.failure, .missingResponse)
    }

    func testSecondForegroundUploadWaitsForTheFirst() async throws {
        StubUploadProtocol.reset(status: 200, body: Data("{}".utf8))
        let file = try makeFile("day.zip", contents: "Z")
        let manager = makeManager()
        let firstRequest = makeRequest(file: file, id: "first")
        let secondRequest = makeRequest(file: file, id: "second")
        async let first = manager.uploadForeground(firstRequest)
        async let second = manager.uploadForeground(secondRequest)
        let results = try await [first, second]
        XCTAssertEqual(Set(results.map(\.id)), ["first", "second"])
        XCTAssertTrue(results.allSatisfy(\.isSuccess))
    }

    func testStartBackgroundWithoutBackgroundSessionThrows() async throws {
        let file = try makeFile("day.zip", contents: "Z")
        do {
            try await makeManager().startBackground(makeRequest(file: file))
            XCTFail("expected invalidRequest")
        } catch let failure as UploadFailure {
            XCTAssertEqual(failure, .invalidRequest)
        }
    }
}
