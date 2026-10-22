import Foundation
import AVFoundation

/// edge-tts: Microsoft's online Edge voices via a Microsoft WebSocket gateway.
/// Best fidelity of the lot, but NOT offline — text leaves the device.
///
/// `voice` is an edge voice name, e.g. "zh-CN-XiaoxiaoNeural",
/// "en-US-AriaNeural", "en-GB-SoniaNeural".
///
/// Runtime: `pip install edge-tts`. Invoked as:
///   edge-tts --voice NAME --file text.txt --write-media out.mp3
///
/// **Text never goes on the command line.** The text is written to a
/// `0600` temporary file and passed with `--file`; the previous `--text <text>`
/// form exposed the user's words to every process on the machine (`ps`) and
/// blew past `ARG_MAX` on long inputs. The temp file is removed as soon as the
/// child exits.
    // SAFETY (@unchecked Sendable): all stored properties are immutable `let`s.
    // A future mutable cache must be an `actor` or locked, not a bare var.
public final class EdgeTTSBackend: TTSBackend, @unchecked Sendable {

    private let binary: String
    private let binaryLocator: BinaryLocator

    public init(modelDirectory: URL = ModelPaths.fromEnvironment().root,
                binaryLocator: BinaryLocator = BinaryLocator(),
                binaryOverride: String? = nil) {
        self.binaryLocator = binaryLocator
        let raw = binaryOverride
                  ?? ProcessInfo.processInfo.environment["VOICEBRIDGE_EDGE_TTS"]
        if let raw {
            self.binary = raw
          } else {
            self.binary = binaryLocator.resolve(preferred: "VOICEBRIDGE_EDGE_TTS", "edge-tts")
            }
        }

    public var displayName: String { "Edge TTS (online, Microsoft voices)" }

         /// The text for this engine is synthesized on Microsoft
         /// servers: it leaves the device. Surface a privacy warning when used.
    public var requiresNetwork: Bool { true }

         /// edge-tts writes MP3, not WAV.
    public var preferredFileExtension: String { "mp3" }

          /// edge-tts needs an installed binary AND a network connection; we gate on
          /// the binary so "offline" is an explicit config choice, not a silence.
    public func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: binary)
           || binaryLocator.isAvailable("edge-tts")
          }

    public func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
           // Missing 2: bail early on caller cancellation.
        try Task.checkCancellation()

        let voiceName = voice ?? "en-US-AriaNeural"
           // edge-tts writes mp3, not wav; honour the caller's extension.
        let media = outputPath.deletingPathExtension().appendingPathExtension("mp3")

           // 1. Stage the text in a private temp file (never on the argv).
        let textFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicebridge-edge-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: textFile, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: textFile.path)
        defer { try? FileManager.default.removeItem(at: textFile) }

        let args = [binary,
                       "--voice", voiceName,
                       "--file", textFile.path,
                       "--write-media", media.path]
        // The child is a Python program: on failure it prints a stack trace
        // (on stdout *or* stderr). We read both and turn them into one
        // actionable line.
        let outcome = try await Pipeline.runWithStdinRaw(input: "", at: args,
                                                          workingDirectory: nil,
                                                          timeout: 120)
        if outcome.status != 0 {
            throw VoiceError.onlineServiceRejected(
                engine: "edge-tts",
                reason: EdgeTTSBackend.diagnose(outcome.stderr + "\n" + outcome.stdout))
            }
        guard FileManager.default.fileExists(atPath: media.path) else {
            throw VoiceError.onlineServiceRejected(
                engine: "edge-tts",
                reason: "no audio came back (network problem?)")
             }
        // edge-tts may write `.mp3` even when asked for another extension.
        if media != outputPath {
            try? FileManager.default.removeItem(at: outputPath)
            try FileManager.default.moveItem(at: media, to: outputPath)
        }
        return outputPath
         }

    /// Turn the child's stack trace into one short, actionable line.
    ///
    /// The classic failure is Microsoft's endpoint refusing the WebSocket
    /// handshake with a 403 because the installed `edge-tts` is too old - the
    /// fix is a one-line upgrade, and the user should not have to read a
    /// Python traceback to find that out.
    static func diagnose(_ stderr: String) -> String {
        let text = stderr.lowercased()
        if text.contains("wsserverhandshakeerror")
            || text.contains("invalid response status")
            || text.contains("403") {
            return "Microsoft's service refused the request (HTTP 403). "
                + "The installed edge-tts client is too old - upgrade it with "
                + "`pipx upgrade edge-tts` (or `pip install -U edge-tts`)."
            }
        if text.contains("timed out") || text.contains("timeout") {
            return "the request to Microsoft's service timed out."
            }
        if text.contains("connection") || text.contains("network")
            || text.contains("unreachable") || text.contains("dns") {
            return "could not reach Microsoft's service - check the network."
            }
        // Fall back to the last meaningful line of the trace.
        let lines = stderr
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Traceback") && !$0.hasPrefix("File ") }
        if let last = lines.last {
            return String(last.prefix(160))
            }
        return "the service refused the request."
        }
}
