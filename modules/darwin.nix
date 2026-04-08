{
  config,
  lib,
  pkgs,
  ...
}:
# NOTE: This module is intentionally ~95% identical to modules/nixos.nix.
# The only difference is the containerPackage default (null on darwin,
# pkgs.podman on NixOS). The actualPackage wrapping logic is shared via modules/lib.nix.
# If you change the wrapping logic, update modules/lib.nix (not this file).
let
  cfg = config.programs.agent-sandbox;
  moduleLib = import ./lib.nix { inherit lib pkgs; };

  # When image is set, wrap the launcher with AGENT_SANDBOX_IMAGE_PATH so the
  # launcher loads the local image instead of pulling from GHCR.
  # See modules/lib.nix for the shared implementation.
  actualPackage = moduleLib.mkActualPackage {
    inherit (cfg) package image;
  };
in
{
  options.programs.agent-sandbox = {
    enable = lib.mkEnableOption "agent-sandbox";

    package = lib.mkPackageOption pkgs "agent-sandbox" { };

    containerPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "null";
      description = "Container runtime package. Defaults to null on darwin (use Homebrew for Podman Machine).";
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
