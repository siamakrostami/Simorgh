import Foundation

// MARK: - NetworkError

/// A comprehensive enum representing various types of network errors that can occur
/// during API requests and responses.
///
/// ## Overview
/// `NetworkError` provides a unified way to handle different types of network-related
/// errors, from basic network failures to custom server errors and decoding issues.
/// It conforms to `LocalizedError` to provide user-friendly error descriptions.
///
/// ## Error Types
///
/// ### Basic Errors
/// - **unknown**: Generic error when the specific error type cannot be determined
/// - **urlError(URLError)**: Wrapped URLError from URLSession operations
/// - **responseError(Error)**: Generic response-related errors
///
/// ### Data Processing Errors
/// - **decodingError(Error)**: Errors that occur during JSON decoding
///
/// ### Server Errors
/// - **customError(Int, Data)**: Custom server errors with status code and response data
///
/// ## Usage Examples
///
/// ### Error Handling in Combine
/// ```swift
/// client.request(endpoint)
///     .sink(
///         receiveCompletion: { completion in
///             if case .failure(let error) = completion {
///                 switch error {
///                 case .urlError(let urlError):
///                     print("Network error: \(urlError.localizedDescription)")
///                 case .decodingError(let decodingError):
///                     print("Decoding error: \(decodingError)")
///                 case .customError(let statusCode, let data):
///                     print("Server error: \(statusCode)")
///                 case .responseError(let error):
///                     print("Response error: \(error)")
///                 case .unknown:
///                     print("Unknown error occurred")
///                 }
///             }
///         },
///         receiveValue: { response in
///             // Handle successful response
///         }
///     )
///     .store(in: &cancellables)
/// ```
///
/// ### Error Handling in async/await
/// ```swift
/// do {
///     let response = try await client.request(endpoint)
///     // Handle successful response
/// } catch let error as NetworkError {
///     switch error {
///     case .urlError(let urlError):
///         // Handle network error
///     case .decodingError(let decodingError):
///         // Handle decoding error
///     case .customError(let statusCode, let data):
///         // Handle server error
///     case .responseError(let error):
///         // Handle response error
///     case .unknown:
///         // Handle unknown error
///     }
/// } catch {
///     // Handle other errors
/// }
/// ```
///
/// ### Custom Error Handling
/// ```swift
/// switch networkError {
/// case .customError(let statusCode, let data):
///     if statusCode == 401 {
///         // Handle unauthorized
///         handleUnauthorized()
///     } else if statusCode == 500 {
///         // Handle server error
///         handleServerError()
///     }
/// case .urlError(let urlError):
///     if urlError.code == .notConnectedToInternet {
///         // Handle no internet connection
///         showOfflineMessage()
///     }
/// default:
///     // Handle other errors
///     showGenericError()
/// }
/// ```
///
/// ## Localized Error Support
/// The enum conforms to `LocalizedError` to provide user-friendly error messages
/// that can be displayed to users in the appropriate language.
public enum NetworkError: Error, Sendable {
    case unknown
    case urlError(URLError)
    case decodingError(Error)
    case customError(Int, Data)
    case responseError(Error)
}

// MARK: LocalizedError

extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknown:
            return "An unknown network error occurred."
        case .urlError(let error):
            return error.localizedDescription
        case .decodingError(let error):
            return "Decoding failed: \(error.localizedDescription)"
        case .customError(let statusCode, _):
            return "Server returned status code \(statusCode)."
        case .responseError(let error):
            return error.localizedDescription
        }
    }

    /// The HTTP status code for `.customError`, or `nil` for other cases.
    public var statusCode: Int? {
        if case .customError(let code, _) = self { return code }
        return nil
    }

    /// The raw response data for `.customError`, or `nil` for other cases.
    public var responseData: Data? {
        if case .customError(_, let data) = self { return data }
        return nil
    }

    @available(*, deprecated, renamed: "localizedDescription")
    public var localizedErrorDescription: String? {
        return errorDescription
    }
}
