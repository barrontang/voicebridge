import Foundation
import AVFoundation

/// AVSpeechSynthesizer — built-in, fully-offline macOS voice. No model files,
/// no network: a true zero-setup baseline and the safety fallback when Piper
/// is absent.
///
/// Unlike the file-producing engines, AVSpeech *speaks to the system audio
/// device directly* and cannot render a WAV. Hence `producesAudioFile == false`
/// and `synthesize` returns its (nonexistent) output path as a sentinel — the
/// orchestrator sees `producesAudioFile == false` and skips file playback,
/// instead letting AVSpeech deliver audio while a runloop spin keeps it alive.
public final class SystemVoiceBackend: TTSBackend, @unchecked Sendable {

        /// In-place engine — no audio file is produced.
    public var producesAudioFile: Bool { false }
    public var displayName: String { "Built-in (AVSpeechSynthesizer)" }

        /// System voices are always available on macOS.
    public func isAvailable() -> Bool { true }

    public func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
             DispatchQueue.main.async {
                 let synth = AVSpeechSynthesizer()
                 let utter = AVSpeechUtterance(string: text)
                 utter.rate = AVSpeechUtteranceDefaultSpeechRate
                  if let voice, let v = AVSpeechSynthesisVoice.speechVoices()
                              .first(where: { $0.name == voice }) {
                     utter.voice = v
                   }
                 synth.speak(utter)
                 // Return the (nonexistent) path so the caller's contract holds;
                 // the orchestrator will not re-play it because
                 // `producesAudioFile` is false.
                 cont.resume(returning: outputPath)
               }
            }
       }
}
