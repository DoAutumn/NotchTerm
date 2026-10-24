import AppKit
import SwiftUI

@MainActor
final class NotchWindowController: NSWindowController {
    private let model: AppModel
    private let screenManager: ScreenManager
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private weak var hostingView: NotchHostingView<AnyView>?

    /// 不用全局 mouseMoved：accessory 下会拖慢菜单悬停（开设置变 regular 后就顺）。
    /// 改为低频采样，并在菜单打开时暂停。
    private var hoverSampleTimer: Timer?
    private var lastSampledMouse: NSPoint?
    private var hoverSamplingPaused = false

    init(model: AppModel, screenManager: ScreenManager) {
        self.model = model
        self.screenManager = screenManager

        let size = Self.panelSize(for: model)
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

        // 点击类监听开销小，保留；悬停改走 timer，避免 mouseMoved 洪水。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleGlobalClick(event)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleGlobalClick(event)
            return event
        }

        applyConfiguration()
        updateClickThrough()
        startHoverSamplingIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        hoverSampleTimer?.invalidate()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }

    func show() {
        guard model.settings.isEnabled else { return }
        applyConfiguration()
        window?.orderFrontRegardless()
        startHoverSamplingIfNeeded()
        updateClickThrough()
    }

    func hide() {
        stopHoverSampling()
        window?.orderOut(nil)
    }

    /// 菜单栏 NSMenu 打开期间暂停采样，避免和系统菜单抢主线程。
    func setMenuTrackingActive(_ active: Bool) {
        hoverSamplingPaused = active
        if active {
            // 菜单打开时强制穿透，别让刘海抢事件。
            (window as? NotchPanel)?.ignoresMouseEvents = true
            if model.isHovering, !model.isPinned {
                model.hoverChanged(false)
            }
        } else {
            lastSampledMouse = nil
            updateClickThrough()
        }
    }

    func restart() {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.show() }
    }

    func applyConfiguration() {
        guard let panel = window as? NotchPanel,
              let screen = screenManager.screen(for: model.settings.targetDisplayID) else { return }

        panel.level = .statusBar
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary]
        if model.settings.showOnFullscreen { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior

        let size = Self.panelSize(for: model)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - model.settings.verticalOffset,
            width: size.width,
            height: size.height
        )

        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            lastSampledMouse = nil
        }
        model.updateHardwareNotchSize(screen.hardwareNotchSize)
        startHoverSamplingIfNeeded()
        updateClickThrough()
    }

    // MARK: - Hover sampling (no mouseMoved monitors)

    private func startHoverSamplingIfNeeded() {
        guard hoverSampleTimer == nil else { return }
        guard window?.isVisible == true else { return }
        // 12 Hz：挂在 main RunLoop，直接采样，避免每拍分配 Task。
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleHover()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverSampleTimer = timer
    }

    private func stopHoverSampling() {
        hoverSampleTimer?.invalidate()
        hoverSampleTimer = nil
        lastSampledMouse = nil
    }

    private func sampleHover() {
        guard !hoverSamplingPaused else { return }
        guard let panel = window as? NotchPanel, panel.isVisible else { return }

        let mouse = NSEvent.mouseLocation
        // 鼠标几乎没动则跳过。
        if let last = lastSampledMouse,
           abs(mouse.x - last.x) < 0.5,
           abs(mouse.y - last.y) < 0.5 {
            return
        }
        lastSampledMouse = mouse

        // 远离开顶部刘海带则廉价返回（全屏移动时不刷 ignoresMouseEvents）。
        let bandMinY = panel.frame.maxY - model.currentSize.height - 40
        if mouse.y < bandMinY {
            if !panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = true
            }
            if model.isHovering, !model.isPinned {
                model.hoverChanged(false)
            }
            return
        }

        updateClickThrough(mouse: mouse)
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

    private func updateClickThrough(mouse: NSPoint = NSEvent.mouseLocation) {
        guard let panel = window as? NotchPanel, panel.isVisible else { return }
        guard !hoverSamplingPaused else {
            panel.ignoresMouseEvents = true
            return
        }

        let hoverFrame = visibleNotchFrame(in: panel).insetBy(dx: -10, dy: -6)
        let overNotch = hoverFrame.contains(mouse)
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

    /// 窗口需覆盖 expanded 与（含多股提醒加宽后的）compact；用 currentSize 避免提醒被裁切。
    private static func panelSize(for model: AppModel) -> NSSize {
        let settings = model.settings
        let compactPad: CGFloat = model.mode == .compact ? 28 : 0
        let width = max(
            settings.compactWidth + 28,
            settings.expandedWidth,
            model.currentSize.width + compactPad
        ) + NotchLayout.shadowHorizontalPadding * 2
        return NSSize(
            width: width,
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
