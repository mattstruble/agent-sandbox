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
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

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

# ─── opencode ─────────────────────────────────────────────────────────────────
# Installed via the official install script into /home/sandbox/.opencode/bin/.
# The install script is fetched from opencode.ai — the official distribution
# channel for opencode. No pinned-binary release artifact is published by the
# opencode project; the install script is the only supported install method.
# ACCEPTED RISK: The install script is trusted based on TLS to opencode.ai.
# If a pinned release binary becomes available, migrate to a curl + version-pin
# + SHA256 checksum verification + install pattern.
# opencode db migrate runs immediately after install to pre-initialize the
# database and avoid a hang on first container start (known issue).
# Both steps are wrapped with timeout to prevent hung build layers.

# opencode install script writes to $HOME; must run as sandbox user.
ENV HOME=/home/sandbox
USER sandbox

RUN timeout 120 bash -c "curl -fsSL https://opencode.ai/install | bash" \
    && timeout 60 /home/sandbox/.opencode/bin/opencode db migrate

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
