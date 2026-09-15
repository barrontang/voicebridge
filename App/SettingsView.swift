// SettingsView.swift - the TTS config page. Receives the manager by
// initialization (the same @StateObject instance the main window uses), so a
// change here applies to the next Speak and is persisted to disk.

import SwiftUI
import VoiceBridgeCore

struct SettingsView: View {
        @ObservedObject var ttsConfig: TTSConfigManager

       private var savedLabel: String {
         if let at = ttsConfig.configSavedAt {
             return "Saved " + at.formatted(date: .omitted, time: .standard)
        }
        return "Not yet saved"
    }

     var body: some View {
          Form {
             Picker("Engine", selection: $ttsConfig.selectedMode) {
                  ForEach(TTSMode.allCases) { mode in
                       Text(mode.rawValue).tag(mode)
                   }
                  }
              .help("The engine that produces speech. Changing it applies to "
                   + "the next time you press \"Speak\" on the main page.")

             Picker("Voice", selection: $ttsConfig.selectedModelFile) {
                  Text("Engine default").tag(String?.none)
                   ForEach(ttsConfig.availableLocalModels, id: \.self) { name in
                        Text(name).tag(Optional(name))
                }
                }
                .disabled(ttsConfig.selectedMode == .system || ttsConfig.selectedMode == .edgeTTS)
                .help("A Piper .onnx voice; other engines use their own default.")

              LabeledContent("Model root") {
                   Text(ttsConfig.modelRoot.path).textSelection(.enabled)
                  }

               Button("Refresh local models") { ttsConfig.scan() }

                Text("Found \(ttsConfig.availableLocalModels.count) local voice(s).")
                    .foregroundStyle(.secondary)

                   Divider()

                     // Immediate proof the selection took effect.
                   HStack {
                        Button("Test Speak") {
                             Task { await ttsConfig.previewSpeak("This is VoiceBridge.") }
                        }
                        .help("Speaks a sample with the engine + voice chosen above. "
                             + "If the voice changes, the setting is live.")
                         Spacer()
                        Text(savedLabel)
                             .font(.caption)
                             .foregroundStyle(ttsConfig.configSavedAt == nil ? Color.secondary : Color.green)
                       }
                    }
                    .padding()
                    .frame(width: 440, height: 380)
            }
}
