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
          version = "0.1.0"; # x-release-please-version

          # Linux nixpkgs instance — used for all container image contents.
          # On Linux, linuxSystem == system but pkgsLinux is a separate import
          # with allowUnfree = true (pkgs does not enable unfree). On darwin it
          # also targets the corresponding Linux arch so the build is delegated
          # to a Linux builder.
          # allowUnfree is required for opencode and rtk (lib.licenses.unfree).
          linuxSystem = builtins.replaceStrings [ "-darwin" ] [ "-linux" ] system;
          pkgsLinux = import nixpkgs {
            system = linuxSystem;
            config.allowUnfree = true;
          };

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

          # nixpkgs revision from flake.lock — used to pin the flake registry
          # inside the container so `nix run nixpkgs#<pkg>` resolves reproducibly.
          nixpkgsRev = inputs.nixpkgs.rev;

          # Flake registry JSON pinning nixpkgs to the locked revision.
          # Built via pkgsLinux so the store path lives in the Linux builder's domain.
          flakeRegistry = pkgsLinux.writeText "registry.json" (
            builtins.toJSON {
              version = 2;
              flakes = [
                {
                  from = {
                    type = "indirect";
                    id = "nixpkgs";
                  };
                  to = {
                    type = "github";
                    owner = "NixOS";
                    repo = "nixpkgs";
                    rev = nixpkgsRev;
                  };
                }
              ];
            }
          );

          # Static files bundled into the image at /etc/agent-sandbox/.
          # Built via pkgsLinux so they resolve correctly inside the Linux builder.
          nixInstructionsFile = pkgsLinux.writeText "nix-instructions.md" ''
            # Runtime Package Management

            This environment has Nix installed. When you need a tool that is not on
            PATH (e.g., go, rustc, cargo, ripgrep, fd, yq, terraform, kubectl),
            use `nix run nixpkgs#<package>` or
            `nix shell nixpkgs#<package> --command <cmd>` instead of attempting
            apt-get (which requires root you do not have).
          '';

          opencodePermissionsFile = pkgsLinux.writeText "opencode-permissions.json" (
            builtins.toJSON {
              permission = {
                bash = "allow";
                edit = "allow";
                read = "allow";
                grep = "allow";
                webfetch = "allow";
              };
            }
          );

          # Static configuration files baked into the image.
          # Using writeText (consistent with nixInstructionsFile and opencodePermissionsFile)
          # keeps all static content in Nix expressions rather than inline heredocs,
          # making them content-addressed and easier to audit.
          nixConfFile = pkgsLinux.writeText "nix.conf" ''
            experimental-features = nix-command flakes
            sandbox = false
            warn-dirty = false
            accept-flake-config = false
            substituters = https://cache.nixos.org
            trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
          '';

          chronyConfFile = pkgsLinux.writeText "chrony.conf" ''
            server 162.159.200.1 iburst
            server 162.159.200.123 iburst
            makestep 1 3
            port 0
            cmdport 0
            driftfile /var/lib/chrony/drift
          '';

          sandboxBashrcFile = pkgsLinux.writeText "sandbox-bashrc" ''
            command_not_found_handle() {
                printf '%s: command not found. Try: nix run nixpkgs#%s\n' "$1" "$1" >&2
                return 127
            }
          '';

          # Minimal Nix CLI for the container — only the nix binary and its
          # runtime library dependencies, with S3/AWS auth disabled (the
          # container only fetches from cache.nixos.org over HTTPS).
          # Uses nix-cli instead of nix-everything to exclude docs, man pages,
          # Perl bindings, and the test-suite build gate.
          nixMinimal =
            let
              components = pkgsLinux.nixVersions.nixComponents_2_34.overrideScope (
                _finalScope: prevScope: {
                  nix-store = prevScope.nix-store.override { withAWS = false; };
                }
              );
            in
            components.nix-cli;

          # Container image contents — built entirely via pkgsLinux so the
          # derivation targets Linux regardless of the host system.
          # Defined before linuxPackages so linuxPackages can reference them
          # directly rather than calling callPackage a second time.
          opencode = pkgsLinux.callPackage ./packages/opencode.nix { };
          rtk = pkgsLinux.callPackage ./packages/rtk.nix { };

          # Linux-only packages exposed as top-level outputs on Linux systems.
          # References the standalone opencode/rtk bindings above so both the
          # image contents and the top-level outputs share the same derivation.
          linuxPackages = lib.optionalAttrs pkgs.stdenv.isLinux { inherit opencode rtk; };

          containerImage = pkgsLinux.dockerTools.buildLayeredImage {
            name = "agent-sandbox";
            tag = version;

            contents = [
              pkgsLinux.bash
              pkgsLinux.curl
              pkgsLinux.git
              pkgsLinux.gnumake
              pkgsLinux.su-exec
              pkgsLinux.procps
              pkgsLinux.findutils
              pkgsLinux.coreutils
              pkgsLinux.gnugrep
              pkgsLinux.gawk
              pkgsLinux.iptables
              pkgsLinux.ipset
              pkgsLinux.iproute2
              pkgsLinux.bind.dnsutils
              pkgsLinux.jq
              pkgsLinux.cacert
              pkgsLinux.xz
              pkgsLinux.chrony
              pkgsLinux.nodejs
              pkgsLinux.gh
              pkgsLinux.uv
              nixMinimal
              opencode
              rtk
              pkgsLinux.dockerTools.caCertificates
              pkgsLinux.dockerTools.usrBinEnv
            ];

            fakeRootCommands = ''
              # ── User/group database ──────────────────────────────────────────────
              mkdir -p etc
              printf 'root:x:0:0:root:/root:/bin/sh\nsandbox:x:1000:1000:sandbox:/home/sandbox:/bin/bash\n' \
                > etc/passwd
              printf 'root:x:0:\nsandbox:x:1000:\n' \
                > etc/group
              printf 'root:!:19000:0:99999:7:::\nsandbox:!:19000:0:99999:7:::\n' \
                > etc/shadow
              chmod 0640 etc/shadow

              # ── Home directory ───────────────────────────────────────────────────
              mkdir -p home/sandbox
              chown 1000:1000 home/sandbox

              # ── /nix owned by sandbox user ───────────────────────────────────────
              mkdir -p nix
              chown 1000:1000 nix

              # ── /workspace working directory ─────────────────────────────────────
              mkdir -p workspace
              chown 1000:1000 workspace

              # ── Nix configuration ────────────────────────────────────────────────
              mkdir -p etc/nix
              chmod 0555 etc/nix
              cp ${nixConfFile} etc/nix/nix.conf
              chmod 0444 etc/nix/nix.conf

              # ── Flake registry (pinned nixpkgs) ──────────────────────────────────
              cp ${flakeRegistry} etc/nix/registry.json
              chmod 0444 etc/nix/registry.json

              # ── Chrony configuration ─────────────────────────────────────────────
              mkdir -p etc/chrony
              chmod 0555 etc/chrony
              cp ${chronyConfFile} etc/chrony/chrony.conf

              # ── Static agent-sandbox files ───────────────────────────────────────
              mkdir -p etc/agent-sandbox
              chmod 0555 etc/agent-sandbox
              cp ${nixInstructionsFile} etc/agent-sandbox/nix-instructions.md
              cp ${opencodePermissionsFile} etc/agent-sandbox/opencode-permissions.json
              chmod 0444 etc/agent-sandbox/nix-instructions.md
              chmod 0444 etc/agent-sandbox/opencode-permissions.json

              # ── bashrc with command-not-found handler ────────────────────────────
              cp ${sandboxBashrcFile} home/sandbox/.bashrc
              chown 1000:1000 home/sandbox/.bashrc

              # ── Entrypoint and firewall scripts ──────────────────────────────────
              cp ${./entrypoint.sh} entrypoint.sh
              chmod 0755 entrypoint.sh
              cp ${./init-firewall.sh} init-firewall.sh
              chmod 0755 init-firewall.sh

              # ── Runtime var directories ──────────────────────────────────────────
              mkdir -p var/lib/chrony
              chown 1000:1000 var/lib/chrony
              mkdir -p tmp
              chmod 1777 tmp

              # ── Dynamic linker for unpatched binaries ────────────────────────────
              # opencode is a Bun-compiled binary that cannot be patched with
              # autoPatchelfHook (patching breaks embedded JS sentinel detection).
              # Provide the conventional dynamic linker path as a symlink to the
              # Nix store glibc so the kernel can load the unpatched binary.
              ${
                if linuxSystem == "aarch64-linux" then
                  ''
                    mkdir -p lib
                    ln -sf ${pkgsLinux.glibc}/lib/ld-linux-aarch64.so.1 lib/ld-linux-aarch64.so.1
                  ''
                else
                  ''
                    mkdir -p lib64
                    ln -sf ${pkgsLinux.glibc}/lib/ld-linux-x86-64.so.2 lib64/ld-linux-x86-64.so.2
                  ''
              }
            '';

            enableFakechroot = true;

            config = {
              Entrypoint = [ "/entrypoint.sh" ];
              WorkingDir = "/workspace";
              Env = [
                "PATH=/home/sandbox/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                "SSL_CERT_FILE=${pkgsLinux.cacert}/etc/ssl/certs/ca-bundle.crt"
                "GIT_SSL_CAINFO=${pkgsLinux.cacert}/etc/ssl/certs/ca-bundle.crt"
                "NIX_SSL_CERT_FILE=${pkgsLinux.cacert}/etc/ssl/certs/ca-bundle.crt"
                "RTK_TELEMETRY_DISABLED=1"
                "HOME=/home/sandbox"
                "NIX_CONF_DIR=/etc/nix"
                "LD_LIBRARY_PATH=${pkgsLinux.glibc}/lib"
              ];
              Labels = {
                "org.opencontainers.image.title" = "agent-sandbox";
                "org.opencontainers.image.source" = "https://github.com/mstruble/agent-sandbox";
                "org.opencontainers.image.description" = "Sandboxed AI coding agent environment";
              };
            };
          };

        in
        {
          packages = {
            default = pkgs.stdenv.mkDerivation {
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
                # Restore shebangs for container-only scripts. patchShebangs rewrites
                # them to /nix/store paths, which won't exist inside the container.
                # We can't use dontPatchShebangs because the launcher script (agent-sandbox.sh)
                # legitimately needs Nix store shebangs for the host Nix installation path.
                # This postFixup only affects the tarball distribution — the container image
                # copies scripts directly from source via ${./entrypoint.sh}.
                sed -i '1s|^#!.*/bash$|#!/usr/bin/env bash|' \
                  $out/share/agent-sandbox/entrypoint.sh \
                  $out/share/agent-sandbox/init-firewall.sh
              '';

              installPhase = ''
                runHook preInstall

                # Install support files (entrypoint.sh, init-firewall.sh)
                mkdir -p $out/share/agent-sandbox
                install -m 0755 entrypoint.sh $out/share/agent-sandbox/
                install -m 0755 init-firewall.sh $out/share/agent-sandbox/

                # Install the launcher script
                mkdir -p $out/bin
                install -m 0755 agent-sandbox.sh $out/bin/agent-sandbox

                # Substitute @SHARE_DIR@ with the absolute Nix store path at build time.
                # The launcher uses this to locate the other support files.
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
                  agent-sandbox wraps Podman (or Docker) to run AI coding agents (OpenCode)
                  in isolated containers with iptables-based network allowlists,
                  SSH agent forwarding, and deterministic container naming.
                '';
                homepage = "https://github.com/mstruble/agent-sandbox";
                license = lib.licenses.mit;
                maintainers = [ ];
                platforms = lib.platforms.unix;
                mainProgram = "agent-sandbox";
              };
            };

            container-image = containerImage;
          }
          // linuxPackages; # adds opencode and rtk on Linux systems

          apps.default =
            let
              imagePath = self'.packages.container-image;
              wrapper = pkgs.writeShellScript "agent-sandbox-run" ''
                # imagePath is always a valid Nix store path string at evaluation time,
                # but the file may not exist on disk until 'nix build .#container-image'
                # has been run. Only export AGENT_SANDBOX_IMAGE_PATH when the file is
                # present; otherwise the launcher falls back to pulling from GHCR.
                if [ -f "${imagePath}" ]; then
                  export AGENT_SANDBOX_IMAGE_PATH="${imagePath}"
                else
                  echo "[agent-sandbox] NOTE: container image not built yet (${imagePath} not found). Run 'nix build .#container-image' to build it locally, or the launcher will pull from GHCR." >&2
                fi
                exec "${self'.packages.default}/bin/agent-sandbox" "$@"
              '';
            in
            {
              type = "app";
              program = toString wrapper;
            };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.bats
              pkgs.bats.libraries.bats-support
              pkgs.bats.libraries.bats-assert
              pkgs.shellcheck
              pkgs.nixfmt
              pkgs.gnumake
              pkgs.vulnix
            ];

            shellHook = ''
              export BATS_LIB_PATH="${pkgs.bats.libraries.bats-support}/share/bats:${pkgs.bats.libraries.bats-assert}/share/bats"
            '';
          };
        };
    };
}
