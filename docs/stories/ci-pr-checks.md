# Story: CI Pull Request Checks

## Source
PRD Capability Group: Continuous Integration
Behaviors covered:
- Every pull request to main runs lint checks, builds the container image, and scans it for vulnerabilities before merge.
- ShellCheck validates all bash scripts (`agent-sandbox.sh`, `entrypoint.sh`, `init-firewall.sh`).
- `nixfmt` validates Nix formatting; `nix flake check` validates the flake evaluates correctly; `nix build` validates the package builds.
- PR titles are validated against the conventional commit format.
- Trivy scans the built container image for HIGH and CRITICAL vulnerabilities on every PR.
- Trivy performs a filesystem scan on the repository on every PR.
- All CI checks are required to pass before a PR can be merged.
- PRs are merged via squash-merge only.

## Summary
A `pr-checks.yml` workflow runs three parallel jobs on every PR to main: lint (ShellCheck, nixfmt, nix flake check, conventional commit PR title), build+scan (docker build + Trivy container and filesystem scans), and nix build. All jobs must pass before merge. Branch protection enforces required checks and squash-merge.

## Acceptance Criteria

### Lint job
- [ ] ShellCheck runs against `agent-sandbox.sh`, `entrypoint.sh`, and `init-firewall.sh`; the job fails if any script has warnings or errors.
- [ ] `nixfmt --check flake.nix` runs and fails the job if the file is not formatted.
- [ ] `nix flake check` runs and fails the job if the flake does not evaluate.
- [ ] PR title is validated against conventional commit format via `amannn/action-semantic-pull-request`; the job fails if the title does not match.

### Build + Scan job
- [ ] The container image is built from the `Containerfile` using `docker build`.
- [ ] Trivy runs a container scan against the built image at HIGH and CRITICAL severity thresholds; the job fails if vulnerabilities are found.
- [ ] Trivy runs a filesystem scan against the repository; the job fails if vulnerabilities are found.
- [ ] The image is **not** pushed to any registry during PR checks.

### Nix build job
- [ ] `nix build` runs successfully, verifying the Nix package builds.

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
- Publishing images to GHCR (see image-publishing story).
- Security scanning on pushes to main (see image-publishing story).
