{ pkgs, nanokvm-pro-src, ... }:

# ---------------------------------------------------------------------------
# NanoKVM-Pro web frontend (React + Vite + TypeScript, pnpm workspace).
# Source: NanoKVM-Pro/web (GPL-3.0). Build: `pnpm build` == `tsc && vite build`.
#
# Architecture-independent (pure JS/static assets); output = static dist/ served
# by the Go server (or nginx in the PiKVM layout).
#
# pnpm: lockfile is v9.0 (pnpm 9/10). We use pnpm_10 + pnpmConfigHook, which
# reads v9 locks. The dependency set is fetched by a fixed-output derivation
# (pnpm.fetchDeps); its hash is pinned below.
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
  # Track the actual upstream pin, so the store path says what was built (#34).
  version = "unstable-${nanokvm-pro-src.shortRev or "unpinned"}";

  src = nanokvm-pro-src;
  sourceRoot = "source/web";

  # Remove the KVM Admin and AI Assistant panels: their /api/extensions/*
  # backend routes are deliberately dropped in nanokvm-server.nix (they fetch
  # closed third-party code; see docs/provenance.md), so the vendor UI surfaces
  # would 404. Applied against the pinned source; a pin bump that drifts these
  # files fails the patch loudly rather than silently resurfacing dead panels.
  #
  # Add the 720p60 EDID to the mode dropdown. Our clean-room set ships
  # NanoKVM-720P60.bin (pkgs/edid, installed as /kvmcomm/edid/NanoKVM-720P60.bin)
  # but upstream's defaultEdidList never listed it, so 720p was reachable only by
  # a raw POST /api/vm/edid (#62). The matching server-side EDIDMap entry
  # (0x72 -> "NanoKVM-720P60") is added in pkgs/nanokvm-server.nix.
  #
  # Add the h265-direct video mode (#66): "H.265 Direct" in both mode selectors,
  # an H265Direct screen reusing the direct WebCodecs worker (hvc1.1.6.L153.B0),
  # support probed with VideoDecoder.isConfigSupported, fallback to H.264 Direct
  # with a notice where the browser cannot decode HEVC. The server side (streamer
  # + route) is step 9 in pkgs/nanokvm-server.nix.
  patches = [
    ./patches/web-remove-dead-extensions.patch
    ./patches/web-add-720p-edid.patch
    ./patches/web-h265-direct.patch
  ];

  nativeBuildInputs = [
    nodejs
    pnpm.configHook
  ];

  pnpmDeps = pnpm.fetchDeps {
    inherit (finalAttrs) pname version src sourceRoot;
    # pnpm lockfile fetcher format (v3 = required on nixpkgs 26.11).
    fetcherVersion = 3;
    # Pinned from the FOD fetch (2026-07-17); regenerate if the lockfile changes.
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
    description = "NanoKVM-Pro web UI (React/Vite static bundle)";
    license = pkgs.lib.licenses.gpl3Only;
    platforms = pkgs.lib.platforms.all;
  };
})
