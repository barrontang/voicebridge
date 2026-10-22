import Foundation
import Combine
import AVFoundation

/// Push-to-talk recording: mic → router → 16 kHz mono WAV on disk.
///
/// The old implementation used `AVAudioRecorder`, which writes the file
/// itself and needs a "sleep a beat and hope it flushed" hack before the
/// file can be transcribed. This one reuses the same `AudioInputRouter` as
/// the live captions (one tap, one format) and writes the WAV itself, so the
/// audio is always complete and always exactly the shape whisper.cpp wants.
@MainActor
public final class PushToTalkSession: ObservableObject {

    public enum Phase: Sendable {
        case idle
        case recording
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var status = "Ready."
    /// The input level of the last frame (0…1). The UI animates with it, so
    /// the user can see that the app is really listening.
    @Published public private(set) var level: Float = 0

    /// Where the recording is written (valid after `start`).
    public private(set) var outputURL: URL?

    private let router = AudioInputRouter()
    private let accumulator = SampleAccumulator()
    private var sinkID: UUID?
    private var isRecording = false

    /// Hard cap on a single take (10 minutes at 16 kHz mono = ~19 MB).
    private let maxSeconds: Double = 600

    public init() {}

    /// The root-mean-square of a frame (a cheap level estimate).
    nonisolated static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        return (acc / Float(samples.count)).squareRoot()
    }

    /// Ask for microphone access (async, never blocks the caller).
    public static func requestPermission() async -> Bool {
        await LiveSttSession.requestMicPermission()
    }

    /// Start recording into `url`.
    public func start(url: URL) async throws {
        guard !isRecording else { return }
        guard await Self.requestPermission() else {
            status = "Microphone denied - enable it in System Settings > Privacy & Security > Microphone."
            throw VoiceError.permissionDenied(capability: "microphone")
            }

        accumulator.reset()
        outputURL = url
        isRecording = true
        phase = .recording
        status = "Recording…"

        let limit = Int(maxSeconds * AudioFrame.sampleRate)
        sinkID = router.addSink { [weak self] frame in
            // The sink runs on the audio pump thread, so the samples go into
            // a lock-protected buffer (never on the main actor).
            self?.accumulator.append(frame, limit: limit)
            // The level is published for the animation - throttled, so the
            // UI is not flooded with 50 updates a second.
            let rms = Self.rms(of: frame.samples)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.level = min(1, rms * 4)
                }
            }
        do {
            try router.start()
            } catch {
            isRecording = false
            phase = .idle
            status = "Could not start the mic: \(error.localizedDescription)"
            throw error
            }
        }

    /// Stop recording and finalize the WAV. Returns the file URL.
    @discardableResult
    public func stop() throws -> URL? {
        guard isRecording else { return outputURL }
        router.stop()
        level = 0
        if let sinkID { router.removeSink(sinkID) }
        sinkID = nil
        isRecording = false
        phase = .idle

        guard let url = outputURL else { return nil }
        let samples = accumulator.drain()
        try WAVWriter.write(samples: samples, sampleRate: AudioFrame.sampleRate, to: url)
        status = "Recorded \(String(format: "%.1f", Double(samples.count) / AudioFrame.sampleRate))s"
        return url
        }

}

/// A lock-protected sample buffer for the recorder (the sink runs on the
/// audio pump thread, not the main actor).
private final class SampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []

    func reset() {
        lock.lock(); storage.removeAll(keepingCapacity: true); lock.unlock()
    }

    func append(_ frame: AudioFrame, limit: Int) {
        lock.lock()
        defer { lock.unlock() }
        if storage.count + frame.samples.count > limit {
            let room = max(0, limit - storage.count)
            storage.append(contentsOf: frame.samples.prefix(room))
            return
            }
        storage.append(contentsOf: frame.samples)
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
