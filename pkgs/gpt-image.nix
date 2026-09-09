{ pkgs
, lib ? pkgs.lib
, layout ? import ../nixos/emmc-partitions.nix { inherit (pkgs) lib; layout = "minimal"; }
, ...
}:

# ===========================================================================
# THE GPT, generated (#89 rung 4).
#
# The eMMC's `disk` device -- everything after the BootROM's 768 KiB -- carries
# an ordinary, spec-conformant GPT at its own LBA 0. This derivation builds it
# with sgdisk against a sparse image of exactly `disk`'s size and then cuts out
# the two structures the rest of the world needs:
#
#   gpt-primary.bin   34 sectors: protective MBR (disk LBA 0), header (LBA 1)
#                     and the 128-entry array (LBA 2-33). Written at physical
#                     byte 0xC0000.
#   gpt-alt.bin       33 sectors: the backup array and, in the final sector,
#                     the alternate header. Lives at the very end of the eMMC.
#   gpt-alt-member.bin  the same 33 sectors preceded by 15872 zero bytes, so
#                     the whole thing is a 32 KiB image that can be written at
#                     a partition base rather than at an offset from the end --
#                     which is the only kind of address the .axp flasher takes.
#
# WHY GENERATE IT IN NIX rather than run sgdisk on the device. The .axp and the
# migration script then write IDENTICAL bytes, and the table is reproducible:
# the disk GUID and all five partition GUIDs are pinned in
# nixos/lib/emmc-layout.nix, so two builds of the same layout are byte-for-byte
# equal and a device can be diffed against the source of truth.
#
# THE DEVICE SIZE IS BAKED IN. `last_usable_lba` and the alternate header's
# position are functions of it. nixos/lib/emmc-layout.nix carries the measured
# 31272730624 B and the migration script refuses to run on a device that
# disagrees.
# ===========================================================================

let
  m = layout;

  q = s: lib.escapeShellArg s;

  newPart = p: lib.concatStringsSep " " [
    "--new=${toString p.number}:${toString p.startLba}:${toString p.endLba}"
    "--typecode=${toString p.number}:${p.type}"
    "--partition-guid=${toString p.number}:${p.uuid}"
    "--change-name=${toString p.number}:${p.name}"
  ];

  sgdiskArgs = lib.concatStringsSep " \\\n    "
    ([ "--clear" "--disk-guid=${m.diskGuid}" ] ++ map newPart m.gptParts);

  primaryBytes = m.firstUsableLba * m.sector; # 34 sectors = 17408
in
assert lib.assertMsg m.gpt "gpt-image: this layout has no GPT";
pkgs.runCommand "nanokvm-gpt"
{
  nativeBuildInputs = [ pkgs.gptfdisk pkgs.util-linux ];
  meta.description =
    "The NanoKVM-Pro eMMC GPT (primary + alternate), generated from nixos/lib/emmc-layout.nix";
} ''
  set -euo pipefail
  mkdir -p "$out"

  # A sparse image of `disk` -- everything after the BootROM's region. sgdisk
  # needs the real size, because last_usable_lba and the alternate header's
  # position both come from it; the file stays sparse, so it costs nothing.
  truncate -s ${toString m.diskBytes} disk.img

  sgdisk ${sgdiskArgs} \
    disk.img

  echo "=== sgdisk --verify ==="
  sgdisk --verify disk.img
  echo "=== sgdisk --print ==="
  sgdisk --print disk.img | tee "$out/gpt.txt"
  echo "=== sfdisk --dump (a second, independent reader) ==="
  sfdisk --dump disk.img | tee "$out/sfdisk.txt"

  # ---- cut out the two structures --------------------------------------
  dd if=disk.img of="$out/gpt-primary.bin" bs=512 count=${toString m.firstUsableLba} \
     status=none iflag=fullblock
  dd if=disk.img of="$out/gpt-alt.bin" bs=512 \
     skip=${toString m.altArrayLba} count=${toString (m.gptArrayLbas + 1)} \
     status=none iflag=fullblock

  # The 32 KiB flash member: zero padding, then the alternate structure, so
  # its last byte is the device's last byte.
  altSlot=${toString (m.need "gptalt").size}
  altLen=${toString m.altBytes}
  truncate -s $(( altSlot - altLen )) "$out/gpt-alt-member.bin"
  cat "$out/gpt-alt.bin" >> "$out/gpt-alt-member.bin"

  # ---- assertions -------------------------------------------------------
  test "$(stat -c %s "$out/gpt-primary.bin")" = ${toString primaryBytes}
  test "$(stat -c %s "$out/gpt-alt.bin")" = "$altLen"
  test "$(stat -c %s "$out/gpt-alt-member.bin")" = "$altSlot"

  # The protective MBR must be there, and it must be a protective MBR: 0x55AA
  # at the end of disk LBA 0 and a single 0xEE partition.
  sig=$(od -An -tx1 -j510 -N2 "$out/gpt-primary.bin" | tr -d ' ')
  test "$sig" = "55aa" || { echo "ERROR: no 0x55AA in the protective MBR ($sig)" >&2; exit 1; }
  ptype=$(od -An -tx1 -j450 -N1 "$out/gpt-primary.bin" | tr -d ' ')
  test "$ptype" = "ee" || { echo "ERROR: MBR partition type is $ptype, not ee" >&2; exit 1; }

  # "EFI PART" at the start of disk LBA 1, and at the start of the alternate
  # header (the final sector of gpt-alt.bin).
  hdr=$(dd if="$out/gpt-primary.bin" bs=512 skip=1 count=1 status=none | head -c 8)
  test "$hdr" = "EFI PART" || { echo "ERROR: primary header signature is '$hdr'" >&2; exit 1; }
  ahdr=$(dd if="$out/gpt-alt.bin" bs=512 skip=${toString m.gptArrayLbas} count=1 status=none | head -c 8)
  test "$ahdr" = "EFI PART" || { echo "ERROR: alternate header signature is '$ahdr'" >&2; exit 1; }

  # Every partition the layout declares must be in the table sgdisk wrote,
  # with the start LBA the layout computed. Two independent renderings.
  ${lib.concatMapStrings (p: ''
    grep -qE '^ +${toString p.number} +${toString p.startLba} +${toString p.endLba} .* ${p.name}$' "$out/gpt.txt" \
      || { echo "ERROR: ${p.name} is not at ${toString p.startLba}..${toString p.endLba} in the generated table" >&2;
           cat "$out/gpt.txt" >&2; exit 1; }
  '') m.gptParts}

  {
    echo "disk base (physical): ${m.hex m.splBytes}  = LBA ${toString m.gptBaseLba}"
    echo "disk size:            ${toString m.diskBytes} B (${toString m.diskLbaCount} LBAs)"
    echo "first usable LBA:     ${toString m.firstUsableLba}"
    echo "last usable LBA:      ${toString m.lastUsableLba}"
    echo "alternate header LBA: ${toString m.altHeaderLba} (disk) = device last sector"
    echo
    sha256sum "$out"/gpt-primary.bin "$out"/gpt-alt.bin "$out"/gpt-alt-member.bin
  } > "$out/MANIFEST.txt"
  cat "$out/MANIFEST.txt"
''
