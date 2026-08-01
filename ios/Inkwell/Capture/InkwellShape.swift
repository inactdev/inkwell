import SwiftUI

/// Vector reproduction of the owner's inkwell artwork (`design/inkwell.svg`):
/// a squat glass ink bottle, traced from its 200x200 viewBox into SwiftUI
/// `Path`s that scale to whatever rect they're given, so the mark stays
/// resolution-independent at any size.
///
/// The SVG's ink-surface fill (the ellipse at the neck opening) is
/// deliberately not reproduced here - `InkwellView` draws that live, reacting
/// to microphone input, and layers it between `InkwellMarkBase` (the glass
/// body) and `InkwellMarkRim` (the rim highlights, which sit in front of the
/// ink surface in the source art).
enum InkwellArt {
    static func pt(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x / 200 * rect.width, y: rect.minY + y / 200 * rect.height)
    }

    static func len(_ rect: CGRect, _ v: CGFloat) -> CGFloat {
        v / 200 * rect.width
    }

    // MARK: Paths

    static func neckTube(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 79, 38))
        path.addLine(to: pt(rect, 121, 38))
        path.addLine(to: pt(rect, 122, 64))
        path.addLine(to: pt(rect, 78, 64))
        path.closeSubpath()
        return path
    }

    static func neckEdgeLeft(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 82, 38))
        path.addLine(to: pt(rect, 86, 38))
        path.addLine(to: pt(rect, 85, 64))
        path.addLine(to: pt(rect, 80.5, 64))
        path.closeSubpath()
        return path
    }

    static func neckEdgeRight(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 114, 38))
        path.addLine(to: pt(rect, 118, 38))
        path.addLine(to: pt(rect, 119.5, 64))
        path.addLine(to: pt(rect, 115, 64))
        path.closeSubpath()
        return path
    }

    static func body(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 78, 58))
        path.addCurve(to: pt(rect, 34, 120), control1: pt(rect, 78, 84), control2: pt(rect, 36, 88))
        path.addCurve(to: pt(rect, 100, 172), control1: pt(rect, 32.5, 151), control2: pt(rect, 62, 172))
        path.addCurve(to: pt(rect, 166, 120), control1: pt(rect, 138, 172), control2: pt(rect, 167.5, 151))
        path.addCurve(to: pt(rect, 122, 58), control1: pt(rect, 164, 88), control2: pt(rect, 122, 84))
        path.closeSubpath()
        return path
    }

    static func depthRect(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 30, 60))
        path.addLine(to: pt(rect, 170, 60))
        path.addLine(to: pt(rect, 170, 176))
        path.addLine(to: pt(rect, 30, 176))
        path.closeSubpath()
        return path
    }

    static func shadowBand(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 34, 104))
        path.addCurve(to: pt(rect, 166, 104), control1: pt(rect, 58, 116), control2: pt(rect, 142, 116))
        path.addLine(to: pt(rect, 166, 96))
        path.addCurve(to: pt(rect, 34, 96), control1: pt(rect, 142, 108), control2: pt(rect, 58, 108))
        path.closeSubpath()
        return path
    }

    static func bandLine(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 36, 100))
        path.addCurve(to: pt(rect, 164, 100), control1: pt(rect, 60, 111), control2: pt(rect, 140, 111))
        return path
    }

    static func leftWallHighlight(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 42, 108))
        path.addCurve(to: pt(rect, 58, 166), control1: pt(rect, 40, 132), control2: pt(rect, 44, 154))
        return path
    }

    static func rightWallHighlight(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 160, 108))
        path.addCurve(to: pt(rect, 148, 165), control1: pt(rect, 165, 130), control2: pt(rect, 162, 152))
        return path
    }

    static func broadStreak(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 64, 78))
        path.addCurve(to: pt(rect, 42, 126), control1: pt(rect, 52, 92), control2: pt(rect, 44, 108))
        return path
    }

    static func crispStreak(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 70, 80))
        path.addCurve(to: pt(rect, 52, 118), control1: pt(rect, 60, 92), control2: pt(rect, 54, 104))
        return path
    }

    static func thinStreak(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 78, 84))
        path.addCurve(to: pt(rect, 66, 108), control1: pt(rect, 71, 92), control2: pt(rect, 67, 100))
        return path
    }

    static func baseReflectionLine(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 60, 170))
        path.addCurve(to: pt(rect, 140, 170), control1: pt(rect, 76, 176), control2: pt(rect, 124, 176))
        return path
    }

    static func collarRing(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 76, 39))
        path.addCurve(to: pt(rect, 100, 48), control1: pt(rect, 76, 44), control2: pt(rect, 86.7, 48))
        path.addCurve(to: pt(rect, 124, 39), control1: pt(rect, 113.3, 48), control2: pt(rect, 124, 44))
        path.addLine(to: pt(rect, 124, 45))
        path.addCurve(to: pt(rect, 100, 54), control1: pt(rect, 124, 50), control2: pt(rect, 113.3, 54))
        path.addCurve(to: pt(rect, 76, 45), control1: pt(rect, 86.7, 54), control2: pt(rect, 76, 50))
        path.closeSubpath()
        return path
    }

    static func rimHighlightLeft(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 77.5, 37))
        path.addCurve(to: pt(rect, 100, 32.4), control1: pt(rect, 81.5, 34), control2: pt(rect, 90, 32.4))
        return path
    }

    static func rimHighlightRight(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(rect, 120, 44.5))
        path.addCurve(to: pt(rect, 124, 39.4), control1: pt(rect, 122.5, 43), control2: pt(rect, 123.6, 41.2))
        return path
    }

    // MARK: Gradients

    static let glassGradient = LinearGradient(
        stops: [
            .init(color: InkwellPalette.glassHighlight, location: 0),
            .init(color: InkwellPalette.glassUpper, location: 0.13),
            .init(color: InkwellPalette.glassCore, location: 0.42),
            .init(color: InkwellPalette.glassLower, location: 0.72),
            .init(color: InkwellPalette.glassSheen, location: 0.9),
            .init(color: InkwellPalette.glassDeepest, location: 1),
        ],
        startPoint: UnitPoint(x: 0, y: 0),
        endPoint: UnitPoint(x: 1, y: 0.35)
    )

    static let collarGradient = LinearGradient(
        stops: [
            .init(color: InkwellPalette.collarShadow, location: 0),
            .init(color: InkwellPalette.collarBright, location: 0.18),
            .init(color: InkwellPalette.collarMid, location: 0.42),
            .init(color: InkwellPalette.collarWarm, location: 0.72),
            .init(color: InkwellPalette.collarDeepest, location: 1),
        ],
        startPoint: UnitPoint(x: 0, y: 0),
        endPoint: UnitPoint(x: 1, y: 0.2)
    )

    static let depthGradient = LinearGradient(
        stops: [
            .init(color: InkwellPalette.baseShadow.opacity(0.75), location: 0),
            .init(color: InkwellPalette.baseShadow.opacity(0.15), location: 0.35),
            .init(color: InkwellPalette.baseShadow.opacity(0), location: 0.78),
            .init(color: InkwellPalette.baseShadow.opacity(0.7), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let wallLGradient = LinearGradient(
        stops: [
            .init(color: InkwellPalette.wallHighlight.opacity(0.05), location: 0),
            .init(color: InkwellPalette.wallHighlight.opacity(0.5), location: 0.5),
            .init(color: InkwellPalette.wallHighlight.opacity(0), location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: Composite layers

    @ViewBuilder
    static func contactShadow(in rect: CGRect) -> some View {
        Ellipse()
            .fill(RadialGradient(
                colors: [InkwellPalette.causticWarm.opacity(0.3), InkwellPalette.causticWarm.opacity(0)],
                center: .center, startRadius: 0, endRadius: len(rect, 76)
            ))
            .frame(width: len(rect, 152), height: len(rect, 26))
            .position(pt(rect, 118, 176))
            .blur(radius: len(rect, 3))
        Ellipse()
            .fill(RadialGradient(
                colors: [InkwellPalette.contactShadow.opacity(0.5), InkwellPalette.contactShadow.opacity(0)],
                center: .center, startRadius: 0, endRadius: len(rect, 60)
            ))
            .frame(width: len(rect, 120), height: len(rect, 22))
            .position(pt(rect, 104, 174))
        Ellipse()
            .fill(InkwellPalette.neckShadow.opacity(0.45))
            .frame(width: len(rect, 84), height: len(rect, 12))
            .position(pt(rect, 100, 172))
            .blur(radius: len(rect, 3))
    }

    @ViewBuilder
    static func interior(in rect: CGRect) -> some View {
        depthRect(in: rect).fill(depthGradient)
        Ellipse()
            .fill(RadialGradient(
                colors: [InkwellPalette.throughLight.opacity(0.38), InkwellPalette.throughLight.opacity(0)],
                center: .center, startRadius: 0, endRadius: len(rect, 44)
            ))
            .frame(width: len(rect, 88), height: len(rect, 52))
            .position(pt(rect, 100, 168))
        shadowBand(in: rect)
            .fill(Color.black.opacity(0.5))
            .blur(radius: len(rect, 3))
        bandLine(in: rect)
            .stroke(InkwellPalette.wallHighlightSubtle.opacity(0.35), style: StrokeStyle(lineWidth: len(rect, 1.6)))
            .blur(radius: len(rect, 0.9))
        leftWallHighlight(in: rect)
            .stroke(wallLGradient, style: StrokeStyle(lineWidth: len(rect, 9), lineCap: .round))
            .blur(radius: len(rect, 3))
        rightWallHighlight(in: rect)
            .stroke(InkwellPalette.wallHighlightSubtle.opacity(0.32), style: StrokeStyle(lineWidth: len(rect, 6), lineCap: .round))
            .blur(radius: len(rect, 3))
        broadStreak(in: rect)
            .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: len(rect, 7), lineCap: .round))
            .blur(radius: len(rect, 3))
        crispStreak(in: rect)
            .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: len(rect, 2.4), lineCap: .round))
            .blur(radius: len(rect, 0.9))
        thinStreak(in: rect)
            .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: len(rect, 1.1), lineCap: .round))
            .blur(radius: len(rect, 0.9))
        Ellipse()
            .fill(InkwellPalette.wallHighlight.opacity(0.12))
            .frame(width: len(rect, 36), height: len(rect, 18))
            .rotationEffect(.degrees(-18))
            .position(pt(rect, 126, 150))
            .blur(radius: len(rect, 3))
        Ellipse()
            .fill(InkwellPalette.baseShadow.opacity(0.6))
            .frame(width: len(rect, 124), height: len(rect, 36))
            .position(pt(rect, 100, 180))
            .blur(radius: len(rect, 8))
        baseReflectionLine(in: rect)
            .stroke(InkwellPalette.rimStroke.opacity(0.22), style: StrokeStyle(lineWidth: len(rect, 3), lineCap: .round))
            .blur(radius: len(rect, 3))
    }
}

/// Everything from the SVG behind the ink surface: contact shadow, neck,
/// glass body, and collar/rim down to the dark opening hole.
struct InkwellMarkBase: View {
    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                InkwellArt.contactShadow(in: rect)
                InkwellArt.neckTube(in: rect).fill(InkwellPalette.neckShadow)
                InkwellArt.neckEdgeLeft(in: rect)
                    .fill(InkwellPalette.wallHighlight.opacity(0.35))
                    .blur(radius: InkwellArt.len(rect, 0.9))
                InkwellArt.neckEdgeRight(in: rect)
                    .fill(InkwellPalette.wallHighlightSubtle.opacity(0.28))
                    .blur(radius: InkwellArt.len(rect, 0.9))
                InkwellArt.body(in: rect).fill(InkwellArt.glassGradient)
                InkwellArt.interior(in: rect).clipShape(InkwellArt.body(in: rect))
                InkwellArt.collarRing(in: rect).fill(InkwellArt.collarGradient)
                Ellipse()
                    .fill(InkwellArt.collarGradient)
                    .frame(width: InkwellArt.len(rect, 48), height: InkwellArt.len(rect, 16))
                    .position(InkwellArt.pt(rect, 100, 39))
                Ellipse()
                    .fill(InkwellPalette.rimHole)
                    .frame(width: InkwellArt.len(rect, 37), height: InkwellArt.len(rect, 12))
                    .position(InkwellArt.pt(rect, 100, 39.6))
            }
        }
    }
}

/// The rim highlights that sit in front of the ink surface in the source
/// art: the thin outline ring around the opening, its glass glint, and the
/// two rim reflection strokes.
struct InkwellMarkRim: View {
    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                Ellipse()
                    .stroke(InkwellPalette.wallHighlightSubtle.opacity(0.4), lineWidth: InkwellArt.len(rect, 0.8))
                    .frame(width: InkwellArt.len(rect, 34), height: InkwellArt.len(rect, 10.8))
                    .position(InkwellArt.pt(rect, 100, 40.4))
                Ellipse()
                    .fill(InkwellPalette.rimGlint.opacity(0.32))
                    .frame(width: InkwellArt.len(rect, 15), height: InkwellArt.len(rect, 4))
                    .position(InkwellArt.pt(rect, 94, 38.8))
                    .blur(radius: InkwellArt.len(rect, 0.9))
                InkwellArt.rimHighlightLeft(in: rect)
                    .stroke(InkwellPalette.rimStroke.opacity(0.6), style: StrokeStyle(lineWidth: InkwellArt.len(rect, 1.8), lineCap: .round))
                InkwellArt.rimHighlightRight(in: rect)
                    .stroke(InkwellPalette.rimStroke.opacity(0.35), style: StrokeStyle(lineWidth: InkwellArt.len(rect, 1.4), lineCap: .round))
            }
        }
    }
}
