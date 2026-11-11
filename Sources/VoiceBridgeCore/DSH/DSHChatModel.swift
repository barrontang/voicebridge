import Combine
import Foundation

/// One bubble in the DSH chat.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable, Equatable {
        case user
        case assistant
        /// Informational line ("New conversation", "Heard nothing").
        case notice
        case error
    }

    public let id: UUID
    public let role: Role
    public let text: String
    /// The user's message came from the microphone.
    public let viaVoice: Bool
    public let date: Date

    public init(
        id: UUID = UUID(), role: Role, text: String, viaVoice: Bool = false, date: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.viaVoice = viaVoice
        self.date = date
    }
}

/// Anything that can answer a prompt inside a DSH session.
public protocol DSHAsking: Sendable {
    func ask(
        _ prompt: String,
        session: String?,
        onProgress: (@Sendable (DSHClient.Progress) -> Void)?
    ) async throws -> DSHClient.Reply
}

extension DSHAsking {
    /// Ask without caring about progress.
    public func ask(_ prompt: String, session: String?) async throws -> DSHClient.Reply {
        try await ask(prompt, session: session, onProgress: nil)
    }
}

extension DSHClient: DSHAsking {}

/// The state behind the chat window: messages, the DSH session, and the
/// talk → transcribe → ask → speak cycle.
///
/// Every side effect is injected (asking DSH, recording, transcribing,
/// speaking), so the conversation logic is unit-tested without a microphone,
/// a whisper model or DSH. The SwiftUI view only renders this and forwards
/// taps.
@MainActor
public final class DSHChatModel: ObservableObject {

    public enum Phase: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case thinking
        /// An answer is being read aloud; sending or recording now would
        /// transcribe the app's own voice, so input is blocked.
        case speaking
    }

    public struct Dependencies {
        /// Build the DSH client for a working directory.
        public var makeAsker: (URL) throws -> any DSHAsking
        public var startRecording: () async throws -> Void
        /// Stop and return the recorded clip (nil = nothing recorded).
        public var stopRecording: () async -> URL?
        public var transcribe: (URL) async throws -> String
        public var speak: (String) async -> Void
        /// The DSH session to continue in this folder, if one was left open.
        public var loadSession: (URL) -> String?
        public var saveSession: (URL, String?) -> Void

        public init(
            makeAsker: @escaping (URL) throws -> any DSHAsking,
            startRecording: @escaping () async throws -> Void,
            stopRecording: @escaping () async -> URL?,
            transcribe: @escaping (URL) async throws -> String,
            speak: @escaping (String) async -> Void,
            loadSession: @escaping (URL) -> String? = { _ in nil },
            saveSession: @escaping (URL, String?) -> Void = { _, _ in }
        ) {
            self.makeAsker = makeAsker
            self.startRecording = startRecording
            self.stopRecording = stopRecording
            self.transcribe = transcribe
            self.speak = speak
            self.loadSession = loadSession
            self.saveSession = saveSession
        }
    }

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var phase: Phase = .idle
    /// The DSH session the next turn continues (nil = a new conversation).
    @Published public private(set) var sessionID: String?
    /// Where DSH works: it reads and edits files here.
    @Published public private(set) var workingDirectory: URL
    /// What DSH is doing right now ("Writing probe.txt…"), while it works.
    @Published public private(set) var activity: String?
    /// The answer so far, as DSH streams it — replaced by the final text.
    @Published public private(set) var streamingText: String?
    @Published public var draft = ""
    @Published public var speakReplies = true

    private let dependencies: Dependencies
    /// The turn in flight, so Stop can cancel it (which kills the child).
    private var turnTask: Task<DSHClient.Reply, Error>?

    public init(workingDirectory: URL, dependencies: Dependencies) {
        self.workingDirectory = workingDirectory
        self.dependencies = dependencies
        // Continue the conversation that was open in this folder last time,
        // instead of forgetting it on every launch.
        self.sessionID = dependencies.loadSession(workingDirectory)
    }

    /// True while a turn is in flight; the working bubble is showing.
    public var isBusy: Bool { phase == .transcribing || phase == .thinking }

    /// True while input must be blocked: a turn is running, or the answer is
    /// being read aloud (recording that would transcribe the app's own voice).
    public var isInputBlocked: Bool { isBusy || phase == .speaking }

    // MARK: - Actions

    /// Send the typed draft.
    public func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase == .idle else { return }
        draft = ""
        await send(text, viaVoice: false)
    }

    /// Tap the mic: start recording, or stop and send what was said.
    public func toggleMicrophone() async {
        switch phase {
        case .idle:
            do {
                try await dependencies.startRecording()
                phase = .recording
            } catch {
                append(.error, error.localizedDescription)
            }
        case .recording:
            phase = .transcribing
            guard let clip = await dependencies.stopRecording() else {
                phase = .idle
                append(.notice, "Nothing was recorded.")
                return
            }
            do {
                let text = try await dependencies.transcribe(clip)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                phase = .idle
                guard !text.isEmpty else {
                    append(.notice, "Heard nothing — try again a little closer to the mic.")
                    return
                }
                await send(text, viaVoice: true)
            } catch {
                phase = .idle
                append(.error, error.localizedDescription)
            }
        case .transcribing, .thinking, .speaking:
            break
        }
    }

    /// Stop the turn in flight (the Stop button). Kills the child process.
    public func cancelTurn() {
        turnTask?.cancel()
    }

    /// Forget the session; the next message starts a new DSH conversation.
    public func newConversation() {
        guard !isBusy else { return }
        sessionID = nil
        dependencies.saveSession(workingDirectory, nil)
        messages = []
    }

    /// Point DSH at another folder. Each folder keeps its own conversation.
    public func changeWorkingDirectory(_ url: URL) {
        guard !isBusy, url != workingDirectory else { return }
        workingDirectory = url
        messages = []
        sessionID = dependencies.loadSession(url)
        append(.notice, "Working in \(url.path)")
        if sessionID != nil {
            append(.notice, "Continuing this folder's earlier conversation.")
        }
    }

    /// Resume an existing DSH session (e.g. one started from the CLI).
    public func resume(session: String) {
        guard !isBusy else { return }
        sessionID = session
        dependencies.saveSession(workingDirectory, session)
        append(.notice, "Continuing session \(session)")
    }

    // MARK: - The turn

    func send(_ text: String, viaVoice: Bool) async {
        append(.user, text, viaVoice: viaVoice)
        phase = .thinking
        activity = "Starting…"
        streamingText = nil
        defer {
            activity = nil
            streamingText = nil
        }
        do {
            let asker = try dependencies.makeAsker(workingDirectory)
            let reply: DSHClient.Reply
            do {
                reply = try await run(asker, text, session: sessionID)
            } catch let error as DSHClient.DSHError where error.kind == .missingSession {
                // The stored session is gone (DSH was reset, or this is a
                // different Mac). Forget it and ask again in a fresh one,
                // instead of failing every turn from now on.
                sessionID = nil
                dependencies.saveSession(workingDirectory, nil)
                reply = try await run(asker, text, session: nil)
            }
            sessionID = reply.sessionID ?? sessionID
            dependencies.saveSession(workingDirectory, sessionID)
            phase = .idle
            let answer = reply.text.isEmpty ? "(no answer)" : reply.text
            append(.assistant, answer)
            if speakReplies, !reply.text.isEmpty {
                phase = .speaking
                await dependencies.speak(reply.text)
                phase = .idle
            }
        } catch is CancellationError {
            phase = .idle
            append(.notice, "Stopped.")
        } catch {
            phase = .idle
            append(.error, error.localizedDescription)
        }
    }

    /// One ask, kept in a task so Stop can cancel it.
    ///
    /// Cancelling the task cancels the `ProcessRunner` waiting on the child,
    /// which terminates it — a 5-minute agent run really does stop.
    private func run(
        _ asker: any DSHAsking, _ text: String, session: String?
    ) async throws -> DSHClient.Reply {
        let task = Task<DSHClient.Reply, Error> { [weak self] in
            try await asker.ask(text, session: session) { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }
        }
        turnTask = task
        defer { turnTask = nil }
        do {
            return try await task.value
        } catch {
            // A killed child surfaces as a non-zero exit; the user asked for
            // that, so report it as a cancellation, not a failure.
            if task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Turn a progress event into the "working…" line, and collect the answer
    /// as it streams so a long reply is readable before the turn ends.
    private func apply(_ event: DSHClient.Progress) {
        switch event {
        case .starting: activity = "Starting…"
        case .thinking: activity = "Thinking…"
        case .tool(let phrase, _): activity = phrase
        case .text(let delta):
            activity = "Replying…"
            streamingText = (streamingText ?? "") + delta
        }
    }

    private func append(_ role: ChatMessage.Role, _ text: String, viaVoice: Bool = false) {
        messages.append(ChatMessage(role: role, text: text, viaVoice: viaVoice))
    }
}
