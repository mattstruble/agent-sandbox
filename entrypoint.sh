#!/usr/bin/env bash
set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "[entrypoint] $*" >&2; }
warn() { echo "[entrypoint] WARNING: $*" >&2; }
die() {
	echo "[entrypoint] ERROR: $*" >&2
	exit 1
}

# ─── Validate $AGENT ──────────────────────────────────────────────────────────

if [[ -z "${AGENT:-}" ]]; then
	die "AGENT environment variable is not set. Must be 'opencode' or 'claude'."
fi

if [[ "$AGENT" != "opencode" && "$AGENT" != "claude" ]]; then
	die "AGENT='$AGENT' is not valid. Must be 'opencode' or 'claude'."
fi

log "Starting sandbox for agent: $AGENT"

# ─── Phase 1: Root operations ─────────────────────────────────────────────────
# The container starts as root so the firewall can be established without sudo.
# After firewall setup, we re-exec this script as the sandbox user via gosu.

if [[ -z "${_SANDBOX_PHASE2:-}" ]]; then
	log "Running firewall setup..."
	/init-firewall.sh
	log "Firewall established."

	log "Starting chronyd..."
	if chronyd; then
		log "chronyd started."
	else
		warn "chronyd failed to start — continuing without time synchronization."
	fi

	# Proxy setup (CA generation, trust store, start proxy, modify iptables)
	# Normalize PROXY_ENABLED to lowercase for canonical comparison
	_proxy_enabled=$(echo "${PROXY_ENABLED:-true}" | tr '[:upper:]' '[:lower:]')
	if [[ "$_proxy_enabled" == "true" ]]; then
		# Read proxy port (must match init-proxy.sh default)
		_proxy_port="${PROXY_PORT:-8080}"

		log "Running proxy setup..."
		/init-proxy.sh
		log "Proxy established."

		# Modify iptables to force traffic through proxy.
		# The proxy runs as the 'proxyuser' system user (uid from Containerfile).
		# Use --uid-owner (not --pid-owner, which was removed in Linux 3.14).
		log "Redirecting HTTP/HTTPS through proxy..."

		PROXY_UID=$(id -u proxyuser 2>/dev/null) || die "proxyuser system user not found — cannot configure iptables"

		# Remove the existing broad ACCEPT rules for 80/443 installed by init-firewall.sh.
		# Use || true: the rules may have already been removed.
		iptables -D OUTPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
		iptables -D OUTPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true

		# Allow loopback traffic to the proxy port.
		# NOTE: Rule 1 (-o lo -j ACCEPT) already covers all loopback traffic,
		# so this is defense-in-depth in case the loopback rule is ever removed.
		iptables -I OUTPUT 3 -o lo -p tcp --dport "$_proxy_port" -j ACCEPT

		# Allow the proxy user to reach 80/443 upstream (before the catch-all REJECT)
		iptables -I OUTPUT 4 -p tcp --dport 80 -m owner --uid-owner "$PROXY_UID" -j ACCEPT
		iptables -I OUTPUT 5 -p tcp --dport 443 -m owner --uid-owner "$PROXY_UID" -j ACCEPT

		# Drop all other direct 80/443 traffic (forces through proxy).
		# Inserted before the catch-all REJECT so they match first for 80/443.
		iptables -I OUTPUT 6 -p tcp --dport 80 -j DROP
		iptables -I OUTPUT 7 -p tcp --dport 443 -j DROP

		log "iptables updated: direct 80/443 blocked, proxy-only access (proxy uid=$PROXY_UID)."

		# Delete CA private key from disk — proxy has already loaded it into memory.
		rm -f /etc/sandbox-proxy/ca.key
	else
		log "Proxy disabled — skipping proxy setup."
	fi

	# Re-exec as sandbox user; _SANDBOX_PHASE2 prevents infinite loop
	log "Dropping to sandbox user..."
	exec gosu sandbox env _SANDBOX_PHASE2=1 "$0"
fi

# ─── Phase 2: Sandbox operations (runs as sandbox user) ──────────────────────

# ─── Step 2: Stage configs from read-only mounts to writable locations ────────

if [[ -d /host-config/opencode ]]; then
	log "Staging opencode config..."
	mkdir -p ~/.config/opencode
	if cp -a /host-config/opencode/. ~/.config/opencode/; then
		log "opencode config staged."
	else
		warn "Failed to copy opencode config — continuing without it."
	fi
else
	log "No opencode host config mounted, skipping."
fi

if [[ -d /host-config/claude ]]; then
	log "Staging claude config..."
	mkdir -p ~/.claude
	if cp -a /host-config/claude/. ~/.claude/; then
		log "claude config staged."
	else
		warn "Failed to copy claude config — continuing without it."
	fi
else
	log "No claude host config mounted, skipping."
fi

# ─── Step 3: Apply OpenCode permission overrides ──────────────────────────────

OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
log "Applying opencode permission overrides to $OPENCODE_CONFIG..."

mkdir -p ~/.config/opencode

if [[ -f "$OPENCODE_CONFIG" ]]; then
	# File exists — merge permission fields without removing other content
	tmp=$(mktemp "$(dirname "$OPENCODE_CONFIG")/config.json.XXXXXX")
	if jq '
    .permission.bash     = "allow" |
    .permission.edit     = "allow" |
    .permission.read     = "allow" |
    .permission.grep     = "allow" |
    .permission.webfetch = "allow"
  ' "$OPENCODE_CONFIG" >"$tmp"; then
		if mv -f "$tmp" "$OPENCODE_CONFIG"; then
			log "Permission overrides applied."
		else
			rm -f "$tmp"
			warn "mv failed — continuing without permission overrides."
		fi
	else
		rm -f "$tmp"
		warn "jq failed to patch $OPENCODE_CONFIG — continuing without permission overrides."
	fi
else
	# File does not exist — create it with just the permission object
	cat >"$OPENCODE_CONFIG" <<'EOF'
{
  "permission": {
    "bash": "allow",
    "edit": "allow",
    "read": "allow",
    "grep": "allow",
    "webfetch": "allow"
  }
}
EOF
	log "Created $OPENCODE_CONFIG with permission overrides."
fi

# ─── Step 4: Initialize rtk for the active agent ──────────────────────────────

log "Running rtk init for agent: $AGENT..."

if [[ "$AGENT" == "opencode" ]]; then
	if rtk init -g --opencode; then
		log "rtk init completed for opencode."
	else
		warn "rtk init failed for opencode — continuing without rtk."
	fi
else
	if rtk init -g; then
		log "rtk init completed for claude."
	else
		warn "rtk init failed for claude — continuing without rtk."
	fi
fi

# ─── Step 5: Set proxy environment variables ─────────────────────────────────

_proxy_enabled=$(echo "${PROXY_ENABLED:-true}" | tr '[:upper:]' '[:lower:]')
if [[ "$_proxy_enabled" == "true" ]]; then
	_proxy_port="${PROXY_PORT:-8080}"
	export HTTP_PROXY="http://127.0.0.1:${_proxy_port}"
	export HTTPS_PROXY="http://127.0.0.1:${_proxy_port}"
	export NO_PROXY="localhost,127.0.0.1"
	# Node.js (Claude Code) needs the system CA bundle to trust the proxy CA
	export NODE_EXTRA_CA_CERTS="/etc/ssl/certs/ca-certificates.crt"
	log "Proxy environment set: HTTP_PROXY=$HTTP_PROXY"
else
	log "Proxy disabled — no proxy env vars set."
fi

# Clean up proxy configuration env vars — the agent does not need them
unset PROXY_ENABLED PROXY_ALLOW_POST_EXTRA PROXY_EXTRA_CA_CERTS 2>/dev/null || true

# ─── Step 6: Exec the agent ───────────────────────────────────────────────────

cd /workspace || die "/workspace is not accessible — check that the workspace mount succeeded."

if [[ "$AGENT" == "opencode" ]]; then
	# opencode installs to ~/.opencode/bin/, not onto $PATH
	OPENCODE_BIN="$HOME/.opencode/bin/opencode"
	if [[ ! -x "$OPENCODE_BIN" ]]; then
		die "opencode binary not found at $OPENCODE_BIN"
	fi
	log "Exec'ing opencode..."
	exec "$OPENCODE_BIN"
else
	if ! command -v claude &>/dev/null; then
		die "claude binary not found in PATH"
	fi
	log "Exec'ing claude..."
	exec claude --dangerously-skip-permissions
fi
