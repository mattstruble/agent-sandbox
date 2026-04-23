# Story: Cross-Platform Install Script

## Source
PRD Capability Group: Distribution > Cross-Platform Install (non-Nix)
Behaviors covered:
- The tool is installable without Nix via `curl -fsSL https://raw.githubusercontent.com/mstruble/agent-sandbox/main/install.sh | sh`.
- Supported platforms: macOS (Intel and Apple Silicon), Linux (x86_64 and aarch64), and Windows via WSL2.
- The only host prerequisite is a container runtime (Docker or Podman). The installer checks for one and errors with platform-specific install instructions if missing.
- The installer does not require sudo.
- The installer downloads a release tarball from GitHub Releases and extracts the launcher to `~/.local/bin/agent-sandbox` and support files to `~/.local/share/agent-sandbox/`.
- If `~/.local/bin` is not on `$PATH`, the installer warns with shell-specific instructions for adding it.
- A specific version can be installed by setting `AGENT_SANDBOX_VERSION` before running the installer.
- The installer supports `--uninstall` to remove the launcher and support files. The config directory (`~/.config/agent-sandbox/`) is preserved.

## Summary
A static `install.sh` script in the repo root that non-Nix users pipe through `curl | sh`. It detects the platform, verifies a container runtime is present, downloads the appropriate release tarball from GitHub Releases, and extracts the launcher and support files to `~/.local/`. Supports versioned install, uninstall, and re-install (for use by the self-update mechanism).

## Acceptance Criteria

### Platform detection
- [ ] The installer detects the OS via `uname -s` and normalizes to `darwin` or `linux`. Any other value causes a clear error naming supported platforms.
- [ ] The installer detects the architecture via `uname -m` and normalizes to `x86_64` or `aarch64` (mapping `arm64` to `aarch64`).
- [ ] On Linux, the installer does not attempt to distinguish native Linux from WSL2 — both are treated identically.

### Prerequisite check
- [ ] The installer checks for `podman` or `docker` on `$PATH`.
- [ ] If neither is found, the installer exits with a non-zero code and prints platform-specific install instructions (e.g., "Install Docker Desktop from https://docker.com/... or Podman from ...").
- [ ] The installer does not attempt to install Docker or Podman.

### Download and extract
- [ ] The installer requires `curl` (errors clearly if missing).
- [ ] When `AGENT_SANDBOX_VERSION` is set, the installer downloads that specific version's tarball from `https://github.com/mstruble/agent-sandbox/releases/download/v${VERSION}/agent-sandbox-${VERSION}.tar.gz`.
- [ ] When `AGENT_SANDBOX_VERSION` is not set, the installer queries the GitHub API (`/repos/mstruble/agent-sandbox/releases/latest`) to determine the latest version.
- [ ] The tarball is extracted to a temporary directory and files are moved to their final locations.
- [ ] The launcher is placed at `~/.local/bin/agent-sandbox` with executable permissions.
- [ ] Support files (entrypoint.sh, init-firewall.sh) are placed at `~/.local/share/agent-sandbox/`.
- [ ] `~/.local/bin/` and `~/.local/share/agent-sandbox/` are created if they do not exist.
- [ ] The installer does not use `sudo` at any point.

### PATH detection
- [ ] After install, the installer checks whether `~/.local/bin` is in the current `$PATH`.
- [ ] If not on `$PATH`, the installer prints instructions for adding it, tailored to the detected shell (`$SHELL`): bash (`~/.bashrc`), zsh (`~/.zshrc`), fish (`~/.config/fish/config.fish`).
- [ ] The installer does not modify any shell rc files.

### Uninstall
- [ ] `install.sh --uninstall` removes `~/.local/bin/agent-sandbox` and `~/.local/share/agent-sandbox/`.
- [ ] Uninstall preserves `~/.config/agent-sandbox/` (user config).
- [ ] Uninstall prints a confirmation message listing what was removed.
- [ ] If the files do not exist, uninstall exits cleanly with a "nothing to remove" message.

### Re-install
- [ ] Running the installer when agent-sandbox is already installed overwrites the existing files (used by the self-update mechanism).
- [ ] The installer prints the installed version on success.

### Script quality
- [ ] `install.sh` passes ShellCheck with no warnings or errors.
- [ ] `install.sh` is POSIX sh compatible (no bash-isms) so it works when piped to `sh`.

## Open Questions
- None.

## Out of Scope
- Installing Docker or Podman (provide instructions only).
- Homebrew tap or other package manager formulas.
- Modifying shell rc files to add `~/.local/bin` to PATH.
- Checksum verification of the downloaded tarball (rely on TLS to GitHub).
