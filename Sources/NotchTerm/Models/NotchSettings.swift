import Foundation

struct NotchSettings: Equatable, Sendable {
    static let compactWidthRange = 220.0...700.0
    static let compactHeightRange = 28.0...48.0
    static let expandedWidthRange = 320.0...720.0
    static let expandedHeightRange = 160.0...420.0

    var isEnabled = true
    var alwaysOnTop = true
    var showOnFullscreen = true
    var launchAtLogin = false
    var notifyOnComplete = false
    /// Local chime on DONE / 等待确认 / 有提问. Default on.
    var playAlertSound = true
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

extension NotchSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case isEnabled, alwaysOnTop, showOnFullscreen, launchAtLogin
        case notifyOnComplete, playAlertSound, targetDisplayID
        case compactWidth, compactHeight, expandedWidth, expandedHeight
        case collapseDelay, verticalOffset
        case stockWatcherEnabled, stockRefreshIntervalSeconds, stockCarouselIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = NotchSettings()
        s.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? s.isEnabled
        s.alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? s.alwaysOnTop
        s.showOnFullscreen = try c.decodeIfPresent(Bool.self, forKey: .showOnFullscreen) ?? s.showOnFullscreen
        s.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? s.launchAtLogin
        s.notifyOnComplete = try c.decodeIfPresent(Bool.self, forKey: .notifyOnComplete) ?? s.notifyOnComplete
        // New key: default ON when migrating older settings blobs.
        s.playAlertSound = try c.decodeIfPresent(Bool.self, forKey: .playAlertSound) ?? true
        s.targetDisplayID = try c.decodeIfPresent(UInt32.self, forKey: .targetDisplayID)
        s.compactWidth = try c.decodeIfPresent(Double.self, forKey: .compactWidth) ?? s.compactWidth
        s.compactHeight = try c.decodeIfPresent(Double.self, forKey: .compactHeight) ?? s.compactHeight
        s.expandedWidth = try c.decodeIfPresent(Double.self, forKey: .expandedWidth) ?? s.expandedWidth
        s.expandedHeight = try c.decodeIfPresent(Double.self, forKey: .expandedHeight) ?? s.expandedHeight
        s.collapseDelay = try c.decodeIfPresent(Double.self, forKey: .collapseDelay) ?? s.collapseDelay
        s.verticalOffset = try c.decodeIfPresent(Double.self, forKey: .verticalOffset) ?? s.verticalOffset
        s.stockWatcherEnabled = try c.decodeIfPresent(Bool.self, forKey: .stockWatcherEnabled) ?? s.stockWatcherEnabled
        s.stockRefreshIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .stockRefreshIntervalSeconds)
            ?? s.stockRefreshIntervalSeconds
        s.stockCarouselIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .stockCarouselIntervalSeconds)
            ?? s.stockCarouselIntervalSeconds
        self = s
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
