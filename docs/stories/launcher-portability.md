# Story: Launcher Portability

## Source
PRD Capability Group: Distribution > Launcher Portability
Behaviors covered:
- The launcher is compatible with bash 3.2+ and does not require GNU coreutils, GNU sed, GNU grep, or dasel on the host.
- Config file parsing (`~/.config/agent-sandbox/config.toml`) uses Python3 `tomllib` (3.11+). Python3 is only required when the config file exists; users without a config file have no Python3 dependency.
- Symlink resolution uses `realpath` with a Python3 fallback, replacing the GNU `readlink -f` dependency.

## Summary
Makes the launcher script portable across macOS (bash 3.2, BSD userland) and Linux (bash 4+/5.x, GNU userland) without requiring external tools beyond a container runtime. Replaces three bash 4+ features with POSIX-compatible equivalents, replaces `dasel` TOML parsing with a Python3 `tomllib` helper, and replaces `readlink -f` with a portable resolution chain. The Nix build path continues to wrap the launcher with GNU tools but no longer requires them.

## Acceptance Criteria

### Bash 3.2 compatibility
- [ ] `declare -A` (associative arrays) at lines 574 and 634 are replaced with a POSIX-compatible deduplication approach (e.g., newline-delimited string checked with `case` or `grep -Fx`).
- [ ] `${name,,}` (case folding) at line 355 is replaced with `printf '%s' "$name" | tr '[:upper:]' '[:lower:]'` or equivalent.
- [ ] The `BASH_VERSINFO` check at line 7 is removed or lowered to document the new minimum (3.2).
- [ ] The launcher runs without error on macOS system bash (3.2) and Linux bash 5.x.

### TOML config parsing via Python3
- [ ] All 15 `dasel` invocations in `parse_config()` (lines 178–263) are replaced with a single Python3 helper that reads the TOML file and outputs structured data consumable by bash.
- [ ] The Python3 helper uses `tomllib` (stdlib in 3.11+).
- [ ] When `~/.config/agent-sandbox/config.toml` does not exist, Python3 is never invoked.
- [ ] When `config.toml` exists but Python3 is not available or is below 3.11, the launcher exits with a clear error message naming the dependency.
- [ ] All existing config validation (domain regex, variable name regex, cpus integer check) is preserved.
- [ ] The `dasel` availability check at line 183 is removed.

### Portable symlink resolution
- [ ] `readlink -f` (line 583) is replaced with a function that tries `realpath` first, then falls back to `python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))"`.
- [ ] The existing guard at line 569–571 is updated to reflect the new resolution chain instead of dying on missing `readlink -f`.
- [ ] Symlink resolution produces the same results as GNU `readlink -f` for both absolute and relative symlinks.

### Nix wrapper cleanup
- [ ] `dasel` is removed from the Nix `runtimeDeps` in `flake.nix`.
- [ ] `jq` is removed from the Nix `runtimeDeps` in `flake.nix` (unused by the launcher).
- [ ] `gnused` and `gnugrep` are evaluated for removal; remove if the launcher has no GNU-specific sed/grep usage remaining.
- [ ] The Nix-wrapped launcher continues to function identically after dep removal.

## Open Questions
- None.

## Out of Scope
- Replacing the TOML config format itself (stays TOML).
- Supporting Python < 3.11 for config parsing (tomllib is 3.11+ only).
- Changing config file semantics or adding new config options.
