# Story: Network Sandboxing

## Source
PRD Capability Group: Network Sandboxing
Behaviors covered:
- All outbound network traffic is filtered before the agent starts; there is no window where the agent runs without restrictions.
- Only TCP ports 80 (HTTP), 443 (HTTPS), and optionally 22 (SSH) are permitted outbound. All other protocols and ports are blocked.
- DNS is pinned to the container's configured resolver only. Queries to other DNS servers are rejected.
- Connections on non-allowed ports are rejected immediately (ICMP admin-prohibited), not silently dropped.

## Summary
Implements the iptables-based port filter via `init-firewall.sh`, which runs as the **first** step in the container entrypoint — before config staging, rtk init, or the agent. IPv6 is disabled via `--sysctl` at container creation (primary) and sysctl in the entrypoint (defense-in-depth), with hard verification via `/proc`. DNS is pinned to the container's configured resolver.

## Acceptance Criteria
- [ ] `init-firewall.sh` is the first command run in `entrypoint.sh`, before config copying, `rtk init`, or the agent binary.
- [ ] The container is started with `--cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW`.
- [ ] IPv6 is disabled via `--sysctl` flags at container creation time and verified via `/proc/sys/net/ipv6/conf/all/disable_ipv6`; failure to disable IPv6 exits non-zero.
- [ ] After firewall initialization, outbound connections on non-HTTP/HTTPS ports are rejected (ICMP admin-prohibited), not silently dropped.
- [ ] Outbound TCP port 80 and 443 are allowed to any destination (required for MCP servers, documentation, APIs, and web browsing).

### DNS pinning
- [ ] DNS (UDP/TCP port 53) is restricted to the container's configured resolver IP, read from `/etc/resolv.conf` at startup.
- [ ] DNS queries to any IP other than the configured resolver are rejected.

### SSH firewall interaction
- [ ] If the container was started without `--no-ssh`, SSH outbound (TCP port 22) is allowed.
- [ ] If `--no-ssh` was used (communicated via `AGENT_SANDBOX_NO_SSH=1` env var), SSH outbound (TCP port 22) is also blocked by the firewall.

### Post-setup verification
- [ ] A negative test confirms that a non-HTTP port (TCP 9) to an external IP is blocked; failure exits non-zero.
- [ ] A positive test confirms that HTTPS (TCP 443) to an external IP is reachable; failure exits non-zero (catches overly-restrictive misconfiguration).

## Open Questions
- None.

## Out of Scope
- Destination-IP-based allowlisting (removed in favor of port-based filtering to support unrestricted web access).
- Per-session allowlist overrides via CLI flag.
- HTTP method-level filtering (see proxy-binary, proxy-integration, and proxy-configuration stories).
