import AVFoundation
import Foundation

/// Continuous, "streaming" speech-to-text.
///
/// This machine's `whisper-cli` build predates the streaming flags
/// (`--adatabase`, `--print-partial`), so *incremental* decoding isn't available
/// through it. Instead we approximate live captions with a robust rolling
/// strategy:
///
///        mic - AVAudioEngine installTap -> native-rate Float32 PCM
///              -> linear downsample -> 16 kHz / mono
///              -> accumulate -> every `flushInterval`, transcribe the WINDOW
///                 (uncommitted audio + a short overlap), append only the NEW
///                 words, then COMMIT: drop the audio already turned into text
///                 while keeping a small overlap so a boundary word isn't split.
///
/// The OLD approach re-transcribed the WHOLE buffer each tick, which was O(n^2)
/// *and* let whisper re-word earlier segments: the longest-common-prefix diff
/// then leaked stray fragments (e.g. old "recognize speech" -> new "recognize
/// speeches" printed a stray "es"). Committing each window once fixes both:
/// each sample is transcribed exactly once, so earlier words are never re-worded,
/// and the short overlap + word-level dedup stops a word being split across two
/// flushes.
///
/// Next step to *true* streaming: VAD-based segmenting (flush on detected pauses
/// instead of a fixed timer) or a streaming decoder (`sherpa-onnx`
/// paraformer-streaming, or a newer whisper.cpp with `--adatabase` +
/// `--print-partial`) - both get sub-second latency.
@MainActor
public final class StreamingSttController: ObservableObject {

    public enum Phase {
        case idle
        case live              // mic on, transcribing in the background
        case stopping          // flushing + tearing down
     }

     // Published UI state.
    @Published public private(set) var transcript = ""

     /// Number of native-rate samples already turned into `transcript` (excludes a
     /// carried-over overlap tail). Each flush only re-feeds the overlap instead of
     /// the whole buffer.
    private var committed = 0

     @Published public private(set) var phase: Phase = .idle
     @Published public private(set) var status = "idle - press Live to start"

     // Tunables.
    public var flushInterval = DispatchTimeInterval.seconds(4)      // live refresh
    public var maxTotalSeconds: Double = 180.0                      // hard cap on buffer
    public var overlapSeconds: Double = 0.4                         // re-fed each flush
    private let minSeconds: Double = 0.6                            // ignore < 0.6 s windows
    private var minSamplesAt16k: Int { Int(minSeconds * 16_000) }

     // Model / backend (whisper.cpp out-of-process backend).
    private var model: SttModel
    private let backend: WhisperCliBackend
    /// Scratch dir for per-window WAVs (Finding 2: injected, not the static path).
    private let cacheDir: URL

     // Audio engine + tap fields.
    private var engine: AVAudioEngine?
    private var inputSampleRate: Double = 16_000
    private var busy = false              // a transcription is in flight
    private var flushTimer: DispatchSourceTimer?
    private var sessionToken = UUID()      // cancels stale flushes on restart

     // The tap runs on a real-time audio thread; the only fields it touches are
     // `samples`/`lastRMS`, guarded by `samplesLock` and held for the minimum time.
    private var samples: [Float] = []
    private var lastRMS: Float = 0        // VAD-lite gate (guarded by samplesLock)
    private let samplesLock = NSLock()

    public init(model: SttModel = .largeV3Turbo,
                backend: WhisperCliBackend = WhisperCliBackend(),
                cacheDir: URL = ModelPaths.fromEnvironment().cacheDir) {
        self.model = model
        self.backend = backend
        self.cacheDir = cacheDir
    }

     /// Switch the whisper model the live stream uses (called from Settings).
     /// Takes effect on the next flush; ignored while a session is live.
    public func useModel(_ newModel: SttModel) {
        guard phase == .idle else { return }
        self.model = newModel
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
            samplesLock.withLock {
                self.samples = []            // fresh this session
                self.lastRMS = 0
             }
            committed = 0
            self.transcript = ""
            phase = .live
            status = "Listening (live)"
            startFlushTimer()
         } catch {
            status = "Could not start the mic: \(error.localizedDescription)"
            phase = .idle
            teardown()
         }
     }

     /// Stop the mic and do a final transcript so the last few seconds
     /// are not dropped.
    public func stop() async {
        guard phase != .idle else { return }
        phase = .stopping
        status = "Transcribing final segment..."
        teardown()
        let remaining = samplesLock.withLock { self.samples }
        if !remaining.isEmpty {
            await transcribeNew()
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

     /// A timer that kicks a windowed transcription every `flushInterval`.
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
                                   >= Int(self.minSeconds * max(self.inputSampleRate, 1))
            if hasSpeech && enough {
                self.status = "...transcribing"
                Task { await self.transcribeNew() }
             }
         }
        flushTimer = timer
        timer.resume()
     }

     /// Transcribe only the newest window (uncommitted audio + a short overlap),
     /// append the new words, then commit that window so it is never re-transcribed.
     @discardableResult
     @MainActor
    private func transcribeNew() async -> String {
          // Missing 2: if the caller cancelled (Stop / quit), don't keep transcribing.
        try? Task.checkCancellation()
        guard !busy else { return "" }
        busy = true

         // Snapshot the whole native-rate buffer.
        let raw = samplesLock.withLock { self.samples }
        let rate = max(inputSampleRate, 1)
        let overlapNative = Int(max(overlapSeconds, 0) * rate)

         // Window start: don't re-transcribe committed audio, but re-feed a short
         // overlap so a word straddling the boundary isn't split.
        let startNative = max(0, min(committed, raw.count) - overlapNative)
        let windowNative = startNative < raw.count ? Array(raw[startNative...]) : [Float]()

        let pcm16k = StreamingSttController.resampleTo16k(windowNative, from: rate)
        guard pcm16k.count >= minSamplesAt16k else {
             // Not enough audio yet - keep accumulating.
            busy = false
            return ""
         }

        let token = sessionToken
        let url = cacheDir
              .appendingPathComponent("stream-\(token).wav")
        var committedAdvanced = false
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

                  // COMMIT: everything in this snapshot is now transcribed. Drop the
                  // pre-overlap prefix (it will never be re-fed); a short overlap tail
                  // remains in the buffer so the next flush can bridge a straddling
                  // word. `committed` is MainActor-only, so it needs no lock.
                committed = raw.count
                samplesLock.withLock {
                    if self.samples.count > startNative {
                        self.samples.removeFirst(startNative)
                       }
                  }
                if committed > startNative {
                    committed -= startNative
                  }

                   // Append only the NEW words (the re-fed overlap is deduped away).
                transcript = StreamingSttController.appendDeduped(
                    transcript, segment: clean)
                status = "Live - \(result.model.label)      "
                      + String(format: "%.1fs", result.durationSeconds)
                committedAdvanced = true
             }
         } catch {
             // One flaky tick mustn't tear the session down; the window stays
             // uncommitted so the same audio (plus anything new) is retried.
            let msg = (error as? LocalizedError)?.localizedDescription ?? "transcript error"
            status = "Paused: \(msg)"
         }

         // Release the busy flag.
        busy = false

        if committedAdvanced {
             // Safety cap on the (otherwise small) buffer, in native-rate samples.
            let cap = Int(maxTotalSeconds * rate)
            samplesLock.withLock {
                if self.samples.count > cap {
                    self.samples.removeFirst(self.samples.count - cap)
                 }
             }
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

     // Append `segment` to `accumulated`, dropping the leading words of `segment`
     // that merely re-echo the trailing words of `accumulated`.
     //
     // The live window deliberately re-includes a short overlap of the previous
     // window (so a word straddling the boundary isn't split). Whisper
     // re-transcribes that overlap, so its output often starts by repeating words
     // already shown. We strip the longest *contiguous* run of leading words that
     // duplicates the tail of `accumulated` (capped at `maxOverlapWords`), then
     // append what's left.
     //
     // Returns `accumulated` unchanged when nothing new was found (fully re-echoed
     // or empty segment).
    static func appendDeduped(_ accumulated: String,
                              segment: String,
                              maxOverlapWords: Int = 8) -> String {
        let acc = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        let seg = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if seg.isEmpty { return acc }
        if acc.isEmpty { return seg }

        let a = acc.split(whereSeparator: { $0.isWhitespace })
                       .map(String.init)
        let s = seg.split(whereSeparator: { $0.isWhitespace })
                       .map(String.init)

             // Longest k for which the HEAD of the segment repeats the TAIL of the
             // accumulated transcript, in forward order: the overlap re-transcribes
             // the words we just committed, so they reappear at the front. Strip
             // that echo and keep whatever is newer.
        let maxOverlap = min(maxOverlapWords, a.count, s.count)
        var k = 0
        var probe = 1
        while probe <= maxOverlap {
            if Array(a[(a.count - probe)...]) == Array(s[..<probe]) {
                k = probe
                }
            probe += 1
            }

        let newWords = s.dropFirst(k)
        if newWords.isEmpty { return acc }
        return acc + " " + newWords.joined(separator: " ")
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

     // Write a 16 kHz mono 16-bit PCM WAV from Float32 samples in [-1, 1].
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
        u32(16)                          // PCM subchunk size
        u16(1)                           // audio format = PCM
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
