FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="agent-sandbox"
LABEL org.opencontainers.image.description="Sandboxed AI coding agent environment"

# ─── System packages ──────────────────────────────────────────────────────────

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    make \
    gosu \
    procps \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    jq \
    ca-certificates \
    chrony \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# ─── chrony configuration ─────────────────────────────────────────────────────
# Client-only config using Cloudflare NTP IPs directly (no DNS dependency).
# makestep 1 3 allows clock stepping for large corrections after host sleep/wake.
# port 0 / cmdport 0 disable all listening sockets — daemon is outbound-only.

RUN mkdir -p /etc/chrony && cat > /etc/chrony/chrony.conf <<'EOF'
server 162.159.200.1 iburst
server 162.159.200.123 iburst
makestep 1 3
port 0
cmdport 0
driftfile /var/lib/chrony/drift
EOF

# ─── gh CLI v2.89.0 ───────────────────────────────────────────────────────────
# Version-pinned; downloaded over TLS. No SHA256 checksum — enables automated
# version bumps via Renovate without requiring checksum updates.

RUN curl -fsSL \
    "https://github.com/cli/cli/releases/download/v2.89.0/gh_2.89.0_linux_amd64.tar.gz" \
    -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install -m 0755 /tmp/gh_2.89.0_linux_amd64/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz /tmp/gh_2.89.0_linux_amd64

# ─── rtk v0.34.2 ──────────────────────────────────────────────────────────────
# Version-pinned; downloaded over TLS. No SHA256 checksum — enables automated
# version bumps via Renovate without requiring checksum updates.

RUN curl -fsSL \
    "https://github.com/rtk-ai/rtk/releases/download/v0.34.2/rtk-x86_64-unknown-linux-musl.tar.gz" \
    -o /tmp/rtk.tar.gz \
    && mkdir -p /tmp/rtk-extract \
    && tar -xzf /tmp/rtk.tar.gz -C /tmp/rtk-extract \
    && rtk_bin="$(find /tmp/rtk-extract -maxdepth 2 -name 'rtk' -type f | head -1)" \
    && test -n "$rtk_bin" \
    && install -m 0755 "$rtk_bin" /usr/local/bin/rtk \
    && test -x /usr/local/bin/rtk \
    && rm -rf /tmp/rtk.tar.gz /tmp/rtk-extract

# ─── uv 0.11.2 ────────────────────────────────────────────────────────────────
# Copied from the official uv image, pinned by digest for reproducibility.
# Both /uv and /uvx are copied — uvx is required for tool execution.
# Digest: sha256:c4f5de312ee66d46810635ffc5df34a1973ba753e7241ce3a08ef979ddd7bea5
# Tag: 0.11.2 (also tagged: 0.11, latest)
# Source: https://github.com/astral-sh/uv/pkgs/container/uv

COPY --from=ghcr.io/astral-sh/uv:0.11.2@sha256:c4f5de312ee66d46810635ffc5df34a1973ba753e7241ce3a08ef979ddd7bea5 \
    /uv /uvx /usr/local/bin/

# ─── sandbox user ─────────────────────────────────────────────────────────────

RUN useradd --uid 1000 --create-home --shell /bin/bash sandbox

# ─── Copy scripts ─────────────────────────────────────────────────────────────

COPY --chown=root:root --chmod=0755 init-firewall.sh /init-firewall.sh
COPY --chown=root:root --chmod=0755 entrypoint.sh /entrypoint.sh

# ─── opencode v1.3.11 ─────────────────────────────────────────────────────────
# Version-pinned; downloaded over TLS from GitHub releases. Architecture is
# detected at build time via dpkg --print-architecture.
# Database migrations run automatically on first container start.

ENV HOME=/home/sandbox
USER sandbox

RUN ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in amd64) OC_ARCH="x64" ;; arm64) OC_ARCH="arm64" ;; *) echo "Unsupported arch: $ARCH" && exit 1 ;; esac \
    && mkdir -p /home/sandbox/.opencode/bin \
    && curl -fsSL \
       "https://github.com/anomalyco/opencode/releases/download/v1.3.11/opencode-linux-${OC_ARCH}.tar.gz" \
       -o /tmp/opencode.tar.gz \
    && tar -xzf /tmp/opencode.tar.gz -C /home/sandbox/.opencode/bin \
    && chmod 755 /home/sandbox/.opencode/bin/opencode \
    && rm -f /tmp/opencode.tar.gz

# ─── claude-code v2.1.87 ──────────────────────────────────────────────────────
# Installed globally via npm. Version pinned to latest stable as of 2026-03-31.
# Source: https://www.npmjs.com/package/@anthropic-ai/claude-code

USER root

RUN timeout 180 npm install -g --ignore-scripts @anthropic-ai/claude-code@2.1.87

# ─── Runtime configuration ────────────────────────────────────────────────────
# The entrypoint starts as root to establish the iptables firewall, then drops
# to the sandbox user via gosu for all subsequent operations.

USER root
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
