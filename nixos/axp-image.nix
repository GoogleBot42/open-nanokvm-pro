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
, bootChain ? "vendor" # "vendor" | "mainline" -- see below
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

  # WHICH BOOT CHAIN THE IMAGE STORES, and why the default is still the
  # vendor-derived one (#89 rung 3).
  #
  # `bootChain = "mainline"` puts mainline TF-A 2.15 (plat/axera/ax630c) in
  # `atf`/`atf_b` and mainline U-Boot 2026.07 (our board port) in
  # `uboot`/`uboot_b`, and moves the boot payload into `boot` (p16) as
  # extlinux.conf + Image + dtb -- which is what mainline U-Boot's `bootcmd`
  # reads. `kernel`/`dtb` stay packed as a rescue copy that nothing loads.
  #
  # It is NOT the default, because the chain does not yet boot reliably. On
  # hardware (2026-09-09) it boots and reaches a running NixOS, and it also
  # fails roughly two boots in three, always the same way: an eMMC data
  # transfer times out, and this board cannot recover from that. Multi-block
  # transfers do not work on its Cadence SD4HC (#91), so it runs with
  # `cdns,single-block-only`; a timed-out single-block read is cleared by
  # re-initialising the card, and re-initialisation walks
  # `mmc_select_mode_and_width()` down to modes that need 3.3 V I/O, which a
  # fixed 1.8 V vqmmc rail cannot supply. The card ends with no mode and no
  # block device. In an in-place promotion the SPL's A/B fallback catches
  # that -- slot B still holds the vendor-derived U-Boot -- but a FLASHED
  # image has the same U-Boot in both slots and no fallback at all, which is
  # why this flag exists and why it is off. #91 is the gate.
  mainlineChain = bootChain == "mainline";

  atfImg =
    if mainlineChain
    then "${atf-mainline}/images/atf_bl31_mainline_signed.bin"
    else bootImg "atf_bl31_signed.bin";
  ubootImg =
    if mainlineChain
    then "${uboot-mainline}/images/u-boot_mainline_signed.bin"
    else bootImg "u-boot_signed.bin";

  # The extlinux payload rides in /boot only when the loader that reads it is
  # the one being installed; under the vendor chain U-Boot loads the kernel
  # from the signed `kernel` partition by byte offset and 51 MB of unread
  # Image on p16 would be dead weight.
  bootfs = if mainlineChain then mkBootfs "${kernel}/Image" else mkBootfs null;

  # Member names say which chain is inside, so a bundle can be identified from
  # its own file list.
  sfx = lib.optionalString mainlineChain "_mainline";

  chainName = if mainlineChain then "MAINLINE TF-A 2.15" else "vendor-fork TF-A 2.7";
  ubootName = if mainlineChain then "MAINLINE U-Boot 2026.07" else "vendor-fork U-Boot 2020.04";
  bootfsName =
    if mainlineChain
    then "FAT32 /boot + extlinux + Image + dtb  pkgs/bootfs.nix"
    else "FAT32 /boot                           pkgs/bootfs.nix";

  # partition name -> the member the manifest points at. `rawSize` is the size
  # the partition actually has to hold, for members whose stored form is
  # smaller than what the device unpacks (the Android-sparse rootfs).
  partitionImages = {
    spl = { member = "spl_${project}_signed.bin"; file = bootImg "spl_${project}_signed.bin"; };
    ddrinit = { member = "ddrinit_${project}_signed.bin"; file = bootImg "ddrinit_${project}_signed.bin"; };
    atf = { member = "atf${sfx}_bl31_signed.bin"; file = atfImg; };
    atf_b = { member = "atf_b${sfx}_bl31_signed.bin"; file = atfImg; };
    uboot = { member = "u-boot${sfx}_signed.bin"; file = ubootImg; };
    uboot_b = { member = "u-boot_b${sfx}_signed.bin"; file = ubootImg; };
    env = { member = "uboot_env.bin"; file = "${uboot-env}"; };
    logo = { member = "logo.bmp"; file = "${logo}"; };
    logo_b = { member = "logo_b.bmp"; file = "${logo}"; };
    optee = { member = "optee_signed.bin"; file = bootImg "optee_signed.bin"; };
    optee_b = { member = "optee_b_signed.bin"; file = bootImg "optee_signed.bin"; };
    dtb = { member = "${project}_signed.dtb"; file = "${dtbSlotImage}/${project}_mainline_signed.dtb"; };
    dtb_b = { member = "${project}_b_signed.dtb"; file = "${dtbSlotImage}/${project}_mainline_signed.dtb"; };
    kernel = { member = "kernel.bin"; file = "${kernelSlotImage}/kernel_b.bin"; };
    kernel_b = { member = "kernel_b.bin"; file = "${kernelSlotImage}/kernel_b.bin"; };
    boot = { member = "bootfs.fat32"; file = "${bootfs}"; };
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
    pname = "nanokvm-pro-nixos-firmware-image${lib.optionalString mainlineChain "-mainline"}";
    inherit version;
    artifact = "${project}-nixos${sfx}.axp";
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
        atf/atf_b       ${chainName} bl31, signed
        uboot/uboot_b   ${ubootName} bl33, signed
        env             U-Boot's own default env + a delta  pkgs/uboot-env.nix
        logo/logo_b     800x480 24-bpp BMP                  pkgs/logo.nix
        optee/optee_b   OP-TEE bl32, signed                 pkgs/boot.nix
        dtb/dtb_b       mainline DT from dts/               pkgs/dtb-mainline.nix
        kernel/kernel_b mainline Linux + NixOS stage 1      pkgs/kernel-mainline.nix
        boot            ${bootfsName}
        rootfs          NixOS appliance ext4 (sparse)       nixos/appliance.nix

      BOOT CHAIN: ${bootChain}. The mainline variant (`bootChain =
      "mainline"`) replaces BL31 and BL33 with upstream TF-A and U-Boot plus
      this repo's patches and boots the kernel with `sysboot` off
      /boot/extlinux/extlinux.conf; it is not the default, because that chain
      still loses roughly two boots in three to #91 and a flashed image has
      no other bootloader to fall back to. nixos/axp-image.nix explains it.
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
