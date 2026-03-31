{
  description = "agent-sandbox — sandboxed AI coding agent environments";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Runtime dependencies available to the launcher at runtime.
        # podman is included on Linux only — on macOS, users install Podman via
        # Homebrew (podman machine requires a native install) and the launcher
        # falls back to whatever podman/docker is on the user's PATH.
        runtimeDeps = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnused
          pkgs.gnugrep
          pkgs.jq
          pkgs.dasel
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
          version = "0.1.0";

          src = filteredSrc;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # No configure or build steps needed — this is a pure shell script package.
          dontConfigure = true;
          dontBuild = true;

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

            # Wrap the launcher so that:
            #   1. Nix-provided bash 5.x is first on PATH (macOS ships bash 3.2 which
            #      lacks associative arrays and ''${var,,} case-folding used by the script).
            #   2. All other runtime tools (coreutils, findutils, gnused, gnugrep, jq,
            #      dasel, and podman on Linux) are available without requiring them on
            #      the user's system PATH.
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
          program = "${self.packages.${system}.default}/bin/agent-sandbox";
        };
      }
    );
}
