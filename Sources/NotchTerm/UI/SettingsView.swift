import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var screenManager: ScreenManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NotchTerm")
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
                    Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
                    Toggle("Notify when a task finishes", isOn: $model.settings.notifyOnComplete)
                    Toggle(
                        "Show over fullscreen apps",
                        isOn: $model.settings.showOnFullscreen
                    )
                    Text("Keeps the notch visible while another app is in fullscreen (e.g. video or Keynote). Turn off if you want it hidden during fullscreen.")
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
                    Text("Cursor Agent busy/idle comes only from CLI hooks (beforeSubmitPrompt / preCompact → RUNNING, stop → IDLE). No scrollback or transcript guessing. Restart each `agent` session once after installing NotchTerm so it loads ~/.cursor/hooks.json. Also tracks git clone/fetch/pull and npm/pnpm/yarn/bun install|build|test.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    Text("Grant Automation access for iTerm so NotchTerm can read tab names and Jump to iTerm. Agent running state does not use scrollback.")
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
        .frame(minWidth: 460, minHeight: 400)
    }

    private var displayBinding: Binding<UInt32?> {
        Binding(
            get: { model.settings.targetDisplayID },
            set: { model.settings.targetDisplayID = $0 }
        )
    }
}
