import AVFoundation

/// whisper.cpp requires **16 kHz, mono, 16-bit little-endian PCM WAV**.
///
/// This is the canonical target format for both live mic capture and file
/// transcode. Live mic capture MUST be normalized to this shape (the mic
/// delivers 48 kHz stereo by default); for *file* input you may feed whisper
/// many formats directly, but normalizing first keeps behavior predictable.
public enum AudioFormats {

       /// 16 kHz / mono / 16-bit linear PCM. Used both as the mic capture
       /// settings and the transcode target.
    public static var target: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
           ]
      }

       /// Convenience `AVAudioFormat` object for converters.
    ///
    /// Failable in Apple's API (`init?(standardFormatWithSampleRate:channels:)`),
    /// so it is surfaced as an optional rather than force-unwrapped — a Core
    /// force-unwrap is a crash waiting for a bad host configuration. The 16-bit
    /// PCM *shape* itself is described by `target` (the settings dictionary).
    public static var targetFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
         }
}
