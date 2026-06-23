import Foundation

/// Sliding-window speed and ETA calculator for a single download.
/// Keeps samples from the last `windowSeconds` and discards older ones.
final class SpeedSampler: @unchecked Sendable {
    private struct Sample {
        let bytes: Int64
        let timestamp: TimeInterval  // CFAbsoluteTimeGetCurrent()
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private let windowSeconds: TimeInterval

    init(windowSeconds: TimeInterval = 3) {
        self.windowSeconds = windowSeconds
    }

    /// Record `bytes` received at the current time.
    func record(bytes: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        samples.append(Sample(bytes: bytes, timestamp: now))
        prune(now: now)
        lock.unlock()
    }

    /// Bytes per second over the sliding window. Returns 0 if no recent samples.
    func speed() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        prune(now: now)
        let total = samples.reduce(Int64(0)) { $0 + $1.bytes }
        let duration = samples.isEmpty ? 0 : now - samples[0].timestamp
        lock.unlock()
        guard duration > 0 else { return 0 }
        return Double(total) / duration
    }

    /// Estimated seconds remaining. `nil` if speed is 0 or total is unknown.
    func eta(downloaded: Int64, total: Int64) -> TimeInterval? {
        guard total > 0, downloaded < total else { return nil }
        let s = speed()
        guard s > 0 else { return nil }
        return Double(total - downloaded) / s
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    private func prune(now: TimeInterval) {
        let cutoff = now - windowSeconds
        samples.removeAll { $0.timestamp < cutoff }
    }
}
