import Foundation

/// Runs `llama-server` for one Qwen3-ASR tier, on loopback only.
///
/// The life of a request: `baseURL(for:)` starts a server if none is running
/// for that tier, waits until it answers `/health`, and returns the URL. A
/// reaper stops servers that have not been used for a while, so the 1–3 GB
/// the weights occupy is given back when the app is idle rather than held for
/// the life of the process.
///
/// Two servers can be alive at once on purpose: the live path wants the 0.6B
/// model for cheap partials while a final pass runs on the 1.7B. Each binds to
/// its own ephemeral port on 127.0.0.1 — never 0.0.0.0, because this API has
/// no authentication and the model can read the audio of everything you say.
public actor QwenAsrServer {

    public struct Configuration: Sendable {
        public var modelDirectory: URL
        /// An explicit `llama-server` path (Settings), which outranks `$PATH`.
        public var executablePath: String?
        /// Context window. Transcription needs far less than chat: 4096 covers
        /// a long utterance and keeps the KV cache small (the 65536 default
        /// allocates gigabytes for nothing).
        public var contextSize: Int
        /// Slots, so a live window and a final pass can overlap.
        public var parallel: Int
        /// Seconds of inactivity before a server is stopped.
        public var idleTimeout: TimeInterval

        public init(
            modelDirectory: URL,
            executablePath: String? = nil,
            contextSize: Int = 4096,
            parallel: Int = 2,
            idleTimeout: TimeInterval = 300
        ) {
            self.modelDirectory = modelDirectory
            self.executablePath = executablePath
            self.contextSize = contextSize
            self.parallel = parallel
            self.idleTimeout = idleTimeout
        }
    }

    private struct Running {
        let process: Process
        let baseURL: URL
        var lastUsed: Date
    }

    private let configuration: Configuration
    private var servers: [QwenAsrTier: Running] = [:]
    private var reaper: Task<Void, Never>?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Public

    /// The base URL of a live server for `tier`, starting one if needed.
    public func baseURL(for tier: QwenAsrTier) async throws -> URL {
        if var running = servers[tier], running.process.isRunning {
            running.lastUsed = Date()
            servers[tier] = running
            return running.baseURL
        }
        servers[tier] = nil

        let model = configuration.modelDirectory.appendingPathComponent(tier.modelFileName)
        let mmproj = configuration.modelDirectory.appendingPathComponent(tier.mmprojFileName)
        for file in [model, mmproj] where !FileManager.default.fileExists(atPath: file.path) {
            throw VoiceError.modelMissing(
                model: tier.shortLabel, directory: configuration.modelDirectory.path)
        }

        // Try each `llama-server` we can find until one actually serves. A
        // binary that predates the `qwen3vl` architecture starts and then dies
        // with "unknown model architecture", which is indistinguishable from
        // "no llama.cpp installed" to a user — so we move on to the next.
        let candidates = Self.executables(override: configuration.executablePath)
        guard !candidates.isEmpty else {
            throw VoiceError.binaryNotFound(
                component: "llama-server",
                hint:
                    "Install llama.cpp (`brew install llama.cpp`, or run "
                    + "`scripts/install-llama.sh`), or point at it in Settings › Speech.")
        }

        var lastError: Error?
        for executable in candidates {
            do {
                let running = try await Self.startServer(
                    executable: executable, model: model, mmproj: mmproj,
                    contextSize: configuration.contextSize,
                    parallel: configuration.parallel)
                servers[tier] = running
                startReaperIfNeeded()
                return running.baseURL
            } catch {
                lastError = error
            }
        }
        throw lastError
            ?? VoiceError.engineUnavailable(
                engine: "Qwen3-ASR", reason: "No llama-server candidate could start.")
    }

    /// Start one server process and wait for it to answer `/health`.
    private static func startServer(
        executable: String, model: URL, mmproj: URL, contextSize: Int, parallel: Int
    ) async throws -> Running {
        let port = try freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(
            model: model.path, mmproj: mmproj.path, port: port,
            contextSize: contextSize, parallel: parallel)
        // llama-server needs its sibling dylibs; they sit next to the binary.
        process.currentDirectoryURL = URL(fileURLWithPath: executable).deletingLastPathComponent()

        let log = Pipe()
        process.standardOutput = log
        process.standardError = log
        // Drain the pipe: a full buffer would block the child, and without the
        // text a startup failure is just "exited with status 1".
        let capture = LogCapture(log.fileHandleForReading)

        do {
            try process.run()
        } catch {
            capture.stop()
            throw VoiceError.binaryNotFound(
                component: executable, hint: "llama-server did not start: \(error)")
        }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        do {
            try await waitUntilHealthy(base, process: process, capture: capture)
        } catch {
            process.terminate()
            capture.stop()
            throw VoiceError.processFailed(
                component:
                    "llama-server (\(URL(fileURLWithPath: executable).deletingLastPathComponent().lastPathComponent))",
                status: process.isRunning ? -1 : process.terminationStatus,
                stderr: capture.tail())
        }
        return Running(process: process, baseURL: base, lastUsed: Date())
    }

    /// Stop every server (app termination, or switching engines).
    public func stopAll() {
        for (_, running) in servers { running.process.terminate() }
        servers.removeAll()
        reaper?.cancel()
        reaper = nil
    }

    public func stop(_ tier: QwenAsrTier) {
        servers[tier]?.process.terminate()
        servers[tier] = nil
    }

    /// Which tiers currently have a resident server (for the Settings pane).
    public func runningTiers() -> [QwenAsrTier] {
        servers.filter { $0.value.process.isRunning }.keys.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Startup

    /// The exact argv for one server. Pure, so the flags are unit-tested.
    public static func arguments(
        model: String, mmproj: String, port: Int, contextSize: Int, parallel: Int
    ) -> [String] {
        [
            "-m", model,
            "--mmproj", mmproj,
            "--ctx-size", String(contextSize),
            "--parallel", String(parallel),
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
    }

    /// Wait for `/health` to report `ok`.
    ///
    /// Loading 1.7B from disk takes a couple of seconds, so this polls rather
    /// than sleeping a fixed amount. It also watches for the process dying —
    /// otherwise a bad `mmproj` would look like a 30-second hang.
    private static func waitUntilHealthy(
        _ base: URL, process: Process, capture: LogCapture
    ) async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !process.isRunning {
                throw VoiceError.processFailed(
                    component: "llama-server", status: process.terminationStatus,
                    stderr: capture.tail())
            }
            if let ok = try? await isHealthy(base), ok { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw VoiceError.processTimeout(component: "llama-server", seconds: 60)
    }

    static func isHealthy(_ base: URL) async throws -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("\"ok\"")
    }

    private func startReaperIfNeeded() {
        guard reaper == nil else { return }
        let timeout = configuration.idleTimeout
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.reapIdle(olderThan: timeout)
            }
        }
    }

    private func reapIdle(olderThan timeout: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-timeout)
        for (tier, running) in servers where running.lastUsed < cutoff {
            running.process.terminate()
            servers[tier] = nil
        }
    }

    // MARK: - Locating llama-server

    /// Every place we look for `llama-server`, in order.
    ///
    /// Order matters more here than for `dsh`: Qwen3-ASR needs a *recent*
    /// llama.cpp (the `qwen3vl` architecture landed in b8769), and a stale
    /// `/opt/homebrew/bin/llama-server` from before that starts fine and then
    /// fails with "unknown model architecture". So a release we installed
    /// ourselves — whose version we pinned — outranks `$PATH`. An explicit
    /// override still outranks everything, and Settings shows which one won.
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        override: String? = nil
    ) -> [String] {
        var paths: [String] = []
        for raw in [override, environment["VOICEBRIDGE_LLAMA_SERVER"]] {
            guard let raw, !raw.isEmpty else { continue }
            paths.append((raw as NSString).expandingTildeInPath)
        }
        // Self-installed releases, newest first:
        // ~/.voicebridge/bin/llama-b<build>/llama-server
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binRoot = home.appendingPathComponent(".voicebridge/bin", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: binRoot, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        {
            let byAge = entries.sorted { lhs, rhs in
                let l =
                    (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r =
                    (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
            for entry in byAge {
                paths.append(entry.appendingPathComponent("llama-server").path)
            }
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            paths.append("\(dir)/llama-server")
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            paths.append("\(dir)/llama-server")
        }
        return paths
    }

    /// Every executable candidate, in preference order.
    public static func executables(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        override: String? = nil,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String] {
        var seen = Set<String>()
        return candidates(environment: environment, override: override)
            .filter { isExecutable($0) && seen.insert($0).inserted }
    }

    /// Resolve `llama-server`, or throw something a human can act on.
    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        override: String? = nil,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> String {
        for candidate in candidates(environment: environment, override: override)
        where isExecutable(candidate) {
            return candidate
        }
        throw VoiceError.binaryNotFound(
            component: "llama-server",
            hint:
                "Install llama.cpp (`brew install llama.cpp`, or run "
                + "`scripts/install-llama.sh`), or point at it in Settings › Speech.")
    }

    /// An ephemeral free port on loopback.
    ///
    /// Bind-and-close is inherently racy, but the window is microseconds and
    /// the only cost of losing it is a failed start, which `baseURL(for:)`
    /// surfaces as an error instead of a silent hang.
    static func freePort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw VoiceError.processFailed(
                component: "socket", status: -1, stderr: "socket() failed")
        }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw VoiceError.processFailed(component: "socket", status: -1, stderr: "bind() failed")
        }
        var result = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &result) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard named == 0 else {
            throw VoiceError.processFailed(
                component: "socket", status: -1, stderr: "getsockname() failed")
        }
        return Int(UInt16(bigEndian: result.sin_port))
    }
}

/// Drains a child's output into a bounded buffer so a failed start can explain
/// itself.
///
/// The buffer is bounded because a long-running server logs indefinitely; what
/// matters for a diagnosis is the last few dozen lines.
final class LogCapture: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var lines: [String] = []
    private var reader: Task<Void, Never>?
    private let limit = 80

    init(_ handle: FileHandle) {
        self.handle = handle
        reader = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                let text = String(decoding: chunk, as: UTF8.self)
                self.append(text)
            }
        }
    }

    private func append(_ chunk: String) {
        let newLines = chunk.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        lock.lock()
        lines.append(contentsOf: newLines)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    /// The last lines the child wrote (empty when it said nothing).
    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(12).joined(separator: "\n")
    }

    func stop() {
        reader?.cancel()
        reader = nil
    }
}
