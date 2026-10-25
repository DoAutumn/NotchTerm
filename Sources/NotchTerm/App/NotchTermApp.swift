import AppKit
import SwiftUI

@main
struct NotchTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 菜单栏 UI 由 AppDelegate 的 NSStatusItem + NSPanel 驱动；
        // Settings 场景仅满足 SwiftUI App 需要至少一个 Scene。
        Settings {
            EmptyView()
        }
    }

    /// Multi-representation template icon so Retina menu bars stay sharp.
    static let trayIconImage: NSImage = {
        let pointSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: pointSize)

        let scales: [(CGFloat, String)] = [
            (1, "TrayIconTemplate"),
            (2, "TrayIconTemplate@2x"),
            (3, "TrayIconTemplate@3x")
        ]

        var loadedAny = false
        for (_, name) in scales {
            guard let url = resolveTrayURL(named: name),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = pointSize
            image.addRepresentation(rep)
            loadedAny = true
        }

        if !loadedAny {
            let fallback = NSImage(systemSymbolName: "terminal", accessibilityDescription: "NotchTerm") ?? NSImage()
            fallback.isTemplate = true
            fallback.size = pointSize
            return fallback
        }

        image.isTemplate = true
        image.size = pointSize
        return image
    }()

    private static func resolveTrayURL(named name: String) -> URL? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: "png"),
            Bundle.main.resourceURL?
                .appendingPathComponent("NotchTerm_NotchTerm.bundle")
                .appendingPathComponent("\(name).png"),
            Bundle.main.resourceURL?
                .appendingPathComponent("\(name).png")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    let model = AppModel()
    let screenManager = ScreenManager()
    private var notchController: NotchWindowController?
    private var settingsController: SettingsWindowController?
    private var menuBarController: MenuBarController?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = AgentHookService.ensureInstalled()
        _ = ShellHookService.ensureInstalled()
        notchController = NotchWindowController(model: model, screenManager: screenManager)
        settingsController = SettingsWindowController(model: model, screenManager: screenManager)
        menuBarController = MenuBarController(model: model)
        model.syncNotchPresentation()
        if model.settings.notifyOnComplete {
            NotificationService.shared.requestAuthorizationIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func setNotchVisible(_ visible: Bool) {
        model.setVisible(visible)
        visible ? notchController?.show() : notchController?.hide()
    }

    func showNotch() {
        setNotchVisible(true)
    }

    func hideNotch() {
        setNotchVisible(false)
    }

    func openSettings() {
        menuBarController?.dismissPanel()
        settingsController?.present()
    }

    func settingsWindowDidClose() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// 菜单栏菜单开合时暂停刘海鼠标采样，避免 accessory 下拖慢菜单悬停。
    func setMenuBarMenuOpen(_ open: Bool) {
        notchController?.setMenuTrackingActive(open)
    }
}
