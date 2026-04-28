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
	die "AGENT environment variable is not set. Must be 'opencode'."
fi

if [[ "$AGENT" != "opencode" ]]; then
	die "AGENT='$AGENT' is not valid. Must be 'opencode'."
fi

log "Starting sandbox for agent: $AGENT"

# ─── Phase 1: Root operations ─────────────────────────────────────────────────
# The container starts as root so the firewall can be established without sudo.
# After firewall setup, we re-exec this script as the sandbox user via su-exec.
# _SANDBOX_PHASE2 prevents infinite re-exec; phase guard uses the env var rather
# than id -u because su-exec drops privileges before re-exec.

if [[ -z "${_SANDBOX_PHASE2:-}" ]]; then
	log "Running firewall setup..."
	/init-firewall.sh
	log "Firewall established."

	log "Starting chronyd..."
	# Run chronyd in foreground mode, backgrounded by the shell. The background
	# job always returns exit code 0 to the shell, so we cannot detect immediate
	# failure here — if chronyd exits (e.g., missing SYS_TIME cap), it does so
	# silently. Time synchronization is non-critical; the container continues.
	#
	# Orphan note: chronyd is backgrounded here (Phase 1, as root) because it
	# requires SYS_TIME capability. After `exec su-exec` below replaces this
	# shell process, chronyd becomes an orphan — it has no parent process to
	# reap it. Container runtimes run as PID 1 and act as a reaper for orphaned
	# processes in --init containers (Docker/Podman with --init flag). Time sync
	# is best-effort: if chronyd dies, the container continues normally.
	chronyd -n &
	log "chronyd launched in background."

	# Re-exec as sandbox user; _SANDBOX_PHASE2 prevents infinite loop
	log "Dropping to sandbox user..."
	exec su-exec sandbox env _SANDBOX_PHASE2=1 "$0"
fi

# ─── Phase 2: Sandbox operations (runs as sandbox user) ──────────────────────
# Step numbers correspond to the entrypoint sequence documented in DESIGN.md.
# Steps 1-3 are Phase 1 (firewall, chronyd, su-exec drop); steps 4-8 are here.

# ─── Step 4: Stage configs from read-only mounts to writable locations ────────

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

# ─── Step 5: Append Nix usage instructions to agent prompt files ──────────────
# Tells the agent to use `nix run`/`nix shell` for tools not on PATH.
# Appended after staging so the host file content is preserved.
# Creates the file if it does not exist (e.g., host had no config mounted).

NIX_INSTRUCTIONS_FILE="/etc/agent-sandbox/nix-instructions.md"
if [[ -f "$NIX_INSTRUCTIONS_FILE" ]]; then
	NIX_INSTRUCTIONS=$(cat "$NIX_INSTRUCTIONS_FILE")
else
	warn "Nix instructions file not found at $NIX_INSTRUCTIONS_FILE"
	NIX_INSTRUCTIONS=""
fi

mkdir -p ~/.config/opencode
if [[ -n "$NIX_INSTRUCTIONS" ]]; then
	if ! printf '\n# --- Added by agent-sandbox ---\n%s\n' "$NIX_INSTRUCTIONS" >>~/.config/opencode/AGENTS.md; then
		warn "Failed to append Nix instructions to AGENTS.md — continuing."
	else
		log "Nix usage instructions appended to AGENTS.md."
	fi
fi

# ─── Step 6: Apply OpenCode sandbox config overrides ──────────────────────────

OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
SANDBOX_CONFIG="/etc/agent-sandbox/opencode-config.json"
log "Applying sandbox opencode overrides to $OPENCODE_CONFIG..."

mkdir -p ~/.config/opencode

# The sandbox is the security boundary. `permission` and `lsp` are replaced
# wholesale — a user-supplied `lsp.<name>.command` could spawn arbitrary
# binaries, and a user-supplied `permission` could remove the
# `external_directory: deny` mount defense. Any failure that would leave the
# user's config in place (and therefore bypass these overrides) must fail the
# container startup rather than warn-and-continue.
if [[ ! -f "$SANDBOX_CONFIG" ]]; then
	die "Sandbox config not found at $SANDBOX_CONFIG"
fi

if ! jq -e '.permission and .lsp' "$SANDBOX_CONFIG" >/dev/null; then
	die "Sandbox config at $SANDBOX_CONFIG is missing required .permission or .lsp keys"
fi

if [[ -f "$OPENCODE_CONFIG" ]]; then
	tmp=$(mktemp "$(dirname "$OPENCODE_CONFIG")/config.json.XXXXXX") ||
		die "mktemp failed — cannot apply sandbox overrides."

	if ! jq --slurpfile sandbox "$SANDBOX_CONFIG" \
		'.permission = $sandbox[0].permission | .lsp = $sandbox[0].lsp' \
		"$OPENCODE_CONFIG" >"$tmp"; then
		rm -f "$tmp"
		die "jq failed to patch $OPENCODE_CONFIG — cannot apply sandbox overrides."
	fi

	if ! mv -f "$tmp" "$OPENCODE_CONFIG"; then
		rm -f "$tmp"
		die "mv failed — cannot apply sandbox overrides."
	fi
	log "Sandbox overrides applied."
else
	cp "$SANDBOX_CONFIG" "$OPENCODE_CONFIG" ||
		die "cp failed — cannot create $OPENCODE_CONFIG from sandbox defaults."
	log "Created $OPENCODE_CONFIG from sandbox defaults."
fi

# ─── Step 7: Initialize rtk for the active agent ──────────────────────────────

log "Running rtk init for agent: $AGENT..."

if rtk init -g --opencode; then
	log "rtk init completed for opencode."
else
	warn "rtk init failed for opencode — continuing without rtk."
fi

# ─── Step 8: Exec the agent ───────────────────────────────────────────────────

if [[ -z "${SANDBOX_WORKSPACE:-}" ]]; then
	die "SANDBOX_WORKSPACE environment variable is not set."
fi
cd "$SANDBOX_WORKSPACE" || die "'$SANDBOX_WORKSPACE' is not accessible — check that the workspace mount succeeded."

if ! command -v opencode &>/dev/null; then
	die "opencode binary not found in PATH"
fi
log "Exec'ing opencode..."
exec opencode
