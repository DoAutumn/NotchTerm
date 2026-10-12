# NotchTerm

Long-running iTerm tasks in your Mac’s notch — git, package builds, and Cursor Agent.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://developer.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/CPU-Apple%20Silicon-black?logo=apple)](https://support.apple.com/en-us/HT211814)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)

---

## What it does

- Watches **iTerm** for long tasks: `git clone|fetch|pull`, `npm` / `pnpm` / `yarn` / `bun` install·build·test, and **Cursor Agent** (`agent` / `cursor-agent`)
- Shows active work in the notch (compact strip; hover or click to expand). Multiple tasks → current tab + `+N` menu
- **Cursor Agent busy/idle** comes only from CLI [hooks](docs/CURSOR-HOOKS.md) (`beforeSubmitPrompt` → RUNNING, `stop` / `afterAgentResponse` → IDLE). No scrollback or transcript guessing
- Idle agents stay out of the notch; when an agent finishes a turn, a short **DONE** banner appears (~4.5s) — click it to jump to that iTerm session
- Click a running task to **focus its iTerm tab**
- Menu-bar accessory app; optional Login Items and completion notifications (notifications default **off**)

## Requirements

- macOS 13+
- **Apple Silicon** (arm64). The release `.app` is arm64-only
- [iTerm2](https://iterm2.com/)
- Cursor Agent CLI for agent busy/idle (hooks install on first NotchTerm launch)

## Build & run

```bash
swift run NotchTerm
```

Standalone `.app` (arm64):

```bash
./scripts/build-app.sh
open dist/NotchTerm.app
```

DMG / zip (optional):

```bash
./scripts/build-dmg.sh
./scripts/build-zip.sh
```

## Cursor Agent hooks

On launch, NotchTerm merges its hooks into `~/.cursor/hooks.json` and installs `~/.cursor/hooks/notchterm-agent-hook.sh`.

After installing or updating NotchTerm (or reinstalling Cursor), **open NotchTerm once**, then **restart each `agent` session** so the CLI reloads hooks.

Details and troubleshooting: [docs/CURSOR-HOOKS.md](docs/CURSOR-HOOKS.md).

## Permissions

Grant **Automation** access for iTerm (System Settings → Privacy & Security → Automation) so NotchTerm can list sessions and focus the right tab.

Ad-hoc signed local builds may need to re-grant Automation after each rebuild; a stable local signing identity keeps the grant.

## Privacy

100% local. No accounts, no telemetry, no cloud sync. Agent state files live under `~/Library/Application Support/com.doautumn.notchterm/`.

## License

MIT
