# agent-sandbox Design

**Date:** 2026-03-30
**Status:** Approved

## Overview

`agent-sandbox` is a Nix flake that packages a bash launcher wrapping Podman to run AI coding agents (OpenCode) in isolated containers. Each sandbox provides:

- The current directory (or an explicit path) mounted at its full host path
- Agent dotfiles and git config staged from the host then made writable inside the container
- `rtk` pre-configured for 60-90% token savings on every tool call
- SSH credentials forwarded via socket — no private keys enter the container
- An iptables port-based network filter restricting outbound traffic to HTTP/HTTPS, DNS (pinned to container resolver), NTP (pinned to Cloudflare IPs), and SSH (optional)
- Deterministic container naming so multiple instances run in parallel without collision

The container image is built entirely from Nix via `dockerTools.buildLayeredImage` and published to GHCR (`ghcr.io/mstruble/agent-sandbox`). The launcher pulls the image on first use. Quick standup and teardown; supports many parallel sessions.

**Reference implementations studied:**
- [`alexjuda/ws1/sandbox`](https://github.com/alexjuda/ws1/tree/main/sandbox) — Podman/Docker Makefile wrapper for opencode
- [`anthropics/claude-code/.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer) — iptables firewall approach
- [`rtk-ai/rtk`](https://github.com/rtk-ai/rtk) — token compression proxy for AI agent tool calls

---

## Repository Layout

```
agent-sandbox/
├── .github/
│   └── workflows/
│       ├── pr-checks.yml       # Lint + build + scan on PRs
│       ├── publish-image.yml   # Build + push SHA-tagged image on main
│       ├── release-please.yml  # Release Please automation
│       └── release.yml         # Re-tag image with semver on release
├── modules/
│   ├── nixos.nix               # NixOS module (package + container runtime)
│   ├── darwin.nix              # nix-darwin module (package + container runtime)
│   └── home-manager.nix        # Home Manager module (package + runtime + config)
├── packages/
│   ├── opencode.nix            # Custom derivation for opencode binary
│   └── rtk.nix                 # Custom derivation for rtk binary
├── flake.nix                   # flake-parts: packages, container image, apps, module exports
├── flake.lock
├── agent-sandbox.sh            # Launcher script  → installed to $out/bin/
├── entrypoint.sh               # Container entrypoint → baked into image
├── init-firewall.sh            # iptables port-based network filter → baked into image
└── renovate.json               # Renovate dependency update configuration
```

---

## CLI

```
agent-sandbox [OPTIONS] [WORKSPACE]

Options:
  -a, --agent <name>       Agent to run: opencode (default)
  -b, --pull               Force re-pull image from GHCR before running
  --follow-symlinks        Mount depth-1 symlink targets from the workspace (skips dotfile dirs)
  --follow-all-symlinks    Like --follow-symlinks but includes dotfile directories
  --mount <path>           Mount an extra host path read-only (repeatable; append :rw for read-write)
  --no-ssh                 Skip SSH agent socket forwarding
  --list                   List running agent-sandbox containers
  --stop                   Stop sandbox(es) for the given/current workspace
  --prune                  Remove old agent-sandbox images, keeping only the current hash
  -v, --version            Print version and exit
  -h, --help               Show help

Arguments:
  WORKSPACE                Workspace directory to mount (default: $PWD)

Examples:
  agent-sandbox                        # opencode on current directory
  agent-sandbox ~/projects/foo         # opencode on ~/projects/foo
  agent-sandbox --follow-symlinks      # mount workspace symlink targets
  agent-sandbox --mount ~/.kube        # mount kubectl config read-only
  agent-sandbox --mount ~/data:rw      # mount a directory read-write
  agent-sandbox --no-ssh               # skip SSH agent forwarding
  agent-sandbox --pull                # force image re-pull, then run
  agent-sandbox --list                 # show running sandboxes
  agent-sandbox --stop                 # stop all sandboxes for current directory
  agent-sandbox --stop ~/projects/foo  # stop all sandboxes for that path
  agent-sandbox --prune                # remove stale images
  agent-sandbox --version              # print version
```

**Container naming** is deterministic: `agent-sandbox-<agent>-<workspace-basename>-<6-char-hash>` where the hash is derived from the absolute workspace path. Example: `agent-sandbox-opencode-myproject-a3f2b1`. Same workspace always maps to the same name; different workspaces with the same basename still get unique names. `--list` and `--stop` use this naming to find the right container.

**`--stop` behavior:** Without `--agent`, stops all `agent-sandbox-*` containers for the given workspace. With `--agent`, stops only the container for that specific agent. If no matching container is running, exits 0 silently.

**`--prune` behavior:** Lists all local `agent-sandbox:*` images, removes any whose tag does not match the launcher's current version, and prints the images removed and space freed.

**Runtime detection:** prefers `podman`, falls back to `docker`. Overridable via `AGENT_SANDBOX_RUNTIME=docker`. When using Podman, `--userns keep-id` is added automatically to preserve host UID in the workspace mount (avoids file permission issues).

---

## Container Image

**Build method:** `dockerTools.buildLayeredImage` from the project's `flake.nix`, following the pattern established by the upstream NixOS/nix `docker.nix`. There is no Containerfile — the image is defined entirely in Nix.

**Base:** Pure Nix (no Debian, Alpine, or other distro layer). All packages come from nixpkgs or custom derivations.

**Installed at build time:**

| Package | Source |
|---|---|
| bash, curl, git, make, procps, findutils, coreutils | nixpkgs |
| iptables, ipset, iproute2, dnsutils | nixpkgs |
| jq, ca-certificates, xz | nixpkgs |
| chrony | nixpkgs |
| nodejs, npm | nixpkgs |
| su-exec | nixpkgs |
| `gh` CLI | nixpkgs |
| `uv` | nixpkgs |
| `ty` | nixpkgs — Python LSP (astral-sh, preview); invoked via absolute store path |
| `nixd` | nixpkgs — Nix LSP; invoked via absolute store path |
| `stdenv.cc.cc.lib` | nixpkgs — provides `libstdc++.so.6` for OpenCode's native file-watcher |
| `nix` | nixpkgs (bundled via `dockerTools.buildLayeredImage`) |
| `opencode` | Custom derivation (`packages/opencode.nix`) — `fetchurl` from GitHub releases, per-architecture |
| `rtk` | Custom derivation (`packages/rtk.nix`) — `fetchurl` from GitHub releases, per-architecture |

**User management:** A `sandbox` user (UID 1000) is defined in the Nix expression. `/etc/passwd`, `/etc/group`, and `/etc/shadow` are generated directly by the Nix build (same pattern as upstream NixOS/nix `docker.nix`). No `useradd` or `shadow` package is needed at runtime.

**Privilege model:** The container starts as root to establish the iptables firewall, then drops to the `sandbox` user via `su-exec` for all subsequent operations. No sudo access is granted — sudo is not installed in the container.

**Static files baked into image:** The Nix instructions text (appended to agent prompt files at runtime) and the default OpenCode sandbox config JSON (`opencode-config.json`, containing `permission` and `lsp` blocks) are stored as Nix-produced files at `/etc/agent-sandbox/` in the image. The entrypoint reads these files rather than generating them inline.

**Image tagging:** `agent-sandbox:<version>` for releases, `agent-sandbox:<commit-sha>` for CI builds. The launcher knows its own version and pulls the matching tag from GHCR.

**Multi-architecture:** The image is currently built for `linux/amd64` only. ARM64 support is deferred until a native ARM runner is available for CI. Cross-compiling from x86_64 would produce a mislabeled image.

---

## Nix Runtime Package Management

Nix is included in the container image at build time via `dockerTools.buildLayeredImage` (the Nix package is part of the image's package set). The `sandbox` user owns `/nix` and can `nix run`, `nix shell`, and `nix build` freely. No Nix daemon runs inside the container.

**PATH integration:** The Nix binary directory is added to `PATH` via the image's `Env` configuration. This ensures `nix` is available in all shell contexts — interactive, non-interactive, and subshells — without relying on shell profile sourcing.

**Immutable configuration:** Nix settings live in `/etc/nix/` (root-owned, mode `0555`):

| File | Purpose |
|---|---|
| `/etc/nix/nix.conf` | Enables flakes, disables Nix build sandbox, restricts substituters to `cache.nixos.org` |

The `sandbox` user cannot modify, delete, or create files in `/etc/nix/`. The user can create `~/.config/nix/nix.conf` to add settings, but cannot override `substituters` (only `extra-substituters` is available at the user level, and there are no trusted substituters configured).

**`nix.conf` contents:**

```ini
experimental-features = nix-command flakes
sandbox = false
warn-dirty = false
accept-flake-config = false
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
```

- `sandbox = false` — Nix's own build sandbox (not the container). Requires root/namespaces, unavailable in single-user mode.
- `accept-flake-config = false` — prevents flakes from injecting trusted settings via their `nixConfig` attribute.
- `substituters` — locked to the official binary cache. No third-party caches.

**nixpkgs pinning:** The flake registry pins `nixpkgs` to the same revision used in `flake.lock` at build time. This is generated as part of the `dockerTools.buildLayeredImage` invocation using the `flake-registry` parameter (same pattern as upstream NixOS/nix `docker.nix`). `nix run nixpkgs#<package>` resolves to this revision, ensuring packages are served from the binary cache. There is no separate `NIXPKGS_REV` to maintain — updating `flake.lock` updates both the build-time and runtime nixpkgs pin in one operation.

**Ephemeral store:** The Nix store (`/nix/store`) is ephemeral — packages downloaded or built during a session are lost when the container stops. Each session starts with a clean store containing only the Nix tooling. Binary substitutes from `cache.nixos.org` make re-downloads fast (seconds for most packages).

**Arbitrary flake URIs:** The agent can use any flake URI (e.g., `nix run github:user/repo#thing`). This is intentionally unrestricted — the container boundary is the security layer, and `curl`, `uvx`, and `npx` already allow arbitrary remote code execution.

**Agent awareness:** The entrypoint appends Nix usage instructions to the agent's system prompt file (`~/.config/opencode/AGENTS.md` for OpenCode) at session start, telling the agent to prefer `nix run`/`nix shell` for tools not on PATH. The instructions text is stored as a static file at `/etc/agent-sandbox/nix-instructions.md` in the image. A `command_not_found_handle` function in `/home/sandbox/.bashrc` provides a reactive fallback — when the agent runs an unrecognized command, the shell suggests `nix run nixpkgs#<cmd>` in the error output.

---

## Mount Strategy

Host agent config directories are **staged** at read-only mount points rather than mounted directly over their final home directory locations. This allows the entrypoint to copy them to writable destinations and run `rtk init` — which needs to write hook/plugin files and must point to the container-local rtk binary path, not the host path.

| Host source | Container mount point | Mode |
|---|---|---|
| `<workspace>` | `<workspace>` (full host path) | `rw,z` |
| `~/.gitconfig` | `/home/sandbox/.gitconfig` | `ro,z` |
| `~/.config/opencode/` | `/host-config/opencode/` | `ro,z` (if exists on host) |
| `$SSH_AUTH_SOCK` | `/tmp/ssh_auth_sock` | `ro,z` (unless `--no-ssh`) |
| Extra mounts (config.toml / `--mount`) | Home-relative path in container | `ro,z` by default (`:rw` opt-in) |

**Extra mounts:** The user can mount additional host directories into the container via `config.toml` `[mounts]` `extra_paths` or the `--mount` CLI flag. Each entry is a path — `~/` is expanded to the host user's `$HOME`, absolute paths are used as-is. The host path is resolved via `realpath` before mounting. Paths relative to `$HOME` are mounted at the corresponding path under `/home/sandbox/` (e.g., `~/.kube/` → `/home/sandbox/.kube/`). Absolute paths outside `$HOME` are mounted at the same absolute path. The default mode is read-only; append `:rw` for read-write (e.g., `~/.kube:rw`). If the host path does not exist, the launcher prints a warning and skips it. CLI `--mount` entries are merged with `config.toml` entries (union, deduplicated by resolved host path). The `:z` SELinux option is applied on Linux. No restrictions are applied to extra mount paths — the user is explicitly choosing what to expose.

**Symlink auto-detection** is disabled by default. When `--follow-symlinks` is passed, the launcher scans the workspace directory at depth 1. For each entry that is a symlink resolving to a directory outside the workspace, it adds a read-write bind mount at the target's absolute path (`-v <target>:<target>:rw,z`). Targets are deduplicated. If a symlink target does not exist on the host, the launcher prints a warning and skips it. Symlinks resolving to paths within the workspace are skipped (already accessible).

**Dotfile directory protection:** Even with `--follow-symlinks`, symlink targets whose basename starts with `.` (e.g., `.ssh`, `.gnupg`, `.aws`, `.config`) are skipped with a warning. These directories commonly contain credentials and private keys, so mounting them into the sandbox would undermine its isolation. To override this protection and mount dotfile directories, pass `--follow-all-symlinks` (or set `follow_all_symlinks = true` in `config.toml` `[workspace]` section). Use this only when you understand which dotfile directories will be exposed.

**SSH:** `SSH_AUTH_SOCK=/tmp/ssh_auth_sock` is set in the container environment. No SSH private keys enter the container.

**API key passthrough:** The launcher forwards a fixed set of environment variables required by AI agents and cloud services:

- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `OPENROUTER_API_KEY`
- `MISTRAL_API_KEY`
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
- `GITHUB_TOKEN`

Additional variables can be forwarded via `config.toml` `[env]` `extra_vars`. Variables not in the default list or `extra_vars` are never forwarded — this prevents accidental leakage of unrelated secrets (e.g., `DATABASE_API_KEY`, `STRIPE_API_KEY`) into the container. Each variable is forwarded only if present in the host environment.

**Container capabilities:** `--cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SETUID --cap-add=SETGID --cap-add=SYS_TIME` — all capabilities dropped first, then only what iptables, su-exec, and chronyd require is added back. `SETUID`/`SETGID` are required for `su-exec` to drop privileges; `SYS_TIME` is required for chronyd to step the system clock.

**Privilege escalation prevention:** `--security-opt=no-new-privileges` prevents any process inside the container from gaining elevated privileges. This is compatible with `su-exec` which uses syscall-based privilege dropping.

**Resource limits:** `--memory=8g --cpus=4` by default. Overridable via `~/.config/agent-sandbox/config.toml` `[resources]` section.

**Input sanitization:** Before building the container name, the workspace basename is sanitized to `[a-z0-9-]` only (lowercased, non-matching characters stripped). The workspace path is resolved to an absolute path via `realpath` before mounting.

---

## Entrypoint (`entrypoint.sh`)

Runs inside the container in this order:

1. Run `/init-firewall.sh` as root to establish iptables port-based network filter and disable IPv6 — **first**, before any other step
2. Start `chronyd` as root for time synchronization; if it fails to start, log a warning and continue
3. Drop to the `sandbox` user via `su-exec`; steps 4–8 run as `sandbox`
4. Copy `/host-config/opencode/` → `~/.config/opencode/` (writable); skip if not mounted
5. Append Nix usage instructions (read from `/etc/agent-sandbox/nix-instructions.md`) to `~/.config/opencode/AGENTS.md`; create file if absent
6. Apply sandbox config overrides: use `jq` to replace the `.permission` and `.lsp` objects in `~/.config/opencode/opencode.json` with sandbox defaults from `/etc/agent-sandbox/opencode-config.json`. If `opencode.json` does not yet exist, copy `opencode-config.json` in as the initial user config. If `opencode-config.json` is missing from the image, abort container startup — the sandbox cannot enforce its security boundary without it.
7. Run `rtk init -g --opencode`
8. `exec opencode` with `$SANDBOX_WORKSPACE` as working directory

The firewall runs first to eliminate any unprotected network window. `rtk init` is a local-only operation and runs safely behind the established firewall.

**Note:** The firewall script does not hardcode `/usr/sbin:/usr/bin` paths. In the Nix-built image, all binaries (`iptables`, `ip6tables`, `sysctl`, etc.) are on `PATH` via the Nix profile.

---

## Network Filter (`init-firewall.sh`)

Uses `iptables` to establish a port-based network filter before any agent code runs. The filter restricts outbound traffic by protocol and port rather than by destination IP, allowing the agent to reach any HTTP/HTTPS server — this is intentional, as agents need unrestricted web access for MCP servers, documentation, web browsing, and diverse API endpoints that cannot be enumerated in advance.

**First actions on start:**
- Disable IPv6: `sysctl -w net.ipv6.conf.all.disable_ipv6=1` (defense-in-depth; primary mechanism is `--sysctl` flags at container creation). Hard verification via `/proc/sys/net/ipv6/conf/all/disable_ipv6` — fails closed if IPv6 cannot be disabled.
- Flush existing iptables rules

**Allowed traffic:**
- Loopback (`lo` interface, both directions)
- Established/related connections (conntrack)
- DNS (UDP/TCP port 53) — restricted to the container's configured resolver IP only (read from `/etc/resolv.conf` at startup). DNS to any other destination is explicitly rejected. This mitigates DNS tunneling to attacker-controlled nameservers.
- NTP (UDP port 123) — restricted to Cloudflare NTP IPs (162.159.200.1, 162.159.200.123) only. NTP to any other destination is explicitly rejected. This mitigates NTP amplification and exfiltration via NTP.
- HTTP outbound (TCP port 80) — to any destination
- HTTPS outbound (TCP port 443) — to any destination
- SSH outbound (TCP port 22) — conditional. When `--no-ssh` is passed, the launcher sets `AGENT_SANDBOX_NO_SSH=1`; `init-firewall.sh` reads this and blocks TCP 22.

**Blocked traffic:**
- All IPv6 (disabled via sysctl + ip6tables DROP policies)
- All non-HTTP/HTTPS/SSH outbound TCP ports
- All UDP except DNS to the pinned resolver and NTP to pinned Cloudflare IPs
- All ICMP and other protocols not matching the above
- All unsolicited inbound traffic

**Default policy:** REJECT all INPUT and OUTPUT not matching the above (ICMP admin-prohibited), providing immediate failure feedback rather than silent timeouts. Default chain policies are DROP as a catch-all.

**Post-setup verification:** Two tests validate the firewall is working correctly:
1. TCP port 9 (discard) to an external IP must be blocked — confirms non-HTTP ports are rejected
2. TCP port 443 to an external IP must succeed — confirms ACCEPT rules are applied (catches misconfigured rules that block everything)

---

## User Configuration (`~/.config/agent-sandbox/config.toml`)

Optional. All fields have defaults. If the file is missing, all defaults apply. If the file exists but is malformed, the launcher exits with a clear error message. Parsed using Python 3.11+ `tomllib`.

```toml
[defaults]
agent = "opencode"              # default agent when --agent is not passed

[env]
extra_vars = []                 # additional env vars to forward (e.g. ["DEEPSEEK_API_KEY"])

[workspace]
follow_symlinks = false         # mount depth-1 symlink targets (skips dotfile dirs)
follow_all_symlinks = false     # include dotfile directories (.ssh, .gnupg, etc.)

[mounts]
extra_paths = []                # additional host paths to mount (e.g. ["~/.kube", "~/.docker/config.json"])

[resources]
memory = "8g"                   # container memory limit
cpus = 4                        # container CPU limit
```

---

## Nix Packaging (`flake.nix`)

The flake exports two main outputs:

### Launcher package (`packages.default`)

Built with `pkgs.stdenv.mkDerivation`:

```
$out/
  bin/
    agent-sandbox          # launcher script (with @SHARE_DIR@ substituted)
  share/agent-sandbox/
    entrypoint.sh
    init-firewall.sh
```

The launcher has `@SHARE_DIR@` replaced with `$out/share/agent-sandbox` at build time, so it always locates its support files regardless of invocation directory. `@VERSION@` is replaced with the `version` value from the derivation, enabling `agent-sandbox --version`.

### Container image (`packages.container-image`)

Built with `dockerTools.buildLayeredImage` following the pattern from NixOS/nix `docker.nix`. The Nix expression:

1. Defines the `sandbox` user (UID 1000) and generates `/etc/passwd`, `/etc/group`, `/etc/shadow`
2. Assembles all packages (nixpkgs + custom derivations) into a layered image
3. Generates `/etc/nix/nix.conf` with immutable security settings
4. Pins the flake registry to the same nixpkgs revision as `flake.lock`
5. Includes static files at `/etc/agent-sandbox/` (Nix instructions, default sandbox config JSON `opencode-config.json`)
6. Includes `entrypoint.sh` and `init-firewall.sh`
7. Configures the OCI image: entrypoint, env vars, labels, user

The image is produced as a tarball: `nix build .#container-image` outputs a file loadable via `docker load < result` or `podman load < result`.

### Custom derivations (`packages/`)

Binaries not available in nixpkgs have custom derivations:

- **`packages/opencode.nix`** — `fetchurl` from GitHub releases with per-architecture URLs (`x64`/`arm64`) and SHA256 hashes. Extracts the tarball and installs the binary.
- **`packages/rtk.nix`** — `fetchurl` from GitHub releases with per-architecture URLs and SHA256 hashes.

Both derivations use `stdenv.hostPlatform` to select the correct architecture variant.

**Runtime inputs** (declared in flake, available automatically via `nix run`):
- `podman`
- `coreutils`, `findutils`

**Supported systems:** `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`

**Usage patterns:**

```bash
# One-shot without install:
nix run github:mstruble/agent-sandbox

# Permanent install into user profile:
nix profile install github:mstruble/agent-sandbox

# Build the container image locally:
nix build github:mstruble/agent-sandbox#container-image

# Reference from another flake (devShell, home-manager, etc.):
inputs.agent-sandbox.url = "github:mstruble/agent-sandbox";
# then: agent-sandbox.packages.${system}.default
```

---

## Nix Modules

The flake exports three modules: `nixosModules.default`, `darwinModules.default`, and `homeManagerModules.default`. The flake uses `flake-parts` (replacing `flake-utils`) to support both per-system outputs (packages, apps) and system-agnostic outputs (modules).

### Shared options (all modules)

All three modules expose the same base options under `programs.agent-sandbox`:

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | `bool` | `false` | Add agent-sandbox to the environment |
| `package` | `package` | flake's own package | Override the agent-sandbox package |
| `containerPackage` | `nullOr package` | `pkgs.podman` (Linux), `null` (darwin) | Container runtime package; added to environment when non-null |

### NixOS module (`modules/nixos.nix`)

Adds `package` and `containerPackage` (when non-null) to `environment.systemPackages`. Does not manage user-level configuration. Users who need a fully-configured podman setup should also enable `virtualisation.podman.enable` in their NixOS configuration.

### nix-darwin module (`modules/darwin.nix`)

Adds `package` and `containerPackage` (when non-null) to `environment.systemPackages`. `containerPackage` defaults to `null` on darwin because Podman Machine is typically managed outside Nix (e.g., via Homebrew). Does not manage user-level configuration.

### Home Manager module (`modules/home-manager.nix`)

Adds `package` and `containerPackage` (when non-null) to `home.packages`. Additionally exposes typed options under `programs.agent-sandbox.settings` that generate `~/.config/agent-sandbox/config.toml` via `xdg.configFile` using `pkgs.formats.toml`:

| Option | Type | Default | config.toml key |
|---|---|---|---|
| `settings.defaultAgent` | `enum [ "opencode" ]` | `"opencode"` | `defaults.agent` |
| `settings.env.extraVars` | `listOf str` | `[]` | `env.extra_vars` |
| `settings.workspace.followSymlinks` | `bool` | `false` | `workspace.follow_symlinks` |
| `settings.workspace.followAllSymlinks` | `bool` | `false` | `workspace.follow_all_symlinks` |
| `settings.mounts.extraPaths` | `listOf str` | `[]` | `mounts.extra_paths` |
| `settings.resources.memory` | `str` | `"8g"` | `resources.memory` |
| `settings.resources.cpus` | `ints.positive` | `4` | `resources.cpus` |

When all settings are at their defaults, no config file is generated — the launcher uses its built-in defaults. When any setting differs, the full config.toml is written. Generated TOML uses snake_case keys matching what the launcher expects.

**Example usage (Home Manager):**

```nix
{
  inputs.agent-sandbox.url = "github:mstruble/agent-sandbox";

  # In your Home Manager configuration:
  programs.agent-sandbox = {
    enable = true;
    settings = {
      resources.memory = "16g";
      resources.cpus = 8;
    };
  };
}
```

**Example usage (NixOS):**

```nix
{
  inputs.agent-sandbox.url = "github:mstruble/agent-sandbox";

  # In your NixOS configuration:
  programs.agent-sandbox.enable = true;
  virtualisation.podman.enable = true; # recommended for full podman setup
}
```

---

## CI/CD Workflows

Four GitHub Actions workflows, each with a single responsibility. Nix steps use `DeterminateSystems/nix-installer-action`.

### PR Checks (`pr-checks.yml`)

Triggered on every pull request to main. Three parallel jobs:

**Lint job:**
- Install Nix via `DeterminateSystems/nix-installer-action`
- `nixfmt --check flake.nix` and all `.nix` files in `packages/` — fail if not formatted
- `nix flake check` — validate flake evaluates
- ShellCheck on `agent-sandbox.sh`, `entrypoint.sh`, `init-firewall.sh`
- Conventional commit validation on the PR title via `amannn/action-semantic-pull-request`

**Build + Scan job:**
- `nix build .#container-image` to produce the image tarball
- `docker load` the tarball into the local Docker daemon
- `vulnix` scan on the Nix store closure of the image for known vulnerabilities
- Trivy filesystem scan on the repository
- Image is **not** pushed — build artifact only

**Nix build job:**
- `nix build` to verify the launcher Nix package builds cleanly

All three jobs are required to pass before merge.

### Image Publishing (`publish-image.yml`)

Triggered on push to main. Runs on `ubuntu-latest` (x86_64):

1. `nix build .#container-image` on x86_64
2. `docker load` the tarball
3. Tag as `ghcr.io/mstruble/agent-sandbox:<commit-sha>-amd64`
4. Push arch-specific image to GHCR
5. Create and push a manifest as `ghcr.io/mstruble/agent-sandbox:<commit-sha>`
6. `vulnix` scan on the image closure (advisory-only; non-blocking during early development)
7. Add OCI labels: `org.opencontainers.image.version`, `org.opencontainers.image.source`, `org.opencontainers.image.revision`

ARM64 support is deferred until a native ARM runner is available.

### Release Please (`release-please.yml`)

Triggered on push to main:

- Runs `googleapis/release-please-action`
- Configured for "simple" release type
- `extra-files` configured to bump the version string in `flake.nix`
- Opens (or updates) a release PR with version bump and generated changelog
- When the release PR is merged, creates a GitHub Release with a semver tag

### Release Tagging (`release.yml`)

Triggered when Release Please creates a GitHub Release:

1. Read the release version from the tag
2. Pull the SHA-tagged multi-arch image already published by `publish-image.yml` on the merge commit
3. Re-tag as `ghcr.io/mstruble/agent-sandbox:<semver>` and `ghcr.io/mstruble/agent-sandbox:latest`
4. Push both tags to GHCR

This avoids rebuilding the image — the release image is byte-identical to what was tested on main.

---

## Versioning

The version source of truth is the `version` field in `flake.nix`. Release Please bumps it via `extra-files` configuration.

The version is made available to the launcher at runtime via `@VERSION@` placeholder substitution in the Nix `installPhase` (same pattern as `@SHARE_DIR@`).

For the GHCR-published image (non-Nix distribution path), the version is baked into the image via the `org.opencontainers.image.version` label and can be read by the entrypoint or set as a build arg.

---

## Dependency Management (Renovate)

`renovate.json` at the repository root configures automated dependency update PRs grouped by category.

**Nix flake inputs** (single PR):
- `flake.lock` — Renovate's nix manager runs `nix flake update`. This updates nixpkgs and all nixpkgs-sourced packages (git, curl, iptables, chrony, jq, nodejs, gh, uv, su-exec, etc.) in one operation.

**Custom derivations** (single PR):
- `opencode` — regex manager matching the version string in `packages/opencode.nix`; SHA256 hashes must be updated manually after each version bump
- `rtk` — regex manager matching the version string in `packages/rtk.nix`; SHA256 hashes must be updated manually after each version bump

**GitHub Actions** (single PR):
- Action versions in workflow files — Renovate's github-actions manager

Renovate PRs go through the same `pr-checks.yml` pipeline as human PRs, ensuring dependency updates are linted, built, and scanned before merge.

---

## Branch Protection

Configured on the repository (not via workflow):

- Require pull request before merging to main
- Require all status checks to pass (lint, build+scan, nix build)
- Squash merge only
- No force pushes to main

---

## Design Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Container image build | `dockerTools.buildLayeredImage` from Nix, no Containerfile | Single package manager (Nix) for all dependencies; eliminates Debian+apt+curl+npm+COPY-from hybrid; reproducible, content-addressed images |
| su-exec privilege drop | Root → sandbox via `su-exec`; no sudo installed | Entrypoint runs firewall as root, then irrevocably drops to sandbox; `su-exec` is smaller than `gosu` and idiomatic in minimal/Nix containers |
| Multi-architecture | amd64-only for now; ARM64 deferred until native runner available | Cross-compiling from x86_64 produces a mislabeled image; native builds are required for correctness |
| Image distribution | Pull-only from GHCR; no local build path | Users pull pre-built images; eliminates need to ship Containerfile; Nix users can build locally via `nix build .#container-image` |
| Custom derivations | `packages/opencode.nix`, `packages/rtk.nix` | Isolates version+hash per tool; clean Renovate regex targets; keeps `flake.nix` readable |
| Vulnerability scanning | `vulnix` on Nix store closure + Trivy filesystem scan | `vulnix` understands Nix derivations (Trivy cannot enumerate packages in Nix images); Trivy fs scan catches non-package concerns |
| nixpkgs runtime pin | Flake registry derived from `flake.lock` | Single source of truth for nixpkgs version; updating `flake.lock` updates both build-time and runtime pins |
| Static entrypoint files | Nix instructions and default sandbox config JSON (`opencode-config.json`) at `/etc/agent-sandbox/` | Entrypoint reads files instead of inline heredocs; build-time generation via Nix |
| Capability dropping | `--cap-drop=ALL` before cap-adds | Removes all default caps; container gets only NET_ADMIN + NET_RAW + SETUID + SETGID + SYS_TIME |
| NTP pinning | UDP 123 restricted to Cloudflare IPs (162.159.200.1, 162.159.200.123) | Mitigates NTP amplification and exfiltration; no DNS dependency at chrony startup |
| Privilege escalation | `--security-opt=no-new-privileges` | Prevents execve-based privilege gains; compatible with su-exec (syscall-based) |
| IPv6 | Disabled via `--sysctl` at container creation + defense-in-depth sysctl in init-firewall.sh; hard-verified via `/proc` | Eliminates iptables bypass via IPv6 |
| Firewall ordering | Firewall runs first in entrypoint | No unprotected network window before agent starts |
| Port-based network filter | Allow TCP 80/443 to any destination; block all other outbound | Agents need unrestricted web access for MCP servers, documentation, APIs, and web browsing; IP-based allowlisting is infeasible |
| Input sanitization | Workspace basename → `[a-z0-9-]`; path via `realpath` | Prevents name injection and mount ambiguity |
| Resource limits | `--memory=8g --cpus=4` default, user-configurable | Prevents runaway agents from starving the host |
| API key allowlist | Explicit list, not glob | Prevents leaking unrelated secrets into the container |
| Symlink opt-in | `--follow-symlinks` required, dotfile dirs denied | Prevents accidental exposure of `~/.ssh`, `~/.gnupg`, etc. |
| DNS pinning | UDP 53 restricted to container resolver | Mitigates DNS tunneling exfiltration |
| Binary pinning | nixpkgs packages via `flake.lock`; custom derivations with SHA256 hashes | Reproducible builds; Renovate-updatable |
| Release automation | Release Please with conventional commits | Deterministic semver from commit history; auto-generated changelogs |
| Image publishing | SHA on main, semver+latest on release | Every main commit is pullable; releases are stable, never rebuilt |
| Release re-tag | Pull existing SHA image, re-tag | Release image is byte-identical to what was tested on main |
| Dependency updates | Renovate with `flake.lock` + regex managers for custom derivations | `flake.lock` handles most packages; regex managers for opencode/rtk (SHA256 must be updated manually) |
| CI runner | `ubuntu-latest` (x86_64) + `DeterminateSystems/nix-installer-action` | Native amd64 builds; ARM64 deferred until native runner available |
| Security scanning | `vulnix` on Nix closure + Trivy filesystem | `vulnix` understands Nix; Trivy covers non-package concerns |
| Branch protection | Required checks + squash-merge | Ensures clean conventional commit history for Release Please |
| Flake framework | `flake-parts` over `flake-utils` | Supports both per-system (packages, apps) and system-agnostic (modules) outputs cleanly |
| Module split | Three modules: NixOS, darwin, Home Manager | NixOS and darwin are system-level (package only); HM is user-level (package + config) matching the per-user nature of the tool |
| Config generation | `pkgs.formats.toml` via `xdg.configFile` | Standard Nix approach; only writes config when settings differ from defaults |
| Container runtime option | `containerPackage` with per-platform default | More flexible than a boolean toggle; lets users pass any runtime package or null to self-manage |
| Nix in-container | Bundled via `dockerTools.buildLayeredImage`, no separate install step, ephemeral store | Agent can install arbitrary packages on demand without root; no state leaks between sessions |
| Nix config immutability | `/etc/nix/` root-owned, mode `0555`; `0444` files, generated by Nix build | Agent cannot modify substituters, experimental features, or trust settings |
| Nix substituters | `cache.nixos.org` only | No third-party binary caches; source builds from arbitrary flakes still allowed |
| Nix flake URI restrictions | None — arbitrary URIs allowed | Container boundary is the security layer; `curl`/`uvx`/`npx` already allow arbitrary remote code |
| nixpkgs pinning | Flake registry derived from `flake.lock` at build time | Single source of truth; binary cache hits; agent can override with explicit rev |
| Nix PATH integration | `Env` directive in OCI image config | Works for non-interactive shells; explicit over shell profile sourcing |

---

## Security Model

The container boundary is the primary trust line. The network filter is defense-in-depth — it restricts protocols and ports but does not restrict destination IPs. This section documents known trust boundaries and accepted risks.

**Trust boundaries:**

- **Unrestricted HTTPS egress.** The firewall allows outbound TCP 80 and 443 to any destination. This is required for agents to access MCP servers, web documentation, APIs, and arbitrary web resources. The trade-off is that a misbehaving agent can exfiltrate data to any HTTPS endpoint. The container boundary, capability dropping, and `no-new-privileges` are the primary isolation mechanisms; the network filter prevents non-web protocols (raw TCP, UDP, ICMP) from being used as exfiltration channels.
- **SSH agent socket.** The forwarded `SSH_AUTH_SOCK` allows the container to use all keys loaded in the host's SSH agent to authenticate to any SSH server. Port 22 is open outbound. This is required for git-over-SSH but means a misbehaving agent can authenticate as the user to arbitrary SSH hosts. Use `--no-ssh` if git-over-SSH is not needed.
- **Workspace write access.** The agent has full read-write access to the mounted workspace. It can modify `.git/hooks`, `.github/workflows`, `Makefile`, or other files that may execute on the host after the session. Review agent changes before running host-side automation.
- **DNS.** DNS queries are pinned to the container's configured resolver (from `/etc/resolv.conf`). This mitigates tunneling to attacker-controlled nameservers but does not prevent all DNS-based exfiltration techniques (e.g., encoding data in queries to domains that resolve through the pinned resolver's upstream chain).
- **SYS_TIME capability.** `--cap-add=SYS_TIME` is granted to the container for chronyd to adjust the system clock. After `su-exec` drops to the `sandbox` user, `SYS_TIME` remains available to all processes in the container, including the agent. A misbehaving agent could manipulate the system clock to defeat time-sensitive security checks (TLS certificate validity, JWT/TOTP expiry, AWS SigV4 windows). This is an accepted trade-off: clock manipulation is a lower-severity capability than the unrestricted HTTPS egress already permitted, and the alternative (no time synchronization) causes real operational failures after host sleep/resume.

**Mitigations in place:**

- Capabilities dropped to minimum (`NET_ADMIN` + `NET_RAW` + `SETUID` + `SETGID` + `SYS_TIME` only; `NET_ADMIN`/`NET_RAW` for iptables, `SETUID`/`SETGID` for su-exec privilege drop, `SYS_TIME` for chronyd clock adjustment)
- `no-new-privileges` prevents execve-based privilege escalation
- IPv6 disabled via `--sysctl` at container creation + defense-in-depth sysctl in entrypoint; hard-verified via `/proc`
- Firewall established before any agent code runs
- Non-web protocols blocked (only TCP 80/443/22, pinned DNS, and pinned NTP permitted)
- API keys restricted to an explicit allowlist (not a glob pattern)
- Symlink auto-mounting is opt-in and denies dotfile directories by default
- Resource limits prevent host starvation
- All container packages are sourced from nixpkgs (content-addressed, reproducible) or custom Nix derivations with SHA256 hashes
- `vulnix` scans the container image's Nix store closure for CVEs on every PR and main push

---

## macOS Caveats

The flake targets `x86_64-darwin` and `aarch64-darwin`. On macOS, containers run inside a Linux VM (Podman Machine or Docker Desktop). This introduces differences from native Linux:

- **SSH agent socket.** The host socket path is remapped through the VM's mount layer. Podman Machine and Docker Desktop handle this differently; the launcher must use the VM-translated path. If the socket is not accessible inside the VM, `--no-ssh` avoids startup failures.
- **`--userns keep-id`.** Podman Machine may not support `keep-id` identically to native Linux Podman. File ownership in the workspace mount may differ. Test during implementation and document any required workarounds.
- **File permissions.** VM-backed mounts (e.g., virtiofs, gRPC FUSE) may not propagate POSIX permissions exactly. Files created by the agent may appear with different ownership on the host.
- **Symlink resolution.** Symlink targets are resolved on the host, but the resulting paths must be accessible inside the VM. Paths outside the VM's shared directories may not mount correctly.
- **iptables.** The firewall runs inside the Linux container, which runs inside the Linux VM. This works correctly — iptables controls the container's network namespace regardless of the host OS.

These caveats will be refined during implementation. Story-level acceptance criteria will be added for any behavior that requires macOS-specific code paths.
