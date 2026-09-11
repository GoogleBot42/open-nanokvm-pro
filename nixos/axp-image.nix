{ pkgs
, lib ? pkgs.lib
, project
, version
, boot # pkgs/boot.nix -- built from the SDK for its two FDL agents alone
, uboot-env # pkgs/uboot-env.nix
, mkBootfs # /boot payload dir -> pkgs/bootfs.nix
, atf-mainline # pkgs/atf-mainline.nix -- mainline TF-A BL31, signed
, uboot-mainline # pkgs/uboot-mainline.nix -- mainline U-Boot BL33, signed
, spl-minimal # pkgs/spl-minimal.nix -- the SPL rebuilt for this layout
, gpt-image # pkgs/gpt-image.nix -- the generated GPT (primary + alternate)
, artifacts # nixos/lib/appliance-artifacts.nix
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
# NOTHING HERE COMES OUT OF THE VENDOR `.axp`, and there is no vendor bundle to
# swap members into any more (#97). The SPL, BL31, BL33, the environment, the
# GPT, the /boot filesystem and the rootfs are all built by this flake.
#
# WHAT IS NOT FROM SOURCE. Two host-side download agents, FDL1 and FDL2, ride
# in the bundle but are never stored on the eMMC: the flasher pushes them into
# the BootROM's RAM to get a programmer running. pkgs/boot.nix builds both from
# the SDK sources, so even those are ours. The vendor bundle also carries
# `eip_ax620e.bin`, a closed Axera download helper -- it is NOT in this image,
# because axdl-rs never looks at it (only `Type=CODE` images are written, and
# the FDLs are found by their `name` attribute).
#
# THERE ARE NO A/B TWINS (#89 rung 4). The vendor map's pairs were always
# byte-identical -- verified by hashing the members of the v1.0.15 release --
# and the slot register only ever chose between two copies of one image. One
# copy is stored now, and a U-Boot candidate is tried through the one-shot
# chainload slot instead (docs/flashing-and-recovery.md).
# ===========================================================================

{ toplevel
, kernelImage
, configurationLimit
, timeout
, dtbName
, rootDevice
, variant ? "emmc"
}:

let
  # The SPL is COMPILED for this layout's byte offsets, so the two are one
  # artefact: a layout change is an SPL rebuild (#89 rung 4).
  parts = import ./emmc-partitions.nix { inherit lib; };
  layoutName = parts.layoutName;

  bootDir = artifacts.mkBootDir {
    inherit toplevel configurationLimit timeout dtbName;
  };
  rootfs = artifacts.mkRootfs { inherit toplevel bootDir version variant rootDevice; };

  bootImg = f: "${boot}/images/${f}";

  # THE BOOT CHAIN. Mainline TF-A 2.15 (plat/axera/ax630c) in `atf`, mainline
  # U-Boot 2026.07 (our board port) in `uboot`, behind the blob-free SPL
  # rebuilt for this layout -- and the kernel loaded by `sysboot` off
  # /boot/extlinux/extlinux.conf, so there is no `kernel` or `dtb` partition
  # at all. The vendor-fork TF-A 2.7 / U-Boot 2020.04 alternative is gone
  # (#97); a flashed image's fallback is the `bootcount` rollback, not a
  # second bootloader.
  atfImg = "${atf-mainline}/images/atf_bl31_mainline_signed.bin";
  ubootImg = "${uboot-mainline}/images/u-boot_mainline_signed.bin";
  splImg = "${spl-minimal}/images/spl_${project}_signed.bin";

  bootfs = mkBootfs bootDir;

  # Member names say which chain is inside, so a bundle can be identified from
  # its own file list.
  sfx = "_mainline";

  chainName = "MAINLINE TF-A 2.15";
  ubootName = "MAINLINE U-Boot 2026.07";
  bootfsName = "ext4 /boot + the NixOS extlinux tree  pkgs/bootfs.nix";

  # partition name -> the member the manifest points at. `rawSize` is the size
  # the partition actually has to hold, for members whose stored form is
  # smaller than what the device unpacks (the Android-sparse rootfs).
  # One entry per partition in the layout.
  allPartitionImages = {
    spl = { member = "spl${sfx}_${project}_signed.bin"; file = splImg; };
    # The two GPT structures. They are not partitions in any other sense --
    # `gpt` is the 1 MiB the protective MBR, header and entry array live in at
    # the front of `disk`, and `gptalt` is the last 32 KiB of the device, whose
    # final 16896 bytes are the backup array and the alternate header. The
    # flasher writes whole partitions at a base, which is the only reason the
    # second one is expressed as a padded 32 KiB image.
    gpt = { member = "gpt_primary.bin"; file = "${gpt-image}/gpt-primary.bin"; };
    gptalt = { member = "gpt_alternate.bin"; file = "${gpt-image}/gpt-alt-member.bin"; };
    atf = { member = "atf${sfx}_bl31_signed.bin"; file = atfImg; };
    uboot = { member = "u-boot${sfx}_signed.bin"; file = ubootImg; };
    env = { member = "uboot_env.bin"; file = "${uboot-env}"; };
    boot = { member = "bootfs.ext4"; file = "${bootfs}"; };
    rootfs = { member = "nixos_rootfs_sparse.ext4"; file = "${rootfs}/ubuntu_rootfs_sparse.ext4"; };
  };

  partNames = map (p: p.name) parts.parts;
  partitionImages = lib.getAttrs partNames allPartitionImages;

  # The vendor's write order, kept: `spl` goes LAST, so an interrupted flash
  # leaves a board that falls into AXDL rather than one whose first-stage
  # loader runs with nothing behind it, and `env` goes FIRST. Everything
  # between keeps on-disk order -- which, for the vendor layout, reproduces
  # the vendor manifest's order exactly.
  imgOrder = [ "env" ]
    ++ (lib.filter (n: n != "spl" && n != "env") partNames)
    ++ [ "spl" ];

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
    pname = "nanokvm-pro-nixos-firmware-image-mainline";
    inherit version;
    artifact = "${project}-nixos${sfx}.axp";
    # No A/B twins in this layout, so no pair to assert identical.
    slotPairs = [ ];
    signedMembers = lib.filter parts.has [ "spl" "atf" "uboot" ];
    notes = ''
      NanoKVM-Pro NixOS appliance firmware (.axp) -- built from scratch (#78/#26).

      There is NO vendor bundle behind this image. Every partition it stores was
      built by this flake. LAYOUT: ${layoutName}, ${
        toString (lib.length parts.parts)} partitions.

      ${parts.table}
        spl             SPL rebuilt for THIS layout         pkgs/spl-minimal.nix
        atf             ${chainName} bl31, signed
        uboot           ${ubootName} bl33, signed
        env             U-Boot's own default env + a delta  pkgs/uboot-env.nix
        boot            ${bootfsName}
        rootfs          NixOS appliance ext4 (sparse)       nixos/appliance.nix

      BL31 and BL33 are upstream TF-A and U-Boot plus this repo's patches, and
      the kernel is loaded with `sysboot` off /boot/extlinux/extlinux.conf --
      so there is no `kernel`, `dtb`, `optee`, `logo` or `ddrinit` partition
      and no `_b` twin. The SPL is compiled for exactly these offsets, which is
      why the layout and the first-stage loader are one artefact.

      A flashed image has no second bootloader behind it. What replaces that is
      the `bootcount` rollback: four failed boot attempts and U-Boot's
      `altbootcmd` boots /boot/extlinux/extlinux-fallback.conf instead
      (docs/nixos-rootfs.md 4b).

      Flash-time only, never stored on the eMMC: FDL1 and FDL2, the download
      agents the flasher pushes into BootROM RAM -- from pkgs/boot.nix.

        nix run .#axdl -- --file <this file> --wait-for-device

      FIRST BOOT: stage 1 fsck's and grows the rootfs to ${parts.root.device},
      the appliance derives its MAC and hostname from the SoC UID, and sshd
      comes up with root's password `sipeed`. Read
      docs/flashing-and-recovery.md before flashing: this OVERWRITES whatever
      is on the eMMC, and the only way back is another AXDL flash.
    '';
  };
in
axp
