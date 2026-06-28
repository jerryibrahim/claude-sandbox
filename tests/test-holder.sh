#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export HOLDER_TEST=1
# shellcheck disable=SC1090
source "$HERE/../scripts/holder.sh"

fail=0
check() { local d="$1" exp="$2" act="$3"; if [ "$exp" != "$act" ]; then echo "FAIL: $d (exp $exp got $act)"; fail=1; else echo "PASS: $d"; fi; }

tmp="$(mktemp -d)"
f="$tmp/.claude.json"
echo '{"v":1}' > "$f"

backup_claude_json "$f" 3
check "first backup created" 1 "$([ -f "$f.bak.1" ] && echo 1 || echo 0)"

# Unchanged content → no new/rotated backup.
cp -p "$f.bak.1" "$tmp/snap1"
backup_claude_json "$f" 3
check "no rotation when unchanged" 1 "$(cmp -s "$f.bak.1" "$tmp/snap1" && [ ! -f "$f.bak.2" ] && echo 1 || echo 0)"

# Change content → rotate (old becomes .bak.2, new is .bak.1).
echo '{"v":2}' > "$f"
backup_claude_json "$f" 3
check "rotated on change" 1 "$([ -f "$f.bak.2" ] && grep -q '"v":2' "$f.bak.1" && grep -q '"v":1' "$f.bak.2" && echo 1 || echo 0)"

# main exits 0 promptly when idle timeout is 0 and no sessions run.
( SANDBOX_IDLE_TIMEOUT=0 HOLDER_POLL_INTERVAL=0 CLAUDE_JSON="$f" main ) >/dev/null 2>&1
check "main exits 0 when idle" 0 "$?"

rm -rf "$tmp"
exit $fail
