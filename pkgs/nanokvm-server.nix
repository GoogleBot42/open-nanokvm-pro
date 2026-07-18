{ pkgs, crossPkgs, nanokvm-pro-src, kvm-encoder, axera-libs, ... }:

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

  # cgo on for the kvm_vision + opus bindings.
  env.CGO_ENABLED = "1";
  env.GOEXPERIMENT = "boringcrypto";

  # opus for -lopus; kvm-encoder provides libkvm.so + kvm_vision.h. axera-libs is
  # needed at LINK time only: the real libkvm.so has DT_NEEDED on libax_venc/sys/
  # proton/mipi/ivps, and libax_proton in turn NEEDs libax_engine, so ld must be
  # able to find the whole AX graph to validate the cgo link (see rpath-link below).
  buildInputs = [
    crossPkgs.libopus
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
    # -rpath-link (NOT -L): resolve libkvm.so's transitive AX deps (libax_engine
    # via libax_proton, etc.) at link time WITHOUT adding them as DT_NEEDED to the
    # server binary. On-device those libs load from /opt/lib via libkvm's RUNPATH.
    export CGO_LDFLAGS="-L$PWD/dl_lib -L${crossPkgs.libopus}/lib -Wl,-rpath-link,${axera-libs}/lib $CGO_LDFLAGS"
  '';

  ldflags = [
    "-X" "main.Version=nix"
    "-X" "main.GitBranch=nix-nanokvm-pro"
  ];

  # On-device the libs live at /opt/lib + $ORIGIN/dl_lib; the image layer is
  # responsible for placing libkvm.so/libax_*.so there. Keep binary unstripped
  # cross-target.
  dontStrip = true;

  meta = {
    description = "NanoKVM-Server (Go+cgo, aarch64) linking libkvm + libopus -- builds pending real vendorHash";
    license = pkgs.lib.licenses.gpl3Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
