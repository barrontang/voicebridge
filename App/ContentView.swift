// ContentView.swift — reference main view. Uses TTSManager to speak text through
// the pluggable engine selector, with graceful fallback to the built-in voice.
//
// Reference source, not part of the Swift package. See VoiceBridgeApp.swift.

import SwiftUI
import VoiceBridgeCore

struct ContentView: View {
    @EnvironmentObject var ttsConfig: TTSConfigManager

    @State private var text = "Hello. This is VoiceBridge, running fully on device."
    @State private var transcript = ""
    @State private var status = "Ready."
    @State private var speaking = false

    var body: some View {
        VStack(spacing: 16) {
            Text("VoiceBridge — local STT + TTS").font(.title2.bold())

            TextEditor(text: $text)
                .frame(minHeight: 80)
                .border(.quaternary)

            HStack {
                Picker("Engine", selection: Binding(
                    get: { ttsConfig.selectedMode },
                    set: { ttsConfig.selectedMode = $0 })) {
                        ForEach(TTSMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                Button("Speak") { speak() }
                    .disabled(speaking || text.isEmpty)
            }

            Text("Transcript: \(transcript)").foregroundStyle(.secondary)
            Text(status).font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { ttsConfig.scan() }
    }

    @MainActor private func speak() {
        speaking = true
        status = "Speaking…"
        Task {
            do {
                let url = try await TTSManager(config: ttsConfig).speak(
                    text,
                    mode: ttsConfig.selectedMode,
                    voice: ttsConfig.selectedModelFile,
                    play: true)
                status = "Wrote \(url.lastPathComponent)"
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
            speaking = false
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TTSConfigManager())
}
