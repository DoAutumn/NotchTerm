import SwiftUI

struct NotchView: View {
    @EnvironmentObject private var model: AppModel

    private var topCornerRadius: CGFloat {
        model.mode == .expanded ? 10 : 8
    }

    private var bottomCornerRadius: CGFloat {
        model.mode == .expanded ? 12 : 10
    }

    private var notchShape: AttachedNotchShape {
        AttachedNotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.allowsHitTesting(false)

            // One continuous surface: compact strip stays mounted while height grows,
            // so expand/collapse morphs instead of swapping two separate UIs.
            VStack(spacing: 0) {
                CompactTaskView()
                    .frame(height: model.settings.compactHeight)
                    .frame(maxWidth: .infinity)

                ExpandedTaskView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .opacity(model.mode == .expanded ? 1 : 0)
                    .allowsHitTesting(model.mode == .expanded)
            }
            .frame(width: model.currentSize.width, height: model.currentSize.height, alignment: .top)
            .background(notchShape.fill(Color.black.opacity(0.94)))
            .overlay {
                notchShape.stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .clipShape(notchShape)
            // Flatten before shadow so spring size animation doesn't rebuild the
            // drop-shadow layer (that was the delayed “shadow blink”).
            .compositingGroup()
            .shadow(
                color: .black.opacity(shadowOpacity),
                radius: 10,
                y: 4
            )
            .contentShape(notchShape)
            .onTapGesture { model.notchClicked() }
            // Grow out of / shrink into the hardware notch. Top-center stays pinned
            // to the bezel so the motion reads as the notch itself changing size.
            .scaleEffect(surfaceScale, anchor: .top)
            .offset(y: tuckOffsetY)
            .opacity(surfaceOpacity)
            .allowsHitTesting(model.isSurfaceRevealed)
            .animation(NotchMotion.spring, value: model.currentSize)
            .animation(NotchMotion.spring, value: model.mode)
            .animation(surfaceAnimation, value: model.isSurfaceRevealed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, NotchLayout.shadowHorizontalPadding)
    }

    /// 1 when shown. Hidden: match the physical notch, or a small tuck on displays without one.
    private var surfaceScale: CGSize {
        guard !model.isSurfaceRevealed else { return CGSize(width: 1, height: 1) }
        guard let notch = model.hardwareNotchSize else {
            return CGSize(width: 0.86, height: 0.35)
        }
        let size = model.currentSize
        return CGSize(
            width: min(1, notch.width / max(size.width, 1)),
            height: min(1, notch.height / max(size.height, 1))
        )
    }

    /// Displays without a notch still slide a little; a real notch stays glued to the bezel.
    private var tuckOffsetY: CGFloat {
        guard !model.isSurfaceRevealed, model.hardwareNotchSize == nil else { return 0 }
        return -10
    }

    /// Notched displays stay solid and only scale. Other displays still fade out.
    private var surfaceOpacity: Double {
        if model.hardwareNotchSize != nil { return 1 }
        return model.isSurfaceRevealed ? 1 : 0
    }

    private var shadowOpacity: Double {
        if model.hardwareNotchSize != nil { return 0.28 }
        return model.isSurfaceRevealed ? 0.28 : 0
    }

    private var surfaceAnimation: Animation {
        if model.hardwareNotchSize != nil {
            return model.isSurfaceRevealed ? NotchMotion.notchReveal : NotchMotion.notchConceal
        }
        return model.isSurfaceRevealed ? NotchMotion.reveal : NotchMotion.conceal
    }
}

enum NotchMotion {
    static let spring: Animation = .spring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.2)
    /// Displays without a notch: soft drop from the top edge.
    static let reveal: Animation = .spring(response: 0.4, dampingFraction: 0.78, blendDuration: 0.15)
    /// Displays without a notch: quicker tuck and fade.
    static let conceal: Animation = .spring(response: 0.32, dampingFraction: 0.92, blendDuration: 0.1)
    static let concealHold: TimeInterval = 0.34
    /// Notched displays: bloom out of the hardware notch, no fade.
    static let notchReveal: Animation = .spring(response: 0.46, dampingFraction: 0.86, blendDuration: 0.12)
    /// Notched displays: settle into the notch without bouncing back out.
    static let notchConceal: Animation = .spring(response: 0.38, dampingFraction: 1, blendDuration: 0)
    static let notchConcealHold: TimeInterval = 0.46
}

enum NotchChrome {
    /// Shared horizontal inset so header / tabs / card share one left+right edge.
    /// Sized past the notch ear (`topRadius`) so chrome doesn't sit on the curve.
    static let contentInset: CGFloat = 30
    /// Slightly under side inset so the jump button sits clear of the bottom curve.
    static let bottomInset: CGFloat = 16
}
