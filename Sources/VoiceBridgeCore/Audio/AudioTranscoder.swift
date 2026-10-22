import Foundation
import AVFoundation

/// File → 16 kHz / mono / 16-bit PCM WAV, the shape `whisper-cli` consumes.
///
/// The live-mic path (`AudioInputRouter`) already emits exactly this shape, so
/// it never touches this type. This type's only job is *file* input — turning
/// an arbitrary user-supplied file (MP3, AAC, 48 kHz stereo, 32-bit float,
/// OGG, …) into the canonical PCM the STT backend expects.
///
/// Two paths:
///
///       * **Fast path** — the source is already 16 kHz / mono. We read it
///        and re-emit it with no sample-rate conversion.
///      * **Convert path** — the source is anything else. `AVAudioConverter`
///        down-mixes the channels and re-samples to 16 kHz in one pass, with
///        a proper anti-aliasing filter (a linear interpolator folds the
///        8-24 kHz band back down and makes the speech metallic).
///
/// The conversion is **streamed**: the source is read in chunks and the WAV is
/// written as it goes, so converting a two-hour recording does not need two
/// hours of RAM.
///
/// A linear-interpolation fallback is kept for hosts where `AVAudioConverter`
/// misbehaves; it is unit-tested on its own.
public enum AudioTranscoder {

     /// Canonical target sample rate (matches `AudioFormats.target`).
    public static let targetSampleRate = 16_000.0

     /// Normalize `from` into a 16 kHz / mono / 16-bit PCM WAV at `to`.
    ///
    /// Returns the output URL. Throws `VoiceError.audioDecodeFailed` only when
    /// the source genuinely can't be read (truncated/corrupt file, no audio
    /// track, an empty stream) — *not* for a mismatched rate or channel count,
    /// which is the conversion path's job.
    @discardableResult
    public static func transcodeToWAV(from: URL, to: URL) throws -> URL {
        let inFile = try AVAudioFile(forReading: from)
        let source = inFile.processingFormat

          // A readable-but-empty or non-PCM source is a hard failure even after
          // resampling.
        guard Int(inFile.length) > 0 else {
            throw VoiceError.audioDecodeFailed(url: from.path, reason: "Empty audio file.")
         }
        guard source.channelCount > 0, source.sampleRate > 0 else {
            throw VoiceError.audioDecodeFailed(url: from.path, reason: "Unusable audio format.")
            }

        // The fast path: already the canonical shape.
        if isCanonical(source) {
            try copyThrough(file: inFile, to: to)
            return to
            }

        do {
            try convertWithAVAudioConverter(file: inFile, source: source, to: to)
            return to
            } catch {
            // Fall back to the pure-Swift path (the converter is unavailable
            // or refused the format).
            try convertWithLinearResampler(file: inFile, source: source, to: to)
            return to
            }
    }

     /// Whether a format already matches the 16 kHz / mono target — the fast-path
     /// check (a copy, no resample).
    public static func isCanonical(_ fmt: AVAudioFormat) -> Bool {
        fmt.channelCount == 1
          && fmt.sampleRate > 0
          && abs(fmt.sampleRate - targetSampleRate) <= 5
     }

    // MARK: - Fast path

    /// Copy a 16 kHz / mono source through to a WAV, unchanged.
    private static func copyThrough(file: AVAudioFile, to: URL) throws {
        let writer = try WAVStreamWriter(url: to, sampleRate: targetSampleRate)
        do {
            let format = file.processingFormat
            let chunk = 8_192
            var position = 0
            let total = Int(file.length)
            while position < total {
                let cap = AVAudioFrameCount(min(UInt32(chunk), UInt32(total - position)))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap),
                      let channel = buffer.floatChannelData else {
                    throw VoiceError.audioDecodeFailed(url: file.url.path,
                        reason: "Could not read samples (channel 0 unavailable).")
                    }
                buffer.frameLength = 0
                _ = try file.read(into: buffer)
                let got = Int(buffer.frameLength)
                if got == 0 { break }
                try writer.append(Array(UnsafeBufferPointer(start: channel[0], count: got)))
                position += got
                }
            try writer.finish()
            } catch {
            writer.cancel()
            throw error
            }
    }

    // MARK: - Convert path

    /// Convert with `AVAudioConverter`, streaming the source in chunks.
    private static func convertWithAVAudioConverter(file: AVAudioFile,
                                                   source: AVAudioFormat,
                                                   to: URL) throws {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate,
                                         channels: 1),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw VoiceError.audioDecodeFailed(url: file.url.path,
                reason: "Could not create an audio converter for this format.")
            }

        let chunk = 8_192
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target,
                                                frameCapacity: AVAudioFrameCount(chunk)),
              let outChannel = outBuffer.floatChannelData else {
            throw VoiceError.audioDecodeFailed(url: file.url.path,
                reason: "Could not allocate the output buffer.")
            }

        let writer = try WAVStreamWriter(url: to, sampleRate: targetSampleRate)
        do {
            var sourceExhausted = false
            var conversionError: NSError?
            var pendingInput: AVAudioPCMBuffer?

            while true {
                outBuffer.frameLength = 0
                let status = converter.convert(to: outBuffer, error: &conversionError) {
                    _, outStatus in
                    if sourceExhausted {
                        outStatus.pointee = .noDataNow
                        return nil
                        }
                    let input: AVAudioPCMBuffer
                    if let pending = pendingInput {
                        input = pending
                    } else {
                        guard let fresh = AVAudioPCMBuffer(
                            pcmFormat: source,
                            frameCapacity: AVAudioFrameCount(chunk)) else {
                            sourceExhausted = true
                            outStatus.pointee = .noDataNow
                            return nil
                            }
                        input = fresh
                    }
                    pendingInput = nil
                    input.frameLength = 0
                    do {
                        try file.read(into: input)
                        } catch {
                        sourceExhausted = true
                        outStatus.pointee = .noDataNow
                        return nil
                        }
                    if input.frameLength == 0 {
                        sourceExhausted = true
                        outStatus.pointee = .endOfStream
                        return nil
                        }
                    pendingInput = input
                    outStatus.pointee = .haveData
                    return input
                    }

                if let conversionError {
                    throw VoiceError.audioDecodeFailed(url: file.url.path,
                        reason: "Conversion failed: \(conversionError.localizedDescription)")
                    }
                let produced = Int(outBuffer.frameLength)
                if produced > 0 {
                    try writer.append(Array(UnsafeBufferPointer(start: outChannel[0],
                                                                count: produced)))
                    }
                if status == .endOfStream || (produced == 0 && sourceExhausted) { break }
                if produced == 0 && status == .inputRanDry && !sourceExhausted { continue }
                if status == .error { break }
            }
            try writer.finish()
            } catch {
            writer.cancel()
            throw error
            }
    }

    /// The pure-Swift fallback: read everything, resample, write.
    private static func convertWithLinearResampler(file: AVAudioFile,
                                                   source: AVAudioFormat,
                                                   to: URL) throws {
        let mono = try readMonoFloat(file, sourceFormat: source)
        guard !mono.isEmpty else {
            throw VoiceError.audioDecodeFailed(url: file.url.path, reason: "Source produced no audio.")
            }
        let resampled = AudioResampler.resample(mono, from: source.sampleRate,
                                                 to: targetSampleRate)
        try WAVWriter.write(samples: resampled, sampleRate: targetSampleRate, to: to)
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
}
