import Foundation

/// Thread-safe file storage for completed downloads.
/// Each task gets its own subdirectory under `baseDirectory/<taskId>/`.
final class DownloadStorage: @unchecked Sendable {
    private let baseDirectory: URL
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.srnetwork.download.io", qos: .utility)

    init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// Move the temp file from URLSession to the download directory.
    /// Returns the final destination URL.
    func save(tempURL: URL, task: DownloadTask) throws -> URL {
        var fileName = task.fileName
        if fileName.isEmpty { fileName = task.url.lastPathComponent }
        if fileName.isEmpty { fileName = task.id.uuidString }

        let taskDir = baseDirectory.appendingPathComponent(task.id.uuidString, isDirectory: true)
        let destURL = taskDir.appendingPathComponent(fileName)

        try ioQueue.sync {
            if !fileManager.fileExists(atPath: taskDir.path) {
                try fileManager.createDirectory(at: taskDir, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: tempURL, to: destURL)
        }

        return destURL
    }

    /// Save resume data to disk so pause survives app termination.
    func saveResumeData(_ data: Data, taskId: UUID) throws {
        let url = resumeDataURL(for: taskId)
        try ioQueue.sync {
            let dir = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try data.write(to: url)
        }
    }

    func loadResumeData(taskId: UUID) -> Data? {
        let url = resumeDataURL(for: taskId)
        return ioQueue.sync { try? Data(contentsOf: url) }
    }

    func deleteResumeData(taskId: UUID) {
        let url = resumeDataURL(for: taskId)
        ioQueue.async { try? self.fileManager.removeItem(at: url) }
    }

    /// Remove all files for a task (completed file + resume data).
    func remove(taskId: UUID) {
        let taskDir = baseDirectory.appendingPathComponent(taskId.uuidString, isDirectory: true)
        ioQueue.async {
            try? self.fileManager.removeItem(at: taskDir)
        }
    }

    func fileExists(for task: DownloadTask) -> Bool {
        guard let url = task.localURL else { return false }
        return ioQueue.sync { fileManager.fileExists(atPath: url.path) }
    }

    /// Available disk space at the downloads directory location.
    func availableDiskSpace() -> Int64 {
        let attrs = try? fileManager.attributesOfFileSystem(forPath: baseDirectory.path)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    private func resumeDataURL(for taskId: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(taskId.uuidString, isDirectory: true)
            .appendingPathComponent("resume.dat")
    }
}
