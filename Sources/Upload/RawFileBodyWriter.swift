import Foundation

/// Writes a raw upload body (the bytes of a file from an offset) to disk for `uploadTask(with:fromFile:)`.
public enum RawFileBodyWriter {
    /// Replaces `destination` with the bytes of `body.fileURL` starting at `body.offset`.
    /// Offset 0 uses a file copy (an APFS clone, so no extra disk space or time for large files).
    public static func write(_ body: UploadRawBody, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard body.offset > 0 else {
            try FileManager.default.copyItem(at: body.fileURL, to: destination)
            return
        }
        let input = try FileHandle(forReadingFrom: body.fileURL)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard UInt64(body.offset) <= size else { throw UploadFailure.invalidRequest }
        try input.seek(toOffset: UInt64(body.offset))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while true {
            let chunk = try input.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
    }
}
