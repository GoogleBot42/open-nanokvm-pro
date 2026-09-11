{ pkgs
, crossPkgs
, initramfsMainline ? null
  # The cpio embedded in the Image via CONFIG_INITRAMFS_SOURCE, or `null` for
  # no embedded initramfs at all.
  #
  # `null` IS WHAT THE APPLIANCE USES SINCE #99. The kernel belongs to a NixOS
  # generation now: `boot.loader.generic-extlinux-compatible` writes an
  # `INITRD` line, and mainline U-Boot's `bootmeth_extlinux` loads that file to
  # `ramdisk_addr_r` and hands it to `booti`. Embedding was a workaround for
  # the VENDOR U-Boot, which called `booti` with `-` for the ramdisk argument
  # and had no partition to hold one; nothing has needed it since #89 rung 3.
  #
  # The #75 bring-up variant still embeds, and always will: its `/init` is the
  # only userspace that can exist, because there is no rootfs to switch to.
, initramfsCpio ?
    (if initramfsMainline == null
     then null
     else "${initramfsMainline}/initramfs-mainline.cpio")
  # NONE for the tiny bring-up cpio: a single *.cpio source is embedded byte
  # for byte, which keeps the kernel reproducible and costs nothing at 100 KB.
, initramfsCompression ? "NONE"
  # Names the derivation, so two kernels never collide in a store path or in
  # `nix build` output.
, variant ? "bringup"
  # `boot.kernelPackages`'s `apply` (nixos/modules/system/boot/kernel.nix)
  # calls `kernel.override` and reads `kernel.features`, so this file is
  # instantiated through `lib.makeOverridable` and has to absorb the three
  # arguments NixOS passes. None of them means anything here: there is one
  # config fragment, no randstruct plugin, and our patches are `patches` below
  # in upstream-submission shape rather than a nixpkgs kernelPatches list.
, randstructSeed ? ""
, kernelPatches ? [ ]
, features ? { }
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
# TWO VARIANTS, differing only in whether an initramfs is baked into the Image:
#   bringup   (#75-#77) -- a static musl /init that leaves boot evidence in the
#                          A/B slot register and reserved DRAM, then reboots.
#   appliance (#99)     -- no embedded initramfs. This is the kernel of a NixOS
#                          generation: `boot.kernelPackages` names it, the
#                          extlinux builder copies it and the matching initrd
#                          into /boot/nixos/, and U-Boot loads both.
#
# TWO OUTPUTS. `out` is what a generation carries -- the `Image` and its
# release string, nothing else. `dev` holds vmlinux, System.map, the resolved
# .config and the dt-bindings headers pkgs/dtb-mainline.nix compiles against;
# those are diagnostics and build inputs, and a hundred megabytes of them has
# no business inside an OTA bundle or on the appliance's rootfs.
#
# It replaced pkgs/kernel.nix (Linux 4.19.125, once the shipped
# kernel). No shipped firmware/rootfs/update output references this file yet.
#
# Version ceiling: 7.2. The out-of-tree aic8800 WiFi driver (#85) does not
# build above it. WiFi is explicitly droppable (#26, #55) -- when that call is
# made, the ceiling lifts and `kernelAttr` below can move.
#
# Why not nixpkgs' buildLinux: the same reason the 4.19 build drove `make`
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

  # The video stack's modules (#83). Only the appliance variant can load
  # them; see the buildPhase.
  buildModules = variant != "bringup";

  crossCC = crossPkgs.buildPackages.gcc;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;
in

# The ceiling is a real constraint, so make it a build-time error rather than a
# comment that rots when nixpkgs bumps.
assert lib.assertMsg (lib.versionOlder version "7.3")
  "kernel-mainline: ${kernelAttr} is ${version}, above the 7.2 aic8800 ceiling (#85). Either pin a lower kernel or record the WiFi drop decision first.";

pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "nanokvm-pro-kernel-mainline-${variant}";
  version = release;

  # `out` = the Image a generation boots; `dev` = vmlinux, System.map, the
  # resolved .config and the dt-bindings headers. Splitting them is what keeps
  # the system closure (and therefore the OTA bundle) from carrying an
  # unstripped vmlinux -- see the header.
  outputs = [ "out" "dev" ];

  # What NixOS reads off a kernel derivation. `features` is the important one:
  # nixos/modules/system/boot/kernel.nix skips the `system.requiredKernelConfig`
  # assertions entirely when the kernel advertises it, which is right here --
  # our config is asserted line by line against the fragment in configurePhase,
  # not against a nixpkgs structuredExtraConfig.
  passthru = {
    features = { };
    inherit release version;
    modDirVersion = release;
    # The file NixOS copies as the kernel (`system.boot.loader.kernelFile`),
    # and the name it lands under in /boot/nixos/. `Image` is what arm64's
    # `booti` wants and what installPhase produces.
    target = "Image";
    # `linuxPackagesFor` inherits these off the kernel (linux-kernels.nix,
    # `packagesFor`) and NixOS modules test against them. They are cheap and
    # true; leaving them out makes the eval fail deep inside nixpkgs with
    # "attribute 'kernelAtLeast' missing".
    kernelOlder = lib.versionOlder version;
    kernelAtLeast = lib.versionAtLeast version;
    isLTS = false;
    isZen = false;
    isHardened = false;
    isLibre = false;
    # The kernel is CROSS-COMPILED (see crossCC below), but out-of-tree module
    # packages are the only consumer of this and there are none -- the six
    # modular drivers this kernel has are IN-tree (#83).
    inherit (pkgs) stdenv;
    # No /lib/modules tree in this output. The six video modules are laid out
    # as one by pkgs/video-modules.nix, which is what the appliance's closure
    # names; `system.modulesTree` therefore stays empty and
    # `boot.extraModulePackages` is not the mechanism here.
    hasModules = false;
    # `hardware.deviceTree.enable` defaults to this; the appliance sets both
    # explicitly, and our dtbs come from dts/ rather than the kernel tree.
    buildDTBs = false;
    # THE RESOLVED .config, which nixos/modules/config/sysctl.nix greps for
    # CONFIG_ARCH_MMAP_RND_BITS_MAX on every system. It lives in `dev`, so
    # naming it needs the finished package -- hence the finalAttrs form.
    configfile = "${finalAttrs.finalPackage.dev}/config";
  };

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
    # `make modules` builds every driver arm64 defconfig leaves modular,
    # which is a thousand drivers for other people's hardware -- and some of
    # them generate headers with a host tool. drivers/gpu/drm/msm wants
    # python3 and fails with a bare `Error 127` without it.
    python3
  ]);

  # Modifications to files that already exist upstream. Unlike treeGraft below
  # (which only ADDS files), these have to be diffs, and they are deliberately
  # kept in upstream-submission shape -- one logical change, with the commit
  # message in the patch header -- so #87 can send them as-is. A kernel bump
  # that moves the context breaks the build loudly, which is the point.
  patches = [
    ./kernel-mainline/patches/0001-mmc-sdhci-cadence-add-axera-ax630c.patch
    # #84. The DesignWare PWM core models its two count registers as
    # inversed-polarity only; the hardware is symmetric and a pwm-backlight
    # with an active-high load cannot be expressed without this.
    ./kernel-mainline/patches/0002-pwm-dwc-support-normal-polarity.patch
    # #84. Three optional DT-described integration facts the DesignWare I2S
    # driver has no way to be told about: which RX channel the crossbar lands
    # the capture stream on, a syscon word that has to be written before the
    # block is used, and the clock gates a slave-mode port still needs held.
    ./kernel-mainline/patches/0003-ASoC-dwc-integration-properties.patch
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

  # The mini-display's panel driver (#84): one .c in treeGraft under
  # drivers/staging/fbtft plus this Kconfig block and a Makefile line.
  fbtftKconfig = ./kernel-mainline/fbtft.Kconfig;

  # And the OF front end for the DesignWare PWM core (#84), the backlight's
  # controller. drivers/pwm is flat upstream too.
  pwmKconfig = ./kernel-mainline/pwm.Kconfig;

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

    # --- graft the JD9853 panel driver (#84) -----------------------------
    # fb_jd9853.c was copied above. drivers/staging/fbtft is a flat directory
    # whose Kconfig entries and Makefile lines are both alphabetical;
    # FB_TFT_JD9853 sorts between ILI9486 and PCD8544. A missed hook here is a
    # kernel with no panel driver, which looks exactly like a panel that did
    # not come up.
    awk -v snippet="$fbtftKconfig" '
      /^config FB_TFT_PCD8544$/ && !inserted {
        while ((getline line < snippet) > 0) print line
        print ""
        inserted = 1
      }
      { print }
    ' drivers/staging/fbtft/Kconfig > drivers/staging/fbtft/Kconfig.grafted
    mv drivers/staging/fbtft/Kconfig.grafted drivers/staging/fbtft/Kconfig
    grep -q '^config FB_TFT_JD9853$' drivers/staging/fbtft/Kconfig \
      || { echo "ERROR: could not hook FB_TFT_JD9853 into drivers/staging/fbtft/Kconfig" >&2; exit 1; }

    sed -i 's|^obj-$(CONFIG_FB_TFT_ILI9486)     += fb_ili9486.o$|&\nobj-$(CONFIG_FB_TFT_JD9853)      += fb_jd9853.o|' \
      drivers/staging/fbtft/Makefile
    grep -qF 'obj-$(CONFIG_FB_TFT_JD9853)' drivers/staging/fbtft/Makefile \
      || { echo "ERROR: could not hook fb_jd9853.o into drivers/staging/fbtft/Makefile" >&2; exit 1; }

    # --- graft the DesignWare PWM OF front end (#84) ---------------------
    # pwm-dwc-of.c was copied above. It sits next to the PCI front end it
    # shares a core with, so the anchors are that driver's own Kconfig block
    # and Makefile line. Without it the backlight has no PWM provider and
    # pwm-backlight defers forever -- silently, because a deferred probe is
    # not an error.
    awk -v snippet="$pwmKconfig" '
      /^config PWM_EP93XX$/ && !inserted {
        while ((getline line < snippet) > 0) print line
        print ""
        inserted = 1
      }
      { print }
    ' drivers/pwm/Kconfig > drivers/pwm/Kconfig.grafted
    mv drivers/pwm/Kconfig.grafted drivers/pwm/Kconfig
    grep -q '^config PWM_DWC_OF$' drivers/pwm/Kconfig \
      || { echo "ERROR: could not hook PWM_DWC_OF into drivers/pwm/Kconfig" >&2; exit 1; }

    sed -i 's|^obj-$(CONFIG_PWM_DWC)\t\t+= pwm-dwc.o$|&\nobj-$(CONFIG_PWM_DWC_OF)\t+= pwm-dwc-of.o|' \
      drivers/pwm/Makefile
    grep -qF 'obj-$(CONFIG_PWM_DWC_OF)' drivers/pwm/Makefile \
      || { echo "ERROR: could not hook pwm-dwc-of.o into drivers/pwm/Makefile" >&2; exit 1; }
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

    # ---- Embedded initramfs (#75 bring-up only, since #99) ---------------
    # For the bring-up variant this cpio's /init is the ONLY userspace that can
    # exist -- there is no rootfs to switch to -- and proving userspace was
    # reached is the whole point of that kernel.
    #
    # The appliance passes `null`: its initrd is a FILE in /boot that U-Boot
    # loads, because it is a NixOS generation's initrd now. Leaving
    # INITRAMFS_SOURCE empty also restores the kernel's built-in
    # usr/default_cpio_list, which is what creates /dev/console before PID 1 --
    # the trap documented in nixos/lib/appliance-artifacts.nix until #99.
    #
    # Set BEFORE the fragment is merged, on purpose: the
    # INITRAMFS_COMPRESSION_* choice is `depends on INITRAMFS_SOURCE != ""`, so
    # merging a compression choice into a config with no source silently drops
    # it and the next olddefconfig picks the choice's first member, gzip.
    ${if initramfsCpio == null then ''
      echo "embedded initramfs (${variant}): none -- the initrd is a /boot file"
    '' else ''
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
    ''}

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

    # --- assert the initramfs decision actually landed ---------------------
    # A kernel that boots to no userspace looks exactly like a kernel that
    # died, and this is the only thing that tells the two apart.
    ${if initramfsCpio == null then ''
      grep -q '^CONFIG_INITRAMFS_SOURCE=""' build/.config \
        || { echo "ERROR: this variant must embed NO initramfs, but" >&2
             grep '^CONFIG_INITRAMFS_SOURCE=' build/.config >&2; exit 1; }
      # The initrd arrives as a separate file, so the decompressors the
      # bootloader's payload might use have to be compiled in. NixOS's default
      # compressor is zstd; gzip is kept because a hand-built initrd often is.
      for d in CONFIG_RD_ZSTD CONFIG_RD_GZIP; do
        grep -q "^$d=y" build/.config \
          || { echo "ERROR: $d is off -- the /boot initrd would not unpack" >&2; exit 1; }
      done
    '' else ''
      grep -q "^CONFIG_INITRAMFS_SOURCE=\"$initramfsCpio\"" build/.config \
        || { echo "ERROR: INITRAMFS_SOURCE is not our cpio" >&2; exit 1; }
      # ...and with the compression we asked for. The choice's first member is
      # GZIP, so a dropped selection is silent and only shows up as an Image
      # that is the wrong size -- or, for a *.cpio source, a double compression.
      grep -q '^CONFIG_INITRAMFS_COMPRESSION_${initramfsCompression}=y' build/.config \
        || { echo "ERROR: INITRAMFS_COMPRESSION_${initramfsCompression} did not survive olddefconfig" >&2; exit 1; }
    ''}
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
    # `modules` for the appliance only. Six of them ship (#83): the video
    # stack plus the videobuf2 modules it imports. Everything else this board
    # has is built in, and that is deliberate -- these are modular so a
    # capture or encoder fix is a file copy and an insmod on the running
    # board rather than a /boot write and a reboot into a kernel with no
    # automatic rollback.
    #
    # The bring-up variant skips it. Its userspace is a static /init in a cpio
    # with no insmod path, so the .ko would be unloadable -- and
    # pkgs/dtb-mainline.nix depends on that variant purely for its
    # dt-bindings headers, which is not a reason to build a thousand modules.
    make O=build -j$NIX_BUILD_CORES Image ${lib.optionalString buildModules "modules"}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    got="$(cat build/include/config/kernel.release)"
    if [ "$got" != "${release}" ]; then
      echo "ERROR: kernel.release is '$got', expected '${release}'" >&2
      exit 1
    fi

    # `out` carries the Image and nothing else that costs bytes: it is a
    # runtime dependency of every NixOS generation built on this kernel, so it
    # is also inside every OTA bundle and on the appliance's rootfs.
    mkdir -p "$out"
    cp build/arch/arm64/boot/Image "$out/Image"
    echo "${release}" > "$out/kernelrelease"

    # --- the video stack's modules (#83) ---------------------------------
    # `make modules` builds everything arm64 defconfig leaves modular, which
    # is a thousand drivers for other people's SoCs. Exactly six of them are
    # ours or are needed by ours, and only those are installed -- flat, in
    # $out/modules, with a load order beside them.
    #
    # FLAT, not a /lib/modules tree: pkgs/video-modules.nix copies these ~280 KB
    # out into a proper tree for the appliance's closure, so a systemd unit
    # names that package and not this one. #83 had a second reason -- the
    # appliance's initrd was inside this Image, so a unit referencing the
    # kernel would have made the closure and the kernel depend on each other --
    # and #99 retired it: the initrd is the generation's now, and the KERNEL is
    # in the generation too, which also closes the seam #83 documented (a
    # generation and its kernel could disagree, and nothing could catch it).
    #
    # The order is depmod's, resolved at build time and asserted below:
    # videobuf2-common <- memops, v4l2 <- open_vin_capture; the receiver and
    # the encoder import nothing.
    ${lib.optionalString buildModules ''
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
      echo "video modules: $(tr '\n' ' ' < "$out/modules/load-order")"

      # --- the mini-display's panel modules (#84) ------------------------
      # A SECOND set, in its own directory with its own load order, because
      # they answer to a different service and a different oracle: the video
      # set's is /dev/video0, this one's is /dev/fb0. Mixing them would make
      # one unit's failure look like the other's.
      #
      # Modular rather than built in, and that is the safety property, not a
      # convenience. Loading this driver runs ~560 ms of mdelay and two full
      # panel resets over SPI; built in, a hang there is a kernel that never
      # reaches userspace and costs a bootcount rollback. As a module the
      # board is already up, the unit fails, and the next round can insmod it
      # by hand. (The rule that it is never UNLOADED is unchanged --
      # docs/mini-display.md.)
      mkdir -p "$out/display-modules"
      for ko in fbtft fb_jd9853; do
        src=$(find "$TMPDIR/modstage/lib/modules/${release}" -name "$ko.ko")
        [ -n "$src" ] \
          || { echo "ERROR: $ko.ko was not built as a module" >&2; exit 1; }
        install -m 0644 "$src" "$out/display-modules/$ko.ko"
        echo "$ko.ko" >> "$out/display-modules/load-order"
      done
      echo "display modules: $(tr '\n' ' ' < "$out/display-modules/load-order")"
    ''}

    # `dev` is the diagnostics half, plus the dt-bindings headers
    # pkgs/dtb-mainline.nix compiles dts/ against -- so the DT is always built
    # against the exact kernel that will boot it, without unpacking the tarball
    # twice. -L: a few dt-bindings headers are symlinks into include/uapi (e.g.
    # input/linux-event-codes.h), which we do not ship. Dereference them.
    mkdir -p "$dev/include"
    cp build/vmlinux "$dev/vmlinux"
    cp build/System.map "$dev/System.map"
    cp build/.config "$dev/config"
    echo "${release}" > "$dev/kernelrelease"
    cp -rL include/dt-bindings "$dev/include/"

    # --- a build tree for OUT-OF-TREE modules (#85) ----------------------
    # `dev/lib/modules/<release>/build` is a KDIR: `make -C <kdir> M=<src>
    # modules` against it produces a .ko with this kernel's exact vermagic.
    # The aic8800 WiFi driver (pkgs/aic8800.nix) is the only consumer, and it
    # has to be out-of-tree -- it is 150 kLOC of vendor source with its own
    # Makefile, which is not something to graft into the kernel tree the way
    # the six in-tree drivers above are.
    #
    # The recipe is nixpkgs' (pkgs/os-specific/linux/kernel/manual-config.nix,
    # `postInstall`): copy the source, drop in .config and Module.symvers, run
    # `modules_prepare`, then keep only headers, linker scripts, the root and
    # arch Makefiles and all of scripts/. That prune is what keeps this at a
    # couple of hundred megabytes instead of the whole tree -- and it costs the
    # `dev` output only, which no generation and no image references.
    ${lib.optionalString buildModules ''
      kdir="$dev/lib/modules/${release}"
      mkdir -p "$kdir/build" "$kdir/source"
      # tools/testing is excluded, not pruned afterwards: the selftests are
      # full of relative symlinks into arch/<other>/ and drivers/, both of
      # which the prune below deletes, and 84 dangling links fail nixpkgs'
      # noBrokenSymlinks fixup. Nothing out-of-tree compiles against them.
      rsync --archive --prune-empty-dirs \
        --exclude='/build/' --exclude='/tools/testing/' \
        ./ "$kdir/source/"
      cp build/.config build/Module.symvers "$kdir/build/"

      ( cd "$kdir/source"
        make O="$kdir/build" modules_prepare
        # A leftover from a `try-run` cc1 invocation; removing it keeps the
        # output reproducible.
        rm -f "$kdir/build"/.[0-9]*.d

        chmod -R u+w .
        # Every arch but ours (arm64 keeps arm, as upstream's own build does).
        for d in arch/*/; do
          d=''${d%/}; d=''${d#arch/}
          case "$d" in arm64|arm|Kconfig) continue ;; esac
          rm -rf "arch/$d"
        done
        # 50 MB of it is headers for other people's hardware, and an
        # out-of-tree module includes none of them.
        rm -rf drivers

        # Mark what survives read-only, then delete everything still writable.
        find . -type f -name '*.h'   -print0 | xargs -0 -r chmod u-w
        find . -type f -name '*.lds' -print0 | xargs -0 -r chmod u-w
        chmod u-w Makefile arch/arm64/Makefile*
        # FILES only, not the directories: a read-only directory is one
        # nothing can be deleted from, and the dangling-symlink sweep below
        # has to be able to delete inside scripts/dtc/include-prefixes.
        find scripts -type f -print0 | xargs -0 -r chmod u-w
        find . -type f -perm -u=w -print0 | xargs -0 -r rm

        # `find -type f` never matches a symlink, so the prune above leaves
        # every symlink in place while deleting plenty of targets -- the dtc
        # include-prefixes into arch/<other>/boot/dts, perf's cross-referenced
        # pmu-event json. Thirty-two of those fail nixpkgs' noBrokenSymlinks
        # fixup. Delete the dangling ones generically rather than naming
        # directories a kernel bump can rename.
        find . -xtype l -delete
        find . -empty -type d -delete
      )

      # The point of the whole thing, asserted: a KDIR that cannot answer
      # `make M=` is a build failure three packages away from here.
      for f in Makefile scripts/Makefile.build scripts/mod/modpost; do
        [ -e "$kdir/source/$f" ] || [ -e "$kdir/build/$f" ] \
          || { echo "ERROR: the out-of-tree KDIR is missing $f" >&2; exit 1; }
      done
      echo "KDIR: $(du -sh "$kdir" | cut -f1) at lib/modules/${release}"
    ''}

    # 64 MiB is two limits that happen to coincide: the vendor layout's
    # `kernel` partition (the bring-up variant is flashed into it), and the gap
    # between `kernel_addr_r` (0x4a000000) and `ramdisk_addr_r` (0x4e000000) in
    # mainline U-Boot's environment -- an Image larger than that would be
    # loaded straight over the initrd's landing address.
    size=$(stat -c %s "$out/Image")
    echo "Image: $size bytes (${release})"
    if [ "$size" -gt $((64 * 1024 * 1024)) ]; then
      echo "ERROR: Image exceeds 64 MiB -- the vendor kernel partition, and the" >&2
      echo "       kernel_addr_r..ramdisk_addr_r gap in U-Boot's environment." >&2
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
})
