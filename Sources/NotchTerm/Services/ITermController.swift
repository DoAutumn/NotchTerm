import AppKit
import Foundation

struct TerminalSession: Equatable, Sendable {
    let tty: String
    let name: String
}

/// iTerm2 / Ghostty session list + focus.
///
/// Never calls into an app unless it already looks running. AppleScript is also
/// wrapped in `if application id … is running` so a quit between the Swift check
/// and `osascript` is far less likely to relaunch the terminal.
enum TerminalController {
    enum App: String, CaseIterable, Sendable {
        case iTerm
        case ghostty

        var bundleIdentifier: String {
            switch self {
            case .iTerm: return "com.googlecode.iterm2"
            case .ghostty: return "com.mitchellh.ghostty"
            }
        }

        static func from(bundleIdentifier: String) -> App? {
            allCases.first { $0.bundleIdentifier == bundleIdentifier }
        }
    }

    private static let cacheLock = NSLock()
    /// Last terminal app known to own a tty (from list or successful focus).
    private static var ttyOwner: [String: App] = [:]
    /// Dedicated pool so `group.wait()` never blocks the same concurrent queue that runs probes.
    private static let probeQueue = DispatchQueue(
        label: "com.doautumn.notchterm.terminal-probe",
        qos: .utility,
        attributes: .concurrent
    )

    /// Normalize `/dev/ttys000` and `ttys000` to `ttys000`.
    nonisolated static func normalizedTTY(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/dev/", with: "")
    }

    nonisolated static func isRunning(_ app: App) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
    }

    nonisolated static func anySupportedTerminalRunning() -> Bool {
        App.allCases.contains(where: isRunning)
    }

    nonisolated static func forget(app: App) {
        cacheLock.lock()
        ttyOwner = ttyOwner.filter { $0.value != app }
        cacheLock.unlock()
    }

    /// Lightweight session list (tty + name). Never pulls scrollback.
    /// Queries running apps in parallel when more than one is open.
    ///
    /// Do not call this synchronously from `probeQueue` — it may `group.wait()` on that pool.
    nonisolated static func listSessionSummaries() -> [TerminalSession] {
        let apps = App.allCases.filter(isRunning)
        guard !apps.isEmpty else { return [] }

        if apps.count == 1, let app = apps.first {
            let sessions = listSessions(in: app)
            remember(sessions: sessions, app: app)
            return sessions
        }

        let lock = NSLock()
        var merged: [TerminalSession] = []
        let group = DispatchGroup()
        for app in apps {
            group.enter()
            probeQueue.async {
                let sessions = listSessions(in: app)
                lock.lock()
                merged.append(contentsOf: sessions)
                lock.unlock()
                remember(sessions: sessions, app: app)
                group.leave()
            }
        }
        // Each listSessions already times out at 1.5s; wait for both so `merged` is final.
        group.wait()
        return merged
    }

    /// Frontmost terminal's tty only when a supported terminal is the frontmost app.
    /// Returns nil if the user is in another app (caller should keep the last known tty).
    /// Never uses bare `tell application` without an `is running` guard (that launches apps).
    nonisolated static func frontmostTTY() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let app = App.from(bundleIdentifier: front),
              isRunning(app)
        else {
            return nil
        }
        guard let tty = frontmostTTY(in: app), !tty.isEmpty else { return nil }
        return normalizedTTY(tty)
    }

    /// Focus the session that owns `tty`. Prefers the app that last listed/focused it.
    nonisolated static func activateSession(tty: String) -> Bool {
        let target = normalizedTTY(tty)
        guard !target.isEmpty else { return false }

        var order = App.allCases.filter(isRunning)
        guard !order.isEmpty else { return false }

        cacheLock.lock()
        let preferred = ttyOwner[target]
        cacheLock.unlock()
        if let preferred, let idx = order.firstIndex(of: preferred) {
            order.remove(at: idx)
            order.insert(preferred, at: 0)
        }

        for app in order {
            if activateSession(tty: target, in: app) {
                cacheLock.lock()
                ttyOwner[target] = app
                cacheLock.unlock()
                return true
            }
        }
        return false
    }

    // MARK: - Ownership cache

    nonisolated private static func remember(sessions: [TerminalSession], app: App) {
        // Drop results from an in-flight probe that finished after the app quit
        // (terminate → forget, then late listSessions would otherwise repopulate).
        guard isRunning(app), !sessions.isEmpty else { return }
        cacheLock.lock()
        for session in sessions where !session.tty.isEmpty {
            ttyOwner[session.tty] = app
        }
        cacheLock.unlock()
    }

    // MARK: - Per-app AppleScript

    nonisolated private static func frontmostTTY(in app: App) -> String? {
        guard isRunning(app) else { return nil }
        let bid = app.bundleIdentifier
        let body: String
        switch app {
        case .iTerm:
            body = """
              try
                return tty of current session of current window
              end try
              return ""
            """
        case .ghostty:
            body = """
              try
                set w to front window
                set t to selected tab of w
                set term to focused terminal of t
                return tty of term
              end try
              return ""
            """
        }
        let script = """
        if application id "\(bid)" is running then
          tell application id "\(bid)"
        \(body)
          end tell
        end if
        return ""
        """
        let raw = ShellCommand.run("/usr/bin/osascript", ["-e", script], timeout: 1.0)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    nonisolated private static func listSessions(in app: App) -> [TerminalSession] {
        // Swift-side skip avoids spawning osascript when already quit.
        guard isRunning(app) else { return [] }

        let bid = app.bundleIdentifier
        let body: String
        switch app {
        case .iTerm:
            // Inside iTerm's tell block, bare `tab` is shadowed — use ASCII 9.
            body = """
              set out to ""
              set delim to ASCII character 9
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    try
                      set ttyName to tty of s
                      set sessName to name of s
                      set out to out & "TTY=" & ttyName & delim & "NAME=" & sessName & linefeed
                    end try
                  end repeat
                end repeat
              end repeat
              return out
            """
        case .ghostty:
            // Prefer terminal surface title (what usually changes when switching tabs);
            // fall back to tab name if the surface title is empty.
            body = """
              set out to ""
              set delim to ASCII character 9
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with term in terminals of t
                    try
                      set ttyName to tty of term
                      set sessName to name of term
                      if sessName is missing value or sessName is "" then
                        set sessName to name of t
                      end if
                      set out to out & "TTY=" & ttyName & delim & "NAME=" & sessName & linefeed
                    end try
                  end repeat
                end repeat
              end repeat
              return out
            """
        }

        // `application id … is running` avoids launching if the process died after the Swift check.
        let script = """
        if application id "\(bid)" is running then
          tell application id "\(bid)"
        \(body)
          end tell
        end if
        return ""
        """
        return parseSessionList(ShellCommand.run("/usr/bin/osascript", ["-e", script], timeout: 1.5))
    }

    nonisolated private static func activateSession(tty target: String, in app: App) -> Bool {
        guard isRunning(app) else { return false }

        let bid = app.bundleIdentifier
        let body: String
        switch app {
        case .iTerm:
            body = """
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    try
                      set ttyName to tty of s as string
                      if ttyName ends with "\(target)" then
                        select w
                        tell w to select t
                        tell t to select s
                        return "ok"
                      end if
                    end try
                  end repeat
                end repeat
              end repeat
              return "missing"
            """
        case .ghostty:
            body = """
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with term in terminals of t
                    try
                      set ttyName to tty of term as string
                      if ttyName ends with "\(target)" then
                        focus term
                        return "ok"
                      end if
                    end try
                  end repeat
                end repeat
              end repeat
              return "missing"
            """
        }

        let script = """
        if application id "\(bid)" is running then
          tell application id "\(bid)"
        \(body)
          end tell
        end if
        return "missing"
        """
        return ShellCommand.run("/usr/bin/osascript", ["-e", script], timeout: 3.0)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    nonisolated private static func parseSessionList(_ raw: String) -> [TerminalSession] {
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: "\n").compactMap { line -> TerminalSession? in
            let text = String(line)
            guard text.hasPrefix("TTY=") else { return nil }
            let body = String(text.dropFirst(4))
            let parts = body.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let tty = parts.first, !tty.isEmpty else { return nil }
            var name = ""
            if parts.count > 1, parts[1].hasPrefix("NAME=") {
                name = String(parts[1].dropFirst(5))
            }
            guard parts.count == 2, !name.isEmpty else { return nil }
            return TerminalSession(tty: normalizedTTY(tty), name: name)
        }
    }
}
