# Story: End-to-End Tests

## Source
PRD Capability Group: Testing & Validation — End-to-End Tests
Behaviors covered:
- Invoking `agent-sandbox.sh` with a temporary workspace directory starts a container and the fake agent runs to completion.
- The workspace is mounted correctly at `/workspace` inside the container.
- The container name matches the expected deterministic pattern.
- The container is cleaned up after the agent exits.

## Summary
Bats end-to-end tests that invoke `agent-sandbox.sh` directly with a real temporary workspace, exercising the full launcher-to-container lifecycle. A fake agent binary is mounted over the real agent binary. These tests catch wiring bugs between the launcher and the container that unit and integration tests miss. Requires a container runtime.

## Acceptance Criteria

### Full lifecycle
- [ ] Invoking `agent-sandbox.sh` with a temporary workspace directory starts a container successfully.
- [ ] The fake agent binary (mounted over the real one) runs to completion and produces its expected marker output.
- [ ] The container is removed automatically after the agent exits (consistent with `--rm` behavior).

### Workspace mounting
- [ ] The temporary workspace is mounted at `/workspace` inside the container.
- [ ] A file created in the temporary workspace before launch is visible inside the container.
- [ ] A file created inside the container at `/workspace` is reflected on the host filesystem.

### Symlink mount accessibility
- [ ] When `--follow-symlinks` is used, symlinked directories in the workspace are accessible inside the container with readable contents (not broken symlink paths).
- [ ] A file inside a symlink target directory is readable from within the container (verifying the target is mounted, not just the symlink).
- [ ] When `--follow-all-symlinks` is used, symlinked dotfile directories are also accessible with readable contents inside the container.

### Container naming
- [ ] The running container's name matches the expected deterministic pattern `agent-sandbox-<agent>-<basename>-<6-char-hash>`.

### Launcher integration
- [ ] The launcher's container runtime detection runs naturally (no override) and selects an available runtime.
- [ ] The launcher builds the container image automatically if not already cached.

### Test mechanics
- [ ] Every test is tagged with `# bats test_tags=e2e`.
- [ ] Tests create a unique temporary workspace directory in `setup` and clean it up in `teardown`.
- [ ] Tests remove any leftover containers in `teardown`, even on failure.
- [ ] Tests provide minimal git config fixtures so the launcher's config staging succeeds.

## Open Questions
- None.

## Out of Scope
- Testing individual launcher functions (covered by launcher-unit-tests).
- Testing container image contents or firewall rules (covered by container-integration-tests).
- Testing with real LLM API keys or actual agent conversations.
