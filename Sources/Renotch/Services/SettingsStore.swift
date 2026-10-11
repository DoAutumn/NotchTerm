import Foundation

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "renotch.settings.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> NotchSettings {
        guard let data = defaults.data(forKey: key),
              var settings = try? JSONDecoder().decode(NotchSettings.self, from: data) else {
            return .default
        }
        settings.clampValues()
        return settings
    }

    func save(_ settings: NotchSettings) {
        var copy = settings
        copy.clampValues()
        guard let data = try? JSONEncoder().encode(copy) else { return }
        defaults.set(data, forKey: key)
    }
}
