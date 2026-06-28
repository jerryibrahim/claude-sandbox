# Release Notes

## v1.0.0 -- 2026-06-28

First public release of the **Claude Code Docker Sandbox** — run Claude Code
autonomously (no permission prompts) in a shared container behind a default-deny
firewall and a command denylist.

- **Hardened image** (`ubuntu:24.04`) with pinned Python 3.12, Go 1.26.3, Node 22,
  plus `claude`/`gh`/`git`/`jq`, firewall tooling, and persistent Go caches.
- **`run.sh` session manager** — interactive, headless (`-p`), and concurrent
  sessions, each scoped by working directory to `/code/<repo>` under `SANDBOX_ROOT`.
- **Raw flag passthrough** to `claude` with explicit per-session IDs
  (`--resume <id>`, `--resume` picker, `--continue`).
- **Lifecycle commands** — `--list`, `--stop`, `--restore-config`; the container
  auto-starts on first use.
- **Idle auto-stop** after `SANDBOX_IDLE_TIMEOUT` seconds (default 1800), with
  rotating `.claude.json` backups.
- **Persistent home** bind-mounted to `CLAUDE_HOME_HOST` — credentials, history,
  MCP config, and caches shared across repos and sessions.
- **Flexible auth** — `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, or
  interactive browser OAuth that persists.
- **Default-deny egress firewall** (IPv4 + IPv6) with a host-editable allowlist,
  plus a PreToolUse command deny-hook and a non-root `claude` user.
- **Git auth & GPG signing** — `gh` HTTPS, SSH agent relay, and a macOS YubiKey
  gpg-agent bridge that keeps keys out of the container.
- **Host-editable `config/` and `.env`** (allowlist, denylist, settings) with no
  rebuild required, plus shell test suites under `tests/`.
