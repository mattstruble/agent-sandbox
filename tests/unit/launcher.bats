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
}

# ---------------------------------------------------------------------------
# 1. Argument Parsing Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "parse_args: no arguments sets all OPT_ vars to defaults" {
    parse_args

    [[ "$OPT_AGENT"              == ""    ]]
    [[ "$OPT_PULL"               == false ]]
    [[ "$OPT_FOLLOW_SYMLINKS"    == false ]]
    [[ "$OPT_FOLLOW_ALL_SYMLINKS" == false ]]
    [[ "$OPT_NO_SSH"             == false ]]
    [[ "$OPT_LIST"               == false ]]
    [[ "$OPT_STOP"               == false ]]
    [[ "$OPT_PRUNE"              == false ]]
    [[ "$OPT_UPDATE"             == false ]]
    [[ "$OPT_HELP"               == false ]]
    [[ "$OPT_VERSION"            == false ]]
    [[ "${#OPT_EXTRA_MOUNTS[@]}" -eq 0   ]]
    [[ "$OPT_WORKSPACE"          == ""   ]]
}

# bats test_tags=unit
@test "parse_args: --agent opencode sets OPT_AGENT to opencode" {
    parse_args --agent opencode

    [[ "$OPT_AGENT" == "opencode" ]]
}

# bats test_tags=unit
@test "parse_args: -a shorthand sets OPT_AGENT" {
    parse_args -a opencode

    [[ "$OPT_AGENT" == "opencode" ]]
}

# bats test_tags=unit
@test "parse_args: --agent does NOT validate value (validation is in apply_config_defaults)" {
    # parse_args just stores whatever is passed; no die() for invalid agent names
    parse_args --agent invalid-value

    [[ "$OPT_AGENT" == "invalid-value" ]]
}

# bats test_tags=unit
@test "parse_args: --pull sets OPT_PULL to true" {
    parse_args --pull

    [[ "$OPT_PULL" == true ]]
}

# bats test_tags=unit
@test "parse_args: -b shorthand sets OPT_PULL to true" {
    parse_args -b

    [[ "$OPT_PULL" == true ]]
}

# bats test_tags=unit
@test "parse_args: --no-ssh sets OPT_NO_SSH to true" {
    parse_args --no-ssh

    [[ "$OPT_NO_SSH" == true ]]
}

# bats test_tags=unit
@test "parse_args: --follow-symlinks sets OPT_FOLLOW_SYMLINKS to true" {
    parse_args --follow-symlinks

    [[ "$OPT_FOLLOW_SYMLINKS" == true ]]
    [[ "$OPT_FOLLOW_ALL_SYMLINKS" == false ]]
}

# bats test_tags=unit
@test "parse_args: --follow-all-symlinks sets both OPT_FOLLOW_ALL_SYMLINKS and OPT_FOLLOW_SYMLINKS to true" {
    parse_args --follow-all-symlinks

    [[ "$OPT_FOLLOW_ALL_SYMLINKS" == true ]]
    [[ "$OPT_FOLLOW_SYMLINKS"     == true ]]
}

# bats test_tags=unit
@test "parse_args: --list sets OPT_LIST to true" {
    parse_args --list

    [[ "$OPT_LIST" == true ]]
}

# bats test_tags=unit
@test "parse_args: --stop sets OPT_STOP to true" {
    parse_args --stop

    [[ "$OPT_STOP" == true ]]
}

# bats test_tags=unit
@test "parse_args: --prune sets OPT_PRUNE to true" {
    parse_args --prune

    [[ "$OPT_PRUNE" == true ]]
}

# bats test_tags=unit
@test "parse_args: --version sets OPT_VERSION to true" {
    parse_args --version

    [[ "$OPT_VERSION" == true ]]
}

# bats test_tags=unit
@test "parse_args: -v shorthand sets OPT_VERSION to true" {
    parse_args -v

    [[ "$OPT_VERSION" == true ]]
}

# bats test_tags=unit
@test "parse_args: --help sets OPT_HELP to true" {
    parse_args --help

    [[ "$OPT_HELP" == true ]]
}

# bats test_tags=unit
@test "parse_args: -h shorthand sets OPT_HELP to true" {
    parse_args -h

    [[ "$OPT_HELP" == true ]]
}

# bats test_tags=unit
@test "parse_args: --update sets OPT_UPDATE to true" {
    parse_args --update

    [[ "$OPT_UPDATE" == true ]]
}

# bats test_tags=unit
@test "parse_args: positional argument sets OPT_WORKSPACE" {
    parse_args /some/path

    [[ "$OPT_WORKSPACE" == "/some/path" ]]
}

# bats test_tags=unit
@test "parse_args: --mount adds to OPT_EXTRA_MOUNTS" {
    parse_args --mount /foo/bar

    [[ "${#OPT_EXTRA_MOUNTS[@]}" -eq 1 ]]
    [[ "${OPT_EXTRA_MOUNTS[0]}" == "/foo/bar" ]]
}

# bats test_tags=unit
@test "parse_args: multiple --mount flags accumulate in OPT_EXTRA_MOUNTS" {
    parse_args --mount /foo/bar --mount /baz/qux

    [[ "${#OPT_EXTRA_MOUNTS[@]}" -eq 2 ]]
    [[ "${OPT_EXTRA_MOUNTS[0]}" == "/foo/bar" ]]
    [[ "${OPT_EXTRA_MOUNTS[1]}" == "/baz/qux" ]]
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

    [[ "$OPT_WORKSPACE" == "/my/workspace" ]]
}

# ---------------------------------------------------------------------------
# 2. apply_config_defaults Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "apply_config_defaults: empty OPT_AGENT falls back to CFG_AGENT" {
    parse_args
    CFG_AGENT="opencode"
    apply_config_defaults

    [[ "$OPT_AGENT" == "opencode" ]]
}

# bats test_tags=unit
@test "apply_config_defaults: CLI --agent takes precedence over CFG_AGENT" {
    parse_args --agent opencode
    CFG_AGENT="opencode"
    apply_config_defaults

    [[ "$OPT_AGENT" == "opencode" ]]
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

    [[ "$OPT_FOLLOW_SYMLINKS" == true ]]
}

# bats test_tags=unit
@test "apply_config_defaults: CFG_FOLLOW_ALL_SYMLINKS=true sets both follow flags" {
    parse_args
    CFG_AGENT="opencode"
    CFG_FOLLOW_SYMLINKS=false
    CFG_FOLLOW_ALL_SYMLINKS=true
    apply_config_defaults

    [[ "$OPT_FOLLOW_ALL_SYMLINKS" == true ]]
    [[ "$OPT_FOLLOW_SYMLINKS"     == true ]]
}

# bats test_tags=unit
@test "apply_config_defaults: CLI --follow-symlinks is not overridden by CFG_FOLLOW_SYMLINKS=false" {
    parse_args --follow-symlinks
    CFG_AGENT="opencode"
    CFG_FOLLOW_SYMLINKS=false
    apply_config_defaults

    [[ "$OPT_FOLLOW_SYMLINKS" == true ]]
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
    [[ "$CFG_AGENT"           == "opencode" ]]
    [[ "$CFG_MEMORY"          == "32g"    ]]
    [[ "$CFG_CPUS"            -eq 16      ]]
    [[ "$CFG_FOLLOW_SYMLINKS" == true     ]]
    # Arrays are reset to empty
    [[ "${#CFG_EXTRA_VARS[@]}" -eq 0 ]]
}

# bats test_tags=unit
@test "parse_config: valid config sets all fields correctly" {
    CONFIG_FILE="${FIXTURE_DIR}/config-valid.toml"
    parse_config

    [[ "$CFG_AGENT"           == "opencode" ]]
    [[ "$CFG_MEMORY"          == "16g"    ]]
    [[ "$CFG_CPUS"            -eq 8       ]]
    [[ "$CFG_FOLLOW_SYMLINKS" == true     ]]
    [[ "${#CFG_EXTRA_VARS[@]}" -eq 1      ]]
    [[ "${CFG_EXTRA_VARS[0]}" == "CUSTOM_VAR" ]]
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
    [[ "$CFG_AGENT"  == "opencode"  ]]
    # Other values should remain at defaults
    [[ "$CFG_MEMORY" == "8g"      ]]
    [[ "$CFG_CPUS"   -eq 4        ]]
    [[ "$CFG_FOLLOW_SYMLINKS" == false ]]
    [[ "${#CFG_EXTRA_VARS[@]}" -eq 0   ]]
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

    [[ "${#CFG_EXTRA_VARS[@]}" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# 4. Container Naming Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "sanitize_basename: lowercases uppercase letters" {
    local result
    result=$(sanitize_basename "MyProject")

    [[ "$result" == "myproject" ]]
}

# bats test_tags=unit
@test "sanitize_basename: strips underscores" {
    local result
    result=$(sanitize_basename "my_project")

    [[ "$result" == "myproject" ]]
}

# bats test_tags=unit
@test "sanitize_basename: strips dots" {
    local result
    result=$(sanitize_basename "project.v2")

    [[ "$result" == "projectv2" ]]
}

# bats test_tags=unit
@test "sanitize_basename: preserves hyphens" {
    local result
    result=$(sanitize_basename "my-project")

    [[ "$result" == "my-project" ]]
}

# bats test_tags=unit
@test "sanitize_basename: strips special characters leaving only [a-z0-9-]" {
    local result
    result=$(sanitize_basename "My_Project.v2")

    # Only lowercase alphanumeric and hyphens remain
    [[ "$result" =~ ^[a-z0-9-]*$ ]]
    [[ "$result" == "myprojectv2" ]]
}

# bats test_tags=unit
@test "sanitize_basename: handles empty string" {
    local result
    result=$(sanitize_basename "")

    [[ "$result" == "" ]]
}

# bats test_tags=unit
@test "sanitize_basename: strips spaces" {
    local result
    result=$(sanitize_basename "my project")

    [[ "$result" == "myproject" ]]
}

# bats test_tags=unit
@test "compute_workspace_hash: returns a 6-character hex string" {
    local result
    result=$(compute_workspace_hash "/home/user/my-project")

    [[ ${#result} -eq 6 ]]
    [[ "$result" =~ ^[0-9a-f]{6}$ ]]
}

# bats test_tags=unit
@test "compute_workspace_hash: same path always produces the same hash (deterministic)" {
    local hash1 hash2
    hash1=$(compute_workspace_hash "/home/user/my-project")
    hash2=$(compute_workspace_hash "/home/user/my-project")

    [[ "$hash1" == "$hash2" ]]
}

# bats test_tags=unit
@test "compute_workspace_hash: different paths produce different hashes" {
    local hash1 hash2
    hash1=$(compute_workspace_hash "/home/user/project-a")
    hash2=$(compute_workspace_hash "/home/user/project-b")

    [[ "$hash1" != "$hash2" ]]
}

# bats test_tags=unit
@test "compute_container_name: returns expected pattern for opencode agent" {
    local result
    result=$(compute_container_name "opencode" "/home/user/my-project")

    # Should match: agent-sandbox-opencode-my-project-<6chars>
    [[ "$result" =~ ^agent-sandbox-opencode-my-project-[0-9a-f]{6}$ ]]
}

# bats test_tags=unit
@test "compute_container_name: same path always produces the same name (deterministic)" {
    local name1 name2
    name1=$(compute_container_name "opencode" "/home/user/my-project")
    name2=$(compute_container_name "opencode" "/home/user/my-project")

    [[ "$name1" == "$name2" ]]
}

# bats test_tags=unit
@test "compute_container_name: different paths produce different names" {
    local name1 name2
    name1=$(compute_container_name "opencode" "/home/user/project-a")
    name2=$(compute_container_name "opencode" "/home/user/project-b")

    [[ "$name1" != "$name2" ]]
}

# bats test_tags=unit
@test "compute_container_name: sanitizes basename with special characters" {
    local result
    result=$(compute_container_name "opencode" "/home/user/My_Project.v2")

    # Basename "My_Project.v2" → sanitized to "myprojectv2"
    [[ "$result" =~ ^agent-sandbox-opencode-myprojectv2-[0-9a-f]{6}$ ]]
}

# bats test_tags=unit
@test "compute_container_name: name contains only safe characters" {
    local result
    result=$(compute_container_name "opencode" "/home/user/my-project")

    # Container names must be safe for use as DNS names / container identifiers
    [[ "$result" =~ ^[a-z0-9-]+$ ]]
}

# ---------------------------------------------------------------------------
# 5. Image Tag Computation Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "image tag: uses VERSION for image tag" {
    [[ "$VERSION" == "0.1.0-test" ]]
    local tag="agent-sandbox:${VERSION}"
    [[ "$tag" == "agent-sandbox:0.1.0-test" ]]
}

# ---------------------------------------------------------------------------
# 6. Symlink Resolution Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "collect_symlink_mounts: mounts external directory symlinks" {
    local workspace ext_dir
    workspace="$(mktemp -d)"
    ext_dir="$(mktemp -d)"
    # Register cleanup trap so temp dirs are removed even if the test fails
    # shellcheck disable=SC2064
    trap "rm -rf '$workspace' '$ext_dir'" EXIT

    mkdir -p "${ext_dir}/some-content"
    ln -s "$ext_dir" "${workspace}/link-to-external"

    # Resolve paths as the launcher will (portable_realpath resolves /var -> /private/var on macOS)
    local resolved_ext
    resolved_ext=$(portable_realpath "$ext_dir")

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    collect_symlink_mounts

    rm -rf "$workspace" "$ext_dir"
    trap - EXIT

    # The resolved external dir should appear in MOUNT_FLAGS
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == "${resolved_ext}:${resolved_ext}:rw" ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == true ]]
}

# bats test_tags=unit
@test "collect_symlink_mounts: skips broken symlinks" {
    local workspace
    workspace="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$workspace'" EXIT

    ln -s "/nonexistent/broken-target" "${workspace}/broken-link"

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    # Should not fail even with broken symlinks
    collect_symlink_mounts

    rm -rf "$workspace"
    trap - EXIT

    # /nonexistent/broken-target must not appear in MOUNT_FLAGS
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"broken-target"* ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == false ]]
}

# bats test_tags=unit
@test "collect_symlink_mounts: skips dotfile dirs when OPT_FOLLOW_ALL_SYMLINKS=false" {
    local workspace dot_parent dot_dir
    workspace="$(mktemp -d)"
    dot_parent="$(mktemp -d)"
    dot_dir="${dot_parent}/.dotfile-test-$$"
    mkdir -p "$dot_dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$workspace' '$dot_parent'" EXIT

    ln -s "$dot_dir" "${workspace}/link-to-dotdir"

    # Resolve as the launcher will
    local resolved_dot
    resolved_dot=$(portable_realpath "$dot_dir")

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    collect_symlink_mounts

    rm -rf "$workspace" "$dot_parent"
    trap - EXIT

    # The dotfile dir must NOT appear in MOUNT_FLAGS
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"${resolved_dot}"* ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == false ]]
}

# bats test_tags=unit
@test "collect_symlink_mounts: includes dotfile dirs when OPT_FOLLOW_ALL_SYMLINKS=true" {
    local workspace dot_parent dot_dir
    workspace="$(mktemp -d)"
    dot_parent="$(mktemp -d)"
    dot_dir="${dot_parent}/.dotfile-test-$$"
    mkdir -p "$dot_dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$workspace' '$dot_parent'" EXIT

    ln -s "$dot_dir" "${workspace}/link-to-dotdir"

    # Resolve as the launcher will
    local resolved_dot
    resolved_dot=$(portable_realpath "$dot_dir")

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=true

    collect_symlink_mounts

    rm -rf "$workspace" "$dot_parent"
    trap - EXIT

    # The dotfile dir SHOULD appear in MOUNT_FLAGS
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"${resolved_dot}"* ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == true ]]
}

# bats test_tags=unit
@test "collect_symlink_mounts: skips regular directories (non-symlinks)" {
    local workspace
    workspace="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$workspace'" EXIT

    mkdir -p "${workspace}/regular-dir"

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    collect_symlink_mounts

    rm -rf "$workspace"
    trap - EXIT

    # The regular-dir inside the workspace must not appear as a separate mount
    local found=false
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == *"regular-dir"* ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == false ]]
}

# bats test_tags=unit
@test "collect_symlink_mounts: deduplicates identical symlink targets" {
    local workspace ext_dir
    workspace="$(mktemp -d)"
    ext_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$workspace' '$ext_dir'" EXIT

    # Two symlinks pointing to the same external directory
    ln -s "$ext_dir" "${workspace}/link-a"
    ln -s "$ext_dir" "${workspace}/link-b"

    # Resolve as the launcher will
    local resolved_ext
    resolved_ext=$(portable_realpath "$ext_dir")

    WORKSPACE="$workspace"
    MOUNT_FLAGS=()
    MOUNT_Z=""
    OPT_FOLLOW_ALL_SYMLINKS=false

    collect_symlink_mounts

    rm -rf "$workspace" "$ext_dir"
    trap - EXIT

    # Count how many times the resolved external dir appears as a mount value in MOUNT_FLAGS
    local count=0
    for flag in "${MOUNT_FLAGS[@]}"; do
        if [[ "$flag" == "${resolved_ext}:${resolved_ext}:rw" ]]; then
            count=$((count + 1))
        fi
    done
    [[ "$count" -eq 1 ]]
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

    # ENV_FLAGS should contain "-e" "AGENT=opencode"
    local found=false
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "AGENT=opencode" ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == true ]]
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

    # ANTHROPIC_API_KEY should be in ENV_FLAGS (as "-e" "ANTHROPIC_API_KEY")
    local found_anthropic=false
    local found_openai=false
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "ANTHROPIC_API_KEY" ]]; then
            found_anthropic=true
        fi
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "OPENAI_API_KEY" ]]; then
            found_openai=true
        fi
    done
    [[ "$found_anthropic" == true  ]]
    [[ "$found_openai"    == false ]]
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

    # None of the default API keys should appear since they are all unset
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" ]]; then
            local val="${ENV_FLAGS[$i+1]}"
            # Only AGENT=... and possibly SSH/NO_SSH flags are expected
            if [[ "$val" != "AGENT="* && "$val" != "SSH_AUTH_SOCK="* && "$val" != "AGENT_SANDBOX_NO_SSH="* ]]; then
                fail "Unexpected env flag: $val"
            fi
        fi
    done
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

    local found=false
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "MY_CUSTOM_VAR" ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == true ]]
}

# bats test_tags=unit
@test "assemble_env_flags: does not include CFG_EXTRA_VARS when var is unset" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=("MY_UNSET_VAR")
    unset MY_UNSET_VAR 2>/dev/null || true

    assemble_env_flags

    local found=false
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "MY_UNSET_VAR" ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == false ]]
}

# bats test_tags=unit
@test "assemble_env_flags: includes SSH_AUTH_SOCK when SSH_FORWARDED=true" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=true
    CFG_EXTRA_VARS=()

    assemble_env_flags

    local found=false
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "SSH_AUTH_SOCK=/tmp/ssh_auth_sock" ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == true ]]
}

# bats test_tags=unit
@test "assemble_env_flags: does not include SSH_AUTH_SOCK when SSH_FORWARDED=false" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()

    assemble_env_flags

    local found=false
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "SSH_AUTH_SOCK=/tmp/ssh_auth_sock" ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == false ]]
}

# bats test_tags=unit
@test "assemble_env_flags: includes AGENT_SANDBOX_NO_SSH when OPT_NO_SSH=true" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=true
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()

    assemble_env_flags

    local found=false
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "AGENT_SANDBOX_NO_SSH=1" ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == true ]]
}

# bats test_tags=unit
@test "assemble_env_flags: does not include AGENT_SANDBOX_NO_SSH when OPT_NO_SSH=false" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()

    assemble_env_flags

    local found=false
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "AGENT_SANDBOX_NO_SSH=1" ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == false ]]
}

# bats test_tags=unit
@test "assemble_env_flags: AGENT reflects opencode when OPT_AGENT=opencode" {
    OPT_AGENT="opencode"
    OPT_NO_SSH=false
    SSH_FORWARDED=false
    CFG_EXTRA_VARS=()

    assemble_env_flags

    local found=false
    local i
    for (( i=0; i<${#ENV_FLAGS[@]}; i++ )); do
        if [[ "${ENV_FLAGS[$i]}" == "-e" && "${ENV_FLAGS[$i+1]}" == "AGENT=opencode" ]]; then
            found=true
            break
        fi
    done
    [[ "$found" == true ]]
}

# ---------------------------------------------------------------------------
# 8. resolve_workspace Tests
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "resolve_workspace: resolves an existing directory" {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

    # Compute expected value while the directory still exists
    local expected
    expected=$(portable_realpath "$tmp_dir")

    # Use run to isolate die() calls from the parent shell
    run resolve_workspace "$tmp_dir"

    rm -rf "$tmp_dir"
    trap - EXIT

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
    # shellcheck disable=SC2064
    trap "rm -rf '${HOME}/test-workspace-$$'" EXIT

    # Use run to isolate die() calls from the parent shell
    run resolve_workspace "~/test-workspace-$$"

    rm -rf "${HOME}/test-workspace-$$"
    trap - EXIT

    assert_success
    # portable_realpath may resolve symlinks (e.g. /var -> /private/var on macOS),
    # so compare the resolved HOME prefix rather than the raw HOME value.
    local resolved_home
    resolved_home=$(portable_realpath "$HOME")
    assert_output "${resolved_home}/test-workspace-$$"
}

# bats test_tags=unit
@test "resolve_workspace: uses PWD when no argument given" {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

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

    rm -rf "$tmp_dir"
    trap - EXIT

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

