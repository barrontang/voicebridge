import AVFoundation
import Darwin
import Foundation
import VoiceBridgeCore

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
            case "stt": try await runSTT(Array(args.dropFirst()))
            case "transcribe": try await runBatch(Array(args.dropFirst()))
            case "tts": try await runTTS(Array(args.dropFirst()))
            case "ask": try await runAsk(Array(args.dropFirst()))
            case "ping": runPing()
            case "--version", "-v", "version": printVersion()
            case "help", "-h", "--help": printMenu()
            default:
                print("Unknown subcommand: \(args[0])")
                printMenu()
            }
        } catch {
            print("❌ \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - STT
    static func runSTT(_ args: [String]) async throws {
        guard !args.isEmpty else {
            print("usage: stt <audio> [lang] [model]")
            return
        }
        let audio = URL(fileURLWithPath: args[0])
        let lang = args.count > 1 ? args[1] : nil
        let model = SttModel(rawValue: args.count > 2 ? args[2] : "large-v3-turbo") ?? .largeV3Turbo

        print("→ transcribing \(audio.lastPathComponent) with \(model.label)")
        // Any input format is fine: transcode to the 16 kHz / mono shape
        // whisper.cpp wants (the file is a WAV already? → a straight copy).
        let prepared = try prepareAudio(audio)
        let t = try await sttBackend().transcribe(
            audio: prepared, language: lang, model: model, useTimestamps: false)
        print("—")
        print(t.text)
        print("—")
        var meta = "lang=\(t.language)  model=\(t.model.rawValue)"
        if t.durationSeconds > 0 {
            meta +=
                "  audio=\(String(format: "%.2f", t.durationSeconds))s"
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
            case "--in": inputDir = URL(fileURLWithPath: it.next() ?? ".")
            case "--out": outputDir = URL(fileURLWithPath: it.next() ?? ".")
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
        let files = try fm.contentsOfDirectory(
            at: inputDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
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
                let t = try await sttBackend().transcribe(
                    audio: prepared, language: language, model: model, useTimestamps: false)
                let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let out = outDir.appendingPathComponent(
                    file.deletingPathExtension().lastPathComponent + ".txt")
                try text.write(to: out, atomically: true, encoding: .utf8)
                print(
                    "✓ \(file.lastPathComponent) → \(out.lastPathComponent) (\(text.count) chars)")
                done += 1
            } catch {
                print("✗ \(file.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }
        print("\(done) transcribed, \(failed) failed")
    }

    /// The STT backend: a local whisper.cpp server when one is configured,
    /// otherwise the out-of-process `whisper-cli`.
    static func sttBackend() -> any WhisperBackend {
        if let server = WhisperServerBackend.fromEnvironment() { return server }
        return WhisperCliBackend()
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
                AudioTranscoder.isCanonical(file.processingFormat)
            {
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
                    text = v!
                    textGiven = true
                }
            case "--voice": voice = it.next()
            case "--stdin": useStdin = true
            case "-": useStdin = true
            case "--engine":
                if let raw = it.next() {
                    // Accepts the slug (edge-tts), a legacy display label, or a
                    // short alias (piper/kokoro/edge/fish/system).
                    if let m = TTSMode(identifier: raw) {
                        engine = m
                    } else {
                        print(
                            "unknown --engine '\(raw)' "
                                + "(try piper|kokoro|edge|fish|system)")
                    }
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
        if useStdin {
            text = readAllStdin()
        } else if !textGiven && stdinHasData() {
            text = readAllStdin()
        }

        // A call that expected a pipe but nothing arrived should not hear the demo.
        if !textGiven && (useStdin || !isInteractiveStdin()),
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            print("[no text supplied on --stdin]")
            return
        }

        print(
            "→ speaking \(text.count) chars via \(engine.displayName); voice=\(voice ?? "default")")
        // The CLI has no UI to ask for consent, so anything that transmits is
        // announced on stderr — for *every* online engine, not just edge-tts
        // (a remote Drama 3 server used to pass silently).
        if EnginePrivacy.requiresNetwork(
            mode: engine,
            modelRoot: ModelPaths.fromEnvironment().root)
        {
            let warn =
                "[privacy] \(engine.displayName) is online: the text is sent to "
                + EnginePrivacy.remoteServiceName(for: engine)
                + " and is not kept on-device. Use --engine system|piper|kokoro to stay local.\n"
            FileHandle.standardError.write(Data(warn.utf8))
        }
        // One-shot: selecting an engine here must not rewrite the user's
        // saved settings (the app's choice survives a CLI smoke test).
        let cfg = TTSConfigManager(persistChanges: false)
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

    // MARK: - Voice interface for DeepSeek Harness

    /// Talk to DSH: speech in → whisper → `dsh --profile headless` → speech out.
    ///
    ///   voicebridge-cli ask                       listen 8 s, ask, speak the answer
    ///   voicebridge-cli ask --listen 15 --loop    hands-free conversation
    ///   voicebridge-cli ask --audio q.m4a         a recorded question
    ///   voicebridge-cli ask --text "你好"          skip STT (no mic needed)
    ///
    /// Options: --lang zh|en|… (default auto), --model M, --engine say|piper|edge|…
    /// (default `say`), --voice V,
    /// --profile P (default headless), --patch FILE (repeatable; e.g. selects
    /// the DSH model), --no-speak (print only).
    static func runAsk(_ args: [String]) async throws {
        var audio: URL?
        var text: String?
        var listenSeconds: Double = 8
        var loop = false
        var language: String?
        var model = SttModel.largeV3Turbo
        // `say` by default: offline, and reliable from a headless process (the
        // in-place AVSpeech engine needs an app run loop to report completion).
        var engine = "say"
        var voice: String?
        var profile = "headless"
        var patches: [String] = []
        var speak = true

        var it = args.makeIterator()
        while let tok = it.next() {
            switch tok {
            case "--audio": audio = it.next().map { URL(fileURLWithPath: $0) }
            case "--text": text = it.next()
            case "--listen": listenSeconds = Double(it.next() ?? "") ?? listenSeconds
            case "--loop": loop = true
            case "--lang": language = it.next()
            case "--model": model = SttModel(rawValue: it.next() ?? "") ?? model
            case "--engine": engine = it.next() ?? engine
            case "--voice": voice = it.next()
            case "--profile": profile = it.next() ?? profile
            case "--patch": if let p = it.next() { patches.append(p) }
            case "--no-speak": speak = false
            default: print("ignoring: \(tok)")
            }
        }

        guard let dsh = DSHClient.locate() else {
            throw VoiceError.binaryNotFound(
                component: "dsh",
                hint: "Install DeepSeek Harness, or set VOICEBRIDGE_DSH to the dsh launcher.")
        }
        let client = DSHClient(
            configuration: .init(
                executable: dsh, profile: profile, patches: patches,
                workingDirectory: FileManager.default.currentDirectoryPath))

        repeat {
            // 1. The question, as text.
            let question: String
            if let text {
                question = text
            } else {
                let clip: URL
                if let audio {
                    clip = try prepareAudio(audio)
                } else {
                    clip = try await recordClip(seconds: listenSeconds)
                }
                print("→ transcribing…")
                question = try await sttBackend().transcribe(
                    audio: clip, language: language, model: model, useTimestamps: false
                ).text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !question.isEmpty else {
                print("[heard nothing]")
                if loop { continue } else { return }
            }
            print("🗣  \(question)")

            // 2. Ask DSH.
            print("→ asking DeepSeek Harness (\(profile))…")
            let answer = try await client.ask(question)
            print("🤖 \(answer.isEmpty ? "[no answer]" : answer)")

            // 3. Speak the answer.
            if speak, !answer.isEmpty {
                if engine == "say" {
                    try await sayAloud(answer, voice: voice)
                } else {
                    var ttsArgs = ["--text", answer, "--engine", engine]
                    if let voice { ttsArgs += ["--voice", voice] }
                    try await runTTS(ttsArgs)
                }
            }
            // A fixed question or file is a single turn.
        } while loop && text == nil && audio == nil
    }

    /// Speak with macOS `say`, choosing a Chinese voice for Chinese text.
    static func sayAloud(_ text: String, voice: String?) async throws {
        let say = "/usr/bin/say"
        var args: [String] = []
        if let voice {
            args = ["-v", voice]
        } else if WordDiff.isMostlyCJK(text),
            let zh = await firstWorkingSayVoice(
                ["Tingting", "Lanlan", "Meijia", "Han", "Sinji"])
        {
            args = ["-v", zh]
        }
        _ = try await Shell.run(at: say, arguments: args + [text], timeout: 600)
    }

    /// The first `say` voice that is installed (a missing one exits non-zero).
    static func firstWorkingSayVoice(_ candidates: [String]) async -> String? {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-say-probe.aiff").path
        for name in candidates {
            if (try? await Shell.run(at: "/usr/bin/say", arguments: ["-v", name, "-o", probe, "好"]))
                != nil
            {
                return name
            }
        }
        return nil
    }

    /// Record `seconds` of microphone audio to a temp 16 kHz WAV.
    static func recordClip(seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-ask-\(UUID().uuidString).wav")
        let session = PushToTalkSession()
        try await session.start(url: url)
        print("🎙  listening for \(Int(seconds)) s — speak now…")
        try? await Task.sleep(for: .seconds(seconds))
        guard let recorded = await session.stop() else {
            throw VoiceError.audioDeviceUnavailable(reason: "nothing was recorded")
        }
        return recorded
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
        var fds = pollfd(
            fd: FileHandle.standardInput.fileDescriptor,
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
        print("  TTS  fish audio   : \(fishStatus(roots))")
        print("  TTS  system (AVSpeech): always available")
        print("  models root   : \(roots.root.path)")
        print("  microphone    : \(micPermissionStatus())")
        if !whisperAvailable() {
            print(
                "\nHint: `brew install whisper-cpp` then set WHISPER_CLI, or run scripts/fetch-whisper-turbo.sh."
            )
        }
        if !piperAvailable() {
            print("Hint: `scripts/install-piper.sh` to enable Piper (offline TTS).")
        }
        if let hint = fishHint(roots) { print(hint) }
        if micPermissionStatus().contains("denied")
            || micPermissionStatus().contains("notDetermined")
        {
            print(
                "Hint: grant microphone access in System Settings > Privacy & Security > Microphone."
            )
        }
    }

    // All discovery routes through the single locator (Finding 4).
    static func whisperAvailable() -> Bool {
        if let p = ProcessInfo.processInfo.environment["WHISPER_CLI"],
            FileManager.default.isExecutableFile(atPath: p)
        {
            return true
        }
        return locator.isAvailable("whisper-cli")
    }
    static func piperAvailable() -> Bool {
        if let p = ProcessInfo.processInfo.environment["VOICEBRIDGE_PIPER"],
            FileManager.default.isExecutableFile(atPath: p)
        {
            return true
        }
        return locator.isAvailable("piper")
    }
    /// A Fish Audio Drama 3 server is configured, and (for a local one)
    /// whether it is actually listening.
    static func fishStatus(_ paths: ModelPaths) -> String {
        guard let backend = FishAudioBackend.fromEnvironment(modelRoot: paths.root) else {
            return "false"
        }
        let whereName = backend.isLocal ? "local MLX" : (backend.baseURL.host ?? "remote")
        return backend.isAvailable()
            ? "true (\(whereName) server responding)"
            : "configured (\(whereName)), server not running"
    }

    static func fishHint(_ paths: ModelPaths) -> String? {
        if FishAudioBackend.localModelExists(root: paths.root) {
            return "Hint: `scripts/start-drama3-mlx.sh` to run Drama 3 locally "
                + "(downloaded 4-bit MLX checkpoint)."
        }
        return nil
    }
    static func edgeAvailable() -> Bool {
        if let p = ProcessInfo.processInfo.environment["VOICEBRIDGE_EDGE_TTS"],
            FileManager.default.isExecutableFile(atPath: p)
        {
            return true
        }
        return locator.isAvailable("edge-tts")
    }

    /// Missing 5: report microphone TCC status explicitly on a fresh terminal,
    /// where an unsigned binary is silently denied and AVAudioEngine's failure is
    /// otherwise unintelligible.
    static func micPermissionStatus() -> String {
        #if canImport(AVFoundation)
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized: return "authorized"
            case .denied:
                return "DENIED — grant it in System Settings > Privacy & Security > Microphone"
            case .notDetermined: return "notDetermined — will prompt on first use"
            case .restricted: return "restricted by policy"
            @unknown default: return "unknown"
            }
        #else
            return "n/a (no AVFoundation)"
        #endif
    }

    /// The CLI version (kept in sync with the app bundle's short version).
    static let version = "1.2.0"

    static func printVersion() {
        print("voicebridge-cli \(version)")
    }

    private static func printMenu() {
        print(
            """
             voicebridge-cli -- run STT / TTS without opening the GUI
             stt   <audio> [lang] [model]   transcribe one file (any format)
             transcribe --in <dir> --out <dir>   transcribe a whole folder
             tts   --text "..." [--voice V] [--engine piper|system|edge-tts|kokoro|fish-audio]
                   `... | voicebridge-cli tts` [--engine ...]  speak piped text
             ask   [--listen S] [--loop] [--audio F] [--text T] [--lang L] [--patch P]
                   voice interface for DeepSeek Harness: speak → dsh → hear the answer
             ping                            show engine, model, & mic availability
             --version                       print the version
             help                            this menu
            """)
    }
}
