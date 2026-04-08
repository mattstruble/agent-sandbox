{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.agent-sandbox;

  # Build the TOML config structure from settings
  tomlFormat = pkgs.formats.toml { };

  # Full config structure — written only when any setting differs from its default
  configContent = {
    defaults = {
      agent = cfg.settings.defaultAgent;
    };
    env = {
      extra_vars = cfg.settings.env.extraVars;
    };
    workspace = {
      follow_symlinks = cfg.settings.workspace.followSymlinks;
      follow_all_symlinks = cfg.settings.workspace.followAllSymlinks;
    };
    mounts = {
      extra_paths = cfg.settings.mounts.extraPaths;
    };
    resources = {
      memory = cfg.settings.resources.memory;
      cpus = cfg.settings.resources.cpus;
    };
  };

  # True when every setting is at its default; suppresses config file generation
  allDefaults =
    cfg.settings.defaultAgent == "opencode"
    && cfg.settings.env.extraVars == [ ]
    && cfg.settings.workspace.followSymlinks == false
    && cfg.settings.workspace.followAllSymlinks == false
    && cfg.settings.mounts.extraPaths == [ ]
    && cfg.settings.resources.memory == "8g"
    && cfg.settings.resources.cpus == 4;

  # When image is set, wrap the launcher with AGENT_SANDBOX_IMAGE_PATH so the
  # launcher loads the local image instead of pulling from GHCR.
  actualPackage =
    if cfg.image != null then
      pkgs.symlinkJoin {
        name = "agent-sandbox-wrapped";
        paths = [ cfg.package ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/agent-sandbox \
            --set AGENT_SANDBOX_IMAGE_PATH "${cfg.image}"
        '';
      }
    else
      cfg.package;
in
{
  options.programs.agent-sandbox = {
    enable = lib.mkEnableOption "agent-sandbox";

    package = lib.mkPackageOption pkgs "agent-sandbox" { };

    containerPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = if pkgs.stdenv.isLinux then pkgs.podman else null;
      defaultText = lib.literalExpression "if pkgs.stdenv.isLinux then pkgs.podman else null";
      description = "Container runtime package. Defaults to podman on Linux, null on darwin.";
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "null";
      description = "Container image package. When set, the launcher is wrapped with AGENT_SANDBOX_IMAGE_PATH pointing to the image store path.";
    };

    settings = {
      defaultAgent = lib.mkOption {
        type = lib.types.enum [
          "opencode"
        ];
        default = "opencode";
        description = "Default agent when --agent is not passed.";
      };

      env.extraVars = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional environment variables to forward into the sandbox.";
      };

      workspace.followSymlinks = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "When true, mount depth-1 symlink targets from the workspace (skips dotfile directories).";
      };

      workspace.followAllSymlinks = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "When true, mount depth-1 symlink targets including dotfile directories (implies followSymlinks).";
      };

      mounts.extraPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional host paths to mount into the sandbox.";
      };

      resources.memory = lib.mkOption {
        type = lib.types.str;
        default = "8g";
        description = "Container memory limit.";
      };

      resources.cpus = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Container CPU limit.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      actualPackage
    ]
    ++ lib.optional (cfg.containerPackage != null) cfg.containerPackage;

    xdg.configFile."agent-sandbox/config.toml" = lib.mkIf (!allDefaults) {
      source = tomlFormat.generate "agent-sandbox-config" configContent;
    };
  };
}
