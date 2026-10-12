import Foundation

// MARK: - UploadManager

/// File-based multipart uploads with optional background `URLSession` support.
///
/// ## Why not `APIClient.uploadRequest`?
/// `APIClient` sends an in-memory `Data` body through a per-call session. That cannot run in a
/// background session (only `uploadTask(with:fromFile:)` with delegate callbacks can) and holds the
/// whole file in RAM. `UploadManager` writes the multipart body to disk and sends it from the file, so
/// a large upload survives app suspension and relaunch.
///
/// ## Features
/// - Background session (`startBackground`) and foreground session (`uploadForeground`)
/// - One upload at a time (a new one waits for the running one)
/// - Persisted jobs (`UploadJobStore`) and unacknowledged results (`UploadResultStore`)
/// - Cancel-and-replace without reporting the replaced job
/// - Progress observers, active job queries, request/response logging through `URLSessionLogger`
///
/// ## Typical use
/// ```swift
/// let manager = UploadManager(config: UploadManagerConfig(
///     backgroundSessionIdentifier: "com.example.upload",
///     storageDirectory: uploadsDirectory,
///     logLevel: .standard))
/// manager.setFinishHandler { result in ... }       // set before the background session is re-attached
/// manager.replayUnacknowledgedResults()            // results delivered while no handler was set
/// try await manager.startBackground(request)       // returns once the transfer has started
/// // AppDelegate:
/// // application(_:handleEventsForBackgroundURLSession:completionHandler:)
/// manager.handleEventsForBackgroundURLSession(identifier: id, completionHandler: completionHandler)
/// ```
public final class UploadManager: NSObject, @unchecked Sendable {

    // MARK: Properties

    public let config: UploadManagerConfig

    private let jobStore: UploadJobStore
    private let resultStore: UploadResultStore
    private let lock = NSLock()

    private var finishHandler: (@Sendable (UploadResult) -> Void)?
    private var backgroundCompletionHandler: (() -> Void)?
    private var progressHandlers: [String: ProgressHandler] = [:]
    private var foregroundContinuations: [Int: CheckedContinuation<UploadResult, Error>] = [:]
    private var foregroundProgressHandlers: [Int: ProgressHandler] = [:]
    private var foregroundJobs: [Int: UploadJob] = [:]
    /// Jobs cancelled because a replacement is starting. Their completion is not reported.
    private var replacedJobIds: Set<String> = []
    private var responseBuffers: [Int: Data] = [:]
    /// The one upload allowed to run. A second start waits until it finishes.
    private var slotOwner: String?

    private lazy var backgroundSession: URLSession? = {
        guard let identifier = config.backgroundSessionIdentifier else { return nil }
        let sessionConfig = URLSessionConfiguration.background(withIdentifier: identifier)
        sessionConfig.isDiscretionary = false
        sessionConfig.sessionSendsLaunchEvents = true
        sessionConfig.allowsCellularAccess = config.allowsCellularAccess
        sessionConfig.timeoutIntervalForRequest = config.timeoutIntervalForRequest
        sessionConfig.timeoutIntervalForResource = config.backgroundTimeoutIntervalForResource
        sessionConfig.waitsForConnectivity = config.waitsForConnectivity
        return URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
    }()

    private lazy var foregroundSession: URLSession = {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.allowsCellularAccess = config.allowsCellularAccess
        sessionConfig.timeoutIntervalForRequest = config.timeoutIntervalForRequest
        sessionConfig.timeoutIntervalForResource = config.foregroundTimeoutIntervalForResource
        if let classes = config.foregroundProtocolClasses {
            sessionConfig.protocolClasses = classes
        }
        return URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
    }()

    // MARK: Init

    public init(
        config: UploadManagerConfig,
        jobStore: UploadJobStore? = nil,
        resultStore: UploadResultStore? = nil
    ) {
        self.config = config
        self.jobStore = jobStore ?? FileUploadJobStore(directory: config.storageDirectory)
        self.resultStore = resultStore ?? FileUploadResultStore(directory: config.storageDirectory)
        super.init()
    }

    // MARK: Finish handler

    /// Called once per finished background upload (not for replaced jobs). Every result is stored until
    /// `acknowledge(id:)`, also when no handler is set (a result delivered at cold launch, before the
    /// app is ready, is never lost).
    public func setFinishHandler(_ handler: (@Sendable (UploadResult) -> Void)?) {
        withLock { finishHandler = handler }
    }

    /// Delivers every stored, unacknowledged result to the finish handler again.
    public func replayUnacknowledgedResults() {
        let handler = withLock { finishHandler }
        for stored in resultStore.loadAll() {
            handler?(stored.result)
        }
    }

    /// Results delivered but not yet acknowledged.
    public func unacknowledgedResults() -> [UploadResult] {
        resultStore.loadAll().map(\.result)
    }

    /// Drops a stored result once the app handled it.
    public func acknowledge(id: String) {
        resultStore.remove(id: id)
    }

    // MARK: Background session lifecycle

    /// Store the completion handler iOS passes to
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        withLock { backgroundCompletionHandler = handler }
    }

    /// Re-creates the background session so iOS can deliver pending events to the delegate.
    public func reattachBackgroundSession() {
        backgroundSession?.getAllTasks { _ in }
    }

    /// Convenience for the AppDelegate callback. Returns `false` when `identifier` is not this manager's.
    @discardableResult
    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard identifier == config.backgroundSessionIdentifier else { return false }
        setBackgroundCompletionHandler(completionHandler)
        reattachBackgroundSession()
        return true
    }

    // MARK: Queries

    public func pendingJobs() -> [UploadJob] {
        jobStore.loadJobs()
    }

    public func job(id: String) -> UploadJob? {
        jobStore.loadJobs().first { $0.id == id }
    }

    /// Where a job's multipart body is kept inside `storageDirectory`.
    public func bodyFileURL(forJobId id: String) -> URL {
        config.storageDirectory.appendingPathComponent("\(id).multipart", isDirectory: false)
    }

    /// Observes byte progress of a background upload while the app is in the foreground.
    public func setProgressHandler(id: String, handler: ProgressHandler?) {
        withLock {
            if let handler {
                progressHandlers[id] = handler
            } else {
                progressHandlers.removeValue(forKey: id)
            }
        }
    }

    /// Ids of background tasks URLSession still has.
    public func activeJobIds() async -> Set<String> {
        guard let session = backgroundSession else { return [] }
        return await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.compactMap(\.taskDescription)))
            }
        }
    }

    /// Bytes sent so far for a running background upload.
    public func bytesSent(id: String) async -> (sent: Int64, expected: Int64)? {
        guard let session = backgroundSession else { return nil }
        return await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                guard let task = tasks.first(where: { $0.taskDescription == id }) else {
                    continuation.resume(returning: nil)
                    return
                }
                let expected = task.countOfBytesExpectedToSend
                guard expected > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (task.countOfBytesSent, expected))
            }
        }
    }

    // MARK: Cancel

    /// Cancels the background jobs whose metadata matches, so a replacement can be the only job.
    /// The cancelled jobs' results are not reported. Returns their ids.
    public func cancelJobs(matching predicate: @Sendable ([String: String]) -> Bool) async -> [String] {
        let jobs = jobStore.loadJobs().filter { predicate($0.metadata) }
        guard !jobs.isEmpty else { return [] }
        let ids = Set(jobs.map(\.id))
        withLock {
            replacedJobIds.formUnion(ids)
            for id in ids { progressHandlers.removeValue(forKey: id) }
        }
        guard let session = backgroundSession else {
            for job in jobs { removeJobAndBody(id: job.id) }
            withLock { replacedJobIds.subtract(ids) }
            return Array(ids)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.getAllTasks { tasks in
                var missing: [String] = []
                for job in jobs {
                    if let task = tasks.first(where: { $0.taskDescription == job.id }) {
                        task.cancel()
                    } else {
                        missing.append(job.id)
                        self.removeJobAndBody(id: job.id)
                    }
                }
                if !missing.isEmpty {
                    self.withLock { self.replacedJobIds.subtract(missing) }
                }
                continuation.resume()
            }
        }
        return Array(ids)
    }

    /// Drops a job record and its body file when URLSession no longer has a matching task.
    public func abandon(id: String) {
        setProgressHandler(id: id, handler: nil)
        removeJobAndBody(id: id)
    }

    /// Cancels the running foreground uploads. Their `uploadForeground` calls throw `CancellationError`.
    public func cancelForegroundUploads() {
        foregroundSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        let continuations = withLock { () -> [CheckedContinuation<UploadResult, Error>] in
            let all = Array(foregroundContinuations.values)
            foregroundContinuations.removeAll()
            foregroundProgressHandlers.removeAll()
            foregroundJobs.removeAll()
            responseBuffers.removeAll()
            return all
        }
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Cancels foreground and background uploads (logout, 401).
    public func cancelAll() {
        cancelForegroundUploads()
        backgroundSession?.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    // MARK: Start

    /// Builds the body, persists the job and starts a background transfer. Returns once the task runs.
    /// The result arrives through the finish handler, also after a relaunch.
    public func startBackground(_ request: UploadRequest) async throws {
        guard let session = backgroundSession else { throw UploadFailure.invalidRequest }
        let bodyURL = bodyFileURL(forJobId: request.id)
        try? FileManager.default.createDirectory(at: config.storageDirectory, withIntermediateDirectories: true)
        let urlRequest = try buildRequest(request, bodyURL: bodyURL)

        URLSessionLogger.shared.logRequest(urlRequest, logLevel: config.logLevel)

        try await acquireSlot(id: request.id)
        jobStore.upsert(
            UploadJob(id: request.id, metadata: request.metadata, bodyFileName: bodyURL.lastPathComponent)
        )
        let task = session.uploadTask(with: urlRequest, fromFile: bodyURL)
        task.taskDescription = request.id
        task.resume()
    }

    /// Uploads in the foreground session and waits for the result. A failed upload is returned as an
    /// `UploadResult` with `failure` set; only cancellation throws.
    public func uploadForeground(
        _ request: UploadRequest,
        progress: ProgressHandler? = nil
    ) async throws -> UploadResult {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-body-\(request.id).multipart", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let urlRequest = try buildRequest(request, bodyURL: bodyURL)

        URLSessionLogger.shared.logRequest(urlRequest, logLevel: config.logLevel)

        try await acquireSlot(id: request.id)
        let job = UploadJob(id: request.id, metadata: request.metadata, bodyFileName: nil)
        let session = foregroundSession
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UploadResult, Error>) in
            let task = session.uploadTask(with: urlRequest, fromFile: bodyURL)
            task.taskDescription = request.id
            withLock {
                foregroundContinuations[task.taskIdentifier] = continuation
                foregroundProgressHandlers[task.taskIdentifier] = progress
                foregroundJobs[task.taskIdentifier] = job
            }
            task.resume()
        }
    }

    // MARK: Internals

    private func buildRequest(_ request: UploadRequest, bodyURL: URL) throws -> URLRequest {
        let boundary: String
        do {
            boundary = try MultipartFileBodyWriter.write(
                textParts: request.textParts,
                fileParts: request.fileParts,
                to: bodyURL
            )
        } catch let failure as UploadFailure {
            throw failure
        } catch {
            throw error
        }
        var urlRequest = request.urlRequest
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return urlRequest
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func removeJobAndBody(id: String) {
        jobStore.remove(id: id)
        try? FileManager.default.removeItem(at: bodyFileURL(forJobId: id))
    }

    /// Takes the single upload slot once no other upload is still running.
    private func acquireSlot(id: String) async throws {
        while true {
            let claimed = withLock { () -> Bool in
                if let owner = slotOwner, owner != id { return false }
                slotOwner = id
                return true
            }
            if claimed, await liveBackgroundTaskCount() == 0, !foregroundInFlight { return }
            if claimed {
                withLock { if slotOwner == id { slotOwner = nil } }
            }
            if Task.isCancelled { throw CancellationError() }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func releaseSlot(id: String) {
        withLock { if slotOwner == id { slotOwner = nil } }
    }

    private var foregroundInFlight: Bool {
        withLock { !foregroundJobs.isEmpty }
    }

    private func liveBackgroundTaskCount() async -> Int {
        guard let session = backgroundSession else { return 0 }
        return await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let live = tasks.reduce(into: 0) { count, task in
                    if task.state == .running || task.state == .suspended { count += 1 }
                }
                continuation.resume(returning: live)
            }
        }
    }

    private func isBackground(_ session: URLSession) -> Bool {
        guard let identifier = config.backgroundSessionIdentifier else { return false }
        return session.configuration.identifier == identifier
    }
}

// MARK: - URLSession delegates

extension UploadManager: URLSessionTaskDelegate, URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let progress = totalBytesExpectedToSend > 0
            ? Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            : 0
        let handler = withLock { () -> ProgressHandler? in
            if isBackground(session) {
                return task.taskDescription.flatMap { progressHandlers[$0] }
            }
            return foregroundProgressHandlers[task.taskIdentifier]
        }
        handler?(progress, totalBytesSent, totalBytesExpectedToSend)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        withLock {
            var buffer = responseBuffers[dataTask.taskIdentifier] ?? Data()
            buffer.append(data)
            responseBuffers[dataTask.taskIdentifier] = buffer
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let buffer = withLock { responseBuffers.removeValue(forKey: task.taskIdentifier) }
        URLSessionLogger.shared.logResponse(task.response, data: buffer, error: error, logLevel: config.logLevel)

        let id = task.taskDescription ?? "unknown"
        releaseSlot(id: id)

        if isBackground(session) {
            completeBackground(id: id, task: task, buffer: buffer, error: error)
        } else {
            completeForeground(id: id, task: task, buffer: buffer, error: error)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard isBackground(session) else { return }
        let handler = withLock { () -> (() -> Void)? in
            let handler = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return handler
        }
        DispatchQueue.main.async { handler?() }
    }

    private func completeBackground(id: String, task: URLSessionTask, buffer: Data?, error: Error?) {
        let job = jobStore.loadJobs().first { $0.id == id }
        let replaced = withLock { () -> Bool in
            progressHandlers.removeValue(forKey: id)
            return replacedJobIds.remove(id) != nil
        }
        if replaced {
            removeJobAndBody(id: id)
            return
        }

        let http = task.response as? HTTPURLResponse
        let bytesSent = task.countOfBytesSent
        let bytesExpected = task.countOfBytesExpectedToSend
        let outcome = UploadCompletion.evaluate(
            transportError: error != nil,
            transportDescription: error?.localizedDescription ?? "",
            httpStatusCode: http?.statusCode,
            responseBody: buffer,
            bytesSent: bytesSent,
            bytesExpected: bytesExpected
        )
        let failure: UploadFailure?
        if case .failure(let reason) = outcome { failure = reason } else { failure = nil }
        let result = UploadResult(
            id: id,
            metadata: job?.metadata ?? [:],
            statusCode: http?.statusCode,
            responseBody: buffer,
            bytesSent: bytesSent,
            bytesExpected: bytesExpected,
            failure: failure,
            transportError: error
        )

        removeJobAndBody(id: id)
        resultStore.save(PersistedUploadResult(result))
        let handler = withLock { finishHandler }
        handler?(result)
    }

    private func completeForeground(id: String, task: URLSessionTask, buffer: Data?, error: Error?) {
        let (continuation, job) = withLock { () -> (CheckedContinuation<UploadResult, Error>?, UploadJob?) in
            foregroundProgressHandlers.removeValue(forKey: task.taskIdentifier)
            return (
                foregroundContinuations.removeValue(forKey: task.taskIdentifier),
                foregroundJobs.removeValue(forKey: task.taskIdentifier)
            )
        }
        guard let continuation else { return }

        let http = task.response as? HTTPURLResponse
        // Foreground gates: no full-send check (the connection is live, the response decides).
        let outcome = UploadCompletion.evaluate(
            transportError: error != nil,
            transportDescription: error?.localizedDescription ?? "",
            httpStatusCode: http?.statusCode,
            responseBody: buffer,
            bytesSent: 0,
            bytesExpected: 0
        )
        let failure: UploadFailure?
        if case .failure(let reason) = outcome { failure = reason } else { failure = nil }
        continuation.resume(returning: UploadResult(
            id: id,
            metadata: job?.metadata ?? [:],
            statusCode: http?.statusCode,
            responseBody: buffer,
            bytesSent: task.countOfBytesSent,
            bytesExpected: task.countOfBytesExpectedToSend,
            failure: failure,
            transportError: error
        ))
    }
}
