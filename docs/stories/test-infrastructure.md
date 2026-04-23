# Story: Test Infrastructure

## Source
PRD Capability Group: Testing & Validation — Test Infrastructure
Behaviors covered:
- Tests use bats-core with bats-assert and bats-support as the test framework.
- A Makefile provides `test-unit`, `test-integration`, `test-e2e`, `test` (all), and `test-fast` (unit alias) targets.
- Integration and e2e targets require the container image to be loaded locally (built via `nix build .#container-image` on any supported system, or pulled from GHCR).
- bats-core and helper libraries are provided via a Nix devShell in `flake.nix`.
- Tests are tagged (`unit`, `integration`, `e2e`) to support selective execution via `bats --filter-tags`.
- CI runs all test tiers after the image build step in `pr-checks.yml`.

## Summary
Sets up the foundational test infrastructure: Nix devShell with bats-core and helpers, Makefile targets for running tests by tier, test directory structure, and CI integration. This story is a prerequisite for the launcher-unit-tests, container-integration-tests, and e2e-tests stories.

## Acceptance Criteria

### Nix devShell
- [ ] `flake.nix` defines a `devShells.default` that includes `bats`, `bats-assert`, and `bats-support` (from nixpkgs).
- [ ] `nix develop` drops into a shell where `bats --version` succeeds.
- [ ] The devShell also includes existing dev dependencies (shellcheck, nixfmt, etc.) if not already present.

### Test directory structure
- [ ] `tests/unit/` directory exists for launcher unit tests.
- [ ] `tests/integration/` directory exists for container integration tests.
- [ ] `tests/e2e/` directory exists for end-to-end tests.
- [ ] `tests/fixtures/` directory exists for shared test data (fake agent binary, sample configs).
- [ ] `tests/fixtures/fake-agent` is an executable script that prints a marker string and exits 0.
- [ ] A `tests/test_helper.bash` provides shared setup (bats helper library loading, common variables).

### Makefile
- [ ] `make test-unit` runs `bats --filter-tags unit tests/`.
- [ ] `make test-integration` ensures the container image is loaded locally then runs `bats --filter-tags integration tests/`.
- [ ] `make test-e2e` ensures the container image is loaded locally then runs `bats --filter-tags e2e tests/`.
- [ ] `make test` runs all three tiers sequentially.
- [ ] `make test-fast` is an alias for `test-unit`.
- [ ] Image availability is checked by verifying `agent-sandbox:<version>` exists in the local image store; the Makefile provides an `ensure-image` target that builds and loads the Nix-built image via `nix build .#container-image` (cross-platform, works on both Linux and darwin with a Linux builder configured).

### Launcher refactor
- [ ] `agent-sandbox.sh` wraps its top-level execution in an `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` guard.
- [ ] Key logic is extracted into named functions that can be called independently when the script is sourced.
- [ ] The refactor does not change any observable behavior of the launcher when invoked normally.

### CI integration
- [ ] `pr-checks.yml` runs `make test` (or equivalent) as a step after the container image build.
- [ ] Test failures fail the CI job and block merge.

## Open Questions
- None.

## Out of Scope
- Specific test cases (covered by launcher-unit-tests, container-integration-tests, and e2e-tests stories).
- Test coverage metrics or reporting.
