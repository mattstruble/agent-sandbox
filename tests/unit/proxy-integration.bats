#!/usr/bin/env bats
# tests/unit/proxy-integration.bats — unit tests for init-proxy.sh functions
#
# These tests source the proxy init script and exercise whitelist assembly
# and MCP domain parsing in isolation. No container runtime is required.
#
# Run with:
#   bats --filter-tags unit tests/unit/proxy-integration.bats
# or via make:
#   make test-unit

load '../test_helper'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
    export HOME
    HOME="$(mktemp -d)"
    _TEST_HOME="$HOME"

    # Source the proxy init script
    INIT_PROXY="${REPO_ROOT}/init-proxy.sh"
    # shellcheck disable=SC1090
    source "$INIT_PROXY"
}

teardown() {
    # Unset API key env vars to prevent leaking between tests
    unset ANTHROPIC_API_KEY 2>/dev/null || true
    unset OPENAI_API_KEY 2>/dev/null || true
    unset OPENROUTER_API_KEY 2>/dev/null || true
    unset MISTRAL_API_KEY 2>/dev/null || true
    unset AWS_ACCESS_KEY_ID 2>/dev/null || true
    unset PROXY_ALLOW_POST_EXTRA 2>/dev/null || true

    if [[ -n "${_TEST_HOME:-}" && "$_TEST_HOME" != "/" ]]; then
        rm -rf "$_TEST_HOME"
    fi
}

# ---------------------------------------------------------------------------
# 1. assemble_whitelist: always includes models.dev
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "assemble_whitelist: always includes models.dev" {
    unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY MISTRAL_API_KEY AWS_ACCESS_KEY_ID PROXY_ALLOW_POST_EXTRA 2>/dev/null || true

    local result
    result=$(assemble_whitelist)

    [[ "$result" == *"models.dev"* ]]
}

# ---------------------------------------------------------------------------
# 2. assemble_whitelist: auto-detects API key domains
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "assemble_whitelist: adds api.anthropic.com when ANTHROPIC_API_KEY is set" {
    export ANTHROPIC_API_KEY="test-key"
    unset OPENAI_API_KEY OPENROUTER_API_KEY MISTRAL_API_KEY AWS_ACCESS_KEY_ID PROXY_ALLOW_POST_EXTRA 2>/dev/null || true

    local result
    result=$(assemble_whitelist)

    [[ "$result" == *"api.anthropic.com"* ]]
}

# bats test_tags=unit
@test "assemble_whitelist: adds api.openai.com when OPENAI_API_KEY is set" {
    export OPENAI_API_KEY="test-key"
    unset ANTHROPIC_API_KEY OPENROUTER_API_KEY MISTRAL_API_KEY AWS_ACCESS_KEY_ID PROXY_ALLOW_POST_EXTRA 2>/dev/null || true

    local result
    result=$(assemble_whitelist)

    [[ "$result" == *"api.openai.com"* ]]
}

# bats test_tags=unit
@test "assemble_whitelist: adds openrouter.ai when OPENROUTER_API_KEY is set" {
    export OPENROUTER_API_KEY="test-key"
    unset ANTHROPIC_API_KEY OPENAI_API_KEY MISTRAL_API_KEY AWS_ACCESS_KEY_ID PROXY_ALLOW_POST_EXTRA 2>/dev/null || true

    local result
    result=$(assemble_whitelist)

    [[ "$result" == *"openrouter.ai"* ]]
}

# bats test_tags=unit
@test "assemble_whitelist: adds api.mistral.com when MISTRAL_API_KEY is set" {
    export MISTRAL_API_KEY="test-key"
    unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY AWS_ACCESS_KEY_ID PROXY_ALLOW_POST_EXTRA 2>/dev/null || true

    local result
    result=$(assemble_whitelist)

    [[ "$result" == *"api.mistral.com"* ]]
}

# bats test_tags=unit
@test "assemble_whitelist: adds bedrock wildcard when AWS_ACCESS_KEY_ID is set" {
    export AWS_ACCESS_KEY_ID="test-key"
    unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY MISTRAL_API_KEY PROXY_ALLOW_POST_EXTRA 2>/dev/null || true

    local result
    result=$(assemble_whitelist)

    [[ "$result" == *"bedrock-runtime.*.amazonaws.com"* ]]
}

# bats test_tags=unit
@test "assemble_whitelist: does not add api.anthropic.com when ANTHROPIC_API_KEY is unset" {
    unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY MISTRAL_API_KEY AWS_ACCESS_KEY_ID PROXY_ALLOW_POST_EXTRA 2>/dev/null || true

    local result
    result=$(assemble_whitelist)

    [[ "$result" != *"api.anthropic.com"* ]]
}

# bats test_tags=unit
@test "assemble_whitelist: includes multiple API key domains when multiple keys are set" {
    export ANTHROPIC_API_KEY="test-key"
    export OPENAI_API_KEY="test-key"
    unset OPENROUTER_API_KEY MISTRAL_API_KEY AWS_ACCESS_KEY_ID PROXY_ALLOW_POST_EXTRA 2>/dev/null || true

    local result
    result=$(assemble_whitelist)

    [[ "$result" == *"api.anthropic.com"* ]]
    [[ "$result" == *"api.openai.com"* ]]
}

# ---------------------------------------------------------------------------
# 3. assemble_whitelist: user-configured extra domains
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "assemble_whitelist: appends PROXY_ALLOW_POST_EXTRA domains" {
    unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY MISTRAL_API_KEY AWS_ACCESS_KEY_ID 2>/dev/null || true
    export PROXY_ALLOW_POST_EXTRA="custom.api.com,another.example.org"

    local result
    result=$(assemble_whitelist)

    [[ "$result" == *"custom.api.com"* ]]
    [[ "$result" == *"another.example.org"* ]]
}

# bats test_tags=unit
@test "assemble_whitelist: deduplicates domains" {
    export ANTHROPIC_API_KEY="test-key"
    unset OPENAI_API_KEY OPENROUTER_API_KEY MISTRAL_API_KEY AWS_ACCESS_KEY_ID 2>/dev/null || true
    export PROXY_ALLOW_POST_EXTRA="api.anthropic.com"

    local result
    result=$(assemble_whitelist)

    # Count occurrences of api.anthropic.com — should be exactly 1
    local count
    count=$(echo "$result" | tr ',' '\n' | grep -cFx "api.anthropic.com")
    [[ "$count" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# 4. _parse_mcp_domains: Claude settings.json format
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "_parse_mcp_domains: extracts domains from Claude mcpServers URLs" {
    mkdir -p "$HOME/.claude"
    cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "mcpServers": {
    "my-server": {
      "url": "https://mcp.example.com/api"
    },
    "other-server": {
      "url": "http://tools.internal.io:8080/v1"
    }
  }
}
EOF

    local domains=()
    _parse_mcp_domains "$HOME/.claude/settings.json" domains

    [[ "${#domains[@]}" -eq 2 ]]
    [[ "${domains[0]}" == "mcp.example.com" ]]
    [[ "${domains[1]}" == "tools.internal.io" ]]
}

# bats test_tags=unit
@test "_parse_mcp_domains: extracts domains from OpenCode mcp URLs" {
    mkdir -p "$HOME/.config/opencode"
    cat > "$HOME/.config/opencode/opencode.json" <<'EOF'
{
  "mcp": {
    "context7": {
      "url": "https://context7.example.com/mcp"
    }
  }
}
EOF

    local domains=()
    _parse_mcp_domains "$HOME/.config/opencode/opencode.json" domains

    [[ "${#domains[@]}" -eq 1 ]]
    [[ "${domains[0]}" == "context7.example.com" ]]
}

# bats test_tags=unit
@test "_parse_mcp_domains: silently handles missing config file" {
    local domains=()
    _parse_mcp_domains "/nonexistent/settings.json" domains

    [[ "${#domains[@]}" -eq 0 ]]
}

# bats test_tags=unit
@test "_parse_mcp_domains: silently handles malformed JSON" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "not valid json {{[" > "$tmpfile"

    local domains=()
    _parse_mcp_domains "$tmpfile" domains

    rm -f "$tmpfile"

    [[ "${#domains[@]}" -eq 0 ]]
}

# bats test_tags=unit
@test "_parse_mcp_domains: handles config with no mcpServers" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo '{"permission": {"bash": "allow"}}' > "$tmpfile"

    local domains=()
    _parse_mcp_domains "$tmpfile" domains

    rm -f "$tmpfile"

    [[ "${#domains[@]}" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# 5. proxy_main: disabled mode
# ---------------------------------------------------------------------------

# bats test_tags=unit
@test "proxy_main: skips all proxy setup when PROXY_ENABLED=false" {
    export PROXY_ENABLED=false

    # proxy_main should return 0 without calling generate_ca etc.
    # (which would fail since openssl/update-ca-certificates aren't available in test)
    run proxy_main

    assert_success
    assert_output --partial "disabled"
}
