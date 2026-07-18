{ pkgs, crossPkgs, maix_ax620e_sdk, maix_ax620e_sdk_kernel, maix_ax620e_sdk_msp
, # ---- root device baked into chosen/bootargs -------------------------------
  # eMMC (default): rootfs is p17 of the 17-partition A/B eMMC layout = mmcblk0p17.
  # SD card:        rootfs is MBR partition 2 of the card           = mmcblk1p2.
  #   (DTB aliases: mmc0 = eMMC sdhc@1B40000, mmc1 = SD sdhc@104E0000 -> the SD
  #    card always enumerates as mmcblk1 regardless of boot source.)
  # The SD variant is wired into pkgs/sd-image.nix so the card's dtb.img carries
  # the SD root. See the deliverable notes: the vendor SD U-Boot (cmd/axera/
  # sd_boot/sd_boot.c) sets env bootargs=BOOTARGS_SD (root=/dev/mmcblk1p2) and
  # booti's fdt_chosen SHOULD overwrite /chosen/bootargs -- but on-hardware the
  # eMMC root still reached the kernel, so we fix the DTB too. With BOTH the env
  # and the DTB now naming mmcblk1p2, every boot path agrees; no eMMC-root path
  # remains.
  rootDev ? "/dev/mmcblk0p17"
, nameSuffix ? ""
, ... }:

# ===========================================================================
# NanoKVM-Pro AX630C board device tree -- CORRECTLY built (reserved-memory
# patched in).  This closes the gap documented in kernel-fip.nix / PLAN.md.
#
# ---------------------------------------------------------------------------
# THE GAP (proven):  kernel.nix runs a PLAIN `make dtbs`, which compiles the
# board dts *without* the vendor's reserved-memory / bootargs injection. The
# board dts (AX630C_emmc_arm64_k419_sipeed_nanokvm.dts) references CPP macros
# that come from
#     include/dt-bindings/memory/AX620E_reserve_mem_define.h
# and ship EMPTY by default:
#     #define ATF_RESERVED_START_HI            (empty)
#     ...
#     #define BOOTARGS "bootargs"
#     #ifdef OPTEE_BOOT ... #endif           (OPTEE_BOOT undefined)
# so a plain build yields a BROKEN dtb:
#     atf_memreserved { reg; no-map; };      <-- EMPTY reg cell!
#     (no optee_memserved node at all)
#     chosen { bootargs = "bootargs"; };     <-- placeholder, not the cmdline
#
# ---------------------------------------------------------------------------
# THE FIX:  reproduce EXACTLY what kernel/linux/Makefile.kernel's `dtbs` target
# does before it calls the inner `make dtbs`: run scripts/axera/
# patch_reserve_mem.sh over that header to substitute the real addresses/sizes
# (driven by build/projects/.../{project,partition_ab}.mak), THEN `make dtbs`.
#
# The exact make-var values were resolved by evaluating the vendor makefiles
# (make -f project.mak print-<VAR>):
#     SUPPORT_ATF               = TRUE
#     ATF_IMG_ADDR              = 0x40040000   (-> ATF reserved start)
#     ATF_IMG_PKG_SIZE          = 0x40000      (-> ATF reserved size, 256K)
#     SUPPORT_OPTEE             = TRUE         (-> #define OPTEE_BOOT)
#     OPTEE_IMAGE_ADDR          = 0x44200000   (-> OPTEE reserved start)
#     OPTEE_RESERVED_SIZE       = 0x2000000    (-> OPTEE reserved size, 32M)
#     AX630C_DDR4_RETRAIN       = TRUE         (0x40000000 / 0x1000; no-op for
#                                               this board -- dts hardcodes the
#                                               axera_ddr_retrain node -- run for
#                                               vendor fidelity)
#     CMM_POOL_PARAM            = (empty)      (no-op: board dts has no cmmpool)
#     SUPPORT_KERNEL_BOOTARGS   = TRUE
#     KERNEL_BOOTARGS           = the full cmdline below (rootfs = mmcblk0p17)
#
# The patch-then-build sequence and its ordering mirror Makefile.kernel:dtbs
# (ATF, TEE, -p SUPPORT_ATF, DTB bootargs, DDR_RETRAIN, CMM).
#
# ---------------------------------------------------------------------------
# WHY a separate derivation (not folded into kernel.nix):  the correct dtb only
# needs `make dtbs` (dtc + cpp), not Image/modules, so this is a light build and
# it keeps the already-built kernel derivation's hash stable. kernel.nix's own
# $out/dtb/*.dtb remains the (unpatched) raw artifact for reference; THIS is the
# one that gets packaged + flashed. See dtb-fip.nix for the signed partition.
#
# The SDK-tree setup (writable kernel copy, msp/build siblings, HOME_PATH/
# PROJECT/LIBC, gcc13, empty INITRAMFS) is identical to kernel.nix -- see the
# long rationale there.
# ===========================================================================

let
  crossCC = crossPkgs.buildPackages.gcc13;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;

  kernelSubdir = "linux/linux-4.19.125";
  defconfig = "axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig";
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";
  release = "4.19.125";

  # -- reserved-memory values, verbatim from the vendor makefiles (see header) --
  atfResStart = "0x40040000";
  atfResSize = "0x40000";
  opteeResStart = "0x44200000";
  opteeResSize = "0x2000000";
  ddrRetrainStart = "0x40000000";
  ddrRetrainSize = "0x1000";

  # KERNEL_BOOTARGS, verbatim from `make print-KERNEL_BOOTARGS` (outer quotes
  # stripped by the shell exactly as the vendor recipe passes `-b $(KERNEL_BOOTARGS)`).
  # rootfs is `${rootDev}` (eMMC: p17 = mmcblk0p17 ; SD: mmcblk1p2). Only the
  # `root=` clause changes between variants -- console/earlycon/mem/rootwait are
  # identical, and `blkdevparts=mmcblk0:...` describes the (still-present) eMMC
  # partition layout, so it is accurate and harmless on an SD boot (it only NAMES
  # eMMC partitions; it does not affect where root is mounted). Kept for both
  # variants so the two dtbs differ ONLY in `root=`.
  kernelBootargs =
    "mem=256M console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x4880000 "
    + "board_id=0x0,boot_reason=0x00,initcall_debug=0 loglevel=8 "
    + "usbcore.autosuspend=-1 root=${rootDev} rootfstype=ext4 rw rootwait "
    + "blkdevparts=mmcblk0:768K(spl),512K(ddrinit),256K(atf),256K(atf_b),"
    + "1536K(uboot),1536K(uboot_b),1M(env),6M(logo),6M(logo_b),1M(optee),"
    + "1M(optee_b),1M(dtb),1M(dtb_b),64M(kernel),64M(kernel_b),128M(boot),-(rootfs)";
in
pkgs.stdenv.mkDerivation {
  pname = "nanokvm-pro-dtb${nameSuffix}";
  version = release;

  src = maix_ax620e_sdk_kernel;

  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  nativeBuildInputs = [
    crossCC
    crossBinutils
  ] ++ (with pkgs; [
    gnumake
    bc
    bison
    flex
    openssl
    ncurses
    perl
    elfutils
    cpio
    gzip
    lzop
    which
    gawk
    bash
    dtc # host dtc for the verification decompile below
  ]);

  dontUnpack = true;

  configurePhase = ''
    runHook preConfigure

    export ARCH=arm64
    export CROSS_COMPILE=${crossPrefix}
    export KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970"
    export KBUILD_BUILD_USER=nix
    export KBUILD_BUILD_HOST=nixbuild

    # SDK sibling layout <root>/{kernel,msp,build}; kernel must be a REAL writable
    # path ending in /kernel (getcwd resolves symlinks). See kernel.nix.
    mkdir -p "$TMPDIR/sdk"
    cp -a "$src" "$TMPDIR/sdk/kernel"
    chmod -R u+w "$TMPDIR/sdk/kernel"
    ln -s "${maix_ax620e_sdk_msp}" "$TMPDIR/sdk/msp"
    ln -s "${maix_ax620e_sdk}/build" "$TMPDIR/sdk/build"

    export HOME_PATH="$TMPDIR/sdk"
    export PROJECT=${project}
    export LIBC=glibc
    export KROOT="$TMPDIR/sdk/kernel/${kernelSubdir}"
    cd "$KROOT"

    make O=build ${defconfig}
    bash ./scripts/config --file build/.config --set-str INITRAMFS_SOURCE ""
    make O=build olddefconfig

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cd "$KROOT"

    hdr="include/dt-bindings/memory/AX620E_reserve_mem_define.h"
    patch="scripts/axera/patch_reserve_mem.sh"
    bootargs="${kernelBootargs}"

    echo "=== patch_reserve_mem.sh (reproducing Makefile.kernel:dtbs ordering) ==="
    # ATF reserved region
    bash "$patch" -o "$hdr" -a ${atfResStart} -s ${atfResSize} -t ATF
    # OP-TEE reserved region (defines OPTEE_BOOT -> optee nodes appear)
    bash "$patch" -o "$hdr" -a ${opteeResStart} -s ${opteeResSize} -t TEE
    # keep SUPPORT_ATF defined (project sets SUPPORT_ATF=TRUE)
    bash "$patch" -o "$hdr" -p TRUE
    # kernel cmdline into chosen/bootargs
    bash "$patch" -o "$hdr" -b "$bootargs" -t DTB
    # DDR retrain (no-op for this board; run for fidelity)
    bash "$patch" -o "$hdr" -a ${ddrRetrainStart} -s ${ddrRetrainSize} -t DDR_RETRAIN
    # CMM pool param empty (board dts has no cmmpool node -> no-op)
    bash "$patch" -o "$hdr" -c "" -t CMM

    echo "=== patched header ==="
    grep -E 'ATF_RESERVED|OPTEE_RESERVED|OPTEE_BOOT|BOOTARGS|SUPPORT_ATF' "$hdr" || true

    echo "=== make dtbs ==="
    make O=build -j$NIX_BUILD_CORES HOME_PATH="$HOME_PATH" PROJECT=${project} LIBC=glibc dtbs

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cd "$KROOT"

    dtb="build/arch/arm64/boot/dts/axera/${project}.dtb"
    test -f "$dtb" || { echo "ERROR: dtbs did not produce $dtb" >&2; exit 1; }

    # ---- VERIFY: the reserved-memory nodes must now be present + non-empty ----
    dtc -I dtb -O dts "$dtb" > dump.dts 2>/dev/null

    echo "=== reserved-memory in the PATCHED dtb ==="
    sed -n '/reserved-memory {/,/^\t};/p' dump.dts

    # (a) atf_memreserved must have a real 4-cell reg = <0x0 0x40040000 0x0 0x40000>
    if ! grep -Eq 'reg = <0x0+ 0x40040000 0x0+ 0x40000>' dump.dts; then
      echo "ERROR: atf reserved-memory reg missing/empty in patched dtb" >&2
      exit 1
    fi
    # (b) optee reserved region present (OPTEE_BOOT took effect)
    if ! grep -Eq 'reg = <0x0+ 0x44200000 0x0+ 0x2000000>' dump.dts; then
      echo "ERROR: optee reserved-memory reg missing in patched dtb" >&2
      exit 1
    fi
    # (c) bootargs must be the real cmdline, not the "bootargs" placeholder
    if grep -q 'bootargs = "bootargs"' dump.dts; then
      echo "ERROR: bootargs still the placeholder -- DTB patch did not apply" >&2
      exit 1
    fi
    if ! grep -q 'root=${rootDev}' dump.dts; then
      echo "ERROR: bootargs missing root=${rootDev}" >&2
      exit 1
    fi
    echo "VERIFY OK: atf + optee reserved-memory regions present, bootargs patched."

    mkdir -p "$out/dtb"
    cp "$dtb" "$out/dtb/${project}.dtb"
    cp dump.dts "$out/dtb/${project}.dts"   # decompiled, for inspection/proof

    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "NanoKVM-Pro AX630C board dtb, CORRECTLY built with the vendor reserved-memory / bootargs patch (closes the kernel.nix dtb gap)";
    license = pkgs.lib.licenses.gpl2Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
