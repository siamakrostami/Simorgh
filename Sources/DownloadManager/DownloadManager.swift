import Combine
import Foundation

// MARK: - DownloadManager

/// A production-quality download manager with:
/// - True pause/resume via `URLSessionDownloadTask` resume data
/// - Priority queue (critical > high > normal > low)
/// - Concurrent download cap with automatic queue draining
/// - Exponential backoff retry for network errors
/// - Real-time speed (sliding 3-second window) and ETA
/// - Duplicate URL detection
/// - Background session support
/// - Logging via `URLSessionLogger`
/// - Combine publishers + AsyncStream (iOS 15+)
public final class DownloadManager: @unchecked Sendable {

    // MARK: - Properties

    public let config: DownloadManagerConfig

    private let tracker = DownloadTracker()
    private let storage: DownloadStorage
    private let session: URLSession
    private let sessionDelegate: _DownloadSessionDelegate

    // Priority-sorted queue of tasks waiting to start
    private var pendingQueue: [DownloadTask] = []
    // Active URLSession tasks keyed by DownloadTask.id
    private var activeTasks: [UUID: URLSessionDownloadTask] = [:]
    private var activeCount = 0
    private let lock = NSLock()

    // Background session completion handler (store from AppDelegate)
    public var backgroundCompletionHandler: (() -> Void)?

    private let logLevel: LogLevel

    // MARK: - Init

    public init(config: DownloadManagerConfig = .default, logLevel: LogLevel = .none) throws {
        self.config = config
        self.logLevel = logLevel
        self.storage = try DownloadStorage(baseDirectory: config.downloadDirectory)

        let sessionConfig: URLSessionConfiguration
        if let bgId = config.backgroundSessionIdentifier {
            sessionConfig = URLSessionConfiguration.background(withIdentifier: bgId)
            sessionConfig.sessionSendsLaunchEvents = true
            sessionConfig.isDiscretionary = false
        } else {
            sessionConfig = URLSessionConfiguration.default
        }
        sessionConfig.allowsCellularAccess = config.allowsCellularAccess
        sessionConfig.timeoutIntervalForRequest = config.timeoutInterval

        let delegate = _DownloadSessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        delegate.manager = self
    }

    // MARK: - Public API

    /// All tasks (active, queued, completed, failed, cancelled).
    public var tasks: [DownloadTask] { tracker.allTasks() }

    /// Combine publisher emitting the full task list on every change.
    public var tasksPublisher: AnyPublisher<[DownloadTask], Never> {
        tracker.tasksPublisher
    }

    /// Combine publisher emitting granular events (progress, state changes, errors).
    public var eventsPublisher: AnyPublisher<DownloadEvent, Never> {
        tracker.eventsPublisher
    }

    // MARK: Enqueue

    /// Add a URL to the download queue. Returns the task ID.
    /// Starts immediately if a slot is available, otherwise queues.
    @discardableResult
    public func enqueue(
        url: URL,
        fileName: String? = nil,
        priority: DownloadPriority = .normal
    ) throws -> UUID {
        guard !tracker.contains(url: url) else {
            throw DownloadError.alreadyQueued(url)
        }
        let free = storage.availableDiskSpace()
        guard free > config.minFreeDiskSpace else {
            throw DownloadError.insufficientDiskSpace(
                required: config.minFreeDiskSpace,
                available: free
            )
        }

        let task = DownloadTask(url: url, fileName: fileName, priority: priority)
        tracker.add(task)
        URLSessionLogger.shared.logDownload(event: "ENQUEUED", url: url, logLevel: logLevel)
        startOrEnqueue(task)
        return task.id
    }

    // MARK: Pause

    /// Pause an active download. Resume data is saved so it continues from the same byte.
    public func pause(id: UUID) {
        lock.lock()
        guard let urlTask = activeTasks[id] else {
            // Already queued, not started — just update state
            lock.unlock()
            tracker.setState(.paused, id: id)
            removePending(id: id)
            return
        }
        lock.unlock()

        tracker.setState(.paused, id: id)
        URLSessionLogger.shared.logDownload(event: "PAUSED", url: tracker.task(id: id)?.url, logLevel: logLevel)

        urlTask.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            if let data {
                self.tracker.setResumeData(data, id: id)
                try? self.storage.saveResumeData(data, taskId: id)
            }
            self.lock.lock()
            self.activeTasks.removeValue(forKey: id)
            self.activeCount -= 1
            self.lock.unlock()
            self.drainQueue()
        })
    }

    // MARK: Resume

    /// Resume a paused download. Uses resume data if available; otherwise restarts.
    public func resume(id: UUID) throws {
        guard var task = tracker.task(id: id) else {
            throw DownloadError.taskNotFound(id)
        }
        guard task.state == .paused else { return }
        task.state = .queued
        tracker.update(task)

        // Load resume data from memory first, then disk
        let data = tracker.resumeData(id: id) ?? storage.loadResumeData(taskId: id)
        startOrEnqueueWithResumeData(task, resumeData: data)
    }

    // MARK: Cancel

    /// Cancel and remove a download. Cleans up files.
    public func cancel(id: UUID) {
        lock.lock()
        let urlTask = activeTasks.removeValue(forKey: id)
        if urlTask != nil { activeCount -= 1 }
        lock.unlock()

        removePending(id: id)
        urlTask?.cancel()
        tracker.setState(.cancelled, id: id)
        tracker.clearResumeData(id: id)
        storage.deleteResumeData(taskId: id)
        storage.remove(taskId: id)
        tracker.remove(id: id)

        URLSessionLogger.shared.logDownload(event: "CANCELLED", url: tracker.task(id: id)?.url, logLevel: logLevel)
        drainQueue()
    }

    // MARK: Remove completed

    public func removeCompleted() {
        let completed = tracker.allTasks().filter { $0.state == .completed }
        completed.forEach { task in
            storage.remove(taskId: task.id)
            tracker.remove(id: task.id)
        }
    }

    // MARK: Combine per-task

    public func progressPublisher(for id: UUID) -> AnyPublisher<DownloadProgress, Never> {
        tracker.eventsPublisher
            .compactMap { event -> DownloadProgress? in
                if case .progress(let p) = event, p.taskId == id { return p }
                return nil
            }
            .eraseToAnyPublisher()
    }

    public func statePublisher(for id: UUID) -> AnyPublisher<DownloadState, Never> {
        tracker.eventsPublisher
            .compactMap { event -> DownloadState? in
                if case .stateChange(let eid, let state) = event, eid == id { return state }
                return nil
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Private: queue management

    private func startOrEnqueue(_ task: DownloadTask) {
        startOrEnqueueWithResumeData(task, resumeData: nil)
    }

    private func startOrEnqueueWithResumeData(_ task: DownloadTask, resumeData: Data?) {
        lock.lock()
        if activeCount < config.maxConcurrentDownloads {
            activeCount += 1
            lock.unlock()
            startURLTask(task, resumeData: resumeData)
        } else {
            insertPending(task)
            lock.unlock()
        }
    }

    private func insertPending(_ task: DownloadTask) {
        // Insert sorted by priority (highest first)
        if let idx = pendingQueue.firstIndex(where: { $0.priority < task.priority }) {
            pendingQueue.insert(task, at: idx)
        } else {
            pendingQueue.append(task)
        }
    }

    private func removePending(id: UUID) {
        lock.lock()
        pendingQueue.removeAll { $0.id == id }
        lock.unlock()
    }

    private func drainQueue() {
        lock.lock()
        guard !pendingQueue.isEmpty, activeCount < config.maxConcurrentDownloads else {
            lock.unlock()
            return
        }
        let next = pendingQueue.removeFirst()
        activeCount += 1
        lock.unlock()

        let resumeData = tracker.resumeData(id: next.id) ?? storage.loadResumeData(taskId: next.id)
        startURLTask(next, resumeData: resumeData)
    }

    private func startURLTask(_ task: DownloadTask, resumeData: Data?) {
        tracker.setState(.downloading, id: task.id)
        tracker.clearResumeData(id: task.id)
        storage.deleteResumeData(taskId: task.id)

        let urlTask: URLSessionDownloadTask
        if let data = resumeData {
            urlTask = session.downloadTask(withResumeData: data)
            URLSessionLogger.shared.logDownload(event: "RESUMED", url: task.url, logLevel: logLevel)
        } else {
            urlTask = session.downloadTask(with: task.url)
            URLSessionLogger.shared.logDownload(event: "STARTED", url: task.url, logLevel: logLevel)
        }
        urlTask.priority = task.priority.urlSessionPriority

        lock.lock()
        activeTasks[task.id] = urlTask
        lock.unlock()

        urlTask.resume()
    }

    // MARK: - Delegate callbacks (called by _DownloadSessionDelegate)

    fileprivate func handleProgress(
        urlTask: URLSessionDownloadTask,
        bytesWritten: Int64,
        totalWritten: Int64,
        totalExpected: Int64
    ) {
        guard let taskId = taskId(for: urlTask) else { return }
        tracker.recordProgress(id: taskId, downloaded: totalWritten, total: totalExpected)
    }

    fileprivate func handleFinished(urlTask: URLSessionDownloadTask, tempURL: URL) {
        guard let taskId = taskId(for: urlTask),
              var task = tracker.task(id: taskId) else { return }

        // Detect MIME and fix extension if needed
        if let data = try? Data(contentsOf: tempURL, options: .mappedIfSafe) {
            let detected = MimeTypeDetector.detectMimeType(from: data)
            let ext = detected?.ext ?? task.url.pathExtension
            if !task.fileName.contains(".") && !ext.isEmpty {
                task.fileName += ".\(ext)"
            }
        }

        do {
            let localURL = try storage.save(tempURL: tempURL, task: task)
            lock.lock()
            activeTasks.removeValue(forKey: taskId)
            activeCount -= 1
            lock.unlock()
            tracker.setCompleted(id: taskId, localURL: localURL)
            URLSessionLogger.shared.logDownload(event: "COMPLETED", url: task.url, detail: localURL.lastPathComponent, logLevel: logLevel)
        } catch {
            handleFailure(urlTask: urlTask, error: error)
            return
        }
        drainQueue()
    }

    fileprivate func handleFailure(urlTask: URLSessionDownloadTask, error: Error) {
        guard let taskId = taskId(for: urlTask),
              let task = tracker.task(id: taskId) else { return }

        lock.lock()
        activeTasks.removeValue(forKey: taskId)
        activeCount -= 1
        lock.unlock()

        let attempt = task.retryAttempt + 1
        if config.retryPolicy.shouldRetry(attempt: attempt, error: error) {
            tracker.incrementRetry(id: taskId)
            tracker.setState(.queued, id: taskId)
            let delay = config.retryPolicy.delay(for: attempt)
            URLSessionLogger.shared.logDownload(event: "RETRY", url: task.url, detail: "attempt \(attempt), delay \(delay)s", logLevel: logLevel)
            Task { [weak self] in
                let ns = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                guard let self else { return }
                if let t = self.tracker.task(id: taskId), t.state == .queued {
                    self.startOrEnqueue(t)
                }
            }
        } else {
            tracker.setFailed(id: taskId, message: error.localizedDescription)
            URLSessionLogger.shared.logResponse(nil, data: nil, error: error, logLevel: logLevel)
        }
        drainQueue()
    }

    fileprivate func handleBackgroundSessionFinished() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    private func taskId(for urlTask: URLSessionTask) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return activeTasks.first { $0.value == urlTask }?.key
    }
}

// MARK: - Async/Await API (iOS 15+)

@available(iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension DownloadManager {
    /// Enqueue and observe a download in one call. Yields progress until completion.
    /// Cancel the enclosing Task to pause (resume data is preserved).
    public func download(
        url: URL,
        fileName: String? = nil,
        priority: DownloadPriority = .normal
    ) throws -> AsyncStream<DownloadProgress> {
        let id = try enqueue(url: url, fileName: fileName, priority: priority)
        return tracker.makeProgressStream(id: id)
    }

    /// Observe progress for an already-enqueued task.
    public func progress(for id: UUID) -> AsyncStream<DownloadProgress> {
        tracker.makeProgressStream(id: id)
    }
}

// MARK: - _DownloadSessionDelegate

private final class _DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        manager?.handleProgress(
            urlTask: downloadTask,
            bytesWritten: bytesWritten,
            totalWritten: totalBytesWritten,
            totalExpected: totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy before temp file is deleted
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.copyItem(at: location, to: tempCopy)
        manager?.handleFinished(urlTask: downloadTask, tempURL: tempCopy)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let error else { return }
        // Ignore NSURLErrorCancelled — handled by pause/cancel paths
        let nsErr = error as NSError
        guard nsErr.code != NSURLErrorCancelled else { return }
        manager?.handleFailure(urlTask: downloadTask, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.manager?.handleBackgroundSessionFinished()
        }
    }
}
