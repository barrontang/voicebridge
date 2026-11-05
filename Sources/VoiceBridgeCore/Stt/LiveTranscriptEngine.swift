import Foundation

public actor LiveTranscriptEngine {

    public struct Config: Sendable {
        /// Sliding window handed to whisper on each pass.
        public var windowSeconds: TimeInterval = 4.0
        /// Already-heard audio prepended to each window as *context*.
        ///
        /// Whisper decodes every window independently, so a fragment that
        /// starts at a VAD boundary had no left context at all: the first word
        /// of each utterance was decoded from silence. This field existed with
        /// a comment claiming it did that, but nothing read it. The pre-roll is
        /// context only - the reconciler's watermark drops re-emitted audio.
        public var overlapSeconds: TimeInterval = 0.8
        public var ringBufferSeconds: TimeInterval = 60

        /// Minimum wall-clock gap between volatile passes. Raise this for
        /// the CLI backend (process spawn dominates); lower it once the
        /// in-process backend lands.
        public var partialInterval: TimeInterval = 1.2

        public var model: String = "large-v3-turbo"
        public var language: String? = nil

        public init() {}
    }

    private let backend: any StreamingWhisperBackend
    private let config: Config
    /// Optional post-ASR fixer; `nil` keeps the raw whisper text.
    private let corrector: (any TranscriptCorrector)?

    private var ring = AudioRingBuffer(capacitySeconds: 60)
    private var segmenter = UtteranceSegmenter()
    private var reconciler = TranscriptReconciler()

    private var windowIndex = 0
    private var lastPartialAt: TimeInterval = -.infinity
    /// End of the last audio a final pass actually committed.
    ///
    /// The pre-roll must never reach back into speech the transcript already
    /// covers: at the 30 s hard cap there is no pause to land in, so the extra
    /// audio would duplicate the previous words (or, once the watermark drops
    /// them, swallow the first word of the next chunk).
    private var committedEnd: TimeInterval = 0
    /// True once audio has reached the ring; used for the "no input" log.
    private var hasSeenAudio = false
    private var isRunning = false

    private var partialTask: Task<Void, Never>?
    private var partialInFlight = false
    private var partialPending = false
    private var finalTask: Task<Void, Never>?

    // Contextual correction (opt-in). One request in flight at a time; the
    // queue is tiny because a stalled model must not build a backlog.
    private var correctionTask: Task<Void, Never>?
    private var correctionRunning = false
    private var correctionQueue: [(segment: TranscriptSegment, context: [String])] = []
    /// The committed texts, for the corrector's context window.
    private var committedTexts: [String] = []
    private var pendingFinals: [(range: Range<TimeInterval>, utteranceID: UUID?)] = []

    private var continuation: AsyncStream<TranscriptEvent>.Continuation?

    public init(
        backend: any StreamingWhisperBackend,
        config: Config = Config(),
        corrector: (any TranscriptCorrector)? = nil
    ) {
        self.backend = backend
        self.config = config
        self.corrector = corrector
        self.ring = AudioRingBuffer(capacitySeconds: config.ringBufferSeconds)
    }

    // MARK: - Lifecycle

    public func start() -> AsyncStream<TranscriptEvent> {
        shutdown()
        // The logger's interpolation is an escaping closure; copy the value so
        // it does not capture `self`.
        let cfg = config
        VBLog.engine.info(
            "live start: model=\(cfg.model, privacy: .public) language=\(cfg.language ?? "auto", privacy: .public) window=\(cfg.windowSeconds, privacy: .public)s overlap=\(cfg.overlapSeconds, privacy: .public)s partialEvery=\(cfg.partialInterval, privacy: .public)s"
        )

        let (stream, cont) = AsyncStream<TranscriptEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        continuation = cont
        isRunning = true
        windowIndex = 0
        lastPartialAt = -.infinity
        committedEnd = 0
        hasSeenAudio = false
        partialInFlight = false
        partialPending = false
        correctionQueue.removeAll()
        correctionRunning = false
        committedTexts.removeAll()
        reconciler.reset()
        ring = AudioRingBuffer(capacitySeconds: config.ringBufferSeconds)
        segmenter = UtteranceSegmenter()

        cont.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        return stream
    }

    /// Stop the engine and flush what is left.
    ///
    /// This *awaits* the final transcription: the caller (the session) tears
    /// the pipeline down right after, so a fire-and-forget drain would drop
    /// the last sentence.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false

        partialTask?.cancel()
        partialTask = nil

        // Flush a half-spoken utterance by appending it *directly*. Going
        // through `enqueueFinal` started a second drain loop, and the two
        // competed for the same queue: if that loop won, this drain saw an
        // empty queue, called `finishStream()`, and the last sentence was
        // dropped — the exact case the flush exists to prevent.
        if case .ended(let range) = segmenter.flush(at: ring.endTime) {
            pendingFinals.append((range, segmenter.currentUtteranceID))
        }

        // Let any already-running final drain finish before ending the stream,
        // so `.finished` can never overtake the transcript it is waiting for.
        if let finalTask {
            await finalTask.value
            self.finalTask = nil
        }

        await drainFinals()
        finishStream()
    }

    private func shutdown() {
        partialTask?.cancel()
        partialTask = nil
        partialInFlight = false
        partialPending = false
        correctionTask?.cancel()
        correctionTask = nil
        correctionRunning = false
        correctionQueue.removeAll()
        finalTask?.cancel()
        finalTask = nil
        pendingFinals.removeAll()
        continuation?.finish()
        continuation = nil
        isRunning = false
    }

    private func finishStream() {
        continuation?.yield(.finished)
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Ingestion (called from capture thread)

    public func ingest(_ frame: AudioFrame) {
        guard isRunning else { return }
        if !hasSeenAudio {
            hasSeenAudio = true
            VBLog.capture.info("live: first audio frame received")
        }
        ring.append(frame)

        for boundary in segmenter.consume(frame) {
            switch boundary {
            case .started:
                break
            case .continuing:
                maybeKickPartial()
            case .ended(let range):
                // The utterance id is captured *now*: by the time the final is
                // transcribed the segmenter may already be on the next one.
                enqueueFinal(range, utteranceID: segmenter.currentUtteranceID)
            }
        }
    }

    // MARK: - Partial path (coalesced: never cancel a running pass)

    /// Kick a volatile pass, unless one is still running.
    ///
    /// A partial re-transcribes the **whole open utterance**, so it gets slower
    /// as the sentence grows. This used to cancel the in-flight pass on every
    /// 1.2 s tick to replace it with a longer one — which meant that once an
    /// utterance ran longer than a pass takes, *every* pass was killed before
    /// whisper returned and the caption never appeared at all. The log showed
    /// it as `whisper-cli exited with status 15` (SIGTERM from our own cancel).
    ///
    /// Now the running pass is allowed to finish and a follow-up pass is
    /// coalesced behind it, so the caption updates at the pace whisper can
    /// actually deliver instead of never.
    private func maybeKickPartial() {
        guard isRunning else { return }
        let now = ring.endTime
        guard now - lastPartialAt >= config.partialInterval else { return }
        guard !partialInFlight else {
            partialPending = true
            return
        }

        // The partial covers the *open utterance* (from its start to now), so
        // the caption reads as a sentence. When no utterance is open we fall
        // back to a trailing window.
        let lo = segmenter.currentUtteranceStart ?? max(0, now - config.windowSeconds)
        let range = lo..<now
        guard let (samples, startTime) = audioForWindow(range) else { return }

        lastPartialAt = now
        partialInFlight = true
        let idx = nextWindowIndex()
        let utteranceID = segmenter.currentUtteranceID
        let backend = self.backend
        let model = config.model
        let language = config.language

        partialTask = Task { [weak self] in
            var produced: [TranscriptSegment] = []
            var failure: String?
            do {
                produced = try await backend.transcribe(
                    samples: samples,
                    sampleRate: AudioFrame.sampleRate,
                    startTime: startTime,
                    model: model,
                    language: language,
                    hint: .partial
                )
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            guard let self else { return }
            if let failure {
                await self.reportPartialFailure(range, failure)
            } else if !Task.isCancelled {
                await self.apply(
                    segments: produced,
                    windowRange: range,
                    windowIndex: idx,
                    utteranceID: utteranceID,
                    isFinal: false)
            }
            await self.partialDidFinish()
        }
    }

    /// The running pass is done; if audio arrived meanwhile, go again now.
    private func partialDidFinish() {
        partialInFlight = false
        guard partialPending, isRunning else {
            partialPending = false
            return
        }
        partialPending = false
        partialTask = nil
        maybeKickPartial()
    }

    private func reportPartialFailure(_ range: Range<TimeInterval>, _ message: String) {
        VBLog.engine.error(
            "live partial failed (\(range.lowerBound, privacy: .public)s..\(range.upperBound, privacy: .public)s): \(message, privacy: .public)"
        )
        emitGap(range)
    }

    // MARK: - Final path (serial FIFO, never cancelled)

    private func enqueueFinal(_ range: Range<TimeInterval>, utteranceID: UUID?) {
        pendingFinals.append((range, utteranceID))
        guard finalTask == nil else { return }

        finalTask = Task { [weak self] in
            await self?.drainFinals()
            await self?.setFinalTaskNil()
        }
    }

    private func drainFinals() async {
        while !pendingFinals.isEmpty {
            let pending = pendingFinals.removeFirst()
            let range = pending.range
            guard let (samples, startTime) = audioForWindow(range) else { continue }
            let idx = nextWindowIndex()
            let utteranceID = pending.utteranceID
            do {
                let segments = try await backend.transcribe(
                    samples: samples,
                    sampleRate: AudioFrame.sampleRate,
                    startTime: startTime,
                    model: config.model,
                    language: config.language,
                    hint: .final
                )
                let committed = await apply(
                    segments: segments,
                    windowRange: range,
                    windowIndex: idx,
                    utteranceID: utteranceID,
                    isFinal: true)
                // Only now may the next window's pre-roll stop at this point.
                committedEnd = max(committedEnd, range.upperBound)
                for case .final(let segment) in committed {
                    enqueueCorrection(for: segment)
                }
                VBLog.engine.info(
                    "live final \(range.lowerBound, privacy: .public)s..\(range.upperBound, privacy: .public)s → \(segments.count, privacy: .public) segment(s)"
                )
            } catch {
                VBLog.engine.error(
                    "live final failed (\(range.lowerBound, privacy: .public)s..\(range.upperBound, privacy: .public)s): \(error.localizedDescription, privacy: .public)"
                )
                emitGap(range)
            }
        }
    }

    private func setFinalTaskNil() { finalTask = nil }

    // MARK: - Shared

    @discardableResult
    private func apply(
        segments: [TranscriptSegment],
        windowRange: Range<TimeInterval>,
        windowIndex: Int,
        utteranceID: UUID?,
        isFinal: Bool
    ) async -> [TranscriptEvent] {
        let events = reconciler.ingest(
            segments: segments,
            windowRange: windowRange,
            windowIndex: windowIndex,
            utteranceID: utteranceID,
            isFinal: isFinal
        )
        for e in events { continuation?.yield(e) }
        return events
    }

    private func emitGap(_ range: Range<TimeInterval>) {
        continuation?.yield(.gap(range))
    }

    // MARK: - Contextual correction

    /// Queue a committed sentence for post-ASR correction.
    ///
    /// The context is the last three committed sentences: enough to resolve a
    /// homophone or a name, short enough to keep a 4B model fast.
    private func enqueueCorrection(for segment: TranscriptSegment) {
        guard corrector != nil, !segment.text.isEmpty else { return }
        let context = Array(committedTexts.suffix(3))
        committedTexts.append(segment.text)
        if committedTexts.count > 20 {
            committedTexts.removeFirst(committedTexts.count - 20)
        }
        correctionQueue.append((segment, context))
        guard !correctionRunning else { return }
        correctionRunning = true
        correctionTask = Task { [weak self] in
            await self?.drainCorrections()
        }
    }

    private func drainCorrections() async {
        defer { correctionRunning = false }
        guard let corrector else { return }
        while !correctionQueue.isEmpty, isRunning, !Task.isCancelled {
            let job = correctionQueue.removeFirst()
            do {
                guard
                    let corrected = try await corrector.correct(
                        sentence: job.segment.text, context: job.context)
                else { continue }
                let decision = CorrectionPolicy.evaluate(
                    original: job.segment.text, corrected: corrected)
                guard decision.accepted else {
                    VBLog.engine.debug(
                        "live correction rejected (\(decision.reason, privacy: .public))")
                    continue
                }
                let revised = TranscriptSegment(
                    id: job.segment.id,
                    text: corrected.trimmingCharacters(in: .whitespacesAndNewlines),
                    range: job.segment.range,
                    stability: .stable,
                    confidence: job.segment.confidence,
                    windowIndex: job.segment.windowIndex,
                    utteranceID: job.segment.utteranceID)
                continuation?.yield(.revision(revised))
                VBLog.engine.info(
                    "live correction applied to \(job.segment.id.uuidString.prefix(8), privacy: .public)"
                )
            } catch {
                // Ollama not running, model missing, timeout: keep whisper's
                // words and say so once, at info level.
                VBLog.engine.info(
                    "live correction skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The audio for one pass: `overlapSeconds` of already-heard audio in
    /// front of `range`, so whisper has left context instead of a fragment
    /// that starts in silence.
    ///
    /// The returned `startTime` is the *context* start, not the utterance
    /// start, so the backend's relative timings still map to absolute audio
    /// time. Re-emitted committed audio is dropped downstream by the
    /// reconciler's watermark (1 second of trailing silence now guarantees the
    /// pre-roll lands in a pause, never in committed speech).
    private func audioForWindow(_ range: Range<TimeInterval>) -> (
        samples: [Float], startTime: TimeInterval
    )? {
        let lower = max(max(0, range.lowerBound - config.overlapSeconds), committedEnd)
        guard lower < range.upperBound else { return nil }
        guard let (samples, startTime) = ring.extract(lower..<range.upperBound),
            !samples.isEmpty
        else { return nil }
        return (samples, startTime)
    }

    private func nextWindowIndex() -> Int {
        defer { windowIndex += 1 }
        return windowIndex
    }

    public func transcriptSnapshot() -> [TranscriptSegment] {
        reconciler.snapshot
    }
}
