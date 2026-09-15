// SettingsView.swift - the TTS config page. Receives the manager by
// initialization (the same @StateObject instance the main window uses), so a
// change here applies to the next Speak and is persisted to disk.
//
// "What is the config selection for TTS?" - see the explainer at the top of
// the Form below: it names what "Engine" and "Voice" mean and what the two
// save buttons on the main page do.

import SwiftUI
import VoiceBridgeCore

struct SettingsView: View {
         @ObservedObject var ttsConfig: TTSConfigManager

        /// A short human description of the currently-selected engine.
     private var engineBlurb: String {
         switch ttsConfig.selectedMode {
         case .piper:   return "Piper runs fully on your Mac (offline). "
                          + "The voice is downloaded once, then reused."
           case .kokoro: return "Kokoro-82M runs fully on your Mac (offline). "
                          + "High-quality neural voice; first utterance warms up ~15 s."
           case .edgeTTS: return "Edge TTS streams from Microsoft's servers. "
                          + "Best quality, needs the Internet each time."
           case .system:  return "Built-in macOS voice. No download, always "
                          + "available, but basic quality."
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
         Form {
             Section {
             Text("TTS ENGINE SELECTION")
                 .font(.caption).fontWeight(.bold)
                 .foregroundStyle(.secondary)
             Text("Engine = how the speech is produced. "
                  + "Voice = the Piper/Kokoro voice to use. "
                  + "Changes apply the next time you press \"Speak\" "
                  + "on the main page and are saved here automatically.")
                  .font(.caption)
                  .foregroundStyle(.secondary)

              Picker("Engine", selection: $ttsConfig.selectedMode) {
               ForEach(TTSMode.allCases) { mode in
                  Text(mode.rawValue).tag(mode)
                 }
                }
                .help("The engine that produces speech.")

              Picker("Voice", selection: $ttsConfig.selectedModelFile) {
               Text("Engine default").tag(String?.none)
                ForEach(ttsConfig.availableLocalModels, id: \.self) { name in
                  Text(name).tag(Optional(name))
                 }
                }
                .disabled(ttsConfig.selectedMode == .system || ttsConfig.selectedMode == .edgeTTS)
                .help("Pick a Piper .onnx voice. Other engines use their own default.")

              Text(engineBlurb)
                 .font(.caption)
                 .foregroundStyle(ttsConfig.configSavedAt == nil ? Color.secondary : Color.green)

                LabeledContent("Model root") {
                  Text(ttsConfig.modelRoot.path).textSelection(.enabled)
                 }

              Button("Refresh local models") { ttsConfig.scan() }

               Text("Found \(ttsConfig.availableLocalModels.count) "
                    + "local voice(s) on disk.")
                 .font(.caption).foregroundStyle(.secondary)
            }  // end Section "TTS ENGINE SELECTION"

            Section {
                 Text("WHAT THE SAVE BUTTONS DO")
                     .font(.caption).fontWeight(.bold)
                     .foregroundStyle(.secondary)
                 Text("\u{2022} TTS card \u{2192} \"Save Speech (.wav)\" "
                      + "saves the audio that was generated. "
                      + "\u{2022} STT card \u{2192} \"Save Transcript (.txt)\" "
                      + "saves what the microphone heard.")
                     .font(.caption).foregroundStyle(.secondary)

                   Button("Test Speak (with current config)") {
                       Task { await ttsConfig.previewSpeak("This is VoiceBridge.") }
                        }
                        .help("Speaks a sample with the engine + voice chosen above. "
                             + "If the voice changes, the setting is live.")
                     HStack {
                         Spacer()
                         Text(savedLabel)
                             .font(.caption)
                             .foregroundStyle(ttsConfig.configSavedAt == nil
                                               ? Color.secondary : Color.green)
                       }
                 }
         }
         .padding()
         .frame(width: 460, height: 440)
        }
}
