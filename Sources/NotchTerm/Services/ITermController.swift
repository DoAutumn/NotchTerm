import AppKit
import Foundation

struct ITermSession: Equatable, Sendable {
    let tty: String
    let name: String
}

enum ITermController {
    /// Normalize `/dev/ttys000` and `ttys000` to `ttys000`.
    nonisolated static func normalizedTTY(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/dev/", with: "")
    }

    /// Lightweight session list (tty + name only). Never pulls scrollback text.
    /// Uses `/usr/bin/osascript` with a timeout so it never wedges the main actor
    /// the way in-process `NSAppleScript` can.
    nonisolated static func listSessionSummaries() -> [ITermSession] {
        let script = """
        tell application "iTerm"
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  set ttyName to tty of s
                  set sessName to name of s
                  set out to out & "TTY=" & ttyName & tab & "NAME=" & sessName & linefeed
                end try
              end repeat
            end repeat
          end repeat
          return out
        end tell
        """
        let raw = ShellCommand.run("/usr/bin/osascript", ["-e", script], timeout: 1.5)
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: "\n").compactMap { line -> ITermSession? in
            let text = String(line)
            guard text.hasPrefix("TTY=") else { return nil }
            let body = String(text.dropFirst(4))
            let parts = body.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let tty = parts.first else { return nil }
            var name = ""
            if parts.count > 1, parts[1].hasPrefix("NAME=") {
                name = String(parts[1].dropFirst(5))
            }
            return ITermSession(tty: normalizedTTY(tty), name: name)
        }
    }

    /// Focus an iTerm session. Safe to call off the main actor — `ShellCommand`
    /// blocks with `Thread.sleep` for up to ~3s and must not run on MainActor.
    nonisolated static func activateSession(tty: String) -> Bool {
        let target = normalizedTTY(tty)
        let script = """
        tell application "iTerm"
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
        end tell
        """
        // User gesture: allow a slightly longer wait than background title scans.
        return ShellCommand.run("/usr/bin/osascript", ["-e", script], timeout: 3.0)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }
}
