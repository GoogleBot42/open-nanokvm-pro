{ pkgs, crossPkgs, maix_ax620e_sdk, maix_ax620e_sdk_kernel, maix_ax620e_sdk_msp
, # ---- root device baked into chosen/bootargs -------------------------------
  # eMMC (default): rootfs is p17 of the 17-partition A/B eMMC layout = mmcblk0p17.
  # SD card:        rootfs is MBR partition 2 of the card           = mmcblk1p2.
  #   (DTB aliases: mmc0 = eMMC sdhc@1B40000, mmc1 = SD sdhc@104E0000 -> the SD
  #    card always enumerates as mmcblk1 regardless of boot source.)
  # The SD variant is wired into pkgs/sd-image.nix. The vendor SD U-Boot sets env
  # bootargs=BOOTARGS_SD (root=/dev/mmcblk1p2) and booti's fdt_chosen should
  # overwrite /chosen/bootargs, but on-hardware the eMMC root still reached the
  # kernel, so we fix the DTB too. With both the env and the DTB naming
  # mmcblk1p2, every boot path agrees.
  rootDev ? "/dev/mmcblk0p17"
, # ---- console UART baked into chosen/bootargs -----------------------------
  # Default (eMMC): UART0 = ttyS0 = MMIO 0x4880000 (the hidden debug pads).
  # SD debug variant overrides these to UART1 = ttyS1 = MMIO 0x4881000 (the
  # accessible header pin) so the whole SD boot is watchable on UART1. The dtb
  # aliases already map serial0->ax_uart@4880000 and serial1->ax_uart@4881000
  # (both nodes status="okay"), so console=ttyS1 selects UART1 and the matching
  # earlycon=...,0x4881000 gives early kernel output on the same port.
  consoleTty ? "ttyS0"
, earlyconAddr ? "0x4880000"
, nameSuffix ? ""
, ... }:

# ===========================================================================
# NanoKVM-Pro AX630C board device tree, built with the vendor reserved-memory /
# bootargs injection that a plain `make dtbs` omits.
#
# A plain `make dtbs` compiles the board dts
# (AX630C_emmc_arm64_k419_sipeed_nanokvm.dts) without running the vendor's
# patch_reserve_mem.sh over
#     include/dt-bindings/memory/AX620E_reserve_mem_define.h
# whose macros ship EMPTY by default (ATF_RESERVED_* blank, BOOTARGS "bootargs",
# OPTEE_BOOT undefined). The result is a broken dtb: atf_memreserved with an
# empty reg cell, no optee_memreserved node, and chosen/bootargs = "bootargs"
# instead of the real cmdline.
#
# This derivation reproduces Makefile.kernel's dtbs target: run
# patch_reserve_mem.sh over that header to substitute the real addresses/sizes,
# THEN `make dtbs`. The make-var values below were resolved by evaluating the
# vendor makefiles (make -f project.mak print-<VAR>):
#     SUPPORT_ATF               = TRUE
#     ATF_IMG_ADDR              = 0x40040000   (-> ATF reserved start)
#     ATF_IMG_PKG_SIZE          = 0x40000      (-> ATF reserved size, 256K)
#     SUPPORT_OPTEE             = TRUE         (-> #define OPTEE_BOOT)
#     OPTEE_IMAGE_ADDR          = 0x44200000   (-> OPTEE reserved start)
#     OPTEE_RESERVED_SIZE       = 0x2000000    (-> OPTEE reserved size, 32M)
#     AX630C_DDR4_RETRAIN       = TRUE         (0x40000000 / 0x1000; no-op for
#                                               this board, run for fidelity)
#     CMM_POOL_PARAM            = (empty)      (no-op: board dts has no cmmpool)
#     SUPPORT_KERNEL_BOOTARGS   = TRUE
#     KERNEL_BOOTARGS           = the full cmdline below (rootfs = mmcblk0p17)
# The patch-then-build ordering mirrors Makefile.kernel:dtbs (ATF, TEE,
# -p SUPPORT_ATF, DTB bootargs, DDR_RETRAIN, CMM).
#
# This is a separate derivation from kernel.nix because the correct dtb only
# needs `make dtbs` (dtc + cpp), not Image/modules -- a light build that keeps
# the kernel derivation's hash stable. kernel.nix's own $out/dtb/*.dtb remains
# the unpatched raw artifact; THIS is the one packaged + flashed (see
# dtb-fip.nix for the signed partition). The SDK-tree setup (writable kernel
# copy, msp/build siblings, HOME_PATH/PROJECT/LIBC, gcc13) mirrors kernel.nix.
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
    "mem=256M console=${consoleTty},115200n8 earlycon=uart8250,mmio32,${earlyconAddr} "
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
    # (d) console must be the selected UART (eMMC: ttyS0/0x4880000 ; SD: ttyS1/0x4881000)
    if ! grep -q 'console=${consoleTty},115200' dump.dts; then
      echo "ERROR: bootargs missing console=${consoleTty}" >&2
      exit 1
    fi
    if ! grep -q 'earlycon=uart8250,mmio32,${earlyconAddr}' dump.dts; then
      echo "ERROR: bootargs missing earlycon=...,${earlyconAddr}" >&2
      exit 1
    fi
    echo "VERIFY OK: atf + optee reserved-memory regions present, bootargs patched (console=${consoleTty}, earlycon=${earlyconAddr})."

    mkdir -p "$out/dtb"
    cp "$dtb" "$out/dtb/${project}.dtb"
    cp dump.dts "$out/dtb/${project}.dts"   # decompiled, for inspection/proof

    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "NanoKVM-Pro AX630C board dtb, built with the vendor reserved-memory / bootargs patch";
    license = pkgs.lib.licenses.gpl2Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
