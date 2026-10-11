<div align="center">

<img src="public/renotch_logo.png" alt="Re:notch" width="120">

# Re:notch

Monitor long-running iTerm tasks in your Mac's notch — `git clone`, package builds, and Cursor Agent.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)

</div>

---

## What it does

- Watches **iTerm** for long tasks: `git clone|fetch|pull`, `npm/pnpm/yarn/bun` install/build/test, and **Cursor Agent** (`agent` / `cursor-agent`)
- Shows each task as a notch tab (current + “+N more” menu when there are many)
- Keeps idle Agent sessions until they exit; animates when Agent finishes outputting
- Click a task to **jump to and focus** its iTerm session
- Optional system notifications (default **off**)

## Install

### Homebrew

```bash
brew tap DoAutumn/tap
brew install --cask renotch
```

### Build from source

```bash
git clone https://github.com/DoAutumn/renotch.git
cd renotch
swift run Renotch
```

Standalone `.app`:

```bash
./scripts/build-app.sh
```

Release zip / dmg:

```bash
./scripts/build-zip.sh
./scripts/build-dmg.sh
```

## Permissions

Grant **Automation** access for iTerm (System Settings → Privacy & Security → Automation) so Re:notch can read session state and focus the right tab.

## Privacy

100% local. No accounts, no telemetry, no cloud sync.

## License

MIT
