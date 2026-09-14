import Foundation
import AVFoundation

/// edge-tts: Microsoft's online Edge voices via a Microsoft WebSocket gateway.
/// Best fidelity of the lot, but NOT offline — text leaves the device.
///
/// `voice` is an edge voice name, e.g. "zh-CN-XiaoxiaoNeural",
/// "en-US-AriaNeural", "en-GB-SoniaNeural".
///
/// Runtime: `pip install edge-tts`. Invoked as:
///   edge-tts --text "..." --voice <voice> --write-media out.mp3
public final class EdgeTTSBackend: TTSBackend, @unchecked Sendable {

    private let binary: String

    public init(binaryOverride: String? = nil, modelDirectory: URL = ModelPaths.root) {
        let raw = binaryOverride
             ?? ProcessInfo.processInfo.environment["VOICEBRIDGE_EDGE_TTS"]
             ?? "edge-tts"
        self.binary = Shell.resolve(raw)
      }

    public var displayName: String { "Edge TTS (online, Microsoft voices)" }

      /// edge-tts needs an installed binary AND a network connection; we gate on
      /// the binary so "offline" is an explicit config choice, not a silence.
    public func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: binary)
         || Shell.pathLookup("edge-tts") != nil
      }

    public func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
        let voiceName = voice ?? "en-US-AriaNeural"
         // edge-tts writes mp3, not wav. Play it via AVAudioPlayer if needed.
        let mp3 = outputPath.deletingPathExtension().appendingPathExtension("mp3")
        let args = [binary,
                     "--voice", voiceName,
                     "--text", text,
                     "--write-media", mp3.path]
        try Pipeline.runWithStdin(input: "", at: args, workingDirectory: nil, timeout: 120)
        guard FileManager.default.fileExists(atPath: mp3.path) else {
            throw VoiceError.processFailed(component: "edge-tts", status: -1,
                                           stderr: "No audio produced (no network?).")
        }
         // For a uniform API, copy into the requested .wav slot is not trivial
         // (mp3 vs pcm); callers should accept mp3 for this engine.
        try? FileManager.default.copyItem(at: mp3, to: outputPath)
        return outputPath
      }
}
