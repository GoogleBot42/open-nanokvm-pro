{ lib, pkgs, ... }:

# ===========================================================================
# The reversible on-device root (#78).
#
# The device's only writable medium is the eMMC, and p17 carries the running
# vendor system -- the only way back onto the board short of AXDL and Jeremy's
# hands. There is no SD card in the unit. So the first NixOS boot on hardware
# does not get a partition: it gets a rootfs IMAGE FILE dropped onto p17, which
# stage 1 loop-mounts. Nothing is overwritten and rolling back is `rm` plus the
# slot-B restore the harness already does.
#
# Procedure: `.claude/skills/mainline-boot-test/SKILL.md`, "Variant: booting
# the NixOS appliance from slot B".
# ===========================================================================

{
  nanokvm.rootImage.enable = true;

  # THE SAFETY PROPERTY OF THE WHOLE HARNESS. The SPL treats `SLOTB_BOOTABLE`
  # as consume-once and nothing in a slot-B image re-arms it, so every exit
  # path -- clean boot, panic, hang, watchdog reset -- lands the next boot on
  # slot A by itself. `nanokvm-checkboot` is precisely the thing that would
  # re-arm it: on a successful slot-B boot it finds `bootsystem=B` and writes
  # `0x2390028 = 0x20`, and the board then stays on B. Off, here.
  nanokvm.checkboot.enable = false;

  # Keep the vendor rootfs -- the filesystem this image is a file on -- visible
  # to the booted system. Two uses, both specific to a test boot: root's
  # password comes off it (below), and the derived MAC can be checked against
  # the `hwaddress ether` line the vendor /init last wrote there, which is the
  # one comparison the identity derivation exists to pass.
  #
  # It has to be bind-mounted ACROSS the switch_root: stage 1 mounts the
  # carrier at /nanokvm-host in the initramfs's namespace, and switch_root
  # leaves that mount alive but unreachable by any path.
  boot.initrd.postMountCommands = ''
    mkdir -p "$targetRoot/vendor-root"
    mount --bind /nanokvm-host "$targetRoot/vendor-root" \
      || echo "nanokvm: could not bind the carrier filesystem into the new root" >&2

    # Root's password hash, harvested rather than built in -- the same trick
    # #77 used from the bring-up initramfs, and for the same reason: no
    # credential of any kind belongs in this image, the Nix store or the
    # repository, and `tools/kvmssh` must reach this system with the password
    # it already knows. The vendor hashes with yescrypt, which NixOS's
    # libxcrypt verifies.
    mkdir -p "$targetRoot/root"
    if grep -q '^root:' /nanokvm-host/etc/shadow 2>/dev/null; then
      grep '^root:' /nanokvm-host/etc/shadow | cut -d: -f2 \
        > "$targetRoot/root/.vendor-root-hash"
      chmod 0600 "$targetRoot/root/.vendor-root-hash"
    else
      echo "nanokvm: no root entry in the carrier's /etc/shadow -- this boot" >&2
      echo "         will not accept the device's usual password" >&2
    fi
  '';

  users.users.root.hashedPasswordFile = lib.mkForce "/root/.vendor-root-hash";

  # ---- BOOT EVIDENCE ----------------------------------------------------
  # The appliance is reached over the network, so when it does not appear on
  # the network there is nothing to read -- "never booted", "booted and hung"
  # and "booted fine but the DHCP server moved it" are one indistinguishable
  # blank. The #75 milestone register answers that from slot A afterwards, and
  # it costs three `devmem` writes.
  #
  # Bits 12-24 belong to the bring-up initramfs (#75-#77, #82). 25-29 are
  # still free; this takes three of them. Clear them when arming slot B:
  #   devmem 0x0239002C 32 0x7FFF000
  # and read them back from slot A with `devmem 0x02390024`.
  #
  #   25 (0x2000000)  multi-user.target reached
  #   26 (0x4000000)  a routable IPv4 address is configured
  #   27 (0x8000000)  sshd is listening on :22
  systemd.services.nanokvm-slotb-milestones = {
    description = "Record slot-B boot milestones in the A/B slot register";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ busybox coreutils iproute2 ];
    script = ''
      # +0x4 is the write-1-to-set alias, so a milestone never needs a
      # read-modify-write and can never disturb the slot bits themselves.
      devmem 0x02390028 32 0x2000000
      for _ in $(seq 1 60); do
        if ip -4 -br addr show scope global | grep -q .; then
          devmem 0x02390028 32 0x4000000
          break
        fi
        sleep 2
      done
      for _ in $(seq 1 30); do
        if ss -ltn 2>/dev/null | grep -q ':22 '; then
          devmem 0x02390028 32 0x8000000
          break
        fi
        sleep 2
      done
      echo "slotb-milestones: BACKUP0 now $(devmem 0x02390024)"
    '';
  };

  # ---- THE WAY OUT ------------------------------------------------------
  # A slot-B test image must have one, and the appliance does not get one for
  # free the way the #75 bring-up initramfs did. That `/init` always ended in
  # reboot(2), so every path out of it landed on slot A within the dwell. An
  # appliance does the opposite: it is supposed to stay up, and the kernel's
  # watchdog driver pets the dog U-Boot armed forever
  # (WATCHDOG_HANDLE_BOOT_ENABLED=y, WATCHDOG_OPEN_TIMEOUT=0), so a boot that
  # comes up but cannot be reached has no exit at all. That is not theory: the
  # second hardware run of #78 booted, failed to appear on the network, and
  # stranded the board on slot B until it was power-cycled by hand.
  #
  # Two nets, covering the two halves of the boot.

  # 1. Stage 1. `fail()` in the NixOS stage-1 script is INTERACTIVE -- it
  #    prints a menu and blocks in `read -n 1 reply` on /dev/console. On a
  #    board whose console is on pads nobody can reach, that blocks forever
  #    with the watchdog petted. `panicOnFail` turns it into `exit 1`, PID 1
  #    exits, the kernel panics, and CONFIG_PANIC_TIMEOUT=5 restarts the board
  #    onto slot A. Upstream only sets it from the kernel command line
  #    (`boot.panic_on_fail`), and this board's command line comes from the
  #    U-Boot environment, so it is set here instead -- preDeviceCommands is
  #    spliced in after the cmdline parse and after `trap 'fail' 0`, which is
  #    exactly where the variable has to land.
  boot.initrd.preDeviceCommands = lib.mkBefore ''
    panicOnFail=1
  '';

  # 2. Userspace. A bounded dwell, then reboot -- the same one-way keepalive
  #    idiom the bring-up initramfs uses (#77). Pulled from basic.target, not
  #    multi-user.target, so it is already counting if the boot stalls before
  #    multi-user. `touch /run/keepalive` from a shell buys another hour, once
  #    per touch, and nothing here raises the cap.
  systemd.services.nanokvm-slotb-deadman = {
    description = "Leave the slot-B test: reboot after a bounded dwell";
    wantedBy = [ "basic.target" ];
    after = [ "basic.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "no";
    };
    path = with pkgs; [ coreutils systemd ];
    script = ''
      dwell=1800
      deadline=$(( $(date +%s) + dwell ))
      echo "slotb-deadman: rebooting to slot A in $dwell s unless /run/keepalive appears"
      while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 15
        if [ -e /run/keepalive ]; then
          rm -f /run/keepalive
          deadline=$(( $(date +%s) + 3600 ))
          echo "slotb-deadman: keepalive taken, one hour more"
        fi
      done
      echo "slotb-deadman: dwell expired, rebooting -- nothing re-armed slot B"
      systemctl --no-block reboot
    '';
  };
}
