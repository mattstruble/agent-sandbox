# Story: Image Build and Publishing (amd64; arm64 deferred)

## Source
PRD Capability Group: Distribution > Image Publishing
Behaviors covered:
- Images are published for `linux/amd64`. ARM64 support is deferred until a native ARM runner is available for CI.
- Every push to main builds on an x86_64 runner, pushes an arch-specific image, and creates a manifest tagged with the commit SHA.
- Every semver release publishes a version-tagged image and updates the `:latest` tag.

## Summary
Implements the image publishing pipeline for amd64. An x86_64 CI runner runs `nix build .#container-image`, loads the tarball, pushes the arch-specific tag, then creates a manifest. The release workflow re-tags the manifest with the semver version. ARM64 is deferred until a native ARM runner is available — cross-compiling from x86_64 would produce a mislabeled image.

## Acceptance Criteria

### Publish on main push (`publish-image.yml`)
- [ ] The workflow runs a single build job on `ubuntu-latest` (x86_64).
- [ ] The job runs `nix build .#container-image` to produce the image tarball.
- [ ] The job loads the tarball via `docker load`.
- [ ] The job tags the image as `ghcr.io/mstruble/agent-sandbox:<commit-sha>-amd64`.
- [ ] The job pushes the arch-specific image to GHCR.
- [ ] A manifest job (depends on the build job) creates a manifest via `docker manifest create ghcr.io/mstruble/agent-sandbox:<commit-sha> --amend <sha>-amd64`.
- [ ] The manifest is pushed to GHCR as `ghcr.io/mstruble/agent-sandbox:<commit-sha>`.
- [ ] OCI labels are set: `org.opencontainers.image.source`, `org.opencontainers.image.revision`.

### Release re-tagging (`release.yml`)
- [ ] The release workflow pulls the manifest (not the arch-specific image directly).
- [ ] The manifest is re-tagged as `ghcr.io/mstruble/agent-sandbox:<semver>` and `ghcr.io/mstruble/agent-sandbox:latest`.
- [ ] Both tags are pushed to GHCR.

### PR checks (`pr-checks.yml`)
- [ ] PR checks build the image for the runner's native architecture only (x86_64).
- [ ] The build step uses `nix build .#container-image` and `docker load`.

### Nix build expression
- [ ] The `container-image` output in `flake.nix` produces an image for the current system's architecture (determined by `system` in the flake-parts per-system evaluation).
- [ ] Custom derivations in `packages/` use `stdenv.hostPlatform` to select per-architecture URLs.

## Open Questions
- None.

## Out of Scope
- ARM64 support (deferred until a native ARM runner is available; cross-compilation would produce a mislabeled image).
- Image signing or SBOM attestation.
- Publishing images from PR branches.
