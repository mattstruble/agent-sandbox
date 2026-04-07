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
# Helper: make_temp / make_tempdir
# ---------------------------------------------------------------------------
# Wrappers around mktemp that resolve the resulting path to its canonical form.
# On macOS, /tmp is a symlink to /private/tmp, and inside nix develop, mktemp
# creates files under /tmp/nix-shell.XXXXX/. Docker Desktop's filesystem
# sharing uses the canonical path, so passing the unresolved symlink path to
# `docker run -v` fails with "statfs: no such file or directory".
#
# These helpers resolve the path via realpath so it's safe for container -v flags.

make_temp() {
	local f
	f="$(mktemp)" || return 1
	realpath "$f"
}

make_tempdir() {
	local d
	d="$(mktemp -d)" || return 1
	realpath "$d"
}
