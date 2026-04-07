# Story: Dependency Management

## Source
PRD Capability Group: Dependency Management
Behaviors covered:
- Renovate opens dependency update PRs automatically, grouped by category.
- Most container dependencies are managed through the `flake.lock` nixpkgs pin.
- Custom Nix derivations for opencode and rtk have version strings and SHA256 hashes tracked by Renovate regex managers.
- The claude-code npm version is tracked by a Renovate regex manager.
- Nix flake inputs (`flake.lock`) are grouped into a single PR.
- GitHub Actions versions are grouped into a single PR.

## Summary
A `renovate.json` at the repository root configures automated dependency update PRs. The `flake.lock` update handles most package versions (everything from nixpkgs). Regex managers target the custom Nix derivation files in `packages/` for opencode and rtk version+hash bumps, and the claude-code npm version in the container image expression. PRs are grouped by category to reduce noise.

## Acceptance Criteria

### Renovate configuration
- [ ] `renovate.json` exists at the repository root.
- [ ] The nix manager handles `flake.lock` updates via `nix flake update`.
- [ ] Renovate is configured with regex managers for custom derivation dependencies:
  - `opencode`: matches the version string and SHA256 hashes in `packages/opencode.nix` against the `github-releases` datasource for `anomalyco/opencode`.
  - `rtk`: matches the version string and SHA256 hashes in `packages/rtk.nix` against the `github-releases` datasource for `rtk-ai/rtk`.
  - `claude-code`: matches the npm version string in the container image Nix expression against the `npm` datasource.
- [ ] The github-actions manager handles action version updates in workflow files.

### Grouping
- [ ] Nix flake inputs (`flake.lock`) are grouped into a single PR.
- [ ] Custom derivation dependencies (opencode, rtk, claude-code) are grouped into a single PR.
- [ ] GitHub Actions versions are grouped into a single PR.

### Renovate-compatible comments
- [ ] `packages/opencode.nix` contains Renovate-compatible comments (e.g., `# renovate: datasource=github-releases depName=anomalyco/opencode`) near the version string.
- [ ] `packages/rtk.nix` contains Renovate-compatible comments near the version string.
- [ ] The claude-code version string has a Renovate-compatible comment.

### Renovate PR integration
- [ ] Renovate PRs go through the same `pr-checks.yml` pipeline as human PRs.
- [ ] A failed image build on a Renovate PR indicates a broken dependency update.

## Open Questions
- None.

## Out of Scope
- Auto-merging Renovate PRs (all PRs require human review).
- Renovate configuration for Dockerfile-based dependencies (Containerfile no longer exists).
