{
  config,
  lib,
  pkgs,
  ...
}:
# NOTE: This module is intentionally ~95% identical to modules/darwin.nix.
# The only difference is the containerPackage default (pkgs.podman on NixOS,
# null on darwin). Shared logic has not been extracted to avoid introducing an
# extra import indirection for what is a two-file module set. If a third
# platform module is added, consider extracting a modules/common.nix.
let
  cfg = config.programs.agent-sandbox;

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
      default = pkgs.podman;
      defaultText = lib.literalExpression "pkgs.podman";
      description = "Container runtime package. Set to null to manage separately.";
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "null";
      description = "Container image package. When set, the launcher is wrapped with AGENT_SANDBOX_IMAGE_PATH pointing to the image store path.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      actualPackage
    ]
    ++ lib.optional (cfg.containerPackage != null) cfg.containerPackage;
  };
}
