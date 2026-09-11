{ config, lib, pkgs, ... }:

# ===========================================================================
# The boot-attempt safety net: U-Boot's `bootcount` rollback, the health gate
# that clears it, the hardware watchdog that makes a wedged PID 1 count as a
# failed boot, the A/B slot re-arm, and the one-shot U-Boot chainload test
# slot (#89 rung 5, #79, #91).
#
# ENABLES: `nanokvm-mark-good` on a timer -- it clears the boot counter and
# DERIVES /boot/extlinux/extlinux-fallback.conf from the config NixOS wrote,
# but only once the system is `running`, routed and serving;
# `nanokvm-checkboot`, which keeps the slot register deterministic;
# `nanokvm-uboot-test`, which stages a U-Boot candidate on /boot and arms a
# one-shot token in flash; and systemd's watchdog pings.
#
# HARDWARE FACTS IT ENCODES: U-Boot increments a counter in
# TOP_CHIPMODE_GLB_BACKUP1 (0x02390030) on every attempt and runs
# `altbootcmd` past `bootlimit` = 3; the AX630C WDT0's own timeout is 60 s;
# and this board has no console, so an unattended rollback is the ONLY way
# back from a generation that cannot boot.
#
# A PERIPHERAL THAT IS ALLOWED TO BE ABSENT MUST NOT BE ALLOWED TO FAIL:
# `markGood.tolerateFailed` is the second line of defence behind units that
# log and `exit 0` (#84, #85).
# ===========================================================================

let
  cfg = config.nanokvm;

  # ---- the two boot configs ----------------------------------------------
  #
  #   /boot/extlinux/extlinux.conf           NixOS writes it; the default boot
  #   /boot/extlinux/extlinux-fallback.conf  DERIVED from it by mark-good
  #
  # U-Boot's `bootcmd` runs `sysboot ... ${extlinux_cfg}`; its `altbootcmd`,
  # which `bootcount` > `bootlimit` selects, runs the same command against
  # ${extlinux_fallback}. `sysboot` boots a config's DEFAULT entry and has no
  # way to be told a LABEL, so the choice of generation is made by choosing a
  # FILE -- but since #99 the two files have the SAME labels, and only their
  # DEFAULT line differs. That is what makes the fallback a derivation of the
  # official config rather than a second generator: nothing in this repo
  # renders an extlinux.conf any more.
  #
  # nixos/lib/mark-good.nix is the script and its reasoning; it lives there
  # rather than here so `nix flake check`'s `nanokvm-mark-good-fallback` can
  # instantiate it against the BUILD host's package set and run it for real.
  markGood = import ../lib/mark-good.nix {
    inherit pkgs lib;
    serverEnabled = cfg.server.enable;
    timeoutSec = cfg.markGood.timeoutSec;
    tolerateFailed = cfg.markGood.tolerateFailed;
  };

  # ---- the U-Boot chainload test slot ------------------------------------
  # The minimal layout has one `uboot` partition and no B twin, so trying a
  # U-Boot candidate by writing it is a USB-recovery trip. U-Boot patch 0025
  # gives the partition its A/B property back as a FILE: on the first boot
  # attempt after a healthy one, `bootcmd` loads /boot/uboot-test.bin to
  # CONFIG_TEXT_BASE and chainloads it. This is the appliance's half -- putting
  # the file there, and taking it away again after the one attempt.
  #
  # NOTHING HERE WRITES FLASH. Staging is a copy; recovery is a reboot.
  ubootTest = pkgs.writeShellApplication {
    name = "nanokvm-uboot-test";
    runtimeInputs = with pkgs; [ coreutils busybox gnugrep ];
    text = ''
      set -eu

      TESTFILE=/boot/uboot-test.bin
      # The arming token, and the reason the slot is safe: one 512-byte block
      # at the head of the unused `env` partition. U-Boot zeroes it BEFORE it
      # jumps, so a candidate is tried exactly once, ever. It has to live in
      # flash -- an earlier version armed on `bootcount`, which clears on power
      # loss, so the cold cycle that recovers a hung board re-armed the
      # candidate that hung it and the board could not be recovered at all.
      TOKPART=/dev/loop0p3
      BOOTCOUNT_REG=0x02390030
      MSREG=0x02390024
      # The chainload record U-Boot leaves in the spare page of the pstore
      # window: 0x43484C44 ("CHLD") and the address it jumped to.
      CHLD_REG=0x480EE000
      CHLD_ADDR=0x480EE004

      usage() {
        cat >&2 <<'EOF'
      usage: nanokvm-uboot-test stage <u-boot.bin> | clear | status

        stage   put a RAW U-Boot image (images/u-boot.bin, device tree
                appended -- NOT the signed container) in the test slot. The
                next boot chainloads it, once. A candidate that hangs is reset
                by the watchdog and the boot after it runs the production
                U-Boot on flash, unattended.
        clear   remove it.
        status  say what is staged, and what the last boot did with it.
      EOF
        exit 2
      }

      [ $# -ge 1 ] || usage

      case "$1" in
      stage)
        [ $# -eq 2 ] || usage
        src="$2"
        [ -f "$src" ] || { echo "nanokvm-uboot-test: no such file: $src" >&2; exit 1; }
        [ -d /boot ] || { echo "nanokvm-uboot-test: /boot is not there" >&2; exit 1; }
        mountpoint -q /boot \
          || { echo "nanokvm-uboot-test: /boot is not mounted -- U-Boot would never see the file" >&2; exit 1; }

        size=$(stat -c%s "$src")
        if [ "$size" -lt 65536 ] || [ "$size" -gt 2097152 ]; then
          echo "nanokvm-uboot-test: $src is $size bytes; a U-Boot image for this board is 64 KiB..2 MiB" >&2
          exit 1
        fi

        # The image must be the RAW one, linked at 0x5C000400. arch/arm/cpu/
        # armv8/start.S puts `_TEXT_BASE: .quad CONFIG_TEXT_BASE` at offset 8,
        # so those eight bytes are a free, exact identity check -- and they are
        # what separates a raw u-boot.bin from the signed container
        # (which would be loaded and jumped into as if it were code), from a
        # kernel Image, and from a U-Boot built for another board.
        got=$(od -An -tx8 -j8 -N8 "$src" | tr -d ' \n')
        if [ "$got" != "000000005c000400" ]; then
          echo "nanokvm-uboot-test: $src does not carry _TEXT_BASE = 0x5C000400 at offset 8" >&2
          echo "nanokvm-uboot-test: found $got -- this is not a raw u-boot.bin for this board." >&2
          echo "nanokvm-uboot-test: stage images/u-boot.bin, NOT u-boot_mainline_signed.bin." >&2
          exit 1
        fi

        cp "$src" "$TESTFILE.new"
        sync "$TESTFILE.new"
        mv "$TESTFILE.new" "$TESTFILE"
        sync

        # Verify from the medium, not the page cache.
        echo 3 > /proc/sys/vm/drop_caches
        a=$(md5sum < "$src" | cut -d' ' -f1)
        b=$(md5sum < "$TESTFILE" | cut -d' ' -f1)
        [ "$a" = "$b" ] || { echo "nanokvm-uboot-test: read-back mismatch $a != $b" >&2; exit 1; }

        # Arm it, last: the token is what U-Boot acts on, so it must not be
        # there before the file it names is.
        [ -b "$TOKPART" ] || { echo "nanokvm-uboot-test: no $TOKPART" >&2; exit 1; }
        { printf 'CHTK'; dd if=/dev/zero bs=508 count=1 2>/dev/null; } \
          | dd of="$TOKPART" bs=512 count=1 conv=fsync 2>/dev/null
        sync
        echo 3 > /proc/sys/vm/drop_caches
        [ "$(dd if="$TOKPART" bs=4 count=1 2>/dev/null)" = CHTK ] \
          || { echo "nanokvm-uboot-test: token did not stick" >&2; exit 1; }

        echo "nanokvm-uboot-test: staged $size bytes, md5 $b"
        echo "nanokvm-uboot-test: armed (token CHTK in $TOKPART, spent by the attempt)"
        echo "nanokvm-uboot-test: bootcount is $(devmem $BOOTCOUNT_REG 32) (0xB0010000 = healthy)"
        echo "nanokvm-uboot-test: reboot to try it, then \`nanokvm-uboot-test status\`:"
        echo "  chainload: no                       nothing was chainloaded"
        echo "  chainload: yes, ms_uboot clear      the candidate never reached its own preboot"
        echo "  chainload: yes, ms_uboot set        two U-Boot passes in one boot"
        ;;
      clear)
        rm -f "$TESTFILE" "$TESTFILE.new"
        if [ -b "$TOKPART" ]; then
          dd if=/dev/zero of="$TOKPART" bs=512 count=1 conv=fsync 2>/dev/null
        fi
        sync
        echo "nanokvm-uboot-test: cleared (file and token)"
        ;;
      status)
        if [ -e "$TESTFILE" ]; then
          echo "staged: $(stat -c%s "$TESTFILE") bytes, md5 $(md5sum < "$TESTFILE" | cut -d' ' -f1)"
        else
          echo "staged: nothing"
        fi
        if [ -b "$TOKPART" ] && [ "$(dd if="$TOKPART" bs=4 count=1 2>/dev/null)" = CHTK ]; then
          echo "armed: yes -- the next boot will chainload it, once"
        else
          echo "armed: no (token spent or never written)"
        fi
        echo "bootcount: $(devmem $BOOTCOUNT_REG 32)"
        ms=$(devmem $MSREG 32)
        echo "milestones: $ms"
        # devmem prints 0x........; bit 28 is the top hex digit's bit 0.
        if [ "$(( ms & 0x10000000 ))" -ne 0 ]; then
          echo "  ms_uboot (28): set   -- a U-Boot reached preboot after the last write to this bit"
        else
          echo "  ms_uboot (28): CLEAR -- no U-Boot reached preboot since bootchain cleared it"
        fi
        chld=$(cat /run/nanokvm-uboot-test.chainload 2>/dev/null || devmem $CHLD_REG 32)
        if [ "$(( chld ))" -eq "$(( 0x43484C44 ))" ]; then
          echo "chainload: yes, to $(cat /run/nanokvm-uboot-test.addr 2>/dev/null || devmem $CHLD_ADDR 32)"
        else
          echo "chainload: no (record $chld)"
        fi
        ;;
      *)
        usage
        ;;
      esac
    '';
  };

  # ONE ATTEMPT, and this is what makes it one. U-Boot only chainloads at
  # `bootcount` == 1 and the candidate increments the counter itself, so a
  # staged file cannot loop the board -- but it would be retried after every
  # later healthy boot, which is a surprise nobody wants from a file they
  # forgot about. Removing it on the boot after it was staged makes the slot
  # strictly one-shot whichever way the attempt went.
  ubootTestClear = pkgs.writeShellApplication {
    name = "nanokvm-uboot-test-clear";
    runtimeInputs = with pkgs; [ coreutils busybox ];
    text = ''
      set -eu
      TESTFILE=/boot/uboot-test.bin

      # Latch the chainload record before anything else can lose it, and zero
      # it, so a record that is present always describes THIS boot. It lives
      # in the spare page of the pstore window and survives a chip reset,
      # which is exactly why it has to be consumed rather than left lying.
      chld=$(devmem 0x480EE000 32)
      addr=$(devmem 0x480EE004 32)
      printf '%s\n' "$chld" > /run/nanokvm-uboot-test.chainload
      printf '%s\n' "$addr" > /run/nanokvm-uboot-test.addr
      if [ "$(( chld ))" -eq "$(( 0x43484C44 ))" ]; then
        echo "uboot-test: this boot chainloaded a candidate at $addr" \
             "(milestones $(devmem 0x02390024 32))"
        devmem 0x480EE000 32 0
        devmem 0x480EE004 32 0
      fi

      # The token is U-Boot's to spend and it already has; zeroing it here is
      # belt and braces for the case where the load failed and the attempt
      # never happened. The FILE is this unit's to remove.
      if [ -b /dev/loop0p3 ]; then
        dd if=/dev/zero of=/dev/loop0p3 bs=512 count=1 conv=fsync 2>/dev/null || true
      fi

      mountpoint -q /boot || exit 0
      [ -e "$TESTFILE" ] || exit 0
      echo "uboot-test: consuming the staged candidate"
      rm -f "$TESTFILE"
      sync
    '';
  };
in
{
  options.nanokvm = {
    checkboot.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Re-arm the active A/B slot on every boot (the S99checkboot equivalent).

        Turn this OFF for a slot-B boot test. The SPL treats `SLOTB_BOOTABLE` as
        consume-once, and the entire safety argument of the reversible harness
        is that NOTHING in the slot-B image re-arms it -- so whatever happens
        there, the next boot lands on slot A by itself. A booted appliance that
        re-armed would stay on slot B, and getting back would need either a
        working shell on it or Jeremy's hands on the power.
      '';
    };

    markGood.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Clear U-Boot's boot counter and promote the running generation to the
        rollback fallback, once this boot has been shown to be healthy
        (#89 rung 5, and what closes #79).

        With this OFF the counter is never cleared, so every boot counts and
        the fourth consecutive one takes `altbootcmd`. That is the correct
        behaviour for a deliberately-broken generation in a rollback drill --
        and the reason the knob exists.
      '';
    };

    markGood.delaySec = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        Seconds after boot before the health check first runs. The appliance
        takes ~93 s of userspace on this board, so this is a floor, not a
        deadline: the check polls from here until `markGood.timeoutSec`.
      '';
    };

    markGood.timeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 240;
      description = ''
        How long the health check keeps polling before giving up and leaving
        the boot counter alone. Must stay well under the time three more boot
        attempts would take, or a board that is merely slow looks broken.
      '';
    };

    markGood.tolerateFailed = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "nanokvm-wifi.service"
        "nanokvm-panel.service"
        "nanokvm-display.service"
      ];
      example = [ "nanokvm-wifi.service" ];
      description = ''
        Units whose failure still counts as a healthy boot. When
        `systemctl is-system-running` says `degraded` and EVERY failed unit is
        in this list, the boot counter is cleared and the generation is
        promoted anyway.

        This is the second half of a rule the units themselves implement
        first: optional hardware gets a journal line and `exit 0`, never a
        failed unit (#85's WiFi, #84's panel). Both cost a hardware round to
        the same mechanism -- a peripheral unit that `exit 1`-ed made the
        system `degraded`, `nanokvm-mark-good` polled `markGood.timeoutSec`
        and gave up, `bootcount` was never cleared, and the fourth such boot
        would have rolled a working KVM onto its previous generation over a
        missing radio or a dark status screen.

        Keep it to peripherals. A unit that is not listed still fails the
        gate, which is what keeps the rollback meaningful for the things this
        appliance is actually for: the server, the network, the capture stack.
      '';
    };

    ubootTest.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ship `nanokvm-uboot-test` and the unit that consumes the chainload test
        slot after one attempt. The slot itself lives in U-Boot (patch 0025);
        this is only the half that stages and removes /boot/uboot-test.bin.
      '';
    };
  };

  config = {
    # Confirm the active A/B boot slot on every boot -- the S99checkboot
    # equivalent. The SPL CONSUMES the current slot's BOOTABLE bit on the way
    # in, so a boot that never re-arms it is a boot that falls back next time.
    # `bootsystem` is written uppercase A/B by U-Boot; the vendor's own script
    # writes lowercase in places, so both are accepted.
    #
    # This was inert in the 4.19 scaffold for want of /etc/fw_env.config. That
    # file now ships (nixos/modules/identity.nix), so the unit is live -- and #79 is what
    # puts a health gate in front of it (After=nanokvm-healthy.target) instead
    # of re-arming unconditionally the way the vendor does.
    #
    # UNDER THE MINIMAL LAYOUT THE SLOT BITS SELECT NOTHING (#89 rung 4). The
    # rebuilt SPL has `*_BAK_FLASH_BASE` equal to the A bases, so slot A and
    # slot B are the same two partitions and `select_slot_ab()` picks between
    # two identical addresses. The unit is kept anyway, for two reasons: it
    # keeps bits 2-5 of 0x02390024 in a DETERMINISTIC state (slot A, armed),
    # which is what makes `0x300000x5` a readable oracle rather than a value
    # that alternates every boot; and it keeps the mechanism alive for a
    # vendor-layout system, where the bits do still choose. Rung 5 replaces
    # the whole thing with U-Boot's `bootcount`/`altbootcmd` over
    # DM_BOOTCOUNT_SYSCON on this same register.
    systemd.services.nanokvm-checkboot = lib.mkIf cfg.checkboot.enable {
      description = "Confirm the active A/B boot slot (S99checkboot equivalent)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      unitConfig.ConditionPathExists = "/etc/fw_env.config";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ ubootTools busybox gnugrep gnused coreutils ];
      script = ''
        slot=$(fw_printenv -n bootsystem 2>/dev/null | tr -d '[:space:]') || slot=""
        case "$slot" in
          a|A) echo "checkboot: slot A -> 0x2390028=0x10"; devmem 0x2390028 32 0x10 ;;
          b|B) echo "checkboot: slot B -> 0x2390028=0x20"; devmem 0x2390028 32 0x20 ;;
          *)   echo "checkboot: bootsystem='$slot' not a/b -- refusing to write the slot register" >&2 ;;
        esac
      '';
    };

    # The rollback gate (#89 rung 5; this is what closes #79).
    #
    # U-Boot increments `bootcount` in TOP_CHIPMODE_GLB_BACKUP1 on every boot
    # and, once it passes `bootlimit` (3), runs `altbootcmd` instead of
    # `bootcmd` -- which sets milestone bit 30 and boots
    # /boot/extlinux/extlinux-fallback.conf. This unit is the other half: it
    # clears the counter, and promotes the config that booted to the fallback,
    # ONLY once the system has been shown to work.
    #
    # A TIMER, not a `WantedBy=multi-user.target` service. The health check
    # polls `systemctl is-system-running` for `running`, which is only reached
    # when the boot's initial transaction is empty -- so a unit inside that
    # transaction would be waiting on itself. A timer-started job is not part
    # of it.
    #
    # THE FAILURE MODE IS THE SAFE ONE. If this unit does not run, or runs and
    # finds the system unhealthy, the counter is simply not cleared and the
    # next boot counts one higher. Three of those and the board rolls back by
    # itself. Nothing here can strand the board; only NOT running it can end
    # a boot on the fallback.
    systemd.services.nanokvm-mark-good = lib.mkIf cfg.markGood.enable {
      description = "Clear the boot counter and promote this generation to the rollback fallback";
      after = [ "multi-user.target" "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${markGood}/bin/nanokvm-mark-good";
      };
    };

    # Consume the chainload test slot: one attempt, then the file goes.
    # Ordered after /boot is mounted and before nothing -- it is not on any
    # critical path, and if it never runs the only cost is that the candidate
    # is tried again after the next healthy boot.
    systemd.services.nanokvm-uboot-test-clear = lib.mkIf cfg.ubootTest.enable {
      description = "Consume the one-shot U-Boot chainload test slot";
      wantedBy = [ "multi-user.target" ];
      after = [ "boot.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${ubootTestClear}/bin/nanokvm-uboot-test-clear";
      };
    };

    systemd.timers.nanokvm-mark-good = lib.mkIf cfg.markGood.enable {
      description = "Run the boot health gate once, after this boot has had time to finish";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.markGood.delaySec}s";
        AccuracySec = "1s";
        RemainAfterElapse = false;
      };
    };

    # The hardware watchdog, petted from PID 1. Without this the ax630c
    # watchdog is petted by the KERNEL for as long as the kernel schedules,
    # which protects against nothing a user would call a hang. With it, a PID 1
    # that stops running resets the board, the counter reaches `bootlimit`, and
    # the rollback above happens unattended -- which is the whole point of a
    # box whose console is a pad nobody can reach.
    #
    # 60 s is the driver's own default timeout (it programs TORR in units of
    # 64Ki ticks of a 24 MHz counter, two stages); systemd pings at half that.
    # RebootWatchdogSec covers a shutdown that wedges after the filesystems are
    # gone, which is exactly where this board has no other way out.
    systemd.watchdog = {
      runtimeTime = "60s";
      rebootTime = "3min";
    };

    # On PATH so a hardware run can force the promotion by hand and read what
    # it decided, rather than inferring it from the unit's journal, and so a
    # U-Boot candidate can be staged without knowing a store path.
    #
    # mkOrder pins where these land in the one merged list: the areas all
    # contribute to `environment.systemPackages` and its ORDER is hashed into
    # the system path's derivation (#87).
    environment.systemPackages = lib.mkOrder 300 (
      lib.optional cfg.ubootTest.enable ubootTest
      ++ lib.optional cfg.markGood.enable markGood
    );
  };
}
