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
# WHY A SEPARATE DERIVATION rather than referencing the kernel directly: the
# kernel output carries a 51 MB Image and a 63 MB vmlinux, and a systemd unit
# that named it would drag both into the system closure. This copies out the
# ~280 KB that actually gets loaded, so the kernel is a BUILD-time dependency
# of the appliance and not a runtime one.
#
# WHERE IT SITS, and the honest statement of the seam: the modules are in the
# NixOS generation. The kernel they load into is not -- it is a /boot artefact
# the boot chain reads (pkgs/boot-payload.nix), outside any generation. So a
# generation and its kernel can in principle disagree, and nothing here can
# catch it: the vermagic is the release string alone, which does not change
# when a built-in driver does. The follow-up rung that moves the kernel, the
# initrd and the dtb into the generation through NixOS' own extlinux builder
# is what closes that, and this package is written to need no change when it
# does.
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
