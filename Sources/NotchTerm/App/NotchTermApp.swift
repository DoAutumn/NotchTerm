import AppKit
import SwiftUI

@main
struct NotchTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appDelegate.model)
        } label: {
            Image(nsImage: Self.trayIcon)
        }
    }

    /// Multi-representation template icon so Retina menu bars stay sharp.
    private static let trayIcon: NSImage = {
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
            // Point size stays 18×18; pixel dimensions encode the scale.
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

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Install Cursor CLI hooks so agents push running/idle (hooks are the only agent-state signal).
        _ = AgentHookService.ensureInstalled()
        UpdateChecker.check(interactive: false)
        notchController = NotchWindowController(model: model, screenManager: screenManager)
        settingsController = SettingsWindowController(model: model, screenManager: screenManager)
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

    func restartNotch() {
        notchController?.restart()
    }

    func openSettings() {
        settingsController?.present()
    }

    func checkForUpdates() {
        UpdateChecker.check(interactive: true)
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let task = model.selectedTask {
            Button("\(task.title) · \(task.state.label)") {
                model.expand(pin: true)
            }
            Button("Jump to iTerm") {
                model.focusTaskInITerm(task)
            }
            Divider()
        }

        Button("Settings…") { AppDelegate.shared?.openSettings() }
            .keyboardShortcut(",")
        Button("Check for Updates…") { AppDelegate.shared?.checkForUpdates() }
        Button("Restart Notch") { AppDelegate.shared?.restartNotch() }

        Divider()

        Button("Quit NotchTerm") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
