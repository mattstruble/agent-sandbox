# Story: Multi-Arch Image Build and Publishing

## Source
PRD Capability Group: Distribution > Image Publishing
Behaviors covered:
- Images are published for both `linux/amd64` and `linux/arm64` architectures as a multi-arch manifest.
- Every push to main builds on two native runners (x86_64 and aarch64), pushes arch-specific images, and creates a multi-arch manifest tagged with the commit SHA.
- Every semver release publishes a version-tagged multi-arch image and updates the `:latest` tag.

## Summary
Extends the image publishing pipeline to produce multi-architecture images. Two native CI runners (x86_64 and aarch64) each run `nix build .#container-image`, load the tarball, push arch-specific tags, then a final job creates and pushes a multi-arch manifest. The release workflow re-tags the multi-arch manifest with the semver version. ARM Mac users get native container images instead of x86_64 emulation.

## Acceptance Criteria

### Publish on main push (`publish-image.yml`)
- [ ] The workflow runs two parallel build jobs: one on `ubuntu-latest` (x86_64) and one on an ARM runner (aarch64).
- [ ] Each job runs `nix build .#container-image` to produce the image tarball.
- [ ] Each job loads the tarball via `docker load`.
- [ ] Each job tags the image as `ghcr.io/mstruble/agent-sandbox:<commit-sha>-<arch>` (e.g., `-amd64`, `-arm64`).
- [ ] Each job pushes the arch-specific image to GHCR.
- [ ] A third job (depends on both build jobs) creates a multi-arch manifest via `docker manifest create ghcr.io/mstruble/agent-sandbox:<commit-sha> --amend <sha>-amd64 --amend <sha>-arm64`.
- [ ] The multi-arch manifest is pushed to GHCR as `ghcr.io/mstruble/agent-sandbox:<commit-sha>`.
- [ ] OCI labels are set: `org.opencontainers.image.source`, `org.opencontainers.image.revision`.

### Release re-tagging (`release.yml`)
- [ ] The release workflow pulls the multi-arch manifest (not individual arch images).
- [ ] The manifest is re-tagged as `ghcr.io/mstruble/agent-sandbox:<semver>` and `ghcr.io/mstruble/agent-sandbox:latest`.
- [ ] Both tags are pushed to GHCR as multi-arch manifests.
- [ ] `docker pull ghcr.io/mstruble/agent-sandbox:<semver>` on an ARM host pulls the arm64 image; on x86_64 it pulls the amd64 image.

### PR checks (`pr-checks.yml`)
- [ ] PR checks build the image for the runner's native architecture only (x86_64) — multi-arch is not required for PR validation.
- [ ] The build step uses `nix build .#container-image` and `docker load`.

### Nix build expression
- [ ] The `container-image` output in `flake.nix` produces an image for the current system's architecture (determined by `system` in the flake-parts per-system evaluation).
- [ ] Custom derivations in `packages/` use `stdenv.hostPlatform` to select per-architecture URLs.

## Open Questions
- None.

## Out of Scope
- Cross-compilation of images (each architecture is built natively on its own runner).
- Image signing or SBOM attestation.
- Publishing images from PR branches.
