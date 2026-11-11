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

struct DSHChatView: View {
    @StateObject private var chat: DSHChatModel
    @StateObject private var recorder: PushToTalkSession
    @AppStorage("dshChat.backend") private var backendRaw = DSHBackend.local.rawValue
    @FocusState private var inputFocused: Bool

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
        .frame(minWidth: 480, minHeight: 520)
        .onAppear { inputFocused = true }
        .onChange(of: chat.workingDirectory) {
            UserDefaults.standard.set(chat.workingDirectory.path, forKey: "dshChat.folder")
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
                    if chat.phase == .thinking || chat.phase == .transcribing {
                        WorkingBubble(phase: chat.phase).id("working")
                    }
                }
                .padding(14)
            }
            .onChange(of: chat.messages.count) { scrollToEnd(proxy) }
            .onChange(of: chat.phase) { scrollToEnd(proxy) }
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
                "Tap the mic and speak, or type. DSH works in the folder above and "
                    + "remembers the whole conversation."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
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
            .disabled(chat.isBusy || chat.phase == .recording)
            .onSubmit { Task { await chat.sendDraft() } }

            Button {
                Task { await chat.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
        }
        .padding(12)
    }

    private var canSend: Bool {
        chat.phase == .idle && !chat.draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var micButton: some View {
        let recording = chat.phase == .recording
        return Button {
            Task { await chat.toggleMicrophone() }
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
        .disabled(chat.isBusy)
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
        if panel.runModal() == .OK, let url = panel.url {
            chat.changeWorkingDirectory(url)
        }
    }

    private static func initialFolder() -> URL {
        if let saved = UserDefaults.standard.string(forKey: "dshChat.folder"),
            FileManager.default.fileExists(atPath: saved)
        {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Wiring the real engines

    /// Built once, so it reads settings at call time instead of capturing them.
    private static func dependencies(recorder: PushToTalkSession) -> DSHChatModel.Dependencies {
        DSHChatModel.Dependencies(
            makeAsker: { folder in
                guard let dsh = DSHClient.locate() else {
                    throw VoiceError.binaryNotFound(
                        component: "DeepSeek Harness (dsh)",
                        hint: "Install DeepSeek Harness, or set VOICEBRIDGE_DSH.")
                }
                let backend =
                    DSHBackend(
                        rawValue: UserDefaults.standard.string(forKey: "dshChat.backend") ?? "")
                    ?? .local
                let patches =
                    backend == .local ? [try DSHClient.ensureLocalOllamaPatch()] : []
                return DSHClient(
                    configuration: .init(
                        executable: dsh, patches: patches, workingDirectory: folder.path))
            },
            startRecording: {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vb-chat-\(UUID().uuidString).wav")
                try await recorder.start(url: url)
            },
            stopRecording: { await recorder.stop() },
            transcribe: { clip in
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
            speak: { text in try? await SystemSpeech.speak(text) })
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

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phase == .transcribing ? "Transcribing…" : "DeepSeek Harness is working…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
            Spacer()
        }
    }
}

extension URL {
    /// `~/…` for paths in the home folder.
    fileprivate var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
