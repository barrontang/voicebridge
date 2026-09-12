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
    @Published public var selectedMode: TTSMode = .piper

        /// The voice the picked engine loads. For Piper this is a filename; for
       /// edge-tts / system it's a voice name. `nil` means "use engine default".
    @Published public var selectedModelFile: String?

        /// Voices found on-disk. Refreshed via `scan()` ("刷新本地模型文件夹").
    @Published public var availableLocalModels: [String] = []

        /// The directory `scan()` looks at for `.onnx` Piper voices.
    @Published public var scanDirectory: URL

    public init() {
        self.modelRoot = ModelPaths.root
        self.scanDirectory = ModelPaths.piperVoiceDir
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
