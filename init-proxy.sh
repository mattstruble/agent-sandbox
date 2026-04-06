#!/usr/bin/env bash
# init-proxy.sh — proxy setup for agent-sandbox containers
# Runs as root during entrypoint Phase 1, after firewall setup.
#
# Responsibilities:
#   1. Generate a fresh CA certificate and private key
#   2. Install the CA + any extra corporate certs into the system trust store
#   3. Assemble the whitelist from API keys, MCP configs, and user config
#   4. Start the proxy binary in the background (as proxyuser)
#   5. Health-check the proxy before returning

set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[proxy] $*" >&2; }
warn() { echo "[proxy] WARNING: $*" >&2; }
err() { echo "[proxy] ERROR: $*" >&2; }

PROXY_PORT="${PROXY_PORT:-8080}"
PROXY_CA_DIR="/etc/sandbox-proxy"
PROXY_CA_CERT="${PROXY_CA_DIR}/ca.crt"
PROXY_CA_KEY="${PROXY_CA_DIR}/ca.key"

# Validate PROXY_PORT is numeric to prevent shell injection in health check
if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
	err "Invalid PROXY_PORT: '$PROXY_PORT' — must be a positive integer"
	exit 1
fi

# ---------------------------------------------------------------------------
# 1. CA Certificate Generation
# ---------------------------------------------------------------------------

generate_ca() {
	mkdir -p "$PROXY_CA_DIR"
	chmod 700 "$PROXY_CA_DIR"

	log "Generating CA certificate..."
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-keyout "$PROXY_CA_KEY" \
		-out "$PROXY_CA_CERT" \
		-days 1 \
		-nodes \
		-subj "/CN=agent-sandbox proxy CA"

	# Verify openssl produced non-empty output files
	if [[ ! -s "$PROXY_CA_CERT" ]]; then
		err "openssl produced empty CA certificate at $PROXY_CA_CERT"
		return 1
	fi
	if [[ ! -s "$PROXY_CA_KEY" ]]; then
		err "openssl produced empty CA key at $PROXY_CA_KEY"
		return 1
	fi

	# Make key readable by proxyuser (who runs the proxy binary)
	chmod 640 "$PROXY_CA_KEY"
	chown root:proxyuser "$PROXY_CA_KEY"
	chmod 644 "$PROXY_CA_CERT"
	log "CA certificate generated at $PROXY_CA_CERT"
}

# ---------------------------------------------------------------------------
# 2. Install CA into system trust store
# ---------------------------------------------------------------------------

install_ca_certs() {
	# Install generated CA
	cp "$PROXY_CA_CERT" /usr/local/share/ca-certificates/sandbox-proxy-ca.crt

	# Install extra corporate CA certs if provided
	if [[ -n "${PROXY_EXTRA_CA_CERTS:-}" ]]; then
		local IFS=','
		local i=0
		for cert_path in $PROXY_EXTRA_CA_CERTS; do
			if [[ ! -f "$cert_path" ]]; then
				warn "Extra CA cert not found, skipping: $cert_path"
				continue
			fi
			# Validate: must be a regular file (not symlink to sensitive file)
			if [[ -L "$cert_path" ]]; then
				warn "Extra CA cert is a symlink, skipping for safety: $cert_path"
				continue
			fi
			# Validate: must end in .crt or .pem
			case "$cert_path" in
				*.crt|*.pem) ;;
				*) warn "Extra CA cert has unexpected extension (expected .crt or .pem), skipping: $cert_path"; continue ;;
			esac
			# Validate: must be parseable as a PEM certificate
			if ! openssl x509 -noout -in "$cert_path" 2>/dev/null; then
				warn "Extra CA cert is not a valid PEM certificate, skipping: $cert_path"
				continue
			fi
			cp "$cert_path" "/usr/local/share/ca-certificates/extra-ca-${i}.crt"
			log "Installed extra CA cert: $cert_path"
			i=$((i + 1))
		done
	fi

	update-ca-certificates || {
		err "update-ca-certificates failed"
		return 1
	}
	log "System trust store updated."
}

# ---------------------------------------------------------------------------
# 3. Whitelist Assembly
# ---------------------------------------------------------------------------

# Builds the PROXY_ALLOW_POST env var from:
#   - Auto-detected API key -> domain mappings
#   - MCP server URLs from agent configs
#   - User-configured extra domains (PROXY_ALLOW_POST_EXTRA)
#   - models.dev (always included)
#
# Prints the assembled comma-separated whitelist to stdout.

assemble_whitelist() {
	local domains=()

	# Always include models.dev
	domains+=("models.dev")

	# Auto-detect from API keys
	if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
		domains+=("api.anthropic.com")
	fi
	if [[ -n "${OPENAI_API_KEY:-}" ]]; then
		domains+=("api.openai.com")
	fi
	if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
		domains+=("openrouter.ai")
	fi
	if [[ -n "${MISTRAL_API_KEY:-}" ]]; then
		domains+=("api.mistral.com")
	fi
	if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
		domains+=("bedrock-runtime.*.amazonaws.com")
	fi

	# Parse MCP server URLs from Claude config (host-config mount, available in Phase 1)
	_parse_mcp_domains "/host-config/claude/settings.json" domains

	# Parse MCP server URLs from OpenCode config (host-config mount, available in Phase 1)
	_parse_mcp_domains "/host-config/opencode/opencode.json" domains

	# Add user-configured extra domains
	if [[ -n "${PROXY_ALLOW_POST_EXTRA:-}" ]]; then
		local IFS=','
		for domain in $PROXY_ALLOW_POST_EXTRA; do
			domain=$(echo "$domain" | tr -d '[:space:]')
			[[ -n "$domain" ]] && domains+=("$domain")
		done
	fi

	# Deduplicate and join using an associative array
	declare -A _seen
	local result=""
	for d in "${domains[@]}"; do
		[[ -z "$d" ]] && continue
		if [[ -z "${_seen[$d]+x}" ]]; then
			_seen[$d]=1
			if [[ -n "$result" ]]; then
				result="${result},${d}"
			else
				result="$d"
			fi
		fi
	done

	echo "$result"
}

# Parses MCP server URLs from a JSON config file and appends their domains
# to the array variable whose name is passed as $2.
# Non-fatal: silently returns if the file doesn't exist or can't be parsed.
_parse_mcp_domains() {
	local config_file="$1"
	local -n _domains_ref=$2  # nameref to caller's array

	[[ -f "$config_file" ]] || return 0

	# Extract URLs from mcpServers entries using jq
	# Claude format: .mcpServers.<name>.url
	# OpenCode format: .mcp.<name>.url
	local urls
	urls=$(jq -r '
		(.mcpServers // {} | to_entries[] | .value.url // empty),
		(.mcp // {} | to_entries[] | .value.url // empty)
	' "$config_file" 2>/dev/null || true)

	local url
	while IFS= read -r url; do
		[[ -z "$url" ]] && continue
		# Extract hostname using python3 urlparse. The URL is passed as a
		# positional argument (sys.argv[1]) — never interpolated into the
		# source string — to prevent code injection via crafted URLs.
		local domain
		domain=$(python3 -c "import sys; from urllib.parse import urlparse; h = urlparse(sys.argv[1]).hostname; print(h if h else '')" "$url" 2>/dev/null || true)
		# Validate hostname: only allow DNS-safe characters and wildcards
		if [[ -n "$domain" ]] && [[ "$domain" =~ ^[a-zA-Z0-9*][a-zA-Z0-9.*-]*$ ]]; then
			_domains_ref+=("$domain")
		fi
	done <<< "$urls"
}

# ---------------------------------------------------------------------------
# 4. Start Proxy
# ---------------------------------------------------------------------------

start_proxy() {
	local whitelist="$1"

	log "Starting sandbox-proxy on port $PROXY_PORT..."

	# Start the proxy as the dedicated proxyuser. iptables --uid-owner rules
	# allow only this user to make upstream 80/443 connections.
	PROXY_ALLOW_POST="$whitelist" \
	PROXY_CA_CERT="$PROXY_CA_CERT" \
	PROXY_CA_KEY="$PROXY_CA_KEY" \
	PROXY_LISTEN_ADDR=":${PROXY_PORT}" \
		gosu proxyuser /usr/local/bin/sandbox-proxy &

	local proxy_pid=$!

	# Health check: wait for proxy to accept connections
	local retries=0
	local max_retries=30
	while ! bash -c "echo >/dev/tcp/127.0.0.1/${PROXY_PORT}" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ $retries -ge $max_retries ]]; then
			err "Proxy failed to start after ${max_retries} retries"
			kill "$proxy_pid" 2>/dev/null || true
			return 1
		fi
		# Check if process is still alive
		if ! kill -0 "$proxy_pid" 2>/dev/null; then
			err "Proxy process died during startup"
			return 1
		fi
		sleep 0.1
	done

	log "Proxy started (PID $proxy_pid)."
}

# ---------------------------------------------------------------------------
# 5. Main (called from entrypoint.sh)
# ---------------------------------------------------------------------------

proxy_main() {
	# Normalize to lowercase for canonical comparison
	local _enabled
	_enabled=$(echo "${PROXY_ENABLED:-true}" | tr '[:upper:]' '[:lower:]')
	if [[ "$_enabled" != "true" ]]; then
		log "Proxy is disabled (PROXY_ENABLED=${PROXY_ENABLED:-}). Skipping proxy setup."
		return 0
	fi

	generate_ca
	install_ca_certs

	local whitelist
	whitelist=$(assemble_whitelist)

	start_proxy "$whitelist"
}

# Entry point guard — only run proxy_main() when executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	proxy_main
fi
