#!/usr/bin/env bash
set -uo pipefail

CLAUDE_JSON="${CLAUDE_JSON:-/home/claude/.claude.json}"
BACKUP_KEEP="${BACKUP_KEEP:-3}"
SANDBOX_IDLE_TIMEOUT="${SANDBOX_IDLE_TIMEOUT:-1800}"
HOLDER_POLL_INTERVAL="${HOLDER_POLL_INTERVAL:-60}"

# Back up $1 (keeping newest $2) only when its content changed since last backup.
backup_claude_json() {
  local f="$1" keep="$2"
  [ -f "$f" ] || return 0
  local sum last i
  sum="$(sha256sum "$f" | cut -d' ' -f1)"
  last="${f}.lastsum"
  if [ -f "$last" ] && [ "$(cat "$last")" = "$sum" ]; then
    return 0
  fi
  for (( i=keep; i>1; i-- )); do
    [ -f "${f}.bak.$((i-1))" ] && cp -p "${f}.bak.$((i-1))" "${f}.bak.$i"
  done
  cp -p "$f" "${f}.bak.1"
  printf '%s' "$sum" > "$last"
}

# True when at least one Claude session process is running.
# Detection contract: run.sh always launches Claude with --dangerously-skip-permissions,
# so that flag token in a process's argv is the install-independent marker of an active
# session regardless of whether the native binary or the node cli-wrapper is used.
claude_sessions_running() {
  pgrep -f 'dangerously-skip-permissions' >/dev/null 2>&1
}

main() {
  local last_active now
  last_active="$(date +%s)"
  while true; do
    backup_claude_json "$CLAUDE_JSON" "$BACKUP_KEEP"
    if claude_sessions_running; then
      last_active="$(date +%s)"
    fi
    now="$(date +%s)"
    if (( now - last_active >= SANDBOX_IDLE_TIMEOUT )); then
      echo "holder: idle ${SANDBOX_IDLE_TIMEOUT}s with no sessions, stopping container"
      exit 0
    fi
    sleep "$HOLDER_POLL_INTERVAL"
  done
}

if [ "${HOLDER_TEST:-}" != "1" ]; then
  main
fi
