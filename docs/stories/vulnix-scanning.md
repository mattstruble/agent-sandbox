# Story: Vulnerability Scanning with vulnix

## Source
PRD Capability Group: Continuous Integration
Behaviors covered:
- `vulnix` scans the Nix store closure of the built container image against the NVD for known vulnerabilities on every PR and every push to main.
- Trivy performs a filesystem scan on the repository on every PR and every push to main.

## Summary
Replaces Trivy container image scanning with `vulnix`, a Nix-native vulnerability scanner that understands Nix store closures. Trivy's OS package scanner cannot enumerate packages in Nix-built images (no `/var/lib/dpkg/status`), making it ineffective. `vulnix` scans all derivations in the image's dependency closure against the NVD. Trivy filesystem scanning is retained for non-package concerns (secrets, misconfigurations).

## Acceptance Criteria

### vulnix integration in PR checks
- [ ] The build+scan job in `pr-checks.yml` runs `vulnix` against the Nix store closure of the container image after building it.
- [ ] `vulnix` is available via `nix run nixpkgs#vulnix` or added to the devShell.
- [ ] The job fails if `vulnix` reports vulnerabilities above a configured severity threshold.
- [ ] The `vulnix` scan runs after `nix build .#container-image` so the closure is available in the Nix store.

### vulnix integration in publish workflow
- [ ] The publish workflow (`publish-image.yml`) runs `vulnix` as part of each architecture's build job.
- [ ] A `vulnix` failure prevents the image from being pushed to GHCR.

### Trivy changes
- [ ] The Trivy container image scan (`trivy image`) is removed from `pr-checks.yml` and `publish-image.yml`.
- [ ] The Trivy filesystem scan (`trivy fs`) is retained in both workflows.
- [ ] Trivy filesystem scan continues to fail the job at HIGH and CRITICAL severity thresholds.

### devShell
- [ ] `vulnix` is added to the `devShells.default` packages so developers can run scans locally via `nix develop --command vulnix`.

## Open Questions
- None.

## Out of Scope
- Scanning npm dependencies within claude-code (vulnix scans Nix derivations; npm audit is a separate concern).
- Replacing Trivy filesystem scanning (retained for non-Nix concerns).
- Configuring vulnix whitelists for accepted CVEs (can be added later if needed).
