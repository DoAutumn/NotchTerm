import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var clickMonitor: Any?

    init(model: AppModel, screenManager: ScreenManager) {
        let content = SettingsView()
            .environmentObject(model)
            .environmentObject(screenManager)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.minSize = NSSize(width: 540, height: 520)
        window.title = "NotchTerm 设置"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.setFrameAutosaveName("NotchTerm.SettingsWindow.v5")
        window.setContentSize(NSSize(width: 560, height: 560))
        window.center()
        // 启动时只创建窗口，不要留在屏上，避免误触成 regular / Dock。
        window.orderOut(nil)

        super.init(window: window)
        window.delegate = self
        installClickMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }

    func present() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        // NSWindowDelegate 没有 didClose；下一拍再切回 accessory。
        // 若同一拍又 present 打开，则不要切回 accessory。
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                AppDelegate.shared?.settingsWindowDidClose()
                return
            }
            if self.window?.isVisible == true { return }
            AppDelegate.shared?.settingsWindowDidClose()
        }
    }

    /// 点击非文本控件时强制卸下搜索框焦点（SwiftUI Form 不会自动 resign NSTextView）。
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window == window else { return event }
            let point = event.locationInWindow
            let hit = window.contentView?.hitTest(point)
            if !Self.isSearchOrTextInput(hit) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private static func isSearchOrTextInput(_ view: NSView?) -> Bool {
        var current = view
        while let node = current {
            if node is NSTextView || node is NSTextField {
                return true
            }
            current = node.superview
        }
        return false
    }
}
