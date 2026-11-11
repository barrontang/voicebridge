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
        /// `read-only`, `workspace-write` (DSH's default) or `danger-full-access`.
        ///
        /// `read-only` is what turns the window into "answer questions about this
        /// folder" — DSH then cannot write anything, and an escalation attempt is
        /// refused because headless has no approval channel.
        public var permissionMode: String?
        /// The environment to hand DSH; `nil` means `childEnvironment()`.
        public var environment: [String: String]?

        public init(
            executable: String,
            profile: String = "headless",
            patches: [String] = [],
            workingDirectory: String? = nil,
            timeout: TimeInterval = 300,
            permissionMode: String? = nil,
            environment: [String: String]? = nil
        ) {
            self.executable = executable
            self.profile = profile
            self.patches = patches
            self.workingDirectory = workingDirectory
            self.timeout = timeout
            self.permissionMode = permissionMode
            self.environment = environment
        }
    }

    /// Where the desktop app installs its CLI launcher.
    public static let launcherPathInBundle = "Contents/Resources/runtime/cli/bin/dsh"

    /// Where the desktop app installs its CLI launcher (`/Applications`).
    public static let appBundleLauncher =
        "/Applications/DeepSeek Harness.app/" + launcherPathInBundle

    /// Both places a person actually installs a Mac app.
    ///
    /// `/Applications` alone is not enough: dragging an app to `~/Applications`
    /// (no admin password) is common, and the Finder launch path means the
    /// bundle is often the *only* way `dsh` can be found — see `locate`.
    public static var appBundleLaunchers: [String] {
        [
            "/Applications/DeepSeek Harness.app/" + launcherPathInBundle,
            ("~/Applications/" as NSString).expandingTildeInPath + "/DeepSeek Harness.app/"
                + launcherPathInBundle,
        ]
    }

    /// Where a `dsh` from a package manager usually lands.
    static let commonBinDirectories = [
        "/opt/homebrew/bin",  // Homebrew on Apple Silicon
        "/usr/local/bin",  // Homebrew on Intel, or a manual symlink
        "~/.local/bin",  // scripts/install-cli.sh
        "~/.bun/bin",
        "~/.npm-global/bin",
        "~/.volta/bin",
    ]

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// The environment DSH is given.
    ///
    /// A GUI app launched from Finder inherits almost nothing — no shell
    /// exports, and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. So we rebuild one:
    /// the parent's variables, plus the directories `dsh` is commonly installed
    /// in, plus `OLLAMA_API_KEY`.
    ///
    /// The last one is not a real secret: Ollama ignores it, but DSH's provider
    /// config (`apiKeyEnv`) refuses to route without *some* value, and the local
    /// patch can only name a variable, not a literal. Setting it here is what
    /// makes "Local model (Ollama)" work in a Finder-launched app.
    public static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in commonBinDirectories {
            let expanded = (dir as NSString).expandingTildeInPath
            if !dirs.contains(expanded) { dirs.append(expanded) }
        }
        env["PATH"] = dirs.joined(separator: ":")
        if env["OLLAMA_API_KEY"] == nil { env["OLLAMA_API_KEY"] = "ollama" }
        return env
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

    /// Find `dsh`, in the order a person would look: an explicit choice, the
    /// environment, `$PATH`, the usual package-manager bins, then the app bundle.
    ///
    /// `$PATH` alone is not enough for a GUI app: launched from Finder it is
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, so a Homebrew `dsh` is invisible and the
    /// desktop app's bundled launcher is the only thing left. `override` is the
    /// user's explicit pick from Settings, which outranks everything.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        override: String? = nil,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for candidate in candidates(environment: environment, override: override)
        where isExecutable(candidate) {
            return candidate
        }
        return nil
    }

    /// Every place `locate` will look, in order. Pure, so it is unit-tested.
    static func candidates(environment: [String: String], override: String?) -> [String] {
        var paths: [String] = []
        for raw in [override, environment["VOICEBRIDGE_DSH"]] {
            guard let raw, !raw.isEmpty else { continue }
            paths.append((raw as NSString).expandingTildeInPath)
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            paths.append("\(dir)/dsh")
        }
        for dir in commonBinDirectories {
            paths.append((dir as NSString).expandingTildeInPath + "/dsh")
        }
        paths.append(contentsOf: appBundleLaunchers)
        return paths
    }

    /// One answer, and the DSH session it belongs to.
    public struct Reply: Sendable, Equatable {
        public let text: String
        /// Pass this back as `session` to continue the same conversation.
        public let sessionID: String?

        public init(text: String, sessionID: String?) {
            self.text = text
            self.sessionID = sessionID
        }
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
        prompt: String, profile: String, patches: [String], session: String? = nil,
        permissionMode: String? = nil
    ) -> [String] {
        var args = ["--profile", profile]
        for patch in patches { args += ["--patch", patch] }
        if let permissionMode { args += ["--permission-mode", permissionMode] }
        args.append("--json")
        if let session { args += ["--session-id", session] }
        args.append(prompt)
        return args
    }

    /// What DSH is doing right now, for the "working…" line in the chat.
    public enum Progress: Sendable, Equatable {
        case starting
        case thinking
        /// A tool ran: a short phrase ("Writing probe.txt…"), plus the raw tool name.
        case tool(phrase: String, name: String)
        /// A piece of the answer, as it is streamed.
        case text(String)
    }

    /// Ask DSH. Pass the previous reply's `sessionID` to continue that
    /// conversation; `nil` starts a new one.
    ///
    /// `onProgress` is called while the run is still going (from a background
    /// thread), so a 5-minute agent task can show what it is doing instead of a
    /// spinner. Cancelling the surrounding task kills the child process.
    public func ask(
        _ prompt: String,
        session: String? = nil,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Reply {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Reply(text: "", sessionID: session) }
        onProgress?(.starting)
        let result: Shell.Result
        do {
            result = try await Shell.run(
                at: configuration.executable,
                arguments: Self.arguments(
                    prompt: trimmed, profile: configuration.profile,
                    patches: configuration.patches, session: session,
                    permissionMode: configuration.permissionMode),
                workingDirectory: configuration.workingDirectory,
                timeout: configuration.timeout,
                environment: configuration.environment ?? Self.childEnvironment(),
                onLine: onProgress.map { report -> @Sendable (ProcessLine) -> Void in
                    { line in
                        guard line.channel == .stdout,
                            let progress = Self.progress(forLine: line.text)
                        else { return }
                        report(progress)
                    }
                })
        } catch VoiceError.processFailed(_, _, let stderr) {
            throw DSHError(
                message: Self.friendlyError(stderr: stderr),
                kind: Self.kind(forStderr: stderr))
        } catch VoiceError.processTimeout(_, let seconds) {
            throw DSHError(
                message: "DeepSeek Harness did not answer within \(Int(seconds)) s. "
                    + "Long agent tasks can take longer than the limit — raise the "
                    + "timeout, or ask for less.")
        }
        let parsed = Self.parseEvents(result.stdout)
        return Reply(text: Self.cleanAnswer(parsed.text), sessionID: parsed.sessionID ?? session)
    }

    /// A DSH failure, worded for a chat bubble.
    public struct DSHError: LocalizedError, Equatable {
        public enum Kind: Sendable, Equatable {
            /// The persisted session id is gone; retrying without it works.
            case missingSession
            case missingCredential
            case other
        }

        public let message: String
        public let kind: Kind
        public var errorDescription: String? { message }

        public init(message: String, kind: Kind = .other) {
            self.message = message
            self.kind = kind
        }
    }

    /// Classify a failure so the caller can *recover* from the recoverable one.
    static func kind(forStderr stderr: String) -> DSHError.Kind {
        if stderr.contains("does not exist") && stderr.contains("session") {
            return .missingSession
        }
        if stderr.contains("MISSING_CREDENTIAL") { return .missingCredential }
        return .other
    }

    /// Read one line of `--json` output into a progress event.
    ///
    /// Pure and tolerant: a non-JSON line (a plain-text build) is simply "no
    /// progress", never an error.
    public static func progress(forLine line: String) -> Progress? {
        guard let data = line.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = event["type"] as? String
        else { return nil }
        switch type {
        case "thinking": return .thinking
        case "text":
            return (event["text"] as? String).map { .text($0) }
        case "tool_call":
            guard let tool = event["tool"] as? String else { return nil }
            let input = (event["input"] as? [String: Any]) ?? [:]
            return .tool(phrase: phrase(forTool: tool, input: input), name: tool)
        default: return nil
        }
    }

    /// A short human phrase for a tool call ("Writing probe.txt…").
    static func phrase(forTool tool: String, input: [String: Any]) -> String {
        let path =
            (input["file_path"] as? String) ?? (input["path"] as? String)
            ?? (input["filePath"] as? String)
        let name = path.map { ($0 as NSString).lastPathComponent }
        switch tool.lowercased() {
        case "write":
            return name.map { "Writing \($0)…" } ?? "Writing a file…"
        case "edit", "apply_patch", "patch":
            return name.map { "Editing \($0)…" } ?? "Editing a file…"
        case "read":
            return name.map { "Reading \($0)…" } ?? "Reading a file…"
        case "bash", "shell":
            guard let command = input["command"] as? String else { return "Running a command…" }
            let short = command.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return "Running \(short.prefix(48))…"
        case "grep", "glob", "search":
            return "Searching the folder…"
        default:
            return "Using \(tool)…"
        }
    }

    /// Turn DSH's stderr into one sentence a user can act on.
    ///
    /// DSH reports failures as `dsh: CODE: detail` — or, for a crash, a Node
    /// stack trace. Showing either raw (with the launcher's full path in front)
    /// is noise in a chat bubble; the known codes get a next step.
    public static func friendlyError(stderr: String) -> String {
        // Every third-party invocation of the desktop app's CLI gets this line
        // from Electron, on success and on failure alike. It says nothing about
        // what went wrong (the environment *is* inherited — verified), and it
        // would otherwise become the "unknown error" fallback.
        let noise = [
            "electron/shell/app/node_main.cc",
            "Node.js environment variables are disabled",
        ]
        let lines = stderr.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { line in !noise.contains(where: line.contains) }
        if lines.contains(where: { $0.contains("MISSING_CREDENTIAL") }) {
            return "DeepSeek Harness has no API key for this model. Choose “Local model "
                + "(Ollama)”, or add a key in DeepSeek Harness › Settings › Models."
        }
        if lines.contains(where: { $0.contains("AUTH") }) {
            return "DeepSeek Harness rejected the API key for this model. Check it in "
                + "DeepSeek Harness › Settings › Models, or choose “Local model (Ollama)”."
        }
        if lines.contains(where: {
            $0.contains("429") || $0.localizedCaseInsensitiveContains("rate limit")
                || $0.localizedCaseInsensitiveContains("too many requests")
        }) {
            return "The model provider is rate-limiting DeepSeek Harness. "
                + "Wait a moment and try again."
        }
        if lines.contains(where: { $0.contains("does not exist") && $0.contains("session") }) {
            return "That conversation is no longer in DeepSeek Harness."
        }
        if let overlay = lines.first(where: { $0.contains("failed to read overlay") }) {
            return "DeepSeek Harness could not read a settings patch: "
                + (overlay.components(separatedBy: "overlay ").last ?? overlay)
        }
        if lines.contains(where: { $0.contains("ECONNREFUSED") || $0.contains("fetch failed") }) {
            return "DeepSeek Harness could not reach its model. If you use the local model, "
                + "make sure Ollama is running (`ollama serve`)."
        }
        // `dsh: CODE: detail` → "detail"; else the first `Error:` line; else
        // the last non-empty line.
        if let line = lines.first(where: { $0.hasPrefix("dsh: ") }) {
            let parts = line.dropFirst(5).split(separator: ":", maxSplits: 1)
            let detail = (parts.count == 2 ? parts[1] : parts[0])
                .trimmingCharacters(in: .whitespaces)
            return "DeepSeek Harness: \(detail)"
        }
        if let error = lines.first(where: { $0.hasPrefix("Error: ") }) {
            return "DeepSeek Harness: \(error.dropFirst(7))"
        }
        return "DeepSeek Harness failed: \(lines.last(where: { !$0.isEmpty }) ?? "unknown error")"
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
