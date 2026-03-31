# Story: Self-Update Mechanism

## Source
PRD Capability Group: Distribution > Cross-Platform Install (non-Nix)
Behaviors covered:
- `agent-sandbox --update` checks for a newer release and updates the launcher and support files in place.
- When `--update` detects it is running from a Nix store path, it advises using Nix-native update methods instead.

## Summary
Adds an `--update` flag to the launcher that checks for a newer version on GitHub Releases and re-installs if one is available. The update downloads and runs the install script from the main branch with the latest version pinned. When running from a read-only Nix store path, the flag prints guidance to use Nix-native update methods instead of attempting a write.

## Acceptance Criteria

### Version check
- [ ] `agent-sandbox --update` queries the GitHub API for the latest release tag.
- [ ] The launcher compares the latest release version against the `VERSION` baked into the running launcher.
- [ ] If the versions match, prints "agent-sandbox is already up to date (vX.Y.Z)" and exits 0.

### Update execution
- [ ] If a newer version is available, the launcher downloads `install.sh` from `https://raw.githubusercontent.com/mstruble/agent-sandbox/main/install.sh`.
- [ ] The downloaded install script is executed with `AGENT_SANDBOX_VERSION` set to the latest release version.
- [ ] On success, prints "Updated agent-sandbox from vX.Y.Z to vA.B.C".
- [ ] On failure (download error, install error), exits non-zero with a clear error message.

### Nix store detection
- [ ] If the launcher's path starts with `/nix/store/`, `--update` does not attempt to download or install.
- [ ] Instead it prints: "Installed via Nix. Update with: nix profile upgrade or update your flake input." and exits 0.

### CLI integration
- [ ] `--update` is documented in the `--help` output.
- [ ] `--update` is mutually exclusive with `--build`, `--list`, `--stop`, `--prune`, and running a session.

## Open Questions
- None.

## Out of Scope
- Downgrading to a specific older version (use `AGENT_SANDBOX_VERSION` with the install script directly).
- Auto-update on launch (update is always explicit via `--update`).
- Updating the container image (the launcher pulls the matching GHCR tag at runtime).
