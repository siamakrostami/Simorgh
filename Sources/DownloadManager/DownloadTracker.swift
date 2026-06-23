import Combine
import Foundation

// MARK: - _DownloadSubjectBox

/// @unchecked Sendable wrapper — PassthroughSubject is internally synchronized.
private final class _DownloadSubjectBox: @unchecked Sendable {
    let events = PassthroughSubject<DownloadEvent, Never>()
    let tasks = CurrentValueSubject<[DownloadTask], Never>([])
}

// MARK: - DownloadTracker

/// Thread-safe store for all DownloadTask state, resume data, speed samplers,
/// and progress continuations. Protected by NSLock.
final class DownloadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _tasks: [UUID: DownloadTask] = [:]
    private var _resumeData: [UUID: Data] = [:]
    private var _samplers: [UUID: SpeedSampler] = [:]
    private var _continuations: [UUID: [UUID: AsyncStream<DownloadProgress>.Continuation]] = [:]
    private let box = _DownloadSubjectBox()

    // MARK: - Combine publishers

    var eventsPublisher: AnyPublisher<DownloadEvent, Never> {
        box.events.eraseToAnyPublisher()
    }

    var tasksPublisher: AnyPublisher<[DownloadTask], Never> {
        box.tasks.eraseToAnyPublisher()
    }

    // MARK: - Task CRUD

    func add(_ task: DownloadTask) {
        lock.lock()
        _tasks[task.id] = task
        _samplers[task.id] = SpeedSampler()
        let all = Array(_tasks.values)
        lock.unlock()
        box.tasks.send(all)
        box.events.send(.added(task))
    }

    func update(_ task: DownloadTask) {
        lock.lock()
        _tasks[task.id] = task
        let all = Array(_tasks.values)
        lock.unlock()
        box.tasks.send(all)
    }

    func remove(id: UUID) {
        lock.lock()
        _tasks.removeValue(forKey: id)
        _resumeData.removeValue(forKey: id)
        _samplers.removeValue(forKey: id)
        let conts = _continuations.removeValue(forKey: id) ?? [:]
        let all = Array(_tasks.values)
        lock.unlock()
        conts.values.forEach { $0.finish() }
        box.tasks.send(all)
        box.events.send(.removed(id: id))
    }

    func task(id: UUID) -> DownloadTask? {
        lock.lock()
        defer { lock.unlock() }
        return _tasks[id]
    }

    func allTasks() -> [DownloadTask] {
        lock.lock()
        defer { lock.unlock() }
        return Array(_tasks.values)
    }

    func contains(url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _tasks.values.contains { $0.url == url && $0.state != .completed && $0.state != .cancelled && $0.state != .failed }
    }

    // MARK: - State changes

    func setState(_ state: DownloadState, id: UUID) {
        lock.lock()
        guard var t = _tasks[id] else { lock.unlock(); return }
        t.state = state
        if state == .completed { t.completedAt = Date() }
        _tasks[id] = t
        let all = Array(_tasks.values)
        lock.unlock()
        box.tasks.send(all)
        box.events.send(.stateChange(id: id, state: state))
    }

    func setCompleted(id: UUID, localURL: URL) {
        lock.lock()
        guard var t = _tasks[id] else { lock.unlock(); return }
        t.state = .completed
        t.localURL = localURL
        t.completedAt = Date()
        t.downloadedBytes = t.totalBytes
        _tasks[id] = t
        let conts = _continuations[id] ?? [:]
        let all = Array(_tasks.values)
        lock.unlock()
        let prog = DownloadProgress(
            taskId: id, state: .completed, fraction: 1.0,
            downloadedBytes: t.downloadedBytes, totalBytes: t.totalBytes,
            speed: 0, eta: 0, localURL: localURL
        )
        conts.values.forEach { $0.yield(prog); $0.finish() }
        box.tasks.send(all)
        box.events.send(.stateChange(id: id, state: .completed))
    }

    func setFailed(id: UUID, message: String) {
        lock.lock()
        guard var t = _tasks[id] else { lock.unlock(); return }
        t.state = .failed
        t.errorMessage = message
        _tasks[id] = t
        let conts = _continuations[id] ?? [:]
        let all = Array(_tasks.values)
        lock.unlock()
        conts.values.forEach { $0.finish() }  // stream ends; caller sees no more progress
        box.tasks.send(all)
        box.events.send(.error(id: id, message: message))
        box.events.send(.stateChange(id: id, state: .failed))
    }

    func incrementRetry(id: UUID) {
        lock.lock()
        _tasks[id]?.retryAttempt += 1
        lock.unlock()
    }

    // MARK: - Progress

    func recordProgress(id: UUID, downloaded: Int64, total: Int64) {
        lock.lock()
        guard var t = _tasks[id] else { lock.unlock(); return }
        t.downloadedBytes = downloaded
        if total > 0 { t.totalBytes = total }
        _tasks[id] = t
        let sampler = _samplers[id]
        let conts = _continuations[id] ?? [:]
        lock.unlock()

        sampler?.record(bytes: downloaded - t.downloadedBytes)
        let speed = sampler?.speed() ?? 0
        let eta = sampler?.eta(downloaded: downloaded, total: total)
        let fraction = total > 0 ? Double(downloaded) / Double(total) : Double.nan

        let prog = DownloadProgress(
            taskId: id, state: .downloading, fraction: fraction,
            downloadedBytes: downloaded, totalBytes: total,
            speed: speed, eta: eta, localURL: nil
        )
        conts.values.forEach { $0.yield(prog) }
        box.events.send(.progress(prog))
    }

    // MARK: - Resume data

    func setResumeData(_ data: Data, id: UUID) {
        lock.lock()
        _resumeData[id] = data
        lock.unlock()
    }

    func resumeData(id: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return _resumeData[id]
    }

    func clearResumeData(id: UUID) {
        lock.lock()
        _resumeData.removeValue(forKey: id)
        lock.unlock()
    }

    // MARK: - AsyncStream continuations

    /// Register a continuation for live progress delivery. Returns a stream + unregister closure.
    func makeProgressStream(id: UUID) -> AsyncStream<DownloadProgress> {
        let streamId = UUID()
        return AsyncStream { [weak self] continuation in
            guard let self else { continuation.finish(); return }
            lock.lock()
            if _continuations[id] == nil { _continuations[id] = [:] }
            _continuations[id]?[streamId] = continuation
            // If task is already complete/cancelled, finish immediately
            let existing = _tasks[id]
            lock.unlock()
            if let t = existing, t.state == .completed || t.state == .failed || t.state == .cancelled {
                continuation.finish()
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.lock.lock()
                self?._continuations[id]?.removeValue(forKey: streamId)
                self?.lock.unlock()
            }
        }
    }
}
