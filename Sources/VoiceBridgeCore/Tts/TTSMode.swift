import Foundation

/// The selectable TTS engines. Default is `.piper` (fully local, best
/// latency/quality/size tradeoff on Apple Silicon).
public enum TTSMode: String, CaseIterable, Identifiable, Codable, Sendable {
     /// AVSpeechSynthesizer — built-in macOS voice. No model files, fully
     /// offline, multilingual. Zero-setup baseline.
    case system = "Built-in (offline)"
     /// Piper — local ONNX runtime + a voice .onnx. Default.
    case piper = "Piper (local, DEFAULT)"
     /// Kokoro-82M — local, very high quality; heavier runtime.
    case kokoro = "Kokoro-82M (local)"
     /// edge-tts — ONLINE Microsoft Edge voices. Best fidelity, not offline.
    case edgeTTS = "Edge TTS (online)"
     /// Fish Audio Drama 3 — a served, multi-speaker TTS model (not offline).
    case fishAudio = "Fish Audio (Drama 3)"

    public var id: String { rawValue }

    /// True when the engine sends the text to a remote service.
    ///
    /// The UI asks for consent before the first online synthesis, so this
    /// must be the single source of truth for "does the text leave the
    /// machine".
    public var isOnline: Bool {
        switch self {
        case .edgeTTS, .fishAudio: return true
        case .system, .piper, .kokoro: return false
        }
    }
}

// MARK: - Tolerant decoding

extension TTSMode {
    /// Decoding never fails on an unknown value.
    ///
    /// A settings file written by a *newer* build (with an engine this build
    /// does not know) must not wipe the user's whole configuration - it falls
    /// back to the default engine instead.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TTSMode(rawValue: raw) ?? .piper
    }
}
