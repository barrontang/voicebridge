import Foundation
import AVFoundation

/// File → 16 kHz / mono / 16-bit PCM WAV, the shape `whisper-cli` consumes.
///
/// The live-mic path (`MicrophoneCapture`) already emits exactly this shape, so
/// it never touches this type. This type's only job is *file* input — turning an
/// arbitrary user-supplied file (MP3, AAC, 48 kHz stereo, 32-bit float, OGG, …)
/// into the canonical PCM the STT backend expects.
///
/// Two paths:
///
///       * **Fast path** — the source is already 16 kHz / mono PCM (a WAV the
///        mic wrote, or a scratch file from an earlier batch pass). We read it
///        and re-emit it with no sample-rate conversion.
///      * **Resample path** (P0 of the review) — the source is anything else.
///       We down-mix the channels to mono and sample-rate-convert to 16 kHz in
///       one pass. This is what makes "drag in an MP3 and transcribe" work
///       end-to-end instead of throwing `audioDecodeFailed`.
///
/// ### Why a hand-rolled resampler, not `AVAudioConverter`?
///
/// `AVAudioConverter` is the "blessed" API in principle, but on this Apple-Silicon
/// toolchain its Swift overlay is incomplete: `render(to:)` / `convert(to:error:
/// withInputFromBlock:)` don't resolve, and `AVAudioFile(forWriting:)` aborts in
/// a bare command-line / sandboxed context. A linear-interpolation resampler over
/// an `AVAudioFile` *read* (which does work) plus the project's existing, tested
/// `WAVWriter` (which does write to disk) needs no external dependency and is
/// fully unit-testable. Linear interpolation is entirely adequate for STT —
/// whisper.cpp re-samples internally and is robust to it. A higher-quality
/// windowed/sinc resampler is a documented drop-in upgrade.
public enum AudioTranscoder {

     /// Canonical target sample rate (matches `AudioFormats.target`).
    public static let targetSampleRate = 16_000.0

     /// Normalize `from` into a 16 kHz / mono / 16-bit PCM WAV at `to`.
     ///
     /// Returns the output URL. Throws `VoiceError.audioDecodeFailed` only when
     /// the source genuinely can't be read (truncated/corrupt file, no audio
     /// track, an empty stream) — *not* for a mismatched rate or channel count,
     /// which is now the resample path's job.
     @discardableResult
    public static func transcodeToWAV(from: URL, to: URL) throws -> URL {
        let inFile = try AVAudioFile(forReading: from)
        let source = inFile.processingFormat

          // A readable-but-empty or non-PCM source is a hard failure even after
          // resampling.
        guard Int(inFile.length) > 0 else {
            throw VoiceError.audioDecodeFailed(url: from.path, reason: "Empty audio file.")
         }

          // Read the whole source into mono float samples at its native rate
          // (channels averaged — a phase-safe down-mix).
        var mono = try readMonoFloat(inFile, sourceFormat: source)
        guard !mono.isEmpty else {
            throw VoiceError.audioDecodeFailed(url: from.path, reason: "Source produced no audio.")
         }

          // If we're already at the target rate, skip the resampler entirely.
        if abs(source.sampleRate - targetSampleRate) > 5.0 {
            mono = linearResample(mono, from: source.sampleRate, to: targetSampleRate)
         }

          // Write via WAVWriter (a tested, sandbox-safe manual writer) rather
          // than AVAudioFile, which aborts in a bare CLI / sandbox context.
        try WAVWriter.write(samples: mono, sampleRate: targetSampleRate, to: to)
        return to
     }

     /// Whether a format already matches the 16 kHz / mono target — the fast-path
     /// check (a copy, no resample).
    public static func isCanonical(_ fmt: AVAudioFormat) -> Bool {
        fmt.channelCount == 1
          && fmt.sampleRate > 0
          && abs(fmt.sampleRate - targetSampleRate) <= 5
     }

     // MARK: - Read

          /// Read an `AVAudioFile` end-to-end into a single mono `Float` stream
          /// normalized to [-1, 1] at the source's native sample rate. Channels
          /// are averaged (a down-mix): the phase-safe reduction that doesn't
          /// cancel a coherent stereo pair, and correct enough for speech.
    static func readMonoFloat(_ file: AVAudioFile, sourceFormat: AVAudioFormat) throws -> [Float] {
        let frames = Int(file.length)          // AVAudioFramePosition is Int64 here
        let channels = Int(sourceFormat.channelCount)
        guard channels > 0, frames > 0 else { return [] }

        var out = [Float](repeating: 0, count: frames)
        var position = 0
        let chunk = 4_096

        while position < frames {
            let cap = AVAudioFrameCount(min(chunk, frames - position))
              // AVFoundation auto-converts PCM sources to *float* on read, so a
             // float buffer reads every PCM format uniformly; a missing channel 0
             // means the stream is non-PCM / corrupt.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: cap),
                  let ch = buffer.floatChannelData else {
                throw VoiceError.audioDecodeFailed(url: file.url.path,
                    reason: "Could not read samples (channel 0 unavailable).")
              }
            buffer.frameLength = 0
               // `read(into:)` populates the buffer in place; its count return is
              // elided by this toolchain's overlay, so we trust frameLength.
             _ = try file.read(into: buffer)
            let got = Int(buffer.frameLength)
            if got == 0 { break }

              // Down-mix this chunk, averaging the channels per frame.
             for i in 0..<got {
                 var acc: Float = 0
                 for c in 0..<channels { acc += ch[c][i] }
                 out[position + i] = acc / Float(channels)
               }
            position += got
          }
        return out
     }

     // MARK: - Resample

          /// Textbook linear-interpolation sample-rate conversion. Adequate for
          /// speech STT (whisper re-samples internally); swap for a windowed/sinc
          /// resampler if fidelity ever matters. `from`/`to` are sample rates.
     static func linearResample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard !samples.isEmpty, from > 0, to > 0 else { return [] }
        if abs(from - to) <= 5.0 { return samples }

        let ratio = to / from                                // target / source
        let outCount = Int((Double(samples.count - 1) * ratio).rounded()) + 1
        var out = [Float](repeating: 0, count: outCount)

        for i in 0..<outCount {
            let srcPos = Double(i) / ratio                   // fractional source index
            let lo = min(Int(srcPos), samples.count - 1)
            let hi = min(lo + 1, samples.count - 1)
            let t = max(0, min(1, Float(srcPos - Double(lo))))
            out[i] = samples[lo] + (samples[hi] - samples[lo]) * t
           }
        return out
     }
}
