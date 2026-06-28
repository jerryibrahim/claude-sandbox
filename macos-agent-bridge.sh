#!/usr/bin/env bash
# Run on the macOS HOST (not inside the container).
#
# Bridges the host gpg-agent's SSH and GPG sockets to TCP loopback ports so the
# sandbox container can reach them via host.docker.internal. Use this when your
# keys live in gpg-agent (e.g. a YubiKey OpenPGP card), which Docker Desktop's
# default agent forwarding cannot reach.
#
# Set the SAME ports in the sandbox .env and restart the container:
#   SSH_AGENT_BRIDGE_PORT=9018
#   GPG_AGENT_BRIDGE_PORT=9019
#
# Then leave this running while you use the sandbox.
set -euo pipefail

SSH_PORT="${SSH_AGENT_BRIDGE_PORT:-9018}"
GPG_PORT="${GPG_AGENT_BRIDGE_PORT:-9019}"

command -v socat  >/dev/null || { echo "socat not found — 'brew install socat'" >&2; exit 1; }
command -v gpgconf >/dev/null || { echo "gpgconf not found — install GnuPG" >&2; exit 1; }

ssh_sock="$(gpgconf --list-dir agent-ssh-socket)"
gpg_sock="$(gpgconf --list-dir agent-extra-socket)"
[ -S "$ssh_sock" ] || { echo "no gpg-agent ssh socket at $ssh_sock (enable-ssh-support in gpg-agent.conf?)" >&2; exit 1; }
[ -S "$gpg_sock" ] || { echo "no gpg-agent extra socket at $gpg_sock (extra-socket in gpg-agent.conf?)" >&2; exit 1; }

echo "ssh-agent : $ssh_sock -> 127.0.0.1:$SSH_PORT  (git-over-SSH auth)"
echo "gpg-agent : $gpg_sock -> 127.0.0.1:$GPG_PORT  (commit signing)"
echo "Loopback-only. Leave running while you use the sandbox; Ctrl-C to stop."

socat "TCP-LISTEN:${SSH_PORT},bind=127.0.0.1,fork,reuseaddr" "UNIX-CONNECT:${ssh_sock}" &
ssh_pid=$!
socat "TCP-LISTEN:${GPG_PORT},bind=127.0.0.1,fork,reuseaddr" "UNIX-CONNECT:${gpg_sock}" &
gpg_pid=$!
trap 'kill "$ssh_pid" "$gpg_pid" 2>/dev/null || true' EXIT
wait
