import AppKit
import SwiftUI

@main
struct RenotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appDelegate.model)
        } label: {
            Image(nsImage: Self.trayIcon)
        }
    }

    private static var trayIcon: NSImage {
        if let url = Bundle.main.url(forResource: "TrayIconTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("Renotch_Renotch.bundle"),
           let bundle = Bundle(url: bundleURL),
           let url = bundle.url(forResource: "TrayIconTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let fallback = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Re:notch") ?? NSImage()
        fallback.isTemplate = true
        fallback.size = NSSize(width: 18, height: 18)
        return fallback
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
        UpdateChecker.check(interactive: false)
        notchController = NotchWindowController(model: model, screenManager: screenManager)
        settingsController = SettingsWindowController(model: model, screenManager: screenManager)
        if model.settings.isEnabled {
            notchController?.show()
        }
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
        Button("Show Notch") { AppDelegate.shared?.showNotch() }
            .disabled(model.settings.isEnabled)
        Button("Hide Notch") { AppDelegate.shared?.hideNotch() }
            .disabled(!model.settings.isEnabled)

        Divider()

        if let task = model.selectedTask {
            Button("\(task.title) · \(task.state.label)") {
                AppDelegate.shared?.showNotch()
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

        Button("Quit Re:notch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
