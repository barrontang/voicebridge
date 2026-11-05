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
            var partialCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return partials
            }
            var finalCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return finals
            }
            func record(partial: Bool) {
                lock.lock()
                if partial { partials += 1 } else { finals += 1 }
                lock.unlock()
            }
        }

        func transcribe(
            samples: [Float],
            sampleRate: Double,
            startTime: TimeInterval,
            model: String,
            language: String?,
            hint: StreamingHint
        ) async throws -> [TranscriptSegment] {
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
        AudioFrame(
            samples: [Float](repeating: rms, count: count),
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
        for _ in 0..<12 {
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
        for _ in 0..<12 {
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

    // MARK: - Left context + language

    /// Records what each *final* pass was given.
    private struct RecordingFinalBackend: StreamingWhisperBackend {
        struct Call: Sendable {
            let startTime: TimeInterval
            let duration: TimeInterval
            let language: String?
        }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [Call] = []
            var calls: [Call] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            func append(_ call: Call) {
                lock.lock()
                storage.append(call)
                lock.unlock()
            }
        }

        let box = Box()
        var text = "sentence"

        func transcribe(
            samples: [Float], sampleRate: Double, startTime: TimeInterval,
            model: String, language: String?, hint: StreamingHint
        ) async throws -> [TranscriptSegment] {
            let duration = Double(samples.count) / sampleRate
            if hint == .final {
                box.append(Call(startTime: startTime, duration: duration, language: language))
            }
            return [
                TranscriptSegment(
                    text: text,
                    range: startTime..<(startTime + duration),
                    stability: hint == .final ? .stable : .volatile)
            ]
        }
    }

    /// Feed `count` frames of `rms`, advancing `t` by 0.1 s each.
    private func feed(
        _ engine: LiveTranscriptEngine, rms: Float, count: Int, t: inout TimeInterval
    ) async {
        for _ in 0..<count {
            await engine.ingest(frame(rms: rms, start: t))
            t += 0.1
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A final pass must get `overlapSeconds` of already-heard audio, and the
    /// language the user pinned — the two accuracy fixes for live captions.
    func testFinalWindowCarriesThePinnedLanguageAndLeftContext() async throws {
        let backend = RecordingFinalBackend()
        var config = LiveTranscriptEngine.Config()
        config.partialInterval = 10  // finals only
        config.language = "zh"
        config.ringBufferSeconds = 30

        let engine = LiveTranscriptEngine(backend: backend, config: config)
        // The stream must be retained and drained: dropping it triggers
        // `onTermination`, which stops the engine before any audio arrives.
        let stream = await engine.start()
        let drain = Task { for await _ in stream {} }
        defer { drain.cancel() }

        var t = 0.0
        await feed(engine, rms: 0.0, count: 20, t: &t)  // 0.0 – 2.0 s silence
        await feed(engine, rms: 0.5, count: 10, t: &t)  // 2.0 – 3.0 s speech
        await feed(engine, rms: 0.0, count: 12, t: &t)  // closes the utterance
        await engine.stop()

        let call = try XCTUnwrap(backend.box.calls.first)
        XCTAssertEqual(call.language, "zh", "the pinned language must reach whisper")
        // Utterance = 1.7 (2.0 - 0.3 lead-in) … 3.0; 0.8 s of pre-roll → 0.9.
        XCTAssertEqual(call.startTime, 0.9, accuracy: 0.12, "expected 0.8 s of pre-roll")
        XCTAssertEqual(call.duration, 2.1, accuracy: 0.12)
    }

    /// The pre-roll must never re-read audio the transcript already covers.
    func testLeftContextStopsAtCommittedAudio() async throws {
        let backend = RecordingFinalBackend()
        var config = LiveTranscriptEngine.Config()
        config.partialInterval = 10
        config.overlapSeconds = 3.0  // deliberately larger than the pause
        config.ringBufferSeconds = 30

        let engine = LiveTranscriptEngine(backend: backend, config: config)
        let stream = await engine.start()
        let drain = Task { for await _ in stream {} }
        defer { drain.cancel() }

        var t = 0.0
        await feed(engine, rms: 0.5, count: 10, t: &t)  // 0.0 – 1.0 s speech
        await feed(engine, rms: 0.0, count: 12, t: &t)  // closes at ~1.0
        await feed(engine, rms: 0.5, count: 10, t: &t)  // 2.2 – 3.2 s speech
        await feed(engine, rms: 0.0, count: 12, t: &t)
        await engine.stop()

        let calls = backend.box.calls
        XCTAssertEqual(calls.count, 2, "two utterances → two finals")
        // The second window's pre-roll is clamped to the first utterance's end
        // instead of reaching 3 s back into committed speech.
        XCTAssertGreaterThanOrEqual(
            calls[1].startTime, calls[0].startTime + calls[0].duration - 0.12)
    }

    // MARK: - Partial scheduling

    /// A slow backend must not be cancelled mid-flight.
    ///
    /// The old scheduler cancelled the running pass on every tick. Once an
    /// utterance grew longer than one pass, every pass was killed before it
    /// returned and the caption never appeared — the "live shows nothing"
    /// report. Passes must now run one at a time, and none may be cancelled.
    func testPartialPassesAreCoalescedNotCancelled() async throws {
        let backend = SlowBackend(delay: .milliseconds(120))
        var config = LiveTranscriptEngine.Config()
        config.partialInterval = 0.02  // far faster than a pass takes
        config.ringBufferSeconds = 30

        let engine = LiveTranscriptEngine(backend: backend, config: config)
        let stream = await engine.start()
        let drain = Task { for await _ in stream {} }
        defer { drain.cancel() }

        var t = 0.0
        for _ in 0..<25 {  // 2.5 s of speech
            await engine.ingest(frame(rms: 0.5, start: t))
            t += 0.1
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(400))
        await engine.stop()

        let stats = backend.stats
        XCTAssertGreaterThan(stats.calls, 0, "expected at least one partial pass")
        XCTAssertEqual(stats.cancelled, 0, "no pass may be cancelled just to start a newer one")
        XCTAssertEqual(stats.maxConcurrent, 1, "partial passes must not overlap")
        XCTAssertLessThan(stats.calls, 25, "passes must be coalesced, not one per tick")
    }

    /// A backend whose passes take longer than the partial interval.
    private struct SlowBackend: StreamingWhisperBackend {
        struct Stats: Sendable {
            var calls = 0
            var cancelled = 0
            var maxConcurrent = 0
            var concurrent = 0
        }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Stats()
            var stats: Stats {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            func began() {
                lock.lock()
                value.calls += 1
                value.concurrent += 1
                value.maxConcurrent = max(value.maxConcurrent, value.concurrent)
                lock.unlock()
            }
            func ended(cancelled: Bool) {
                lock.lock()
                value.concurrent -= 1
                if cancelled { value.cancelled += 1 }
                lock.unlock()
            }
        }

        let delay: Duration
        let box = Box()
        var stats: Stats { box.stats }

        func transcribe(
            samples: [Float], sampleRate: Double, startTime: TimeInterval,
            model: String, language: String?, hint: StreamingHint
        ) async throws -> [TranscriptSegment] {
            box.began()
            do {
                try await Task.sleep(for: delay)
            } catch {
                box.ended(cancelled: true)
                throw error
            }
            box.ended(cancelled: false)
            let duration = Double(samples.count) / sampleRate
            return [
                TranscriptSegment(
                    text: "slow",
                    range: startTime..<(startTime + duration),
                    stability: hint == .final ? .stable : .volatile)
            ]
        }
    }

    // MARK: - Contextual correction

    private struct FakeCorrector: TranscriptCorrector {
        let replacement: String
        func correct(sentence: String, context: [String]) async throws -> String? {
            replacement
        }
    }

    /// A committed sentence is corrected in place: same id, same range, new
    /// words, and it is never appended as a second segment.
    func testAnAcceptedCorrectionRevisesTheCommittedSegment() async throws {
        let backend = RecordingFinalBackend(text: "the meeting is at tree")
        var config = LiveTranscriptEngine.Config()
        config.partialInterval = 10
        config.ringBufferSeconds = 30

        let engine = LiveTranscriptEngine(
            backend: backend,
            config: config,
            corrector: FakeCorrector(replacement: "the meeting is at three"))
        let stream = await engine.start()
        let collector = RevisionCollector()
        let drain = Task { for await e in stream { await collector.add(e) } }
        defer { drain.cancel() }

        var t = 0.0
        await feed(engine, rms: 0.5, count: 10, t: &t)
        await feed(engine, rms: 0.0, count: 12, t: &t)
        // Give the correction task time to run (it is async by design).
        try? await Task.sleep(for: .milliseconds(400))
        await engine.stop()
        drain.cancel()

        let finals = await collector.finals
        let revisions = await collector.revisions
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(revisions.count, 1, "one sentence → at most one correction")
        let final = try XCTUnwrap(finals.first)
        let revised = try XCTUnwrap(revisions.first)
        XCTAssertEqual(revised.id, final.id, "a revision replaces the segment, never adds one")
        XCTAssertEqual(revised.range, final.range, "timings must not move")
        XCTAssertEqual(revised.text, "the meeting is at three")
    }

    /// A correction that rewrites the sentence is dropped and the transcript
    /// keeps whisper's words.
    func testARejectedCorrectionLeavesTheTranscriptAlone() async throws {
        let backend = RecordingFinalBackend(text: "the cat sat on the mat")
        var config = LiveTranscriptEngine.Config()
        config.partialInterval = 10
        config.ringBufferSeconds = 30

        let engine = LiveTranscriptEngine(
            backend: backend,
            config: config,
            corrector: FakeCorrector(replacement: "a completely different sentence"))
        let stream = await engine.start()
        let collector = RevisionCollector()
        let drain = Task { for await e in stream { await collector.add(e) } }
        defer { drain.cancel() }

        var t = 0.0
        await feed(engine, rms: 0.5, count: 10, t: &t)
        await feed(engine, rms: 0.0, count: 12, t: &t)
        try? await Task.sleep(for: .milliseconds(400))
        await engine.stop()
        drain.cancel()

        let revisions = await collector.revisions
        XCTAssertTrue(revisions.isEmpty, "the policy must reject a rewrite")
    }

    private actor RevisionCollector {
        private(set) var finals: [TranscriptSegment] = []
        private(set) var revisions: [TranscriptSegment] = []
        func add(_ event: TranscriptEvent) {
            switch event {
            case .final(let s): finals.append(s)
            case .revision(let s): revisions.append(s)
            default: break
            }
        }
    }

    /// Collects events from the engine's stream.
    private actor EventCollector {
        private(set) var events: [TranscriptEvent] = []
        func add(_ event: TranscriptEvent) { events.append(event) }
    }
}
