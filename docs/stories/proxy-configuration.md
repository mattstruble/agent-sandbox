# Story: Proxy Configuration

## Source
PRD Capability Group: HTTP Method Filtering (Proxy)
Behaviors covered:
- The user may add additional domains to the whitelist via `[proxy].allowed_post_urls` in config.toml.
- The proxy is enabled by default; it can be disabled via `[proxy].enabled = false`.
- Corporate or additional CA certificates can be provided via `[proxy].extra_ca_certs`.

## Summary
Extends the config.toml parser in the launcher to support a new `[proxy]` section with three fields: `enabled`, `allowed_post_urls`, and `extra_ca_certs`. Values are validated, converted to environment variables, and passed into the container. The Home Manager Nix module is extended with corresponding typed options.

## Acceptance Criteria

### Config parsing
- [ ] `[proxy]` section: `enabled` is a boolean. Defaults to `true`. Passed to the container as `PROXY_ENABLED` env var (`true`/`false`).
- [ ] `[proxy]` section: `allowed_post_urls` is a list of strings, each a domain or origin (e.g., `"https://api.example.com"`, `"example.com"`). Defaults to an empty list. Passed to the container as `PROXY_ALLOW_POST_EXTRA` env var (comma-separated).
- [ ] `[proxy]` section: `extra_ca_certs` is a list of strings, each a file path (absolute or `~/`-prefixed). Defaults to an empty list. Paths are expanded and each file is mounted read-only into the container. Paths are passed as `PROXY_EXTRA_CA_CERTS` env var (comma-separated).
- [ ] `[proxy]` section: entries in `allowed_post_urls` that are empty strings or contain only whitespace cause a non-zero exit with a clear error.
- [ ] `[proxy]` section: entries in `extra_ca_certs` that are empty strings or contain only whitespace cause a non-zero exit with a clear error.
- [ ] If `extra_ca_certs` paths do not exist on the host, the launcher warns to stderr and continues (non-fatal).
- [ ] Unrecognized keys within `[proxy]` are silently ignored (forward compatibility, consistent with other sections).

### CLI override
- [ ] `--no-proxy` flag disables the proxy for the current session, overriding `[proxy].enabled = true` in config.

### Nix Home Manager module
- [ ] `programs.agent-sandbox.settings.proxy.enabled` option (boolean, default `true`) maps to `[proxy].enabled` in the generated config.toml.
- [ ] `programs.agent-sandbox.settings.proxy.allowed_post_urls` option (list of strings, default `[]`) maps to `[proxy].allowed_post_urls`.
- [ ] `programs.agent-sandbox.settings.proxy.extra_ca_certs` option (list of paths, default `[]`) maps to `[proxy].extra_ca_certs`.

## Open Questions
- None.

## Out of Scope
- The proxy binary itself (see proxy-binary story).
- Entrypoint wiring, CA generation, and iptables changes (see proxy-integration story).
