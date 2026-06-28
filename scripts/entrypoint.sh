#!/usr/bin/env bash
set -euo pipefail

CLAUDE_HOME=/home/claude/.claude

# 1. Apply the egress firewall (requires NET_ADMIN/NET_RAW).
/opt/claude-sandbox/init-firewall.sh

# 2. Install sandbox Claude settings (hook + deny backup).
install -D -m 0644 /etc/claude-sandbox/claude-settings.json "$CLAUDE_HOME/settings.json"

# 3. Report authentication source (non-fatal).
# Precedence: ANTHROPIC_API_KEY > CLAUDE_CODE_OAUTH_TOKEN > credentials persisted
# in the Claude home (from a prior `claude /login`). Env-var tokens are inherited
# by the claude process through gosu. The container does NOT require auth to
# start — only Claude sessions need it, and an interactive session can log in
# itself. So this only reports; it never exits.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "entrypoint: auth = ANTHROPIC_API_KEY"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "entrypoint: auth = CLAUDE_CODE_OAUTH_TOKEN (subscription token)"
elif [ -f "$CLAUDE_HOME/.credentials.json" ]; then
  echo "entrypoint: auth = persisted login credentials"
else
  echo "entrypoint: auth = none preconfigured — interactive sessions will prompt for login;" >&2
  echo "            headless (-p) runs need a token/key or a prior login." >&2
fi

# 4. Ensure the claude user owns its home + config, then drop privileges.
# /home/claude is a bind-mounted folder; chown the mountpoint so claude can
# write ~/.claude.json (onboarding/theme/trust state).
chown claude:claude /home/claude
chown -R claude:claude "$CLAUDE_HOME"

# 5. Agent bridges. SSH_AUTH_SOCK is a fixed path (/run/agent/ssh.sock) that
# exec'd sessions inherit from compose; populate it here from whichever source
# is active. socat relays run as root (backgrounded; they survive the exec into
# holder) and expose claude-owned sockets.
install -d -o claude -g claude -m 0755 /run/agent
if [ -n "${SSH_AGENT_BRIDGE_PORT:-}" ]; then
  # macOS: bridge to the host gpg-agent ssh socket via TCP (see macos-agent-bridge.sh).
  echo "entrypoint: ssh-agent bridge -> host.docker.internal:${SSH_AGENT_BRIDGE_PORT}"
  socat "UNIX-LISTEN:/run/agent/ssh.sock,unlink-early,fork,mode=0600,user=claude" \
        "TCP:host.docker.internal:${SSH_AGENT_BRIDGE_PORT}" &
elif [ -S /ssh-agent ]; then
  # A directly-forwarded agent socket (Linux host / Docker Desktop default agent).
  socat "UNIX-LISTEN:/run/agent/ssh.sock,unlink-early,fork,mode=0600,user=claude" \
        "UNIX-CONNECT:/ssh-agent" &
fi
if [ -n "${GPG_AGENT_BRIDGE_PORT:-}" ]; then
  # macOS: bridge to the host gpg-agent extra socket for commit signing. gpg in
  # the container talks to its standard agent socket under GNUPGHOME. unlink-early
  # clears a stale socket left in the persistent home by a previous run.
  echo "entrypoint: gpg-agent bridge -> host.docker.internal:${GPG_AGENT_BRIDGE_PORT}"
  install -d -o claude -g claude -m 0700 /home/claude/.gnupg
  # Run as claude so the socket is claude-owned/connectable. No mode=/user=:
  # socat's chmod/chown on a socket fails with EINVAL on the virtiofs bind mount.
  gosu claude socat "UNIX-LISTEN:/home/claude/.gnupg/S.gpg-agent,unlink-early,fork" \
        "TCP:host.docker.internal:${GPG_AGENT_BRIDGE_PORT}" &
fi

cd /code

# Hand off to the long-lived holder (PID 1): idle auto-stop + .claude.json backup.
# Sessions are launched separately via `docker compose exec` and never re-run
# this entrypoint.
exec /opt/claude-sandbox/holder.sh
