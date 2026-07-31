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

    // The neck opening's ellipse, measured from InkwellShape's own geometry
    // (168pt box): a tight frame around just the opening, offset up from the
    // box's center, so scaleEffect below grows rings from the opening's own
    // center instead of drifting toward the bottle's center.
    private let openingSize = CGSize(width: 56, height: 10)
    private let openingOffsetY: CGFloat = -72

    var body: some View {
        ZStack {
            // Ambient glow behind the well.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [InkwellPalette.amber.opacity(glowOpacity), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 130
                    )
                )
                .frame(width: 260, height: 260)
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
            InkwellShape()
                .fill(
                    LinearGradient(
                        colors: [InkwellPalette.inkLight, InkwellPalette.inkDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    InkwellShape()
                        .stroke(InkwellPalette.inkHairline, lineWidth: 1)
                )
                .frame(width: 168, height: 168)
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
        }
        .frame(width: 260, height: 260)
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
}

#Preview {
    VStack(spacing: 40) {
        InkwellView(isRecording: false, inputLevel: 0)
        InkwellView(isRecording: true, inputLevel: 0.6)
    }
    .padding(60)
    .background(InkwellPalette.parchment)
}
