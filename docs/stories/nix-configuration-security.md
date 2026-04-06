# Story: Nix Configuration and Security Hardening

## Source
PRD Capability Group: Runtime Package Management
Behaviors covered:
- A specific nixpkgs revision is pinned in the Nix flake registry at build time. `nix run nixpkgs#<package>` resolves to this pinned revision, ensuring binary cache hits and reproducible default behavior.
- The pinned nixpkgs revision is updated automatically via Renovate alongside other container dependencies.
- Binary substitutes (pre-built packages) are downloaded only from the official Nix binary cache (`cache.nixos.org`). Third-party binary caches are not trusted.
- Nix configuration (`/etc/nix/nix.conf`) and the flake registry (`/etc/nix/registry.json`) are owned by root and read-only to the sandbox user. The agent cannot modify Nix's core settings (substituters, experimental features, trust model).

## Summary
Locks down the Nix installation with immutable, root-owned configuration files. Pins nixpkgs to a specific revision for reproducible binary cache hits, restricts substituters to `cache.nixos.org`, and integrates the nixpkgs revision into Renovate for automated updates. The agent retains full ability to use Nix but cannot alter its trust model or binary cache sources.

## Acceptance Criteria

### `/etc/nix/nix.conf`
- [ ] Written at build time with root ownership and mode `0444`.
- [ ] Contains `experimental-features = nix-command flakes`.
- [ ] Contains `sandbox = false` (Nix build sandbox; single-user mode cannot use it).
- [ ] Contains `warn-dirty = false`.
- [ ] Contains `accept-flake-config = false` (prevents flakes from injecting trusted settings).
- [ ] Contains `substituters = https://cache.nixos.org` with no additional substituters.
- [ ] Contains `trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=`.
- [ ] The `sandbox` user cannot write to, delete, or replace this file.

### `/etc/nix/registry.json`
- [ ] Written at build time with root ownership and mode `0444`.
- [ ] Pins `nixpkgs` to a specific commit hash of the `NixOS/nixpkgs` repository.
- [ ] `nix registry list` as the `sandbox` user shows the pinned `nixpkgs` entry.
- [ ] `nix run nixpkgs#hello` resolves to the pinned revision (not a floating channel).
- [ ] The `sandbox` user cannot write to, delete, or replace this file.

### Immutability of `/etc/nix/` directory
- [ ] `/etc/nix/` is owned by root with permissions that prevent the `sandbox` user from creating, deleting, or modifying files in it.

### Renovate integration
- [ ] `renovate.json` includes a regex manager that detects the nixpkgs commit hash in `/etc/nix/registry.json` (or the Containerfile section that writes it).
- [ ] The nixpkgs revision update is grouped with the existing container dependencies PR group.

### Integration tests
- [ ] `/etc/nix/nix.conf` is owned by root and not writable by the `sandbox` user.
- [ ] `/etc/nix/registry.json` is owned by root and not writable by the `sandbox` user.
- [ ] `nix registry list` output contains the pinned `nixpkgs` flake reference.
- [ ] The substituters configuration resolves to `cache.nixos.org` only (verified via `nix show-config | grep substituters`).

## Open Questions
- None.

## Out of Scope
- Restricting which flake URIs the agent can fetch from (the container boundary is the security layer; arbitrary URIs are intentionally allowed).
- User-level Nix configuration (`~/.config/nix/`) — the agent can create this to extend settings, but cannot override substituters set in `/etc/nix/nix.conf`.
- Persisting the Nix store across sessions.
