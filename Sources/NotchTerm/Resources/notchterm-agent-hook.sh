#!/bin/bash
# NotchTerm ← Cursor Agent CLI hook (PRIMARY busy/idle signal).
# beforeSubmitPrompt / preToolUse / beforeShellExecution / preCompact → running
# stop / afterAgentResponse / sessionStart → idle
# Args: <running|idle>
# stdin: Cursor hook JSON (Cursor may append a heredoc)
set +e

STATE="${1:-idle}"
case "$STATE" in
  running|idle) ;;
  *) STATE="idle" ;;
esac

STATE_DIR="${HOME}/Library/Application Support/com.doautumn.notchterm/agent-state"
LOG="${STATE_DIR}/hook.log"
mkdir -p "$STATE_DIR"

PAYLOAD_FILE="$(mktemp -t notchterm-hook 2>/dev/null || echo "/tmp/notchterm-hook.$$")"
# Bounded stdin read — never hang if Cursor leaves the hook pipe open.
python3 - "$PAYLOAD_FILE" <<'PY'
import select, sys
path = sys.argv[1]
chunks = []
deadline = 2.0
while True:
    ready, _, _ = select.select([sys.stdin.buffer], [], [], deadline)
    if not ready:
        break
    chunk = sys.stdin.buffer.read(65536)
    if not chunk:
        break
    chunks.append(chunk)
    deadline = 0.25  # short idle gap after first bytes
open(path, "wb").write(b"".join(chunks))
PY

# Find agent PID by walking parents from the hook's parent shell.
AGENT_PID="$(
python3 - <<'PY'
import os, subprocess
pid = os.getppid()
found = None
for _ in range(14):
    try:
        out = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "pid=,ppid=,command="],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        break
    if not out:
        break
    parts = out.split(None, 2)
    if len(parts) < 3:
        break
    cur, ppid_s, cmd = parts[0], parts[1], parts[2]
    low = cmd.lower()
    if "cursor-agent" in low or "/.local/bin/agent" in low or "cursor-agent/versions" in low:
        found = cur
        break
    try:
        pid = int(ppid_s)
    except ValueError:
        break
    if pid <= 1:
        break
print(found or os.getppid())
PY
)"

python3 - "$STATE" "$AGENT_PID" "$STATE_DIR" "$PAYLOAD_FILE" "$LOG" <<'PY'
import json, os, subprocess, sys, time

state, pid_s, state_dir, payload_path, log_path = sys.argv[1:6]
try:
    pid = int(pid_s)
except ValueError:
    pid = os.getppid()

payload = {}
try:
    raw = open(payload_path, "r", encoding="utf-8").read().strip()
    if raw:
        payload = json.loads(raw)
except Exception as exc:
    open(log_path, "a", encoding="utf-8").write(f"{time.time()} parse_error {exc!r}\n")

cwd = payload.get("cwd") or ""
roots = payload.get("workspace_roots")
if not cwd and isinstance(roots, list) and roots:
    cwd = roots[0] or ""
conversation_id = (payload.get("conversation_id") or payload.get("session_id") or "").lower()

tty = ""
try:
    out = subprocess.check_output(
        ["ps", "-p", str(pid), "-o", "tty="],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
    if out and out != "??":
        tty = out.replace("/dev/", "")
except Exception:
    pass

# Also try to extract --resume id from the agent command line.
resume = ""
try:
    cmd = subprocess.check_output(
        ["ps", "-p", str(pid), "-o", "command="],
        text=True,
        stderr=subprocess.DEVNULL,
    )
    import re
    m = re.search(r"--resume\s+([0-9a-fA-F-]{36})", cmd)
    if m:
        resume = m.group(1).lower()
except Exception:
    pass
if not conversation_id and resume:
    conversation_id = resume

doc = {
    "pid": pid,
    "state": state,
    "updatedAt": time.time(),
    "conversationId": conversation_id,
    "cwd": cwd,
    "tty": tty,
}

def atomic_write(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    # Unique tmp avoids races when many hooks fire in the same millisecond.
    tmp = f"{path}.{os.getpid()}.{time.time_ns()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"))
    os.replace(tmp, path)

errors = []
for name, enabled in (
    (f"pid-{pid}.json", True),
    (f"conv-{conversation_id}.json", bool(conversation_id)),
    (f"tty-{tty}.json", bool(tty)),
):
    if not enabled:
        continue
    try:
        atomic_write(os.path.join(state_dir, name), doc)
    except Exception as exc:
        errors.append(f"{name}:{exc!r}")

try:
    os.makedirs(state_dir, exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as fh:
        if errors:
            fh.write(f"{time.time()} write_error {' | '.join(errors)}\n")
        else:
            fh.write(
                f"{time.time()} ok state={state} pid={pid} conv={conversation_id} tty={tty} cwd={cwd}\n"
            )
except Exception:
    pass

# beforeSubmitPrompt must allow continue
print("{}")
PY

rm -f "$PAYLOAD_FILE" 2>/dev/null
exit 0
