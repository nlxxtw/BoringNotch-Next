import SwiftUI

private struct LyricTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Karaoke line: sung text bright, unsung dim.
/// Short lines stay centered; long lines scroll (“拉过来”) so the singing edge stays visible.
struct WalkingLyricLine: View {
    let text: String
    let progress: Double
    var isLoading: Bool = false
    var fontSize: CGFloat = 13
    /// Sung / primary lyric color (notch defaults to white).
    var sungColor: Color = .white
    /// Unsung / dim lyric color.
    var unsungColor: Color = .white.opacity(0.36)
    /// When true, short lines shrink to text width (capped) so trailing peers sit closer.
    var hugContentWidth: Bool = false
    /// Cap used with `hugContentWidth` (and as the scroll viewport for long lines).
    var maxContentWidth: CGFloat = 180

    @State private var textWidth: CGFloat = 0

    var body: some View {
        let clamped = min(1, max(0, progress))
        let dim = isLoading ? sungColor.opacity(0.45) : unsungColor
        let viewportWidth: CGFloat = {
            guard hugContentWidth else { return 0 }
            if textWidth > 1 {
                return min(maxContentWidth, textWidth)
            }
            return maxContentWidth
        }()

        Group {
            if hugContentWidth {
                lyricCanvas(
                    width: viewportWidth,
                    clamped: clamped,
                    dim: dim,
                    centerWhenFits: false
                )
                .frame(width: viewportWidth, height: fontSize + 6, alignment: .leading)
            } else {
                GeometryReader { geo in
                    lyricCanvas(
                        width: geo.size.width,
                        clamped: clamped,
                        dim: dim,
                        centerWhenFits: true
                    )
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                }
                .frame(minHeight: fontSize + 6)
            }
        }
        .onPreferenceChange(LyricTextWidthKey.self) { textWidth = $0 }
        .accessibilityLabel(displayText)
    }

    @ViewBuilder
    private func lyricCanvas(
        width: CGFloat,
        clamped: Double,
        dim: Color,
        centerWhenFits: Bool
    ) -> some View {
        let fits = textWidth > 1 && textWidth <= width - 2
        let line = ZStack(alignment: .leading) {
            Text(displayText)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(dim)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { textGeo in
                        Color.clear.preference(
                            key: LyricTextWidthKey.self,
                            value: textGeo.size.width
                        )
                    }
                }

            Text(displayText)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(sungColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .mask(alignment: .leading) {
                    GeometryReader { maskGeo in
                        Rectangle()
                            .frame(width: max(0, maskGeo.size.width * clamped))
                    }
                }
        }
        .fixedSize(horizontal: true, vertical: false)

        Group {
            if fits {
                if centerWhenFits {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        line
                        Spacer(minLength: 0)
                    }
                } else {
                    line
                        .frame(width: width, alignment: .leading)
                }
            } else {
                let overflow = max(0, textWidth - width)
                let frontier = textWidth * clamped
                let focusX = width * 0.72
                let offsetX = min(0, max(-overflow, focusX - frontier))
                line
                    .offset(x: offsetX)
                    .frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
        .animation(.linear(duration: 0.12), value: clamped)
    }

    private var displayText: String {
        text.isEmpty ? " " : text
    }
}
