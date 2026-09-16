// SettingsView.swift — the config page. Receives the manager by
// initialization (the same @StateObject instance the main window uses), so a
// change here applies to the next Speak/transcription and is persisted to disk.
//
// Two settings groups live side by side:
//   1) TEXT-TO-SPEECH ENGINE  — which TTS engine + voice produces the audio.
//   2) SPEECH-TO-TEXT ENGINE  — which whisper model listens/transcribes.
//
// The two save buttons on the main page: TTS card → "Save Speech (.wav)" saves
// the audio generated; STT card → "Save Transcript (.txt)" saves what the mic
// heard.

import SwiftUI
import VoiceBridgeCore

struct SettingsView: View {
        @ObservedObject var ttsConfig: TTSConfigManager

         /// A short human description of the currently-selected TTS engine.
     private var ttsEngineBlurb: String {
        switch ttsConfig.selectedMode {
        case .piper:   return "Piper runs fully on your Mac (offline). "
                              + "The voice downloads once, then is reused."
          case .kokoro: return "Kokoro-82M runs fully on your Mac (offline). "
                              + "High-quality neural voice; first run warms up ~15 s."
          case .edgeTTS: return "Edge TTS streams from Microsoft's servers. "
                              + "Best quality, needs the Internet each time."
          case .system:  return "Built-in macOS voice. No download, always "
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
         Form {
             // ── GROUP 1: TEXT-TO-SPEECH ENGINE ──────────────────────
            Section {
             Text("TEXT-TO-SPEECH ENGINE")
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

              Text(ttsEngineBlurb)
                  .font(.caption)
                  .foregroundStyle(ttsConfig.configSavedAt == nil ? Color.secondary : Color.green)

                LabeledContent("Model root") {
                  Text(ttsConfig.modelRoot.path).textSelection(.enabled)
                  }

              Button("Refresh TTS voices") { ttsConfig.scan() }

               Text("Found \(ttsConfig.availableLocalModels.count) "
                     + "local voice(s) on disk.")
                  .font(.caption).foregroundStyle(.secondary)
             }   // end GROUP 1

            // ── GROUP 2: SPEECH-TO-TEXT ENGINE ─────────────────────
            Section {
              Text("SPEECH-TO-TEXT ENGINE")
                   .font(.caption).fontWeight(.bold)
                   .foregroundStyle(.secondary)
              Text("This whisper model is used by both the push-to-talk and "
                    + "live (streaming) transcription on the main page. "
                    + "Bigger = more accurate. A model must be downloaded to "
                    + "disk before it can be used.")
                   .font(.caption)
                   .foregroundStyle(.secondary)

               Picker("Model", selection: $ttsConfig.selectedSttModel) {
                 ForEach(SttModel.allCases, id: \.rawValue) { m in
                   Text(sttModelLabel(m)).tag(m)
                     }
                }
                 .help("The whisper model used to transcribe speech.")

               LabeledContent("On disk") {
                  Text(ttsConfig.availableSttModels.count == 0
                        ? "none — download one below"
                        : ttsConfig.availableSttModels
                            .map(\.ggmlFilename).joined(separator: ", "))
                     .textSelection(.enabled)
                }

               if ttsConfig.selectedSttModelAvailable {
                   HStack {
                  Image(systemName: "checkmark.circle.fill")
                       .foregroundStyle(.green)
                   Text("Selected model is available on disk.")
                       .font(.caption)
                  Spacer()
                   }
                } else {
                   HStack {
                  Image(systemName: "exclamationmark.triangle.fill")
                       .foregroundStyle(.orange)
                  Text("Not on disk — run scripts/fetch-whisper-turbo.sh to download it.")
                       .font(.caption)
                  Spacer()
                   }
                 }

               Button("Refresh STT models") { ttsConfig.scanSttModels() }

               LabeledContent("Whisper dir") {
                 Text(ttsConfig.paths.whisperDir.path).textSelection(.enabled)
                 }
             }   // end GROUP 2

             // ── What the save buttons do (shared explainer) ─────────
            Section {
                 Text("WHAT THE SAVE BUTTONS DO")
                      .font(.caption).fontWeight(.bold)
                      .foregroundStyle(.secondary)
                 Text("\u{2022} TTS card \u{2192} \"Save Speech (.wav)\" "
                       + "saves the audio that was generated. "
                       + "\u{2022} STT card \u{2192} \"Save Transcript (.txt)\" "
                       + "saves what the microphone heard.")
                      .font(.caption).foregroundStyle(.secondary)

                   Button("Test Speak (with current TTS config)") {
                       Task { await ttsConfig.previewSpeak("This is VoiceBridge.") }
                         }
                         .help("Speaks a sample with the engine + voice chosen in group 1.")
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
         .frame(width: 480, height: 620)
         .onAppear { ttsConfig.scan(); ttsConfig.scanSttModels() }
     }

     /// The picker label, annotated with whether the model is on disk.
     private func sttModelLabel(_ m: SttModel) -> String {
         let onDisk = ttsConfig.availableSttModels.contains(m)
        let marker = onDisk ? "" : "  (not downloaded)"
        return m.label + marker
       }
}
