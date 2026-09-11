{
  description = "Self-built open firmware for the Sipeed NanoKVM-Pro (Axera AX630C): boot chain, kernel, and app layer from source; Axera's redistributable media libraries and ax_*.ko modules pinned as binary inputs";

  inputs = {
    # ONE nixpkgs pin. There used to be a second, older one (nixos-24.11) for
    # the NixOS rootfs alone, because systemd's declared minimum kernel had
    # risen to 5.4 and then 5.10 while the ax_*.ko vermagic contract held this
    # board on Linux 4.19.125. Both halves of that argument are gone -- the
    # image has carried no vendor kernel module since #54, and the appliance
    # boots pkgs/kernel-mainline (7.1.x) since #78 -- so the appliance is back
    # on this pin and `nixpkgs-rootfs` is retired. docs/nixos-rootfs.md.
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

    # App layer (GPL-3.0): server/ (Go + cgo -> libkvm.so). The web UI is our
    # own fork in ./web (web/FORK.md) and no longer comes from this input.
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

      perSystem = flake-utils.lib.eachSystem supportedSystems (
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

        # The three stored partitions the shipping 4.19 `firmware-image` still
        # inherits from Sipeed's release bundle, built from source instead --
        # they are what makes `.#nixos-firmware-image` a from-scratch .axp
        # rather than a member swap.
        # The stored environment is generated from the MAINLINE U-Boot's own
        # compiled-in default (#89 rung 3), so p5 and p7 cannot disagree.
        uboot-env = callPkg ./pkgs/uboot-env.nix { uboot = uboot-mainline; };
        logo = callPkg ./pkgs/logo.nix { };

        # /boot, and since rung 3 the whole boot payload: mainline U-Boot's
        # bootcmd runs `sysboot ... /extlinux/extlinux.conf` off this
        # partition, so the kernel and the device tree ride in it rather than
        # in the signed `kernel`/`dtb` partitions the vendor chain loaded by
        # byte offset. `extlinux-fallback.conf` starts as a copy: the only
        # known-good generation is the one being installed.
        # The kernel + dtb + both extlinux configs, with the kernel and dtb
        # CONTENT-ADDRESSED (#86) so `extlinux.conf` and
        # `extlinux-fallback.conf` can name two different kernels and a kernel
        # update gets the same automatic rollback a generation switch has.
        mkBootPayload = kernelImage: callPkg ./pkgs/boot-payload.nix {
          inherit kernelImage;
          dtb = "${dtb-mainline}/dtb/ax630c-nanokvm-pro.dtb";
        };
        # `null` = /boot with `ver` alone, which is what the vendor-derived
        # chain wants: it loads the kernel from the signed `kernel` partition
        # and never looks here.
        #
        # SIZE AND FILESYSTEM COME FROM THE LAYOUT (#89 rung 4): 128 MiB of
        # FAT32 under the vendor 17-partition map, 275 MiB of ext4 under the
        # minimal six. nixos/lib/emmc-layout.nix is the single definition.
        mkBootfsFor = layoutName: kernelImage:
          let l = import ./nixos/emmc-partitions.nix {
            inherit (pkgs) lib;
            layout = layoutName;
          };
          in
          callPkg ./pkgs/bootfs.nix {
            inherit version;
            size = l.bootfs.size;
            fsType = if layoutName == "vendor" then "vfat" else "ext4";
            payloadDir =
              if kernelImage == null then null
              else "${mkBootPayload kernelImage}/boot";
          };
        mkBootfs = mkBootfsFor "minimal";
        bootfs = mkBootfs "${kernel-mainline-appliance}/Image";
        # The same payload as a first-class output: `.#system-bundle` ships it,
        # the checks read its NAMES file, and a hardware run can copy one file
        # onto /boot from it.
        boot-payload = mkBootPayload "${kernel-mainline-appliance}/Image";
        boot-fsbl = callPkg ./pkgs/boot-fsbl.nix { inherit boot; };
        boot-atf = callPkg ./pkgs/boot-atf.nix { inherit boot; };
        boot-optee = callPkg ./pkgs/boot-optee.nix { inherit boot; };
        boot-uboot = callPkg ./pkgs/boot-uboot.nix { inherit boot; };

        # Mainline TF-A BL31 with our own plat/axera/ax630c (#89 rung 0),
        # signed for the `atf` partition exactly like the vendor BL31 above.
        # Untested on hardware -- see docs/mainline-port.md 11.9.
        atf-mainline = callPkg ./pkgs/atf-mainline.nix { inherit boot-atf; };

        # The same BL31 plus seven milestone-bit writes (#89 rung 1). A
        # debugging tool, never a shipped image: it writes the A/B slot
        # register. See pkgs/atf-mainline.nix.
        atf-mainline-debug = callPkg ./pkgs/atf-mainline.nix {
          inherit boot-atf;
          debugMilestones = true;
        };

        # Embedded kernel initramfs (static busybox + e2fsck from nixpkgs, the
        # vendor /init script kept verbatim). Baked into the kernel Image.
        initramfs = callPkg ./pkgs/initramfs.nix { };

        kernel = callPkg ./pkgs/kernel.nix { inherit initramfs; };

        # Bring-up initramfs for the mainline kernel (#75): one static init
        # whose only job is to leave evidence that userspace ran, in places the
        # vendor system can read back on the next boot. Distinct from
        # `initramfs` above, which is the shipping 4.19 one.
        initramfsMainline = callPkg ./pkgs/initramfs-mainline.nix { };

        # Mainline kernel for epic #26 (#74 scaffolding, #75 first boot). Built
        # from the kernel.org tree our nixpkgs pin carries, with our own config
        # fragment, our own drivers grafted in, and our own device tree (dts/,
        # compiled by pkgs/dtb-mainline.nix). Additive: no image, rootfs or
        # update output references it, and the 4.19 outputs are untouched.
        #
        # This is the BRING-UP variant: it carries the #75 evidence initramfs
        # and reboots itself. The appliance variant, which carries the NixOS
        # stage-1 initrd instead, is defined below the appliance itself --
        # a mainline kernel is the only place an initrd can live on this board
        # (U-Boot passes none and no partition holds one).
        kernel-mainline = callPkg ./pkgs/kernel-mainline.nix {
          inherit initramfsMainline;
        };

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

        # Deblob probe (#56, epic #55): one open module exporting the 26 symbols
        # ax_proton imports from ax_npu/ax_gdc/ax_ivps/ax_vpp as logging stubs,
        # so a capture run can PROVE those four blobs are dead weight. Not part
        # of any image -- built and loaded by hand alongside
        # pkgs/rootfs/ax-load-drv.stub.sh. See pkgs/ax-stub.nix.
        ax-stub = callPkg ./pkgs/ax-stub.nix { };

        # Open V4L2 capture stack (epic #55, M1/M2). Clean-room drivers written
        # from docs/reference/deblob-scope/specs/ that replace the vendor
        # ax_mipi_rx (CSI-2 subdev) and ax_proton bypass/IFE-WDMA path (capture
        # video node). First-draft compiling modules; on-hardware bring-up is the
        # serial slot-B A/B follow-on. See pkgs/open-vin-{csi2,capture}.nix.
        open-vin-csi2 = callPkg ./pkgs/open-vin-csi2.nix { };
        open-vin-capture = callPkg ./pkgs/open-vin-capture.nix { };

        # Open VC8000E userspace submitter -- userspace half of the blob-free
        # encoder (#45). Stage A (ewl_probe) drives the full VCMD cmdbuf
        # lifecycle from userspace and is device-proven. See pkgs/vcenc-ewl.nix.
        vcenc-ewl = callPkg ./pkgs/vcenc-ewl.nix { };

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

        # Mainline device tree, compiled from dts/ in this repo (#74).
        dtb-mainline = callPkg ./pkgs/dtb-mainline.nix { inherit kernel-mainline; };

        # The mainline pair, packaged for the SAME slot-B partitions the vendor
        # kernel uses -- that is the whole point: #75's first boot test is a
        # reversible slot-B flash, rolled back by booting slot A.
        kernel-mainline-slot-image = callPkg ./pkgs/slot-image.nix {
          payload = "${kernel-mainline}/Image";
          pname = "nanokvm-pro-kernel-mainline-slot-image";
          version = "ax630c-kernel-mainline-b";
          artifact = "kernel_b.bin";
          partSize = 64 * 1024 * 1024;
          loadAddr = "0x40200000";
          nameSuffix = "-mainline";
          title = "mainline kernel partition image (slot B, #74/#75)";
          flashNotes = ''
            TARGET partition: kernel_b  (A/B slot B), 64M
              eMMC device   : /dev/mmcblk0p15   (p14 = slot A / shipped 4.19 kernel)

            Carries the ax630c watchdog driver (#75), so U-Boot's 30 s
            wdt0 arm-before-booti no longer resets it, and a bring-up
            initramfs whose /init leaves boot evidence in the A/B slot
            register and in reserved DRAM. There is no storage driver yet
            (#76), so it reaches that initramfs and nothing further, then
            reboots itself. Flash only together with the matching mainline
            dtb -- the reserved-memory layout and the watchdog's syscon
            phandle both live there.

            Flash (reversible slot-B test):
              dd if=kernel_b.bin of=/dev/mmcblk0p15 bs=1M conv=fsync

            Read the result back from slot A afterwards:
              devmem 0x02390024                      # milestone bits 12-15
              dd if=/dev/mem bs=4096 skip=$((0x480e8000/4096)) count=8 | strings'';
        };

        dtb-mainline-slot-image = callPkg ./pkgs/slot-image.nix {
          payload = "${dtb-mainline}/dtb/ax630c-nanokvm-pro.dtb";
          pname = "nanokvm-pro-dtb-mainline-slot-image";
          version = "ax630c-dtb-mainline";
          artifact = "${project}_mainline_signed.dtb";
          partSize = 1024 * 1024;
          loadAddr = "0x40001000";
          nameSuffix = "-mainline";
          title = "mainline dtb partition image (#74)";
          flashNotes = ''
            TARGET partition: dtb_b  (A/B slot B), 1M (p13)

            Built from dts/ in this repo, with 4 KiB of FDT slack so U-Boot's
            fdt_chosen() can write the env bootargs without hanging.

            Flash (reversible slot-B test):
              dd if=${project}_mainline_signed.dtb of=/dev/mmcblk0p13 bs=1M conv=fsync'';
        };

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
        # FULLY blob-free libkvm: open capture + the open VC8000E encoder
        # (#25; fixed-QP32, H.264-only, 1080p-only). Links ZERO vendor libs;
        # needs ax630c_venc_vcmd.ko on the device instead of ax_venc/ax_jenc:
        #   nix build .#kvm-encoder-openvenc -L
        kvm-encoder-openvenc = callPkg ./pkgs/kvm-encoder.nix {
          inherit axera-libs; openCapture = true; openVenc = true;
        };
        # #55 M3 (#60): open encoder fed by the OPEN V4L2 capture driver
        # (pkgs/open-vin-capture) -- zero vendor capture modules on the device:
        #   nix build .#kvm-encoder-v4l2 -L
        kvm-encoder-v4l2 = callPkg ./pkgs/kvm-encoder.nix {
          inherit axera-libs; openCapture = true; openVenc = true; v4l2Capture = true;
        };
        # #50 diagnostic probe: openvenc with AX_SYS_Init restored (links
        # libax_sys only) -- isolates whether libax_sys's kernel-side OSAL
        # registration is what protects ax_proton's exception-exit path.
        kvm-encoder-openvenc-axsysprobe = callPkg ./pkgs/kvm-encoder.nix {
          inherit axera-libs; openCapture = true; openVenc = true; axsysProbe = true;
        };
        # Host-side 1080p byte-identity proof for the open backend's parametric
        # geometry (#17). See pkgs/kvm-encoder-geom-test.nix.
        kvm-encoder-geom-test = callPkg ./pkgs/kvm-encoder-geom-test.nix { };
        # Host-side geometry-law proof for the open ENCODER (#17): 17 golden
        # vendor vectors + 1080p template identity. See pkgs/vcenc-geom-test.nix.
        vcenc-geom-test = callPkg ./pkgs/vcenc-geom-test.nix { };
        # Host-side proof of the from-scratch rate controller (#46): vendor
        # trajectory replay + closed-loop simulation. See pkgs/vcenc-rc-test.nix.
        vcenc-rc-test = callPkg ./pkgs/vcenc-rc-test.nix { };
        # The 4.19 image's server. Its OTA is RETIRED (#86, 2026-09-10): no
        # release publishes an overlay payload any more, so its update check
        # finds nothing, and install() refuses rather than falling back to the
        # vendor's dpkg installer. A vendor-layout device moves forward by an
        # AXDL reflash of `.#nixos-firmware-image-mainline`.
        nanokvm-server = callPkg ./pkgs/nanokvm-server.nix {
          inherit kvm-encoder axera-libs updateBaseUrl previewUpdateBaseUrl;
          updateMode = "retired";
        };

        # ATX power/reset/LED tool for the mainline stack (#81): resolves a
        # line by its dts/ gpio-line-names entry over libgpiod v2, and the
        # request programs the pad mux. Replaces the legacy-sysfs export unit,
        # the devmem pad poke and the server's per-press pinmux re-assert.
        nanokvm-gpio = callPkg ./pkgs/nanokvm-gpio.nix { };

        # Same server source, ATX lines driven through nanokvm-gpio instead of
        # /sys/class/gpio -- global GPIO numbers are not stable on mainline, so
        # the NixOS appliance gets this build and the shipped 4.19 image keeps
        # the sysfs one above (which stays byte-identical).
        # The appliance also polls a DIFFERENT CHANNEL and applies a different
        # payload (#86): `nanokvm_pro_sys_latest.json` and a system bundle,
        # installed by `nanokvm-update`, instead of the 4.19 rootfs overlay.
        # One release carries both, and the manifest filename is the whole of
        # the separation -- a device is never offered a payload its installer
        # cannot apply.
        nanokvm-server-libgpiod = callPkg ./pkgs/nanokvm-server.nix {
          inherit kvm-encoder axera-libs updateBaseUrl previewUpdateBaseUrl nanokvm-gpio;
          gpioBackend = "libgpiod";
          updateMode = "bundle";
        };

        nanokvm-web = callPkg ./pkgs/nanokvm-web.nix { inherit version; };

        # Mini-display status daemon (pure Python + build-time-generated fonts;
        # the display kernel modules are part of `kernel` -- all from source).
        nanokvm-display = callPkg ./pkgs/nanokvm-display.nix { };

        # ISP dummy-sensor library, built from SDK source (#30). The
        # closed-capture backend dlopens it; replaces the vendor's prebuilt
        # /opt/lib copy in the shipped rootfs and the OTA payload.
        libsns-dummy = callPkg ./pkgs/libsns-dummy.nix { inherit axera-libs; };

        # `update-package` -- the 4.19 rootfs-overlay OTA -- is GONE (#86,
        # 2026-09-10). The product is the mainline NixOS appliance and its
        # update is `.#system-bundle` (a whole store closure), which no Ubuntu
        # rootfs can apply; keeping a second payload format alive for devices
        # that do not exist was cost with no benefit. A vendor-layout board is
        # reflashed over AXDL. docs/updates.md, "History".

        # Pinned vendor release .axp (overlay base; 1.4 GB fixed-output fetch).
        base-axp = callPkg ./pkgs/base-axp.nix { };

        # Host-side USB flasher (axdl-cli): pushes a .axp onto an AX630C in
        # BootROM download mode. Built for the local system, not cross-compiled.
        axdl = callPkg ./pkgs/axdl.nix { };

        # Rootfs: vendor Ubuntu base (from base-axp) overlaid with our server,
        # web UI, libkvm.so, and merged/depmod'd kernel modules.
        # Clean-room EDID set for the LT6911UXC front-end (from source; distinct
        # per-mode identity + edid-decode --check clean). See pkgs/edid.nix.
        edid = callPkg ./pkgs/edid.nix { };

        rootfs = callPkg ./pkgs/rootfs.nix {
          # Shipped video stack = fully open (#60): V4L2 libkvm over the open
          # capture drivers + open VCMD encoder; the loader insmods only those
          # three from-source modules. See pkgs/rootfs.nix step [5b7]/[5b7a].
          kvm-encoder = kvm-encoder-v4l2;
          inherit base-axp kernel vc8000-vcmd open-vin-csi2 open-vin-capture
            nanokvm-server nanokvm-web nanokvm-display libsns-dummy edid version;
        };

        # The NixOS appliance (#78) -- nixos/appliance.nix evaluated into a
        # system closure and packed into a rootless ext4, replacing the vendor
        # Ubuntu base. It boots the MAINLINE kernel with a NixOS initrd; the
        # vendor /init contract is gone. Same nixpkgs pin as everything else.
        #
        # Two variants, differing only in where root comes from:
        #   nixos-appliance      root = the eMMC rootfs partition (p17). What
        #                        ships, and what overwrites the vendor system.
        #   nixos-appliance-loop root = a rootfs IMAGE FILE dropped on p17 and
        #                        loop-mounted by stage 1. The REVERSIBLE
        #                        hardware test: nothing is overwritten, and
        #                        rolling back is `rm` plus a slot-B restore.
        nixosApplianceArgs = {
          # The SHIPPED video stack is fully open (#60): V4L2 libkvm over the
          # open capture drivers + open VCMD encoder. The server links the ABI
          # header only, so it keeps the plain kvm-encoder.
          kvm-encoder = kvm-encoder-v4l2;
          # The appliance runs the mainline stack, so it takes the libgpiod
          # server and ships nanokvm-gpio beside it (#81) -- global GPIO
          # numbers are not stable on mainline, so the sysfs build cannot come
          # here. The shipped 4.19 image keeps the sysfs one, byte-identical.
          nanokvm-server = nanokvm-server-libgpiod;
          inherit nanokvm-gpio nanokvm-web nanokvm-display version;
        };
        # The shipped variant also carries the .axp builder: nixos/image-axp.nix
        # defines `system.build.axpImage` from this configuration's own closure,
        # which is what `.#nixos-firmware-image` is.
        #
        # LAYOUT FOLLOWS THE CHAIN (#89 rung 4). The vendor chain's SPL is
        # compiled for the 17-partition map, so a system imaged with it must
        # have its root device, /boot and fw_env.config built for that map;
        # the mainline chain gets the six-partition minimal one. The two evals
        # therefore no longer share a rootfs closure.
        nixos-appliance = callPkg ./nixos/rootfs.nix (nixosApplianceArgs // {
          applianceModules = [
            ./nixos/image-axp.nix
            { nanokvm.emmcLayout = "vendor"; }
          ];
          imageBuilder = applianceAxpImage;
        });
        nixos-appliance-mainline-chain = callPkg ./nixos/rootfs.nix (nixosApplianceArgs // {
          applianceModules = [
            ./nixos/image-axp.nix
            { nanokvm.emmcLayout = "minimal"; }
          ];
          imageBuilder = applianceAxpImageMainline;
        });
        nixos-appliance-loop = callPkg ./nixos/rootfs.nix (nixosApplianceArgs // {
          variant = "loop-image";
          applianceModules = [ ./nixos/loop-test.nix ];
        });
        # The same loop-image test with the two identity fixes REVERTED to the
        # behaviour of the first hardware run -- the static `hostnamectl` call
        # and networkd's own DHCP client identifier. It exists to attribute a
        # failure, not to ship: run 3 boots this to prove the exit machinery
        # brings the board back on a boot known to reach the LAN, and run 4
        # boots the variant above so the two differ in exactly those two
        # properties. Stage 1 is byte-identical between them -- both changes are
        # stage-2 only -- so the two runs share one kernel and one slot-B flash,
        # and swapping runs is swapping the rootfs image file.
        nixos-appliance-loop-nofixes = callPkg ./nixos/rootfs.nix (nixosApplianceArgs // {
          variant = "loop-image-nofixes";
          applianceModules = [
            ./nixos/loop-test.nix
            {
              nanokvm.identity.useTransientHostname = false;
              nanokvm.dhcp.clientIdentifier = "duid";
            }
          ];
        });
        # Third variant: the same appliance retargeted at `qemu-system-aarch64
        # -M virt`, which is where the NixOS half of the boot is proven before
        # anything is written to the device. See nixos/qemu-test.nix.
        nixos-appliance-qemu = callPkg ./nixos/rootfs.nix (nixosApplianceArgs // {
          variant = "qemu";
          applianceModules = [ ./nixos/qemu-test.nix ];
        });

        # The mainline kernel with the appliance's stage-1 initrd baked into
        # the Image, and the slot-B pair that flashes it. One kernel build per
        # root variant, because the initrd differs.
        # Takes the initrd CPIO rather than the appliance derivation, so the
        # .axp builder can call it from inside the module system with the
        # initrd that configuration produces -- and land on the same store path
        # as `.#kernel-mainline-appliance` here.
        mkApplianceKernel = initrdCpio: variant:
          callPkg ./pkgs/kernel-mainline.nix {
            initramfsCpio = "${initrdCpio}";
            initramfsCompression = "ZSTD";
            inherit variant;
          };
        # THE MINIMAL-LAYOUT INITRD, and that is load-bearing (#89 rung 4).
        # Stage 1 mounts root BY DEVICE, so an initrd built for the vendor
        # layout looks for /dev/mmcblk0p17 -- which does not exist once the
        # layout changes. This kernel is what `.#bootfs` and therefore
        # `.#migrate-layout` put on /boot, so it has to be the one that knows
        # root is p6. The .axp builders take the initrd of the configuration
        # they are imaging, so they were never at risk.
        kernel-mainline-appliance =
          mkApplianceKernel nixos-appliance-mainline-chain.initrd "appliance";
        kernel-mainline-appliance-loop =
          mkApplianceKernel nixos-appliance-loop.initrd "appliance-loop";
        kernel-mainline-appliance-qemu =
          mkApplianceKernel nixos-appliance-qemu.initrd "appliance-qemu";

        # `nix run .#nixos-appliance-qemu-run` -- boots the appliance under
        # qemu-system-aarch64 on a throwaway copy of the rootfs image. The one
        # place the NixOS boot can be watched on a console, since the real
        # board has none.
        nixos-appliance-qemu-run = pkgs.writeShellApplication {
          name = "nanokvm-appliance-qemu";
          runtimeInputs = with pkgs; [ qemu coreutils e2fsprogs ];
          text = ''
            work=$(mktemp -d)
            trap 'rm -rf "$work"' EXIT
            cp ${nixos-appliance-qemu}/nixos_rootfs.ext4 "$work/root.img"
            chmod u+w "$work/root.img"
            # Room for the writes a first boot makes (machine-id, journal,
            # /etc). make-ext4-fs shrinks the image to its contents.
            truncate -s +512M "$work/root.img"
            resize2fs "$work/root.img" >/dev/null

            exec qemu-system-aarch64 \
              -M virt -cpu cortex-a53 -smp 2 -m 1024 -nographic \
              -kernel ${kernel-mainline-appliance-qemu}/Image \
              -append "console=ttyAMA0,115200 loglevel=8 root=/dev/vda rw panic=10" \
              -drive file="$work/root.img",format=raw,if=none,id=hd0 \
              -device virtio-blk-device,drive=hd0 \
              -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
              "$@"
          '';
        };

        mkApplianceSlotImage = kern: variant: callPkg ./pkgs/slot-image.nix {
          payload = "${kern}/Image";
          pname = "nanokvm-pro-kernel-mainline-${variant}-slot-image";
          version = "ax630c-kernel-mainline-${variant}-b";
          artifact = "kernel_b.bin";
          partSize = 64 * 1024 * 1024;
          loadAddr = "0x40200000";
          title = "mainline appliance kernel partition image (slot B, #78)";
          flashNotes = ''
            TARGET partition: kernel_b  (A/B slot B), 64M
              eMMC device   : /dev/mmcblk0p15   (p14 = slot A / shipped 4.19 kernel)

            Carries the NixOS stage-1 initrd inside the Image: U-Boot passes no
            initrd address and no partition holds one, so this is the only way
            an initrd reaches this board. Stage 1 mounts the root filesystem
            and switch_roots to /init on it -- there is no `init=` on the
            command line, because the command line comes from the U-Boot
            environment, not from the device tree.

            Flash together with the matching mainline dtb (p13). Reversible
            slot-B test:
              dd if=kernel_b.bin of=/dev/mmcblk0p15 bs=1M conv=fsync
          '';
        };
        kernel-mainline-appliance-slot-image =
          mkApplianceSlotImage kernel-mainline-appliance "appliance";
        kernel-mainline-appliance-loop-slot-image =
          mkApplianceSlotImage kernel-mainline-appliance-loop "appliance-loop";

        # ---- the NixOS appliance's .axp, built FROM SCRATCH (#78/#26) -------
        #
        # Not a member swap on Sipeed's bundle: nixos/lib/make-axp-image.nix
        # writes the manifest and the ZIP itself, and every partition it stores
        # comes from this flake. It is a FUNCTION of a system closure, called
        # from inside the module system by nixos/image-axp.nix -- so
        # `.#nixos-firmware-image` and
        # `.#nixosConfigurations.nanokvm-pro.config.system.build.axpImage` are
        # one derivation, and the image can never disagree with the system it
        # images.
        mkApplianceAxpImage = bootChain: import ./nixos/axp-image.nix {
          inherit bootChain;
          inherit pkgs project version boot uboot-env logo mkBootfsFor;
          inherit atf-mainline uboot-mainline spl-minimal gpt-image;
          dtbSlotImage = dtb-mainline-slot-image;
          artifacts = import ./nixos/lib/appliance-artifacts.nix {
            inherit pkgs;
            nixpkgs = inputs.nixpkgs;
          };
          mkKernel = initrd: mkApplianceKernel initrd "appliance";
          mkSlotImage = kern: mkApplianceSlotImage kern "appliance";
        };
        applianceAxpImage = mkApplianceAxpImage "vendor";
        applianceAxpImageMainline = mkApplianceAxpImage "mainline";

        # ---- the appliance's OTA artefact (#86) ----------------------------
        # The ONLY OTA artefact this project publishes.
        # It is a function of the SAME two things `.#bootfs` is built from --
        # the minimal-layout appliance closure and the kernel its initrd is
        # inside -- so a release cannot publish a bundle that disagrees with the
        # image flashed from the same commit.
        system-bundle = callPkg ./pkgs/system-bundle.nix {
          inherit version;
          bootPayload = boot-payload;
          toplevel = "${nixos-appliance-mainline-chain.eval.config.system.build.toplevel}";
        };

        nixos-firmware-image =
          nixos-appliance.eval.config.system.build.axpImage;

        # The same appliance, imaged with the MAINLINE boot chain: mainline
        # TF-A BL31 + mainline U-Boot in both slots, and the kernel loaded by
        # `sysboot` from /boot/extlinux/extlinux.conf (#89 rung 3). The rootfs
        # closure is identical to `.#nixos-firmware-image`'s -- only the boot
        # members and /boot differ. NOT for flashing yet: nixos/axp-image.nix
        # says why (#91), and an image whose two slots hold the same U-Boot
        # has no fallback when that U-Boot's payload read fails.
        nixos-firmware-image-mainline =
          nixos-appliance-mainline-chain.eval.config.system.build.axpImage;

        # Final flashable .axp: our dtb/kernel/boot-chain/rootfs member-swapped
        # into a copy of the base .axp (pure zip rewrite).
        firmware-image = callPkg ./pkgs/image.nix {
          inherit base-axp boot kernel-slot-image dtb-slot-image rootfs;
        };

        # ---- mainline U-Boot (#89 rung 0) ----------------------------------
        #
        # Upstream U-Boot 2026.07 plus a five-patch AX630C board port, wrapped
        # in the same axgzip + signed-header container the vendor's
        # u-boot_signed.bin uses, so it can be dd'd into `uboot_b` and boot-
        # tested from slot B. Additive: no image or update output references
        # it yet. docs/mainline-port.md 11.10.
        axSign = callPkg ./pkgs/ax-sign.nix { };
        uboot-mainline = callPkg ./pkgs/uboot-mainline.nix { inherit axSign; };

        # The #91 multi-block probe sequence, shared by the variants below.
        # `bmax` overrides the driver's b_max for exactly these two reads; the
        # count arguments of `mmc read` are hex, `bmax` is decimal.
        # It ends by re-initialising the card, so a failed transfer does not
        # decide whether the boot that follows can read its own payload.
        bmaxProbe =
          "mmc dev 0; echo MB-A-CMD18-2; setenv bmax 2;"
          + " mmc read 0x4a000000 0x4ae00 2;"
          + " echo MB-B-CMD18-64; setenv bmax 64;"
          + " mmc read 0x4a000000 0x4ae00 40;"
          + " setenv bmax 1; echo MB-C-REINIT; mmc dev 0; echo MB-END";

        # ---- the SPL, rebuilt for the minimal layout (#89 rung 4) ---------
        #
        # The one artefact the layout change cannot be made without: the SPL
        # finds BL31 and BL33 by compile-time byte offsets, so it is compiled
        # from the same nixos/lib/emmc-layout.nix list the kernel command line
        # and the .axp manifest come from. Writing it to p1 is the single
        # one-way step of the port -- a bad SPL means AXDL.
        gpt-image = callPkg ./pkgs/gpt-image.nix { };

        # BLOB-FREE since 2026-09-09 (#90): signed with an EMPTY firmware
        # member, so the closed EIP-130 crypto-engine firmware is absent from
        # the container entirely rather than spliced in at 0xCC00/0x2CC00.
        # Nothing documented said the BootROM would accept a header declaring
        # `fw_size = 0`; it does, proven on hardware across two warm reboots
        # and a cold power cycle. That was the last closed payload on the
        # eMMC image.
        spl-minimal = callPkg ./pkgs/spl-minimal.nix { };

        # The vendor-shaped container, WITH the closed firmware spliced in --
        # kept as the fallback a single `dd` away if a unit ever turns out to
        # need it. Not what any image stores.
        spl-minimal-eip = callPkg ./pkgs/spl-minimal.nix { withEip = true; };

        # The same image plus milestone writes through every board_init_r hook
        # U-Boot already calls, so a BL33 that dies before `preboot` still says
        # where. The sibling of `.#atf-mainline-debug`, and the build that
        # localised rung 2's first failure. Never ship it: it writes bits 12-20,
        # which are Linux's in the shipping assignment.
        uboot-mainline-debug = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          debugMilestones = true;
        };

        # The shipping image plus the pre-console capture, and nothing that
        # writes the slot register -- so a run that succeeds leaves the
        # register reading exactly as the shipping bit assignment says, while
        # a run that fails still leaves a full U-Boot log in reserved DRAM.
        # This is the variant to reach for on this board.
        uboot-mainline-console = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          consoleToBuffer = true;
        };

        # The SHIPPING image with its console redirected into the pre-console
        # buffer from board_late_init() on -- so `bootcmd`, `sysboot` and their
        # error messages are readable from the next boot. Nothing else differs
        # from `.#uboot-mainline`. A diagnostic; never flashed as the product.
        uboot-mainline-trace = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          traceBoot = true;
        };

        # The SHIPPING image with every console write ALSO copied into the
        # pre-console buffer. Unlike `-trace` it takes nothing away: serial
        # output and console input both stay live, so the boot behaves exactly
        # as the product does and the DRAM ring records what it printed.
        uboot-mainline-tee = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          teeConsole = true;
        };

        # The tee image plus a one-shot eMMC interrogation in `preboot`
        # (#89 rung 3b, data for #91): one open-ended CMD18 with the card's
        # own CMD13 state read before any CMD12 or controller reset, a
        # single-block read in MMC_HS and in HS200, and a forced re-init.
        # A diagnostic; never flashed as the product.
        uboot-mainline-probe = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          teeConsole = true;
          probeMmc = true;
        };

        # === the #91 multi-block measurement (2026-09-10) ==================
        # The probe image with a `preboot` that issues a 2-block and a
        # 64-block open-ended CMD18 and then hands the card back, so the
        # appliance still boots and can be asked what happened. Safe to
        # chainload: a candidate that cannot read its own payload is reset by
        # WDT0 into the production U-Boot on flash, and the DRAM ring the
        # answer lives in survives that reset.
        #
        # 64 blocks matters as well as 2: a 32 KiB transfer crosses the SDMA
        # boundary a 512-byte single block never reaches.
        uboot-mainline-probe-mb = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          teeConsole = true;
          probeMmc = true;
          probeTag = "-mb";
          probeCmds = bmaxProbe;
        };

        # The negative control for the #91 answer: the same probe with the
        # eMMC clock put back to the 50 MHz the tree carried before, which is
        # the one thing that changed. Both of its CMD18s are expected to fail.
        #
        # It ends in `reset` rather than booting. With the single-block cap
        # gone, a 50 MHz build cannot read its own payload either, and the
        # retry storm that follows would wrap the 8 KiB DRAM ring the answer
        # is written into. Resetting hands the board straight back to the
        # production U-Boot on flash, whose own pre-console output is a dozen
        # lines, so the probe's result survives to be read from Linux.
        uboot-mainline-probe-mb-50m = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          teeConsole = true;
          probeMmc = true;
          probeTag = "-mb-50m";
          probeCmds = bmaxProbe + "; reset";
          emmcMaxFreq = 50000000;
        };

        # The tee image plus the AX630C first-stage loader's own SD4HC read
        # path (#91): its init ladder, its HS400ES-at-200 MHz clock, its PHY
        # table and its single 32-bit SRS03 write, run from `preboot` against
        # the #91 four-read matrix and a 51 MiB timed read, then `mmc rescan`
        # and a normal boot so the answer can be read out of the pre-console
        # buffer. A diagnostic, and a CHAINLOAD candidate -- stage it with
        # `nanokvm-uboot-test`, never write it to the `uboot` partition.
        uboot-mainline-spldrv = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          teeConsole = true;
          splDrv = true;
        };

        # The shipping image with the branch out of save_boot_params turned
        # into a branch to itself: it arms WDT0 and then hangs, at the first
        # instruction U-Boot runs. The negative half of the #91 chainload
        # proof -- a candidate that never comes back must cost one unattended
        # boot cycle. Only ever staged in the test slot, never flashed.
        uboot-mainline-hangtest = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          hangTest = true;
        };

        # The MMU is never switched on, so the boot walks straight past rung
        # 2's mmu_setup() hang and exercises what the rung is actually for --
        # sdhci-cadence, part_cmdline, the environment, extlinux, booti. Slow,
        # a diagnostic, never a shipped image; carries the milestone writes.
        uboot-mainline-nommu = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          debugMilestones = true;
          dcacheOff = true;
        };

        # The in-place layout migration kit (#89 rung 4): the script plus every
        # image it writes, all derived from nixos/lib/emmc-layout.nix. Copied
        # to the board and run there; see pkgs/migrate-layout.nix.
        migrate-layout = callPkg ./pkgs/migrate-layout.nix {
          inherit atf-mainline uboot-mainline spl-minimal gpt-image uboot-env bootfs project;
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
            boot boot-fsbl boot-atf boot-optee boot-uboot atf-mainline
            atf-mainline-debug
            initramfs kernel vc8000-vcmd vcenc-ewl ax-stub dtb dtb-slot-image
            initramfsMainline kernel-mainline dtb-mainline
            kernel-mainline-slot-image dtb-mainline-slot-image
            kernel-mainline-appliance kernel-mainline-appliance-loop
            kernel-mainline-appliance-qemu
            kernel-mainline-appliance-slot-image
            kernel-mainline-appliance-loop-slot-image
            nixos-appliance-qemu nixos-appliance-qemu-run
            open-vin-csi2 open-vin-capture
            kernel-slot-image
            kvm-encoder kvm-encoder-open kvm-encoder-openvenc kvm-encoder-v4l2
            kvm-encoder-openvenc-axsysprobe kvm-encoder-geom-test
            vcenc-geom-test vcenc-rc-test
            nanokvm-server nanokvm-server-libgpiod nanokvm-gpio
            nanokvm-web nanokvm-display libsns-dummy
            base-axp rootfs nixos-appliance nixos-appliance-mainline-chain
            nixos-appliance-loop nixos-appliance-loop-nofixes
            uboot-env logo bootfs boot-payload system-bundle
            uboot-mainline uboot-mainline-debug uboot-mainline-console
            uboot-mainline-nommu uboot-mainline-trace uboot-mainline-tee uboot-mainline-probe
            uboot-mainline-spldrv uboot-mainline-hangtest
            uboot-mainline-probe-mb uboot-mainline-probe-mb-50m
            gpt-image spl-minimal spl-minimal-eip migrate-layout
            firmware-image nixos-firmware-image nixos-firmware-image-mainline sd-image
            edid axdl;

          default = firmware-image;
        };

        # Cheap, hardware-free regression gates.
        #   nix build .#checks.x86_64-linux.open-capture-geometry -L
        checks = {
          open-capture-geometry = kvm-encoder-geom-test;
          open-venc-geometry = vcenc-geom-test;
          open-venc-rc = vcenc-rc-test;
          # The mainline DT asserts its own boot contract (FDT slack, the
          # blkdevparts= clause, the ATF/OP-TEE reservations) -- #74.
          mainline-dtb = dtb-mainline;
          # Mainline TF-A BL31 for the AX630C: it builds, the ELF's entry and
          # link address are 0x40040000, the signed image fits the 256 KiB
          # `atf` partition, and its Axera header matches the vendor
          # atf_bl31_signed.bin field for field with both checksums
          # recomputed (#89).
          atf-mainline = atf-mainline.verify;
          # Mainline U-Boot (#89 rung 0): it links where the SPL jumps, the
          # signed image fits the `uboot` partition and carries the AX header
          # magic, the device tree reserves what belongs to other stages, and
          # the new blkdevparts= partition driver -- compiled from the shipped
          # source -- yields the same table nixos/emmc-partitions.nix does.
          uboot-mainline = callPkg ./pkgs/uboot-mainline-check.nix {
            inherit uboot-mainline;
          };
          # The GPT-at-a-base-LBA parser (patch 0023), RUN rather than read:
          # sandbox U-Boot against a faithful model of the eMMC (#89 rung 4).
          uboot-gpt = callPkg ./pkgs/uboot-gpt-test.nix {
            inherit uboot-mainline gpt-image;
          };
          # The eMMC partition map, parsed out of the blkdevparts= clause that
          # defines it, with the root/boot partition numbers and the U-Boot
          # environment offset asserted against the values docs record (#78).
          # Pure evaluation -- it builds a text file.
          # The from-scratch .axp, read back: one manifest, the partition table
          # against the blkdevparts= clause, every <Img> against what the host
          # flasher's parser requires, every member inside its partition, the
          # A/B pairs identical and the Axera signed headers intact (#78).
          nixos-axp-manifest = nixos-firmware-image.verify;
          # The flashable minimal-layout .axp and the in-place migration kit
          # must put the same boot chain on the eMMC (#94): the migration is
          # what this hardware has actually booted, so any byte the flashed
          # image would write differently is a byte nothing has ever proven.
          axp-migration-parity = callPkg ./pkgs/axp-migration-parity.nix {
            inherit nixos-firmware-image-mainline migrate-layout project;
          };
          # The #86 update loop, run for real against a fake root: apply a
          # bundle, check the profile advanced and the boot config names the
          # new generation AND its kernel, then collect and check the right
          # things survived -- including that gc REFUSES when it cannot know
          # the live set. Everything an update does except meeting hardware.
          nanokvm-updater-loop = callPkg ./nixos/lib/updater-test.nix { };
          # The policy wrapped around that loop (#86): the web UI's automatic-
          # updates checkbox gating the timer, the pending markers, and the
          # reboot that waits for an empty room -- including that an
          # unanswerable idle question fails CLOSED. A fake release host and a
          # fake idle route on loopback; everything else is the real scripts.
          nanokvm-update-idle = callPkg ./nixos/lib/update-idle-test.nix { };
          # The release artefact itself, read back: the manifest hash against
          # the tarball, closure.txt against the toplevel's real closure, and
          # the /boot payload against the kernel the bundle carries.
          nanokvm-system-bundle = callPkg ./pkgs/system-bundle-check.nix {
            inherit system-bundle version;
            bootPayload = boot-payload;
            toplevel = "${nixos-appliance-mainline-chain.eval.config.system.build.toplevel}";
          };
          emmc-partition-map =
            let
              l = import ./nixos/lib/emmc-layout.nix { inherit (pkgs) lib; };
              render = p: ''
                === ${p.layoutName} (${toString (pkgs.lib.length p.parts)} partitions)
                ${p.table}
                ${p.blkdevparts}
                fw_env.config: ${p.fwEnvConfig}'';
            in
            pkgs.writeText "emmc-partition-map" ''
              ${render l.vendor}
              ${render l.minimal}
            '';
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
    in
    perSystem // {
      # The appliance as a first-class NixOS system (#78), so it can be
      # inspected and switched with the ordinary tooling:
      #   nix build .#nixosConfigurations.nanokvm-pro.config.system.build.toplevel
      # It is built from the x86_64-linux instantiation because every flashable
      # output of this flake is (pkgs/boot.nix's packer is x86-64-only); the
      # SYSTEM it describes is aarch64-linux.
      #
      # `.#nanokvm-pro` IS THE MINIMAL-LAYOUT SYSTEM (#89 rung 4), because
      # that is what the board runs:
      #   nixos-rebuild switch --flake .#nanokvm-pro --target-host root@<dev>
      # `.#nanokvm-pro-vendor-layout` is the same appliance built for the
      # 17-partition map -- the system inside the AXDL recovery image.
      nixosConfigurations.nanokvm-pro =
        perSystem.packages.x86_64-linux.nixos-appliance-mainline-chain.eval;
      nixosConfigurations.nanokvm-pro-vendor-layout =
        perSystem.packages.x86_64-linux.nixos-appliance.eval;
      nixosConfigurations.nanokvm-pro-loop =
        perSystem.packages.x86_64-linux.nixos-appliance-loop.eval;
    };
}
