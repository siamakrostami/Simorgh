import Combine
import Foundation

/// Lets a Combine `Future` promise be resolved from a `@Sendable` completion handler.
///
/// `Future` already serializes resolution internally and ignores every call after the
/// first, so no extra locking is needed here — the wrapper only satisfies the compiler.
struct SendablePromise<T>: @unchecked Sendable {
    private let promise: (Result<T, NetworkError>) -> Void

    init(_ promise: @escaping (Result<T, NetworkError>) -> Void) {
        self.promise = promise
    }

    func resolve(_ result: Result<T, NetworkError>) {
        promise(result)
    }
}
