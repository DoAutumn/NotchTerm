import AppKit
import Combine
import Foundation
import SwiftUI

/// 股票监视：行情订阅、菜单栏轮播、涨跌幅刘海提醒（滞回再武装）。
@MainActor
final class StockWatcherService: ObservableObject {
    static let quoteSubscriberID = "notchterm.stockWatcher"

    @Published private(set) var isEnabled = false
    @Published private(set) var tickers: [String: Ticker] = [:]
    @Published private(set) var pendingAlerts: [StockAlertItem] = []
    /// 有勾选菜单栏股票时的轮播文案；否则为 nil（只显示图标）。
    /// 使用 NSAttributedString + 非模板位图显示，避免 MenuBarExtra 把 SwiftUI 颜色冲成系统色。
    @Published private(set) var menuBarTitleImage: NSImage?
    @Published private(set) var isTradingHours = false

    private var carouselEntries: [StockEntry] = []
    private var carouselIndex = 0
    private var carouselTimer: Timer?
    /// 当前 timer 使用的间隔；用于避免行情刷新时误重置轮播。
    private var runningCarouselInterval: TimeInterval?
    private var quoteObserver: NSObjectProtocol?
    private var storeObserver: NSObjectProtocol?
    private var carouselInterval: TimeInterval = StockCarouselSettings.defaultInterval
    /// 轮播各股标题的最大宽度，避免切换股票或涨跌数字变化时菜单栏来回伸缩。
    private var stableMenuBarWidth: CGFloat = 0
    /// 上次渲染的菜单栏文案签名，相同时跳过重绘。
    private var lastMenuBarSignature = ""
    /// 确认后闩锁：回到 |涨跌幅| ≤ 阈值−1 才再武装。
    private var disarmedSymbols: Set<String> = []
    private let hysteresisPoints: Double = 1.0

    var hasPendingAlert: Bool { !pendingAlerts.isEmpty }

    var alertSummary: String {
        pendingAlerts.map { item in
            let arrow = item.isUp ? "↑" : "↓"
            return "\(item.name) \(arrow)\(String(format: "%.2f", abs(item.changePercent)))%"
        }.joined(separator: "  ")
    }

    init() {
        quoteObserver = NotificationCenter.default.addObserver(
            forName: .quoteDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleQuotesUpdated() }
        }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .stockStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resyncSubscriptions() }
        }
    }

    deinit {
        carouselTimer?.invalidate()
        if let quoteObserver { NotificationCenter.default.removeObserver(quoteObserver) }
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    func applySettings(
        enabled: Bool,
        refreshInterval: Double,
        carouselInterval: Double
    ) {
        let refresh = StockRefreshSettings.options.contains(refreshInterval)
            ? refreshInterval
            : StockRefreshSettings.defaultInterval
        let carousel = StockCarouselSettings.options.contains(carouselInterval)
            ? carouselInterval
            : StockCarouselSettings.defaultInterval

        self.carouselInterval = carousel
        QuoteService.shared.setRefreshInterval(refresh)

        let wasEnabled = isEnabled
        isEnabled = enabled
        if enabled {
            resyncSubscriptions()
        } else if wasEnabled {
            stop()
        }
        refreshTradingState()
        updateMenuBarDisplay(animated: false)
        evaluateAlerts()
    }

    func confirmAlerts() {
        for item in pendingAlerts {
            disarmedSymbols.insert(item.symbol.lowercased())
        }
        pendingAlerts = []
    }

    func ticker(for symbol: String) -> Ticker? {
        tickers[symbol.lowercased()] ?? QuoteService.shared.ticker(for: symbol)
    }

    // MARK: - Private

    private func stop() {
        QuoteService.shared.unsubscribe(id: Self.quoteSubscriberID)
        carouselTimer?.invalidate()
        carouselTimer = nil
        runningCarouselInterval = nil
        carouselEntries = []
        carouselIndex = 0
        tickers = [:]
        pendingAlerts = []
        menuBarTitleImage = nil
        lastMenuBarSignature = ""
        stableMenuBarWidth = 0
        isTradingHours = false
    }

    private func resyncSubscriptions() {
        guard isEnabled else {
            stop()
            return
        }
        let entries = StockStore.shared.entries
        QuoteService.shared.subscribe(
            id: Self.quoteSubscriberID,
            symbols: entries.map(\.symbol)
        )
        reloadCarouselEntries()
        refreshTradingState()
        handleQuotesUpdated()
    }

    private func reloadCarouselEntries() {
        carouselEntries = StockStore.shared.entries.filter(\.showInMenuBar)
        if carouselIndex >= carouselEntries.count {
            carouselIndex = 0
        }
        recalculateStableMenuBarWidth()
        restartCarouselIfNeeded()
    }

    private func recalculateStableMenuBarWidth() {
        let widths = carouselEntries.map {
            makeMenuBarTitle(entry: $0, ticker: ticker(for: $0.symbol)).size().width
        }
        stableMenuBarWidth = ceil((widths.max() ?? 0) + 4)
    }

    private func handleQuotesUpdated() {
        let wasTrading = isTradingHours
        let next = QuoteService.shared.tickers
        if next != tickers {
            tickers = next
        }
        refreshTradingState()
        updateMenuBarDisplay(animated: false)
        evaluateAlerts()
        // 仅开盘/收盘切换时启停轮播；绝不能每轮行情都 invalidate，否则轮播永远走不到下一只。
        if wasTrading != isTradingHours {
            restartCarouselIfNeeded()
        }
    }

    private func refreshTradingState() {
        isTradingHours = StockRefreshSettings.isTradingHours()
    }

    private func evaluateAlerts() {
        guard isEnabled, isTradingHours else {
            // 收盘后保留未确认提醒，避免盘中弹出却因收盘被吞掉。
            if !isEnabled { pendingAlerts = [] }
            return
        }

        var nextPending = pendingAlerts
        let pendingSymbols = Set(nextPending.map { $0.symbol.lowercased() })

        for entry in StockStore.shared.entries {
            let key = entry.symbol.lowercased()
            guard let ticker = ticker(for: entry.symbol), ticker.price > 0 else { continue }
            let pct = ticker.changePercent
            let absPct = abs(pct)
            let threshold = entry.alertThresholdPercent
            let rearmBelow = max(0, threshold - hysteresisPoints)

            if disarmedSymbols.contains(key) {
                if absPct <= rearmBelow {
                    disarmedSymbols.remove(key)
                } else {
                    continue
                }
            }

            if pendingSymbols.contains(key) {
                if let index = nextPending.firstIndex(where: { $0.symbol.lowercased() == key }) {
                    nextPending[index] = StockAlertItem(
                        symbol: entry.symbol,
                        name: displayName(entry: entry, ticker: ticker),
                        changePercent: pct,
                        price: ticker.price
                    )
                }
                continue
            }

            if absPct >= threshold {
                nextPending.append(
                    StockAlertItem(
                        symbol: entry.symbol,
                        name: displayName(entry: entry, ticker: ticker),
                        changePercent: pct,
                        price: ticker.price
                    )
                )
            }
        }

        // Drop alerts for removed stocks.
        let live = Set(StockStore.shared.entries.map { $0.symbol.lowercased() })
        nextPending.removeAll { !live.contains($0.symbol.lowercased()) }

        if nextPending != pendingAlerts {
            pendingAlerts = nextPending
        }
    }

    private func updateMenuBarDisplay(animated: Bool) {
        // 仅「显示到菜单栏」的股票上菜单栏；非交易时段用已缓存的昨收/现价，方便开关可验证。
        guard isEnabled,
              !carouselEntries.isEmpty,
              carouselIndex < carouselEntries.count
        else {
            if menuBarTitleImage != nil {
                menuBarTitleImage = nil
            }
            lastMenuBarSignature = ""
            carouselTimer?.invalidate()
            carouselTimer = nil
            runningCarouselInterval = nil
            return
        }

        let entry = carouselEntries[carouselIndex]
        let ticker = ticker(for: entry.symbol)
        let attributed = makeMenuBarTitle(entry: entry, ticker: ticker)
        // 行情跳动时宽度可能略增，只升不降，避免菜单栏抖动。
        let nextWidth = max(stableMenuBarWidth, ceil(attributed.size().width + 4))
        let signature = "\(entry.symbol)|\(attributed.string)|\(nextWidth)"
        guard signature != lastMenuBarSignature else { return }
        lastMenuBarSignature = signature
        stableMenuBarWidth = nextWidth
        menuBarTitleImage = Self.renderStatusItemImage(attributed, minWidth: stableMenuBarWidth)
        _ = animated
    }

    private func restartCarouselIfNeeded() {
        let shouldRun = isEnabled && isTradingHours && carouselEntries.count >= 2
        if !shouldRun {
            carouselTimer?.invalidate()
            carouselTimer = nil
            runningCarouselInterval = nil
            return
        }
        // 已在跑且间隔未变：不要重置，否则会被行情刷新节奏「吃掉」轮播。
        if carouselTimer != nil, runningCarouselInterval == carouselInterval {
            return
        }
        carouselTimer?.invalidate()
        carouselTimer = Timer.scheduledTimer(
            withTimeInterval: carouselInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.carouselEntries.count >= 2 else { return }
                self.carouselIndex = (self.carouselIndex + 1) % self.carouselEntries.count
                self.updateMenuBarDisplay(animated: true)
            }
        }
        runningCarouselInterval = carouselInterval
    }

    private func displayName(entry: StockEntry, ticker: Ticker?) -> String {
        if let name = ticker?.name, name.containsCJK { return name }
        if entry.name.containsCJK { return entry.name }
        return entry.symbol.uppercased()
    }

    private func makeMenuBarTitle(entry: StockEntry, ticker: Ticker?) -> NSAttributedString {
        let name = displayName(entry: entry, ticker: ticker)
        let priceStr: String
        let changeStr: String
        let isUp: Bool

        if let ticker, ticker.price > 0 {
            // 等宽数字 + 固定字段宽度，减少 1.10% / 14.10% 这类跳动。
            priceStr = String(format: "%7.2f", ticker.price)
            let arrow = ticker.isUp ? "↑" : "↓"
            // 不要用 String(format: "%@", Swift.String)——会坏指针崩溃。
            changeStr = arrow + String(format: "%6.2f%%", abs(ticker.changePercent))
            isUp = ticker.isUp
        } else {
            priceStr = String(repeating: " ", count: 5) + "--"
            changeStr = ""
            isUp = true
        }

        let accent = StockTheme.nsColor(isUp: isUp)
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let priceFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let result = NSMutableAttributedString()

        result.append(NSAttributedString(string: "\(name)  ", attributes: [
            .font: nameFont,
            .foregroundColor: NSColor.labelColor
        ]))
        result.append(NSAttributedString(string: priceStr, attributes: [
            .font: priceFont,
            .foregroundColor: changeStr.isEmpty ? NSColor.secondaryLabelColor : accent
        ]))
        if !changeStr.isEmpty {
            result.append(NSAttributedString(string: " \(changeStr)", attributes: [
                .font: priceFont,
                .foregroundColor: accent
            ]))
        }
        return result
    }

    /// 画成非模板图，菜单栏才能保留红涨绿跌；`minWidth` 用于稳住状态栏宽度。
    private static func renderStatusItemImage(
        _ attributed: NSAttributedString,
        minWidth: CGFloat
    ) -> NSImage {
        let size = attributed.size()
        let width = max(ceil(size.width) + 2, minWidth, 1)
        let height = max(ceil(size.height) + 2, 16)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let y = (height - size.height) / 2
        attributed.draw(at: NSPoint(x: 1, y: y))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
