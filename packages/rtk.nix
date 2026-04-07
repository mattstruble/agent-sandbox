{
  lib,
  stdenv,
  fetchurl,
}:

let
  # renovate: datasource=github-releases depName=rtk-ai/rtk
  version = "0.34.2";

  src =
    if stdenv.hostPlatform.system == "x86_64-linux" then
      fetchurl {
        url = "https://github.com/rtk-ai/rtk/releases/download/v${version}/rtk-x86_64-unknown-linux-musl.tar.gz";
        sha256 = lib.fakeHash;
      }
    else if stdenv.hostPlatform.system == "aarch64-linux" then
      fetchurl {
        url = "https://github.com/rtk-ai/rtk/releases/download/v${version}/rtk-aarch64-unknown-linux-musl.tar.gz";
        sha256 = lib.fakeHash;
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
    rtk_bin="$(find . -maxdepth 2 -name 'rtk' -type f | head -1)"
    test -n "$rtk_bin"
    install -m 0755 "$rtk_bin" $out/bin/rtk
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
