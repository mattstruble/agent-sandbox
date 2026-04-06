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
    xz-utils \
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

ENV RTK_TELEMETRY_DISABLED=1

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

# ─── Nix configuration (immutable, root-owned) ────────────────────────────────
# /etc/nix/ is root-owned with mode 0755; files inside are 0444.
# The sandbox user cannot modify, delete, or create files in this directory.
# nix.conf is written before the Nix install so the installer picks up settings.

RUN mkdir -p /etc/nix && chmod 0755 /etc/nix && cat > /etc/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
sandbox = false
warn-dirty = false
accept-flake-config = false
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
EOF

RUN chmod 0444 /etc/nix/nix.conf

# ─── Nix single-user install v2.34.4 ──────────────────────────────────────────
# Single-user mode (no daemon) — /nix is owned by the sandbox user.
# The installer auto-detects architecture (amd64/arm64).
# Placed before ARG NIXPKGS_REV so nixpkgs pin updates don't bust this layer.
# Version-pinned; Renovate tracks via custom regex manager.

RUN mkdir -p /nix && chown sandbox:sandbox /nix

# HOME is used by Nix install and all subsequent USER sandbox stages.
ENV HOME=/home/sandbox
USER sandbox

RUN curl -fsSL https://releases.nixos.org/nix/nix-2.34.4/install | bash -s -- --no-daemon \
    && /home/sandbox/.nix-profile/bin/nix --version

ENV PATH="/home/sandbox/.nix-profile/bin:${PATH}"

# ─── Shell command-not-found handler ──────────────────────────────────────────
# When the agent runs an unrecognized command, suggest `nix run nixpkgs#<cmd>`.
# Works for both OpenCode and Claude Code since both invoke bash.

RUN cat >> /home/sandbox/.bashrc <<'BASHRC'

command_not_found_handle() {
    printf '%s: command not found. Try: nix run nixpkgs#%s\n' "$1" "$1" >&2
    return 127
}
BASHRC

# ─── Nix flake registry (pinned nixpkgs) ──────────────────────────────────────
# Pins nixpkgs to a specific commit for reproducible binary cache hits.
# `nix run nixpkgs#<pkg>` resolves to this revision.
# Written after Nix install so only this layer and chmod are invalidated when
# Renovate bumps the pin — the expensive Nix install layer is cached.

USER root

# renovate: datasource=git-refs depName=https://github.com/NixOS/nixpkgs.git branch=nixpkgs-unstable
ARG NIXPKGS_REV="5e11f7acce6c3469bef9df154d78534fa7ae8b6c"

RUN test -n "${NIXPKGS_REV}" || { echo "ERROR: NIXPKGS_REV is empty"; exit 1; }

RUN cat > /etc/nix/registry.json <<EOF
{
  "version": 2,
  "flakes": [
    {
      "from": {
        "type": "indirect",
        "id": "nixpkgs"
      },
      "to": {
        "type": "github",
        "owner": "NixOS",
        "repo": "nixpkgs",
        "rev": "${NIXPKGS_REV}"
      }
    }
  ]
}
EOF

RUN chmod 0444 /etc/nix/registry.json

USER sandbox

# ─── opencode v1.3.13 ─────────────────────────────────────────────────────────
# Version-pinned; downloaded over TLS from GitHub releases. Architecture is
# detected at build time via dpkg --print-architecture.
# opencode db migrate runs at build time to avoid hang on first start.

RUN ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in amd64) OC_ARCH="x64" ;; arm64) OC_ARCH="arm64" ;; *) echo "Unsupported arch: $ARCH" && exit 1 ;; esac \
    && mkdir -p /home/sandbox/.opencode/bin \
    && curl -fsSL \
       "https://github.com/anomalyco/opencode/releases/download/v1.3.13/opencode-linux-${OC_ARCH}.tar.gz" \
       -o /tmp/opencode.tar.gz \
    && tar -xzf /tmp/opencode.tar.gz -C /home/sandbox/.opencode/bin \
    && chmod 755 /home/sandbox/.opencode/bin/opencode \
    && rm -f /tmp/opencode.tar.gz \
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
