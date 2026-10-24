import Foundation

enum StockRefreshSettings {
    static let options: [Double] = [3, 5, 10, 15, 30, 60]
    static let defaultInterval: Double = 5
    static let nonTradingCheckInterval: Double = 60

    static func effectiveInterval(_ configured: Double) -> Double {
        isTradingHours() ? configured : nonTradingCheckInterval
    }

    static func isTradingHours(date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }

        let comps = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = comps.hour, let minute = comps.minute else { return false }
        let minutes = hour * 60 + minute
        let morning = (9 * 60 + 15)...(11 * 60 + 30)
        let afternoon = (13 * 60)...(15 * 60)
        return morning.contains(minutes) || afternoon.contains(minutes)
    }
}

enum StockCarouselSettings {
    static let options: [Double] = [3, 5, 10, 15, 30]
    static let defaultInterval: Double = 10
}
