# Agent Sandbox

Run AI coding agents in isolated, network-firewalled containers with
built-in token compression.

Agent Sandbox wraps Podman (or Docker) to run
[OpenCode](https://opencode.ai) and
[Claude Code](https://github.com/anthropics/claude-code) inside sandboxed
containers. An iptables firewall restricts outbound traffic to only
HTTP/HTTPS and DNS, preventing unintended data exfiltration. The bundled
[rtk](https://github.com/rtk-ai/rtk) proxy compresses tool-call output,
cutting LLM token costs by 60--90%.

## Quick Start

```bash
# With Nix (no install required):
nix run github:mattstruble/agent-sandbox

# Or install with the shell installer:
curl -fsSL https://raw.githubusercontent.com/mattstruble/agent-sandbox/main/install.sh | sh
```

Then, from any project directory:

```bash
agent-sandbox              # run opencode on the current directory
agent-sandbox --agent claude   # run claude code instead
```

## Install

### Nix (recommended)

```bash
# With Nix (no install required):
nix run github:mattstruble/agent-sandbox

# Permanent install:
nix profile install github:mattstruble/agent-sandbox
```

Nix modules are provided for NixOS, nix-darwin, and Home Manager:

```nix
# flake.nix inputs
inputs.agent-sandbox.url = "github:mattstruble/agent-sandbox";

# Home Manager example
programs.agent-sandbox = {
  enable = true;
  settings.defaultAgent = "opencode";
  settings.resources.memory = "16g";
};
```

### Shell installer

```bash
curl -fsSL https://raw.githubusercontent.com/mattstruble/agent-sandbox/main/install.sh | sh
```

Installs to `~/.local/bin/agent-sandbox`. Uninstall with
`agent-sandbox --update` or re-run with `--uninstall`.

### Container image

```bash
docker pull ghcr.io/mattstruble/agent-sandbox:latest
```

## Usage

```
agent-sandbox [OPTIONS] [WORKSPACE]
```

| Flag | Description |
|---|---|
| `-a, --agent <name>` | Agent to run: `opencode` (default) or `claude` |
| `-b, --build` | Force image rebuild before running |
| `--follow-symlinks` | Mount depth-1 symlink targets from the workspace |
| `--mount <path>` | Mount an extra host path read-only (repeatable; append `:rw` for read-write) |
| `--no-ssh` | Skip SSH agent socket forwarding |
| `--list` | List running sandbox containers |
| `--stop` | Stop sandbox(es) for the current/given workspace |
| `--prune` | Remove old images, keep the current one |
| `--update` | Self-update to the latest release (non-Nix) |

```bash
agent-sandbox ~/projects/foo               # specific workspace
agent-sandbox --mount ~/.kube              # mount extra path read-only
agent-sandbox --mount ~/data:rw            # mount extra path read-write
agent-sandbox --stop --agent claude        # stop only the claude sandbox
```

Run `agent-sandbox --help` for the full reference.

## Configuration

Create `~/.config/agent-sandbox/config.toml` to set persistent defaults.
All fields are optional.

```toml
[defaults]
agent = "opencode"                # default agent

[env]
extra_vars = ["DEEPSEEK_API_KEY"] # additional env vars to forward

[workspace]
follow_all_symlinks = false       # include dotfile dirs when following symlinks

[mounts]
extra_paths = ["~/.kube"]         # additional host paths to mount

[resources]
memory = "8g"                     # container memory limit
cpus = 4                          # container CPU limit
```

Nix Home Manager users can declare this configuration via typed options
under `programs.agent-sandbox.settings` instead of managing the file
directly.

## Security

Every container runs with:

- **Dropped capabilities** -- `--cap-drop=ALL`, then only `NET_ADMIN`,
  `NET_RAW`, `SETUID`, `SETGID` added back (firewall setup, then dropped)
- **No new privileges** -- `--security-opt=no-new-privileges`
- **Port-based iptables firewall** -- only TCP 80, 443, and (optionally) 22
  are allowed outbound; all other ports are rejected
- **Pinned DNS** -- UDP/TCP 53 restricted to the container's own resolver;
  blocks DNS tunneling to external nameservers
- **IPv6 disabled** -- fully blocked via sysctl and ip6tables
- **API key allowlist** -- only explicitly named environment variables are
  forwarded; no glob patterns
- **Resource limits** -- `--memory=8g --cpus=4` by default (configurable)
- **Firewall self-test** -- two runtime checks verify the rules are applied
  correctly before the agent starts

See [DESIGN.md](DESIGN.md) for the full security model and architecture.

## Requirements

- **Container runtime**: [Podman](https://podman.io) (preferred) or Docker
- **macOS/Linux**: x86_64 or aarch64
- **Nix users**: Nix with flakes enabled (runtime deps are handled
  automatically)

Override the container runtime with `AGENT_SANDBOX_RUNTIME=docker` or
`AGENT_SANDBOX_RUNTIME=podman`.

## License

[MIT](LICENSE)
