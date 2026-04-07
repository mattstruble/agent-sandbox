{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  # renovate: datasource=github-releases depName=anomalyco/opencode
  version = "1.3.13";

  src =
    if stdenv.hostPlatform.system == "x86_64-linux" then
      fetchurl {
        url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64.tar.gz";
        sha256 = lib.fakeHash;
      }
    else if stdenv.hostPlatform.system == "aarch64-linux" then
      fetchurl {
        url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-arm64.tar.gz";
        sha256 = lib.fakeHash;
      }
    else
      throw "opencode: unsupported platform ${stdenv.hostPlatform.system}";
in
stdenv.mkDerivation {
  pname = "opencode";
  inherit version src;

  sourceRoot = ".";

  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m 0755 opencode $out/bin/opencode
    runHook postInstall
  '';

  meta = {
    description = "AI coding agent";
    homepage = "https://github.com/anomalyco/opencode";
    license = lib.licenses.unfree;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "opencode";
  };
}
