import Foundation

/// Claude Code pushes busy / awaiting / idle via `~/.claude/settings.json` hooks.
/// State files share `AgentHookService.stateDirectory` with Cursor (keyed by PID + `provider`).
enum ClaudeHookService {
    private static var settingsJSONURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private static var installedHookScriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("notchterm-claude-hook.sh")
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: AgentHookService.stateDirectory,
                withIntermediateDirectories: true
            )
            try installHookScript()
            try mergeSettingsJSON()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Install

    private static func installHookScript() throws {
        let fm = FileManager.default
        let hooksDir = installedHookScriptURL.deletingLastPathComponent()
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        guard let bundled = Bundle.main.url(forResource: "notchterm-claude-hook", withExtension: "sh")
            ?? Bundle.main.resourceURL?
            .appendingPathComponent("NotchTerm_NotchTerm.bundle")
            .appendingPathComponent("notchterm-claude-hook.sh")
        else {
            throw NSError(domain: "NotchTerm", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bundled Claude hook script missing"
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

    private static func mergeSettingsJSON() throws {
        let fm = FileManager.default
        let claudeDir = settingsJSONURL.deletingLastPathComponent()
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsJSONURL.path),
           let data = try? Data(contentsOf: settingsJSONURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = parsed
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        hooks = stripOttyHooks(hooks)

        let scriptPath = installedHookScriptURL.path
        let runningCmd = "'\(scriptPath)' running"
        let idleCmd = "'\(scriptPath)' idle"
        // `permission` remaps AskUserQuestion → awaiting_question (don't clobber「有提问」).
        let permissionCmd = "'\(scriptPath)' permission"
        let pretoolCmd = "'\(scriptPath)' pretool"

        // → running / awaiting_question (script inspects AskUserQuestion)
        hooks["UserPromptSubmit"] = upsertNotchTermMatcherGroup(
            in: hooks["UserPromptSubmit"],
            command: runningCmd
        )
        hooks["PreToolUse"] = upsertNotchTermMatcherGroup(
            in: hooks["PreToolUse"],
            command: pretoolCmd
        )
        // After user approves a tool (or a tool finishes), leave awaiting_* → running.
        // PermissionRequest fires before the prompt; PreToolUse already ran, so without
        // PostToolUse the notch would stay on「确认」until Stop.
        hooks["PostToolUse"] = upsertNotchTermMatcherGroup(
            in: hooks["PostToolUse"],
            command: runningCmd
        )
        hooks["PostToolUseFailure"] = upsertNotchTermMatcherGroup(
            in: hooks["PostToolUseFailure"],
            command: runningCmd
        )
        // User denied the tool — model usually continues; don't leave notch on「确认」.
        hooks["PermissionDenied"] = upsertNotchTermMatcherGroup(
            in: hooks["PermissionDenied"],
            command: runningCmd
        )
        // → awaiting_permission (tool allow/deny prompt)
        hooks["PermissionRequest"] = upsertNotchTermMatcherGroup(
            in: hooks["PermissionRequest"],
            command: permissionCmd
        )
        // Long compact (Cursor parity) — keep notch busy while summarizing.
        hooks["PreCompact"] = upsertNotchTermMatcherGroup(
            in: hooks["PreCompact"],
            command: runningCmd
        )
        // → idle
        hooks["SessionStart"] = upsertNotchTermMatcherGroup(
            in: hooks["SessionStart"],
            command: idleCmd
        )
        hooks["Stop"] = upsertNotchTermMatcherGroup(
            in: hooks["Stop"],
            command: idleCmd
        )
        hooks["StopFailure"] = upsertNotchTermMatcherGroup(
            in: hooks["StopFailure"],
            command: idleCmd
        )
        // Session quit without a clean Stop (faster than PID alive-check).
        hooks["SessionEnd"] = upsertNotchTermMatcherGroup(
            in: hooks["SessionEnd"],
            command: idleCmd
        )

        root["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsJSONURL, options: .atomic)
    }

    /// Claude Code hook groups: `{ matcher?, hooks: [{ type, command }], _notchterm }`.
    private static func upsertNotchTermMatcherGroup(
        in existing: Any?,
        command: String,
        matcher: String? = nil
    ) -> [[String: Any]] {
        var entries = (existing as? [[String: Any]]) ?? []
        entries.removeAll { ($0["_notchterm"] as? Bool) == true }
        var group: [String: Any] = [
            "_notchterm": true,
            "hooks": [
                [
                    "type": "command",
                    "command": command
                ]
            ]
        ]
        if let matcher, !matcher.isEmpty {
            group["matcher"] = matcher
        }
        entries.append(group)
        return entries
    }

    private static func stripOttyHooks(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                result[key] = value
                continue
            }
            result[key] = entries.filter { entry in
                if (entry["_otty"] as? Bool) == true { return false }
                // Also drop unmarked leftovers that still call Otty's script.
                let blob = String(describing: entry).lowercased()
                if blob.contains("otty-hook.sh") || blob.contains("otty.app") {
                    return false
                }
                return true
            }
        }
        return result
    }
}
