# Story: Launcher Image Sourcing

## Source
PRD Capability Group: Image Management
Behaviors covered:
- The launcher sources the container image through a three-tier chain: local tag, `AGENT_SANDBOX_IMAGE_PATH`, GHCR pull.
- For Nix users, `AGENT_SANDBOX_IMAGE_PATH` is set by the app wrapper or modules, bypassing GHCR.
- For non-Nix users, GHCR pull is the sole image source.
- `--pull` forces a re-pull from GHCR regardless of other sources.
- `--prune` removes locally cached images whose tag does not match the launcher's version.

## Summary
The launcher uses a three-tier image sourcing chain. Tier 1: check if `agent-sandbox:<version>` already exists in the local container runtime. Tier 2: if `AGENT_SANDBOX_IMAGE_PATH` is set, load the image tarball from that path into the runtime. Tier 3: pull from GHCR. Nix distribution (app wrapper, modules) sets `AGENT_SANDBOX_IMAGE_PATH` to the Nix-built image store path so Nix users never depend on GHCR. Non-Nix users installed via `install.sh` rely on tier 3 exclusively.

## Acceptance Criteria

### Tier 1: Local image check
- [ ] On startup, if `agent-sandbox:<version>` exists in the local container runtime, the launcher uses it immediately with no pull or load.
- [ ] The version is the `@VERSION@` value baked into the launcher at build/install time.

### Tier 2: `AGENT_SANDBOX_IMAGE_PATH` loading
- [ ] If the local image does not exist and `AGENT_SANDBOX_IMAGE_PATH` is set, the launcher loads the image tarball via `$runtime load < $AGENT_SANDBOX_IMAGE_PATH`.
- [ ] After loading, the launcher tags the image as `agent-sandbox:<version>` so tier 1 succeeds on subsequent runs.
- [ ] If the load fails (file not found, invalid tarball, runtime error), the launcher exits with a clear error message and does not fall through to GHCR pull.
- [ ] The launcher prints a message when loading from the path (e.g., `Loading image from <path>...`).

### Tier 3: GHCR pull (fallback)
- [ ] If the local image does not exist and `AGENT_SANDBOX_IMAGE_PATH` is not set, the launcher pulls `ghcr.io/mstruble/agent-sandbox:<version>` from GHCR.
- [ ] The launcher prints a message when pulling (e.g., `Pulling image ghcr.io/mstruble/agent-sandbox:<version>...`).
- [ ] If the pull fails (network error, image not found), the launcher exits with a clear error message.
- [ ] After pulling, the image is tagged locally as `agent-sandbox:<version>`.

### `--pull` flag
- [ ] `--pull` forces the launcher to re-pull the image from GHCR regardless of local cache or `AGENT_SANDBOX_IMAGE_PATH`.
- [ ] After pulling, the launcher starts the container as normal.
- [ ] `--help` output documents `--pull`.

### `--prune`
- [ ] `--prune` compares local `agent-sandbox:*` image tags against the launcher's version.
- [ ] `--prune` removes images whose tag does not match the launcher's version.
- [ ] `--prune` prints each removed image and the total space freed.

### Image tag scheme
- [ ] Local images are tagged as `agent-sandbox:<version>` (e.g., `agent-sandbox:0.1.0`).
- [ ] The GHCR registry tag matches: `ghcr.io/mstruble/agent-sandbox:<version>`.

### Self-update interaction
- [ ] After `--update` installs a new launcher version, the next run detects the version mismatch and sources the new image via the appropriate tier.

## Open Questions
- None.

## Out of Scope
- Building images from Nix expressions inside the launcher (the launcher only loads pre-built tarballs or pulls from GHCR).
- Multi-architecture image selection (handled by Docker/Podman multi-arch manifest resolution).
