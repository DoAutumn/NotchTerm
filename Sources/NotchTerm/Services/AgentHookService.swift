import Foundation

/// Cursor Agent CLI pushes busy/idle via `~/.cursor/hooks.json`.
/// This is the **primary** signal for NotchTerm agent state.
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
        }

        let pid: Int32
        let state: Value
        let updatedAt: Date
        let conversationId: String?
        let cwd: String?
        let tty: String?
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

            // Drop stale pushes (crashed mid-turn, etc.) so the directory cannot grow forever.
            guard now.timeIntervalSince(updatedAt) < 6 * 60 * 60 else {
                try? FileManager.default.removeItem(at: url)
                continue
            }

            let pid = Int32(pidValue)
            let hook = HookState(
                pid: pid,
                state: state,
                updatedAt: updatedAt,
                conversationId: json["conversationId"] as? String,
                cwd: json["cwd"] as? String,
                tty: json["tty"] as? String
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
            if now.timeIntervalSince(mtime) >= 6 * 60 * 60 {
                try? FileManager.default.removeItem(at: url)
            }
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
               ITermController.normalizedTTY(hookTTY) == ITermController.normalizedTTY(tty)
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
        // Drop dead Otty hooks (app uninstalled) so they don't confuse debugging.
        hooks = stripBrokenOttyHooks(hooks)

        let scriptPath = installedHookScriptURL.path
        let runningCmd = "'\(scriptPath)' running"
        let idleCmd = "'\(scriptPath)' idle"

        hooks["sessionStart"] = upsertNotchTermHook(in: hooks["sessionStart"], command: idleCmd)
        hooks["beforeSubmitPrompt"] = upsertNotchTermHook(in: hooks["beforeSubmitPrompt"], command: runningCmd)
        hooks["preToolUse"] = upsertNotchTermHook(in: hooks["preToolUse"], command: runningCmd)
        hooks["beforeShellExecution"] = upsertNotchTermHook(in: hooks["beforeShellExecution"], command: runningCmd)
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

    private static func stripBrokenOttyHooks(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                result[key] = value
                continue
            }
            let kept = entries.filter { entry in
                guard (entry["_otty"] as? Bool) == true else { return true }
                let command = entry["command"] as? String ?? ""
                // Keep only if the otty-hook.sh path still exists.
                if let range = command.range(of: "'/"),
                   let end = command[range.upperBound...].firstIndex(of: "'")
                {
                    let path = String(command[range.upperBound..<end])
                    if path.contains("otty-hook.sh") {
                        return FileManager.default.isExecutableFile(atPath: path)
                    }
                }
                return false
            }
            result[key] = kept
        }
        return result
    }
}
