# Cursor 钩子与重装说明

NotchTerm **只靠** Cursor Agent CLI 的 hooks 判断 Agent 是否出现、以及 RUNNING / IDLE（不做进程表扫描）。相关文件写在用户目录的 `~/.cursor/` 下，**不属于 NotchTerm.app 本身**。

## NotchTerm 会改动哪些路径

| 路径 | 作用 |
|------|------|
| `~/.cursor/hooks/notchterm-agent-hook.sh` | 钩子脚本：收到事件后把 busy/idle 写到状态目录 |
| `~/.cursor/hooks.json` | 合并注册 NotchTerm 关心的事件（带 `"_notchterm": true` 标记，不覆盖你其它钩子） |

状态文件（钩子运行后产生，不在 `~/.cursor/`）：

| 路径 | 作用 |
|------|------|
| `~/Library/Application Support/com.doautumn.notchterm/agent-state/*.json` | 各 Agent 的 running/idle |
| `~/Library/Application Support/com.doautumn.notchterm/agent-state/hook.log` | 钩子执行日志（排错用） |

当前注册的事件：

- **→ running：** `beforeSubmitPrompt`、`preToolUse`、`beforeShellExecution`、`preCompact`（含 `/summarize` 与自动压缩）
- **→ idle：** `sessionStart`、`stop`、`afterAgentResponse`

## 重装 Cursor 之后要做什么

### 多数情况：不用手动折腾

1. **再打开一次 NotchTerm**  
   启动时会调用 `AgentHookService.ensureInstalled()`，自动：
   - 重新复制 `notchterm-agent-hook.sh`
   - 重新把 NotchTerm 条目合并进 `~/.cursor/hooks.json`（保留你其它钩子）

2. **重启已在跑的 `agent` 会话**  
   已启动的 CLI 不会自动重载 hooks。对每个相关会话执行一次，例如：

   ```bash
   agent --resume=<conversation-id>
   ```

   或退出后重新开一个 agent。

3. **自检**  
   发一条消息后应出现：

   ```bash
   tail -5 ~/Library/Application\ Support/com.doautumn.notchterm/agent-state/hook.log
   ```

   看到 `ok state=running ...` 即表示钩子生效；刘海应显示 RUNNING。

### 若重装清掉了整个 `~/.cursor`

同上：先开 NotchTerm，再重启 agent。无需从本仓库手动拷文件（脚本打在 App 包里）。

### 若你只想手动恢复（可选）

一般不需要。若要用命令行确认：

```bash
# 钩子脚本是否存在且可执行
ls -l ~/.cursor/hooks/notchterm-agent-hook.sh

# hooks.json 里是否有 _notchterm 条目
python3 -c "import json; h=json.load(open('$HOME/.cursor/hooks.json')); print(sorted(h.get('hooks',{})))"
```

缺失时：**启动 NotchTerm 一次**即可写回。

## 卸载 NotchTerm 时（可选清理）

删除 App 不会自动清理 `~/.cursor`。若要手动去掉 NotchTerm 钩子：

1. 编辑 `~/.cursor/hooks.json`，删掉所有 `"_notchterm": true` 的条目  
2. 删除 `~/.cursor/hooks/notchterm-agent-hook.sh`  
3. （可选）删除 `~/Library/Application Support/com.doautumn.notchterm/`

## 注意

- `hooks.json` 是**用户级全局配置**，PromptQy / 其它工具也可能往里写；NotchTerm 用 `_notchterm` 标记自己的条目，合并时不会整文件覆盖。
- 重装 Cursor **不会**删掉 `Application Support` 里的 agent-state；一般可留着。
- 企业/团队级 hooks 若另有配置，以 Cursor 文档的优先级为准；用户级 `~/.cursor/hooks.json` 仍需存在对应事件名，CLI 才容易触发。
