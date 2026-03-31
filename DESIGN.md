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

The container image is built locally on first use and cached by Containerfile content hash. Quick standup and teardown; supports many parallel sessions.

**Reference implementations studied:**
- [`alexjuda/ws1/sandbox`](https://github.com/alexjuda/ws1/tree/main/sandbox) — Podman/Docker Makefile wrapper for opencode
- [`anthropics/claude-code/.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer) — iptables firewall approach
- [`rtk-ai/rtk`](https://github.com/rtk-ai/rtk) — token compression proxy for AI agent tool calls

---

## Repository Layout

```
agent-sandbox/
├── flake.nix           # Nix package + app definition
├── flake.lock
├── agent-sandbox.sh    # Launcher script  → installed to $out/bin/
├── Containerfile       # Image definition → installed to $out/share/agent-sandbox/
├── entrypoint.sh       # Container entrypoint → $out/share/agent-sandbox/
└── init-firewall.sh    # iptables allowlist  → $out/share/agent-sandbox/
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
| bash, curl, git, make, wget, sudo | apt |
| iptables, ipset, iproute2, dnsutils | apt |
| jq, aggregate, ca-certificates | apt |
| nodejs, npm | apt |
| `gh` CLI | `eget cli/cli --tag vX.Y.Z` + SHA256 verify |
| `uv` | copied from `ghcr.io/astral-sh/uv` (pinned digest) |
| `opencode` | official install script |
| `claude-code` | `npm install -g @anthropic-ai/claude-code@X.Y.Z` |
| `rtk` | `eget rtk-ai/rtk --tag vX.Y.Z` + SHA256 verify → `/usr/local/bin/rtk` |

**Binary verification:** Binaries installed via `eget` (`gh`, `rtk`) are pinned to specific release versions and verified against hardcoded SHA256 checksums after download. If a checksum does not match, the build fails. The `claude-code` npm package is pinned to a specific version. Checksums and versions are maintained in the Containerfile and updated via PRs.

`opencode db migrate` is run at image build time to avoid a hang on first container start (a known issue discovered in ws1/sandbox).

A `sandbox` user is created at UID 1000 with sudo scoped to exactly one command: `sandbox ALL=(root) NOPASSWD: /init-firewall.sh`. No other sudo access is granted.

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

1. Run `sudo /init-firewall.sh` to establish iptables allowlist and disable IPv6 — **first**, before any other step
2. Copy `/host-config/opencode/` → `~/.config/opencode/` (writable); skip if not mounted
3. Copy `/host-config/claude/` → `~/.claude/` (writable); skip if not mounted
4. Apply permission overrides: use `jq` to set all permission fields to `"allow"` in `~/.config/opencode/config.json`; create the file if absent
5. Based on `$AGENT` env var (set by launcher):
   - `opencode`: run `rtk init -g --opencode`
   - `claude`: run `rtk init -g`
6. `exec` the agent binary with `/workspace` as working directory:
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

## Design Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Scoped sudo | `NOPASSWD: /init-firewall.sh` only | Least privilege; sandbox user cannot escalate beyond firewall setup |
| Capability dropping | `--cap-drop=ALL` before cap-adds | Removes all default caps; container gets only NET_ADMIN + NET_RAW |
| Privilege escalation | `--security-opt=no-new-privileges` | Prevents in-container escalation |
| IPv6 | Disabled via sysctl in init-firewall.sh | Eliminates iptables bypass via IPv6 |
| Firewall ordering | Firewall runs first in entrypoint | No unprotected network window before agent starts |
| Input sanitization | Workspace basename → `[a-z0-9-]`; path via `realpath` | Prevents name injection and mount ambiguity |
| Resource limits | `--memory=8g --cpus=4` default, user-configurable | Prevents runaway agents from starving the host |
| Domain validation | Hostname regex before `dig` | Prevents injection via extra_domains config |
| API key allowlist | Explicit list, not glob | Prevents leaking unrelated secrets into the container |
| Symlink opt-in | `--follow-symlinks` required, dotfile dirs denied | Prevents accidental exposure of `~/.ssh`, `~/.gnupg`, etc. |
| DNS pinning | UDP 53 restricted to container resolver | Mitigates DNS tunneling exfiltration |
| Binary pinning | Versions + SHA256 checksums for eget-installed binaries | Mitigates supply chain tampering |
| IP range fetch | Best-effort with warning | Graceful degradation when GitHub/AWS endpoints are unreachable |

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
- `no-new-privileges` prevents in-container privilege escalation
- IPv6 disabled to prevent firewall bypass
- Firewall established before any agent code runs
- API keys restricted to an explicit allowlist (not a glob pattern)
- Symlink auto-mounting is opt-in and denies dotfile directories by default
- Resource limits prevent host starvation
- All eget-installed binaries are version-pinned with SHA256 checksum verification

---

## macOS Caveats

The flake targets `x86_64-darwin` and `aarch64-darwin`. On macOS, containers run inside a Linux VM (Podman Machine or Docker Desktop). This introduces differences from native Linux:

- **SSH agent socket.** The host socket path is remapped through the VM's mount layer. Podman Machine and Docker Desktop handle this differently; the launcher must use the VM-translated path. If the socket is not accessible inside the VM, `--no-ssh` avoids startup failures.
- **`--userns keep-id`.** Podman Machine may not support `keep-id` identically to native Linux Podman. File ownership in the workspace mount may differ. Test during implementation and document any required workarounds.
- **File permissions.** VM-backed mounts (e.g., virtiofs, gRPC FUSE) may not propagate POSIX permissions exactly. Files created by the agent may appear with different ownership on the host.
- **Symlink resolution.** Symlink targets are resolved on the host, but the resulting paths must be accessible inside the VM. Paths outside the VM's shared directories may not mount correctly.
- **iptables.** The firewall runs inside the Linux container, which runs inside the Linux VM. This works correctly — iptables controls the container's network namespace regardless of the host OS.

These caveats will be refined during implementation. Story-level acceptance criteria will be added for any behavior that requires macOS-specific code paths.
