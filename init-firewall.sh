#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# init-firewall.sh — port-based network filter for agent-sandbox containers
# Runs as root as the first step in entrypoint.sh, before any agent code.
#
# Security model:
#   ALLOW  — loopback, established/related, DNS (pinned), TCP 80/443, SSH (conditional)
#   BLOCK  — all IPv6, all other outbound protocols/ports, all unsolicited inbound

# Regex for valid IPv4 host address (no prefix)
IPV4_ADDR_REGEX='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[firewall] $*" >&2; }
warn() { echo "[firewall] WARNING: $*" >&2; }
err() { echo "[firewall] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Disable IPv6 — defense-in-depth (primary mechanism is --sysctl at container creation)
# ---------------------------------------------------------------------------

log "Disabling IPv6..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || warn "sysctl disable_ipv6 (all) failed — may already be set via container runtime"
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || warn "sysctl disable_ipv6 (default) failed — may already be set via container runtime"
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || warn "sysctl disable_ipv6 (lo) failed — may already be set via container runtime"

# Hard verification: confirm IPv6 is actually disabled regardless of sysctl exit code.
# If neither --sysctl (at container creation) nor the in-container sysctl succeeded,
# fail closed — do not start the agent with IPv6 enabled.
if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]; then
	err "IPv6 could not be disabled — aborting for safety"
	exit 1
fi

# Drop all IPv6 traffic
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Detect container DNS resolver
# ---------------------------------------------------------------------------

log "Detecting DNS resolver from /etc/resolv.conf..."
DNS_IP=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}' || true)
if [[ -z "$DNS_IP" ]]; then
	err "Could not determine DNS resolver from /etc/resolv.conf"
	exit 1
fi
if ! [[ "$DNS_IP" =~ $IPV4_ADDR_REGEX ]]; then
	err "DNS resolver '$DNS_IP' is not a valid IPv4 address — IPv6 resolvers are not supported"
	exit 1
fi
log "  DNS resolver: $DNS_IP"

# ---------------------------------------------------------------------------
# 3. Flush existing iptables rules
# ---------------------------------------------------------------------------

log "Flushing existing iptables rules..."
iptables -L >/dev/null 2>&1 || {
	err "iptables is not available — NET_ADMIN capability may be missing"
	exit 1
}
iptables -F
iptables -X

# Preserve Docker's embedded DNS NAT rules (127.0.0.11 relies on DNAT)
if [[ "$DNS_IP" == "127.0.0.11" ]]; then
	log "  Skipping nat table flush — Docker embedded resolver (127.0.0.11) detected"
else
	iptables -t nat -F
	iptables -t nat -X
fi
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Apply iptables rules
# ---------------------------------------------------------------------------

log "Applying iptables rules..."

# --- INPUT chain ---
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -j REJECT --reject-with icmp-admin-prohibited

# --- OUTPUT chain ---
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS: pinned to container resolver only (mitigates DNS tunneling)
iptables -A OUTPUT -p udp --dport 53 -d "$DNS_IP" -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable
iptables -A OUTPUT -p tcp --dport 53 -d "$DNS_IP" -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j REJECT --reject-with icmp-port-unreachable

# HTTP/HTTPS: allow all outbound web traffic
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

# SSH: conditionally allowed
if [[ "${AGENT_SANDBOX_NO_SSH:-}" != "1" ]]; then
	log "  SSH outbound (TCP 22): ALLOWED"
	iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
else
	log "  SSH outbound (TCP 22): BLOCKED (AGENT_SANDBOX_NO_SSH=1)"
fi

# Reject everything else with immediate ICMP feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Default DROP policies (catch-all after REJECT rules)
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

log "iptables rules applied."

# ---------------------------------------------------------------------------
# 5. Post-setup verification
# ---------------------------------------------------------------------------

log "Running post-setup verification..."

# Negative test: a non-HTTP port must be blocked.
# TCP 9 (discard) is never legitimately needed; the REJECT rule drops it immediately.
# If iptables failed to apply (default kernel ACCEPT policy), this catches it.
log "  Checking non-HTTP port is blocked..."
if timeout 3 bash -c 'echo >/dev/tcp/93.184.216.34/9' 2>/dev/null; then
	err "FIREWALL BROKEN: non-HTTP port (TCP 9) is reachable — iptables rules did not apply correctly"
	exit 1
fi
log "  Non-HTTP traffic is blocked."

# Positive test: HTTPS must be reachable.
# Validates that ACCEPT rules for TCP 443 are actually in place. Without this,
# a firewall that blocks *everything* (e.g., rules applied in wrong order, or
# default DROP without ACCEPT rules) would pass the negative test alone.
log "  Checking HTTPS port is reachable..."
if ! timeout 5 bash -c 'echo >/dev/tcp/93.184.216.34/443' 2>/dev/null; then
	err "FIREWALL BROKEN: HTTPS (TCP 443) is not reachable — ACCEPT rules may not have applied"
	exit 1
fi
log "  HTTPS traffic is allowed — firewall is working."

log "Firewall initialization complete."
