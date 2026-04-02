# Story: Proxy Integration

## Source
PRD Capability Group: HTTP Method Filtering (Proxy)
Behaviors covered:
- An internal MITM proxy runs inside the container, intercepting all HTTP and HTTPS traffic.
- Traffic is routed through the proxy via HTTP_PROXY and HTTPS_PROXY environment variables.
- Direct outbound traffic to ports 80 and 443 is dropped by iptables, forcing all HTTP/HTTPS through the proxy.
- The proxy generates a fresh CA keypair at each container startup, installed into the system trust store and NODE_EXTRA_CA_CERTS.
- Corporate or additional CA certificates are mounted and merged into the system trust store.
- LLM provider domains are auto-whitelisted based on which API keys are present.
- Remote MCP server URLs are auto-whitelisted by parsing agent config files.
- The proxy is enabled by default.

## Summary
Wires the proxy binary into the container entrypoint and firewall. The entrypoint root phase generates a CA keypair, merges any extra CA certs into the system trust store, assembles the whitelist from API keys and MCP configs, starts the proxy, then modifies iptables to drop direct port 80/443 traffic. The sandbox user phase sets `HTTP_PROXY`/`HTTPS_PROXY` and `NODE_EXTRA_CA_CERTS` before launching the agent.

## Acceptance Criteria

### CA certificate generation
- [ ] A fresh CA certificate and private key are generated during the entrypoint root phase, before the proxy starts.
- [ ] The CA certificate is installed to `/usr/local/share/ca-certificates/` and `update-ca-certificates` is run.
- [ ] `NODE_EXTRA_CA_CERTS` is set to point to the system CA bundle so that Node.js (used by Claude Code) trusts the proxy CA.

### Corporate CA support
- [ ] If extra CA certificate paths are provided (via `PROXY_EXTRA_CA_CERTS` environment variable, populated from config), each file is copied into `/usr/local/share/ca-certificates/` before `update-ca-certificates` runs.
- [ ] Extra CA cert files are mounted read-only from the host into the container.
- [ ] If a specified CA cert file does not exist on the host, the launcher warns and continues without it (non-fatal).

### Whitelist auto-detection
- [ ] If `ANTHROPIC_API_KEY` is set, `api.anthropic.com` is added to the whitelist.
- [ ] If `OPENAI_API_KEY` is set, `api.openai.com` is added to the whitelist.
- [ ] If `OPENROUTER_API_KEY` is set, `openrouter.ai` is added to the whitelist.
- [ ] If `MISTRAL_API_KEY` is set, `api.mistral.com` is added to the whitelist.
- [ ] If `AWS_ACCESS_KEY_ID` is set, `bedrock-runtime.*.amazonaws.com` is added to the whitelist (wildcard region matching).
- [ ] `models.dev` is always added to the whitelist regardless of which keys are present.
- [ ] Remote MCP server URLs in `~/.claude/settings.json` (Claude Code) are parsed and their domains added to the whitelist.
- [ ] Remote MCP server URLs in `~/.config/opencode/opencode.json` (OpenCode) are parsed and their domains added to the whitelist.
- [ ] If an MCP config file does not exist or cannot be parsed, the entrypoint continues without those whitelist entries (non-fatal).
- [ ] User-configured `allowed_post_urls` (via `PROXY_ALLOW_POST_EXTRA` env var, populated from config) are added to the whitelist, additive to auto-detected domains.

### Proxy startup
- [ ] The proxy binary is started in the background during the entrypoint root phase, after CA generation and before iptables modification.
- [ ] The entrypoint waits for the proxy to be accepting connections before proceeding (health check on proxy port).
- [ ] If the proxy fails to start, the entrypoint exits non-zero with a clear error message.

### iptables integration
- [ ] Direct outbound TCP traffic to ports 80 and 443 is dropped by iptables, except traffic originating from the proxy process itself.
- [ ] Traffic from the proxy process to ports 80 and 443 is allowed (the proxy needs to make upstream connections).
- [ ] Loopback traffic to the proxy port (8080) is allowed.
- [ ] The existing iptables rules for DNS pinning, NTP pinning, SSH, and IPv6 disabling remain unchanged.

### Environment variables
- [ ] `HTTP_PROXY` and `HTTPS_PROXY` are set to `http://127.0.0.1:8080` in the sandbox user phase.
- [ ] `NO_PROXY` is set to `localhost,127.0.0.1` to prevent loopback traffic from being proxied.

### Proxy disabled mode
- [ ] When the proxy is disabled (via `PROXY_ENABLED=false` env var, populated from config), none of the above steps execute — no CA generation, no proxy startup, no iptables changes, no proxy env vars.
- [ ] When disabled, the existing port 80/443 iptables ACCEPT rules remain as they are today (unrestricted outbound HTTP/HTTPS).

## Open Questions
- None.

## Out of Scope
- The proxy binary itself (see proxy-binary story).
- Config file parsing for `[proxy]` section (see proxy-configuration story).
