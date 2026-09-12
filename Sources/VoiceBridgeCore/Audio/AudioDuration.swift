import Foundation
import AVFoundation

/// Best-effort audio duration, measured from the source file rather than
/// trusting a model's (often window-sized, e.g. 30 s) offset field.
public enum AudioDuration {

        /// Returns the audio length in seconds, or 0 when it can't be read
      /// (unsupported container, missing file).
    public static func estimateSeconds(at url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            return 0
          }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
         }
}
