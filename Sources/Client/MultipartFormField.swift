import Foundation

/// Represents a single field in a multipart form data request.
public enum MultipartFormField: Sendable {
    /// A text form field (e.g., `--form 'key=value'`).
    case text(name: String, value: String)

    /// A file form field (e.g., `--form 'file=@/path/to/file'`).
    /// - Parameters:
    ///   - name: The field name (e.g., "file").
    ///   - data: The file data.
    ///   - fileName: The file name including extension (e.g., "photo.jpg").
    ///   - mimeType: Optional MIME type. If nil, it will be auto-detected from the data.
    case file(name: String, data: Data, fileName: String, mimeType: String? = nil)
}
