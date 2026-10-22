import Foundation

/// Writes a raw upload body (the bytes of a file from an offset, optionally limited to a length) to disk
/// for `uploadTask(with:fromFile:)`.
public enum RawFileBodyWriter {
    /// Replaces `destination` with the bytes of `body.fileURL` from `body.offset`, at most `body.length` bytes.
    /// The whole file (offset 0, no limit) uses a file copy (an APFS clone, so no extra disk space or time).
    public static func write(_ body: UploadRawBody, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let input = try FileHandle(forReadingFrom: body.fileURL)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard UInt64(body.offset) <= size else { throw UploadFailure.invalidRequest }
        let remaining = size - UInt64(body.offset)
        let bytesToWrite = body.length.map { min(UInt64($0), remaining) } ?? remaining

        if body.offset == 0, bytesToWrite == size {
            try? input.close()
            try FileManager.default.copyItem(at: body.fileURL, to: destination)
            return
        }
        try input.seek(toOffset: UInt64(body.offset))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var left = bytesToWrite
        while left > 0 {
            let chunk = try input.read(upToCount: Int(min(left, 65_536))) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            left -= UInt64(chunk.count)
        }
    }
}
