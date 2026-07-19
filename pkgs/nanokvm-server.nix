{ pkgs, crossPkgs, nanokvm-pro-src, kvm-encoder, axera-libs
, # Base URL the on-device updater fetches from. Point at the GitHub repo that
  # hosts the Releases; `releases/latest/download` always resolves to the newest
  # release's assets. See flake.nix (updateBaseUrl) and docs/updates.md.
  updateBaseUrl ? "https://github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download"
, ...
}:

# ---------------------------------------------------------------------------
# NanoKVM-Server (Go + cgo), cross-built for aarch64/glibc.
# Source: NanoKVM-Pro/server (GPL-3.0). Upstream build: server/build.sh.
#
# cgo dependencies (grepped from the source):
#   common/kvm_vision.go        : #cgo CFLAGS: -I../include
#                                 #cgo LDFLAGS: -L../dl_lib -lkvm   (our encoder)
#   service/stream/opus/decoder.go : #cgo LDFLAGS: -lopus -lm       (audio)
# So this binary hard-links libkvm.so (kvm-encoder) and libopus. Upstream copies
# the built libkvm.so into server/dl_lib/ and patchelf-adds rpath $ORIGIN/dl_lib;
# we instead stage libkvm.so into dl_lib/ pre-build and let Nix set rpath.
#
# ASSUMPTIONS / FLAGS:
#   - vendorHash is a PLACEHOLDER (lib.fakeHash). It evaluates fine (nix flake
#     check passes) but `nix build` will fail at the vendor FOD and print the
#     REAL hash to paste back. Computing it needs a network fetch of the full
#     module graph (pion/webrtc, gin, viper, ...). TODO: run once, pin it.
#   - Go 1.25 required (go.mod `go 1.25.0`); using go_1_25 from nixpkgs.
#   - GOEXPERIMENT=boringcrypto (upstream build.sh) -- kept for parity; drop if
#     it fights the cross build.
#   - libkvm is now the REAL capture+encode backend (kvm-encoder.nix): the server
#     binary links it and its full AX_VENC dependency graph. The video path is
#     functional on-device (subject to the capture-poc CMM re-sync noted in
#     kvm-encoder.nix).
# ---------------------------------------------------------------------------

let
  # Cross buildGoModule: emits aarch64 binaries and wires the cross CC for cgo.
  # IMPORTANT: use crossPkgs' own `go` (cross-capable). Overriding it with a
  # native `pkgs.go_1_25` breaks the cross cgo setup (native go passes -m64 to
  # the aarch64 gcc). nixpkgs default go (1.26) already satisfies go.mod's
  # `go 1.25.0` requirement.
  buildGoModule = crossPkgs.buildGoModule;
in
buildGoModule {
  pname = "nanokvm-server";
  version = "unstable-2026-06-12";

  src = nanokvm-pro-src;
  sourceRoot = "source/server";

  # Pinned from the go-modules FOD (2026-07-17); regenerate if go.mod changes.
  vendorHash = "sha256-cPh//bSTnvibkCRqeIwxjWaRI7YQHOK42PZGMcoJhiY=";

  # ---- Redirect application updates from Sipeed's CDN to OUR host -----------
  # So the web UI "update" button pulls firmware/app updates we publish, not
  # Sipeed's. Runs in sourceRoot (server/). See docs/updates.md for the protocol.
  postPatch = ''
    # 1. Base URL. One fixed-string replace rewrites BOTH consts, because
    #    PreviewURL == StableURL + "/preview": replacing the StableURL substring
    #    also fixes the PreviewURL prefix.
    substituteInPlace service/application/service.go \
      --replace-fail 'https://cdn.sipeed.com/nanokvm' '${updateBaseUrl}'

    # 2. Drop the ?now= cache-buster. GitHub release-asset URLs 302-redirect and
    #    a trailing query can interfere; a static manifest needs no cache-bust.
    substituteInPlace service/application/version.go \
      --replace-fail '"%s/nanokvm_pro_latest.json?now=%d", baseURL, time.Now().Unix()' '"%s/nanokvm_pro_latest.json", baseURL'
    sed -i '/^[[:space:]]*"time"$/d' service/application/version.go

    # 3. Replace the vendor dpkg-based install() with our overlay-copy version
    #    (see pkgs/nanokvm-server/install-override.go.in for the rationale).
    #    install() is the LAST function in update.go: truncate at its signature
    #    and append ours. appNames/getFileInfo become unused package-level decls,
    #    which Go permits (only unused imports / locals are errors).
    sed -i '/^func install(dir string, version string) error {/,$d' service/application/update.go
    cat ${./nanokvm-server/install-override.go.in} >> service/application/update.go
  '';

  # cgo on for the kvm_vision + opus bindings.
  env.CGO_ENABLED = "1";
  env.GOEXPERIMENT = "boringcrypto";

  # opus for -lopus; kvm-encoder provides libkvm.so + kvm_vision.h. axera-libs is
  # needed at LINK time only: the real libkvm.so has DT_NEEDED on libax_venc/sys/
  # proton/mipi/ivps, and libax_proton in turn NEEDs libax_engine, so ld must be
  # able to find the whole AX graph to validate the cgo link (see rpath-link below).
  buildInputs = [
    crossPkgs.libopus
    crossPkgs.alsa-lib
    kvm-encoder
    axera-libs
  ];

  # The cgo directive is `-L../dl_lib -lkvm` (relative to server/common). Stage
  # libkvm.so where the linker expects it. Also expose opus include/lib via CGO
  # env so the relative `../include` (server/include, kvm_vision.h) resolves.
  preBuild = ''
    mkdir -p dl_lib
    cp ${kvm-encoder}/lib/libkvm.so dl_lib/libkvm.so
    cp ${kvm-encoder}/lib/libkvm.so dl_lib/libkvm.so.0
    export CGO_CFLAGS="-I$PWD/include -I${crossPkgs.libopus.dev}/include $CGO_CFLAGS"
    # -rpath-link (NOT -L): resolve libkvm.so's transitive deps at link time
    # WITHOUT adding them as DT_NEEDED to the server binary. libkvm DT_NEEDEDs the
    # AX graph (libax_engine via libax_proton, ...) AND libasound.so.2 (its real
    # ALSA HDMI-audio path), so ld must be able to find BOTH to validate the cgo
    # link. On-device the AX libs load from /opt/lib via libkvm's RPATH and
    # libasound from the standard multiarch path.
    export CGO_LDFLAGS="-L$PWD/dl_lib -L${crossPkgs.libopus}/lib -Wl,-rpath-link,${axera-libs}/lib -Wl,-rpath-link,${crossPkgs.alsa-lib}/lib $CGO_LDFLAGS"
  '';

  ldflags = [
    "-X" "main.Version=nix"
    "-X" "main.GitBranch=open-nanokvm-pro"
  ];

  nativeBuildInputs = [ pkgs.patchelf ];

  # Make the binary run on the device's Ubuntu userland, NOT in nix. buildGoModule
  # bakes the nix-store glibc as the ELF interpreter and a nix-store RUNPATH, which
  # do not exist on the target -- so retarget both to on-device paths (matching the
  # vendor binary: interpreter /lib/ld-linux-aarch64.so.1, RUNPATH $ORIGIN/dl_lib).
  # We add /opt/usr/lib (libopus.so.0) and /opt/lib (Axera libs) because, unlike the
  # vendor server, ours DT_NEEDEDs libopus directly. Device glibc is 2.35 and our
  # binary's highest required symbol is GLIBC_2.34, so there is no ABI gap.
  # dontPatchELF stops nix's fixup from shrinking the RUNPATH we set here.
  dontPatchELF = true;
  postInstall = ''
    patchelf \
      --set-interpreter /lib/ld-linux-aarch64.so.1 \
      --set-rpath '$ORIGIN/dl_lib:/opt/lib:/opt/usr/lib' \
      "$out/bin/NanoKVM-Server"
  '';

  # Keep binary unstripped cross-target.
  dontStrip = true;

  meta = {
    description = "NanoKVM-Server (Go+cgo, aarch64) linking libkvm + libopus -- builds pending real vendorHash";
    license = pkgs.lib.licenses.gpl3Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
