import SwiftUI

/// Four-bar music spectrum (boring.notch AudioSpectrum), pure SwiftUI.
struct MusicSpectrumBars: View {
    var isPlaying: Bool
    var tint: Color = Color(red: 0.35, green: 0.78, blue: 0.98)
    var barCount: Int = 4
    var barWidth: CGFloat = 2.2
    var spacing: CGFloat = 2
    var height: CGFloat = 14

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 0.28, paused: !isPlaying)
        ) { context in
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(barStyle(for: index))
                        .frame(
                            width: barWidth,
                            height: max(3, height * scale(for: index, at: context.date))
                        )
                        .frame(height: height, alignment: .center)
                }
            }
        }
        .frame(
            width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing,
            height: height
        )
        .accessibilityHidden(true)
    }

    private func barStyle(for index: Int) -> AnyShapeStyle {
        let opacity = isPlaying ? (0.88 + 0.06 * Double(index % 3)) : 0.42
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    tint.opacity(min(1, opacity + 0.08)),
                    tint.opacity(opacity * 0.78),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        )
    }

    private func scale(for index: Int, at date: Date) -> CGFloat {
        guard isPlaying else { return 0.35 }
        let t = date.timeIntervalSinceReferenceDate
        let phase = Double(index) * 1.7 + t * (2.4 + Double(index) * 0.35)
        let wave = (sin(phase) + 1) / 2
        return 0.35 + 0.65 * CGFloat(wave)
    }
}
