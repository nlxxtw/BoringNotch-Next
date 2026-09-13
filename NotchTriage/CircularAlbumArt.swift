import AppKit
import SwiftUI

/// Circular album art for the lyrics chin (boring.notch-style cover).
struct CircularAlbumArt: View {
    enum Chrome {
        case notch
        case menuBar
    }

    let snapshot: MediaSnapshot
    var size: CGFloat = 32
    var chrome: Chrome = .notch

    var body: some View {
        Group {
            if let image = artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(placeholderFill)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(placeholderSymbol)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var placeholderFill: Color {
        switch chrome {
        case .notch: return .white.opacity(0.12)
        case .menuBar: return Color.primary.opacity(0.10)
        }
    }

    private var placeholderSymbol: Color {
        switch chrome {
        case .notch: return .white.opacity(0.85)
        case .menuBar: return Color.primary.opacity(0.75)
        }
    }

    private var borderColor: Color {
        switch chrome {
        case .notch: return .white.opacity(0.28)
        case .menuBar: return Color.primary.opacity(0.22)
        }
    }

    private var artworkImage: NSImage? {
        AlbumArtPalette.image(for: snapshot)
    }
}
