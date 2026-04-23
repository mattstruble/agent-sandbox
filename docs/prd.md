# PRD: agent-sandbox

## Problem Statement

AI coding agents (OpenCode) run with full network access and access to the host filesystem. This creates two problems: **safety** — the agent can make outbound calls to arbitrary hosts, potentially exfiltrating code or secrets — and **cost** — every tool call returns uncompressed output that consumes LLM tokens unnecessarily.

`agent-sandbox` solves both: it runs the agent inside a container with a strict network allowlist and `rtk` pre-configured for transparent token compression, with no per-session setup required.

## User Stories

- As a developer, I want to run an AI coding agent against a project without exposing my host network or filesystem, so that I can work without risk of unintended data exfiltration.
- As a developer, I want token consumption reduced automatically on every agent session, so that I don't pay for verbose tool output.
- As a developer, I want to start a sandbox from any directory with a single command, so that the workflow is as fast as running the agent directly.
- As a developer, I want to run multiple sandboxed agent sessions in parallel on different projects, so that I can parallelize work without sessions interfering with each other.
- As a developer, I want my git identity, SSH credentials, and API keys available inside the sandbox, so that the agent can perform the same operations it could outside the sandbox.
- As a developer without Nix, I want a pre-built container image available on GHCR, so that I can run the sandbox without Nix and without waiting for a local build.
- As a Nix user on macOS, I want `nix run` to build and load the container image locally, so that I can use the sandbox without depending on GHCR or a published image.
- As a maintainer, I want automated semver releases driven by conventional commits, so that versioning is consistent and changelogs are generated automatically.
- As a maintainer, I want PRs to be linted, scanned, and validated before merge, so that broken or insecure changes don't reach main.
- As a maintainer, I want dependency update PRs opened automatically, so that pinned versions stay current without manual tracking.
- As a developer, I want the agent to install and run arbitrary software packages on demand inside the sandbox, so that I don't need to pre-install every tool the agent might need or rebuild the container image when a new tool is required.
- As a developer without Nix, I want to install agent-sandbox with a single curl command on macOS, Linux, or WSL2, so that I can use the tool without adopting Nix.
- As a NixOS, nix-darwin, or Home Manager user, I want to enable agent-sandbox declaratively in my Nix configuration and manage its settings through Nix options, so that the tool integrates with my existing system management workflow.

## Expected Behaviors

### Sandbox Lifecycle

- Running `agent-sandbox` from a directory starts a sandboxed session with that directory as the workspace.
- An explicit workspace path may be passed as an argument; if omitted, the current directory is used.
- The active agent defaults to OpenCode; no other agents are supported in the current release.
- Each session is identified by a name derived deterministically from the agent and the absolute workspace path — starting the same session twice does not create duplicate containers.
- `--list` displays all currently running agent-sandbox containers.
- `--stop` terminates the sandbox for the current (or specified) workspace.
- The container is removed automatically when the agent exits.

### Workspace Isolation

- Only the target workspace directory is accessible to the agent; the rest of the host filesystem is not mounted.
- Files written by the agent inside the workspace are reflected on the host filesystem immediately.
- The agent's working directory inside the container is the root of the mounted workspace.

### Network Sandboxing

- All outbound network traffic is filtered before the agent starts; there is no window where the agent runs without restrictions.
- Only TCP ports 80 (HTTP), 443 (HTTPS), and optionally 22 (SSH) are permitted outbound. UDP port 123 (NTP) is permitted to pinned Cloudflare server IPs only. All other protocols and ports are blocked.
- DNS is pinned to the container's configured resolver only. Queries to other DNS servers are rejected.
- Connections on non-allowed ports are rejected immediately (ICMP admin-prohibited), not silently dropped.

### Time Synchronization

- The container's system clock is kept synchronized with an external time source for the lifetime of the session.
- Time synchronization starts before the agent and runs continuously in the background, correcting drift caused by host sleep/resume (e.g., macOS lid close with Podman Machine).
- NTP traffic is restricted to pinned Cloudflare server IPs only; NTP to any other destination is rejected.
- If time synchronization fails to start, the container starts normally without it — time sync failure never blocks a session.

### Agent Configuration

- The host agent configs (`~/.config/opencode/` for OpenCode) are available to the agent inside the sandbox.
- Config changes made by the agent during a session do not persist back to the host.
- The host git identity (`~/.gitconfig`) is available to the agent.
- SSH operations use the host's SSH agent via socket forwarding; no private key material enters the container.
- API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `MISTRAL_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) and `GITHUB_TOKEN` present in the host environment are forwarded into the sandbox. Additional variables can be added via `config.toml`.
- The sandbox overrides agent tool permissions to fully allow for the duration of the session; the agent never prompts for approval to read, edit, or run commands.
- Permission overrides are applied regardless of what the host agent config specifies.
- The sandbox enforces container resource limits (memory and CPU) to prevent a runaway agent from starving the host; limits are configurable by the user.

### Token Savings

- `rtk` is pre-installed and configured for the active agent at the start of every session, with no user setup required.
- Shell commands (git, cargo, cat, ls, grep, and others) are transparently rewritten to `rtk` equivalents inside the container, reducing token consumption by 60–90%.

### Runtime Package Management

- The container image is built entirely from Nix — all system packages (git, curl, iptables, chrony, jq, nodejs, etc.) are provided by nixpkgs. There is no Debian base layer, no apt-get, and no secondary package manager.
- Custom derivations in the project's Nix expressions provide binaries not available in nixpkgs (opencode, rtk). These derivations use `fetchurl` with per-architecture URLs and SHA256 hashes.
- The default container image ships OpenCode only. Support for other agents is a future addition and not included in the default image.
- Nix is pre-installed inside the container at build time so the agent can install and run arbitrary software packages on demand without root access.
- The agent can run any package from nixpkgs via `nix run nixpkgs#<package>` or enter a shell with packages via `nix shell nixpkgs#<package>`.
- The agent can run packages from arbitrary flake URIs (e.g., `nix run github:user/repo#thing`); there is no restriction on which flake sources the agent can use.
- The `nix` command is available on `PATH` for all shell sessions (interactive and non-interactive) via the image's environment configuration, not via shell profile sourcing.
- The nixpkgs revision used for runtime `nix run` commands is pinned at build time via the Nix flake registry, derived from the same `flake.lock` that pins build-time dependencies. There is no separate nixpkgs version pin to maintain.
- The pinned nixpkgs revision is updated automatically when Renovate updates `flake.lock`.
- Binary substitutes (pre-built packages) are downloaded only from the official Nix binary cache (`cache.nixos.org`). Third-party binary caches are not trusted.
- Nix configuration (`/etc/nix/nix.conf`) and the flake registry are owned by root and read-only to the sandbox user. The agent cannot modify Nix's core settings (substituters, experimental features, trust model).
- The Nix store (`/nix/store`) is ephemeral — packages downloaded or built during a session are not persisted across container restarts. Each session starts with a clean store containing only the Nix tooling itself.
- The Nix installation works on amd64 — the Nix expression produces architecture-appropriate images. ARM64 image support is deferred until a native ARM runner is available for CI.
- The entrypoint appends Nix usage instructions to the active agent's system prompt file (`~/.config/opencode/AGENTS.md` for OpenCode) at session start, so the agent knows to use `nix run`/`nix shell` for tools not on PATH. The Nix instructions text is stored as a static file in the image, read by the entrypoint at runtime.
- A shell `command_not_found_handle` in `/home/sandbox/.bashrc` suggests `nix run nixpkgs#<cmd>` when an unrecognized command is executed, providing a reactive fallback hint for both agents.

### Image Management

- The container image is built entirely from Nix using `dockerTools.buildLayeredImage` — there is no Containerfile. All packages, user configuration, and static files are declared in the project's `flake.nix` and associated Nix expressions.
- The container image (`packages.<system>.container-image`) is buildable on all supported systems (x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin). On darwin, it cross-compiles to Linux via a configured Linux builder.
- The launcher sources the container image through a three-tier chain: (1) if `agent-sandbox:<version>` exists in the local container runtime, use it; (2) if the `AGENT_SANDBOX_IMAGE_PATH` environment variable is set, load the image tarball from that path into the runtime; (3) fall back to pulling `ghcr.io/mstruble/agent-sandbox:<version>` from GHCR.
- For Nix users, the `apps.default` wrapper and Nix modules set `AGENT_SANDBOX_IMAGE_PATH` to the Nix-built container image store path, bypassing GHCR entirely.
- For non-Nix users (installed via `install.sh`), GHCR pull is the sole image source.
- The image tag matches the launcher's baked-in version. When the launcher runs, it checks for `agent-sandbox:<version>` locally before attempting other sources.
- `--pull` forces a re-pull of the image from GHCR regardless of local cache state or `AGENT_SANDBOX_IMAGE_PATH`.
- `--prune` removes locally cached images whose tag does not match the launcher's version.

### Distribution

#### Cross-Platform Install (non-Nix)

- The tool is installable without Nix via `curl -fsSL https://raw.githubusercontent.com/mstruble/agent-sandbox/main/install.sh | sh`.
- Supported platforms: macOS (Intel and Apple Silicon), Linux (x86_64 and aarch64), and Windows via WSL2.
- The only host prerequisite is a container runtime (Docker or Podman). The installer checks for one and errors with platform-specific install instructions if missing.
- The installer does not require sudo.
- The installer downloads a release tarball from GitHub Releases and extracts the launcher to `~/.local/bin/agent-sandbox` and support files to `~/.local/share/agent-sandbox/`.
- If `~/.local/bin` is not on `$PATH`, the installer warns with shell-specific instructions for adding it.
- A specific version can be installed by setting `AGENT_SANDBOX_VERSION` before running the installer.
- The installer supports `--uninstall` to remove the launcher and support files. The config directory (`~/.config/agent-sandbox/`) is preserved.
- `agent-sandbox --update` checks for a newer release and updates the launcher and support files in place.
- When `--update` detects it is running from a Nix store path, it advises using Nix-native update methods instead.

#### Launcher Portability

- The launcher is compatible with bash 3.2+ and does not require GNU coreutils, GNU sed, GNU grep, or dasel on the host.
- Config file parsing (`~/.config/agent-sandbox/config.toml`) uses Python3 `tomllib` (3.11+). Python3 is only required when the config file exists; users without a config file have no Python3 dependency.
- Symlink resolution uses `realpath` with a Python3 fallback, replacing the GNU `readlink -f` dependency.
- The launcher auto-detects Podman or Docker on `$PATH` (preferring Podman) and accepts `AGENT_SANDBOX_RUNTIME` or `--runtime` to override.

#### Nix Distribution

- The tool is runnable without installation via `nix run github:mstruble/agent-sandbox`.
- `nix run` loads the container image into the local container runtime and runs the launcher, with no GHCR dependency. The `apps.default` wrapper sets `AGENT_SANDBOX_IMAGE_PATH` to the Nix-built container image and execs the launcher.
- The tool is installable into a user profile via `nix profile install github:mstruble/agent-sandbox`.
- The tool is referenceable as a flake input from other Nix flakes.
- The flake is structured using `flake-parts` to support both per-system outputs (packages, apps) and system-agnostic outputs (modules).
- The flake exposes a NixOS module (`nixosModules.default`), a nix-darwin module (`darwinModules.default`), and a Home Manager module (`homeManagerModules.default`).
- All three modules expose `programs.agent-sandbox.enable` to add the tool to the environment and `programs.agent-sandbox.package` to override the default package.
- All three modules expose `programs.agent-sandbox.containerPackage` to specify the container runtime package. Defaults to `pkgs.podman` on Linux, `null` on darwin. When set, the package is added to the environment. When `null`, the user ensures a container runtime is available on PATH.
- All three modules expose `programs.agent-sandbox.image` to specify the container image package. When set, the launcher is wrapped with `AGENT_SANDBOX_IMAGE_PATH` pointing to the image store path, enabling local image loading without GHCR. When `null`, the launcher falls back to GHCR pull.
- The Home Manager module generates `~/.config/agent-sandbox/config.toml` from typed Nix options covering all config sections: default agent, extra network domains, extra environment variables, symlink behavior, extra mount paths, and resource limits.
- When no settings are configured in the Home Manager module, no config file is generated (the launcher uses its built-in defaults).
- The NixOS and nix-darwin modules do not manage agent-sandbox configuration.

#### Image Publishing

- The container image is published to GHCR at `ghcr.io/mstruble/agent-sandbox`.
- Images are published for `linux/amd64`. ARM64 support is deferred until a native ARM runner is available for CI.
- Every push to main builds on an x86_64 runner, pushes an arch-specific image, and creates a manifest tagged with the commit SHA (`ghcr.io/mstruble/agent-sandbox:<commit-sha>`).
- Every semver release publishes a version-tagged image (`ghcr.io/mstruble/agent-sandbox:<semver>`) and updates the `:latest` tag.
- `agent-sandbox --version` prints the current version and exits.

### Testing & Validation

#### Launcher Unit Tests
- Launcher functions are extractable and sourceable in isolation via a `BASH_SOURCE` guard without triggering side effects.
- Argument parsing logic is testable for all flags, invalid inputs, and defaults.
- Config TOML loading is testable for valid config, missing config, partial config, and invalid TOML.
- Container name generation produces deterministic names and handles special characters in paths.
- Image tag computation is testable in isolation (version-based tagging).
- Symlink resolution is testable with filesystem fixtures covering `follow_symlinks`, `follow_all_symlinks`, nested symlinks, broken symlinks, and symlinks into dotfile directories.
- Dotfile directory protection rejects mounts that would expose sensitive directories.
- Extra mount path validation is testable.
- Resource limit parsing is testable.
- Environment variable passthrough assembly is testable.
- Self-update version comparison logic is testable.

#### Container Integration Tests
- Expected binaries (`opencode`, `rtk`, `gh`, `uv`, `node`, `git`, `nix`) exist and are executable inside the built image.
- The `sandbox` user exists with UID 1000 and correct permissions.
- Firewall allows outbound TCP 80 and 443.
- Firewall allows outbound UDP 123 (NTP) to pinned Cloudflare IPs only; NTP to non-pinned IPs is rejected.
- Firewall blocks non-allowed ports (e.g., 8080, 3000).
- DNS resolution works through the pinned resolver.
- IPv6 is disabled.
- The entrypoint drops to the `sandbox` user via `su-exec` after the root setup phase.
- Staged host configs (git config, SSH socket, API keys) land at expected paths inside the container and are readable by the `sandbox` user.
- A fake agent binary mounted over the real agent binary is executed by the entrypoint without production code changes.
- `nix run nixpkgs#hello` executes successfully inside the container as the sandbox user.
- The Nix flake registry resolves `nixpkgs` to the pinned revision.
- `/etc/nix/nix.conf` and `/etc/nix/registry.json` are owned by root and not writable by the sandbox user.
- The Nix binary cache is configured to `cache.nixos.org` only.
- Running a nonexistent command in the sandbox shell outputs a `nix run nixpkgs#` suggestion via `command_not_found_handle`.
- The entrypoint appends Nix usage instructions to `~/.config/opencode/AGENTS.md` for OpenCode sessions.

#### End-to-End Tests
- Invoking `agent-sandbox.sh` with a temporary workspace directory starts a container and the fake agent runs to completion.
- The workspace is mounted correctly at `/workspace` inside the container.
- When symlink following is enabled, symlinked directories are accessible inside the container with readable contents (not broken symlink paths).
- The container name matches the expected deterministic pattern.
- The container is cleaned up after the agent exits.

#### Test Infrastructure
- Tests use bats-core with bats-assert and bats-support as the test framework.
- A Makefile provides `test-unit`, `test-integration`, `test-e2e`, `test` (all), and `test-fast` (unit alias) targets.
- Integration and e2e targets require the container image to be loaded locally (built via `nix build .#container-image` on any supported system, or pulled from GHCR).
- bats-core and helper libraries are provided via a Nix devShell in `flake.nix`.
- Tests are tagged (`unit`, `integration`, `e2e`) to support selective execution via `bats --filter-tags`.
- CI runs all test tiers after the image build step in `pr-checks.yml`.

### Continuous Integration

- Every pull request to main runs lint checks, builds the container image, scans it for vulnerabilities, and runs the full test suite before merge.
- ShellCheck validates all bash scripts (`agent-sandbox.sh`, `entrypoint.sh`, `init-firewall.sh`, `install.sh`).
- `nixfmt` validates Nix formatting; `nix flake check` validates the flake evaluates correctly; `nix build` validates the package builds.
- PR titles are validated against the conventional commit format (required for Release Please changelog generation).
- `vulnix` scans the Nix store closure of the built container image against the NVD for known vulnerabilities on every PR and every push to main.
- Trivy performs a filesystem scan on the repository on every PR and every push to main.
- All test tiers (unit, integration, e2e) run after the container image is built in CI.
- All CI checks are required to pass before a PR can be merged.
- PRs are merged via squash-merge only.

### Versioning & Releases

- Versioning follows semver and is automated via Release Please based on conventional commits.
- When conventional commits land on main, Release Please opens (or updates) a PR that bumps the version and generates a changelog.
- Merging the release PR creates a GitHub Release with a semver tag.
- The version source of truth is `flake.nix`; Release Please bumps it there.
- The launcher supports `--version` (or `-v`) which prints the version and exits.
- Each GitHub Release includes a platform-independent tarball (`agent-sandbox-<semver>.tar.gz`) containing the launcher (with version and share-dir substituted for the non-Nix install path) and support files (entrypoint and firewall scripts).

### Dependency Management

- Renovate opens dependency update PRs automatically, grouped by category.
- Most container dependencies (git, curl, iptables, chrony, jq, nodejs, gh, uv, etc.) are managed through the `flake.lock` nixpkgs pin. Updating `flake.lock` updates all nixpkgs-sourced packages in one operation.
- Custom Nix derivations for opencode and rtk have version strings and SHA256 hashes tracked by Renovate regex managers targeting the files in the `packages/` directory.
- Nix flake inputs (`flake.lock`) are grouped into a single PR.
- GitHub Actions versions are grouped into a single PR.
- Dependency versions are pinned via `flake.lock` and per-derivation SHA256 hashes.

## Open Questions

- Should config changes inside the sandbox optionally be persisted back to the host (e.g. via a `--persist-config` flag)? Currently all in-session config changes are ephemeral.
- Should there be a mode that disables network sandboxing entirely for cases where the user needs unrestricted access?
- Should `rtk` gain stats (`rtk gain`) be persisted across sessions, or is per-session ephemerality acceptable?

## Out of Scope

- Nix store persistence across sessions — packages are re-downloaded each session; shared caches or volumes are not supported.
- Per-project config files — configuration is user-global (`~/.config/agent-sandbox/config.toml`) only.
- Support for agents other than OpenCode.
- Native Windows support (PowerShell/cmd.exe). Windows is supported via WSL2 only.
- Homebrew tap or other package manager distribution (curl|sh is the non-Nix install path).
