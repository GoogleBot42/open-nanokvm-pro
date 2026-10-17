{ pkgs, toplevel, ... }:

# ===========================================================================
# THE GADGET'S HOST-FACING UNITS, READ OUT OF THE BUILT SYSTEM (#82) --
# `nix flake check`'s `usb-gadget-units`.
#
# Two of the three things nixos/modules/usb.nix sets are invisible when they
# go wrong: the board boots, every unit is green, and the host simply gets no
# address or no login prompt. So assert them in the toplevel, not the module:
#
#   * NOTHING is written for serial-getty@ttyGS0 -- no unit file, no
#     drop-in. An instance unit shadows the serial-getty@ template (no
#     ExecStart), and an `asDropin` override lands in overrides.conf, the
#     same name as the template's own ExecStart override, which it then
#     replaces: the getty ran `/usr/bin/agetty` and looped on hardware. Both
#     builds of this module did one of the two; and the template carries
#     ConditionPathExists=/dev/%I, without which a gadget teardown
#     start-limits the getty into a failed unit;
#   * the udev rule that starts it when acm.usb0 binds is in the image;
#   * usb0's .network sorts ahead of nixpkgs' default DHCP-client files and
#     offers no router, so a host that plugs in never routes through the KVM.
# ===========================================================================

pkgs.runCommand "usb-gadget-units-check" { } ''
  set -eu
  sys=${toplevel}/etc/systemd/system
  net=${toplevel}/etc/systemd/network

  fail() { echo "usb-gadget-units: $*" >&2; exit 1; }

  for f in "$sys/serial-getty@ttyGS0.service" "$sys/serial-getty@ttyGS0.service.d"; do
    [ ! -e "$f" ] || fail "$f exists; it shadows the serial-getty@ template or its ExecStart"
  done
  grep -q 'KERNEL=="ttyGS0".*SYSTEMD_WANTS.*serial-getty@ttyGS0.service' \
    ${toplevel}/etc/udev/rules.d/*.rules \
    || fail "no udev rule starts serial-getty@ttyGS0"
  grep -q '^ExecStart=.*agetty' "$sys/serial-getty@.service.d/"*.conf \
    || fail "the serial-getty@ template lost its agetty ExecStart"
  grep -qx 'ConditionPathExists=/dev/%I' "$sys/serial-getty@.service.d/"*.conf \
    || fail "serial-getty@ has no ConditionPathExists=/dev/%I: a gadget teardown start-limits it into failed"

  f=$net/40-usb-gadget-ncm.network
  [ -f "$f" ] || fail "no 40-usb-gadget-ncm.network"
  first=$(ls "$net" | grep '\.network$' | head -1)
  [ "$first" = 40-usb-gadget-ncm.network ] \
    || fail "$first sorts ahead of the usb0 network"
  for want in 'Name=usb0' 'DHCPServer=true' 'EmitRouter=false' 'EmitDNS=false' \
              'IPv6AcceptRA=false' 'RequiredForOnline=no'; do
    grep -qx "$want" "$f" || fail "$f lacks $want"
  done

  echo ok > $out
''
