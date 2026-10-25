import AppKit
import Foundation

@MainActor
final class NowPlayingMonitor: ObservableObject {
    static let bundleID = "com.doautumn.musicplayer"
    static let notification = Notification.Name("com.doautumn.musicplayer.nowPlaying")

    @Published private(set) var title = ""
    @Published private(set) var isPlaying = false

    private var observer: NSObjectProtocol?

    var showsInNotch: Bool {
        isPlaying && !title.isEmpty
    }

    func start() {
        reload()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
            }
        }
    }

    private func apply(userInfo: [AnyHashable: Any]?) {
        guard musicPlayerIsRunning else {
            clear()
            return
        }
        let name = userInfo?["title"] as? String ?? ""
        let playing = (userInfo?["playing"] as? Bool)
            ?? (userInfo?["playing"] as? NSNumber)?.boolValue
            ?? false
        let nextPlaying = playing && !name.isEmpty
        if title != name { title = name }
        if isPlaying != nextPlaying { isPlaying = nextPlaying }
    }

    private func reload() {
        guard musicPlayerIsRunning else {
            clear()
            return
        }
        let url = nowPlayingFileURL
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            clear()
            return
        }
        apply(userInfo: json)
    }

    private func clear() {
        if !title.isEmpty { title = "" }
        if isPlaying { isPlaying = false }
    }

    private var musicPlayerIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    private var nowPlayingFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.bundleID, isDirectory: true)
            .appendingPathComponent("now-playing.json")
    }
}
