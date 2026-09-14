// SettingsView.swift — reference settings panel. Receives the manager via
// @ObservedObject (injection), so a change here persists instead of being
// forgotten on the next render — the exact bug the original PRD had.
//
// Reference source, not part of the Swift package. See VoiceBridgeApp.swift.

import SwiftUI
import VoiceBridgeCore

struct SettingsView: View {
    @ObservedObject var ttsConfig: TTSConfigManager

    var body: some View {
        Form {
            Picker("Engine", selection: $ttsConfig.selectedMode) {
                ForEach(TTSMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Picker("Voice", selection: $ttsConfig.selectedModelFile) {
                Text("Engine default").tag(String?.none)
                ForEach(ttsConfig.availableLocalModels, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .disabled(ttsConfig.selectedMode == .system || ttsConfig.selectedMode == .edgeTTS)

            LabeledContent("Model root") {
                Text(ttsConfig.modelRoot.path).textSelection(.enabled)
            }

            Button("Refresh local models") { ttsConfig.scan() }

            Text("Found \(ttsConfig.availableLocalModels.count) local voice(s).")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 420, height: 320)
    }
}

