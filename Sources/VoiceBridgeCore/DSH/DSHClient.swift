import Foundation

/// Sends one prompt to DeepSeek Harness (DSH) and returns its answer.
///
/// This is the "brain" half of the voice interface: VoiceBridge turns speech
/// into text, `DSHClient` asks DSH, and VoiceBridge speaks the reply. It talks
/// to DSH through its documented headless CLI —
///
///     dsh --profile headless [--patch FILE] "task"
///
/// — which answers one task on stdout and exits. No private API, no server
/// session to manage, and every DSH provider (DeepSeek, Copilot, a local Ollama
/// model) works, because the profile/patch decides the model, not this client.
public struct DSHClient: Sendable {

    public struct Configuration: Sendable {
        /// Absolute path to the `dsh` launcher.
        public var executable: String
        /// The DSH profile to boot (`headless` answers one task and exits).
        public var profile: String
        /// Extra patch overlays (e.g. one that selects a provider/model).
        public var patches: [String]
        /// Working directory DSH runs the task in.
        public var workingDirectory: String?
        /// An agent task can run tools; give it room, but not forever.
        public var timeout: TimeInterval

        public init(
            executable: String,
            profile: String = "headless",
            patches: [String] = [],
            workingDirectory: String? = nil,
            timeout: TimeInterval = 300
        ) {
            self.executable = executable
            self.profile = profile
            self.patches = patches
            self.workingDirectory = workingDirectory
            self.timeout = timeout
        }
    }

    /// Where the desktop app installs its CLI launcher.
    public static let appBundleLauncher =
        "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Where `scripts/install-cli.sh` puts the example patches.
    public static var installedPatchDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voicebridge/dsh", isDirectory: true)
    }

    /// The DSH patch that answers with a local Ollama model (`qwen3.5:4b`).
    /// Mirrors `examples/dsh-ollama.yml` (a test keeps the two identical).
    public static let localOllamaPatch = #"""
        # DSH patch for `voicebridge-cli ask`: answer with a local Ollama model, so the
        # whole voice loop (whisper → DSH → TTS) stays on this Mac.
        #
        #   voicebridge-cli ask --patch examples/dsh-ollama.yml
        #
        # Needs `ollama pull qwen3.5:4b` and an OLLAMA_API_KEY credential (any value —
        # Ollama ignores it, DSH requires one): export OLLAMA_API_KEY=ollama
        - id: credentials
          name: "@deepseek-ai/dsh-credentials-local"
          disabled: false
        - id: llm-pi-ai
          name: "@deepseek-ai/dsh-llm-pi-ai"
          config:
            providers:
              ollama:
                displayName: Ollama (local)
                api: openai-completions
                baseURL: http://127.0.0.1:11434/v1
                apiKeyEnv: OLLAMA_API_KEY
                models:
                  - id: qwen3.5:4b
                    name: Qwen3.5 4B
                    contextWindow: 32768
                    maxTokens: 4096
        - id: agent-default-model
          name: "@deepseek-ai/dsh-agent-default-model"
          config:
            provider: ollama
            model: qwen3.5:4b
        """#

    /// Write the local-model patch to `~/.voicebridge/dsh/` if it is not there
    /// yet, and return its path. The app uses this so the local mode works
    /// without the repo checkout or `scripts/install-cli.sh`.
    public static func ensureLocalOllamaPatch(
        in directory: URL = DSHClient.installedPatchDirectory
    ) throws -> String {
        let file = directory.appendingPathComponent("dsh-ollama.yml")
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try localOllamaPatch.write(to: file, atomically: true, encoding: .utf8)
        }
        return file.path
    }

    /// Resolve a `--patch` argument to an existing file, or nil.
    ///
    /// Tried in order: as given (absolute, `~`, or relative to `cwd`), then by
    /// file name in `~/.voicebridge/dsh/`. The fallback is what makes
    /// `--patch examples/dsh-ollama.yml` work outside the repo; checking up
    /// front means a bad path fails *before* the user speaks, with one line
    /// instead of DSH's Node stack trace.
    public static func resolvePatch(
        _ path: String,
        cwd: String = FileManager.default.currentDirectoryPath,
        installed: URL = DSHClient.installedPatchDirectory,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let direct =
            expanded.hasPrefix("/")
            ? expanded : URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path
        if exists(direct) { return direct }
        let fallback = installed.appendingPathComponent((expanded as NSString).lastPathComponent)
            .path
        return exists(fallback) ? fallback : nil
    }

    /// Find `dsh`: `VOICEBRIDGE_DSH` → `$PATH` → the desktop app bundle.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override = environment["VOICEBRIDGE_DSH"], isExecutable(override) {
            return override
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/dsh"
            if isExecutable(candidate) { return candidate }
        }
        return isExecutable(appBundleLauncher) ? appBundleLauncher : nil
    }

    /// One answer, and the DSH session it belongs to.
    public struct Reply: Sendable, Equatable {
        public let text: String
        /// Pass this back as `session` to continue the same conversation.
        public let sessionID: String?
    }

    /// The exact argument vector for one prompt. Pure, so it is unit-tested.
    ///
    /// `--json` makes DSH emit newline-delimited events: the session id, the
    /// model's thinking (separately — nothing to strip), and a `final` answer.
    /// `--session-id` resumes a persisted session, which is what turns a
    /// sequence of one-shot calls into a conversation: DSH keeps the history,
    /// the tool results and the working state between turns.
    ///
    /// The prompt is one positional argument (no shell involved), so quotes,
    /// newlines and CJK reach DSH intact.
    public static func arguments(
        prompt: String, profile: String, patches: [String], session: String? = nil
    ) -> [String] {
        var args = ["--profile", profile]
        for patch in patches { args += ["--patch", patch] }
        args.append("--json")
        if let session { args += ["--session-id", session] }
        args.append(prompt)
        return args
    }

    /// Ask DSH. Pass the previous reply's `sessionID` to continue that
    /// conversation; `nil` starts a new one.
    public func ask(_ prompt: String, session: String? = nil) async throws -> Reply {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Reply(text: "", sessionID: session) }
        let result = try await Shell.run(
            at: configuration.executable,
            arguments: Self.arguments(
                prompt: trimmed, profile: configuration.profile,
                patches: configuration.patches, session: session),
            workingDirectory: configuration.workingDirectory,
            timeout: configuration.timeout)
        let parsed = Self.parseEvents(result.stdout)
        return Reply(text: Self.cleanAnswer(parsed.text), sessionID: parsed.sessionID ?? session)
    }

    /// Read DSH's `--json` event stream.
    ///
    /// The `final` event carries the answer; if a run ends without one (an
    /// interrupted turn), the streamed `text` events are joined instead.
    /// `thinking` events are ignored — reasoning is never read aloud. Lines that
    /// are not JSON (a plain-text build) are kept as the answer.
    public static func parseEvents(_ stdout: String) -> (text: String, sessionID: String?) {
        var sessionID: String?
        var finalText: String?
        var streamed: [String] = []
        var plain: [String] = []
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = event["type"] as? String
            else {
                plain.append(String(line))
                continue
            }
            if let id = event["sessionId"] as? String { sessionID = id }
            switch type {
            case "final": finalText = event["text"] as? String
            case "text": if let t = event["text"] as? String { streamed.append(t) }
            default: break
            }
        }
        let text =
            finalText ?? (streamed.isEmpty ? plain.joined(separator: "\n") : streamed.joined())
        return (text, sessionID)
    }

    /// Strip what should not be read aloud.
    ///
    /// A thinking model's headless output can start with a `reasoning:` block
    /// before the answer; markdown fences and emphasis are noise for a voice.
    public static func cleanAnswer(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        // Drop a leading "dsh: reasoning:" / "reasoning:" block up to the first
        // blank line — the answer follows it.
        if let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
            first.hasSuffix("reasoning:")
        {
            if let blank = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).isEmpty
            }) {
                lines = Array(lines[(blank + 1)...])
            } else if lines.count > 1 {
                // No blank line: reasoning is everything but the last line.
                lines = [lines[lines.count - 1]]
            }
        }
        var text = lines.filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        for marker in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
