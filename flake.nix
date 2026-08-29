{
  description = "Self-built open firmware for the Sipeed NanoKVM-Pro (Axera AX630C): boot chain, kernel, and app layer from source; Axera's redistributable media libraries and ax_*.ko modules pinned as binary inputs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # SECOND nixpkgs pin, used ONLY by the pure-Nix rootfs scaffold
    # (nixos/rootfs.nix, issue #26). It is deliberately older than the main
    # pin: systemd declares a hard kernel floor and from v258 on that floor is
    # 5.4, while this board is locked to a from-source Linux 4.19.125 by the
    # ax_*.ko vermagic contract. nixos-24.11 ships systemd 256, the newest
    # release whose systemd still lists 4.19 as above its RECOMMENDED
    # baseline. Do not bump this without reading docs/nixos-rootfs.md.
    nixpkgs-rootfs.url = "github:NixOS/nixpkgs/nixos-24.11";

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
      # The firmware targets aarch64-linux but must be built from an
      # x86_64-linux dev box: the vendor's ax_gzip partition packer is an
      # x86-64-only static ELF (pkgs/boot.nix), so every flashable output is
      # x86_64-only. The cross set below handles the aarch64 target.
      supportedSystems = [ "x86_64-linux" ];

      # Release identity for the OTA / web-update system (docs/updates.md).
      # `version` comes from ./VERSION (first token) — the single source of
      # truth that `tools/release` tags from — and is stamped into
      # /kvmapp/version and the update manifest. `updateBaseUrl` is baked into
      # NanoKVM-Server so its update check pulls from our releases instead of
      # Sipeed's CDN. Releases are hosted on the public GitHub downstream
      # mirror (the Gitea source of truth is Tailscale-only, unreachable from
      # devices); `releases/latest/download/<asset>` always resolves to the
      # newest release's assets.
      version =
        let m = builtins.match "[[:space:]]*([^[:space:]]+).*" (builtins.readFile ./VERSION);
        in if m == null then "0.0.0-dev" else builtins.head m;
      updateBaseUrl = "https://github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download";
      # The preview/alpha channel (web-UI "preview updates" toggle). GitHub's
      # `latest` alias excludes prereleases, so alphas ride a ROLLING release
      # on the fixed `preview` tag instead (assets clobbered on every cut) --
      # a release-asset namespace is flat, so the vendor's derived
      # `<stable>/preview` sub-path can never work on GitHub. docs/updates.md.
      previewUpdateBaseUrl = "https://github.com/GoogleBot42/open-nanokvm-pro/releases/download/preview";
    in
    flake-utils.lib.eachSystem supportedSystems (
      localSystem:
      let
        pkgs = import nixpkgs { system = localSystem; };

        # aarch64/glibc cross set (the rootfs is Ubuntu 22.04 arm64).
        crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;

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
        boot-fsbl = callPkg ./pkgs/boot-fsbl.nix { inherit boot; };
        boot-atf = callPkg ./pkgs/boot-atf.nix { inherit boot; };
        boot-optee = callPkg ./pkgs/boot-optee.nix { inherit boot; };
        boot-uboot = callPkg ./pkgs/boot-uboot.nix { inherit boot; };

        # Embedded kernel initramfs (static busybox + e2fsck from nixpkgs, the
        # vendor /init script kept verbatim). Baked into the kernel Image.
        initramfs = callPkg ./pkgs/initramfs.nix { };

        kernel = callPkg ./pkgs/kernel.nix { inherit initramfs; };

        # NOTE (#49, resolved 2026-08-30): there is deliberately NO CMA kernel
        # variant. CONFIG_CMA/CONFIG_DMA_CMA are vermagic-invisible but ABI-
        # BREAKING for the vendor ax_*.ko blobs -- DMA_CMA adds `cma_area` to
        # struct device (include/linux/device.h) and CMA renumbers the
        # migratetype enum / resizes struct zone freelists -- proven on device:
        # both CMA kernels (16M and 0-reserve) die pre-init on slot B while the
        # identical non-CMA kernel boots there. The open VC8000E driver gets its
        # coherent pools from dma_declare_coherent_memory() over a CMM-tail
        # carveout instead (pkgs/vc8000-vcmd/ax630c_vcmd_glue.c), which runs on
        # the SHIPPING kernel. Full record: docs/vcmd-cma-unblock.md.

        # Open VC8000E VCMD command-engine driver (eswin EIC7X), ported
        # out-of-tree to the 4.19 kernel -- the kernel half of the blob-free
        # encode-submission path (issue #44). See pkgs/vc8000-vcmd.nix.
        vc8000-vcmd = callPkg ./pkgs/vc8000-vcmd.nix { };

        # Board dtb with the vendor reserved-memory / bootargs patch applied
        # (a plain `make dtbs` would omit it -- see pkgs/dtb.nix). The SD-root
        # dtb variant is built internally by pkgs/sd-image.nix.
        dtb = callPkg ./pkgs/dtb.nix { };

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

        # Signed kernel_b partition image carrying the CMA variant (issue #49) --
        # the ONE reversible flash that unblocks the open VC8000E VCMD driver.
        # Flash to /dev/mmcblk0p15 (slot B), boot slot B, roll back by booting
        # slot A. Same DTB as stock (no DTB change needed). See docs/vcmd-cma-unblock.md.
        # Vendor-MPI capture default. The blob-free raw-ioctl backend ships
        # alpha-only for now: flip `openCapture = true` here for a preview-channel
        # cut (as v2.1.0-alpha.1 did), and flip back before the next stable.
        kvm-encoder = callPkg ./pkgs/kvm-encoder.nix { inherit axera-libs; };
        # Same libkvm.so with the blob-free capture backend selected. Not used
        # by any image (flip the flag above for that) -- it exists so the open
        # path is built and type-checked on demand:
        #   nix build .#kvm-encoder-open -L
        kvm-encoder-open = callPkg ./pkgs/kvm-encoder.nix { inherit axera-libs; openCapture = true; };
        # Host-side 1080p byte-identity proof for the open backend's parametric
        # geometry (#17). See pkgs/kvm-encoder-geom-test.nix.
        kvm-encoder-geom-test = callPkg ./pkgs/kvm-encoder-geom-test.nix { };
        nanokvm-server = callPkg ./pkgs/nanokvm-server.nix { inherit kvm-encoder axera-libs updateBaseUrl previewUpdateBaseUrl; };
        nanokvm-web = callPkg ./pkgs/nanokvm-web.nix { };

        # Mini-display status daemon (pure Python + build-time-generated fonts;
        # the display kernel modules are part of `kernel` -- all from source).
        nanokvm-display = callPkg ./pkgs/nanokvm-display.nix { };

        # ISP dummy-sensor library, built from SDK source (#30). The
        # closed-capture backend dlopens it; replaces the vendor's prebuilt
        # /opt/lib copy in the shipped rootfs and the OTA payload.
        libsns-dummy = callPkg ./pkgs/libsns-dummy.nix { inherit axera-libs; };

        # Full-firmware OTA package (tarball + manifest) served from our
        # Releases: rootfs overlay (app/web/libkvm/modules) + A/B partition
        # images (kernel/dtb/boot chain). See docs/updates.md.
        update-package = callPkg ./pkgs/update-package.nix {
          inherit nanokvm-server nanokvm-web kvm-encoder nanokvm-display
            libsns-dummy version kernel boot dtb-slot-image kernel-slot-image;
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
            nanokvm-server nanokvm-web nanokvm-display libsns-dummy version;
        };

        # Pure-Nix rootfs (issue #26) -- a NixOS system closure packed into a
        # rootless ext4, replacing the vendor Ubuntu base. SCAFFOLD: it builds,
        # it has never booted. Evaluated against the SEPARATE nixpkgs-rootfs
        # pin (systemd ceiling); see nixos/rootfs.nix + docs/nixos-rootfs.md.
        nixos-rootfs = callPkg ./nixos/rootfs.nix {
          nixpkgsRootfs = inputs.nixpkgs-rootfs;
          inherit axera-libs ax-ko-blobs kernel kvm-encoder
            nanokvm-server nanokvm-web nanokvm-display libsns-dummy version;
        };

        # Final flashable .axp: our dtb/kernel/boot-chain/rootfs member-swapped
        # into a copy of the base .axp (pure zip rewrite).
        firmware-image = callPkg ./pkgs/image.nix {
          inherit base-axp boot kernel-slot-image dtb-slot-image rootfs;
        };

        # Non-destructive microSD boot image (dd-able .img): boots the whole
        # from-source stack from a card, eMMC untouched. Byte-matched to the
        # official v1.0.15 SD image; builds its own UART0 boot chain + SD-root
        # dtb internally (it takes the shared callArgs). See pkgs/sd-image.nix.
        sd-image = callPkg ./pkgs/sd-image.nix {
          inherit kernel-slot-image rootfs;
        };
      in
      {
        packages = {
          inherit
            toolchain
            axera-libs ax-ko-blobs
            boot boot-fsbl boot-atf boot-optee boot-uboot
            initramfs kernel vc8000-vcmd dtb dtb-slot-image
            kernel-slot-image
            kvm-encoder kvm-encoder-open kvm-encoder-geom-test
            nanokvm-server nanokvm-web nanokvm-display libsns-dummy
            update-package
            base-axp rootfs nixos-rootfs firmware-image sd-image
            axdl;

          default = firmware-image;
        };

        # Cheap, hardware-free regression gates.
        #   nix build .#checks.x86_64-linux.open-capture-geometry -L
        checks = {
          open-capture-geometry = kvm-encoder-geom-test;
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
