# tests/test_helper.bash — shared setup for all bats test files
#
# Load this at the top of every .bats file:
#   load '../test_helper'
#
# bats-core 1.7+ supports bats_load_library which searches BATS_LIB_PATH.
# The Nix devShell sets BATS_LIB_PATH to include bats-support and bats-assert.

bats_load_library bats-support
bats_load_library bats-assert

# ---------------------------------------------------------------------------
# Common variables
# ---------------------------------------------------------------------------

# Repository root — one level up from tests/.
# Use BASH_SOURCE[0] (always points to test_helper.bash itself) rather than
# BATS_TEST_FILENAME (which points to the .bats file being run, e.g.
# tests/unit/foo.bats — one level too deep).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Path to the launcher script
LAUNCHER="${REPO_ROOT}/agent-sandbox.sh"

# Path to the fake agent binary used in tests
FAKE_AGENT="${REPO_ROOT}/tests/fixtures/fake-agent"

# Path to the fixtures directory
FIXTURE_DIR="${REPO_ROOT}/tests/fixtures"

# ---------------------------------------------------------------------------
# Helper: runtime_name
# ---------------------------------------------------------------------------
# Prints the name of the available container runtime (podman or docker).
# Returns 1 if neither is found.
#
# Named runtime_name (not detect_runtime) to distinguish from the launcher's
# detect_runtime(), which sets a global RUNTIME variable instead of printing.

runtime_name() {
	if command -v podman &>/dev/null; then
		echo "podman"
	elif command -v docker &>/dev/null; then
		echo "docker"
	else
		return 1
	fi
}

# ---------------------------------------------------------------------------
# Helper: compute_image_tag
# ---------------------------------------------------------------------------
# Computes the image tag from the Containerfile content hash, matching the
# launcher's logic: sha256sum Containerfile | cut -c1-64
#
# Portable: uses sha256sum on Linux, shasum -a 256 on macOS.

compute_image_tag() {
	local containerfile="${REPO_ROOT}/Containerfile"
	local hash
	if command -v sha256sum &>/dev/null; then
		hash=$(sha256sum "$containerfile" 2>/dev/null | cut -c1-64)
	elif command -v shasum &>/dev/null; then
		hash=$(shasum -a 256 "$containerfile" 2>/dev/null | cut -c1-64)
	else
		echo "compute_image_tag: no sha256 tool found (need sha256sum or shasum)" >&2
		return 1
	fi
	if [[ -z "$hash" ]]; then
		echo "compute_image_tag: failed to hash Containerfile (missing or unreadable: $containerfile)" >&2
		return 1
	fi
	echo "agent-sandbox:${hash}"
}
