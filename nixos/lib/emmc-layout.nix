{ lib }:

# ===========================================================================
# THE eMMC LAYOUT. One definition, every consumer derived from it (#89 rung 4).
#
# This SoC's eMMC user area carries no on-disk partition table and cannot:
# the BootROM reads the SPL from byte 0, so LBA 0 (an MBR) and LBAs 1-33 (a
# GPT) are inside the first-stage loader. The table is therefore a STRING --
# `blkdevparts=mmcblk0:...` -- and both sides of the boot read it: mainline
# U-Boot through the `part_cmdline` driver (pkgs/uboot-mainline/patches/0004),
# Linux through CONFIG_CMDLINE_PARTITION.
#
# Until rung 4 that string lived in dts/ax630c-nanokvm-pro.dts and this file's
# predecessor PARSED it. That was the right shape while the layout was the
# vendor's and could not be changed; it is the wrong shape now, because the
# SPL's stage offsets are COMPILE-TIME constants (docs/mainline-port.md 11.2)
# and a layout change that misses them produces a first-stage loader that
# reads the wrong bytes and hangs, with no console to say so. So the list is
# here, in Nix, and SEVEN consumers are generated from it:
#
#   1. the `blkdevparts=` clause on the kernel command line (pkgs/extlinux.nix)
#   2. the same clause as U-Boot's CONFIG_CMDLINE_PARTITION_DEFAULT, plus
#      CONFIG_ENV_OFFSET/SIZE and the hex `bootpart` (pkgs/uboot-mainline.nix)
#   3. the .axp `<Partitions>` manifest (nixos/lib/make-axp-image.nix)
#   4. /etc/fw_env.config and the NixOS fileSystems (nixos/appliance.nix)
#   5. the SPL's *_HEADER_FLASH_BASE constants, as a generated makefile that
#      REPLACES the vendor's hand-written partition_ab.mak (pkgs/spl-minimal.nix)
#   6. the migration script's `dd seek=` offsets (tools/migrate-layout.sh)
#   7. the DT `chosen/bootargs` fallback clause, asserted equal below
#
# TWO LAYOUTS EXIST, and both are real.
#
#   `vendor`  the 17-partition A/B map the board shipped with and the one the
#             vendor boot chain requires (its SPL is compiled for it). It is
#             what `.#nixos-firmware-image` and `.#firmware-image` flash, and
#             therefore what an AXDL recovery puts back.
#   `minimal` six partitions, no twins, no ddrinit, no OP-TEE, no logo, no
#             kernel/dtb partitions -- extlinux carries those per generation.
#             `.#nixos-firmware-image-mainline` flashes it and tools/
#             migrate-layout.sh converts a running board to it in place.
#
# THE ROOTFS START IS THE INVARIANT. `minimal` lays its five boot-chain and
# /boot partitions inside exactly the span the vendor layout's p1-p16 occupied,
# so `rootfs` begins at the same byte (0x115C0000) in both. That is what makes
# the migration possible from a running system: the filesystem holding the
# script is never touched. The assertion at the bottom of this file is the
# thing that keeps it true.
# ===========================================================================

let
  units = { K = 1024; M = 1048576; G = 1073741824; };

  # "768K" -> 786432, "275M" -> 288358400, "-" -> null (fill the device)
  toBytes = spec:
    if spec == "-" then null
    else
      let
        unit = lib.substring (lib.stringLength spec - 1) 1 spec;
        num = lib.substring 0 (lib.stringLength spec - 1) spec;
      in
      if units ? ${unit} then (lib.toInt num) * units.${unit}
      else lib.toInt spec;

  hex = v: "0x${lib.toUpper (lib.toHexString v)}";

  mkLayout =
    { name
    , # [ { name = "spl"; size = "768K"; } ... ] in on-disk order; exactly one
      # entry may carry size = "-", and it must be the last.
      partitions
    }:
    let
      walk = lib.foldl'
        (acc: e:
          let bytes = toBytes e.size; in {
            n = acc.n + 1;
            off = if bytes == null then acc.off else acc.off + bytes;
            out = acc.out ++ [{
              inherit (e) name;
              sizeSpec = e.size;
              size = bytes;
              number = acc.n;
              offset = acc.off;
              device = "/dev/mmcblk0p${toString acc.n}";
            }];
          })
        { n = 1; off = 0; out = [ ]; }
        partitions;

      parts = walk.out;
      byName = lib.listToAttrs (map (p: lib.nameValuePair p.name p) parts);

      need = n:
        if byName ? ${n} then byName.${n}
        else throw "emmc-layout(${name}): no partition named '${n}'";

      has = n: byName ? ${n};

      clause = lib.concatStringsSep ","
        (map (p: "${p.sizeSpec}(${p.name})") parts);
    in
    rec {
      layoutName = name;
      inherit parts byName hex need has clause;

      blkdevparts = "blkdevparts=mmcblk0:${clause}";

      root = need "rootfs";
      bootfs = need "boot";
      env = need "env";

      # Total bytes ahead of the rootfs -- the span the migration works inside.
      preRootBytes = root.offset;

      # /etc/fw_env.config for libubootenv's fw_printenv / fw_setenv: device,
      # offset, size. Non-redundant single copy in the eMMC user area.
      fwEnvConfig = "/dev/mmcblk0 ${hex env.offset} ${hex env.size}\n";

      # ---- what the SPL is compiled with (docs/mainline-port.md 11.2) ------
      # The SPL finds every later stage by a compile-time byte offset; nothing
      # on the eMMC tells it where anything is. These are those offsets.
      splBases = {
        atf = need "atf";
        uboot = need "uboot";
      } // lib.optionalAttrs (has "ddrinit") { ddrinit = need "ddrinit"; }
      // lib.optionalAttrs (has "optee") { optee = need "optee"; }
      // lib.optionalAttrs (has "atf_b") { atf_b = need "atf_b"; }
      // lib.optionalAttrs (has "uboot_b") { uboot_b = need "uboot_b"; }
      // lib.optionalAttrs (has "optee_b") { optee_b = need "optee_b"; };

      # A/B pairs, where they exist, so nothing downstream has to remember
      # which number is which.
      slotA = lib.optionalAttrs (has "kernel") { kernel = need "kernel"; dtb = need "dtb"; };
      slotB = lib.optionalAttrs (has "kernel_b") { kernel = need "kernel_b"; dtb = need "dtb_b"; };

      # A human-readable table, for docs and for the build log.
      table = lib.concatMapStrings
        (p: "p${toString p.number}\t${p.name}\t${hex p.offset}\t"
          + (if p.size == null then "(remainder)" else "${hex p.size}\t${p.sizeSpec}") + "\n")
        parts;
    };

  # ---- the vendor's 17, exactly as the board shipped ----------------------
  vendor = mkLayout {
    name = "vendor";
    partitions = [
      { name = "spl"; size = "768K"; }
      { name = "ddrinit"; size = "512K"; }
      { name = "atf"; size = "256K"; }
      { name = "atf_b"; size = "256K"; }
      { name = "uboot"; size = "1536K"; }
      { name = "uboot_b"; size = "1536K"; }
      { name = "env"; size = "1M"; }
      { name = "logo"; size = "6M"; }
      { name = "logo_b"; size = "6M"; }
      { name = "optee"; size = "1M"; }
      { name = "optee_b"; size = "1M"; }
      { name = "dtb"; size = "1M"; }
      { name = "dtb_b"; size = "1M"; }
      { name = "kernel"; size = "64M"; }
      { name = "kernel_b"; size = "64M"; }
      { name = "boot"; size = "128M"; }
      { name = "rootfs"; size = "-"; }
    ];
  };

  # ---- the minimal six (#89 rung 4) --------------------------------------
  #
  # `boot` is 275M and not the 512M of the section-11.5 proposal for one
  # reason: the rootfs start must not move, and 275M is exactly what is left
  # of the vendor layout's first 277.75 MiB once spl/atf/uboot/env have taken
  # their 2816 KiB. Growing /boot past that would mean moving 29 GiB of root.
  minimal = mkLayout {
    name = "minimal";
    partitions = [
      { name = "spl"; size = "768K"; }
      { name = "atf"; size = "256K"; }
      { name = "uboot"; size = "1536K"; }
      { name = "env"; size = "256K"; }
      { name = "boot"; size = "275M"; }
      { name = "rootfs"; size = "-"; }
    ];
  };

  # ---- the DT's copy of the clause, and the assertion that it agrees ------
  # dts/ax630c-nanokvm-pro.dts carries the clause literally, because a .dts
  # has to be a standalone compilable file. U-Boot's extlinux APPEND overrides
  # /chosen/bootargs at `booti`, so the DT copy is a fallback -- but a fallback
  # that disagreed with the real table would be a trap, so it is asserted.
  dtsClause =
    let
      marker = "blkdevparts=mmcblk0:";
      dts = builtins.readFile ../../dts/ax630c-nanokvm-pro.dts;
      hit = lib.filter (l: lib.hasInfix marker l) (lib.splitString "\n" dts);
    in
    if hit == [ ] then throw "emmc-layout: no ${marker} in dts/ax630c-nanokvm-pro.dts"
    else lib.head (lib.splitString "\"" (lib.last (lib.splitString marker (lib.head hit))));
in

# ---- build-time agreement checks ------------------------------------------
# Every one of these is a thing that, if it drifted, would only be discovered
# on a board that stopped booting.
assert lib.assertMsg (lib.length vendor.parts == 17)
  "emmc-layout: the vendor layout must have 17 partitions";
assert lib.assertMsg (vendor.root.number == 17 && vendor.bootfs.number == 16)
  "emmc-layout: the vendor layout's rootfs/boot moved off p17/p16";
assert lib.assertMsg (vendor.env.offset == 4980736 && vendor.env.size == 1048576)
  "emmc-layout: the vendor env is not at 0x4C0000/0x100000";
assert lib.assertMsg (lib.length minimal.parts == 6)
  "emmc-layout: the minimal layout must have 6 partitions";
assert lib.assertMsg (minimal.root.number == 6 && minimal.bootfs.number == 5)
  "emmc-layout: the minimal layout's rootfs/boot moved off p6/p5";
# THE invariant: the in-place migration is only possible while these agree.
assert lib.assertMsg (minimal.root.offset == vendor.root.offset)
  ("emmc-layout: the minimal layout's rootfs starts at ${hex minimal.root.offset}, "
    + "the vendor layout's at ${hex vendor.root.offset} -- an in-place migration "
    + "would have to move 29 GiB of root filesystem");
assert lib.assertMsg (minimal.env.offset == 2621440 && minimal.env.size == 262144)
  "emmc-layout: the minimal env is not at 0x280000/0x40000";
# The DT's fallback clause must be the layout the mainline chain actually runs.
assert lib.assertMsg (dtsClause == minimal.clause)
  ("emmc-layout: dts/ax630c-nanokvm-pro.dts carries\n  ${dtsClause}\n"
    + "but the minimal layout is\n  ${minimal.clause}");

{
  inherit mkLayout vendor minimal hex toBytes;

  # Name -> layout, for the module option and for callers that take a string.
  byLayoutName = { inherit vendor minimal; };
}
