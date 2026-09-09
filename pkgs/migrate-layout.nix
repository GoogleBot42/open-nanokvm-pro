{ pkgs
, lib ? pkgs.lib
, atf-mainline
, uboot-mainline
, spl-minimal
, gpt-image
, uboot-env
, bootfs # the ext4 /boot image for the MINIMAL layout
, project
, layout ? import ../nixos/emmc-partitions.nix { inherit (pkgs) lib; layout = "minimal"; }
, vendorLayout ? import ../nixos/emmc-partitions.nix { inherit (pkgs) lib; layout = "vendor"; }
, ...
}:

# ===========================================================================
# The in-place layout migration kit (#89 rung 4).
#
#   nix build .#migrate-layout
#   tar -C result -cf - . | tools/kvmssh 'mkdir -p /root/rung4-kit && tar -C /root/rung4-kit -xf -'
#   tools/kvmssh '/root/rung4-kit/bin/migrate-layout backup'
#   tools/kvmssh '/root/rung4-kit/bin/migrate-layout write'
#   # ... coordinator's go ...
#   tools/kvmssh '/root/rung4-kit/bin/migrate-layout spl --i-have-the-go'
#
# WHY A KIT AND NOT A FLASH. The board already runs the mainline chain; only
# the layout changes. Rewriting in place from a shell keeps the 29 GiB rootfs
# exactly where it is (both layouts start it at the same byte) and keeps every
# step before the SPL reversible from that same shell. An AXDL flash would be
# simpler and would also erase the machine.
#
# EVERY IMAGE IS PADDED TO A 4 KiB MULTIPLE. The signed containers are not:
# BL31 is 14592 B, U-Boot 185232 B, the primary GPT 17408 B. Padding with
# zeros lets the script `dd` in whole 4 KiB blocks and, more importantly, read
# the same span back and hash it -- a byte-exact read-back check needs a
# block-aligned length. The SPL reads `img_size` out of its header and ignores
# what follows; the GPT's own length is in its header; so the pad is invisible.
# ===========================================================================

let
  m = layout;

  pad = name: src: pkgs.runCommand "padded-${name}" { } ''
    cp ${src} img
    chmod u+w img
    sz=$(stat -c %s img)
    want=$(( (sz + 4095) / 4096 * 4096 ))
    truncate -s "$want" img
    echo "${name}: $sz B -> $want B (4 KiB aligned)"
    cp img "$out"
  '';

  images = {
    "spl.bin" = pad "spl" "${spl-minimal}/images/spl_${project}_signed.bin";
    "gpt.bin" = pad "gpt" "${gpt-image}/gpt-primary.bin";
    "gptalt.bin" = pad "gptalt" "${gpt-image}/gpt-alt-member.bin";
    "atf.bin" = pad "atf" "${atf-mainline}/images/atf_bl31_mainline_signed.bin";
    "uboot.bin" = pad "uboot" "${uboot-mainline}/images/u-boot_mainline_signed.bin";
    "env.bin" = pad "env" "${uboot-env}";
  };

  # Everything the `write` phase puts down, in on-disk order. `spl` is
  # deliberately absent: it is the gate.
  region = name: file:
    let p = m.need name; in
    "${name} ${toString p.offset} ${toString p.size} ${file}";

  regions = lib.concatStringsSep "\n" [
    (region "gpt" "gpt.bin")
    (region "atf" "atf.bin")
    (region "uboot" "uboot.bin")
    (region "env" "env.bin")
    (region "boot" "bootfs.ext4.gz")
    (region "gptalt" "gptalt.bin")
  ];

  subst = {
    DEVICE_BYTES = toString m.deviceBytes;
    SPL_OFF = toString (m.need "spl").offset;
    SPL_SIZE = toString (m.need "spl").size;
    ROOT_OFF = toString m.root.offset;
    ALT_OFF = toString (m.need "gptalt").offset;
    ALT_SIZE = toString (m.need "gptalt").size;
    NEW_ROOT_DEV = m.root.device;
    OLD_ROOT_DEV = vendorLayout.root.device;
    CLAUSE = m.blkdevparts;
    FW_ENV = lib.removeSuffix "\n" m.fwEnvConfig;
    GPT_BASE_LBA = toString m.gptBaseLba;
    REGIONS = regions;
  };

  substArgs = lib.concatStringsSep " "
    (lib.mapAttrsToList (k: v: "--subst-var-by ${k} ${lib.escapeShellArg v}") subst);

  copyImages = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (n: p: "cp ${p} \"$out/images/${n}\"") images);
in
pkgs.runCommand "nanokvm-migrate-layout"
{
  nativeBuildInputs = [ pkgs.gzip ];
  meta.description =
    "In-place eMMC layout migration kit for the NanoKVM-Pro (#89 rung 4): "
    + "the vendor 17-partition map -> spl + a GPT-carrying disk, rootfs untouched";
} ''
  mkdir -p "$out/bin" "$out/images"

  substitute ${../tools/migrate-layout.sh.in} "$out/bin/migrate-layout" ${substArgs}
  chmod +x "$out/bin/migrate-layout"
  ! grep -n '@[A-Z_]\+@' "$out/bin/migrate-layout" \
    || { echo "ERROR: unsubstituted placeholder in migrate-layout" >&2; exit 1; }

  ${copyImages}

  # 272 MiB of mostly-zero ext4 compresses to a few MiB, which is the
  # difference between a fast scp and a slow one over the board's link.
  gzip -9 -c ${bootfs} > "$out/images/bootfs.ext4.gz"

  cp ${gpt-image}/gpt.txt "$out/gpt.txt"
  cp ${gpt-image}/sfdisk.txt "$out/sfdisk.txt"
  cat > "$out/LAYOUT.txt" <<'EOF'
${m.table}
EOF

  {
    echo "target layout (physical byte offsets):"
    sed 's/^/  /' "$out/LAYOUT.txt"
    echo "kernel cmdline: ${m.blkdevparts}"
    echo "fw_env.config:  ${lib.removeSuffix "\n" m.fwEnvConfig}"
    echo "GPT base LBA:   ${toString m.gptBaseLba}"
    echo
    echo "images (sha256, as written to the medium):"
    for f in "$out"/images/*; do
      printf '  %s  %s  %s B\n' "$(sha256sum "$f" | cut -d' ' -f1)" \
        "$(basename "$f")" "$(stat -c %s "$f")"
    done
  } > "$out/MANIFEST.txt"
  cat "$out/MANIFEST.txt"
''
