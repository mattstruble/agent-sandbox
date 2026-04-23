# Story: rtk Integration

## Source
PRD Capability Group: Token Savings
Behaviors covered:
- `rtk` is pre-installed and configured for the active agent at the start of every session, with no user setup required.
- Shell commands (git, cargo, cat, ls, grep, and others) are transparently rewritten to `rtk` equivalents inside the container, reducing token consumption by 60–90%.

## Summary
Installs the `rtk` binary in the container image and runs `rtk init` for the active agent during `entrypoint.sh` before the agent starts. Because agent config directories are staged to writable locations first, `rtk init` can write its hooks/plugins at container-local paths.

## Acceptance Criteria
- [ ] The `rtk` binary is installed to the Nix store and available on PATH in the container image.
- [ ] For OpenCode sessions, `entrypoint.sh` runs `rtk init -g --opencode` after staging config dirs and before starting the agent.
- [ ] `rtk init` runs after config staging and after `init-firewall.sh` (rtk init is a local operation requiring no outbound network). The entrypoint ordering (firewall, chronyd, su-exec drop, config staging, Nix instructions, permission overrides, rtk init, agent) is defined in DESIGN.md.
- [ ] After `rtk init`, the OpenCode plugin file exists at `~/.config/opencode/plugins/rtk.ts` inside the container.
- [ ] Shell commands issued by the agent (e.g. `git status`, `cargo test`, `cat`) are transparently rewritten to `rtk` equivalents without the agent's knowledge.

## Open Questions
- `rtk gain` stats are ephemeral per session (per PRD Open Questions). This is acceptable for now.

## Out of Scope
- Persisting `rtk` token savings history across sessions.
- Allowing the user to disable rtk per session.
