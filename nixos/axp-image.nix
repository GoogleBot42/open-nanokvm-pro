{ pkgs
, lib ? pkgs.lib
, project
, version
, boot # pkgs/boot.nix -- the whole from-source boot chain + the FDL agents
, uboot-env # pkgs/uboot-env.nix
, logo # pkgs/logo.nix
, mkBootfs # kernel Image -> pkgs/bootfs.nix (/boot AND the boot payload)
, atf-mainline # pkgs/atf-mainline.nix -- mainline TF-A BL31, signed
, uboot-mainline # pkgs/uboot-mainline.nix -- mainline U-Boot BL33, signed
, dtbSlotImage # the signed mainline dtb partition image
, artifacts # nixos/lib/appliance-artifacts.nix
, mkKernel # initrd cpio -> the appliance kernel
, mkSlotImage # kernel -> its signed partition image
, ...
}:

# ===========================================================================
# The NanoKVM-Pro NixOS `.axp` -- every stored partition, assembled.
#
# This is the board-specific half of the image builder; the container itself is
# nixos/lib/make-axp-image.nix. It is a FUNCTION of the system closure, called
# from inside the module system by nixos/image-axp.nix, which is what makes
# `system.build.axpImage` possible without a module-system cycle.
#
# Nothing here comes out of the vendor `.axp`. `pkgs/image.nix` -- the shipping
# 4.19 `firmware-image` -- rewrites members inside Sipeed's release bundle and
# therefore keeps five vendor members. This one keeps none: the boot chain, the
# environment, the logo, the /boot filesystem, the kernel, the dtb and the
# rootfs are all built here.
#
# WHAT IS NOT FROM SOURCE. Two host-side download agents, FDL1 and FDL2, ride
# in the bundle but are never stored on the eMMC: the flasher pushes them into
# the BootROM's RAM to get a programmer running. pkgs/boot.nix builds both from
# the SDK sources, so even those are ours. The vendor bundle also carries
# `eip_ax620e.bin`, a closed Axera download helper -- it is NOT in this image,
# because axdl-rs never looks at it (only `Type=CODE` images are written, and
# the FDLs are found by their `name` attribute).
#
# A/B SLOTS, and why nothing here is slot-specific. Every A/B pair in the
# vendor bundle is BYTE-IDENTICAL -- kernel, dtb, OP-TEE, U-Boot and ATF alike,
# verified by hashing the members of the v1.0.15 release. The 1 KB signed
# header pkgs/slot-image.nix builds carries no slot field; which slot an image
# belongs to is decided entirely by the partition it is written to and by the
# `bootsystem` variable plus the A/B slot register. So slot A and slot B get
# the same image here, and the packer asserts that they do.
# ===========================================================================

{ toplevel
, initialRamdisk
, initrdFile
, rootDevice
, variant ? "emmc"
}:

let
  parts = import ./emmc-partitions.nix { inherit lib; };

  initrd = artifacts.mkInitrd { inherit initialRamdisk initrdFile; };
  rootfs = artifacts.mkRootfs { inherit toplevel initrd version variant rootDevice; };

  kernel = mkKernel initrd;
  kernelSlotImage = mkSlotImage kernel;

  bootImg = f: "${boot}/images/${f}";

  # #89 rung 3: the boot chain above the SPL is MAINLINE. `atf` and `uboot`
  # (and their twins, which are byte-identical as always) carry mainline TF-A
  # 2.15 with our plat/axera/ax630c and mainline U-Boot 2026.07 with our board
  # port -- both signed and axgzip'd into exactly the container the SPL reads.
  # The vendor-derived U-Boot survives only where the board already has one:
  # slot B of a device promoted in place, as the automatic fallback. A flash
  # of this image has no vendor bootloader anywhere on it.
  atfImg = "${atf-mainline}/images/atf_bl31_mainline_signed.bin";
  ubootImg = "${uboot-mainline}/images/u-boot_mainline_signed.bin";

  # partition name -> the member the manifest points at. `rawSize` is the size
  # the partition actually has to hold, for members whose stored form is
  # smaller than what the device unpacks (the Android-sparse rootfs).
  partitionImages = {
    spl = { member = "spl_${project}_signed.bin"; file = bootImg "spl_${project}_signed.bin"; };
    ddrinit = { member = "ddrinit_${project}_signed.bin"; file = bootImg "ddrinit_${project}_signed.bin"; };
    atf = { member = "atf_bl31_mainline_signed.bin"; file = atfImg; };
    atf_b = { member = "atf_b_bl31_mainline_signed.bin"; file = atfImg; };
    uboot = { member = "u-boot_mainline_signed.bin"; file = ubootImg; };
    uboot_b = { member = "u-boot_b_mainline_signed.bin"; file = ubootImg; };
    env = { member = "uboot_env.bin"; file = "${uboot-env}"; };
    logo = { member = "logo.bmp"; file = "${logo}"; };
    logo_b = { member = "logo_b.bmp"; file = "${logo}"; };
    optee = { member = "optee_signed.bin"; file = bootImg "optee_signed.bin"; };
    optee_b = { member = "optee_b_signed.bin"; file = bootImg "optee_signed.bin"; };
    dtb = { member = "${project}_signed.dtb"; file = "${dtbSlotImage}/${project}_mainline_signed.dtb"; };
    dtb_b = { member = "${project}_b_signed.dtb"; file = "${dtbSlotImage}/${project}_mainline_signed.dtb"; };
    kernel = { member = "kernel.bin"; file = "${kernelSlotImage}/kernel_b.bin"; };
    kernel_b = { member = "kernel_b.bin"; file = "${kernelSlotImage}/kernel_b.bin"; };
    boot = { member = "bootfs.fat32"; file = "${mkBootfs "${kernel}/Image"}"; };
    rootfs = { member = "nixos_rootfs_sparse.ext4"; file = "${rootfs}/ubuntu_rootfs_sparse.ext4"; };
  };

  # The vendor's write order, kept: `spl` goes LAST, so an interrupted flash
  # leaves a board that falls into AXDL rather than one whose first-stage
  # loader runs with nothing behind it.
  imgOrder = [
    "env"
    "ddrinit"
    "atf"
    "atf_b"
    "uboot"
    "uboot_b"
    "logo"
    "logo_b"
    "optee"
    "optee_b"
    "dtb"
    "dtb_b"
    "kernel"
    "kernel_b"
    "boot"
    "rootfs"
    "spl"
  ];

  # Host-side download agents. `name` is load-bearing: axdl-rs finds FDL1 and
  # FDL2 by the `name` attribute, not by <Type> or <ID>, and requires their
  # <Block> to carry NO id so it resolves to an absolute RAM address. The two
  # addresses are the vendor manifest's.
  downloadAgents = [
    {
      id = "FDL1";
      type = "FDL1";
      flag = 3;
      base = "0x3000000";
      member = "fdl_${project}_signed.bin";
      file = bootImg "fdl_${project}_signed.bin";
    }
    {
      id = "FDL2";
      type = "FDL2";
      flag = 3;
      base = "0x5C000000";
      member = "fdl2_signed.bin";
      file = bootImg "fdl2_signed.bin";
    }
  ];

  axp = import ./lib/make-axp-image.nix {
    inherit pkgs lib parts project partitionImages downloadAgents imgOrder;
    projectVersion = "open-nanokvm-pro ${version} (nixos appliance)";
    pname = "nanokvm-pro-nixos-firmware-image";
    inherit version;
    artifact = "${project}-nixos.axp";
    slotPairs = [
      { a = "kernel"; b = "kernel_b"; }
      { a = "dtb"; b = "dtb_b"; }
      { a = "optee"; b = "optee_b"; }
      { a = "atf"; b = "atf_b"; }
      { a = "uboot"; b = "uboot_b"; }
      { a = "logo"; b = "logo_b"; }
    ];
    signedMembers = [ "spl" "ddrinit" "atf" "atf_b" "uboot" "uboot_b" "optee" "optee_b" "dtb" "dtb_b" "kernel" "kernel_b" ];
    notes = ''
      NanoKVM-Pro NixOS appliance firmware (.axp) -- built from scratch (#78/#26).

      There is NO vendor bundle behind this image. Every partition it stores was
      built by this flake:

        spl      spl_${project}_signed.bin   pkgs/boot.nix
        ddrinit  ddrinit_${project}_signed.bin              pkgs/boot.nix
        atf/atf_b       MAINLINE TF-A 2.15 bl31, signed     pkgs/atf-mainline.nix
        uboot/uboot_b   MAINLINE U-Boot 2026.07 bl33        pkgs/uboot-mainline.nix
        env             U-Boot's own default env + a delta  pkgs/uboot-env.nix
        logo/logo_b     800x480 24-bpp BMP                  pkgs/logo.nix
        optee/optee_b   OP-TEE bl32, signed                 pkgs/boot.nix
        dtb/dtb_b       mainline DT from dts/               pkgs/dtb-mainline.nix
        kernel/kernel_b mainline Linux + NixOS stage 1      pkgs/kernel-mainline.nix
        boot            FAT32 /boot + extlinux + Image+dtb  pkgs/bootfs.nix
        rootfs          NixOS appliance ext4 (sparse)       nixos/appliance.nix

      THE BOOT CHAIN IS MAINLINE ABOVE THE SPL (#89 rung 3). Axera's bl1
      loads BL31 and BL33 by compile-time byte offset and jumps; from BL31 on,
      everything is upstream plus this repo's patches. The kernel is loaded by
      `sysboot` from /boot/extlinux/extlinux.conf, so `kernel`/`dtb` are a
      rescue copy rather than the boot path -- U-Boot never reads them.
      OP-TEE stays only because this SPL build hangs without a BL32 it can
      verify; nothing running on the board uses it.

      Flash-time only, never stored on the eMMC: FDL1 and FDL2, the download
      agents the flasher pushes into BootROM RAM -- also from pkgs/boot.nix.

        nix run .#axdl -- --file <this file> --wait-for-device

      FIRST BOOT: stage 1 fsck's and grows the rootfs to p17, the appliance
      derives its MAC and hostname from the SoC UID, and sshd comes up with
      root's password `sipeed`. Read docs/flashing-and-recovery.md before
      flashing: this OVERWRITES the vendor system, and the only way back is
      AXDL with a vendor .axp.
    '';
  };
in
axp
