import Foundation
import AVFoundation

/// Audio playback. `playWAV` plays a file and keeps the run loop alive so it
/// works both in a long-lived GUI app and a short-lived CLI. `spinMainRunLoop`
/// keeps the loop alive for an in-place (AVSpeech) engine. Both guard against
/// missing files, so a no-output engine can't crash the pipeline.
///
/// GUI note: when the main run loop is *already running* (a SwiftUI app),
/// re-entering it with `run(until:)` freezes the UI. The app sets
/// `assumesRunningLoop = true` at launch; in that mode we start the player and
/// let the app's own loop drive the audio instead of spinning.
///
/// Stop semantics: `stopAll()` halts whatever is currently sounding (a retained
/// `AVAudioPlayer` or an in-place `AVSpeechSynthesizer`). Any new playback
/// call stops the previous one first, so "select a new voice → speak" replaces
/// the in-flight utterance instead of stacking on top of it.
public enum Playback {

       /// Set `true` by the GUI at launch. When set, playback never re-enters
        /// the already-running main run loop.
      @MainActor public static var assumesRunningLoop = false

        /// The file-based player currently sounding (retained so it survives the
        /// running-loop hand-off).
      @MainActor private static var current: AVAudioPlayer?

        /// The in-place AVSpeech synthesizer currently sounding (the built-in
         /// engine speaks straight to the device; it can't render a file).
      @MainActor private static var currentSynth: AVSpeechSynthesizer?

          /// Whether anything is currently producing sound.
        @MainActor public static var isPlaying: Bool {
             (current?.isPlaying ?? false) || (currentSynth?.isSpeaking ?? false)
           }

          /// Stop whatever is currently sounding. Safe to call when nothing is
           /// playing.
         @MainActor public static func stopAll() {
             current?.stop()
             current?.prepareToPlay() // reset for the next utterance
             currentSynth?.stopSpeaking(at: .immediate)
         }

           /// Plays `url`. A missing/unopenable file is a no-op (not a crash).
            /// Any playback already in progress is stopped first.
        @MainActor
    public static func playWAV(_ url: URL) throws {
        stopAll() // replace anything already sounding

        guard FileManager.default.fileExists(atPath: url.path) else {
            VBLog.capture.warning("file not found: \(url.path)")
            return
               }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            VBLog.capture.warning("could not open \(url.path)")
            return
               }
        player.volume = 1.0
        player.prepareToPlay()
        current = player
        player.play()

            // GUI: the main loop is already running — hand the player to it and
            // keep it alive (it lives in `current`), but do NOT re-enter the
            // loop (that freezes the UI).
        if assumesRunningLoop {
             VBLog.capture.info("queued \(url.lastPathComponent) on running loop")
              return
                 }

             // CLI: no running loop — spin it so playback finishes before exit.
        VBLog.capture.info("playing \(url.lastPathComponent)")
        while player.isPlaying {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        current = nil
             }

            /// Spins the main run loop for `seconds` so an in-place AVSpeech
             /// utterance has time to deliver before a CLI process would otherwise
             /// exit. In a GUI app the loop is already running, so this is a no-op.
         @MainActor
    public static func spinMainRunLoop(for seconds: Double) {
            // GUI: the loop is already running — nothing more to do.
           guard !assumesRunningLoop else { return }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
                RunLoop.current.run(until: end)
           }
           }

           /// Registers an in-place AVSpeech synthesizer as the current sound
            /// source so `stopAll()` can halt it.
         @MainActor
    public static func registerSynthesizer(_ synth: AVSpeechSynthesizer) {
             currentSynth = synth
        }
}
