{ pkgs
, crossPkgs
, initramfsMainline ? null
  # The cpio embedded in the Image via CONFIG_INITRAMFS_SOURCE. Defaults to the
  # #75 bring-up initramfs; #78 passes the NixOS stage-1 initrd instead, and
  # that substitution is the whole difference between "a kernel that proves it
  # booted" and "a kernel that boots the appliance". There is no other way to
  # get an initrd onto this board: U-Boot's `booti` is called with `-` for the
  # ramdisk argument and no partition holds one (docs/mainline-port.md § 5).
, initramfsCpio ? "${initramfsMainline}/initramfs-mainline.cpio"
  # NONE for the tiny bring-up cpio: a single *.cpio source is embedded byte
  # for byte, which keeps the kernel reproducible and costs nothing at 100 KB.
  # ZSTD for the NixOS initrd, which is tens of megabytes and shares a 64 MiB
  # partition with the kernel.
, initramfsCompression ? "NONE"
  # Names the derivation and the slot image, so the two kernels never collide
  # in a store path or in `nix build` output.
, variant ? "bringup"
, ...
}:

# ---------------------------------------------------------------------------
# Mainline Linux for the AX630C / NanoKVM-Pro (#74, epic #26).
#
# An aarch64 `Image` built from an unmodified kernel.org tree plus our own
# config fragment, our own in-tree drivers and our own device tree: no vendor
# SDK tree, no vendor defconfig, no vermagic contract, no prebuilt .ko to stay
# ABI-compatible with. It has booted this silicon since #75.
#
# TWO VARIANTS, differing only in the initramfs baked into the Image:
#   bringup   (#75-#77) -- a static musl /init that leaves boot evidence in the
#                          A/B slot register and reserved DRAM, then reboots.
#   appliance (#78)     -- the NixOS stage-1 initrd (nixos/rootfs.nix), which
#                          mounts the real root and switch_roots into it.
#
# It exists ALONGSIDE pkgs/kernel.nix (Linux 4.19.125, still the shipped
# kernel). No shipped firmware/rootfs/update output references this file yet.
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
  pname = "nanokvm-pro-kernel-mainline-${variant}";
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

  # Modifications to files that already exist upstream. Unlike treeGraft below
  # (which only ADDS files), these have to be diffs, and they are deliberately
  # kept in upstream-submission shape -- one logical change, with the commit
  # message in the patch header -- so #87 can send them as-is. A kernel bump
  # that moves the context breaks the build loudly, which is the point.
  patches = [
    ./kernel-mainline/patches/0001-mmc-sdhci-cadence-add-axera-ax630c.patch
  ];

  configFragment = ./kernel-mainline/ax630c.config;

  # Our own in-tree drivers, laid out at the path they would occupy upstream so
  # that #87's submission is a `git add`, not a re-layout. Grafted into the
  # kernel tree in postPatch below. Built in, not modular: a clock provider and
  # a pinctrl driver are needed long before there is a rootfs to load a .ko from.
  treeGraft = ./kernel-mainline/tree;

  # drivers/watchdog has no per-vendor subdirectories upstream, so the watchdog
  # driver (#75) is a flat file in treeGraft plus this Kconfig block, inserted
  # below where it belongs alphabetically.
  watchdogKconfig = ./kernel-mainline/watchdog.Kconfig;

  # Same shape for the DWMAC glue (#77): drivers/net/ethernet/stmicro/stmmac is
  # a flat directory upstream, so the driver is one .c in treeGraft plus this
  # Kconfig block and a Makefile line.
  stmmacKconfig = ./kernel-mainline/stmmac.Kconfig;

  # And again for the GPIO controller (#81): drivers/gpio is flat upstream, so
  # one .c in treeGraft plus this Kconfig block and a Makefile line.
  gpioKconfig = ./kernel-mainline/gpio.Kconfig;

  # Same for the HDMI receiver's management driver (#81), in drivers/misc.
  miscKconfig = ./kernel-mainline/misc.Kconfig;

  # And for the DWC3 glue (#82). drivers/usb/dwc3 is flat too.
  dwc3Kconfig = ./kernel-mainline/dwc3.Kconfig;

  postPatch = ''
    patchShebangs scripts

    # --- graft our in-tree drivers (#80 clk + pinctrl) --------------------
    cp -r "$treeGraft"/. .
    chmod -R u+w drivers include

    # Hook each grafted directory into its subsystem's Kconfig and Makefile,
    # in the alphabetical slot upstream would put it. `sed` is doing an
    # insertion, so assert it landed -- a silently missed hook would build a
    # kernel with no clock driver and fail much later and much less clearly.
    # $1 = subsystem dir, $2 = the existing entry we sort ourselves after,
    # $3 = the tab run that keeps our Makefile line in the file's column. The
    # entry is unconditional obj-y: the Kconfig symbols gate it from inside our
    # own Makefile, which is how a directory with several symbols does it
    # upstream.
    graft_into() {
      sed -i "s|^source \"drivers/$1/$2/Kconfig\"|&\nsource \"drivers/$1/axera/Kconfig\"|" \
        "drivers/$1/Kconfig"
      grep -q "^source \"drivers/$1/axera/Kconfig\"" "drivers/$1/Kconfig" \
        || { echo "ERROR: could not hook drivers/$1/axera into Kconfig" >&2; exit 1; }

      sed -i "s|^obj-[^ \t]*[ \t]*+= $2/|&\nobj-y$3+= axera/|" "drivers/$1/Makefile"
      grep -qF "obj-y$3+= axera/" "drivers/$1/Makefile" \
        || { echo "ERROR: could not hook drivers/$1/axera into the Makefile" >&2; exit 1; }
    }

    graft_into clk     aspeed "$(printf '\t\t\t\t\t')"
    graft_into pinctrl aspeed "$(printf '\t\t\t\t')"

    # --- graft the video stack (#83) -------------------------------------
    # drivers/media/platform is a directory of per-vendor directories, so this
    # is the same shape as clk/pinctrl above but with different anchors: the
    # Kconfig sources each vendor's file by full path and the Makefile lists
    # `obj-y += <vendor>/`. `axera` sorts between `atmel` and `broadcom` in
    # both. Assert each insertion -- a missed hook builds a kernel with no
    # capture and no encoder, which is a working appliance that serves a black
    # stream.
    sed -i 's|^source "drivers/media/platform/atmel/Kconfig"|&\nsource "drivers/media/platform/axera/Kconfig"|' \
      drivers/media/platform/Kconfig
    grep -q '^source "drivers/media/platform/axera/Kconfig"' drivers/media/platform/Kconfig \
      || { echo "ERROR: could not hook drivers/media/platform/axera into Kconfig" >&2; exit 1; }

    sed -i 's|^obj-y += atmel/$|&\nobj-y += axera/|' drivers/media/platform/Makefile
    grep -qF 'obj-y += axera/' drivers/media/platform/Makefile \
      || { echo "ERROR: could not hook drivers/media/platform/axera into the Makefile" >&2; exit 1; }

    # --- graft the flat watchdog driver (#75) ----------------------------
    # Not a directory graft: drivers/watchdog is flat upstream, so this is one
    # .c (already copied above) plus a Kconfig block and a Makefile line, each
    # inserted at the alphabetical slot upstream would use. Both anchors are
    # unique in their file; assert the insertions, because a silently missed
    # hook here builds a kernel with no watchdog driver -- which on this board
    # means U-Boot's 30 s dog resets it mid-boot, forever, with no console.
    awk -v snippet="$watchdogKconfig" '
      /^config CADENCE_WATCHDOG$/ && !inserted {
        while ((getline line < snippet) > 0) print line
        print ""
        inserted = 1
      }
      { print }
    ' drivers/watchdog/Kconfig > drivers/watchdog/Kconfig.grafted
    mv drivers/watchdog/Kconfig.grafted drivers/watchdog/Kconfig
    grep -q '^config AX630C_WATCHDOG$' drivers/watchdog/Kconfig \
      || { echo "ERROR: could not hook AX630C_WATCHDOG into drivers/watchdog/Kconfig" >&2; exit 1; }

    sed -i 's|^obj-$(CONFIG_AT91SAM9X_WATCHDOG) += at91sam9_wdt.o$|&\nobj-$(CONFIG_AX630C_WATCHDOG) += ax630c_wdt.o|' \
      drivers/watchdog/Makefile
    grep -qF 'obj-$(CONFIG_AX630C_WATCHDOG) += ax630c_wdt.o' drivers/watchdog/Makefile \
      || { echo "ERROR: could not hook ax630c_wdt.o into drivers/watchdog/Makefile" >&2; exit 1; }

    # --- graft the DWMAC glue (#77) --------------------------------------
    # dwmac-axera.c was copied above; hook its Kconfig block in ahead of
    # DWMAC_EIC7700 (the alphabetical slot after DWMAC_ANARION) and its object
    # line after dwmac-anarion.o. Assert both: a missed hook here builds a
    # kernel whose ethernet node binds nothing, on a board that is supposed to
    # be reachable only over ethernet.
    stmmacK=drivers/net/ethernet/stmicro/stmmac
    awk -v snippet="$stmmacKconfig" '
      /^config DWMAC_EIC7700$/ && !inserted {
        while ((getline line < snippet) > 0) print line
        print ""
        inserted = 1
      }
      { print }
    ' "$stmmacK/Kconfig" > "$stmmacK/Kconfig.grafted"
    mv "$stmmacK/Kconfig.grafted" "$stmmacK/Kconfig"
    grep -q '^config DWMAC_AXERA$' "$stmmacK/Kconfig" \
      || { echo "ERROR: could not hook DWMAC_AXERA into $stmmacK/Kconfig" >&2; exit 1; }

    sed -i 's|^obj-$(CONFIG_DWMAC_ANARION)\t+= dwmac-anarion.o$|&\nobj-$(CONFIG_DWMAC_AXERA)\t+= dwmac-axera.o|' \
      "$stmmacK/Makefile"
    grep -qF 'obj-$(CONFIG_DWMAC_AXERA)' "$stmmacK/Makefile" \
      || { echo "ERROR: could not hook dwmac-axera.o into $stmmacK/Makefile" >&2; exit 1; }

    # --- graft the GPIO controller (#81) ---------------------------------
    # gpio-ax630c.c was copied above; GPIO_AX630C sorts between GPIO_ATH79 and
    # GPIO_BCM_KONA. Assert both hooks: a kernel with this driver missing
    # binds no gpiochip, so the HDMI receiver never powers on and the ATX
    # lines are never claimed -- and the DT would look perfectly correct.
    awk -v snippet="$gpioKconfig" '
      /^config GPIO_BCM_KONA$/ && !inserted {
        while ((getline line < snippet) > 0) print line
        print ""
        inserted = 1
      }
      { print }
    ' drivers/gpio/Kconfig > drivers/gpio/Kconfig.grafted
    mv drivers/gpio/Kconfig.grafted drivers/gpio/Kconfig
    grep -q '^config GPIO_AX630C$' drivers/gpio/Kconfig \
      || { echo "ERROR: could not hook GPIO_AX630C into drivers/gpio/Kconfig" >&2; exit 1; }

    sed -i 's|^obj-$(CONFIG_GPIO_ATH79)\t\t+= gpio-ath79.o$|&\nobj-$(CONFIG_GPIO_AX630C)\t\t+= gpio-ax630c.o|' \
      drivers/gpio/Makefile
    grep -qF 'obj-$(CONFIG_GPIO_AX630C)' drivers/gpio/Makefile \
      || { echo "ERROR: could not hook gpio-ax630c.o into drivers/gpio/Makefile" >&2; exit 1; }

    # --- graft the HDMI receiver's management driver (#81) ---------------
    # drivers/misc is flat and unsorted upstream, so the anchors are simply
    # two lines that exist exactly once. Assert both: without this driver the
    # /proc interface libkvm reads for the source geometry does not exist, and
    # capture has no way to learn what the attached machine is displaying.
    awk -v snippet="$miscKconfig" '
      /^config SRAM$/ && !inserted {
        while ((getline line < snippet) > 0) print line
        print ""
        inserted = 1
      }
      { print }
    ' drivers/misc/Kconfig > drivers/misc/Kconfig.grafted
    mv drivers/misc/Kconfig.grafted drivers/misc/Kconfig
    grep -q '^config LT6911_MANAGE$' drivers/misc/Kconfig \
      || { echo "ERROR: could not hook LT6911_MANAGE into drivers/misc/Kconfig" >&2; exit 1; }

    sed -i 's|^obj-$(CONFIG_SRAM)\t\t+= sram.o$|&\nobj-$(CONFIG_LT6911_MANAGE)\t+= lt6911-manage.o|' \
      drivers/misc/Makefile
    grep -qF 'obj-$(CONFIG_LT6911_MANAGE)' drivers/misc/Makefile \
      || { echo "ERROR: could not hook lt6911-manage.o into drivers/misc/Makefile" >&2; exit 1; }

    # --- graft the DWC3 glue (#82) ---------------------------------------
    # dwc3-axera.c was copied above. drivers/usb/dwc3 is flat and, unlike the
    # files above, has NO alphabetical order to slot into -- upstream appends
    # each new glue layer to the end of both lists. So the anchors are
    # positional: the first glue entry in the Kconfig (USB_DWC3_OMAP) and the
    # dwc3-apple.o line in the Makefile. Assert both, as everywhere else: a
    # missed hook here builds a kernel whose USB node binds nothing, which on
    # this board means no keyboard and no mouse.
    awk -v snippet="$dwc3Kconfig" '
      /^config USB_DWC3_OMAP$/ && !inserted {
        while ((getline line < snippet) > 0) print line
        print ""
        inserted = 1
      }
      { print }
    ' drivers/usb/dwc3/Kconfig > drivers/usb/dwc3/Kconfig.grafted
    mv drivers/usb/dwc3/Kconfig.grafted drivers/usb/dwc3/Kconfig
    grep -q '^config USB_DWC3_AXERA$' drivers/usb/dwc3/Kconfig \
      || { echo "ERROR: could not hook USB_DWC3_AXERA into drivers/usb/dwc3/Kconfig" >&2; exit 1; }

    sed -i 's|^obj-$(CONFIG_USB_DWC3_APPLE)\t\t+= dwc3-apple.o$|&\nobj-$(CONFIG_USB_DWC3_AXERA)\t\t+= dwc3-axera.o|' \
      drivers/usb/dwc3/Makefile
    grep -qF 'obj-$(CONFIG_USB_DWC3_AXERA)' drivers/usb/dwc3/Makefile \
      || { echo "ERROR: could not hook dwc3-axera.o into drivers/usb/dwc3/Makefile" >&2; exit 1; }
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

    # ---- Embedded initramfs (#75 bring-up, #78 appliance) ----------------
    # For the bring-up variant this cpio's /init is the ONLY userspace that can
    # exist (there is no rootfs to switch to) and proving userspace was reached
    # is the whole point; for the appliance variant it is NixOS stage 1 and it
    # is the only stage-1 the board has, because U-Boot passes no initrd.
    #
    # Set BEFORE the fragment is merged, on purpose: the
    # INITRAMFS_COMPRESSION_* choice is `depends on INITRAMFS_SOURCE != ""`, so
    # merging a compression choice into a config with no source silently drops
    # it and the next olddefconfig picks the choice's first member, gzip.
    initramfsCpio="${initramfsCpio}"
    case "$initramfsCpio" in
      *.cpio) ;;
      *) echo "ERROR: INITRAMFS_SOURCE must end in .cpio -- usr/Makefile only" >&2
         echo "       uses a single source verbatim when it does." >&2
         exit 1 ;;
    esac
    echo "embedded initramfs (${variant}): $(stat -Lc%s "$initramfsCpio") bytes ($initramfsCpio)"
    ./scripts/config --file build/.config \
      --set-str INITRAMFS_SOURCE "$initramfsCpio" \
      --enable INITRAMFS_COMPRESSION_${initramfsCompression}

    ./scripts/kconfig/merge_config.sh -m -O build \
      build/.config "$configFragment"
    make O=build olddefconfig

    # --- assert EVERY fragment line survived olddefconfig -----------------
    # Generated from the fragment itself, not hand-maintained. The previous
    # hand-written list could only check what someone remembered to add to it,
    # and it did not include CONFIG_BLK_CMDLINE_PARSER -- a symbol that does
    # not exist in 7.x at all (it is the 4.19 name for CMDLINE_PARTITION).
    # olddefconfig dropped it in silence, nothing noticed for two issues, and
    # the first #76 boot came up with an eMMC that enumerated perfectly and had
    # no partitions.
    #
    # A fragment line that does not survive is ALWAYS a bug: either the symbol
    # is misspelled or its dependencies are unmet. Both deserve a failed build
    # rather than a surprise three hours later on hardware. If a line ever
    # legitimately cannot hold, special-case it here deliberately and say why.
    fail=0
    while read -r line; do
      case "$line" in
        CONFIG_*=*)
          grep -qxF "$line" build/.config || {
            echo "ERROR: fragment line did not survive olddefconfig: $line" >&2
            echo "       (misspelled symbol, or unmet dependency)" >&2
            fail=1
          } ;;
        "# CONFIG_"*" is not set")
          opt=''${line#'# '}
          opt=''${opt%' is not set'}
          grep -q "^$opt=" build/.config && {
            echo "ERROR: $opt is set, but the fragment disables it" >&2
            fail=1
          } ;;
      esac
    done < "$configFragment"
    [ "$fail" -eq 0 ] || exit 1

    # --- assert the things whose ABSENCE is load-bearing ------------------
    # STRICT_DEVMEM would let the bring-up init map the two MMIO windows but
    # not its log stash, which is reserved-but-mapped System RAM -- and it
    # would fail at runtime, on the one boot that matters, with no console.
    grep -q '^CONFIG_STRICT_DEVMEM=y' build/.config \
      && { echo "ERROR: STRICT_DEVMEM blocks the bring-up init's log stash" >&2; exit 1; }

    # --- assert the embedded initramfs actually landed --------------------
    # A kernel that boots to no userspace looks exactly like a kernel that
    # died, and this is the only thing that tells the two apart.
    grep -q "^CONFIG_INITRAMFS_SOURCE=\"$initramfsCpio\"" build/.config \
      || { echo "ERROR: INITRAMFS_SOURCE is not our cpio" >&2; exit 1; }
    # ...and with the compression we asked for. The choice's first member is
    # GZIP, so a dropped selection is silent and only shows up as an Image that
    # is the wrong size -- or, for a *.cpio source, as a double compression.
    grep -q '^CONFIG_INITRAMFS_COMPRESSION_${initramfsCompression}=y' build/.config \
      || { echo "ERROR: INITRAMFS_COMPRESSION_${initramfsCompression} did not survive olddefconfig" >&2; exit 1; }
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
    # `make dtbs` would build every arm64 vendor's dtbs; ours is compiled from
    # dts/ by pkgs/dtb-mainline.nix, out of tree, on purpose.
    #
    # `modules` builds exactly three .ko: the video stack (#83). Every other
    # driver this board has is built in, and that is deliberate -- these three
    # are modular so a capture or encoder fix is a file copy and an insmod on
    # the running board rather than a /boot write and a reboot into a kernel
    # with no automatic rollback.
    make O=build -j$NIX_BUILD_CORES Image modules
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

    # --- the video stack's modules (#83) ---------------------------------
    # `make modules` builds everything arm64 defconfig leaves modular, which
    # is a thousand drivers for other people's SoCs. Exactly six of them are
    # ours or are needed by ours, and only those are installed -- flat, in
    # $out/modules, with a load order beside them.
    #
    # FLAT AND ON /boot, not a /lib/modules tree in the NixOS closure, and
    # that is a dependency fact rather than a style choice: the appliance's
    # initrd is EMBEDDED IN THIS IMAGE, so a systemd unit that referenced this
    # derivation would make the system closure depend on the kernel and the
    # kernel depend on the system closure. The modules belong to the same
    # artefact as the Image and the dtb, they are installed with them
    # (pkgs/bootfs.nix payloadDirs), and a mismatched pair fails loudly at
    # insmod with a vermagic error rather than quietly.
    #
    # The order is depmod's, resolved at build time and asserted below:
    # videobuf2-common <- memops, v4l2 <- open_vin_capture; the receiver and
    # the encoder import nothing.
    make O=build INSTALL_MOD_PATH="$TMPDIR/modstage" INSTALL_MOD_STRIP=1 \
      DEPMOD=${pkgs.kmod}/bin/depmod modules_install

    mkdir -p "$out/modules"
    for ko in videobuf2-common videobuf2-memops videobuf2-v4l2 \
              open_vin_csi2 open_vin_capture ax630c_venc_vcmd; do
      src=$(find "$TMPDIR/modstage/lib/modules/${release}" -name "$ko.ko")
      [ -n "$src" ] \
        || { echo "ERROR: $ko.ko was not built as a module" >&2; exit 1; }
      install -m 0644 "$src" "$out/modules/$ko.ko"
      echo "$ko.ko" >> "$out/modules/load-order"
    done
    echo "video modules: $(cat "$out/modules/load-order" | tr '\n' ' ')"

    # dt-bindings headers, so pkgs/dtb-mainline.nix compiles dts/ against the
    # exact kernel it will boot on rather than unpacking the tarball twice.
    # -L: a few dt-bindings headers are symlinks into include/uapi (e.g.
    # input/linux-event-codes.h), which we do not ship. Dereference them.
    mkdir -p "$out/include"
    cp -rL include/dt-bindings "$out/include/"

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
    description = "Mainline Linux ${version} for the Axera AX630C (NanoKVM-Pro), ${variant} variant (#26)";
    platforms = [ "x86_64-linux" ];
  };
}
