import Foundation

struct NotchSettings: Codable, Equatable, Sendable {
    static let compactWidthRange = 220.0...700.0
    static let compactHeightRange = 28.0...48.0
    static let expandedWidthRange = 320.0...720.0
    static let expandedHeightRange = 160.0...420.0

    var isEnabled = true
    var alwaysOnTop = true
    var showOnFullscreen = true
    var launchAtLogin = false
    var notifyOnComplete = false
    var targetDisplayID: UInt32?
    var compactWidth = 460.0
    var compactHeight = 38.0
    var expandedWidth = 520.0
    /// Compact strip + header / tab / detail / jump button + bottom inset.
    var expandedHeight = 176.0
    var collapseDelay = 0.18
    var verticalOffset = 0.0

    /// 股票监视总开关；关闭后不拉行情、不改菜单栏标题、不提醒。
    var stockWatcherEnabled = false
    var stockRefreshIntervalSeconds = StockRefreshSettings.defaultInterval
    var stockCarouselIntervalSeconds = StockCarouselSettings.defaultInterval

    static let `default` = NotchSettings()

    mutating func clampValues() {
        compactWidth = compactWidth.clamped(to: Self.compactWidthRange)
        compactHeight = compactHeight.clamped(to: Self.compactHeightRange)
        expandedWidth = expandedWidth.clamped(to: Self.expandedWidthRange)
        expandedHeight = expandedHeight.clamped(to: Self.expandedHeightRange)
        collapseDelay = collapseDelay.clamped(to: 0.12...1.2)
        verticalOffset = verticalOffset.clamped(to: 0...40)
        if !StockRefreshSettings.options.contains(stockRefreshIntervalSeconds) {
            stockRefreshIntervalSeconds = StockRefreshSettings.defaultInterval
        }
        if !StockCarouselSettings.options.contains(stockCarouselIntervalSeconds) {
            stockCarouselIntervalSeconds = StockCarouselSettings.defaultInterval
        }
    }
}

enum NotchMode: String, Codable, Sendable {
    case compact
    case expanded
}

enum NotchLayout {
    static let shadowHorizontalPadding: CGFloat = 28
    static let shadowBottomPadding: CGFloat = 32
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
