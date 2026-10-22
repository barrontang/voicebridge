import Foundation
import Combine
import os

/// Fixes the original PRD's bug:
///
///       * The PRD put `@ObservedObject var ttsConfig = TTSConfigManager()`
///         *inside* `SettingsView`. That recreates the object on every render,
///        so published state is lost the moment the view re-renders — the UI
///        forgets the user's selection.
///       * Correct pattern: the parent app owns the manager as `@StateObject`,
///        and each view *receives* it via `@ObservedObject`.
///
/// See `App/VoiceBridgeApp.swift` for the `@StateObject` + injection shape.
///
/// Models live under a user-chosen directory. The scan path is sandbox-aware
/// (see `scan` and `docs/RUNBOOK.md`).
///
/// **Meta-fix (the "one root cause" of Findings 1/2/3/11):** path resolution now
/// lives in a `paths: ModelPaths` value owned by *this* manager, so a custom
/// model folder chosen via `configureRoot` updates the single source of truth that
/// both TTS (`environment().paths.piperVoiceDir`) and STT (`scanSttModels` →
/// `paths.whisperDir`) read. Before, TTS honored the override while STT read the
/// static `ModelPaths.whisperDir` — the "half my models disappeared" bug.
@MainActor
public final class TTSConfigManager: ObservableObject {

            /// The resolved model layout; all engine paths come off this.
    @Published public private(set) var paths: ModelPaths

          /// The on-disk root; all engine paths resolve against it.
    @Published public var modelRoot: URL
     /// The currently-active engine. Default is Piper per the project brief.
     @Published public var selectedMode: TTSMode = .piper {
        didSet { persist() }
         }

     /// When we last wrote config to disk - shown on the Settings page so the
     /// user can confirm their change actually applied (and persisted).
    @Published public private(set) var configSavedAt: Date? = nil

           // --- STT (whisper) selection: the second settings group. ----
             /// The whisper model the Speech-to-Text cards use. Persisted with the rest.
    @Published public var selectedSttModel: SttModel = .largeV3Turbo {
        didSet { persist() }
         }
        /// whisper models physically present under `whisperDir` (refreshed by `scan()`).
    @Published public private(set) var availableSttModels: [SttModel] = []

      /// True when the currently-selected STT model exists on disk.
    @MainActor public var selectedSttModelAvailable: Bool {
        availableSttModels.contains(selectedSttModel)
          }

    // Guard against writing during the initial load().
    private var isLoaded = false
    /// Set when the on-disk config was written by a *newer* build: we read
    /// what we understand and refuse to overwrite the newer file.
    private var configIsReadOnly = false
    /// Set when the on-disk config was in an older format and should be
    /// rewritten in the current one (forward migration).
    private var needsRewrite = false

          /// The voice the picked engine loads. For Piper this is a filename; for
         /// edge-tts / system it's a voice name. `nil` means "use engine default".
     @Published public var selectedModelFile: String? = nil {
        didSet { persist() }
        }

         /// Voices found on-disk. Refreshed via `scan()` ("刷新本地模型文件夹").
    @Published public var availableLocalModels: [String] = []

         /// The directory `scan()` looks at for `.onnx` Piper voices.
     @Published public var scanDirectory: URL

    // MARK: - configuration persistence (Fixing Finding 3 + Missing 4)

     /// Canonical, *persistent* settings URL (`~/Library/Application Support/
     /// VoiceBridge/config.json`, not the reclaimed temp dir the old code used).
     public var persistURL: URL {
        if let explicitPersistURL { return explicitPersistURL }
        return (try? AppPaths.configURL()) ?? fallbackConfigURL
        }

       /// Test/dev override for `persistURL`.
    public var explicitPersistURL: URL? = nil

       /// Last-resort location when Application Support can't be resolved (tests,
       /// sandboxless contexts).
    public var fallbackConfigURL: URL = FileManager.default.temporaryDirectory
                                       .appendingPathComponent("voicebridge-fallback.json")

       /// The settings version we read/write; bump + add a `migrate` step when the
        /// structure changes (Missing 4 — a 20-minute guard against a silent
        /// full-reset of every user's config on the next schema bump).
       /// v2 adds the custom model root (`root`).
    public static let schemaVersion = 2

     /// Current version embedded in persisted state.
    public let schema: Int = TTSConfigManager.schemaVersion

         /// Builds the environment a `TTSManager` / backend resolves paths from —
         /// the injected root (never the static default).
    @MainActor public func environment() -> VoiceBridgeEnvironment {
        VoiceBridgeEnvironment(paths: paths, binaryLocator: BinaryLocator())
         }

         /// The canonical model root for this instance.
     nonisolated public static var defaultModelsDirectory: URL {
        ModelPaths.fromEnvironment().root
         }

     // MARK: - persistence

     @discardableResult public func persist() -> URL? {
        guard isLoaded else { return nil }
        guard !configIsReadOnly else {
            VBLog.models.warning("config persist skipped: the file was written by a newer VoiceBridge")
            return nil
            }
         struct Cfg: Codable {
            let schemaVersion: Int
            let mode: TTSMode
            let voice: String?
            let sttModel: SttModel?
            /// v2: the user's custom model root (the default location when nil).
            let root: String?
            init(schemaVersion: Int, mode: TTSMode, voice: String?,
                 sttModel: SttModel?, root: String?) {
                self.schemaVersion = schemaVersion
                self.mode = mode
                self.voice = voice
                self.sttModel = sttModel
                self.root = root
                      }
                    }
        let cfg = Cfg(schemaVersion: schema,
                         mode: selectedMode,
                    voice: selectedModelFile,
                    sttModel: selectedSttModel,
                    root: modelRoot.path)
        do {
            let data = try JSONEncoder().encode(cfg)
            let url = persistURL
             // Create the parent dir and write atomically (never leave a half-file).
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            configSavedAt = Date()
            return url
              } catch {
                _ = (error as any CustomStringConvertible).description
            VBLog.models.error("config persist failed: \(error)")
            return nil
              }
         }

     /// Speak a short sample with the currently selected engine + voice, so the
        /// user can confirm from the Settings page that their change is live.
     @MainActor public func previewSpeak(_ text: String) async {
         _ = try? await TTSManager(config: self)
                       .speak(text, mode: selectedMode, voice: selectedModelFile, play: true)
         }

      /// Load persisted state, migrating the one-time legacy location first.
    func load() {
        // Fix Finding 3: move any legacy temp-dir config to Application Support.
        _ = AppPaths.migrateLegacyConfigIfNeeded()

        let url = persistURL
        guard let data = try? Data(contentsOf: url) else { return }

        // The current schema (v2): every field optional, so an older payload
        // still decodes.
        struct Cfg: Decodable {
            let schemaVersion: Int?
            let mode: TTSMode?
            let voice: String?
            let sttModel: SttModel?
            let root: String?
            }
        struct CfgLegacy: Decodable {            // schemaVersion 0 / pre-versioning
            let mode: TTSMode?
            let voice: String?
            let sttModel: SttModel?
            }

        guard let cfg = try? JSONDecoder().decode(Cfg.self, from: data) else {
            if let legacy = try? JSONDecoder().decode(CfgLegacy.self, from: data) {
                // A pre-versioning record: apply it, then rewrite it in the
                // current schema (a forward migration).
                if let m = legacy.mode { selectedMode = m }
                if let v = legacy.voice { selectedModelFile = v }
                if let s = legacy.sttModel { selectedSttModel = s }
                needsRewrite = true
                VBLog.models.info("migrated a pre-versioned config to schema \(Self.schemaVersion)")
            }
            return
            }

        // A record with no `schemaVersion` at all is pre-versioning: it
        // decoded fine (every field is optional), but it must be rewritten in
        // the current schema.
        if cfg.schemaVersion == nil {
            needsRewrite = true
            VBLog.models.info("migrated a pre-versioned config to schema \(Self.schemaVersion)")
            }

        // A config written by a NEWER build: read what we understand, but do
        // not clobber the file (the newer build's fields would be lost).
        if let v = cfg.schemaVersion, v > Self.schemaVersion {
            configIsReadOnly = true
            VBLog.models.warning("config schema v\(v, privacy: .public) is newer than v\(Self.schemaVersion, privacy: .public); reading what we understand and leaving the file alone")
            }

        if let m = cfg.mode { selectedMode = m }
        if let v = cfg.voice { selectedModelFile = v }
        if let s = cfg.sttModel { selectedSttModel = s }

        // v2: restore the custom model root, if the user picked one.
        if let root = cfg.root, !root.isEmpty {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            if rootURL != modelRoot {
                applyRoot(rootURL)
                needsRewrite = true
            }
        }
          }

    public init(persistURL: URL? = nil) {
// Initialize all stored properties from a *local* first; referencing
// `self.paths` before every stored property is set is an error.
    let env = ModelPaths.fromEnvironment()
    self.paths = env
    self.modelRoot = env.root
    self.scanDirectory = env.piperVoiceDir
    if let persistURL { self.explicitPersistURL = persistURL }
    // Now `self` is fully initialized; safe to call methods.
    load()
    scanSttModels()
    isLoaded = true
    // Forward migration: an older (or pre-versioning) config is rewritten in
    // the current schema *now*, not the next time the user happens to change
    // a setting. (The old code claimed to do this but the `isLoaded` guard
    // silently skipped it.)
    if needsRewrite && !configIsReadOnly {
        needsRewrite = false
        persist()
    }
    }

          /// Replaces the root for all engines and rescans. This is the one place
           /// a custom model folder is set; both TTS and STT now follow because they
             /// read from `paths`, which this updates.
     public func configureRoot(_ newRoot: URL) {
        applyRoot(newRoot)
        scan()
        scanSttModels()
        // The chosen root is part of the user's settings: persist it so the
        // next launch uses the same folder.
        persist()
          }

           /// Points every engine at `newRoot` (no scan, no persist - the
            /// caller decides when to do those).
    public func applyRoot(_ newRoot: URL) {
        self.paths = .make(newRoot)
        self.scanDirectory = newRoot
                     .appendingPathComponent("piper/voice", isDirectory: true)
        self.modelRoot = newRoot
          }

           /// Rescans `scanDirectory` for `.onnx` voices (Piper ships an
            /// `.onnx` + `.onnx.json` pair — we ignore the json config).
    public func scan() {
        let dir = scanDirectory
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
             availableLocalModels = files
                   .filter { $0.pathExtension == "onnx" }
                   .map { $0.lastPathComponent.lastPathComponentWithoutSuffix }
                   .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
         } catch {
            VBLog.models.warning("scan failed at \(dir.path): \(error)")
          availableLocalModels = []
          }
            // Keep the STT model list in sync so the two settings groups agree.
        scanSttModels()
         }

          /// Rescan where STT models live, keeping the speech-to-text settings
             /// group fresh alongside the TTS voice scan.
      /// **Fix Finding 1:** resolve against this instance's `paths.whisperDir`,
      /// which honors a custom root, instead of the static `ModelPaths.whisperDir`.
    public func scanSttModels() {
        availableSttModels = SttModel.allCases.filter {
            let url = paths.whisperDir.appendingPathComponent($0.ggmlFilename)
            return FileManager.default.fileExists(atPath: url.path)
            }
                     // Refresh the available-set only when the root actually changes;
                     // otherwise a no-op reconfigure shouldn't thrash `@Published`.
        }

          /// Resolves a voice name into an absolute URL for the chosen engine;
            /// nil for engines that load no on-disk model (`system` / `edgeTTS`).
     public func resolveAbsoluteVoiceURL(_ voiceName: String?, engine: TTSMode) -> URL? {
        guard let name = voiceName else { return nil }
        switch engine {
        case .piper:
            return scanDirectory.appendingPathComponent(name).appendingPathExtension("onnx")
        case .kokoro:
            return paths.kokoroDir.appendingPathComponent(name).appendingPathExtension("onnx")
        case .system:
            return nil
        case .edgeTTS, .fishAudio:
            return nil
          }
         }
}
