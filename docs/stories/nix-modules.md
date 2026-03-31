# Story: NixOS, nix-darwin, and Home Manager Modules

## Source
PRD Capability Group: Distribution
Behaviors covered:
- The flake exposes a NixOS module (`nixosModules.default`), a nix-darwin module (`darwinModules.default`), and a Home Manager module (`homeManagerModules.default`).
- All three modules expose `enable`, `package`, and `containerPackage` options.
- The Home Manager module generates `~/.config/agent-sandbox/config.toml` from typed Nix options.
- The NixOS and nix-darwin modules do not manage agent-sandbox configuration.

## Summary
Migrate the flake from `flake-utils` to `flake-parts` to support system-agnostic module outputs alongside existing per-system package outputs. Add three modules: a NixOS module and nix-darwin module (package + container runtime), and a Home Manager module (package + container runtime + declarative config.toml generation from typed options). Module files live in `modules/` at the repository root.

## Acceptance Criteria

### Flake restructuring
- [ ] `flake-utils` input is replaced by `flake-parts`.
- [ ] Existing outputs (`packages.${system}.default`, `apps.${system}.default`) continue to work identically after the migration.
- [ ] `nix build`, `nix run`, and `nix profile install` produce the same result as before.

### Shared module options (all three modules)
- [ ] `programs.agent-sandbox.enable` (bool, default `false`) — when `true`, adds the package to the environment.
- [ ] `programs.agent-sandbox.package` — defaults to the flake's own package. Overridable.
- [ ] `programs.agent-sandbox.containerPackage` (`nullOr package`) — defaults to `pkgs.podman` on Linux, `null` on darwin. When set, added to the environment. When `null`, no container runtime is provided by the module.

### NixOS module (`nixosModules.default`)
- [ ] Adds `agent-sandbox` to `environment.systemPackages` when enabled.
- [ ] Adds `containerPackage` to `environment.systemPackages` when non-null.
- [ ] Does not manage `~/.config/agent-sandbox/config.toml`.
- [ ] Module lives at `modules/nixos.nix`.

### nix-darwin module (`darwinModules.default`)
- [ ] Adds `agent-sandbox` to `environment.systemPackages` when enabled.
- [ ] Adds `containerPackage` to `environment.systemPackages` when non-null.
- [ ] `containerPackage` defaults to `null` on darwin.
- [ ] Does not manage `~/.config/agent-sandbox/config.toml`.
- [ ] Module lives at `modules/darwin.nix`.

### Home Manager module (`homeManagerModules.default`)
- [ ] Adds `agent-sandbox` to `home.packages` when enabled.
- [ ] Adds `containerPackage` to `home.packages` when non-null.
- [ ] `containerPackage` defaults to `pkgs.podman` when `pkgs.stdenv.isLinux`, `null` otherwise.
- [ ] Exposes typed options under `programs.agent-sandbox.settings`:
  - `defaultAgent` — `enum [ "opencode" "claude" ]`, default `"opencode"`.
  - `env.extraVars` — `listOf str`, default `[]`.
  - `workspace.followAllSymlinks` — `bool`, default `false`.
  - `mounts.extraPaths` — `listOf str`, default `[]`.
  - `resources.memory` — `str`, default `"8g"`.
  - `resources.cpus` — `ints.positive`, default `4`.
- [ ] When any setting differs from defaults, generates `~/.config/agent-sandbox/config.toml` via `xdg.configFile` using `pkgs.formats.toml`.
- [ ] When all settings are at defaults, no config file is generated.
- [ ] Generated TOML uses snake_case keys matching what the launcher expects (`extra_vars`, `follow_all_symlinks`, `extra_paths`).
- [ ] Module lives at `modules/home-manager.nix`.

### Updates to existing files
- [ ] `nix-distribution.md` out-of-scope note about modules is removed.
- [ ] PRD out-of-scope line about modules is removed.
- [ ] PRD Distribution section includes the new module behaviors.
- [ ] DESIGN.md updated with module architecture, flake-parts migration, and repository layout.

## Open Questions
- None.

## Out of Scope
- Module-level tests (e.g., NixOS VM tests). Manual verification is sufficient for v0.1.
- Nix binary cache (e.g., Cachix). GHCR image publishing is covered by the image-publishing story.
