import Foundation
import SwiftUI

/// Fixes the original PRD's bug:
///
///      * The PRD put `@ObservedObject var ttsConfig = TTSConfigManager()`
///        *inside* `SettingsView`. That recreates the object on every render,
///        so published state is lost the moment the view re-renders — the UI
///        forgets the user's selection.
///      * Correct pattern: the parent app owns the manager as `@StateObject`,
///        and each view *receives* it via `@ObservedObject`.
///
/// See `App/VoiceBridgeApp.swift` for the `@StateObject` + injection shape.
///
/// Models live under a user-chosen directory. The scan path is sandbox-aware
/// (see `scan` and `docs/RUNBOOK.md`).
@MainActor
public final class TTSConfigManager: ObservableObject {

        /// The on-disk root; all engine paths resolve against it.
    @Published public var modelRoot: URL

        /// The currently-active engine. Default is Piper per the project brief.
    @Published public var selectedMode: TTSMode = .piper {
        didSet { persist() }
       }

    /// When we last wrote config to disk - shown on the Settings page so the
    /// user can confirm their change actually applied (and persisted).
    @Published public private(set) var configSavedAt: Date? = nil

    // Guard against writing during the initial load().
    private var isLoaded = false

        /// The voice the picked engine loads. For Piper this is a filename; for
       /// edge-tts / system it's a voice name. `nil` means "use engine default".
    @Published public var selectedModelFile: String? = nil {
        didSet { persist() }
     }

        /// Voices found on-disk. Refreshed via `scan()` ("刷新本地模型文件夹").
    @Published public var availableLocalModels: [String] = []

        /// The directory `scan()` looks at for `.onnx` Piper voices.
    @Published public var scanDirectory: URL

    public static var persistURL: URL {
        var comps = FileManager.default.temporaryDirectory
                     .deletingLastPathComponent()
        comps.appendPathComponent("voicebridge/config.json")
        return comps
       }

     @discardableResult public func persist() -> URL? {
        guard isLoaded else { return nil }
        struct Cfg: Codable { var mode: TTSMode; var voice: String? }
        let cfg = Cfg(mode: selectedMode, voice: selectedModelFile)
        do {
            let data = try JSONEncoder().encode(cfg)
            let url = Self.persistURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            configSavedAt = Date()
            return url
             } catch {
            return nil
             }
        }

    /// Speak a short sample with the currently selected engine + voice, so the
     /// user can confirm from the Settings page that their change is live.
    @MainActor public func previewSpeak(_ text: String) async {
        _ = try? await TTSManager(config: self)
                     .speak(text, mode: selectedMode, voice: selectedModelFile, play: true)
        }

     func load() {
        let url = Self.persistURL
        guard let data = try? Data(contentsOf: url) else { return }
        struct Cfg: Codable { var mode: TTSMode; var voice: String? }
        if let cfg = try? JSONDecoder().decode(Cfg.self, from: data) {
            selectedMode = cfg.mode
             selectedModelFile = cfg.voice
         }
        }

    public init() {
        self.modelRoot = ModelPaths.root
        self.scanDirectory = ModelPaths.piperVoiceDir
        load()
        self.isLoaded = true
       }

       /// The canonical model root for this instance. Forwards to
         /// `ModelPaths.root` (overridable via `VOICEBRIDGE_MODELS_MAP`).
       /// `nonisolated` so engines running off the main actor can read it.
    nonisolated public static var defaultModelsDirectory: URL { ModelPaths.root }

        /// Replaces the root for all engines and rescans.
     public func configureRoot(_ newRoot: URL) {
        self.modelRoot = newRoot
        self.scanDirectory = newRoot
                .appendingPathComponent("piper/voice", isDirectory: true)
        scan()
        }

        /// Rescans `scanDirectory` for `.onnx` voices (Piper ships an
           /// `.onnx` + `.onnx.json` pair — we ignore the json config).
     public func scan() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: scanDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
          availableLocalModels = files
                  .filter { $0.pathExtension == "onnx" }
                  .map { $0.lastPathComponent.lastPathComponentWithoutSuffix }
                  .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
          availableLocalModels = []
        }
        }

        /// Resolves a voice name into an absolute URL for the chosen engine;
          /// nil for engines that load no on-disk model (`system` / `edgeTTS`).
     public func resolveAbsoluteVoiceURL(_ voiceName: String?, engine: TTSMode) -> URL? {
        guard let name = voiceName else { return nil }
        switch engine {
        case .piper:
            return scanDirectory.appendingPathComponent(name).appendingPathExtension("onnx")
        case .kokoro:
            return ModelPaths.kokoroDir.appendingPathComponent(name).appendingPathExtension("onnx")
        case .system:
            return nil
        case .edgeTTS:
            return nil
         }
        }
}
