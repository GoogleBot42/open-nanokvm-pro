{
  description = ''
    Open, self-built firmware image for the Sipeed NanoKVM-Pro (Axera AX630C,
    ARM Cortex-A53 aarch64). Boot chain / kernel / app layer are built from
    source; Axera's redistributable media libraries (libax_*.so, BSD-3) and the
    prebuilt ax_*.ko media kernel modules are pinned as binary inputs.

    See README.md for architecture and PLAN.md (repo root, one level up) for the
    authoritative video-path / on-device recon notes. This flake is a STRUCTURE
    pass: light derivations build; heavy ones (kernel, boot chain, image) are
    documented stubs with correct sources + TODOs.
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # ------------------------------------------------------------------
    # Upstream Sipeed / Axera source repositories.
    #
    # Rev pins are the HEAD of each repo's `main` branch as of 2026-07-17
    # (looked up via the GitHub API). ASSUMPTION / TODO: these are moving
    # `main` HEADs, not release tags. Before a real build, re-pin to a tagged
    # SDK release that matches the on-device V3.0.0_20250319 SDK (the msp repo
    # HEAD is what matches the device today). Treat each as `flake = false`
    # (plain source tree, no flake.nix of its own).
    # ------------------------------------------------------------------

    # Boot chain (bl1/SPL, TF-A 2.7, OP-TEE 3.21, U-Boot 2020.04) + image
    # pipeline (build/projects/AX630C_emmc_arm64_k419_sipeed_nanokvm) + rootfs
    # scripts + tools (axp-tools shims). GPL/BSD mix, buildable from source.
    maix_ax620e_sdk = {
      url = "github:sipeed/maix_ax620e_sdk/45ebcc32dfcfade1f8cfd1d8f70da67b86ea2902";
      flake = false;
    };

    # Kernel: Linux 4.19.125 + AX630C..._sipeed_nanokvm DTS + open
    # lt6911_manage.c. NOTE: the ax_*.ko media modules under osdrv/out/*/ko/
    # are PREBUILT BLOBS living in THIS repo (pinned via ax-ko-blobs.nix).
    maix_ax620e_sdk_kernel = {
      url = "github:sipeed/maix_ax620e_sdk_kernel/ee5d79590ba85c1fd08eed587ba13c6f98da862c";
      flake = false;
    };

    # Axera userspace media libraries (libax_*.so, libsns_dummy.so, BSD-3,
    # redistributable) + matching V3.0.0 headers. out/arm64_glibc/{lib,include}.
    maix_ax620e_sdk_msp = {
      url = "github:sipeed/maix_ax620e_sdk_msp/1bd333bc5ec074b868107102889044e79209771d";
      flake = false;
    };

    # App layer (GPL-3.0): server/ (Go + cgo -> libkvm.so), web/ (React/pnpm).
    nanokvm-pro-src = {
      url = "github:sipeed/NanoKVM-Pro/8d0557b400e20d18590b780df3b7faddb2a5588c";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , ...
    }@inputs:
    let
      # This firmware only targets aarch64-linux, but the flake is meant to be
      # driven (cross-built) from an x86_64-linux dev box. We therefore key
      # outputs off the *build/dev* system and construct an aarch64 cross set
      # (pkgsCross) inside each system's package set.
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      # ------------------------------------------------------------------
      # Release identity for the OTA / web-update system (see docs/updates.md).
      #
      # `version` is read from the tracked ./VERSION file (first whitespace-
      # delimited token). It is stamped into /kvmapp/version in the image and
      # into the update manifest; the web UI offers an update when a published
      # manifest's version is semver-greater than the device's. CI overwrites
      # ./VERSION with the git tag (e.g. `v2.0.0` -> `2.0.0`) before building.
      #
      # `updateBaseUrl` is baked into NanoKVM-Server so its "update" button pulls
      # from OUR GitHub Releases instead of Sipeed's CDN. `releases/latest/
      # download` always resolves to the newest release's assets.
      # >>> SET OWNER/REPO to the repo that hosts the Releases. <<<
      # ------------------------------------------------------------------
      version =
        let m = builtins.match "[[:space:]]*([^[:space:]]+).*" (builtins.readFile ./VERSION);
        in if m == null then "0.0.0-dev" else builtins.head m;
      updateBaseUrl = "https://github.com/OWNER/REPO/releases/latest/download";
    in
    flake-utils.lib.eachSystem supportedSystems (
      localSystem:
      let
        pkgs = import nixpkgs { system = localSystem; };

        # Cross package set: aarch64, glibc (rootfs is Ubuntu 22.04 arm64).
        # When the dev box is already aarch64-linux this is a no-op native set.
        # Stock aarch64 GCC is sufficient (NO exotic toolchain, unlike the
        # SG2002/T-Head RISC-V case). See pkgs/toolchain.nix for the
        # 4.19-kernel / boot GCC-version caveats.
        crossPkgs =
          if localSystem == "aarch64-linux"
          then pkgs
          else pkgs.pkgsCross.aarch64-multiplatform;

        # Shared arguments handed to every derivation file.
        callArgs = {
          inherit pkgs crossPkgs inputs;
          inherit (inputs)
            maix_ax620e_sdk
            maix_ax620e_sdk_kernel
            maix_ax620e_sdk_msp
            nanokvm-pro-src;
        };

        callPkg = path: extra: import path (callArgs // extra);

        # ---- individual component derivations ----
        toolchain = callPkg ./pkgs/toolchain.nix { };

        axera-libs = callPkg ./pkgs/axera-libs.nix { };
        ax-ko-blobs = callPkg ./pkgs/ax-ko-blobs.nix { };

        # Whole AX630C boot chain (SPL/DDR-init + ATF + OP-TEE + U-Boot), one
        # shared from-source build; the boot-* selectors below expose subsets.
        boot = callPkg ./pkgs/boot.nix { };
        # SD debug variant of the whole boot chain: identical build, but the
        # console of EVERY stage (SPL/bl1 + ATF bl31 + OP-TEE bl32 + U-Boot bl33)
        # is redirected from UART0 (ttyS0, hidden pads) to UART1 (ttyS1 =
        # 0x4881000, the exposed header pin). Consumed ONLY by sd-image so the SD
        # boot is watchable end-to-end; the eMMC firmware-image keeps using `boot`
        # (UART0) unchanged. See pkgs/boot.nix `sdConsoleUart1`.
        boot-sd = callPkg ./pkgs/boot.nix { sdConsoleUart1 = true; };
        boot-fsbl = callPkg ./pkgs/boot-fsbl.nix { };
        boot-atf = callPkg ./pkgs/boot-atf.nix { };
        boot-optee = callPkg ./pkgs/boot-optee.nix { };
        boot-uboot = callPkg ./pkgs/boot-uboot.nix { };

        kernel = callPkg ./pkgs/kernel.nix { };

        # Board device tree, CORRECTLY built: the vendor reserved-memory /
        # bootargs patch (scripts/axera/patch_reserve_mem.sh) is applied before
        # `make dtbs`, so the atf/optee reserved regions and the real kernel
        # cmdline are present (the plain `make dtbs` in kernel.nix omits them).
        dtb = callPkg ./pkgs/dtb.nix { };

        # SD-card variant of the board dtb: identical reserved-memory patch, but
        # chosen/bootargs carries root=/dev/mmcblk1p2 (the card's ext4 rootfs =
        # MBR p2) instead of the eMMC's mmcblk0p17. Wired into sd-image below so
        # an SD boot mounts the CARD's rootfs, not eMMC. See pkgs/dtb.nix header
        # for why the DTB (not just the U-Boot BOOTARGS_SD env) must carry this.
        dtb-sd = callPkg ./pkgs/dtb.nix {
          rootDev = "/dev/mmcblk1p2";
          # SD debug build: redirect the kernel console from UART0 (ttyS0, hidden
          # pads) to UART1 (ttyS1 = 0x4881000, the accessible header pin) so the
          # SD boot is watchable end-to-end. eMMC dtb (above) stays on UART0.
          consoleTty = "ttyS1";
          earlyconAddr = "0x4881000";
          nameSuffix = "-sd";
        };

        # Vendor-format DTB PARTITION image (dtb/dtb_b, p12/p13): ax_gzip -9 the
        # patched dtb + the 1KB RSA-signed header, exactly as Makefile.kernel's
        # install_dtb does. Ready to `dd` / to feed build_image.py --dtb.
        dtb-slot-image = callPkg ./pkgs/dtb-fip.nix { inherit dtb; };

        # Same packaging, SD-root dtb -> the dtb.img placed on the microSD card.
        dtb-slot-image-sd = callPkg ./pkgs/dtb-fip.nix {
          dtb = dtb-sd;
          nameSuffix = "-sd";
        };

        # Vendor-format kernel PARTITION image for the A/B slot B (kernel_b/p15):
        # ax_gzip -9 the source-built Image + prepend the 1KB RSA-signed header,
        # exactly as kernel/linux/Makefile.kernel does. x86_64-linux only
        # (prebuilt ax_gzip codec). Ready to `dd` to /dev/mmcblk0p15.
        kernel-slot-image = callPkg ./pkgs/kernel-fip.nix { inherit kernel; };

        kvm-encoder = callPkg ./pkgs/kvm-encoder.nix { inherit axera-libs; };
        nanokvm-server = callPkg ./pkgs/nanokvm-server.nix { inherit kvm-encoder axera-libs updateBaseUrl; };
        nanokvm-web = callPkg ./pkgs/nanokvm-web.nix { };

        # Web-update package (tarball + manifest) our Releases serve; the device's
        # patched server downloads + applies this. See docs/updates.md.
        update-package = callPkg ./pkgs/update-package.nix {
          inherit nanokvm-server nanokvm-web kvm-encoder version;
        };

        # Pinned vendor release .axp (overlay base; 1.4 GB fixed-output fetch).
        base-axp = callPkg ./pkgs/base-axp.nix { };

        # Host-side USB flasher (axdl-cli, ciniml/axdl-rs): pushes a .axp onto an
        # AX630C in BootROM download mode. Built from source (cargo). This is a
        # HOST tool -- built for the local/dev system, not cross-compiled.
        axdl = callPkg ./pkgs/axdl.nix { };

        # Rootfs = vendor Ubuntu base (from base-axp) OVERLAID with our libkvm.so
        # + merged/depmod'd kernel modules (no-root debugfs surgery).
        rootfs = callPkg ./pkgs/rootfs.nix {
          inherit base-axp kvm-encoder kernel ax-ko-blobs
            nanokvm-server nanokvm-web version;
        };

        # Final flashable .axp: swap our dtb/kernel/u-boot/rootfs into a copy of
        # the base .axp (build_image.py's file-swap surface), pure zip rewrite.
        firmware-image = callPkg ./pkgs/image.nix {
          inherit base-axp boot kernel-slot-image dtb-slot-image rootfs;
        };

        # NON-DESTRUCTIVE microSD boot image (dd-able .img): boots the whole
        # from-source stack from an SD/TF card via the AX620E BootROM's FAT SD
        # path, leaving eMMC untouched (pull the card to revert). MBR/FAT32+ext4;
        # the SD-variant SPL (boot/bl1/sd) now fits its 50K slot -- see boot.nix.
        sd-image = callPkg ./pkgs/sd-image.nix {
          inherit kernel-slot-image rootfs;
          # Use the UART1-console boot chain (SPL/ATF/OP-TEE/U-Boot all redirected
          # to ttyS1/0x4881000) so the SD boot is watchable on the exposed header
          # pin. eMMC firmware-image (pkgs/image.nix) still uses `boot` (UART0).
          boot = boot-sd;
          # Use the SD-root dtb (root=/dev/mmcblk1p2, console=ttyS1) as dtb.img.
          dtb-slot-image = dtb-slot-image-sd;
        };
      in
      {
        packages = {
          inherit
            toolchain
            axera-libs ax-ko-blobs
            boot boot-sd boot-fsbl boot-atf boot-optee boot-uboot
            kernel dtb dtb-sd dtb-slot-image dtb-slot-image-sd kernel-slot-image
            kvm-encoder nanokvm-server nanokvm-web update-package
            base-axp rootfs firmware-image sd-image
            axdl;

          # Top-level default = the flashable firmware image (currently a stub
          # that documents the 17-partition layout; see pkgs/image.nix).
          default = firmware-image;
        };

        # `nix run .#axdl -- --file result/*.axp --wait-for-device`
        apps.axdl = {
          type = "app";
          program = "${axdl}/bin/axdl-cli";
        };

        devShells.default = callPkg ./pkgs/devshell.nix { inherit toolchain axdl; };

        # Formatter for `nix fmt`.
        formatter = pkgs.nixpkgs-fmt;
      }
    );
}
