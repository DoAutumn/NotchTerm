import Foundation

extension Notification.Name {
    static let stockStoreDidChange = Notification.Name("notchterm.stockStoreDidChange")
}

@MainActor
final class StockStore: ObservableObject {
    static let shared = StockStore()

    private let defaultsKey = "notchterm.stockEntries"
    private let defaults = UserDefaults.standard

    @Published private(set) var entries: [StockEntry] = []

    private init() {
        entries = load()
    }

    func add(_ entry: StockEntry) {
        guard !entries.contains(where: { $0.symbol == entry.symbol }) else { return }
        var next = entries
        next.append(entry)
        save(next)
    }

    func remove(symbol: String) {
        save(entries.filter { $0.symbol != symbol })
    }

    func update(_ entry: StockEntry) {
        var next = entries
        guard let index = next.firstIndex(where: { $0.symbol == entry.symbol }) else { return }
        next[index] = entry
        save(next)
    }

    func setShowInMenuBar(symbol: String, enabled: Bool) {
        var next = entries
        guard let index = next.firstIndex(where: { $0.symbol == symbol }) else { return }
        next[index].showInMenuBar = enabled
        save(next)
    }

    func setAlertThreshold(symbol: String, percent: Double) {
        var next = entries
        guard let index = next.firstIndex(where: { $0.symbol == symbol }) else { return }
        next[index].alertThresholdPercent = percent.clamped(to: 0.5...50)
        save(next)
    }

    func updateNames(_ namesBySymbol: [String: String]) {
        guard !namesBySymbol.isEmpty else { return }
        var next = entries
        var changed = false
        for (symbol, name) in namesBySymbol {
            guard name.containsCJK,
                  let index = next.firstIndex(where: {
                      $0.symbol == symbol || $0.symbol.lowercased() == symbol.lowercased()
                  }),
                  next[index].name != name
            else { continue }
            next[index].name = name
            changed = true
        }
        guard changed else { return }
        save(next)
    }

    private func save(_ next: [StockEntry]) {
        entries = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: .stockStoreDidChange, object: nil)
    }

    private func load() -> [StockEntry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([StockEntry].self, from: data)
        else { return [] }
        return decoded
    }
}
