import SwiftUI

/// A squat ink bottle silhouette: rounded body, tapered neck. Deliberately
/// not a breathing circle - the product contract calls that out by name as
/// the wrong visual for this.
struct InkwellShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let neckWidth = width * 0.32
        let neckHeight = height * 0.14
        let bodyCorner = width * 0.24

        var path = Path()
        let bodyRect = CGRect(x: rect.minX, y: rect.minY + neckHeight, width: width, height: height - neckHeight)
        path.addRoundedRect(in: bodyRect, cornerSize: CGSize(width: bodyCorner, height: bodyCorner))

        let neckRect = CGRect(
            x: rect.minX + (width - neckWidth) / 2,
            y: rect.minY,
            width: neckWidth,
            height: neckHeight + bodyCorner
        )
        path.addRoundedRect(in: neckRect, cornerSize: CGSize(width: neckWidth * 0.28, height: neckWidth * 0.28))

        return path
    }
}
