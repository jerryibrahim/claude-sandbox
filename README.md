# Claude Code Docker Sandbox

Run Claude Code autonomously (no permission prompts) inside a single shared
container. Multiple sessions can run concurrently — each scoped to a different
repository under a common root — behind a default-deny network firewall and a
command denylist.

## What's in the image

Built on `ubuntu:24.04`, with pinned toolchains so in-container runs match a
typical dev/CI environment:

- **Python 3.12** (native — matches common test-suite versions)
- **Go 1.26.3** (official tarball; `go`/`gofmt` for build/test/format)
- **Node 22** (NodeSource; the Claude Code runtime)
- **Claude Code** (`claude`), **GitHub CLI** (`gh`), `git`, `jq`, `curl`
- Sandbox machinery: `iptables`/`ip6tables`/`ipset` (firewall), `procps`,
  `dnsutils`, `gosu`, `libxml2-utils` (`xmllint`)

Go module/build caches live under the persistent home (`GOPATH=/home/claude/go`,
`GOCACHE=/home/claude/.cache/go-build`), so dependencies aren't re-downloaded
every run.

## Prerequisites

- Docker with the `docker compose` v2 plugin.
- Authentication is **optional to preconfigure** — the container starts without
  it and an interactive session will prompt for login. Resolution order:
  1. `ANTHROPIC_API_KEY` (`.env`) — API billing.
  2. `CLAUDE_CODE_OAUTH_TOKEN` (`.env`) — Pro/Max one-year token
     (`claude setup-token`).
  3. Credentials persisted in the home from a prior interactive `claude /login`.
  4. None → an interactive session prompts for browser OAuth login, which then
     persists. (Headless `-p` runs still need 1–3.)

## Setup

```bash
cp .env.example .env        # optional: set CLAUDE_HOME_HOST and/or auth
docker build -t claude-sandbox:latest .
```

`.env` (all optional) controls:

- `CLAUDE_HOME_HOST` — host dir bind-mounted as Claude's home (default
  `/Users/claude`).
- `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` — auth (see above).
- `SANDBOX_IDLE_TIMEOUT` — idle auto-stop seconds (default `1800`).

First-run auth via subscription, without an API key: just start an interactive
session and complete the browser login (or pre-mint a token with
`claude setup-token` and put it in `.env`).

## Usage

```bash
# Interactive session scoped to a repo under SANDBOX_ROOT (default ~/code):
./run.sh ~/code/my-repo

# Headless one-shot task:
./run.sh ~/code/my-repo "summarize the architecture of this repo"

# Concurrent session in another terminal (different repo) while the first runs:
./run.sh ~/code/other-repo "Reply with exactly: PONG"

# Resume a prior session (or any raw claude flags) — forwarded to claude:
./run.sh ~/code/my-repo --resume <session-id>
./run.sh ~/code/my-repo --resume            # interactive session picker
```

The container starts automatically on first use; later calls join the running
container. Each session is scoped by **working directory** to `/code/<repo>`
inside the container. Post-repo arguments are interpreted as: a text prompt →
headless `-p`; anything starting with `-` (or after `--`) → forwarded raw to
`claude` (e.g. `--resume`, `--continue`).

## Lifecycle

| Command | Effect |
|---|---|
| `./run.sh <repo> [prompt]` | Start container (if needed) + open a session |
| `./run.sh <repo> --resume [id]` | Resume a session (raw flag passthrough) |
| `./run.sh --list` | Container status + active sessions (`pid → repo → session id`) |
| `./run.sh --stop` | Stop and remove the container |
| `./run.sh --restore-config` | Restore `<home>/.claude.json` from newest backup |

The container's PID 1 (`holder.sh`) watches for active sessions and backs up
`.claude.json`. When no session has run for `SANDBOX_IDLE_TIMEOUT` seconds
(default 1800 = 30 min) the holder exits; with `restart: "no"` the container
then stops. New sessions assign an explicit `--session-id`, so `--list` shows
the exact id (handy for `--resume`).

## SANDBOX_ROOT (which repos are reachable)

`SANDBOX_ROOT` (default `~/code`) is mounted read-write at `/code`. `run.sh`
accepts any path under it and rejects paths outside it before touching the
container.

```bash
SANDBOX_ROOT=/projects ./run.sh /projects/my-repo "..."   # different root
```

## Configuration

Edit files under `config/` on the host — no rebuild needed; changes take effect
the next time the container starts (the firewall re-resolves at start).

- `config/allowed-domains.txt` — egress allowlist, one entry per line: a
  hostname (no wildcards; resolved to IPs at startup) **or** a literal IPv4/IPv6
  address or CIDR (added directly — use CIDRs for hosts with large rotating IP
  pools). Defaults cover Anthropic, Claude auth, GitHub (hostnames + the
  published CIDR ranges, so `api.github.com`/`gh` work across the pool), npm
  (`registry.npmjs.org`), Go modules (`proxy.golang.org`, `sum.golang.org`), and
  Atlassian (`*.atlassian.net` org host, `api.atlassian.com`, plus the remote MCP
  at `mcp.atlassian.com` / `auth.atlassian.com`). Add private hosts (internal
  proxies, Artifactory) as needed.
- `config/denied-commands.txt` — POSIX-ERE patterns blocked before execution.
- `config/claude-settings.json` — Claude settings (deny-hook wiring + a
  `permissions.deny` backup).

### MCP servers

Add them from inside a session with **user scope** so they persist in the home
and apply to every repo:

```bash
claude mcp add --scope user --transport http atlassian https://mcp.atlassian.com/v1/mcp
```

Remote MCP hosts must be in `allowed-domains.txt` (the Atlassian ones are
preconfigured). OAuth-based servers prompt for a browser login on first use,
and the token persists in the home.

## Git authentication & commit signing

`github.com` is allowlisted, but git still needs credentials. Pick the path
that matches your host setup.

### Simplest: HTTPS via `gh` (no SSH/agent)

In a session, once (persists in the home):

```bash
gh auth login                                    # browser OAuth, or set GH_TOKEN in .env
gh auth setup-git
git config --global url."https://github.com/".insteadOf "git@github.com:"
```

`git@github.com:…` remotes then transparently use HTTPS + the gh token — no
agent, no `known_hosts`, no per-op touch.

### SSH with a normal agent (Linux host, or macOS default `ssh-agent`)

Point `SSH_AUTH_SOCK_HOST` (in `.env`) at the host agent socket; the entrypoint
relays it to the fixed `SSH_AUTH_SOCK=/run/agent/ssh.sock` that sessions use.
On a Linux box reached with `ssh -A`/RemoteForward (e.g. a YubiKey gpg-agent
forwarded in), use the forwarded socket:

```text
SSH_AUTH_SOCK_HOST=/run/user/1000/gnupg/S.gpg-agent.ssh
```

### macOS + YubiKey (gpg-agent): the socat bridge

Docker Desktop's agent forwarding only proxies the *default* `ssh-agent`, not
**gpg-agent** (where a YubiKey OpenPGP card lives). Bridge gpg-agent's sockets
over TCP loopback instead. One-time:

1. `brew install socat` on the host.
2. In `.env`, set the bridge ports (and restart the container):
   ```text
   SSH_AGENT_BRIDGE_PORT=9018      # git-over-SSH auth (gpg-agent ssh socket)
   GPG_AGENT_BRIDGE_PORT=9019      # commit signing (gpg-agent extra socket)
   ```
3. Run the host bridge (leave it running while you use the sandbox):
   ```bash
   ./macos-agent-bridge.sh
   ```
4. Seed GitHub's host key once: in a session,
   `mkdir -p ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts`.

The chain is: container `ssh`/`gpg` → `/run/agent/ssh.sock` &
`/run/agent/S.gpg-agent` → `host.docker.internal:<port>` → host `socat` →
gpg-agent → YubiKey (PIN/touch on the Mac). Keys never enter the container; the
host-gateway is allowlisted so the bridge passes the firewall.

**Verify:** `ssh-add -l` in a session should list your card key (`cardno:…`).

**Notes / gotchas:**
- Both container-side relays are started by the entrypoint and persist for the
  container's life. Each relay socket lives on the container-local `/run/agent`,
  **not** the bind-mounted home: virtiofs cannot `unlink()` a socket file, so a
  stale socket left in `~/.gnupg` by a prior run would break the relay's
  `unlink-early` on the next start. gpg is pointed at its relay via an Assuan
  redirect file (a *regular* file, which virtiofs can rewrite in place) at
  `~/.gnupg/S.gpg-agent` containing `%Assuan%` + `socket=/run/agent/S.gpg-agent`.
- The host bridge (`macos-agent-bridge.sh`) must be running whenever a session
  uses the agent; if it isn't, `ssh-add -l` errors through the relay.
- If you upgraded from an older image that put the gpg socket directly in
  `~/.gnupg`, a stale socket may block the new redirect file — the entrypoint
  logs a `WARNING`. Remove it from the host and restart:
  `rm -f "$CLAUDE_HOME_HOST/.gnupg/S.gpg-agent"`.

### Commit signing (GPG)

With the GPG bridge up (above), import your public key and mark it trusted
(the secret stays on the YubiKey):

```bash
# host: export your public key somewhere the container sees (e.g. under ~/code)
gpg --armor --export <KEYID> > ~/code/pub.key
# in a session (or via docker compose exec --user claude):
gpg --import /code/pub.key
echo "<FULL_FINGERPRINT>:6:" | gpg --import-ownertrust   # 6 = ultimate
git config --global user.signingkey <KEYID>
git config --global commit.gpgsign true
```

Verify signing works (pops pinentry on the Mac):

```bash
echo test | gpg --local-user <KEYID> --clearsign
```

A valid signature block means `git commit` (and `git tag`) will sign via the
card. Put identity/signing settings in the container's `~/.gitconfig`
(`/Users/claude/.gitconfig`) so they persist.

Notes:
- `gpg: problem with fast path key listing: Forbidden - ignored` is **benign** —
  the restricted gpg-agent *extra* socket refuses key *enumeration*, but signing
  is allowed. Keys may show as `ssb#` for the same reason.
- With `commit.gpgsign true` (and `tag.gpgsign true`), **every** commit/tag
  requires the GPG bridge to be running, or it fails.

## Applying changes (rebuild vs. restart)

How a change takes effect depends on whether the file is baked into the image or
mounted/host-side:

| Changed… | Applies by |
|---|---|
| `scripts/*.sh`, `Dockerfile` | **rebuild + recreate** the container |
| `config/*`, `.env` | **restart** the container (no rebuild) |
| `run.sh`, `macos-agent-bridge.sh` | **immediately** (host-side, no build/restart) |

The `scripts/` files (entrypoint, firewall, holder, deny-hook) are baked into
the image, so editing one and only restarting does **nothing** — a running
container keeps the old baked scripts. Rebuild and recreate:

```bash
docker build -t claude-sandbox:latest .
./run.sh --stop                                   # next ./run.sh recreates on the new image
# or: SANDBOX_ROOT="$HOME/code" docker compose up -d --force-recreate
```

A running container always uses the image it was created from; `docker build`
alone changes nothing until you recreate.

## How enforcement works

- **Firewall (once per container):** `init-firewall.sh` runs at startup, sets
  the IPv4 *and* IPv6 `OUTPUT` policy to DROP, and allows only loopback,
  established/related, DNS, and IPs resolved from the allowlist. Requires
  `NET_ADMIN`/`NET_RAW` (set in `docker-compose.yml`). All sessions share the
  container's network namespace.
- **Command deny-hook (per session):** a PreToolUse hook (`deny-check.sh`)
  matches each Bash command against the denylist and blocks matches before
  execution; `permissions.deny` mirrors the list as a second layer.
- **Non-root user:** sessions run as the unprivileged `claude` user (uid 1001).

The denylist blocks obvious footguns but string-matching can be evaded; the
network firewall, non-root user, and bounded filesystem mount are the real
isolation boundary.

## Persistent state

Claude's home (`/home/claude`) is bind-mounted to `CLAUDE_HOME_HOST` (default
`/Users/claude`) and shared across all repos and sessions. It persists
onboarding/theme/trust, session history and project state, login credentials,
MCP config, and the Go caches. Because each repo has a distinct `/code/<repo>`
path, per-repo session history separates naturally while global config is
shared.

**First-time setup of the home dir (macOS).** Create an empty, private folder
owned by you (it lives at the root `/Users`, so the `mkdir` needs `sudo`):

```bash
sudo mkdir -p /Users/claude
sudo chown "$USER:staff" /Users/claude   # you own it; Docker Desktop maps it to the container's claude user
sudo chmod 700 /Users/claude             # private — it will hold credentials, gpg keyring, .gitconfig
```

Point `CLAUDE_HOME_HOST` elsewhere (in `.env`) if you prefer a different path,
e.g. `~/.claude-sandbox-home`, in which case no `sudo` is needed. The folder
holds secrets (`.claude/.credentials.json`, gpg keyring), so keep it `700`.

**`.claude.json` backups:** the holder backs up `<home>/.claude.json` on change
(rotating, newest `.bak.1`, keep 3). Restore the newest with:

```bash
./run.sh --stop            # stop first so a live session can't overwrite mid-restore
./run.sh --restore-config
```

Note: Claude Code *also* keeps its own timestamped backups under
`<home>/.claude/backups/`.

**Reset state:** delete the home's contents (you can also just `rm -rf` the
`CLAUDE_HOME_HOST` dir and recreate it).

## Security boundary

- **Reachable filesystem:** anything under `SANDBOX_ROOT` (mounted rw at
  `/code`) plus the home. Sessions are scoped by working directory but are **not
  isolated between repos** under the root — a session in `/code/repoA` can read
  and write `/code/repoB`. For strict per-repo isolation, use separate roots.
- **Host filesystem:** nothing outside `SANDBOX_ROOT` and the home mount is
  visible; the rest of the host is unreachable.
- **Egress:** default-deny (IPv4 + IPv6); only allowlisted hosts are reachable.
  DNS to port 53 is allowed to any resolver (a known residual exfiltration
  channel).
- **Commands:** best-effort denylist, not a syscall sandbox.

## Limitations

- The firewall resolves allowlisted *hostnames* to IPs at container start; if a
  host's IPs change mid-session, restart the container — or list a **CIDR** for
  hosts with large rotating pools (GitHub's ranges are already included).
- Wildcard domains aren't supported — list concrete hostnames or CIDRs.
- On macOS, Claude's host login lives in the Keychain (not a mountable file), so
  use `.env` auth or an interactive `claude /login` inside the container.
- In-flight sessions are terminated if the container stops (idle or `--stop`);
  the holder does not drain active sessions.
- `.claude.json` backups are poll-based; if the newest was captured mid-write,
  restore an older `.bak.N` (or use Claude's own `<home>/.claude/backups/`).
- Two sessions in the *same* repo share that repo's history; only `.claude.json`
  is backed up, not per-repo history.
- Private Go modules need their proxy/host added to `allowed-domains.txt` (and
  `GOPRIVATE` set); public modules work out of the box.

## Release notes

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for the per-version feature list and
changes.
```
