{ pkgs
, kernel # pkgs/kernel-mainline.nix, the appliance variant
, ...
}:

# ===========================================================================
# The mini-display's kernel modules, as an ordinary package in the appliance's
# closure (#84). Same shape as pkgs/video-modules.nix, and a SEPARATE package
# from it on purpose: the two sets answer to different services with different
# oracles (/dev/video0 and /dev/fb0), and a failure in one must not read as a
# failure in the other.
#
# Two modules, ~40 KB: the fbtft core and the JD9853 panel driver
# (drivers/staging/fbtft/fb_jd9853.c, ported from the SDK's GPL copy). The
# panel's SPI controller, its backlight PWM, the knob's gpio-keys and
# rotary-encoder and the heartbeat LED are all built in -- they are stock
# mainline drivers that bind from DT and cost nothing.
#
# WHY THESE TWO ARE MODULAR. Loading fb_jd9853 runs the vendor's power-on
# sequence twice: ~560 ms of mdelay plus two hardware resets and ~40 SPI
# register writes. Built in, a hang anywhere in there is a kernel that never
# reaches userspace, which on this board costs a bootcount rollback. As a
# module the system is already up when it happens, `nanokvm-panel.service`
# fails, and the board is still reachable to try again.
#
# The other half of that rule is unchanged and is NOT enforced here, because
# nothing in software can enforce it: **never unload fb_jd9853**. On the
# vendor 4.19 driver that hard-hangs the device, and although the cause is
# understood and structurally absent from this port (the vendor's
# init_display() overwrote the SPI device's drvdata, so its remove path read a
# private struct as a fb_info and made an indirect call through slab garbage),
# it has never been tested here. Test at boot. See docs/mini-display.md.
# ===========================================================================

pkgs.runCommand "nanokvm-display-modules-${kernel.version}"
{
  nativeBuildInputs = [ pkgs.kmod ];
  meta.description =
    "Mini-display panel modules for the NanoKVM-Pro (#84), laid out as /lib/modules/<release>";
} ''
  rel=$(cat ${kernel}/kernelrelease)
  d="$out/lib/modules/$rel"
  mkdir -p "$d"

  install -m 0644 ${kernel}/display-modules/*.ko "$d/"
  install -m 0644 ${kernel}/display-modules/load-order "$d/load-order"

  depmod -b "$out" "$rel"

  while read -r ko; do
    [ -f "$d/$ko" ] \
      || { echo "ERROR: load-order names $ko, which is not here" >&2; exit 1; }
  done < "$d/load-order"

  # fbtft must come FIRST: fb_jd9853 imports its symbols and the loader is a
  # plain insmod, not modprobe.
  head -n1 "$d/load-order" | grep -qxF 'fbtft.ko' \
    || { echo "ERROR: fbtft.ko is not first in the load order" >&2; exit 1; }
  grep -qxF 'fb_jd9853.ko' "$d/load-order" \
    || { echo "ERROR: fb_jd9853.ko is not in the load order" >&2; exit 1; }

  echo "=== $rel ==="
  cat "$d/load-order"
  ls -l "$d"
''
