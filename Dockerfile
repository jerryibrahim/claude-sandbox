FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System packages. Ubuntu 24.04 ships Python 3.12 as python3 (matches the
# project's test-suite version). libxml2-utils provides xmllint (skills).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      git \
      openssh-client \
      socat \
      jq \
      iptables \
      ipset \
      procps \
      dnsutils \
      gosu \
      python3 \
      python3-venv \
      libxml2-utils \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh) from its official apt repo (arch-aware).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 via NodeSource (Claude Code is an npm package).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Go 1.26.3 from the official tarball (pinned, arch-aware).
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL "https://go.dev/dl/go1.26.3.linux-${ARCH}.tar.gz" \
      | tar -C /usr/local -xz \
    && /usr/local/go/bin/go version
ENV PATH="/usr/local/go/bin:${PATH}"

# Claude Code.
RUN npm install -g @anthropic-ai/claude-code

# Non-root user; Go caches live under the (persistent) home.
RUN useradd -m -s /bin/bash claude
ENV GOPATH=/home/claude/go
ENV GOCACHE=/home/claude/.cache/go-build

COPY scripts/ /opt/claude-sandbox/
RUN chmod +x /opt/claude-sandbox/*.sh

WORKDIR /code
ENTRYPOINT ["/opt/claude-sandbox/entrypoint.sh"]
