import AppKit
import SwiftUI

@MainActor
final class NotchWindowController: NSWindowController {
    private let model: AppModel
    private let screenManager: ScreenManager
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    init(model: AppModel, screenManager: ScreenManager) {
        self.model = model
        self.screenManager = screenManager

        let size = Self.panelSize(for: model.settings)
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        super.init(window: panel)

        let hostingView = NotchHostingView(
            rootView: NotchView()
                .environmentObject(model)
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        model.onPanelConfigurationChanged = { [weak self] in
            self?.applyConfiguration(animated: true)
        }
        model.onVisibilityChanged = { [weak self] visible in
            visible ? self?.show() : self?.hide()
        }
        screenManager.onScreensChanged = { [weak self] in
            self?.applyConfiguration(animated: false)
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.handleGlobalClick(event) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.handleGlobalClick(event) }
            return event
        }
        applyConfiguration(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }

    func show() {
        guard model.settings.isEnabled else { return }
        applyConfiguration(animated: false)
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func restart() {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.show() }
    }

    func applyConfiguration(animated: Bool) {
        guard let panel = window as? NotchPanel,
              let screen = screenManager.screen(for: model.settings.targetDisplayID) else { return }

        panel.level = model.settings.alwaysOnTop ? .statusBar : .floating
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

        guard panel.frame != frame else { return }

        guard animated,
              panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func handleGlobalClick(_ event: NSEvent) {
        guard let panel = window, panel.isVisible, model.isPinned else { return }
        let notchSize = model.currentSize
        let visibleNotchFrame = NSRect(
            x: panel.frame.midX - notchSize.width / 2,
            y: panel.frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
        if !visibleNotchFrame.contains(NSEvent.mouseLocation) {
            model.closeFromOutsideClick()
        }
    }

    private static func panelSize(for settings: NotchSettings) -> NSSize {
        NSSize(
            width: max(settings.compactWidth, settings.expandedWidth)
                + NotchLayout.shadowHorizontalPadding * 2,
            height: max(settings.compactHeight, settings.expandedHeight)
                + NotchLayout.shadowBottomPadding
        )
    }
}
