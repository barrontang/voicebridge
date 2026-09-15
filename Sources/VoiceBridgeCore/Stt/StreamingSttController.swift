import AVFoundation
import Foundation

/// Continuous, "streaming" speech-to-text.
///
/// This machine's `whisper-cli` build predates the streaming flags
/// (`--adatabase`, `--print-partial`), so *incremental* decoding isn't
/// available through it. Instead we approximate live captions with a robust
/// rolling strategy:
///
///        mic - AVAudioEngine installTap -> native-rate Float32 PCM
///              -> linear downsample -> 16 kHz / mono
///              -> accumulate -> every `flushInterval`, snapshot the whole buffer
///              -> write 16-bit WAV -> WhisperCliBackend.transcribe(full)
///              -> @Published -> live-updating transcript
///
/// Re-transcribing the whole buffer each tick makes the captions *refine* as
/// you speak and stay self-consistent (no dropped sentence boundaries). Cost
/// is O(n^2) in session length, so the window is capped (`maxTotalSeconds`).
///
/// Next step to *true* streaming: VAD-based segmenting (flush on detected
/// pauses instead of a fixed timer) or a streaming decoder
/// (`sherpa-onnx` paraformer-streaming, or a newer whisper.cpp with
/// `--adatabase` + `--print-partial`) - both drop the O(n^2) cost and get
/// sub-second latency.
@MainActor
public final class StreamingSttController: ObservableObject {

     public enum Phase {
        case idle
        case live            // mic on, transcribing in the background
        case stopping        // flushing + tearing down
       }

         // Published UI state.
    @Published public private(set) var transcript = ""

            // The full text of the previous flush, so we only append the *new*
        // words each tick instead of re-showing everything from the start.
        private var lastFullText = ""
     @Published public private(set) var phase: Phase = .idle
     @Published public private(set) var status = "idle - press Live to start"

          // Tunables.
    public var flushInterval = DispatchTimeInterval.seconds(4)     // live refresh
    public var maxTotalSeconds: Double = 180.0                     // cap the window
   private let flushMinSamplesAt16k = Int(0.6 * 16_000)           // ignore < 0.6 s

          // Model / backend (whisper.cpp out-of-process backend).
    private let model: SttModel
    private let backend: WhisperCliBackend

          // Audio engine + tap.
    private var engine: AVAudioEngine?
    private var inputSampleRate: Double = 16_000
    private var lastRMS: Float = 0      // VAD-lite gate (guarded by samplesLock)
    private var busy = false            // a transcription is in flight
    private var flushTimer: DispatchSourceTimer?
    private var sessionToken = UUID()    // cancels stale flushes on restart

          // The tap runs on a real-time audio thread; the only field it
          // touches is `samples`, guarded by `samplesLock` and held for the
          // minimum time.
     private var samples: [Float] = []
    private let samplesLock = NSLock()

    public init(model: SttModel,
                backend: WhisperCliBackend = WhisperCliBackend()) {
        self.model = model
        self.backend = backend
         }

    public var isRunning: Bool { phase != .idle }

          // MARK: - start / stop

    public func start() async {
        guard phase == .idle else { return }
        guard await Self.requestMicPermission() else {
            status = "Microphone denied - enable it in System Settings > Privacy & Security > Microphone."
            return
                }
        do {
            try setupEngine()
            sessionToken = UUID()
            samplesLock.withLock { self.samples = [] }    // fresh this session
            self.transcript = ""
            self.lastFullText = ""
            phase = .live
            status = "Listening (live)"
            startFlushTimer()
              } catch {
            status = "Could not start the mic: \(error.localizedDescription)"
            phase = .idle
            teardown()
                 }
          }

          // Stop the mic and do a final transcript so the last few seconds
          // are not dropped.
    public func stop() async {
        guard phase != .idle else { return }
        phase = .stopping
        status = "Transcribing final segment..."
        teardown()
        let remaining = samplesLock.withLock { self.samples }
        if !remaining.isEmpty {
            await transcribeFull()
              }
           // End the session only if Live was the active phase.
        if phase == .stopping {
            phase = .idle
            status = "Idle."
                }
         }

        // MARK: - audio

    private func setupEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inFormat = inputNode.outputFormat(forBus: 0)
        let rate = inFormat.sampleRate
        guard rate > 0 else {
            throw VoiceError.audioDecodeFailed(
                url: "(tap)", reason: "input format had no sample rate")
                }
        inputSampleRate = rate

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) {
              [weak self] buffer, _ in
                // Real-time thread: read the mic samples, copy them under the
                // lock, and never block.
            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let slice = Array(UnsafeBufferPointer(start: ch[0], count: n))
            let rms = StreamingSttController.rms(of: slice)
                guard let self else { return }
            self.samplesLock.withLock {
                self.samples.append(contentsOf: slice)
                self.lastRMS = rms
                   }
              }

        engine.prepare()
        try engine.start()
        self.engine = engine
          }

          // MARK: - flush + transcribe

        // A timer that kicks a full transcription every `flushInterval`.
    private func startFlushTimer() {
        flushTimer?.cancel()
        let token = sessionToken
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.sessionToken == token,
                self.phase == .live,
                   !self.busy else { return }
            let hasSpeech = self.samplesLock.withLock { self.lastRMS } > 0.002
            let enough = self.samplesLock.withLock { self.samples.count }
                                >= self.flushMinSamplesAt16k
            if hasSpeech && enough {
                self.status = "...transcribing"
                Task { await self.transcribeFull() }
                  }
                }
        flushTimer = timer
        timer.resume()
          }

        // Transcribe the whole accumulated buffer and update the live transcript.
    @discardableResult
     @MainActor
     private func transcribeFull() async -> String {
        guard !busy else { return "" }
        busy = true

        let raw = samplesLock.withLock { self.samples }
        guard raw.count >= flushMinSamplesAt16k else {
            busy = false
            return ""
               }
        let pcm16k = StreamingSttController.resampleTo16k(raw, from: inputSampleRate)
        guard pcm16k.count >= flushMinSamplesAt16k else {
            busy = false
            return ""
               }

        let token = sessionToken
        let url = ModelPaths.cacheDir
                          .appendingPathComponent("stream-\(token).wav")
        do {
            try StreamingSttController.writeWAV16(pcm16k, to: url)
                // `transcribe` is nonisolated + async, so it hops off the main
                // actor for the heavy whisper run.
            let result = try await backend.transcribe(
                audio: url,
                language: nil,
                model: model,
                useTimestamps: false)
            if sessionToken == token {
                 let clean = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                       // Re-transcribing the WHOLE buffer each tick would otherwise repeat
                       // everything from the start. Keep only the NEW words this flush found
                       // since the previous one.
                     let delta = StreamingSttController.deltaSince(lastFullText, full: clean)
                     lastFullText = clean
                     if !delta.isEmpty {
                        transcript = transcript.isEmpty ? delta : transcript + " " + delta
                           }
                         status = "Live - \(result.model.label)     "
                                   + String(format: "%.1fs", result.durationSeconds)
                           }
              } catch {
                // One flaky tick mustn't tear the session down.
            let msg = (error as? LocalizedError)?.localizedDescription ?? "transcript error"
            status = "Paused: \(msg)"
                }

             // Release the busy flag and trim the window.
        busy = false
        samplesLock.withLock {
            let cap = Int(maxTotalSeconds * 16_000)
            if samples.count > cap { samples.removeFirst(samples.count - cap) }
               }
         return transcript
         }

          // MARK: - teardown + helpers

    private func teardown() {
        flushTimer?.cancel()
        flushTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        }

        // Linearly resample Float32 PCM (any rate) to 16 kHz mono.
    static func resampleTo16k(_ input: [Float], from fromRate: Double) -> [Float] {
        let target = 16_000.0
        guard !input.isEmpty, fromRate > 0, target > 0 else { return [] }
        let ratio = target / fromRate
        let outCount = Int(Double(input.count) * ratio)
        guard outCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
               // Interpolate source location for output sample i+1 (skip final
               // one so we never read past the end).
            let position = Double(i + 1) / ratio - 1
            let i0 = Int(floor(position))
            let i1 = min(i0 + 1, input.count - 1)
            let frac = position - Double(i0)
             let left = max(0, i0)
            out[i] = input[left] + (input[i1] - input[left]) * Float(frac)
            }
        return out
         }

        // Rough RMS energy - cheap VAD gate ("> 0.002" ~ -34 dBFS).
    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        return sqrt(acc / Float(samples.count))
         }

          // Append only the words that appeared since the previous flush. `full` is the
          // WHOLE buffer re-transcribed this tick; diff it against `old` and return the new
          // suffix (trimmed) so the transcript GROWS rather than repeating from the start.
        static func deltaSince(_ old: String, full: String) -> String {
             let full = full.trimmingCharacters(in: .whitespacesAndNewlines)
             if full.isEmpty { return "" }
             let old = old.trimmingCharacters(in: .whitespacesAndNewlines)
             if old.isEmpty { return full }
             if full == old { return "" }
             if full.hasPrefix(old) {
                 return String(full.dropFirst(old.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                 }
               // Whisper can drift between flushes; fall back to the longest-common-prefix.
             let a = Array(old)
             let b = Array(full)
             var i = 0
             while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
             if i == b.count { return "" }                 // full is a prefix of old: none new
             return String(b[i...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

        // Ask for mic access without blocking the main thread (async).
    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                   // Resume exactly once.
                 if !resumed {
                     resumed = true
                     cont.resume(returning: granted)
                       }
                 }
             }
         }

        // Write a 16 kHz mono 16-bit PCM WAV from Float32 samples in [-1, 1].\
    static func writeWAV16(_ samples: [Float], to url: URL, sampleRate: Double = 16_000) throws {
        // Pure byte-level 16-bit mono PCM WAV writer - no AVAudioFile, which
        // intermittently asserts inside AudioToolbox when written rapidly from
        // the live-transcription timer (SIGTRAP / CAAssertRtn).
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let bitsPerSample = 16
        let channels = 1
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = samples.count * blockAlign
        var out = Data()

        func u32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { out.append(contentsOf: $0) }
          }
        func u16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { out.append(contentsOf: $0) }
           }

        out.append(contentsOf: Array("RIFF".utf8))
        u32(36 + UInt32(dataBytes))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        u32(16)                        // PCM subchunk size
        u16(1)                         // audio format = PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bitsPerSample))
        out.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))

         // 16-bit little-endian samples.
        var samples16 = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, Float(samples[i])))
            samples16[i] = Int16(clamped * 32_767.0)
               }
        out.append(contentsOf: samples16.withUnsafeBytes { Array($0) })
        try out.write(to: url)
       }
}
