import Foundation

/// Pure evaluation of a finished upload task. Same gates as a normal request, plus a full-send check.
public enum UploadCompletion {
    public enum Outcome: Equatable, Sendable {
        case success(responseBody: Data)
        case failure(UploadFailure)
    }

    /// - A transport error fails first.
    /// - The whole request body must have been sent.
    /// - The status must be 2xx and the response body non-empty, except `204 No Content`
    ///   (for example a tus `PATCH`), which succeeds with an empty body.
    public static func evaluate(
        transportError: Bool,
        transportDescription: String = "",
        httpStatusCode: Int?,
        responseBody: Data?,
        bytesSent: Int64,
        bytesExpected: Int64
    ) -> Outcome {
        if transportError { return .failure(.transport(transportDescription)) }
        if bytesExpected > 0, bytesSent < bytesExpected {
            return .failure(.incompleteSend(sent: bytesSent, expected: bytesExpected))
        }
        guard let httpStatusCode else { return .failure(.missingResponse) }
        guard (200..<300).contains(httpStatusCode) else {
            return .failure(.httpStatus(httpStatusCode))
        }
        if httpStatusCode == 204 {
            return .success(responseBody: responseBody ?? Data())
        }
        guard let responseBody, !responseBody.isEmpty else {
            return .failure(.missingResponse)
        }
        return .success(responseBody: responseBody)
    }
}
