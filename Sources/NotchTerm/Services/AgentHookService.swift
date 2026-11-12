import Darwin
import Foundation

/// Cursor Agent CLI pushes busy/idle via `~/.cursor/hooks.json`.
/// Claude Code writes the same `agent-state` shape via `ClaudeHookService`.
enum AgentHookService {
    nonisolated static var stateDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return root
            .appendingPathComponent("com.doautumn.notchterm", isDirectory: true)
            .appendingPathComponent("agent-state", isDirectory: true)
    }

    private static var hooksJSONURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    private static var installedHookScriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("notchterm-agent-hook.sh")
    }

    struct HookState: Sendable, Equatable {
        enum Value: String, Sendable {
            case running
            case idle
            case awaitingPermission = "awaiting_permission"
            case awaitingQuestion = "awaiting_question"

            var taskState: TerminalTaskState {
                switch self {
                case .running: return .running
                case .idle: return .idle
                case .awaitingPermission: return .awaitingPermission
                case .awaitingQuestion: return .awaitingQuestion
                }
            }

            var isBusy: Bool {
                self != .idle
            }
        }

        let pid: Int32
        let state: Value
        let updatedAt: Date
        let conversationId: String?
        let cwd: String?
        let tty: String?
        let provider: AgentProvider
        let sessionTitle: String?
    }

    /// Last successful hook write age, for diagnostics.
    nonisolated static func lastHookEventAge() -> TimeInterval? {
        let log = stateDirectory.appendingPathComponent("hook.log")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: log.path),
              let date = attrs[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(date)
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try installHookScript()
            try mergeHooksJSON()
            return true
        } catch {
            return false
        }
    }

    /// Load hook-pushed states keyed by agent PID (also indexes tty/cwd/conversation).
    nonisolated static func loadStatesByPID() -> [Int32: HookState] {
        let dir = stateDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [:] }

        var result: [Int32: HookState] = [:]
        let now = Date()
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int ?? (json["pid"] as? Double).map(Int.init),
                  let stateRaw = json["state"] as? String,
                  let state = HookState.Value(rawValue: stateRaw)
            else { continue }

            let updatedAt: Date
            if let ts = json["updatedAt"] as? TimeInterval {
                updatedAt = Date(timeIntervalSince1970: ts)
            } else if let ts = json["updatedAt"] as? Int {
                updatedAt = Date(timeIntervalSince1970: TimeInterval(ts))
            } else {
                continue
            }

            let pid = Int32(pidValue)
            // Drop stale pushes only when the agent PID is gone. Awaiting permission /
            // question can sit for hours with no further hooks, so age-only prune would
            // clear「等待确认」/「有提问」and emit a false DONE while claude is still alive.
            if now.timeIntervalSince(updatedAt) >= 6 * 60 * 60 {
                if kill(pid, 0) != 0 {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
            }

            let providerRaw = (json["provider"] as? String)?.lowercased()
            let provider = providerRaw.flatMap(AgentProvider.init(rawValue:)) ?? .cursor
            let sessionTitle = (json["sessionTitle"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hook = HookState(
                pid: pid,
                state: state,
                updatedAt: updatedAt,
                conversationId: json["conversationId"] as? String,
                cwd: json["cwd"] as? String,
                tty: json["tty"] as? String,
                provider: provider,
                sessionTitle: (sessionTitle?.isEmpty == false) ? sessionTitle : nil
            )
            if let existing = result[pid], existing.updatedAt > hook.updatedAt {
                continue
            }
            result[pid] = hook
        }
        return result
    }

    /// Remove stale / unreadable state files (called on the monitor scan path).
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
            guard now.timeIntervalSince(mtime) >= 6 * 60 * 60 else { continue }
            // Keep files whose agent PID is still alive (long awaits / quiet turns).
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pidValue = json["pid"] as? Int ?? (json["pid"] as? Double).map(Int.init),
               kill(Int32(pidValue), 0) == 0
            {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
        // Cap hook.log growth.
        let log = dir.appendingPathComponent("hook.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: log.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 512_000
        {
            try? FileManager.default.removeItem(at: log)
        }
    }

    /// Resolve hook state for a live agent (pid / resume id / tty / cwd).
    nonisolated static func resolve(
        pid: Int32,
        resumeID: String?,
        tty: String?,
        cwd: String?,
        states: [Int32: HookState]
    ) -> HookState? {
        if let direct = states[pid] {
            return direct
        }

        let resume = resumeID?.lowercased()
        let candidates = states.values.filter { hook in
            if let resume, let conv = hook.conversationId?.lowercased(), !conv.isEmpty, conv == resume {
                return true
            }
            if let tty, let hookTTY = hook.tty, !hookTTY.isEmpty,
               TerminalController.normalizedTTY(hookTTY) == TerminalController.normalizedTTY(tty)
            {
                return true
            }
            if let cwd, let hookCWD = hook.cwd, !hookCWD.isEmpty,
               (cwd as NSString).standardizingPath == (hookCWD as NSString).standardizingPath
            {
                return true
            }
            return false
        }
        return candidates.max(by: { $0.updatedAt < $1.updatedAt })
    }

    // MARK: - Install

    private static func installHookScript() throws {
        let fm = FileManager.default
        let hooksDir = installedHookScriptURL.deletingLastPathComponent()
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        guard let bundled = Bundle.main.url(forResource: "notchterm-agent-hook", withExtension: "sh")
            ?? Bundle.main.resourceURL?
            .appendingPathComponent("NotchTerm_NotchTerm.bundle")
            .appendingPathComponent("notchterm-agent-hook.sh")
        else {
            throw NSError(domain: "NotchTerm", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bundled hook script missing"
            ])
        }

        if fm.fileExists(atPath: installedHookScriptURL.path) {
            try fm.removeItem(at: installedHookScriptURL)
        }
        try fm.copyItem(at: bundled, to: installedHookScriptURL)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedHookScriptURL.path
        )
    }

    private static func mergeHooksJSON() throws {
        let fm = FileManager.default
        let cursorDir = hooksJSONURL.deletingLastPathComponent()
        try fm.createDirectory(at: cursorDir, withIntermediateDirectories: true)

        var root: [String: Any] = ["version": 1, "hooks": [String: Any]()]
        if fm.fileExists(atPath: hooksJSONURL.path),
           let data = try? Data(contentsOf: hooksJSONURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = parsed
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        // Otty is uninstalled — drop leftover hooks so they don't fail or confuse debugging.
        hooks = stripOttyHooks(hooks)

        let scriptPath = installedHookScriptURL.path
        let runningCmd = "'\(scriptPath)' running"
        let idleCmd = "'\(scriptPath)' idle"

        hooks["sessionStart"] = upsertNotchTermHook(in: hooks["sessionStart"], command: idleCmd)
        hooks["beforeSubmitPrompt"] = upsertNotchTermHook(in: hooks["beforeSubmitPrompt"], command: runningCmd)
        hooks["preToolUse"] = upsertNotchTermHook(in: hooks["preToolUse"], command: runningCmd)
        hooks["beforeShellExecution"] = upsertNotchTermHook(in: hooks["beforeShellExecution"], command: runningCmd)
        hooks["preCompact"] = upsertNotchTermHook(in: hooks["preCompact"], command: runningCmd)
        hooks["stop"] = upsertNotchTermHook(in: hooks["stop"], command: idleCmd)
        hooks["afterAgentResponse"] = upsertNotchTermHook(in: hooks["afterAgentResponse"], command: idleCmd)

        root["version"] = root["version"] ?? 1
        root["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksJSONURL, options: .atomic)
    }

    private static func upsertNotchTermHook(in existing: Any?, command: String) -> [[String: Any]] {
        var entries = (existing as? [[String: Any]]) ?? []
        entries.removeAll { ($0["_notchterm"] as? Bool) == true }
        entries.append([
            "_notchterm": true,
            "command": command
        ])
        return entries
    }

    /// Remove every Otty-tagged hook entry (app is uninstalled).
    private static func stripOttyHooks(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                result[key] = value
                continue
            }
            result[key] = entries.filter { ($0["_otty"] as? Bool) != true }
        }
        return result
    }
}
