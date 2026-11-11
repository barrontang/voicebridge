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
        var calls: [(prompt: String, session: String?)] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        func ask(_ prompt: String, session: String?) async throws -> DSHClient.Reply {
            lock.lock()
            _calls.append((prompt, session))
            lock.unlock()
            if fail { throw VoiceError.processFailed(component: "dsh", status: 1, stderr: "boom") }
            return DSHClient.Reply(text: answer, sessionID: session ?? "session-1")
        }
    }

    private final class Spoken: @unchecked Sendable {
        var texts: [String] = []
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
}
