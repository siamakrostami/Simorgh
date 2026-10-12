import Foundation

/// Streams a multipart/form-data body to disk, so large files are never held in memory.
public enum MultipartFileBodyWriter {
    /// Writes the body to `destination` (replacing an existing file) and returns the boundary token.
    /// Set `Content-Type: multipart/form-data; boundary=<token>` on the request.
    @discardableResult
    public static func write(
        textParts: [UploadTextPart],
        fileParts: [UploadFilePart],
        to destination: URL
    ) throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        for part in textParts {
            try writeUTF8("--\(boundary)\r\n", to: output)
            try writeUTF8("Content-Disposition: form-data; name=\"\(part.name)\"\r\n\r\n", to: output)
            try writeUTF8("\(part.value)\r\n", to: output)
        }

        for part in fileParts {
            try writeUTF8("--\(boundary)\r\n", to: output)
            try writeUTF8(
                "Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(part.fileName)\"\r\n",
                to: output
            )
            try writeUTF8("Content-Type: \(part.mimeType)\r\n\r\n", to: output)
            try streamFile(at: part.fileURL, to: output)
            try writeUTF8("\r\n", to: output)
        }

        try writeUTF8("--\(boundary)--\r\n", to: output)
        return boundary
    }

    private static func writeUTF8(_ string: String, to output: FileHandle) throws {
        guard let data = string.data(using: .utf8) else {
            throw UploadFailure.multipartEncodingFailed
        }
        try output.write(contentsOf: data)
    }

    private static func streamFile(at source: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
    }
}
