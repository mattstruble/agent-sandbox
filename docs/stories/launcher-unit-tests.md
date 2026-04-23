# Story: Launcher Unit Tests

## Source
PRD Capability Group: Testing & Validation — Launcher Unit Tests
Behaviors covered:
- Launcher functions are extractable and sourceable in isolation via a `BASH_SOURCE` guard without triggering side effects.
- Argument parsing logic is testable for all flags, invalid inputs, and defaults.
- Config TOML loading is testable for valid config, missing config, partial config, and invalid TOML.
- Container name generation produces deterministic names and handles special characters in paths.
- Image tag computation is testable in isolation (version-based tagging).
- Symlink resolution is testable with filesystem fixtures covering `follow_symlinks`, `follow_all_symlinks`, nested symlinks, broken symlinks, and symlinks into dotfile directories.
- Dotfile directory protection rejects mounts that would expose sensitive directories.
- Extra mount path validation is testable.
- Resource limit parsing is testable.
- Environment variable passthrough assembly is testable.
- Self-update version comparison logic is testable.

## Summary
Bats unit tests that source `agent-sandbox.sh` and exercise individual functions in isolation. These tests run in seconds with no container runtime required, providing fast local feedback. Depends on the launcher refactor from the test-infrastructure story.

## Acceptance Criteria

### Argument parsing
- [ ] `--agent opencode` sets the agent to opencode.
- [ ] `--agent invalid` exits with a non-zero code and an error message.
- [ ] `--no-ssh`, `--follow-symlinks`, `--follow-all-symlinks`, `--pull`, `--list`, `--stop`, `--prune`, `--version` are all recognized.
- [ ] `--follow-all-symlinks` implies `--follow-symlinks`.
- [ ] Unknown flags exit with a non-zero code and an error message.
- [ ] Default values are correct when no flags are passed.

### Config loading
- [ ] A valid `config.toml` is parsed and values are applied.
- [ ] A missing config file results in built-in defaults with no error.
- [ ] A partial config file applies only the specified values; unspecified values retain defaults.
- [ ] An invalid TOML file exits with a non-zero code and an error message.
- [ ] Tests use sample config files from `tests/fixtures/`.

### Container naming
- [ ] The name matches the pattern `agent-sandbox-<agent>-<basename>-<6-char-hash>`.
- [ ] The same absolute path always produces the same name.
- [ ] Different absolute paths produce different names.
- [ ] Workspace basenames are sanitized to `[a-z0-9-]`.
- [ ] Special characters in paths (spaces, unicode) are handled without error.

### Image tag computation
- [ ] The tag matches the launcher's baked-in `@VERSION@` value.
- [ ] The tag is used to check for and pull images from GHCR.

### Symlink resolution
- [ ] `follow_symlinks` resolves depth-1 symlinks in the workspace to their targets.
- [ ] `follow_all_symlinks` includes dotfile directory symlink targets.
- [ ] Nested symlinks (symlink to symlink) are resolved.
- [ ] Broken symlinks are skipped without error.
- [ ] Symlinks pointing into dotfile directories are excluded when `follow_all_symlinks` is not set.
- [ ] Tests create temporary directory trees with symlinks in `setup`.

### Dotfile directory protection
- [ ] Mounts targeting directories like `~/.ssh`, `~/.gnupg`, `~/.aws` are rejected.
- [ ] The rejection produces a clear error message naming the protected directory.

### Extra mount path validation
- [ ] Valid absolute paths are accepted.
- [ ] Non-existent paths produce an error.
- [ ] The `:rw` suffix is parsed correctly for read-write mounts.

### Resource limit parsing
- [ ] Memory values like `8g`, `4096m` are accepted.
- [ ] CPU values like `4`, `2.5` are accepted.
- [ ] Invalid values produce an error.

### Environment variable passthrough
- [ ] Known API key variables present in the environment are included.
- [ ] Missing API key variables are silently skipped.
- [ ] Extra variables from config are included.
- [ ] The assembled list contains no duplicates.

### Self-update version comparison
- [ ] A newer remote version is detected as an available update.
- [ ] An equal version is not flagged as an update.
- [ ] An older remote version is not flagged as an update.

### All tests
- [ ] Every test is tagged with `# bats test_tags=unit`.
- [ ] All tests pass without a container runtime installed.

## Open Questions
- None.

## Out of Scope
- Testing the actual `podman`/`docker` invocation (covered by e2e-tests).
- Testing container image contents (covered by container-integration-tests).
