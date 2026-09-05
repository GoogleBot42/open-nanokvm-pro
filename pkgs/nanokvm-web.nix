{ pkgs, version, ... }:

# ---------------------------------------------------------------------------
# NanoKVM-Pro web frontend (React + Vite + TypeScript, pnpm workspace).
# Source: ../web -- our fork of Sipeed's NanoKVM-Pro/web (GPL-3.0), vendored at
# upstream 8d0557b (web/FORK.md). Changes are ordinary commits in web/, not
# patches. Build: `pnpm build` == `tsc && vite build`.
#
# Architecture-independent (pure JS/static assets); output = static dist/ served
# by the Go server.
#
# pnpm: lockfile is v9.0 (pnpm 9/10). We use pnpm_10 + pnpmConfigHook, which
# reads v9 locks. The dependency set is fetched by a fixed-output derivation
# (pnpm.fetchDeps); its hash is pinned below and must be bumped whenever
# web/pnpm-lock.yaml changes.
# ---------------------------------------------------------------------------

let
  # pnpm_10 reads the v9.0 lockfile and supports fetcherVersion 3 on nixpkgs
  # 26.11 (the top-level pnpm_11 fetchPnpmDeps does not). The .configHook /
  # .fetchDeps attribute access emits a deprecation warning -- cosmetic.
  pnpm = pkgs.pnpm_10;
  nodejs = pkgs.nodejs_22; # engines: node ^20.19 || >=22.12
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "nanokvm-web";
  # The repo release version (./VERSION), so the store path says which
  # open-nanokvm-pro the bundle belongs to.
  inherit version;

  src = pkgs.lib.cleanSource ../web;

  nativeBuildInputs = [
    nodejs
    pnpm.configHook
  ];

  pnpmDeps = pnpm.fetchDeps {
    inherit (finalAttrs) pname version src;
    # pnpm lockfile fetcher format (v3 = required on nixpkgs 26.11).
    fetcherVersion = 3;
    # Pinned from the FOD fetch (2026-07-17); unchanged by the fork (same
    # lockfile). Regenerate if web/pnpm-lock.yaml changes.
    hash = "sha256-MqrzcZu5Hqv+r2KHzMUxIVhcoiv0AhAPqRQFaWVd3bE=";
  };

  buildPhase = ''
    runHook preBuild
    pnpm build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r dist/* "$out/"
    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro web UI (React/Vite static bundle, our fork)";
    license = pkgs.lib.licenses.gpl3Only;
    platforms = pkgs.lib.platforms.all;
  };
})
