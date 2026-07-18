{ pkgs, crossPkgs, axera-libs, ... }:

# ---------------------------------------------------------------------------
# libkvm.so -- our REAL open capture + hardware-encode backend for the AX630C.
#
# INTERFACE (the contract the Go server links against):
#   server/include/kvm_vision.h  (kvmv_init / kvmv_read_img / kvmv_set_fps /
#   kvmv_set_gop / kvmv_hdmi_control / kvmv_read_audio / ...). The Go server
#   dlopen/links libkvm.so at $ORIGIN/dl_lib (rpath). Encode types: MJPEG,
#   H.264 SPS/PPS/I/P (see IMG_* constants in the header).
#
# WHAT THIS DERIVATION BUILDS (real, cross-compiled aarch64):
#   Our own open reimplementation of Sipeed's closed libkvm.so, driving the
#   documented Axera MPI video path end-to-end:
#     LT6911UXC HDMI->CSI-2 => MIPI_RX(DPHY 4-lane 600Mbps, LaneCombo MODE_0)
#       => VIN dev (MIPI_RAW/RAW16/BGGR) => VIN pipe (ISP_BYPASS_MODE 12, dummy
#       sensor via dlopen libsns_dummy.so) => VIN chn (YUV420 SP)
#       => AX_VENC (H.264 chn7 / MJPEG chn6).
#   Sources (snapshot -- see below):
#     libkvm.c        implements the kvm_vision.h ABI over the pipeline
#     kvm_pipeline.c  the shared capture+encode pipeline (documented AX MPI only)
#     kvm_pipeline.h  pipeline API (ours)
#     kvm_vision.h    the Go-server ABI header (ours; == server/include copy)
#   The Axera SDK headers (ax_*.h) come from `axera-libs` so header and .so
#   versions stay in lockstep (V3.0.0 msp snapshot, matches on-device libs).
#
# SNAPSHOT / RE-SYNC TODO:
#   ./kvm-encoder/src/ is a POINT-IN-TIME SNAPSHOT of scratchpad/capture-poc/
#   (libkvm.c, kvm_pipeline.{c,h}) + server/include/kvm_vision.h, taken while a
#   concurrent agent is fixing a CMM-teardown bug in capture-poc/. We build from
#   the snapshot so this derivation is hermetic and does not race the edits.
#   >>> RE-SYNC once the CMM fix lands:
#         cp scratchpad/capture-poc/{libkvm.c,kvm_pipeline.c,kvm_pipeline.h} \
#            pkgs/kvm-encoder/src/
#         cp NanoKVM-Pro/server/include/kvm_vision.h pkgs/kvm-encoder/src/
#       then `nix build .#kvm-encoder` to reconfirm. (kvm_vision.h is the frozen
#       ABI and rarely changes; the two pipeline files carry the CMM fix.)
#
# LINK LINE (from the on-hardware PoC build.sh / PLAN.md):
#   gcc -shared -fPIC libkvm.c kvm_pipeline.c -Iinclude \
#     -L/opt/lib -lax_venc -lax_sys -lax_proton -lax_mipi -lax_ivps \
#     -lopus -lasound -ldl -lpthread -Wl,-rpath,/opt/lib -o libkvm.so
#   (-lopus/-lasound back kvmv_read_audio: ALSA HDMI-audio capture + Opus encode.)
#   QUIRKS resolved here:
#     - libax_proton.so has a DT_NEEDED on libax_engine.so; the link-time search
#       path (axera-libs/lib) must contain it so the transitive dep resolves.
#     - on-device the media libs live at /opt/lib (populated by the rootfs/image
#       layer from axera-libs); the nix store path baked into RUNPATH below does
#       not exist there but is harmless (loader falls through to /opt/lib, which
#       we also add to RUNPATH).
# ---------------------------------------------------------------------------

let
  cc = "${crossPkgs.stdenv.cc.targetPrefix}gcc";
in
crossPkgs.stdenv.mkDerivation {
  pname = "libkvm";
  version = "0.1.0";

  # Build from the in-tree snapshot (see SNAPSHOT / RE-SYNC note above).
  src = ./kvm-encoder/src;

  # axera-libs supplies BOTH the Axera SDK headers (-I) and the import .so's (-L)
  # plus the RUNPATH so libax_engine (transitive via libax_proton) resolves.
  # libopus + alsa-lib back the REAL HDMI-audio path in kvmv_read_audio (ALSA
  # capture off the LT6911UXC card -> Opus encode). Their headers (<opus/opus.h>,
  # <alsa/asoundlib.h>) and cross libs are injected by the cc-wrapper via
  # buildInputs; on-device the .so's (libopus.so.0 / libasound.so.2) resolve
  # from the standard multiarch path.
  buildInputs = [ axera-libs crossPkgs.libopus crossPkgs.alsa-lib ];

  # patchelf: pin the RUNPATH deterministically (see buildPhase). The nix
  # ld-wrapper rewrites -rpath and drops our /opt/lib entry, so we set it by hand.
  nativeBuildInputs = [ pkgs.patchelf ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    echo "Cross-building REAL libkvm.so (capture+encode) for aarch64"

    ${cc} -shared -fPIC -O2 -Wall \
      -I. -I${axera-libs}/include \
      -Wl,-soname,libkvm.so.0 \
      libkvm.c kvm_pipeline.c \
      -L${axera-libs}/lib \
      -lax_venc -lax_sys -lax_proton -lax_mipi -lax_ivps \
      -lopus -lasound \
      -ldl -lpthread \
      -Wl,-rpath,${axera-libs}/lib \
      -o libkvm.so

    # RUNPATH decision: keep axera-libs/lib (so libax_* -- incl. libax_engine,
    # pulled in transitively by libax_proton -- resolve in the nix sandbox / CI /
    # dev box), and prepend /opt/lib, which is where the rootfs/image layer stages
    # the media libs ON-DEVICE (the nix store paths do not exist there). Both are
    # harmless when the other is authoritative: the loader takes the first match.
    patchelf --set-rpath "/opt/lib:${axera-libs}/lib" libkvm.so

    cp libkvm.so libkvm.so.0

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/include"
    cp libkvm.so libkvm.so.0 "$out/lib/"
    cp kvm_vision.h "$out/include/"
    runHook postInstall
  '';

  # aarch64 target output on an x86 builder: do not strip, and do NOT let the
  # fixup phase shrink our RUNPATH (it would drop the /opt/lib entry, whose libs
  # only exist on-device, and could relocate the axera-libs entry).
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  meta = {
    description = "libkvm.so -- open capture+encode backend implementing kvm_vision.h over the Axera AX_VENC pipeline (cross-built aarch64)";
    platforms = pkgs.lib.platforms.linux;
  };
}
