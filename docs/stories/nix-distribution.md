# Story: Nix Flake Distribution

## Source
PRD Capability Group: Distribution
Behaviors covered:
- The tool is runnable without installation via `nix run github:mstruble/agent-sandbox`.
- `nix run` loads the container image into the local container runtime and runs the launcher, with no GHCR dependency.
- The tool is installable into a user profile via `nix profile install github:mstruble/agent-sandbox`.
- The tool is referenceable as a flake input from other Nix flakes.

## Summary
The flake packages the launcher script and support files (entrypoint.sh, init-firewall.sh) into a derivation, substitutes the share directory path at build time, and declares all runtime dependencies so `nix run` works on a fresh machine with only Nix installed. The flake also exports a `container-image` output for building the OCI image from Nix. The `apps.default` wrapper sets `AGENT_SANDBOX_IMAGE_PATH` to the Nix-built container image and execs the launcher, so `nix run` handles image loading automatically without GHCR.

## Acceptance Criteria
- [ ] `nix run github:mstruble/agent-sandbox` builds the container image, loads it into the local container runtime, and runs the launcher — with no GHCR dependency.
- [ ] `apps.${system}.default` is a wrapper script that sets `AGENT_SANDBOX_IMAGE_PATH` to the `container-image` output store path and execs the launcher.
- [ ] The app wrapper depends on both `packages.default` (launcher) and `packages.container-image`, so `nix run` triggers both builds.
- [ ] On darwin, `nix run` requires a configured Linux builder (e.g., `nix.linux-builder`) to cross-compile the container image. Without one, the build fails with a clear Nix error.
- [ ] `nix profile install github:mstruble/agent-sandbox` makes `agent-sandbox` available on `$PATH` permanently (installs the launcher only, not the app wrapper).
- [ ] The flake exposes `packages.${system}.default` and `apps.${system}.default` for all four targets: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`.
- [ ] The installed package places the launcher at `$out/bin/agent-sandbox` and support files at `$out/share/agent-sandbox/` (entrypoint.sh, init-firewall.sh — no Containerfile).
- [ ] `@SHARE_DIR@` in the launcher script is substituted with the absolute Nix store path to `$out/share/agent-sandbox` at build time.
- [ ] Runtime dependencies (`podman`, `coreutils`) are declared in the flake and available to the launcher without being on the user's `$PATH`. `dasel`, `jq`, `gnused`, and `gnugrep` are no longer required (see launcher-portability story).
- [ ] Another flake can reference `inputs.agent-sandbox.url = "github:mstruble/agent-sandbox"` and use `agent-sandbox.packages.${system}.default`.

## Open Questions
- None.

## Out of Scope
- Nix binary cache (e.g., Cachix). GHCR image publishing is covered by the image-publishing story.
