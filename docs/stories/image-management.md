# Story: Container Image Management

## Source
PRD Capability Group: Image Management
Behaviors covered:
- The container image is built automatically on first use with no manual step required.
- The image is cached locally and reused on subsequent runs.
- When the Containerfile changes, the next run detects the change and rebuilds automatically.
- `--build` forces an immediate rebuild regardless of cache state.

## Summary
The launcher computes a SHA256 hash of the Containerfile at startup and uses it as the image tag. If no image with that tag exists locally, it builds automatically. This makes cache invalidation deterministic and transparent. `--prune` removes stale images.

## Acceptance Criteria

### Auto-build and caching
- [ ] On first run, if no `agent-sandbox:<hash>` image exists locally, the launcher builds the image before starting the container.
- [ ] The image tag is derived from the SHA256 hash of the Containerfile contents: `agent-sandbox:<sha256>`.
- [ ] On subsequent runs with the same Containerfile, the launcher skips the build and starts immediately.
- [ ] If the Containerfile is modified, the next run computes a different hash, finds no matching image, and rebuilds automatically.
- [ ] `--build` forces a rebuild regardless of whether a matching image exists, then starts the container.
- [ ] The launcher prints a progress message when a build is starting (e.g. `Building image agent-sandbox:<hash>...`).
- [ ] The Nix package installs the Containerfile to `$out/share/agent-sandbox/Containerfile`; the launcher resolves it via the substituted `@SHARE_DIR@` path.

### Image pruning (`--prune`)

*Note: The `--prune` flag is parsed and dispatched in the sandbox-lifecycle story.*
- [ ] `--prune` lists all local images matching `agent-sandbox:*`.
- [ ] `--prune` removes all `agent-sandbox:*` images whose tag does not match the current Containerfile hash.
- [ ] `--prune` prints the name of each image removed.
- [ ] `--prune` prints the total number of images removed and disk space freed.
- [ ] If no stale images exist, `--prune` prints a message indicating nothing to clean and exits 0.
- [ ] `--prune` does not start a container — it exits after cleanup.

## Open Questions
- None.

## Out of Scope
- Automatic pruning on every run (pruning is manual via `--prune`).
- Multi-architecture image builds (amd64 only).
