{ pkgs, ... }:

# The capture envelope, asserted across the four places that have to agree
# (#98).
#
# WHY THIS EXISTS RATHER THAN ONE CONSTANT. The envelope is stated four times
# in three languages -- a kernel driver, a userspace library, an encoder
# header and a device tree -- and nothing links them. Worse, the coupling is
# SILENT in the direction that matters: `open_vin_capture` CLAMPS an
# out-of-range VIDIOC_S_FMT instead of refusing it, so if libkvm's ceiling
# ever sits above the driver's, the driver quietly negotiates a smaller
# picture and libkvm rejects its own successful ioctl with "driver negotiated
# WxH, wanted W'xH'". That is exactly the shape of #98's symptom: a stream
# that produces nothing, with the real number nowhere in the error.
#
# So this derivation reads the numbers out of the shipping sources -- not out
# of a copy -- and checks the relations between them:
#
#   1. libkvm's V4L2_MAX_* == the driver's OVC_MAX_*        (the silent one)
#   2. the CSI-2 receiver's clamp >= the capture driver's   (it is the source)
#   3. the encoder's VCENC_GEOM_MAX_* >= the capture envelope
#   4. the capture carveout holds at least two frames at the largest geometry
#      (vb2 min_queued_buffers; one buffer cannot rotate)
#
#   nix build .#checks.x86_64-linux.open-capture-envelope -L

pkgs.runCommand "capture-envelope-check"
  {
    capture = ../pkgs/kernel-mainline/tree/drivers/media/platform/axera/open_vin_capture.c;
    csi2 = ../pkgs/kernel-mainline/tree/drivers/media/platform/axera/open_vin_csi2.c;
    v4l2 = ../pkgs/kvm-encoder/src/kvm_capture_v4l2.c;
    venc = ../pkgs/vcenc-ewl/vcenc_geom.h;
    dts = ../dts/ax630c-nanokvm-pro.dts;
  }
  ''
    set -euo pipefail
    fail=0
    note() { echo "  $*"; }
    bad() { echo "FAIL: $*" >&2; fail=1; }

    # ---- the four statements of the envelope ------------------------------
    define() {
      # $1 = file, $2 = macro name. Matches `#define NAME<tabs/spaces>VALUE`.
      sed -n "s/^#define[[:space:]]\+$2[[:space:]]\+\([0-9]\+\).*/\1/p" "$1" | head -1
    }

    ovc_w=$(define "$capture" OVC_MAX_WIDTH)
    ovc_h=$(define "$capture" OVC_MAX_HEIGHT)
    lib_w=$(define "$v4l2" V4L2_MAX_W)
    lib_h=$(define "$v4l2" V4L2_MAX_H)
    enc_w=$(define "$venc" VCENC_GEOM_MAX_W)
    enc_h=$(define "$venc" VCENC_GEOM_MAX_H)

    # The receiver states its limits inline, as clamp_t(u32, ..., 64, N).
    csi_w=$(sed -n 's/.*fmt->format\.width = clamp_t(u32, fmt->format\.width, [0-9]\+, \([0-9]\+\)).*/\1/p' "$csi2" | head -1)
    csi_h=$(sed -n 's/.*fmt->format\.height = clamp_t(u32, fmt->format\.height, [0-9]\+, \([0-9]\+\)).*/\1/p' "$csi2" | head -1)

    for v in ovc_w ovc_h lib_w lib_h enc_w enc_h csi_w csi_h; do
      eval "val=\''${$v:-}"
      if [ -z "$val" ]; then
        bad "could not read $v -- the constant moved or changed shape"
      fi
    done
    [ "$fail" = 0 ] || exit 1

    echo "envelope as stated:"
    note "open_vin_capture  OVC_MAX      ''${ovc_w}x''${ovc_h}"
    note "open_vin_csi2     clamp        ''${csi_w}x''${csi_h}"
    note "libkvm            V4L2_MAX     ''${lib_w}x''${lib_h}"
    note "vcenc_geom        VCENC_MAX    ''${enc_w}x''${enc_h}"

    # 1. libkvm and the driver must be IDENTICAL, not merely compatible: the
    #    driver clamps, so libkvm asking for more gets a smaller picture and a
    #    confusing error, and libkvm asking for less silently narrows the
    #    product's envelope with no way to tell from the kernel side.
    if [ "$ovc_w" != "$lib_w" ] || [ "$ovc_h" != "$lib_h" ]; then
      bad "libkvm ''${lib_w}x''${lib_h} != driver ''${ovc_w}x''${ovc_h} (the driver CLAMPS; this fails as a bogus S_FMT mismatch, not as a clean rejection)"
    fi

    # 2. the receiver feeds the capture driver, so it must admit at least what
    #    the capture driver will accept.
    if [ "$csi_w" -lt "$ovc_w" ] || [ "$csi_h" -lt "$ovc_h" ]; then
      bad "CSI-2 receiver clamps at ''${csi_w}x''${csi_h}, below the capture envelope ''${ovc_w}x''${ovc_h}"
    fi

    # 3. every geometry capture will hand over has to be encodable.
    if [ "$enc_w" -lt "$ovc_w" ] || [ "$enc_h" -lt "$ovc_h" ]; then
      bad "encoder envelope ''${enc_w}x''${enc_h} is smaller than the capture envelope ''${ovc_w}x''${ovc_h}: H.264/H.265 would fail on a geometry capture accepts"
    fi

    # ---- 4. the carveout, from the device tree ----------------------------
    # capture-pool@<base> { ... reg = <0x0 BASE 0x0 SIZE>; ... }
    pool=$(sed -n '/capture-pool@/,/};/p' "$dts" \
           | sed -n 's/.*reg = <0x0 0x[0-9a-f]\+ 0x0 \(0x[0-9a-f]\+\)>.*/\1/p' | head -1)
    if [ -z "$pool" ]; then
      bad "could not read the capture-pool reg from the device tree"
      exit 1
    fi
    pool_bytes=$(( pool ))

    # YUYV 4:2:2, stride == width (ovc_fill_pix_format).
    #
    # A BUFFER DOES NOT COST ITS PAGE-ALIGNED SIZE. The pool is a declared
    # coherent region, so dma_alloc_from_dev_coherent() allocates
    # 2^get_order(size) PAGES, aligned to itself -- 16 MiB for a 15.82 MiB
    # 3840x2160 frame, 32 MiB for anything larger up to 32. Measured on
    # hardware (#98): out of 56 MiB the driver got three buffers at
    # 3840x2160 and could not get ONE at 3840x2400. Reproduce that
    # arithmetic here rather than the page-aligned arithmetic that hid it.
    #
    # And the floor is three, not two: vb2 fails REQBUFS outright below
    # min_queued_buffers + 1, and open_vin_capture declares 2.
    min_buffers=$(sed -n 's/^#define[[:space:]]\+OVC_MIN_BUFFERS[[:space:]]\+\([0-9]\+\).*/\1/p' "$capture" | head -1)
    [ -n "$min_buffers" ] || { bad "could not read OVC_MIN_BUFFERS"; exit 1; }

    frame=$(( lib_w * 2 * lib_h ))
    cost=4096
    while [ "$cost" -lt "$frame" ]; do cost=$(( cost * 2 )); done
    fit=$(( pool_bytes / cost ))

    note "capture-pool      $(( pool_bytes / 1048576 )) MiB"
    note "frame at ''${lib_w}x''${lib_h}  $frame B -> $(( cost / 1048576 )) MiB allocated -> $fit buffers (need $min_buffers)"

    if [ "$fit" -lt "$min_buffers" ]; then
      bad "the capture pool yields $fit buffers at ''${lib_w}x''${lib_h} (each frame costs $(( cost / 1048576 )) MiB after the order rounding); vb2 refuses REQBUFS below $min_buffers, so this geometry cannot stream at all"
    fi

    [ "$fail" = 0 ] || { echo "RESULT: FAIL" >&2; exit 1; }
    echo "RESULT: PASS"
    mkdir -p "$out"
    {
      echo "capture envelope ''${ovc_w}x''${ovc_h}"
      echo "csi2 ''${csi_w}x''${csi_h} venc ''${enc_w}x''${enc_h}"
      echo "pool $(( pool_bytes / 1048576 )) MiB, $fit buffers at the maximum"
    } > "$out/envelope.log"
  ''
