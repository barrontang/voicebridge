import Foundation
import AVFoundation

/// Best-effort file → 16 kHz / mono / 16-bit PCM WAV.
///
/// The live-mic path (`MicrophoneCapture`) already produces exactly this shape,
/// and `whisper-cli` reads WAV/OGG/FLAC/MP3 directly, so a full resample is
/// often unnecessary. This implementation handles a source that is *already* in
/// a compatible PCM shape (an exact copy). For 48 kHz stereo or other formats,
/// wire `AVAudioConverter` here — see `docs/RUNBOOK.md` §transcode for the
/// streaming pattern; it is intentionally left as a documented extension point
/// rather than a half-verified converter.
public enum AudioTranscoder {

      /// Reads `from`, writes a compatible WAV at `to`. Throws if the source
     /// isn't a 16 kHz / mono PCM file (a signal to run the resample step).
    @discardableResult
    public static func transcodeToWAV(from: URL, to: URL) throws -> URL {
        let inFile = try AVAudioFile(forReading: from)
        let fmt = inFile.processingFormat
        guard fmt.channelCount == 1, abs(fmt.sampleRate - 16_000) <= 5 else {
            throw VoiceError.audioDecodeFailed(
                url: from.path,
                reason: "Source is \(fmt.sampleRate) Hz / \(fmt.channelCount) ch; not 16 kHz/mono. Resample required.")
              }

        let outFile = try AVAudioFile(forWriting: to, settings: AudioFormats.target)

        let frameCount = inFile.length
        guard frameCount > 0 else {
            throw VoiceError.audioDecodeFailed(url: from.path, reason: "Empty audio file.")
              }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                            frameCapacity: UInt32(frameCount)) else {
            throw VoiceError.audioDecodeFailed(url: from.path, reason: "Could not allocate PCM buffer.")
              }

        try inFile.read(into: buffer)
        try outFile.write(from: buffer)
        return to
        }
}
