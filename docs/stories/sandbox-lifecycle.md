# Story: Sandbox Lifecycle

## Source
PRD Capability Group: Sandbox Lifecycle
Behaviors covered:
- Running `agent-sandbox` from a directory starts a sandboxed session with that directory as the workspace.
- An explicit workspace path may be passed as an argument; if omitted, the current directory is used.
- The active agent defaults to OpenCode; no other agents are supported in the current release.
- Each session is identified by a name derived deterministically from the agent and the absolute workspace path — starting the same session twice does not create duplicate containers.
- `--list` displays all currently running agent-sandbox containers.
- `--stop` terminates sandbox(es) for the current (or specified) workspace.
- The container is removed automatically when the agent exits.

## Summary
Implements the core launcher CLI: argument parsing, container naming, start/stop/list operations, session deduplication, and new flags (`--no-ssh`, `--follow-symlinks`, `--follow-all-symlinks`, `--prune`). The launcher is the only user-facing interface; all other behaviors flow through it.

## Acceptance Criteria

### Core lifecycle
- [ ] `agent-sandbox` with no arguments starts a container using `$PWD` as the workspace and opencode as the agent.
- [ ] `agent-sandbox ~/projects/foo` starts a container with `~/projects/foo` as the workspace.
- [ ] If the workspace path does not exist, the launcher exits with a non-zero code and a human-readable error before starting any container.
- [ ] Container names match the pattern `agent-sandbox-<agent>-<workspace-basename>-<6-char-hash>` where the hash is derived from the absolute workspace path.
- [ ] Running the same command twice from the same directory does not start a second container (the existing container is reused or the launcher detects it is already running).
- [ ] The container is started with `--rm` so it is removed automatically when the agent process exits.
- [ ] The workspace path is resolved to an absolute path via `realpath` before being used in the container name or mount spec.
- [ ] The workspace basename is sanitized to `[a-z0-9-]` (lowercased, non-matching characters stripped) before being used in the container name.

### List and stop
- [ ] `agent-sandbox --list` prints the names and workspace paths of all running `agent-sandbox-*` containers.
- [ ] `agent-sandbox --stop` stops all `agent-sandbox-*` containers for the current workspace.
- [ ] `agent-sandbox --stop ~/projects/foo` stops all containers for that explicit path.
- [ ] If no container is running for the targeted workspace (and agent, if specified), `--stop` exits 0 silently.

### Security flags
- [ ] The container is started with `--cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW`.
- [ ] The container is started with `--security-opt=no-new-privileges`.
- [ ] The container is started with `--memory` and `--cpus` values read from `config.toml [resources]`, defaulting to `8g` and `4` respectively.

### New CLI flags
- [ ] `--no-ssh` sets `AGENT_SANDBOX_NO_SSH=1` in the container environment and skips the SSH agent socket mount.
- [ ] `--follow-symlinks` enables depth-1 symlink target mounting from the workspace (see workspace-isolation story for detailed behavior).
- [ ] `--follow-all-symlinks` enables depth-1 symlink target mounting including dotfile directories. Implies `--follow-symlinks`.
- [ ] `--mount <path>` adds an extra host directory mount (read-only by default; append `:rw` for read-write). Repeatable. See workspace-isolation story for mount path resolution and behavior.

### Image management
- [ ] `--prune` removes old `agent-sandbox:*` images (see image-management story for detailed behavior) and exits without starting a container.

### Runtime detection
- [ ] The launcher prefers `podman` if available, falls back to `docker`.
- [ ] On Podman, `--userns keep-id` is passed automatically. On Docker, it is omitted.
- [ ] `AGENT_SANDBOX_RUNTIME=docker` overrides runtime detection.
- [ ] If neither `podman` nor `docker` is found and `AGENT_SANDBOX_RUNTIME` is not set, the launcher exits with a non-zero code and a clear error message.

## Open Questions
- None.

## Out of Scope
- Session persistence across reboots.
- A TUI or status dashboard.
