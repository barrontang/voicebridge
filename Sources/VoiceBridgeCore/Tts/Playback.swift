import Foundation
import AVFoundation

/// Audio playback. `playWAV` plays a file and keeps the run loop alive so it
/// works both in a long-lived GUI app and a short-lived CLI. `spinMainRunLoop`
/// keeps the loop alive for an in-place (AVSpeech) engine. Both guard against
/// missing files, so a no-output engine can't crash the pipeline.
public enum Playback {

        /// Plays `url`. A missing/unopenable file is a no-op (not a crash).
     @MainActor
    public static func playWAV(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[Playback] file not found: \(url.path)")
            return
            }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            print("[Playback] could not open \(url.path)")
            return
            }
        player.volume = 1.0
        player.prepareToPlay()
        player.play()
             // Spin the main run loop so playback completes even in the CLI.
        let runLoop = RunLoop.current
        while player.isPlaying {
            runLoop.run(until: Date().addingTimeInterval(0.05))
            }
            }

         /// Spins the main run loop for `seconds` so an in-place AVSpeech
          /// utterance has time to deliver before a CLI process would otherwise
          /// exit. In a GUI app the run loop is already running, so this is a
          /// short no-op.
     @MainActor
    public static func spinMainRunLoop(for seconds: Double) {
        let runLoop = RunLoop.current
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            runLoop.run(until: end)
            }
            }
}
