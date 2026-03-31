# agent-sandbox Design

**Date:** 2026-03-30
**Status:** Approved

## Overview

`agent-sandbox` is a Nix flake that packages a bash launcher wrapping Podman to run AI coding agents (OpenCode, Claude Code) in isolated containers. Each sandbox provides:

- The current directory (or an explicit path) mounted as `/workspace`
- Agent dotfiles and git config staged from the host then made writable inside the container
- `rtk` pre-configured for 60-90% token savings on every tool call
- SSH credentials forwarded via socket — no private keys enter the container
- An iptables allowlist restricting outbound traffic to known-good AI API endpoints, GitHub, and DNS/SSH
- Deterministic container naming so multiple instances run in parallel without collision

The container image is built locally on first use and cached by Containerfile content hash, or pulled from GHCR (`ghcr.io/mstruble/agent-sandbox`). Quick standup and teardown; supports many parallel sessions.

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
├── flake.nix                   # flake-parts: packages, apps, and module exports
├── flake.lock
├── agent-sandbox.sh            # Launcher script  → installed to $out/bin/
├── Containerfile               # Image definition → installed to $out/share/agent-sandbox/
├── entrypoint.sh               # Container entrypoint → $out/share/agent-sandbox/
├── init-firewall.sh            # iptables allowlist  → $out/share/agent-sandbox/
└── renovate.json               # Renovate dependency update configuration
```

---

## CLI

```
agent-sandbox [OPTIONS] [WORKSPACE]

Options:
  -a, --agent <name>       Agent to run: opencode (default) or claude
  -b, --build              Force rebuild image before running
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
  agent-sandbox --agent claude         # claude-code on current directory
  agent-sandbox ~/projects/foo         # opencode on ~/projects/foo
  agent-sandbox --agent claude ~/work  # claude-code on ~/work
  agent-sandbox --follow-symlinks      # mount workspace symlink targets
  agent-sandbox --mount ~/.kube        # mount kubectl config read-only
  agent-sandbox --mount ~/data:rw      # mount a directory read-write
  agent-sandbox --no-ssh               # skip SSH agent forwarding
  agent-sandbox --build                # force image rebuild, then run
  agent-sandbox --list                 # show running sandboxes
  agent-sandbox --stop                 # stop all sandboxes for current directory
  agent-sandbox --stop --agent claude  # stop only the claude sandbox
  agent-sandbox --stop ~/projects/foo  # stop all sandboxes for that path
  agent-sandbox --prune                # remove stale images
  agent-sandbox --version              # print version
```

**Container naming** is deterministic: `agent-sandbox-<agent>-<workspace-basename>-<6-char-hash>` where the hash is derived from the absolute workspace path. Example: `agent-sandbox-opencode-myproject-a3f2b1`. Same workspace always maps to the same name; different workspaces with the same basename still get unique names. `--list` and `--stop` use this naming to find the right container.

**`--stop` behavior:** Without `--agent`, stops all `agent-sandbox-*` containers for the given workspace (both opencode and claude if running). With `--agent`, stops only the container for that specific agent. If no matching container is running, exits 0 silently.

**`--prune` behavior:** Lists all local `agent-sandbox:*` images, removes any whose tag does not match the current Containerfile hash, and prints the images removed and space freed.

**Runtime detection:** prefers `podman`, falls back to `docker`. Overridable via `AGENT_SANDBOX_RUNTIME=docker`. When using Podman, `--userns keep-id` is added automatically to preserve host UID in the workspace mount (avoids file permission issues).

---

## Container Image (`Containerfile`)

**Base:** `debian:bookworm-slim`

**Installed at build time:**

| Package | Method |
|---|---|
| bash, curl, git, make, gosu | apt |
| iptables, ipset, iproute2, dnsutils | apt |
| jq, aggregate, ca-certificates | apt |
| nodejs, npm | apt |
| `gh` CLI | curl from GitHub releases (version-pinned) |
| `uv` | copied from `ghcr.io/astral-sh/uv` (pinned digest) |
| `opencode` | official install script |
| `claude-code` | `npm install -g @anthropic-ai/claude-code@X.Y.Z` |
| `rtk` | curl from GitHub releases (version-pinned) → `/usr/local/bin/rtk` |

**Binary pinning:** All binaries installed from external sources are pinned to specific release versions. Downloads are over TLS. SHA256 checksum verification has been removed in favor of version pinning to enable automated dependency updates via Renovate. The `opencode` install script is trusted based on TLS to opencode.ai (accepted risk — no pinned release binary is published). The `claude-code` npm package is pinned to a specific version.

`opencode db migrate` is run at image build time to avoid a hang on first container start (a known issue discovered in ws1/sandbox).

A `sandbox` user is created at UID 1000. The container starts as root to establish the iptables firewall, then drops to the `sandbox` user via `gosu` for all subsequent operations. No sudo access is granted — sudo is not installed in the container.

**Image tagging:** `agent-sandbox:<sha256-of-Containerfile-contents>`. The launcher computes this hash at startup, checks `podman images` for the tag, and builds automatically if absent. `--build` forces a rebuild unconditionally.

---

## Mount Strategy

Host agent config directories are **staged** at read-only mount points rather than mounted directly over their final home directory locations. This allows the entrypoint to copy them to writable destinations and run `rtk init` — which needs to write hook/plugin files and must point to the container-local rtk binary path, not the host path.

| Host source | Container mount point | Mode |
|---|---|---|
| `<workspace>` | `/workspace` | `rw,z` |
| `~/.gitconfig` | `/home/sandbox/.gitconfig` | `ro,z` |
| `~/.config/opencode/` | `/host-config/opencode/` | `ro,z` (if exists on host) |
| `~/.claude/` | `/host-config/claude/` | `ro,z` (if exists on host) |
| `$SSH_AUTH_SOCK` | `/tmp/ssh_auth_sock` | `ro,z` (unless `--no-ssh`) |
| Extra mounts (config.toml / `--mount`) | Home-relative path in container | `ro,z` by default (`:rw` opt-in) |

**Extra mounts:** The user can mount additional host directories into the container via `config.toml` `[mounts]` `extra_paths` or the `--mount` CLI flag. Each entry is a path — `~/` is expanded to the host user's `$HOME`, absolute paths are used as-is. The host path is resolved via `realpath` before mounting. Paths relative to `$HOME` are mounted at the corresponding path under `/home/sandbox/` (e.g., `~/.kube/` → `/home/sandbox/.kube/`). Absolute paths outside `$HOME` are mounted at the same absolute path. The default mode is read-only; append `:rw` for read-write (e.g., `~/.kube:rw`). If the host path does not exist, the launcher prints a warning and skips it. CLI `--mount` entries are merged with `config.toml` entries (union, deduplicated by resolved host path). The `:z` SELinux option is applied on Linux. No restrictions are applied to extra mount paths — the user is explicitly choosing what to expose.

**Symlink auto-detection** is disabled by default. When `--follow-symlinks` is passed, the launcher scans the workspace directory at depth 1. For each entry that is a symlink resolving to a directory outside the workspace, it adds a read-write bind mount at the target's absolute path (`-v <target>:<target>:rw,z`). Targets are deduplicated. If a symlink target does not exist on the host, the launcher prints a warning and skips it. Symlinks resolving to paths within the workspace are skipped (already accessible).

**Dotfile directory protection:** Even with `--follow-symlinks`, symlink targets whose basename starts with `.` (e.g., `.ssh`, `.gnupg`, `.aws`, `.config`) are skipped with a warning. This prevents accidental exposure of sensitive host directories. To override this protection and mount dotfile directories, pass `--follow-all-symlinks` (or set `follow_all_symlinks = true` in `config.toml` `[workspace]` section).

**SSH:** `SSH_AUTH_SOCK=/tmp/ssh_auth_sock` is set in the container environment. No SSH private keys enter the container.

**API key passthrough:** The launcher forwards a fixed set of environment variables required by AI agents and cloud services:

- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `OPENROUTER_API_KEY`
- `MISTRAL_API_KEY`
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
- `GITHUB_TOKEN`

Additional variables can be forwarded via `config.toml` `[env]` `extra_vars`. Variables not in the default list or `extra_vars` are never forwarded — this prevents accidental leakage of unrelated secrets (e.g., `DATABASE_API_KEY`, `STRIPE_API_KEY`) into the container. Each variable is forwarded only if present in the host environment.

**Container capabilities:** `--cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW` — all capabilities dropped first, then only what iptables requires is added back.

**Privilege escalation prevention:** `--security-opt=no-new-privileges` prevents any process inside the container from gaining elevated privileges.

**Resource limits:** `--memory=8g --cpus=4` by default. Overridable via `~/.config/agent-sandbox/config.toml` `[resources]` section.

**Input sanitization:** Before building the container name, the workspace basename is sanitized to `[a-z0-9-]` only (lowercased, non-matching characters stripped). The workspace path is resolved to an absolute path via `realpath` before mounting.

---

## Entrypoint (`entrypoint.sh`)

Runs inside the container in this order:

1. Run `/init-firewall.sh` as root to establish iptables allowlist and disable IPv6 — **first**, before any other step
2. Drop to the `sandbox` user via `gosu`; steps 3–7 run as `sandbox`
3. Copy `/host-config/opencode/` → `~/.config/opencode/` (writable); skip if not mounted
4. Copy `/host-config/claude/` → `~/.claude/` (writable); skip if not mounted
5. Apply permission overrides: use `jq` to set all permission fields to `"allow"` in `~/.config/opencode/config.json`; create the file if absent
6. Based on `$AGENT` env var (set by launcher):
   - `opencode`: run `rtk init -g --opencode`
   - `claude`: run `rtk init -g`
7. `exec` the agent binary with `/workspace` as working directory:
   - `opencode`: `exec ~/.opencode/bin/opencode`
   - `claude`: `exec claude --dangerously-skip-permissions`

The firewall runs first to eliminate any unprotected network window. `rtk init` is a local-only operation and runs safely behind the established firewall.

---

## Network Allowlist (`init-firewall.sh`)

Adapted from the Claude Code devcontainer firewall script. Uses `iptables` and `ipset` to establish a strict allowlist before any agent code runs.

**First actions on start:**
- Disable IPv6: `sysctl -w net.ipv6.conf.all.disable_ipv6=1` — prevents firewall bypass via IPv6
- Flush existing iptables rules and destroy any prior ipsets

**Always allowed:**
- DNS (UDP port 53) — restricted to the container's configured resolver IP (read from `/etc/resolv.conf` at startup). This mitigates DNS tunneling to attacker-controlled nameservers.
- SSH outbound (TCP port 22) + established responses inbound. When `--no-ssh` is passed, the launcher sets `AGENT_SANDBOX_NO_SSH=1` in the container environment; `init-firewall.sh` reads this variable and blocks TCP port 22 as well.
- Localhost (`lo` interface, both directions)
- Host gateway subnet (detected at runtime via `ip route`)

**Allowlisted external destinations** (resolved to IPs at container start, stored in an `ipset hash:net`):

| Domain / Source | Purpose |
|---|---|
| `api.anthropic.com` | Claude API |
| `api.openai.com` | OpenAI API |
| `openrouter.ai` | OpenRouter multi-provider |
| `api.mistral.ai` | Mistral API |
| `opencode.ai` | OpenCode auth / telemetry |
| GitHub IP ranges | Fetched live from `api.github.com/meta` (web + api + git ranges) |
| AWS Bedrock IP ranges | Fetched from `ip-ranges.amazonaws.com`, filtered to `BEDROCK` service |
| `registry.npmjs.org` | npm (used by claude-code) |
| `sentry.io` | Agent error reporting |
| `statsig.com`, `statsig.anthropic.com` | Agent telemetry |

**IP range fetch resilience:** If `api.github.com/meta` or `ip-ranges.amazonaws.com` is unreachable, the firewall logs a warning and continues without those ranges. The agent starts but may lack connectivity to GitHub or AWS Bedrock. Domain-based allowlist entries (e.g., `api.anthropic.com`) are resolved via `dig` and are not affected by IP range fetch failures.

**Default policy:** REJECT all INPUT and OUTPUT not matching the above (ICMP admin-prohibited), providing immediate failure feedback rather than silent timeouts.

**User-extensible** via `~/.config/agent-sandbox/config.toml`. The launcher validates `extra_domains` entries against `^[a-zA-Z0-9]([a-zA-Z0-9\-\.]+)?$` before starting the container (fail fast). Valid entries are serialized into `AGENT_SANDBOX_EXTRA_DOMAINS` (newline-separated). `init-firewall.sh` also validates each entry as defense-in-depth before resolving and adding it to the ipset.

---

## User Configuration (`~/.config/agent-sandbox/config.toml`)

Optional. All fields have defaults. If the file is missing, all defaults apply. If the file exists but is malformed, the launcher exits with a clear error message. Parsed using `dasel`.

```toml
[defaults]
agent = "opencode"              # default agent when --agent is not passed

[network]
extra_domains = []              # additional domains to allowlist

[env]
extra_vars = []                 # additional env vars to forward (e.g. ["DEEPSEEK_API_KEY"])

[workspace]
follow_all_symlinks = false     # when true, --follow-symlinks includes dotfile directories

[mounts]
extra_paths = []                # additional host paths to mount (e.g. ["~/.kube", "~/.docker/config.json"])

[resources]
memory = "8g"                   # container memory limit
cpus = 4                        # container CPU limit
```

---

## Nix Packaging (`flake.nix`)

The package is built with `pkgs.stdenv.mkDerivation`:

```
$out/
  bin/
    agent-sandbox          # launcher script (with @SHARE_DIR@ substituted)
  share/agent-sandbox/
    Containerfile
    entrypoint.sh
    init-firewall.sh
```

The launcher has `@SHARE_DIR@` replaced with `$out/share/agent-sandbox` at build time, so it always locates its Containerfile regardless of invocation directory.

The launcher also has `@VERSION@` replaced with the `version` value from the derivation at build time, enabling `agent-sandbox --version`.

**Runtime inputs** (declared in flake, available automatically via `nix run`):
- `podman`
- `coreutils`, `gnused`, `gnugrep`
- `jq` (for parsing AWS/GitHub IP range JSON responses and patching `opencode.json`)
- `dasel` (for reading `config.toml`)

**Supported systems:** `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`

**Usage patterns:**

```bash
# One-shot without install:
nix run github:mstruble/agent-sandbox

# Permanent install into user profile:
nix profile install github:mstruble/agent-sandbox

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
| `settings.defaultAgent` | `enum [ "opencode" "claude" ]` | `"opencode"` | `defaults.agent` |
| `settings.network.extraDomains` | `listOf str` | `[]` | `network.extra_domains` |
| `settings.env.extraVars` | `listOf str` | `[]` | `env.extra_vars` |
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
      defaultAgent = "claude";
      network.extraDomains = [ "api.internal.corp" ];
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

Four GitHub Actions workflows, each with a single responsibility. All run on `ubuntu-latest` runners. Nix steps use `DeterminateSystems/nix-installer-action`.

### PR Checks (`pr-checks.yml`)

Triggered on every pull request to main. Three parallel jobs:

**Lint job:**
- Install Nix via `DeterminateSystems/nix-installer-action`
- `nixfmt --check flake.nix` — fail if not formatted
- `nix flake check` — validate flake evaluates
- ShellCheck on `agent-sandbox.sh`, `entrypoint.sh`, `init-firewall.sh`
- Conventional commit validation on the PR title via `amannn/action-semantic-pull-request`

**Build + Scan job:**
- `docker build` the image from `Containerfile`
- Trivy container scan (HIGH + CRITICAL severities)
- Trivy filesystem scan on the repository
- Image is **not** pushed — build artifact only

**Nix build job:**
- `nix build` to verify the Nix package builds cleanly

All three jobs are required to pass before merge.

### Image Publishing (`publish-image.yml`)

Triggered on push to main:

1. Build the image from `Containerfile`
2. Tag as `ghcr.io/mstruble/agent-sandbox:<commit-sha>`
3. Push to GHCR via `docker/login-action` + `GITHUB_TOKEN`
4. Trivy container scan on the pushed image
5. Add OCI labels: `org.opencontainers.image.version`, `org.opencontainers.image.source`, `org.opencontainers.image.revision`

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
2. Pull the SHA-tagged image already published by `publish-image.yml` on the merge commit
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

**Container dependencies** (single PR):
- `debian:bookworm-slim` base image — Renovate's Dockerfile manager
- `gh` CLI — regex manager matching the version string in the curl URL
- `rtk` — regex manager matching the version string in the curl URL
- `uv` — regex manager matching the image tag and digest in the `COPY --from` directive
- `claude-code` — regex manager matching the npm version string

**Nix** (single PR):
- `flake.lock` — Renovate's nix manager runs `nix flake update`

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
| gosu privilege drop | Root → sandbox via `gosu`; no sudo installed | Entrypoint runs firewall as root, then irrevocably drops to sandbox |
| Capability dropping | `--cap-drop=ALL` before cap-adds | Removes all default caps; container gets only NET_ADMIN + NET_RAW |
| Privilege escalation | `--security-opt=no-new-privileges` | Prevents execve-based privilege gains; compatible with gosu (syscall-based) |
| IPv6 | Disabled via sysctl in init-firewall.sh | Eliminates iptables bypass via IPv6 |
| Firewall ordering | Firewall runs first in entrypoint | No unprotected network window before agent starts |
| Input sanitization | Workspace basename → `[a-z0-9-]`; path via `realpath` | Prevents name injection and mount ambiguity |
| Resource limits | `--memory=8g --cpus=4` default, user-configurable | Prevents runaway agents from starving the host |
| Domain validation | Hostname regex before `dig` | Prevents injection via extra_domains config |
| API key allowlist | Explicit list, not glob | Prevents leaking unrelated secrets into the container |
| Symlink opt-in | `--follow-symlinks` required, dotfile dirs denied | Prevents accidental exposure of `~/.ssh`, `~/.gnupg`, etc. |
| DNS pinning | UDP 53 restricted to container resolver | Mitigates DNS tunneling exfiltration |
| Binary pinning | Version-pinned downloads over TLS | Enables automated Renovate updates; consistent trust model across all deps |
| IP range fetch | Best-effort with warning | Graceful degradation when GitHub/AWS endpoints are unreachable |
| Release automation | Release Please with conventional commits | Deterministic semver from commit history; auto-generated changelogs |
| Image publishing | SHA on main, semver+latest on release | Every main commit is pullable; releases are stable, never rebuilt |
| Release re-tag | Pull existing SHA image, re-tag | Release image is byte-identical to what was tested on main |
| Dependency updates | Renovate with grouped PRs | Handles custom Containerfile patterns; reduces PR noise via grouping |
| CI runner | `ubuntu-latest` + `DeterminateSystems/nix-installer-action` | No self-hosted runners needed; native amd64 build |
| Security scanning | Trivy on PRs and main | Catches CVEs in OS packages and installed binaries before and after merge |
| Branch protection | Required checks + squash-merge | Ensures clean conventional commit history for Release Please |
| Flake framework | `flake-parts` over `flake-utils` | Supports both per-system (packages, apps) and system-agnostic (modules) outputs cleanly |
| Module split | Three modules: NixOS, darwin, Home Manager | NixOS and darwin are system-level (package only); HM is user-level (package + config) matching the per-user nature of the tool |
| Config generation | `pkgs.formats.toml` via `xdg.configFile` | Standard Nix approach; only writes config when settings differ from defaults |
| Container runtime option | `containerPackage` with per-platform default | More flexible than a boolean toggle; lets users pass any runtime package or null to self-manage |

---

## Security Model

The container boundary is the primary trust line. The network firewall is defense-in-depth. This section documents known trust boundaries and accepted risks.

**Trust boundaries:**

- **SSH agent socket.** The forwarded `SSH_AUTH_SOCK` allows the container to use all keys loaded in the host's SSH agent to authenticate to any SSH server. Port 22 is open outbound. This is required for git-over-SSH but means a misbehaving agent can authenticate as the user to arbitrary SSH hosts. Use `--no-ssh` if git-over-SSH is not needed.
- **Workspace write access.** The agent has full read-write access to the mounted workspace. It can modify `.git/hooks`, `.github/workflows`, `Makefile`, or other files that may execute on the host after the session. Review agent changes before running host-side automation.
- **Broad IP ranges.** GitHub IP ranges (from `api.github.com/meta`) include GitHub Pages, Actions, and other services beyond git and the API. AWS Bedrock CIDRs cover large IP blocks. A determined attacker could host a receiver within these ranges. SNI-based filtering would mitigate this but is not implemented due to complexity.
- **Telemetry domains.** `sentry.io` and `statsig.com` are allowlisted for agent error reporting. These are low-risk exfiltration vectors compared to GitHub and AWS but are reachable from the container.
- **DNS.** DNS queries are pinned to the container's configured resolver (from `/etc/resolv.conf`). This mitigates tunneling to attacker-controlled nameservers but does not prevent all DNS-based exfiltration techniques (e.g., encoding data in queries to domains that resolve through the pinned resolver's upstream chain).

**Mitigations in place:**

- Capabilities dropped to minimum (`NET_ADMIN` + `NET_RAW` only, for iptables)
- `no-new-privileges` prevents execve-based privilege escalation
- IPv6 disabled to prevent firewall bypass
- Firewall established before any agent code runs
- API keys restricted to an explicit allowlist (not a glob pattern)
- Symlink auto-mounting is opt-in and denies dotfile directories by default
- Resource limits prevent host starvation
- All externally installed binaries are version-pinned and downloaded over TLS
- Trivy scans the container image for CVEs on every PR and main push

---

## macOS Caveats

The flake targets `x86_64-darwin` and `aarch64-darwin`. On macOS, containers run inside a Linux VM (Podman Machine or Docker Desktop). This introduces differences from native Linux:

- **SSH agent socket.** The host socket path is remapped through the VM's mount layer. Podman Machine and Docker Desktop handle this differently; the launcher must use the VM-translated path. If the socket is not accessible inside the VM, `--no-ssh` avoids startup failures.
- **`--userns keep-id`.** Podman Machine may not support `keep-id` identically to native Linux Podman. File ownership in the workspace mount may differ. Test during implementation and document any required workarounds.
- **File permissions.** VM-backed mounts (e.g., virtiofs, gRPC FUSE) may not propagate POSIX permissions exactly. Files created by the agent may appear with different ownership on the host.
- **Symlink resolution.** Symlink targets are resolved on the host, but the resulting paths must be accessible inside the VM. Paths outside the VM's shared directories may not mount correctly.
- **iptables.** The firewall runs inside the Linux container, which runs inside the Linux VM. This works correctly — iptables controls the container's network namespace regardless of the host OS.

These caveats will be refined during implementation. Story-level acceptance criteria will be added for any behavior that requires macOS-specific code paths.
