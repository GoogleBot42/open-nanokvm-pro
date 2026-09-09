{ pkgs
, lib ? pkgs.lib
, uboot-mainline
, gpt-image
, ...
}:

# ===========================================================================
# THE GPT-AT-A-BASE-LBA TEST (#89 rung 4).
#
#   nix build .#checks.x86_64-linux.uboot-gpt -L
#
# Patch 0023 teaches disk/part_efi.c to read a GUID Partition Table that does
# not start at LBA 0 -- which is the only way this board can have a real GPT
# at all, because its BootROM owns the first 768 KiB of the eMMC. Getting the
# arithmetic wrong is not a build error: U-Boot would find no table, or a
# table whose partitions point at the wrong sectors, and the first symptom
# would be a board that stops booting after a one-way SPL write.
#
# So the patched parser is RUN, not inspected. U-Boot's `sandbox` target
# builds the same disk/part_efi.c as a host binary; this derivation builds it
# from the same source and the same patch series, hands it a file that is a
# faithful model of the eMMC -- 768 KiB of BootROM region, then the generated
# GPT and its partitions, then the alternate header in the very last sector --
# and asserts that `part list` reports the five partitions at the PHYSICAL
# sectors nixos/lib/emmc-layout.nix says they are at.
#
# Three things it proves that reading the patch cannot:
#   * the protective MBR and header are found at the base rather than at 0;
#   * `last_usable_lba` validates against the table-relative device size,
#     not the real one (the check that rejects a table read at an offset);
#   * a partition's reported start is a device sector, so `ext4load mmc 0:4`
#     lands where the `boot` filesystem actually is.
# ===========================================================================

let
  m = uboot-mainline.passthru.layout;

  expected = lib.concatMapStringsSep "\n"
    (p: "${toString p.number} ${toString (m.gptBaseLba + p.startLba)} "
      + "${toString (m.gptBaseLba + p.endLba)} ${p.name}")
    m.gptParts;
in
assert lib.assertMsg m.gpt "uboot-gpt-test: this layout has no GPT";
pkgs.runCommand "uboot-gpt-test"
{
  nativeBuildInputs = with pkgs; [
    stdenv.cc gnumake bison flex bc dtc openssl ncurses swig
    (python3.withPackages (ps: [ ps.setuptools ]))
    which gawk perl bash util-linux gnugrep coreutils
    gnutls pkg-config libuuid
  ];
  meta.platforms = [ "x86_64-linux" ];
} ''
  set -euo pipefail
  export HOME=$PWD

  echo "=== unpacking U-Boot ${uboot-mainline.version} and applying the series ==="
  tar xf ${uboot-mainline.passthru.src}
  cd u-boot-${uboot-mainline.version}
  ${lib.concatMapStrings (p: "patch -p1 --no-backup-if-mismatch < ${p} > /dev/null\n  ") uboot-mainline.passthru.patches}
  patchShebangs tools scripts

  echo "=== building the sandbox target ==="
  # NO_SDL: the test drives U-Boot with -c and reads stdout; there is no
  # display, and pulling SDL into a partition-table test would be absurd.
  make sandbox_defconfig NO_SDL=1 >/dev/null
  # The board's settings, so the code under test is the code that ships.
  ./scripts/config --enable EFI_PARTITION
  ./scripts/config --set-val EFI_PARTITION_BASE_LBA ${toString m.gptBaseLba}
  ./scripts/config --enable CMD_PART
  # A partition-table test needs none of the EFI loader, and its capsule
  # signing pulls in efitools/gnutls that have nothing to do with this.
  ./scripts/config --disable EFI_CAPSULE_AUTHENTICATE
  make olddefconfig NO_SDL=1 >/dev/null
  grep -qx 'CONFIG_EFI_PARTITION_BASE_LBA=${toString m.gptBaseLba}' .config
  make NO_SDL=1 -j''${NIX_BUILD_CORES:-4} >/dev/null 2>build.log || { tail -40 build.log >&2; exit 1; }
  test -x ./u-boot

  echo "=== building a model of the eMMC ==="
  # Sparse: the file is 29 GiB on paper and a few hundred KiB on disk.
  img=$PWD/emmc.img
  truncate -s ${toString m.deviceBytes} "$img"
  # 1. the BootROM's region -- deliberately NOT a partition table. If the
  #    parser looked at LBA 0 it would find this and fail, which is the point.
  printf 'AXERA-SPL-REGION-NOT-A-PARTITION-TABLE' | dd of="$img" bs=1 conv=notrunc status=none
  # 2. the primary GPT, at the base.
  dd if=${gpt-image}/gpt-primary.bin of="$img" bs=512 \
     seek=${toString m.gptBaseLba} conv=notrunc status=none
  # 3. the alternate GPT, in the device's last 33 sectors.
  dd if=${gpt-image}/gpt-alt.bin of="$img" bs=512 \
     seek=${toString (m.deviceBytes / 512 - m.gptArrayLbas - 1)} conv=notrunc status=none

  echo "=== what the kernel's own tools make of it (an independent reader) ==="
  losetup --version >/dev/null
  # No loop device in a Nix build sandbox, so use the offset-aware parser in
  # util-linux directly.
  sfdisk --dump --force "$img" 2>/dev/null || true

  echo "=== running the patched parser ==="
  ./u-boot -T -c "host bind 0 $img; part list host 0; setenv gpt_base_lba ${toString m.gptBaseLba}; part list host 0" \
    > out.txt 2>&1 || { cat out.txt >&2; echo "ERROR: sandbox U-Boot failed" >&2; exit 1; }
  cat out.txt

  echo "=== assertions ==="
  # `part list` prints:  N\t0xSTART\t0xEND\t"name"
  ${lib.concatMapStrings (p: ''
    want_start=$(printf '0x%08x' ${toString (m.gptBaseLba + p.startLba)})
    want_end=$(printf '0x%08x' ${toString (m.gptBaseLba + p.endLba)})
    grep -qE "^ *${toString p.number}[[:space:]]+$want_start[[:space:]]+$want_end[[:space:]]+\"${p.name}\"" out.txt \
      || { echo "ERROR: ${p.name} not reported at $want_start..$want_end (device LBAs)" >&2;
           exit 1; }
    echo "  ok  ${p.name}\tdevice LBA $want_start..$want_end"
  '') m.gptParts}

  # And it must have found the table at the base, not stumbled onto the
  # alternate: `Using Backup GPT` would mean the primary read was wrong.
  ! grep -q "Using Backup GPT" out.txt \
    || { echo "ERROR: the primary GPT at LBA ${toString m.gptBaseLba} was not accepted" >&2; exit 1; }

  mkdir -p "$out"
  {
    echo "u-boot ${uboot-mainline.version}, sandbox, CONFIG_EFI_PARTITION_BASE_LBA=${toString m.gptBaseLba}"
    echo
    echo "expected (partition, device start LBA, device end LBA, name):"
    cat <<'EXP'
${expected}
EXP
    echo
    echo "u-boot said:"
    cat out.txt
  } > "$out/report"
  echo "GPT at base LBA ${toString m.gptBaseLba}: all ${toString (lib.length m.gptParts)} partitions correct"
''
