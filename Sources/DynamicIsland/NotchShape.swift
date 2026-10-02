import SwiftUI

/// The island outline: a flat top whose corners flare outward into the menu
/// bar (concave, like the hardware notch) and rounded bottom corners.
///
/// Both radii follow the height, so a camera-tall strip keeps the cutout's
/// own small corners and the open island gets full ones; as the frame
/// animates, the corners morph with it. The flare takes `shoulder(height:)`
/// on each side, so the solid body is `width - 2 * shoulder` wide.
struct NotchShape: Shape {
    static func shoulder(height: CGFloat) -> CGFloat { min(14, height * 0.2) }
    static func bottomRadius(height: CGFloat) -> CGFloat { min(26, height * 0.33) }

    func path(in rect: CGRect) -> Path {
        let t = min(Self.shoulder(height: rect.height), rect.width / 4)
        let b = min(Self.bottomRadius(height: rect.height), (rect.width - 2 * t) / 2, rect.height)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
