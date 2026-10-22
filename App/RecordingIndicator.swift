// RecordingIndicator.swift — the "we are listening" animation.
//
// A push-to-talk recording is otherwise silent: the user sees a button that
// says "Stop & Transcribe" and has to trust that the microphone is open.
// This view animates with the *actual* input level, so the app visibly reacts
// to the voice - and a flat line means "we hear nothing".

import SwiftUI

/// A pulsing microphone dot plus a live level meter.
struct RecordingIndicator: View {
    /// The current input level (0…1).
    let level: Double
    /// The label next to the animation.
    var label: String = "Listening…"

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                // A ring that breathes while recording.
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 26, height: 26)
                    .scaleEffect(pulse ? 1.35 : 0.85)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: pulse)
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.red)
                }
                .frame(width: 26, height: 26)

            LevelMeter(level: level)
                .frame(width: 74, height: 16)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
            }
        .onAppear { pulse = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A small bar meter: the bars scale with the input level.
struct LevelMeter: View {
    let level: Double

    private let bars = 7

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 4, height: height(for: index))
                    .animation(.easeOut(duration: 0.12), value: level)
                }
            Spacer(minLength: 0)
            }
    }

    /// The middle bar is the tallest; the outer ones scale with the level.
    private func height(for index: Int) -> CGFloat {
        let centre = Double(bars - 1) / 2
        let weight = 1.0 - abs(Double(index) - centre) / centre
        let minimum: CGFloat = 3
        let maximum: CGFloat = 16
        return minimum + (maximum - minimum) * CGFloat(weight * max(0.06, min(1, level)))
    }
}
