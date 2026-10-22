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
/// instead letting AVSpeech deliver the audio.
///
/// **Completion contract (fixed):** `synthesize` now resolves only when the
/// utterance has actually *finished* (or been cancelled), instead of resolving
/// the instant `speak(_:)` is called. That makes `play: true` / `play: false`
/// honest for in-place engines: the caller can await the audio, and a CLI
/// process no longer exits mid-sentence.
    // SAFETY (@unchecked Sendable): the stored properties are immutable; the
    // mutable state (the continuation) is guarded by a lock.
public final class SystemVoiceBackend: TTSBackend, @unchecked Sendable {

         /// In-place engine — no audio file is produced.
    public var producesAudioFile: Bool { false }
    public var displayName: String { "Built-in (AVSpeechSynthesizer)" }

         /// System voices are always available on macOS.
    public func isAvailable() -> Bool { true }

    public func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
        try Task.checkCancellation()
        // The runner owns the synthesizer *and* acts as its delegate; the
        // local strong reference keeps both alive until the utterance ends
        // (AVSpeechSynthesizer holds its delegate weakly).
        let runner = SpeechRunner()
        try await runner.run(text: text, voice: voice)
        // Return the (nonexistent) path so the caller's contract holds; the
        // orchestrator will not re-play it because `producesAudioFile` is false.
        return outputPath
    }
}

// MARK: - Utterance runner

/// Drives one `AVSpeechUtterance` and resolves when it finishes.
final class SpeechRunner: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    /// Speak `text`, resolving when the utterance completes.
    func run(text: String, voice: String?) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                continuation = cont
                lock.unlock()

                // Safety net: some hosts (no output device, a muted session,
                // a stuck audio server) never deliver `didFinish`. Without this
                // the caller would wait forever, so the utterance is given a
                // generous deadline and then abandoned.
                let deadline = Self.deadline(for: text)
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(deadline))
                    guard !Task.isCancelled else { return }
                    self?.synth.stopSpeaking(at: .immediate)
                    self?.finish(with: VoiceError.processTimeout(
                        component: "AVSpeechSynthesizer", seconds: deadline))
                }

                // AVSpeechSynthesizer must be driven from the main thread, and
                // `Playback` is main-actor isolated - so the utterance starts
                // on the main actor.
                Task { @MainActor [self] in
                    let utter = AVSpeechUtterance(string: text)
                    utter.rate = AVSpeechUtteranceDefaultSpeechRate
                    if let voice,
                       let v = AVSpeechSynthesisVoice.speechVoices()
                                    .first(where: { $0.name == voice }) {
                        utter.voice = v
                    }
                    // Stop whatever is currently sounding and register this
                    // synth so a later utterance (or the UI's stop) can halt it.
                    if Playback.assumesRunningLoop {
                        Playback.stopAll()
                        Playback.registerSynthesizer(synth)
                    }
                    synth.speak(utter)
                }
            }
        } onCancel: {
            self.synth.stopSpeaking(at: .immediate)
        }
    }

    /// How long an utterance of `text` may reasonably take (plus slack).
    static func deadline(for text: String) -> TimeInterval {
        let words = text.split { $0 == " " || $0 == "\n" }.count
        let estimated = Double(words) / 2.5 + 2.0
        return min(300, max(5, estimated))
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        finish(with: nil)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        finish(with: CancellationError())
    }

    private func finish(with error: Error?) {
        lock.lock()
        guard !finished, let cont = continuation else {
            lock.unlock()
            return
        }
        finished = true
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()

        if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }
}
