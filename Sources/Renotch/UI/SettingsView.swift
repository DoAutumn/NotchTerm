import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var screenManager: ScreenManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Re:notch")
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 4)
            Text("iTerm long-task monitor for the Mac notch")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

            Form {
                Section("General") {
                    Toggle("Show notch", isOn: Binding(
                        get: { model.settings.isEnabled },
                        set: { AppDelegate.shared?.setNotchVisible($0) }
                    ))
                    Toggle("Always on top", isOn: $model.settings.alwaysOnTop)
                    Toggle("Show over fullscreen apps", isOn: $model.settings.showOnFullscreen)
                    Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
                    Toggle("Notify when a task finishes", isOn: $model.settings.notifyOnComplete)
                    Text("Notifications are off by default.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Display") {
                    Picker("Target display", selection: displayBinding) {
                        Text("Default").tag(UInt32?.none)
                        ForEach(screenManager.displays) { display in
                            Text(display.name).tag(Optional(display.id))
                        }
                    }
                    HStack {
                        Text("Vertical offset")
                        Slider(value: $model.settings.verticalOffset, in: 0...40, step: 1)
                        Text("\(Int(model.settings.verticalOffset))")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }

                Section("Monitoring") {
                    HStack {
                        Text("Poll interval")
                        Slider(value: $model.settings.pollIntervalSeconds, in: 0.6...3.0, step: 0.1)
                        Text(String(format: "%.1fs", model.settings.pollIntervalSeconds))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    Text("Tracks git clone/fetch/pull, npm/pnpm/yarn/bun install|build|test, and Cursor Agent in iTerm.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    Text("Grant Automation access for iTerm so Re:notch can read session state and jump to the right tab.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Open Automation Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                        )
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var displayBinding: Binding<UInt32?> {
        Binding(
            get: { model.settings.targetDisplayID },
            set: { model.settings.targetDisplayID = $0 }
        )
    }
}
