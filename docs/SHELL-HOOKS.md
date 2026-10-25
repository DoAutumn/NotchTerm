# zsh 长任务钩子

NotchTerm 用 **zsh `preexec` / `precmd`** 感知 git / 包管理长任务（**不做进程表扫描**）。只在 **iTerm** 的交互式 zsh 里生效。

## 会改动哪些路径

| 路径 | 作用 |
|------|------|
| `~/Library/Application Support/com.doautumn.notchterm/shell/notchterm-shell.zsh` | 钩子脚本（启动时从 App 包复制） |
| `~/.zshrc` | 写入标记块 `# >>> notchterm-shell >>>` … `# <<< notchterm-shell <<<`，source 上面的脚本 |

状态文件：

| 路径 | 作用 |
|------|------|
| `~/Library/Application Support/com.doautumn.notchterm/task-state/shell-<pid>.json` | 当前 shell 跟踪中的任务 running/idle |

## 监控的命令

- **git：** `clone` / `fetch` / `pull`
- **npm / pnpm / yarn / bun：** `install` / `i`，以及 `build` / `test` / `deploy`（含 `npm run …`）

## 生效步骤

1. **打开一次 NotchTerm**（自动安装脚本并合并 `~/.zshrc`）
2. **新开一个 iTerm tab**，或在现有 tab 执行 `source ~/.zshrc`
3. 跑例如 `git pull` / `npm run build`，刘海应出现 RUNNING；结束后短暂 DONE

## 限制

- 仅 **zsh** + **`$TERM_PROGRAM=iTerm.app`**
- 非交互、脚本、其它终端不会通知
- 已打开且未重新 source 的旧 session 不会加载钩子

## 卸载（可选）

1. 编辑 `~/.zshrc`，删掉 `# >>> notchterm-shell >>>` 到 `# <<< notchterm-shell <<<` 整块  
2. （可选）删除 `~/Library/Application Support/com.doautumn.notchterm/shell/` 与 `task-state/`
