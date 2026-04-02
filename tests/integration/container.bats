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
    IMAGE=$(compute_image_tag) || skip "Could not compute image tag — Containerfile missing or no sha256 tool"

    # Verify the image exists; skip rather than fail if not built yet.
    if ! "$RUNTIME" images -q "$IMAGE" 2>/dev/null | grep -q .; then
        skip "Image $IMAGE not found — run 'make ensure-image' first"
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
    [[ -n "$_TEST_WORKSPACE" ]] && rm -rf "$_TEST_WORKSPACE"
    [[ -n "$_TEST_AGENT" ]] && rm -f "$_TEST_AGENT"
    [[ -n "$_TEST_GITCONFIG" ]] && rm -f "$_TEST_GITCONFIG"
    [[ -n "$_TEST_HOST_CONFIG_DIR" ]] && rm -rf "$_TEST_HOST_CONFIG_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: Image Contents
# ─────────────────────────────────────────────────────────────────────────────

# bats test_tags=integration
@test "image: opencode binary exists and is executable" {
    # opencode is NOT on PATH — it lives at /home/sandbox/.opencode/bin/opencode.
    # The entrypoint uses the full path; `which opencode` would fail.
    run "$RUNTIME" run --rm --entrypoint test "$IMAGE" -x /home/sandbox/.opencode/bin/opencode
    assert_success
}

# bats test_tags=integration
@test "image: claude binary exists and is executable" {
    run "$RUNTIME" run --rm --entrypoint which "$IMAGE" claude
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
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c 'cat /proc/sys/net/ipv6/conf/all/disable_ipv6'
    assert_success
    assert_output "1"
}

# bats test_tags=integration
@test "firewall: outbound TCP 443 (HTTPS) is allowed" {
    # Requires internet access: init-firewall.sh itself verifies HTTPS reachability
    # as part of its post-setup check, and this test also probes it directly.
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c '/init-firewall.sh >/dev/null 2>&1 && timeout 5 bash -c "echo >/dev/tcp/93.184.216.34/443" 2>/dev/null && echo "HTTPS_OK"'
    assert_success
    assert_output --partial "HTTPS_OK"
}

# bats test_tags=integration
@test "firewall: outbound TCP 80 (HTTP) is allowed" {
    # Requires internet access: see note on TCP 443 test above.
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c '/init-firewall.sh >/dev/null 2>&1 && timeout 5 bash -c "echo >/dev/tcp/93.184.216.34/80" 2>/dev/null && echo "HTTP_OK"'
    assert_success
    assert_output --partial "HTTP_OK"
}

# bats test_tags=integration
@test "firewall: outbound TCP 8080 is blocked" {
    # Verifies the iptables REJECT rule for non-allowed ports is in place.
    # Uses iptables rule inspection rather than live connectivity to avoid
    # false positives from network unreachability masking a missing firewall rule.
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c '/init-firewall.sh >/dev/null 2>&1 || { echo "FIREWALL_INIT_FAILED"; exit 1; }
            iptables -L OUTPUT -n | grep -q "REJECT" && echo "REJECT_RULE_PRESENT" || echo "REJECT_RULE_MISSING"'
    assert_success
    assert_output --partial "REJECT_RULE_PRESENT"
}

# bats test_tags=integration
@test "firewall: outbound TCP 3000 is blocked" {
    # Same approach as TCP 8080: verify the catch-all REJECT rule is present.
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c '/init-firewall.sh >/dev/null 2>&1 || { echo "FIREWALL_INIT_FAILED"; exit 1; }
            iptables -L OUTPUT -n | grep -q "REJECT" && echo "REJECT_RULE_PRESENT" || echo "REJECT_RULE_MISSING"'
    assert_success
    assert_output --partial "REJECT_RULE_PRESENT"
}

# bats test_tags=integration
@test "firewall: DNS resolution works through pinned resolver" {
    # Requires internet access: getent hosts makes a live DNS query.
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c '/init-firewall.sh >/dev/null 2>&1 && getent hosts example.com'
    assert_success
    # Verify the output contains an IP address, not just any non-empty string.
    assert_output --regexp '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

# bats test_tags=integration
@test "firewall: NTP iptables rule allows UDP 123 to Cloudflare 162.159.200.1" {
    # UDP is connectionless so we verify the iptables ACCEPT rule is present
    # rather than attempting a live NTP exchange. Uses word-boundary grep to
    # avoid matching 162.159.200.123 when checking for 162.159.200.1.
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c '/init-firewall.sh >/dev/null 2>&1 && iptables -L OUTPUT -n | grep "udp dpt:123" | grep -w "162.159.200.1"'
    assert_success
}

# bats test_tags=integration
@test "firewall: NTP iptables rule allows UDP 123 to Cloudflare 162.159.200.123" {
    # UDP is connectionless so we verify the iptables ACCEPT rule is present
    # rather than attempting a live NTP exchange.
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c '/init-firewall.sh >/dev/null 2>&1 && iptables -L OUTPUT -n | grep "udp dpt:123" | grep -w "162.159.200.123"'
    assert_success
}

# bats test_tags=integration
@test "firewall: NTP iptables rule rejects UDP 123 to non-pinned IPs" {
    # Verify the catch-all REJECT rule for UDP 123 (after the Cloudflare ACCEPT rules)
    # is present. This ensures non-Cloudflare NTP is blocked.
    run "$RUNTIME" run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl=net.ipv6.conf.lo.disable_ipv6=1 \
        --security-opt=no-new-privileges \
        --entrypoint bash "$IMAGE" \
        -c '/init-firewall.sh >/dev/null 2>&1 && iptables -L OUTPUT -n | grep "udp dpt:123" | grep "REJECT"'
    assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 4: Entrypoint Behavior
# ─────────────────────────────────────────────────────────────────────────────

# bats test_tags=integration
@test "entrypoint: drops to sandbox user before executing agent" {
    # Mount the fake agent over the real opencode binary.
    # The entrypoint starts as root, sets up the firewall, then re-execs as sandbox.
    # We verify the user drop by having the fake agent print its effective username.
    _TEST_WORKSPACE=$(mktemp -d)
    _TEST_AGENT=$(mktemp)
    # Use printf '%s\n' to write each line; prevents host-side expansion of $() and ${}.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'echo "FAKE_AGENT_MARKER: agent-sandbox-test-sentinel"' \
        'echo "RUNNING_AS_USER=$(id -un)"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"

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
        -v "${_TEST_AGENT}:/home/sandbox/.opencode/bin/opencode:ro" \
        -v "${_TEST_WORKSPACE}:/workspace" \
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
@test "entrypoint: opencode permission overrides are written to config file" {
    # The entrypoint (Phase 2) creates ~/.config/opencode/opencode.json with
    # permission overrides. We run the full entrypoint and have the fake agent
    # print the config file contents to verify the overrides were applied.
    _TEST_WORKSPACE=$(mktemp -d)
    _TEST_AGENT=$(mktemp)
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'cat "${HOME}/.config/opencode/opencode.json" 2>/dev/null || echo "CONFIG_NOT_FOUND"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"

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
        -v "${_TEST_AGENT}:/home/sandbox/.opencode/bin/opencode:ro" \
        -v "${_TEST_WORKSPACE}:/workspace" \
        "$IMAGE"
    assert_success
    assert_output --partial '"bash": "allow"'
    assert_output --partial '"edit": "allow"'
    assert_output --partial '"webfetch": "allow"'
}

# bats test_tags=integration
@test "entrypoint: claude agent path executes claude binary" {
    # For the claude agent, the entrypoint runs `exec claude --dangerously-skip-permissions`.
    # We verify the entrypoint reaches that point by mounting a fake claude over the real one.
    _TEST_WORKSPACE=$(mktemp -d)
    _TEST_AGENT=$(mktemp)
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'echo "FAKE_CLAUDE_MARKER: agent-sandbox-test-sentinel"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"

    # Determine where claude is installed inside the image (globally via npm, on PATH).
    local claude_path
    claude_path=$("$RUNTIME" run --rm --entrypoint which "$IMAGE" claude 2>/dev/null || true)

    # Validate the path is absolute before using it in a volume mount.
    if [[ -z "$claude_path" || "$claude_path" != /* ]]; then
        skip "claude binary path could not be determined or is not absolute: '${claude_path}'"
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
        -e AGENT=claude \
        -v "${_TEST_AGENT}:${claude_path}:ro" \
        -v "${_TEST_WORKSPACE}:/workspace" \
        "$IMAGE"
    assert_success
    assert_output --partial "FAKE_CLAUDE_MARKER"
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 5: Config Staging
# ─────────────────────────────────────────────────────────────────────────────

# bats test_tags=integration
@test "config staging: git config mounted at expected path is readable" {
    _TEST_GITCONFIG=$(mktemp)
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
    _TEST_GITCONFIG=$(mktemp)
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
    _TEST_WORKSPACE=$(mktemp -d)
    _TEST_AGENT=$(mktemp)
    # Use printf '%s\n' to write each line; prevents host-side expansion of ${...}.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'echo "ENV_VAR_VALUE=${TEST_INTEGRATION_VAR}"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"

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
        -v "${_TEST_AGENT}:/home/sandbox/.opencode/bin/opencode:ro" \
        -v "${_TEST_WORKSPACE}:/workspace" \
        "$IMAGE"
    assert_success
    assert_output --partial "ENV_VAR_VALUE=hello-from-host"
}

# bats test_tags=integration
@test "config staging: opencode host config is staged and permission overrides are merged" {
    # Mount a fake opencode config at /host-config/opencode.
    # The entrypoint copies it to ~/.config/opencode, then jq-merges permission overrides.
    # The fake agent reads the resulting config to verify both staging and merging worked.
    _TEST_HOST_CONFIG_DIR=$(mktemp -d)
    printf '{"model": "test-model"}\n' > "${_TEST_HOST_CONFIG_DIR}/opencode.json"

    _TEST_WORKSPACE=$(mktemp -d)
    _TEST_AGENT=$(mktemp)
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'cat "${HOME}/.config/opencode/opencode.json" 2>/dev/null || echo "CONFIG_NOT_FOUND"' \
        'exit 0' > "$_TEST_AGENT"
    chmod +x "$_TEST_AGENT"

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
        -v "${_TEST_AGENT}:/home/sandbox/.opencode/bin/opencode:ro" \
        -v "${_TEST_HOST_CONFIG_DIR}:/host-config/opencode:ro" \
        -v "${_TEST_WORKSPACE}:/workspace" \
        "$IMAGE"
    assert_success
    # Verify permission overrides were applied and the staged model value was preserved.
    assert_output --partial '"bash": "allow"'
    assert_output --partial '"model": "test-model"'
}
