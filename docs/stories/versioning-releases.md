# Story: Versioning & Releases

## Source
PRD Capability Group: Versioning & Releases
Behaviors covered:
- Versioning follows semver and is automated via Release Please based on conventional commits.
- When conventional commits land on main, Release Please opens (or updates) a PR that bumps the version and generates a changelog.
- Merging the release PR creates a GitHub Release with a semver tag.
- The version source of truth is `flake.nix`; Release Please bumps it there.
- The launcher supports `--version` (or `-v`) which prints the version and exits.
- `agent-sandbox --version` prints the current version and exits.

## Summary
Release Please watches main for conventional commits and opens a release PR that bumps the version in `flake.nix` and generates a `CHANGELOG.md`. Merging that PR creates a GitHub Release with a semver tag. The launcher gains a `--version` / `-v` flag that prints the version via a `@VERSION@` placeholder substituted at Nix build time.

## Acceptance Criteria

### Release Please (`release-please.yml`)
- [ ] The workflow triggers on `push` events to the `main` branch.
- [ ] Uses `googleapis/release-please-action` configured for "simple" release type.
- [ ] `extra-files` is configured to locate and bump the version string in `flake.nix`.
- [ ] When conventional commits exist on main since the last release, Release Please opens a PR that bumps the version and includes a generated changelog.
- [ ] If a release PR already exists, it is updated with new commits.
- [ ] When the release PR is merged, a GitHub Release is created with a semver tag (e.g., `v1.2.0`).

### Version in flake.nix
- [ ] The version source of truth is the `version` field in `flake.nix` (currently `"0.1.0"`).
- [ ] Release Please correctly identifies and bumps the version string in `flake.nix`.

### Launcher `--version` flag
- [ ] `agent-sandbox.sh` contains a `@VERSION@` placeholder.
- [ ] The Nix `installPhase` in `flake.nix` substitutes `@VERSION@` with the `version` value from the derivation.
- [ ] `agent-sandbox --version` prints `agent-sandbox <version>` and exits 0.
- [ ] `agent-sandbox -v` is an alias for `--version`.
- [ ] `--version` is documented in the `--help` output.

## Open Questions
- None.

## Out of Scope
- Pre-release versions or release channels.
- Automatic `nix flake update` on release.
