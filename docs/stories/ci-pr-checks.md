# Story: CI Pull Request Checks

## Source
PRD Capability Group: Continuous Integration
Behaviors covered:
- Every pull request to main runs lint checks, builds the container image, scans it for vulnerabilities, and runs the full test suite before merge.
- All test tiers (unit, integration, e2e) run after the container image is built in CI.
- ShellCheck validates all bash scripts (`agent-sandbox.sh`, `entrypoint.sh`, `init-firewall.sh`, `install.sh`).
- `nixfmt` validates Nix formatting; `nix flake check` validates the flake evaluates correctly; `nix build` validates the package builds.
- PR titles are validated against the conventional commit format.
- `vulnix` scans the Nix store closure of the built container image for known vulnerabilities on every PR.
- Trivy performs a filesystem scan on the repository on every PR.
- All CI checks are required to pass before a PR can be merged.
- PRs are merged via squash-merge only.

## Summary
A `pr-checks.yml` workflow runs parallel jobs on every PR to main: lint (ShellCheck, nixfmt, nix flake check, conventional commit PR title), build+scan+test (nix build container image, vulnix closure scan, Trivy filesystem scan, full test suite), and nix build (launcher package). All jobs must pass before merge. Branch protection enforces required checks and squash-merge.

## Acceptance Criteria

### Lint job
- [ ] ShellCheck runs against `agent-sandbox.sh`, `entrypoint.sh`, `init-firewall.sh`, and `install.sh`; the job fails if any script has warnings or errors.
- [ ] `nixfmt --check` runs against all `.nix` files in the repository; fails if not formatted.
- [ ] `nix flake check` runs and fails the job if the flake does not evaluate.
- [ ] PR title is validated against conventional commit format via `amannn/action-semantic-pull-request`; the job fails if the title does not match.

### Build + Scan + Test job
- [ ] The container image is built via `nix build .#container-image`.
- [ ] The image tarball is loaded into the local Docker daemon via `docker load`.
- [ ] `vulnix` scans the Nix store closure of the image for known vulnerabilities; the job fails if vulnerabilities above the configured threshold are found.
- [ ] Trivy runs a filesystem scan against the repository; the job fails if vulnerabilities are found.
- [ ] The image is **not** pushed to any registry during PR checks.
- [ ] `make test` runs after the image is loaded, executing all test tiers (unit, integration, e2e); the job fails if any test fails.

### Nix build job
- [ ] `nix build` runs successfully, verifying the launcher Nix package builds.

### Workflow configuration
- [ ] The workflow triggers on `pull_request` events targeting the `main` branch.
- [ ] All three jobs run in parallel on `ubuntu-latest` runners.
- [ ] Nix is installed via `DeterminateSystems/nix-installer-action`.

### Branch protection
- [ ] The repository requires a pull request before merging to main.
- [ ] All three CI jobs are configured as required status checks.
- [ ] Squash merge is the only allowed merge strategy.
- [ ] Force pushes to main are disabled.

## Open Questions
- None.

## Out of Scope
- Publishing images to GHCR (see multi-arch-image-publishing story).
- Security scanning on pushes to main (see multi-arch-image-publishing story).
- vulnix severity threshold tuning (see vulnix-scanning story).
