import AppKit
import Foundation

struct ITermSession: Equatable, Sendable {
    let tty: String
    let name: String
    let tail: String
}

enum ITermController {
    /// Normalize `/dev/ttys000` and `ttys000` to `ttys000`.
    static func normalizedTTY(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/dev/", with: "")
    }

    static func listSessions() -> [ITermSession] {
        let script = """
        tell application "iTerm"
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  set ttyName to tty of s
                  set sessName to name of s
                  set txt to text of s
                  set out to out & "TTY=" & ttyName & tab & "NAME=" & sessName & linefeed
                  if (length of txt) > 1200 then
                    set snippet to text ((length of txt) - 1199) thru -1 of txt
                  else
                    set snippet to txt
                  end if
                  set out to out & "TAIL<<" & snippet & ">>END" & linefeed
                end try
              end repeat
            end repeat
          end repeat
          return out
        end tell
        """
        guard let raw = runAppleScript(script) else { return [] }
        return parseSessions(raw)
    }

    static func activateSession(tty: String) -> Bool {
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
        return runAppleScript(script) == "ok"
    }

    static func isAgentBusy(tail: String, cpu: Double, childCount: Int) -> Bool {
        let lower = tail.lowercased()
        if lower.contains("ctrl+c to stop") { return true }
        if lower.range(of: #"\d+\s+tasks?"#, options: .regularExpression) != nil { return true }
        if childCount > 0 { return true }
        return cpu >= 3.0
    }

    static func isAgentIdlePrompt(tail: String) -> Bool {
        tail.contains("Add a follow-up") || tail.contains("→ Add a follow-up")
    }

    // MARK: - Private

    private static func parseSessions(_ raw: String) -> [ITermSession] {
        var sessions: [ITermSession] = []
        var currentTTY: String?
        var currentName = ""
        var collectingTail = false
        var tailBuffer = ""

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("TTY=") {
                if collectingTail, let tty = currentTTY {
                    sessions.append(ITermSession(tty: normalizedTTY(tty), name: currentName, tail: tailBuffer))
                    tailBuffer = ""
                    collectingTail = false
                }
                let body = String(line.dropFirst(4))
                let parts = body.split(separator: "\t", maxSplits: 1).map(String.init)
                currentTTY = parts.first
                if parts.count > 1, parts[1].hasPrefix("NAME=") {
                    currentName = String(parts[1].dropFirst(5))
                } else {
                    currentName = ""
                }
            } else if line.hasPrefix("TAIL<<") {
                collectingTail = true
                var chunk = String(line.dropFirst(6))
                if chunk.hasSuffix(">>END") {
                    chunk = String(chunk.dropLast(5))
                    if let tty = currentTTY {
                        sessions.append(ITermSession(tty: normalizedTTY(tty), name: currentName, tail: chunk))
                    }
                    collectingTail = false
                    tailBuffer = ""
                    currentTTY = nil
                } else {
                    tailBuffer = chunk + "\n"
                }
            } else if collectingTail {
                if line.hasSuffix(">>END") {
                    tailBuffer += String(line.dropLast(5))
                    if let tty = currentTTY {
                        sessions.append(ITermSession(tty: normalizedTTY(tty), name: currentName, tail: tailBuffer))
                    }
                    collectingTail = false
                    tailBuffer = ""
                    currentTTY = nil
                } else {
                    tailBuffer += line + "\n"
                }
            }
        }
        return sessions
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}
