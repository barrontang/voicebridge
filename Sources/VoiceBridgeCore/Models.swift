import Foundation

// MARK: - Shared types

/// A tiered model for the STT stage.
///
/// On M4 Pro / 64GB unified memory `large-v3-turbo` is the sweet spot:
/// ~1.6 GB resident, ~8x faster than large-v3 at near-full accuracy.
/// `base`/`small` are kept for low-latency interactive dictation.
public enum SttModel: String, CaseIterable, Codable, Sendable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case largeV3Turbo = "large-v3-turbo"
    case largeV3 = "large-v3"

    /// Human readable label for UI pickers.
    public var label: String {
        switch self {
        case .tiny:         return "Tiny · fastest, low accuracy"
        case .base:         return "Base · ultra-fast, low accuracy"
        case .small:        return "Small · fast dictation"
        case .medium:       return "Medium · balanced accuracy"
        case .largeV3Turbo: return "Large-v3-turbo · best speed/accuracy (RECOMMENDED)"
        case .largeV3:      return "Large-v3 · maximum accuracy, slower"
        }
    }

    /// ggml filename on whisper.cpp / HuggingFace `ggerganov/whisper.cpp`.
    public var ggmlFilename: String {
        "ggml-\(self.rawValue).bin"
    }
}

/// A single transcription attempt and its metadata.
public struct Transcription: Sendable, Equatable {
    public let text: String
    public let language: String
    public let model: SttModel
    public let durationSeconds: Double
    public let realtimeFactor: Double // wallclock / audio length. <1 means faster than realtime

    public init(
        text: String,
        language: String,
        model: SttModel,
        durationSeconds: Double,
        realtimeFactor: Double
    ) {
        self.text = text
        self.language = language
        self.model = model
        self.durationSeconds = durationSeconds
        self.realtimeFactor = realtimeFactor
    }

    public var isMeaningful: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Errors

public enum VoiceError: LocalizedError, Sendable {
    case binaryNotFound(component: String, hint: String)
    case modelMissing(model: String, directory: String)
    case modelNotFound(name: String, directory: String)
    case processFailed(component: String, status: Int32, stderr: String)
    case processTimeout(component: String, seconds: TimeInterval)
    case audioDecodeFailed(url: String, reason: String)
    case permissionDenied(capability: String)
    case engineUnavailable(engine: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let c, let hint):
            return "\(c): binary not found. \(hint)"
        case .modelMissing(let m, let dir):
            return "Model '\(m)' is missing. Expected it at:\n  \(dir)"
        case .modelNotFound(let m, let dir):
            return "Model '\(m)' not found under \(dir)"
        case .processFailed(let c, let status, let stderr):
            return "\(c) exited with status \(status).\n\(stderr)"
        case .processTimeout(let c, let seconds):
            return "\(c) timed out after \(Int(seconds))s (terminated)."
        case .audioDecodeFailed(let url, let reason):
            return "Could not decode audio \(url): \(reason)"
        case .permissionDenied(let cap):
            return "Permission denied for \(cap). Grant it in System Settings › Privacy & Security."
        case .engineUnavailable(let e, let reason):
            return "TTS engine '\(e)' is unavailable: \(reason)"
        }
    }
}
