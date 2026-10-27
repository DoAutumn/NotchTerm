# NotchTerm

Cursor Agent and long git / package tasks in your Mac’s notch — driven by hooks, not process scanning.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://developer.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/CPU-Apple%20Silicon-black?logo=apple)](https://support.apple.com/en-us/HT211814)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)

---

## What it does

- Shows **Cursor Agent** and long **git** / **npm·pnpm·yarn·bun** work in the notch (compact strip; hover or click to expand)
- **No process-table polling.** Signals come from:
  - Cursor Agent CLI [hooks](docs/CURSOR-HOOKS.md)
  - zsh [shell hooks](docs/SHELL-HOOKS.md) in **iTerm** (`preexec` / `precmd`)
- Idle agents stay out of the notch; when a turn or long command finishes, a short **DONE** banner appears (~4.5s) — click it to jump to that iTerm session
- Click a running task to **focus its iTerm tab**
- Optional Music Player now-playing and stock watcher in the same strip
- Menu-bar accessory app; optional Login Items and completion notifications (notifications default **off**)

## Requirements

- macOS 13+
- **Apple Silicon** (arm64). The release `.app` is arm64-only
- [iTerm2](https://iterm2.com/)
- Cursor Agent CLI for agent busy/idle (hooks install on first NotchTerm launch)
- **zsh** for git/package task notifications (snippet installed into `~/.zshrc` on launch)

## Build & run

```bash
swift run NotchTerm
```

Standalone `.app` (arm64):

```bash
./scripts/build-app.sh
open dist/NotchTerm.app
```

Release zip (optional):

```bash
./scripts/build-zip.sh
```

## Hooks

On launch, NotchTerm:

1. Merges Cursor hooks into `~/.cursor/hooks.json` and installs `notchterm-agent-hook.sh`
2. Installs `notchterm-shell.zsh` and a marked snippet in `~/.zshrc`

After installing or updating NotchTerm: **open NotchTerm once**, then **restart agent sessions** and **open a new iTerm tab** (or `source ~/.zshrc`) so hooks reload.

- Agent details: [docs/CURSOR-HOOKS.md](docs/CURSOR-HOOKS.md)
- Shell details: [docs/SHELL-HOOKS.md](docs/SHELL-HOOKS.md)

## Permissions

Grant **Automation** access for iTerm (System Settings → Privacy & Security → Automation) so NotchTerm can list sessions and focus the right tab.

Ad-hoc signed local builds may need to re-grant Automation after each rebuild; a stable local signing identity keeps the grant.

## Privacy

100% local. No accounts, no telemetry, no cloud sync. State files live under `~/Library/Application Support/com.doautumn.notchterm/`.

## License

MIT
