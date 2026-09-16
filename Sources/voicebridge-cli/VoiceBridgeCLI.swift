import Foundation
import VoiceBridgeCore
import AVFoundation

/// voicebridge-cli — a headless demo that exercises VoiceBridgeCore so you can
/// see the STT→TTS pipeline work *before* wiring the SwiftUI app. Not shipped in
/// the GUI target, but useful for CI / smoke tests.
///
/// Usage:
///    voicebridge-cli stt   <audio> [lang] [model]
///    voicebridge-cli tts   --text "hello" [--voice NAME] [--engine piper|system|edgeTTS|kokoro]
///    voicebridge-cli ping                  // report engine + model availability
///
/// Examples:
///    ./voicebridge-cli stt  out.wav en large-v3-turbo
///    ./voicebridge-cli tts   --text "This is Piper, fully offline." --voice en_US-lessac-medium
///    ./voicebridge-cli ping
@main
@MainActor
struct Main {
     // `@main` + `@MainActor`: the config manager and `speak()` are main-actor
      // isolated, so the whole command dispatch runs on the main actor.
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
              printMenu()
              return
             }
        do {
            switch args[0] {
            case "stt":      try await runSTT(Array(args.dropFirst()))
            case "tts":      try await runTTS(Array(args.dropFirst()))
            case "ping":     runPing()
            case "help","-h","--help": printMenu()
            default:
                print("Unknown subcommand: \(args[0])"); printMenu()
             }
          } catch {
            print("❌ \(error.localizedDescription)"); exit(1)
           }
       }

       // MARK: - STT
    static func runSTT(_ args: [String]) async throws {
        guard !args.isEmpty else {
            print("usage: stt <audio> [lang] [model]"); return
            }
        let audio = URL(fileURLWithPath: args[0])
        let lang = args.count > 1 ? args[1] : nil
        let model = SttModel(rawValue: args.count > 2 ? args[2] : "large-v3-turbo") ?? .largeV3Turbo

        print("→ transcribing \(audio.lastPathComponent) with \(model.label)")
        let t = try await WhisperCliBackend().transcribe(
            audio: audio, language: lang, model: model, useTimestamps: false)
         print("—"); print(t.text); print("—")
        var meta = "lang=\(t.language)  model=\(t.model.rawValue)"
        if t.durationSeconds > 0 {
             meta += "  audio=\(String(format: "%.2f", t.durationSeconds))s"
                    + "  factor=\(String(format: "%.2f", t.realtimeFactor))x"
              } else {
            meta += "  wallclock=\(String(format: "%.2f", t.realtimeFactor))s"
              }
        print(meta)
       }

       // MARK: - TTS
    static func runTTS(_ args: [String]) async throws {
        var text = "Hello. This is a demo of VoiceBridge's engine selector."
        var voice: String? = nil
        var engine: TTSMode = .piper
        var noPlay = false

        var it = args.makeIterator()
        while let tok = it.next() {
            switch tok {
            case "--text":  text = it.next() ?? text
            case "--voice": voice = it.next()
            case "--engine":
                if let raw = it.next() {
                    // Accept either a rawValue or a short alias (piper/kokoro/edge/system).
                    var m = TTSMode(rawValue: raw)
                    if m == nil {
                        switch raw.lowercased()
                                       .trimmingCharacters(in: .whitespacesAndNewlines) {
                            case "system", "builtin", "built-in", "avspeech": m = .system
                            case "piper": m = .piper
                            case "kokoro": m = .kokoro
                            case "edge", "edge-tts", "edgetts": m = .edgeTTS
                            default: print("unknown --engine '\(raw)' (try piper|kokoro|edge|system)")
                        }
                    }
                    if let m { engine = m }
                }
            case "--no-play": noPlay = true
            default: print("ignoring: \(tok)")
              }
           }

        print("→ speaking \(text.count) chars via \(engine.rawValue); voice=\(voice ?? "default")")
        let cfg = TTSConfigManager()
        cfg.selectedMode = engine
        cfg.selectedModelFile = voice
        // Always synthesize with play:false, then play via a reliable path below
         // (avoids AVAudioPlayer's runloop-spin hanging a headless CLI).
        let result = try await TTSManager(config: cfg)
                       .speak(text, mode: engine, voice: voice, play: false)
        print("output: \(result.url.path)")
      if result.fellBack { print("\(result.statusLine)") }

        if !noPlay {
            if engine == .system {
                // Built-in engine speaks in place (no file). Re-speak with play.
               try await TTSManager(config: cfg)
                           .speak(text, mode: .system, voice: voice, play: true)
                 } else if FileManager.default.fileExists(atPath: result.url.path) {
                // afplay blocks until playback completes — robust in a CLI.
                _ = try await Shell.run(at: ProcessInfo.processInfo.environment["AFPLAY"] ?? "afplay",
                                      arguments: [result.url.path])
                print("✓ played via afplay")
                 } else {
                print("[no on-disk audio to play; run with --no-play to skip]")
                 }
          }
        }

// MARK: - helpers
    // Findings 4 & 5: binary discovery goes through one `BinaryLocator` (not the
    // copy-pasted checks the CLI used to roll here), and we surface microphone
    // TCC status explicitly instead of letting AVAudioEngine emit an opaque error.
    static let locator = BinaryLocator()

     static func runPing() {
        let roots = ModelPaths.fromEnvironment()
        print("VoiceBridge engine & model availability:")
        print("  STT  whisper-cli : \(whisperAvailable())")
        print("  TTS  piper        : \(piperAvailable())")
        print("  TTS  edge-tts     : \(edgeAvailable())")
        print("  TTS  system (AVSpeech): always available")
        print("  models root   : \(roots.root.path)")
        print("  microphone    : \(micPermissionStatus())")
        if !whisperAvailable() {
             print("\nHint: `brew install whisper-cpp` then set WHISPER_CLI, or run scripts/fetch-whisper-turbo.sh.")
              }
        if !piperAvailable() {
           print("Hint: `scripts/install-piper.sh` to enable Piper (offline TTS).")
             }
         if micPermissionStatus().contains("denied") || micPermissionStatus().contains("notDetermined") {
            print("Hint: grant microphone access in System Settings > Privacy & Security > Microphone.")
          }
       }

        // All discovery routes through the single locator (Finding 4).
       static func whisperAvailable() -> Bool {
       if let p = ProcessInfo.processInfo.environment["WHISPER_CLI"],
             FileManager.default.isExecutableFile(atPath: p) { return true }
        return locator.isAvailable("whisper-cli")
          }
     static func piperAvailable() -> Bool {
        if let p = ProcessInfo.processInfo.environment["VOICEBRIDGE_PIPER"],
             FileManager.default.isExecutableFile(atPath: p) { return true }
        return locator.isAvailable("piper")
       }
    static func edgeAvailable() -> Bool {
        if let p = ProcessInfo.processInfo.environment["VOICEBRIDGE_EDGE_TTS"],
             FileManager.default.isExecutableFile(atPath: p) { return true }
        return locator.isAvailable("edge-tts")
       }

        /// Missing 5: report microphone TCC status explicitly on a fresh terminal,
        /// where an unsigned binary is silently denied and AVAudioEngine's failure is
       /// otherwise unintelligible.
    static func micPermissionStatus() -> String {
         #if canImport(AVFoundation)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:      return "authorized"
        case .denied:          return "DENIED — grant it in System Settings > Privacy & Security > Microphone"
        case .notDetermined:   return "notDetermined — will prompt on first use"
        case .restricted:      return "restricted by policy"
        @unknown default:      return "unknown"
         }
        #else
        return "n/a (no AVFoundation)"
         #endif
      }

       private static func printMenu() {
        print("""
                 voicebridge-cli -- run STT / TTS without opening the GUI
                 stt   <audio> [lang] [model]   e.g. `stt out.wav en large-v3-turbo`
                 tts   --text "..." [--voice V] [--engine piper|system|edgeTTS|kokoro]
                 ping                            show engine, model, & mic availability
                 help                            this menu
                """)
        }
    }
