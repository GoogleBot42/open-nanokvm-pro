{ pkgs, crossPkgs, ... }:

# ---------------------------------------------------------------------------
# libkvm.so -- the open capture + hardware-encode backend for the AX630C.
# ONE build, and it is blob-free: no vendor library is linked, no vendor
# header is on the include path, and nothing vendor reaches the image (#102).
#
# INTERFACE (the contract the Go server links against):
#   server/include/kvm_vision.h  (kvmv_init / kvmv_read_img / kvmv_set_fps /
#   kvmv_set_gop / kvmv_hdmi_control / kvmv_read_audio / ...). The Go server
#   links libkvm.so at $ORIGIN/dl_lib (rpath). Encode types: MJPEG,
#   H.264/H.265 SPS/PPS/I/P (see IMG_* constants in the header).
#
# THE PIPELINE (all of it ours, all of it open):
#   LT6911UXC HDMI->CSI-2 => open_vin_csi2 => open_vin_capture => /dev/videoN
#     => V4L2 YUYV 4:2:2 frames, each buffer's dma-buf imported through the
#        open VC8000E VCMD driver so the encoder reads it in place (zero-copy)
#     => H.264/H.265 on the VC8000E (kvm_venc_open.c, the #25/#46/#64 register
#        programs + from-scratch rate controller), or a from-source software
#        JPEG for MJPEG (#51, libjpeg-turbo over the same mapped frame).
#   Sources (./kvm-encoder/src):
#     libkvm.c            implements the kvm_vision.h ABI over the pipeline
#     kvm_capture_v4l2.c  the V4L2 capture backend (#60 M3)
#     kvm_venc_open.c     the VC8000E encode backend (shares the register /
#                         cmdbuf / header sources with pkgs/vcenc-ewl via -I)
#     kvm_preview.c       the mini-display live-preview side channel
#     kvm_pipeline.c      the /proc/lt6911_info source poll
#     kvm_types.h         OUR frame/pack types -- the seam between them (#102)
#     kvm_pipeline.h      pipeline API (ours)
#     kvm_vision.h        the Go-server ABI header (ours; == server/include copy)
#
# LINKS: libjpeg (soft-MJPEG), libopus + libasound (ALSA HDMI-audio capture ->
# Opus, backing kvmv_read_audio), libm, libdl, libpthread. Nothing else.
# ---------------------------------------------------------------------------

let
  cc = "${crossPkgs.stdenv.cc.targetPrefix}gcc";
  # Soft-JPEG MJPEG path (#51): libjpeg-turbo built with the jpeg8 ABI so the
  # recorded DT_NEEDED is libjpeg.so.8. The appliance stages this same build
  # into /opt/lib (nixos/modules/server.nix); exported as passthru so it cannot
  # skew from what libkvm linked against.
  libjpeg8 = crossPkgs.libjpeg_turbo.override { enableJpeg8 = true; };
in
crossPkgs.stdenv.mkDerivation {
  pname = "libkvm";
  version = "0.1.0";

  # Our in-tree libkvm source.
  src = ./kvm-encoder/src;

  # libopus + alsa-lib back the REAL HDMI-audio path in kvmv_read_audio (ALSA
  # capture off the LT6911UXC card -> Opus encode), libjpeg8 the soft-MJPEG
  # path. Their headers (<opus/opus.h>, <alsa/asoundlib.h>, <jpeglib.h>) and
  # cross libs are injected by the cc-wrapper via buildInputs; on-device the
  # .so's resolve from /opt/lib, which the appliance stages.
  buildInputs = [ crossPkgs.libopus crossPkgs.alsa-lib libjpeg8 ];

  # patchelf: pin the RUNPATH deterministically (see buildPhase). The nix
  # ld-wrapper rewrites -rpath and drops our /opt/lib entry, so we set it by hand.
  nativeBuildInputs = [ pkgs.patchelf ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    echo "Cross-building libkvm.so (open V4L2 capture + open VC8000E encode) for aarch64"

    # BLOB POLICY, asserted where it can be checked cheaply (#102): no vendor
    # SDK header may be included by anything this builds, and no vendor header
    # may be on the include path. Since the SDK headers are not an input any
    # more the second half cannot fail silently -- but a re-added `-I` would,
    # so assert both.
    if grep -rn '#include[[:space:]]*[<"]ax_' *.c *.h; then
      echo "ERROR: a source still includes a vendor SDK header (ax_*.h)." >&2
      exit 1
    fi
    echo "  no ax_*.h include in any source."

    # -std=gnu17: keep fscanf/scanf-family on their classic symbols. The default
    # (C23) mode on newer gcc/glibc redirects fscanf -> __isoc23_fscanf, which is
    # GLIBC_2.38 and does NOT exist on older target rootfs glibcs; gnu17 drops
    # the only >2.35 symbol.
    ${cc} -shared -fPIC -O2 -Wall -std=gnu17 \
      -I. -I${./vcenc-ewl} \
      -Wl,-soname,libkvm.so.0 \
      libkvm.c kvm_pipeline.c kvm_preview.c kvm_capture_v4l2.c kvm_venc_open.c \
      -ljpeg -lopus -lasound -lm \
      -ldl -lpthread \
      -o libkvm.so

    # No vendor library may have crept into the link (#102). NEEDED is the
    # authority, not the command line above.
    if ${crossPkgs.stdenv.cc.targetPrefix}readelf -d libkvm.so | grep -q 'libax_'; then
      echo "ERROR: libkvm.so DT_NEEDEDs a closed Axera library." >&2
      ${crossPkgs.stdenv.cc.targetPrefix}readelf -d libkvm.so >&2
      exit 1
    fi
    echo "  libkvm.so links no libax_*:"
    ${crossPkgs.stdenv.cc.targetPrefix}readelf -d libkvm.so | grep NEEDED

    # RPATH: /opt/lib, and only that -- where the appliance stages the three
    # open libraries libkvm needs (libjpeg.so.8, libopus.so.0, libasound.so.2).
    # The `<axera-libs>/lib` entry that used to sit beside it went with the SDK
    # headers (#102); it resolved nothing once the vendor-backend build was
    # deleted, and in a Nix closure it was a *reference* that had to be
    # patched out again by nixos/appliance.nix.
    #
    # --force-rpath is LOAD-BEARING: it emits DT_RPATH (transitive) instead of
    # the modern default DT_RUNPATH (non-transitive), so a dependency's own
    # dependencies resolve too. A libkvm that loads from an SSH shell and
    # crash-loops under systemd is always this (docs/architecture.md).
    patchelf --force-rpath --set-rpath "/opt/lib" libkvm.so

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
  # fixup phase shrink our RUNPATH (its /opt/lib entry only exists on-device).
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  # The exact jpeg8-ABI libjpeg-turbo this links (see above); consumed by
  # nixos/modules/server.nix so /opt/lib stages the matching .so.
  passthru = { inherit libjpeg8; };

  meta = {
    description = "libkvm.so -- open capture+encode backend implementing kvm_vision.h over the open V4L2 + VC8000E pipeline (cross-built aarch64)";
    platforms = pkgs.lib.platforms.linux;
  };
}
