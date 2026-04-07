# Story: Nix-Native Container Image Build

## Source
PRD Capability Group: Image Management, Runtime Package Management
Behaviors covered:
- The container image is built entirely from Nix using `dockerTools.buildLayeredImage` — there is no Containerfile.
- All packages, user configuration, and static files are declared in the project's `flake.nix` and associated Nix expressions.
- The container image is built entirely from Nix — all system packages are provided by nixpkgs. There is no Debian base layer, no apt-get, and no secondary package manager.
- `claude-code` is installed via `npm install -g --ignore-scripts` using the Nix-provided nodejs.
- The `sandbox` user (UID 1000) is defined in the Nix expression via `/etc/passwd` generation.
- The container starts as root, drops to sandbox via `su-exec` (replacing `gosu`).
- Static files (Nix instructions text, default OpenCode permissions JSON) are built into the image at `/etc/agent-sandbox/`.

## Summary
Replaces the Debian-based Containerfile with a pure Nix image built via `dockerTools.buildLayeredImage`, following the pattern from upstream NixOS/nix `docker.nix`. All system packages come from nixpkgs. User management, `/etc/passwd` generation, nix.conf, flake registry, and static entrypoint files are all expressed in Nix. The Containerfile is removed from the repository. `gosu` is replaced with `su-exec`.

## Acceptance Criteria

### Nix image expression
- [ ] `flake.nix` exports a `packages.<system>.container-image` output that produces an OCI image tarball via `dockerTools.buildLayeredImage`.
- [ ] The image contains all required packages from nixpkgs: bash, curl, git, make, su-exec, procps, findutils, coreutils, iptables, ipset, iproute2, dnsutils, jq, ca-certificates, xz, chrony, nodejs, npm, gh, uv, nix.
- [ ] The image contains custom derivations for `opencode` and `rtk` (from `packages/` directory).
- [ ] `claude-code` is installed via `npm install -g --ignore-scripts @anthropic-ai/claude-code@<version>` using the Nix-provided nodejs in a build step.
- [ ] The `--ignore-scripts` flag is present on the npm install to prevent post-install script execution.
- [ ] `nix build .#container-image` produces a tarball loadable via `docker load < result` or `podman load < result`.

### User management
- [ ] `/etc/passwd` contains a `sandbox` user with UID 1000 and home directory `/home/sandbox`.
- [ ] `/etc/group` contains the corresponding group entry.
- [ ] `/etc/shadow` contains a locked password entry for the sandbox user.
- [ ] `/home/sandbox` exists and is owned by the sandbox user.
- [ ] `/nix` exists and is owned by the sandbox user.
- [ ] No `useradd` or `shadow` package is needed at runtime — user entries are generated at build time.

### Nix configuration (baked into image)
- [ ] `/etc/nix/nix.conf` is present with `experimental-features = nix-command flakes`, `sandbox = false`, `warn-dirty = false`, `accept-flake-config = false`, substituters locked to `cache.nixos.org`.
- [ ] `/etc/nix/nix.conf` is owned by root and not writable by the sandbox user.
- [ ] The Nix flake registry pins `nixpkgs` to the same revision used in the project's `flake.lock`, generated via the `flake-registry` parameter of the image build.
- [ ] `nix registry list` as the sandbox user shows the pinned `nixpkgs` entry.

### Static entrypoint files
- [ ] `/etc/agent-sandbox/nix-instructions.md` exists in the image, containing the Nix usage instructions text.
- [ ] `/etc/agent-sandbox/opencode-permissions.json` exists in the image, containing the default OpenCode permissions JSON.
- [ ] Both files are readable by the sandbox user.

### OCI image configuration
- [ ] The image entrypoint is set to `/entrypoint.sh`.
- [ ] The image working directory is `/workspace`.
- [ ] `PATH` includes the Nix profile binary directories.
- [ ] `SSL_CERT_FILE`, `GIT_SSL_CAINFO`, and `NIX_SSL_CERT_FILE` point to the Nix CA bundle.
- [ ] OCI labels include `org.opencontainers.image.title`, `org.opencontainers.image.source`, `org.opencontainers.image.description`.

### Entrypoint and firewall scripts
- [ ] `entrypoint.sh` is included in the image and is executable.
- [ ] `init-firewall.sh` is included in the image and is executable.
- [ ] `entrypoint.sh` uses `su-exec` instead of `gosu` for privilege dropping.
- [ ] `entrypoint.sh` reads Nix instructions from `/etc/agent-sandbox/nix-instructions.md` instead of an inline heredoc.
- [ ] `entrypoint.sh` reads default permissions from `/etc/agent-sandbox/opencode-permissions.json` when no host config exists, instead of an inline heredoc.
- [ ] `init-firewall.sh` does not hardcode `/usr/sbin:/usr/bin` PATH prefixes — binaries are on PATH via the Nix profile.

### bashrc
- [ ] `/home/sandbox/.bashrc` contains the `command_not_found_handle` function suggesting `nix run nixpkgs#<cmd>`.

### Containerfile removal
- [ ] The `Containerfile` is removed from the repository.
- [ ] No references to `Containerfile` remain in `flake.nix`, `Makefile`, or scripts (except historical references in design docs or changelogs).

## Open Questions
- None.

## Out of Scope
- Multi-architecture builds (covered by multi-arch-image-publishing story).
- Launcher changes for pull-only image management (covered by launcher-pull-only story).
- Custom derivation implementation details (covered by custom-nix-derivations story).
- CI workflow changes (covered by respective CI stories).
