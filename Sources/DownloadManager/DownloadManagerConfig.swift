import Foundation

public struct DownloadManagerConfig: Sendable {
    /// Maximum simultaneous active URLSessionDownloadTask objects.
    public let maxConcurrentDownloads: Int
    /// Maximum tasks held in the pending queue (additional enqueues throw).
    public let maxQueueSize: Int
    /// Retry policy for failed downloads (network errors only — 4xx are not retried).
    public let retryPolicy: DownloadRetryPolicy
    /// Whether to allow downloads over cellular.
    public let allowsCellularAccess: Bool
    /// Root directory where completed files are moved. Defaults to `Documents/Downloads`.
    public let downloadDirectory: URL
    /// Minimum free disk space required before starting a download (bytes). Default 100 MB.
    public let minFreeDiskSpace: Int64
    /// Per-request timeout. Default 60 s.
    public let timeoutInterval: TimeInterval
    /// Background URLSession identifier. Pass non-nil to enable background downloads.
    public let backgroundSessionIdentifier: String?

    public init(
        maxConcurrentDownloads: Int = 3,
        maxQueueSize: Int = 100,
        retryPolicy: DownloadRetryPolicy = DownloadRetryPolicy(maximumAttempts: 3),
        allowsCellularAccess: Bool = true,
        downloadDirectory: URL? = nil,
        minFreeDiskSpace: Int64 = 100 * 1024 * 1024,
        timeoutInterval: TimeInterval = 60,
        backgroundSessionIdentifier: String? = nil
    ) {
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.maxQueueSize = max(1, maxQueueSize)
        self.retryPolicy = retryPolicy
        self.allowsCellularAccess = allowsCellularAccess
        self.downloadDirectory = downloadDirectory ?? {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.appendingPathComponent("Downloads", isDirectory: true)
        }()
        self.minFreeDiskSpace = minFreeDiskSpace
        self.timeoutInterval = timeoutInterval
        self.backgroundSessionIdentifier = backgroundSessionIdentifier
    }

    public static let `default` = DownloadManagerConfig()
}

// MARK: - DownloadRetryPolicy

public struct DownloadRetryPolicy: Sendable {
    public let maximumAttempts: Int
    public let initialDelay: TimeInterval
    public let multiplier: Double
    public let maximumDelay: TimeInterval

    public init(
        maximumAttempts: Int = 3,
        initialDelay: TimeInterval = 1,
        multiplier: Double = 2,
        maximumDelay: TimeInterval = 30
    ) {
        self.maximumAttempts = max(0, maximumAttempts)
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
        self.maximumDelay = max(initialDelay, maximumDelay)
    }

    public static let none = DownloadRetryPolicy(maximumAttempts: 0)

    func delay(for attempt: Int) -> TimeInterval {
        let d = initialDelay * pow(multiplier, Double(max(0, attempt - 1)))
        return min(d, maximumDelay)
    }

    func shouldRetry(attempt: Int, error: Error) -> Bool {
        guard attempt <= maximumAttempts else { return false }
        // Only retry network-level errors, not 4xx client errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        return false
    }
}
