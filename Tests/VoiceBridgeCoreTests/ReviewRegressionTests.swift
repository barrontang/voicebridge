import XCTest

@testable import VoiceBridgeCore

/// Regression tests for the defects found in the 2026-10-30 review.
///
/// Each test is named after the behaviour a user sees, because every one of
/// these was a "fixed in a comment" bug that no test would have failed on.
final class ReviewRegressionTests: XCTestCase {

    // MARK: - P0-3 · CJK speech was cut off after 5 seconds

    /// A 200-character Chinese paragraph used to score one "word" (no spaces),
    /// so the watchdog gave it 5 seconds and stopped the utterance mid-sentence.
    func testChineseTextGetsADeadlineLongEnoughToFinish() {
        let paragraph = String(repeating: "这是一个很长的中文段落。", count: 20)  // 240 chars
        let deadline = SpeechRunner.deadline(for: paragraph)

        XCTAssertGreaterThan(
            deadline, 30,
            "240 Chinese characters need far more than the old 5 s cap")
        XCTAssertLessThanOrEqual(deadline, 300)
    }

    func testDeadlineScalesWithLengthInBothScripts() {
        let shortEnglish = SpeechRunner.deadline(for: "Hello there.")
        let longEnglish = SpeechRunner.deadline(
            for: String(repeating: "word ", count: 200))
        XCTAssertLessThan(shortEnglish, longEnglish, "longer speech needs a longer watchdog")

        // The floor is a watchdog, not an estimate: a short clip still gets room.
        XCTAssertGreaterThanOrEqual(shortEnglish, 30)

        // Japanese and Korean are written without spaces too.
        XCTAssertGreaterThan(SpeechRunner.deadline(for: String(repeating: "あ", count: 200)), 30)
        XCTAssertGreaterThan(SpeechRunner.deadline(for: String(repeating: "가", count: 200)), 30)
    }

    // MARK: - P1-2 · a wedged whisper-cli blocked the final queue forever

    func testWhisperTimeoutScalesWithTheAudioAndCanBeOverridden() {
        XCTAssertEqual(
            WhisperCliBackend.timeout(forAudio: 0, explicit: nil), 30,
            "short clips keep the 30 s floor")
        XCTAssertGreaterThan(
            WhisperCliBackend.timeout(forAudio: 120, explicit: nil), 120,
            "a two-minute file must be allowed more than two minutes")
        XCTAssertEqual(
            WhisperCliBackend.timeout(forAudio: 120, explicit: 7), 7,
            "an explicit timeout wins")
    }

    // MARK: - P1-3 · stop() could drop the last sentence

    /// Speech that never ends with silence is exactly the case the flush exists
    /// for: `stop()` must commit the open utterance *before* it ends the stream.
    func testStopCommitsTheOpenUtterance() async {
        let backend = FixedWordBackend(word: "last")
        var config = LiveTranscriptEngine.Config()
        config.partialInterval = 10  // keep partials out of the way
        config.ringBufferSeconds = 10

        let engine = LiveTranscriptEngine(backend: backend, config: config)
        // The stream must be *held*: letting it deallocate fires its termination
        // handler, which stops the engine before a single frame arrives.
        let stream = await engine.start()
        let consumer = Task { for await _ in stream {} }

        var t = 0.0
        for _ in 0..<8 {  // loud from start to finish: no trailing silence
            await engine.ingest(frame(start: t))
            t += 0.1
        }
        await engine.stop()
        consumer.cancel()

        let snapshot = await engine.transcriptSnapshot()
        let finals = snapshot.filter { $0.stability == .stable }
        XCTAssertEqual(finals.count, 1, "stop() must flush and commit the open utterance")
        XCTAssertEqual(finals.first?.text, "last")
    }

    /// A second session must not inherit the first one's captions.
    func testRestartingTheEngineStartsFromACleanTranscript() async {
        let backend = FixedWordBackend(word: "again")
        var config = LiveTranscriptEngine.Config()
        config.partialInterval = 10
        config.ringBufferSeconds = 10
        let engine = LiveTranscriptEngine(backend: backend, config: config)

        let firstStream = await engine.start()
        let firstConsumer = Task { for await _ in firstStream {} }
        var t = 0.0
        for _ in 0..<8 {
            await engine.ingest(frame(start: t))
            t += 0.1
        }
        await engine.stop()
        firstConsumer.cancel()
        let first = await engine.transcriptSnapshot()
        XCTAssertFalse(first.isEmpty)

        let secondStream = await engine.start()  // start() resets the reconciler
        let secondConsumer = Task { for await _ in secondStream {} }
        let second = await engine.transcriptSnapshot()
        XCTAssertTrue(second.isEmpty, "a new session starts empty")
        secondConsumer.cancel()
    }

    // MARK: - P2-5 · the 15 s hard cap re-fed 0.2 s of transcribed audio

    func testAHardCappedUtteranceDoesNotReFeedItsPreRoll() {
        var config = UtteranceSegmenter.Config()
        config.maximumUtterance = 0.3  // force-chunk a monologue
        config.trailingSilence = 10  // never closes on silence
        config.leadIn = 0.2
        var segmenter = UtteranceSegmenter(config: config)

        var starts: [(frameStart: TimeInterval, reported: TimeInterval)] = []
        var ends = 0
        var t = 0.0
        for _ in 0..<10 {
            let frameStart = t
            for boundary in segmenter.consume(frame(start: t)) {
                switch boundary {
                case .started(let at): starts.append((frameStart, at))
                case .ended: ends += 1
                case .continuing: break
                }
            }
            t += 0.1
        }

        XCTAssertGreaterThanOrEqual(ends, 1, "a monologue must be force-chunked")
        XCTAssertGreaterThanOrEqual(starts.count, 2)

        // The first utterance gets its pre-roll (clamped at zero).
        XCTAssertEqual(starts[0].reported, 0.0, accuracy: 0.001)
        // The continuation starts exactly where the audio is: re-adding the
        // pre-roll would transcribe the same 0.2 s twice.
        XCTAssertEqual(
            starts[1].reported, starts[1].frameStart, accuracy: 0.0001,
            "a continuation must not re-feed the previous utterance's tail")
    }

    // MARK: - Helpers

    private func frame(start: TimeInterval) -> AudioFrame {
        AudioFrame(
            samples: [Float](repeating: 0.5, count: 1600),  // 0.1 s @ 16 kHz, loud
            startTime: start,
            sequence: UInt64(start * 10_000))
    }

    /// Returns one segment covering whatever audio it is handed.
    private struct FixedWordBackend: StreamingWhisperBackend {
        let word: String

        func transcribe(
            samples: [Float],
            sampleRate: Double,
            startTime: TimeInterval,
            model: String,
            language: String?,
            hint: StreamingHint
        ) async throws -> [TranscriptSegment] {
            let duration = Double(samples.count) / sampleRate
            return [
                TranscriptSegment(
                    text: word,
                    range: startTime..<(startTime + duration),
                    stability: hint == .final ? .stable : .volatile)
            ]
        }
    }
}
