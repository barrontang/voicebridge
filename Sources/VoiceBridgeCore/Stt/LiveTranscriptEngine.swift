import Foundation

public actor LiveTranscriptEngine {

    public struct Config: Sendable {
        /// Sliding window handed to whisper on each pass.
        public var windowSeconds: TimeInterval = 4.0
        /// Left context so whisper doesn't truncate word boundaries.
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

    private var ring = AudioRingBuffer(capacitySeconds: 60)
    private var segmenter = UtteranceSegmenter()
    private var reconciler = TranscriptReconciler()

    private var windowIndex = 0
    private var lastPartialAt: TimeInterval = -.infinity
    private var isRunning = false

    private var partialTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var pendingFinals: [Range<TimeInterval>] = []

    private var continuation: AsyncStream<TranscriptEvent>.Continuation?

    public init(backend: any StreamingWhisperBackend, config: Config = Config()) {
        self.backend = backend
        self.config = config
        self.ring = AudioRingBuffer(capacitySeconds: config.ringBufferSeconds)
    }

    // MARK: - Lifecycle

    public func start() -> AsyncStream<TranscriptEvent> {
        shutdown()

        let (stream, cont) = AsyncStream<TranscriptEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        continuation = cont
        isRunning = true
        windowIndex = 0
        lastPartialAt = -.infinity
        reconciler.reset()
        ring = AudioRingBuffer(capacitySeconds: config.ringBufferSeconds)
        segmenter = UtteranceSegmenter()

        cont.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        return stream
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        // Flush a half-spoken utterance.
        if case .ended(let range) = segmenter.flush(at: ring.endTime) {
            enqueueFinal(range)
        }

        partialTask?.cancel()
        partialTask = nil
        // Drain finals so the caller sees a clean end.
        Task { [weak self] in
            await self?.drainFinals()
            await self?.finishStream()
        }
    }

    private func shutdown() {
        partialTask?.cancel(); partialTask = nil
        finalTask?.cancel();   finalTask = nil
        pendingFinals.removeAll()
        continuation?.finish(); continuation = nil
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
        ring.append(frame)

        for boundary in segmenter.consume(frame) {
            switch boundary {
            case .started:
                break
            case .continuing:
                maybeKickPartial()
            case .ended(let range):
                enqueueFinal(range)
            }
        }
    }

    // MARK: - Partial path (cancellable, latest wins)

    private func maybeKickPartial() {
        let now = ring.endTime
        guard now - lastPartialAt >= config.partialInterval else { return }
        lastPartialAt = now

        let lo = max(0, now - config.windowSeconds)
        let range = lo..<now
        guard let (samples, startTime) = ring.extract(range), !samples.isEmpty else { return }

        // Supersede in-flight partial — newer audio is more valuable.
        partialTask?.cancel()
        let idx = nextWindowIndex()
        let utteranceID = segmenter.currentUtteranceID
        let backend = self.backend
        let model = config.model
        let language = config.language

        partialTask = Task { [weak self] in
            do {
                let segments = try await backend.transcribe(
                    samples: samples,
                    sampleRate: AudioFrame.sampleRate,
                    startTime: startTime,
                    model: model,
                    language: language,
                    hint: .partial
                )
                if Task.isCancelled { return }
                await self?.apply(segments: segments,
                                  windowRange: range,
                                  windowIndex: idx,
                                  utteranceID: utteranceID)
            } catch is CancellationError {
                // expected
            } catch {
                await self?.emitGap(range)
            }
        }
    }

    // MARK: - Final path (serial FIFO, never cancelled)

    private func enqueueFinal(_ range: Range<TimeInterval>) {
        pendingFinals.append(range)
        guard finalTask == nil else { return }

        finalTask = Task { [weak self] in
            await self?.drainFinals()
            await self?.setFinalTaskNil()
        }
    }

    private func drainFinals() async {
        while !pendingFinals.isEmpty {
            let range = pendingFinals.removeFirst()
            guard let (samples, startTime) = ring.extract(range), !samples.isEmpty else { continue }
            let idx = nextWindowIndex()
            let utteranceID = segmenter.currentUtteranceID
            do {
                let segments = try await backend.transcribe(
                    samples: samples,
                    sampleRate: AudioFrame.sampleRate,
                    startTime: startTime,
                    model: config.model,
                    language: config.language,
                    hint: .final
                )
                await apply(segments: segments,
                           windowRange: range,
                           windowIndex: idx,
                           utteranceID: utteranceID)
            } catch {
                emitGap(range)
            }
        }
    }

    private func setFinalTaskNil() { finalTask = nil }

    // MARK: - Shared

    private func apply(
        segments: [TranscriptSegment],
        windowRange: Range<TimeInterval>,
        windowIndex: Int,
        utteranceID: UUID?
    ) async {
        let events = reconciler.ingest(
            segments: segments,
            windowRange: windowRange,
            windowIndex: windowIndex,
            utteranceID: utteranceID
        )
        for e in events { continuation?.yield(e) }
    }

    private func emitGap(_ range: Range<TimeInterval>) {
        continuation?.yield(.gap(range))
    }

    private func nextWindowIndex() -> Int {
        defer { windowIndex += 1 }
        return windowIndex
    }

    public func transcriptSnapshot() -> [TranscriptSegment] {
        reconciler.snapshot
    }
}
