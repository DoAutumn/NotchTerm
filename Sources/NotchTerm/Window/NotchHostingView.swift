import AppKit
import SwiftUI

/// Hosts SwiftUI content but only intercepts hits inside the visible notch.
/// Transparent areas pass clicks through to apps underneath.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Interactive region in this view's coordinates (AppKit: origin bottom-left).
    var interactiveRectInView: (() -> CGRect)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let region = interactiveRectInView?() ?? .zero
        guard region.insetBy(dx: -2, dy: -2).contains(point) else {
            return nil
        }
        return super.hitTest(point)
    }
}
