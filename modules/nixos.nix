{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.agent-sandbox;
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
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ]
    ++ lib.optional (cfg.containerPackage != null) cfg.containerPackage;
  };
}
