// ContentView.swift - main page for VoiceBridge.
//
// Two cards:
//   1) Text to Speech  - type text, Speak (or Stop to interrupt), Save .wav.
//   2) Speech to Text  - two modes:
//        * push-to-talk ("Start Listening" / "Stop & Transcribe")
//        * live streaming ("Live" / "Stop Live") with real-time captions
//     plus "Save transcript as .txt".
//
// TTS engine/voice selection lives on the Settings page.

import SwiftUI
import AppKit
import VoiceBridgeCore

/// State machine for the push-to-talk STT flow.
enum SttPhase {
   case idle            // not recording, not busy
   case requestingMic   // awaiting the macOS mic-permission prompt
   case recording       // microphone live; the button now stops & transcribes
   case transcribing    // mic stopped; whisper runs (button busy)
}

struct ContentView: View {
     @EnvironmentObject var ttsConfig: TTSConfigManager
     @Environment(\.openSettings) private var openSettingsAction

     // - TTS -
     @State private var text = "Hello. This is VoiceBridge, running fully on device."
     @State private var ttsStatus = "Ready."
     @State private var speaking = false
     @State private var currentTask: Task<Void, Never>?
     @State private var lastWav: URL?             // for "Save .wav..."

     // - STT -
     @State private var mic: MicrophoneCapture?
     @State private var sttPhase: SttPhase = .idle
     @State private var sttStatus = "Ready."
     @State private var sttModel: SttModel?
     @StateObject private var stream = StreamingSttController(model: .tiny)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
            Text("VoiceBridge")
                 .font(.largeTitle.bold())
            Text("Local speech-to-text & text-to-speech")
                 .font(.subheadline)
                 .foregroundStyle(.secondary)

            // - - - TTS card - - -
            VStack(alignment: .leading, spacing: 10) {
                 HStack {
                     Label("Text to Speech", systemImage: "speaker.wave.2.fill")
                          .font(.headline)
                     Spacer()
                     Button(action: { openSettingsAction() }) {
                         Label("Settings...", systemImage: "gearshape")
                          }
                          .buttonStyle(.borderless)
                          .help("Open the TTS config page.")
                 }

             // Scrollable text input - supports arbitrarily long input.
                TextEditor(text: $text)
                      .font(.body)
                      .frame(minHeight: 140)
                      .border(.quaternary)
                      .accessibilityLabel("Text to speak")

                 HStack(spacing: 10) {
                     Button {
                          speak()
                         } label: {
                         Label("Speak", systemImage: "play.fill")
                          }
                          .buttonStyle(.borderedProminent)
                          .disabled(speaking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                     Button {
                          stop()
                         } label: {
                         Label("Stop", systemImage: "stop.fill")
                          }
                          .buttonStyle(.bordered)
                          .disabled(!Playback.isPlaying && !speaking).help("Stop current TTS playback.")

                  // Save button enabled only when we have a real audio file on
                  // disk (Piper / Kokoro - not the AVSpeech in-place engine).
                    Button {
                        saveWav()
                       } label: {
                       Label("Save Speech (.wav)", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(lastWav == nil)
                        .help("Save the last TTS output to a .wav file you choose.")

                     Spacer()
                    Text(voiceCaption)
                         .font(.footnote)
                         .foregroundStyle(.secondary)
                      .lineLimit(2)
                 }

                  // TTS status + save target.
                 Text(ttsStatus)
                      .font(.footnote)
                      .foregroundStyle(.secondary)
                      .textSelection(.enabled)
            }
             .padding()
             .background(.quaternary.opacity(0.15))
             .cornerRadius(12)

             // - - - STT card - - -
            VStack(alignment: .leading, spacing: 10) {
                 HStack {
                     Label("Speech to Text", systemImage: "mic.fill")
                          .font(.headline)
                     Spacer()
                     Text(sttModel?.label ?? "no model")
                          .font(.footnote)
                          .foregroundStyle(.secondary)
                 }

                  // Mode buttons: push-to-talk and live.
                 HStack(spacing: 10) {

                      // Push-to-talk.
                     Button {
                          togglePushToTalk()
                         } label: {
                         Label(pushToTalkTitle, systemImage: pushToTalkIcon)
                          }
                          .buttonStyle(.borderedProminent)
                          .disabled(stream.isRunning || pushToTalkDisabled)
                          .help("Record a short clip and transcribe on demand.")

                      // Live / streaming.
                     Button {
                          toggleLive()
                         } label: {
                         Label(stream.isRunning ? "Stop Live" : "Live (streaming)",
                               systemImage: stream.isRunning ? "stop.circle" : "dot.radiowaves.left.and.right")
                          }
                          .buttonStyle(.borderedProminent)
                          .disabled(stream.isRunning && stream.phase == .stopping)
                          .help("Continuous live captions via whisper (whisper-cli).")

                  }

                  // Status: live mode or push-to-talk mode.
                 Text(displaySttStatus)
                      .font(.footnote)
                      .foregroundStyle(.secondary)

                  // Scrollable transcript (live or last push-to-talk result).
                ScrollView {
                 Text(displayTranscript.isEmpty ? "Transcript appears here..."
                                                : displayTranscript)
                       .font(.body)
                       .frame(maxWidth: .infinity, alignment: .leading)
                       .textSelection(.enabled)
                }
                .frame(minHeight: 100, maxHeight: 200)
                .border(.quaternary)
                .accessibilityLabel("Transcript")

                  // Save row.
                 HStack(spacing: 10) {
                    Button {
                        saveTranscript()
                       } label: {
                       Label("Save Transcript (.txt)", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(displayTranscript.isEmpty)

                    Spacer()

                 // Small legend: which whisper model, live/push-to-talk status,
                 // etc.
                    Text(legend)
                         .font(.caption2)
                         .foregroundStyle(.secondary)
                 }
            }
             .padding()
             .background(.quaternary.opacity(0.15))
             .cornerRadius(12)

         }
         }
          .padding()
          .frame(minWidth: 560, minHeight: 700)
          .onAppear {
            ttsConfig.scan()
            Playback.assumesRunningLoop = true
            sttModel = ContentView.availableSttModel()
            if sttModel == nil {
                sttStatus = "No whisper model on disk - run scripts/fetch-whisper-turbo.sh."
             } else {
                sttStatus = "Ready."
             }
         }
    }

     // ---------- View models ----------

     /// Short caption for the TTS card.
    private var voiceCaption: String {
        var s = ttsConfig.selectedMode.rawValue
        if let v = ttsConfig.selectedModelFile { s += "    voice: \(v)" }
        return s
    }

     /// The active transcript to display: live when streaming, otherwise the
     /// last push-to-talk result.
    private var displayTranscript: String {
        if stream.isRunning { return stream.transcript }
        return lastPushToTalkTranscript
    }

    @State private var lastPushToTalkTranscript = ""

     /// "Ready" / "Transcribing…" / "Live" / "Microphone denied…", etc.
    private var displaySttStatus: String {
        if stream.isRunning { return stream.status }
        return sttStatus
    }

     /// A short model / status legend under the transcript.
    private var legend: String {
        guard let m = sttModel else { return "(no model)" }
        let live = stream.isRunning ? " · LIVE" : ""
        return "\(m.label) / \(m.ggmlFilename)\(live)"
    }

     /// Disable the push-to-talk button when live or busy already.
    private var pushToTalkDisabled: Bool {
        stream.isRunning || sttPhase == .requestingMic || sttPhase == .transcribing
    }

    private var pushToTalkTitle: String {
        switch sttPhase {
        case .idle, .requestingMic: return "Start Listening"
        case .recording:            return "Stop & Transcribe"
        case .transcribing:         return "Transcribing..."
        }
    }

    private var pushToTalkIcon: String {
        switch sttPhase {
        case .recording:    return "stop.circle"
        case .transcribing: return "hourglass"
        case .idle:         return "mic.circle"
        case .requestingMic:return "mic"
        }
    }

    // ---------- TTS actions ----------

     /// Speak the text. Cancels any in-flight task first, stops all audio.
    @MainActor
     private func speak() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        currentTask?.cancel()
        Playback.stopAll()
        speaking = true
        ttsStatus = "Speaking via \(ttsConfig.selectedMode.rawValue)…"

        let mode = ttsConfig.selectedMode
        let voice = ttsConfig.selectedModelFile
        currentTask = Task {
            do {
                 let result = try await TTSManager(config: ttsConfig)
                                   .speak(text, mode: mode, voice: voice, play: true)
                if !Task.isCancelled {
                  var s = "Playing \(result.url.lastPathComponent) - \(result.engineName)"
                  if result.fellBack { s += "   (\(result.statusLine))" }
                  ttsStatus = s
                  lastWav = result.url
                  }
            } catch {
                if !Task.isCancelled {
                    ttsStatus = "Error: \(error.localizedDescription)"}
            }
          if !Task.isCancelled {
              speaking = false
              if currentTask == nil { ttsStatus = "Done." }
          }
      }
  }

     /// Stop all TTS.
    @MainActor
     private func stop() {
        currentTask?.cancel()
        currentTask = nil
        Playback.stopAll()
        speaking = false
        ttsStatus = "Stopped."
     }

     /// Save the last TTS output to a user-chosen .wav file.
     @MainActor
     private func saveWav() {
        guard let url = lastWav,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
          NSSound.beep()
          ttsStatus = "No .wav to save yet."
          return
     }
     let defaultName = "voicebridge-\(Date().timeIntervalSince1970).wav"
     if let chosen = SaveDialog.save(data, defaultName: defaultName) {
         ttsStatus = "Saved WAV to \(chosen.lastPathComponent)."
         } else {
         ttsStatus = "Save cancelled."
         }
     }

     /// Whether the lastWav URL still points to a file on disk.
    private func lastWavExists() -> Bool {
        guard let url = lastWav else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

     // ---------- STT actions ----------

     /// Toggle the push-to-talk flow.
     @MainActor
     private func togglePushToTalk() {
        switch sttPhase {
        case .recording:     stopAndTranscribe()
        case .idle:          startListening()
        case .requestingMic, .transcribing:
            // Busy - do nothing.
            break
        }
     }

     @MainActor
     private func startListening() {
        guard let model = sttModel else {
            sttStatus = "No whisper model on disk."
            return
        }
        sttPhase = .requestingMic
        sttStatus = "Requesting microphone access…"
        Task {
            let granted: Bool = await withCheckedContinuation { cont in
                var resumed = false
                MicrophoneCapture.requestInputPermission { g in
                    if !resumed { resumed = true; cont.resume(returning: g) }
                }
            }
            guard granted else {
                sttPhase = .idle
                sttStatus = "Microphone denied - enable in System Settings > Privacy & Security > Microphone."
                return
            }
            startCapture(voice: model)
        }
     }

     @MainActor
     private func startCapture(voice: SttModel) {
        let dir = ModelPaths.cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mic-\(UUID().uuidString).wav")
        do {
            let cap = try MicrophoneCapture(outputURL: url)
            try cap.start()
            mic = cap
            sttPhase = .recording
            sttStatus = "Recording with \(voice.label). Click \"Stop & Transcribe\"."
        } catch {
            mic = nil
            sttPhase = .idle
            sttStatus = "Could not start the mic: \(error.localizedDescription)"
        }
     }

     @MainActor
     private func stopAndTranscribe() {
        // Capture the written WAV URL *from the binding* before we nil it out.
        // (This was the "No audio to transcribe" bug: reading `mic?.writtenURL`
        //  after setting `mic = nil` always fell back to a non-existent path.)
        var audioURL = ModelPaths.cacheDir.appendingPathComponent("last-mic.wav")
        if let cap = mic {
            audioURL = cap.writtenURL   // mic's outputPath, flushed in stop()
            cap.stop()
            mic = nil
        }
        sttPhase = .transcribing
        sttStatus = "Transcribing…"

        let model = sttModel ?? ContentView.availableSttModel()
        Task {
            do {
                 // AVAudioRecorder may need a beat to flush its final frames.
                try? await Task.sleep(for: .milliseconds(300))
                guard let model,
                      FileManager.default.fileExists(atPath: audioURL.path) else {
                    sttPhase = .idle
                    sttStatus = "No audio on disk - check mic & permission."
                    return
                }
                let t = try await WhisperCliBackend()
                               .transcribe(audio: audioURL,
                                          language: nil,
                                          model: model,
                                          useTimestamps: false)
                lastPushToTalkTranscript = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                sttPhase = .idle
                sttStatus = "Recognized · \(t.model.label) · "
                      + String(format: "%.1fs", t.durationSeconds)
                      + " · \(t.language)"
            } catch {
                sttPhase = .idle
                sttStatus = "Transcribe failed: \(error.localizedDescription)"
            }
        }
     }

     /// Toggle live streaming STT (start if idle, stop if live).
     @MainActor
     private func toggleLive() {
        switch stream.phase {
        case .idle:
            if sttModel == nil {
                sttStatus = "No whisper model on disk - run scripts/fetch-whisper-turbo.sh."
                return
            }
            lastPushToTalkTranscript = ""   // clear the view; live will drive displayTranscript
            Task { await stream.start() }
        case .live:
            Task { await stream.stop() }
            sttStatus = "Stopping live…"
        case .stopping:
            // already stopping - ignore.
            break
        }
     }

     /// Save the current transcript to a user-chosen .txt file.
     @MainActor
     private func saveTranscript() {
        let text = displayTranscript
        let name = "voicebridge-transcript-\(Date().timeIntervalSince1970).txt"
        if let url = SaveDialog.saveText(text, defaultName: name) {
            sttStatus = "Saved transcript to \(url.lastPathComponent)."
        } else {
            sttStatus = "Save cancelled or failed."
        }
     }

     // ---------- Helpers ----------

     /// First whisper model physically present on disk (preferred order).
    static func availableSttModel() -> SttModel? {
        for m in SttModel.allCases {
            let url = ModelPaths.whisperDir.appendingPathComponent(m.ggmlFilename)
            if FileManager.default.fileExists(atPath: url.path) { return m }
        }
        return nil
     }
}
