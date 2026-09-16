import XCTest
import AVFoundation
@testable import VoiceBridgeCore

/// P0 of the review: batch transcription of arbitrary user files (48 kHz stereo,
/// 32-bit float, MP3, …) used to hard-fail because `transcodeToWAV` only accepted
/// an already-canonical 16 kHz / mono PCM file. These tests exercise the new
/// resample path end-to-end plus the pure functions it's built from.
final class AudioTranscoderTests: XCTestCase {

      /// A sample-rate conversion yields ≈ (in · to/from) output frames, and is a
      /// no-op at equal rates.
    func testLinearResampleLengthIsProportional() {
        let input = (0..<48_000).map { Float($0) }      // 48 kHz, 1 s worth
        let out = AudioTranscoder.linearResample(input, from: 48_000, to: 16_000)
          // 48 kHz → 16 kHz is a 3:1 down-sampling: ≈16 000 frames.
        XCTAssertEqual(out.count, 16_000, accuracy: 2)
      }

    func testLinearResampleIsIdentityAtEqualRate() {
        let input: [Float] = [0, 0.5, -0.5, 1.0, -1.0]
        let out = AudioTranscoder.linearResample(input, from: 16_000, to: 16_000)
          // Within the ±5 Hz dead-band the input is returned untouched.
        XCTAssertEqual(out, input)
      }

    func testLinearResampleEmptyAndBadRates() {
        XCTAssertTrue(AudioTranscoder.linearResample([], from: 48_000, to: 16_000).isEmpty)
        XCTAssertTrue(AudioTranscoder.linearResample([1, 2, 3], from: 0, to: 16_000).isEmpty)
      }

      /// Down-mixing averages a coherent stereo pair to its mono value.
    func testReadMonoFloatAveragesChannels() throws {
          // A 48 kHz stereo int16 tone, written raw — AVAudioFile-forWriting aborts
          // in a bare CLI/test context, so the test owns the bytes it feeds in.
        let url = try makeRaw48kStereoWAV(samplePattern: { (i: Int) -> Int16 in
            Int16(sin(Double(i) / 48_000 * 2 * Double.pi * 440) * 16_000)
           }, frames: 2_400)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        let mono = try AudioTranscoder.readMonoFloat(file, sourceFormat: file.processingFormat)
          // 48 kHz · 0.05 s ≈ 2 400 mono frames; a coherent L R pair averages to
         // the tone, never to silence.
        XCTAssertEqual(mono.count, 2_400, accuracy: 4)
        XCTAssertTrue(mono.contains { abs($0) > 0.01 })
       }

      /// End-to-end: a 48 kHz stereo source becomes a 16 kHz / mono PCM WAV whose
      /// duration matches the source (≈ sample-count ratio), not the source rate.
    func testTranscodeResamples48kStereoTo16kMono() throws {
        let src = try makeRaw48kStereoWAV(samplePattern: { _ in 10_000 }, frames: 2_400)
        let dst = FileManager.default.temporaryDirectory
                       .appendingPathComponent("vb-resample-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try AudioTranscoder.transcodeToWAV(from: src, to: dst)

        let out = try AVAudioFile(forReading: dst)
        XCTAssertEqual(out.processingFormat.sampleRate, 16_000, accuracy: 1)
        XCTAssertEqual(out.processingFormat.channelCount, 1)
          // 0.05 s stereo @ 48 kHz → 0.05 s mono @ 16 kHz ≈ 800 frames.
        XCTAssertEqual(Int(out.length), 800, accuracy: 12)
       }

      /// Fast path: an already-canonical 16 kHz / mono PCM file round-trips through
      /// `transcodeToWAV` with its frame count preserved.
    func testTranscodeFastPathPreservesCanonicalFrames() throws {
        let src = FileManager.default.temporaryDirectory
                        .appendingPathComponent("vb-fastpath-src-\(UUID().uuidString).wav")
        let dst = FileManager.default.temporaryDirectory
                       .appendingPathComponent("vb-fastpath-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
          }

           // WAVWriter already emits the canonical 16 kHz / mono shape the fast path
           // copies without resampling.
        try WAVWriter.write(samples: (0..<1_600).map { Float($0 % 500 - 250) },
                            sampleRate: 16_000, to: src)
        try AudioTranscoder.transcodeToWAV(from: src, to: dst)

        let out = try AVAudioFile(forReading: dst)
        XCTAssertEqual(Int(out.length), 1_600)
       }

      // MARK: - RAW WAV fixture

           /// Manually emit a 48 kHz / stereo / 16-bit PCM WAV. `AVAudioFile(forWriting:)`
         /// aborts in a bare CLI/test context, so the bytes are written directly — the
         /// exact scenario the resample path must read.
    private func makeRaw48kStereoWAV(
         samplePattern: (Int) -> Int16,
         frames: Int
      ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
                       .appendingPathComponent("vb-src48-\(UUID().uuidString).wav")

        func u32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { out.append(contentsOf: $0) }
            }
        func u16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { out.append(contentsOf: $0) }
            }

        let channels = 2
        let sampleRate = 48_000
        let bits = 16
        let byteRate = sampleRate * channels * bits / 8
        let blockAlign = channels * bits / 8
        let dataBytes = frames * blockAlign

        var out = Data()
        out.append(contentsOf: Array("RIFF".utf8))
        u32(36 + UInt32(dataBytes))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bits))
        out.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))

          // Interleave L R, then emit as raw little-endian bytes (arm64 is LE).
        var interleaved = [Int16](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let v = samplePattern(i)
            interleaved[i * 2] = v
            interleaved[i * 2 + 1] = v
            }
        out.append(contentsOf: interleaved.withUnsafeBytes { Array($0) })

        try? FileManager.default.removeItem(at: url)
        try out.write(to: url)
        return url
        }
}
