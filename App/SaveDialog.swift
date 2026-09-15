// SaveDialog.swift — thin AppKit wrappers for "Save…" panels.
//
// The GUI target links AppKit, so we can present a native save panel and hand
// back the chosen URL. Returning nil means "user cancelled or no file chosen".
import AppKit
import Foundation

public enum SaveDialog {

    /// Present a save panel and return the chosen URL, or nil if cancelled.
     /// - Parameters:
    ///     - data:        the bytes to write.
    ///       - defaultName: the filename (with extension) shown by default.
    ///       - directory: optional starting directory (a file's dir, etc.).
      @MainActor
    public static func save(_ data: Data,
                             defaultName: String,
                             directory: URL? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
            if let directory {
            // Use the parent directory (or current CWD) as the "where" hint.
             panel.directoryURL = directory
             }

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
             }
        do {
            try data.write(to: url, options: .atomic)
              } catch {
            NSSound.beep()
            return nil
            }
        return url
      }

      /// Convenience for "Save text as .txt".
   @MainActor
    public static func saveText(_ text: String,
                                 defaultName: String,
                                 directory: URL? = nil) -> URL? {
        save(Data(text.utf8), defaultName: defaultName, directory: directory)
       }
}
