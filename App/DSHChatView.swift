// DSHChatView.swift — talk to DeepSeek Harness in a chat window.
//
// A messaging-style front end for DSH: bubbles, a tap-to-talk mic, a text
// field, replies read aloud. Every message continues one DSH session, so DSH
// keeps the history, its tool results and the files it touched — "add a test
// for that", then "now run it".
//
// All the conversation logic lives in `DSHChatModel` (VoiceBridgeCore, unit
// tested); this file only wires the real recorder / whisper / DSH / `say` into
// it and renders the state.

import AppKit
import SwiftUI
import VoiceBridgeCore

/// Which model DSH answers with.
enum DSHBackend: String, CaseIterable, Identifiable {
    /// A local Ollama model via the bundled patch — nothing leaves the Mac.
    case local
    /// Whatever the DSH `headless` profile is configured with.
    case dshDefault

    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: return "Local model (Ollama)"
        case .dshDefault: return "DSH default model"
        }
    }
}

/// The defaults shared by this window and the Settings page.
enum DSHSettings {
    static let backendKey = "dshChat.backend"
    static let folderKey = "dshChat.folder"
    static let readOnlyKey = "dshChat.readOnly"
    static let timeoutKey = "dshChat.timeout"
    static let pathKey = "dsh.path"
    static let consentKey = "dshChat.remoteConsent"
    static let sessionPrefix = "dshChat.session."

    static let defaultTimeout: Double = 300

    /// Each folder keeps its own conversation.
    static func sessionKey(for folder: URL) -> String {
        sessionPrefix + folder.standardizedFileURL.path
    }

    /// Where DSH works when the user has not chosen a folder.
    ///
    /// Deliberately **not** the home directory: DSH runs with `workspace-write`,
    /// so the folder chosen here is the tree an agent may edit. A dedicated
    /// folder keeps the blast radius small, and it is created on demand.
    static func defaultFolder() -> URL {
        let base =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let folder = base.appendingPathComponent("VoiceBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

struct DSHChatView: View {
    @StateObject private var chat: DSHChatModel
    @StateObject private var recorder: PushToTalkSession
    @AppStorage(DSHSettings.backendKey) private var backendRaw = DSHBackend.local.rawValue
    @AppStorage(DSHSettings.consentKey) private var remoteConsent = false
    @FocusState private var inputFocused: Bool
    /// While the remote-model warning is up: did the user tap the mic or Send?
    @State private var pendingVoice = false
    @State private var showRemoteWarning = false

    init() {
        let recorder = PushToTalkSession()
        _recorder = StateObject(wrappedValue: recorder)
        _chat = StateObject(
            wrappedValue: DSHChatModel(
                workingDirectory: Self.initialFolder(),
                dependencies: Self.dependencies(recorder: recorder)))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputBar
        }
        .frame(minWidth: 500, minHeight: 520)
        .onAppear { inputFocused = true }
        .onChange(of: chat.workingDirectory) {
            UserDefaults.standard.set(chat.workingDirectory.path, forKey: DSHSettings.folderKey)
        }
        .alert("Send this to DeepSeek's servers?", isPresented: $showRemoteWarning) {
            Button("Send it") {
                remoteConsent = true
                if pendingVoice {
                    pendingVoice = false
                    Task { await chat.toggleMicrophone() }
                } else {
                    Task { await chat.sendDraft() }
                }
            }
            Button("Use the local model", role: .cancel) {
                pendingVoice = false
                backendRaw = DSHBackend.local.rawValue
            }
        } message: {
            Text(
                "“DSH default model” answers from DeepSeek's servers: your words — and "
                    + "anything DSH reads in this folder — are sent there. “Local model "
                    + "(Ollama)” keeps everything on this Mac."
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("DeepSeek Harness").font(.headline)
                Button {
                    chooseFolder()
                } label: {
                    Label(chat.workingDirectory.abbreviatedPath, systemImage: "folder")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.link)
                .help("The folder DSH works in. Changing it starts a new conversation.")
                .disabled(chat.isBusy)
            }
            Spacer()
            Picker("", selection: $backendRaw) {
                ForEach(DSHBackend.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(width: 190)
            .help("Which model answers. Local keeps everything on this Mac.")

            Toggle(isOn: $chat.speakReplies) {
                Image(systemName: chat.speakReplies ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .toggleStyle(.button)
            .help("Read answers aloud")

            Button {
                chat.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New conversation")
            .disabled(chat.isBusy || chat.messages.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chat.messages.isEmpty { emptyState }
                    ForEach(chat.messages) { MessageBubble(message: $0) }
                    if chat.isBusy {
                        // The answer so far, while the model is still writing it.
                        if let partial = chat.streamingText, !partial.isEmpty {
                            MessageBubble(
                                message: ChatMessage(role: .assistant, text: partial)
                            )
                            .opacity(0.65)
                        }
                        WorkingBubble(phase: chat.phase, activity: chat.activity).id("working")
                    }
                }
                .padding(14)
            }
            .onChange(of: chat.messages.count) { scrollToEnd(proxy) }
            .onChange(of: chat.activity) { scrollToEnd(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Talk to DeepSeek Harness")
                .font(.title3.weight(.medium))
            Text(
                "Tap the mic and speak, or type. DSH works in the folder above — it can "
                    + "read and edit files there — and remembers the conversation."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .padding(.top, 60)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if chat.isBusy {
                proxy.scrollTo("working", anchor: .bottom)
            } else if let last = chat.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            micButton

            TextField(
                chat.phase == .recording ? "Listening…" : "Message DeepSeek Harness",
                text: $chat.draft, axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
            .focused($inputFocused)
            .disabled(chat.isInputBlocked || chat.phase == .recording)
            .onSubmit { submit() }

            if chat.isBusy {
                Button {
                    chat.cancelTurn()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Stop — the DSH task is killed, not just hidden")
            } else {
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
            }
        }
        .padding(12)
    }

    private var canSend: Bool {
        chat.phase == .idle && !chat.draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the selected backend sends the conversation off this Mac.
    private var isRemoteBackend: Bool {
        (DSHBackend(rawValue: backendRaw) ?? .local) == .dshDefault
    }

    /// Typed and spoken turns are equally remote, so both ask once.
    private func submit() {
        guard chat.phase == .idle else { return }
        if isRemoteBackend && !remoteConsent {
            pendingVoice = false
            showRemoteWarning = true
            return
        }
        Task { await chat.sendDraft() }
    }

    private func tapMic() {
        if chat.phase == .idle && isRemoteBackend && !remoteConsent {
            pendingVoice = true
            showRemoteWarning = true
            return
        }
        Task { await chat.toggleMicrophone() }
    }

    private var micButton: some View {
        let recording = chat.phase == .recording
        return Button {
            tapMic()
        } label: {
            ZStack {
                Circle()
                    .fill(recording ? Color.red : Color.accentColor)
                    .frame(width: 36, height: 36)
                if recording {
                    // The ring follows the input level: proof the mic hears you.
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 4)
                        .frame(
                            width: 36 + CGFloat(recorder.level) * 26,
                            height: 36 + CGFloat(recorder.level) * 26
                        )
                        .animation(.easeOut(duration: 0.1), value: recorder.level)
                }
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(chat.isInputBlocked)
        .keyboardShortcut("m", modifiers: .command)
        .help(recording ? "Stop and send (⌘M)" : "Tap to talk (⌘M)")
    }

    // MARK: - Folder

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = chat.workingDirectory
        panel.prompt = "Work Here"
        panel.message = "DSH can read and edit files in the folder you pick."
        if panel.runModal() == .OK, let url = panel.url {
            chat.changeWorkingDirectory(url)
        }
    }

    private static func initialFolder() -> URL {
        if let saved = UserDefaults.standard.string(forKey: DSHSettings.folderKey),
            FileManager.default.fileExists(atPath: saved)
        {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return DSHSettings.defaultFolder()
    }

    // MARK: - Wiring the real engines

    /// Built once, so it reads settings at call time instead of capturing them.
    private static func dependencies(recorder: PushToTalkSession) -> DSHChatModel.Dependencies {
        DSHChatModel.Dependencies(
            makeAsker: { folder in
                guard
                    let dsh = DSHClient.locate(
                        override: UserDefaults.standard.string(forKey: DSHSettings.pathKey))
                else {
                    throw VoiceError.binaryNotFound(
                        component: "DeepSeek Harness (dsh)",
                        hint: "Install DeepSeek Harness, or choose its dsh launcher in "
                            + "Settings › DeepSeek Harness.")
                }
                let backend =
                    DSHBackend(
                        rawValue: UserDefaults.standard.string(forKey: DSHSettings.backendKey) ?? ""
                    )
                    ?? .local
                let patches =
                    backend == .local ? [try DSHClient.ensureLocalOllamaPatch()] : []
                let storedTimeout = UserDefaults.standard.double(forKey: DSHSettings.timeoutKey)
                let timeout = storedTimeout > 0 ? storedTimeout : DSHSettings.defaultTimeout
                let readOnly = UserDefaults.standard.bool(forKey: DSHSettings.readOnlyKey)
                return DSHClient(
                    configuration: .init(
                        executable: dsh,
                        patches: patches,
                        workingDirectory: folder.path,
                        timeout: timeout,
                        permissionMode: readOnly ? "read-only" : nil))
            },
            startRecording: {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vb-chat-\(UUID().uuidString).wav")
                try await recorder.start(url: url)
            },
            stopRecording: { await recorder.stop() },
            transcribe: { clip in
                // The clip is only needed until whisper has read it.
                defer { try? FileManager.default.removeItem(at: clip) }
                // The same model + language the rest of the app uses.
                let config = TTSConfigManager(persistChanges: false)
                config.scan()
                let model =
                    config.selectedSttModelAvailable
                    ? config.selectedSttModel : config.availableSttModels.first
                guard let model else {
                    throw VoiceError.modelMissing(
                        model: "a whisper model", directory: config.paths.whisperDir.path)
                }
                return try await WhisperCliBackend(modelDirectory: config.paths.whisperDir)
                    .transcribe(
                        audio: clip, language: config.selectedSttLanguage, model: model,
                        useTimestamps: false
                    ).text
            },
            speak: { text in try? await SystemSpeech.speak(text) },
            loadSession: { folder in
                UserDefaults.standard.string(forKey: DSHSettings.sessionKey(for: folder))
            },
            saveSession: { folder, session in
                let key = DSHSettings.sessionKey(for: folder)
                if let session {
                    UserDefaults.standard.set(session, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            })
    }
}

// MARK: - Bubbles

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                bubble(fill: Color.accentColor, foreground: .white)
            }
        case .assistant:
            HStack {
                bubble(fill: Color(nsColor: .controlBackgroundColor), foreground: .primary)
                Spacer(minLength: 60)
            }
        case .notice:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.red.opacity(0.08)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func bubble(fill: Color, foreground: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.viaVoice {
                Label("Voice", systemImage: "waveform")
                    .font(.caption2)
                    .opacity(0.8)
            }
            Text(message.text)
                .textSelection(.enabled)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary.opacity(0.6)))
    }
}

private struct WorkingBubble: View {
    let phase: DSHChatModel.Phase
    /// What DSH is doing ("Writing probe.txt…"), when it has said.
    let activity: String?

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
            Spacer()
        }
    }

    private var caption: String {
        switch phase {
        case .transcribing: return "Transcribing…"
        case .speaking: return "Speaking…"
        default: return activity ?? "DeepSeek Harness is working…"
        }
    }
}

extension URL {
    /// `~/…` for paths in the home folder.
    fileprivate var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
