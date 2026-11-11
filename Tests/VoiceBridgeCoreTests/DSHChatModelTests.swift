import XCTest

@testable import VoiceBridgeCore

/// The chat window's logic: sessions carry across turns, voice and text both
/// become messages, failures become visible bubbles instead of silence.
@MainActor
final class DSHChatModelTests: XCTestCase {

    /// Records every prompt and the session it was asked in.
    private final class FakeDSH: DSHAsking, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(prompt: String, session: String?)] = []
        var answer = "ok"
        var fail = false
        /// Throw this on the next call, then behave normally.
        var failOnce: Error?
        /// Report a tool call before answering, like a real agent run.
        var toolPhrase: String?
        var calls: [(prompt: String, session: String?)] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        func ask(
            _ prompt: String,
            session: String?,
            onProgress: (@Sendable (DSHClient.Progress) -> Void)?
        ) async throws -> DSHClient.Reply {
            lock.lock()
            _calls.append((prompt, session))
            let once = failOnce
            failOnce = nil
            let phrase = toolPhrase
            lock.unlock()
            if let once { throw once }
            if fail { throw VoiceError.processFailed(component: "dsh", status: 1, stderr: "boom") }
            if let phrase { onProgress?(.tool(phrase: phrase, name: "write")) }
            onProgress?(.text(answer))
            return DSHClient.Reply(text: answer, sessionID: session ?? "session-1")
        }
    }

    /// A backend that never answers until it is cancelled.
    private final class HangingDSH: DSHAsking, @unchecked Sendable {
        func ask(
            _ prompt: String,
            session: String?,
            onProgress: (@Sendable (DSHClient.Progress) -> Void)?
        ) async throws -> DSHClient.Reply {
            try await Task.sleep(for: .seconds(60))
            return DSHClient.Reply(text: "too late", sessionID: session)
        }
    }

    private final class Spoken: @unchecked Sendable {
        var texts: [String] = []
        /// The model's phase at the moment each answer was read aloud.
        var phases: [DSHChatModel.Phase?] = []
    }

    /// Records what the model asked to persist.
    private final class Saver: @unchecked Sendable {
        var pairs: [(folder: String, session: String?)] = []
    }

    private func makeModel(
        dsh: FakeDSH,
        spoken: Spoken = Spoken(),
        transcript: String = "spoken words",
        recordingFails: Bool = false,
        folders: Box<[URL]> = Box([])
    ) -> DSHChatModel {
        DSHChatModel(
            workingDirectory: URL(fileURLWithPath: "/repo"),
            dependencies: .init(
                makeAsker: { folder in
                    folders.value.append(folder)
                    return dsh
                },
                startRecording: {
                    if recordingFails {
                        throw VoiceError.audioDeviceUnavailable(reason: "no input device")
                    }
                },
                stopRecording: { URL(fileURLWithPath: "/tmp/clip.wav") },
                transcribe: { _ in transcript },
                speak: { spoken.texts.append($0) }))
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    func testEveryTurnContinuesTheSameSession() async {
        let dsh = FakeDSH()
        let model = makeModel(dsh: dsh)

        model.draft = "create notes.txt"
        await model.sendDraft()
        model.draft = "add a line to it"
        await model.sendDraft()

        XCTAssertEqual(dsh.calls.map(\.session), [nil, "session-1"])
        XCTAssertEqual(model.sessionID, "session-1")
        XCTAssertEqual(model.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(model.draft, "", "the field is cleared after sending")
    }

    func testAVoiceTurnIsTranscribedSentAndSpoken() async {
        let dsh = FakeDSH()
        dsh.answer = "Done."
        let spoken = Spoken()
        let model = makeModel(dsh: dsh, spoken: spoken, transcript: " 你好 ")

        await model.toggleMicrophone()
        XCTAssertEqual(model.phase, .recording)
        await model.toggleMicrophone()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(dsh.calls.first?.prompt, "你好")
        XCTAssertEqual(model.messages.first?.viaVoice, true)
        XCTAssertEqual(spoken.texts, ["Done."])
    }

    func testMutedRepliesAreNotSpoken() async {
        let spoken = Spoken()
        let model = makeModel(dsh: FakeDSH(), spoken: spoken)
        model.speakReplies = false
        model.draft = "hi"
        await model.sendDraft()
        XCTAssertTrue(spoken.texts.isEmpty)
    }

    func testSilenceSendsNothing() async {
        let dsh = FakeDSH()
        let model = makeModel(dsh: dsh, transcript: "   ")
        await model.toggleMicrophone()
        await model.toggleMicrophone()
        XCTAssertTrue(dsh.calls.isEmpty)
        XCTAssertEqual(model.messages.last?.role, .notice)
        XCTAssertEqual(model.phase, .idle)
    }

    /// No mic or a DSH failure is a visible message, and the chat keeps working.
    func testFailuresBecomeErrorBubbles() async {
        let dsh = FakeDSH()
        let model = makeModel(dsh: dsh, recordingFails: true)

        await model.toggleMicrophone()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.messages.last?.role, .error)

        dsh.fail = true
        model.draft = "hello"
        await model.sendDraft()
        XCTAssertEqual(model.messages.last?.role, .error)
        XCTAssertEqual(model.phase, .idle)

        dsh.fail = false
        model.draft = "again"
        await model.sendDraft()
        XCTAssertEqual(model.messages.last?.role, .assistant)
    }

    func testNewConversationAndFolderChangeResetTheSession() async {
        let dsh = FakeDSH()
        let folders = Box<[URL]>([])
        let model = makeModel(dsh: dsh, folders: folders)
        model.draft = "one"
        await model.sendDraft()
        XCTAssertNotNil(model.sessionID)

        model.newConversation()
        XCTAssertNil(model.sessionID)
        XCTAssertTrue(model.messages.isEmpty)

        model.draft = "two"
        await model.sendDraft()
        model.changeWorkingDirectory(URL(fileURLWithPath: "/other"))
        XCTAssertNil(model.sessionID, "a session belongs to its folder")
        model.draft = "three"
        await model.sendDraft()
        XCTAssertEqual(folders.value.last?.path, "/other", "DSH runs in the chosen folder")
    }

    func testEmptyDraftIsIgnored() async {
        let dsh = FakeDSH()
        let model = makeModel(dsh: dsh)
        model.draft = "   "
        await model.sendDraft()
        XCTAssertTrue(dsh.calls.isEmpty)
        XCTAssertTrue(model.messages.isEmpty)
    }

    // MARK: - The bundled local-model patch

    /// The app writes this patch itself; it must stay identical to the example
    /// the CLI documents.
    func testTheEmbeddedPatchMatchesTheExample() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/dsh-ollama.yml")
        let text = try String(contentsOf: example, encoding: .utf8)
        XCTAssertEqual(
            DSHClient.localOllamaPatch.trimmingCharacters(in: .whitespacesAndNewlines),
            text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testTheLocalPatchIsWrittenOnce() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-dsh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try DSHClient.ensureLocalOllamaPatch(in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        // A user's edit is not overwritten.
        try "edited".write(toFile: path, atomically: true, encoding: .utf8)
        _ = try DSHClient.ensureLocalOllamaPatch(in: dir)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "edited")
    }

    // MARK: - Lifecycle (review findings P1-4/5/6)

    /// An answer being read aloud must block input: recording then would
    /// transcribe the app's own voice.
    func testTheAnswerIsSpokenInItsOwnPhase() async {
        let dsh = FakeDSH()
        dsh.answer = "Done."
        let box = ModelBox()
        let seen = Spoken()
        let model = DSHChatModel(
            workingDirectory: URL(fileURLWithPath: "/repo"),
            dependencies: .init(
                makeAsker: { _ in dsh },
                startRecording: {},
                stopRecording: { nil },
                transcribe: { _ in "" },
                speak: { _ in seen.phases.append(box.model?.phase) }))
        box.model = model

        model.draft = "hi"
        await model.sendDraft()

        XCTAssertEqual(
            seen.phases.compactMap { $0 }, [.speaking], "speak() runs while the phase is .speaking")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.messages.last?.text == "Done.")
    }

    /// A stored session that DSH no longer has must not wedge the chat.
    func testADeadSessionIsForgottenAndRetriedOnce() async {
        let dsh = FakeDSH()
        dsh.failOnce = DSHClient.DSHError(message: "gone", kind: .missingSession)
        let model = DSHChatModel(
            workingDirectory: URL(fileURLWithPath: "/repo"),
            dependencies: .init(
                makeAsker: { _ in dsh },
                startRecording: {},
                stopRecording: { nil },
                transcribe: { _ in "" },
                speak: { _ in },
                loadSession: { _ in "session-old" },
                saveSession: { _, _ in }))

        XCTAssertEqual(model.sessionID, "session-old")
        model.draft = "still there?"
        await model.sendDraft()

        XCTAssertEqual(dsh.calls.map(\.session), ["session-old", nil], "retried in a new session")
        XCTAssertEqual(model.sessionID, "session-1")
        XCTAssertEqual(model.messages.last?.role, .assistant, "the retry succeeded")
    }

    /// The conversation survives a relaunch, per folder.
    func testTheSessionIsRestoredAndSavedPerFolder() async {
        let dsh = FakeDSH()
        let saved = Saver()
        let folder = URL(fileURLWithPath: "/repo")
        let model = DSHChatModel(
            workingDirectory: folder,
            dependencies: .init(
                makeAsker: { _ in dsh },
                startRecording: {},
                stopRecording: { nil },
                transcribe: { _ in "" },
                speak: { _ in },
                loadSession: { _ in "session-kept" },
                saveSession: { url, id in saved.pairs.append((url.path, id)) }))

        model.draft = "hello again"
        await model.sendDraft()

        XCTAssertEqual(dsh.calls.first?.session, "session-kept", "the turn resumes what was stored")
        XCTAssertEqual(saved.pairs.last?.folder, folder.path)
        XCTAssertEqual(saved.pairs.last?.session ?? nil, "session-1", "the new id is persisted")

        model.newConversation()
        XCTAssertFalse(saved.pairs.isEmpty)
        XCTAssertNil(saved.pairs.last?.session ?? nil, "a new conversation clears the stored id")
    }

    /// Stop must cancel the turn (killing the child) and say so, not error.
    func testStoppingATurnCancelsIt() async {
        let model = DSHChatModel(
            workingDirectory: URL(fileURLWithPath: "/repo"),
            dependencies: .init(
                makeAsker: { _ in HangingDSH() },
                startRecording: {},
                stopRecording: { nil },
                transcribe: { _ in "" },
                speak: { _ in }))

        model.draft = "do something slow"
        let turn = Task { await model.sendDraft() }
        // Let the turn start and park inside ask().
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.phase, .thinking)

        model.cancelTurn()
        await turn.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.messages.last?.role, .notice)
        XCTAssertEqual(model.messages.last?.text, "Stopped.")
    }

    /// The "working…" line is cleared when the turn ends, so a later turn
    /// starts from a clean state.
    func testToolActivityIsClearedWhenTheTurnEnds() async {
        let dsh = FakeDSH()
        dsh.toolPhrase = "Writing probe.txt…"
        let model = DSHChatModel(
            workingDirectory: URL(fileURLWithPath: "/repo"),
            dependencies: .init(
                makeAsker: { _ in dsh },
                startRecording: {},
                stopRecording: { nil },
                transcribe: { _ in "" },
                speak: { _ in }))

        model.draft = "write it"
        await model.sendDraft()

        XCTAssertNil(model.activity, "the line is cleared when the turn ends")
        XCTAssertNil(model.streamingText, "the streamed text is replaced by the final bubble")
        XCTAssertEqual(
            model.messages.filter { $0.role == .assistant }.count, 1,
            "the streamed text is not left behind as a second bubble")
    }

    final class ModelBox: @unchecked Sendable {
        var model: DSHChatModel?
    }
}
