import Foundation
import os

/// Unified, structured logging via `os.Logger` (Finding 5).
///
/// Before this, the core scattered `print(...)` across `TTSManager`, `Playback`,
/// etc. That is the *wrong* tool: `print` is unbuffered to a TTY but buffered to a
/// file, is not thread-safe under contention (interleaved garbage under load —
/// exactly when logs matter most), and has no per-subsystem or per-category
/// filtering. `os.Logger` is fast, structured, sandbox-safe, and free on macOS.
///
/// Rule of thumb enforced by CI: **nothing in `Core/` may write to stdout except
/// the CLI's explicit user-facing output path.** Diagnostic output goes here.
/// `grep -rn "print(" Sources/VoiceBridgeCore` must return nothing.
public enum VBLog {
    /// Reverse-DNS subsystem shared by every category.
    public static let subsystem = "com.yourorg.voicebridge"

    public static let engine   = Logger(subsystem: subsystem, category: "engine")
    public static let tts      = Logger(subsystem: subsystem, category: "tts")
    public static let capture  = Logger(subsystem: subsystem, category: "capture")
    public static let models   = Logger(subsystem: subsystem, category: "models")
    public static let process  = Logger(subsystem: subsystem, category: "process")
}
