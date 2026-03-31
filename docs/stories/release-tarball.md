# Story: Release Tarball Publishing

## Source
PRD Capability Group: Versioning & Releases
Behaviors covered:
- Each GitHub Release includes a platform-independent tarball (`agent-sandbox-<semver>.tar.gz`) containing the launcher (with version and share-dir substituted for the non-Nix install path) and support files.

## Summary
Extends the `release.yml` workflow to produce a platform-independent tarball as a GitHub Release asset. The tarball contains the launcher script with `@VERSION@` and `@SHARE_DIR@` substituted for the non-Nix install path (`~/.local/share/agent-sandbox`), plus the support files. This tarball is what `install.sh` and `--update` download.

## Acceptance Criteria

### Tarball contents
- [ ] The tarball is named `agent-sandbox-${VERSION}.tar.gz` where `${VERSION}` is the semver release version (without `v` prefix).
- [ ] The tarball contains a top-level directory `agent-sandbox-${VERSION}/` with the following structure:
  ```
  agent-sandbox-${VERSION}/
    bin/agent-sandbox
    share/agent-sandbox/Containerfile
    share/agent-sandbox/entrypoint.sh
    share/agent-sandbox/init-firewall.sh
  ```
- [ ] `@VERSION@` in the launcher is substituted with the release semver version.
- [ ] `@SHARE_DIR@` in the launcher is substituted with `~/.local/share/agent-sandbox` (the literal string with tilde, not expanded).
- [ ] `bin/agent-sandbox` has executable permissions in the tarball.
- [ ] Support files are identical to the source files at the release tag (no modification).

### Workflow integration
- [ ] The tarball is built as a new job in `release.yml`, triggered alongside the existing image re-tagging job.
- [ ] The tarball is uploaded as a release asset to the GitHub Release via `gh release upload`.
- [ ] The substitution uses `sed` on the checked-out source — no Nix tooling is required for this job.
- [ ] The workflow runs on `ubuntu-latest`.

### Verification
- [ ] The tarball is downloadable at `https://github.com/mstruble/agent-sandbox/releases/download/v${VERSION}/agent-sandbox-${VERSION}.tar.gz`.
- [ ] Extracting the tarball and running `bin/agent-sandbox --version` prints the correct version.

## Open Questions
- None.

## Out of Scope
- Per-platform tarballs (the tarball is architecture-independent bash scripts).
- Signing or checksum files for the tarball.
- Nix-specific packaging of the tarball contents (Nix builds from source via the flake).
