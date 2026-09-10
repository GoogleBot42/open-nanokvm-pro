{ pkgs
, lib ? pkgs.lib
, nixos-firmware-image-mainline # the flashable minimal-layout .axp
, migrate-layout # the in-place migration kit
, project
, ...
}:

# ===========================================================================
# THE FLASHED IMAGE AND THE MIGRATION KIT MUST PUT DOWN THE SAME BYTES (#94).
#
# The minimal layout has been reached two ways. `.#migrate-layout` writes it
# in place from a shell on the running board, verifying every region from the
# medium, and that chain has booted this hardware repeatedly.
# `.#nixos-firmware-image-mainline` writes the same layout over AXDL onto a
# board with nothing on it -- and when one of those did not come up (#94), the
# first question was whether the two carry the same boot chain at all.
#
# They did, byte for byte, and this check keeps it that way. For every region
# the migration writes, the `.axp` member and the kit image must agree over
# the member's whole length; the kit's images are the same bytes padded out to
# a 4 KiB multiple (so the script can `dd` and hash whole blocks), so the tail
# must be zeros and nothing else.
#
# `spl` is included even though the kit calls it the gate rather than a
# region: it is the one byte range whose contents decide whether the board has
# a first-stage loader at all.
#
# WHAT THIS DOES NOT COVER. The `rootfs` member exists only in the .axp -- the
# migration never writes one, because the whole point of the layout is that
# the root filesystem does not move. Nothing here can compare it, and nothing
# here says anything about what the FLASHER does with the bytes it is handed.
# ===========================================================================

let
  axp = "${nixos-firmware-image-mainline}/${project}-nixos_mainline.axp";

  # member in the .axp  ->  image in the kit. The kit's name is the region.
  pairs = [
    { member = "spl_mainline_${project}_signed.bin"; kit = "spl.bin"; }
    { member = "gpt_primary.bin"; kit = "gpt.bin"; }
    { member = "atf_mainline_bl31_signed.bin"; kit = "atf.bin"; }
    { member = "u-boot_mainline_signed.bin"; kit = "uboot.bin"; }
    { member = "uboot_env.bin"; kit = "env.bin"; }
    { member = "gpt_alternate.bin"; kit = "gptalt.bin"; }
  ];

  pairArgs = lib.concatMapStringsSep " "
    (p: lib.escapeShellArg "${p.member}:${p.kit}") pairs;
in
pkgs.runCommand "nanokvm-axp-migration-parity"
{
  nativeBuildInputs = [ pkgs.unzip pkgs.gzip ];
} ''
  set -euo pipefail
  mkdir members
  unzip -q -o ${axp} -d members

  fail=0
  for pair in ${pairArgs}; do
    member="members/''${pair%%:*}"
    kitimg="${migrate-layout}/images/''${pair##*:}"
    [ -r "$member" ] || { echo "MISSING member ''${pair%%:*} in the .axp" >&2; fail=1; continue; }
    [ -r "$kitimg" ] || { echo "MISSING kit image ''${pair##*:}" >&2; fail=1; continue; }

    msz=$(stat -c %s "$member")
    ksz=$(stat -c %s "$kitimg")
    if [ "$ksz" -lt "$msz" ]; then
      echo "FAIL ''${pair%%:*}: kit image is $ksz B, shorter than the member's $msz B" >&2
      fail=1; continue
    fi

    # The member's bytes, in full, must be the kit image's leading bytes.
    if ! cmp -n "$msz" "$member" "$kitimg"; then
      echo "FAIL ''${pair%%:*}: the .axp member and the kit image differ" >&2
      fail=1; continue
    fi

    # ... and the kit's 4 KiB padding must be nothing but zeros.
    pad=$(( ksz - msz ))
    if [ "$pad" -gt 0 ]; then
      nz=$(tail -c "$pad" "$kitimg" | tr -d '\000' | wc -c)
      if [ "$nz" -ne 0 ]; then
        echo "FAIL ''${pair##*:}: $nz non-zero byte(s) in the $pad B pad" >&2
        fail=1; continue
      fi
    fi
    echo "[ok] ''${pair%%:*}: $msz B identical to ''${pair##*:} (+ $pad B zero pad)"
  done

  # /boot is the odd one out: the kit ships it gzipped, because 272 MiB of
  # mostly-zero ext4 is the difference between a fast scp and a slow one.
  gzip -dc ${migrate-layout}/images/bootfs.ext4.gz > bootfs.kit
  if cmp members/bootfs.ext4 bootfs.kit; then
    echo "[ok] bootfs.ext4: $(stat -c %s bootfs.kit) B identical to the kit's bootfs.ext4.gz"
  else
    echo "FAIL boot: the .axp's /boot filesystem differs from the kit's" >&2
    fail=1
  fi

  [ "$fail" -eq 0 ] || {
    echo >&2
    echo "The flashable mainline image no longer carries the boot chain the" >&2
    echo "in-place migration has proven on hardware. See pkgs/axp-migration-parity.nix." >&2
    exit 1
  }

  echo
  echo "every boot-chain byte in the flashable mainline .axp is the byte the"
  echo "migration kit writes and the board has booted."
  : > "$out"
''
