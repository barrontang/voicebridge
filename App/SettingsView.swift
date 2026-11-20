// SettingsView.swift — the config page. Receives the manager by
// initialization (the same @StateObject instance the main window uses), so a
// change here applies to the next Speak/transcription and is persisted to disk.
//
// Five groups:
//   1) TEXT-TO-SPEECH ENGINE  — which TTS engine + voice produces the audio.
//   2) SPEECH-TO-TEXT ENGINE  — which whisper model listens/transcribes.
//   3) DOWNLOAD MODELS        — install a model without a terminal.
//   4) MODEL FOLDER           — where the models live.
//   5) WHAT THE SAVE BUTTONS DO — the shared explainer.
//
// The two save buttons on the main page: TTS card → "Save Speech (.wav)" saves
// the audio generated; STT card → "Save Transcript (.txt)" saves what the mic
// heard.
//
// Layout note: the content lives in a ScrollView, not a Form. A Form inside a
// macOS `Settings` window does not scroll (the window is fixed-size), so with
// the model list the content overflowed and the bottom was unreachable.

import AppKit
import SwiftUI
import VoiceBridgeCore

struct SettingsView: View {
    @ObservedObject var ttsConfig: TTSConfigManager
    /// Drives the "download a model" rows.
    @StateObject private var downloads = ModelDownloadController()

    // DeepSeek Harness. Shared with the chat window through `DSHSettings`.
    @AppStorage(DSHSettings.pathKey) private var dshPath = ""
    @AppStorage(DSHSettings.readOnlyKey) private var dshReadOnly = false
    @AppStorage(DSHSettings.timeoutKey) private var dshTimeout = DSHSettings.defaultTimeout
    @State private var detectedDSH: String?

    // Speech-to-text. Shared with the main window through `SttEngineSettings`.
    @AppStorage(SttEngineSettings.Keys.kind) private var sttEngineRaw =
        SttEngineKind.whisperCLI.rawValue
    @AppStorage(SttEngineSettings.Keys.qwenTier) private var qwenTierRaw =
        QwenAsrTier.fast.rawValue
    /// Empty = one model for everything; otherwise the tier for the final pass.
    @AppStorage(SttEngineSettings.Keys.qwenFinalTier) private var qwenFinalTierRaw = ""
    @State private var detectedLlama: String?

    /// A short human description of the currently-selected TTS engine.
    private var ttsEngineBlurb: String {
        switch ttsConfig.selectedMode {
        case .piper:
            return "Piper runs fully on your Mac (offline). "
                + "The voice downloads once, then is reused."
        case .kokoro:
            return "Kokoro-82M runs fully on your Mac (offline). "
                + "High-quality neural voice; first run warms up ~15 s."
        case .edgeTTS:
            return "Edge TTS streams from Microsoft's servers. "
                + "Best quality, needs the Internet each time."
        case .fishAudio:
            let remote = EnginePrivacy.requiresNetwork(
                mode: .fishAudio,
                modelRoot: ttsConfig.paths.root)
            return "Fish Audio Drama 3 - a 35B model with "
                + "multi-speaker voices and voice cloning. "
                + "Runs locally from the 4-bit MLX checkpoint "
                + "(scripts/install-drama3-mlx.sh), or against a "
                + "server set in VOICEBRIDGE_FISH_TTS. "
                + (remote
                    ? "Currently ONLINE: your text is sent to that server."
                    : "Currently on this Mac: nothing is transmitted.")
        case .system:
            return "Built-in macOS voice. No download, always "
                + "available, basic quality."
        }
    }

    /// A "Saved HH:MM:SS" label so the user can see a change took effect.
    private var savedLabel: String {
        if let at = ttsConfig.configSavedAt {
            return "Saved " + at.formatted(date: .omitted, time: .standard)
        }
        return "Not yet saved"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ttsGroup
                sttGroup
                downloadGroup
                folderGroup
                dshGroup
                explainerGroup
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 660)
        .onAppear {
            ttsConfig.scan()
            ttsConfig.scanSttModels()
            detectDSH()
            detectLlama()
            // After a download, the model lists (and the main page) must be
            // refreshed - otherwise a freshly installed model stays invisible.
            downloads.onInstalled = {
                ttsConfig.scan()
                ttsConfig.scanSttModels()
            }
        }
    }

    // MARK: - Group 1: text-to-speech

    private var ttsGroup: some View {
        GroupBox("Text-to-speech engine") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Engine = how the speech is produced. "
                        + "Voice = the Piper/Kokoro voice to use. "
                        + "Changes apply the next time you press \"Speak\" "
                        + "on the main page and are saved here automatically."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker("Engine", selection: $ttsConfig.selectedMode) {
                    ForEach(TTSMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .help("The engine that produces speech.")

                Picker("Voice", selection: $ttsConfig.selectedModelFile) {
                    Text("Engine default").tag(String?.none)
                    ForEach(ttsConfig.availableLocalModels, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
                .disabled(
                    ttsConfig.selectedMode == .system
                        || ttsConfig.selectedMode == .edgeTTS
                        || ttsConfig.selectedMode == .fishAudio
                )
                .help("Pick a Piper .onnx voice. Other engines use their own default.")

                Text(ttsEngineBlurb)
                    .font(.caption)
                    .foregroundStyle(ttsConfig.configSavedAt == nil ? Color.secondary : Color.green)

                LabeledContent("Model root") {
                    Text(ttsConfig.modelRoot.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Refresh TTS voices") { ttsConfig.scan() }
                    Spacer()
                    Text(
                        "Found \(ttsConfig.availableLocalModels.count) "
                            + "local voice(s) on disk."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Group 2: speech-to-text

    private var sttGroup: some View {
        GroupBox("Speech-to-text engine") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Used by both push-to-talk and live (streaming) transcription "
                        + "on the main page. whisper.cpp needs a ggml model on disk; "
                        + "Qwen3-ASR needs its GGUF pair and llama.cpp."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker("Engine", selection: $sttEngineRaw) {
                    ForEach(SttEngineKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                .help(
                    "Qwen3-ASR runs on llama.cpp, stays on this Mac, and handles "
                        + "30 languages plus 22 Chinese dialects including Cantonese.")

                if sttEngineRaw == SttEngineKind.qwen3.rawValue {
                    qwenControls
                } else {
                    Picker("Model", selection: $ttsConfig.selectedSttModel) {
                        ForEach(SttModel.allCases, id: \.rawValue) { m in
                            Text(sttModelLabel(m)).tag(m)
                        }
                    }
                    .help("The whisper model used to transcribe speech.")
                }

                Picker("Language", selection: $ttsConfig.selectedSttLanguage) {
                    Text("Auto-detect").tag(String?.none)
                    ForEach(Self.sttLanguageChoices) { choice in
                        Text(choice.label).tag(String?.some(choice.id))
                    }
                }
                .help(
                    "Pinning the language is much more accurate than auto-detect, "
                        + "especially for live captions: a short window is not "
                        + "enough audio to identify the language reliably.")

                Toggle(
                    "Contextual correction (local LLM)",
                    isOn: $ttsConfig.correctionEnabled
                )
                .help(
                    "After each live sentence, a local model fixes only the words "
                        + "whisper misheard, using the preceding sentences as context.")

                HStack(spacing: 8) {
                    Text("Ollama model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("qwen3.5:4b", text: $ttsConfig.correctionModel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!ttsConfig.correctionEnabled)
                        .frame(maxWidth: 220)
                }

                Text(
                    "Text — never audio — is sent to a model on this Mac "
                        + "(127.0.0.1:11434). If Ollama is not running, captions "
                        + "simply keep whisper's words. Corrections never rewrite a "
                        + "sentence: only misheard words are replaced, and a change "
                        + "that rewrites too much is rejected."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("On disk") {
                    Text(
                        ttsConfig.availableSttModels.count == 0
                            ? "none — download one below"
                            : ttsConfig.availableSttModels
                                .map(\.ggmlFilename).joined(separator: ", ")
                    )
                    .font(.caption)
                    .textSelection(.enabled)
                }

                HStack(spacing: 6) {
                    if ttsConfig.selectedSttModelAvailable {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Selected model is available on disk.")
                            .font(.caption)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Not on disk — download it below.")
                            .font(.caption)
                    }
                    Spacer()
                }

                HStack {
                    Button("Refresh STT models") { ttsConfig.scanSttModels() }
                    Spacer()
                    LabeledContent("Whisper dir") {
                        Text(ttsConfig.paths.whisperDir.path)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Everything that only matters when Qwen3-ASR is the chosen engine.
    @ViewBuilder private var qwenControls: some View {
        Picker("Model", selection: $qwenTierRaw) {
            ForEach(QwenAsrTier.allCases, id: \.rawValue) { tier in
                Text(tier.displayName).tag(tier.rawValue)
            }
        }
        .help("Both tiers are the same family; 0.6B is ~2× faster, 1.7B is more accurate.")

        Toggle("Use the 1.7B model for the final text", isOn: twoTierBinding)
            .disabled(qwenTierRaw == QwenAsrTier.accurate.rawValue)
            .help(
                "Partial captions stream from the fast model; a finished sentence is "
                    + "re-transcribed by the larger one. Costs a second server in memory.")

        LabeledContent("Weights") {
            Text(qwenWeightsStatus)
                .font(.caption)
                .textSelection(.enabled)
        }

        LabeledContent("llama-server") {
            Text(detectedLlama ?? "not found")
                .font(.caption)
                .textSelection(.enabled)
                .foregroundStyle(detectedLlama == nil ? Color.orange : Color.secondary)
        }

        HStack(spacing: 6) {
            Button("Find llama.cpp") { detectLlama() }
            Spacer()
            LabeledContent("Qwen dir") {
                Text(ttsConfig.paths.qwen3Dir.path)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }

        Text(
            "Runs entirely on this Mac: llama-server binds 127.0.0.1 only, and "
                + "there is no setting that points it elsewhere. Nothing is sent "
                + "anywhere — not the audio, not the transcript."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// "on" when both files of the selected tier (and the final tier) exist.
    private var qwenWeightsStatus: String {
        var tiers = [qwenTierRaw]
        if !qwenFinalTierRaw.isEmpty { tiers.append(qwenFinalTierRaw) }
        let missing = tiers.compactMap(QwenAsrTier.init(rawValue:)).filter { tier in
            let dir = ttsConfig.paths.qwen3Dir
            let weights = dir.appendingPathComponent(tier.modelFileName)
            let projector = dir.appendingPathComponent(tier.mmprojFileName)
            return
                !(FileManager.default.fileExists(atPath: weights.path)
                && FileManager.default.fileExists(atPath: projector.path))
        }
        return missing.isEmpty
            ? "ready" : "missing \(missing.map(\.shortLabel).joined(separator: ", "))"
    }

    /// Empty storage means "one model for everything".
    private var twoTierBinding: Binding<Bool> {
        Binding(
            get: { qwenFinalTierRaw == QwenAsrTier.accurate.rawValue },
            set: { on in
                qwenFinalTierRaw = on ? QwenAsrTier.accurate.rawValue : ""
            })
    }

    private func detectLlama() {
        detectedLlama = try? QwenAsrServer.locateExecutable()
    }

    // MARK: - Group 3: downloads
    private var downloadGroup: some View {
        GroupBox("Download models") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "One click, no terminal. Downloads land in the model folder "
                        + "below and are verified before they are moved into place."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(downloads.rows(for: ModelCatalog.stt, in: ttsConfig.paths)) { row in
                    downloadRow(row)
                }
                ForEach(downloads.rows(for: ModelCatalog.qwen, in: ttsConfig.paths)) { row in
                    downloadRow(row)
                }
                ForEach(downloads.rows(for: ModelCatalog.tts, in: ttsConfig.paths)) { row in
                    downloadRow(row)
                }

                if !downloads.status.isEmpty {
                    Text(downloads.status)
                        .font(.caption)
                        .foregroundStyle(downloads.lastError == nil ? Color.secondary : Color.red)
                }
                if let error = downloads.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if downloads.activeModelID != nil {
                        Button("Cancel download") { downloads.cancel() }
                    }
                    Button("Refresh") {
                        ttsConfig.scan()
                        ttsConfig.scanSttModels()
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Group 4: model folder

    private var folderGroup: some View {
        GroupBox("Model folder") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Where VoiceBridge looks for models. The default is "
                        + "~/.voicebridge/models/tts. Pick a different folder and "
                        + "both STT and TTS follow it - the choice is saved."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Location") {
                    Text(ttsConfig.modelRoot.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Choose folder...") { chooseModelRoot() }
                    Button("Use default") {
                        ttsConfig.configureRoot(ModelPaths.fromEnvironment().root)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Group 5: DeepSeek Harness

    private var dshGroup: some View {
        GroupBox("DeepSeek Harness") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "The chat window (⇧⌘D) and `voicebridge-cli chat` drive DeepSeek "
                        + "Harness through its headless CLI. An app launched from the "
                        + "Finder cannot see your shell's PATH, so if `dsh` lives "
                        + "somewhere unusual, point at it here."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("dsh") {
                    HStack(spacing: 6) {
                        if detectedDSH == nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text(dshDescription)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("Choose dsh...") { chooseDSHLauncher() }
                    Button("Find automatically") {
                        dshPath = ""
                        detectDSH()
                    }
                    Spacer()
                }

                Toggle("Read-only: DSH may read files but not edit them", isOn: $dshReadOnly)
                    .help(
                        "Runs DSH with --permission-mode read-only. Answers still work; "
                            + "every write or command that changes files is refused.")

                Stepper(value: $dshTimeout, in: 60...3600, step: 60) {
                    Text("Timeout: \(Int(dshTimeout)) s").font(.callout)
                }
                .help("How long one task may run before it is killed.")

                Text(
                    "The folder DSH works in is chosen in the chat window. It is created "
                        + "as ~/Documents/VoiceBridge by default, because DSH can edit "
                        + "whatever is selected there."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// What to show next to the "dsh" label.
    private var dshDescription: String {
        if let detectedDSH { return detectedDSH }
        if !dshPath.isEmpty { return "\(dshPath) (not executable)" }
        return "Not found - install DeepSeek Harness, or choose its launcher."
    }

    /// Re-run discovery with the current override.
    private func detectDSH() {
        detectedDSH = DSHClient.locate(override: dshPath.isEmpty ? nil : dshPath)
    }

    private func chooseDSHLauncher() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use dsh"
        panel.message = "Pick the `dsh` launcher inside DeepSeek Harness."
        panel.directoryURL = URL(
            fileURLWithPath: "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dshPath = url.path
        detectDSH()
    }

    // MARK: - Group 6: explainer

    private var explainerGroup: some View {
        GroupBox("What the save buttons do") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "• TTS card → \"Save Speech\" saves the audio that was generated. "
                        + "• STT card → \"Save Transcript\" saves what the microphone heard."
                )
                .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("Test Speak (with current TTS config)") {
                        Task { await ttsConfig.previewSpeak("This is VoiceBridge.") }
                    }
                    .help("Speaks a sample with the engine + voice chosen in group 1.")
                    Spacer()
                    Text(savedLabel)
                        .font(.caption)
                        .foregroundStyle(
                            ttsConfig.configSavedAt == nil
                                ? Color.secondary : Color.green)
                }
            }
        }
    }

    // MARK: - Helpers

    /// One row of the download list.
    private func downloadRow(_ row: ModelDownloadController.Row) -> some View {
        let model = row.model
        let fraction = downloads.progress[model.id]
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.callout)
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 220)
                } else {
                    Text(
                        ByteCountFormatter.string(fromByteCount: model.byteSize, countStyle: .file)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if row.isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("Already on disk.")
            } else if downloads.activeModelID == model.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Download") {
                    downloads.download(model, into: ttsConfig.paths)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Ask the user for a model folder and adopt it.
    private func chooseModelRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        panel.message = "Choose the folder that holds your models."
        panel.directoryURL = ttsConfig.modelRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ttsConfig.configureRoot(url)
    }

    /// The picker label, annotated with whether the model is on disk.
    private struct SttLanguageChoice: Identifiable {
        let id: String
        let label: String
    }

    /// whisper's language codes, most likely first. `nil` (auto) stays the
    /// default so nothing changes for a user who never opens this picker.
    private static let sttLanguageChoices: [SttLanguageChoice] = [
        SttLanguageChoice(id: "zh", label: "Chinese · 中文"),
        SttLanguageChoice(id: "en", label: "English"),
        SttLanguageChoice(id: "ja", label: "Japanese · 日本語"),
        SttLanguageChoice(id: "ko", label: "Korean · 한국어"),
        SttLanguageChoice(id: "es", label: "Spanish"),
        SttLanguageChoice(id: "fr", label: "French"),
        SttLanguageChoice(id: "de", label: "German"),
        SttLanguageChoice(id: "ru", label: "Russian"),
        SttLanguageChoice(id: "pt", label: "Portuguese"),
        SttLanguageChoice(id: "it", label: "Italian"),
    ]

    private func sttModelLabel(_ m: SttModel) -> String {
        let onDisk = ttsConfig.availableSttModels.contains(m)
        let marker = onDisk ? "" : "  (not downloaded)"
        return m.label + marker
    }
}
