import Foundation

// MARK: - DownloadState

public enum DownloadState: String, Codable, Sendable, Equatable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

// MARK: - DownloadPriority

public enum DownloadPriority: Int, Codable, Sendable, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3

    public static func < (lhs: DownloadPriority, rhs: DownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var urlSessionPriority: Float {
        switch self {
        case .low:      return URLSessionTask.lowPriority
        case .normal:   return URLSessionTask.defaultPriority
        case .high:     return URLSessionTask.highPriority
        case .critical: return 1.0
        }
    }
}

// MARK: - DownloadTask

public struct DownloadTask: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let url: URL
    public var fileName: String
    public var priority: DownloadPriority
    public var state: DownloadState
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var createdAt: Date
    public var completedAt: Date?
    public var localURL: URL?           // set when state == .completed
    public var errorMessage: String?
    public var retryAttempt: Int

    public init(
        url: URL,
        fileName: String? = nil,
        priority: DownloadPriority = .normal
    ) {
        self.id = UUID()
        self.url = url
        self.fileName = fileName ?? (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        self.priority = priority
        self.state = .queued
        self.totalBytes = 0
        self.downloadedBytes = 0
        self.createdAt = Date()
        self.retryAttempt = 0
    }

    public static func == (lhs: DownloadTask, rhs: DownloadTask) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - DownloadProgress

public struct DownloadProgress: Sendable {
    public let taskId: UUID
    public let state: DownloadState
    public let fraction: Double         // 0.0 – 1.0  (nan if total unknown)
    public let downloadedBytes: Int64
    public let totalBytes: Int64        // 0 if unknown
    public let speed: Double            // bytes/sec, sliding 3s window
    public let eta: TimeInterval?       // nil if total unknown or speed == 0
    public let localURL: URL?           // non-nil only when state == .completed

    public var isIndeterminate: Bool { totalBytes == 0 }
    public var isCompleted: Bool { state == .completed }
}

// MARK: - DownloadEvent

public enum DownloadEvent: Sendable {
    case progress(DownloadProgress)
    case stateChange(id: UUID, state: DownloadState)
    case error(id: UUID, message: String)
    case added(DownloadTask)
    case removed(id: UUID)
}

// MARK: - DownloadError

public enum DownloadError: Error, Sendable {
    case invalidURL
    case alreadyQueued(URL)
    case taskNotFound(UUID)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case noResumeData
    case fileSystemError(Error)
    case maxRetriesExhausted
    case cancelled
}
