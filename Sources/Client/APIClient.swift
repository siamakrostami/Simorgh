import Combine
import Foundation

// MARK: - APIClient



/// A comprehensive, thread-safe API client for handling network requests with support for
/// both Combine and async/await programming models.
///
/// ## Overview
/// `APIClient` is the core component of Simorgh that provides a unified interface
/// for making HTTP requests, handling responses, managing uploads, and implementing retry logic.
/// It's designed to be thread-safe and can handle concurrent requests efficiently.
///
/// ## Key Features
/// - **Dual Programming Models**: Support for both Combine and async/await
/// - **Thread Safety**: All operations are thread-safe with proper synchronization
/// - **Retry Logic**: Configurable retry strategies for failed requests
/// - **Upload Support**: File upload with progress tracking
/// - **Streaming**: Support for streaming responses
/// - **Logging**: Comprehensive request/response logging
/// - **Error Handling**: Rich error types with proper mapping
/// - **Session Management**: Automatic session lifecycle management
///
/// ## Thread Safety
/// Mutable state is guarded by a private serial queue. All requests share one long-lived
/// `URLSession` (connection reuse, HTTP/2 multiplexing); only uploads with progress and
/// Combine streams get a short-lived session of their own, which is invalidated as soon
/// as the task finishes.
///
/// ## Usage Examples
///
/// ### Basic Configuration
/// ```swift
/// let client = APIClient(
///     configuration: .default,
///     qos: .userInitiated,
///     logLevel: .verbose,
///     decoder: JSONDecoder(),
///     retryHandler: DefaultRetryHandler(numberOfRetries: 3)
/// )
/// ```
///
/// ### Making Requests
/// ```swift
/// // Combine
/// client.request(endpoint)
///     .sink(receiveCompletion: { ... }, receiveValue: { ... })
///     .store(in: &cancellables)
///
/// // Async/await
/// let response = try await client.request(endpoint)
/// ```
///
/// ### File Upload
/// ```swift
/// client.uploadRequest(endpoint, withName: "file", data: fileData) { progress in
///     print("Upload progress: \(progress)")
/// }
/// .sink(receiveCompletion: { ... }, receiveValue: { ... })
/// .store(in: &cancellables)
/// ```
///
/// ### Streaming
/// ```swift
/// client.streamRequest(endpoint)
///     .sink(receiveCompletion: { ... }, receiveValue: { chunk in
///         // Handle each chunk
///     })
///     .store(in: &cancellables)
/// ```
///
/// ## Error Handling
/// The client provides comprehensive error handling with automatic mapping of:
/// - Network errors (URLError)
/// - Decoding errors (DecodingError)
/// - Custom server errors
/// - Response errors
///
/// ## Retry Logic
/// Failed requests can be automatically retried based on configurable strategies:
/// - Number of retries
/// - Retry conditions
/// - Request modification for retries
///
/// ## Logging
/// Request and response logging can be configured with different levels:
/// - `.none`: No logging
/// - `.basic`: Basic request/response info
/// - `.verbose`: Detailed logging with headers and body
///
/// ## Session Management
/// The client automatically manages URLSession instances and provides methods to:
/// - Track active sessions
/// - Cancel all ongoing requests
/// - Invalidate sessions properly
public final class APIClient: @unchecked Sendable
{
    // MARK: Lifecycle

    // MARK: - Initialization

    /// Initializes a new APIClient instance.
    /// - Parameters:
    ///   - configuration: An optional `URLSessionConfiguration` to use for sessions. Pass `nil` to use a default configuration.
    ///   - configurationDelegate: An optional `URLSessionDelegate` used when creating sessions.
    ///   - qos: The quality of service for the API queue. Default is `.background`.
    ///   - logLevel: The initial log level for request/response logging. Default is `.none`.
    ///   - defaultCacheStrategy: The default cache strategy applied to requests when no explicit policy is provided. Default is `.useProtocolCachePolicy`.
    ///   - decoder: The JSONDecoder used for decoding responses. Defaults to a new `JSONDecoder()`.
    ///   - retryHandler: The retry handler controlling retry behavior. Defaults to `DefaultRetryHandler(numberOfRetries: 0)`.
    public init(
        configuration: URLSessionConfiguration? = nil,
        configurationDelegate: URLSessionDelegate? = nil,
        qos: DispatchQoS = .background,
        logLevel: LogLevel = .none,
        defaultCacheStrategy: CacheStrategy = .useProtocolCachePolicy,
        decoder: JSONDecoder? = nil,
        retryHandler: RetryHandler? = nil
    ) {
        self._logLevel = logLevel
        self._defaultCacheStrategy = defaultCacheStrategy
        self.apiQueue = DispatchQueue(label: "com.simorgh.apiClient", qos: qos)
        self._decoder = decoder ?? JSONDecoder()
        self._retryHandler = retryHandler ?? DefaultRetryHandler(numberOfRetries: 0)
        self._configuration = configuration
        self._configurationDelegate = configurationDelegate
        self._activeSessions = Set()
    }

    deinit {
        // Sessions retain their delegates strongly; make sure nothing outlives the client.
        _activeSessions.forEach { $0.finishTasksAndInvalidate() }
    }

    // MARK: Private

    // MARK: - Properties

    /// Serial queue guarding all mutable state below.
    ///
    /// - Important: Never call one of the `apiQueue.sync` accessors from code that is already
    ///   running on `apiQueue` — the queue is serial and that would deadlock.
    private let apiQueue: DispatchQueue

    private var _logLevel: LogLevel

    /// Thread-safe access to log level
    private var logLevel: LogLevel {
        get { return apiQueue.sync { _logLevel } }
        set { apiQueue.sync { _logLevel = newValue } }
    }

    /// Backing storage for the session configuration used to build new URLSession instances.
    private var _configuration: URLSessionConfiguration?

    /// Backing storage for the URLSession delegate used when creating sessions.
    private var _configurationDelegate: URLSessionDelegate?

    /// Thread-safe access to the current URLSessionConfiguration. If `nil`, a default configuration is used.
    private var configuration: URLSessionConfiguration? {
        get { return apiQueue.sync { _configuration } }
        set { apiQueue.sync { _configuration = newValue } }
    }

    /// Thread-safe access to the current URLSessionDelegate used for newly created sessions.
    private var configurationDelegate: URLSessionDelegate? {
        get { return apiQueue.sync { _configurationDelegate } }
        set { apiQueue.sync { _configurationDelegate = newValue } }
    }

    private var _retryHandler: RetryHandler?

    /// Thread-safe access to the retry handler.
    private var retryHandler: RetryHandler {
        get { return apiQueue.sync { _retryHandler ?? DefaultRetryHandler(numberOfRetries: 0) } }
        set { apiQueue.sync { _retryHandler = newValue } }
    }

    private var _decoder: JSONDecoder

    /// Thread-safe access to the JSON decoder used for decoding server responses.
    private var decoder: JSONDecoder {
        get { return apiQueue.sync { _decoder } }
        set { apiQueue.sync { _decoder = newValue } }
    }

    /// The long-lived session used for every request that does not need its own delegate.
    /// Created lazily, rebuilt only when the configuration or cache settings change.
    private var _sharedSession: URLSession?

    /// Every session the client currently owns: the shared session plus any short-lived
    /// per-request sessions (uploads with progress, Combine streams) that are still running.
    private var _activeSessions: Set<URLSession>

    private var _defaultCacheStrategy: CacheStrategy = .useProtocolCachePolicy

    private var _cacheConfiguration: CacheConfiguration?

    /// Thread-safe access to the default cache strategy.
    private var defaultCacheStrategy: CacheStrategy {
        get { return apiQueue.sync { _defaultCacheStrategy } }
        set { apiQueue.sync { _defaultCacheStrategy = newValue } }
    }

    /// Thread-safe access to the cache configuration used to build a URLCache for new sessions.
    private var cacheConfiguration: CacheConfiguration? {
        get { return apiQueue.sync { _cacheConfiguration } }
        set { apiQueue.sync { _cacheConfiguration = newValue } }
    }
}

// MARK: - Session lifecycle

extension APIClient {
    /// Number of sessions the client currently owns. Exposed for tests.
    var activeSessionCount: Int {
        apiQueue.sync { _activeSessions.count }
    }

    /// Returns the shared session, creating it on first use.
    private func sharedSession() -> URLSession {
        apiQueue.sync {
            if let session = _sharedSession { return session }
            let session = makeSessionLocked(delegate: _configurationDelegate)
            _sharedSession = session
            _activeSessions.insert(session)
            return session
        }
    }

    /// Creates a short-lived session for a single request that needs its own delegate.
    /// Every call must be balanced by `releaseRequestSession(_:)` once the task finishes.
    private func requestSession(delegate: URLSessionDelegate) -> URLSession {
        apiQueue.sync {
            let session = makeSessionLocked(delegate: delegate)
            _activeSessions.insert(session)
            return session
        }
    }

    /// Session for one upload: a per-request session reporting progress, or the shared
    /// session when the caller supplied their own delegate.
    private func uploadSession(ownsSession: Bool, progressCompletion: @escaping ProgressHandler) -> URLSession {
        guard ownsSession else { return sharedSession() }
        let progressDelegate = UploadProgressDelegate()
        progressDelegate.progressHandler = progressCompletion
        return requestSession(delegate: progressDelegate)
    }

    /// Lets a per-request session finish and release its delegate.
    private func releaseRequestSession(_ session: URLSession) {
        session.finishTasksAndInvalidate()
        apiQueue.sync { _ = _activeSessions.remove(session) }
    }

    /// Drops the shared session so the next request builds one with the current settings.
    /// - Parameter cancelAll: Cancel every in-flight task instead of letting them finish.
    /// - Important: Must be called on `apiQueue`.
    private func resetSessionsLocked(cancelAll: Bool) {
        if cancelAll {
            _activeSessions.forEach { $0.invalidateAndCancel() }
            _activeSessions.removeAll()
        } else if let shared = _sharedSession {
            shared.finishTasksAndInvalidate()
            _activeSessions.remove(shared)
        }
        _sharedSession = nil
    }

    /// Builds a session from the current configuration and cache settings.
    /// - Important: Must be called on `apiQueue`.
    private func makeSessionLocked(delegate: URLSessionDelegate?) -> URLSession {
        let sessionConfiguration: URLSessionConfiguration
        if let configured = _configuration {
            // Copy so we never mutate the caller's configuration object.
            sessionConfiguration = (configured.copy() as? URLSessionConfiguration) ?? configured
        } else {
            sessionConfiguration = URLSessionConfiguration.default
            sessionConfiguration.timeoutIntervalForRequest = 120
            sessionConfiguration.timeoutIntervalForResource = 120
        }
        sessionConfiguration.requestCachePolicy = _defaultCacheStrategy.requestPolicy
        if let cacheConfig = _cacheConfiguration {
            sessionConfiguration.urlCache = cacheConfig.buildCache()
        }
        return URLSession(
            configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
    }

    /// Builds the `URLRequest` for an endpoint, surfacing build failures as `.invalidRequest`.
    private func makeURLRequest(_ endpoint: any NetworkRouter) throws(NetworkError) -> URLRequest {
        do {
            return try endpoint.asURLRequest()
        } catch {
            throw NetworkError.invalidRequest(error)
        }
    }

    /// Validates the HTTP status (2xx) and logs the response.
    private func validateStatus(_ data: Data, _ response: URLResponse) throws(NetworkError) {
        let logLevel = self.logLevel
        guard let httpResponse = response as? HTTPURLResponse else {
            URLSessionLogger.shared.logResponse(response, data: data, error: NetworkError.unknown, logLevel: logLevel)
            throw NetworkError.unknown
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let error = NetworkError.customError(httpResponse.statusCode, data)
            URLSessionLogger.shared.logResponse(response, data: data, error: error, logLevel: logLevel)
            throw error
        }
        URLSessionLogger.shared.logResponse(response, data: data, error: nil, logLevel: logLevel)
    }

    /// Validates the HTTP status and decodes the body.
    private func validateAndDecode<T: Decodable>(_ data: Data, _ response: URLResponse) throws(NetworkError) -> T {
        try validateStatus(data, response)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw mapErrorToNetworkError(error)
        }
    }
}

// MARK: - Retry

extension APIClient {
    /// Combine retry step. Each call works only on the request it was given, so concurrent
    /// failures never see each other's requests.
    private func retryPublisher<T>(
        request: URLRequest,
        retryCount: Int,
        attempt: Int,
        error: NetworkError,
        operation: @escaping (URLRequest, _ retryCount: Int, _ attempt: Int) -> AnyPublisher<T, NetworkError>
    ) -> AnyPublisher<T, NetworkError> {
        let handler = retryHandler
        guard retryCount > 0, !error.isCancellation,
              handler.shouldRetry(request: request, error: error)
        else {
            return Fail(error: error).eraseToAnyPublisher()
        }

        let (newRequest, blockingError) = handler.modifyRequestForRetry(
            client: self, request: request, error: error)
        if let blockingError {
            return Fail(error: blockingError).eraseToAnyPublisher()
        }

        let delay = handler.retryDelay(for: request, error: error, attempt: attempt)
        guard delay > 0 else {
            return operation(newRequest, retryCount - 1, attempt + 1)
        }
        return Just(())
            .delay(for: .seconds(delay), scheduler: DispatchQueue.global())
            .setFailureType(to: NetworkError.self)
            .flatMap { _ in operation(newRequest, retryCount - 1, attempt + 1) }
            .eraseToAnyPublisher()
    }

    /// async/await retry loop. Stops immediately when the calling task is cancelled.
    private func withRetry<T>(
        _ urlRequest: URLRequest,
        operation: (URLRequest) async throws -> T
    ) async throws(NetworkError) -> T {
        let handler = retryHandler
        var request = urlRequest
        var remaining = handler.numberOfRetries
        var attempt = 1

        while true {
            do {
                return try await operation(request)
            } catch {
                let networkError = mapErrorToNetworkError(error)
                if Task.isCancelled || networkError.isCancellation {
                    throw NetworkError.urlError(URLError(.cancelled))
                }
                guard remaining > 0,
                      await handler.shouldRetryAsync(request: request, error: networkError)
                else {
                    throw networkError
                }

                let failedRequest = request
                do {
                    request = try await handler.modifyRequestForRetryAsync(
                        client: self, request: failedRequest, error: networkError)
                    let delay = handler.retryDelay(for: failedRequest, error: networkError, attempt: attempt)
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                } catch {
                    throw mapErrorToNetworkError(error)
                }
                remaining -= 1
                attempt += 1
            }
        }
    }
}

// MARK: - APIClient+CombineRequest

extension APIClient {
    // MARK: - Combine Network Request

    /// Performs a network request using Combine.
    /// - Parameter endpoint: The NetworkRouter defining the request.
    /// - Returns: A publisher that emits the decoded response or an error. Values are delivered on the main queue.
    public func request<T: Codable & Sendable>(_ endpoint: any NetworkRouter)
        -> AnyPublisher<T, NetworkError>
    {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(endpoint)
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }

        return makeRequest(urlRequest: urlRequest, retryCount: retryHandler.numberOfRetries, attempt: 1)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Internal method to make the actual network request.
    private func makeRequest<T: Codable & Sendable>(
        urlRequest: URLRequest, retryCount: Int, attempt: Int
    ) -> AnyPublisher<T, NetworkError> {
        URLSessionLogger.shared.logRequest(urlRequest, logLevel: logLevel)

        return sharedSession().dataTaskPublisher(for: urlRequest)
            .tryMap { output -> T in
                try self.validateAndDecode(output.data, output.response)
            }
            .mapError { error -> NetworkError in
                if !(error is NetworkError) {
                    URLSessionLogger.shared.logResponse(
                        nil, data: nil, error: error, logLevel: self.logLevel)
                }
                return self.mapErrorToNetworkError(error)
            }
            .catch { error -> AnyPublisher<T, NetworkError> in
                self.retryPublisher(
                    request: urlRequest, retryCount: retryCount, attempt: attempt, error: error
                ) { request, retryCount, attempt in
                    self.makeRequest(urlRequest: request, retryCount: retryCount, attempt: attempt)
                }
            }
            .eraseToAnyPublisher()
    }
}

extension APIClient {
    // MARK: - Combine Upload Request

    /// Performs a file upload request using Combine.
    /// - Parameters:
    ///   - endpoint: The NetworkRouter defining the request.
    ///   - withName: The name to be used for the file in the multipart form data.
    ///   - data: The file data to be uploaded.
    ///   - progressCompletion: A closure to handle upload progress updates.
    /// - Returns: A publisher that emits the decoded response or an error. Values are delivered on the main queue.
    public func uploadRequest<T: Codable & Sendable>(
        _ endpoint: any NetworkRouter, withName: String, data: Data?,
        progressCompletion: @escaping ProgressHandler
    ) -> AnyPublisher<T, NetworkError> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(endpoint)
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
        guard let file = data else {
            return Fail(error: NetworkError.unknown).eraseToAnyPublisher()
        }

        return makeUploadRequest(
            urlRequest: urlRequest, withName: withName, data: file,
            progressCompletion: progressCompletion,
            retryCount: retryHandler.numberOfRetries, attempt: 1
        )
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    /// Performs a multipart form data upload request using Combine.
    /// - Parameters:
    ///   - endpoint: The NetworkRouter defining the request.
    ///   - formFields: An array of multipart form fields (text values and/or files).
    ///   - progressCompletion: A closure to handle upload progress updates.
    /// - Returns: A publisher that emits the decoded response or an error. Values are delivered on the main queue.
    public func uploadRequest<T: Codable & Sendable>(
        _ endpoint: any NetworkRouter, formFields: [MultipartFormField],
        progressCompletion: @escaping ProgressHandler
    ) -> AnyPublisher<T, NetworkError> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(endpoint)
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }

        return makeUploadRequest(
            urlRequest: urlRequest, formFields: formFields,
            progressCompletion: progressCompletion,
            retryCount: retryHandler.numberOfRetries, attempt: 1
        )
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    /// Single-file upload with retry. The multipart body is rebuilt for every attempt.
    private func makeUploadRequest<T: Codable & Sendable>(
        urlRequest: URLRequest, withName: String, data: Data,
        progressCompletion: @escaping ProgressHandler, retryCount: Int, attempt: Int
    ) -> AnyPublisher<T, NetworkError> {
        URLSessionLogger.shared.logRequest(urlRequest, logLevel: logLevel)
        let (newUrlRequest, bodyData) = createBody(
            urlRequest: urlRequest, data: data, filename: withName)

        let upload: AnyPublisher<T, NetworkError> = performUpload(
            urlRequest: newUrlRequest, bodyData: bodyData, progressCompletion: progressCompletion)
        return upload
            .catch { error -> AnyPublisher<T, NetworkError> in
                self.retryPublisher(
                    request: urlRequest, retryCount: retryCount, attempt: attempt, error: error
                ) { request, retryCount, attempt in
                    self.makeUploadRequest(
                        urlRequest: request, withName: withName, data: data,
                        progressCompletion: progressCompletion,
                        retryCount: retryCount, attempt: attempt)
                }
            }
            .eraseToAnyPublisher()
    }

    /// Multipart form-fields upload with retry. The body is rebuilt for every attempt.
    private func makeUploadRequest<T: Codable & Sendable>(
        urlRequest: URLRequest, formFields: [MultipartFormField],
        progressCompletion: @escaping ProgressHandler, retryCount: Int, attempt: Int
    ) -> AnyPublisher<T, NetworkError> {
        URLSessionLogger.shared.logRequest(urlRequest, logLevel: logLevel)
        let (newUrlRequest, bodyData) = createMultipartBody(
            urlRequest: urlRequest, formFields: formFields)

        let upload: AnyPublisher<T, NetworkError> = performUpload(
            urlRequest: newUrlRequest, bodyData: bodyData, progressCompletion: progressCompletion)
        return upload
            .catch { error -> AnyPublisher<T, NetworkError> in
                self.retryPublisher(
                    request: urlRequest, retryCount: retryCount, attempt: attempt, error: error
                ) { request, retryCount, attempt in
                    self.makeUploadRequest(
                        urlRequest: request, formFields: formFields,
                        progressCompletion: progressCompletion,
                        retryCount: retryCount, attempt: attempt)
                }
            }
            .eraseToAnyPublisher()
    }

    /// Runs one upload attempt. Starts on subscription and cancels the task when the subscriber cancels.
    private func performUpload<T: Codable & Sendable>(
        urlRequest: URLRequest, bodyData: Data,
        progressCompletion: @escaping ProgressHandler
    ) -> AnyPublisher<T, NetworkError> {
        Deferred { [weak self] () -> AnyPublisher<T, NetworkError> in
            guard let self else {
                return Fail(error: NetworkError.unknown).eraseToAnyPublisher()
            }

            let taskBox = TaskBox()
            let future = Future<Data, NetworkError> { promise in
                let sendablePromise = SendablePromise(promise)
                let ownsSession = self.configurationDelegate == nil
                let session = self.uploadSession(
                    ownsSession: ownsSession, progressCompletion: progressCompletion)

                let task = session.uploadTask(with: urlRequest, from: bodyData) {
                    data, response, error in
                    if ownsSession {
                        self.releaseRequestSession(session)
                    }
                    if let error {
                        URLSessionLogger.shared.logResponse(
                            response, data: data, error: error, logLevel: self.logLevel)
                        sendablePromise.resolve(.failure(self.mapErrorToNetworkError(error)))
                    } else if let response {
                        do {
                            try self.validateStatus(data ?? Data(), response)
                            sendablePromise.resolve(.success(data ?? Data()))
                        } catch {
                            sendablePromise.resolve(.failure(self.mapErrorToNetworkError(error)))
                        }
                    } else {
                        sendablePromise.resolve(.failure(.unknown))
                    }
                }
                taskBox.task = task
                task.resume()
            }

            return future
                .handleEvents(receiveCancel: { taskBox.task?.cancel() })
                .tryMap { data -> T in
                    do {
                        return try self.decoder.decode(T.self, from: data)
                    } catch {
                        throw self.mapErrorToNetworkError(error)
                    }
                }
                .mapError { self.mapErrorToNetworkError($0) }
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }
}

/// Holds a task reference so a Combine cancel can reach it. Written once, before the
/// publisher can be cancelled, then only read.
private final class TaskBox: @unchecked Sendable {
    var task: URLSessionTask?
}

extension APIClient {
    // MARK: - Async/Await Network Request

    /// Performs a network request using async/await.
    ///
    /// Cancelling the calling task cancels the underlying `URLSessionTask` and any pending retry.
    /// - Parameter endpoint: The NetworkRouter defining the request.
    /// - Returns: The decoded response.
    /// - Throws: A `NetworkError` if the request fails.
    public func request<T: Codable & Sendable>(_ endpoint: any NetworkRouter)
        async throws -> T
    {
        let urlRequest = try makeURLRequest(endpoint)
        return try await withRetry(urlRequest) { request in
            try await self.performDataRequest(request)
        }
    }

    /// One async data request attempt.
    private func performDataRequest<T: Decodable>(_ urlRequest: URLRequest) async throws -> T {
        URLSessionLogger.shared.logRequest(urlRequest, logLevel: logLevel)
        let session = sharedSession()
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return try validateAndDecode(data, response)
        } catch let error as NetworkError {
            throw error
        } catch {
            URLSessionLogger.shared.logResponse(nil, data: nil, error: error, logLevel: logLevel)
            throw mapErrorToNetworkError(error)
        }
    }
}

extension APIClient {
    // MARK: - Async/Await Upload Request

    /// Performs a file upload request using async/await.
    /// - Parameters:
    ///   - endpoint: The NetworkRouter defining the request.
    ///   - withName: The name to be used for the file in the multipart form data.
    ///   - data: The file data to be uploaded.
    ///   - progressCompletion: A closure to handle upload progress updates.
    /// - Returns: The decoded response.
    /// - Throws: A NetworkError if the request fails.
    public func uploadRequest<T: Codable & Sendable>(
        _ endpoint: any NetworkRouter, withName: String, data: Data?,
        progressCompletion: @escaping ProgressHandler
    ) async throws -> T {
        let urlRequest = try makeURLRequest(endpoint)
        guard let file = data else {
            throw NetworkError.unknown
        }

        return try await withRetry(urlRequest) { request in
            URLSessionLogger.shared.logRequest(request, logLevel: self.logLevel)
            let (uploadRequest, bodyData) = self.createBody(
                urlRequest: request, data: file, filename: withName)
            return try await self.performAsyncUpload(
                urlRequest: uploadRequest, bodyData: bodyData,
                progressCompletion: progressCompletion)
        }
    }

    /// Performs a multipart form data upload request using async/await.
    /// - Parameters:
    ///   - endpoint: The NetworkRouter defining the request.
    ///   - formFields: An array of multipart form fields (text values and/or files).
    ///   - progressCompletion: A closure to handle upload progress updates.
    /// - Returns: The decoded response.
    /// - Throws: A NetworkError if the request fails.
    public func uploadRequest<T: Codable & Sendable>(
        _ endpoint: any NetworkRouter, formFields: [MultipartFormField],
        progressCompletion: @escaping ProgressHandler
    ) async throws -> T {
        let urlRequest = try makeURLRequest(endpoint)

        return try await withRetry(urlRequest) { request in
            URLSessionLogger.shared.logRequest(request, logLevel: self.logLevel)
            let (uploadRequest, bodyData) = self.createMultipartBody(
                urlRequest: request, formFields: formFields)
            return try await self.performAsyncUpload(
                urlRequest: uploadRequest, bodyData: bodyData,
                progressCompletion: progressCompletion)
        }
    }

    /// One async upload attempt.
    private func performAsyncUpload<T: Decodable>(
        urlRequest: URLRequest, bodyData: Data,
        progressCompletion: @escaping ProgressHandler
    ) async throws -> T {
        let ownsSession = configurationDelegate == nil
        let session = uploadSession(ownsSession: ownsSession, progressCompletion: progressCompletion)
        defer {
            if ownsSession { releaseRequestSession(session) }
        }

        do {
            let (data, response) = try await session.upload(for: urlRequest, from: bodyData)
            return try validateAndDecode(data, response)
        } catch let error as NetworkError {
            throw error
        } catch {
            URLSessionLogger.shared.logResponse(nil, data: nil, error: error, logLevel: logLevel)
            throw mapErrorToNetworkError(error)
        }
    }
}

// MARK: - APIClient+CombineStreamRequest

extension APIClient {
    // MARK: - Combine Stream Request

    /// Performs a streaming network request using Combine.
    /// - Parameter endpoint: The NetworkRouter defining the request.
    /// - Returns: A publisher that emits decoded responses as they arrive or an error.
    public func streamRequest<T: Codable & Sendable>(_ endpoint: any NetworkRouter)
        -> AnyPublisher<T, NetworkError>
    {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(endpoint)
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }

        return makeStreamRequest(urlRequest: urlRequest)
    }

    /// Internal method to make the actual streaming network request.
    private func makeStreamRequest<T: Codable & Sendable>(urlRequest: URLRequest)
        -> AnyPublisher<T, NetworkError>
    {
        let sessionDelegate = StreamingSessionDelegate<T>()
        sessionDelegate.logLevel = logLevel

        let session: URLSession
        if configurationDelegate == nil {
            let ownSession = requestSession(delegate: sessionDelegate)
            sessionDelegate.onFinish = { [weak self] in
                self?.releaseRequestSession(ownSession)
            }
            session = ownSession
        } else {
            session = sharedSession()
        }

        let task = sessionDelegate.startRequest(session: session, urlRequest: urlRequest)

        return sessionDelegate.subject
            .handleEvents(receiveCancel: { task.cancel() })
            .mapError { [weak self] error in
                self?.mapErrorToNetworkError(error) ?? .unknown
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - StreamingSessionDelegate

private class StreamingSessionDelegate<T: Codable>: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let subject = PassthroughSubject<T, Error>()
    private let queue = DispatchQueue(label: "com.simorgh.streamingSessionDelegate")
    private var _dataBuffer = Data()
    private var _logLevel: LogLevel = .none

    /// Called once when the task completes, so the owner can release the session.
    var onFinish: (@Sendable () -> Void)?

    var logLevel: LogLevel {
        get { queue.sync { _logLevel } }
        set { queue.sync { _logLevel = newValue } }
    }

    func startRequest(session: URLSession, urlRequest: URLRequest) -> URLSessionDataTask {
        URLSessionLogger.shared.logRequest(urlRequest, logLevel: logLevel)
        let task = session.dataTask(with: urlRequest)
        task.resume()
        return task
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let logLevel = self.logLevel
        queue.sync {
            _dataBuffer.append(data)
            while let range = _dataBuffer.range(of: Data("\n".utf8)) {
                let lineData = _dataBuffer.subdata(
                    in: _dataBuffer.startIndex..<range.lowerBound)
                _dataBuffer.removeSubrange(_dataBuffer.startIndex..<range.upperBound)

                do {
                    let decodedObject = try JSONDecoder().decode(T.self, from: lineData)
                    if let text = String(data: lineData, encoding: .utf8) {
                        URLSessionLogger.shared.logStreamChunk(content: text, url: dataTask.originalRequest?.url, logLevel: logLevel)
                    }
                    subject.send(decodedObject)
                } catch {
                    subject.send(completion: .failure(error))
                    dataTask.cancel()
                    return
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer { onFinish?() }
        if let error = error {
            URLSessionLogger.shared.logResponse(
                nil, data: nil, error: error, logLevel: logLevel)
            subject.send(completion: .failure(error))
        } else {
            // If there's any data left in buffer after the stream ends
            queue.sync {
                if !_dataBuffer.isEmpty {
                    do {
                        let decodedObject = try JSONDecoder().decode(
                            T.self, from: _dataBuffer)
                        subject.send(decodedObject)
                    } catch {
                        subject.send(completion: .failure(error))
                        return
                    }
                }
            }
            subject.send(completion: .finished)
        }
    }
}

// MARK: - APIClient+ErrorHandling

extension APIClient {
    // MARK: - Error Handling

    /// Maps a general Error to a NetworkError.
    private func mapErrorToNetworkError(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError {
            return networkError
        }
        switch error {
        case is CancellationError:
            return .urlError(URLError(.cancelled))
        case let urlError as URLError:
            return .urlError(urlError)
        case let decodingError as DecodingError:
            return .decodingError(decodingError)
        default:
            return .responseError(error)
        }
    }
}

// MARK: - APIClient+AsyncStreamRequest

extension APIClient {
    // MARK: - Async/Await Stream Request

    /// Performs a streaming network request using async/await.
    /// - Parameter endpoint: The NetworkRouter defining the request.
    /// - Returns: An AsyncThrowingStream that yields decoded responses as they arrive.
    @available(iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public func asyncStreamRequest<T: Codable & Sendable>(_ endpoint: any NetworkRouter)
        -> AsyncThrowingStream<T, Error>
    {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(endpoint)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        return makeAsyncStreamRequest(urlRequest: urlRequest)
    }

    /// Internal method to make the actual async streaming network request.
    @available(iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    private func makeAsyncStreamRequest<T: Codable & Sendable>(urlRequest: URLRequest)
        -> AsyncThrowingStream<T, Error>
    {
        return AsyncThrowingStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish(throwing: NetworkError.unknown)
                return
            }

            let session = self.sharedSession()
            URLSessionLogger.shared.logRequest(urlRequest, logLevel: self.logLevel)

            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(
                        for: urlRequest)
                    URLSessionLogger.shared.logResponse(
                        response, data: nil, error: nil, logLevel: self.logLevel
                    )

                    var iterator = bytes.makeAsyncIterator()
                    var dataBuffer = Data()

                    while let chunk = try await iterator.next() {
                        dataBuffer.append(chunk)

                        while let range = dataBuffer.range(of: Data("\n".utf8))
                        {
                            let lineData = dataBuffer.subdata(
                                in: dataBuffer.startIndex..<range.lowerBound)
                            dataBuffer.removeSubrange(
                                dataBuffer.startIndex..<range.upperBound)

                            do {
                                let decoder = JSONDecoder()
                                let decodedObject = try decoder.decode(
                                    T.self, from: lineData)
                                if let text = String(data: lineData, encoding: .utf8) {
                                    URLSessionLogger.shared.logStreamChunk(content: text, url: urlRequest.url, logLevel: self.logLevel)
                                }
                                continuation.yield(decodedObject)
                            } catch {
                                // Handle decoding error for this chunk
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                    }

                    // If there's any data left in buffer after the stream ends
                    if !dataBuffer.isEmpty {
                        do {
                            let decoder = JSONDecoder()
                            let decodedObject = try decoder.decode(
                                T.self, from: dataBuffer)
                            continuation.yield(decodedObject)
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }

                    continuation.finish()
                } catch {
                    URLSessionLogger.shared.logResponse(
                        nil, data: nil, error: error, logLevel: self.logLevel)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

extension APIClient {
    // MARK: - Helper Methods

    /// Creates a WebSocket connection from a `WebSocketRouter`.
    ///
    /// The returned `WebSocketConnection` owns its own `URLSession` (using the same
    /// `URLSessionConfiguration` as this client) so that invalidating the connection
    /// does not affect any HTTP requests in flight. Call `connect()` on the returned
    /// value, then consume `events()` or `messages(of:)`.
    public func webSocketConnection(
        _ endpoint: any WebSocketRouter,
        options: WebSocketOptions = WebSocketOptions()
    ) throws -> WebSocketConnection {
        let request = try endpoint.asURLRequest()

        return WebSocketConnection(
            request: request,
            configuration: configuration,
            protocols: endpoint.protocols,
            options: options,
            logLevel: logLevel
        )
    }

    /// Updates the client's URLSession configuration and optional delegate in a thread-safe manner.
    ///
    /// The next request builds a fresh shared session with the new settings.
    /// - Parameters:
    ///   - configuration: The new URLSessionConfiguration to apply. Pass `nil` to revert to default.
    ///   - delegate: An optional URLSessionDelegate to use for newly created sessions.
    ///   - invalidateExistingSessions: If true, cancels every in-flight request. If false,
    ///     in-flight requests finish on the old session. Defaults to `true`.
    public func updateConfiguration(
        _ configuration: URLSessionConfiguration?,
        delegate: URLSessionDelegate? = nil,
        invalidateExistingSessions: Bool = true
    ) {
        apiQueue.sync {
            self._configuration = configuration
            if let delegate = delegate {
                self._configurationDelegate = delegate
            }
            self.resetSessionsLocked(cancelAll: invalidateExistingSessions)
        }
    }

    /// Updates the default cache strategy used for requests that don't specify a cache policy.
    /// In-flight requests finish on the old session; the next request uses the new strategy.
    /// - Parameter strategy: The new cache strategy to apply.
    public func updateDefaultCacheStrategy(_ strategy: CacheStrategy) {
        apiQueue.sync {
            self._defaultCacheStrategy = strategy
            self.resetSessionsLocked(cancelAll: false)
        }
    }

    /// Updates the cache configuration. The next request builds a session with a URLCache from this configuration.
    /// - Parameters:
    ///   - configuration: The cache configuration to use. Pass `nil` to remove a custom cache.
    ///   - invalidateExistingSessions: If true, cancels every in-flight request. Defaults to `false`.
    public func updateCacheConfiguration(_ configuration: CacheConfiguration?, invalidateExistingSessions: Bool = false) {
        apiQueue.sync {
            self._cacheConfiguration = configuration
            self.resetSessionsLocked(cancelAll: invalidateExistingSessions)
        }
    }


    /// Creates the body for a single-file multipart form data request.
    private func createBody(
        urlRequest: URLRequest, data: Data,
        filename: String
    ) -> (URLRequest, Data) {
        var newUrlRequest = urlRequest
        let boundary = "Boundary-\(UUID().uuidString)"
        let mime = MimeTypeDetector.detectMimeType(from: data)
        let mimeType = mime?.mime ?? "application/octet-stream"
        newUrlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename).\(mime?.ext ?? "")\"\r\n"
        )
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")

        return (newUrlRequest, body)
    }

    /// Creates the body for a multipart form data request from an array of form fields.
    private func createMultipartBody(
        urlRequest: URLRequest, formFields: [MultipartFormField]
    ) -> (URLRequest, Data) {
        var newUrlRequest = urlRequest
        let boundary = "Boundary-\(UUID().uuidString)"
        newUrlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")

        var body = Data()

        for field in formFields {
            switch field {
            case .text(let name, let value):
                body.appendString("--\(boundary)\r\n")
                body.appendString(
                    "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                body.appendString("\(value)\r\n")

            case .file(let name, let data, let fileName, let mimeType):
                let resolvedMimeType = mimeType
                    ?? MimeTypeDetector.detectMimeType(from: data)?.mime
                    ?? "application/octet-stream"
                body.appendString("--\(boundary)\r\n")
                body.appendString(
                    "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
                body.appendString("Content-Type: \(resolvedMimeType)\r\n\r\n")
                body.append(data)
                body.appendString("\r\n")
            }
        }

        body.appendString("--\(boundary)--\r\n")

        return (newUrlRequest, body)
    }
}

// MARK: - Session Management

extension APIClient {
    /// Cancels all ongoing network requests, including pending retries' current attempts.
    public func cancelAllRequests() {
        apiQueue.sync {
            resetSessionsLocked(cancelAll: true)
        }
    }
}

// MARK: - APIClient+Subscription

extension APIClient {

    // MARK: Explicit lifecycle

    /// Creates a `SubscriptionConnection` for the given `SubscriptionRouter`.
    ///
    /// The returned object gives you explicit control over when to connect, disconnect,
    /// and reconnect. Call `events()` or `publisher()` **before** calling `connect()`
    /// so the initial `.connected` event (which sends the subscribe message) is not missed.
    ///
    /// ```swift
    /// let sub = try apiClient.subscription(MySubscription())
    /// Task { for try await event in sub.events() { ... } }
    /// sub.connect()
    /// // later:
    /// await sub.disconnect()
    /// ```
    public func subscription<R: SubscriptionRouter>(
        _ router: R,
        options: WebSocketOptions = WebSocketOptions(),
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> SubscriptionConnection<R> {
        let ws = try webSocketConnection(router, options: options)
        return SubscriptionConnection(wsConnection: ws, router: router, decoder: decoder, logLevel: logLevel)
    }

    // MARK: Inline — Async/Await

    /// Connects, subscribes, and returns an `AsyncThrowingStream` of typed events.
    ///
    /// The entire lifecycle (connect → subscribe → receive → unsubscribe → close) is
    /// managed internally. Cancelling the `Task` that owns the `for try await` loop
    /// sends the unsubscribe message and closes the connection automatically.
    ///
    /// ```swift
    /// for try await trade in apiClient.subscribe(TradeSubscription(symbol: "btcusdt"),
    ///     options: WebSocketOptions(reconnectPolicy: WebSocketReconnectPolicy(maximumAttempts: 3))
    /// ) {
    ///     print(trade)
    /// }
    /// ```
    public func subscribe<R: SubscriptionRouter>(
        _ router: R,
        options: WebSocketOptions = WebSocketOptions(),
        decoder: JSONDecoder = JSONDecoder()
    ) -> AsyncThrowingStream<R.Event, Error> {
        AsyncThrowingStream { continuation in
            do {
                let sub = try subscription(router, options: options, decoder: decoder)
                let stream = sub.events()

                let task = Task {
                    sub.connect()
                    do {
                        for try await event in stream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                    // Retain sub until the termination handler fires so disconnect() can run
                    Task { [sub] in await sub.disconnect() }
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: Inline — Combine

    /// Connects, subscribes, and returns a Combine publisher of typed events.
    ///
    /// The connection is kept alive for the lifetime of the subscription. Cancelling
    /// the `AnyCancellable` sends the unsubscribe message and closes the connection.
    ///
    /// ```swift
    /// apiClient.subscribe(TradeSubscription(symbol: "btcusdt"))
    ///     .sink(
    ///         receiveCompletion: { print($0) },
    ///         receiveValue:      { print($0) }
    ///     )
    ///     .store(in: &cancellables)
    /// ```
    public func subscribe<R: SubscriptionRouter>(
        _ router: R,
        options: WebSocketOptions = WebSocketOptions(),
        decoder: JSONDecoder = JSONDecoder()
    ) -> AnyPublisher<R.Event, NetworkError> {
        do {
            let sub = try subscription(router, options: options, decoder: decoder)
            sub.connect()
            // The publisher captures `sub` so it is retained for the subscription lifetime.
            return sub.publisher()
        } catch {
            let netError = error as? NetworkError ?? .responseError(error)
            return Fail(error: netError).eraseToAnyPublisher()
        }
    }
}
