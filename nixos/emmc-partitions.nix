{ lib }:

# ===========================================================================
# The eMMC partition map, parsed out of the ONE place it is actually defined.
#
# This SoC's eMMC carries no on-disk partition table at all. The layout is the
# `blkdevparts=mmcblk0:...` clause of the kernel command line: U-Boot parses it
# to find `kernel`/`dtb`/`rootfs` by name (docs/mainline-port.md section 5,
# trap 1), and Linux turns it into `/dev/mmcblk0pN` via CONFIG_CMDLINE_PARTITION.
# Everything downstream -- which partition is root, which is /boot, where the
# U-Boot environment lives -- is a consequence of that single string.
#
# So it is parsed here rather than restated. Three numbers that used to be
# hand-copied into three different files (p16, p17, and the 0x4C0000 env offset
# in /etc/fw_env.config) are now derived from the same source the bootloader
# reads, and the asserts below fail the build if that source ever changes shape.
# ===========================================================================

let
  dts = builtins.readFile ../dts/ax630c-nanokvm-pro.dts;

  marker = "blkdevparts=mmcblk0:";

  # The clause lives on the `bootargs = "..."` line of /chosen. Take the line,
  # then everything between the marker and the closing quote.
  bootargsLine =
    let hit = lib.filter (l: lib.hasInfix marker l) (lib.splitString "\n" dts);
    in if hit == [ ] then throw "emmc-partitions: no ${marker} in dts/ax630c-nanokvm-pro.dts"
    else lib.head hit;

  clause = lib.head (lib.splitString "\"" (lib.last (lib.splitString marker bootargsLine)));

  # "768K(spl)" -> { name = "spl"; size = 786432; }
  #      "-(rootfs)" -> size = null (the remainder of the device)
  parseEntry = e:
    let
      m = builtins.match "([0-9]+[KMG]?|-)\\(([^)]+)\\)" e;
      sz = builtins.elemAt m 0;
      name = builtins.elemAt m 1;
      unit = lib.substring (lib.stringLength sz - 1) 1 sz;
      num = builtins.fromJSON (lib.substring 0 (lib.stringLength sz - 1) sz);
      mult = { "K" = 1024; "M" = 1048576; "G" = 1073741824; };
    in
    if m == null then throw "emmc-partitions: cannot parse blkdevparts entry '${e}'"
    else {
      inherit name;
      size =
        if sz == "-" then null
        else if mult ? ${unit} then num * mult.${unit}
        else builtins.fromJSON sz;
    };

  entries = map parseEntry (lib.splitString "," clause);

  # Fold once: partition number (1-based, the order U-Boot and the kernel both
  # use) and byte offset from the start of the eMMC user area.
  walk = lib.foldl'
    (acc: e: {
      n = acc.n + 1;
      off = if e.size == null then acc.off else acc.off + e.size;
      out = acc.out ++ [{
        inherit (e) name size;
        number = acc.n;
        offset = acc.off;
        device = "/dev/mmcblk0p${toString acc.n}";
      }];
    })
    { n = 1; off = 0; out = [ ]; }
    entries;

  parts = walk.out;

  byName = lib.listToAttrs (map (p: lib.nameValuePair p.name p) parts);

  need = n:
    if byName ? ${n} then byName.${n}
    else throw "emmc-partitions: no partition named '${n}' in the blkdevparts clause";

  hex = v: "0x${lib.toUpper (lib.toHexString v)}";
in
assert lib.assertMsg (lib.length parts == 17)
  "emmc-partitions: expected the vendor's 17-partition layout, parsed ${toString (lib.length parts)}";
assert lib.assertMsg ((need "rootfs").number == 17)
  "emmc-partitions: rootfs is p${toString (need "rootfs").number}, not p17";
assert lib.assertMsg ((need "boot").number == 16)
  "emmc-partitions: boot is p${toString (need "boot").number}, not p16";
# docs/mainline-port.md section 6 derives the U-Boot environment location from
# this same sum. Assert the agreement rather than trusting either side.
assert lib.assertMsg ((need "env").offset == 4980736 && (need "env").size == 1048576)
  "emmc-partitions: env is at ${hex (need "env").offset} size ${hex (need "env").size}, expected 0x4C0000/0x100000";

{
  inherit parts byName hex;

  # The raw clause, verbatim, without the `blkdevparts=mmcblk0:` marker. #89's
  # mainline U-Boot reads the same string through its own `part_cmdline`
  # driver, so the bootloader's table and the kernel's come from one source
  # rather than two hand-copied ones (pkgs/uboot-mainline.nix).
  inherit clause;
  blkdevparts = "${marker}${clause}";

  root = need "rootfs";
  bootfs = need "boot";
  env = need "env";

  # A/B pairs, so nothing downstream has to remember which number is which.
  slotA = { kernel = need "kernel"; dtb = need "dtb"; };
  slotB = { kernel = need "kernel_b"; dtb = need "dtb_b"; };

  # /etc/fw_env.config for libubootenv's fw_printenv / fw_setenv: device,
  # offset, size. Non-redundant single copy in the eMMC user area.
  fwEnvConfig = "/dev/mmcblk0 ${hex (need "env").offset} ${hex (need "env").size}\n";
}
