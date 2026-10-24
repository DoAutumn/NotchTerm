import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: NotchSettings {
        didSet {
            // Never mutate `settings` inside didSet (e.g. clampValues) — that
            // re-enters didSet recursively and crashes the settings window.
            guard !isApplyingSettings else { return }
            isApplyingSettings = true
            defer { isApplyingSettings = false }

            var next = settings
            next.clampValues()
            next.alwaysOnTop = true
            if next != settings {
                // Nested didSet is ignored via isApplyingSettings.
                settings = next
            }

            store.save(settings)
            onPanelConfigurationChanged?()
            adjustMonitorCadence()
            let stockChanged =
                oldValue.stockWatcherEnabled != settings.stockWatcherEnabled
                || oldValue.stockRefreshIntervalSeconds != settings.stockRefreshIntervalSeconds
                || oldValue.stockCarouselIntervalSeconds != settings.stockCarouselIntervalSeconds
            if stockChanged {
                applyStockWatcherSettings()
            }
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
    /// Drives the drop-in / tuck-away surface animation (window may stay up briefly).
    @Published private(set) var isSurfaceRevealed = false
    /// Physical notch on the target display, in points. Nil when that display has no notch.
    @Published private(set) var hardwareNotchSize: CGSize?
    @Published var statusMessage: String?

    let monitor = TerminalTaskMonitor()
    let nowPlaying = NowPlayingMonitor()
    let stockWatcher = StockWatcherService()

    var onPanelConfigurationChanged: (() -> Void)?
    /// Fired when the notch should appear/disappear (enabled ∧ has active content).
    var onVisibilityChanged: ((Bool) -> Void)?

    private let store = SettingsStore()
    private var collapseWorkItem: DispatchWorkItem?
    private var statusWorkItem: DispatchWorkItem?
    private var concealWorkItem: DispatchWorkItem?
    private var lastNotifiedCompletionID: UUID?
    private var monitorCancellable: AnyCancellable?
    private var nowPlayingCancellable: AnyCancellable?
    private var stockCancellable: AnyCancellable?
    private var userPinnedSelection = false
    private var isApplyingSettings = false
    private var lastPresentedNotch = false
    /// 避免行情 tick 在尺寸未变时反复 setFrame。
    private var lastPanelConfigSize: CGSize = .zero

    /// 股票提醒优先于任务 / DONE。
    var hasStockAlert: Bool { stockWatcher.hasPendingAlert }

    /// Tasks and the brief DONE banner. Music never outranks these.
    var hasTaskContent: Bool {
        !monitor.tasks.isEmpty || monitor.lastCompletion != nil
    }

    /// Compact strip: stock alert > tasks/DONE > music.
    var hasNotchContent: Bool {
        hasStockAlert || hasTaskContent || nowPlaying.showsInNotch
    }

    var currentSize: CGSize {
        switch mode {
        case .compact:
            return CGSize(width: compactWidthForContent, height: settings.compactHeight)
        case .expanded:
            return CGSize(width: settings.expandedWidth, height: settings.expandedHeight)
        }
    }

    /// 多只股票提醒拼一行时可加宽刘海；短文案也不小于用户配置的 compactWidth。
    private var compactWidthForContent: CGFloat {
        guard hasStockAlert else { return settings.compactWidth }
        let summary = stockWatcher.alertSummary
        let estimated = 120.0 + Double(summary.count) * 7.5
        let needed = CGFloat(estimated.clamped(to: NotchSettings.compactWidthRange))
        return max(settings.compactWidth, needed)
    }

    var selectedTask: TerminalTask? {
        let tasks = monitor.tasks
        if let selectedTaskID, let match = tasks.first(where: { $0.id == selectedTaskID }) {
            return match
        }
        return preferredTask(from: tasks)
    }

    var overflowTasks: [TerminalTask] {
        guard let selected = selectedTask else { return monitor.tasks }
        return monitor.tasks.filter { $0.id != selected.id }
    }

    init() {
        var loaded = store.load()
        if loaded.expandedHeight != 220 {
            loaded.expandedHeight = 220
            store.save(loaded)
        }
        settings = loaded
        monitorCancellable = monitor.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            Task { @MainActor in
                self.handleCompletionSideEffects()
                self.syncNotchPresentation()
                self.adjustMonitorCadence()
            }
        }
        nowPlayingCancellable = nowPlaying.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            Task { @MainActor in
                self.syncNotchPresentation()
            }
        }
        stockCancellable = stockWatcher.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            Task { @MainActor in
                // 只走 sync：尺寸真变了才 notify panel（提醒加宽）；勿每 tick 双刷 setFrame。
                self.syncNotchPresentation()
            }
        }
        monitor.start(interval: settings.pollIntervalSeconds)
        nowPlaying.start()
        applyStockWatcherSettings()
        applyLaunchAtLoginIfNeeded(oldValue: !settings.launchAtLogin)
    }

    func updateHardwareNotchSize(_ size: CGSize?) {
        guard hardwareNotchSize != size else { return }
        hardwareNotchSize = size
    }

    func setVisible(_ visible: Bool) {
        settings.isEnabled = visible
        syncNotchPresentation()
    }

    /// Show notch only while there is something to display; otherwise tuck away.
    func syncNotchPresentation() {
        let present = settings.isEnabled && hasNotchContent
        // 股票提醒优先：有提醒时强制收起展开面板；无任务时也不保持展开。
        if hasStockAlert || !hasTaskContent {
            if mode == .expanded || isPinned {
                collapse(force: true)
            }
        }
        // Wait until the window controller has wired the callback (avoids
        // swallowing the first "show" during AppModel.init).
        guard onVisibilityChanged != nil else { return }

        // Recover stuck state: logic thinks we're shown but the surface never revealed.
        if present, lastPresentedNotch, !isSurfaceRevealed {
            concealWorkItem?.cancel()
            concealWorkItem = nil
            onVisibilityChanged?(true)
            withAnimation(revealAnimation) {
                isSurfaceRevealed = true
            }
            return
        }

        guard present != lastPresentedNotch else {
            // 提醒文案变长时仍要刷新面板宽度；尺寸不变则跳过。
            if present { notifyPanelConfigurationIfSizeChanged() }
            return
        }
        lastPresentedNotch = present

        if present {
            concealWorkItem?.cancel()
            concealWorkItem = nil
            lastPanelConfigSize = currentSize
            // Mount the panel first (hidden surface), then drop it in next frame.
            onVisibilityChanged?(true)
            isSurfaceRevealed = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastPresentedNotch else { return }
                withAnimation(self.revealAnimation) {
                    self.isSurfaceRevealed = true
                }
            }
        } else {
            withAnimation(concealAnimation) {
                isSurfaceRevealed = false
            }
            concealWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.lastPresentedNotch else { return }
                self.onVisibilityChanged?(false)
            }
            concealWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + concealHold, execute: work)
        }
    }

    private var revealAnimation: Animation {
        hardwareNotchSize == nil ? NotchMotion.reveal : NotchMotion.notchReveal
    }

    private var concealAnimation: Animation {
        hardwareNotchSize == nil ? NotchMotion.conceal : NotchMotion.notchConceal
    }

    private var concealHold: TimeInterval {
        hardwareNotchSize == nil ? NotchMotion.concealHold : NotchMotion.notchConcealHold
    }

    func hoverChanged(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        // 股票提醒 / 音乐仅 compact；展开面板只给终端任务。
        guard hasTaskContent, !hasStockAlert else { return }
        if hovering {
            cancelCollapse()
            if mode == .compact {
                withAnimation(NotchMotion.spring) {
                    isPinned = false
                    mode = .expanded
                }
            }
        } else if !isPinned {
            scheduleCollapse()
        }
    }

    func notchClicked() {
        if hasStockAlert {
            stockWatcher.confirmAlerts()
            syncNotchPresentation()
            // 确认时鼠标可能仍在刘海上，isHovering 已是 true，需补一次展开判定。
            reapplyHoverExpandIfNeeded()
            return
        }
        guard hasTaskContent else { return }
        withAnimation(NotchMotion.spring) {
            if mode == .expanded, isPinned {
                isPinned = false
                mode = .compact
            } else {
                cancelCollapse()
                isPinned = true
                mode = .expanded
            }
        }
    }

    func confirmStockAlerts() {
        stockWatcher.confirmAlerts()
        syncNotchPresentation()
        reapplyHoverExpandIfNeeded()
    }

    /// 提醒期间 hoverChanged(true) 会 early-return；确认后若指针仍在上面，补跑悬停展开。
    private func reapplyHoverExpandIfNeeded() {
        guard isHovering, hasTaskContent, !hasStockAlert else { return }
        cancelCollapse()
        guard mode == .compact else { return }
        withAnimation(NotchMotion.spring) {
            isPinned = false
            mode = .expanded
        }
    }

    func expand(pin: Bool = false) {
        guard hasTaskContent, !hasStockAlert else { return }
        cancelCollapse()
        withAnimation(NotchMotion.spring) {
            isPinned = pin || isPinned
            mode = .expanded
        }
    }

    func collapse(force: Bool = false) {
        cancelCollapse()
        if !force, isPinned { return }
        withAnimation(NotchMotion.spring) {
            isPinned = false
            mode = .compact
        }
    }

    func closeFromOutsideClick() {
        collapse(force: true)
    }

    func selectTask(_ id: String) {
        selectedTaskID = id
        userPinnedSelection = true
        expand(pin: true)
    }

    func focusSelectedTaskInITerm() {
        guard let task = selectedTask else {
            showMessage("当前没有任务")
            return
        }
        focusTaskInITerm(task)
    }

    func focusTaskInITerm(_ task: TerminalTask) {
        focusTTYInITerm(task.tty)
    }

    /// Jump from the compact DONE strip (within the ~4.5s banner window).
    func focusCompletionInITerm(_ event: TaskCompletionEvent) {
        focusTTYInITerm(event.tty)
        monitor.clearCompletionBanner()
        syncNotchPresentation()
    }

    private func focusTTYInITerm(_ tty: String?) {
        guard let tty else {
            showMessage("该任务没有可用的 iTerm TTY")
            return
        }
        // ShellCommand blocks; never run it on the main actor.
        Task { [weak self] in
            let ok = await Task.detached(priority: .userInitiated) {
                ITermController.activateSession(tty: tty)
            }.value
            await MainActor.run {
                guard let self else { return }
                if ok {
                    self.showMessage("已切换到 iTerm")
                } else {
                    self.showMessage("无法聚焦 iTerm（请检查自动化权限）")
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
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

    private func applyStockWatcherSettings() {
        stockWatcher.applySettings(
            enabled: settings.stockWatcherEnabled,
            refreshInterval: settings.stockRefreshIntervalSeconds,
            carouselInterval: settings.stockCarouselIntervalSeconds
        )
    }

    private func notifyPanelConfigurationIfSizeChanged() {
        let size = currentSize
        guard size != lastPanelConfigSize else { return }
        lastPanelConfigSize = size
        onPanelConfigurationChanged?()
    }

    /// Idle: keep a short poll as a safety net; hook-dir watcher handles instant wake.
    private func adjustMonitorCadence() {
        let base = settings.pollIntervalSeconds
        let interval = hasNotchContent ? base : min(base, 0.8)
        monitor.setInterval(interval)
    }

    private func handleCompletionSideEffects() {
        let tasks = monitor.tasks
        let ids = Set(tasks.map(\.id))

        if let selectedTaskID, !ids.contains(selectedTaskID) {
            self.selectedTaskID = preferredTask(from: tasks)?.id
            userPinnedSelection = false
        } else if selectedTaskID == nil {
            selectedTaskID = preferredTask(from: tasks)?.id
        } else if !userPinnedSelection, mode == .compact {
            // Only auto-follow while compact — never reshuffle tabs while expanded.
            if let preferred = preferredTask(from: tasks) {
                selectedTaskID = preferred.id
            }
        }

        guard let event = monitor.lastCompletion else { return }
        if lastNotifiedCompletionID == event.id { return }
        lastNotifiedCompletionID = event.id

        // Don't steal tab focus while the user is browsing the expanded panel.
        if mode == .compact, tasks.contains(where: { $0.id == event.taskID }) {
            selectedTaskID = event.taskID
            userPinnedSelection = false
        }

        if settings.notifyOnComplete {
            NotificationService.shared.taskCompleted(
                title: "\(event.kind.title) 已完成",
                body: "\(event.title) — \(event.subtitle)"
            )
        }
    }

    private func preferredTask(from tasks: [TerminalTask]) -> TerminalTask? {
        // Task list is oldest→newest; prefer the latest RUNNING.
        tasks.last(where: { $0.state == .running }) ?? tasks.last ?? tasks.first
    }

    private func scheduleCollapse() {
        cancelCollapse()
        let work = DispatchWorkItem { [weak self] in
            self?.collapse()
        }
        collapseWorkItem = work
        // Prefer a short leave delay so collapse feels responsive.
        let delay = min(settings.collapseDelay, 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
            let fallback = LaunchAtLoginService.isEnabled
            if settings.launchAtLogin != fallback {
                var next = settings
                next.launchAtLogin = fallback
                settings = next
                store.save(settings)
            }
            showMessage("无法更新登录项")
        }
    }
}
