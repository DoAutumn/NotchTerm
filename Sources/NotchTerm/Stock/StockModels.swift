import Foundation

struct OrderBookLevel: Equatable {
    var price: Double
    var volume: Double
}

/// 新浪 hq.sinajs.cn 实时快照。
struct Ticker: Equatable {
    var symbol: String
    var name: String
    var price: Double = 0
    var previousClose: Double = 0
    var open: Double = 0
    var high: Double = 0
    var low: Double = 0
    var volume: Double = 0
    var amount: Double = 0
    var avgPrice: Double = 0
    var buyLevels: [OrderBookLevel] = []
    var sellLevels: [OrderBookLevel] = []

    var changeAmount: Double { price - previousClose }

    var changePercent: Double {
        guard previousClose != 0 else { return 0 }
        return (price - previousClose) / previousClose * 100
    }

    /// 持平按上涨配色。
    var isUp: Bool { price >= previousClose }
}

struct StockEntry: Codable, Equatable, Identifiable {
    var symbol: String
    var name: String
    var showInMenuBar: Bool = false
    /// 涨/跌超过该比例（相对昨收）时提醒，默认 5%。
    var alertThresholdPercent: Double = 5.0

    var id: String { symbol }

    enum CodingKeys: String, CodingKey {
        case symbol, name, showInMenuBar, alertThresholdPercent
    }

    init(
        symbol: String,
        name: String,
        showInMenuBar: Bool = false,
        alertThresholdPercent: Double = 5.0
    ) {
        self.symbol = symbol
        self.name = name
        self.showInMenuBar = showInMenuBar
        self.alertThresholdPercent = alertThresholdPercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol)
        name = try c.decode(String.self, forKey: .name)
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? false
        alertThresholdPercent = try c.decodeIfPresent(Double.self, forKey: .alertThresholdPercent) ?? 5.0
    }
}

struct SuggestItem: Equatable, Identifiable {
    var code: String
    var name: String
    var id: String { code }
}

enum StockAPIError: Error {
    case invalidURL
    case emptyRequest
    case emptyResponse
    case httpStatus(Int)
}

enum SymbolHelper {
    static func normalizedSymbol(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed.hasPrefix("sh") || trimmed.hasPrefix("sz") {
            let digits = trimmed.dropFirst(2)
            return (digits.count == 6 && digits.allSatisfy(\.isNumber)) ? trimmed : nil
        }

        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber), let first = trimmed.first else {
            return nil
        }
        switch first {
        case "6", "9": return "sh" + trimmed
        case "0", "3": return "sz" + trimmed
        default: return nil
        }
    }
}

extension String.Encoding {
    static let gbk: String.Encoding = .init(rawValue: 2_147_485_234)
}

extension String {
    var containsCJK: Bool {
        contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
    }
}

enum NumberFormat {
    static func chineseCompact(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let v = abs(value)
        switch v {
        case 100_000_000...:
            return "\(sign)\(String(format: "%.2f", v / 100_000_000))亿"
        case 10_000...:
            return "\(sign)\(String(format: "%.2f", v / 10_000))万"
        default:
            return "\(sign)\(String(format: "%.0f", v))"
        }
    }
}

struct StockAlertItem: Equatable, Identifiable {
    var symbol: String
    var name: String
    var changePercent: Double
    var price: Double

    var id: String { symbol }

    var isUp: Bool { changePercent >= 0 }
}
