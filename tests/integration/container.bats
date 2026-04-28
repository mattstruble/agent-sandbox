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
@test "image: ty binary exists and is executable" {
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" ty
    assert_success
}

# bats test_tags=integration
@test "image: nixd binary exists and is executable" {
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" nixd
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

    # Determine opencode binary path inside the image
    local opencode_path
    opencode_path=$("$RUNTIME" run --rm --entrypoint which "$IMAGE" opencode 2>/dev/null || true)
    if [[ -z "$opencode_path" || "$opencode_path" != /* ]]; then
        skip "opencode binary path could not be determined"
    fi

    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=SYS_TIME \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        -e AGENT=opencode \
        -v "${_TEST_WORKSPACE}:${_TEST_WORKSPACE}:rw" \
        -e SANDBOX_WORKSPACE="${_TEST_WORKSPACE}" \
        -v "${_TEST_AGENT}:${opencode_path}:ro" \
        "$IMAGE"
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

    local opencode_path
    opencode_path=$("$RUNTIME" run --rm --entrypoint which "$IMAGE" opencode 2>/dev/null || true)
    if [[ -z "$opencode_path" || "$opencode_path" != /* ]]; then
        skip "opencode binary path could not be determined"
    fi

    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=SYS_TIME \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        -e AGENT=opencode \
        -v "${_TEST_AGENT}:${opencode_path}:ro" \
        -v "${_TEST_HOST_CONFIG_DIR}:/host-config/opencode:ro" \
        -v "${_TEST_WORKSPACE}:${_TEST_WORKSPACE}:rw" \
        -e SANDBOX_WORKSPACE="${_TEST_WORKSPACE}" \
        "$IMAGE"
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
@test "static files: /etc/agent-sandbox/opencode-config.json exists and is readable" {
    run "$RUNTIME" run --rm --entrypoint test "$IMAGE" -r /etc/agent-sandbox/opencode-config.json
    assert_success
}

# bats test_tags=integration
@test "static files: /etc/agent-sandbox/opencode-config.json is valid JSON" {
    run "$RUNTIME" run --rm --entrypoint bash "$IMAGE" \
        -c 'jq . < /etc/agent-sandbox/opencode-config.json'
    assert_success
    assert_output --partial '"permission"'
    assert_output --partial '"doom_loop"'
    assert_output --partial '"external_directory"'
    assert_output --partial '"deny"'
    assert_output --partial '"lsp"'
    assert_output --partial '"ty"'
    assert_output --partial '"nixd"'
    assert_output --partial '"pyright"'
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
@test "firewall: non-allowed TCP ports are blocked by catch-all REJECT rule (port 8080)" {
    # The firewall design uses a catch-all REJECT at the end of the OUTPUT chain
    # (after ACCEPT rules for allowed ports: 80, 443, 22, DNS, NTP).
    # This test verifies two things:
    #   1. The catch-all REJECT rule exists as the final rule in OUTPUT (no dport).
    #   2. Port 8080 has no ACCEPT rule — it falls through to the catch-all.
    # This is more specific than checking for any REJECT rule, which would pass
    # even if only an unrelated port had a REJECT rule.
    run _run_in_sandbox '/init-firewall.sh >/dev/null 2>&1 || { echo "FIREWALL_INIT_FAILED"; exit 1; }
            # Verify the catch-all REJECT rule exists (REJECT with no dpt: qualifier = catch-all)
            if iptables -L OUTPUT -n | grep -E "^REJECT" | grep -qv "dpt:"; then
                echo "CATCHALL_REJECT_PRESENT"
            else
                echo "CATCHALL_REJECT_MISSING"
            fi
            # Verify port 8080 is NOT in any ACCEPT rule
            if iptables -L OUTPUT -n | grep "ACCEPT" | grep -q "dpt:8080"; then
                echo "PORT_8080_ACCEPTED"
            else
                echo "PORT_8080_NOT_ACCEPTED"
            fi'
    assert_success
    assert_output --partial "CATCHALL_REJECT_PRESENT"
    assert_output --partial "PORT_8080_NOT_ACCEPTED"
}

# bats test_tags=integration
@test "firewall: non-allowed TCP ports are blocked by catch-all REJECT rule (port 3000)" {
    # Same verification as port 8080: the catch-all REJECT blocks port 3000 because
    # there is no ACCEPT rule for it. Tests both the presence of the catch-all and
    # the absence of a port-3000 ACCEPT rule.
    run _run_in_sandbox '/init-firewall.sh >/dev/null 2>&1 || { echo "FIREWALL_INIT_FAILED"; exit 1; }
            # Verify the catch-all REJECT rule exists (REJECT with no dpt: qualifier = catch-all)
            if iptables -L OUTPUT -n | grep -E "^REJECT" | grep -qv "dpt:"; then
                echo "CATCHALL_REJECT_PRESENT"
            else
                echo "CATCHALL_REJECT_MISSING"
            fi
            # Verify port 3000 is NOT in any ACCEPT rule
            if iptables -L OUTPUT -n | grep "ACCEPT" | grep -q "dpt:3000"; then
                echo "PORT_3000_ACCEPTED"
            else
                echo "PORT_3000_NOT_ACCEPTED"
            fi'
    assert_success
    assert_output --partial "CATCHALL_REJECT_PRESENT"
    assert_output --partial "PORT_3000_NOT_ACCEPTED"
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

    # Determine opencode binary path inside the image
    local opencode_path
    opencode_path=$("$RUNTIME" run --rm --entrypoint which "$IMAGE" opencode 2>/dev/null || true)
    if [[ -z "$opencode_path" || "$opencode_path" != /* ]]; then
        skip "opencode binary path could not be determined"
    fi

    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=SYS_TIME \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        -e AGENT=opencode \
        -v "${_TEST_AGENT}:${opencode_path}:ro" \
        -v "${_TEST_WORKSPACE}:${_TEST_WORKSPACE}" \
        -e SANDBOX_WORKSPACE="${_TEST_WORKSPACE}" \
        "$IMAGE"
    assert_success
    assert_output --partial "FAKE_AGENT_MARKER"
    assert_output --partial "RUNNING_AS_USER=sandbox"
}

# bats test_tags=integration
@test "entrypoint: fails with clear error when AGENT is not set" {
    # AGENT validation happens before any capability-requiring operations,
    # so no workspace mount or SETUID/SETGID caps are needed.
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=SYS_TIME \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        "$IMAGE"
    assert_failure
    assert_output --partial "AGENT environment variable is not set"
}

# bats test_tags=integration
@test "entrypoint: fails with clear error when AGENT is invalid" {
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=SYS_TIME \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        -e AGENT=invalid-agent \
        "$IMAGE"
    assert_failure
    assert_output --partial "not valid"
}

# bats test_tags=integration
@test "entrypoint: opencode sandbox overrides are written to config file" {
    # The entrypoint (Phase 2) creates ~/.config/opencode/opencode.json with
    # permission and lsp overrides. We run the full entrypoint and have the
    # fake agent print the config file contents to verify the overrides were
    # applied.
    _TEST_WORKSPACE=$(make_tempdir)
    _TEST_AGENT=$(make_temp)
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'cat "${HOME}/.config/opencode/opencode.json" 2>/dev/null || echo "CONFIG_NOT_FOUND"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"

    # Determine opencode binary path inside the image
    local opencode_path
    opencode_path=$("$RUNTIME" run --rm --entrypoint which "$IMAGE" opencode 2>/dev/null || true)
    if [[ -z "$opencode_path" || "$opencode_path" != /* ]]; then
        skip "opencode binary path could not be determined"
    fi

    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=SYS_TIME \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        -e AGENT=opencode \
        -v "${_TEST_AGENT}:${opencode_path}:ro" \
        -v "${_TEST_WORKSPACE}:${_TEST_WORKSPACE}" \
        -e SANDBOX_WORKSPACE="${_TEST_WORKSPACE}" \
        "$IMAGE"
    assert_success
    assert_output --partial '"*": "allow"'
    assert_output --partial '"doom_loop": "ask"'
    assert_output --partial '"external_directory"'
    assert_output --partial '"deny"'
    assert_output --partial '"lsp"'
    assert_output --partial '"ty"'
    assert_output --partial '"nixd"'
    assert_output --partial '"pyright"'
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

    # Determine opencode binary path inside the image
    local opencode_path
    opencode_path=$("$RUNTIME" run --rm --entrypoint which "$IMAGE" opencode 2>/dev/null || true)
    if [[ -z "$opencode_path" || "$opencode_path" != /* ]]; then
        skip "opencode binary path could not be determined"
    fi

    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=SYS_TIME \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        -e AGENT=opencode \
        -e TEST_INTEGRATION_VAR=hello-from-host \
        -v "${_TEST_AGENT}:${opencode_path}:ro" \
        -v "${_TEST_WORKSPACE}:${_TEST_WORKSPACE}" \
        -e SANDBOX_WORKSPACE="${_TEST_WORKSPACE}" \
        "$IMAGE"
    assert_success
    assert_output --partial "ENV_VAR_VALUE=hello-from-host"
}

# bats test_tags=integration
@test "config staging: opencode host config is staged and sandbox overrides replace user prefs" {
    # Mount a fake opencode config at /host-config/opencode.
    # The entrypoint copies it to ~/.config/opencode, then replaces the
    # `permission` and `lsp` blocks with sandbox overrides. The fake agent
    # reads the resulting config to verify staging, permission replacement,
    # and lsp injection all worked.
    _TEST_HOST_CONFIG_DIR=$(make_tempdir)
    printf '{"model": "test-model", "permission": {"bash": "deny"}}\n' > "${_TEST_HOST_CONFIG_DIR}/opencode.json"

    _TEST_WORKSPACE=$(make_tempdir)
    _TEST_AGENT=$(make_temp)
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'cat "${HOME}/.config/opencode/opencode.json" 2>/dev/null || echo "CONFIG_NOT_FOUND"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"

    # Determine opencode binary path inside the image
    local opencode_path
    opencode_path=$("$RUNTIME" run --rm --entrypoint which "$IMAGE" opencode 2>/dev/null || true)
    if [[ -z "$opencode_path" || "$opencode_path" != /* ]]; then
        skip "opencode binary path could not be determined"
    fi

    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=SYS_TIME \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        -e AGENT=opencode \
        -v "${_TEST_AGENT}:${opencode_path}:ro" \
        -v "${_TEST_HOST_CONFIG_DIR}:/host-config/opencode:ro" \
        -v "${_TEST_WORKSPACE}:${_TEST_WORKSPACE}" \
        -e SANDBOX_WORKSPACE="${_TEST_WORKSPACE}" \
        "$IMAGE"
    assert_success
    # Non-overridden config is preserved
    assert_output --partial '"model": "test-model"'
    # Permission block is fully replaced
    assert_output --partial '"*": "allow"'
    assert_output --partial '"doom_loop": "ask"'
    # User's deny should NOT appear — sandbox overrides everything
    refute_output --partial '"bash": "deny"'
    # LSP block is injected from sandbox defaults
    assert_output --partial '"lsp"'
    assert_output --partial '"ty"'
}

# bats test_tags=integration
@test "config staging: user-supplied lsp entries are replaced wholesale by sandbox defaults" {
    # A user-supplied lsp.<name>.command could point at an arbitrary binary —
    # the sandbox must discard the entire user-provided lsp block and replace
    # it with the baked config. This test pins that contract.
    _TEST_HOST_CONFIG_DIR=$(make_tempdir)
    printf '%s' \
        '{"lsp": {"custom-ls": {"command": ["/bin/evil"], "extensions": [".evil"]}}}' \
        > "${_TEST_HOST_CONFIG_DIR}/opencode.json"

    _TEST_WORKSPACE=$(make_tempdir)
    _TEST_AGENT=$(make_temp)
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'cat "${HOME}/.config/opencode/opencode.json" 2>/dev/null || echo "CONFIG_NOT_FOUND"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"

    # Determine opencode binary path inside the image
    local opencode_path
    opencode_path=$("$RUNTIME" run --rm --entrypoint which "$IMAGE" opencode 2>/dev/null || true)
    if [[ -z "$opencode_path" || "$opencode_path" != /* ]]; then
        skip "opencode binary path could not be determined"
    fi

    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=SYS_TIME \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        -e AGENT=opencode \
        -v "${_TEST_AGENT}:${opencode_path}:ro" \
        -v "${_TEST_HOST_CONFIG_DIR}:/host-config/opencode:ro" \
        -v "${_TEST_WORKSPACE}:${_TEST_WORKSPACE}" \
        -e SANDBOX_WORKSPACE="${_TEST_WORKSPACE}" \
        "$IMAGE"
    assert_success
    # Sandbox defaults are in place
    assert_output --partial '"ty"'
    assert_output --partial '"nixd"'
    # User's custom lsp entry is gone
    refute_output --partial '"custom-ls"'
    refute_output --partial '/bin/evil'
}
