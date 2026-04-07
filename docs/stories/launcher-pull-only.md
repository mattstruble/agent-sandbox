# Story: Launcher Pull-Only Image Management

## Source
PRD Capability Group: Image Management
Behaviors covered:
- The image is pulled from GHCR on first use when no matching local image exists. The launcher does not build images locally.
- The image tag matches the launcher's baked-in version.
- `--pull` forces a re-pull of the image from GHCR regardless of local cache state.
- `--prune` removes locally cached images whose tag does not match the launcher's version.

## Summary
Replaces the launcher's local image build logic with a pull-from-GHCR model. The launcher checks for `agent-sandbox:<version>` locally and pulls `ghcr.io/mstruble/agent-sandbox:<version>` if absent. The `--build` flag is replaced with `--pull` (force re-pull). `compute_containerfile_hash()` and `build_image()` are removed. `--prune` compares image tags against the launcher's version instead of a Containerfile hash.

## Acceptance Criteria

### Image pulling
- [ ] On startup, if no `agent-sandbox:<version>` image exists locally, the launcher pulls `ghcr.io/mstruble/agent-sandbox:<version>` from GHCR.
- [ ] The version is the `@VERSION@` value baked into the launcher at build/install time.
- [ ] The launcher prints a message when pulling (e.g., `Pulling image ghcr.io/mstruble/agent-sandbox:<version>...`).
- [ ] If the pull fails (network error, image not found), the launcher exits with a clear error message.
- [ ] If the image already exists locally, the launcher starts immediately without pulling.

### `--pull` flag (replaces `--build`)
- [ ] `--pull` forces the launcher to re-pull the image from GHCR regardless of local cache.
- [ ] After pulling, the launcher starts the container as normal.
- [ ] The `--build` flag is removed from the launcher.
- [ ] `--help` output documents `--pull` and does not mention `--build`.

### `--prune` changes
- [ ] `--prune` compares local `agent-sandbox:*` image tags against the launcher's version.
- [ ] `--prune` removes images whose tag does not match the launcher's version.
- [ ] `--prune` prints each removed image and the total space freed.
- [ ] `--prune` does not require a Containerfile to be present.

### Removed code
- [ ] `compute_containerfile_hash()` function is removed.
- [ ] `build_image()` function is removed.
- [ ] The `CONTAINERFILE` variable and Containerfile path resolution are removed.
- [ ] The Nix package no longer installs a Containerfile to `$out/share/agent-sandbox/`.

### Image tag scheme
- [ ] Local images are tagged as `agent-sandbox:<version>` (e.g., `agent-sandbox:1.2.3`).
- [ ] The GHCR registry tag matches: `ghcr.io/mstruble/agent-sandbox:<version>`.

### Self-update interaction
- [ ] After `--update` installs a new launcher version, the next run detects the version mismatch and pulls the new image automatically.

## Open Questions
- None.

## Out of Scope
- Building images locally from Nix expressions (Nix users can do `nix build .#container-image` independently).
- Multi-architecture image selection (handled by Docker/Podman multi-arch manifest resolution).
