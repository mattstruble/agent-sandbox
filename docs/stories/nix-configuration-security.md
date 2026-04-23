# Story: Nix Configuration and Security Hardening

## Source
PRD Capability Group: Runtime Package Management
Behaviors covered:
- The nixpkgs revision used for runtime `nix run` commands is pinned at build time via the Nix flake registry, derived from the same `flake.lock` that pins build-time dependencies.
- The pinned nixpkgs revision is updated automatically when Renovate updates `flake.lock`.
- Binary substitutes (pre-built packages) are downloaded only from the official Nix binary cache (`cache.nixos.org`). Third-party binary caches are not trusted.
- Nix configuration (`/etc/nix/nix.conf`) and the flake registry are owned by root and read-only to the sandbox user. The agent cannot modify Nix's core settings (substituters, experimental features, trust model).

## Summary
Locks down the Nix installation with immutable, root-owned configuration files baked into the Nix-built image. Pins nixpkgs to the same revision as `flake.lock` via a `writeText`-generated registry JSON copied into the image at `/etc/nix/registry.json`, restricts substituters to `cache.nixos.org`, and relies on `flake.lock` updates via Renovate for version management. The agent retains full ability to use Nix but cannot alter its trust model or binary cache sources.

## Acceptance Criteria

### `/etc/nix/nix.conf`
- [ ] Generated at build time by the Nix image expression with root ownership and mode `0444`.
- [ ] Contains `experimental-features = nix-command flakes`.
- [ ] Contains `sandbox = false` (Nix build sandbox; single-user mode cannot use it).
- [ ] Contains `warn-dirty = false`.
- [ ] Contains `accept-flake-config = false` (prevents flakes from injecting trusted settings).
- [ ] Contains `substituters = https://cache.nixos.org` with no additional substituters.
- [ ] Contains `trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=`.
- [ ] The `sandbox` user cannot write to, delete, or replace this file.

### Flake registry (nixpkgs pin)
- [ ] The nixpkgs pin is derived from the project's `flake.lock` at build time — there is no separate `NIXPKGS_REV` variable.
- [ ] The registry JSON is generated via `pkgsLinux.writeText` and copied into the image at `/etc/nix/registry.json` via `fakeRootCommands` in `dockerTools.buildLayeredImage`.
- [ ] `nix registry list` as the `sandbox` user shows the pinned `nixpkgs` entry.
- [ ] `nix run nixpkgs#hello` resolves to the pinned revision (not a floating channel).
- [ ] Updating `flake.lock` updates both the build-time and runtime nixpkgs pin in one operation.
- [ ] The registry file and its GC roots are managed by the Nix build expression.

### Immutability of `/etc/nix/` directory
- [ ] `/etc/nix/` is owned by root with permissions that prevent the `sandbox` user from creating, deleting, or modifying files in it.

### Renovate integration
- [ ] `flake.lock` updates (via Renovate's nix manager) automatically update the runtime nixpkgs pin.
- [ ] No separate regex manager is needed for the nixpkgs revision — it is tracked entirely through `flake.lock`.

### Integration tests
- [ ] `/etc/nix/nix.conf` is owned by root and not writable by the `sandbox` user.
- [ ] `nix registry list` output contains the pinned `nixpkgs` flake reference.
- [ ] The substituters configuration resolves to `cache.nixos.org` only (verified via `nix show-config | grep substituters`).

## Open Questions
- None.

## Out of Scope
- Restricting which flake URIs the agent can fetch from (the container boundary is the security layer; arbitrary URIs are intentionally allowed).
- User-level Nix configuration (`~/.config/nix/`) — the agent can create this to extend settings, but cannot override substituters set in `/etc/nix/nix.conf`.
- Persisting the Nix store across sessions.
