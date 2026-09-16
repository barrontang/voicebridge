import Foundation

// MARK: - Shared types

/// A tiered model for the STT stage.
///
/// On M4 Pro / 64GB unified memory `large-v3-turbo` is the sweet spot:
/// ~1.6 GB resident, ~8x faster than large-v3 at near-full accuracy.
/// `base`/`small` are kept for low-latency interactive dictation.
///
/// The enum is the *well-known subset*; new code should prefer
/// `SttModelDescriptor` so user/imported models are representable (Finding 7).
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
    public let realtimeFactor: Double   // wallclock / audio length; <1 means faster

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

    public var isMeaningful: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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
    // Missing 3: a precise, user-actionable disk-space message.
    case insufficientDiskSpace(needed: Int64, available: Int64, at: String)
    // Finding 8: discard a download whose checksum doesn't match.
    case checksumMismatch(url: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let c, let hint):
            return "\(c): binary not found. \(hint)"
        case .modelMissing(let m, let dir):
            return "Model '\(m)' is missing. Expected it at:\n   \(dir)"
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
        case .insufficientDiskSpace(let needed, let available, let at):
            let need = vbFormatBytes(needed)
            let have = vbFormatBytes(available)
            return "Not enough disk space for \(need) at \(at) "
                + "(only \(have) free). Free up space and retry."
        case .checksumMismatch(let url, let expected, let actual):
            return "Downloaded model failed checksum at \(url): "
                + "expected \(expected), got \(actual). The file was discarded."
        }
    }
}

/// Human-friendly byte count for error messages. File scope so the enum's
/// `errorDescription` can call it without a `self`-capture.
private func vbFormatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: n)
}

// MARK: - Model descriptors (Finding 7)

/// A user-extensible descriptor for an STT model.
///
/// `SttModel` was a fixed `enum`, which meant "add a model" = "change code +
/// ship a release": no user-supplied GGUF from Hugging Face, no fine-tunes, no
/// A/B of local models. The product's model catalog is fundamentally
/// *user-extensible*, so the right shape is a value type keyed by a stable
/// identifier whose `origin` names *where its bytes came from*.
///
/// The enum is retained as a thin, well-known subset (see
/// `SttModelCatalog.bundled`) so the picker UX doesn't regress; the descriptor is
/// the thing the scanner, downloader, and settings page should key off.
public struct SttModelDescriptor: Sendable, Codable, Hashable, Identifiable {

    /// Where a model's bytes came from.
    public enum Origin: Sendable, Codable, Hashable {
        case bundled
        case huggingFace(repo: String, file: String)
        case imported(bookmark: Data)        // security-scoped
        case userPath(String)
    }

    /// Stable id, e.g. `"large-v3-turbo"` or `"base"`.
    public let id: String
    /// Human label for the picker.
    public let displayName: String
    /// ggml filename on disk, e.g. `"ggml-base.bin"`.
    public let fileName: String
    /// Quantization tag when known (e.g. `"q5_0"`); nil for full-precision.
    public let quantization: String?
    /// Size in bytes when known; 0 when unknown.
    public let sizeBytes: Int64
    public let origin: Origin
    /// Languages this model is good at; empty = multilingual/unknown.
    public let languageHints: [String]

    public init(id: String,
                displayName: String,
                fileName: String,
                quantization: String? = nil,
                sizeBytes: Int64 = 0,
                origin: Origin,
                languageHints: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.quantization = quantization
        self.sizeBytes = sizeBytes
        self.origin = origin
        self.languageHints = languageHints
    }

    public var identifier: String { id }
}

/// The well-known, ship-with-app models. Mirrors the `SttModel` enum's
/// labels/filenames so the existing picker keeps working, but keyed by descriptor
/// id so the scanner and downloader can match any of these on disk *and* any
/// user-imported descriptor with the same `fileName`.
public enum SttModelCatalog {

    /// The bundled catalog, best-first (picker order).
    public static let bundled: [SttModelDescriptor] = [
        SttModelDescriptor(id: "large-v3-turbo",
            displayName: "Large-v3-turbo · best speed/accuracy (RECOMMENDED)",
            fileName: "ggml-large-v3-turbo.bin",
            quantization: "f16",
            sizeBytes: 1_752_944_432,
            origin: .bundled,
            languageHints: ["en","fr","de","es","it","pt","nl","zh","ja","ko","ru","ar","hi"]),
        SttModelDescriptor(id: "large-v3",
            displayName: "Large-v3 · maximum accuracy, slower",
            fileName: "ggml-large-v3.bin",
            quantization: "f16",
            sizeBytes: 3_087_659_584,
            origin: .bundled),
        SttModelDescriptor(id: "medium",
            displayName: "Medium · balanced accuracy",
            fileName: "ggml-medium.bin",
            quantization: "f16",
            sizeBytes: 1_516_533_520,
            origin: .bundled),
        SttModelDescriptor(id: "small",
            displayName: "Small · fast dictation",
            fileName: "ggml-small.bin",
            quantization: "f16",
            sizeBytes: 485_557_560,
            origin: .bundled),
        SttModelDescriptor(id: "base",
            displayName: "Base · ultra-fast, low accuracy",
            fileName: "ggml-base.bin",
            quantization: "f16",
            sizeBytes: 75_520_216,
            origin: .bundled),
        SttModelDescriptor(id: "tiny",
            displayName: "Tiny · fastest, low accuracy",
            fileName: "ggml-tiny.bin",
            quantization: "f16",
            sizeBytes: 75_243_368,
            origin: .bundled),
    ]

    /// The descriptor matching a legacy enum, or nil.
    public static func descriptor(for model: SttModel) -> SttModelDescriptor? {
        switch model {
        case .tiny:         return bundled.first { $0.id == "tiny" }
        case .base:         return bundled.first { $0.id == "base" }
        case .small:        return bundled.first { $0.id == "small" }
        case .medium:       return bundled.first { $0.id == "medium" }
        case .largeV3Turbo: return bundled.first { $0.id == "large-v3-turbo" }
        case .largeV3:      return bundled.first { $0.id == "large-v3" }
        }
    }
}
