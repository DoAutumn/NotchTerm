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
                color: .black.opacity(model.isSurfaceRevealed ? 0.28 : 0),
                radius: 10,
                y: 4
            )
            .contentShape(notchShape)
            .onTapGesture { model.notchClicked() }
            // Drop out of / tuck into the hardware notch.
            .scaleEffect(
                x: model.isSurfaceRevealed ? 1 : 0.86,
                y: model.isSurfaceRevealed ? 1 : 0.35,
                anchor: .top
            )
            .offset(y: model.isSurfaceRevealed ? 0 : -10)
            .opacity(model.isSurfaceRevealed ? 1 : 0)
            .allowsHitTesting(model.isSurfaceRevealed)
            .animation(NotchMotion.spring, value: model.currentSize)
            .animation(NotchMotion.spring, value: model.mode)
            .animation(
                model.isSurfaceRevealed ? NotchMotion.reveal : NotchMotion.conceal,
                value: model.isSurfaceRevealed
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, NotchLayout.shadowHorizontalPadding)
    }
}

enum NotchMotion {
    static let spring: Animation = .spring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.2)
    /// Appear: soft drop from the top edge.
    static let reveal: Animation = .spring(response: 0.4, dampingFraction: 0.78, blendDuration: 0.15)
    /// Dismiss: quicker tuck back into the notch.
    static let conceal: Animation = .spring(response: 0.32, dampingFraction: 0.92, blendDuration: 0.1)
}

enum NotchChrome {
    /// Shared horizontal inset so header / tabs / card share one left+right edge.
    /// Sized past the notch ear (`topRadius`) so chrome doesn't sit on the curve.
    static let contentInset: CGFloat = 30
    static let bottomInset: CGFloat = 8
}
