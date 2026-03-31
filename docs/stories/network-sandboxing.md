# Story: Network Sandboxing

## Source
PRD Capability Group: Network Sandboxing
Behaviors covered:
- All outbound network traffic is blocked before the agent starts; there is no window where the agent runs without restrictions.
- The following destinations are allowlisted by default: Anthropic API, OpenAI API, OpenRouter, Mistral API, AWS Bedrock (all regions), GitHub, npm registry, DNS, SSH.
- Connections to non-allowlisted destinations are rejected immediately, not silently dropped.
- The user can extend the allowlist with additional domains via `~/.config/agent-sandbox/config.toml`.

## Summary
Implements the iptables-based network allowlist via `init-firewall.sh`, which runs as the **first** step in the container entrypoint — before config staging, rtk init, or the agent. IPv6 is disabled at the same time to prevent firewall bypass. DNS is pinned to the container's configured resolver. IP range fetches (GitHub, AWS Bedrock) degrade gracefully on failure.

## Acceptance Criteria
- [ ] `init-firewall.sh` is the first command run in `entrypoint.sh`, before config copying, `rtk init`, or the agent binary.
- [ ] The container is started with `--cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW`.
- [ ] `init-firewall.sh` disables IPv6 via `sysctl -w net.ipv6.conf.all.disable_ipv6=1` as its first action.
- [ ] After firewall initialization, outbound connections to non-allowlisted hosts are rejected (ICMP admin-prohibited), not silently dropped.
- [ ] The following domains are resolved and added to the allowlist at container start: `api.anthropic.com`, `api.openai.com`, `openrouter.ai`, `api.mistral.ai`, `opencode.ai`, `registry.npmjs.org`, `sentry.io`, `statsig.com`, `statsig.anthropic.com`.
- [ ] GitHub IP ranges are fetched from `api.github.com/meta` and added to the allowlist.
- [ ] AWS Bedrock IP ranges are fetched from `ip-ranges.amazonaws.com` filtered to the `BEDROCK` service prefix and added to the allowlist.

### DNS pinning
- [ ] DNS (UDP port 53) is restricted to the container's configured resolver IP, read from `/etc/resolv.conf` at startup.
- [ ] DNS queries to any IP other than the configured resolver are rejected.

### SSH firewall interaction
- [ ] If the container was started without `--no-ssh`, SSH outbound (TCP port 22) is allowed.
- [ ] If `--no-ssh` was used (communicated via `AGENT_SANDBOX_NO_SSH=1` env var), SSH outbound (TCP port 22) is also blocked by the firewall.

### Graceful IP range fetch failure
- [ ] If the GitHub IP range fetch (`api.github.com/meta`) fails, `init-firewall.sh` prints a warning to stderr and continues without GitHub IP ranges. The agent starts but may lack GitHub connectivity.
- [ ] If the AWS Bedrock IP range fetch (`ip-ranges.amazonaws.com`) fails, `init-firewall.sh` prints a warning to stderr and continues without Bedrock IP ranges.
- [ ] Domain-based allowlist entries (e.g., `api.anthropic.com`) are resolved independently and are not affected by IP range fetch failures.

### User-extensible allowlist
- [ ] Each entry in `AGENT_SANDBOX_EXTRA_DOMAINS` is validated against `^[a-zA-Z0-9]([a-zA-Z0-9\-\.]+)?$` before being resolved; invalid entries cause a non-zero exit.
- [ ] Valid `AGENT_SANDBOX_EXTRA_DOMAINS` entries are resolved and added to the allowlist before REJECT policies are applied.

### Post-setup verification
- [ ] A post-setup verification confirms that `example.com` is unreachable and `api.github.com` is reachable (if GitHub ranges were fetched successfully); failure of the `example.com` check exits non-zero.

## Open Questions
- None.

## Out of Scope
- ip6tables rules (IPv6 is disabled entirely instead).
- Per-session allowlist overrides via CLI flag.
