import Foundation

/// zsh preexec/precmd pushes git/npm long-task state (iTerm only).
enum ShellHookService {
    nonisolated static var stateDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return root
            .appendingPathComponent("com.doautumn.notchterm", isDirectory: true)
            .appendingPathComponent("task-state", isDirectory: true)
    }

    private static var installedScriptURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return root
            .appendingPathComponent("com.doautumn.notchterm", isDirectory: true)
            .appendingPathComponent("shell", isDirectory: true)
            .appendingPathComponent("notchterm-shell.zsh")
    }

    private static var zshrcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    private static let zshrcBegin = "# >>> notchterm-shell >>>"
    private static let zshrcEnd = "# <<< notchterm-shell <<<"

    struct TaskState: Sendable, Equatable {
        enum Value: String, Sendable {
            case running
            case idle
        }

        let pid: Int32
        let state: Value
        let kind: TerminalTaskKind
        let command: String
        let title: String
        let updatedAt: Date
        let cwd: String?
        let tty: String?
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try installShellScript()
            try ensureZshrcSnippet()
            return true
        } catch {
            return false
        }
    }

    nonisolated static func loadStatesByPID() -> [Int32: TaskState] {
        let dir = stateDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [:] }

        var result: [Int32: TaskState] = [:]
        let now = Date()
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int ?? (json["pid"] as? Double).map(Int.init),
                  let stateRaw = json["state"] as? String,
                  let state = TaskState.Value(rawValue: stateRaw),
                  let kindRaw = json["kind"] as? String,
                  let kind = TerminalTaskKind(rawValue: kindRaw),
                  kind != .agent
            else { continue }

            let updatedAt: Date
            if let ts = json["updatedAt"] as? TimeInterval {
                updatedAt = Date(timeIntervalSince1970: ts)
            } else if let ts = json["updatedAt"] as? Int {
                updatedAt = Date(timeIntervalSince1970: TimeInterval(ts))
            } else {
                continue
            }

            guard now.timeIntervalSince(updatedAt) < 6 * 60 * 60 else {
                try? FileManager.default.removeItem(at: url)
                continue
            }

            let pid = Int32(pidValue)
            let task = TaskState(
                pid: pid,
                state: state,
                kind: kind,
                command: json["command"] as? String ?? "",
                title: json["title"] as? String ?? kind.title,
                updatedAt: updatedAt,
                cwd: json["cwd"] as? String,
                tty: json["tty"] as? String
            )
            if let existing = result[pid], existing.updatedAt > task.updatedAt {
                continue
            }
            result[pid] = task
        }
        return result
    }

    nonisolated static func pruneStaleStateFiles() {
        let dir = stateDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        for url in files where url.pathExtension == "json" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(mtime) >= 6 * 60 * 60 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Install

    private static func installShellScript() throws {
        let fm = FileManager.default
        let dir = installedScriptURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let bundled = Bundle.main.url(forResource: "notchterm-shell", withExtension: "zsh")
            ?? Bundle.main.resourceURL?
            .appendingPathComponent("NotchTerm_NotchTerm.bundle")
            .appendingPathComponent("notchterm-shell.zsh")
        else {
            throw NSError(domain: "NotchTerm", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Bundled shell hook missing"
            ])
        }

        if fm.fileExists(atPath: installedScriptURL.path) {
            try fm.removeItem(at: installedScriptURL)
        }
        try fm.copyItem(at: bundled, to: installedScriptURL)
    }

    private static func ensureZshrcSnippet() throws {
        let fm = FileManager.default
        let path = zshrcURL.path
        let snippet = """
        \(zshrcBegin)
        [[ -f "\(installedScriptURL.path)" ]] && source "\(installedScriptURL.path)"
        \(zshrcEnd)
        """

        if !fm.fileExists(atPath: path) {
            try snippet.write(to: zshrcURL, atomically: true, encoding: .utf8)
            return
        }

        var text = try String(contentsOf: zshrcURL, encoding: .utf8)
        if let begin = text.range(of: zshrcBegin),
           let end = text.range(of: zshrcEnd),
           begin.lowerBound < end.upperBound
        {
            text.replaceSubrange(begin.lowerBound..<end.upperBound, with: snippet)
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") {
                text.append("\n")
            }
            text.append("\n")
            text.append(snippet)
            text.append("\n")
        }
        try text.write(to: zshrcURL, atomically: true, encoding: .utf8)
    }
}
