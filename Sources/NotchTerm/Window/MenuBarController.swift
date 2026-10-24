import AppKit
import Combine

/// 菜单栏：NSStatusItem + 系统 NSMenu（与 Calendar 相同路径：系统负责圆角与悬停）。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let statusMenu = NSMenu()
    private var stockTableView: MenuBarStockTableView?
    private var cancellables = Set<AnyCancellable>()
    private var cachedTask: TerminalTask?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusMenu.delegate = self
        statusItem.menu = statusMenu
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
        }

        bindModel()
        refreshStatusItem()
        rebuildMenu()
    }

    // MARK: - Bindings

    private func bindModel() {
        model.stockWatcher.$menuBarTitleImage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)

        model.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        if let image = model.stockWatcher.menuBarTitleImage {
            button.image = image
            button.image?.isTemplate = false
            button.title = ""
            statusItem.length = max(image.size.width + 8, 24)
        } else {
            button.image = NotchTermApp.trayIconImage
            button.image?.isTemplate = true
            button.title = ""
            statusItem.length = NSStatusItem.squareLength
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        AppDelegate.shared?.setMenuBarMenuOpen(true)
        rebuildMenu()
        stockTableView?.reloadQuotes()
        // 打开菜单时补一次行情，冷启动后首次展开也能看到价。
        if model.settings.stockWatcherEnabled {
            QuoteService.shared.refreshNow()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        AppDelegate.shared?.setMenuBarMenuOpen(false)
    }

    func dismissPanel() {
        statusMenu.cancelTracking()
    }

    // MARK: - Build menu

    private func rebuildMenu() {
        statusMenu.removeAllItems()
        stockTableView = nil
        cachedTask = model.selectedTask

        if model.settings.stockWatcherEnabled, !StockStore.shared.entries.isEmpty {
            let table = MenuBarStockTableView(stockWatcher: model.stockWatcher)
            stockTableView = table
            let item = NSMenuItem()
            // 禁用整块选中高亮；行内悬停由 AppKit tracking 自己画（同 Calendar 格子）。
            item.isEnabled = false
            item.view = table
            statusMenu.addItem(item)
            statusMenu.addItem(.separator())
        }

        if let task = cachedTask {
            let expand = NSMenuItem(
                title: "\(task.title) · \(task.state.label)",
                action: #selector(expandSelectedTask),
                keyEquivalent: ""
            )
            expand.target = self
            expand.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            statusMenu.addItem(expand)

            let focus = NSMenuItem(
                title: "跳转到 iTerm",
                action: #selector(focusSelectedTask),
                keyEquivalent: ""
            )
            focus.target = self
            focus.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            statusMenu.addItem(focus)
            statusMenu.addItem(.separator())
        }

        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        statusMenu.addItem(settings)

        let quit = NSMenuItem(
            title: "退出 NotchTerm",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        statusMenu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func expandSelectedTask() {
        model.expand(pin: true)
    }

    @objc private func focusSelectedTask() {
        guard let task = cachedTask else { return }
        model.focusTaskInITerm(task)
    }

    @objc private func openSettings() {
        AppDelegate.shared?.openSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
