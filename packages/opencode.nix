{
  lib,
  stdenv,
  fetchurl,
}:

let
  # renovate: datasource=github-releases depName=anomalyco/opencode
  # IMPORTANT: The version line MUST immediately follow this comment (no blank
  # lines between them). Renovate's regex manager relies on this adjacency.
  # NOTE: When Renovate bumps this version, the sha256 hashes below must also
  # be updated manually (e.g. via `nix-update`) — Renovate cannot fetch them
  # automatically. A stale hash causes a fetchurl mismatch build failure.
  version = "1.3.13";

  src =
    if stdenv.hostPlatform.system == "x86_64-linux" then
      fetchurl {
        url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64.tar.gz";
        sha256 = "sha256-CKwqkdjwcbDlu37AhmXH+US8ugCm/gK7ZjONdK0GesU=";
      }
    else if stdenv.hostPlatform.system == "aarch64-linux" then
      fetchurl {
        url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-arm64.tar.gz";
        sha256 = "sha256-r5EzzrXZlXJl1zBFZVSqfDiqvI/zgnOUoj0/6sj+fvI=";
      }
    else
      throw "opencode: unsupported platform ${stdenv.hostPlatform.system}";
in
stdenv.mkDerivation {
  pname = "opencode";
  inherit version src;

  sourceRoot = ".";

  # Bun-compiled binary: JavaScript bytecode is appended after the ELF
  # sections with a trailer sentinel. strip removes this trailing data,
  # causing the runtime to fall back to plain Bun. Same applies to any
  # binary that embeds data past the ELF (Deno compile, Node.js SEA).
  dontStrip = true;

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
