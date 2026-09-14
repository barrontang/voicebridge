// VoiceBridgeApp.swift — the `@StateObject` + injection shape.
//
// Two scenes:
//      * WindowGroup    : the minimal main page (TTS + Voice-to-Text) — ContentView.
//      * Settings       : the config page — SettingsView — to pick the TTS model.
//
// The observable config manager is owned exactly once here as `@StateObject`
// and shared with both scenes, so a selection made on the Settings page
// survives and is seen by the main page (the original PRD bug was recreating
// the manager inside a view, losing the selection on every re-render).
//
// Note: we do NOT override `.appSettings`. Declaring a `Settings` scene gives
// macOS a working "Settings…" menu item automatically; the main page's "⚙
// Settings…" button opens it via the `openSettings` environment action.
//
// This app target is built from ./App sources (not the SPM core) — see
// scripts/make-app.sh. Core = VoiceBridgeCore added as an SPM dependency.

import SwiftUI
import VoiceBridgeCore

@main
struct VoiceBridgeApp: App {
    @StateObject private var ttsConfig = TTSConfigManager()

    var body: some Scene {
        // ── Main page: TTS + Voice-to-Text. ──
        WindowGroup {
            ContentView()
                 .environmentObject(ttsConfig)
             }

              // ── Config page: pick the TTS engine + voice + model root.
              // Opens automatically as the "Settings…" (⌘,) menu item and from
              // the main page's "⚙ Settings…" button.
        Settings {
            SettingsView(ttsConfig: ttsConfig)
              }
       }
}
