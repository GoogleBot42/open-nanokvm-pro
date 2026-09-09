{ lib }:

# ===========================================================================
# THE eMMC LAYOUT. One definition, every consumer derived from it (#89 rung 4).
#
# THE SHAPE OF THE PROBLEM. The AX630C BootROM reads the first-stage loader
# from byte 0 of the eMMC USER AREA. Which area it reads is a pin strap, not
# software (`get_boot_mode()` on `chip_mode`), and this board is strapped to
# mode 0 -- the user area. Its two 4 MiB eMMC boot partitions are blank and
# unreachable without changing that strap. So byte 0 belongs to the ROM, and
# an MBR (LBA 0) or a GPT (LBA 0 for the protective MBR, 1-33 for the header
# and array) cannot live where the standard puts it.
#
# THE ANSWER: TWO LOGICAL DEVICES.
#
#   spl    the first 768 KiB. The ROM's image and nothing else. It is never
#          inside a partition table, because there is no table there.
#   disk   everything after it. This carries a REAL, spec-conformant GPT at
#          ITS OWN LBA 0 -- protective MBR at disk LBA 0, header at disk LBA
#          1, entry array at disk LBA 2-33, first usable disk LBA 34, and the
#          alternate header at the last LBA of the device, exactly as the
#          UEFI specification requires. Partitions get names, type GUIDs and
#          partition GUIDs; `lsblk`, `blkid`, `sgdisk` and `parted` all read
#          it as an ordinary disk.
#
# Linux gets `disk` through the ONE thing the kernel can do without a table:
# `blkdevparts=mmcblk0:768K(spl),-(disk)` splits the raw eMMC in two, and
# stage 1 then does `losetup -P /dev/mmcblk0p2`, at which point the in-kernel
# EFI parser scans the GPT and creates /dev/loop0p1..5. U-Boot gets it from a
# `gpt_base_lba` patch to disk/part_efi.c: the same GPT, read at a base LBA.
#
# THREE VIEWS OF ONE LIST, all generated here:
#
#   gptParts    disk-relative LBAs. What the GPT itself declares, what
#               pkgs/gpt-image.nix hands to sgdisk, and what U-Boot and Linux
#               both read back.
#   flashParts  physical byte offsets in the eMMC user area. What the .axp
#               manifest describes and what tools/migrate-layout.sh `dd`s --
#               including the `spl` region and the two GPT structures, which
#               are not partitions in either of the other views.
#   kernelParts the two-entry `blkdevparts=` clause, the only thing Linux is
#               told directly.
#
# and from them: the SPL's compiled-in ATF/UBOOT flash bases, U-Boot's
# `gpt_base_lba` and `bootpart`, /etc/fw_env.config, the NixOS `fileSystems`
# devices, the extlinux APPEND, and the migration script's `dd seek=`.
#
# THE INVARIANT: `rootfs` KEEPS ITS PHYSICAL START, byte 0x115C0000 -- the
# same byte the vendor's 17-partition map put it at. That is what lets the
# whole conversion happen in place, from a shell, on a running system: the
# filesystem the script is executing from is never moved. Everything before
# it is sized to fit the span the old p1-p16 occupied. The assertion at the
# bottom of this file is what keeps it true.
#
# TWO LAYOUTS EXIST, and both are real.
#
#   `vendor`  the 17-partition A/B map the board shipped with, and the one
#             the vendor SPL is compiled for. `.#nixos-firmware-image` flashes
#             it; it is the AXDL recovery.
#   `minimal` the two-device GPT layout above.
# ===========================================================================

let
  sector = 512;
  units = { K = 1024; M = 1048576; G = 1073741824; };

  toBytes = spec:
    if spec == null || spec == "-" then null
    else
      let
        unit = lib.substring (lib.stringLength spec - 1) 1 spec;
        num = lib.substring 0 (lib.stringLength spec - 1) spec;
      in
      if units ? ${unit} then (lib.toInt num) * units.${unit}
      else lib.toInt spec;

  hex = v: "0x${lib.toUpper (lib.toHexString v)}";

  # Nix has no % operator.
  mod = a: b: a - (a / b) * b;

  # ---- the vendor's 17, as a flat physical list --------------------------
  mkFlatLayout =
    { name, partitions, deviceBytes ? null }:
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
      need = n: if byName ? ${n} then byName.${n}
      else throw "emmc-layout(${name}): no partition named '${n}'";
      clause = lib.concatStringsSep "," (map (p: "${p.sizeSpec}(${p.name})") parts);
    in
    {
      layoutName = name;
      gpt = false;
      # What the `blkdevparts=` clause describes. For the vendor layout that
      # is the whole table; the GPT layout below overrides it with two.
      kernelParts = parts;
      inherit parts byName need clause hex deviceBytes;
      has = n: byName ? ${n};
      blkdevparts = "blkdevparts=mmcblk0:${clause}";
      root = need "rootfs";
      bootfs = need "boot";
      env = need "env";
      fwEnvConfig = "/dev/mmcblk0 ${hex (need "env").offset} ${hex (need "env").size}\n";
      slotA = { kernel = need "kernel"; dtb = need "dtb"; };
      slotB = { kernel = need "kernel_b"; dtb = need "dtb_b"; };
      table = lib.concatMapStrings
        (p: "p${toString p.number}\t${p.name}\t${hex p.offset}\t"
          + (if p.size == null then "(remainder)" else "${hex p.size}\t${p.sizeSpec}") + "\n")
        parts;
    };

  vendor = mkFlatLayout {
    name = "vendor";
    deviceBytes = null;
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

  # ======================================================================
  # THE MINIMAL LAYOUT: spl + a GPT-carrying `disk`
  # ======================================================================

  # The eMMC on this board, measured 2026-09-09:
  #   blockdev --getsize64 /dev/mmcblk0  ->  31272730624   (29.1 GiB)
  #   mmcblk0boot0 / boot1               ->  4194304 each, blank, and only
  #                                          reachable by changing the strap
  # The GPT's alternate header and its `last_usable_lba` are functions of the
  # device size, so the layout cannot be device-size-agnostic the way a
  # `blkdevparts=` clause was. A board with a different eMMC needs this
  # number changed and the GPT regenerated; the migration script asserts the
  # device it is running on matches.
  deviceBytes = 31272730624;

  splBytes = 786432; # 768 KiB -- the ROM's region, and the base of `disk`
  gptBaseLba = splBytes / sector; # 1536
  diskBytes = deviceBytes - splBytes;
  diskLbaCount = diskBytes / sector; # 61078016
  diskLastLba = diskLbaCount - 1; # 61078015 (disk-relative)

  # GPT geometry, disk-relative, straight from the UEFI spec.
  gptHeaderLba = 1;
  gptArrayLba = 2;
  gptArrayLbas = 32; # 128 entries x 128 B
  firstUsableLba = gptArrayLba + gptArrayLbas; # 34
  lastUsableLba = diskLastLba - gptArrayLbas - 1; # 61077982
  altArrayLba = lastUsableLba + 1; # 61077983
  altHeaderLba = diskLastLba; # 61078015
  # The whole alternate structure, as bytes at the very end of the device.
  altBytes = (gptArrayLbas + 1) * sector; # 16896

  # Partitions start at disk LBA 2048 -- the conventional 1 MiB alignment,
  # which is also what sgdisk picks by default, so a human running sgdisk on
  # this disk lands on the same numbers.
  firstPartLba = 2048;

  # Type GUIDs from the Discoverable Partitions Specification, so the table
  # says what each partition IS rather than "Linux filesystem" five times.
  guidLinuxReserved = "8DA63339-0007-60C0-C436-083AC8230908";
  guidUbootEnv = "3DE21764-95BD-54BD-A5C3-4ABE786F38A8";
  guidXbootldr = "BC13C2FF-59E6-4262-A352-B275FD6F7172";
  guidRootArm64 = "B921B045-1DF0-41C3-AF44-4C6F280D3FAE";

  gptSpec = [
    # `atf` and `uboot` are raw signed containers the SPL loads by byte
    # offset; the GPT entry exists so the space is named and reserved, not
    # because anything parses it to find them.
    { name = "atf"; size = "1M"; type = guidLinuxReserved; }
    { name = "uboot"; size = "2M"; type = guidLinuxReserved; }
    { name = "env"; size = "1M"; type = guidUbootEnv; }
    # ext4: extlinux.conf, the kernel, the dtb, and the server's flag files.
    { name = "boot"; size = "272M"; type = guidXbootldr; }
    # null = to `last_usable_lba`, which is 33 LBAs short of the device end
    # because that is where the alternate GPT lives.
    { name = "rootfs"; size = null; type = guidRootArm64; }
  ];

  gptWalk = lib.foldl'
    (acc: e:
      let
        bytes = toBytes e.size;
        lbas = if bytes == null then (lastUsableLba - acc.lba + 1) else bytes / sector;
      in {
        n = acc.n + 1;
        lba = acc.lba + lbas;
        out = acc.out ++ [{
          inherit (e) name type;
          sizeSpec = e.size;
          number = acc.n;
          startLba = acc.lba; # disk-relative
          endLba = acc.lba + lbas - 1; # inclusive, disk-relative
          lbaCount = lbas;
          size = lbas * sector;
          offset = splBytes + acc.lba * sector; # PHYSICAL byte offset
          device = "/dev/loop0p${toString acc.n}";
          # Deterministic, so two builds of the same layout are byte-identical.
          uuid = "4e4b564d-0001-4000-8000-00000000000${toString acc.n}";
        }];
      })
    { n = 1; lba = firstPartLba; out = [ ]; }
    gptSpec;

  gptParts = gptWalk.out;
  gptByName = lib.listToAttrs (map (p: lib.nameValuePair p.name p) gptParts);
  gptNeed = n:
    if gptByName ? ${n} then gptByName.${n}
    else throw "emmc-layout(minimal): no GPT partition named '${n}'";

  # ---- the flash view: physical byte offsets, for the .axp and for `dd` ---
  # Every byte of the user area is accounted for, in order, so the .axp's
  # running-sum <Partitions> list and the migration script's `seek=` come
  # from the same arithmetic as the GPT.
  gptRegionBytes = (gptNeed "atf").offset - splBytes; # 1 MiB
  rootfsFlashBytes = deviceBytes - (gptNeed "rootfs").offset - 32768;

  bytesToSpec = b:
    if mod b units.M == 0 then "${toString (b / units.M)}M"
    else if mod b units.K == 0 then "${toString (b / units.K)}K"
    else toString b;

  flashSpec = [
    { name = "spl"; size = bytesToSpec splBytes; }
    { name = "gpt"; size = bytesToSpec gptRegionBytes; }
  ] ++ (map (p: { inherit (p) name; size = bytesToSpec p.size; })
    (lib.filter (p: p.name != "rootfs") gptParts))
  ++ [
    { name = "rootfs"; size = bytesToSpec rootfsFlashBytes; }
    # The last 32 KiB of the device. Its final 16896 bytes are the alternate
    # GPT (32 array LBAs + the header at the very last sector); the 15872 in
    # front of them are zero padding, because the flasher writes whole
    # partitions and cannot address a byte offset from the end.
    { name = "gptalt"; size = "32K"; }
  ];

  flashWalk = lib.foldl'
    (acc: e:
      let bytes = toBytes e.size; in {
        n = acc.n + 1;
        off = acc.off + bytes;
        out = acc.out ++ [{
          inherit (e) name;
          sizeSpec = e.size;
          size = bytes;
          number = acc.n;
          offset = acc.off;
          device = "/dev/mmcblk0"; # a byte range, not a block device
        }];
      })
    { n = 1; off = 0; out = [ ]; }
    flashSpec;

  flashParts = flashWalk.out;
  flashByName = lib.listToAttrs (map (p: lib.nameValuePair p.name p) flashParts);

  # ---- what Linux is told -------------------------------------------------
  # Two entries and no more. This is the ONE thing the kernel can be told
  # without an on-disk table, and all it has to do is hand back `disk` as a
  # block device; the GPT inside it does the rest, once stage 1 has put a loop
  # over it. Nothing addresses these two by number except that loop setup.
  kernelClause = "${bytesToSpec splBytes}(spl),-(disk)";

  kernelParts = [
    {
      name = "spl";
      number = 1;
      offset = 0;
      size = splBytes;
      sizeSpec = bytesToSpec splBytes;
      device = "/dev/mmcblk0p1";
    }
    {
      name = "disk";
      number = 2;
      offset = splBytes;
      size = null;
      sizeSpec = "-";
      device = "/dev/mmcblk0p2";
    }
  ];

  minimal = {
    layoutName = "minimal";
    gpt = true;
    inherit deviceBytes splBytes gptBaseLba diskBytes diskLbaCount diskLastLba
      gptHeaderLba gptArrayLba gptArrayLbas firstUsableLba lastUsableLba
      altArrayLba altHeaderLba altBytes firstPartLba sector hex
      gptParts gptByName flashParts flashByName kernelClause kernelParts;

    diskGuid = "4e4b564d-0000-4000-8000-00006e616e6f";

    # `parts` is the FLASH view, because that is what the .axp packer and the
    # migration script iterate. GPT consumers use `gptParts`.
    parts = flashParts;
    byName = flashByName;
    has = n: flashByName ? ${n};
    need = n:
      if flashByName ? ${n} then flashByName.${n}
      else throw "emmc-layout(minimal): no flash region named '${n}'";

    # The block devices the running system uses: the GPT partitions, as the
    # loop device stage 1 sets up over /dev/mmcblk0p2.
    root = gptNeed "rootfs";
    bootfs = gptNeed "boot";
    env = gptNeed "env";

    # The two raw eMMC partitions the kernel command line creates.
    splDevice = "/dev/mmcblk0p1";
    diskDevice = "/dev/mmcblk0p2";
    loopDevice = "/dev/loop0";

    clause = kernelClause;
    blkdevparts = "blkdevparts=mmcblk0:${kernelClause}";

    # fw_setenv addresses the raw eMMC by PHYSICAL byte offset, so it needs
    # no loop device and works from the earliest possible moment.
    fwEnvConfig = "/dev/mmcblk0 ${hex (gptNeed "env").offset} ${hex (gptNeed "env").size}\n";

    slotA = { };
    slotB = { };

    table =
      "spl region  0x0 .. ${hex splBytes}   (${toString (splBytes / 1024)} KiB, BootROM, no table)\n"
      + "disk base  ${hex splBytes} = LBA ${toString gptBaseLba}; GPT hdr LBA "
      + "${toString (gptBaseLba + gptHeaderLba)}, array LBA "
      + "${toString (gptBaseLba + gptArrayLba)}..${toString (gptBaseLba + gptArrayLba + gptArrayLbas - 1)} (physical)\n"
      + lib.concatMapStrings
        (p: "p${toString p.number}\t${p.name}\tdiskLBA ${toString p.startLba}..${toString p.endLba}"
          + "\tphys ${hex p.offset}\t"
          + (if p.sizeSpec == null then "(to last usable)" else p.sizeSpec) + "\n")
        gptParts
      + "alt GPT    phys ${hex (deviceBytes - altBytes)} .. ${hex deviceBytes} (${toString altBytes} B)\n";
  };
in

# ---- build-time agreement checks ------------------------------------------
assert lib.assertMsg (lib.length vendor.parts == 17)
  "emmc-layout: the vendor layout must have 17 partitions";
assert lib.assertMsg (vendor.root.number == 17 && vendor.bootfs.number == 16)
  "emmc-layout: the vendor layout's rootfs/boot moved off p17/p16";
assert lib.assertMsg (vendor.env.offset == 4980736 && vendor.env.size == 1048576)
  "emmc-layout: the vendor env is not at 0x4C0000/0x100000";

# THE invariant: the in-place migration is only possible while these agree.
assert lib.assertMsg (minimal.root.offset == vendor.root.offset)
  ("emmc-layout: the minimal layout's rootfs starts at ${hex minimal.root.offset}, "
    + "the vendor layout's at ${hex vendor.root.offset} -- an in-place migration "
    + "would have to move 29 GiB of root filesystem");

# Nothing may reach back into the ROM's region, and nothing but rootfs may
# reach past the rootfs start.
assert lib.assertMsg ((lib.head minimal.gptParts).offset >= minimal.splBytes + 17408)
  "emmc-layout: the first partition overlaps the GPT header/array";
assert lib.assertMsg (lib.all (p: p.offset >= minimal.splBytes) minimal.gptParts)
  "emmc-layout: a GPT partition reaches into the spl region";
assert lib.assertMsg
  (lib.all (p: p.offset + p.size <= minimal.root.offset)
    (lib.filter (p: p.name != "rootfs") minimal.gptParts))
  "emmc-layout: a boot-chain partition crosses the rootfs start";
assert lib.assertMsg (minimal.root.endLba == minimal.lastUsableLba)
  "emmc-layout: rootfs does not end at last_usable_lba";
assert lib.assertMsg
  ((lib.last minimal.flashParts).offset + (lib.last minimal.flashParts).size == minimal.deviceBytes)
  "emmc-layout: the flash view does not cover the device exactly";
assert lib.assertMsg
  (lib.all (p: p.startLba * minimal.sector + minimal.splBytes == p.offset) minimal.gptParts)
  "emmc-layout: a GPT LBA and its physical byte offset disagree";
assert lib.assertMsg (mod (minimal.firstPartLba * minimal.sector) 1048576 == 0)
  "emmc-layout: partitions are not 1 MiB aligned inside `disk`";

{
  inherit vendor minimal hex toBytes;
  byLayoutName = { inherit vendor minimal; };
}
