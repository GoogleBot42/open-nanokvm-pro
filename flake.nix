{
  description = "Self-built open firmware for the Sipeed NanoKVM-Pro (Axera AX630C): boot chain, kernel, and app layer from source; Axera's redistributable media libraries and ax_*.ko modules pinned as binary inputs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Upstream Sipeed / Axera source repos, pinned by commit (`flake = false`
    # plain trees). No release tags exist upstream; these are main-branch
    # commits matching the on-device V3.0.0_20250319 SDK.

    # Boot chain (bl1/SPL, TF-A 2.7, OP-TEE 3.21, U-Boot 2020.04), the vendor
    # `build/` make system, rootfs scripts, and image tools.
    maix_ax620e_sdk = {
      url = "github:sipeed/maix_ax620e_sdk/45ebcc32dfcfade1f8cfd1d8f70da67b86ea2902";
      flake = false;
    };

    # Linux 4.19.125 + board DTS + open lt6911_manage.c. Also carries the
    # prebuilt ax_*.ko media modules (pinned via pkgs/ax-ko-blobs.nix).
    maix_ax620e_sdk_kernel = {
      url = "github:sipeed/maix_ax620e_sdk_kernel/ee5d79590ba85c1fd08eed587ba13c6f98da862c";
      flake = false;
    };

    # Prebuilt Axera userspace media libraries (libax_*.so, BSD-3) + matching
    # V3.0.0 headers, under out/arm64_glibc/{lib,include}.
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
      # The firmware targets aarch64-linux but is normally cross-built from an
      # x86_64-linux dev box; outputs are keyed off the build system and use an
      # aarch64 cross set internally.
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Release identity for the OTA / web-update system (docs/updates.md).
      # `version` comes from ./VERSION (first token; CI overwrites the file with
      # the release tag) and is stamped into /kvmapp/version and the update
      # manifest. `updateBaseUrl` is baked into NanoKVM-Server so its update
      # check pulls from our GitHub Releases instead of Sipeed's CDN.
      version =
        let m = builtins.match "[[:space:]]*([^[:space:]]+).*" (builtins.readFile ./VERSION);
        in if m == null then "0.0.0-dev" else builtins.head m;
      updateBaseUrl = "https://github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download";
    in
    flake-utils.lib.eachSystem supportedSystems (
      localSystem:
      let
        pkgs = import nixpkgs { system = localSystem; };

        # aarch64/glibc cross set (the rootfs is Ubuntu 22.04 arm64); a no-op
        # native set when the dev box is already aarch64-linux.
        crossPkgs =
          if localSystem == "aarch64-linux"
          then pkgs
          else pkgs.pkgsCross.aarch64-multiplatform;

        project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

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

        toolchain = callPkg ./pkgs/toolchain.nix { };

        axera-libs = callPkg ./pkgs/axera-libs.nix { };
        ax-ko-blobs = callPkg ./pkgs/ax-ko-blobs.nix { };

        # Whole AX630C boot chain (SPL/DDR-init + ATF + OP-TEE + U-Boot) from
        # source; the boot-* selectors below expose subsets of its images.
        boot = callPkg ./pkgs/boot.nix { };
        # SD debug variant: every stage's console redirected from UART0 (hidden
        # pads) to UART1 (exposed header pin). Consumed only by sd-image.
        boot-sd = callPkg ./pkgs/boot.nix { sdConsoleUart1 = true; };
        boot-fsbl = callPkg ./pkgs/boot-fsbl.nix { inherit boot; };
        boot-atf = callPkg ./pkgs/boot-atf.nix { inherit boot; };
        boot-optee = callPkg ./pkgs/boot-optee.nix { inherit boot; };
        boot-uboot = callPkg ./pkgs/boot-uboot.nix { inherit boot; };

        kernel = callPkg ./pkgs/kernel.nix { };

        # Board dtb with the vendor reserved-memory / bootargs patch applied
        # (a plain `make dtbs` would omit it -- see pkgs/dtb.nix).
        dtb = callPkg ./pkgs/dtb.nix { };
        # SD variant: root on the card (mmcblk1p2) and console on UART1, so an
        # SD boot mounts the card's rootfs and is watchable on the header pin.
        dtb-sd = callPkg ./pkgs/dtb.nix {
          rootDev = "/dev/mmcblk1p2";
          consoleTty = "ttyS1";
          earlyconAddr = "0x4881000";
          nameSuffix = "-sd";
        };

        # Vendor-format signed partition images (ax_gzip -9 + 1KB signed
        # header), ready to `dd` / feed to the .axp; see pkgs/slot-image.nix.
        dtbSlotArgs = {
          payload = "${dtb}/dtb/${project}.dtb";
          pname = "nanokvm-pro-dtb-slot-image";
          version = "ax630c-dtb";
          artifact = "${project}_signed.dtb";
          partSize = 1024 * 1024;
          loadAddr = "0x40001000";
          title = "dtb partition image (reserved-memory patched)";
          flashNotes = ''
            TARGET partition: dtb / dtb_b  (A/B), 1M each (p12 / p13)

            CONTENT: the board dtb carries the vendor reserved-memory regions
              atf_memreserved  = <0x0 0x40040000 0x0 0x40000>   (256K)
              optee_memserved  = <0x0 0x44200000 0x0 0x2000000> (32M)
            plus the real kernel bootargs. Built from pkgs/dtb.nix.'';
        };
        dtb-slot-image = callPkg ./pkgs/slot-image.nix dtbSlotArgs;
        dtb-slot-image-sd = callPkg ./pkgs/slot-image.nix (dtbSlotArgs // {
          payload = "${dtb-sd}/dtb/${project}.dtb";
          nameSuffix = "-sd";
        });

        kernel-slot-image = callPkg ./pkgs/slot-image.nix {
          payload = "${kernel}/Image";
          pname = "nanokvm-pro-kernel-slot-image";
          version = "ax630c-kernel-b";
          artifact = "kernel_b.bin";
          partSize = 64 * 1024 * 1024;
          loadAddr = "0x40200000";
          title = "kernel partition image (slot B)";
          flashNotes = ''
            TARGET partition: kernel_b  (A/B slot B), 64M
              eMMC device   : /dev/mmcblk0p15   (p14 = slot A / stock kernel)

            Flash (reversible slot-B test):
              dd if=kernel_b.bin of=/dev/mmcblk0p15 bs=1M conv=fsync'';
        };

        kvm-encoder = callPkg ./pkgs/kvm-encoder.nix { inherit axera-libs; };
        nanokvm-server = callPkg ./pkgs/nanokvm-server.nix { inherit kvm-encoder axera-libs updateBaseUrl; };
        nanokvm-web = callPkg ./pkgs/nanokvm-web.nix { };

        # Full-firmware OTA package (tarball + manifest) served from our
        # Releases: rootfs overlay (app/web/libkvm/modules) + A/B partition
        # images (kernel/dtb/boot chain). See docs/updates.md.
        update-package = callPkg ./pkgs/update-package.nix {
          inherit nanokvm-server nanokvm-web kvm-encoder version
            kernel boot dtb-slot-image kernel-slot-image;
        };

        # Pinned vendor release .axp (overlay base; 1.4 GB fixed-output fetch).
        base-axp = callPkg ./pkgs/base-axp.nix { };

        # Host-side USB flasher (axdl-cli): pushes a .axp onto an AX630C in
        # BootROM download mode. Built for the local system, not cross-compiled.
        axdl = callPkg ./pkgs/axdl.nix { };

        # Rootfs: vendor Ubuntu base (from base-axp) overlaid with our server,
        # web UI, libkvm.so, and merged/depmod'd kernel modules.
        rootfs = callPkg ./pkgs/rootfs.nix {
          inherit base-axp kvm-encoder kernel
            nanokvm-server nanokvm-web version;
        };

        # Final flashable .axp: our dtb/kernel/boot-chain/rootfs member-swapped
        # into a copy of the base .axp (pure zip rewrite).
        firmware-image = callPkg ./pkgs/image.nix {
          inherit base-axp boot kernel-slot-image dtb-slot-image rootfs;
        };

        # Non-destructive microSD boot image (dd-able .img): boots the whole
        # from-source stack from a card, eMMC untouched. Uses the UART1-console
        # boot chain + SD-root dtb so the boot is watchable on the header pin.
        sd-image = callPkg ./pkgs/sd-image.nix {
          inherit kernel-slot-image rootfs;
          boot = boot-sd;
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

          default = firmware-image;
        };

        # `nix run .#axdl -- --file result/*.axp --wait-for-device`
        apps.axdl = {
          type = "app";
          program = "${axdl}/bin/axdl-cli";
        };

        devShells.default = callPkg ./pkgs/devshell.nix { inherit toolchain axdl; };

        formatter = pkgs.nixpkgs-fmt;
      }
    );
}
