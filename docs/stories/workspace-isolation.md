# Story: Workspace Isolation

## Source
PRD Capability Group: Workspace Isolation
Behaviors covered:
- Only the target workspace directory is accessible to the agent; the rest of the host filesystem is not mounted.
- Files written by the agent inside the workspace are reflected on the host filesystem immediately.
- The agent's working directory inside the container is the root of the mounted workspace.

## Summary
Ensures the workspace mount is the only host filesystem path accessible inside the container. Symlink target mounting is opt-in via `--follow-symlinks`, with dotfile directories denied by default to prevent accidental exposure of sensitive host paths like `~/.ssh` or `~/.gnupg`.

## Acceptance Criteria
- [ ] The workspace directory is mounted at `/workspace` inside the container with read-write access.
- [ ] The container's working directory is `/workspace`.
- [ ] Files created or modified by the agent inside `/workspace` are immediately visible on the host at the original path.
- [ ] Host paths outside the workspace (e.g. `~/Documents`, `/etc`) are not accessible from inside the container.
- [ ] The `:z` mount option is applied on Linux to handle SELinux labeling.
- [ ] Without `--follow-symlinks`, no symlink targets from the workspace are mounted — symlinks inside the workspace that point outside it are unresolvable in the container.

### Symlink mounting (`--follow-symlinks`)

*Note: CLI flag parsing for `--follow-symlinks` and `--follow-all-symlinks` is implemented in the sandbox-lifecycle story.*
- [ ] When `--follow-symlinks` is passed, the workspace directory is scanned at depth 1 for symlinks that resolve to directories outside the workspace.
- [ ] Each resolved symlink target is mounted read-write at its original absolute path inside the container, so symlinks in `/workspace/` resolve correctly and the agent can modify files in referenced repositories.
- [ ] If a symlink target does not exist on the host, the launcher prints a warning and skips it; the sandbox starts normally.
- [ ] Symlink targets that fall within the workspace directory itself are not added as extra mounts.
- [ ] Duplicate targets (multiple symlinks pointing to the same directory) are mounted only once.

### Dotfile directory protection
- [ ] When `--follow-symlinks` is active, symlink targets whose basename starts with `.` (e.g., `.ssh`, `.gnupg`, `.aws`, `.config`) are skipped with a warning printed to stderr.
- [ ] The warning identifies which symlink was skipped and why (dotfile directory protection).
- [ ] `--follow-all-symlinks` overrides the dotfile protection — all symlink targets are mounted, including dotfile directories.
- [ ] `follow_all_symlinks = true` in `config.toml` `[workspace]` section has the same effect as `--follow-all-symlinks`.
- [ ] `--follow-all-symlinks` implies `--follow-symlinks` (no need to pass both).

## Open Questions
- None.

## Out of Scope
- Recursive symlink scanning beyond depth 1.
- A per-path deny-list beyond the dotfile basename convention.

---

## Addendum: Extra Mounts (`--mount` / `config.toml`)

*Note: The `--mount` CLI flag is parsed in the sandbox-lifecycle story. The `[mounts]` config section is parsed in the user-configuration story.*

### Acceptance Criteria
- [ ] Each entry from `config.toml` `[mounts]` `extra_paths` and each `--mount` CLI argument is processed as an extra mount.
- [ ] Paths starting with `~/` are expanded to the host user's `$HOME`.
- [ ] Each host path is resolved via `realpath` before mounting.
- [ ] Paths relative to `$HOME` are mounted at the corresponding path under `/home/sandbox/` inside the container (e.g., `~/.kube/` on host → `/home/sandbox/.kube/` in container).
- [ ] Absolute paths outside `$HOME` are mounted at the same absolute path inside the container.
- [ ] The default mount mode is read-only (`:ro,z`).
- [ ] Appending `:rw` to a path (e.g., `~/.kube:rw`) mounts it read-write (`:rw,z`).
- [ ] If the host path does not exist, the launcher prints a warning to stderr and skips it; the sandbox starts normally.
- [ ] CLI `--mount` entries are merged with `config.toml` `extra_paths` entries. Duplicates (same resolved host path) are mounted only once.
- [ ] The `:z` SELinux mount option is applied on Linux.
- [ ] No restrictions or deny-lists are applied to extra mount paths — the user is explicitly choosing what to expose.
