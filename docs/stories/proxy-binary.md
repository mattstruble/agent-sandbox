# Story: Proxy Binary

## Source
PRD Capability Group: HTTP Method Filtering (Proxy)
Behaviors covered:
- The proxy blocks outbound requests using write methods (POST, PUT, PATCH, DELETE) to non-whitelisted domains, returning a 403 with a descriptive error message.
- The proxy allows read methods (GET, HEAD, OPTIONS) to any domain without restriction.
- WebSocket upgrade requests to non-whitelisted domains are blocked; WebSocket connections to whitelisted domains are allowed.
- Whitelisting operates at domain/origin level, not per-path.
- Blocked requests are logged to stderr with method, domain, and timestamp.
- The proxy is built as a static Go binary using goproxy, compiled via a multi-stage build in the Containerfile.

## Summary
Implements the Go proxy binary using `github.com/elazarl/goproxy`. The binary listens on a configurable port (default 8080), intercepts HTTP and HTTPS traffic via CONNECT-based MITM, and enforces method-based filtering against a domain whitelist. The whitelist is read from an environment variable at startup. The binary is compiled as a static binary in a multi-stage Containerfile build and dropped into the final image.

## Acceptance Criteria

### Method filtering
- [ ] GET, HEAD, and OPTIONS requests to any domain are forwarded without modification.
- [ ] POST, PUT, PATCH, and DELETE requests to a whitelisted domain are forwarded without modification.
- [ ] POST, PUT, PATCH, and DELETE requests to a non-whitelisted domain return HTTP 403 with a body that includes: the blocked method, the target domain, and instructions to add the domain to `[proxy].allowed_post_urls` in `config.toml`.
- [ ] The proxy does not inspect or modify request/response bodies for allowed requests.

### WebSocket filtering
- [ ] WebSocket upgrade requests (HTTP `GET` with `Upgrade: websocket` header) to a non-whitelisted domain are blocked with HTTP 403.
- [ ] WebSocket upgrade requests to a whitelisted domain are forwarded normally.

### Whitelist matching
- [ ] The whitelist is read from the `PROXY_ALLOW_POST` environment variable as a comma-separated list of domain/origin strings.
- [ ] Matching is performed at the domain/origin level (scheme + host), ignoring path and query parameters.
- [ ] An empty whitelist means all write methods are blocked to all domains.

### HTTPS interception
- [ ] HTTPS connections are intercepted via CONNECT + MITM using a CA certificate and key provided via environment variables or file paths.
- [ ] The proxy signs intercepted responses with the provided CA.

### Logging
- [ ] Blocked requests are logged to stderr with: timestamp, method, and target domain.
- [ ] Allowed requests are not logged (avoids noise).

### Build
- [ ] The proxy is compiled as a statically-linked Go binary (CGO_ENABLED=0).
- [ ] The Containerfile includes a Go builder stage that compiles the proxy and copies the binary into the final image.
- [ ] The binary is placed at `/usr/local/bin/sandbox-proxy` in the final image.

## Open Questions
- None.

## Out of Scope
- CA certificate generation (see proxy-integration story).
- iptables rules to force traffic through the proxy (see proxy-integration story).
- Config file parsing for `[proxy]` section (see proxy-configuration story).
- Auto-detection of whitelist domains from API keys or MCP configs (see proxy-integration story).
