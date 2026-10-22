import Foundation
import Combine
import AVFoundation

/// The live speech-to-text session: mic → router → engine → transcript.
///
/// This is the *one* live STT path. It replaces the older
/// `StreamingSttController`, which re-transcribed a rolling window and
/// patched the text with word matching. This one uses the utterance
/// segmenter (VAD), the reconciler (watermark de-duplication) and
/// whisper's own segment timings, so the captions are committed once and
/// never re-worded.
///
///     mic ─▶ AudioInputRouter (one tap, 16 kHz mono frames)
///              └▶ LiveTranscriptEngine (ring buffer, VAD, reconciler)
///                   └▶ LiveTranscriptViewModel (committed + volatile)
///                        └▶ `transcript` (one string for the UI)
///
/// The session owns the whole pipeline, so the UI only has to call
/// `start()` / `stop()` and read `transcript` / `status`.
@MainActor
public final class LiveSttSession: ObservableObject {

    public enum Phase: Sendable {
        case idle
        case live
        case stopping
    }

    /// Everything the session needs; the UI refreshes it when the settings
    /// change (model, model folder, scratch folder).
    public struct Configuration: Sendable {
        public var model: SttModel
        /// Where the whisper `.bin` files live.
        public var modelDirectory: URL
        /// Where the per-window WAVs are written.
        public var scratchDir: URL
        /// Minimum wall-clock gap between two partial passes.
        public var partialInterval: TimeInterval
        /// How much trailing audio a partial pass covers.
        public var windowSeconds: TimeInterval
        /// How much audio the engine keeps for the segmenter.
        public var ringBufferSeconds: TimeInterval
        /// The URL of a local whisper.cpp server. When set, the live path
        /// talks to it instead of spawning `whisper-cli` per window (the
        /// model stays resident - no process spawn, no model load).
        public var serverURL: URL?

        public init(model: SttModel = .largeV3Turbo,
                    modelDirectory: URL = ModelPaths.fromEnvironment().whisperDir,
                    scratchDir: URL = ModelPaths.fromEnvironment().cacheDir,
                    partialInterval: TimeInterval = 1.2,
                    windowSeconds: TimeInterval = 4.0,
                    ringBufferSeconds: TimeInterval = 60.0,
                    serverURL: URL? = nil) {
            self.model = model
            self.modelDirectory = modelDirectory
            self.scratchDir = scratchDir
            self.partialInterval = partialInterval
            self.windowSeconds = windowSeconds
            self.ringBufferSeconds = ringBufferSeconds
            self.serverURL = serverURL
            }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var status = "idle - press Live to start"
    /// The transcript so far: committed sentences plus the live one.
    @Published public private(set) var transcript = ""
    /// The input level of the last frame (0…1, roughly -60…0 dBFS).
    /// Cheap to compute and the only honest way to show "it hears you".
    @Published public private(set) var level: Float = 0

    private var configuration: Configuration
    private let router: AudioInputRouter
    private var engine: LiveTranscriptEngine?
    private var viewModel: LiveTranscriptViewModel?
    private var frameContinuation: AsyncStream<AudioFrame>.Continuation?
    private var frameConsumer: Task<Void, Never>?
    private var sinkID: UUID?
    private var cancellables = Set<AnyCancellable>()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.router = AudioInputRouter()
    }

    /// Adopt a new configuration (the UI calls this when the model or the
    /// model folder changes). Ignored while a session is live.
    public func apply(_ new: Configuration) {
        guard phase == .idle else { return }
        configuration = new
    }

    public var isRunning: Bool { phase != .idle }

    // MARK: - Lifecycle

    /// Start listening. Requests microphone access on the way.
    public func start() async {
        guard phase == .idle else { return }
        guard await Self.requestMicPermission() else {
            status = "Microphone denied - enable it in System Settings > Privacy & Security > Microphone."
            return
            }

        do {
            try await startPipeline()
            phase = .live
            status = "Listening (live)"
            } catch {
            phase = .idle
            status = "Could not start the mic: \(error.localizedDescription)"
            await stopPipeline()
            }
        }

    /// Stop listening. The engine flushes the open utterance, so the last
    /// sentence is not lost.
    public func stop() async {
        guard phase != .idle else { return }
        phase = .stopping
        status = "Transcribing the last sentence..."

        // 1. Stop the mic first: no more audio can arrive.
        router.stop()
        sinkID.map { router.removeSink($0) }
        sinkID = nil
        frameContinuation?.finish()
        frameContinuation = nil

        // 2. Let the engine drain what it has (this awaits the final
        //    transcription of the open utterance).
        await viewModel?.stop()
        frameConsumer?.cancel()
        frameConsumer = nil

        // 3. Release the engine.
        engine = nil
        viewModel = nil

        phase = .idle
        status = "Idle."
        level = 0
        }

    // MARK: - Pipeline

    private func startPipeline() async throws {
        let config = configuration

        // The engine + view model are built per session so a restart starts
        // from a clean transcript.
        //
        // A local whisper.cpp server (when configured) keeps the model
        // resident, so the live path does not spawn a process per window.
        let fileBackend: any WhisperBackend
        if let serverURL = config.serverURL {
            fileBackend = WhisperServerBackend(baseURL: serverURL)
        } else {
            fileBackend = WhisperCliBackend(modelDirectory: config.modelDirectory)
        }
        let backend = WindowedWhisperAdapter(
            fileBackend: fileBackend,
            scratchDir: config.scratchDir)
        let engineConfig = LiveTranscriptEngine.Config()
        let engine = LiveTranscriptEngine(backend: backend, config: engineConfig)
        let viewModel = LiveTranscriptViewModel(engine: engine)
        self.engine = engine
        self.viewModel = viewModel

        // Publish the transcript as the view model changes.
        viewModel.$committed
            .sink { [weak self] _ in self?.refreshTranscript() }
            .store(in: &cancellables)
        viewModel.$volatile
            .sink { [weak self] _ in self?.refreshTranscript() }
            .store(in: &cancellables)

        // The event stream is consumed by the view model.
        viewModel.start()

        // Frames: router → stream → engine. The stream keeps the ORDER
        // (the engine's ring buffer and the segmenter both assume it).
        let (frames, continuation) = AsyncStream<AudioFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        frameContinuation = continuation

        let sink = router.addSink { [weak self] frame in
            let rms = Self.rms(of: frame.samples)
            Task { @MainActor [weak self] in
                self?.level = min(1, rms * 4)
                }
            continuation.yield(frame)
            }
        sinkID = sink

        frameConsumer = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.engine?.ingest(frame)
            }
        }

        try router.start()
    }

    private func stopPipeline() async {
        router.stop()
        if let sinkID { router.removeSink(sinkID) }
        sinkID = nil
        frameContinuation?.finish()
        frameContinuation = nil
        frameConsumer?.cancel()
        frameConsumer = nil
        await viewModel?.stop()
        engine = nil
        viewModel = nil
        }

    private func refreshTranscript() {
        guard let viewModel else { return }
        let all = (viewModel.committed + viewModel.volatile)
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        transcript = all.map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        }

    /// The root-mean-square of a frame (a cheap level estimate).
    nonisolated static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        return (acc / Float(samples.count)).squareRoot()
    }

    // MARK: - Permissions

    /// Ask for microphone access without blocking the main thread.
    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resumed = ResumeGuard()
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if resumed.tryResume() {
                    cont.resume(returning: granted)
                }
            }
        }
    }
}

/// A tiny "resume exactly once" latch (the permission callback can fire more
/// than once on some systems, and resuming a continuation twice traps).
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    /// Returns true the first time only.
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
