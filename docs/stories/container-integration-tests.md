# Story: Container Integration Tests

## Source
PRD Capability Group: Testing & Validation — Container Integration Tests
Behaviors covered:
- Expected binaries (`opencode`, `claude`, `rtk`, `gh`, `uv`, `node`, `git`, `nix`) exist and are executable inside the built image.
- The `sandbox` user exists with UID 1000 and correct permissions.
- Firewall allows outbound TCP 80 and 443.
- Firewall blocks non-allowed ports (e.g., 8080, 3000).
- DNS resolution works through the pinned resolver.
- IPv6 is disabled.
- The entrypoint drops to the `sandbox` user via `su-exec` after the root setup phase.
- Staged host configs (git config, SSH socket, API keys) land at expected paths inside the container and are readable by the `sandbox` user.
- A fake agent binary mounted over the real agent binary is executed by the entrypoint without production code changes.

## Summary
Bats integration tests that drive `podman run` / `docker run` against the Nix-built container image from outside. Tests validate image contents, firewall behavior, entrypoint logic, and config staging. A fake agent binary is mounted over the real agent binary to avoid LLM API dependencies. Requires a container runtime and the image loaded locally (via `nix build .#container-image` + `docker load` or pulled from GHCR).

## Acceptance Criteria

### Image contents
- [ ] `opencode` binary exists and is executable (`which opencode` succeeds).
- [ ] `claude` binary exists and is executable (`which claude` succeeds).
- [ ] `rtk` binary exists and is executable (`which rtk` succeeds).
- [ ] `gh` binary exists and is executable (`which gh` succeeds).
- [ ] `uv` binary exists and is executable (`which uv` succeeds).
- [ ] `node` binary exists and is executable (`which node` succeeds).
- [ ] `git` binary exists and is executable (`which git` succeeds).
- [ ] `nix` binary exists and is executable (`which nix` succeeds).
- [ ] `su-exec` binary exists and is executable.

### User setup
- [ ] User `sandbox` exists with UID 1000.
- [ ] The `sandbox` user's home directory exists and is writable by the user.

### Static entrypoint files
- [ ] `/etc/agent-sandbox/nix-instructions.md` exists and is readable.
- [ ] `/etc/agent-sandbox/opencode-permissions.json` exists and is readable.

### Firewall rules
- [ ] Outbound TCP 80 (HTTP) succeeds from inside the container.
- [ ] Outbound TCP 443 (HTTPS) succeeds from inside the container.
- [ ] Outbound UDP 123 (NTP) to pinned Cloudflare IPs succeeds from inside the container.
- [ ] Outbound UDP 123 (NTP) to non-pinned IPs is rejected.
- [ ] Outbound TCP on a non-allowed port (e.g., 8080) is rejected.
- [ ] DNS resolution succeeds (e.g., resolving a public hostname).
- [ ] IPv6 is disabled (e.g., `cat /proc/sys/net/ipv6/conf/all/disable_ipv6` returns `1`).
- [ ] Firewall tests run the container with `--cap-add NET_ADMIN --cap-add NET_RAW` matching production flags.

### Entrypoint behavior
- [ ] After the entrypoint completes setup, the process runs as the `sandbox` user (not root).
- [ ] The entrypoint uses `su-exec` (not `gosu`) for privilege dropping.
- [ ] The entrypoint executes the fake agent binary (mounted over the real one) and the fake agent's marker output is captured.

### Config staging
- [ ] A git config file mounted at the staging path is readable inside the container at the expected target path.
- [ ] Environment variables passed via `-e` are visible to the agent process.
- [ ] Staged configs are not writable by the `sandbox` user (read-only mount verification).

### Test mechanics
- [ ] Every test is tagged with `# bats test_tags=integration`.
- [ ] Tests require the image to be loaded locally (via `nix build .#container-image` + `docker load` or Makefile target).
- [ ] Tests use `teardown` to remove any containers created during the test, even on failure.
- [ ] Tests use the container runtime detected on the host (podman or docker), matching the launcher's detection logic.

## Open Questions
- None.

## Out of Scope
- Testing launcher argument parsing or config loading (covered by launcher-unit-tests).
- Testing full launcher-to-container wiring (covered by e2e-tests).
- Testing with real LLM API keys or actual agent conversations.
