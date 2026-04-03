#!/usr/bin/env bash
set -euo pipefail

SHARE_DIR="${AGENT_SANDBOX_SHARE_DIR:-@SHARE_DIR@}"
VERSION="${AGENT_SANDBOX_VERSION:-@VERSION@}"

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

# Portable realpath: resolves symlinks and canonicalizes a path.
# Works on macOS (bash 3.2, no GNU coreutils) via realpath or python3 fallback.
portable_realpath() {
	if command -v realpath &>/dev/null; then
		realpath "$1"
	elif command -v python3 &>/dev/null; then
		python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"
	else
		readlink -f "$1" 2>/dev/null || {
			err "Cannot resolve path '$1': install 'realpath' or 'python3'"
			return 1
		}
	fi
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
  --follow-all-symlinks    Like --follow-symlinks but includes dotfile directories (.ssh, .gnupg, etc.)
  --mount <path>           Mount an extra host path read-only (repeatable; append :rw for read-write)
  --no-ssh                 Skip SSH agent socket forwarding
  --list                   List running agent-sandbox containers
  --stop                   Stop sandbox(es) for the given/current workspace
  --prune                  Remove old agent-sandbox images, keeping only the current hash
  --update                 Update to the latest version
  -v, --version            Print version and exit
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
  agent-sandbox --update               # update to the latest version
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
	OPT_AGENT=""
	OPT_AGENT_EXPLICIT="" # set only when --agent is passed on CLI; used for --stop dispatch
	OPT_BUILD=false
	OPT_FOLLOW_SYMLINKS=false
	OPT_FOLLOW_ALL_SYMLINKS=false
	OPT_NO_SSH=false
	OPT_LIST=false
	OPT_STOP=false
	OPT_PRUNE=false
	OPT_UPDATE=false
	OPT_HELP=false
	OPT_VERSION=false
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
		--update)
			OPT_UPDATE=true
			shift
			;;
		-v | --version)
			OPT_VERSION=true
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
}

# ---------------------------------------------------------------------------
# Dispatch: --update (early exit — does not need runtime or config)
# ---------------------------------------------------------------------------

do_update() {
	# Detect Nix installation via SHARE_DIR (substituted at build time by both
	# the Nix build and install.sh; Nix sets it to /nix/store/...).
	case "$SHARE_DIR" in
	/nix/store/*)
		log "Installed via Nix. Update with: nix profile upgrade or update your flake input."
		exit 0
		;;
	esac

	# Query latest version from GitHub
	log "Checking for updates..."
	local api_response
	api_response=$(curl -fsSL https://api.github.com/repos/mstruble/agent-sandbox/releases/latest 2>/dev/null) ||
		die "Failed to check for updates. Check your internet connection."

	# Extract tag_name from JSON without jq.
	# Isolate the "tag_name" field first, then strip the optional leading 'v' prefix
	# so latest_tag holds a bare semver (e.g. "1.2.3" not "v1.2.3").
	local latest_tag
	latest_tag=$(printf '%s' "$api_response" |
		grep '"tag_name"' |
		head -1 |
		grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' |
		sed 's/.*"v\{0,1\}\([^"]*\)"/\1/' ||
		true)

	if [[ -z "$latest_tag" ]]; then
		die "Could not parse version from GitHub API response."
	fi

	# Validate the extracted version string before any further use.
	# Reject anything that isn't a safe semver-like string to prevent
	# path traversal or injection if the API response is crafted.
	# Note: the empty-string case is already caught above; the explicit
	# [[ -z ]] guard here makes the validation self-contained.
	if [[ -z "$latest_tag" ]] || [[ "$latest_tag" =~ [^0-9A-Za-z._-] ]] || [[ "$latest_tag" == */* ]] || [[ "$latest_tag" == *..* ]]; then
		die "GitHub API returned an invalid version string: '${latest_tag}'"
	fi

	# Compare versions
	if [[ "$latest_tag" == "$VERSION" ]]; then
		log "Already up to date (v${VERSION})."
		exit 0
	fi

	log "Updating from v${VERSION} to v${latest_tag}..."

	# Download install.sh from the specific release tag (not main) to ensure
	# the installer matches the version being installed.
	# Store in variable to allow env-var prefix injection (AGENT_SANDBOX_VERSION=...).
	local install_script
	install_script=$(curl -fsSL "https://raw.githubusercontent.com/mstruble/agent-sandbox/v${latest_tag}/install.sh" 2>/dev/null) ||
		die "Failed to download installer."

	# Sanity-check the downloaded content before executing it.
	# Guards against CDN hiccups returning HTML or other non-script content.
	if [[ "$install_script" != '#!/'* ]]; then
		die "Downloaded installer does not look like a shell script (missing shebang)."
	fi

	# Verify install.sh integrity against the release SHA256SUMS file.
	# Portable sha256 wrapper: GNU coreutils provides sha256sum; macOS ships shasum.
	_sha256sum() {
		if command -v sha256sum &>/dev/null; then
			sha256sum "$@"
		elif command -v shasum &>/dev/null; then
			shasum -a 256 "$@"
		else
			return 1
		fi
	}
	local sums_url="https://github.com/mstruble/agent-sandbox/releases/download/v${latest_tag}/SHA256SUMS"
	local sums_content
	if sums_content=$(curl -fsSL "$sums_url" 2>/dev/null) && _sha256sum /dev/null &>/dev/null; then
		# Extract the expected hash for install.sh; take only the first match
		# (head -1) to guard against duplicate or crafted entries.
		local expected_hash
		expected_hash=$(printf '%s' "$sums_content" | grep ' install\.sh$' | head -1 | awk '{print $1}' || true)
		if [[ -z "$expected_hash" ]]; then
			warn "No entry for install.sh in SHA256SUMS for v${latest_tag} — skipping checksum verification"
		else
			log "Verifying installer checksum..."
			# Capture _sha256sum output separately to detect tool failures
			# before passing to awk (a partial hash would otherwise pass the
			# non-empty check and produce a spurious mismatch error).
			# Use printf '%s\n' to restore the trailing newline stripped by
			# command substitution, so the hash matches the file-based hash
			# in SHA256SUMS.
			local raw_hash actual_hash
			raw_hash=$(printf '%s\n' "$install_script" | _sha256sum) ||
				die "Failed to compute installer checksum."
			actual_hash=$(awk '{print $1}' <<<"$raw_hash")
			if [[ -z "$actual_hash" ]]; then
				die "Failed to parse installer checksum output."
			fi
			if [[ "$actual_hash" != "$expected_hash" ]]; then
				die "install.sh checksum verification FAILED — aborting update. The download may be corrupt or tampered with."
			fi
			log "Checksum verified."
		fi
	else
		warn "SHA256SUMS not available for v${latest_tag} or no sha256 tool found — skipping checksum verification"
	fi

	AGENT_SANDBOX_VERSION="$latest_tag" sh -c "$install_script" ||
		die "Update failed."

	log "Updated to v${latest_tag}."
	exit 0
}

# ---------------------------------------------------------------------------
# Config file parsing (~/.config/agent-sandbox/config.toml)
# ---------------------------------------------------------------------------

CONFIG_FILE="${HOME}/.config/agent-sandbox/config.toml"

# Config values with defaults
CFG_AGENT="opencode"
CFG_EXTRA_VARS=()
CFG_FOLLOW_SYMLINKS=false
CFG_FOLLOW_ALL_SYMLINKS=false
CFG_EXTRA_PATHS=()
CFG_MEMORY="8g"
CFG_CPUS=4

parse_config() {
	# Reset arrays so repeated calls (e.g., in tests) don't accumulate entries
	CFG_EXTRA_VARS=()
	CFG_EXTRA_PATHS=()

	if [[ ! -f "$CONFIG_FILE" ]]; then
		return 0
	fi

	# Verify python3 with tomllib is available (requires Python 3.11+)
	if ! python3 -c "import tomllib" 2>/dev/null; then
		die "Python 3.11+ with tomllib is required to parse config.toml but was not found"
	fi

	# Parse TOML to JSON; die on malformed input
	local config_json
	config_json=$(python3 -c "
import tomllib, json, sys
try:
    with open(sys.argv[1], 'rb') as f:
        config = tomllib.load(f)
    json.dump(config, sys.stdout)
except Exception as e:
    print(f'PARSE_ERROR:{e}', file=sys.stderr)
    sys.exit(1)
" "$CONFIG_FILE" 2>/dev/null) || die "Config file '$CONFIG_FILE' is malformed TOML — fix or remove it"

	# Helper: extract a dotted-key value from the JSON blob.
	# Prints each list item on its own line; booleans as 'true'/'false'; scalars as-is.
	_cfg_get() {
		python3 -c "
import json, sys
data = json.loads(sys.argv[1])
keys = sys.argv[2].split('.')
for k in keys:
    if isinstance(data, dict) and k in data:
        data = data[k]
    else:
        sys.exit(0)
result = data
if isinstance(result, list):
    for item in result:
        print(item)
elif isinstance(result, bool):
    print('true' if result else 'false')
else:
    print(result)
" "$config_json" "$1"
	}

	# [defaults] agent
	local val
	val=$(_cfg_get "defaults.agent")
	if [[ -n "$val" ]]; then
		if [[ "$val" != "opencode" && "$val" != "claude" ]]; then
			die "Config error: defaults.agent must be 'opencode' or 'claude', got '$val'"
		fi
		CFG_AGENT="$val"
	fi

	# [env] extra_vars (array)
	local var_regex='^[A-Za-z_][A-Za-z0-9_]*$'
	while IFS= read -r varname; do
		[[ -z "$varname" ]] && continue
		if ! [[ "$varname" =~ $var_regex ]]; then
			die "Config error: invalid variable name in env.extra_vars: '$varname'"
		fi
		CFG_EXTRA_VARS+=("$varname")
	done < <(_cfg_get "env.extra_vars")

	# [workspace] follow_symlinks (boolean)
	val=$(_cfg_get "workspace.follow_symlinks")
	if [[ "$val" == "true" ]]; then
		CFG_FOLLOW_SYMLINKS=true
	fi

	# [workspace] follow_all_symlinks (boolean)
	val=$(_cfg_get "workspace.follow_all_symlinks")
	if [[ "$val" == "true" ]]; then
		CFG_FOLLOW_ALL_SYMLINKS=true
	fi

	# [mounts] extra_paths (array)
	while IFS= read -r mpath; do
		[[ -z "$mpath" ]] && continue
		CFG_EXTRA_PATHS+=("$mpath")
	done < <(_cfg_get "mounts.extra_paths")

	# [resources] memory
	val=$(_cfg_get "resources.memory")
	if [[ -n "$val" ]]; then
		CFG_MEMORY="$val"
	fi

	# [resources] cpus
	val=$(_cfg_get "resources.cpus")
	if [[ -n "$val" ]]; then
		if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -le 0 ]]; then
			die "Config error: resources.cpus must be a positive integer, got '$val'"
		fi
		CFG_CPUS="$val"
	fi
}

# Apply config defaults to CLI options (CLI takes precedence), and validate.
apply_config_defaults() {
	# Apply config defaults to CLI options (CLI takes precedence)
	if [[ -z "$OPT_AGENT" ]]; then
		OPT_AGENT="$CFG_AGENT"
	fi

	# Validate agent value
	if [[ "$OPT_AGENT" != "opencode" && "$OPT_AGENT" != "claude" ]]; then
		die "--agent must be 'opencode' or 'claude', got '$OPT_AGENT'"
	fi

	# Apply config follow_symlinks
	if $CFG_FOLLOW_SYMLINKS; then
		OPT_FOLLOW_SYMLINKS=true
	fi

	# Apply config follow_all_symlinks
	if $CFG_FOLLOW_ALL_SYMLINKS; then
		OPT_FOLLOW_ALL_SYMLINKS=true
		OPT_FOLLOW_SYMLINKS=true
	fi
}

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
	if ! resolved=$(portable_realpath "$ws" 2>/dev/null); then
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
	# Lowercase (portable: tr works on bash 3.2+)
	name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
	# Strip non-[a-z0-9-] characters
	name=$(printf '%s' "$name" | tr -cd 'a-z0-9-')
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
RUNTIME=""

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
		if "$RUNTIME" rmi "$image"; then removed=$((removed + 1)); else warn "Failed to remove $image"; fi
	done <<<"$images"

	log "Pruned $removed old image(s)."
	exit 0
}

# ---------------------------------------------------------------------------
# Symlink scanning (--follow-symlinks)
# ---------------------------------------------------------------------------

# Appends read-write bind mounts for depth-1 workspace symlinks pointing outside the workspace.
# Skips dotfile targets (e.g. .ssh, .gnupg) unless OPT_FOLLOW_ALL_SYMLINKS is true,
# because dotfile directories commonly contain credentials and private keys.
collect_symlink_mounts() {
	# Newline-delimited list of already-seen resolved targets (deduplication)
	local _seen_targets=""

	while IFS= read -r -d '' entry; do
		# Skip the workspace directory itself (find includes it at depth 0)
		[[ "$entry" == "$WORKSPACE" ]] && continue

		# Only process symlinks
		[[ -L "$entry" ]] || continue

		local target
		target=$(portable_realpath "$entry" 2>/dev/null || true)
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
				warn "Skipping dotfile symlink target (may contain credentials; use --follow-all-symlinks to include): $target"
				continue
			fi
		fi

		# Deduplicate by resolved target path (exact line match)
		if printf '%s\n' "$_seen_targets" | grep -qFx "$target"; then
			continue
		fi
		_seen_targets="${_seen_targets}${target}
"

		MOUNT_FLAGS+=("-v" "${target}:${target}:rw${MOUNT_Z}")
		log "Mounting symlink target: $target"
	done < <(find "$WORKSPACE" -maxdepth 1 -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Extra mounts (--mount CLI + config.toml [mounts] extra_paths)
# ---------------------------------------------------------------------------

# Appends mount flags for all extra host paths (CLI --mount and config extra_paths).
# Paths are expanded, resolved, existence-checked, and deduplicated.
collect_extra_mounts() {
	local all_entries=("${OPT_EXTRA_MOUNTS[@]}" "${CFG_EXTRA_PATHS[@]}")
	# Newline-delimited list of already-seen resolved paths (deduplication)
	local _seen_paths=""

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

		# Resolve via portable_realpath
		if ! resolved=$(portable_realpath "$path" 2>/dev/null); then
			warn "Cannot resolve extra mount path, skipping: $path"
			continue
		fi

		# Check existence
		if [[ ! -e "$resolved" ]]; then
			warn "Extra mount path does not exist, skipping: $resolved"
			continue
		fi

		# Deduplicate by resolved host path (exact line match)
		if printf '%s\n' "$_seen_paths" | grep -qFx "$resolved"; then
			continue
		fi
		_seen_paths="${_seen_paths}${resolved}
"

		# Determine container path:
		# - Paths under $HOME → /home/sandbox/<relative-path>
		# - Absolute paths outside $HOME → same absolute path
		if [[ "$resolved" == "$HOME"/* ]]; then
			rel="${resolved#"$HOME"/}"
			container_path="/home/sandbox/${rel}"
		else
			container_path="$resolved"
		fi

		MOUNT_FLAGS+=("-v" "${resolved}:${container_path}:${mode}${MOUNT_Z}")
	done
}

# ---------------------------------------------------------------------------
# Mount assembly
# ---------------------------------------------------------------------------

assemble_mount_flags() {
	MOUNT_FLAGS=()

	# Workspace mount (always rw)
	MOUNT_FLAGS+=("-v" "${WORKSPACE}:/workspace:rw${MOUNT_Z}")

	# Git config (ro, only if exists)
	if [[ -f "${HOME}/.gitconfig" ]]; then
		MOUNT_FLAGS+=("-v" "${HOME}/.gitconfig:/home/sandbox/.gitconfig:ro${MOUNT_Z}")
	fi

	# Stage host config directories with resolved symlinks.
	# The container cannot follow symlinks that point outside the mount (e.g. Nix
	# store paths). Staging resolves them on the host where targets are accessible.
	# mktemp -d avoids predictable-path attacks; chmod 700 restricts access.
	# NOTE: The cleanup trap fires on launcher exit/error but NOT after a successful
	# exec (which replaces the process). The staged dir persists for the container's
	# lifetime — this is fine since the mount is read-only and permissions are tight.
	_stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-config.XXXXXX")
	# Register cleanup trap immediately after mktemp so the directory is always
	# removed on exit, even if portable_realpath fails before the trap is set.
	# shellcheck disable=SC2064  # intentional: bake in the path at trap-set time
	trap "rm -rf '${_stage_dir}'" EXIT
	# Resolve /tmp -> /private/tmp on macOS so Podman virtiofs bind-mounts work.
	_stage_dir=$(portable_realpath "$_stage_dir")
	chmod 700 "$_stage_dir"
	# Re-register trap with the resolved path so cleanup uses the canonical path.
	# shellcheck disable=SC2064
	trap "rm -rf '${_stage_dir}'" EXIT

	# OpenCode config (ro, only if dir exists)
	if [[ -d "${HOME}/.config/opencode" ]]; then
		mkdir -p "$_stage_dir/opencode"
		if cp -RL "${HOME}/.config/opencode/." "$_stage_dir/opencode/"; then
			MOUNT_FLAGS+=("-v" "$_stage_dir/opencode:/host-config/opencode/:ro${MOUNT_Z}")
		else
			warn "Failed to stage opencode config (symlink resolution failed) — skipping"
		fi
	fi

	# Claude config (ro, only if dir exists)
	if [[ -d "${HOME}/.claude" ]]; then
		mkdir -p "$_stage_dir/claude"
		if cp -RL "${HOME}/.claude/." "$_stage_dir/claude/"; then
			MOUNT_FLAGS+=("-v" "$_stage_dir/claude:/host-config/claude/:ro${MOUNT_Z}")
		else
			warn "Failed to stage claude config (symlink resolution failed) — skipping"
		fi
	fi

	# SSH agent socket (ro, unless --no-ssh or SSH_AUTH_SOCK not set)
	SSH_FORWARDED=false
	if ! $OPT_NO_SSH && [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
		# Normalize: expand leading ~ to $HOME and strip literal backslashes.
		# Common when SSH_AUTH_SOCK is set with unexpanded ~ or backslash-escaped
		# spaces in shell rc files (e.g. 1Password agent socket paths).
		_ssh_sock="${SSH_AUTH_SOCK}"
		_ssh_sock="${_ssh_sock/#\~/$HOME}"
		_ssh_sock="${_ssh_sock//\\/}"
		if [[ "$(uname -s)" == "Darwin" && "$RUNTIME" == "podman" ]]; then
			# Podman Machine uses virtiofs to share the host filesystem with the
			# Linux VM. virtiofs does not support Unix domain sockets — attempting
			# to bind-mount one causes a hard 'statfs: operation not supported'
			# error. Skip SSH forwarding entirely on this combination.
			warn "SSH agent forwarding is not supported with Podman on macOS (virtiofs limitation). Use Docker Desktop or pass --no-ssh to suppress."
		elif [[ -S "$_ssh_sock" ]]; then
			MOUNT_FLAGS+=("-v" "${_ssh_sock}:/tmp/ssh_auth_sock:ro${MOUNT_Z}")
			SSH_FORWARDED=true
		else
			warn "SSH_AUTH_SOCK='${SSH_AUTH_SOCK}' is not a socket, skipping SSH forwarding"
		fi
	fi

	if $OPT_FOLLOW_SYMLINKS; then
		collect_symlink_mounts
	fi

	collect_extra_mounts
}

# ---------------------------------------------------------------------------
# Environment variable assembly
# ---------------------------------------------------------------------------

assemble_env_flags() {
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
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

main() {
	parse_args "$@"

	if $OPT_HELP; then
		usage
		exit 0
	fi
	if $OPT_VERSION; then
		echo "agent-sandbox ${VERSION}"
		exit 0
	fi
	if $OPT_UPDATE; then do_update; fi

	parse_config
	apply_config_defaults
	detect_runtime

	# USERNS_FLAG logic
	USERNS_FLAG=""
	if [[ "$RUNTIME" == "podman" ]]; then USERNS_FLAG="--userns=keep-id"; fi

	# MOUNT_Z logic
	# The :z option relabels the mount for container access; safe on non-SELinux Linux too.
	# Not needed on macOS where containers run in a Linux VM.
	MOUNT_Z=""
	if [[ "$(uname -s)" == "Linux" ]]; then MOUNT_Z=",z"; fi

	# ---------------------------------------------------------------------------
	# Dispatch: --list, --stop, --prune (now that helpers are defined)
	# ---------------------------------------------------------------------------

	if $OPT_LIST; then do_list; fi
	if $OPT_STOP; then do_stop "${OPT_WORKSPACE}" "${OPT_AGENT_EXPLICIT}"; fi
	if $OPT_PRUNE; then do_prune; fi

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
	# Mount and environment assembly
	# ---------------------------------------------------------------------------

	assemble_mount_flags
	assemble_env_flags

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
		--sysctl=net.ipv6.conf.all.disable_ipv6=1
		--sysctl=net.ipv6.conf.default.disable_ipv6=1
		--sysctl=net.ipv6.conf.lo.disable_ipv6=1
		--cap-drop=ALL
		--cap-add=NET_ADMIN
		--cap-add=NET_RAW
		--cap-add=SETUID
		--cap-add=SETGID
		--cap-add=SYS_TIME
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
}

# ---------------------------------------------------------------------------
# Entry point guard — only run main() when executed directly, not when sourced
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
