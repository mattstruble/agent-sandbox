#!/bin/sh
# install.sh — POSIX sh installer for agent-sandbox (non-Nix users)
# Usage: curl -fsSL https://raw.githubusercontent.com/mstruble/agent-sandbox/main/install.sh | sh
# Or:    sh install.sh [--uninstall]
set -eu

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '[agent-sandbox] %s\n' "$*" >&2; }
warn() { printf '[agent-sandbox] WARNING: %s\n' "$*" >&2; }
err() { printf '[agent-sandbox] ERROR: %s\n' "$*" >&2; }
die() {
	err "$*"
	exit 1
}

# ---------------------------------------------------------------------------
# Uninstall mode
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--uninstall" ]; then
	bin_path="${HOME}/.local/bin/agent-sandbox"
	share_dir="${HOME}/.local/share/agent-sandbox"

	if [ ! -f "$bin_path" ] && [ ! -d "$share_dir" ]; then
		log "agent-sandbox is not installed"
		exit 0
	fi

	if [ -f "$bin_path" ]; then
		rm -f "$bin_path"
		log "Removed $bin_path"
	fi

	if [ -d "$share_dir" ]; then
		rm -rf "$share_dir"
		log "Removed $share_dir"
	fi

	log "Note: ~/.config/agent-sandbox/ has been preserved (user configuration)"
	log "agent-sandbox uninstalled successfully."
	exit 0
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

log "Installing agent-sandbox..."

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

detect_platform() {
	_os="$(uname -s)"
	case "$_os" in
	Darwin) OS="darwin" ;;
	Linux) OS="linux" ;;
	*) die "Unsupported operating system: $_os (only macOS and Linux are supported)" ;;
	esac

	_arch="$(uname -m)"
	case "$_arch" in
	x86_64) ARCH="x86_64" ;;
	aarch64 | arm64) ARCH="aarch64" ;;
	*) die "Unsupported architecture: $_arch (only x86_64 and aarch64 are supported)" ;;
	esac

	log "Detected platform: ${OS}/${ARCH}"
}

detect_platform

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

check_prerequisites() {
	# Check for container runtime
	if command -v podman >/dev/null 2>&1; then
		log "Found container runtime: podman"
	elif command -v docker >/dev/null 2>&1; then
		log "Found container runtime: docker"
	else
		err "No container runtime found. agent-sandbox requires podman or docker."
		if [ "$OS" = "darwin" ]; then
			err "Install Docker Desktop from https://www.docker.com/products/docker-desktop/ or Podman from https://podman.io/docs/installation"
		else
			err "Install Docker (https://docs.docker.com/engine/install/) or Podman (https://podman.io/docs/installation)"
		fi
		exit 1
	fi

	# Check for curl
	if ! command -v curl >/dev/null 2>&1; then
		die "curl is required but was not found in PATH. Please install curl and try again."
	fi
}

check_prerequisites

# ---------------------------------------------------------------------------
# Version resolution
# ---------------------------------------------------------------------------

# Validate that a version string contains only safe characters (semver-like).
# Rejects path separators, spaces, and other characters that could cause
# path traversal or URL injection when VERSION is interpolated into paths/URLs.
validate_version() {
	_v="$1"
	case "$_v" in
	*[!0-9A-Za-z._-]*)
		die "Invalid version string: '${_v}' — must contain only [0-9A-Za-z._-]"
		;;
	esac
	case "$_v" in
	*"/"* | *".."*)
		die "Invalid version string: '${_v}' — path traversal characters not allowed"
		;;
	esac
}

resolve_version() {
	if [ -n "${AGENT_SANDBOX_VERSION:-}" ]; then
		VERSION="$AGENT_SANDBOX_VERSION"
		validate_version "$VERSION"
		log "Using specified version: ${VERSION}"
		return
	fi

	log "Querying GitHub API for latest release..."
	_api_response="$(curl -fsSL "https://api.github.com/repos/mstruble/agent-sandbox/releases/latest")" ||
		die "Failed to query GitHub API for latest release. Set AGENT_SANDBOX_VERSION to install a specific version."

	# Extract tag_name from JSON without jq.
	# Isolate the "tag_name" field first, then strip the optional leading 'v' prefix
	# so VERSION holds a bare semver (e.g. "1.2.3" not "v1.2.3").
	_tag="$(printf '%s' "$_api_response" |
		grep '"tag_name"' |
		head -1 |
		grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' |
		sed 's/.*"v\{0,1\}\([^"]*\)"/\1/')"

	if [ -z "$_tag" ]; then
		die "Could not parse version from GitHub API response. Set AGENT_SANDBOX_VERSION to install a specific version."
	fi

	VERSION="$_tag"
	validate_version "$VERSION"
	log "Latest version: ${VERSION}"
}

resolve_version

# ---------------------------------------------------------------------------
# Download and extract
# ---------------------------------------------------------------------------

TARBALL_URL="https://github.com/mstruble/agent-sandbox/releases/download/v${VERSION}/agent-sandbox-${VERSION}.tar.gz"
SUMS_URL="https://github.com/mstruble/agent-sandbox/releases/download/v${VERSION}/SHA256SUMS"
INSTALL_BIN="${HOME}/.local/bin/agent-sandbox"
INSTALL_SHARE="${HOME}/.local/share/agent-sandbox"

log "Downloading v${VERSION}..."

# Use a name that does not shadow the POSIX $TMPDIR environment variable,
# which mktemp and other tools use to locate the system temp directory.
_install_tmpdir="$(mktemp -d -t agent-sandbox-install.XXXXXXXXXX)"
# Ensure temp directory is cleaned up on exit (normal or error).
# SC2064: intentional — capture current value of _install_tmpdir at trap definition time.
# shellcheck disable=SC2064
trap "rm -rf '${_install_tmpdir}'" EXIT

_tarball="${_install_tmpdir}/agent-sandbox-${VERSION}.tar.gz"
_sums_file="${_install_tmpdir}/SHA256SUMS"

curl -fsSL -o "$_tarball" "$TARBALL_URL" ||
	die "Failed to download agent-sandbox v${VERSION} from ${TARBALL_URL}"

# Portable SHA-256 wrapper: GNU coreutils provides sha256sum; macOS ships shasum.
_sha256sum() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$@"
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$@"
	else
		return 1
	fi
}

# Verify tarball integrity via SHA256SUMS published alongside each release.
# This catches accidental corruption and CDN-level substitution.
# Avoids --ignore-missing (not supported by macOS shasum) by extracting the
# expected hash for our specific tarball and comparing directly.
if curl -fsSL -o "$_sums_file" "$SUMS_URL" 2>/dev/null; then
	if _sha256sum /dev/null >/dev/null 2>&1; then
		log "Verifying checksum..."
		_tarball_basename="agent-sandbox-${VERSION}.tar.gz"
		_expected_hash="$(grep " ${_tarball_basename}$" "$_sums_file" | awk '{print $1}')"
		if [ -z "$_expected_hash" ]; then
			warn "No entry for ${_tarball_basename} in SHA256SUMS — skipping checksum verification"
		else
			_actual_hash="$(_sha256sum "$_tarball" | awk '{print $1}')"
			if [ "$_actual_hash" != "$_expected_hash" ]; then
				die "Tarball checksum verification FAILED — aborting install. The download may be corrupt or tampered with."
			fi
			log "Checksum verified."
		fi
	else
		warn "No sha256sum/shasum tool found — skipping checksum verification"
	fi
else
	warn "SHA256SUMS not available for v${VERSION} — skipping checksum verification"
fi

log "Extracting..."

tar -xzf "$_tarball" -C "$_install_tmpdir" ||
	die "Failed to extract tarball"

_extract_dir="${_install_tmpdir}/agent-sandbox-${VERSION}"

# Verify expected layout
if [ ! -f "${_extract_dir}/bin/agent-sandbox" ]; then
	die "Unexpected tarball layout: bin/agent-sandbox not found in extracted archive"
fi

# ---------------------------------------------------------------------------
# Install files
# ---------------------------------------------------------------------------

log "Installing to ~/.local/..."

mkdir -p "${HOME}/.local/bin"
# Remove stale share directory contents before installing to avoid leftover
# files from prior versions (e.g. renamed scripts) being silently used.
rm -rf "${INSTALL_SHARE:?}"
mkdir -p "${INSTALL_SHARE}"

# Install binary
cp "${_extract_dir}/bin/agent-sandbox" "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"

# Substitute build-time placeholders that the Nix build normally fills in.
# The non-Nix tarball may contain @SHARE_DIR@ and @VERSION@ literals that
# must be replaced with the actual install-time paths.
sed -i.bak \
	-e "s|@SHARE_DIR@|${INSTALL_SHARE}|g" \
	-e "s|@VERSION@|${VERSION}|g" \
	"$INSTALL_BIN" && rm -f "${INSTALL_BIN}.bak"

# Install share directory contents (if present)
if [ -d "${_extract_dir}/share/agent-sandbox" ]; then
	cp -r "${_extract_dir}/share/agent-sandbox/." "${INSTALL_SHARE}/"
fi

# ---------------------------------------------------------------------------
# Success message
# ---------------------------------------------------------------------------

log "agent-sandbox v${VERSION} installed successfully!"

# ---------------------------------------------------------------------------
# PATH detection and instructions
# ---------------------------------------------------------------------------

_local_bin="${HOME}/.local/bin"

# Check if ~/.local/bin is already in PATH
case ":${PATH}:" in
# Already in PATH — nothing to do
*":${_local_bin}:"*) ;;
*)
	warn "${_local_bin} is not in your PATH."
	log "Add it by running the appropriate command for your shell:"
	log ""

	_shell_name="$(basename "${SHELL:-}")"
	case "$_shell_name" in
	bash)
		log "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
		log "  source ~/.bashrc"
		;;
	zsh)
		log "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
		log "  source ~/.zshrc"
		;;
	fish)
		log "  fish_add_path ~/.local/bin"
		;;
	*)
		log "  export PATH=\"\$HOME/.local/bin:\$PATH\""
		log "(Add this line to your shell's rc file to make it permanent)"
		;;
	esac
	log ""
	;;
esac
