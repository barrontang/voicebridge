import AVFoundation

/// Captures microphone audio to a 16 kHz / mono / 16-bit PCM WAV via
/// `AVAudioRecorder` — the recorder writes the exact format whisper.cpp expects,
/// so no post-processing tap is needed.
///
/// AVAudioRecorder is the right primitive for *batch* capture (push-to-talk,
/// "record meeting" segments). For true word-partial streaming you'd instead
/// `installTap` on the input node; that variant is a documented extension point.
public final class MicrophoneCapture: NSObject {

    private var recorder: AVAudioRecorder
    private let outputURL: URL
    private var isRecording = false

    public init(outputURL: URL) throws {
        self.outputURL = outputURL
        // Clean any stale file so the format write succeeds.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
             }
        // `try` init: a missing device / unsupported format surfaces here.
        self.recorder = try AVAudioRecorder(url: outputURL, settings: AudioFormats.target)
        super.init()
       }

       /// Request microphone permission (macOS API; fails fast when denied).
    @MainActor
    public static func requestInputPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { (granted) in
            DispatchQueue.main.async { completion(granted) }
           }
       }

    public func start() throws {
        guard recorder.prepareToRecord() else {
            throw VoiceError.audioDecodeFailed(url: outputURL.path, reason: "prepareToRecord failed")
              }
        recorder.record()
        isRecording = true
        }

    public func stop() {
        guard isRecording else { return }
        recorder.stop()
        isRecording = false
        }

    public var capturing: Bool { isRecording }
    public var writtenURL: URL { outputURL }
}
