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

    public var id: String { rawValue }
}
