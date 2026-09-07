{ config, lib, pkgs, ... }:

# ===========================================================================
# The appliance, retargeted at `qemu-system-aarch64 -M virt` (#78).
#
# WHY: this board has no serial console (UART0 on hidden pads) and no autoboot
# interrupt window, so a stage 1 that dies on it is completely silent. Every
# NixOS-side failure mode -- an initrd that cannot find its root, a stage-2
# script that is not a script, a unit that dies at 217/USER -- is identical to
# "the kernel hung" when read through a milestone register. QEMU is where those
# are separated from hardware faults, before a single byte is written to eMMC.
#
# What this DOES prove: the embedded-initrd boot contract (kernel -> NixOS
# stage 1 -> switch_root to /init on the root filesystem, with no `init=` on
# the command line), that the system closure boots to multi-user, and that the
# units below behave when the hardware they want is absent.
#
# What it does NOT prove: anything about the AX630C. The device tree, the
# clocks, eMMC, Ethernet and the watchdog are all QEMU's here, not ours.
# ===========================================================================

{
  # `-device virtio-blk-device,drive=...` on the virt machine, no partition
  # table: the raw ext4 image IS the disk.
  nanokvm.rootDevice = "/dev/vda";

  # There is no vfat p16 in QEMU. The mount is already `nofail`, so the boot
  # would survive it, but a 90 s device timeout on every run is noise that
  # hides the thing being tested.
  fileSystems."/boot" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
    options = [ "nofail" "mode=0755" ];
  };
  # A self-test that makes the run unattended and its result a diff-able
  # artifact instead of a login prompt somebody has to read. It runs after
  # multi-user.target, prints the state of everything #78 is responsible for,
  # and powers the machine off.
  systemd.services.nanokvm-qemu-selftest = {
    description = "Print the appliance's boot state and power off (QEMU only)";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    # config.environment.systemPackages, not a hand-picked list: the point of
    # the nanokvm-gpio probe below is that the appliance's own system PATH
    # carries it, so borrowing that PATH is the honest test.
    path = config.environment.systemPackages
      ++ (with pkgs; [ systemd coreutils util-linux ]);
    script = ''
      echo "=== nanokvm appliance self-test (#78) ==="
      echo "--- root filesystem ---"
      findmnt -no SOURCE,FSTYPE,OPTIONS / || true
      echo "--- stage 2 came from ---"
      readlink -f /run/current-system || true
      echo "--- /etc/fw_env.config ---"
      cat /etc/fw_env.config || echo "MISSING"
      echo "--- identity ---"
      echo "hostname: $(cat /proc/sys/kernel/hostname)"
      echo "device_key: $(cat /device_key 2>/dev/null || echo '(none -- no SoC UID here)')"
      echo "--- nanokvm-gpio (#81) ---"
      # On PATH, and it resolves lines by DT name -- so with no gpiochip in
      # QEMU the expected answer is a clean "no gpiochip names line", not a
      # missing binary. That distinguishes "#81 is wired into the appliance"
      # from "#81's tool is absent".
      command -v nanokvm-gpio || echo "MISSING from PATH"
      nanokvm-gpio get atx-power 2>&1 || true
      echo "--- app tree ---"
      ls -l /kvmapp/server/ /opt/lib/ 2>&1 | head -30
      echo "--- nanokvm units ---"
      systemctl --no-pager --no-legend list-units 'nanokvm*' || true
      echo "--- failed units ---"
      systemctl --no-pager --failed || true
      echo "--- nanokvm.service ---"
      systemctl --no-pager --full status nanokvm.service || true
      echo "--- NanoKVM-Server.log ---"
      tail -n 30 /var/log/nanokvm/NanoKVM-Server.log 2>&1 || true
      echo "--- nanokvm-checkboot ---"
      systemctl --no-pager --full status nanokvm-checkboot.service || true
      echo "=== self-test done, powering off ==="
      systemctl --no-block poweroff
    '';
  };
}
# The console (PL011 ttyAMA0 on the virt machine) is passed on QEMU's own
# `-append`, not through boot.kernelParams: with `boot.kernel.enable = false`
# nothing in this closure writes a command line anywhere, which is exactly the
# situation on the real board -- there, the cmdline comes from the U-Boot
# environment. Keeping it out of the module keeps that honest.
