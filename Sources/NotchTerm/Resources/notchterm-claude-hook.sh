#!/bin/bash
# NotchTerm ← Claude Code hook (busy / awaiting / idle).
# Args: <running|idle|awaiting_permission|awaiting_question|pretool>
#   pretool → awaiting_question if tool is AskUserQuestion, else running
# stdin: Claude Code hook JSON
# Do not print to stdout on UserPromptSubmit/SessionStart (would inject context).
set +e

STATE="${1:-idle}"
case "$STATE" in
  running|idle|awaiting_permission|awaiting_question|pretool|permission) ;;
  *) STATE="idle" ;;
esac

STATE_DIR="${HOME}/Library/Application Support/com.doautumn.notchterm/agent-state"
LOG="${STATE_DIR}/hook.log"
mkdir -p "$STATE_DIR"

PAYLOAD_FILE="$(mktemp -t notchterm-claude-hook 2>/dev/null || echo "/tmp/notchterm-claude-hook.$$")"
# Use -c so stdin stays the Claude hook JSON (a <<heredoc would steal it).
python3 -c '
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
    deadline = 0.25
open(path, "wb").write(b"".join(chunks))
' "$PAYLOAD_FILE"

# Walk parents for the `claude` CLI PID.
AGENT_PID="$(
python3 - <<'PY'
import os, subprocess
pid = os.getppid()
found = None
for _ in range(16):
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
    base = low.rsplit("/", 1)[-1]
    if (
        base.startswith("claude")
        or "/.local/bin/claude" in low
        or "claude-code" in low
        or "@anthropic-ai/claude" in low
    ):
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

def tool_name(p):
    name = p.get("tool_name") or p.get("toolName") or ""
    if not name:
        t = p.get("tool")
        if isinstance(t, dict):
            name = t.get("name") or ""
    return str(name)

if state == "pretool":
    # AskUserQuestion is a clarifying prompt, not a normal tool run.
    state = "awaiting_question" if tool_name(payload) == "AskUserQuestion" else "running"
elif state == "permission":
    # PermissionRequest also fires for AskUserQuestion; keep「有提问」, don't overwrite with「确认」.
    state = "awaiting_question" if tool_name(payload) == "AskUserQuestion" else "awaiting_permission"

cwd = payload.get("cwd") or ""
conversation_id = (
    payload.get("session_id")
    or payload.get("conversation_id")
    or payload.get("sessionId")
    or ""
)
if isinstance(conversation_id, str):
    conversation_id = conversation_id.lower()
else:
    conversation_id = ""

session_title = payload.get("session_title") or payload.get("sessionTitle") or ""
if not isinstance(session_title, str):
    session_title = ""
session_title = session_title.strip()

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

doc = {
    "pid": pid,
    "state": state,
    "updatedAt": time.time(),
    "conversationId": conversation_id,
    "cwd": cwd,
    "tty": tty,
    "provider": "claude",
    "sessionTitle": session_title,
}

def atomic_write(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.{os.getpid()}.{time.time_ns()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"))
    os.replace(tmp, path)

path = os.path.join(state_dir, f"pid-{pid}.json")
skip = False
try:
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as fh:
            old = json.load(fh)
        same = (
            old.get("state") == state
            and int(old.get("pid") or 0) == pid
            and (old.get("conversationId") or "") == (conversation_id or "")
            and (old.get("cwd") or "") == (cwd or "")
            and (old.get("tty") or "") == (tty or "")
            and (old.get("provider") or "") == "claude"
            and (old.get("sessionTitle") or "") == (session_title or "")
        )
        if same:
            age = time.time() - float(old.get("updatedAt") or 0)
            if state == "idle" or age < 300:
                skip = True
except Exception:
    skip = False

errors = []
if not skip:
    try:
        atomic_write(path, doc)
    except Exception as exc:
        errors.append(f"pid-{pid}.json:{exc!r}")

if not skip or errors:
    try:
        os.makedirs(state_dir, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as fh:
            if errors:
                fh.write(f"{time.time()} write_error {' | '.join(errors)}\n")
            else:
                fh.write(
                    f"{time.time()} ok provider=claude state={state} pid={pid} "
                    f"conv={conversation_id} tty={tty} title={session_title!r} cwd={cwd}\n"
                )
    except Exception:
        pass
PY

rm -f "$PAYLOAD_FILE" 2>/dev/null
exit 0
