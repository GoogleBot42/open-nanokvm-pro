{ pkgs, nanokvm-usbdev, ... }:

# ===========================================================================
# THE GADGET'S ENDPOINT BUDGET, OVER EVERY FLAG COMBINATION (#82) --
# `nix flake check`'s `usb-gadget-budget`.
#
# An over-budget gadget does not lose a function, it loses the bind: the UDC
# write fails with `failed to start g0: -19` and the keyboard goes with it.
# So the admission order in usbdev.sh's plan() is product behaviour, and this
# pins it: all sixteen combinations of /boot/usb.{disk0,ncm,uac2,acm}, the
# functions each one binds, and that hid-only binds HID and nothing else
# whatever the flags say. The table is written out rather than recomputed so
# that a change to a function's endpoint cost has to change it here too, on
# purpose.
#
# Costs (IN/OUT, ep0 excluded, 7/7 available): hid set 3/3, disk0 1/1,
# ncm 2/1, uac2 1/1 (adaptive capture: no feedback IN), acm 2/1.
#
# usbdev.sh is the aarch64 build; its `plan` verb uses only bash builtins, so
# the build platform's bash runs it.
# ===========================================================================

pkgs.runCommand "usb-gadget-budget-check" { } ''
  set -eu
  script=${nanokvm-usbdev}/bin/usbdev.sh
  fail() { echo "usb-gadget-budget: $*" >&2; exit 1; }

  # flags (disk0 ncm uac2 acm as 0/1) -> the optional functions bound
  check() {
    local flags=$1 want=$2 mode=''${3:-normal} dir got
    dir=$(mktemp -d)
    [ "''${flags:0:1}" = 1 ] && touch "$dir/usb.disk0"
    [ "''${flags:1:1}" = 1 ] && touch "$dir/usb.ncm"
    [ "''${flags:2:1}" = 1 ] && touch "$dir/usb.uac2"
    [ "''${flags:3:1}" = 1 ] && touch "$dir/usb.acm"
    got=$(USBDEV_BOOT_DIR=$dir ${pkgs.bash}/bin/bash "$script" plan "$mode" \
          | sed -n 's/^functions: hid.GS0 hid.GS1 hid.GS2 *//p' | sed 's/ *$//')
    [ "$got" = "$want" ] \
      || fail "flags $flags ($mode): bound '$got', want '$want'"
    left=$(USBDEV_BOOT_DIR=$dir ${pkgs.bash}/bin/bash "$script" plan "$mode" \
           | sed -n 's/^endpoints left: \([0-9]*\) IN \([0-9]*\) OUT$/\1 \2/p')
    [ -n "$left" ] || fail "flags $flags ($mode): no endpoint summary"
    echo "flags $flags ($mode): $got [left $left]"
  }

  check 0000 ""
  check 1000 "mass_storage.disk0"
  check 0100 "ncm.usb0"
  check 0010 "uac2.usb0"
  check 0001 "acm.usb0"
  check 1100 "mass_storage.disk0 ncm.usb0"
  check 1010 "mass_storage.disk0 uac2.usb0"
  check 1001 "mass_storage.disk0 acm.usb0"
  check 0110 "ncm.usb0 uac2.usb0"
  check 0101 "ncm.usb0 acm.usb0"
  check 0011 "uac2.usb0 acm.usb0"
  check 1110 "mass_storage.disk0 ncm.usb0 uac2.usb0"
  check 1101 "mass_storage.disk0 ncm.usb0"
  check 1011 "mass_storage.disk0 uac2.usb0 acm.usb0"
  check 0111 "ncm.usb0 uac2.usb0"
  check 1111 "mass_storage.disk0 ncm.usb0 uac2.usb0"
  check 1111 "" hid-only
  check 0000 "" hid-only

  # The full set fits exactly: no IN left over, so one more IN anywhere in
  # it is a dead gadget.
  d=$(mktemp -d); touch "$d/usb.disk0" "$d/usb.ncm" "$d/usb.uac2"
  USBDEV_BOOT_DIR=$d ${pkgs.bash}/bin/bash "$script" plan | grep -qx 'endpoints left: 0 IN 1 OUT' \
    || fail "HID + disk0 + ncm + uac2 no longer leaves exactly 0 IN 1 OUT"

  # And the descriptor side of the uac2 cost: capture on, adaptive, no
  # feature units -- the three settings the 1/1 above depends on.
  for want in 'echo 3        > "$d/c_chmask"' 'echo adaptive > "$d/c_sync"' \
              'for fu in p_mute_present p_volume_present c_mute_present c_volume_present; do'; do
    grep -qF "$want" "$script" || fail "usbdev.sh lost: $want"
  done

  echo ok > $out
''
