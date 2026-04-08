# modules/lib.nix — shared helpers for agent-sandbox NixOS/darwin/home-manager modules.
#
# Import with: import ./lib.nix { inherit lib pkgs; }
# Used by: modules/nixos.nix, modules/darwin.nix, modules/home-manager.nix
{ lib, pkgs }:
{
  # Wrap the launcher package with AGENT_SANDBOX_IMAGE_PATH when a local image
  # is provided, so the launcher loads it instead of pulling from GHCR.
  # Returns the package unwrapped when image is null.
  #
  # Arguments:
  #   package  — the agent-sandbox launcher derivation
  #   image    — a container image derivation (or null for GHCR pull)
  mkActualPackage =
    { package, image }:
    if image != null then
      pkgs.symlinkJoin {
        name = "agent-sandbox-wrapped";
        paths = [ package ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/agent-sandbox \
            --set AGENT_SANDBOX_IMAGE_PATH "${image}"
        '';
      }
    else
      package;
}
