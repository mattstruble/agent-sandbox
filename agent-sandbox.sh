#!/usr/bin/env bash
set -euo pipefail

# Require bash 4.0+ for associative arrays and ${var,,} case-folding.
# On macOS the system bash is 3.2; the Nix wrapper substitutes a bash 5.x shebang.
# This check provides a clear error if the script is invoked with an older bash.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
	echo "[agent-sandbox] ERROR: bash 4.0 or newer is required (found ${BASH_VERSION}). Install GNU bash via Nix or Homebrew." >&2
	exit 1
fi

SHARE_DIR="${AGENT_SANDBOX_SHARE_DIR:-@SHARE_DIR@}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[agent-sandbox] $*" >&2; }
warn() { echo "[agent-sandbox] WARNING: $*" >&2; }
err() { echo "[agent-sandbox] ERROR: $*" >&2; }
die() {
	err "$*"
	exit 1
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------

usage() {
	cat >&2 <<'EOF'
Usage: agent-sandbox [OPTIONS] [WORKSPACE]

Options:
  -a, --agent <name>       Agent to run: opencode (default) or claude
  -b, --build              Force rebuild image before running
  --follow-symlinks        Mount depth-1 symlink targets from the workspace (skips dotfile dirs)
  --follow-all-symlinks    Like --follow-symlinks but includes dotfile directories
  --mount <path>           Mount an extra host path read-only (repeatable; append :rw for read-write)
  --no-ssh                 Skip SSH agent socket forwarding
  --list                   List running agent-sandbox containers
  --stop                   Stop sandbox(es) for the given/current workspace
  --prune                  Remove old agent-sandbox images, keeping only the current hash
  -h, --help               Show help

Arguments:
  WORKSPACE                Workspace directory to mount (default: $PWD)

Examples:
  agent-sandbox                        # opencode on current directory
  agent-sandbox --agent claude         # claude-code on current directory
  agent-sandbox ~/projects/foo         # opencode on ~/projects/foo
  agent-sandbox --agent claude ~/work  # claude-code on ~/work
  agent-sandbox --follow-symlinks      # mount workspace symlink targets
  agent-sandbox --mount ~/.kube        # mount kubectl config read-only
  agent-sandbox --mount ~/data:rw      # mount a directory read-write
  agent-sandbox --no-ssh               # skip SSH agent forwarding
  agent-sandbox --build                # force image rebuild, then run
  agent-sandbox --list                 # show running sandboxes
  agent-sandbox --stop                 # stop all sandboxes for current directory
  agent-sandbox --stop --agent claude  # stop only the claude sandbox
  agent-sandbox --stop ~/projects/foo  # stop all sandboxes for that path
  agent-sandbox --prune                # remove stale images
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

OPT_AGENT=""
OPT_AGENT_EXPLICIT="" # set only when --agent is passed on CLI; used for --stop dispatch
OPT_BUILD=false
OPT_FOLLOW_SYMLINKS=false
OPT_FOLLOW_ALL_SYMLINKS=false
OPT_NO_SSH=false
OPT_LIST=false
OPT_STOP=false
OPT_PRUNE=false
OPT_HELP=false
OPT_EXTRA_MOUNTS=()
OPT_WORKSPACE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-a | --agent)
		[[ $# -lt 2 ]] && die "--agent requires an argument"
		OPT_AGENT="$2"
		OPT_AGENT_EXPLICIT="$2"
		shift 2
		;;
	-b | --build)
		OPT_BUILD=true
		shift
		;;
	--follow-symlinks)
		OPT_FOLLOW_SYMLINKS=true
		shift
		;;
	--follow-all-symlinks)
		OPT_FOLLOW_ALL_SYMLINKS=true
		OPT_FOLLOW_SYMLINKS=true
		shift
		;;
	--mount)
		[[ $# -lt 2 ]] && die "--mount requires an argument"
		OPT_EXTRA_MOUNTS+=("$2")
		shift 2
		;;
	--no-ssh)
		OPT_NO_SSH=true
		shift
		;;
	--list)
		OPT_LIST=true
		shift
		;;
	--stop)
		OPT_STOP=true
		shift
		;;
	--prune)
		OPT_PRUNE=true
		shift
		;;
	-h | --help)
		OPT_HELP=true
		shift
		;;
	--)
		shift
		break
		;;
	-*)
		die "Unknown option: $1"
		;;
	*)
		if [[ -z "$OPT_WORKSPACE" ]]; then
			OPT_WORKSPACE="$1"
		else
			die "Unexpected argument: $1"
		fi
		shift
		;;
	esac
done

# ---------------------------------------------------------------------------
# Dispatch: --help (early exit)
# ---------------------------------------------------------------------------

if $OPT_HELP; then
	usage
	exit 0
fi

# ---------------------------------------------------------------------------
# Config file parsing (~/.config/agent-sandbox/config.toml)
# ---------------------------------------------------------------------------

CONFIG_FILE="${HOME}/.config/agent-sandbox/config.toml"

# Config values with defaults
CFG_AGENT="opencode"
CFG_EXTRA_DOMAINS=()
CFG_EXTRA_VARS=()
CFG_FOLLOW_ALL_SYMLINKS=false
CFG_EXTRA_PATHS=()
CFG_MEMORY="8g"
CFG_CPUS=4

parse_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		return 0
	fi

	# Verify dasel is available
	if ! command -v dasel &>/dev/null; then
		die "dasel is required to parse config.toml but was not found in PATH"
	fi

	# Test that the file is parseable (dasel exits non-zero on malformed TOML)
	if ! dasel -f "$CONFIG_FILE" -r toml . &>/dev/null; then
		die "Config file '$CONFIG_FILE' is malformed TOML — fix or remove it"
	fi

	# [defaults] agent
	local val
	val=$(dasel -f "$CONFIG_FILE" -r toml -w plain 'defaults.agent' 2>/dev/null || true)
	if [[ -n "$val" ]]; then
		if [[ "$val" != "opencode" && "$val" != "claude" ]]; then
			die "Config error: defaults.agent must be 'opencode' or 'claude', got '$val'"
		fi
		CFG_AGENT="$val"
	fi

	# [network] extra_domains (array)
	local domains_json
	domains_json=$(dasel -f "$CONFIG_FILE" -r toml -w json 'network.extra_domains' 2>/dev/null || true)
	if [[ -n "$domains_json" && "$domains_json" != "null" ]]; then
		# Require multi-label FQDNs (at least one dot) to match init-firewall.sh's HOSTNAME_REGEX.
		# Rejects single-label names (e.g. "localhost"), trailing dots, and consecutive dots.
		local domain_regex='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'
		while IFS= read -r domain; do
			[[ -z "$domain" ]] && continue
			if ! [[ "$domain" =~ $domain_regex ]]; then
				die "Config error: invalid domain in network.extra_domains: '$domain' (must be a valid multi-label FQDN)"
			fi
			CFG_EXTRA_DOMAINS+=("$domain")
		done < <(echo "$domains_json" | dasel -r json -w plain 'all()' 2>/dev/null || true)
	fi

	# [env] extra_vars (array)
	local vars_json
	vars_json=$(dasel -f "$CONFIG_FILE" -r toml -w json 'env.extra_vars' 2>/dev/null || true)
	if [[ -n "$vars_json" && "$vars_json" != "null" ]]; then
		local var_regex='^[A-Za-z_][A-Za-z0-9_]*$'
		while IFS= read -r varname; do
			[[ -z "$varname" ]] && continue
			if ! [[ "$varname" =~ $var_regex ]]; then
				die "Config error: invalid variable name in env.extra_vars: '$varname'"
			fi
			CFG_EXTRA_VARS+=("$varname")
		done < <(echo "$vars_json" | dasel -r json -w plain 'all()' 2>/dev/null || true)
	fi

	# [workspace] follow_all_symlinks (boolean)
	val=$(dasel -f "$CONFIG_FILE" -r toml -w plain 'workspace.follow_all_symlinks' 2>/dev/null || true)
	if [[ "$val" == "true" ]]; then
		CFG_FOLLOW_ALL_SYMLINKS=true
	fi

	# [mounts] extra_paths (array)
	local paths_json
	paths_json=$(dasel -f "$CONFIG_FILE" -r toml -w json 'mounts.extra_paths' 2>/dev/null || true)
	if [[ -n "$paths_json" && "$paths_json" != "null" ]]; then
		while IFS= read -r mpath; do
			[[ -z "$mpath" ]] && continue
			CFG_EXTRA_PATHS+=("$mpath")
		done < <(echo "$paths_json" | dasel -r json -w plain 'all()' 2>/dev/null || true)
	fi

	# [resources] memory
	val=$(dasel -f "$CONFIG_FILE" -r toml -w plain 'resources.memory' 2>/dev/null || true)
	if [[ -n "$val" ]]; then
		CFG_MEMORY="$val"
	fi

	# [resources] cpus
	val=$(dasel -f "$CONFIG_FILE" -r toml -w plain 'resources.cpus' 2>/dev/null || true)
	if [[ -n "$val" ]]; then
		if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -le 0 ]]; then
			die "Config error: resources.cpus must be a positive integer, got '$val'"
		fi
		CFG_CPUS="$val"
	fi
}

parse_config

# Apply config defaults to CLI options (CLI takes precedence)
if [[ -z "$OPT_AGENT" ]]; then
	OPT_AGENT="$CFG_AGENT"
fi

# Validate agent value
if [[ "$OPT_AGENT" != "opencode" && "$OPT_AGENT" != "claude" ]]; then
	die "--agent must be 'opencode' or 'claude', got '$OPT_AGENT'"
fi

# Apply config follow_all_symlinks
if $CFG_FOLLOW_ALL_SYMLINKS; then
	OPT_FOLLOW_ALL_SYMLINKS=true
	OPT_FOLLOW_SYMLINKS=true
fi

# ---------------------------------------------------------------------------
# Runtime detection
# ---------------------------------------------------------------------------

detect_runtime() {
	if [[ -n "${AGENT_SANDBOX_RUNTIME:-}" ]]; then
		RUNTIME="$AGENT_SANDBOX_RUNTIME"
		# Allowlist: only podman or docker are accepted to prevent arbitrary command execution
		if [[ "$RUNTIME" != "podman" && "$RUNTIME" != "docker" ]]; then
			die "AGENT_SANDBOX_RUNTIME must be 'podman' or 'docker', got '$RUNTIME'"
		fi
		if ! command -v "$RUNTIME" &>/dev/null; then
			die "AGENT_SANDBOX_RUNTIME='$RUNTIME' but '$RUNTIME' was not found in PATH"
		fi
		return
	fi

	if command -v podman &>/dev/null; then
		RUNTIME="podman"
	elif command -v docker &>/dev/null; then
		RUNTIME="docker"
	else
		die "Neither 'podman' nor 'docker' found in PATH. Install one or set AGENT_SANDBOX_RUNTIME."
	fi
}

RUNTIME=""
detect_runtime

USERNS_FLAG=""
if [[ "$RUNTIME" == "podman" ]]; then
	USERNS_FLAG="--userns=keep-id"
fi

# ---------------------------------------------------------------------------
# Mount :z suffix (Linux only)
# ---------------------------------------------------------------------------

# The :z option relabels the mount for container access; safe on non-SELinux Linux too.
# Not needed on macOS where containers run in a Linux VM.
MOUNT_Z=""
if [[ "$(uname -s)" == "Linux" ]]; then
	MOUNT_Z=",z"
fi

# ---------------------------------------------------------------------------
# Workspace validation (needed for --stop, --list uses current dir)
# ---------------------------------------------------------------------------

resolve_workspace() {
	local ws="${1:-}"
	# Use PWD if no workspace provided or empty
	[[ -z "$ws" ]] && ws="$PWD"
	# Expand ~ if present
	ws="${ws/#\~/$HOME}"
	local resolved
	if ! resolved=$(realpath "$ws" 2>/dev/null); then
		die "Cannot resolve workspace path: $ws"
	fi
	if [[ ! -d "$resolved" ]]; then
		die "Workspace '$resolved' does not exist or is not a directory"
	fi
	echo "$resolved"
}

# ---------------------------------------------------------------------------
# Container naming
# ---------------------------------------------------------------------------

sanitize_basename() {
	local name="$1"
	# Lowercase
	name="${name,,}"
	# Strip non-[a-z0-9-] characters
	name="${name//[^a-z0-9-]/}"
	echo "$name"
}

compute_workspace_hash() {
	local workspace="$1"
	# First 6 chars of sha256 of the absolute workspace path
	printf '%s' "$workspace" | sha256sum | cut -c1-6
}

compute_container_name() {
	local agent="$1"
	local workspace="$2"
	local basename
	basename=$(sanitize_basename "$(basename "$workspace")")
	local hash
	hash=$(compute_workspace_hash "$workspace")
	echo "agent-sandbox-${agent}-${basename}-${hash}"
}

# ---------------------------------------------------------------------------
# Containerfile hash / image management
# ---------------------------------------------------------------------------

CONTAINERFILE="${SHARE_DIR}/Containerfile"

compute_containerfile_hash() {
	if [[ ! -f "$CONTAINERFILE" ]]; then
		die "Containerfile not found at '$CONTAINERFILE'. Is SHARE_DIR set correctly?"
	fi
	sha256sum "$CONTAINERFILE" | cut -c1-64
}

image_exists() {
	local tag="$1"
	local result
	result=$("$RUNTIME" images -q "agent-sandbox:${tag}" 2>/dev/null || true)
	[[ -n "$result" ]]
}

build_image() {
	local tag="$1"
	log "Building image agent-sandbox:${tag}..."
	"$RUNTIME" build -t "agent-sandbox:${tag}" -f "$CONTAINERFILE" "$SHARE_DIR"
	log "Image built: agent-sandbox:${tag}"
}

# ---------------------------------------------------------------------------
# Dispatch: --list
# ---------------------------------------------------------------------------

do_list() {
	"$RUNTIME" ps --filter "name=agent-sandbox-" --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}"
	exit 0
}

# ---------------------------------------------------------------------------
# Dispatch: --stop
# ---------------------------------------------------------------------------

do_stop() {
	local workspace="$1"
	local agent="${2:-}"

	local ws
	ws=$(resolve_workspace "$workspace")
	local basename
	basename=$(sanitize_basename "$(basename "$ws")")
	local hash
	hash=$(compute_workspace_hash "$ws")

	if [[ -n "$agent" ]]; then
		# Stop specific agent container
		local container_name
		container_name=$(compute_container_name "$agent" "$ws")
		# Use || true: if the container already stopped between check and stop, exit 0 silently
		"$RUNTIME" stop "$container_name" 2>/dev/null || true
		log "Stopped container: $container_name (or it was already stopped)"
	else
		# Stop all agent-sandbox containers for this workspace (any agent)
		local pattern="agent-sandbox-.*-${basename}-${hash}"
		local containers
		containers=$("$RUNTIME" ps --filter "name=agent-sandbox-" --format "{{.Names}}" 2>/dev/null | grep -E "^${pattern}$" || true)
		if [[ -n "$containers" ]]; then
			while IFS= read -r cname; do
				[[ -z "$cname" ]] && continue
				log "Stopping container: $cname"
				# Use || true: container may have exited between listing and stopping
				"$RUNTIME" stop "$cname" 2>/dev/null || true
			done <<<"$containers"
		fi
	fi
	exit 0
}

# ---------------------------------------------------------------------------
# Dispatch: --prune
# ---------------------------------------------------------------------------

do_prune() {
	local current_hash
	current_hash=$(compute_containerfile_hash)

	log "Current Containerfile hash: ${current_hash}"
	log "Pruning old agent-sandbox images..."

	# List all agent-sandbox images
	local images
	images=$("$RUNTIME" images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep "^agent-sandbox:" || true)

	if [[ -z "$images" ]]; then
		log "No agent-sandbox images found."
		exit 0
	fi

	local removed=0
	while IFS= read -r image; do
		[[ -z "$image" ]] && continue
		local tag="${image#agent-sandbox:}"
		if [[ "$tag" == "$current_hash" ]]; then
			log "Keeping current image: $image"
			continue
		fi
		log "Removing old image: $image"
		"$RUNTIME" rmi "$image" && removed=$((removed + 1)) || warn "Failed to remove $image"
	done <<<"$images"

	log "Pruned $removed old image(s)."
	exit 0
}

# ---------------------------------------------------------------------------
# Dispatch: --list, --stop, --prune (now that helpers are defined)
# ---------------------------------------------------------------------------

if $OPT_LIST; then
	do_list
fi

if $OPT_STOP; then
	do_stop "${OPT_WORKSPACE}" "${OPT_AGENT_EXPLICIT}"
fi

if $OPT_PRUNE; then
	do_prune
fi

# ---------------------------------------------------------------------------
# Workspace validation (for run)
# ---------------------------------------------------------------------------

WORKSPACE=$(resolve_workspace "${OPT_WORKSPACE}")

# ---------------------------------------------------------------------------
# Container naming (for run)
# ---------------------------------------------------------------------------

CONTAINER_NAME=$(compute_container_name "$OPT_AGENT" "$WORKSPACE")

# ---------------------------------------------------------------------------
# Image management
# ---------------------------------------------------------------------------

IMAGE_HASH=$(compute_containerfile_hash)
IMAGE_TAG="agent-sandbox:${IMAGE_HASH}"

if $OPT_BUILD || ! image_exists "$IMAGE_HASH"; then
	build_image "$IMAGE_HASH"
fi

# ---------------------------------------------------------------------------
# Mount assembly
# ---------------------------------------------------------------------------

MOUNT_FLAGS=()

# Workspace mount (always rw)
MOUNT_FLAGS+=("-v" "${WORKSPACE}:/workspace:rw${MOUNT_Z}")

# Git config (ro, only if exists)
if [[ -f "${HOME}/.gitconfig" ]]; then
	MOUNT_FLAGS+=("-v" "${HOME}/.gitconfig:/home/sandbox/.gitconfig:ro${MOUNT_Z}")
fi

# OpenCode config (ro, only if dir exists)
if [[ -d "${HOME}/.config/opencode" ]]; then
	MOUNT_FLAGS+=("-v" "${HOME}/.config/opencode/:/host-config/opencode/:ro${MOUNT_Z}")
fi

# Claude config (ro, only if dir exists)
if [[ -d "${HOME}/.claude" ]]; then
	MOUNT_FLAGS+=("-v" "${HOME}/.claude/:/host-config/claude/:ro${MOUNT_Z}")
fi

# SSH agent socket (ro, unless --no-ssh or SSH_AUTH_SOCK not set)
SSH_FORWARDED=false
if ! $OPT_NO_SSH && [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
	if [[ -S "${SSH_AUTH_SOCK}" ]]; then
		MOUNT_FLAGS+=("-v" "${SSH_AUTH_SOCK}:/tmp/ssh_auth_sock:ro${MOUNT_Z}")
		SSH_FORWARDED=true
	else
		warn "SSH_AUTH_SOCK='${SSH_AUTH_SOCK}' is not a socket, skipping SSH forwarding"
	fi
fi

# ---------------------------------------------------------------------------
# Symlink scanning (--follow-symlinks)
# ---------------------------------------------------------------------------

# Appends read-write bind mounts for depth-1 workspace symlinks pointing outside the workspace.
# Skips dotfile targets unless OPT_FOLLOW_ALL_SYMLINKS is true.
collect_symlink_mounts() {
	# Verify readlink -f is available (not present on macOS without GNU coreutils)
	if ! readlink -f /tmp &>/dev/null; then
		die "readlink -f is not available. Install GNU coreutils (e.g., via Nix or 'brew install coreutils')."
	fi

	declare -A seen_targets=()
	while IFS= read -r -d '' entry; do
		# Skip the workspace directory itself (find includes it at depth 0)
		[[ "$entry" == "$WORKSPACE" ]] && continue

		# Only process symlinks
		[[ -L "$entry" ]] || continue

		local target
		target=$(readlink -f "$entry" 2>/dev/null || true)
		[[ -z "$target" ]] && continue

		# Skip if target doesn't exist
		if [[ ! -e "$target" ]]; then
			warn "Symlink target does not exist, skipping: $target (from $entry)"
			continue
		fi

		# Skip if target is not a directory
		[[ -d "$target" ]] || continue

		# Skip if target is within the workspace (already accessible via /workspace)
		# Exact match covers the workspace root itself (glob requires a trailing slash)
		if [[ "$target" == "$WORKSPACE"/* || "$target" == "$WORKSPACE" ]]; then
			continue
		fi

		# Dotfile protection: skip targets whose basename starts with '.'
		local tbase
		tbase=$(basename "$target")
		if [[ "$tbase" == .* ]]; then
			if ! $OPT_FOLLOW_ALL_SYMLINKS; then
				warn "Skipping dotfile symlink target (use --follow-all-symlinks to include): $target"
				continue
			fi
		fi

		# Deduplicate by resolved target path
		if [[ -n "${seen_targets[$target]+x}" ]]; then
			continue
		fi
		seen_targets["$target"]=1

		MOUNT_FLAGS+=("-v" "${target}:${target}:rw${MOUNT_Z}")
		log "Mounting symlink target: $target"
	done < <(find "$WORKSPACE" -maxdepth 1 -print0 2>/dev/null)
}

if $OPT_FOLLOW_SYMLINKS; then
	collect_symlink_mounts
fi

# ---------------------------------------------------------------------------
# Extra mounts (--mount CLI + config.toml [mounts] extra_paths)
# ---------------------------------------------------------------------------

# Appends mount flags for all extra host paths (CLI --mount and config extra_paths).
# Paths are expanded, resolved, existence-checked, and deduplicated.
collect_extra_mounts() {
	local all_entries=("${OPT_EXTRA_MOUNTS[@]}" "${CFG_EXTRA_PATHS[@]}")
	declare -A seen_paths=()

	local entry
	local mode
	local path
	local resolved
	local rel
	local container_path
	for entry in "${all_entries[@]}"; do
		# Split on trailing :rw if present
		mode="ro"
		path="$entry"
		if [[ "$entry" == *:rw ]]; then
			mode="rw"
			path="${entry%:rw}"
		fi

		# Expand ~/
		path="${path/#\~/$HOME}"

		# Resolve via realpath
		if ! resolved=$(realpath "$path" 2>/dev/null); then
			warn "Cannot resolve extra mount path, skipping: $path"
			continue
		fi

		# Check existence
		if [[ ! -e "$resolved" ]]; then
			warn "Extra mount path does not exist, skipping: $resolved"
			continue
		fi

		# Deduplicate by resolved host path
		if [[ -n "${seen_paths[$resolved]+x}" ]]; then
			continue
		fi
		seen_paths["$resolved"]=1

		# Determine container path:
		# - Paths under $HOME → /home/sandbox/<relative-path>
		# - Absolute paths outside $HOME → same absolute path
		if [[ "$resolved" == "$HOME"/* ]]; then
			rel="${resolved#$HOME/}"
			container_path="/home/sandbox/${rel}"
		else
			container_path="$resolved"
		fi

		MOUNT_FLAGS+=("-v" "${resolved}:${container_path}:${mode}${MOUNT_Z}")
	done
}

collect_extra_mounts

# ---------------------------------------------------------------------------
# Environment variable assembly
# ---------------------------------------------------------------------------

ENV_FLAGS=()

# Default API key set
DEFAULT_ENV_VARS=(
	"ANTHROPIC_API_KEY"
	"OPENAI_API_KEY"
	"OPENROUTER_API_KEY"
	"MISTRAL_API_KEY"
	"AWS_ACCESS_KEY_ID"
	"AWS_SECRET_ACCESS_KEY"
	"AWS_SESSION_TOKEN"
	"GITHUB_TOKEN"
)

# Merge with extra_vars from config (CFG_EXTRA_VARS may be empty)
ALL_ENV_VARS=("${DEFAULT_ENV_VARS[@]}" "${CFG_EXTRA_VARS[@]}")

for varname in "${ALL_ENV_VARS[@]}"; do
	if [[ -n "${!varname:-}" ]]; then
		ENV_FLAGS+=("-e" "$varname")
	fi
done

# Always set AGENT
ENV_FLAGS+=("-e" "AGENT=${OPT_AGENT}")

# SSH_AUTH_SOCK inside container
if $SSH_FORWARDED; then
	ENV_FLAGS+=("-e" "SSH_AUTH_SOCK=/tmp/ssh_auth_sock")
fi

# AGENT_SANDBOX_NO_SSH
if $OPT_NO_SSH; then
	ENV_FLAGS+=("-e" "AGENT_SANDBOX_NO_SSH=1")
fi

# AGENT_SANDBOX_EXTRA_DOMAINS (newline-separated)
if [[ ${#CFG_EXTRA_DOMAINS[@]} -gt 0 ]]; then
	EXTRA_DOMAINS_VAL=$(printf '%s\n' "${CFG_EXTRA_DOMAINS[@]}")
	ENV_FLAGS+=("-e" "AGENT_SANDBOX_EXTRA_DOMAINS=${EXTRA_DOMAINS_VAL}")
fi

# ---------------------------------------------------------------------------
# Session deduplication check
# ---------------------------------------------------------------------------

# Use substring filter + grep for exact match: Docker doesn't support regex anchors
# in --filter name=, but Podman does. The grep -Fx approach works on both.
EXISTING_CONTAINER=$("$RUNTIME" ps --filter "name=agent-sandbox-" --format "{{.Names}}" 2>/dev/null | grep -Fx "$CONTAINER_NAME" || true)
if [[ -n "$EXISTING_CONTAINER" ]]; then
	log "Container '$CONTAINER_NAME' is already running and serving your workspace."
	log "Use '--stop' to stop it, or '--list' to see all running sandboxes."
	exit 0
fi

# ---------------------------------------------------------------------------
# Container run
# ---------------------------------------------------------------------------

log "Starting sandbox: $CONTAINER_NAME"
log "  Agent:     $OPT_AGENT"
log "  Workspace: $WORKSPACE"
log "  Image:     $IMAGE_TAG"
log "  Runtime:   $RUNTIME"

RUN_CMD=(
	run
	--rm
	-i
	-t
	--name "$CONTAINER_NAME"
	--cap-drop=ALL
	--cap-add=NET_ADMIN
	--cap-add=NET_RAW
	--security-opt=no-new-privileges
	"--memory=${CFG_MEMORY}"
	"--cpus=${CFG_CPUS}"
)

if [[ -n "$USERNS_FLAG" ]]; then
	RUN_CMD+=("$USERNS_FLAG")
fi

RUN_CMD+=("${MOUNT_FLAGS[@]}")
RUN_CMD+=("${ENV_FLAGS[@]}")
RUN_CMD+=("$IMAGE_TAG")

exec "$RUNTIME" "${RUN_CMD[@]}"
