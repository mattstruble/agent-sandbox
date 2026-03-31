# PRD: agent-sandbox

## Problem Statement

AI coding agents (OpenCode, Claude Code) run with full network access and access to the host filesystem. This creates two problems: **safety** — the agent can make outbound calls to arbitrary hosts, potentially exfiltrating code or secrets — and **cost** — every tool call returns uncompressed output that consumes LLM tokens unnecessarily.

`agent-sandbox` solves both: it runs the agent inside a container with a strict network allowlist and `rtk` pre-configured for transparent token compression, with no per-session setup required.

## User Stories

- As a developer, I want to run an AI coding agent against a project without exposing my host network or filesystem, so that I can work without risk of unintended data exfiltration.
- As a developer, I want token consumption reduced automatically on every agent session, so that I don't pay for verbose tool output.
- As a developer, I want to start a sandbox from any directory with a single command, so that the workflow is as fast as running the agent directly.
- As a developer, I want to run multiple sandboxed agent sessions in parallel on different projects, so that I can parallelize work without sessions interfering with each other.
- As a developer, I want my git identity, SSH credentials, and API keys available inside the sandbox, so that the agent can perform the same operations it could outside the sandbox.

## Expected Behaviors

### Sandbox Lifecycle

- Running `agent-sandbox` from a directory starts a sandboxed session with that directory as the workspace.
- An explicit workspace path may be passed as an argument; if omitted, the current directory is used.
- The active agent defaults to OpenCode; `--agent claude` selects Claude Code instead.
- Each session is identified by a name derived deterministically from the agent and the absolute workspace path — starting the same session twice does not create duplicate containers.
- `--list` displays all currently running agent-sandbox containers.
- `--stop` terminates the sandbox for the current (or specified) workspace.
- The container is removed automatically when the agent exits.

### Workspace Isolation

- Only the target workspace directory is accessible to the agent; the rest of the host filesystem is not mounted.
- Files written by the agent inside the workspace are reflected on the host filesystem immediately.
- The agent's working directory inside the container is the root of the mounted workspace.

### Network Sandboxing

- All outbound network traffic is blocked before the agent starts; there is no window where the agent runs without restrictions.
- The following destinations are allowlisted by default: Anthropic API, OpenAI API, OpenRouter, Mistral API, AWS Bedrock (all regions), GitHub, npm registry, DNS, SSH.
- Connections to non-allowlisted destinations are rejected immediately, not silently dropped.
- The user can extend the allowlist with additional domains via `~/.config/agent-sandbox/config.toml`.

### Agent Configuration

- The host agent configs (`~/.config/opencode/` for OpenCode, `~/.claude/` for Claude Code) are available to the agent inside the sandbox.
- Config changes made by the agent during a session do not persist back to the host.
- The host git identity (`~/.gitconfig`) is available to the agent.
- SSH operations use the host's SSH agent via socket forwarding; no private key material enters the container.
- API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `MISTRAL_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) and `GITHUB_TOKEN` present in the host environment are forwarded into the sandbox. Additional variables can be added via `config.toml`.
- The sandbox overrides agent tool permissions to fully allow for the duration of the session; the agent never prompts for approval to read, edit, or run commands.
- Permission overrides are applied regardless of what the host agent config specifies.
- The sandbox enforces container resource limits (memory and CPU) to prevent a runaway agent from starving the host; limits are configurable by the user.

### Token Savings

- `rtk` is pre-installed and configured for the active agent at the start of every session, with no user setup required.
- Shell commands (git, cargo, cat, ls, grep, and others) are transparently rewritten to `rtk` equivalents inside the container, reducing token consumption by 60–90%.

### Image Management

- The container image is built automatically on first use with no manual step required.
- The image is cached locally and reused on subsequent runs.
- When the Containerfile changes, the next run detects the change and rebuilds automatically.
- `--build` forces an immediate rebuild regardless of cache state.

### Distribution

- The tool is runnable without installation via `nix run github:mstruble/agent-sandbox`.
- The tool is installable into a user profile via `nix profile install github:mstruble/agent-sandbox`.
- The tool is referenceable as a flake input from other Nix flakes.

## Open Questions

- Should config changes inside the sandbox optionally be persisted back to the host (e.g. via a `--persist-config` flag)? Currently all in-session config changes are ephemeral.
- Should there be a mode that disables network sandboxing entirely for cases where the user needs unrestricted access?
- Should `rtk` gain stats (`rtk gain`) be persisted across sessions, or is per-session ephemerality acceptable?

## Out of Scope

- Building or publishing a pre-built image to a container registry (the image is always built and cached locally).
- A Home Manager or NixOS module (the flake exposes a package and app only).
- Per-project config files — configuration is user-global (`~/.config/agent-sandbox/config.toml`) only.
- Support for agents other than OpenCode and Claude Code.
- Windows support.
