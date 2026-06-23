import Foundation

// MARK: - Log Level

/// An enum representing different levels of logging for network requests and responses.
///
/// ## Overview
/// `LogLevel` provides configurable logging levels to control the amount of detail
/// logged during network operations. This allows developers to balance debugging
/// information with performance and privacy concerns.
///
/// ## Log Levels
///
/// ### none
/// No logging is performed. This is the most performant option and should be used
/// in production environments.
///
/// ### minimal
/// Logs only the essential information: HTTP method and URL. This provides basic
/// request tracking without exposing sensitive data.
///
/// ### standard
/// Logs headers and status codes in addition to method and URL. This level is
/// useful for debugging network issues while maintaining reasonable privacy.
///
/// ### verbose
/// Logs everything including request and response bodies. This level provides
/// maximum debugging information but may expose sensitive data and impact performance.
///
/// ## Usage Examples
///
/// ### Production Configuration
/// ```swift
/// let client = APIClient(logLevel: .none)
/// // No logging in production for performance and privacy
/// ```
///
/// ### Development Configuration
/// ```swift
/// let client = APIClient(logLevel: .standard)
/// // Log headers and status codes for debugging
/// ```
///
/// ### Debug Configuration
/// ```swift
/// let client = APIClient(logLevel: .verbose)
/// // Log everything for detailed debugging
/// ```
///
/// ### Conditional Logging
/// ```swift
/// #if DEBUG
/// let logLevel: LogLevel = .verbose
/// #else
/// let logLevel: LogLevel = .none
/// #endif
/// 
/// let client = APIClient(logLevel: logLevel)
/// ```
///
/// ## Security Considerations
/// - **Production**: Use `.none` to avoid logging sensitive data
/// - **Headers**: Be aware that headers may contain authentication tokens
/// - **Bodies**: Request/response bodies may contain sensitive information
/// - **URLs**: URLs may contain query parameters with sensitive data
///
/// ## Performance Impact
/// - **none**: No performance impact
/// - **minimal**: Minimal performance impact
/// - **standard**: Moderate performance impact
/// - **verbose**: Significant performance impact due to string operations
public enum LogLevel: Sendable {
    /// No logging performed
    case none
    /// Only log the URL and method
    case minimal
    /// Log headers and status code
    case standard
    /// Log everything, including the body
    case verbose
}

/// A thread-safe logger for URL session requests and responses.
///
/// ## Overview
/// `URLSessionLogger` provides comprehensive logging capabilities for network
/// operations, including requests, responses, and errors. It uses a singleton
/// pattern and thread-safe operations to ensure reliable logging across the app.
///
/// ## Key Features
/// - **Thread Safety**: All logging operations are synchronized
/// - **Configurable Levels**: Different levels of detail based on LogLevel
/// - **Rich Formatting**: Emoji-based visual indicators for easy scanning
/// - **Error Handling**: Comprehensive error logging
/// - **Performance**: Asynchronous logging to avoid blocking network operations
///
/// ## Usage Examples
///
/// ### Basic Logging
/// ```swift
/// let logger = URLSessionLogger.shared
/// logger.logRequest(request, logLevel: .standard)
/// logger.logResponse(response, data: data, error: nil, logLevel: .standard)
/// ```
///
/// ### Conditional Logging
/// ```swift
/// let logLevel: LogLevel = isDebugMode ? .verbose : .none
/// logger.logRequest(request, logLevel: logLevel)
/// ```
///
/// ### Error Logging
/// ```swift
/// if let error = networkError {
///     logger.logResponse(nil, data: nil, error: error, logLevel: .standard)
/// }
/// ```
///
/// ## Log Output Examples
///
/// ### Request Log (Standard Level)
/// ```
/// 🚀🚀🚀 REQUEST 🚀🚀🚀
/// 🔈 POST https://api.example.com/users
/// Headers:
/// 💡 Content-Type: application/json
/// 💡 Authorization: Bearer token123
/// 🔼🔼🔼 END REQUEST 🔼🔼🔼
/// ```
///
/// ### Success Response (Standard Level)
/// ```
/// ✅✅✅ SUCCESS RESPONSE ✅✅✅
/// 🔈 https://api.example.com/users
/// 🔈 Status code: 201
/// Headers:
/// 💡 Content-Type: application/json
/// 💡 Location: /users/123
/// 🔼🔼🔼 END RESPONSE 🔼🔼🔼
/// ```
///
/// ### Error Response (Standard Level)
/// ```
/// 🛑🛑🛑 REQUEST ERROR 🛑🛑🛑
/// 🔈 https://api.example.com/users
/// 🔈 Status code: 400
/// Headers:
/// 💡 Content-Type: application/json
/// 🔼🔼🔼 END RESPONSE 🔼🔼🔼
/// ```
///
/// ### Verbose Logging (Includes Bodies)
/// ```
/// 🚀🚀🚀 REQUEST 🚀🚀🚀
/// 🔈 POST https://api.example.com/users
/// Headers:
/// 💡 Content-Type: application/json
/// Body: {
///   {"name":"John","email":"john@example.com"}
/// }
/// 🔼🔼🔼 END REQUEST 🔼🔼🔼
/// ```
///
/// ## Thread Safety
/// All logging operations are performed on a dedicated serial queue to ensure
/// thread safety and prevent log interleaving from concurrent requests.
///
/// ## Performance Considerations
/// - **Asynchronous**: Logging is performed asynchronously to avoid blocking
/// - **String Operations**: Verbose logging involves string encoding operations
/// - **Memory Usage**: Large response bodies may impact memory usage
/// - **Queue Management**: Serial queue prevents log interleaving
///
/// ## Best Practices
/// - **Production**: Use `.none` level for maximum performance
/// - **Development**: Use `.standard` for balanced debugging
/// - **Debugging**: Use `.verbose` only when detailed analysis is needed
/// - **Privacy**: Be mindful of sensitive data in logs
/// - **Performance**: Monitor logging impact in high-traffic scenarios
public final class URLSessionLogger: Sendable {
    
    // MARK: Lifecycle
    
    /// Private initializer for singleton pattern
    private init() {}

    // MARK: Internal
    
    /// Shared singleton instance for global logging
    public static let shared = URLSessionLogger()
    
    /// Serial queue for synchronized logging operations
    private let logQueue = DispatchQueue(label: "com.urlsessionlogger.queue")

    /// Logs a URL request with the specified log level.
    ///
    /// This method logs request information including method, URL, headers, and
    /// optionally the request body based on the specified log level.
    ///
    /// ## Logged Information
    /// - **All Levels**: HTTP method and URL
    /// - **Standard/Verbose**: Request headers
    /// - **Verbose Only**: Request body (if present)
    ///
    /// - Parameters:
    ///   - request: The URLRequest to log
    ///   - logLevel: The desired log level (nil or .none for no logging)
    // MARK: - Download

    public func logDownload(event: String, url: URL?, detail: String? = nil, logLevel: LogLevel?) {
        guard let logLevel, logLevel != .none else { return }
        logQueue.async {
            print("\n⬇️⬇️⬇️ DOWNLOAD \(event) ⬇️⬇️⬇️")
            print("🔈 \(url?.absoluteString ?? "Unknown")")
            if logLevel != .minimal, let detail { print("💡 \(detail)") }
            print("🔼🔼🔼 END 🔼🔼🔼")
        }
    }

    public func logDownloadProgress(url: URL?, fraction: Double, speed: Double, eta: TimeInterval?, logLevel: LogLevel?) {
        guard logLevel == .verbose else { return }
        logQueue.async {
            let pct = String(format: "%.1f%%", fraction * 100)
            let kbps = String(format: "%.1f KB/s", speed / 1024)
            let etaStr = eta.map { String(format: "ETA %.0fs", $0) } ?? "ETA unknown"
            print("\n⬇️ DOWNLOAD PROGRESS \(pct) @ \(kbps)  \(etaStr)")
            print("🔈 \(url?.absoluteString ?? "Unknown")")
        }
    }

    // MARK: - HTTP Request / Response

    public func logRequest(_ request: URLRequest, logLevel: LogLevel?) {
        guard let logLevel = logLevel, logLevel != .none else { return }
        
        logQueue.async {
            print("\n🚀🚀🚀 REQUEST 🚀🚀🚀")
            print("🔈 \(request.httpMethod ?? "UNKNOWN") \(request.url?.absoluteString ?? "Invalid URL")")

            if logLevel != .minimal {
                print("Headers:")
                request.allHTTPHeaderFields?.forEach { print("💡 \($0.key): \($0.value)") }
            }

            if logLevel == .verbose, let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
                print("Body: {\n  \(bodyString)\n}")
            }

            print("🔼🔼🔼 END REQUEST 🔼🔼🔼")
        }
    }

    /// Logs a URL response with the specified log level.
    ///
    /// This method logs response information including status code, headers,
    /// response body, and any errors that occurred during the request.
    ///
    /// ## Logged Information
    /// - **All Levels**: Status code and URL
    /// - **Standard/Verbose**: Response headers
    /// - **Verbose Only**: Response body (if present)
    /// - **Errors**: Error information regardless of level
    ///
    /// - Parameters:
    ///   - response: The URLResponse to log (may be nil for errors)
    ///   - data: The response data (may be nil for errors)
    ///   - error: Any error that occurred during the request
    ///   - logLevel: The desired log level (nil or .none for no logging)
    public func logResponse(_ response: URLResponse?, data: Data?, error: Error?, logLevel: LogLevel?) {
        guard let logLevel = logLevel, logLevel != .none else { return }
        
        logQueue.async {
            if let httpResponse = response as? HTTPURLResponse {
                if 200 ..< 300 ~= httpResponse.statusCode {
                    print("\n✅✅✅ SUCCESS RESPONSE ✅✅✅")
                } else {
                    print("\n🛑🛑🛑 REQUEST ERROR 🛑🛑🛑")
                }
                
                print("🔈 \(httpResponse.url?.absoluteString ?? "Invalid URL")")
                print("🔈 Status code: \(httpResponse.statusCode)")
                
                if logLevel != .minimal {
                    print("Headers:")
                    httpResponse.allHeaderFields.forEach { print("💡 \($0.key): \($0.value)") }
                }

                if logLevel == .verbose, let data = data, let responseBody = String(data: data, encoding: .utf8) {
                    print("Body: {\n  \(responseBody)\n}")
                }

                print("🔼🔼🔼 END RESPONSE 🔼🔼🔼")

            } else if let error = error {
                print("\n🛑🛑🛑 REQUEST ERROR 🛑🛑🛑")
                print("🔈 \(error.localizedDescription)")
                print("🔼🔼🔼 END ERROR 🔼🔼🔼")
            }
        }
    }
}
