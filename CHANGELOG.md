# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [3.0.0] - 2026-11-23

### Fixed
- **Session leak:** `APIClient` created a new `URLSession` for every request and never
  invalidated it, so sessions and their delegates piled up for the life of the client.
  All requests now share one long-lived session, which also brings back connection, TLS
  and HTTP/2 reuse. Uploads with progress and Combine streams get a short-lived session
  that is invalidated as soon as the task finishes.
- **Wrong request retried under concurrency:** retries went through a queue shared by the
  whole client and picked its last entry, so when two requests failed at once, one could
  be retried with the other's `URLRequest`. Each retry now uses only its own request.
- **async/await cancellation:** cancelling the calling `Task` now cancels the underlying
  `URLSessionTask` and any pending retry. Before, requests ran in a detached task and
  kept going after cancellation.
- **Upload retries:** a retried upload was sent as a plain data request with no body, and
  transport errors and non-2xx responses on uploads were never retried. Retries now
  rebuild the multipart body and go through the same policy as other requests.
- Combine uploads and streams now cancel their `URLSessionTask` when the subscriber cancels.
- A Combine stream now cancels its task when a line fails to decode, instead of leaving
  it running after the publisher has failed.
- `APIClient` no longer mutates the `URLSessionConfiguration` you pass in.
- The example app's local package path no longer depends on the name of the checkout folder.

### Changed (breaking)
- `NetworkError` has a new case, `.invalidRequest(Error)`. Endpoints whose
  `asURLRequest()` throws (bad URL, encoding failure) now surface that error instead of
  `.unknown`. Exhaustive `switch` statements over `NetworkError` need a new case.
- `DefaultRetryHandler` now retries only transient failures of idempotent requests:
  - methods `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS` and `TRACE`
  - status codes 408, 429, 500, 502, 503 and 504
  - transient `URLError`s

  It uses exponential backoff with jitter (0.5s base, 30s cap). Before, it retried every
  error, including `POST` and 4xx responses, immediately. To restore the old timing pass
  `baseDelay: 0`, and to opt methods back in use `retryableMethods`.
- `RetryHandler` has a new requirement, `retryDelay(for:error:attempt:)`, with a default
  implementation that returns `0`.
- `updateDefaultCacheStrategy(_:)` and `updateCacheConfiguration(_:)` without
  invalidation let in-flight requests finish, and apply to the next request.

### Added
- `NetworkError.isCancellation`.
- Default implementations of `RetryHandler.shouldRetryAsync` and
  `modifyRequestForRetryAsync` that call the synchronous versions, so custom handlers only
  need `numberOfRetries`, `shouldRetry` and `modifyRequestForRetry`.
- `DefaultRetryHandler` options: `retryableMethods`, `retryableStatusCodes`, `baseDelay`,
  `maximumDelay` and `jitter`.
- `APIClient` tests built on a `URLProtocol` stub. They cover session reuse, concurrent
  retries, cancellation, upload retries and error mapping.
- GitHub Actions CI: SwiftPM build and test on macOS, builds for iOS, tvOS and watchOS,
  tests on the iOS Simulator, and an example app build. A manual release workflow tests
  the chosen commit, then creates the tag and the GitHub release from this changelog.

### Docs
- The README install line pointed at `from: "1.0.0"`, which resolves to the old
  1.x `SRNetworkManager` releases. It now says `from: "3.0.0"`.
- Removed the stale branch comparison table and the broken `.github/ABOUT.md` link.
- Documented the retry policy, backoff and session reuse.

## [2.2.2]

Last release before this changelog was started. See the
[GitHub releases](https://github.com/siamakrostami/Simorgh/releases) for earlier history.
