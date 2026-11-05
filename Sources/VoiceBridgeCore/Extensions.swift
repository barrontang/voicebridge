import Foundation

// Small helpers used across the core.

extension URL {
    /// Returns a copy flagged as a directory (handy for model roots).
    public func appendingIsDirectory() -> URL {
        URL(fileURLWithPath: self.path, isDirectory: true)
    }
}

extension String {
    /// The path component with its file extension removed, e.g.
    /// "en_US-lessac-medium.onnx" → "en_US-lessac-medium".
    public var lastPathComponentWithoutSuffix: String {
        (self as NSString)
            .lastPathComponent
            .split(separator: ".")
            .dropLast()
            .joined(separator: ".")
    }
}
