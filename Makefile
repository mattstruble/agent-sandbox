.PHONY: test test-unit test-integration test-e2e test-fast ensure-image _check-runtime _check-bats-lib

# Auto-detect container runtime: prefer podman, fall back to docker.
RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

# Portable sha256: GNU coreutils provides sha256sum; macOS ships shasum.
SHA256 := $(shell command -v sha256sum 2>/dev/null || command -v shasum 2>/dev/null)

# Compute image tag matching the launcher's logic:
#   sha256sum Containerfile | cut -c1-64
# Evaluated at parse time; IMAGE_TAG will be empty if Containerfile is missing
# or no sha256 tool is found — _check-runtime and ensure-image guard against this.
ifeq ($(SHA256),)
  $(error Neither sha256sum nor shasum found in PATH — cannot compute image tag)
endif

# Determine the correct invocation: sha256sum needs no flags; shasum needs -a 256.
# Use notdir to inspect the binary name — avoids a second $(shell ...) call.
ifeq ($(notdir $(SHA256)),shasum)
  SHA256_CMD := $(SHA256) -a 256
else
  SHA256_CMD := $(SHA256)
endif

IMAGE_TAG := agent-sandbox:$(shell $(SHA256_CMD) Containerfile 2>/dev/null | cut -c1-64)

# Validate IMAGE_TAG is non-empty (guards against missing Containerfile)
ifeq ($(IMAGE_TAG),agent-sandbox:)
  $(error IMAGE_TAG is empty: Containerfile not found or sha256 computation failed)
endif

# Guard: fail fast with a clear message if BATS_LIB_PATH is not set.
# Run 'nix develop' first, or set BATS_LIB_PATH manually.
_check-bats-lib:
	@if [ -z "$(BATS_LIB_PATH)" ]; then \
		echo "[test] ERROR: BATS_LIB_PATH is not set. Run 'nix develop' first, or set BATS_LIB_PATH to the directory containing bats-support and bats-assert."; \
		exit 1; \
	fi

test-unit: _check-bats-lib
	bats --filter-tags unit -r tests/

test-integration: ensure-image _check-bats-lib
	bats --filter-tags integration -r tests/

test-e2e: ensure-image _check-bats-lib
	bats --filter-tags e2e -r tests/

test: test-unit test-integration test-e2e

test-fast: test-unit

# Guard: fail fast with a clear message if no container runtime is available.
_check-runtime:
	@if [ -z "$(RUNTIME)" ]; then \
		echo "[test] ERROR: No container runtime found. Install podman or docker, or set RUNTIME=/path/to/runtime."; \
		exit 1; \
	fi

# Build the container image if not already cached.
ensure-image: _check-runtime
	@if ! "$(RUNTIME)" images -q "$(IMAGE_TAG)" 2>/dev/null | grep -q .; then \
		echo "[test] Building image $(IMAGE_TAG)..."; \
		"$(RUNTIME)" build -t "$(IMAGE_TAG)" -f Containerfile .; \
	else \
		echo "[test] Image $(IMAGE_TAG) already exists, skipping build."; \
	fi
