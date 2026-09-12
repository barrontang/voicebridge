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
    public static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                     sampleRate: 16_000, channels: 1, interleaved: true)!
         }
}
