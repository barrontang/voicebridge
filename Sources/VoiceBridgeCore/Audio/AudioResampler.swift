import Foundation

/// Sample-rate conversion for the live path and the file path, in one place.
///
/// The mic delivers whatever the hardware prefers (48 kHz stereo is the norm)
/// and whisper.cpp wants 16 kHz / mono. Both the live capture and the file
/// transcoder have to make that jump, so the conversion lives here instead of
/// being written twice.
///
/// **Why linear interpolation + a pre-filter.** A windowed-sinc resampler
/// would be more accurate, but whisper.cpp re-samples internally anyway and
/// the project already shipped a linear path (the review flagged the
/// duplication, not the quality). The one improvement over the previous
/// hand-rolled version is a one-pole low-pass *before* the decimation: without
/// it, everything above 8 kHz folds back down and turns the speech into a
/// metallic mess. The filter is two lines of arithmetic and is unit-tested.
///
/// `AVAudioConverter` remains the "blessed" upgrade path - see
/// `docs/ARCHITECTURE.md`; the public shape here (`resample(from:to:)`) is the
/// seam it would slot into.
public enum AudioResampler {

    /// Convert `input` (at `from` Hz) to `to` Hz.
    ///
    /// - Parameters:
    ///   - input: mono samples in [-1, 1].
    ///   - from: the source sample rate.
    ///   - to: the destination sample rate.
    ///   - antiAlias: apply the pre-decimation low-pass (on by default; it is
    ///     a no-op when upsampling).
    public static func resample(_ input: [Float],
                                 from: Double,
                                 to: Double,
                                 antiAlias: Bool = true) -> [Float] {
        guard !input.isEmpty, from > 0, to > 0 else { return [] }
        if abs(from - to) < 1.0 { return input }

        let source = antiAlias && to < from ? lowPass(input, cutoff: to * 0.45, rate: from) : input
        return interpolate(source, from: from, to: to)
    }

    /// Linear interpolation between two samples.
    static func interpolate(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let ratio = to / from                            // target / source
        let outCount = max(1, Int((Double(samples.count - 1) * ratio).rounded()) + 1)
        var out = [Float](repeating: 0, count: outCount)

        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let lo = min(Int(srcPos), samples.count - 1)
            let hi = min(lo + 1, samples.count - 1)
            let t = Float(max(0, min(1, srcPos - Double(lo))))
            out[i] = samples[lo] + (samples[hi] - samples[lo]) * t
           }
        return out
    }

    /// Two-pole IIR low-pass (a cheap anti-aliasing pre-filter).
    ///
    /// `cutoff` is in Hz, `rate` the sample rate of the signal. Two cascaded
    /// one-pole sections give ~-12 dB/octave, which is enough to keep the
    /// 8-24 kHz band from folding back down when decimating 48 kHz to 16 kHz.
    static func lowPass(_ samples: [Float], cutoff: Double, rate: Double) -> [Float] {
        guard !samples.isEmpty, rate > 0, cutoff > 0, cutoff < rate / 2 else { return samples }
        let alpha = Float(exp(-2.0 * Double.pi * cutoff / rate))
        var out = [Float](repeating: 0, count: samples.count)
        var last1: Float = 0
        var last2: Float = 0
        for (i, x) in samples.enumerated() {
            last1 = (1 - alpha) * x + alpha * last1
            last2 = (1 - alpha) * last1 + alpha * last2
            out[i] = last2
           }
        return out
    }
}
