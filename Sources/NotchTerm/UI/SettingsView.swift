import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var screenManager: ScreenManager

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .environmentObject(model)
                .environmentObject(screenManager)
                .tabItem { Label("通用", systemImage: "gearshape") }

            StockSettingsTab()
                .environmentObject(model)
                .tabItem { Label("股票", systemImage: "chart.line.uptrend.xyaxis") }
        }
        .frame(minWidth: 540, minHeight: 520)
        .padding(.top, 8)
    }
}

// MARK: - 通用

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var screenManager: ScreenManager

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时启动", isOn: $model.settings.launchAtLogin)
                Toggle("任务完成时通知", isOn: $model.settings.notifyOnComplete)
                Toggle("在全屏应用上方显示", isOn: $model.settings.showOnFullscreen)
                Text("开启后，其他应用全屏（如视频、Keynote）时刘海仍可见；关闭则全屏期间隐藏。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("显示") {
                Picker("目标显示器", selection: displayBinding) {
                    Text("默认").tag(UInt32?.none)
                    ForEach(screenManager.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                HStack {
                    Text("垂直偏移")
                    Slider(value: $model.settings.verticalOffset, in: 0...40, step: 1)
                    Text("\(Int(model.settings.verticalOffset))")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }

            Section("权限") {
                Text("请授予 iTerm 的自动化权限，以便读取标签名并「跳转到 iTerm」。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("打开自动化设置") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private var displayBinding: Binding<UInt32?> {
        Binding(
            get: { model.settings.targetDisplayID },
            set: { model.settings.targetDisplayID = $0 }
        )
    }
}

// MARK: - 股票

private struct StockSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var stockStore = StockStore.shared

    @State private var searchText = ""
    @State private var searchResults: [SuggestItem] = []
    @State private var searchStatus = ""
    @State private var searchWorkItem: DispatchWorkItem?
    /// 行情预取完成后递增，驱动搜索结果行刷新现价。
    @State private var quoteEpoch = 0

    var body: some View {
        Form {
            Section {
                Toggle("启用股票监视", isOn: $model.settings.stockWatcherEnabled)
            }

            if model.settings.stockWatcherEnabled {
                Section("刷新") {
                    Picker("行情刷新间隔", selection: $model.settings.stockRefreshIntervalSeconds) {
                        ForEach(StockRefreshSettings.options, id: \.self) { seconds in
                            Text("\(Int(seconds)) 秒").tag(seconds)
                        }
                    }
                    Picker("菜单栏轮播间隔", selection: $model.settings.stockCarouselIntervalSeconds) {
                        ForEach(StockCarouselSettings.options, id: \.self) { seconds in
                            Text("\(Int(seconds)) 秒").tag(seconds)
                        }
                    }
                    Text("勾选「显示到菜单栏」的股票会出现在菜单栏标题（交易时段轮播刷新；非交易时段显示已缓存价格）。弹出面板始终列出全部自选股。涨跌幅相对昨收超过阈值时在刘海提醒。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("添加股票") {
                    QuietSearchField(
                        text: $searchText,
                        placeholder: "搜索代码或名称，如 600000 / 天融信"
                    )
                    .onChange(of: searchText) { _ in scheduleSearch() }

                    if !searchStatus.isEmpty {
                        Text(searchStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if !searchResults.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(searchResults.prefix(8)) { item in
                                Button {
                                    addSuggest(item)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(displayName(for: item))
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(.primary)
                                            Text(item.code.uppercased())
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if let priceText = previewPrice(for: item.code) {
                                            Text(priceText.text)
                                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(priceText.color)
                                        }
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .id(quoteEpoch)
                    }
                }

                Section("自选股") {
                    if stockStore.entries.isEmpty {
                        Text("暂无自选股，请先搜索添加")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(stockStore.entries) { entry in
                            StockEntrySettingsRow(symbol: entry.symbol)
                        }
                    }
                }
            } else {
                Section {
                    Text("开启后可添加自选股，并在交易时段于菜单栏显示行情。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private func scheduleSearch() {
        searchWorkItem?.cancel()
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchResults = []
            searchStatus = ""
            return
        }
        let work = DispatchWorkItem { runSearch(keyword) }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func displayName(for item: SuggestItem) -> String {
        if item.name.containsCJK { return item.name }
        if let ticker = QuoteService.shared.ticker(for: item.code), ticker.name.containsCJK {
            return ticker.name
        }
        return item.code.uppercased()
    }

    private func previewPrice(for code: String) -> (text: String, color: Color)? {
        _ = quoteEpoch
        let key = code.lowercased()
        guard let ticker = QuoteService.shared.ticker(for: key), ticker.price > 0 else { return nil }
        return (String(format: "%.2f", ticker.price), StockTheme.color(isUp: ticker.isUp))
    }

    private func runSearch(_ keyword: String) {
        searchStatus = "搜索中…"
        StockAPIService.shared.searchSuggest(keyword: keyword) { result in
            let current = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current == keyword else { return }

            switch result {
            case .success(let items):
                self.searchResults = items
                self.searchStatus = items.isEmpty ? "无匹配结果" : "共 \(items.count) 条"
                // 只预取界面展示的前 8 条，避免全量 suggest 浪费流量。
                self.prefetchQuotes(for: Array(items.prefix(8)), expectedKeyword: keyword)
            case .failure:
                self.searchStatus = "搜索失败，请检查网络"
            }
        }
    }

    private func prefetchQuotes(for items: [SuggestItem], expectedKeyword: String) {
        let symbols = Array(Set(items.map { $0.code.lowercased() })).sorted()
        guard !symbols.isEmpty else { return }
        StockAPIService.shared.fetchSnapshot(symbols: symbols) { result in
            let current = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current == expectedKeyword else { return }

            switch result {
            case .success(let tickers):
                QuoteService.shared.ingest(tickers)
                let map = Dictionary(
                    uniqueKeysWithValues: tickers.map { ($0.symbol.lowercased(), $0.name) }
                )
                self.searchResults = self.searchResults.map { item in
                    let key = item.code.lowercased()
                    guard let real = map[key], real.containsCJK else { return item }
                    return SuggestItem(code: item.code, name: real)
                }
                self.quoteEpoch &+= 1
                if tickers.isEmpty, !self.searchResults.isEmpty {
                    self.searchStatus = "共 \(self.searchResults.count) 条（行情暂无）"
                }
            case .failure:
                if !self.searchResults.isEmpty {
                    self.searchStatus = "共 \(self.searchResults.count) 条（行情拉取失败，可重试搜索）"
                }
            }
        }
    }

    private func addSuggest(_ item: SuggestItem) {
        let name = displayName(for: item)
        stockStore.add(
            StockEntry(
                symbol: item.code.lowercased(),
                name: name,
                showInMenuBar: true,
                alertThresholdPercent: 5
            )
        )
        NSApp.keyWindow?.makeFirstResponder(nil)
        searchText = ""
        searchResults = []
        searchStatus = "已添加 \(name)"
        model.stockWatcher.applySettings(
            enabled: model.settings.stockWatcherEnabled,
            refreshInterval: model.settings.stockRefreshIntervalSeconds,
            carouselInterval: model.settings.stockCarouselIntervalSeconds
        )
        // 添加后立刻再拉一次，确保面板/菜单栏有价。
        QuoteService.shared.refreshNow()
    }
}

private struct StockEntrySettingsRow: View {
    let symbol: String
    @ObservedObject private var stockStore = StockStore.shared

    private var entry: StockEntry? {
        stockStore.entries.first { $0.symbol == symbol }
    }

    var body: some View {
        if let entry {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name.containsCJK ? entry.name : entry.symbol.uppercased())
                            .font(.system(size: 13, weight: .semibold))
                        Text(entry.symbol.uppercased())
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        stockStore.remove(symbol: entry.symbol)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("移除")
                }

                Toggle(
                    "显示到菜单栏",
                    isOn: Binding(
                        get: { entry.showInMenuBar },
                        set: { stockStore.setShowInMenuBar(symbol: entry.symbol, enabled: $0) }
                    )
                )

                HStack {
                    Text("提醒阈值")
                    Slider(
                        value: Binding(
                            get: { entry.alertThresholdPercent },
                            set: { stockStore.setAlertThreshold(symbol: entry.symbol, percent: $0) }
                        ),
                        in: 0.5...20,
                        step: 0.5
                    )
                    Text(String(format: "%.1f%%", entry.alertThresholdPercent))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
