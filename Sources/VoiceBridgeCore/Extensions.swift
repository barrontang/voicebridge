import Foundation

// Small helpers used across the core.

public extension URL {
       /// Returns a copy flagged as a directory (handy for model roots).
    func appendingIsDirectory() -> URL {
        URL(fileURLWithPath: self.path, isDirectory: true)
        }
}

public extension String {
        /// The path component with its file extension removed, e.g.
        /// "en_US-lessac-medium.onnx" → "en_US-lessac-medium".
    var lastPathComponentWithoutSuffix: String {
        (self as NSString)
             .lastPathComponent
             .split(separator: ".")
             .dropLast()
             .joined(separator: ".")
         }
}
