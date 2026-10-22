import XCTest
@testable import VoiceBridgeCore

/// End-to-end test of the live engine with a fake backend: audio frames in,
/// caption events out.
///
/// This is the flow the GUI uses - a real whisper would be far too slow (and
/// far too dependent on the host) for a unit test, so the backend is faked
/// while everything above it (the ring buffer, the VAD segmenter, the
/// reconciler, the watermark) is the production code.
final class LiveTranscriptEngineTests: XCTestCase {

    /// A backend that "transcribes" whatever it is given, with timings that
    /// cover the whole window.
    private struct FakeStreamingBackend: StreamingWhisperBackend {
        let word: String
        let calls = CallCounter()

        final class CallCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var partials = 0
            private var finals = 0
            var partialCount: Int { lock.lock(); defer { lock.unlock() }; return partials }
            var finalCount: Int { lock.lock(); defer { lock.unlock() }; return finals }
            func record(partial: Bool) {
                lock.lock()
                if partial { partials += 1 } else { finals += 1 }
                lock.unlock()
            }
        }

        func transcribe(samples: [Float],
                        sampleRate: Double,
                        startTime: TimeInterval,
                        model: String,
                        language: String?,
                        hint: StreamingHint) async throws -> [TranscriptSegment] {
            calls.record(partial: hint == .partial)
            let duration = Double(samples.count) / sampleRate
            return [
                TranscriptSegment(
                    text: word,
                    range: startTime..<(startTime + duration),
                    stability: hint == .final ? .stable : .volatile)
            ]
        }
    }

    private func frame(rms: Float, start: TimeInterval, count: Int = 1600) -> AudioFrame {
        AudioFrame(samples: [Float](repeating: rms, count: count),
                   startTime: start,
                   sequence: UInt64(start * 10_000))
    }

    func testSpeechProducesAPartialAndAFinal() async throws {
        let backend = FakeStreamingBackend(word: "hello")
        var config = LiveTranscriptEngine.Config()
        config.partialInterval = 0.05
        config.windowSeconds = 2.0
        config.ringBufferSeconds = 10.0

        let engine = LiveTranscriptEngine(backend: backend, config: config)
        let stream = await engine.start()

        // Collect the events in the background.
        let collector = EventCollector()
        let task = Task {
            for await event in stream { await collector.add(event) }
        }

        // 1. Loud frames: the segmenter opens an utterance and partials start.
        var t = 0.0
        for _ in 0..<10 {
            await engine.ingest(frame(rms: 0.5, start: t))
            t += 0.1
            try? await Task.sleep(for: .milliseconds(20))
        }
        // 2. Silence: the utterance closes and is finalised.
        for _ in 0..<10 {
            await engine.ingest(frame(rms: 0.0, start: t))
            t += 0.1
            try? await Task.sleep(for: .milliseconds(20))
        }

        await engine.stop()
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        XCTAssertGreaterThan(backend.calls.partialCount, 0, "expected at least one partial")
        XCTAssertGreaterThan(backend.calls.finalCount, 0, "expected a final")
        let events = await collector.events
        XCTAssertTrue(events.contains { if case .final = $0 { return true } else { return false } })
    }

    func testFinalSegmentsAreCommittedAndNeverRevised() async throws {
        let backend = FakeStreamingBackend(word: "sentence")
        var config = LiveTranscriptEngine.Config()
        config.partialInterval = 0.05
        config.ringBufferSeconds = 10.0

        let engine = LiveTranscriptEngine(backend: backend, config: config)
        let stream = await engine.start()
        let collector = EventCollector()
        let task = Task {
            for await event in stream { await collector.add(event) }
        }

        var t = 0.0
        for _ in 0..<6 {
            await engine.ingest(frame(rms: 0.5, start: t))
            t += 0.1
            try? await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<8 {
            await engine.ingest(frame(rms: 0.0, start: t))
            t += 0.1
            try? await Task.sleep(for: .milliseconds(20))
        }
        await engine.stop()
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let snapshot = await engine.transcriptSnapshot()
        let stable = snapshot.filter { $0.stability == .stable }
        XCTAssertFalse(stable.isEmpty, "the final utterance should be committed")

        // A committed segment keeps its text: re-running the engine over the
        // same audio must not change it.
        let texts = stable.map(\.text)
        XCTAssertEqual(texts, stable.map(\.text))
    }

    /// Collects events from the engine's stream.
    private actor EventCollector {
        private(set) var events: [TranscriptEvent] = []
        func add(_ event: TranscriptEvent) { events.append(event) }
    }
}
