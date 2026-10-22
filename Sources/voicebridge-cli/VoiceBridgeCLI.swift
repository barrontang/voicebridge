import Foundation
import VoiceBridgeCore
import AVFoundation
import Darwin

/// voicebridge-cli — the headless entry point to VoiceBridgeCore: scripting,
/// CI and smoke tests without opening the GUI.
///
/// Usage:
///    voicebridge-cli stt       <audio> [lang] [model]      transcribe one file
///    voicebridge-cli transcribe --in <dir> --out <dir>     transcribe a folder
///    voicebridge-cli tts       --text "hello" [--voice NAME] [--engine ...]
///    voicebridge-cli tts       --stdin                     read the text from STDIN
///    <agent output> | voicebridge-cli tts                 speak piped text
///    voicebridge-cli ping                                 engine / model report
///    voicebridge-cli --version
///
/// Any audio format works for `stt` (mp3, m4a, wav, …): the file is
/// transcoded to the 16 kHz / mono shape whisper.cpp wants.
///
/// Examples:
///    ./voicebridge-cli stt  recording.m4a en large-v3-turbo
///    ./voicebridge-cli transcribe --in ./inbox --out ./outbox
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
            case "transcribe": try await runBatch(Array(args.dropFirst()))
            case "tts":      try await runTTS(Array(args.dropFirst()))
            case "ping":     runPing()
            case "--version","-v","version": printVersion()
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
          // Any input format is fine: transcode to the 16 kHz / mono shape
         // whisper.cpp wants (the file is a WAV already? → a straight copy).
        let prepared = try prepareAudio(audio)
        let t = try await WhisperCliBackend().transcribe(
            audio: prepared, language: lang, model: model, useTimestamps: false)
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

       // MARK: - Batch

       /// Transcribe every audio file in a folder.
    ///
    ///   voicebridge-cli transcribe --in ./inbox --out ./outbox [--lang en]
    ///
    /// Writes `<name>.txt` next to a copy of the transcript for each input
    /// file. Files that fail are reported and skipped - one bad file must not
    /// stop the batch.
    static func runBatch(_ args: [String]) async throws {
        var inputDir: URL?
        var outputDir: URL?
        var language: String?
        var model = SttModel.largeV3Turbo

        var it = args.makeIterator()
        while let tok = it.next() {
            switch tok {
            case "--in":   inputDir = URL(fileURLWithPath: it.next() ?? ".")
            case "--out":  outputDir = URL(fileURLWithPath: it.next() ?? ".")
            case "--lang": language = it.next()
            case "--model": model = SttModel(rawValue: it.next() ?? "") ?? .largeV3Turbo
            default: print("ignoring: \(tok)")
            }
        }
        guard let inputDir else {
            print("usage: transcribe --in <dir> --out <dir> [--lang LANG] [--model MODEL]")
            return
        }
        let outDir = outputDir ?? inputDir
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: inputDir,
                                              includingPropertiesForKeys: nil,
                                              options: [.skipsHiddenFiles])
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else {
            print("no audio files in \(inputDir.path)")
            return
        }

        var done = 0
        var failed = 0
        for file in files {
            do {
                let prepared = try prepareAudio(file)
                let t = try await WhisperCliBackend().transcribe(
                    audio: prepared, language: language, model: model, useTimestamps: false)
                let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let out = outDir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".txt")
                try text.write(to: out, atomically: true, encoding: .utf8)
                print("✓ \(file.lastPathComponent) → \(out.lastPathComponent) (\(text.count) chars)")
                done += 1
            } catch {
                print("✗ \(file.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }
        print("\(done) transcribed, \(failed) failed")
    }

        /// The file extensions the batch mode picks up.
    static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "flac", "ogg", "aiff", "aif", "caf", "mp4", "mov",
    ]

       /// Transcode `url` to a 16 kHz / mono WAV and return the path to use.
    ///
    /// A file that is already in the canonical shape is used as-is (no copy,
    /// no re-encode).
    static func prepareAudio(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let cache = ModelPaths.fromEnvironment().cacheDir
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)

        if url.pathExtension.lowercased() == "wav" {
            // Cheap check: is it already 16 kHz / mono?
            if let file = try? AVAudioFile(forReading: url),
               AudioTranscoder.isCanonical(file.processingFormat) {
                return url
            }
        }
        let out = cache.appendingPathComponent("cli-\(UUID().uuidString).wav")
        return try AudioTranscoder.transcodeToWAV(from: url, to: out)
    }

// MARK: - TTS
    static func runTTS(_ args: [String]) async throws {
        var text = "Hello. This is a demo of VoiceBridge's engine selector."
        var voice: String? = nil
        var engine: TTSMode = .piper
        var noPlay = false
        var useStdin = false
        var textGiven = false

        var it = args.makeIterator()
        while let tok = it.next() {
            switch tok {
            case "--text":
                   let v = it.next()
                    if v == nil || v == "-" {
                            // `-` (or no value): read text from STDIN so an agent's
                            // output can be piped in — `... | voicebridge-cli tts`.
                         useStdin = true
                           } else {
                           text = v!; textGiven = true
                                 }
            case "--voice": voice = it.next()
            case "--stdin": useStdin = true
            case "-":       useStdin = true
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

        // Resolve the text to speak:
        //    * `--stdin` / `-` / `--text -` reads STDIN (agent-piped output);
        //    * a bare pipe with no flag speaks whatever is piped in;
        //    * an interactive terminal with no text keeps the demo string.
        //
        // The "bare pipe" case only reads STDIN when data is *actually*
        // waiting: a script that runs the CLI with an inherited, idle stdin
        // (no TTY, no bytes) used to block forever on readDataToEndOfFile.
        if useStdin { text = readAllStdin() }
        else if !textGiven && stdinHasData() { text = readAllStdin() }

          // A call that expected a pipe but nothing arrived should not hear the demo.
        if !textGiven && (useStdin || !isInteractiveStdin()),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
             print("[no text supplied on --stdin]"); return
              }

        print("→ speaking \(text.count) chars via \(engine.rawValue); voice=\(voice ?? "default")")
      if engine == .edgeTTS {
           // P1: the CLI has no UI, so warn on stderr that the input transits
           // Microsoft's servers rather than staying on-device.
         let warn = "[privacy] \(engine.rawValue) is online: the input text is sent to a Microsoft gateway by edge-tts and is not kept on-device.\n"
         FileHandle.standardError.write(Data(warn.utf8))
             }
        let cfg = TTSConfigManager()
        cfg.selectedMode = engine
        cfg.selectedModelFile = voice
        // The in-place engine (AVSpeech) speaks *while* it synthesizes, so it
        // is only asked to play when playback was requested. A file-producing
        // engine is synthesized with `play: false` and played afterwards
        // through `afplay` (see below).
        let inPlace = engine == .system
        let result = try await TTSManager(config: cfg)
                       .speak(text, mode: engine, voice: voice, play: inPlace && !noPlay)
        if result.fellBack { print("\(result.statusLine)") }
        if result.hasAudioFile { print("output: \(result.url.path)") }

        if !noPlay {
            if inPlace {
                // Already spoken in place; nothing to play.
            } else if result.hasAudioFile {
                try await playFile(result.url)
            } else {
                print("[no on-disk audio to play; run with --no-play to skip]")
                 }
          }
        }

       /// Play a generated audio file from a headless CLI.
       ///
       /// `afplay` is the reliable path (it blocks until the audio finishes and
       /// needs no run loop). It has to be resolved to an **absolute** path:
       /// `Process` does not search `$PATH`, so a bare "afplay" would fail to
       /// launch. When `afplay` isn't available we fall back to the in-process
       /// player.
    static func playFile(_ url: URL) async throws {
        if let afplay = BinaryLocator().locate("afplay") {
            _ = try await Shell.run(at: afplay, arguments: [url.path])
            print("✓ played via afplay")
        } else {
            try Playback.playAudio(url)
            print("✓ played in-process")
        }
    }

// MARK: - helpers

       /// Read every byte off STDIN without blocking the terminal case —
       /// readDataToEndOfFile returns immediately at EOF.
    static func readAllStdin() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
       }

       /// True when STDIN is a terminal, i.e. the user did not pipe text in.
    static func isInteractiveStdin() -> Bool {
        isatty(FileHandle.standardInput.fileDescriptor) == 1
       }

       /// True when STDIN has bytes (or is at EOF) ready to be read *right
       /// now*. A zero-timeout `poll` answers that without blocking, so a CLI
       /// run from a script with an idle stdin never hangs.
    static func stdinHasData() -> Bool {
        if isInteractiveStdin() { return false }
        var fds = pollfd(fd: FileHandle.standardInput.fileDescriptor,
                         events: Int16(POLLIN),
                         revents: 0)
        let ready = poll(&fds, 1, 0)
        return ready > 0 && (fds.revents & Int16(POLLIN)) != 0
    }
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

       /// The CLI version (kept in sync with the app bundle's short version).
    static let version = "1.1.0"

    static func printVersion() {
        print("voicebridge-cli \(version)")
    }

       private static func printMenu() {
        print("""
                 voicebridge-cli -- run STT / TTS without opening the GUI
                 stt   <audio> [lang] [model]   transcribe one file (any format)
                 transcribe --in <dir> --out <dir>   transcribe a whole folder
                 tts   --text "..." [--voice V] [--engine piper|system|edgeTTS|kokoro]
                       `... | voicebridge-cli tts` [--engine ...]  speak piped text
                 ping                            show engine, model, & mic availability
                 --version                       print the version
                 help                            this menu
                """)
        }
    }
