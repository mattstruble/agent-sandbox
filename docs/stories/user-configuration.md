# Story: User Configuration Parsing

## Source
PRD Capability Groups: Sandbox Lifecycle, Agent Configuration
Behaviors covered:
- Resource limits are configurable by the user.
- The default agent is configurable.

## Summary
Implements parsing of `~/.config/agent-sandbox/config.toml` using Python3 `tomllib`. The config file is optional — all values have sensible defaults. When present, values are validated before use. The launcher reads the config early in startup and threads values into the appropriate places (container flags, environment variables).

## Acceptance Criteria
- [ ] If `~/.config/agent-sandbox/config.toml` does not exist, the launcher uses all default values and does not error.
- [ ] If the file exists but is malformed (invalid TOML syntax), the launcher exits with a non-zero code and a human-readable error message identifying the parse failure.
- [ ] `[defaults]` section: `agent` is validated against known agents (`opencode`). An unrecognized value causes a non-zero exit with a clear error.
- [ ] `[defaults]` section: if `agent` is not set, defaults to `opencode`.
- [ ] `[env]` section: `extra_vars` is a list of strings naming environment variables to forward. Each entry is validated as a non-empty string matching `^[A-Za-z_][A-Za-z0-9_]*$`. Invalid entries cause a non-zero exit with a clear error.
- [ ] `[env]` section: if `extra_vars` is not set, defaults to an empty list. Only the default allowlist of API keys is forwarded.
- [ ] `[workspace]` section: `follow_symlinks` is a boolean. Defaults to `false`. When `true`, mounts depth-1 symlink targets from the workspace, skipping dotfile directories.
- [ ] `[workspace]` section: `follow_all_symlinks` is a boolean. Defaults to `false`. When `true`, includes dotfile directories (`.ssh`, `.gnupg`, etc.) when following symlinks. These directories are skipped by default because they commonly contain credentials and private keys.
- [ ] `[mounts]` section: `extra_paths` is a list of strings. Each entry is a path (absolute or `~/`-prefixed). Defaults to an empty list.
- [ ] `[mounts]` section: entries may include a `:rw` suffix to request read-write access (e.g., `"~/.kube:rw"`). Entries without a suffix default to read-only.
- [ ] `[mounts]` section: entries that are empty strings or contain only whitespace cause a non-zero exit with a clear error.
- [ ] `[resources]` section: `memory` is a non-empty string (e.g., `"8g"`, `"16g"`). Invalid or empty values cause a non-zero exit. Defaults to `"8g"`.
- [ ] `[resources]` section: `cpus` is a positive integer. Invalid or non-positive values cause a non-zero exit. Defaults to `4`.
- [ ] Unrecognized sections or keys in the config file are silently ignored (forward compatibility).
- [ ] The config file is parsed using Python3 `tomllib` (3.11+), replacing the previous `dasel` dependency. See launcher-portability story for implementation details.

## Open Questions
- None.

## Out of Scope
- Per-project config files (out of scope per PRD).
- Config file generation or migration tooling.
