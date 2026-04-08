#!/usr/bin/env bats
# tests/e2e/lifecycle.bats — end-to-end tests for the agent-sandbox launcher.
#
# These tests exercise the full launcher-to-container lifecycle by sourcing
# agent-sandbox.sh for its functions, then constructing and running the
# container with a fake agent binary mounted over the real one.
#
# The fake agent (tests/fixtures/fake-agent) prints a sentinel marker and
# exits 0, allowing the container to complete without real API keys.
#
# IMPORTANT: These tests require a container runtime (docker or podman) and
# the agent-sandbox image to be built. Run `make ensure-image` first.
#
# Run with: bats --filter-tags e2e -r tests/

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
	load '../test_helper'

	# Skip if no container runtime is available
	RUNTIME=$(runtime_name) || skip "No container runtime found (install docker or podman)"

	# Set AGENT_SANDBOX_VERSION before sourcing the launcher so VERSION is
	# consistent between the image existence check and _run_sandbox's IMAGE_TAG.
	# The Makefile passes AGENT_SANDBOX_VERSION=$(VERSION) when invoking bats;
	# fall back to 0.1.0 for direct bats invocations.
	export AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-0.1.0}"

	# Verify the image exists — skip rather than build (build is slow and
	# belongs to CI setup, not individual test setup)
	IMAGE="agent-sandbox:${AGENT_SANDBOX_VERSION}"
	if ! "$RUNTIME" images -q "$IMAGE" 2>/dev/null | grep -q .; then
		skip "Image $IMAGE not found — run 'make ensure-image' first"
	fi

	# Create an isolated temporary workspace for this test
	WORKSPACE_DIR="$(make_tempdir)" || skip "mktemp failed: /tmp may be full"

	# Create an isolated HOME with minimal git config so the launcher's
	# gitconfig mount logic doesn't pick up the real user's config
	TEST_HOME="$(make_tempdir)" || skip "mktemp failed: /tmp may be full"
	mkdir -p "${TEST_HOME}/.config/agent-sandbox"
	cat >"${TEST_HOME}/.gitconfig" <<'GITCFG'
[user]
	name = Test User
	email = test@example.com
GITCFG

	# Source the launcher to get all its functions available in this shell.
	# The entry-point guard (BASH_SOURCE[0] == $0) prevents main() from running.
	export AGENT_SANDBOX_SHARE_DIR="${REPO_ROOT}"
	# AGENT_SANDBOX_VERSION is already set above — do not override here.
	export HOME="${TEST_HOME}"
	# Force the detected runtime for tests to avoid Podman macOS virtiofs SSH warnings
	export AGENT_SANDBOX_RUNTIME="${RUNTIME}"
	# Disable SSH forwarding to avoid socket-related warnings in test output
	export SSH_AUTH_SOCK=""

	# Prevent real API keys from leaking into test containers.
	# assemble_env_flags() forwards any of these that are set in the environment.
	# Keep this list in sync with DEFAULT_ENV_VARS in agent-sandbox.sh.
	unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY MISTRAL_API_KEY
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
	unset GITHUB_TOKEN

	# shellcheck source=../../agent-sandbox.sh
	source "${LAUNCHER}"

	# CONTAINER_NAME is set by _precompute_container_name; used in teardown for cleanup
	CONTAINER_NAME=""

	# Accumulate per-test temp files/dirs for cleanup in teardown.
	# Tests append to these arrays; teardown drains them unconditionally.
	TEST_TMPFILES=()
	TEST_TMPDIRS=()
}

teardown() {
	# Remove any leftover container (in case the test failed mid-run).
	# Guard both RUNTIME and CONTAINER_NAME: RUNTIME may be unset if setup
	# failed before the runtime_name() call.
	if [[ -n "${RUNTIME:-}" && -n "${CONTAINER_NAME:-}" ]]; then
		"$RUNTIME" rm -f "$CONTAINER_NAME" 2>/dev/null || true
	fi

	# Remove per-test temp files and directories accumulated during the test.
	# Use the ${array[@]+"${array[@]}"} idiom to avoid a spurious empty-string
	# iteration when the arrays are empty ([@]:- expands to "" not zero items).
	for f in "${TEST_TMPFILES[@]+"${TEST_TMPFILES[@]}"}"; do rm -f "$f" 2>/dev/null || true; done
	for d in "${TEST_TMPDIRS[@]+"${TEST_TMPDIRS[@]}"}"; do rm -rf "$d" 2>/dev/null || true; done

	# Remove the shared workspace and HOME directories
	[[ -d "${WORKSPACE_DIR:-}" ]] && rm -rf "$WORKSPACE_DIR" || true
	[[ -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME" || true
}

# ---------------------------------------------------------------------------
# Helper: _precompute_container_name
# ---------------------------------------------------------------------------
# Computes and sets CONTAINER_NAME in the caller's scope, given the same
# args that will be passed to _run_sandbox. Call this BEFORE `run _run_sandbox`
# so teardown has the container name even if the test fails mid-run.
#
# Without this, a container started by a failing test would be left running
# because --rm only fires on clean container exit, not on bats test failure.
#
# Usage: _precompute_container_name [launcher_args...]
_precompute_container_name() {
	parse_args "$@"
	parse_config
	apply_config_defaults
	local ws
	ws=$(resolve_workspace "${OPT_WORKSPACE}")
	CONTAINER_NAME=$(compute_container_name "$OPT_AGENT" "$ws")
}

# ---------------------------------------------------------------------------
# Helper: _run_sandbox
# ---------------------------------------------------------------------------
# Runs the container using launcher-computed flags, with the fake agent
# injected over the real agent binary and without -t (no TTY in tests).
#
# Usage: _run_sandbox [launcher_args...]
#
# NOTE: Because bats `run` executes in a subshell, CONTAINER_NAME set here
# does NOT propagate back to the test scope. Call _precompute_container_name
# before `run _run_sandbox` to ensure teardown can clean up on failure.
#
# The FAKE_AGENT global (set in test_helper.bash) controls which binary is
# injected. Tests that need a custom agent script should override FAKE_AGENT
# before calling this helper and restore it afterward.
_run_sandbox() {
	# Re-initialize launcher globals for each call (supports multiple calls
	# within one test)
	parse_args "$@"
	parse_config
	apply_config_defaults
	detect_runtime

	# Platform-specific flags
	USERNS_FLAG=""
	[[ "$RUNTIME" == "podman" ]] && USERNS_FLAG="--userns=keep-id"
	MOUNT_Z=""
	[[ "$(uname -s)" == "Linux" ]] && MOUNT_Z=",z"

	# Resolve workspace and compute container name
	WORKSPACE=$(resolve_workspace "${OPT_WORKSPACE}")
	CONTAINER_NAME=$(compute_container_name "$OPT_AGENT" "$WORKSPACE")

	# Log the container name to stderr (mirrors the launcher's main() log output)
	log "Starting sandbox: $CONTAINER_NAME"
	log "  Agent:     $OPT_AGENT"
	log "  Workspace: $WORKSPACE"

	# Use version-based image tag
	IMAGE_TAG="agent-sandbox:${VERSION}"

	# Assemble mounts and env vars using the real launcher functions
	assemble_mount_flags
	assemble_env_flags

	# Inject the fake agent over the real agent binary.
	# Determine the agent binary path dynamically from the image.
	local agent_bin
	agent_bin=$("$RUNTIME" run --rm --entrypoint which "$IMAGE_TAG" opencode 2>/dev/null || true)
	if [[ -z "$agent_bin" || "$agent_bin" != /* ]]; then
		skip "opencode binary path could not be determined in image $IMAGE_TAG"
	fi
	MOUNT_FLAGS+=("-v" "${FAKE_AGENT}:${agent_bin}:ro${MOUNT_Z}")

	# Build the run command without -t (no TTY in test environment).
	# The launcher uses `exec $RUNTIME run -i -t ...`; we omit -t here.
	local cmd=(
		run --rm -i
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
	[[ -n "$USERNS_FLAG" ]] && cmd+=("$USERNS_FLAG")
	cmd+=("${MOUNT_FLAGS[@]}" "${ENV_FLAGS[@]}" "$IMAGE_TAG")

	"$RUNTIME" "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# Test 1: Full lifecycle — fake agent runs to completion
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "full lifecycle: fake agent runs to completion and container exits cleanly" {
	_precompute_container_name --no-ssh "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh "$WORKSPACE_DIR"

	assert_success
	assert_output --partial "FAKE_AGENT_MARKER: agent-sandbox-test-sentinel"
}

# ---------------------------------------------------------------------------
# Test 2: Workspace mounting — host file visible inside container
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "workspace mount: file created on host before launch is visible inside container" {
	# Create a sentinel file in the workspace before launching
	echo "host-created-content" >"${WORKSPACE_DIR}/host-file.txt"

	# Use a custom fake agent that verifies the file exists at /workspace/
	local verify_agent
	verify_agent="$(make_temp)"
	TEST_TMPFILES+=("$verify_agent")
	chmod 700 "$verify_agent"
	cat >"$verify_agent" <<'AGENT'
#!/usr/bin/env bash
if [[ -f /workspace/host-file.txt ]]; then
    echo "WORKSPACE_FILE_VISIBLE: yes"
    cat /workspace/host-file.txt
else
    echo "WORKSPACE_FILE_VISIBLE: no"
    exit 1
fi
exit 0
AGENT

	# FAKE_AGENT is a global read by _run_sandbox; save/restore to scope the
	# override to this test.
	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$verify_agent"

	_precompute_container_name --no-ssh "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "WORKSPACE_FILE_VISIBLE: yes"
	assert_output --partial "host-created-content"
}

# ---------------------------------------------------------------------------
# Test 3: Workspace mounting — file written inside container appears on host
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "workspace mount: file written inside container appears on host filesystem" {
	# Use a custom fake agent that writes a file to /workspace/
	local write_agent
	write_agent="$(make_temp)"
	TEST_TMPFILES+=("$write_agent")
	chmod 700 "$write_agent"
	cat >"$write_agent" <<'AGENT'
#!/usr/bin/env bash
echo "written-from-container" >/workspace/container-created-file.txt
echo "CONTAINER_WRITE: done"
exit 0
AGENT

	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$write_agent"

	_precompute_container_name --no-ssh "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "CONTAINER_WRITE: done"

	# Verify the file was written to the host workspace
	assert [ -f "${WORKSPACE_DIR}/container-created-file.txt" ]
	run cat "${WORKSPACE_DIR}/container-created-file.txt"
	assert_output "written-from-container"
}

# ---------------------------------------------------------------------------
# Test 4: Container naming — deterministic name matches expected pattern
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "container naming: container name matches deterministic pattern" {
	# Compute the expected container name using the launcher's own functions.
	# This verifies the naming formula: agent-sandbox-<agent>-<basename>-<6-char-hash>
	parse_args --no-ssh "$WORKSPACE_DIR"
	parse_config
	apply_config_defaults

	local ws
	ws=$(resolve_workspace "$WORKSPACE_DIR")
	local expected_name
	expected_name=$(compute_container_name "$OPT_AGENT" "$ws")

	# Verify the name matches the expected pattern
	assert [ -n "$expected_name" ]

	# Pre-compute container name for teardown cleanup
	CONTAINER_NAME="$expected_name"

	# Run the container and capture combined output (stdout + stderr).
	# _run_sandbox emits "Starting sandbox: <name>" to stderr; bats `run`
	# captures stderr merged with stdout when calling a shell function.
	run _run_sandbox --no-ssh "$WORKSPACE_DIR"
	assert_success

	assert_output --partial "Starting sandbox: ${expected_name}"
}

# ---------------------------------------------------------------------------
# Test 5: Symlink mounting — --follow-symlinks mounts external directory
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "symlink mount: --follow-symlinks makes external symlink target accessible in container" {
	# Create an external directory with a sentinel file.
	# Resolve to canonical path immediately: portable_realpath (called by
	# collect_symlink_mounts) resolves /var/folders -> /private/var/folders on
	# macOS, so the bind-mount uses the canonical path. The verify_agent script
	# must use the same canonical path to find the file.
	local external_dir
	external_dir="$(make_tempdir)"
	external_dir="$(portable_realpath "$external_dir")"
	TEST_TMPDIRS+=("$external_dir")
	echo "external-content" >"${external_dir}/external-file.txt"

	# Create a symlink in the workspace pointing to the external directory
	ln -s "$external_dir" "${WORKSPACE_DIR}/external-link"

	# Use a custom fake agent that verifies the external directory is accessible.
	# Unquoted heredoc: interpolates ${external_dir} from mktemp (no user input).
	local verify_agent
	verify_agent="$(make_temp)"
	TEST_TMPFILES+=("$verify_agent")
	chmod 700 "$verify_agent"
	cat >"$verify_agent" <<AGENT
#!/usr/bin/env bash
# The external dir is mounted at its absolute (canonical) host path
if [[ -f "${external_dir}/external-file.txt" ]]; then
    echo "SYMLINK_TARGET_VISIBLE: yes"
    cat "${external_dir}/external-file.txt"
else
    echo "SYMLINK_TARGET_VISIBLE: no"
    ls -la /workspace/ >&2
    exit 1
fi
exit 0
AGENT

	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$verify_agent"

	_precompute_container_name --no-ssh --follow-symlinks "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh --follow-symlinks "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "SYMLINK_TARGET_VISIBLE: yes"
	assert_output --partial "external-content"
}

# ---------------------------------------------------------------------------
# Test 6: Symlink mounting — dotfile symlinks skipped without --follow-all-symlinks
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "symlink mount: dotfile symlink targets are skipped without --follow-all-symlinks" {
	# Create an external dotfile directory.
	# Use mktemp's random suffix to avoid PID-predictable names; rename to a
	# dotfile name while preserving the random suffix for uniqueness.
	local dotdir
	dotdir="$(make_tempdir)"
	local dotdir_parent
	dotdir_parent="$(dirname "$dotdir")"
	local dotdir_name=".test-dotdir-$(basename "$dotdir")"
	mv "$dotdir" "${dotdir_parent}/${dotdir_name}" || {
		echo "mv failed: ${dotdir_parent}/${dotdir_name} may already exist" >&2
		return 1
	}
	dotdir="${dotdir_parent}/${dotdir_name}"
	dotdir="$(portable_realpath "$dotdir")"
	TEST_TMPDIRS+=("$dotdir")
	echo "dotfile-content" >"${dotdir}/secret.txt"

	# Create a symlink to the dotfile directory in the workspace
	ln -s "$dotdir" "${WORKSPACE_DIR}/.dotlink"

	# Use a custom fake agent that checks whether the dotdir is accessible.
	# Unquoted heredoc: interpolates ${dotdir} from mktemp (no user input).
	local verify_agent
	verify_agent="$(make_temp)"
	TEST_TMPFILES+=("$verify_agent")
	chmod 700 "$verify_agent"
	cat >"$verify_agent" <<AGENT
#!/usr/bin/env bash
# The dotdir should NOT be mounted (dotfile protection)
if [[ -f "${dotdir}/secret.txt" ]]; then
    echo "DOTDIR_MOUNTED: yes"
    exit 1
else
    echo "DOTDIR_MOUNTED: no"
fi
exit 0
AGENT

	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$verify_agent"

	# --follow-symlinks without --follow-all-symlinks: dotfiles should be skipped
	_precompute_container_name --no-ssh --follow-symlinks "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh --follow-symlinks "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "DOTDIR_MOUNTED: no"
	# The launcher should have logged a warning about skipping the dotfile
	assert_output --partial "Skipping dotfile symlink target"
}

# ---------------------------------------------------------------------------
# Test 7: Symlink mounting — --follow-all-symlinks includes dotfile directories
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "symlink mount: --follow-all-symlinks includes dotfile symlink targets" {
	# Create an external dotfile directory (same pattern as test 6)
	local dotdir
	dotdir="$(make_tempdir)"
	local dotdir_parent
	dotdir_parent="$(dirname "$dotdir")"
	local dotdir_name=".test-dotdir-all-$(basename "$dotdir")"
	mv "$dotdir" "${dotdir_parent}/${dotdir_name}" || {
		echo "mv failed: ${dotdir_parent}/${dotdir_name} may already exist" >&2
		return 1
	}
	dotdir="${dotdir_parent}/${dotdir_name}"
	dotdir="$(portable_realpath "$dotdir")"
	TEST_TMPDIRS+=("$dotdir")
	echo "dotfile-content" >"${dotdir}/secret.txt"

	# Create a symlink to the dotfile directory in the workspace
	ln -s "$dotdir" "${WORKSPACE_DIR}/.dotlink"

	# Use a custom fake agent that verifies the dotdir IS accessible.
	# Unquoted heredoc: interpolates ${dotdir} from mktemp (no user input).
	local verify_agent
	verify_agent="$(make_temp)"
	TEST_TMPFILES+=("$verify_agent")
	chmod 700 "$verify_agent"
	cat >"$verify_agent" <<AGENT
#!/usr/bin/env bash
# The dotdir SHOULD be mounted with --follow-all-symlinks
if [[ -f "${dotdir}/secret.txt" ]]; then
    echo "DOTDIR_MOUNTED: yes"
    cat "${dotdir}/secret.txt"
else
    echo "DOTDIR_MOUNTED: no"
    exit 1
fi
exit 0
AGENT

	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$verify_agent"

	_precompute_container_name --no-ssh --follow-all-symlinks "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh --follow-all-symlinks "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "DOTDIR_MOUNTED: yes"
	assert_output --partial "dotfile-content"
}

# ---------------------------------------------------------------------------
# Test 8: Extra mount — --mount makes host path accessible in container
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "extra mount: --mount makes a host directory accessible inside the container" {
	# Create an extra host directory with a sentinel file.
	# Resolve to canonical path: collect_extra_mounts calls portable_realpath,
	# so the bind-mount uses the canonical path inside the container.
	local extra_dir
	extra_dir="$(make_tempdir)"
	extra_dir="$(portable_realpath "$extra_dir")"
	TEST_TMPDIRS+=("$extra_dir")
	echo "extra-mount-content" >"${extra_dir}/extra-file.txt"

	# Use a custom fake agent that verifies the extra mount is accessible.
	# Unquoted heredoc: interpolates ${extra_dir} from mktemp (no user input).
	local verify_agent
	verify_agent="$(make_temp)"
	TEST_TMPFILES+=("$verify_agent")
	chmod 700 "$verify_agent"
	cat >"$verify_agent" <<AGENT
#!/usr/bin/env bash
# Extra mounts outside HOME are mounted at their absolute (canonical) path
if [[ -f "${extra_dir}/extra-file.txt" ]]; then
    echo "EXTRA_MOUNT_VISIBLE: yes"
    cat "${extra_dir}/extra-file.txt"
else
    echo "EXTRA_MOUNT_VISIBLE: no"
    exit 1
fi
exit 0
AGENT

	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$verify_agent"

	_precompute_container_name --no-ssh --mount "$extra_dir" "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh --mount "$extra_dir" "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "EXTRA_MOUNT_VISIBLE: yes"
	assert_output --partial "extra-mount-content"
}

# ---------------------------------------------------------------------------
# Test 9: AGENT env var — entrypoint receives correct AGENT value
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "env passthrough: AGENT env var is set to 'opencode' inside the container" {
	# Use a custom fake agent that prints the AGENT env var
	local verify_agent
	verify_agent="$(make_temp)"
	TEST_TMPFILES+=("$verify_agent")
	chmod 700 "$verify_agent"
	cat >"$verify_agent" <<'AGENT'
#!/usr/bin/env bash
echo "AGENT_VALUE: ${AGENT:-unset}"
exit 0
AGENT

	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$verify_agent"

	_precompute_container_name --no-ssh "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "AGENT_VALUE: opencode"
}

# ---------------------------------------------------------------------------
# Test 10: --no-ssh flag — AGENT_SANDBOX_NO_SSH is set in container
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "no-ssh flag: AGENT_SANDBOX_NO_SSH env var is set inside container when --no-ssh is passed" {
	local verify_agent
	verify_agent="$(make_temp)"
	TEST_TMPFILES+=("$verify_agent")
	chmod 700 "$verify_agent"
	cat >"$verify_agent" <<'AGENT'
#!/usr/bin/env bash
echo "NO_SSH_VALUE: ${AGENT_SANDBOX_NO_SSH:-unset}"
exit 0
AGENT

	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$verify_agent"

	_precompute_container_name --no-ssh "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "NO_SSH_VALUE: 1"
}

# ---------------------------------------------------------------------------
# Test 12: Gitconfig mount — host gitconfig is accessible in container
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "gitconfig mount: host .gitconfig is mounted read-only at /home/sandbox/.gitconfig" {
	local verify_agent
	verify_agent="$(make_temp)"
	TEST_TMPFILES+=("$verify_agent")
	chmod 700 "$verify_agent"
	cat >"$verify_agent" <<'AGENT'
#!/usr/bin/env bash
if [[ -f /home/sandbox/.gitconfig ]]; then
    echo "GITCONFIG_VISIBLE: yes"
    grep -q "Test User" /home/sandbox/.gitconfig && echo "GITCONFIG_NAME: correct"
else
    echo "GITCONFIG_VISIBLE: no"
    exit 1
fi
exit 0
AGENT

	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$verify_agent"

	_precompute_container_name --no-ssh "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "GITCONFIG_VISIBLE: yes"
	assert_output --partial "GITCONFIG_NAME: correct"
}

# ---------------------------------------------------------------------------
# Test 13: Container removed after exit (--rm flag)
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "container lifecycle: container is removed after the fake agent exits (--rm)" {
	# Compute the expected container name before running
	_precompute_container_name --no-ssh "$WORKSPACE_DIR"
	local expected_name="$CONTAINER_NAME"

	# Run the container to completion
	run _run_sandbox --no-ssh "$WORKSPACE_DIR"
	assert_success

	# After exit, the container should not exist (--rm removes it)
	run "$RUNTIME" inspect "$expected_name" 2>&1
	assert_failure
}

# ---------------------------------------------------------------------------
# Test 14: Workspace is the working directory inside the container
# ---------------------------------------------------------------------------

# bats test_tags=e2e
@test "workspace mount: /workspace is the working directory when the agent runs" {
	local verify_agent
	verify_agent="$(make_temp)"
	TEST_TMPFILES+=("$verify_agent")
	chmod 700 "$verify_agent"
	cat >"$verify_agent" <<'AGENT'
#!/usr/bin/env bash
echo "PWD_VALUE: $(pwd)"
exit 0
AGENT

	local orig_fake_agent="$FAKE_AGENT"
	FAKE_AGENT="$verify_agent"

	_precompute_container_name --no-ssh "$WORKSPACE_DIR"
	run _run_sandbox --no-ssh "$WORKSPACE_DIR"

	FAKE_AGENT="$orig_fake_agent"

	assert_success
	assert_output --partial "PWD_VALUE: /workspace"
}
