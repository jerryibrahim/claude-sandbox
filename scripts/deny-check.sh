#!/usr/bin/env bash
set -euo pipefail

PATTERNS_FILE="${DENY_PATTERNS_FILE:-/etc/claude-sandbox/denied-commands.txt}"

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"

# No command (non-Bash tool or empty) → allow.
[ -z "$cmd" ] && exit 0

# Patterns file missing → fail closed.
if [ ! -r "$PATTERNS_FILE" ]; then
  echo "deny-check: cannot read $PATTERNS_FILE; blocking" >&2
  exit 2
fi

while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  case "$pattern" in \#*) continue ;; esac
  if printf '%s' "$cmd" | grep -Eq -- "$pattern"; then
    echo "Blocked by sandbox denylist (pattern: $pattern): $cmd" >&2
    exit 2
  fi
done < "$PATTERNS_FILE"

exit 0
