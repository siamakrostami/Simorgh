import Foundation

/// Throwing `FileHandle` I/O on every supported OS version.
///
/// `read(upToCount:)`, `write(contentsOf:)` and `seekToEnd()` need iOS/tvOS 13.4. On older
/// systems this falls back to the legacy calls, which raise an Objective-C exception
/// instead of throwing on I/O failure.
extension FileHandle {
    func compatRead(upToCount count: Int) throws -> Data {
        if #available(iOS 13.4, tvOS 13.4, macOS 10.15.4, watchOS 6.2, *) {
            return try read(upToCount: count) ?? Data()
        }
        return readData(ofLength: count)
    }

    func compatWrite(_ data: Data) throws {
        if #available(iOS 13.4, tvOS 13.4, macOS 10.15.4, watchOS 6.2, *) {
            try write(contentsOf: data)
        } else {
            write(data)
        }
    }

    func compatSeekToEnd() throws -> UInt64 {
        if #available(iOS 13.4, tvOS 13.4, macOS 10.15.4, watchOS 6.2, *) {
            return try seekToEnd()
        }
        return seekToEndOfFile()
    }
}
