import AppKit

/// 菜单栏 NSMenu 内的自选行情表（纯 AppKit，对齐 Calendar 自定义 menu item view）。
@MainActor
final class MenuBarStockTableView: NSView {
    private let stockWatcher: StockWatcherService
    private let header = MenuBarStockHeaderView()
    private var rows: [MenuBarStockRowView] = []
    private var quoteObserver: NSObjectProtocol?

    private let tableWidth: CGFloat = 380
    private let headerHeight: CGFloat = 22
    private let rowHeight: CGFloat = 36
    private let bottomPad: CGFloat = 4

    init(stockWatcher: StockWatcherService) {
        self.stockWatcher = stockWatcher
        super.init(frame: .zero)
        addSubview(header)
        quoteObserver = NotificationCenter.default.addObserver(
            forName: .quoteDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadQuotes() }
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let quoteObserver {
            NotificationCenter.default.removeObserver(quoteObserver)
        }
    }

    func reload() {
        rows.forEach { $0.removeFromSuperview() }
        rows = StockStore.shared.entries.map { entry in
            let row = MenuBarStockRowView()
            row.configure(entry: entry, ticker: stockWatcher.ticker(for: entry.symbol))
            addSubview(row)
            return row
        }
        let height = headerHeight + CGFloat(rows.count) * rowHeight + bottomPad
        frame = NSRect(x: 0, y: 0, width: tableWidth, height: height)
        needsLayout = true
    }

    func reloadQuotes() {
        for row in rows {
            row.refreshQuote(stockWatcher.ticker(for: row.symbol))
        }
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: tableWidth, height: headerHeight)
        var y = bounds.height - headerHeight - rowHeight
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: tableWidth, height: rowHeight)
            y -= rowHeight
        }
    }
}

// MARK: - Header

private final class MenuBarStockHeaderView: NSView {
    private let name = makeLabel("名称", weight: .medium)
    private let price = makeLabel("现价", weight: .medium)
    private let percent = makeLabel("涨跌幅", weight: .medium)
    private let amount = makeLabel("涨跌额", weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [name, price, percent, amount] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 10, weight: .medium)
            addSubview(label)
        }
        price.alignment = .right
        percent.alignment = .right
        amount.alignment = .right
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        MenuBarStockColumns.layout(
            name: name, price: price, percent: percent, amount: amount,
            in: bounds, verticalCenter: true
        )
    }
}

// MARK: - Row

private final class MenuBarStockRowView: NSView {
    private(set) var symbol: String = ""
    private let highlight = CALayer()
    private let nameLabel = makeLabel("", weight: .semibold)
    private let codeLabel = makeLabel("", weight: .regular)
    private let priceLabel = makeLabel("", weight: .semibold)
    private let percentLabel = makeLabel("", weight: .semibold)
    private let amountLabel = makeLabel("", weight: .semibold)
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        highlight.cornerRadius = 4
        highlight.cornerCurve = .circular
        highlight.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(highlight)

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        codeLabel.font = .systemFont(ofSize: 10, weight: .regular)
        codeLabel.textColor = .secondaryLabelColor
        for label in [priceLabel, percentLabel, amountLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            label.alignment = .right
        }
        [nameLabel, codeLabel, priceLabel, percentLabel, amountLabel].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(entry: StockEntry, ticker: Ticker?) {
        symbol = entry.symbol
        codeLabel.stringValue = entry.symbol.uppercased()
        applyName(entry: entry, ticker: ticker)
        applyQuote(ticker)
    }

    func refreshQuote(_ ticker: Ticker?) {
        applyName(entry: nil, ticker: ticker)
        applyQuote(ticker)
    }

    private func applyName(entry: StockEntry?, ticker: Ticker?) {
        if let tickerName = ticker?.name, tickerName.containsCJK {
            nameLabel.stringValue = tickerName
            return
        }
        if let entry, entry.name.containsCJK {
            nameLabel.stringValue = entry.name
            return
        }
        if nameLabel.stringValue.isEmpty {
            nameLabel.stringValue = symbol.uppercased()
        }
    }

    private func applyQuote(_ ticker: Ticker?) {
        guard let ticker, ticker.price > 0 else {
            priceLabel.stringValue = "--"
            percentLabel.stringValue = "--"
            amountLabel.stringValue = "--"
            let muted = NSColor.secondaryLabelColor
            priceLabel.textColor = muted
            percentLabel.textColor = muted
            amountLabel.textColor = muted
            return
        }
        let color = StockTheme.nsColor(isUp: ticker.isUp)
        priceLabel.stringValue = String(format: "%.2f", ticker.price)
        let pctSign = ticker.changePercent >= 0 ? "+" : ""
        percentLabel.stringValue = "\(pctSign)\(String(format: "%.2f", ticker.changePercent))%"
        let amtSign = ticker.changeAmount >= 0 ? "+" : ""
        amountLabel.stringValue = "\(amtSign)\(String(format: "%.2f", ticker.changeAmount))"
        priceLabel.textColor = color
        percentLabel.textColor = color
        amountLabel.textColor = color
    }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 4, dy: 1)
        let top = bounds.height - 17
        nameLabel.frame = NSRect(x: MenuBarStockColumns.nameX, y: top - 1, width: MenuBarStockColumns.nameW, height: 15)
        codeLabel.frame = NSRect(x: MenuBarStockColumns.nameX, y: 4, width: MenuBarStockColumns.nameW, height: 12)
        MenuBarStockColumns.layout(
            name: nil, price: priceLabel, percent: percentLabel, amount: amountLabel,
            in: bounds, verticalCenter: true
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        highlight.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        highlight.backgroundColor = NSColor.clear.cgColor
    }
}

// MARK: - Columns

private enum MenuBarStockColumns {
    static let nameX: CGFloat = 12
    static let nameW: CGFloat = 160
    static let priceW: CGFloat = 58
    static let percentW: CGFloat = 66
    static let amountW: CGFloat = 58
    static let gap: CGFloat = 4
    static let trailingPad: CGFloat = 12

    static func layout(
        name: NSTextField?,
        price: NSTextField,
        percent: NSTextField,
        amount: NSTextField,
        in bounds: NSRect,
        verticalCenter: Bool
    ) {
        let y: CGFloat = verticalCenter ? (bounds.height - 14) / 2 : 4
        let h: CGFloat = 14
        let amountX = bounds.width - trailingPad - amountW
        let percentX = amountX - gap - percentW
        let priceX = percentX - gap - priceW
        if let name {
            name.frame = NSRect(x: nameX, y: y, width: nameW, height: h)
        }
        price.frame = NSRect(x: priceX, y: y, width: priceW, height: h)
        percent.frame = NSRect(x: percentX, y: y, width: percentW, height: h)
        amount.frame = NSRect(x: amountX, y: y, width: amountW, height: h)
    }
}

private func makeLabel(_ text: String, weight: NSFont.Weight) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.isBezeled = false
    label.drawsBackground = false
    label.isEditable = false
    label.isSelectable = false
    label.lineBreakMode = .byTruncatingTail
    label.font = .systemFont(ofSize: 12, weight: weight)
    return label
}
