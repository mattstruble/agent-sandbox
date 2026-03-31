# Story: GHCR Image Publishing

## Source
PRD Capability Group: Distribution, Continuous Integration
Behaviors covered:
- The container image is published to GHCR at `ghcr.io/mstruble/agent-sandbox`.
- Every push to main publishes a SHA-tagged image (`ghcr.io/mstruble/agent-sandbox:<commit-sha>`).
- Every semver release publishes a version-tagged image (`ghcr.io/mstruble/agent-sandbox:<semver>`) and updates the `:latest` tag.
- Trivy scans the built container image for HIGH and CRITICAL vulnerabilities on every push to main.
- Trivy performs a filesystem scan on the repository on every push to main.

## Summary
Two workflows handle image publishing. `publish-image.yml` builds and pushes a SHA-tagged image to GHCR on every push to main, then runs Trivy scans. `release.yml` triggers when Release Please creates a GitHub Release — it pulls the existing SHA-tagged image and re-tags it with the semver version and `latest`, avoiding a rebuild.

## Acceptance Criteria

### Publish on main push (`publish-image.yml`)
- [ ] The workflow triggers on `push` events to the `main` branch.
- [ ] The image is built from the `Containerfile` using `docker build`.
- [ ] The image is tagged as `ghcr.io/mstruble/agent-sandbox:<full-commit-sha>`.
- [ ] The image is pushed to GHCR using `docker/login-action` authenticated via `GITHUB_TOKEN`.
- [ ] OCI labels are set on the image: `org.opencontainers.image.version`, `org.opencontainers.image.source`, `org.opencontainers.image.revision`.
- [ ] Trivy runs a container scan against the pushed image at HIGH and CRITICAL severity thresholds.
- [ ] Trivy runs a filesystem scan against the repository.

### Release re-tagging (`release.yml`)
- [ ] The workflow triggers when a GitHub Release is created (by Release Please).
- [ ] The workflow reads the semver version from the release tag.
- [ ] The workflow pulls the SHA-tagged image that was published by `publish-image.yml` on the merge commit.
- [ ] The image is re-tagged as `ghcr.io/mstruble/agent-sandbox:<semver>` (e.g., `1.2.3`).
- [ ] The image is re-tagged as `ghcr.io/mstruble/agent-sandbox:latest`.
- [ ] Both tags are pushed to GHCR.
- [ ] The release image is byte-identical to the SHA-tagged image (no rebuild).

### Image architecture
- [ ] Images are built for `linux/amd64` only.

## Open Questions
- None.

## Out of Scope
- Multi-architecture image builds (arm64).
- Publishing images from PR branches.
- Image signing or SBOM attestation.
