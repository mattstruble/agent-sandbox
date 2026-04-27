#!/usr/bin/env bats
# tests/integration/container.bats — container integration tests
#
# These tests drive `podman run` / `docker run` against the built container image
# to validate image contents, firewall behavior, entrypoint logic, and config staging.
#
# Requirements:
#   - A container runtime (podman or docker) must be available.
#   - The image must be pre-built (Makefile `ensure-image` target handles this).
#   - Run via: make test-integration  OR  bats --filter-tags integration -r tests/
#
# All tests are tagged `integration` so they can be filtered independently of unit tests.
#
# Network dependency: firewall connectivity tests (TCP 80/443, DNS) make live outbound
# connections to 93.184.216.34 (example.com). They require internet access from the
# test host. NTP and blocked-port tests use iptables rule inspection instead and do
# not require live connectivity.

setup() {
    load '../test_helper'
    RUNTIME=$(runtime_name) || skip "No container runtime found"
    export AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-0.1.0}"
    IMAGE="agent-sandbox:${AGENT_SANDBOX_VERSION}"

    # Verify the image exists; skip rather than fail if not built yet.
    if ! "$RUNTIME" images -q "$IMAGE" 2>/dev/null | grep -q .; then
        skip "Image $IMAGE not found — build via 'nix build .#container-image' and load, or run 'make ensure-image'"
    fi

    # Use BATS_TEST_TMPDIR for all temp files so bats auto-cleans on test exit,
    # including on assertion failure. Tests assign to these variables; teardown
    # removes them unconditionally.
    _TEST_WORKSPACE=""
    _TEST_AGENT=""
    _TEST_GITCONFIG=""
    _TEST_HOST_CONFIG_DIR=""
    _OPENCODE_PATH=""
}

teardown() {
    # Clean up any temp files/dirs created during the test.
    # bats calls teardown even when assertions fail, so cleanup is guaranteed.
    # IMPORTANT: Use `|| true` to prevent short-circuit exit code 1 when the
    # variable is empty. Bats runs teardown under `set -e`, so a bare
    # `[[ -n "" ]] && cmd` returns 1 and fails the teardown (and the test).
    [[ -n "$_TEST_WORKSPACE" ]] && rm -rf "$_TEST_WORKSPACE" || true
    [[ -n "$_TEST_AGENT" ]] && rm -f "$_TEST_AGENT" || true
    [[ -n "$_TEST_GITCONFIG" ]] && rm -f "$_TEST_GITCONFIG" || true
    [[ -n "$_TEST_HOST_CONFIG_DIR" ]] && rm -rf "$_TEST_HOST_CONFIG_DIR" || true
}

# ---------------------------------------------------------------------------
# Helper: _run_in_sandbox
# ---------------------------------------------------------------------------
# Run a command inside the container with production-equivalent security flags.
# Usage: _run_in_sandbox "bash -c 'command'"
# For tests that need additional flags (volumes, env vars), use the runtime directly.
_run_in_sandbox() {
    "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c "$1"
}

# ---------------------------------------------------------------------------
# Helper: _run_with_entrypoint
# ---------------------------------------------------------------------------
# Run the container using the image's default entrypoint (entrypoint.sh) with
# production-equivalent security flags. Accepts optional flags:
#   -a AGENT         Set AGENT env var (omit to test missing-AGENT error path)
#   -w WORKSPACE     Mount workspace dir and set SANDBOX_WORKSPACE env
#   -b AGENT_SCRIPT  Mount script over the opencode binary. Requires
#                    _ensure_opencode_path to be called first (outside `run`)
#                    so that skip propagates correctly to BATS.
#   -c CONFIG_DIR    Mount host config at /host-config/opencode:ro
#   -e KEY=VAL       Extra -e flags (repeatable)
#   -v SRC:DST:OPT   Extra -v flags (repeatable)
_run_with_entrypoint() {
    local agent="" workspace="" agent_script="" config_dir=""
    local -a extra_env=() extra_vol=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a) [[ $# -ge 2 ]] || { echo "Flag $1 requires an argument" >&2; return 1; }; agent="$2"; shift 2 ;;
            -w) [[ $# -ge 2 ]] || { echo "Flag $1 requires an argument" >&2; return 1; }; workspace="$2"; shift 2 ;;
            -b) [[ $# -ge 2 ]] || { echo "Flag $1 requires an argument" >&2; return 1; }; agent_script="$2"; shift 2 ;;
            -c) [[ $# -ge 2 ]] || { echo "Flag $1 requires an argument" >&2; return 1; }; config_dir="$2"; shift 2 ;;
            -e) [[ $# -ge 2 ]] || { echo "Flag $1 requires an argument" >&2; return 1; }; extra_env+=(-e "$2"); shift 2 ;;
            -v) [[ $# -ge 2 ]] || { echo "Flag $1 requires an argument" >&2; return 1; }; extra_vol+=(-v "$2"); shift 2 ;;
            *)  echo "Unknown _run_with_entrypoint flag: $1" >&2; return 1 ;;
        esac
    done

    local -a cmd=(
        "$RUNTIME" run --rm
        --cap-add=NET_ADMIN
        --cap-add=NET_RAW
        --cap-add=SETUID
        --cap-add=SETGID
        --cap-add=SYS_TIME
        --sysctl=net.ipv6.conf.all.disable_ipv6=1
        --sysctl=net.ipv6.conf.default.disable_ipv6=1
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1
        --security-opt=no-new-privileges
    )

    [[ -n "$agent" ]] && cmd+=(-e "AGENT=${agent}")

    if [[ -n "$workspace" ]]; then
        cmd+=(-v "${workspace}:${workspace}:rw" -e "SANDBOX_WORKSPACE=${workspace}")
    fi

    [[ -n "$agent_script" ]] && cmd+=(-v "${agent_script}:${_OPENCODE_PATH}:ro")

    [[ -n "$config_dir" ]] && cmd+=(-v "${config_dir}:/host-config/opencode:ro")

    cmd+=("${extra_env[@]}" "${extra_vol[@]}" "$IMAGE")

    "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# Helper: _ensure_opencode_path
# ---------------------------------------------------------------------------
# Populate _OPENCODE_PATH with the absolute path to the opencode binary inside
# the image. Must be called directly in the test body (not inside `run`) so
# that `skip` propagates correctly to BATS when the path cannot be determined.
_ensure_opencode_path() {
    if [[ -z "${_OPENCODE_PATH:-}" ]]; then
        _OPENCODE_PATH=$("$RUNTIME" run --rm --entrypoint which "$IMAGE" opencode 2>/dev/null || true)
        if [[ -z "$_OPENCODE_PATH" || "$_OPENCODE_PATH" != /* ]]; then
            skip "opencode binary path could not be determined"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: Image Contents
# ─────────────────────────────────────────────────────────────────────────────

# bats test_tags=integration
@test "image: opencode binary exists and is executable" {
    # In the Nix image, opencode is on PATH (installed to the Nix store).
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" opencode
    assert_success
}

# bats test_tags=integration
@test "image: rtk binary exists and is executable" {
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" rtk
    assert_success
}

# bats test_tags=integration
@test "image: gh binary exists and is executable" {
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" gh
    assert_success
}

# bats test_tags=integration
@test "image: uv binary exists and is executable" {
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" uv
    assert_success
}

# bats test_tags=integration
@test "image: node binary exists and is executable" {
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" node
    assert_success
}

# bats test_tags=integration
@test "image: git binary exists and is executable" {
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" git
    assert_success
}

# bats test_tags=integration
@test "image: su-exec binary exists and is executable" {
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" su-exec
    assert_success
}

# bats test_tags=integration
@test "image: nix binary exists and is executable" {
    # Nix is installed via ENV PATH directive, so `which` should find it.
    run "$RUNTIME" run --rm --user sandbox --entrypoint which "$IMAGE" nix
    assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 1b: Nix Runtime Package Management
# ─────────────────────────────────────────────────────────────────────────────

# bats test_tags=integration
@test "nix: nix --version succeeds as sandbox user" {
    run "$RUNTIME" run --rm --user sandbox --entrypoint nix "$IMAGE" --version
    assert_success
    assert_output --partial "nix"
}

# bats test_tags=integration
@test "nix: nix run nixpkgs#hello succeeds" {
    # Validates the full download-from-binary-cache → execute path.
    # Requires network access to cache.nixos.org.
    run "$RUNTIME" run --rm --user sandbox --entrypoint bash "$IMAGE" \
        -c 'nix run nixpkgs#hello'
    assert_success
    assert_output --partial "Hello, world!"
}

# bats test_tags=integration
@test "nix: /etc/nix/nix.conf is root-owned and read-only" {
    run "$RUNTIME" run --rm --entrypoint stat "$IMAGE" -c '%U %a' /etc/nix/nix.conf
    assert_success
    assert_output "root 444"
}

# bats test_tags=integration
@test "nix: /etc/nix/registry.json is root-owned and read-only" {
    run "$RUNTIME" run --rm --entrypoint stat "$IMAGE" -c '%U %a' /etc/nix/registry.json
    assert_success
    assert_output "root 444"
}

# bats test_tags=integration
@test "nix: sandbox user cannot write to /etc/nix/nix.conf" {
    run "$RUNTIME" run --rm --user sandbox --entrypoint bash "$IMAGE" \
        -c 'echo test >> /etc/nix/nix.conf'
    assert_failure
}

# bats test_tags=integration
@test "nix: sandbox user cannot write to /etc/nix/registry.json" {
    run "$RUNTIME" run --rm --user sandbox --entrypoint bash "$IMAGE" \
        -c 'echo test >> /etc/nix/registry.json'
    assert_failure
}

# bats test_tags=integration
@test "nix: sandbox user cannot create files in /etc/nix/" {
    run "$RUNTIME" run --rm --user sandbox --entrypoint bash "$IMAGE" \
        -c 'touch /etc/nix/evil.conf'
    assert_failure
}

# bats test_tags=integration
@test "nix: substituters is cache.nixos.org only" {
    run "$RUNTIME" run --rm --user sandbox --entrypoint bash "$IMAGE" \
        -c 'nix show-config 2>/dev/null | grep "^substituters ="'
    assert_success
    # Nix normalizes URLs with trailing slash; match either form
    assert_output --regexp "^substituters = https://cache\.nixos\.org/?$"
}

# bats test_tags=integration
@test "nix: registry contains pinned nixpkgs" {
    run "$RUNTIME" run --rm --user sandbox --entrypoint bash "$IMAGE" \
        -c 'nix registry list 2>/dev/null'
    assert_success
    assert_output --partial "flake:nixpkgs"
    assert_output --partial "github:NixOS/nixpkgs/"
}

# bats test_tags=integration
@test "nix: command_not_found_handle suggests nix run" {
    # Run a nonexistent command in an interactive bash shell to trigger the handler.
    # The handler is defined in .bashrc, which bash only sources for interactive shells.
    run "$RUNTIME" run --rm --user sandbox --entrypoint bash "$IMAGE" \
        -ic 'nonexistent_tool_xyz 2>&1; true'
    assert_output --partial "nix run nixpkgs#nonexistent_tool_xyz"
}

# bats test_tags=integration
@test "nix: entrypoint appends Nix instructions to AGENTS.md" {
    # Run the entrypoint with a fake agent that checks AGENTS.md content.
    _TEST_WORKSPACE="$(make_tempdir)"
    _TEST_AGENT="$(make_temp)"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'grep -q "Runtime Package Management" ~/.config/opencode/AGENTS.md' \
        > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"
    _ensure_opencode_path

    run _run_with_entrypoint -a opencode -w "$_TEST_WORKSPACE" -b "$_TEST_AGENT"
    assert_success
}

# bats test_tags=integration
@test "nix: Nix instructions are separated from existing AGENTS.md content by a newline" {
    # Pre-populate AGENTS.md with content that does NOT end with a newline.
    # The entrypoint must insert a newline separator before appending, so the
    # Nix instructions start on their own line and are not concatenated onto
    # the last line of the existing content.
    _TEST_WORKSPACE="$(make_tempdir)"
    _TEST_HOST_CONFIG_DIR="$(make_tempdir)"

    # Write AGENTS.md without a trailing newline (simulates a common real-world case)
    printf 'existing content without trailing newline' \
        > "${_TEST_HOST_CONFIG_DIR}/AGENTS.md"

    _TEST_AGENT="$(make_temp)"
    # The fake agent prints AGENTS.md content so we can inspect it
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'cat ~/.config/opencode/AGENTS.md' \
        'exit 0' \
        > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"
    _ensure_opencode_path

    run _run_with_entrypoint -a opencode -w "$_TEST_WORKSPACE" -b "$_TEST_AGENT" -c "$_TEST_HOST_CONFIG_DIR"
    assert_success
    # The existing content and the Nix instructions must be on separate lines.
    # If the newline separator is missing, "existing content without trailing newline"
    # and "# Runtime Package Management" would be concatenated on the same line.
    assert_output --regexp $'existing content without trailing newline\n'
    assert_output --partial "# Runtime Package Management"
}

# bats test_tags=integration
@test "static files: /etc/agent-sandbox/nix-instructions.md exists and is readable" {
    run "$RUNTIME" run --rm --entrypoint test "$IMAGE" -r /etc/agent-sandbox/nix-instructions.md
    assert_success
}

# bats test_tags=integration
@test "static files: /etc/agent-sandbox/opencode-permissions.json exists and is readable" {
    run "$RUNTIME" run --rm --entrypoint test "$IMAGE" -r /etc/agent-sandbox/opencode-permissions.json
    assert_success
}

# bats test_tags=integration
@test "static files: /etc/agent-sandbox/opencode-permissions.json is valid JSON" {
    run "$RUNTIME" run --rm --entrypoint bash "$IMAGE" \
        -c 'jq . < /etc/agent-sandbox/opencode-permissions.json'
    assert_success
    assert_output --partial '"permission"'
    assert_output --partial '"doom_loop"'
    assert_output --partial '"external_directory"'
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: User Setup
# ─────────────────────────────────────────────────────────────────────────────

# bats test_tags=integration
@test "user: sandbox user exists with UID 1000" {
    run "$RUNTIME" run --rm --entrypoint id "$IMAGE" -u sandbox
    assert_success
    assert_output "1000"
}

# bats test_tags=integration
@test "user: sandbox home directory exists and is writable" {
    # Use an explicit path rather than $HOME to avoid depending on $HOME being
    # set correctly when --user 1000 is used without a login shell.
    run "$RUNTIME" run --rm \
        --user 1000 \
        --entrypoint bash "$IMAGE" \
        -c 'test -d /home/sandbox && touch /home/sandbox/.test-write-check && rm /home/sandbox/.test-write-check'
    assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 3: Firewall Rules
#
# These tests use --entrypoint bash to run init-firewall.sh directly, then
# probe the resulting iptables state or network connectivity. This approach
# isolates each firewall property without needing a full entrypoint run.
#
# Connectivity tests (TCP 80/443, DNS) require internet access from the test host.
# NTP and blocked-port tests use iptables rule inspection and are offline-safe.
# ─────────────────────────────────────────────────────────────────────────────

# bats test_tags=integration
@test "firewall: IPv6 is disabled" {
    run _run_in_sandbox 'cat /proc/sys/net/ipv6/conf/all/disable_ipv6'
    assert_success
    assert_output "1"
}

# bats test_tags=integration,network
@test "firewall: outbound TCP 443 (HTTPS) is allowed" {
    # Requires internet access: init-firewall.sh itself verifies HTTPS reachability
    # as part of its post-setup check, and this test also probes it directly.
    run _run_in_sandbox '/init-firewall.sh >/dev/null 2>&1 && timeout 5 bash -c "echo >/dev/tcp/93.184.216.34/443" 2>/dev/null && echo "HTTPS_OK"'
    assert_success
    assert_output --partial "HTTPS_OK"
}

# bats test_tags=integration,network
@test "firewall: outbound TCP 80 (HTTP) is allowed" {
    # Requires internet access: see note on TCP 443 test above.
    run _run_in_sandbox '/init-firewall.sh >/dev/null 2>&1 && timeout 5 bash -c "echo >/dev/tcp/93.184.216.34/80" 2>/dev/null && echo "HTTP_OK"'
    assert_success
    assert_output --partial "HTTP_OK"
}

# bats test_tags=integration
@test "firewall: catch-all REJECT rule blocks non-allowed TCP ports" {
    # The firewall uses a catch-all REJECT at the end of the OUTPUT chain
    # (after ACCEPT rules for allowed ports: 80, 443, 22, DNS, NTP).
    # Verify:
    #   1. The catch-all REJECT rule exists as the final rule (no dport qualifier).
    #   2. An arbitrary non-allowed port (8080) has no ACCEPT rule.
    run _run_in_sandbox '/init-firewall.sh >/dev/null 2>&1 || { echo "FIREWALL_INIT_FAILED"; exit 1; }
            # Verify the catch-all REJECT rule exists (REJECT with no dpt: qualifier = catch-all)
            if iptables -L OUTPUT -n | grep -E "^REJECT" | grep -qv "dpt:"; then
                echo "CATCHALL_REJECT_PRESENT"
            else
                echo "CATCHALL_REJECT_MISSING"
            fi
            # Verify port 8080 is NOT in any ACCEPT rule
            if iptables -L OUTPUT -n | grep "ACCEPT" | grep -q "dpt:8080"; then
                echo "PORT_ACCEPTED"
            else
                echo "PORT_NOT_ACCEPTED"
            fi'
    assert_success
    assert_output --partial "CATCHALL_REJECT_PRESENT"
    assert_output --partial "PORT_NOT_ACCEPTED"
}

# bats test_tags=integration,network
@test "firewall: DNS resolution works through pinned resolver" {
    # Requires internet access: getent hosts makes a live DNS query.
    run _run_in_sandbox '/init-firewall.sh >/dev/null 2>&1 && getent hosts example.com'
    assert_success
    # Verify the output contains an IP address, not just any non-empty string.
    assert_output --regexp '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

# bats test_tags=integration
@test "firewall: NTP iptables rule allows UDP 123 to Cloudflare 162.159.200.1" {
    # UDP is connectionless so we verify the iptables ACCEPT rule is present
    # rather than attempting a live NTP exchange. Uses word-boundary grep to
    # avoid matching 162.159.200.123 when checking for 162.159.200.1.
    run _run_in_sandbox '/init-firewall.sh >/dev/null 2>&1 && iptables -L OUTPUT -n | grep "udp dpt:123" | grep -w "162.159.200.1"'
    assert_success
}

# bats test_tags=integration
@test "firewall: NTP iptables rule allows UDP 123 to Cloudflare 162.159.200.123" {
    # UDP is connectionless so we verify the iptables ACCEPT rule is present
    # rather than attempting a live NTP exchange.
    run _run_in_sandbox '/init-firewall.sh >/dev/null 2>&1 && iptables -L OUTPUT -n | grep "udp dpt:123" | grep -w "162.159.200.123"'
    assert_success
}

# bats test_tags=integration
@test "firewall: NTP iptables rule rejects UDP 123 to non-pinned IPs" {
    # Verify the catch-all REJECT rule for UDP 123 (after the Cloudflare ACCEPT rules)
    # is present. This ensures non-Cloudflare NTP is blocked.
    run _run_in_sandbox '/init-firewall.sh >/dev/null 2>&1 && iptables -L OUTPUT -n | grep "udp dpt:123" | grep "REJECT"'
    assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 4: Entrypoint Behavior
# ─────────────────────────────────────────────────────────────────────────────

# bats test_tags=integration
@test "entrypoint: drops to sandbox user before executing agent (su-exec)" {
    # Mount the fake agent over the real opencode binary.
    # The entrypoint starts as root, sets up the firewall, then re-execs as sandbox via su-exec.
    # We verify the user drop by having the fake agent print its effective username.
    _TEST_WORKSPACE=$(make_tempdir)
    _TEST_AGENT=$(make_temp)
    # Use printf '%s\n' to write each line; prevents host-side expansion of $() and ${}.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'echo "FAKE_AGENT_MARKER: agent-sandbox-test-sentinel"' \
        'echo "RUNNING_AS_USER=$(id -un)"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"
    _ensure_opencode_path

    run _run_with_entrypoint -a opencode -w "$_TEST_WORKSPACE" -b "$_TEST_AGENT"
    assert_success
    assert_output --partial "FAKE_AGENT_MARKER"
    assert_output --partial "RUNNING_AS_USER=sandbox"
}

# bats test_tags=integration
@test "entrypoint: fails with clear error when AGENT is not set" {
    # Omit -a so AGENT is unset; the entrypoint should reject this before doing any real work.
    run _run_with_entrypoint
    assert_failure
    assert_output --partial "AGENT environment variable is not set"
}

# bats test_tags=integration
@test "entrypoint: fails with clear error when AGENT is invalid" {
    run _run_with_entrypoint -a invalid-agent
    assert_failure
    assert_output --partial "not valid"
}

# bats test_tags=integration
@test "entrypoint: opencode permission overrides are written to config file" {
    # The entrypoint (Phase 2) creates ~/.config/opencode/opencode.json with
    # permission overrides. We run the full entrypoint and have the fake agent
    # print the config file contents to verify the overrides were applied.
    _TEST_WORKSPACE=$(make_tempdir)
    _TEST_AGENT=$(make_temp)
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'cat "${HOME}/.config/opencode/opencode.json" 2>/dev/null || echo "CONFIG_NOT_FOUND"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"
    _ensure_opencode_path

    run _run_with_entrypoint -a opencode -w "$_TEST_WORKSPACE" -b "$_TEST_AGENT"
    assert_success
    assert_output --partial '"*": "allow"'
    assert_output --partial '"doom_loop": "ask"'
    assert_output --partial '"external_directory"'
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 5: Config Staging
# ─────────────────────────────────────────────────────────────────────────────

# bats test_tags=integration
@test "config staging: git config mounted at expected path is readable" {
    _TEST_GITCONFIG=$(make_temp)
    printf '[user]\n  name = Test User\n  email = test@example.com\n' > "$_TEST_GITCONFIG"

    run "$RUNTIME" run --rm \
        -v "${_TEST_GITCONFIG}:/home/sandbox/.gitconfig:ro" \
        --entrypoint cat \
        "$IMAGE" \
        /home/sandbox/.gitconfig
    assert_success
    assert_output --partial "Test User"
    assert_output --partial "test@example.com"
}

# bats test_tags=integration
@test "config staging: git config is read-only (not writable by sandbox user)" {
    _TEST_GITCONFIG=$(make_temp)
    printf '[user]\n  name = Test User\n' > "$_TEST_GITCONFIG"

    # Attempt to append to the read-only mounted file as the sandbox user.
    # The :ro mount flag should cause the write to fail.
    run "$RUNTIME" run --rm \
        --user 1000 \
        -v "${_TEST_GITCONFIG}:/home/sandbox/.gitconfig:ro" \
        --entrypoint bash \
        "$IMAGE" \
        -c '{ echo "modified" >> /home/sandbox/.gitconfig && echo "WRITE_SUCCEEDED"; } || echo "WRITE_BLOCKED"'
    assert_success
    assert_output --partial "WRITE_BLOCKED"
}

# bats test_tags=integration
@test "config staging: environment variable passed via -e is visible to agent" {
    _TEST_WORKSPACE=$(make_tempdir)
    _TEST_AGENT=$(make_temp)
    # Use printf '%s\n' to write each line; prevents host-side expansion of ${...}.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'echo "ENV_VAR_VALUE=${TEST_INTEGRATION_VAR}"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"
    _ensure_opencode_path

    run _run_with_entrypoint -a opencode -w "$_TEST_WORKSPACE" -b "$_TEST_AGENT" \
        -e TEST_INTEGRATION_VAR=hello-from-host
    assert_success
    assert_output --partial "ENV_VAR_VALUE=hello-from-host"
}

# bats test_tags=integration
@test "config staging: opencode host config is staged and permission overrides replace user prefs" {
    # Mount a fake opencode config at /host-config/opencode.
    # The entrypoint copies it to ~/.config/opencode, then replaces the entire
    # permission block with sandbox overrides. The fake agent reads the resulting
    # config to verify both staging and full permission replacement worked.
    _TEST_HOST_CONFIG_DIR=$(make_tempdir)
    printf '{"model": "test-model", "permission": {"bash": "deny"}}\n' > "${_TEST_HOST_CONFIG_DIR}/opencode.json"

    _TEST_WORKSPACE=$(make_tempdir)
    _TEST_AGENT=$(make_temp)
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'cat "${HOME}/.config/opencode/opencode.json" 2>/dev/null || echo "CONFIG_NOT_FOUND"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"
    _ensure_opencode_path

    run _run_with_entrypoint -a opencode -w "$_TEST_WORKSPACE" -b "$_TEST_AGENT" \
        -c "$_TEST_HOST_CONFIG_DIR"
    assert_success
    # Non-permission config is preserved
    assert_output --partial '"model": "test-model"'
    # Permission block is fully replaced
    assert_output --partial '"*": "allow"'
    assert_output --partial '"doom_loop": "ask"'
    # User's deny should NOT appear — sandbox overrides everything
    refute_output --partial '"bash": "deny"'
}
