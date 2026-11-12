# Claude Code 钩子与重装说明

NotchTerm 通过 Claude Code 的 hooks 判断会话是否 RUNNING / 等待确认 / 有提问 / IDLE（不做进程表扫描）。配置写在用户目录的 `~/.claude/` 下，**不属于 NotchTerm.app 本身**。

## NotchTerm 会改动哪些路径

| 路径 | 作用 |
|------|------|
| `~/.claude/hooks/notchterm-claude-hook.sh` | 钩子脚本：收到事件后把状态写到共享状态目录 |
| `~/.claude/settings.json` | 合并注册 NotchTerm 关心的事件（带 `"_notchterm": true` 标记，不覆盖你其它钩子；启动时会去掉 Otty 遗留条目） |

状态文件（与 Cursor Agent 共用）：

| 路径 | 作用 |
|------|------|
| `~/Library/Application Support/com.doautumn.notchterm/agent-state/*.json` | 各 Agent 的状态（含 `"provider":"claude"`） |
| `~/Library/Application Support/com.doautumn.notchterm/agent-state/hook.log` | 钩子执行日志（排错用） |

当前注册的事件：

- **→ running：** `UserPromptSubmit`、`PreToolUse`（非 `AskUserQuestion`）、`PostToolUse`、`PostToolUseFailure`、`PermissionDenied`、`PreCompact`
- **→ 有提问：** `PreToolUse` 且工具为 `AskUserQuestion`
- **→ 等待确认：** `PermissionRequest`（工具非 `AskUserQuestion`；提问类仍保持「有提问」）
- **→ idle：** `SessionStart`、`Stop`、`StopFailure`、`SessionEnd`

`PermissionRequest` 发生在工具真正执行之前，且同一次调用的 `PreToolUse` 已经先写成 running；用户点允许之后靠 `PostToolUse`（或后续 `PreToolUse`）拉回 running；点拒绝靠 `PermissionDenied`。否则会一直停在「确认」直到 `Stop`。

状态文件超过约 6 小时未更新时，仅在对应 **PID 已不存在** 时才 prune；进程仍在（例如长时间停在权限/提问提示）会保留，避免误清刘海并闪假 DONE。

标题：优先使用 hook 里的 `session_title`（如 `/rename`）；否则用 iTerm / Ghostty 标签名；再否则显示「Claude」。

## 重装 / 更新之后要做什么

1. **再打开一次 NotchTerm**  
   启动时会调用 `ClaudeHookService.ensureInstalled()`，自动复制脚本并合并 hooks。

2. **重启已在跑的 `claude` 会话**  
   已启动的 CLI 不会自动重载 hooks。

3. **自检**

   ```bash
   tail -5 ~/Library/Application\ Support/com.doautumn.notchterm/agent-state/hook.log
   ```

   看到 `ok provider=claude state=...` 即表示钩子生效。

## 卸载 NotchTerm 时（可选清理）

1. 编辑 `~/.claude/settings.json`，删掉所有 `"_notchterm": true` 的条目  
2. 删除 `~/.claude/hooks/notchterm-claude-hook.sh`  
3. （可选）删除 `~/Library/Application Support/com.doautumn.notchterm/`

## 注意

- Claude 的 `UserPromptSubmit` / `SessionStart` 会把 hook 的 **stdout** 注入上下文；NotchTerm 的脚本因此不向 stdout 打印内容。
- `PermissionRequest` 钩子只观察状态，不会代你允许或拒绝工具。
- Cursor 目前没有「等待批准」专用 hook，因此「等待确认 / 有提问」仅适用于 Claude Code。
