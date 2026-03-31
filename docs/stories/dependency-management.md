# Story: Dependency Management

## Source
PRD Capability Group: Dependency Management
Behaviors covered:
- Renovate opens dependency update PRs automatically, grouped by category.
- Container dependencies (base image, gh CLI, rtk, uv, claude-code) are grouped into a single PR.
- Nix flake inputs (`flake.lock`) are grouped into a single PR.
- GitHub Actions versions are grouped into a single PR.
- Dependency versions are pinned but no longer verified via SHA256 checksums; version pinning over TLS is the trust model for all Containerfile dependencies.

## Summary
A `renovate.json` at the repository root configures automated dependency update PRs. Regex managers handle the custom version patterns in the Containerfile (gh, rtk, uv, claude-code). Built-in managers handle the base image, flake.lock, and GitHub Actions. PRs are grouped by category to reduce noise. SHA256 checksums are removed from the Containerfile to enable clean version bumps.

## Acceptance Criteria

### Renovate configuration
- [ ] `renovate.json` exists at the repository root.
- [ ] Renovate is configured with regex managers for each Containerfile dependency:
  - `gh` CLI: matches the version in the curl URL and tarball path (e.g., `v2.89.0`).
  - `rtk`: matches the version in the curl URL and tarball path (e.g., `v0.34.2`).
  - `uv`: matches the image tag and digest in the `COPY --from` directive (e.g., `0.11.2@sha256:...`).
  - `claude-code`: matches the npm version in the `npm install` command (e.g., `2.1.87`).
- [ ] The Dockerfile manager handles `debian:bookworm-slim` base image updates.
- [ ] The nix manager handles `flake.lock` updates via `nix flake update`.
- [ ] The github-actions manager handles action version updates in workflow files.

### Grouping
- [ ] Container dependencies (base image, gh, rtk, uv, claude-code) are grouped into a single PR.
- [ ] Nix flake inputs are grouped into a single PR.
- [ ] GitHub Actions versions are grouped into a single PR.

### Containerfile changes (SHA256 removal)
- [ ] The `gh` CLI install step removes the `sha256sum -c` verification and the hardcoded checksum; the curl download is version-pinned only.
- [ ] The `rtk` install step removes the `sha256sum -c` verification and the hardcoded checksum; the curl download is version-pinned only.
- [ ] The Containerfile comments are updated to reflect the new trust model (version pinning over TLS).

### Renovate PR integration
- [ ] Renovate PRs go through the same `pr-checks.yml` pipeline as human PRs.
- [ ] A failed image build on a Renovate PR indicates a broken dependency update.

## Open Questions
- None.

## Out of Scope
- Auto-merging Renovate PRs (all PRs require human review).
- SHA256 checksum computation in post-update scripts.
