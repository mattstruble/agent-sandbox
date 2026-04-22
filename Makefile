.PHONY: test test-unit test-integration test-e2e test-fast ensure-image clean _check-runtime _check-bats-lib

# Auto-detect container runtime: prefer podman, fall back to docker.
RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

# Version is derived from flake.nix at runtime so it stays in sync automatically.
# Extracts the first 'version = "..."' from flake.nix (the top-level flake version
# inside the perSystem block). The -m1 flag ensures we stop at the first match.
VERSION ?= $(shell grep -m1 'version = ' flake.nix | grep -o '"[^"]*"' | tr -d '"')

IMAGE_TAG := agent-sandbox:$(VERSION)

# Guard: fail fast with a clear message if BATS_LIB_PATH is not set.
# Run 'nix develop' first, or set BATS_LIB_PATH manually.
_check-bats-lib:
	@if [ -z "$(BATS_LIB_PATH)" ]; then \
		echo "[test] ERROR: BATS_LIB_PATH is not set. Run 'nix develop' first, or set BATS_LIB_PATH to the directory containing bats-support and bats-assert."; \
		exit 1; \
	fi

test-unit: _check-bats-lib
	AGENT_SANDBOX_VERSION=$(VERSION) bats --filter-tags unit -r tests/

test-integration: ensure-image _check-bats-lib
	AGENT_SANDBOX_VERSION=$(VERSION) bats --filter-tags integration -r tests/

test-e2e: ensure-image _check-bats-lib
	AGENT_SANDBOX_VERSION=$(VERSION) bats --filter-tags e2e -r tests/

test: test-unit test-integration test-e2e

test-fast: test-unit

# Guard: fail fast with a clear message if no container runtime is available.
_check-runtime:
	@if [ -z "$(RUNTIME)" ]; then \
		echo "[test] ERROR: No container runtime found. Install podman or docker, or set RUNTIME=/path/to/runtime."; \
		exit 1; \
	fi

# Build and load the container image from Nix if not already cached.
ensure-image: _check-runtime
	@if ! "$(RUNTIME)" images -q "$(IMAGE_TAG)" 2>/dev/null | grep -q .; then \
		echo "[test] Building image $(IMAGE_TAG) via nix..."; \
		_tmpdir=$$(mktemp -d) && \
		nix build .#container-image --out-link "$$_tmpdir/result" && \
		"$(RUNTIME)" load < "$$_tmpdir/result"; \
		_rc=$$?; rm -rf "$$_tmpdir"; \
		[ $$_rc -eq 0 ] && echo "[test] Image $(IMAGE_TAG) loaded." || exit $$_rc; \
	else \
		echo "[test] Image $(IMAGE_TAG) already exists, skipping build."; \
	fi

# Remove all agent-sandbox containers (running + stopped) and images (all tags).
# Use this for a clean slate before rebuilding; distinct from the launcher's
# --stop (workspace-scoped) and --prune (keeps current version).
clean: _check-runtime
	@echo "[clean] Stopping and removing all agent-sandbox containers..."
	@"$(RUNTIME)" ps -a --filter "name=agent-sandbox-" --format "{{.Names}}" 2>/dev/null | \
		while IFS= read -r name; do [ -n "$$name" ] && "$(RUNTIME)" rm -f "$$name" 2>/dev/null; done; true
	@echo "[clean] Removing all agent-sandbox images..."
	@"$(RUNTIME)" images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | \
		grep -E "^(localhost/)?agent-sandbox:" | \
		while IFS= read -r img; do [ -n "$$img" ] && "$(RUNTIME)" rmi -f "$$img" 2>/dev/null; done; true
	@echo "[clean] Done."
