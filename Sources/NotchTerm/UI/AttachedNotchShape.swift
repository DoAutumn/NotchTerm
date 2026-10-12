import SwiftUI

/// Notch geometry that flares into the screen bezel at the top corners.
struct AttachedNotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let requestedTopRadius = max(0, topCornerRadius)
        let requestedBottomRadius = max(0, bottomCornerRadius)
        let radiusScale = min(
            1,
            rect.height / max(requestedTopRadius + requestedBottomRadius, 1)
        )
        let topRadius = requestedTopRadius * radiusScale
        let bottomRadius = requestedBottomRadius * radiusScale
        var path = Path()

        // Top-left ear easing out into the screen bezel
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control1: CGPoint(x: rect.minX + topRadius * 0.44, y: rect.minY),
            control2: CGPoint(x: rect.minX + topRadius * 0.88, y: rect.minY + topRadius * 0.42)
        )

        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))

        path.addCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control1: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius * 0.44),
            control2: CGPoint(x: rect.minX + topRadius + bottomRadius * 0.44, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))

        path.addCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control1: CGPoint(x: rect.maxX - topRadius - bottomRadius * 0.44, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius * 0.44)
        )

        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))

        // Top-right ear easing out into the screen bezel
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - topRadius * 0.88, y: rect.minY + topRadius * 0.42),
            control2: CGPoint(x: rect.maxX - topRadius * 0.44, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
