import Foundation

/// The selectable TTS engines. Default is `.piper` (fully local, best
/// latency/quality/size tradeoff on Apple Silicon).
///
/// **The raw value is a stable slug, not a label.** It is written into
/// `config.json`, passed to `--engine`, and used as `Identifiable.id`, so it is
/// an on-disk contract: renaming a case's text must never touch it. The old
/// design made `rawValue` the display string ("Piper (local, DEFAULT)"), which
/// meant a wording tweak silently reset every user's engine choice — the
/// `schemaVersion` guard could not catch it, because the file stayed valid JSON.
public enum TTSMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// AVSpeechSynthesizer — built-in macOS voice. No model files, fully
    /// offline, multilingual. Zero-setup baseline.
    case system = "system"
    /// Piper — local ONNX runtime + a voice .onnx. Default.
    case piper = "piper"
    /// Kokoro-82M — local, very high quality; heavier runtime.
    case kokoro = "kokoro"
    /// edge-tts — ONLINE Microsoft Edge voices. Best fidelity, not offline.
    case edgeTTS = "edge-tts"
    /// Fish Audio Drama 3 — a served, multi-speaker TTS model. Online only when
    /// its server is on another machine (see `EnginePrivacy`).
    case fishAudio = "fish-audio"

    public var id: String { rawValue }

    /// The text shown in pickers, status lines and errors.
    public var displayName: String {
        switch self {
        case .system: return "Built-in (offline)"
        case .piper: return "Piper (local, DEFAULT)"
        case .kokoro: return "Kokoro-82M (local)"
        case .edgeTTS: return "Edge TTS (online)"
        case .fishAudio: return "Fish Audio (Drama 3)"
        }
    }
}

// MARK: - Tolerant decoding

extension TTSMode {
    /// Resolve a persisted identifier: the current slug, a display label
    /// written by an older build, or a CLI alias.
    ///
    /// Accepting the label keeps every existing `config.json` working after the
    /// slug migration — users must not lose their engine choice to a refactor.
    public init?(identifier: String) {
        if let mode = TTSMode(rawValue: identifier) {
            self = mode
            return
        }
        switch identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "built-in (offline)", "builtin", "built-in", "avspeech":
            self = .system
        case "piper (local, default)", "piper (local)":
            self = .piper
        case "kokoro-82m (local)", "kokoro-82m", "kokoro":
            self = .kokoro
        case "edge tts (online)", "edge", "edge-tts", "edgetts", "edge tts":
            self = .edgeTTS
        case "fish audio (drama 3)", "fish", "fish-audio", "fish audio", "drama", "drama-3":
            self = .fishAudio
        default:
            return nil
        }
    }

    /// Decoding never fails on an unknown value.
    ///
    /// A settings file written by a *newer* build (with an engine this build
    /// does not know) must not wipe the user's whole configuration - it falls
    /// back to the default engine instead.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TTSMode(identifier: raw) ?? .piper
    }
}
