import XCTest

@testable import VoiceBridgeCore

// MARK: - TranscriptReconciler

final class TranscriptReconcilerTests: XCTestCase {

    func testOverlappingWindowsDoNotDuplicate() {
        var r = TranscriptReconciler()

        // Window 0 covers 0..<4: both segments fall entirely inside → stable.
        let w0 = [
            TranscriptSegment(text: "hello world", range: 0.0..<1.5, stability: .volatile),
            TranscriptSegment(text: "how are you", range: 1.5..<3.0, stability: .volatile),
        ]
        let firstEvents = r.ingest(
            segments: w0, windowRange: 0..<4, windowIndex: 0,
            utteranceID: nil, isFinal: true)
        let firstFinals = firstEvents.compactMap {
            if case .final(let s) = $0 { return s.text } else { return nil }
        }
        XCTAssertEqual(firstFinals, ["hello world", "how are you"])
        XCTAssertEqual(r.snapshot.filter { $0.stability == .stable }.count, 2)

        // Window 1 covers 3.2..<7.2. Re-emission of the tail must be dropped
        // by the watermark; only the genuinely new "fine thanks" survives.
        let w1 = [
            TranscriptSegment(text: "how are you", range: 1.4..<2.9, stability: .volatile),
            TranscriptSegment(text: "fine thanks", range: 3.5..<5.0, stability: .volatile),
        ]
        let events = r.ingest(
            segments: w1, windowRange: 3.2..<7.2, windowIndex: 1,
            utteranceID: nil, isFinal: true)

        let finals = events.compactMap {
            if case .final(let s) = $0 { return s.text } else { return nil }
        }
        XCTAssertEqual(finals, ["fine thanks"])
        XCTAssertEqual(r.snapshot.filter { $0.stability == .stable }.count, 3)
    }

    func testStableSegmentsNeverMutate() {
        var r = TranscriptReconciler()

        _ = r.ingest(
            segments: [TranscriptSegment(text: "a", range: 0.0..<1.0, stability: .volatile)],
            windowRange: 0..<4, windowIndex: 0, utteranceID: nil, isFinal: true
        )
        let before = r.snapshot

        _ = r.ingest(
            segments: [
                TranscriptSegment(text: "a rewritten", range: 0.0..<1.0, stability: .volatile)
            ],
            windowRange: 3.0..<7.0, windowIndex: 1, utteranceID: nil, isFinal: true
        )
        XCTAssertEqual(r.snapshot.first?.text, before.first?.text)
    }

    func testPartialIsVolatileAndFinalIsStable() {
        var r = TranscriptReconciler()
        let seg = TranscriptSegment(text: "hello", range: 0.0..<0.5, stability: .volatile)

        // A partial is never committed: it may still be revised.
        let partialEvents = r.ingest(
            segments: [seg], windowRange: 0..<0.6, windowIndex: 0,
            utteranceID: UUID(), isFinal: false)
        let partials = partialEvents.compactMap {
            if case .partial(let s) = $0 { return s } else { return nil }
        }
        XCTAssertEqual(partials.count, 1)
        XCTAssertEqual(partials.first?.stability, .volatile)
        XCTAssertEqual(r.snapshot.filter { $0.stability == .stable }.count, 0)

        // The same text, delivered as a final, is committed.
        let finalEvents = r.ingest(
            segments: [seg], windowRange: 0..<0.6, windowIndex: 1,
            utteranceID: partials.first?.utteranceID, isFinal: true)
        let finals = finalEvents.compactMap {
            if case .final(let s) = $0 { return s } else { return nil }
        }
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals.first?.stability, .stable)
        XCTAssertEqual(r.snapshot.filter { $0.stability == .stable }.count, 1)
    }

    func testResetClearsEverything() {
        var r = TranscriptReconciler()
        _ = r.ingest(
            segments: [
                TranscriptSegment(text: "x", range: 0..<1, stability: .volatile)
            ], windowRange: 0..<4, windowIndex: 0, utteranceID: nil, isFinal: true)
        XCTAssertFalse(r.snapshot.isEmpty)
        r.reset()
        XCTAssertTrue(r.snapshot.isEmpty)
    }

    func testCommittedAdvancesWatermark() {
        var r = TranscriptReconciler()
        // First window: 0..<4, "alpha" committed → watermark = 2.0.
        _ = r.ingest(
            segments: [
                TranscriptSegment(text: "alpha", range: 0.0..<2.0, stability: .volatile)
            ], windowRange: 0..<4, windowIndex: 0, utteranceID: nil, isFinal: true)
        // Second window: 3.5..<7.5. "alpha again" at 1.0..<2.0 is below the
        // watermark (2.0) → filtered; "beta" at 4.0..<5.5 is fresh → committed.
        let events = r.ingest(
            segments: [
                TranscriptSegment(text: "alpha again", range: 1.0..<2.0, stability: .volatile),
                TranscriptSegment(text: "beta", range: 4.0..<5.5, stability: .volatile),
            ], windowRange: 3.5..<7.5, windowIndex: 1, utteranceID: nil, isFinal: true)

        let finals = events.compactMap {
            if case .final(let s) = $0 { return s.text } else { return nil }
        }
        // "alpha again" is before watermark → dropped; "beta" becomes stable.
        XCTAssertEqual(finals, ["beta"])
    }
}

// MARK: - UtteranceSegmenter

final class UtteranceSegmenterTests: XCTestCase {

    func testOpensAndClosesOnSilence() {
        var seg = UtteranceSegmenter()
        var boundaries: [UtteranceSegmenter.Boundary] = []

        // Loud frame opens an utterance.
        let loud = AudioFrame(
            samples: [Float](repeating: 0.5, count: 1600),
            startTime: 0, sequence: 0)
        boundaries += seg.consume(loud)
        XCTAssertEqual(boundaries.count, 1)
        if case .started = boundaries[0] {} else { XCTFail("expected .started") }
        XCTAssertNotNil(seg.currentUtteranceID)
        XCTAssertNotNil(seg.currentUtteranceStart)

        // Quiet frames close it once a full second of silence has elapsed
        // (the threshold used to be 0.6 s, which cut sentences mid-clause).
        let quiet = AudioFrame(
            samples: [Float](repeating: 0.0, count: 1600),
            startTime: 0.1, sequence: 1)
        for _ in 0..<12 { boundaries += seg.consume(quiet) }
        let ended = boundaries.compactMap { b -> Range<TimeInterval>? in
            if case .ended(let r) = b { return r } else { return nil }
        }
        XCTAssertEqual(ended.count, 1)
    }

    func testHysteresisPreventsChatter() {
        var seg = UtteranceSegmenter()
        // A frame between the two thresholds must not open an utterance.
        let mid = AudioFrame(
            samples: [Float](repeating: 0.009, count: 1600),
            startTime: 0, sequence: 0)
        let boundaries = seg.consume(mid)
        XCTAssertTrue(boundaries.isEmpty)
        XCTAssertNil(seg.currentUtteranceID)
    }

    /// An ordinary clause pause must not cut the sentence in half.
    ///
    /// The old 0.6 s threshold closed the utterance while the speaker was
    /// still mid-sentence, so whisper decoded fragments with no context.
    func testAnOrdinaryClausePauseDoesNotEndTheUtterance() {
        var seg = UtteranceSegmenter()
        var t = 0.0
        func frame(_ rms: Float) -> AudioFrame {
            defer { t += 0.1 }
            return AudioFrame(
                samples: [Float](repeating: rms, count: 1600), startTime: t,
                sequence: UInt64(t * 10_000))
        }
        // 1 s of speech opens it.
        for _ in 0..<10 { _ = seg.consume(frame(0.5)) }
        XCTAssertNotNil(seg.currentUtteranceStart)

        // 0.8 s of silence: under the old threshold this closed the utterance.
        var boundaries: [UtteranceSegmenter.Boundary] = []
        for _ in 0..<8 { boundaries += seg.consume(frame(0.0)) }
        XCTAssertFalse(
            boundaries.contains { if case .ended = $0 { return true } else { return false } },
            "0.8 s of silence must not end the sentence anymore")
        XCTAssertNotNil(seg.currentUtteranceStart)

        // A full second does close it.
        for _ in 0..<3 { boundaries += seg.consume(frame(0.0)) }
        XCTAssertTrue(
            boundaries.contains { if case .ended = $0 { return true } else { return false } })
    }

    func testFlushForceClosesOpenUtterance() {
        var seg = UtteranceSegmenter()
        let loud = AudioFrame(
            samples: [Float](repeating: 0.5, count: 1600),
            startTime: 0, sequence: 0)
        _ = seg.consume(loud)
        let flushed = seg.flush(at: 2.0)
        guard case .ended(let range)? = flushed else {
            return XCTFail("expected an ended boundary")
        }
        XCTAssertEqual(range.upperBound, 2.0, accuracy: 0.001)
    }
}

// MARK: - Live session ↔ engine wiring

final class LiveSessionConfigurationTests: XCTestCase {

    /// The engine must run the model the user picked.
    ///
    /// `startPipeline` used to build a fresh `LiveTranscriptEngine.Config()`
    /// and ignore the session's configuration, so live captions silently ran
    /// the hard-coded `large-v3-turbo` default even after the user selected
    /// `large-v3` for push-to-talk — the same audio, transcribed by two
    /// different models, which is exactly the "live is less accurate" report.
    func testTheConfiguredModelReachesTheEngine() {
        let configuration = LiveSttSession.Configuration(
            model: .largeV3,
            partialInterval: 0.4,
            windowSeconds: 6,
            ringBufferSeconds: 30)

        let engine = configuration.engineConfig
        XCTAssertEqual(engine.model, "large-v3", "the live engine must honour the chosen model")
        XCTAssertEqual(engine.partialInterval, 0.4)
        XCTAssertEqual(engine.windowSeconds, 6)
        XCTAssertEqual(engine.ringBufferSeconds, 30)
    }

    /// The default is still the recommended turbo model.
    func testTheDefaultConfigurationIsTurbo() {
        XCTAssertEqual(LiveSttSession.Configuration().engineConfig.model, "large-v3-turbo")
    }
}
