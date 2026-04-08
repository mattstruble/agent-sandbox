# Story: Custom Nix Derivations for opencode and rtk

## Source
PRD Capability Group: Runtime Package Management
Behaviors covered:
- Custom derivations in the project's Nix expressions provide binaries not available in nixpkgs (opencode, rtk). These derivations use `fetchurl` with per-architecture URLs and SHA256 hashes.

## Summary
Creates `packages/opencode.nix` and `packages/rtk.nix` — custom Nix derivations for the two binaries not available in nixpkgs. Each derivation uses `fetchurl` to download the version-pinned release tarball (with per-architecture URL selection via `stdenv.hostPlatform`), verifies the SHA256 hash, extracts the binary, and installs it. Renovate regex managers track the version strings and hashes for automated updates.

## Acceptance Criteria

### `packages/opencode.nix`
- [ ] The derivation uses `stdenv.mkDerivation` (or `stdenv.mkDerivation` wrapping `fetchurl`).
- [ ] The source URL selects the correct architecture variant based on `stdenv.hostPlatform`: `x64` for `x86_64-linux`, `arm64` for `aarch64-linux`.
- [ ] The SHA256 hash is specified per architecture.
- [ ] The version is a single string at the top of the file, easily matchable by Renovate regex.
- [ ] The derivation extracts the tarball and installs the `opencode` binary to `$out/bin/opencode`.
- [ ] `nix build .#opencode` produces a working binary.

### `packages/rtk.nix`
- [ ] The derivation uses `stdenv.mkDerivation` (or `stdenv.mkDerivation` wrapping `fetchurl`).
- [ ] The source URL selects the correct architecture variant: `x86_64-unknown-linux-gnu` for x86_64, `aarch64-unknown-linux-gnu` for aarch64.
- [ ] The SHA256 hash is specified per architecture.
- [ ] The version is a single string at the top of the file, easily matchable by Renovate regex.
- [ ] The derivation extracts the tarball and installs the `rtk` binary to `$out/bin/rtk`.
- [ ] `RTK_TELEMETRY_DISABLED=1` is set as a passthru environment variable or documented for the container image to set.
- [ ] `nix build .#rtk` produces a working binary.

### Integration with flake.nix
- [ ] `flake.nix` imports both derivations and makes them available as `packages.<system>.opencode` and `packages.<system>.rtk`.
- [ ] Both packages are included in the container image's package set.

### Renovate configuration
- [ ] `renovate.json` includes a regex manager for `packages/opencode.nix` that tracks the version string and SHA256 hashes against the GitHub releases datasource.
- [ ] `renovate.json` includes a regex manager for `packages/rtk.nix` that tracks the version string and SHA256 hashes against the GitHub releases datasource.
- [ ] Version strings in the Nix files include Renovate-compatible comments (e.g., `# renovate: datasource=github-releases depName=...`).

### File organization
- [ ] `packages/` directory exists at the repository root.
- [ ] `packages/opencode.nix` and `packages/rtk.nix` are the only files in this directory (initially).
- [ ] Both files pass `nixfmt` formatting checks.

## Open Questions
- None.

## Out of Scope
- Adding these packages to nixpkgs upstream.
- macOS/darwin variants of these derivations (the container image is Linux-only; the host launcher does not need these binaries).
