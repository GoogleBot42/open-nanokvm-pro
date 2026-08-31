{ pkgs, crossPkgs, maix_ax620e_sdk_kernel, ... }:

# ---------------------------------------------------------------------------
# ax_stub.ko -- a symbol-only stand-in for FOUR vendor blobs (issue #56, plan
# step 1 of the full-deblob epic #55; see docs/deblob-capture.md).
#
# ax_proton.ko link-imports exactly 26 symbols from ax_npu (9), ax_gdc (7),
# ax_ivps (7) and ax_vpp (3) -- all FUNC, verified against those modules'
# __ksymtab sets. Static scoping says all 26 are reachable only from
# camera-only ISP node modes (AI-NR, dewarp, scaler, VPP tiling) that the KVM
# digital-YUV bypass topology never enters. This module exports those 26 names
# as pr_warn_once()+(-ENODEV) stubs so the claim can be PROVEN at runtime:
# drop the four blobs, load this instead, run a full capture, read dmesg.
# Silent => ~380 KB of blobs leave the image. Any hit => a hidden init-time
# call edge, named exactly.
#
# EXPERIMENT ARTIFACT, not (yet) shipped: nothing in the image build references
# this. The paired loader is pkgs/rootfs/ax-load-drv.stub.sh, which the device
# test drops in beside the production pkgs/rootfs/ax-load-drv.sh.
#
# Build idiom is deliberately identical to pkgs/vc8000-vcmd.nix: same kernel
# source input, same cross GCC, defconfig + modules_prepare, then an M= build.
# That is what keeps vermagic at "4.19.125 SMP preempt mod_unload aarch64" --
# the vendor ax_*.ko require an exact match (docs/building.md).
# ---------------------------------------------------------------------------

let
  # Match kernel.nix / vc8000-vcmd.nix exactly: oldest cross GCC that builds 4.19.
  crossCC = crossPkgs.buildPackages.gcc13;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;

  kernelSubdir = "linux/linux-4.19.125";
  defconfig = "axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig";
in
pkgs.stdenv.mkDerivation {
  pname = "ax-stub";
  version = "0.1.0-ax630c";

  src = ./ax-stub;

  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  nativeBuildInputs = [
    crossCC
    crossBinutils
  ] ++ (with pkgs; [
    gnumake bc bison flex openssl ncurses perl elfutils kmod cpio
    gzip lzop which gawk bash
  ]);

  dontUnpack = true;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    export ARCH=arm64
    export CROSS_COMPILE=${crossPrefix}
    export KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970"
    export KBUILD_BUILD_USER=nix
    export KBUILD_BUILD_HOST=nixbuild

    # Writable copy of the kernel tree; configure + modules_prepare only (no
    # full vmlinux) is enough for an external module. MODVERSIONS is off in the
    # defconfig (see kernel.nix), so no Module.symvers CRC gate applies -- which
    # is also why these stubs' invented signatures resolve fine.
    cp -a "${maix_ax620e_sdk_kernel}" "$TMPDIR/kernel"
    chmod -R u+w "$TMPDIR/kernel"
    KROOT="$TMPDIR/kernel/${kernelSubdir}"
    cd "$KROOT"
    make ${defconfig}
    make -j$NIX_BUILD_CORES modules_prepare

    cp -a "$src" "$TMPDIR/mod"
    chmod -R u+w "$TMPDIR/mod"
    make -j$NIX_BUILD_CORES -C "$KROOT" M="$TMPDIR/mod" modules

    runHook postBuild
  '';

  # Gate the artifact on the two things that make it useful: it must export all
  # 26 names, and it must carry the vendor-matching vermagic.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp "$TMPDIR/mod/ax_stub.ko" "$out/ax_stub.ko"

    want=$(grep -oE '^AX_STUB\(([A-Za-z0-9_]+)\)' "$src/ax_stub.c" \
             | sed -e 's/^AX_STUB(//' -e 's/)$//' | sort -u)
    got=$(${crossBinutils}/bin/${crossPrefix}nm "$out/ax_stub.ko" \
             | grep -oE '__ksymtab_[A-Za-z0-9_]+' | sed 's/^__ksymtab_//' | sort -u)
    nwant=$(echo "$want" | wc -l)
    if [ "$nwant" -ne 26 ]; then
      echo "ax-stub: expected 26 stub symbols in the source, found $nwant" >&2; exit 1
    fi
    missing=$(comm -23 <(echo "$want") <(echo "$got"))
    if [ -n "$missing" ]; then
      echo "ax-stub: these symbols are NOT exported by the built module:" >&2
      echo "$missing" >&2
      exit 1
    fi

    vm=$(${pkgs.kmod}/bin/modinfo -F vermagic "$out/ax_stub.ko")
    echo "ax-stub: vermagic = $vm"
    case "$vm" in
      "4.19.125 SMP preempt mod_unload aarch64") ;;
      *) echo "ax-stub: vermagic mismatch -- vendor ax_*.ko will refuse to coexist" >&2; exit 1 ;;
    esac

    echo "ax-stub: all 26 symbols exported."
    ls -l "$out"/*.ko
    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "Logging stubs for the 26 ax_proton imports from ax_npu/ax_gdc/ax_ivps/ax_vpp (deblob probe, #56)";
    license = pkgs.lib.licenses.gpl2Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
