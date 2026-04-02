{
  description = "agent-sandbox — sandboxed AI coding agent environments";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake = {
        nixosModules.default = import ./modules/nixos.nix;
        darwinModules.default = import ./modules/darwin.nix;
        homeManagerModules.default = import ./modules/home-manager.nix;
      };

      perSystem =
        { system, self', ... }:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;
          version = "0.1.0";

          # Runtime dependencies available to the launcher at runtime.
          # podman is included on Linux only — on macOS, users install Podman via
          # Homebrew (podman machine requires a native install) and the launcher
          # falls back to whatever podman/docker is on the user's PATH.
          runtimeDeps = [
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
          ]
          ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.podman ];

          # Source filter: include only the files needed to build and run the package.
          # Excludes .git/, docs/, and all markdown files.
          filteredSrc = lib.cleanSourceWith {
            src = ./.;
            filter =
              path: _type:
              let
                baseName = baseNameOf path;
                relPath = lib.removePrefix (toString ./. + "/") path;
              in
              # Exclude .git directory
              !(baseName == ".git")
              # Exclude docs directory
              && !(relPath == "docs" || lib.hasPrefix "docs/" relPath)
              # Exclude markdown files (DESIGN.md, README.md, etc.)
              && !(lib.hasSuffix ".md" baseName)
              # Exclude flake.lock (not needed in the derivation source)
              && !(baseName == "flake.lock")
              # Exclude the flake itself (not needed in the derivation source)
              && !(baseName == "flake.nix");
          };
        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "agent-sandbox";
            inherit version;

            src = filteredSrc;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            # No configure or build steps needed — this is a pure shell script package.
            dontConfigure = true;
            dontBuild = true;

            # Restore original shebangs for container-only scripts.
            # Nix's patchShebangs rewrites #!/usr/bin/env bash to a /nix/store
            # path, but these scripts run inside the container where no Nix
            # store exists.
            postFixup = ''
              sed -i '1s|^#!.*/bash$|#!/usr/bin/env bash|' \
                $out/share/agent-sandbox/entrypoint.sh \
                $out/share/agent-sandbox/init-firewall.sh
            '';

            installPhase = ''
              runHook preInstall

              # Install support files (Containerfile, entrypoint.sh, init-firewall.sh)
              mkdir -p $out/share/agent-sandbox
              install -m 0644 Containerfile $out/share/agent-sandbox/
              install -m 0755 entrypoint.sh $out/share/agent-sandbox/
              install -m 0755 init-firewall.sh $out/share/agent-sandbox/

              # Install the launcher script
              mkdir -p $out/bin
              install -m 0755 agent-sandbox.sh $out/bin/agent-sandbox

              # Substitute @SHARE_DIR@ with the absolute Nix store path at build time.
              # The launcher uses this to locate Containerfile and the other support files.
              substituteInPlace $out/bin/agent-sandbox \
                --replace-fail '@SHARE_DIR@' "$out/share/agent-sandbox"

              # Substitute @VERSION@ with the package version at build time.
              substituteInPlace $out/bin/agent-sandbox \
                --replace-fail '@VERSION@' "${version}"

              # Wrap the launcher so that:
              #   1. Nix-provided bash 5.x is first on PATH (macOS ships bash 3.2;
              #      the script is now compatible with bash 3.2+ but the Nix bash
              #      is still preferred for consistency).
              #   2. coreutils (sha256sum, cut, basename, etc.) and podman on Linux
              #      are available without requiring them on the user's system PATH.
              wrapProgram $out/bin/agent-sandbox \
                --prefix PATH : ${lib.makeBinPath runtimeDeps}

              runHook postInstall
            '';

            meta = {
              description = "Sandboxed AI coding agent environments using Podman containers";
              longDescription = ''
                agent-sandbox wraps Podman (or Docker) to run AI coding agents (OpenCode,
                Claude Code) in isolated containers with iptables-based network allowlists,
                SSH agent forwarding, and deterministic container naming.
              '';
              homepage = "https://github.com/mstruble/agent-sandbox";
              license = lib.licenses.mit;
              maintainers = [ ];
              platforms = lib.platforms.unix;
              mainProgram = "agent-sandbox";
            };
          };

          apps.default = {
            type = "app";
            program = "${self'.packages.default}/bin/agent-sandbox";
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.bats
              pkgs.bats.libraries.bats-support
              pkgs.bats.libraries.bats-assert
              pkgs.shellcheck
              pkgs.nixfmt
              pkgs.gnumake
            ];

            shellHook = ''
              export BATS_LIB_PATH="${pkgs.bats.libraries.bats-support}/share/bats:${pkgs.bats.libraries.bats-assert}/share/bats"
            '';
          };
        };
    };
}
