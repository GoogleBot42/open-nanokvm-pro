{ pkgs, crossPkgs, maix_ax620e_sdk, maix_ax620e_sdk_kernel, maix_ax620e_sdk_msp, ... }:

# ---------------------------------------------------------------------------
# Linux 4.19.125 kernel + NanoKVM-Pro DTS + open lt6911_manage.ko (from source).
# Source: maix_ax620e_sdk_kernel/linux/linux-4.19.125.
#   defconfig: arch/arm64/configs/axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig
#   DTS:       arch/arm64/boot/dts/axera/AX630C_emmc_arm64_k419_sipeed_nanokvm.dts
#   HDMI:      drivers/misc/lt6911_manage.c (open GPL LT6911UXC poller, exposes
#              /proc/lt6911/*). CONFIG_LT6911_MANAGE=m in the defconfig, so it is
#              built in-tree by `make modules` -- no external M= build needed.
#
# ===========================================================================
# PREBUILT ax_*.ko COMPATIBILITY -- the load-bearing constraint (RESOLVED)
# ===========================================================================
# The prebuilt Axera media modules (see ax-ko-blobs.nix) must insmod into THIS
# from-source kernel. Two gates were investigated against the actual blobs:
#
#   1. vermagic. Every ax_*.ko carries
#          vermagic = "4.19.125 SMP preempt mod_unload aarch64"
#      (read via `readelf -p .modinfo ax_venc.ko`; identical across all 22
#      blobs). This decodes to: CONFIG_SMP=y, CONFIG_PREEMPT=y,
#      CONFIG_MODULE_UNLOAD=y, release string exactly "4.19.125" (empty
#      CONFIG_LOCALVERSION, LOCALVERSION_AUTO off). The vendor defconfig sets
#      exactly these, so a from-source build with it reproduces the string
#      byte-for-byte (verified: `make kernelrelease` -> "4.19.125").
#
#   2. MODVERSIONS. The blobs have NO `__versions` ELF section and the
#      defconfig has `# CONFIG_MODVERSIONS is not set`. => per-symbol CRCs are
#      NOT checked at load time. Therefore we do NOT need the exact vendor
#      .config or the exact vendor GCC to match CRCs -- only the vermagic
#      STRING must match. (Were MODVERSIONS on, we would have to reproduce the
#      vendor Module.symvers exactly; it is off, so we do not.)
#
# The blobs' undefined symbols are (a) inter-module AX_OSAL_* (provided among
# the ax_*.ko set themselves, e.g. defined in ax_cmm.ko) and (b) a small set of
# standard exported kernel symbols (printk, memcmp, strlen, of_find_compatible_
# node, of_irq_get, of_node_put, param_array_ops, param_ops_charp, ...) which
# the vendor defconfig exports. Building with the vendor defconfig is therefore
# still the right choice (maximises symbol availability), even though CRC-exact
# matching is not required.
#
# VERDICT: a vermagic-string match SUFFICES; exact vendor GCC/.config is NOT
# required. The blobs should load with a plain `insmod` (no --force-vermagic).
# ===========================================================================
#
# TOOLCHAIN: nixpkgs-unstable has REMOVED gcc9..gcc12 ("unmaintained/obsolete");
# only gcc13/gcc14/gcc15 remain. Because MODVERSIONS is off, CRC-exact GCC
# matching is unnecessary, so we use the oldest still-packaged cross GCC that
# builds 4.19 cleanly: gcc13 (13.4.0). gcc15 (the pkgsCross default) is too new
# for 4.19. Validated locally: gcc13 compiles Image + dtbs + modules from this
# tree.
# ---------------------------------------------------------------------------

let
  # Oldest cross GCC still in nixpkgs-unstable that builds Linux 4.19 cleanly.
  crossCC = crossPkgs.buildPackages.gcc13;
  crossBinutils = crossPkgs.buildPackages.binutils;

  # nixpkgs cross triple: aarch64-unknown-linux-gnu- (ABI-identical to the
  # vendor's aarch64-none-linux-gnu-; only the triple string differs).
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;

  kernelSubdir = "linux/linux-4.19.125";
  defconfig = "axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig";
  # AX_OSAL is built INTO the kernel: drivers/soc/axera/Makefile has
  #   obj-$(CONFIG_AXERA_OSAL) += ../../../../../osal/linux/kernel/
  # i.e. it reaches OUT of the kernel tree to the repo-root `osal/` sibling.
  # So the whole repo (not just linux/linux-4.19.125) must be present, writable,
  # with its directory layout intact. CONFIG_AXERA_OSAL=y is set by the
  # defconfig; this is what EXPORT_SYMBOLs the AX_OSAL_* the blobs import.
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";
  release = "4.19.125";
in
pkgs.stdenv.mkDerivation {
  pname = "nanokvm-pro-kernel";
  version = release;

  src = maix_ax620e_sdk_kernel;

  # The cross cc-wrapper must not inject stack-protector / fortify / PIE into
  # the kernel compile; the kernel manages its own flags.
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
    openssl        # host tools: extract-cert (CONFIG_SYSTEM_TRUSTED_KEYRING)
    ncurses
    perl
    elfutils       # objtool / unwinder tooling
    kmod           # depmod for modules_install
    cpio           # usr/ initramfs gen step
    gzip
    lzop
    which
    gawk
    bash           # scripts/config has a /bin/bash shebang absent on NixOS
  ]);

  # We do our own copy (whole repo, writable) in configurePhase.
  dontUnpack = true;

  # Build in a writable copy of the WHOLE repo: the nix store src is read-only,
  # a few Kbuild steps write generated headers, and the OSAL built-in reaches
  # the repo-root `osal/` sibling of the kernel tree (see note above). Also, the
  # vendor defconfig bakes an SDK-relative CONFIG_INITRAMFS_SOURCE that only
  # exists in the vendor build tree -- our rootfs is a separate derivation, so
  # build with an empty embedded initramfs.
  configurePhase = ''
    runHook preConfigure

    export ARCH=arm64
    export CROSS_COMPILE=${crossPrefix}
    export KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970"
    export KBUILD_BUILD_USER=nix
    export KBUILD_BUILD_HOST=nixbuild

    # The in-tree axera SoC drivers (drivers/soc/axera/*) reach OUT of the kernel
    # tree into the vendor SDK's sibling repos, expecting the layout
    #   <SDK_ROOT>/{kernel,msp,build}
    # and the vendor make-vars HOME_PATH / PROJECT / LIBC. Concretely:
    #   - OSAL:   drivers/soc/axera/Makefile pulls in ../../../../../osal/... and
    #             osal/linux/kernel/Makefile adds -I$HOME_PATH/kernel/osal/include.
    #             (getcwd() resolves symlinks, so kernel must sit at a REAL path
    #             ending in /kernel -- copied, not symlinked.)
    #   - gzipd:  drivers/soc/axera/gzipd needs ax_gzipd_api.h etc. from
    #             -I$HOME_PATH/msp/out/$(ARCH)_$(LIBC)/include  (=> LIBC=glibc).
    #   - pinmux: drivers/soc/axera/pinmux #includes board tables from
    #             -I$HOME_PATH/build/projects/$PROJECT/pinmux/.
    # msp and build are read-only-safe (header include dirs only), so symlink
    # them from the store; only the kernel tree needs to be a writable copy.
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

    # Fail LOUDLY here (not on-device) if a future kernel/config bump would
    # break ax_*.ko loading by changing the vermagic inputs.
    rel="$(make -s O=build kernelrelease)"
    if [ "$rel" != "${release}" ]; then
      echo "ERROR: kernelrelease '$rel' != '${release}' -- ax_*.ko vermagic would mismatch." >&2
      exit 1
    fi
    for opt in CONFIG_SMP=y CONFIG_PREEMPT=y CONFIG_MODULE_UNLOAD=y; do
      grep -qx "$opt" build/.config \
        || { echo "ERROR: $opt missing -- vermagic mismatch." >&2; exit 1; }
    done
    if grep -qx 'CONFIG_MODVERSIONS=y' build/.config; then
      echo "ERROR: CONFIG_MODVERSIONS on -- prebuilt ax_*.ko have no __versions." >&2
      exit 1
    fi

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cd "$KROOT"
    mk="make O=build -j$NIX_BUILD_CORES HOME_PATH=$HOME_PATH PROJECT=${project} LIBC=glibc"
    $mk Image
    # PROJECT= also selects the board dtb: arch/arm64/boot/dts/axera/Makefile has
    # dtb-$(CONFIG_ARCH_AXERA) += $(PROJECT).dtb.
    $mk dtbs
    $mk modules
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cd "$KROOT"

    mkdir -p "$out" "$out/dtb"
    cp build/arch/arm64/boot/Image "$out/Image"
    cp build/vmlinux "$out/vmlinux"
    cp build/System.map "$out/System.map"
    cp "build/arch/arm64/boot/dts/axera/${project}.dtb" "$out/dtb/${project}.dtb"

    # Loadable modules (includes lt6911_manage.ko). Pass the vendor make-vars in
    # case any postproc rule re-enters an axera sub-Makefile.
    make O=build HOME_PATH="$HOME_PATH" PROJECT=${project} LIBC=glibc \
      INSTALL_MOD_PATH="$out" modules_install

    # Drop the dangling build/source symlinks modules_install leaves behind.
    rm -f "$out/lib/modules/${release}/build" "$out/lib/modules/${release}/source"

    echo "Built modules:"
    find "$out/lib/modules/${release}" -name '*.ko' -printf '  %f\n' | sort

    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "NanoKVM-Pro Linux ${release} kernel (Image + board dtb + modules incl. lt6911_manage.ko), from source, ax_*.ko-vermagic-compatible";
    license = pkgs.lib.licenses.gpl2Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
