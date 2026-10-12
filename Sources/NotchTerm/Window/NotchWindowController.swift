import AppKit
import SwiftUI

@MainActor
final class NotchWindowController: NSWindowController {
    private let model: AppModel
    private let screenManager: ScreenManager
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private weak var hostingView: NotchHostingView<AnyView>?
    /// Throttle hover/click-through updates (~30 Hz).
    private var lastClickThroughUpdate = Date.distantPast
    private let clickThroughMinInterval: TimeInterval = 1.0 / 30.0

    init(model: AppModel, screenManager: ScreenManager) {
        self.model = model
        self.screenManager = screenManager

        let size = Self.panelSize(for: model.settings)
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        super.init(window: panel)

        let hostingView = NotchHostingView(
            rootView: AnyView(
                NotchView()
                    .environmentObject(model)
            )
        )
        hostingView.sizingOptions = []
        hostingView.interactiveRectInView = { [weak hostingView, weak model] in
            guard let hostingView, let model else { return .zero }
            return Self.notchRect(in: hostingView.bounds, size: model.currentSize)
        }
        self.hostingView = hostingView
        panel.contentView = hostingView
        panel.acceptsMouseMovedEvents = true

        model.onPanelConfigurationChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.applyConfiguration()
            }
        }
        model.onVisibilityChanged = { [weak self] visible in
            visible ? self?.show() : self?.hide()
        }
        screenManager.onScreensChanged = { [weak self] in
            self?.applyConfiguration()
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.handleGlobalClick(event) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.handleGlobalClick(event) }
            return event
        }
        // Drive hover + click-through from mouse location (more reliable than SwiftUI onHover
        // on a panel that toggles ignoresMouseEvents).
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.updateClickThrough() }
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            Task { @MainActor in self?.updateClickThrough() }
            return event
        }
        applyConfiguration()
        updateClickThrough()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let mouseMoveMonitor { NSEvent.removeMonitor(mouseMoveMonitor) }
        if let localMouseMoveMonitor { NSEvent.removeMonitor(localMouseMoveMonitor) }
    }

    func show() {
        guard model.settings.isEnabled else { return }
        applyConfiguration()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func restart() {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.show() }
    }

    func applyConfiguration() {
        guard let panel = window as? NotchPanel,
              let screen = screenManager.screen(for: model.settings.targetDisplayID) else { return }

        // Always stay above normal windows; fullscreen coverage is a separate setting.
        panel.level = .statusBar
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary]
        if model.settings.showOnFullscreen { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior

        let size = Self.panelSize(for: model.settings)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - model.settings.verticalOffset,
            width: size.width,
            height: size.height
        )

        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        updateClickThrough()
    }

    private func visibleNotchFrame(in panel: NSWindow) -> NSRect {
        let notchSize = model.currentSize
        return NSRect(
            x: panel.frame.midX - notchSize.width / 2,
            y: panel.frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    private func updateClickThrough() {
        guard let panel = window as? NotchPanel, panel.isVisible else { return }
        let now = Date()
        guard now.timeIntervalSince(lastClickThroughUpdate) >= clickThroughMinInterval else { return }
        lastClickThroughUpdate = now

        // Slightly larger hover target than the drawn notch for easier enter/leave.
        let hoverFrame = visibleNotchFrame(in: panel).insetBy(dx: -10, dy: -6)
        let overNotch = hoverFrame.contains(NSEvent.mouseLocation)
        // When the cursor is outside the visible notch, ignore mouse so apps below receive clicks.
        if panel.ignoresMouseEvents == overNotch {
            panel.ignoresMouseEvents = !overNotch
        }
        if overNotch {
            model.hoverChanged(true)
        } else if !model.isPinned {
            model.hoverChanged(false)
        } else if model.isHovering {
            model.hoverChanged(false)
        }
    }

    private func handleGlobalClick(_ event: NSEvent) {
        guard let panel = window, panel.isVisible, model.isPinned else { return }
        if !visibleNotchFrame(in: panel).contains(NSEvent.mouseLocation) {
            model.closeFromOutsideClick()
        }
    }

    private static func panelSize(for settings: NotchSettings) -> NSSize {
        NSSize(
            width: max(settings.compactWidth + 28, settings.expandedWidth)
                + NotchLayout.shadowHorizontalPadding * 2,
            height: settings.expandedHeight + NotchLayout.shadowBottomPadding
        )
    }

    /// Visible notch rect inside the hosting view (top-centered).
    private static func notchRect(in bounds: CGRect, size: CGSize) -> CGRect {
        let x = bounds.midX - size.width / 2
        let y = bounds.maxY - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
