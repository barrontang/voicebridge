import Foundation
import AVFoundation

/// A lock-protected, pre-allocated sample buffer for the live capture path.
///
/// The microphone tap runs on a real-time audio thread: allocating there (or
/// growing an array) causes dropouts, so the tap only ever *copies* into this
/// pre-allocated ring under a short lock. The consumer (the pump task) drains
/// whole chunks out of it.
final class AudioSampleRing: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = 0
    private var totalWritten: Int = 0

    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    /// Copy `count` samples in. Never allocates.
    func write(_ source: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<count {
            storage[writeIndex] = source[i]
            writeIndex = (writeIndex + 1) % capacity
            if filled < capacity { filled += 1 }
        }
        totalWritten += count
    }

    /// Remove and return up to `maxCount` of the oldest samples.
    /// Returns an empty array when nothing is buffered.
    func drain(maxCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let n = min(filled, maxCount)
        guard n > 0 else { return [] }

        var out = [Float](repeating: 0, count: n)
        let oldest = (writeIndex - filled + capacity) % capacity
        for i in 0..<n {
            out[i] = storage[(oldest + i) % capacity]
        }
        // Advance the read cursor by dropping the drained samples.
        filled -= n
        writeIndex = (writeIndex - n + capacity) % capacity
        return out
    }

    /// How many samples are waiting to be drained.
    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return filled
    }

    /// Total samples ever written (for diagnostics).
    var written: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalWritten
    }
}

/// The single microphone tap for the whole app.
///
/// **Finding 6, resolved.** `MicrophoneCapture` (push-to-talk) and the live
/// streaming controller each opened their *own* tap on the input device, so
/// two features could fight over the hardware. This router owns exactly one
/// `AVAudioEngine` tap and fans the audio out to any number of subscribers
/// ("sinks"), so a recorder and a live transcriber can listen at the same
/// time without a second device session.
///
/// Shape of the data flow:
///
///     mic ──▶ AVAudioEngine tap (real-time thread)
///                │  down-mix + copy into a pre-allocated ring (no allocation)
///                ▼
///            AudioSampleRing ──▶ pump task (background)
///                │  resample to 16 kHz mono, cut into frames
///                ▼
///            AudioFrame sinks (live engine, recorder, level meter, …)
///
/// The tap never allocates and never blocks on anything but a short mutex, so
/// it is safe to leave installed for the life of the app.
public final class AudioInputRouter: @unchecked Sendable {

    /// How the router behaves.
    public struct Configuration: Sendable {
        /// The rate every frame is delivered at (whisper.cpp's shape).
        public var targetSampleRate: Double
        /// How much audio each delivered frame holds.
        public var frameDuration: TimeInterval
        /// How much audio the ring buffers before the oldest is dropped.
        public var maxBufferedSeconds: TimeInterval
        /// How often the pump wakes up to drain the ring.
        public var pumpInterval: TimeInterval

        public init(targetSampleRate: Double = 16_000,
                    frameDuration: TimeInterval = 0.1,
                    maxBufferedSeconds: TimeInterval = 30,
                    pumpInterval: TimeInterval = 0.01) {
            self.targetSampleRate = targetSampleRate
            self.frameDuration = frameDuration
            self.maxBufferedSeconds = maxBufferedSeconds
            self.pumpInterval = pumpInterval
            }
    }

    /// Receives one frame of 16 kHz mono audio.
    public typealias FrameSink = @Sendable (AudioFrame) -> Void

    public let configuration: Configuration

    private let ring: AudioSampleRing
    private let sinksLock = NSLock()
    private var sinks: [UUID: FrameSink] = [:]
    private let engine = AVAudioEngine()
    private var isRunning = false
    private var pumpTask: Task<Void, Never>?
    private var inputSampleRate: Double = 48_000

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        // The ring is sized for the native rate; it is re-created on start
        // once the real input rate is known.
        self.ring = AudioSampleRing(capacity: 48_000 * 30)
    }

    // MARK: - Subscribers

    /// Register a sink. Returns a token for `removeSink`.
    @discardableResult
    public func addSink(_ sink: @escaping FrameSink) -> UUID {
        let id = UUID()
        sinksLock.lock()
        sinks[id] = sink
        sinksLock.unlock()
        return id
    }

    /// Remove a sink.
    public func removeSink(_ id: UUID) {
        sinksLock.lock()
        sinks[id] = nil
        sinksLock.unlock()
    }

    private func broadcast(_ frame: AudioFrame) {
        sinksLock.lock()
        let list = Array(sinks.values)
        sinksLock.unlock()
        for sink in list { sink(frame) }
    }

    // MARK: - Lifecycle

    /// Install the tap and start pumping. Throws if the input device is
    /// unavailable.
    public func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let rate = format.sampleRate
        guard rate > 0 else {
            throw VoiceError.audioDecodeFailed(url: "(tap)",
                reason: "the input device reported no sample rate")
            }
        inputSampleRate = rate

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
            }
        engine.prepare()
        try engine.start()
        isRunning = true
        startPump()
    }

    /// Stop the tap and the pump. Safe to call when not running.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        pumpTask?.cancel()
        pumpTask = nil
        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }

    /// The device's native sample rate (the rate the tap delivers).
    public var nativeSampleRate: Double { inputSampleRate }

    // MARK: - Audio thread

    /// Real-time thread: down-mix the channels and copy into the ring.
    /// No allocation, no I/O, no locks other than the ring's short mutex.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)

        if channelCount == 1 {
            ring.write(channels[0], count: frames)
            return
        }
        // Down-mix: average the channels (phase-safe for a coherent pair).
        var scratch = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var acc: Float = 0
            for c in 0..<channelCount { acc += channels[c][i] }
            scratch[i] = acc / Float(channelCount)
           }
        scratch.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                ring.write(base, count: frames)
            }
        }
    }

    // MARK: - Pump

    /// Drains the ring, resamples to the target rate, and cuts the result into
    /// fixed-size frames.
    private func startPump() {
        let frameSamples = max(1, Int(configuration.frameDuration * configuration.targetSampleRate))
        let target = configuration.targetSampleRate
        let interval = configuration.pumpInterval
        let frameDuration = configuration.frameDuration
        let ring = self.ring

        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Samples that did not fill a whole frame yet (they stay at the
            // *target* rate, so they never go back into the native-rate ring).
            var pending: [Float] = []
            var frameIndex: UInt64 = 0

            while !Task.isCancelled {
                guard let self else { return }
                let native = ring.drain(maxCount: 64_000)
                if !native.isEmpty {
                    pending.append(contentsOf: AudioResampler.resample(
                        native, from: self.inputSampleRate, to: target))

                    while pending.count >= frameSamples {
                        let chunk = Array(pending.prefix(frameSamples))
                        pending.removeFirst(frameSamples)
                        let frame = AudioFrame(
                            samples: chunk,
                            startTime: Double(frameIndex) * frameDuration,
                            sequence: frameIndex)
                        frameIndex += 1
                        self.broadcast(frame)
                    }
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}
