# Story: Agent Configuration and Credentials

## Source
PRD Capability Group: Agent Configuration
Behaviors covered:
- The host agent configs (`~/.config/opencode/` for OpenCode, `~/.claude/` for Claude Code) are available to the agent inside the sandbox.
- Config changes made by the agent during a session do not persist back to the host.
- The host git identity (`~/.gitconfig`) is available to the agent.
- SSH operations use the host's SSH agent via socket forwarding; no private key material enters the container.
- API keys are forwarded from the host environment via an explicit allowlist.
- The sandbox overrides agent tool permissions to fully allow for the duration of the session; the agent never prompts for approval to read, edit, or run commands.
- Permission overrides are applied regardless of what the host agent config specifies.

## Summary
Stages host agent configs from read-only mount points to writable container-local directories at session start, making them available to the agent while keeping host configs unchanged. Forwards git identity, SSH agent socket (opt-out via `--no-ssh`), and a defined set of API keys. Overrides agent tool permissions to fully allow so the agent never prompts during a session.

## Acceptance Criteria

### Config staging
- [ ] If `~/.config/opencode/` exists on the host, it is mounted at `/host-config/opencode/` (read-only). If it does not exist, the mount is skipped and the entrypoint skips the copy step for OpenCode config.
- [ ] If `~/.claude/` exists on the host, it is mounted at `/host-config/claude/` (read-only). If it does not exist, the mount is skipped and the entrypoint skips the copy step for Claude config.
- [ ] `entrypoint.sh` runs in this order: (1) firewall, (2) copy `/host-config/opencode/` to `~/.config/opencode/` and `/host-config/claude/` to `~/.claude/` (skipping any that were not mounted), (3) apply permission overrides, (4) `rtk init`, (5) exec agent.
- [ ] Config changes made inside the container (e.g. by `rtk init`) do not appear in the host's `~/.config/opencode/` or `~/.claude/` after the session ends.
- [ ] `~/.gitconfig` is mounted from the host read-only at `/home/sandbox/.gitconfig`.

### SSH agent forwarding
- [ ] If `SSH_AUTH_SOCK` is set on the host and `--no-ssh` is not passed, the socket is mounted at `/tmp/ssh_auth_sock` and `SSH_AUTH_SOCK=/tmp/ssh_auth_sock` is set in the container environment.
- [ ] If `SSH_AUTH_SOCK` is not set on the host, the launcher prints a warning and starts the container without SSH agent forwarding.
- [ ] If `--no-ssh` is passed, the SSH agent socket is not mounted regardless of whether `SSH_AUTH_SOCK` is set. No warning is printed.
- [ ] No SSH private key files from the host are mounted into the container.

### API key forwarding
- [ ] The following environment variables are forwarded to the container via `-e` flags if present on the host: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `MISTRAL_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `GITHUB_TOKEN`.
- [ ] Additional variables listed in `config.toml` `[env]` `extra_vars` are also forwarded if present on the host.
- [ ] Environment variables not in the default list or `extra_vars` are never forwarded to the container, even if they match patterns like `*_API_KEY`.

### Permission overrides
- [ ] After config staging, the entrypoint uses `jq` to set all permission fields (`bash`, `edit`, `read`, `grep`, `patch`, `webfetch`) to `"allow"` in `~/.config/opencode/config.json` inside the container.
- [ ] If `~/.config/opencode/config.json` does not exist inside the container, the entrypoint creates it with only the permission override fields.
- [ ] If the file exists but has an unexpected structure (e.g., missing keys), the permission fields are added/overwritten without removing other content.
- [ ] Claude Code is invoked with `--dangerously-skip-permissions`.
- [ ] A host `opencode.json` that sets any permission to `"ask"` does not produce prompts inside the sandbox.

## Open Questions
- None.

## Out of Scope
- Persisting config changes back to the host (`--persist-config` is listed as an Open Question in the PRD).
