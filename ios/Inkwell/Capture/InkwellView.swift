import SwiftUI

/// The tappable inkwell. Reacts to real microphone input while recording -
/// the ink surface glows and ripples with `inputLevel` instead of an
/// artificial breathing animation.
struct InkwellView: View {
    var isRecording: Bool
    var inputLevel: Float // 0...1

    private var glowOpacity: Double {
        isRecording ? 0.35 + Double(inputLevel) * 0.5 : 0.12
    }

    // The resting size of the bottle art itself - large enough to hit
    // without looking closely at the screen, per the owner (roughly 60% of a
    // 393pt phone width). The tap target and glow scale from this, below.
    static let markSize: CGFloat = 230
    static let containerSize: CGFloat = markSize * 260 / 168

    // The neck opening's ellipse, measured directly from the owner's artwork
    // (design/inkwell.svg, 200x200 viewBox: the ink-face ellipse is at
    // cx100 cy40.4 rx17 ry5.4) and scaled to `markSize`, so rings and the ink
    // surface grow from the opening's own center instead of the old
    // placeholder position.
    private let openingSize = CGSize(width: Self.markSize * 0.17, height: Self.markSize * 0.054)
    private let openingOffsetY: CGFloat = Self.markSize * (0.202 - 0.5)

    var body: some View {
        ZStack {
            // Ambient glow behind the well.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [InkwellPalette.amber.opacity(glowOpacity), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: Self.containerSize / 2
                    )
                )
                .frame(width: Self.containerSize, height: Self.containerSize)
                .animation(.easeOut(duration: 0.12), value: inputLevel)

            // Ripple rings, only while listening.
            if isRecording {
                ForEach(0..<3, id: \.self) { i in
                    Ellipse()
                        .stroke(InkwellPalette.amber.opacity(0.5 - Double(i) * 0.15), lineWidth: 2)
                        .frame(width: openingSize.width, height: openingSize.height)
                        .scaleEffect(1 + CGFloat(i) * 0.45 + CGFloat(inputLevel) * 0.5)
                        .opacity(1 - Double(i) * 0.3)
                        .offset(y: openingOffsetY)
                        .animation(.easeOut(duration: 0.18), value: inputLevel)
                }
            }

            // The bottle itself.
            InkwellMarkBase()
                .frame(width: Self.markSize, height: Self.markSize)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 8)

            // The ink surface at the opening - this is what "reacts."
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            InkwellPalette.amber.opacity(isRecording ? 0.9 : 0.5),
                            InkwellPalette.inkDark
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 16
                    )
                )
                .frame(width: openingSize.width, height: openingSize.height)
                .scaleEffect(1 + CGFloat(inputLevel) * 0.12)
                .offset(y: openingOffsetY)
                .animation(.easeOut(duration: 0.1), value: inputLevel)

            // Rim highlights, painted in front of the ink surface just like
            // the source art.
            InkwellMarkRim()
                .frame(width: Self.markSize, height: Self.markSize)
        }
        .frame(width: Self.containerSize, height: Self.containerSize)
        .contentShape(Circle())
    }
}

enum InkwellPalette {
    static let inkDark = Color(red: 0.09, green: 0.10, blue: 0.16)
    static let inkLight = Color(red: 0.20, green: 0.22, blue: 0.32)
    static let inkHairline = Color.white.opacity(0.08)
    static let amber = Color(red: 0.80, green: 0.64, blue: 0.28)
    static let parchment = Color(red: 0.97, green: 0.95, blue: 0.90)
    static let parchmentDeep = Color(red: 0.93, green: 0.90, blue: 0.83)
    static let ink = Color(red: 0.15, green: 0.15, blue: 0.20)

    // Glass mark, traced from design/inkwell.svg.
    static let glassHighlight = Color(red: 0x5d / 255, green: 0x5d / 255, blue: 0x80 / 255)
    static let glassUpper = Color(red: 0x2b / 255, green: 0x2b / 255, blue: 0x3b / 255)
    static let glassCore = Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x26 / 255)
    static let glassLower = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x33 / 255)
    static let glassSheen = Color(red: 0x3d / 255, green: 0x3d / 255, blue: 0x55 / 255)
    static let glassDeepest = Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x18 / 255)
    static let neckShadow = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x28 / 255)
    static let collarShadow = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x3a / 255)
    static let collarBright = Color(red: 0x76 / 255, green: 0x76 / 255, blue: 0x99 / 255)
    static let collarMid = Color(red: 0x2b / 255, green: 0x2b / 255, blue: 0x3c / 255)
    static let collarWarm = Color(red: 0x4c / 255, green: 0x4c / 255, blue: 0x69 / 255)
    static let collarDeepest = Color(red: 0x0e / 255, green: 0x0e / 255, blue: 0x16 / 255)
    static let wallHighlight = Color(red: 0xc9 / 255, green: 0xc9 / 255, blue: 0xe8 / 255)
    static let wallHighlightSubtle = Color(red: 0xb0 / 255, green: 0xb0 / 255, blue: 0xd6 / 255)
    static let throughLight = Color(red: 0x8f / 255, green: 0x8f / 255, blue: 0xbe / 255)
    static let rimHole = Color(red: 0x0b / 255, green: 0x0b / 255, blue: 0x13 / 255)
    static let rimStroke = Color(red: 0xdc / 255, green: 0xdc / 255, blue: 0xf2 / 255)
    static let rimGlint = Color(red: 0xd5 / 255, green: 0xd5 / 255, blue: 0xf0 / 255)
    static let causticWarm = Color(red: 0x8a / 255, green: 0x8a / 255, blue: 0x63 / 255)
    static let contactShadow = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x33 / 255)
    static let baseShadow = Color(red: 0x04 / 255, green: 0x04 / 255, blue: 0x0a / 255)
}

#Preview {
    VStack(spacing: 40) {
        InkwellView(isRecording: false, inputLevel: 0)
        InkwellView(isRecording: true, inputLevel: 0.6)
    }
    .padding(60)
    .background(InkwellPalette.parchment)
}
