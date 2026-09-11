{ config, lib, pkgs, nanokvm, ... }:

# ===========================================================================
# ATX power, reset and the target's two front-panel LEDs (#81).
#
# ENABLES: `nanokvm-gpio` on the system PATH. That is the whole module -- and
# the absence of a unit is the result, not a gap.
#
# HARDWARE FACTS IT ENCODES: the four lines are named in the device tree
# (`atx-power`, `atx-reset`, `atx-power-led`, `atx-hdd-led`), and REQUESTING
# one runs through gpio-ranges -> gpio_request_enable(), so the pin controller
# programs the pad. That retires the SW_PWR pinmux trap: gpio7 lives on the
# VI_D7 pad and a sysfs export never programmed its mux, so "reset works but
# power does not" was the signature for a year. Global GPIO numbers are not
# stable on mainline; the line name is the address.
# ===========================================================================

{
  config = {
    # 5b. NO ATX GPIO UNIT AT ALL, and that is the #81 result rather than a
    # gap. The 4.19 image had one: it poked the VI_D7 pad mux with `devmem` and
    # exported gpio 7/35/74/75 through /sys/class/gpio (the SW_PWR pinmux trap,
    # docs/mini-display.md). Neither half has anything to do here. There is
    # nothing to export, because consumers address lines by their device-tree
    # name (dts/ax630c-nanokvm-pro.dts: atx-power, atx-reset, atx-power-led,
    # atx-hdd-led); and nothing to mux by hand, because requesting a line runs
    # through gpio-ranges -> gpio_request_enable() and the pin controller
    # programs the pad. The tool that does the requesting is `nanokvm-gpio` in
    # environment.systemPackages below, and the server reaches it by absolute
    # store path (pkgs/nanokvm-server.nix).
    #
    # This module therefore stubs the POLICY half of #82 alone. #81 and #83
    # both landed: 5a loads the video modules for real, and the board streams.
    # mkOrder pins where this lands in the one merged list (#87).
    environment.systemPackages = lib.mkOrder 200 [
      # ATX power/reset/LED by device-tree line name (#81) -- the replacement
      # for the deleted sysfs-export unit. On PATH so it can be driven by hand;
      # the server reaches it by store path, not through PATH.
      nanokvm.nanokvm-gpio
    ];
  };
}
