{ config, lib, pkgs, nanokvm, ... }:

# ===========================================================================
# The open capture and encode stack (#83, #55): the kernel modules that turn
# the LT6911UXC's CSI-2 stream into /dev/video0 and give the VC8000E encoder
# its command queue.
#
# ENABLES: `nanokvm-video.service`, which insmods
# `<video-modules>/lib/modules/$(uname -r)` in the order the kernel build's
# depmod resolved and then waits for /dev/video0.
#
# HARDWARE FACTS IT ENCODES: the modules are built from the SAME kernel
# derivation `boot.kernelPackages` names, so a generation carries the drivers
# it was built with and cannot be booted on a kernel it was not built for;
# and every module can load cleanly and still leave no pipeline (a deferred
# probe, a rejected carveout), so the unit's oracle is the video node, not
# insmod's exit status.
#
# NOTHING HERE IS CLOSED. The capture and encoder drivers are ours, in the
# kernel tree at pkgs/kernel-mainline/tree/drivers/media/platform/axera.
# ===========================================================================

let
  cfg = config.nanokvm;
in
{
  options.nanokvm = {
    videoStack.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Load the open capture/encode kernel modules at boot: `open_vin_csi2`,
        `open_vin_capture` and `ax630c_venc_vcmd`, plus the videobuf2 modules
        the capture node imports (#83). They are in this generation's own
        closure (`pkgs/video-modules.nix`), built from the same kernel
        derivation `boot.kernelPackages` names -- so a generation and the
        kernel it boots cannot disagree about them (#99). The load order is
        `<video-modules>/lib/modules/<release>/load-order`.

        Turning this off gives a server that serves the UI but no stream.
        `nixos/qemu-test.nix` does exactly that: the modules load fine on a
        QEMU virt machine and then nothing probes, so the unit's /dev/video0
        oracle fails on a boot that is otherwise perfect.
      '';
    };
  };

  config = {
    # The video stack (#83). Six modules out of the generation's own
    # closure, in the order the kernel build's depmod resolved, then a check
    # that the pipeline actually came up.
    #
    # THE MODULES AND THEIR KERNEL ARE IN THE SAME GENERATION (#99).
    # pkgs/video-modules.nix copies the .ko set out of the kernel derivation
    # `boot.kernelPackages` names, so a generation carries the drivers it was
    # built with and cannot be booted on a kernel it was not built for. #83
    # shipped with a caveat here -- the Image was a /boot artefact outside every
    # generation, so the two could disagree with nothing able to detect it,
    # because the vermagic is the release string alone and does not change when
    # a built-in driver does. #99 closed that by construction.
    #
    # insmod, not modprobe: the order is six lines long, it ships next to the
    # modules, and an explicit order is a mechanism a reader can check. (The
    # package also carries depmod output, so `modprobe -d` works by hand.)
    systemd.services.nanokvm-video = {
      description = "NanoKVM-Pro open video stack (capture + encoder modules)";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm.service" ];
      after = [ "systemd-modules-load.service" ];
      path = [ pkgs.kmod ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        if cfg.videoStack.enable then ''
          set -e
          # `uname -r` rather than a baked-in release string, so a generation
          # running on a kernel it was not built for fails HERE, with a path
          # that names the mismatch, instead of at the first insmod with a
          # vermagic error -- or worse, not at all.
          dir=${nanokvm.video-modules}/lib/modules/$(uname -r)
          if [ ! -r "$dir/load-order" ]; then
            echo "nanokvm-video: $dir does not exist." >&2
            echo "               This generation's modules were built for a" >&2
            echo "               different kernel than the one /boot booted." >&2
            exit 1
          fi
          while read -r ko; do
            [ -n "$ko" ] || continue
            if [ -d "/sys/module/$(basename "$ko" .ko | tr - _)" ]; then
              echo "nanokvm-video: $ko already loaded"
              continue
            fi
            echo "nanokvm-video: insmod $ko"
            insmod "$dir/$ko"
          done < "$dir/load-order"

          # The oracle, not a formality: every module above can load cleanly
          # and still leave no pipeline if a probe deferred or a carveout was
          # rejected. /dev/video0 is what the server opens.
          for _ in $(seq 1 20); do
            [ -e /dev/video0 ] && break
            sleep 0.25
          done
          if [ ! -e /dev/video0 ]; then
            echo "nanokvm-video: modules loaded but /dev/video0 never appeared" >&2
            exit 1
          fi
          echo "nanokvm-video: /dev/video0 up"
        '' else ''
          echo "nanokvm-video: DISABLED (nanokvm.videoStack.enable = false)."
          echo "               No /dev/video0; the server will serve the UI"
          echo "               but not a stream."
        '';
    };
  };
}
