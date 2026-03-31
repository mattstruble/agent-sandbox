# Story: Nix Flake Distribution

## Source
PRD Capability Group: Distribution
Behaviors covered:
- The tool is runnable without installation via `nix run github:mstruble/agent-sandbox`.
- The tool is installable into a user profile via `nix profile install github:mstruble/agent-sandbox`.
- The tool is referenceable as a flake input from other Nix flakes.

## Summary
The flake packages the launcher script and support files (Containerfile, entrypoint.sh, init-firewall.sh) into a derivation, substitutes the share directory path at build time, and declares all runtime dependencies so `nix run` works on a fresh machine with only Nix installed.

## Acceptance Criteria
- [ ] `nix run github:mstruble/agent-sandbox` executes the launcher on a machine with no prior installation.
- [ ] `nix profile install github:mstruble/agent-sandbox` makes `agent-sandbox` available on `$PATH` permanently.
- [ ] The flake exposes `packages.${system}.default` and `apps.${system}.default` for all four targets: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`.
- [ ] The installed package places the launcher at `$out/bin/agent-sandbox` and support files at `$out/share/agent-sandbox/`.
- [ ] `@SHARE_DIR@` in the launcher script is substituted with the absolute Nix store path to `$out/share/agent-sandbox` at build time.
- [ ] Runtime dependencies (`podman`, `coreutils`, `gnused`, `gnugrep`, `jq`, `dasel`) are declared in the flake and available to the launcher without being on the user's `$PATH`.
- [ ] Another flake can reference `inputs.agent-sandbox.url = "github:mstruble/agent-sandbox"` and use `agent-sandbox.packages.${system}.default`.

## Open Questions
- None.

## Out of Scope
- Nix binary cache (e.g., Cachix). GHCR image publishing is covered by the image-publishing story.
