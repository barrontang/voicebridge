import XCTest
@testable import VoiceBridgeCore

/// Tests for the live-capture foundation: the resampler, the sample ring the
/// audio thread writes into, and the timestamped segments that make live
/// captions de-duplicable.
final class AudioRouterTests: XCTestCase {

    // MARK: - Resampler

    func testResampleProducesTheExpectedLength() {
        let input = [Float](repeating: 0.5, count: 48_000)   // 1 s at 48 kHz
        let out = AudioResampler.resample(input, from: 48_000, to: 16_000)
        XCTAssertEqual(out.count, 16_000, accuracy: 2)
    }

    func testResampleIsIdentityForTheSameRate() {
        let input: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(AudioResampler.resample(input, from: 16_000, to: 16_000), input)
    }

    func testResampleHandlesEmptyAndInvalidInput() {
        XCTAssertTrue(AudioResampler.resample([], from: 48_000, to: 16_000).isEmpty)
        XCTAssertTrue(AudioResampler.resample([0.1], from: 0, to: 16_000).isEmpty)
    }

    func testLowPassAttenuatesAboveCutoff() {
        // A 10 kHz tone at 48 kHz: below the 8 kHz cutoff (0.45 * 16 kHz)
        // it survives; a 20 kHz tone does not.
        let rate = 48_000.0
        func tone(freq: Double, count: Int) -> [Float] {
            (0..<count).map { i in
                Float(sin(2 * Double.pi * freq * Double(i) / rate))
            }
        }
        let low = AudioResampler.lowPass(tone(freq: 2_000, count: 4_800), cutoff: 7_200, rate: rate)
        let high = AudioResampler.lowPass(tone(freq: 20_000, count: 4_800), cutoff: 7_200, rate: rate)

        func peak(_ s: [Float]) -> Float { s.map { abs($0) }.max() ?? 0 }
        XCTAssertGreaterThan(peak(low), 0.5)              // 2 kHz passes
        XCTAssertLessThan(peak(high), peak(low) * 0.35)   // 20 kHz is filtered out
    }

    // MARK: - Sample ring

    func testRingPreservesOrder() {
        let ring = AudioSampleRing(capacity: 16)
        let values: [Float] = [1, 2, 3, 4, 5]
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: values.count) }
        XCTAssertEqual(ring.pending, 5)
        let drained = ring.drain(maxCount: 10)
        XCTAssertEqual(drained, values)
        XCTAssertEqual(ring.pending, 0)
    }

    func testRingDropsTheOldestWhenFull() {
        let ring = AudioSampleRing(capacity: 4)
        let values: [Float] = [1, 2, 3, 4, 5, 6]
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: values.count) }
        // Capacity 4 → only the newest four survive.
        XCTAssertEqual(ring.drain(maxCount: 10), [3, 4, 5, 6])
    }

    func testRingDrainIsBounded() {
        let ring = AudioSampleRing(capacity: 32)
        let values = [Float](repeating: 1, count: 10)
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: values.count) }
        XCTAssertEqual(ring.drain(maxCount: 4).count, 4)
        XCTAssertEqual(ring.drain(maxCount: 4).count, 4)
        XCTAssertEqual(ring.drain(maxCount: 4).count, 2)
        XCTAssertEqual(ring.drain(maxCount: 4).count, 0)
    }

    // MARK: - Timestamped segments

    func testParserReadsWhisperOffsets() throws {
        let json = """
        {
          "language": "en",
          "duration_ms": 4000,
          "result": [
            { "transcription": " hello world",
              "offsets": { "from": 0, "to": 1200 } },
            { "transcription": " how are you",
              "offsets": { "from": 1200, "to": 3000 } }
          ]
        }
        """
        let meta = try XCTUnwrap(
            WhisperTranscriptParser.parseJSON(Data(json.utf8)))
        XCTAssertEqual(meta.segments.count, 2)
        XCTAssertEqual(meta.segments[0].text, "hello world")
        XCTAssertEqual(meta.segments[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(meta.segments[0].end, 1.2, accuracy: 0.001)
        XCTAssertEqual(meta.segments[1].start, 1.2, accuracy: 0.001)
        XCTAssertEqual(meta.segments[1].end, 3.0, accuracy: 0.001)
    }

    func testParserReadsClockTimestamps() throws {
        let json = """
        { "transcription": [ { "text": "hi", "timestamps": { "from": "00:00:01,000", "to": "00:00:02,500" } } ] }
        """
        let meta = try XCTUnwrap(
            WhisperTranscriptParser.parseJSON(Data(json.utf8)))
        XCTAssertEqual(meta.segments.count, 1)
        XCTAssertEqual(meta.segments[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(meta.segments[0].end, 2.5, accuracy: 0.001)
    }

    func testParserSkipsSegmentsWithoutUsableTimings() throws {
        let json = """
        { "result": [ { "transcription": "no timing here" } ] }
        """
        let meta = try XCTUnwrap(
            WhisperTranscriptParser.parseJSON(Data(json.utf8)))
        XCTAssertTrue(meta.segments.isEmpty)
        // The flat text is still recovered.
        XCTAssertEqual(meta.text, "no timing here")
    }
}

// MARK: - Windowed adapter

/// A file backend that returns a canned transcript, so the adapter's mapping
/// can be asserted without whisper installed.
private struct FakeFileBackend: WhisperBackend {
    let result: Transcription

    func transcribe(audio: URL,
                    language: String?,
                    model: SttModel,
                    useTimestamps: Bool) async throws -> Transcription {
        result
    }
}

final class WindowedAdapterTests: XCTestCase {

    func testAdapterMapsTimedSegmentsIntoAbsoluteTime() async throws {
        let backend = FakeFileBackend(result: Transcription(
            text: "hello world how are you",
            language: "en",
            model: .tiny,
            durationSeconds: 3.0,
            realtimeFactor: 0.2,
            segments: [
                .init(text: "hello world", start: 0, end: 1.2),
                .init(text: "how are you", start: 1.2, end: 3.0),
            ]))

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-adapter-\(UUID().uuidString)")
        let adapter = WindowedWhisperAdapter(fileBackend: backend, scratchDir: scratch)

        let segments = try await adapter.transcribe(
            samples: [Float](repeating: 0, count: 16_000 * 4),
            sampleRate: 16_000,
            startTime: 10.0,
            model: "tiny",
            language: nil,
            hint: .final)

        XCTAssertEqual(segments.count, 2)
        // The window starts at t=10 s, so the segment times shift with it.
        XCTAssertEqual(segments[0].range.lowerBound, 10.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].range.upperBound, 11.2, accuracy: 0.001)
        XCTAssertEqual(segments[1].range.upperBound, 13.0, accuracy: 0.001)
        XCTAssertTrue(segments.allSatisfy { $0.stability == .stable })
    }

    func testAdapterFallsBackToOneSegmentWithoutTimings() async throws {
        let backend = FakeFileBackend(result: Transcription(
            text: "hello world",
            language: "en",
            model: .tiny,
            durationSeconds: 2.0,
            realtimeFactor: 0.2))

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-adapter-\(UUID().uuidString)")
        let adapter = WindowedWhisperAdapter(fileBackend: backend, scratchDir: scratch)

        let segments = try await adapter.transcribe(
            samples: [Float](repeating: 0, count: 16_000 * 2),
            sampleRate: 16_000,
            startTime: 5.0,
            model: "tiny",
            language: nil,
            hint: .partial)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "hello world")
        XCTAssertEqual(segments[0].range.lowerBound, 5.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].range.upperBound, 7.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].stability, .volatile)
    }
}
