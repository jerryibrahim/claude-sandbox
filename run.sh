#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Host directory mounted read-write at /code. Resolution: shell env > .env >
# default. docker compose also reads .env for the volume interpolation; we read
# it here too so run.sh's own path checks (resolve_workdir) agree with the mount.
# Must be an absolute path — the .env value is used verbatim (no ~/$HOME expansion).
SANDBOX_ROOT="${SANDBOX_ROOT:-$(grep -E '^SANDBOX_ROOT=' "$SCRIPT_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)}"
SANDBOX_ROOT="${SANDBOX_ROOT:-$HOME/code}"
export SANDBOX_ROOT
# Host directory bind-mounted as Claude's home (persistent state/backups).
# Defined in .env (CLAUDE_HOME_HOST=...). Resolution: shell env > .env > default.
# docker compose also reads .env for the volume interpolation; we read it here so
# host-side commands (e.g. --restore-config) agree on the same path.
CLAUDE_HOME_HOST="${CLAUDE_HOME_HOST:-$(grep -E '^CLAUDE_HOME_HOST=' "$SCRIPT_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)}"
CLAUDE_HOME_HOST="${CLAUDE_HOME_HOST:-/Users/claude}"
export CLAUDE_HOME_HOST

usage() {
  cat >&2 <<EOF
Usage:
  $0 <repo> [prompt...]   Start (if needed) the shared sandbox and open a Claude
                          session scoped to <repo> (a path under SANDBOX_ROOT).
                          No prompt = interactive; a text prompt = headless (-p).
  $0 <repo> --resume [id] Resume a prior session in <repo> (interactive). Any
                          args starting with '-' (or everything after '--') are
                          forwarded raw to claude, e.g. --continue.
  $0 --stop               Stop the shared sandbox container.
  $0 --list               Show container status and active sessions.
  $0 --restore-config     Restore claude_home/.claude.json from newest backup.

SANDBOX_ROOT=$SANDBOX_ROOT
EOF
  exit 1
}

# Echo the container working dir for a repo under the root.
# Returns 1 if <repo> is not a directory, 2 if it is outside <root>.
resolve_workdir() {
  local repo="$1" root="$2" repo_abs root_abs
  [ -d "$repo" ] || return 1
  repo_abs="$(cd "$repo" && pwd)" || return 1
  root_abs="$(cd "$root" && pwd)" || return 2
  if [ "$repo_abs" = "$root_abs" ]; then echo "/code"; return 0; fi
  case "$repo_abs/" in
    "$root_abs"/*) echo "/code/${repo_abs#"$root_abs"/}"; return 0 ;;
    *) return 2 ;;
  esac
}

# Decide how to launch claude for the given post-repo session args:
#   interactive : no args
#   raw         : first arg is "--", or starts with "-" (forward raw to claude,
#                 interactive — e.g. --resume <id>, --continue)
#   prompt      : otherwise (headless one-shot: claude -p "<args>")
session_mode() {
  if [ "$#" -eq 0 ]; then echo interactive
  elif [ "$1" = "--" ]; then echo raw
  elif [ "${1#-}" != "$1" ]; then echo raw
  else echo prompt
  fi
}

# Generate a lowercase UUID for a new Claude session id.
gen_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    cat /proc/sys/kernel/random/uuid 2>/dev/null
  fi
}

cmd_stop()  { cd "$SCRIPT_DIR"; docker compose down; }
cmd_list()  {
  cd "$SCRIPT_DIR"; docker compose ps
  echo "active sessions (pid → repo → session id):"
  # Claude writes ~/.claude/sessions/<pid>.json at session start (before the
  # first turn), with the exact sessionId and cwd. Read it for each live session
  # PID. pgrep enumerates live PIDs (the files are PID-named and can go stale);
  # the pattern is passed via env ($PAT) so this command's own `sh -c` argv can't
  # match itself. Run as the claude user (same uid) to read the processes/files.
  docker exec -e PAT=dangerously-skip-permissions --user claude claude-sandbox sh -c '
    found=0
    for pid in $(pgrep -f "$PAT" 2>/dev/null); do
      meta="/home/claude/.claude/sessions/$pid.json"
      sid=""; cwd=""
      if [ -f "$meta" ]; then
        sid=$(jq -r ".sessionId // empty" "$meta" 2>/dev/null)
        cwd=$(jq -r ".cwd // empty" "$meta" 2>/dev/null)
      fi
      [ -z "$cwd" ] && cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
      echo "  $pid  ${cwd:-(unknown)}  ${sid:-(none)}"
      found=1
    done
    [ "$found" = 1 ] || echo "  (none)"
  ' 2>/dev/null || echo "  (container stopped)"
}
cmd_restore() {
  local f="$CLAUDE_HOME_HOST/.claude.json"
  [ -f "$f.bak.1" ] || { echo "no backup at $f.bak.1" >&2; exit 1; }
  cp -p "$f.bak.1" "$f" && echo "restored $f from $f.bak.1 (stop the container first if a session is running)"
}

# Start the sandbox container and wait until it is in the Running state.
# Polls up to 5 times (1s apart) to close the race between `up -d` and exec.
ensure_up() {
  docker compose up -d
  for i in 1 2 3 4 5; do
    [ "$(docker inspect -f '{{.State.Running}}' claude-sandbox 2>/dev/null)" = "true" ] && return 0
    sleep 1
  done
  return 1
}

main() {
  local arg="${1:-}"
  case "$arg" in
    "")             usage ;;
    --stop)         cmd_stop; exit $? ;;
    --list)         cmd_list; exit $? ;;
    --restore-config) cmd_restore; exit $? ;;
  esac

  local repo="$1"; shift
  local workdir rc=0
  workdir="$(resolve_workdir "$repo" "$SANDBOX_ROOT")" || rc=$?
  if [ "$rc" -eq 1 ]; then echo "Error: not a directory: $repo" >&2; usage; fi
  if [ "$rc" -eq 2 ]; then echo "Error: $repo is not under SANDBOX_ROOT ($SANDBOX_ROOT)" >&2; usage; fi

  cd "$SCRIPT_DIR"
  ensure_up || { echo "Error: sandbox container did not start (check auth in .env / docker)" >&2; exit 1; }

  case "$(session_mode "$@")" in
    interactive)
      local sid; sid="$(gen_session_id)"
      echo "session id: $sid  (resume: $0 $repo --resume $sid)" >&2
      exec docker compose exec --user claude -w "$workdir" claude-sandbox \
        claude --dangerously-skip-permissions --session-id "$sid" ;;
    raw)
      # Passthrough (e.g. --resume <id>): the id already exists, don't assign one.
      [ "${1:-}" = "--" ] && shift
      exec docker compose exec --user claude -w "$workdir" claude-sandbox \
        claude --dangerously-skip-permissions "$@" ;;
    prompt)
      local sid; sid="$(gen_session_id)"
      echo "session id: $sid" >&2
      exec docker compose exec -T --user claude -w "$workdir" claude-sandbox \
        claude --dangerously-skip-permissions --session-id "$sid" -p "$*" ;;
  esac
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  main "$@"
fi
