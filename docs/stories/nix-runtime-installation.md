# Story: Nix Runtime Installation

## Source
PRD Capability Group: Runtime Package Management
Behaviors covered:
- Nix is pre-installed inside the container at build time as a single-user installation (no daemon) so the agent can install and run arbitrary software packages on demand without root access.
- The agent can run any package from nixpkgs via `nix run nixpkgs#<package>` or enter a shell with packages via `nix shell nixpkgs#<package>`.
- The agent can run packages from arbitrary flake URIs (e.g., `nix run github:user/repo#thing`); there is no restriction on which flake sources the agent can use.
- The `nix` command is available on `PATH` for all shell sessions (interactive and non-interactive) via a container-level `ENV` directive, not via shell profile sourcing.
- The Nix store (`/nix/store`) is ephemeral — packages downloaded or built during a session are not persisted across container restarts. Each session starts with a clean store containing only the Nix tooling itself.
- The Nix installation works on both amd64 and arm64 architectures without architecture-specific build steps.

## Summary
Adds a single-user Nix installation to the container image at build time. The Nix installer runs as the `sandbox` user against a root-created `/nix` directory. The `nix` binary is added to `PATH` via a Containerfile `ENV` directive so it is available in all shell contexts. No Nix daemon runs; the store is ephemeral per container lifecycle.

## Acceptance Criteria

### Containerfile changes
- [ ] `/nix` is created and owned by `sandbox:sandbox` before the Nix install step.
- [ ] Nix is installed in single-user mode (`--no-daemon`) as the `sandbox` user.
- [ ] The Nix installer does not depend on architecture-specific URLs or flags — the same `RUN` instruction works for both amd64 and arm64 builds.
- [ ] An `ENV PATH` directive adds the Nix binary directory to `PATH` so that `nix` is available in non-interactive shells without sourcing profile scripts.
- [ ] The Nix install step is placed after the `sandbox` user is created and before tool installations that don't depend on Nix (opencode, claude-code).
- [ ] The build completes without the Nix daemon running (no `nix-daemon` process, no systemd socket).

### Runtime behavior
- [ ] `nix --version` succeeds as the `sandbox` user inside the container.
- [ ] `nix run nixpkgs#hello` executes successfully (downloads from binary cache, runs, exits 0).
- [ ] `nix shell nixpkgs#jq --command jq --version` succeeds.
- [ ] `nix run github:nixos/nixpkgs/nixpkgs-unstable#cowsay` succeeds (arbitrary flake URI).
- [ ] The Nix store contains only the Nix tooling after a fresh container start (no leftover packages from the build layer beyond what Nix itself requires).

### Integration tests
- [ ] `nix` is added to the existing binary-existence integration test (`nix` is executable inside the image).
- [ ] A new integration test verifies `nix run nixpkgs#hello` completes successfully as the `sandbox` user.

### Agent awareness
- [ ] `entrypoint.sh` appends a Nix usage section to `~/.config/opencode/AGENTS.md` after config staging.
- [ ] `entrypoint.sh` appends a Nix usage section to `~/.claude/CLAUDE.md` after config staging.
- [ ] The append creates the file if it does not exist and preserves existing content if it does.
- [ ] `/home/sandbox/.bashrc` contains a `command_not_found_handle` function that suggests `nix run nixpkgs#<cmd>`.
- [ ] Running a nonexistent command in an interactive bash shell outputs a message containing `nix run nixpkgs#`.

## Open Questions
- None.

## Out of Scope
- Nix configuration hardening (substituters, registry pinning, immutable config) — covered by the Nix Configuration and Security Hardening story.
- Persisting the Nix store across sessions.
- Replacing existing apt packages or binary downloads with Nix equivalents.
