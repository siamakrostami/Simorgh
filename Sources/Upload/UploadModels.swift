import Foundation

// MARK: - Request

/// A text field of a multipart upload.
public struct UploadTextPart: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A file field of a multipart upload. The file is streamed from disk, never loaded into memory.
public struct UploadFilePart: Sendable, Equatable {
    public let name: String
    public let fileURL: URL
    public let fileName: String
    public let mimeType: String

    public init(name: String, fileURL: URL, fileName: String, mimeType: String) {
        self.name = name
        self.fileURL = fileURL
        self.fileName = fileName
        self.mimeType = mimeType
    }
}

/// A raw (non-multipart) request body read from a file, starting at `offset`.
///
/// Used for protocols that send the file bytes as the whole body, such as a tus `PATCH`
/// (`Content-Type: application/offset+octet-stream`). A non-zero `offset` sends only the tail of the file,
/// which resumes a partially uploaded file.
public struct UploadRawBody: Sendable, Equatable {
    public let fileURL: URL
    public let offset: Int64
    public let contentType: String

    public init(fileURL: URL, offset: Int64 = 0, contentType: String = "application/octet-stream") {
        self.fileURL = fileURL
        self.offset = max(0, offset)
        self.contentType = contentType
    }
}

/// A file-based upload: a multipart body built from parts, or a raw file body.
///
/// The body is written to disk first (`MultipartFileBodyWriter` / `RawFileBodyWriter`) and sent with
/// `uploadTask(with:fromFile:)`. That is the only upload form a background `URLSession` accepts, and
/// it keeps large files out of memory.
public struct UploadRequest: Sendable {
    /// Stable job id. Also used as the task description, so it survives an app relaunch.
    public let id: String
    /// URL, method and headers. The body is built from the parts below, or from `rawBody`.
    public var urlRequest: URLRequest
    public var textParts: [UploadTextPart]
    public var fileParts: [UploadFilePart]
    /// When set, the body is these file bytes and `textParts` / `fileParts` are ignored.
    public var rawBody: UploadRawBody?
    /// Free-form values stored with the job (device id, date, checksum, ...) and returned with the result.
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        urlRequest: URLRequest,
        textParts: [UploadTextPart] = [],
        fileParts: [UploadFilePart] = [],
        rawBody: UploadRawBody? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.urlRequest = urlRequest
        self.textParts = textParts
        self.fileParts = fileParts
        self.rawBody = rawBody
        self.metadata = metadata
    }
}

// MARK: - Job

/// A persisted upload job. Lets the manager re-attach to a background transfer after a relaunch.
public struct UploadJob: Codable, Sendable, Equatable {
    public let id: String
    public var metadata: [String: String]
    /// Multipart body file name inside the manager's storage directory, kept until the job finishes.
    public var bodyFileName: String?
    public let createdAt: Date

    public init(id: String, metadata: [String: String], bodyFileName: String?, createdAt: Date = Date()) {
        self.id = id
        self.metadata = metadata
        self.bodyFileName = bodyFileName
        self.createdAt = createdAt
    }
}

// MARK: - Result

/// Why an upload did not count as successful.
public enum UploadFailure: Error, Equatable, Sendable, Codable, LocalizedError {
    /// URLSession reported an error (network, timeout, cancel).
    case transport(String)
    /// No HTTP response, or a success status without a response body.
    case missingResponse
    case httpStatus(Int)
    /// The task finished before the whole request body was sent.
    case incompleteSend(sent: Int64, expected: Int64)
    case invalidRequest
    case multipartEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .transport(let description): return description
        case .missingResponse: return "Upload finished without a response body."
        case .httpStatus(let code): return "Upload failed with HTTP status \(code)."
        case .incompleteSend: return "Upload finished before the full request body was sent."
        case .invalidRequest: return "Upload request could not be built."
        case .multipartEncodingFailed: return "Failed to encode the multipart upload body."
        }
    }

    public var logLabel: String {
        switch self {
        case .transport: return "transport"
        case .missingResponse: return "missingResponse"
        case .httpStatus(let code): return "httpStatus=\(code)"
        case .incompleteSend(let sent, let expected): return "incompleteSend sent=\(sent) expected=\(expected)"
        case .invalidRequest: return "invalidRequest"
        case .multipartEncodingFailed: return "multipartEncodingFailed"
        }
    }
}

/// The outcome of one upload.
public struct UploadResult: Sendable {
    public let id: String
    public let metadata: [String: String]
    public let statusCode: Int?
    public let responseBody: Data?
    public let bytesSent: Int64
    public let bytesExpected: Int64
    /// `nil` means success.
    public let failure: UploadFailure?
    /// The raw URLSession error behind a `.transport` failure. Not persisted.
    public let transportError: (any Error)?

    public var isSuccess: Bool { failure == nil }

    public init(
        id: String,
        metadata: [String: String],
        statusCode: Int?,
        responseBody: Data?,
        bytesSent: Int64,
        bytesExpected: Int64,
        failure: UploadFailure?,
        transportError: (any Error)? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.bytesSent = bytesSent
        self.bytesExpected = bytesExpected
        self.failure = failure
        self.transportError = transportError
    }
}

/// Codable form of an `UploadResult`, for stores that keep results until the app acknowledges them.
public struct PersistedUploadResult: Codable, Sendable, Equatable {
    public let id: String
    public let metadata: [String: String]
    public let statusCode: Int?
    public let responseBody: Data?
    public let bytesSent: Int64
    public let bytesExpected: Int64
    public let failure: UploadFailure?

    public init(
        id: String,
        metadata: [String: String],
        statusCode: Int?,
        responseBody: Data?,
        bytesSent: Int64,
        bytesExpected: Int64,
        failure: UploadFailure?
    ) {
        self.id = id
        self.metadata = metadata
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.bytesSent = bytesSent
        self.bytesExpected = bytesExpected
        self.failure = failure
    }

    public init(_ result: UploadResult) {
        self.init(
            id: result.id,
            metadata: result.metadata,
            statusCode: result.statusCode,
            responseBody: result.responseBody,
            bytesSent: result.bytesSent,
            bytesExpected: result.bytesExpected,
            failure: result.failure
        )
    }

    public var result: UploadResult {
        UploadResult(
            id: id,
            metadata: metadata,
            statusCode: statusCode,
            responseBody: responseBody,
            bytesSent: bytesSent,
            bytesExpected: bytesExpected,
            failure: failure
        )
    }
}

// MARK: - Config

public struct UploadManagerConfig: Sendable {
    /// Identifier of the background `URLSession`. `nil` disables background uploads.
    public var backgroundSessionIdentifier: String?
    /// Where multipart body files (and the default job/result stores) live.
    public var storageDirectory: URL
    public var allowsCellularAccess: Bool
    /// Per-request idle limit (also used for the foreground session).
    public var timeoutIntervalForRequest: TimeInterval
    /// Wall-clock limit of one background transfer.
    public var backgroundTimeoutIntervalForResource: TimeInterval
    /// Wall-clock limit of one foreground transfer.
    public var foregroundTimeoutIntervalForResource: TimeInterval
    public var waitsForConnectivity: Bool
    public var logLevel: LogLevel
    /// Test hook: custom `URLProtocol` classes for the foreground session.
    public var foregroundProtocolClasses: [AnyClass]?

    public init(
        backgroundSessionIdentifier: String? = nil,
        storageDirectory: URL,
        allowsCellularAccess: Bool = true,
        timeoutIntervalForRequest: TimeInterval = 60 * 60,
        backgroundTimeoutIntervalForResource: TimeInterval = 24 * 60 * 60,
        foregroundTimeoutIntervalForResource: TimeInterval = 60 * 60,
        waitsForConnectivity: Bool = true,
        logLevel: LogLevel = .none,
        foregroundProtocolClasses: [AnyClass]? = nil
    ) {
        self.backgroundSessionIdentifier = backgroundSessionIdentifier
        self.storageDirectory = storageDirectory
        self.allowsCellularAccess = allowsCellularAccess
        self.timeoutIntervalForRequest = timeoutIntervalForRequest
        self.backgroundTimeoutIntervalForResource = backgroundTimeoutIntervalForResource
        self.foregroundTimeoutIntervalForResource = foregroundTimeoutIntervalForResource
        self.waitsForConnectivity = waitsForConnectivity
        self.logLevel = logLevel
        self.foregroundProtocolClasses = foregroundProtocolClasses
    }
}
