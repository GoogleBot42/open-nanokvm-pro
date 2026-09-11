{ pkgs
, kernel # pkgs/kernel-mainline.nix, the appliance variant
, ...
}:

# ===========================================================================
# The video stack's kernel modules, as an ordinary package in the appliance's
# closure (#83).
#
# The three drivers (`open_vin_csi2`, `open_vin_capture`, `ax630c_venc_vcmd`)
# and the two videobuf2 modules the capture node imports are the only modular
# code in this kernel; everything else is built in. They are modular because
# the capture and encode stack is the part still being brought up on hardware,
# and a driver fix should be a file copy and an insmod rather than a reboot
# into a kernel that has no automatic rollback.
#
# WHY A SEPARATE DERIVATION rather than referencing the kernel directly: this
# copies out the ~280 KB that actually gets loaded, so a systemd unit can name
# it without pulling anything else along. (The kernel IS in the closure since
# #99, as the generation's own `kernel` link -- but it is the Image alone; the
# vmlinux and the resolved .config live in that derivation's `dev` output.)
#
# WHERE IT SITS. The modules and the kernel they load into are now in the SAME
# generation: `boot.kernelPackages` names the derivation this package is built
# from. #83 had to write a caveat here -- the kernel was a /boot artefact
# outside every generation, so the two could disagree and nothing could catch
# it, because the vermagic is the release string alone and that does not change
# when a built-in driver does. #99 closed it by construction, and this file
# needed no change, which is what its author predicted.
#
# `nanokvm-video.service` still resolves the directory through `uname -r`
# rather than a baked-in release, so a generation running on a kernel it was
# not built for fails with a path that names the mismatch instead of at the
# first insmod with a vermagic error.
# ===========================================================================

pkgs.runCommand "nanokvm-video-modules-${kernel.version}"
{
  nativeBuildInputs = [ pkgs.kmod ];
  meta.description =
    "Open capture/encode kernel modules for the NanoKVM-Pro (#83), laid out as /lib/modules/<release>";
} ''
  rel=$(cat ${kernel}/kernelrelease)
  d="$out/lib/modules/$rel"
  mkdir -p "$d"

  install -m 0644 ${kernel}/modules/*.ko "$d/"
  install -m 0644 ${kernel}/modules/load-order "$d/load-order"

  # depmod's modules.dep is not what loads them -- nanokvm-video.service walks
  # load-order with insmod, because six explicit lines are a mechanism a reader
  # can check and a `modprobe` search path is not. It is generated anyway so
  # that `modinfo` and `modprobe -d` work for anyone debugging on the board.
  depmod -b "$out" "$rel"

  # The load order is the contract, so assert every line of it resolves.
  while read -r ko; do
    [ -f "$d/$ko" ] \
      || { echo "ERROR: load-order names $ko, which is not here" >&2; exit 1; }
  done < "$d/load-order"

  # And assert the three that are the point of the issue are among them: a
  # Kconfig symbol that silently went =y would leave a kernel that works and a
  # service that fails.
  for ko in open_vin_csi2 open_vin_capture ax630c_venc_vcmd; do
    grep -qxF "$ko.ko" "$d/load-order" \
      || { echo "ERROR: $ko.ko is not in the load order" >&2; exit 1; }
  done

  echo "=== $rel ==="
  cat "$d/load-order"
  ls -l "$d"
''
