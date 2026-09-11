{ config, lib, pkgs, nanokvm, ... }:

# ===========================================================================
# The mini-display (#84): the SPI panel's two kernel modules and the status
# daemon that draws on the framebuffer they register.
#
# ENABLES: `nanokvm-panel.service` (fbtft + fb_jd9853 -> /dev/fb0) and
# `nanokvm-display.service` (the Python status screen, the knob's two evdev
# devices, the backlight and the blank-and-wake behaviour).
#
# HARDWARE FACTS IT ENCODES: the panel is a JD9853 on spi2 (6072000.spi) with
# its backlight on PWM0, so a panel that never appears is usually a
# CONTROLLER fault and the unit's diagnosis separates the two; loading
# fb_jd9853 runs ~560 ms of power-on mdelay over SPI, which is why it is a
# module rather than built in; and the modules must never be unloaded.
#
# THIS UNIT NEVER FAILS. A KVM whose HDMI, USB and ethernet all work is not
# unhealthy because it has no status screen -- see `markGood.tolerateFailed`
# in the rollback module.
# ===========================================================================

let
  cfg = config.nanokvm;
in
{
  options.nanokvm = {
    panel.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Load the mini-display's panel modules at boot -- `fbtft` and
        `fb_jd9853` (#84) -- so that /dev/fb0 exists and
        `nanokvm-display.service` has something to draw on. They come out of
        this generation's own closure (`pkgs/display-modules.nix`), built from
        the same kernel derivation `boot.kernelPackages` names, exactly like
        the video stack's.

        Turning this off leaves a system with no /dev/fb0, which
        `nanokvm-display` treats as "no panel on this board" and skips.
        `nixos/qemu-test.nix` does that: there is no SPI panel on a QEMU virt
        machine, so the load would succeed and the framebuffer would never
        appear.
      '';
    };
  };

  config = {
    # 5d2. The mini-display's panel (#84). Two modules out of the generation's
    # own closure, then a check that /dev/fb0 actually appeared.
    #
    # Same shape as nanokvm-video above and a SEPARATE unit from it on purpose:
    # the two sets have different oracles, and a panel that did not come up
    # must not read as a capture failure (or stop the server from starting).
    #
    # Why these two are modules at all is argued in pkgs/display-modules.nix:
    # loading fb_jd9853 runs the vendor's power-on sequence twice, ~560 ms of
    # mdelay plus two resets over SPI, and a hang in there must cost a dead
    # unit rather than a kernel that never reaches userspace. THE OTHER HALF OF
    # THAT RULE IS NOT ENFORCEABLE HERE: never unload them. On the vendor 4.19
    # driver that hard-hangs the board; the cause is structurally absent from
    # our port, and it has never been tested. Test at boot.
    #
    # THIS UNIT NEVER FAILS, for the reason nanokvm-wifi does not (#85): a
    # `Type=oneshot` that exits non-zero over absent optional hardware makes
    # `systemctl is-system-running` report `degraded`, which makes
    # nanokvm-mark-good poll its whole timeout and give up, which leaves
    # `bootcount` uncleared -- so every reboot counts as a failed attempt and
    # the fourth rolls the board onto the fallback generation. A KVM whose
    # HDMI, USB and ethernet all work is not unhealthy because it has no
    # status screen. Every dead end here is a journal line and `exit 0`, and
    # nanokvm.markGood.tolerateFailed is the second belt on the same trousers.
    systemd.services.nanokvm-panel = {
      description = "NanoKVM-Pro mini-display panel (fbtft + JD9853)";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm-display.service" ];
      after = [ "systemd-modules-load.service" ];
      path = [ pkgs.kmod ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        if cfg.panel.enable then ''
          say() { echo "nanokvm-panel: $*"; }
          note() { echo "nanokvm-panel: $*" >&2; }

          # `uname -r` rather than a baked-in release, for the same reason
          # nanokvm-video does it: a generation running on a kernel it was not
          # built for says so here, with a path that names the mismatch, rather
          # than at the first insmod with a vermagic error.
          dir=${nanokvm.display-modules}/lib/modules/$(uname -r)
          if [ ! -r "$dir/load-order" ]; then
            note "$dir does not exist: this generation's panel modules were"
            note "built for a different kernel than the one /boot booted."
            note "No /dev/fb0; the status daemon will not start."
            exit 0
          fi
          while read -r ko; do
            [ -n "$ko" ] || continue
            if [ -d "/sys/module/$(basename "$ko" .ko | tr - _)" ]; then
              say "$ko already loaded"
              continue
            fi
            if insmod "$dir/$ko"; then
              say "insmod $ko"
            else
              note "insmod $ko failed -- see dmesg for the driver's own reason."
              break
            fi
          done < "$dir/load-order"

          # The oracle. fb_jd9853 can load cleanly and still register no
          # framebuffer -- a failed SPI transfer, a GPIO it could not claim, a
          # panel that did not answer. /dev/fb0 is what the daemon opens.
          for _ in $(seq 1 20); do
            [ -e /dev/fb0 ] && break
            sleep 0.25
          done
          if [ -e /dev/fb0 ]; then
            say "/dev/fb0 up"
            exit 0
          fi

          # The diagnosis, in the journal, in the order that separates the
          # causes. The panel hangs off spi2, and the single fact that says
          # whether anything could have bound is whether the SPI MASTER
          # probed: with no /sys/bus/spi/devices/spi2.1 there is no device for
          # fb_jd9853 to attach to and the fault is the controller (its
          # clocks, its resets, its pinctrl), not the panel driver. #84 lost
          # its first hardware round to exactly this: five clock rows the
          # binding header declared and the clock table never registered, so
          # dw_spi_mmio and dwc-pwm-of both failed clk_get with -ENOENT.
          note "modules loaded but /dev/fb0 never appeared."
          if [ -e /sys/bus/platform/drivers/dw_spi_mmio/6072000.spi ]; then
            note "spi2 (6072000.spi) IS bound; the panel itself did not answer."
          else
            note "spi2 (6072000.spi) did NOT bind -- no SPI device for the panel."
            note "check: dmesg | grep -iE '6072000|dw_spi|dwc-pwm', and"
            note "       /sys/kernel/debug/devices_deferred"
          fi
          note "spi devices: $(ls /sys/bus/spi/devices 2>/dev/null | tr '\n' ' ')"
          exit 0
        '' else ''
          echo "nanokvm-panel: DISABLED (nanokvm.panel.enable = false)."
          echo "               No /dev/fb0; the status daemon will not start."
        '';
    };

    # 5e. Mini-display status daemon. Draws the status screen on /dev/fb0 and
    # reads the knob's two evdev devices; the panel itself is nanokvm-panel
    # above, which is ordered before this.
    #
    # ConditionPathExists rather than a hard dependency: a board with no panel
    # (or with nanokvm.panel.enable = false) should simply not run the daemon,
    # not accumulate a failed unit.
    #
    # `path` carries nanokvm-gpio because that is how the daemon reads the
    # target's power-LED sense on mainline -- there is no sysfs GPIO export any
    # more and global line numbers are not stable, so the line is addressed by
    # its device-tree name (#81, #84).
    #
    # AND iproute2, which is the whole of the daemon's network line. NixOS
    # gives a unit coreutils, findutils, gnugrep, gnused and systemd and
    # nothing else, so `ip -j -4 addr` was an ENOENT the daemon caught and
    # turned into an empty address list -- a panel that read "no network" in
    # amber on a board that was routed, serving and reachable over SSH. It
    # cost nothing to find on hardware and would have been invisible offline
    # (the 4.19 image ran this daemon with an Ubuntu PATH). #84, 2026-09-11.
    systemd.services.nanokvm-display = {
      description = "NanoKVM-Pro mini-display status screen";
      wantedBy = [ "multi-user.target" ];
      after = [ "nanokvm-panel.service" ];
      unitConfig.ConditionPathExists = "/dev/fb0";
      path = [ nanokvm.nanokvm-gpio pkgs.iproute2 ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.python3}/bin/python3 ${nanokvm.nanokvm-display}/opt/nanokvm-display/nanokvm_display.py";
        Restart = "on-failure";
        RestartSec = 5;
        Nice = 10;
      };
    };
  };
}
