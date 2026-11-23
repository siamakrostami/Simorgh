// MARK: - DefaultRetryHandler.swift

import Foundation

/// The built-in retry policy: retries transient failures of idempotent requests with
/// exponential backoff.
///
/// ## Behavior
/// - **Methods**: only idempotent methods are retried by default (`GET`, `HEAD`, `PUT`,
///   `DELETE`, `OPTIONS`, `TRACE`). Retrying a `POST` can create duplicates, so it is
///   opt-in through `retryableMethods`.
/// - **Errors**: transient `URLError`s (timeouts, lost connection, offline, DNS/host
///   failures) and status codes in `retryableStatusCodes` (408, 429, 500, 502, 503, 504).
///   Other 4xx responses, decoding errors and cancellations are never retried.
/// - **Backoff**: `baseDelay * 2^(attempt - 1)`, capped at `maximumDelay`. With `jitter`
///   enabled, the delay is randomized between 50% and 100% of that value so many clients
///   don't retry in lockstep.
///
/// ## Usage
/// ```swift
/// // 3 retries, 0.5s → 1s → 2s (with jitter)
/// let client = APIClient(retryHandler: DefaultRetryHandler(numberOfRetries: 3))
///
/// // Also retry POST (only if your endpoint is idempotent, e.g. uses an idempotency key)
/// let handler = DefaultRetryHandler(
///     numberOfRetries: 2,
///     retryableMethods: DefaultRetryHandler.idempotentMethods.union(["POST"])
/// )
/// ```
///
/// For token refresh or request mutation, implement your own `RetryHandler`.
public struct DefaultRetryHandler: RetryHandler {

    /// HTTP methods that are safe to repeat.
    public static let idempotentMethods: Set<String> = ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE"]

    /// Status codes that usually mean "try again later".
    public static let transientStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    /// `URLError` codes that usually mean a temporary network problem.
    public static let transientURLErrorCodes: [URLError.Code] = [
        .timedOut,
        .networkConnectionLost,
        .notConnectedToInternet,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
    ]

    // MARK: Lifecycle

    /// - Parameters:
    ///   - numberOfRetries: Maximum number of retries (0 disables retrying).
    ///   - retryableMethods: Upper-case HTTP methods that may be retried.
    ///   - retryableStatusCodes: HTTP status codes that may be retried.
    ///   - baseDelay: Delay before the first retry, in seconds. `0` retries immediately.
    ///   - maximumDelay: Upper bound for any single delay, in seconds.
    ///   - jitter: Randomize each delay between 50% and 100% of its computed value.
    public init(
        numberOfRetries: Int,
        retryableMethods: Set<String> = DefaultRetryHandler.idempotentMethods,
        retryableStatusCodes: Set<Int> = DefaultRetryHandler.transientStatusCodes,
        baseDelay: TimeInterval = 0.5,
        maximumDelay: TimeInterval = 30,
        jitter: Bool = true
    ) {
        self.numberOfRetries = max(0, numberOfRetries)
        self.retryableMethods = Set(retryableMethods.map { $0.uppercased() })
        self.retryableStatusCodes = retryableStatusCodes
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(0, maximumDelay)
        self.jitter = jitter
    }

    // MARK: Public

    /// The maximum number of retry attempts.
    public let numberOfRetries: Int
    public let retryableMethods: Set<String>
    public let retryableStatusCodes: Set<Int>
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let jitter: Bool

    public func shouldRetry(request: URLRequest, error: NetworkError) -> Bool {
        guard numberOfRetries > 0 else { return false }
        let method = (request.httpMethod ?? "GET").uppercased()
        guard retryableMethods.contains(method) else { return false }

        switch error {
        case .urlError(let urlError):
            return Self.transientURLErrorCodes.contains(urlError.code)
        case .customError(let statusCode, _):
            return retryableStatusCodes.contains(statusCode)
        default:
            return false
        }
    }

    public func modifyRequestForRetry(client: APIClient, request: URLRequest, error: NetworkError) -> (URLRequest, NetworkError?) {
        (request, nil)
    }

    public func retryDelay(for request: URLRequest, error: NetworkError, attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let delay = min(maximumDelay, baseDelay * pow(2, exponent))
        guard jitter, delay > 0 else { return delay }
        return Double.random(in: (delay / 2)...delay)
    }
}
