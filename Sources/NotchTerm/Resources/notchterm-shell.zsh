# NotchTerm zsh integration — notify long git / package tasks (iTerm only).
# Sourced from ~/.zshrc. Idempotent.
[[ -n "${_NOTCHTERM_SHELL_LOADED:-}" ]] && return
_NOTCHTERM_SHELL_LOADED=1

# Interactive iTerm sessions only.
[[ -o interactive ]] || return 0
[[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] || return 0

typeset -g _NOTCHTERM_TRACKING=0
typeset -g _NOTCHTERM_KIND=""
typeset -g _NOTCHTERM_CMD=""
typeset -g _NOTCHTERM_STATE_DIR="${HOME}/Library/Application Support/com.doautumn.notchterm/task-state"

_notchterm_classify() {
  # Prints kind (git|npm) on match; exit 1 otherwise.
  local low="${(L)1}"

  if [[ "$low" =~ (^|[[:space:]])git[[:space:]]+(clone|fetch|pull)([[:space:]]|$) ]] \
    || [[ "$low" =~ (^|[[:space:]])git-(clone|fetch|pull)([[:space:]]|$) ]]; then
    print -rn -- git
    return 0
  fi

  if [[ "$low" == *"npm run build"* || "$low" == *"npm run test"* \
    || "$low" == *"npm run deploy"* || "$low" == *"npm install"* \
    || "$low" == *"npm i "* || "$low" == "npm i" \
    || "$low" == *"pnpm build"* || "$low" == *"pnpm test"* \
    || "$low" == *"pnpm install"* || "$low" == *"pnpm i "* || "$low" == "pnpm i" \
    || "$low" == *"yarn build"* || "$low" == *"yarn test"* || "$low" == *"yarn install"* \
    || "$low" == *"bun run build"* || "$low" == *"bun run test"* \
    || "$low" == *"bun install"* || "$low" == *"bun i "* || "$low" == "bun i" ]] \
    || [[ "$low" =~ (^|[[:space:]])npm[[:space:]]+i([[:space:]]|$) ]] \
    || [[ "$low" =~ (^|[[:space:]])pnpm[[:space:]]+i([[:space:]]|$) ]] \
    || [[ "$low" =~ (^|[[:space:]])bun[[:space:]]+i([[:space:]]|$) ]]; then
    print -rn -- npm
    return 0
  fi
  return 1
}

_notchterm_title_for() {
  local kind="$1" cmd="$2" low="${(L)2}"
  case "$kind" in
    git)
      if [[ "$low" == *clone* ]]; then print -rn -- "git clone"
      elif [[ "$low" == *fetch* ]]; then print -rn -- "git fetch"
      else print -rn -- "git pull"
      fi
      ;;
    npm)
      if [[ "$low" == *"npm run deploy"* ]]; then print -rn -- "npm run deploy"
      elif [[ "$low" == *"npm run build"* || "$low" == *"pnpm build"* || "$low" == *"yarn build"* || "$low" == *"bun run build"* ]]; then
        print -rn -- "npm run build"
      elif [[ "$low" == *"npm run test"* || "$low" == *"pnpm test"* || "$low" == *"yarn test"* || "$low" == *"bun run test"* ]]; then
        print -rn -- "npm run test"
      elif [[ "$low" == *"install"* || "$low" =~ (^|[[:space:]])(npm|pnpm|bun)[[:space:]]+i([[:space:]]|$) ]]; then
        print -rn -- "npm install"
      else
        print -rn -- "Package task"
      fi
      ;;
    *) print -rn -- "$cmd" ;;
  esac
}

_notchterm_write() {
  local state="$1" kind="$2" cmd="$3"
  local title tty cwd pid
  title="$(_notchterm_title_for "$kind" "$cmd")"
  tty="$(tty 2>/dev/null | sed 's|^/dev/||')"
  cwd="$PWD"
  pid="$$"
  mkdir -p "$_NOTCHTERM_STATE_DIR" 2>/dev/null || return 0

  # Only fire when a tracked command starts/ends — keep this cheap.
  command python3 - "$state" "$kind" "$cmd" "$title" "$pid" "$cwd" "$tty" "$_NOTCHTERM_STATE_DIR" <<'PY'
import json, os, sys, time
state, kind, cmd, title, pid_s, cwd, tty, state_dir = sys.argv[1:9]
try:
    pid = int(pid_s)
except ValueError:
    raise SystemExit(0)
doc = {
    "pid": pid,
    "state": state,
    "kind": kind,
    "command": cmd,
    "title": title,
    "cwd": cwd,
    "tty": tty,
    "updatedAt": time.time(),
}
path = os.path.join(state_dir, f"shell-{pid}.json")
tmp = f"{path}.{os.getpid()}.{time.time_ns()}.tmp"
os.makedirs(state_dir, exist_ok=True)
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, separators=(",", ":"))
os.replace(tmp, path)
PY
}

_notchterm_preexec() {
  local kind
  kind="$(_notchterm_classify "$1")" || {
    _NOTCHTERM_TRACKING=0
    return 0
  }
  _NOTCHTERM_TRACKING=1
  _NOTCHTERM_KIND="$kind"
  _NOTCHTERM_CMD="$1"
  _notchterm_write running "$kind" "$1"
}

_notchterm_precmd() {
  (( _NOTCHTERM_TRACKING )) || return 0
  _notchterm_write idle "$_NOTCHTERM_KIND" "$_NOTCHTERM_CMD"
  _NOTCHTERM_TRACKING=0
  _NOTCHTERM_KIND=""
  _NOTCHTERM_CMD=""
}

autoload -Uz add-zsh-hook 2>/dev/null || return 0
add-zsh-hook preexec _notchterm_preexec
add-zsh-hook precmd _notchterm_precmd
