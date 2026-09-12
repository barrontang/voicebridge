// VoiceBridgeApp.swift — the `@StateObject` + injection shape.
//
// This is reference SwiftUI source, NOT part of the Swift package. The core
// (VoiceBridgeCore) is framework-agnostic; the GUI simply imports it and owns
// the observable config manager here, then injects it down via @ObservedObject.
//
// To build the GUI target:
//   1. Open the project in Xcode and add a macOS App target.
//   2. Copy these three files (VoiceBridgeApp, ContentView, SettingsView) in.
//   3. Add VoiceBridgeCore as an SPM package dependency.
//   4. Set the target's Minimum = macOS 14.

import SwiftUI
import VoiceBridgeCore

@main
struct VoiceBridgeApp: App {
    // The bug the PRD had: declaring the manager *inside* a view recreated it on
    // every render. The fix is to own it once here as @StateObject and pass it
    // down as @ObservedObject so published state survives re-renders.
    @StateObject private var ttsConfig = TTSConfigManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ttsConfig)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openSettings() }
            }
        }
    }

    @MainActor private func openSettings() {
        // On macOS 14+ use Settings scene; kept as a helper for the older
        // NSApp.sendAction pattern used in the original scaffold.
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
