import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: NotchSettings {
        didSet {
            settings.clampValues()
            store.save(settings)
            onPanelConfigurationChanged?()
            monitor.setInterval(settings.pollIntervalSeconds)
            applyLaunchAtLoginIfNeeded(oldValue: oldValue.launchAtLogin)
            if oldValue.notifyOnComplete != settings.notifyOnComplete, settings.notifyOnComplete {
                NotificationService.shared.requestAuthorizationIfNeeded()
            }
        }
    }

    @Published private(set) var mode: NotchMode = .compact
    @Published private(set) var isPinned = false
    @Published private(set) var isHovering = false
    @Published private(set) var selectedTaskID: String?
    @Published var statusMessage: String?

    let monitor = TerminalTaskMonitor()

    var onPanelConfigurationChanged: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    private let store = SettingsStore()
    private var collapseWorkItem: DispatchWorkItem?
    private var statusWorkItem: DispatchWorkItem?
    private var completionWatchTimer: Timer?
    private var lastNotifiedCompletionID: UUID?

    var currentSize: CGSize {
        switch mode {
        case .compact:
            return CGSize(width: settings.compactWidth, height: settings.compactHeight)
        case .expanded:
            return CGSize(width: settings.expandedWidth, height: settings.expandedHeight)
        }
    }

    var selectedTask: TerminalTask? {
        let tasks = monitor.tasks
        if let selectedTaskID, let match = tasks.first(where: { $0.id == selectedTaskID }) {
            return match
        }
        return tasks.first
    }

    var overflowTasks: [TerminalTask] {
        guard let selected = selectedTask else { return monitor.tasks }
        return monitor.tasks.filter { $0.id != selected.id }
    }

    init() {
        settings = store.load()
        monitor.start(interval: settings.pollIntervalSeconds)
        observeCompletions()
        applyLaunchAtLoginIfNeeded(oldValue: !settings.launchAtLogin)
    }

    func setVisible(_ visible: Bool) {
        settings.isEnabled = visible
        onVisibilityChanged?(visible)
    }

    func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            cancelCollapse()
            if mode == .compact { expand() }
        } else if !isPinned {
            scheduleCollapse()
        }
    }

    func notchClicked() {
        if mode == .expanded, isPinned {
            collapse(force: true)
        } else {
            expand(pin: true)
        }
    }

    func expand(pin: Bool = false) {
        cancelCollapse()
        isPinned = pin || isPinned
        mode = .expanded
        onPanelConfigurationChanged?()
    }

    func collapse(force: Bool = false) {
        cancelCollapse()
        if !force, isPinned { return }
        isPinned = false
        mode = .compact
        onPanelConfigurationChanged?()
    }

    func closeFromOutsideClick() {
        collapse(force: true)
    }

    func selectTask(_ id: String) {
        selectedTaskID = id
        expand(pin: true)
    }

    func focusSelectedTaskInITerm() {
        guard let task = selectedTask else {
            showMessage("No active task")
            return
        }
        focusTaskInITerm(task)
    }

    func focusTaskInITerm(_ task: TerminalTask) {
        guard let tty = task.tty else {
            showMessage("No iTerm TTY for this task")
            return
        }
        if ITermController.activateSession(tty: tty) {
            showMessage("Focused iTerm")
        } else {
            showMessage("Could not focus iTerm (check Automation permission)")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    }

    func showMessage(_ message: String) {
        statusWorkItem?.cancel()
        statusMessage = message
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        statusWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    func resetSettings() {
        settings = .default
    }

    private func observeCompletions() {
        completionWatchTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleCompletionSideEffects() }
        }
        timer.tolerance = 0.1
        completionWatchTimer = timer
    }

    private func handleCompletionSideEffects() {
        // Keep selection valid
        let ids = Set(monitor.tasks.map(\.id))
        if let selectedTaskID, !ids.contains(selectedTaskID) {
            self.selectedTaskID = monitor.tasks.first?.id
        } else if selectedTaskID == nil {
            selectedTaskID = monitor.tasks.first?.id
        }

        guard let event = monitor.lastCompletion else { return }
        if lastNotifiedCompletionID == event.id { return }
        lastNotifiedCompletionID = event.id

        // Prefer selecting the task that just finished if it still exists (idle agent)
        if monitor.tasks.contains(where: { $0.id == event.taskID }) {
            selectedTaskID = event.taskID
        }

        if settings.notifyOnComplete {
            NotificationService.shared.taskCompleted(
                title: "\(event.kind.title) finished",
                body: "\(event.title) — \(event.subtitle)"
            )
        }
    }

    private func scheduleCollapse() {
        cancelCollapse()
        let work = DispatchWorkItem { [weak self] in
            self?.collapse()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.collapseDelay, execute: work)
    }

    private func cancelCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    private func applyLaunchAtLoginIfNeeded(oldValue: Bool) {
        guard oldValue != settings.launchAtLogin else { return }
        do {
            try LaunchAtLoginService.setEnabled(settings.launchAtLogin)
        } catch {
            settings.launchAtLogin = LaunchAtLoginService.isEnabled
            showMessage("Could not update Login Items")
        }
    }
}
