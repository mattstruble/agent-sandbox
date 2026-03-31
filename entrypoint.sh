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

# ─── Step 5: Exec the agent ───────────────────────────────────────────────────

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
