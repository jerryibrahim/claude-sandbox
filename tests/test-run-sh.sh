#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../run.sh"
# shellcheck disable=SC1090
source "$RUN"   # defines functions; main is guarded out when sourced
set +e           # restore no-e mode so we can capture non-zero rc from resolve_workdir assertions

fail=0
check() { local d="$1" exp="$2" act="$3"; if [ "$exp" != "$act" ]; then echo "FAIL: $d (exp $exp got $act)"; fail=1; else echo "PASS: $d"; fi; }

root="$(mktemp -d)"
mkdir -p "$root/repoA/sub"

out="$(resolve_workdir "$root/repoA" "$root")"; rc=$?
check "subdir → /code/repoA (rc)" 0 "$rc"
check "subdir → /code/repoA (path)" "/code/repoA" "$out"

out="$(resolve_workdir "$root/repoA/sub" "$root")"; rc=$?
check "nested → /code/repoA/sub" "/code/repoA/sub" "$out"

out="$(resolve_workdir "$root" "$root")"; rc=$?
check "root itself → /code" "/code" "$out"

resolve_workdir "/no/such/dir" "$root" >/dev/null 2>&1
check "missing dir → rc 1" 1 "$?"

outside="$(mktemp -d)"
resolve_workdir "$outside" "$root" >/dev/null 2>&1
check "outside root → rc 2" 2 "$?"

# session_mode: how post-repo args select the launch style.
check "no args → interactive"       interactive "$(session_mode)"
check "text prompt → prompt"        prompt      "$(session_mode "summarize this repo")"
check "--resume <id> → raw"         raw         "$(session_mode --resume bca49d66)"
check "--continue → raw"            raw         "$(session_mode --continue)"
check "-- passthrough → raw"        raw         "$(session_mode -- --resume bca49d66)"

# gen_session_id: lowercase UUID shape (8-4-4-4-12 hex).
sid="$(gen_session_id)"
echo "$sid" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
check "gen_session_id → lowercase uuid" 0 "$?"

rm -rf "$root" "$outside"
exit $fail
