{ lib, ... }:

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
}
