{ pkgs, crossPkgs, axera-libs, openCapture ? false, openVenc ? false, v4l2Capture ? false, axsysProbe ? false, ... }:

# v4l2Capture (default false; requires openVenc): capture through the OPEN
#   V4L2 driver (pkgs/open-vin-capture, #55 M3 / #60) instead of replaying
#   vendor ax_proton ioctls: kvm_capture_v4l2.c does S_FMT/REQBUFS/EXPBUF/
#   STREAMON and hands the encoder each frame's bus address via a dma-buf
#   import on our open VCMD driver. Needs open_vin_csi2.ko + open_vin_capture.ko
#   on the device and NONE of the 10 vendor capture/ISP modules.

# openCapture (default false): select the capture backend.
#   false -> vendor-MPI capture (kvm_pipeline.c; links libax_sys/mipi/proton).
#   true  -> BLOB-FREE capture (kvm_capture_open.c; the folded Stage-6 direct-
#            ioctl sequence, docs/blob-replacement.md). Our capture code calls no
#            AX libs (raw ioctls); the link line keeps libax_venc/sys/ivps/proton
#            only because the closed ENCODER pins them, and drops libax_mipi.
#            Device-verified end-to-end (real H.264 from blob-free capture);
#            teardown is the least-exercised path. Default stays off so the
#            shipped image is unchanged.
#
# openVenc (default false; requires openCapture): select the encode backend.
#   true -> BLOB-FREE H.264 encode (kvm_venc_open.c over the open #44 VCMD
#           driver + the #45/#25 EWL, fixed-QP(32), sources shared with
#           pkgs/vcenc-ewl). ZERO vendor libraries are linked -- the last
#           libax_* leaves the process. Needs ax630c_venc_vcmd.ko loaded
#           instead of ax_venc.ko/ax_jenc.ko on the device. MJPEG is a
#           from-source SOFTWARE JPEG (#51): libjpeg-turbo raw-4:2:2 encode
#           of the mapped YUYV capture frame, no hardware. H.264 geometry is
#           parametric (#17: vcenc_geom laws, 64x64..1920x1200 even dims).
#           v1 limit: fixed QP (bitrate knobs accepted+ignored; gop honored).

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
#   Sources (./kvm-encoder/src):
#     libkvm.c        implements the kvm_vision.h ABI over the pipeline
#     kvm_pipeline.c  the shared capture+encode pipeline (documented AX MPI only)
#     kvm_pipeline.h  pipeline API (ours)
#     kvm_vision.h    the Go-server ABI header (ours; == server/include copy)
#   The Axera SDK headers (ax_*.h) come from `axera-libs` so header and .so
#   versions stay in lockstep (V3.0.0 msp snapshot, matches on-device libs).
#
# LINK LINE (from the on-hardware PoC build.sh):
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

assert openVenc -> openCapture;   # the open encoder presumes the open capture path
assert v4l2Capture -> openVenc;   # the V4L2 backend hands frames to the open encoder only

let
  cc = "${crossPkgs.stdenv.cc.targetPrefix}gcc";
  # Soft-JPEG MJPEG path (#51): libjpeg-turbo built with the jpeg8 ABI so the
  # recorded DT_NEEDED is libjpeg.so.8 -- the soname the device's Ubuntu 22.04
  # multiarch path actually ships (nixpkgs' default is the jpeg62 ABI, whose
  # libjpeg.so.62 exists nowhere on the target). The NixOS appliance stages
  # this same build into /opt/lib (nixos/appliance.nix); exported as passthru
  # so it can't skew from what libkvm linked against.
  libjpeg8 = crossPkgs.libjpeg_turbo.override { enableJpeg8 = true; };
  # Capture backend selection (see openCapture above).
  # kvm_capture_geom.c holds the parametric geometry payloads (#17). It is
  # compiled ONLY on the open path -- the vendor-MPI build is untouched.
  # v4l2Capture swaps in kvm_capture_v4l2.c; KVM_OPEN_CAPTURE stays defined so
  # kvm_pipeline.c compiles out its vendor-MPI capture half either way.
  captureSrc  = if v4l2Capture then "kvm_capture_v4l2.c"
                else if openCapture then "kvm_capture_open.c kvm_capture_geom.c" else "";
  captureDef  = pkgs.lib.optionalString openCapture "-DKVM_OPEN_CAPTURE"
                + pkgs.lib.optionalString v4l2Capture " -DKVM_V4L2_CAPTURE";
  # Encode backend selection (see openVenc above). kvm_venc_open.c shares the
  # register-program/cmdbuf/SPS-PPS sources with pkgs/vcenc-ewl via -I.
  vencSrc     = pkgs.lib.optionalString openVenc "kvm_venc_open.c";
  vencDef     = pkgs.lib.optionalString openVenc ("-DKVM_OPEN_VENC -I${./vcenc-ewl}" + pkgs.lib.optionalString axsysProbe " -DKVM_OPENVENC_AXSYS_PROBE");
  # Direct link deps. The blob-free capture code CALLS none of the AX libs (raw
  # ioctls), but the closed encoder (libax_venc) hard-pins libax_sys
  # (AX_SYS_Init; else AX_VENC_Init => AX_ERR_NOT_INIT), libax_proton
  # (AX_VIN_PRIV_FindMeStat) and libax_ivps (AX_IVPS_*). So the open build drops
  # only -lax_mipi; the rest stay for the encoder until it too is replaced.
  # Device-verified: this set produces real H.264 from blob-free capture.
  # With openVenc the encoder is ours too and NO vendor lib is linked at all.
  captureLibs = if openVenc then ("-ljpeg" + pkgs.lib.optionalString axsysProbe " -lax_sys")
                else if openCapture
                then "-lax_venc -lax_sys -lax_ivps -lax_proton"
                else "-lax_venc -lax_sys -lax_proton -lax_mipi -lax_ivps";
in
crossPkgs.stdenv.mkDerivation {
  pname = "libkvm";
  version = "0.1.0";

  # Our in-tree libkvm source.
  src = ./kvm-encoder/src;

  # axera-libs supplies BOTH the Axera SDK headers (-I) and the import .so's (-L)
  # plus the RUNPATH so libax_engine (transitive via libax_proton) resolves.
  # libopus + alsa-lib back the REAL HDMI-audio path in kvmv_read_audio (ALSA
  # capture off the LT6911UXC card -> Opus encode). Their headers (<opus/opus.h>,
  # <alsa/asoundlib.h>) and cross libs are injected by the cc-wrapper via
  # buildInputs; on-device the .so's (libopus.so.0 / libasound.so.2) resolve
  # from the standard multiarch path.
  buildInputs = [ axera-libs crossPkgs.libopus crossPkgs.alsa-lib ]
    ++ pkgs.lib.optionals openVenc [ libjpeg8 ];

  # patchelf: pin the RUNPATH deterministically (see buildPhase). The nix
  # ld-wrapper rewrites -rpath and drops our /opt/lib entry, so we set it by hand.
  nativeBuildInputs = [ pkgs.patchelf ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    echo "Cross-building REAL libkvm.so (capture+encode) for aarch64"

    # -std=gnu17: keep fscanf/scanf-family on their classic symbols. The default
    # (C23) mode on newer gcc/glibc redirects fscanf -> __isoc23_fscanf, which is
    # GLIBC_2.38 and does NOT exist on the target Ubuntu 22.04 rootfs (glibc 2.35),
    # so the Go server fails to load libkvm.so ("GLIBC_2.38 not found"). gnu17
    # drops the only >2.35 symbol; the rest are <= 2.34 and load fine on 2.35.
    echo "capture backend: ${if v4l2Capture then "OPEN V4L2 DRIVER (kvm_capture_v4l2.c)" else if openCapture then "BLOB-FREE (kvm_capture_open.c)" else "vendor MPI (kvm_pipeline.c)"}"
    echo "encode  backend: ${if openVenc then "BLOB-FREE (kvm_venc_open.c, fixed-QP32)" else "vendor AX_VENC (kvm_pipeline.c)"}"
    ${cc} -shared -fPIC -O2 -Wall -std=gnu17 ${captureDef} ${vencDef} \
      -I. -I${axera-libs}/include \
      -Wl,-soname,libkvm.so.0 \
      libkvm.c kvm_pipeline.c kvm_preview.c ${captureSrc} ${vencSrc} \
      -L${axera-libs}/lib \
      ${captureLibs} \
      -lopus -lasound \
      -ldl -lpthread \
      -Wl,-rpath,${axera-libs}/lib \
      -o libkvm.so

    # RPATH decision: keep axera-libs/lib (so libax_* -- incl. libax_engine,
    # pulled in transitively by libax_proton -- resolve in the nix sandbox / CI /
    # dev box), and prepend /opt/lib, which is where the rootfs/image layer stages
    # the media libs ON-DEVICE (the nix store paths do not exist there). Both are
    # harmless when the other is authoritative: the loader takes the first match.
    #
    # --force-rpath is LOAD-BEARING: it emits DT_RPATH (transitive) instead of the
    # modern default DT_RUNPATH (non-transitive). libkvm's direct deps include
    # libax_proton, which itself DT_NEEDEDs libax_engine.so. DT_RUNPATH is searched
    # ONLY for an object's *own* direct deps, so libkvm's RUNPATH would resolve
    # libax_proton but NOT the transitive libax_engine -- the Go server then dies
    # at load with "libax_engine.so: cannot open shared object file" UNLESS the
    # process happens to have /opt/lib on LD_LIBRARY_PATH or in ld.so.cache. Under
    # systemd (nanokvm.service) it has neither, so the web server crash-looped.
    # DT_RPATH is inherited down the whole dependency chain, so /opt/lib resolves
    # libax_engine for libax_proton too -- self-contained, no ldconfig/env needed.
    patchelf --force-rpath --set-rpath "/opt/lib:${axera-libs}/lib" libkvm.so

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

  # The exact jpeg8-ABI libjpeg-turbo the openVenc build links (see above);
  # consumed by nixos/rootfs.nix so /opt/lib stages the matching .so.
  passthru = { inherit libjpeg8; };

  meta = {
    description = "libkvm.so -- open capture+encode backend implementing kvm_vision.h over the Axera AX_VENC pipeline (cross-built aarch64)";
    platforms = pkgs.lib.platforms.linux;
  };
}
