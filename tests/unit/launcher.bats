#!/usr/bin/env bats
# tests/unit/launcher.bats — unit tests for agent-sandbox.sh functions
#
# These tests source the launcher script and exercise individual functions in
# isolation. No container runtime is required.
#
# Run with:
#   bats --filter-tags unit tests/unit/launcher.bats
# or via make:
#   make test-unit

load '../test_helper'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
    # Set required env vars before sourcing so the script doesn't fail on
    # unset @SHARE_DIR@ / @VERSION@ placeholders.
    export AGENT_SANDBOX_SHARE_DIR="${REPO_ROOT}"
    export AGENT_SANDBOX_VERSION="0.1.0-test"

    # Redirect HOME to a temp dir so the script doesn't load the real user
    # config and so CONFIG_FILE defaults to a non-existent path.
    export HOME
    HOME="$(mktemp -d)"
    # Track the temp HOME for cleanup in teardown
    _TEST_HOME="$HOME"

    # Source the launcher — functions become available in this shell.
    # The BASH_SOURCE guard prevents main() from running.
    # shellcheck disable=SC1090
    source "${LAUNCHER}"
}

teardown() {
    # Clean up the temp HOME directory created in setup.
    # Use the tracked variable rather than $HOME (which may have been
    # overridden by a test) and guard against empty/root paths.
    if [[ -n "${_TEST_HOME:-}" && "$_TEST_HOME" != "/" ]]; then
        rm -rf "$_TEST_HOME"
    fi
    if [[ -n "${_SYMLINK_WS:-}" && "$_SYMLINK_WS" != "/" ]]; then
        rm -rf "$_SYMLINK_WS"
    fi
    if [[ -n "${_EXTERNAL_DIR:-}" && "$_EXTERNAL_DIR" != "/" ]]; then
        rm -rf "$_EXTERNAL_DIR"
    fi
    if [[ -n "${_TEST_TMPDIR:-}" && "$_TEST_TMPDIR" != "/" ]]; then
        rm -rf "$_TEST_TMPDIR"
    fi
    if [[ -n "${_TEST_TMPDIR2:-}" && "$_TEST_TMPDIR2" != "/" ]]; then
        rm -rf "$_TEST_TMPDIR2"
    fi
}

# ---------------------------------------------------------------------------
# ENV_FLAGS assertion helpers
# ---------------------------------------------------------------------------

# Assert that ENV_FLAGS array contains a "-e" entry with the given value.
assert_env_flag() {
    local expected="$1"
    local found=0
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$((i+1))]}" == "$expected" ]]; then
            found=1
            break
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        echo "Expected ENV_FLAGS to contain '-e $expected'" >&2
        echo "Actual ENV_FLAGS: ${ENV_FLAGS[*]}" >&2
        return 1
    fi
}

# Assert that ENV_FLAGS array does NOT contain a "-e" entry with the given value.
refute_env_flag() {
    local unexpected="$1"
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$((i+1))]}" == "$unexpected" ]]; then
            echo "Expected ENV_FLAGS NOT to contain '-e $unexpected'" >&2
            echo "Actual ENV_FLAGS: ${ENV_FLAGS[*]}" >&2
            return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Symlink workspace factory helper
# ---------------------------------------------------------------------------

# Set up a common symlink workspace structure for symlink mount tests.
# Creates a temp workspace dir with a symlink to an external temp dir.
# Sets _SYMLINK_WS and _EXTERNAL_DIR in the caller's scope.
# Cleanup is handled by teardown() via _SYMLINK_WS and _EXTERNAL_DIR.
_setup_symlink_workspace() {
    _SYMLINK_WS="$(mktemp -d)"
    _EXTERNAL_DIR="$(mktemp -d)"
    echo "content" > "$_EXTERNAL_DIR/file.txt"
    ln -s "$_EXTERNAL_DIR" "$_SYMLINK_WS/external-link"
}

# ---------------------------------------------------------------------------
# 1. Argument Parsing Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "parse_args: no arguments sets all OPT_ vars to defaults" {
    parse_args

    assert_equal "$OPT_AGENT"               ""
    assert_equal "$OPT_PULL"                false
    assert_equal "$OPT_FOLLOW_SYMLINKS"     false
    assert_equal "$OPT_FOLLOW_ALL_SYMLINKS" false
    assert_equal "$OPT_NO_SSH"              false
    assert_equal "$OPT_LIST"                false
    assert_equal "$OPT_STOP"                false
    assert_equal "$OPT_PRUNE"               false
    assert_equal "$OPT_UPDATE"              false
    assert_equal "$OPT_HELP"                false
    assert_equal "$OPT_VERSION"             false
    assert_equal "${#OPT_EXTRA_MOUNTS[@]}"  0
    assert_equal "$OPT_WORKSPACE"           ""
}

# bats test_tags=unit
@test "parse_args: --agent opencode sets OPT_AGENT to opencode" {
    parse_args --agent opencode

    assert_equal "$OPT_AGENT" "opencode"
}

# bats test_tags=unit
@test "parse_args: -a shorthand sets OPT_AGENT" {
    parse_args -a opencode

    assert_equal "$OPT_AGENT" "opencode"
}

# bats test_tags=unit
@test "parse_args: --agent does NOT validate value (validation is in apply_config_defaults)" {
    # parse_args just stores whatever is passed; no die() for invalid agent names
    parse_args --agent invalid-value

    assert_equal "$OPT_AGENT" "invalid-value"
}

# bats test_tags=unit
@test "parse_args: --pull sets OPT_PULL to true" {
    parse_args --pull

    assert_equal "$OPT_PULL" true
}

# bats test_tags=unit
@test "parse_args: -b shorthand sets OPT_PULL to true" {
    parse_args -b

    assert_equal "$OPT_PULL" true
}

# bats test_tags=unit
@test "parse_args: --no-ssh sets OPT_NO_SSH to true" {
    parse_args --no-ssh

    assert_equal "$OPT_NO_SSH" true
}

# bats test_tags=unit
@test "parse_args: --follow-symlinks sets OPT_FOLLOW_SYMLINKS to true" {
    parse_args --follow-symlinks

    assert_equal "$OPT_FOLLOW_SYMLINKS"     true
    assert_equal "$OPT_FOLLOW_ALL_SYMLINKS" false
}

# bats test_tags=unit
@test "parse_args: --follow-all-symlinks sets both OPT_FOLLOW_ALL_SYMLINKS and OPT_FOLLOW_SYMLINKS to true" {
    parse_args --follow-all-symlinks

    assert_equal "$OPT_FOLLOW_ALL_SYMLINKS" true
    assert_equal "$OPT_FOLLOW_SYMLINKS"     true
}

# bats test_tags=unit
@test "parse_args: --list sets OPT_LIST to true" {
    parse_args --list

    assert_equal "$OPT_LIST" true
}

# bats test_tags=unit
@test "parse_args: --stop sets OPT_STOP to true" {
    parse_args --stop

    assert_equal "$OPT_STOP" true
}

# bats test_tags=unit
@test "parse_args: --prune sets OPT_PRUNE to true" {
    parse_args --prune

    assert_equal "$OPT_PRUNE" true
}

# bats test_tags=unit
@test "parse_args: --version sets OPT_VERSION to true" {
    parse_args --version

    assert_equal "$OPT_VERSION" true
}

# bats test_tags=unit
@test "parse_args: -v shorthand sets OPT_VERSION to true" {
    parse_args -v

    assert_equal "$OPT_VERSION" true
}

# bats test_tags=unit
@test "parse_args: --help sets OPT_HELP to true" {
    parse_args --help

    assert_equal "$OPT_HELP" true
}

# bats test_tags=unit
@test "parse_args: -h shorthand sets OPT_HELP to true" {
    parse_args -h

    assert_equal "$OPT_HELP" true
}

# bats test_tags=unit
@test "parse_args: --update sets OPT_UPDATE to true" {
    parse_args --update

    assert_equal "$OPT_UPDATE" true
}

# bats test_tags=unit
@test "parse_args: positional argument sets OPT_WORKSPACE" {
    parse_args /some/path

    assert_equal "$OPT_WORKSPACE" "/some/path"
}

# bats test_tags=unit
@test "parse_args: --mount adds to OPT_EXTRA_MOUNTS" {
    parse_args --mount /foo/bar

    assert_equal "${#OPT_EXTRA_MOUNTS[@]}" 1
    assert_equal "${OPT_EXTRA_MOUNTS[0]}"  "/foo/bar"
}

# bats test_tags=unit
@test "parse_args: multiple --mount flags accumulate in OPT_EXTRA_MOUNTS" {
    parse_args --mount /foo/bar --mount /baz/qux

    assert_equal "${#OPT_EXTRA_MOUNTS[@]}" 2
    assert_equal "${OPT_EXTRA_MOUNTS[0]}"  "/foo/bar"
    assert_equal "${OPT_EXTRA_MOUNTS[1]}"  "/baz/qux"
}

# bats test_tags=unit
@test "parse_args: unknown flag exits with non-zero code and error message" {
    run parse_args --invalid-flag

    assert_failure
    assert_output --partial "Unknown option"
}

# bats test_tags=unit
@test "parse_args: second positional argument exits with error" {
    run parse_args /first/path /second/path

    assert_failure
    assert_output --partial "Unexpected argument"
}

# bats test_tags=unit
@test "parse_args: --agent without argument exits with error" {
    run parse_args --agent

    assert_failure
    assert_output --partial "--agent requires an argument"
}

# bats test_tags=unit
@test "parse_args: --mount without argument exits with error" {
    run parse_args --mount

    assert_failure
    assert_output --partial "--mount requires an argument"
}

# bats test_tags=unit
@test "parse_args: -- stops option processing and remaining args become positional" {
    # After `--`, remaining arguments are treated as positional args.
    parse_args -- /my/workspace

    assert_equal "$OPT_WORKSPACE" "/my/workspace"
}

# ---------------------------------------------------------------------------
# 2. apply_config_defaults Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "apply_config_defaults: empty OPT_AGENT falls back to CFG_AGENT" {
    parse_args
    CFG_AGENT="opencode"
    apply_config_defaults

    assert_equal "$OPT_AGENT" "opencode"
}

# bats test_tags=unit
@test "apply_config_defaults: CLI --agent takes precedence over CFG_AGENT" {
    parse_args --agent opencode
    CFG_AGENT="opencode"
    apply_config_defaults

    assert_equal "$OPT_AGENT" "opencode"
}

# bats test_tags=unit
@test "apply_config_defaults: invalid agent value exits with error" {
    parse_args --agent invalid-agent
    CFG_AGENT="opencode"

    run apply_config_defaults

    assert_failure
    assert_output --partial "must be 'opencode'"
}

# bats test_tags=unit
@test "apply_config_defaults: CFG_FOLLOW_SYMLINKS=true propagates to OPT_FOLLOW_SYMLINKS" {
    parse_args
    CFG_AGENT="opencode"
    CFG_FOLLOW_SYMLINKS=true
    CFG_FOLLOW_ALL_SYMLINKS=false
    apply_config_defaults

    assert_equal "$OPT_FOLLOW_SYMLINKS" true
}

# bats test_tags=unit
@test "apply_config_defaults: CFG_FOLLOW_ALL_SYMLINKS=true sets both follow flags" {
    parse_args
    CFG_AGENT="opencode"
    CFG_FOLLOW_SYMLINKS=false
    CFG_FOLLOW_ALL_SYMLINKS=true
    apply_config_defaults

    assert_equal "$OPT_FOLLOW_ALL_SYMLINKS" true
    assert_equal "$OPT_FOLLOW_SYMLINKS"     true
}

# bats test_tags=unit
@test "apply_config_defaults: CLI --follow-symlinks is not overridden by CFG_FOLLOW_SYMLINKS=false" {
    parse_args --follow-symlinks
    CFG_AGENT="opencode"
    CFG_FOLLOW_SYMLINKS=false
    apply_config_defaults

    assert_equal "$OPT_FOLLOW_SYMLINKS" true
}

# ---------------------------------------------------------------------------
# 3. Config Loading Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "parse_config: missing config file succeeds silently and does not reset scalar values" {
    # parse_config only resets arrays (CFG_EXTRA_VARS, CFG_EXTRA_PATHS) when the
    # file is missing — it does NOT reset scalar values. Set them to non-default
    # values first to verify they are preserved (not reset) on a missing file.
    CFG_AGENT="opencode"
    CFG_MEMORY="32g"
    CFG_CPUS=16
    CFG_FOLLOW_SYMLINKS=true

    CONFIG_FILE="/nonexistent/path/config.toml"
    parse_config

    # Scalar values must be unchanged (parse_config is a no-op for scalars when file is missing)
    assert_equal "$CFG_AGENT"           "opencode"
    assert_equal "$CFG_MEMORY"          "32g"
    assert_equal "$CFG_CPUS"            16
    assert_equal "$CFG_FOLLOW_SYMLINKS" true
    # Arrays are reset to empty
    assert_equal "${#CFG_EXTRA_VARS[@]}" 0
}

# bats test_tags=unit
@test "parse_config: valid config sets all fields correctly" {
    CONFIG_FILE="${FIXTURE_DIR}/config-valid.toml"
    parse_config

    assert_equal "$CFG_AGENT"            "opencode"
    assert_equal "$CFG_MEMORY"           "16g"
    assert_equal "$CFG_CPUS"             8
    assert_equal "$CFG_FOLLOW_SYMLINKS"  true
    assert_equal "${#CFG_EXTRA_VARS[@]}" 1
    assert_equal "${CFG_EXTRA_VARS[0]}"  "CUSTOM_VAR"
}

# bats test_tags=unit
@test "parse_config: partial config only sets specified values" {
    # Reset to known defaults first
    CFG_AGENT="opencode"
    CFG_MEMORY="8g"
    CFG_CPUS=4
    CFG_FOLLOW_SYMLINKS=false
    CFG_EXTRA_VARS=()

    CONFIG_FILE="${FIXTURE_DIR}/config-partial.toml"
    parse_config

    # Only agent was set in the partial config
    assert_equal "$CFG_AGENT"            "opencode"
    # Other values should remain at defaults
    assert_equal "$CFG_MEMORY"           "8g"
    assert_equal "$CFG_CPUS"             4
    assert_equal "$CFG_FOLLOW_SYMLINKS"  false
    assert_equal "${#CFG_EXTRA_VARS[@]}" 0
}

# bats test_tags=unit
@test "parse_config: invalid TOML exits with error" {
    CONFIG_FILE="${FIXTURE_DIR}/config-invalid.toml"

    run parse_config

    assert_failure
    assert_output --partial "malformed TOML"
}

# bats test_tags=unit
@test "parse_config: repeated calls reset arrays (no accumulation)" {
    CONFIG_FILE="${FIXTURE_DIR}/config-valid.toml"
    parse_config
    parse_config  # second call should not double the arrays

    assert_equal "${#CFG_EXTRA_VARS[@]}" 1
}

# ---------------------------------------------------------------------------
# 4. Container Naming Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "sanitize_basename: lowercases uppercase letters" {
    local result
    result=$(sanitize_basename "MyProject")

    assert_equal "$result" "myproject"
}

# bats test_tags=unit
@test "sanitize_basename: strips underscores" {
    local result
    result=$(sanitize_basename "my_project")

    assert_equal "$result" "myproject"
}

# bats test_tags=unit
@test "sanitize_basename: strips dots" {
    local result
    result=$(sanitize_basename "project.v2")

    assert_equal "$result" "projectv2"
}

# bats test_tags=unit
@test "sanitize_basename: preserves hyphens" {
    local result
    result=$(sanitize_basename "my-project")

    assert_equal "$result" "my-project"
}

# bats test_tags=unit
@test "sanitize_basename: strips special characters leaving only [a-z0-9-]" {
    local result
    result=$(sanitize_basename "My_Project.v2")

    # Only lowercase alphanumeric and hyphens remain
    assert_regex "$result" "^[a-z0-9-]+$"
    assert_equal "$result" "myprojectv2"
}

# bats test_tags=unit
@test "sanitize_basename: handles empty string" {
    local result
    result=$(sanitize_basename "")

    assert_equal "$result" ""
}

# bats test_tags=unit
@test "sanitize_basename: strips spaces" {
    local result
    result=$(sanitize_basename "my project")

    assert_equal "$result" "myproject"
}

# bats test_tags=unit
@test "compute_workspace_hash: returns a 6-character hex string" {
    local result
    result=$(compute_workspace_hash "/home/user/my-project")

    assert_equal "${#result}" 6
    assert_regex "$result" "^[0-9a-f]{6}$"
}

# bats test_tags=unit
@test "compute_workspace_hash: same path always produces the same hash (deterministic)" {
    local hash1 hash2
    hash1=$(compute_workspace_hash "/home/user/my-project")
    hash2=$(compute_workspace_hash "/home/user/my-project")

    assert_equal "$hash1" "$hash2"
}

# bats test_tags=unit
@test "compute_workspace_hash: different paths produce different hashes" {
    local hash1 hash2
    hash1=$(compute_workspace_hash "/home/user/project-a")
    hash2=$(compute_workspace_hash "/home/user/project-b")

    assert_not_equal "$hash1" "$hash2"
}

# bats test_tags=unit
@test "compute_container_name: returns expected pattern for opencode agent" {
    local result
    result=$(compute_container_name "opencode" "/home/user/my-project")

    # Should match: agent-sandbox-opencode-my-project-<6chars>
    assert_regex "$result" "^agent-sandbox-opencode-my-project-[0-9a-f]{6}$"
}

# bats test_tags=unit
@test "compute_container_name: same path always produces the same name (deterministic)" {
    local name1 name2
    name1=$(compute_container_name "opencode" "/home/user/my-project")
    name2=$(compute_container_name "opencode" "/home/user/my-project")

    assert_equal "$name1" "$name2"
}

# bats test_tags=unit
@test "compute_container_name: different paths produce different names" {
    local name1 name2
    name1=$(compute_container_name "opencode" "/home/user/project-a")
    name2=$(compute_container_name "opencode" "/home/user/project-b")

    assert_not_equal "$name1" "$name2"
}

# bats test_tags=unit
@test "compute_container_name: sanitizes basename with special characters" {
    local result
    result=$(compute_container_name "opencode" "/home/user/My_Project.v2")

    # Basename "My_Project.v2" → sanitized to "myprojectv2"
    assert_regex "$result" "^agent-sandbox-opencode-myprojectv2-[0-9a-f]{6}$"
}

# bats test_tags=unit
@test "compute_container_name: name contains only safe characters" {
    local result
    result=$(compute_container_name "opencode" "/home/user/my-project")

    # Container names must be safe for use as DNS names / container identifiers
    assert_regex "$result" "^[a-z0-9-]+$"
}

# ---------------------------------------------------------------------------
# 6. Symlink Resolution Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "collect_symlink_mounts: mounts external directory symlinks" {
    _setup_symlink_workspace
    mkdir -p "${_EXTERNAL_DIR}/some-content"

    # Resolve paths as the launcher will (portable_realpath resolves /var -> /private/var on macOS)
    local resolved_ext
    resolved_ext=$(portable_realpath "$_EXTERNAL_DIR")

    WORKSPACE="$_SYMLINK_WS"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    collect_symlink_mounts

    # The resolved external dir should appear in MOUNT_FLAGS
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == "${resolved_ext}:${resolved_ext}:rw" ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" true
}

# bats test_tags=unit
@test "collect_symlink_mounts: skips broken symlinks" {
    _TEST_TMPDIR="$(mktemp -d)"
    local workspace="$_TEST_TMPDIR"

    ln -s "/nonexistent/broken-target" "${workspace}/broken-link"

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    # Should not fail even with broken symlinks
    collect_symlink_mounts

    # /nonexistent/broken-target must not appear in MOUNT_FLAGS
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"broken-target"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" false
}

# bats test_tags=unit
@test "collect_symlink_mounts: skips dotfile dirs when OPT_FOLLOW_ALL_SYMLINKS=false" {
    _TEST_TMPDIR="$(mktemp -d)"
    _TEST_TMPDIR2="$(mktemp -d)"
    local workspace="$_TEST_TMPDIR"
    local dot_parent="$_TEST_TMPDIR2"
    local dot_dir="${dot_parent}/.dotfile-test-$$"
    mkdir -p "$dot_dir"

    ln -s "$dot_dir" "${workspace}/link-to-dotdir"

    # Resolve as the launcher will
    local resolved_dot
    resolved_dot=$(portable_realpath "$dot_dir")

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    collect_symlink_mounts

    # The dotfile dir must NOT appear in MOUNT_FLAGS
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"${resolved_dot}"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" false
}

# bats test_tags=unit
@test "collect_symlink_mounts: includes dotfile dirs when OPT_FOLLOW_ALL_SYMLINKS=true" {
    _TEST_TMPDIR="$(mktemp -d)"
    _TEST_TMPDIR2="$(mktemp -d)"
    local workspace="$_TEST_TMPDIR"
    local dot_parent="$_TEST_TMPDIR2"
    local dot_dir="${dot_parent}/.dotfile-test-$$"
    mkdir -p "$dot_dir"

    ln -s "$dot_dir" "${workspace}/link-to-dotdir"

    # Resolve as the launcher will
    local resolved_dot
    resolved_dot=$(portable_realpath "$dot_dir")

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=true

    collect_symlink_mounts

    # The dotfile dir SHOULD appear in MOUNT_FLAGS
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"${resolved_dot}"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" true
}

# bats test_tags=unit
@test "collect_symlink_mounts: skips regular directories (non-symlinks)" {
    _TEST_TMPDIR="$(mktemp -d)"
    local workspace="$_TEST_TMPDIR"

    mkdir -p "${workspace}/regular-dir"

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    collect_symlink_mounts

    # The regular-dir inside the workspace must not appear as a separate mount
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"regular-dir"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" false
}

# bats test_tags=unit
@test "collect_symlink_mounts: deduplicates identical symlink targets" {
    _setup_symlink_workspace
    # Add a second symlink pointing to the same external directory
    ln -s "$_EXTERNAL_DIR" "$_SYMLINK_WS/link-b"

    # Resolve as the launcher will
    local resolved_ext
    resolved_ext=$(portable_realpath "$_EXTERNAL_DIR")

    WORKSPACE="$_SYMLINK_WS"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    collect_symlink_mounts

    # Count how many times the resolved external dir appears as a mount value in MOUNT_FLAGS
    local count=0
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == "${resolved_ext}:${resolved_ext}:rw" ]]; then
            count=$((count + 1))
        fi
    done
    assert_equal "$count" 1
}

# ---------------------------------------------------------------------------
# 7. Environment Variable Passthrough Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "assemble_env_flags: always includes AGENT env var" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()

    assemble_env_flags

    assert_env_flag "AGENT=opencode"
}

# bats test_tags=unit
@test "assemble_env_flags: includes set API key env vars" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()
    export ANTHROPIC_API_KEY="test-key-value"
    unset OPENAI_API_KEY 2>/dev/null || true

    assemble_env_flags

    unset ANTHROPIC_API_KEY

    assert_env_flag "ANTHROPIC_API_KEY"
    refute_env_flag "OPENAI_API_KEY"
}

# bats test_tags=unit
@test "assemble_env_flags: does not include unset API key env vars" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()
    unset ANTHROPIC_API_KEY  2>/dev/null || true
    unset OPENAI_API_KEY     2>/dev/null || true
    unset OPENROUTER_API_KEY 2>/dev/null || true
    unset MISTRAL_API_KEY    2>/dev/null || true
    unset AWS_ACCESS_KEY_ID  2>/dev/null || true
    unset AWS_SECRET_ACCESS_KEY 2>/dev/null || true
    unset AWS_SESSION_TOKEN  2>/dev/null || true
    unset GITHUB_TOKEN       2>/dev/null || true

    assemble_env_flags

    refute_env_flag "ANTHROPIC_API_KEY"
    refute_env_flag "OPENAI_API_KEY"
    refute_env_flag "OPENROUTER_API_KEY"
    refute_env_flag "MISTRAL_API_KEY"
    refute_env_flag "AWS_ACCESS_KEY_ID"
    refute_env_flag "AWS_SECRET_ACCESS_KEY"
    refute_env_flag "AWS_SESSION_TOKEN"
    refute_env_flag "GITHUB_TOKEN"
}

# bats test_tags=unit
@test "assemble_env_flags: includes CFG_EXTRA_VARS when set" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=("MY_CUSTOM_VAR")
    export MY_CUSTOM_VAR="custom-value"

    assemble_env_flags

    unset MY_CUSTOM_VAR

    assert_env_flag "MY_CUSTOM_VAR"
}

# bats test_tags=unit
@test "assemble_env_flags: does not include CFG_EXTRA_VARS when var is unset" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=("MY_UNSET_VAR")
    unset MY_UNSET_VAR 2>/dev/null || true

    assemble_env_flags

    refute_env_flag "MY_UNSET_VAR"
}

# bats test_tags=unit
@test "assemble_env_flags: includes SSH_AUTH_SOCK when SSH_FORWARDED=true" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=true
    CFG_EXTRA_VARS=()

    assemble_env_flags

    assert_env_flag "SSH_AUTH_SOCK=/tmp/ssh_auth_sock"
}

# bats test_tags=unit
@test "assemble_env_flags: does not include SSH_AUTH_SOCK when SSH_FORWARDED=false" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()

    assemble_env_flags

    refute_env_flag "SSH_AUTH_SOCK=/tmp/ssh_auth_sock"
}

# bats test_tags=unit
@test "assemble_env_flags: includes AGENT_SANDBOX_NO_SSH when OPT_NO_SSH=true" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=true
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()

    assemble_env_flags

    assert_env_flag "AGENT_SANDBOX_NO_SSH=1"
}

# bats test_tags=unit
@test "assemble_env_flags: does not include AGENT_SANDBOX_NO_SSH when OPT_NO_SSH=false" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()

    assemble_env_flags

    refute_env_flag "AGENT_SANDBOX_NO_SSH=1"
}

# ---------------------------------------------------------------------------
# 8. resolve_workspace Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "resolve_workspace: resolves an existing directory" {
    _TEST_TMPDIR="$(mktemp -d)"
    local tmp_dir="$_TEST_TMPDIR"

    # Compute expected value while the directory still exists
    local expected
    expected=$(portable_realpath "$tmp_dir")

    # Use run to isolate die() calls from the parent shell
    run resolve_workspace "$tmp_dir"

    assert_success
    assert_output "$expected"
}

# bats test_tags=unit
@test "resolve_workspace: non-existent path exits with error" {
    run resolve_workspace "/nonexistent/path/that/does/not/exist"

    assert_failure
}

# bats test_tags=unit
@test "resolve_workspace: expands tilde to HOME" {
    # Create a directory under HOME to test ~ expansion
    mkdir -p "${HOME}/test-workspace-$$"

    # Use run to isolate die() calls from the parent shell
    run resolve_workspace "~/test-workspace-$$"

    assert_success
    # portable_realpath may resolve symlinks (e.g. /var -> /private/var on macOS),
    # so compare the resolved HOME prefix rather than the raw HOME value.
    local resolved_home
    resolved_home=$(portable_realpath "$HOME")
    assert_output "${resolved_home}/test-workspace-$$"
}

# bats test_tags=unit
@test "resolve_workspace: uses PWD when no argument given" {
    _TEST_TMPDIR="$(mktemp -d)"
    local tmp_dir="$_TEST_TMPDIR"

    # Compute expected value while the directory still exists (portable_realpath
    # may require the path to exist to resolve symlinks, e.g. /var -> /private/var).
    local expected
    expected=$(portable_realpath "$tmp_dir")

    # Use a subshell for the cd so the parent process's working directory
    # is not changed, even if resolve_workspace fails.
    run bash -c "
        export AGENT_SANDBOX_SHARE_DIR='${REPO_ROOT}'
        export AGENT_SANDBOX_VERSION='0.1.0-test'
        source '${LAUNCHER}'
        cd '${tmp_dir}'
        resolve_workspace ''
    "

    assert_success
    assert_output "$expected"
}

# ---------------------------------------------------------------------------
# 9. load_image() Tests
# ---------------------------------------------------------------------------

# Helper: create a fake runtime script in a temp dir and set RUNTIME to it.
# The fake script records the subcommand called and simulates success/failure
# based on the exit codes passed as arguments.
#   load_exit  — exit code for the 'load' subcommand (default 0 = success)
#   tag_exit   — exit code for the 'tag' subcommand used by pull_image (default 0)
#   images_after_load — if "true", 'images' returns non-empty after 'load' is called
# Sets _FAKE_RUNTIME_DIR so teardown can clean it up.
_setup_fake_runtime() {
    local load_exit="${1:-0}"
    local tag_exit="${2:-0}"
    local images_after_load="${3:-true}"
    _FAKE_RUNTIME_DIR="$(mktemp -d)"

    # Write a fake runtime that handles the subcommands we care about.
    # Uses a state file to simulate image appearing after a successful load.
    cat > "${_FAKE_RUNTIME_DIR}/fake-runtime" <<EOF
#!/usr/bin/env bash
# Record the call for inspection
echo "\$@" >> "${_FAKE_RUNTIME_DIR}/calls.log"
subcmd="\$1"
case "\$subcmd" in
    load)
        # Consume stdin (the tarball) so the shell doesn't complain
        cat > /dev/null
        if [ ${load_exit} -eq 0 ] && [ "${images_after_load}" = "true" ]; then
            touch "${_FAKE_RUNTIME_DIR}/image_loaded"
        fi
        exit ${load_exit}
        ;;
    tag)
        exit ${tag_exit}
        ;;
    images)
        # Return non-empty if image was loaded (or pre-existing), empty otherwise
        if [ -f "${_FAKE_RUNTIME_DIR}/image_loaded" ]; then
            echo "sha256:abc123"
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "${_FAKE_RUNTIME_DIR}/fake-runtime"
    RUNTIME="${_FAKE_RUNTIME_DIR}/fake-runtime"
    export RUNTIME
}

_teardown_fake_runtime() {
    if [[ -n "${_FAKE_RUNTIME_DIR:-}" && "$_FAKE_RUNTIME_DIR" != "/" ]]; then
        rm -rf "$_FAKE_RUNTIME_DIR"
    fi
    unset _FAKE_RUNTIME_DIR
}

# bats test_tags=unit
@test "load_image: exits with error when image path file does not exist" {
    _setup_fake_runtime 0 0

    local fake_path="/nonexistent/path/image.tar"
    run load_image "0.1.0-test" "$fake_path"

    _teardown_fake_runtime
    assert_failure
    assert_output --partial "not found"
}

# bats test_tags=unit
@test "load_image: exits with error when image tarball is not readable" {
    # Root bypasses DAC permission checks, so this test is meaningless as root.
    if [[ "$(id -u)" -eq 0 ]]; then
        skip "cannot test unreadable files as root"
    fi
    _setup_fake_runtime 0 0

    local tarball
    tarball="$(mktemp)"
    chmod 000 "$tarball"
    # shellcheck disable=SC2064
    trap "chmod 644 '$tarball'; rm -f '$tarball'" EXIT

    run load_image "0.1.0-test" "$tarball"

    chmod 644 "$tarball"
    rm -f "$tarball"
    trap - EXIT
    _teardown_fake_runtime

    assert_failure
    assert_output --partial "not readable"
}

# bats test_tags=unit
@test "load_image: prints loading message with the image path" {
    _setup_fake_runtime 0 0

    local tarball
    tarball="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tarball'" EXIT

    run load_image "0.1.0-test" "$tarball"

    rm -f "$tarball"
    trap - EXIT
    _teardown_fake_runtime

    assert_success
    assert_output --partial "Loading image from"
    assert_output --partial "$tarball"
}

# bats test_tags=unit
@test "load_image: exits with error when runtime load command fails" {
    # load exits with code 1
    _setup_fake_runtime 1 0

    local tarball
    tarball="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tarball'" EXIT

    run load_image "0.1.0-test" "$tarball"

    rm -f "$tarball"
    trap - EXIT
    _teardown_fake_runtime

    assert_failure
    assert_output --partial "Failed to load image"
}

# bats test_tags=unit
@test "load_image: exits with error when loaded tarball does not produce expected tag" {
    # load succeeds but images_after_load=false simulates the tag not appearing
    _setup_fake_runtime 0 0 false

    local tarball
    tarball="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tarball'" EXIT

    run load_image "0.1.0-test" "$tarball"

    rm -f "$tarball"
    trap - EXIT
    _teardown_fake_runtime

    assert_failure
    assert_output --partial "tag agent-sandbox:0.1.0-test was not found"
}

# bats test_tags=unit
@test "load_image: succeeds and logs confirmation when load produces expected tag" {
    _setup_fake_runtime 0 0 true

    local tarball
    tarball="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tarball'" EXIT

    run load_image "0.1.0-test" "$tarball"

    rm -f "$tarball"
    trap - EXIT
    _teardown_fake_runtime

    assert_success
    assert_output --partial "Image loaded: agent-sandbox:0.1.0-test"
}

# ---------------------------------------------------------------------------
# 10. ensure_image() Orchestration Tests
# ---------------------------------------------------------------------------

# Helper: create a fake runtime that reports image as already present locally.
_setup_fake_runtime_image_exists() {
    _FAKE_RUNTIME_DIR="$(mktemp -d)"
    # Pre-create the state file so 'images' returns non-empty immediately
    touch "${_FAKE_RUNTIME_DIR}/image_loaded"
    cat > "${_FAKE_RUNTIME_DIR}/fake-runtime" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "${_FAKE_RUNTIME_DIR}/calls.log"
subcmd="\$1"
case "\$subcmd" in
    images)
        # Return a non-empty image ID — image exists
        echo "sha256:abc123"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "${_FAKE_RUNTIME_DIR}/fake-runtime"
    RUNTIME="${_FAKE_RUNTIME_DIR}/fake-runtime"
    export RUNTIME
}

# Helper: create a fake runtime that reports image as absent, and succeeds on load/pull/tag.
# After a successful load, subsequent 'images' calls return non-empty (simulating the tag appearing).
_setup_fake_runtime_image_absent() {
    _FAKE_RUNTIME_DIR="$(mktemp -d)"
    cat > "${_FAKE_RUNTIME_DIR}/fake-runtime" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "${_FAKE_RUNTIME_DIR}/calls.log"
subcmd="\$1"
case "\$subcmd" in
    images)
        # Return non-empty only after a successful load
        if [ -f "${_FAKE_RUNTIME_DIR}/image_loaded" ]; then
            echo "sha256:abc123"
        fi
        exit 0
        ;;
    load)
        cat > /dev/null
        touch "${_FAKE_RUNTIME_DIR}/image_loaded"
        exit 0
        ;;
    pull)
        exit 0
        ;;
    tag)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "${_FAKE_RUNTIME_DIR}/fake-runtime"
    RUNTIME="${_FAKE_RUNTIME_DIR}/fake-runtime"
    export RUNTIME
}

# bats test_tags=unit
@test "ensure_image: uses local image without load or pull when image already exists" {
    _setup_fake_runtime_image_exists

    OPT_PULL=false
    unset AGENT_SANDBOX_IMAGE_PATH

    # Track calls to load_image and pull_image
    load_called=false
    pull_called=false
    load_image() { load_called=true; }
    pull_image() { pull_called=true; }

    ensure_image "$VERSION"

    _teardown_fake_runtime

    [[ "$load_called" == false ]] || fail "expected load_called=false, got '$load_called'"
    [[ "$pull_called" == false ]] || fail "expected pull_called=false, got '$pull_called'"
}

# bats test_tags=unit
@test "ensure_image: calls load_image when AGENT_SANDBOX_IMAGE_PATH is set and image absent" {
    _setup_fake_runtime_image_absent

    local tarball
    tarball="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tarball'" EXIT

    export AGENT_SANDBOX_IMAGE_PATH="$tarball"
    OPT_PULL=false

    load_called=false
    pull_called=false
    load_image() { load_called=true; }
    pull_image() { pull_called=true; }

    ensure_image "$VERSION"

    rm -f "$tarball"
    trap - EXIT
    _teardown_fake_runtime
    unset AGENT_SANDBOX_IMAGE_PATH

    [[ "$load_called" == true  ]] || fail "expected load_called=true, got '$load_called'"
    [[ "$pull_called" == false ]] || fail "expected pull_called=false, got '$pull_called'"
}

# bats test_tags=unit
@test "ensure_image: calls pull_image when AGENT_SANDBOX_IMAGE_PATH is unset and image absent" {
    _setup_fake_runtime_image_absent

    unset AGENT_SANDBOX_IMAGE_PATH
    OPT_PULL=false

    load_called=false
    pull_called=false
    load_image() { load_called=true; }
    pull_image() { pull_called=true; }

    ensure_image "$VERSION"

    _teardown_fake_runtime

    [[ "$load_called" == false ]] || fail "expected load_called=false, got '$load_called'"
    [[ "$pull_called" == true  ]] || fail "expected pull_called=true, got '$pull_called'"
}

# bats test_tags=unit
@test "ensure_image: calls pull_image when AGENT_SANDBOX_IMAGE_PATH is empty string" {
    _setup_fake_runtime_image_absent

    export AGENT_SANDBOX_IMAGE_PATH=""
    OPT_PULL=false

    load_called=false
    pull_called=false
    load_image() { load_called=true; }
    pull_image() { pull_called=true; }

    ensure_image "$VERSION"

    _teardown_fake_runtime
    unset AGENT_SANDBOX_IMAGE_PATH

    [[ "$load_called" == false ]] || fail "expected load_called=false, got '$load_called'"
    [[ "$pull_called" == true  ]] || fail "expected pull_called=true, got '$pull_called'"
}

# bats test_tags=unit
@test "ensure_image: --pull forces pull_image even when AGENT_SANDBOX_IMAGE_PATH is set" {
    _setup_fake_runtime_image_absent

    local tarball
    tarball="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tarball'" EXIT

    export AGENT_SANDBOX_IMAGE_PATH="$tarball"
    OPT_PULL=true

    load_called=false
    pull_called=false
    load_image() { load_called=true; }
    pull_image() { pull_called=true; }

    ensure_image "$VERSION"

    rm -f "$tarball"
    trap - EXIT
    _teardown_fake_runtime
    unset AGENT_SANDBOX_IMAGE_PATH

    [[ "$load_called" == false ]] || fail "expected load_called=false, got '$load_called'"
    [[ "$pull_called" == true  ]] || fail "expected pull_called=true, got '$pull_called'"
}

# bats test_tags=unit
@test "ensure_image: --pull forces pull_image even when image already exists locally" {
    _setup_fake_runtime_image_exists

    unset AGENT_SANDBOX_IMAGE_PATH
    OPT_PULL=true

    load_called=false
    pull_called=false
    load_image() { load_called=true; }
    pull_image() { pull_called=true; }

    ensure_image "$VERSION"

    _teardown_fake_runtime

    [[ "$load_called" == false ]] || fail "expected load_called=false, got '$load_called'"
    [[ "$pull_called" == true  ]] || fail "expected pull_called=true, got '$pull_called'"
}

# ---------------------------------------------------------------------------
# 11. pull_image() Tests
# ---------------------------------------------------------------------------

# Helper: create a fake runtime for pull_image tests.
#   pull_exit  — exit code for the 'pull' subcommand (default 0 = success)
#   tag_exit   — exit code for the 'tag' subcommand (default 0 = success)
#   images_after_tag — if "true", 'images' returns non-empty after 'tag' is called
_setup_fake_runtime_for_pull() {
    local pull_exit="${1:-0}"
    local tag_exit="${2:-0}"
    local images_after_tag="${3:-true}"
    _FAKE_RUNTIME_DIR="$(mktemp -d)"

    cat > "${_FAKE_RUNTIME_DIR}/fake-runtime" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "${_FAKE_RUNTIME_DIR}/calls.log"
subcmd="\$1"
case "\$subcmd" in
    pull)
        exit ${pull_exit}
        ;;
    tag)
        if [ ${tag_exit} -eq 0 ] && [ "${images_after_tag}" = "true" ]; then
            touch "${_FAKE_RUNTIME_DIR}/image_tagged"
        fi
        exit ${tag_exit}
        ;;
    images)
        if [ -f "${_FAKE_RUNTIME_DIR}/image_tagged" ]; then
            echo "sha256:abc123"
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "${_FAKE_RUNTIME_DIR}/fake-runtime"
    RUNTIME="${_FAKE_RUNTIME_DIR}/fake-runtime"
    export RUNTIME
}

# bats test_tags=unit
@test "pull_image: exits with error when pull command fails" {
    # pull exits with code 1
    _setup_fake_runtime_for_pull 1 0

    run pull_image "0.1.0-test"

    _teardown_fake_runtime

    assert_failure
    assert_output --partial "Failed to pull image"
}

# bats test_tags=unit
@test "pull_image: exits with error when tag command fails" {
    # pull succeeds but tag exits with code 1
    _setup_fake_runtime_for_pull 0 1

    run pull_image "0.1.0-test"

    _teardown_fake_runtime

    assert_failure
    assert_output --partial "Failed to tag"
}

# bats test_tags=unit
@test "pull_image: exits with error when tag succeeds but image not found locally" {
    # pull and tag succeed but images_after_tag=false simulates the tag not appearing
    _setup_fake_runtime_for_pull 0 0 false

    run pull_image "0.1.0-test"

    _teardown_fake_runtime

    assert_failure
    assert_output --partial "agent-sandbox:0.1.0-test"
}

# bats test_tags=unit
@test "pull_image: succeeds and logs confirmation when pull and tag produce expected local tag" {
    _setup_fake_runtime_for_pull 0 0 true

    run pull_image "0.1.0-test"

    _teardown_fake_runtime

    assert_success
    assert_output --partial "Image pulled and tagged: agent-sandbox:0.1.0-test"
}

# ---------------------------------------------------------------------------
# 12. do_update() Tests
# ---------------------------------------------------------------------------
#
# do_update() calls external commands (curl, sha256sum/shasum, sh) and uses
# SHARE_DIR for Nix detection. Tests use fake scripts in a temp bin dir
# prepended to PATH to intercept these calls without network access.
#
# do_update() calls exit (not return), so all tests use `run do_update`.

# Helper: set up a fake bin directory for do_update() tests.
# Creates fake curl, sha256sum, and sh scripts with configurable behavior.
#
# Parameters (all optional, positional):
#   $1  api_tag        — tag_name returned by the GitHub API (default: "2.0.0")
#   $2  install_exit   — exit code for the installer sh -c call (default: 0)
#   $3  sums_exit      — exit code for the SHA256SUMS curl call (default: 0)
#   $4  sums_hash      — hash entry in SHA256SUMS for install.sh (default: computed)
#   $5  installer_content — content of the fake install.sh (default: valid shebang script)
#
# Sets _FAKE_UPDATE_DIR and prepends it to PATH.
_setup_fake_update_env() {
    local api_tag="${1:-2.0.0}"
    local install_exit="${2:-0}"
    local sums_exit="${3:-0}"
    local sums_hash="${4:-}"
    local installer_content="${5:-#!/bin/sh
echo 'installer ran'
}"

    _FAKE_UPDATE_DIR="$(mktemp -d)"

    # Write installer content to a file so the fake curl can cat it without
    # embedding multi-line content in a shell script (which breaks syntax).
    printf '%s' "$installer_content" > "${_FAKE_UPDATE_DIR}/installer_content.sh"

    # Fake curl: dispatches on the URL argument to return different responses.
    # - GitHub API URL → returns JSON with tag_name
    # - SHA256SUMS URL → returns sums content (or fails if sums_exit != 0)
    # - install.sh URL → returns installer content (read from file)
    cat > "${_FAKE_UPDATE_DIR}/curl" <<CURLEOF
#!/usr/bin/env bash
# Parse args: find the URL (last non-flag argument after -fsSL)
url=""
for arg in "\$@"; do
    case "\$arg" in
        -*)  ;;
        *)   url="\$arg" ;;
    esac
done
case "\$url" in
    *api.github.com*releases/latest*)
        printf '{"tag_name": "v${api_tag}", "name": "v${api_tag}"}\n'
        exit 0
        ;;
    *SHA256SUMS*)
        if [ ${sums_exit} -ne 0 ]; then
            exit ${sums_exit}
        fi
        printf '%s  install.sh\n' "${sums_hash}"
        exit 0
        ;;
    *install.sh*)
        cat "${_FAKE_UPDATE_DIR}/installer_content.sh"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
CURLEOF
    chmod +x "${_FAKE_UPDATE_DIR}/curl"

    # Fake sha256sum: delegates to the real system sha256sum/shasum.
    # The fake is placed first in PATH so do_update's _sha256sum() finds it,
    # but it calls the real tool (by absolute path) to produce correct hashes.
    # On macOS, sha256sum is not available by default; shasum is used instead.
    local real_sha256sum
    real_sha256sum="$(command -v sha256sum 2>/dev/null || true)"
    local real_shasum
    real_shasum="$(command -v shasum 2>/dev/null || true)"

    cat > "${_FAKE_UPDATE_DIR}/sha256sum" <<SUMSEOF
#!/usr/bin/env bash
# Delegate to the real sha256sum tool (by absolute path to avoid self-reference).
if [ -n "${real_sha256sum}" ]; then
    exec "${real_sha256sum}" "\$@"
elif [ -n "${real_shasum}" ]; then
    exec "${real_shasum}" -a 256 "\$@"
else
    echo "aabbccdd1122334455667788990011223344556677889900aabbccdd11223344  -"
fi
SUMSEOF
    chmod +x "${_FAKE_UPDATE_DIR}/sha256sum"

    # Fake sh: records the -c argument and exits with the configured exit code.
    cat > "${_FAKE_UPDATE_DIR}/sh" <<SHEOF
#!/usr/bin/env bash
# Record the call
echo "\$@" >> "${_FAKE_UPDATE_DIR}/sh_calls.log"
# For -c invocations, record the script content
if [ "\$1" = "-c" ]; then
    echo "\$2" >> "${_FAKE_UPDATE_DIR}/sh_scripts.log"
fi
exit ${install_exit}
SHEOF
    chmod +x "${_FAKE_UPDATE_DIR}/sh"

    # Prepend fake bin dir to PATH so our fakes take precedence
    export PATH="${_FAKE_UPDATE_DIR}:${PATH}"
    export _FAKE_UPDATE_DIR
}

_teardown_fake_update_env() {
    if [[ -n "${_FAKE_UPDATE_DIR:-}" && "$_FAKE_UPDATE_DIR" != "/" ]]; then
        rm -rf "$_FAKE_UPDATE_DIR"
    fi
    unset _FAKE_UPDATE_DIR
}

# Helper: compute the SHA256 of installer content as do_update() does.
# do_update() captures install_script via command substitution (which strips
# trailing newlines), then hashes via: printf '%s\n' "$install_script" | sha256sum.
# This helper replicates that exact sequence so test-computed hashes match.
_compute_hash_for_installer() {
    local content="$1"
    # Strip trailing newlines to match command substitution behavior, then
    # add exactly one newline back (as printf '%s\n' does in do_update).
    local stripped
    stripped="${content%$'\n'}"
    # Keep stripping until no trailing newline remains (handles multiple trailing newlines)
    while [[ "$stripped" == *$'\n' ]]; do
        stripped="${stripped%$'\n'}"
    done
    if command -v sha256sum &>/dev/null; then
        printf '%s\n' "$stripped" | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        printf '%s\n' "$stripped" | shasum -a 256 | awk '{print $1}'
    else
        echo ""
    fi
}

# bats test_tags=unit
@test "do_update: Nix installation exits 0 with managed-by-Nix message" {
    # When SHARE_DIR starts with /nix/store/, do_update should exit 0 and
    # print a message directing the user to use nix profile upgrade.
    SHARE_DIR="/nix/store/abc123-agent-sandbox-1.0.0/share"

    run do_update

    assert_success
    assert_output --partial "Installed via Nix"
}

# bats test_tags=unit
@test "do_update: already up to date exits 0 with up-to-date message" {
    # When the GitHub API returns the same version as VERSION, do_update should
    # exit 0 without downloading or executing anything.
    SHARE_DIR="/usr/local/share/agent-sandbox"
    VERSION="1.5.0"
    _setup_fake_update_env "1.5.0"

    run do_update

    _teardown_fake_update_env

    assert_success
    assert_output --partial "Already up to date"
}

# bats test_tags=unit
@test "do_update: GitHub API failure exits non-zero with connection error message" {
    # When curl fails for the GitHub API call, do_update should die with an
    # error message about checking internet connection.
    SHARE_DIR="/usr/local/share/agent-sandbox"
    VERSION="1.0.0"

    _FAKE_UPDATE_DIR="$(mktemp -d)"
    # Fake curl that always fails
    cat > "${_FAKE_UPDATE_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${_FAKE_UPDATE_DIR}/curl"
    export PATH="${_FAKE_UPDATE_DIR}:${PATH}"
    export _FAKE_UPDATE_DIR

    run do_update

    _teardown_fake_update_env

    assert_failure
    assert_output --partial "Failed to check for updates"
}

# bats test_tags=unit
@test "do_update: invalid version string from API exits non-zero with validation error" {
    # When the GitHub API returns a version string containing unsafe characters
    # (e.g. path traversal, injection), do_update should die with a validation error.
    SHARE_DIR="/usr/local/share/agent-sandbox"
    VERSION="1.0.0"

    _FAKE_UPDATE_DIR="$(mktemp -d)"
    # Fake curl that returns a crafted tag with path traversal
    cat > "${_FAKE_UPDATE_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"tag_name": "v../../../etc/passwd", "name": "evil"}\n'
exit 0
EOF
    chmod +x "${_FAKE_UPDATE_DIR}/curl"
    export PATH="${_FAKE_UPDATE_DIR}:${PATH}"
    export _FAKE_UPDATE_DIR

    run do_update

    _teardown_fake_update_env

    assert_failure
    assert_output --partial "invalid version string"
}

# bats test_tags=unit
@test "do_update: empty tag_name from API exits non-zero with parse error" {
    # When the GitHub API response cannot be parsed (no tag_name field),
    # do_update should die with a parse error.
    SHARE_DIR="/usr/local/share/agent-sandbox"
    VERSION="1.0.0"

    _FAKE_UPDATE_DIR="$(mktemp -d)"
    # Fake curl that returns JSON without tag_name
    cat > "${_FAKE_UPDATE_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"name": "some release", "body": "no tag here"}\n'
exit 0
EOF
    chmod +x "${_FAKE_UPDATE_DIR}/curl"
    export PATH="${_FAKE_UPDATE_DIR}:${PATH}"
    export _FAKE_UPDATE_DIR

    run do_update

    _teardown_fake_update_env

    assert_failure
    assert_output --partial "Could not parse version"
}

# bats test_tags=unit
@test "do_update: missing shebang in downloaded installer exits non-zero" {
    # When the downloaded install.sh does not start with '#!/', do_update should
    # die with a shebang validation error before executing anything.
    SHARE_DIR="/usr/local/share/agent-sandbox"
    VERSION="1.0.0"
    local bad_installer="<html>Not Found</html>"
    _setup_fake_update_env "2.0.0" 0 1 "" "$bad_installer"

    run do_update

    _teardown_fake_update_env

    assert_failure
    assert_output --partial "missing shebang"
}

# bats test_tags=unit
@test "do_update: SHA256 mismatch exits non-zero with checksum failure message" {
    # When the SHA256SUMS file is available but the computed hash of install.sh
    # does not match the expected hash, do_update should die with a checksum error.
    SHARE_DIR="/usr/local/share/agent-sandbox"
    VERSION="1.0.0"
    local installer_content="#!/bin/sh
echo 'installer ran'
"
    # Provide a deliberately wrong hash in SHA256SUMS
    local wrong_hash="0000000000000000000000000000000000000000000000000000000000000000"
    _setup_fake_update_env "2.0.0" 0 0 "$wrong_hash" "$installer_content"

    run do_update

    _teardown_fake_update_env

    assert_failure
    assert_output --partial "checksum verification FAILED"
}

# bats test_tags=unit
@test "do_update: missing SHA256SUMS warns and continues to execute installer" {
    # When the SHA256SUMS download fails (curl exits non-zero for the SUMS URL),
    # do_update should warn but continue and execute the installer.
    SHARE_DIR="/usr/local/share/agent-sandbox"
    VERSION="1.0.0"
    local installer_content="#!/bin/sh
echo 'installer ran'
"
    # sums_exit=1 makes the SHA256SUMS curl call fail
    _setup_fake_update_env "2.0.0" 0 1 "" "$installer_content"

    run do_update

    _teardown_fake_update_env

    assert_success
    assert_output --partial "skipping checksum verification"
}

# bats test_tags=unit
@test "do_update: SHA256 match proceeds to execute installer with AGENT_SANDBOX_VERSION set" {
    # When checksums match, do_update should execute the installer via sh -c
    # with AGENT_SANDBOX_VERSION set to the new version tag.
    SHARE_DIR="/usr/local/share/agent-sandbox"
    VERSION="1.0.0"
    local installer_content="#!/bin/sh
echo 'installer ran'
"
    # Compute the correct hash for the installer content (as do_update does)
    local correct_hash
    correct_hash=$(_compute_hash_for_installer "$installer_content")
    if [[ -z "$correct_hash" ]]; then
        skip "No sha256 tool available to compute hash"
    fi

    _setup_fake_update_env "2.0.0" 0 0 "$correct_hash" "$installer_content"

    run do_update

    _teardown_fake_update_env

    assert_success
    assert_output --partial "Checksum verified"
    assert_output --partial "Updated to v2.0.0"
}

# ---------------------------------------------------------------------------
# 13. collect_extra_mounts() Unit Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "collect_extra_mounts: :rw suffix splits correctly and passes rw mode" {
    _TEST_TMPDIR="$(mktemp -d)"
    local extra_dir="$_TEST_TMPDIR"

    OPT_EXTRA_MOUNTS=("${extra_dir}:rw")
    CFG_EXTRA_PATHS=()
    MOUNT_FLAGS=()
    MOUNT_Z=""

    collect_extra_mounts

    # Should contain a :rw mount (not :ro)
    local found_rw=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *":rw" ]]; then
            found_rw=true
            break
        fi
    done
    assert_equal "$found_rw" true
}

# bats test_tags=unit
@test "collect_extra_mounts: default mode is ro when no suffix" {
    _TEST_TMPDIR="$(mktemp -d)"
    local extra_dir="$_TEST_TMPDIR"

    OPT_EXTRA_MOUNTS=("$extra_dir")
    CFG_EXTRA_PATHS=()
    MOUNT_FLAGS=()
    MOUNT_Z=""

    collect_extra_mounts

    # Should contain a :ro mount (not :rw)
    local found_ro=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *":ro" ]]; then
            found_ro=true
            break
        fi
    done
    assert_equal "$found_ro" true
}

# bats test_tags=unit
@test "collect_extra_mounts: ~/path expands to HOME" {
    local subdir="test-extra-mount-$$"
    mkdir -p "${HOME}/${subdir}"

    OPT_EXTRA_MOUNTS=("~/${subdir}")
    CFG_EXTRA_PATHS=()
    MOUNT_FLAGS=()
    MOUNT_Z=""

    collect_extra_mounts

    # The mount should reference the expanded HOME path
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == "${HOME}/${subdir}"* || "$flag" == *"/${subdir}:"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" true
}

# bats test_tags=unit
@test "collect_extra_mounts: HOME-relative paths map to /home/sandbox/ inside container" {
    local subdir="test-sandbox-mount-$$"
    # Resolve HOME so portable_realpath-resolved paths compare correctly on macOS
    # (where /tmp is a symlink to /private/tmp).
    local resolved_home
    resolved_home=$(portable_realpath "$HOME")
    mkdir -p "${resolved_home}/${subdir}"

    OPT_EXTRA_MOUNTS=("${resolved_home}/${subdir}")
    CFG_EXTRA_PATHS=()
    MOUNT_FLAGS=()
    MOUNT_Z=""
    HOME="$resolved_home"

    collect_extra_mounts

    # The container path should be /home/sandbox/<relative>
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *":/home/sandbox/${subdir}:"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" true
}

# bats test_tags=unit
@test "collect_extra_mounts: non-HOME paths map to same absolute path" {
    # Use /tmp which is outside HOME
    _TEST_TMPDIR="$(mktemp -d)"
    local extra_dir="$_TEST_TMPDIR"

    # Ensure the path is not under HOME
    local resolved
    resolved=$(portable_realpath "$extra_dir" 2>/dev/null || echo "$extra_dir")

    # Skip if mktemp created the dir under HOME (unlikely but possible)
    if [[ "$resolved" == "$HOME"/* ]]; then
        skip "mktemp dir is under HOME — cannot test non-HOME path mapping"
    fi

    OPT_EXTRA_MOUNTS=("$extra_dir")
    CFG_EXTRA_PATHS=()
    MOUNT_FLAGS=()
    MOUNT_Z=""

    collect_extra_mounts

    # The container path should equal the host path (same absolute path)
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == "${resolved}:${resolved}:"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" true
}

# bats test_tags=unit
@test "collect_extra_mounts: missing path warns and skips" {
    OPT_EXTRA_MOUNTS=("/nonexistent/path/that/does/not/exist")
    CFG_EXTRA_PATHS=()
    MOUNT_FLAGS=()
    MOUNT_Z=""

    # Should not fail, just warn
    collect_extra_mounts

    # MOUNT_FLAGS should be empty (the missing path was skipped)
    assert_equal "${#MOUNT_FLAGS[@]}" 0
}

# bats test_tags=unit
@test "collect_extra_mounts: deduplicates CLI and config mounts for the same path" {
    _TEST_TMPDIR="$(mktemp -d)"
    local extra_dir="$_TEST_TMPDIR"

    # Resolve before calling collect_extra_mounts (while the dir exists)
    # so the resolved path matches what collect_extra_mounts stores in MOUNT_FLAGS.
    local resolved
    resolved=$(portable_realpath "$extra_dir" 2>/dev/null || echo "$extra_dir")

    # Same path appears in both CLI mounts and config paths
    OPT_EXTRA_MOUNTS=("$extra_dir")
    CFG_EXTRA_PATHS=("$extra_dir")
    MOUNT_FLAGS=()
    MOUNT_Z=""

    collect_extra_mounts

    # Count occurrences of the path in MOUNT_FLAGS
    local count=0
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == "${resolved}:"* ]]; then
            count=$((count + 1))
        fi
    done
    assert_equal "$count" 1
}

# ---------------------------------------------------------------------------
# 14. detect_runtime() Unit Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "detect_runtime: AGENT_SANDBOX_RUNTIME=docker uses docker even when podman exists" {
    # Create fake podman and docker in a temp dir
    local fake_bin
    fake_bin="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$fake_bin'" EXIT
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/podman"
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/docker"
    chmod +x "${fake_bin}/podman" "${fake_bin}/docker"

    export AGENT_SANDBOX_RUNTIME="docker"
    local old_path="$PATH"
    export PATH="${fake_bin}:${PATH}"

    detect_runtime

    export PATH="$old_path"
    unset AGENT_SANDBOX_RUNTIME
    rm -rf "$fake_bin"
    trap - EXIT

    assert_equal "$RUNTIME" "docker"
}

# bats test_tags=unit
@test "detect_runtime: AGENT_SANDBOX_RUNTIME=podman uses podman" {
    local fake_bin
    fake_bin="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$fake_bin'" EXIT
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/podman"
    chmod +x "${fake_bin}/podman"

    export AGENT_SANDBOX_RUNTIME="podman"
    local old_path="$PATH"
    export PATH="${fake_bin}:${PATH}"

    detect_runtime

    export PATH="$old_path"
    unset AGENT_SANDBOX_RUNTIME
    rm -rf "$fake_bin"
    trap - EXIT

    assert_equal "$RUNTIME" "podman"
}

# bats test_tags=unit
@test "detect_runtime: invalid AGENT_SANDBOX_RUNTIME value exits with error" {
    export AGENT_SANDBOX_RUNTIME="invalid-runtime"

    run detect_runtime

    unset AGENT_SANDBOX_RUNTIME

    assert_failure
    assert_output --partial "must be 'podman' or 'docker'"
}

# bats test_tags=unit
@test "detect_runtime: when both podman and docker exist, podman is preferred" {
    local fake_bin
    fake_bin="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$fake_bin'" EXIT
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/podman"
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/docker"
    chmod +x "${fake_bin}/podman" "${fake_bin}/docker"

    unset AGENT_SANDBOX_RUNTIME
    local old_path="$PATH"
    # Prepend fake_bin to PATH so only our fakes are found
    export PATH="${fake_bin}"

    detect_runtime

    export PATH="$old_path"
    rm -rf "$fake_bin"
    trap - EXIT

    assert_equal "$RUNTIME" "podman"
}

# bats test_tags=unit
@test "detect_runtime: when neither podman nor docker exists, exits with error" {
    unset AGENT_SANDBOX_RUNTIME
    local old_path="$PATH"
    # Set PATH to an empty temp dir so no runtimes are found
    local empty_bin
    empty_bin="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$empty_bin'" EXIT
    export PATH="$empty_bin"

    run detect_runtime

    export PATH="$old_path"
    rm -rf "$empty_bin"
    trap - EXIT

    assert_failure
    assert_output --partial "Neither 'podman' nor 'docker' found"
}

# bats test_tags=unit
@test "detect_runtime: when only docker exists, docker is used" {
    local fake_bin
    fake_bin="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$fake_bin'" EXIT
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/docker"
    chmod +x "${fake_bin}/docker"

    unset AGENT_SANDBOX_RUNTIME
    local old_path="$PATH"
    export PATH="${fake_bin}"

    detect_runtime

    export PATH="$old_path"
    rm -rf "$fake_bin"
    trap - EXIT

    assert_equal "$RUNTIME" "docker"
}

# ---------------------------------------------------------------------------
# 15. do_list() Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "do_list: calls runtime ps with name filter and table format" {
    _TEST_TMPDIR="$(mktemp -d)"
    cat > "${_TEST_TMPDIR}/fake-runtime" <<'RTEOF'
#!/usr/bin/env bash
echo "$@" >> "${0%/*}/calls.log"
subcmd="$1"
case "$subcmd" in
    ps)
        echo "agent-sandbox-opencode-myproject-abc123"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
RTEOF
    chmod +x "${_TEST_TMPDIR}/fake-runtime"
    RUNTIME="${_TEST_TMPDIR}/fake-runtime"

    run do_list

    assert_success
    assert_output --partial "agent-sandbox-opencode-myproject-abc123"
    # Verify ps was called with the name filter and table format
    local calls_log="${_TEST_TMPDIR}/calls.log"
    run grep "name=agent-sandbox-" "$calls_log"
    assert_success
    run grep -- "--format" "$calls_log"
    assert_success
}

# bats test_tags=unit
@test "do_list: exits 0 even when no containers are running" {
    _TEST_TMPDIR="$(mktemp -d)"
    cat > "${_TEST_TMPDIR}/fake-runtime" <<'RTEOF'
#!/usr/bin/env bash
echo "$@" >> "${0%/*}/calls.log"
subcmd="$1"
case "$subcmd" in
    ps)
        # Return empty output — no containers running
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
RTEOF
    chmod +x "${_TEST_TMPDIR}/fake-runtime"
    RUNTIME="${_TEST_TMPDIR}/fake-runtime"

    run do_list

    assert_success
}

# ---------------------------------------------------------------------------
# 16. do_stop() Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "do_stop: stops specific container when agent is provided" {
    _TEST_TMPDIR="$(mktemp -d)"
    _TEST_TMPDIR2="$(mktemp -d)"
    local ws_dir="$_TEST_TMPDIR2"

    cat > "${_TEST_TMPDIR}/fake-runtime" <<'RTEOF'
#!/usr/bin/env bash
echo "$@" >> "${0%/*}/calls.log"
exit 0
RTEOF
    chmod +x "${_TEST_TMPDIR}/fake-runtime"
    RUNTIME="${_TEST_TMPDIR}/fake-runtime"

    run do_stop "$ws_dir" "opencode"

    assert_success
    assert_output --partial "Stopped container:"
    # Verify stop was called with a container name matching the expected pattern
    assert [ -f "${_TEST_TMPDIR}/calls.log" ]
    run grep "stop" "${_TEST_TMPDIR}/calls.log"
    assert_success
    run grep "agent-sandbox-opencode-" "${_TEST_TMPDIR}/calls.log"
    assert_success
}

# bats test_tags=unit
@test "do_stop: stops all workspace containers when no agent is provided" {
    _TEST_TMPDIR="$(mktemp -d)"
    _TEST_TMPDIR2="$(mktemp -d)"
    local ws_dir="$_TEST_TMPDIR2"

    # Pre-compute the expected container name so the fake runtime can return it
    local resolved_ws
    resolved_ws=$(portable_realpath "$ws_dir")
    local expected_name
    expected_name=$(compute_container_name "opencode" "$resolved_ws")

    cat > "${_TEST_TMPDIR}/fake-runtime" <<RTEOF
#!/usr/bin/env bash
echo "\$@" >> "\${0%/*}/calls.log"
subcmd="\$1"
case "\$subcmd" in
    ps)
        echo "${expected_name}"
        exit 0
        ;;
    stop)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
RTEOF
    chmod +x "${_TEST_TMPDIR}/fake-runtime"
    RUNTIME="${_TEST_TMPDIR}/fake-runtime"

    run do_stop "$ws_dir"

    assert_success
    assert_output --partial "Stopping container:"
}

# bats test_tags=unit
@test "do_stop: exits 0 when no matching containers found" {
    _TEST_TMPDIR="$(mktemp -d)"
    _TEST_TMPDIR2="$(mktemp -d)"
    local ws_dir="$_TEST_TMPDIR2"

    cat > "${_TEST_TMPDIR}/fake-runtime" <<'RTEOF'
#!/usr/bin/env bash
echo "$@" >> "${0%/*}/calls.log"
subcmd="$1"
case "$subcmd" in
    ps)
        # Return empty — no containers running
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
RTEOF
    chmod +x "${_TEST_TMPDIR}/fake-runtime"
    RUNTIME="${_TEST_TMPDIR}/fake-runtime"

    run do_stop "$ws_dir"

    assert_success
}

# ---------------------------------------------------------------------------
# 17. do_prune() Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "do_prune: removes old images and keeps current version" {
    _TEST_TMPDIR="$(mktemp -d)"
    # Use an unquoted heredoc so $VERSION expands
    cat > "${_TEST_TMPDIR}/fake-runtime" <<RTEOF
#!/usr/bin/env bash
echo "\$@" >> "\${0%/*}/calls.log"
subcmd="\$1"
case "\$subcmd" in
    images)
        printf 'agent-sandbox:${VERSION}\nagent-sandbox:0.0.1-old\nagent-sandbox:0.0.2-old\n'
        exit 0
        ;;
    rmi)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
RTEOF
    chmod +x "${_TEST_TMPDIR}/fake-runtime"
    RUNTIME="${_TEST_TMPDIR}/fake-runtime"

    run do_prune

    assert_success
    assert_output --partial "Keeping current image: agent-sandbox:${VERSION}"
    assert_output --partial "Removing old image: agent-sandbox:0.0.1-old"
    assert_output --partial "Pruned 2 old image(s)"
}

# bats test_tags=unit
@test "do_prune: exits 0 with message when no images found" {
    _TEST_TMPDIR="$(mktemp -d)"
    cat > "${_TEST_TMPDIR}/fake-runtime" <<'RTEOF'
#!/usr/bin/env bash
echo "$@" >> "${0%/*}/calls.log"
subcmd="$1"
case "$subcmd" in
    images)
        # Return empty — no agent-sandbox images
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
RTEOF
    chmod +x "${_TEST_TMPDIR}/fake-runtime"
    RUNTIME="${_TEST_TMPDIR}/fake-runtime"

    run do_prune

    assert_success
    assert_output --partial "No agent-sandbox images found"
}

# bats test_tags=unit
@test "do_prune: warns but continues when rmi fails for one image" {
    _TEST_TMPDIR="$(mktemp -d)"
    cat > "${_TEST_TMPDIR}/fake-runtime" <<'RTEOF'
#!/usr/bin/env bash
echo "$@" >> "${0%/*}/calls.log"
subcmd="$1"
case "$subcmd" in
    images)
        echo "agent-sandbox:0.0.1-old"
        exit 0
        ;;
    rmi)
        # Simulate rmi failure
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
RTEOF
    chmod +x "${_TEST_TMPDIR}/fake-runtime"
    RUNTIME="${_TEST_TMPDIR}/fake-runtime"

    run do_prune

    assert_success
    assert_output --partial "Failed to remove"
    assert_output --partial "Pruned 0 old image(s)"
}

# ---------------------------------------------------------------------------
# 18. assemble_mount_flags() Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "assemble_mount_flags: always includes workspace mount as first entry" {
    _TEST_TMPDIR="$(mktemp -d)"
    WORKSPACE="$_TEST_TMPDIR"
    MOUNT_Z=""
    OPT_NO_SSH=true
    OPT_FOLLOW_SYMLINKS=false
    OPT_EXTRA_MOUNTS=()
    CFG_EXTRA_PATHS=()
    unset SSH_AUTH_SOCK 2>/dev/null || true

    assemble_mount_flags

    assert_equal "${MOUNT_FLAGS[0]}" "-v"
    # Second element should be the workspace path with :rw
    local found_ws=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"${WORKSPACE}"*":rw"* ]]; then
            found_ws=true
            break
        fi
    done
    assert_equal "$found_ws" true
}

# bats test_tags=unit
@test "assemble_mount_flags: mounts gitconfig when it exists" {
    _TEST_TMPDIR="$(mktemp -d)"
    WORKSPACE="$_TEST_TMPDIR"
    MOUNT_Z=""
    OPT_NO_SSH=true
    OPT_FOLLOW_SYMLINKS=false
    OPT_EXTRA_MOUNTS=()
    CFG_EXTRA_PATHS=()
    unset SSH_AUTH_SOCK 2>/dev/null || true

    # Create a .gitconfig in the temp HOME
    echo "[user]" > "${HOME}/.gitconfig"
    echo "  name = Test User" >> "${HOME}/.gitconfig"

    assemble_mount_flags

    # Check MOUNT_FLAGS contains a .gitconfig mount
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *".gitconfig:/home/sandbox/.gitconfig:ro"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" true
}

# bats test_tags=unit
@test "assemble_mount_flags: skips gitconfig when it does not exist" {
    _TEST_TMPDIR="$(mktemp -d)"
    WORKSPACE="$_TEST_TMPDIR"
    MOUNT_Z=""
    OPT_NO_SSH=true
    OPT_FOLLOW_SYMLINKS=false
    OPT_EXTRA_MOUNTS=()
    CFG_EXTRA_PATHS=()
    unset SSH_AUTH_SOCK 2>/dev/null || true

    # Ensure no .gitconfig exists in the temp HOME
    rm -f "${HOME}/.gitconfig"

    assemble_mount_flags

    # Check MOUNT_FLAGS does NOT contain any .gitconfig reference
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *".gitconfig"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" false
}

# bats test_tags=unit
@test "assemble_mount_flags: creates opencode data directory if absent" {
    _TEST_TMPDIR="$(mktemp -d)"
    WORKSPACE="$_TEST_TMPDIR"
    MOUNT_Z=""
    OPT_NO_SSH=true
    OPT_FOLLOW_SYMLINKS=false
    OPT_EXTRA_MOUNTS=()
    CFG_EXTRA_PATHS=()
    unset SSH_AUTH_SOCK 2>/dev/null || true

    # Ensure the opencode data dir does not exist
    rm -rf "${HOME}/.local/share/opencode"

    assemble_mount_flags

    assert [ -d "${HOME}/.local/share/opencode" ]
    # Check MOUNT_FLAGS contains the opencode data mount
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"opencode:/home/sandbox/.local/share/opencode:rw"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" true
}

# bats test_tags=unit
@test "assemble_mount_flags: sets SSH_FORWARDED=false when OPT_NO_SSH=true" {
    _TEST_TMPDIR="$(mktemp -d)"
    WORKSPACE="$_TEST_TMPDIR"
    MOUNT_Z=""
    OPT_NO_SSH=true
    OPT_FOLLOW_SYMLINKS=false
    OPT_EXTRA_MOUNTS=()
    CFG_EXTRA_PATHS=()
    # Set SSH_AUTH_SOCK to a value to confirm OPT_NO_SSH overrides it
    export SSH_AUTH_SOCK="/tmp/ssh-test-sock-$$"

    assemble_mount_flags

    assert_equal "$SSH_FORWARDED" "false"
    unset SSH_AUTH_SOCK
}

# bats test_tags=unit
@test "assemble_mount_flags: stages opencode config from host when config dir exists" {
    _TEST_TMPDIR="$(mktemp -d)"
    WORKSPACE="$_TEST_TMPDIR"
    MOUNT_Z=""
    OPT_NO_SSH=true
    OPT_FOLLOW_SYMLINKS=false
    OPT_EXTRA_MOUNTS=()
    CFG_EXTRA_PATHS=()
    unset SSH_AUTH_SOCK 2>/dev/null || true

    # Create the opencode config directory with a file
    mkdir -p "${HOME}/.config/opencode"
    echo '{"theme": "dark"}' > "${HOME}/.config/opencode/opencode.json"

    assemble_mount_flags

    # Check MOUNT_FLAGS contains the staged config mount at /host-config/opencode/
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"/host-config/opencode/:ro"* ]]; then
            found=true
            break
        fi
    done
    assert_equal "$found" true
}

