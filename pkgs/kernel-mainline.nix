{ pkgs, crossPkgs, ... }:

# ---------------------------------------------------------------------------
# Mainline Linux for the AX630C / NanoKVM-Pro (#74, epic #26).
#
# This is SCAFFOLDING, not a bootable system. It builds an aarch64 `Image` from
# an unmodified kernel.org tree plus our own config fragment, and nothing else:
# no vendor SDK tree, no vendor defconfig, no vermagic contract, no prebuilt
# .ko to stay ABI-compatible with. Booting it is #75, which adds the watchdog
# driver and boot-contract shims and takes the first slot-B boot.
#
# It exists ALONGSIDE pkgs/kernel.nix (Linux 4.19.125, still the shipped
# kernel). Nothing in the firmware/rootfs/update outputs references this file.
#
# Version ceiling: 7.2. The out-of-tree aic8800 WiFi driver (#85) does not
# build above it. WiFi is explicitly droppable (#26, #55) -- when that call is
# made, the ceiling lifts and `kernelAttr` below can move.
#
# Why not nixpkgs' buildLinux: the same reason pkgs/kernel.nix drives `make`
# directly -- we want the config we wrote, an assertable kernelrelease, and the
# raw `Image` that U-Boot's `booti` wants, without a kernel-package wrapper in
# between. We take only the SOURCE from nixpkgs, so the tarball stays pinned and
# hash-verified by the flake's nixpkgs input.
# ---------------------------------------------------------------------------

let
  inherit (pkgs) lib;

  # Highest stable at or below the 7.2 aic8800 ceiling in our nixpkgs pin.
  kernelAttr = "linux_7_1";
  mainline = pkgs.linuxKernel.kernels.${kernelAttr};
  version = mainline.version;

  localversion = "-nanokvm";
  release = "${version}${localversion}";

  crossCC = crossPkgs.buildPackages.gcc;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;
in

# The ceiling is a real constraint, so make it a build-time error rather than a
# comment that rots when nixpkgs bumps.
assert lib.assertMsg (lib.versionOlder version "7.3")
  "kernel-mainline: ${kernelAttr} is ${version}, above the 7.2 aic8800 ceiling (#85). Either pin a lower kernel or record the WiFi drop decision first.";

pkgs.stdenv.mkDerivation {
  pname = "nanokvm-pro-kernel-mainline";
  version = release;

  src = mainline.src;

  # The cross cc-wrapper must not inject stack-protector / fortify / PIE; the
  # kernel manages its own flags.
  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  nativeBuildInputs = [
    crossCC
    crossBinutils
  ] ++ (with pkgs; [
    gnumake bc bison flex openssl ncurses perl elfutils kmod cpio
    gzip lzop which gawk bash zstd rsync
  ]);

  configFragment = ./kernel-mainline/ax630c.config;

  postPatch = ''
    patchShebangs scripts
  '';

  configurePhase = ''
    runHook preConfigure

    export ARCH=arm64
    export CROSS_COMPILE=${crossPrefix}
    export KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970"
    export KBUILD_BUILD_USER=nix
    export KBUILD_BUILD_HOST=nanokvm

    # arm64 `defconfig` is the canonical mainline starting point and already
    # carries this SoC's core drivers. Our fragment (see the file) only pins
    # what a bring-up must not lose.
    make O=build defconfig
    ./scripts/kconfig/merge_config.sh -m -O build \
      build/.config "$configFragment"
    make O=build olddefconfig

    # --- assert the fragment survived olddefconfig ------------------------
    for opt in CONFIG_BLK_DEV_INITRD CONFIG_SERIAL_8250_DW CONFIG_WATCHDOG \
               CONFIG_PSTORE_RAM CONFIG_DMA_CMA CONFIG_NAMESPACES \
               CONFIG_OVERLAY_FS CONFIG_TMPFS_XATTR; do
      grep -q "^$opt=y" build/.config \
        || { echo "ERROR: $opt did not survive olddefconfig" >&2; exit 1; }
    done
    grep -q '^CONFIG_DEBUG_INFO_BTF=y' build/.config \
      && { echo "ERROR: BTF is on; the build will need pahole" >&2; exit 1; }

    # --- assert a stable, predictable release string ----------------------
    # Checked here in config form and again after the build against
    # include/config/kernel.release, which is what actually gets stamped into
    # the Image. `make kernelrelease` does not agree with it before a build.
    grep -q '^CONFIG_LOCALVERSION="${localversion}"' build/.config \
      || { echo "ERROR: CONFIG_LOCALVERSION is not '${localversion}'" >&2; exit 1; }
    grep -q '^CONFIG_LOCALVERSION_AUTO=y' build/.config \
      && { echo "ERROR: LOCALVERSION_AUTO would make the release string vary" >&2; exit 1; }

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Image only. `make dtbs` would build every arm64 vendor's dtbs; ours is
    # compiled from dts/ by pkgs/dtb-mainline.nix, out of tree, on purpose.
    # Modules are not built yet -- there is no rootfs to install them into
    # until #78, and no driver here needs them.
    make O=build -j$NIX_BUILD_CORES Image
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    got="$(cat build/include/config/kernel.release)"
    if [ "$got" != "${release}" ]; then
      echo "ERROR: kernel.release is '$got', expected '${release}'" >&2
      exit 1
    fi

    mkdir -p "$out"
    cp build/arch/arm64/boot/Image "$out/Image"
    cp build/vmlinux "$out/vmlinux"
    cp build/System.map "$out/System.map"
    cp build/.config "$out/config"
    echo "${release}" > "$out/kernelrelease"

    # dt-bindings headers, so pkgs/dtb-mainline.nix compiles dts/ against the
    # exact kernel it will boot on rather than unpacking the tarball twice.
    mkdir -p "$out/include"
    cp -r include/dt-bindings "$out/include/"

    # The slot-image cap is on the COMPRESSED payload, but an Image that
    # already exceeds it uncompressed is a design error worth catching here.
    size=$(stat -c %s "$out/Image")
    echo "Image: $size bytes (${release})"
    if [ "$size" -gt $((64 * 1024 * 1024)) ]; then
      echo "ERROR: Image exceeds the 64 MiB kernel partition even before ax_gzip" >&2
      exit 1
    fi

    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "Mainline Linux ${version} for the Axera AX630C (NanoKVM-Pro), scaffolding for #26";
    platforms = [ "x86_64-linux" ];
  };
}
