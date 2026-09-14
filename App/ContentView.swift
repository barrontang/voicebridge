// ContentView.swift — minimal two-function main page:
//   1) Text to Speech    (TTS): type text, "Speak" plays via the selected engine
//      (chosen on the ⚙ Settings page). Starting a new utterance stops whatever
//      is already playing, then starts the new one.
//   2) Speech to Text    (Voice to Text): push-to-talk — "Start Listening"
//      records the microphone and "Stop & Transcribe" runs whisper.cpp → text,
//      using the first whisper model present on disk.
//
// TTS model/voice selection lives on the Settings page (SettingsView), opened
// from the "⚙ Settings…" button via the macOS 14 `openSettings` action.

import SwiftUI
import VoiceBridgeCore

/// Lifecycle of the Speech-to-Text push-to-talk flow. The button's enabled /
/// label state reads directly from this, so "Stop & Transcribe" is always
/// reachable while recording (this is what fixes "can't stop").
enum SttPhase {
   case idle           // not recording, not busy
   case requestingMic  // awaiting the macOS mic-permission prompt
   case recording      // microphone live; the button now stops & transcribes
   case transcribing   // mic stopped; whisper runs (button busy/disabled)
}

struct ContentView: View {
   @EnvironmentObject var ttsConfig: TTSConfigManager

   /// macOS 14+ control that reliably opens the `Settings` scene on the parent
   /// App. (The legacy `showSettingsWindow:` selector is broken here.)
   @Environment(\.openSettings) private var openSettingsAction

   // ── Text to Speech ─────────────────────────────────────
   @State private var text = "Hello. This is VoiceBridge, running fully on device."
   @State private var ttsStatus = "Ready."
   @State private var speaking = false
   @State private var currentTask: Task<Void, Never>?

   // ── Speech to Text ─────────────────────────────────────
   @State private var mic: MicrophoneCapture?
   @State private var sttPhase: SttPhase = .idle
   @State private var transcript = ""
   @State private var sttStatus = "Ready."
   @State private var sttModel: SttModel?

   var body: some View {
        VStack(spacing: 24) {
            Text("VoiceBridge")
                 .font(.largeTitle.bold())
            Text("Local speech-to-text & text-to-speech")
                 .font(.subheadline)
                 .foregroundStyle(.secondary)

            // ── 1) Text to Speech ─────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                 HStack {
                     Label("Text to Speech", systemImage: "speaker.wave.2.fill")
                          .font(.headline)
                     Spacer()
                     // Open the config page to pick the TTS engine/voice/model.
                     Button {
                          openSettingsAction()
                       } label: { Label("Settings…", systemImage: "gearshape") }
                       .buttonStyle(.borderless)
                       .help("Open the TTS config page (engine, voice, model).")
                 }

                 TextEditor(text: $text)
                      .frame(minHeight: 90)
                      .border(.quaternary)

                 HStack(spacing: 12) {
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
                       .disabled(!speaking && !Playback.isPlaying)

                     Spacer()
                     // Which engine/voice will be used (change it on Settings).
                     Text(voiceCaption)
                          .foregroundStyle(.secondary)
                          .font(.footnote)
                 }

                 Text(ttsStatus)
                      .font(.footnote)
                      .foregroundStyle(.secondary)
            }
            .padding()
            .background(.quaternary.opacity(0.15))
            .cornerRadius(12)

            // ── 2) Speech to Text ─────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                 HStack {
                     Label("Speech to Text", systemImage: "mic.fill")
                          .font(.headline)
                     Spacer()
                     Text(sttModel?.label ?? "no model")
                          .font(.footnote)
                          .foregroundStyle(.secondary)
                 }

                 HStack(spacing: 12) {
                     Button {
                          toggleListen()
                       } label: {
                          Label(sttButtonTitle, systemImage: sttButtonIcon)
                       }
                       .buttonStyle(.borderedProminent)
                       // Only the .recording and .idle phases enable this button.
                       // Crucially, while recording the button is the STOP action,
                       // so it MUST stay enabled.
                       .disabled(sttPhase == .requestingMic || sttPhase == .transcribing)

                     Text(phaseIndicator)
                          .foregroundStyle(phaseColor)
                          .font(.footnote)
                 }

                 // Transcript result.
                 Text(transcript.isEmpty ? "Transcript will appear here." : transcript)
                      .font(.body)
                      .frame(minHeight: 34, alignment: .leading)
                      .padding(8)
                      .background(.quaternary.opacity(0.15))
                      .cornerRadius(8)

                 Text(sttStatus)
                      .font(.footnote)
                      .foregroundStyle(.secondary)
            }
            .padding()
            .background(.quaternary.opacity(0.15))
            .cornerRadius(12)

            Spacer()
        }
        .padding()
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            ttsConfig.scan()
            Playback.assumesRunningLoop = true
            sttModel = ContentView.availableSttModel()
            if sttModel == nil {
                sttStatus = "No whisper model found — run scripts/fetch-whisper-turbo.sh."
            } else {
                sttStatus = "Ready · \(sttModel!.label)"
            }
        }
   }

   // ────────────────── TTS helpers ──────────────────
   /// Short caption of which engine/voice will be used (full pick on Settings).
   private var voiceCaption: String {
        var s = ttsConfig.selectedMode.rawValue
        if let v = ttsConfig.selectedModelFile { s += "     ·     voice: \(v)" }
        return s
   }

   /// Start a new utterance: cancel any in-flight task AND stop the old audio
   /// first, so selecting a new voice + speaking replaces what's playing.
   @MainActor private func speak() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        currentTask?.cancel()
        Playback.stopAll()                    // stop the previous utterance
        speaking = true
        ttsStatus = "Speaking via \(ttsConfig.selectedMode.rawValue)…"

        // Capture the selection at click time so a later Settings change
        // doesn't leak into this utterance.
        let mode = ttsConfig.selectedMode
        let voice = ttsConfig.selectedModelFile

        currentTask = Task {
            do {
                let result = try await TTSManager(config: ttsConfig)
                              .speak(text, mode: mode, voice: voice, play: true)
                if !Task.isCancelled {
                    var s = "Playing \(result.url.lastPathComponent) — \(result.engineName)"
                    if result.fellBack { s += "  (\(result.statusLine))" }
                    ttsStatus = s
                }
            } catch {
                if !Task.isCancelled {
                    ttsStatus = "❌ \(error.localizedDescription)"
                }
            }
            if !Task.isCancelled {
                speaking = false
                if currentTask == nil { ttsStatus = "Done." }
            }
        }
   }

   /// Halt any in-flight utterance (task + audio).
   @MainActor private func stop() {
        currentTask?.cancel()
        currentTask = nil
        Playback.stopAll()
        speaking = false
        ttsStatus = "Stopped."
   }

   // ──────────────────── STT helpers ────────────────────
   /// One action: start recording when idle, stop + transcribe when recording.
   @MainActor private func toggleListen() {
        switch sttPhase {
        case .recording:            stopAndTranscribe()
        case .idle:                 startListening()
        case .requestingMic, .transcribing:
            break                    // busy — wait for completion
        }
   }

   @MainActor private func startListening() {
        guard let model = sttModel else {
            sttStatus = "❌ No whisper model on disk — run scripts/fetch-whisper-turbo.sh."
            return
        }
        sttPhase = .requestingMic
        sttStatus = "Requesting microphone access…"
        MicrophoneCapture.requestInputPermission { granted in
            guard granted else {
                sttPhase = .idle
                sttStatus = "❌ Microphone denied. Enable it in System Settings › Privacy & Security › Microphone, then retry."
                return
            }
            startCapture(voice: model)
        }
   }

   @MainActor private func startCapture(voice: SttModel) {
        let dir = ModelPaths.cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mic-\(UUID().uuidString).wav")
        do {
            let cap = try MicrophoneCapture(outputURL: url)
            try cap.start()
            mic = cap
            sttPhase = .recording
            sttStatus = "● Recording with \(voice.label). Click “Stop & Transcribe”."
        } catch {
            mic = nil
            sttPhase = .idle
            sttStatus = "❌ Could not start the microphone: \(error.localizedDescription)"
        }
   }

   @MainActor private func stopAndTranscribe() {
        // Always tear the recorder down first (fixes "can't stop"). Capture the
        // written WAV URL *from the binding* while `cap` still holds a reference,
        // before we nil out `mic` — that was the "no audio to transcribe" bug.
        var audioURL = ModelPaths.cacheDir
                         .appendingPathComponent("last-mic.wav")
        if let cap = mic {
            audioURL = cap.writtenURL        // mic's outputPath (flushed in stop())
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
                guard let model, FileManager.default.fileExists(atPath: audioURL.path) else {
                    sttPhase = .idle
                    sttStatus = "❌ No audio on disk (mic produced nothing). Check mic + permission."
                    return
                }
                let t = try await WhisperCliBackend()
                              .transcribe(audio: audioURL,
                                          language: nil,
                                          model: model,
                                          useTimestamps: false)
                transcript = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                sttPhase = .idle
                sttStatus = "Recognized · \(t.model.label) · "
                     + String(format: "%.1f", t.durationSeconds) + "s · "
                     + String(format: "%.2f", t.realtimeFactor) + "× realtime · "
                     + t.language
            } catch {
                sttPhase = .idle
                sttStatus = "❌ Transcribe failed: \(error.localizedDescription)"
            }
        }
   }

   /// First whisper model physically present on disk (preferred order).
   static func availableSttModel() -> SttModel? {
        for m in SttModel.allCases {
            let url = ModelPaths.whisperDir.appendingPathComponent(m.ggmlFilename)
            if FileManager.default.fileExists(atPath: url.path) { return m }
        }
        return nil
   }

   // ────────────── view-models derived from sttPhase ──────────────
   private var sttButtonTitle: String {
        switch sttPhase {
        case .idle, .requestingMic:  return "Start Listening"
        case .recording:             return "Stop & Transcribe"
        case .transcribing:          return "Transcribing…"
        }
   }

   private var sttButtonIcon: String {
        switch sttPhase {
        case .recording:            return "stop.circle"
        case .transcribing:         return "hourglass"
        case .idle:                 return "mic.circle"
        case .requestingMic:        return "mic"
        }
   }

   private var phaseIndicator: String {
        switch sttPhase {
        case .idle:          return ""
        case .requestingMic: return "Waiting for permission…"
        case .recording:     return "● Recording…"
        case .transcribing:  return "…transcribing"
        }
   }

   private var phaseColor: Color {
        switch sttPhase {
        case .recording: return .green
        default:         return .secondary
        }
   }
}
