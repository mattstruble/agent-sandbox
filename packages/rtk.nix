{
  lib,
  stdenv,
  fetchurl,
}:

let
  # renovate: datasource=github-releases depName=rtk-ai/rtk
  # IMPORTANT: The version line MUST immediately follow this comment (no blank
  # lines between them). Renovate's regex manager relies on this adjacency.
  # NOTE: When Renovate bumps this version, the sha256 hashes below must also
  # be updated manually (e.g. via `nix-update`) — Renovate cannot fetch them
  # automatically. A stale hash causes a fetchurl mismatch build failure.
  version = "0.34.2";

  src =
    if stdenv.hostPlatform.system == "x86_64-linux" then
      fetchurl {
        url = "https://github.com/rtk-ai/rtk/releases/download/v${version}/rtk-x86_64-unknown-linux-musl.tar.gz";
        sha256 = "sha256-QZs4IWyLEknMcjhtS7z+nngIveCvYxWcgmQ42lNPnlk=";
      }
    else if stdenv.hostPlatform.system == "aarch64-linux" then
      fetchurl {
        url = "https://github.com/rtk-ai/rtk/releases/download/v${version}/rtk-aarch64-unknown-linux-gnu.tar.gz";
        sha256 = "sha256-/BaGNc9lcV2uXLTxHNdgRLTIJHAtUMMoBwt4qzH7bFE=";
      }
    else
      throw "rtk: unsupported platform ${stdenv.hostPlatform.system}";
in
stdenv.mkDerivation {
  pname = "rtk";
  inherit version src;

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    # The rtk tarball extracts the binary directly to the root as 'rtk'.
    # If this fails, the tarball structure may have changed — check the release assets.
    test -f rtk || { echo "rtk binary not found at expected path; tarball structure may have changed" >&2; exit 1; }
    install -m 0755 rtk "$out/bin/rtk"
    runHook postInstall
  '';

  meta = {
    description = "RTK AI agent tool";
    homepage = "https://github.com/rtk-ai/rtk";
    license = lib.licenses.unfree;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "rtk";
  };
}
