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
        let firstEvents = r.ingest(segments: w0, windowRange: 0..<4, windowIndex: 0, utteranceID: nil)
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
        let events = r.ingest(segments: w1, windowRange: 3.2..<7.2, windowIndex: 1, utteranceID: nil)

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
            windowRange: 0..<4, windowIndex: 0, utteranceID: nil
        )
        let before = r.snapshot

        _ = r.ingest(
            segments: [TranscriptSegment(text: "a rewritten", range: 0.0..<1.0, stability: .volatile)],
            windowRange: 3.0..<7.0, windowIndex: 1, utteranceID: nil
        )
        XCTAssertEqual(r.snapshot.first?.text, before.first?.text)
    }

    func testVolatileSegmentsAreReplacedInPlace() {
        var r = TranscriptReconciler()
        let id = UUID()
        // Midpoint 0.25, commitHorizon = windowRange.upperBound = 0.1
        // → 0.25 >= 0.1 → volatile (not yet committed).
        let seg1 = TranscriptSegment(
            id: id, text: "hello", range: 0.0..<0.5, stability: .volatile)
        let seg2 = TranscriptSegment(
            id: id, text: "hello wor", range: 0.0..<0.6, stability: .volatile)

        _ = r.ingest(segments: [seg1], windowRange: 0..<0.1, windowIndex: 0, utteranceID: nil)
        // Second window: commitHorizon = 0.2, seg2 midpoint 0.3 >= 0.2 → still volatile.
        let events = r.ingest(segments: [seg2], windowRange: 0.1..<0.2, windowIndex: 1, utteranceID: nil)

        let partials = events.compactMap {
            if case .partial(let s) = $0 { return s } else { return nil }
        }
        XCTAssertEqual(partials.count, 1)
        XCTAssertEqual(partials.first?.text, "hello wor")
    }

    func testResetClearsEverything() {
        var r = TranscriptReconciler()
        _ = r.ingest(segments: [
            TranscriptSegment(text: "x", range: 0..<1, stability: .volatile)
        ], windowRange: 0..<4, windowIndex: 0, utteranceID: nil)
        XCTAssertFalse(r.snapshot.isEmpty)
        r.reset()
        XCTAssertTrue(r.snapshot.isEmpty)
    }

    func testCommittedAdvancesWatermark() {
        var r = TranscriptReconciler()
        // First window: 0..<4, segment midpoint 1.0 < 4.0 → stable/committed.
        _ = r.ingest(segments: [
            TranscriptSegment(text: "alpha", range: 0.0..<2.0, stability: .volatile)
        ], windowRange: 0..<4, windowIndex: 0, utteranceID: nil)
        // Second window: 3.5..<7.5. "alpha again" at 1.0..<2.0 is below watermark (2.0)
        // → filtered; "beta" at 4.0..<5.5 is fresh and its mid 4.75 < 7.5 → stable.
        let events = r.ingest(segments: [
            TranscriptSegment(text: "alpha again", range: 1.0..<2.0, stability: .volatile),
            TranscriptSegment(text: "beta", range: 4.0..<5.5, stability: .volatile)
        ], windowRange: 3.5..<7.5, windowIndex: 1, utteranceID: nil)

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
        var seg = UtteranceSegmenter(config: .init())
        var seq: UInt64 = 0

        func frame(_ rms: Float, at t: TimeInterval) -> AudioFrame {
            let n = Int(0.02 * AudioFrame.sampleRate)
            return AudioFrame(samples: [Float](repeating: rms, count: n),
                              startTime: t, sequence: seq)
        }

        var boundaries: [UtteranceSegmenter.Boundary] = []
        // 1 s silence, 1 s speech, 1 s silence
        for i in 0..<50    { boundaries += seg.consume(frame(0.001, at: Double(i) * 0.02)) }
        for i in 50..<100  { boundaries += seg.consume(frame(0.05,  at: Double(i) * 0.02)) }
        for i in 100..<150 { boundaries += seg.consume(frame(0.001, at: Double(i) * 0.02)) }

        let starts = boundaries.filter {
            if case .started = $0 { return true } else { return false }
        }
        let ends = boundaries.compactMap {
            if case .ended(let r) = $0 { return r } else { return nil }
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(ends.count, 1)
        // start ≈ 0.8 (1.0 − leadIn 0.2), end ≈ 2.0 (speech ends at 2.0)
        // → duration ≈ 1.2 s
        XCTAssertEqual(ends[0].upperBound - ends[0].lowerBound, 1.2, accuracy: 0.25)
    }

    func testFlushForceClosesOpenUtterance() {
        var seg = UtteranceSegmenter()
        var boundaries: [UtteranceSegmenter.Boundary] = []
        for i in 0..<25 {
            boundaries += seg.consume(
                AudioFrame(samples: [Float](repeating: 0.05, count: 320),
                           startTime: Double(i) * 0.02, sequence: UInt64(i)))
        }
        // Still speaking — no .ended yet.
        XCTAssertFalse(boundaries.contains {
            if case .ended = $0 { return true } else { return false }
        })

        let flushed = seg.flush(at: 0.5)
        XCTAssertNotNil(flushed)
        if case .ended(let range) = flushed {
            XCTAssertLessThanOrEqual(range.lowerBound, 0.02)
            XCTAssertEqual(range.upperBound, 0.5, accuracy: 0.01)
        }
    }

    func testHysteresisPreventsChatter() {
        var seg = UtteranceSegmenter()
        var boundaries: [UtteranceSegmenter.Boundary] = []
        // Alternating RMS just over/under threshold but below speech threshold.
        for i in 0..<100 {
            let rms = (i % 2 == 0) ? 0.007 : 0.005
            boundaries += seg.consume(
                AudioFrame(samples: [Float](repeating: Float(rms), count: 320),
                           startTime: Double(i) * 0.02, sequence: UInt64(i)))
        }
        // 0.007 < speechThreshold (0.012) so no utterance should open.
        let starts = boundaries.filter {
            if case .started = $0 { return true } else { return false }
        }
        XCTAssertEqual(starts.count, 0)
    }
}
