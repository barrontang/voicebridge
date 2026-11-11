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

    /// The exact argument vector for one prompt. Pure, so it is unit-tested.
    ///
    /// The prompt is passed as one positional argument (no shell is involved),
    /// so quotes, newlines and CJK reach DSH intact.
    public static func arguments(prompt: String, profile: String, patches: [String]) -> [String] {
        var args = ["--profile", profile]
        for patch in patches { args += ["--patch", patch] }
        args.append(prompt)
        return args
    }

    /// Ask DSH and return its answer text.
    public func ask(_ prompt: String) async throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let result = try await Shell.run(
            at: configuration.executable,
            arguments: Self.arguments(
                prompt: trimmed, profile: configuration.profile, patches: configuration.patches),
            workingDirectory: configuration.workingDirectory,
            timeout: configuration.timeout)
        return Self.cleanAnswer(result.stdout)
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
