# Story: Time Synchronization

## Source
PRD Capability Group: Time Synchronization
Behaviors covered:
- The container's system clock is kept synchronized with an external time source for the lifetime of the session.
- Time synchronization starts before the agent and runs continuously in the background, correcting drift caused by host sleep/resume (e.g., macOS lid close with Podman Machine).
- NTP traffic is restricted to pinned Cloudflare server IPs only; NTP to any other destination is rejected.
- If time synchronization fails to start, the container starts normally without it — time sync failure never blocks a session.

## Summary
On macOS, Podman Machine's Linux VM clock drifts after host sleep/resume. Containers inherit the stale clock, causing AWS SigV4 signature expiry errors (>5 minute skew) and potentially other time-sensitive failures. This story adds `chronyd` to the container image, configured with Cloudflare NTP servers pinned in both the chrony config and the firewall, and starts it as a background daemon before the agent.

## Acceptance Criteria

### Chrony daemon
- [ ] `chrony` is installed in the container image.
- [ ] A minimal `chrony.conf` is shipped in the image at `/etc/chrony/chrony.conf`, configured with Cloudflare NTP server IPs as the only time sources.
- [ ] `chrony.conf` uses IP addresses directly (no DNS dependency at chrony startup).
- [ ] `chrony.conf` disables all listening sockets (`port 0`, `cmdport 0`) — the daemon is client-only.
- [ ] `chrony.conf` uses `makestep 1 3` to allow stepping the clock for large initial corrections after sleep/wake.
- [ ] `chronyd` is started in the entrypoint as root, after firewall setup and before dropping to the sandbox user.
- [ ] If `chronyd` fails to start, a warning is logged and the entrypoint continues — time sync failure never blocks startup.

### Firewall rules
- [ ] UDP port 123 outbound is allowed to Cloudflare NTP server IPs (162.159.200.1, 162.159.200.123).
- [ ] UDP port 123 outbound to any other destination is rejected with ICMP feedback (same pattern as DNS pinning).
- [ ] The NTP rules are placed between the DNS and HTTP/HTTPS rules in init-firewall.sh.

### Container capabilities
- [ ] The container is started with `--cap-add=SYS_TIME` in addition to existing capabilities.

### Documentation
- [ ] DESIGN.md is updated to reflect the new capability, firewall rule, and entrypoint step.

## Open Questions
- None.

## Out of Scope
- NTS (Network Time Security) — adds complexity (TCP 4460) for no practical benefit in this threat model.
- User-configurable NTP servers.
- One-shot HTTPS-based time correction as a fallback if NTP is unreachable.
