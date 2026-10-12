import Foundation

// MARK: - Protocols

/// Persists upload jobs so a background transfer can be matched to its job after a relaunch.
public protocol UploadJobStore: Sendable {
    func loadJobs() -> [UploadJob]
    func upsert(_ job: UploadJob)
    /// Removes the job record. A custom store may also delete any files it keeps for the job.
    func remove(id: String)
}

/// Keeps finished results until the app acknowledges them, so a result delivered at cold launch
/// (before anyone listens) or lost to a crash is never dropped.
public protocol UploadResultStore: Sendable {
    func save(_ result: PersistedUploadResult)
    func loadAll() -> [PersistedUploadResult]
    func remove(id: String)
}

// MARK: - File based defaults

/// JSON file backed `UploadJobStore` (`upload-jobs.json` in `directory`).
public final class FileUploadJobStore: UploadJobStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("upload-jobs.json", isDirectory: false)
    }

    public func loadJobs() -> [UploadJob] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    public func upsert(_ job: UploadJob) {
        lock.lock()
        defer { lock.unlock() }
        var jobs = read().filter { $0.id != job.id }
        jobs.append(job)
        write(jobs)
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        write(read().filter { $0.id != id })
    }

    private func read() -> [UploadJob] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UploadJob].self, from: data)) ?? []
    }

    private func write(_ jobs: [UploadJob]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(jobs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// JSON file backed `UploadResultStore` (`upload-results.json` in `directory`).
public final class FileUploadResultStore: UploadResultStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("upload-results.json", isDirectory: false)
    }

    public func save(_ result: PersistedUploadResult) {
        lock.lock()
        defer { lock.unlock() }
        var all = read().filter { $0.id != result.id }
        all.append(result)
        write(all)
    }

    public func loadAll() -> [PersistedUploadResult] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        write(read().filter { $0.id != id })
    }

    private func read() -> [PersistedUploadResult] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PersistedUploadResult].self, from: data)) ?? []
    }

    private func write(_ results: [PersistedUploadResult]) {
        guard let data = try? JSONEncoder().encode(results) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
