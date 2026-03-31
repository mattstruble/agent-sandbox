#!/usr/bin/env bash
set -euo pipefail

# init-firewall.sh — iptables-based network allowlist for agent-sandbox containers
# Runs as root (via sudo) as the first step in entrypoint.sh, before any agent code.

IPSET_NAME="allowed-ips"
GITHUB_RANGES_OK=false

# Regex for valid IPv4 CIDR with prefix length 1–32 (rejects /0 which would allowlist everything)
# Used to validate CIDRs from remote sources before adding to ipset.
IPV4_CIDR_REGEX='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/([1-9]|[12][0-9]|3[0-2])$'

# Regex for valid IPv4 host address (no prefix)
IPV4_ADDR_REGEX='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

# Regex for valid hostnames in AGENT_SANDBOX_EXTRA_DOMAINS.
# Stricter than the spec's ^[a-zA-Z0-9]([a-zA-Z0-9\-\.]+)?$ (which accepts single-label names
# and consecutive dots). This regex requires multi-label FQDNs, rejects consecutive dots,
# trailing dots, and leading/trailing hyphens per label.
HOSTNAME_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'

# Temp files scoped to this process; cleaned up on exit.
# Register trap before mktemp so partial initialization is handled safely.
IPSET_ERR_FILE=""
CURL_BODY_FILE=""
trap 'rm -f "${IPSET_ERR_FILE:-}" "${CURL_BODY_FILE:-}"' EXIT
IPSET_ERR_FILE=$(mktemp /tmp/ipset_err.XXXXXX)
CURL_BODY_FILE=$(mktemp /tmp/curl_body.XXXXXX)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[firewall] $*" >&2; }
warn() { echo "[firewall] WARNING: $*" >&2; }
err() { echo "[firewall] ERROR: $*" >&2; }

# Add a validated CIDR or host IP to the ipset. Logs a warning on failure.
ipset_add() {
	local entry="$1"
	if ! ipset add "$IPSET_NAME" "$entry" 2>"$IPSET_ERR_FILE"; then
		warn "ipset add failed for '$entry': $(cat "$IPSET_ERR_FILE")"
	fi
}

# Resolve a domain to its IP addresses and add each to the ipset.
# Validates each IP against the strict IPv4 regex (octet range 0–255).
# Skips entries that produce no IPs (e.g., CNAME-only or NXDOMAIN).
resolve_domain() {
	local domain="$1"
	local ips
	local dig_out
	# Capture dig output separately to avoid masking dig failures with grep's exit code.
	# dig exits non-zero on NXDOMAIN/SERVFAIL; grep exits 1 on no match — both are handled
	# by the empty-string check below. || true prevents set -e from aborting on either.
	dig_out=$(dig +short +timeout=5 +tries=2 "$domain" 2>/dev/null || true)
	# Filter to strict IPv4 addresses only; reuse IPV4_ADDR_REGEX for consistency.
	ips=$(echo "$dig_out" | grep -E "$IPV4_ADDR_REGEX" || true)
	if [[ -z "$ips" ]]; then
		warn "No IPs resolved for $domain — skipping"
		return 0
	fi
	while IFS= read -r ip; do
		log "  $domain → $ip"
		ipset_add "$ip"
	done <<<"$ips"
}

# ---------------------------------------------------------------------------
# 1. Disable IPv6 — must be first to prevent firewall bypass
# ---------------------------------------------------------------------------

log "Disabling IPv6..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null

# Flush ip6tables as defense-in-depth in case IPv6 is re-enabled by another process
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Detect container resolver (must happen before nat table flush)
# ---------------------------------------------------------------------------

# Read DNS resolver early so we can decide whether to flush the nat table.
# Docker's embedded DNS resolver (127.0.0.11) relies on nat DNAT rules to function;
# flushing the nat table when that resolver is in use would break all DNS resolution.
log "Detecting DNS resolver from /etc/resolv.conf..."
DNS_IP=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}' || true)
if [[ -z "$DNS_IP" ]]; then
	err "Could not determine DNS resolver from /etc/resolv.conf"
	exit 1
fi
# Validate DNS_IP is an IPv4 address before using it in iptables rules.
# An IPv6 nameserver (e.g. ::1 from systemd-resolved) would cause iptables to fail
# mid-application, leaving the firewall in a partial state.
if ! [[ "$DNS_IP" =~ $IPV4_ADDR_REGEX ]]; then
	err "DNS resolver '$DNS_IP' is not a valid IPv4 address — IPv6 resolvers are not supported (IPv6 is disabled)"
	exit 1
fi
log "  DNS resolver: $DNS_IP"

# ---------------------------------------------------------------------------
# 3. Flush existing rules and destroy prior ipsets
# ---------------------------------------------------------------------------

log "Flushing existing iptables rules..."
# Verify iptables is functional before flushing (fails loudly if NET_ADMIN is missing)
iptables -L >/dev/null 2>&1 || {
	err "iptables is not available — NET_ADMIN capability may be missing"
	exit 1
}
iptables -F
iptables -X

# NOTE: We do NOT set default-DROP policies here. Domain resolution (section 6),
# GitHub/AWS range fetches (sections 7–8), and the ipset non-empty assertion (section 10)
# all require outbound network access. DROP policies are applied in section 11 after the
# allowlist is fully populated. Under set -euo pipefail, any failure in sections 4–10
# exits non-zero, preventing the agent from starting — this is the fail-closed guarantee.

# When Docker's embedded resolver (127.0.0.11) is in use, Docker installs DNAT rules
# in the nat table to redirect port-53 traffic to the real resolver backend. Flushing
# the nat table would destroy those rules and break DNS. Skip the nat flush in that case
# since this script adds no nat rules of its own.
if [[ "$DNS_IP" == "127.0.0.11" ]]; then
	log "  Skipping nat table flush — Docker embedded resolver (127.0.0.11) detected"
else
	iptables -t nat -F
	iptables -t nat -X
fi

# mangle table may not be loaded in all kernels; skip gracefully if absent
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

log "Destroying existing ipsets..."
ipset destroy "$IPSET_NAME" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Create ipset
# ---------------------------------------------------------------------------

log "Creating ipset '$IPSET_NAME'..."
ipset create "$IPSET_NAME" hash:net

# ---------------------------------------------------------------------------
# 5. Detect host gateway subnet
# ---------------------------------------------------------------------------

log "Detecting host gateway subnet..."
# Extract the first non-default connected route (local subnet) from the routing table.
# grep -E '^[0-9]' selects lines starting with a digit (CIDR routes, not 'default').
GATEWAY_SUBNET=$(ip route | grep -E '^[0-9]' | grep -v '^default' | head -1 | awk '{print $1}' || true)
if [[ -n "$GATEWAY_SUBNET" ]]; then
	# Validate the subnet is a proper CIDR (not 0.0.0.0/0 which would allowlist everything)
	if [[ "$GATEWAY_SUBNET" =~ $IPV4_CIDR_REGEX ]]; then
		log "  Gateway subnet: $GATEWAY_SUBNET"
		ipset_add "$GATEWAY_SUBNET"
	else
		warn "Gateway subnet '$GATEWAY_SUBNET' failed CIDR validation — skipping"
	fi
else
	warn "Could not detect gateway subnet from ip route"
fi

# ---------------------------------------------------------------------------
# 6. Resolve default allowlisted domains
# ---------------------------------------------------------------------------

log "Resolving default allowlisted domains..."
ALLOWED_DOMAINS=(
	"api.anthropic.com"
	"api.openai.com"
	"openrouter.ai"
	"api.mistral.ai"
	"opencode.ai"
	"registry.npmjs.org"
	"sentry.io"
	"statsig.com"
	"statsig.anthropic.com"
)

for domain in "${ALLOWED_DOMAINS[@]}"; do
	resolve_domain "$domain"
done

# ---------------------------------------------------------------------------
# 7. Fetch GitHub IP ranges (best-effort)
# ---------------------------------------------------------------------------

fetch_github_ranges() {
	log "Fetching GitHub IP ranges from api.github.com/meta..."
	local http_code

	# Write response body to temp file; capture HTTP status code separately.
	# This avoids fragile line-splitting when the body ends with a blank line.
	http_code=$(curl -s --max-time 15 \
		-o "$CURL_BODY_FILE" \
		-w "%{http_code}" \
		"https://api.github.com/meta" 2>/dev/null) || {
		warn "curl failed fetching GitHub IP ranges — skipping"
		return 1
	}

	if [[ "$http_code" != "200" ]]; then
		warn "GitHub meta API returned HTTP $http_code — skipping GitHub IP ranges"
		return 1
	fi

	local cidrs
	# Extract web, api, and git CIDRs; filter to IPv4 only (exclude IPv6 ranges)
	cidrs=$(jq -r '(.web[], .api[], .git[]) | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/"))' \
		"$CURL_BODY_FILE" 2>/dev/null) || {
		warn "Failed to parse GitHub IP ranges JSON — skipping"
		return 1
	}

	if [[ -z "$cidrs" ]]; then
		warn "GitHub meta API returned no IPv4 CIDRs — skipping"
		return 1
	fi

	local count=0
	while IFS= read -r cidr; do
		# Validate CIDR before adding: reject /0 (would allowlist the entire internet)
		if ! [[ "$cidr" =~ $IPV4_CIDR_REGEX ]]; then
			warn "Skipping invalid/dangerous CIDR from GitHub meta: '$cidr'"
			continue
		fi
		ipset_add "$cidr"
		count=$((count + 1))
	done <<<"$cidrs"
	log "  Added $count GitHub CIDRs to allowlist"
	return 0
}

if fetch_github_ranges; then
	GITHUB_RANGES_OK=true
else
	warn "GitHub IP ranges not loaded — agent may lack GitHub connectivity"
fi

# ---------------------------------------------------------------------------
# 8. Fetch AWS Bedrock IP ranges (best-effort)
# ---------------------------------------------------------------------------

fetch_bedrock_ranges() {
	log "Fetching AWS Bedrock IP ranges from ip-ranges.amazonaws.com..."
	local http_code

	# Write response body to temp file; capture HTTP status code separately.
	# This avoids fragile line-splitting when the body ends with a blank line.
	http_code=$(curl -s --max-time 15 \
		-o "$CURL_BODY_FILE" \
		-w "%{http_code}" \
		"https://ip-ranges.amazonaws.com/ip-ranges.json" 2>/dev/null) || {
		warn "curl failed fetching AWS IP ranges — skipping"
		return 1
	}

	if [[ "$http_code" != "200" ]]; then
		warn "AWS IP ranges API returned HTTP $http_code — skipping Bedrock IP ranges"
		return 1
	fi

	local cidrs
	cidrs=$(jq -r '.prefixes[] | select(.service == "BEDROCK") | .ip_prefix' \
		"$CURL_BODY_FILE" 2>/dev/null) || {
		warn "Failed to parse AWS IP ranges JSON — skipping"
		return 1
	}

	if [[ -z "$cidrs" ]]; then
		warn "AWS IP ranges returned no BEDROCK prefixes — skipping"
		return 1
	fi

	local count=0
	while IFS= read -r cidr; do
		# Validate CIDR before adding: reject /0 (would allowlist the entire internet)
		if ! [[ "$cidr" =~ $IPV4_CIDR_REGEX ]]; then
			warn "Skipping invalid/dangerous CIDR from AWS IP ranges: '$cidr'"
			continue
		fi
		ipset_add "$cidr"
		count=$((count + 1))
	done <<<"$cidrs"
	log "  Added $count AWS Bedrock CIDRs to allowlist"
	return 0
}

if ! fetch_bedrock_ranges; then
	warn "AWS Bedrock IP ranges not loaded — agent may lack Bedrock connectivity"
fi

# ---------------------------------------------------------------------------
# 9. Process user-extensible domains (AGENT_SANDBOX_EXTRA_DOMAINS)
#    Format: newline-separated list of hostnames
# ---------------------------------------------------------------------------

if [[ -n "${AGENT_SANDBOX_EXTRA_DOMAINS:-}" ]]; then
	log "Processing extra domains from AGENT_SANDBOX_EXTRA_DOMAINS..."
	while IFS= read -r extra_domain; do
		# Skip blank lines
		[[ -z "$extra_domain" ]] && continue
		# Validate hostname before resolving (defense-in-depth against injection).
		# Uses HOSTNAME_REGEX which requires multi-label FQDNs (at least one dot).
		if ! [[ "$extra_domain" =~ $HOSTNAME_REGEX ]]; then
			err "Invalid domain in AGENT_SANDBOX_EXTRA_DOMAINS: '$extra_domain'"
			exit 1
		fi
		log "  Resolving extra domain: $extra_domain"
		resolve_domain "$extra_domain"
	done <<<"$AGENT_SANDBOX_EXTRA_DOMAINS"
fi

# ---------------------------------------------------------------------------
# 10. Assert ipset is non-empty before applying restrictive rules
# ---------------------------------------------------------------------------

# Count member entries only — skip ipset list header lines (Name:, Type:, Members:, etc.)
# Separate the ipset list from the count to distinguish ipset failure from zero-match.
IPSET_LIST=$(ipset list "$IPSET_NAME")
IPSET_COUNT=0
while IFS= read -r line; do
	[[ "$line" =~ ^[0-9] ]] && IPSET_COUNT=$((IPSET_COUNT + 1)) || true # member entries start with a digit
done <<<"$IPSET_LIST"
if [[ "$IPSET_COUNT" -eq 0 ]]; then
	err "Allowlist ipset is empty — all domain resolutions failed. Refusing to apply firewall rules that would block all outbound traffic."
	exit 1
fi
log "Allowlist contains $IPSET_COUNT entries — proceeding to apply rules."

# ---------------------------------------------------------------------------
# 11. Apply iptables rules
# ---------------------------------------------------------------------------

log "Applying iptables rules..."

# --- INPUT chain ---

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Reject all other INPUT with immediate feedback.
# Explicit REJECT fires before DROP policy — DROP policy alone gives no ICMP feedback to the caller.
iptables -A INPUT -j REJECT --reject-with icmp-admin-prohibited

# --- OUTPUT chain ---

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DNS only to the configured resolver; reject DNS to any other destination.
# This pins DNS to the container's resolver and mitigates DNS tunneling exfiltration.
iptables -A OUTPUT -p udp --dport 53 -d "$DNS_IP" -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable
iptables -A OUTPUT -p tcp --dport 53 -d "$DNS_IP" -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j REJECT --reject-with icmp-port-unreachable

# Allow SSH outbound unless explicitly blocked.
# NOTE: SSH is allowed to ANY destination (not restricted to ipset).
# This is intentional — see DESIGN.md "SSH agent socket" trust boundary.
# Use AGENT_SANDBOX_NO_SSH=1 to block SSH entirely.
if [[ "${AGENT_SANDBOX_NO_SSH:-}" != "1" ]]; then
	log "  SSH outbound (TCP 22): ALLOWED"
	iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
else
	log "  SSH outbound (TCP 22): BLOCKED (AGENT_SANDBOX_NO_SSH=1)"
fi

# Allow all OUTPUT to IPs in the allowlist ipset
iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j ACCEPT

# Reject all other OUTPUT with immediate feedback
# Explicit REJECT fires before DROP policy — DROP policy alone gives no ICMP feedback to the caller.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Apply default DROP policies last, after all ACCEPT/REJECT rules are in place.
# iptables policy only supports DROP/ACCEPT (not REJECT), so explicit REJECT rules above
# provide immediate ICMP feedback while the DROP policy catches any remaining traffic.
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

log "iptables rules applied."

# ---------------------------------------------------------------------------
# 12. Post-setup verification
# ---------------------------------------------------------------------------

log "Running post-setup verification..."

# Critical check: a known non-allowlisted IP must be unreachable.
# We test a direct IP (not a domain) to bypass DNS and directly validate the OUTPUT REJECT rule.
# 93.184.216.34 is the IANA-operated example.com address, not in any allowlist.
BLOCKED_TEST_IP="93.184.216.34"
log "  Checking $BLOCKED_TEST_IP (example.com) is unreachable (firewall sanity check)..."
if curl -sf --no-location --max-time 5 --connect-timeout 3 "http://$BLOCKED_TEST_IP/" >/dev/null 2>&1; then
	err "FIREWALL BROKEN: $BLOCKED_TEST_IP is reachable — iptables rules did not apply correctly"
	exit 1
fi
log "  $BLOCKED_TEST_IP is unreachable — firewall is working"

# Non-critical check: api.github.com should be reachable if GitHub ranges were loaded
if [[ "$GITHUB_RANGES_OK" == "true" ]]; then
	log "  Checking api.github.com is reachable..."
	if curl -sf --max-time 10 "https://api.github.com" >/dev/null 2>&1; then
		log "  api.github.com is reachable — GitHub connectivity confirmed"
	else
		warn "api.github.com is not reachable despite GitHub IP ranges being loaded"
	fi
fi

log "Firewall initialization complete."
