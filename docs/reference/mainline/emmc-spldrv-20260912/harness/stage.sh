#!/usr/bin/env bash
# Stage a U-Boot candidate in the one-shot chainload slot and arm the round.
#
#   harness/stage.sh <attr>        e.g. uboot-mainline, uboot-mainline-spldrv
#
# Builds the variant, copies the RAW u-boot.bin to the board, stages it, and
# prints what to read afterwards. Writes NOTHING to the eMMC: the slot is a
# file on /boot and the recovery path is the production U-Boot already in the
# `uboot` partition (#91, docs/reference/mainline/emmc-spldrv-20260912).
set -euo pipefail

attr="${1:?usage: stage.sh <flake attr>}"
repo="$(cd "$(dirname "$0")/../../../../.." && pwd)"

out=$(nix build --no-link --print-out-paths "$repo#$attr")
img="$out/images/u-boot.bin"
[ -f "$img" ] || { echo "no $img" >&2; exit 1; }

echo "candidate: $attr"
echo "  $(stat -c%s "$img") bytes, md5 $(md5sum < "$img" | cut -d' ' -f1)"

# The identity check nanokvm-uboot-test will also make, made here so a wrong
# artefact is caught before it costs a boot cycle: start.S puts
# `_TEXT_BASE: .quad CONFIG_TEXT_BASE` at offset 8.
got=$(od -An -tx8 -j8 -N8 "$img" | tr -d ' \n')
[ "$got" = "000000005c000400" ] \
  || { echo "ERROR: _TEXT_BASE at offset 8 is $got, not 0x5C000400" >&2; exit 1; }

"$repo/tools/kvmscp" "$img" :/root/uboot-test.bin
"$repo/tools/kvmssh" "nanokvm-uboot-test stage /root/uboot-test.bin"

cat <<'EOF'

Now: reboot, wait (a mainline boot is 3-25 min today; poll 30), then

  nanokvm-uboot-test status
  journalctl -b -u nanokvm-uboot-test-clear
  dd if=/dev/mem bs=4096 skip=295144 count=2 2>/dev/null | tr -d '\000'

chainload: yes + ms_uboot set  = two U-Boot passes, the candidate ran
chainload: yes + ms_uboot CLEAR = it jumped and the candidate died early
chainload: no                   = the load never happened
EOF
