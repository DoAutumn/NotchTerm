import Foundation

extension Notification.Name {
    static let quoteDidUpdate = Notification.Name("notchterm.quoteDidUpdate")
}

/// 全局行情：按订阅并集拉取。
/// 启用时立刻拉一次；交易时段内按间隔刷新；非交易时段不轮询刷新，只低频探测是否开盘。
@MainActor
final class QuoteService {
    static let shared = QuoteService()

    private(set) var tickers: [String: Ticker] = [:]

    private var subscriptions: [String: Set<String>] = [:]
    private var timer: Timer?
    private var isFetching = false
    private var needsRefresh = false
    private var refreshInterval: TimeInterval = StockRefreshSettings.defaultInterval
    /// 本次订阅周期内是否已在非交易时段拉过一次。
    private var fetchedOnceWhileClosed = false

    private init() {}

    func setRefreshInterval(_ interval: TimeInterval) {
        let next = StockRefreshSettings.options.contains(interval)
            ? interval
            : StockRefreshSettings.defaultInterval
        guard abs(next - refreshInterval) > 0.01 else { return }
        refreshInterval = next
        restartTimer()
    }

    func subscribe(id: String, symbols: [String]) {
        let normalized = Set(symbols.map { $0.lowercased() }.filter { !$0.isEmpty })
        let previous = subscriptions[id] ?? []
        let idChanged = previous != normalized

        let oldAll = Set(allSymbols)
        if normalized.isEmpty {
            subscriptions.removeValue(forKey: id)
        } else {
            subscriptions[id] = normalized
        }
        let newAll = Set(allSymbols)

        if oldAll != newAll {
            fetchedOnceWhileClosed = false
            restartTimer()
        }

        // 订阅变化时立刻拉一次（含非交易时段），保证面板能显示价格。
        if idChanged, !normalized.isEmpty {
            if !StockRefreshSettings.isTradingHours() {
                fetchedOnceWhileClosed = true
            }
            refreshNow()
        }
    }

    func unsubscribe(id: String) {
        subscribe(id: id, symbols: [])
    }

    func ticker(for symbol: String) -> Ticker? {
        tickers[symbol.lowercased()]
    }

    func refreshNow() {
        fetchSnapshot()
    }

    /// 把外部已拉到的快照写入缓存（搜索预取、手动补拉），并通知 UI。
    func ingest(_ list: [Ticker]) {
        guard !list.isEmpty else { return }
        var nameUpdates: [String: String] = [:]
        for ticker in list {
            tickers[ticker.symbol.lowercased()] = ticker
            if ticker.name.containsCJK {
                nameUpdates[ticker.symbol] = ticker.name
            }
        }
        StockStore.shared.updateNames(nameUpdates)
        NotificationCenter.default.post(name: .quoteDidUpdate, object: self)
    }

    private var allSymbols: [String] {
        Array(Set(subscriptions.values.flatMap { $0 })).sorted()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard !allSymbols.isEmpty else { return }
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        timer?.invalidate()
        guard !allSymbols.isEmpty else {
            timer = nil
            return
        }
        let interval = StockRefreshSettings.effectiveInterval(refreshInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if StockRefreshSettings.isTradingHours() {
                    self.fetchedOnceWhileClosed = false
                    self.fetchSnapshot()
                } else if !self.fetchedOnceWhileClosed {
                    // 非交易时段只拉一次；之后静默等待，开盘后下一拍走上面分支，勿发空 quoteDidUpdate。
                    self.fetchedOnceWhileClosed = true
                    self.fetchSnapshot()
                }
                self.scheduleNextTick()
            }
        }
    }

    private func fetchSnapshot() {
        let symbols = allSymbols
        guard !symbols.isEmpty else { return }
        if isFetching {
            needsRefresh = true
            return
        }
        isFetching = true
        StockAPIService.shared.fetchSnapshot(symbols: symbols) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isFetching = false

                if case .success(let list) = result {
                    var nameUpdates: [String: String] = [:]
                    for ticker in list {
                        self.tickers[ticker.symbol.lowercased()] = ticker
                        if ticker.name.containsCJK {
                            nameUpdates[ticker.symbol] = ticker.name
                        }
                    }
                    StockStore.shared.updateNames(nameUpdates)
                    NotificationCenter.default.post(name: .quoteDidUpdate, object: self)
                }

                if self.needsRefresh {
                    self.needsRefresh = false
                    self.fetchSnapshot()
                }
            }
        }
    }
}
