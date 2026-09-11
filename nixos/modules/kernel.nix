{ config, lib, pkgs, nanokvm, ... }:

# ===========================================================================
# The AX630C boot path: the kernel, the device tree, the bootloader, the
# initrd and the two filesystems the eMMC layout defines (#99, #89 rung 4).
#
# ENABLES: `boot.kernelPackages` (this repo's mainline kernel), the compiled
# `dts/` device tree, NixOS's own generic-extlinux-compatible builder as the
# ONE writer of /boot, the kernel command line, a scripted stage 1 with the
# `panicOnFail` deadman and the loop-device mapping that exposes the GPT
# inside the eMMC's `disk` partition, and `/` plus `/boot` themselves.
#
# HARDWARE FACTS IT ENCODES: the AX630C is arm64 and has 1 GiB of DRAM of
# which the appliance sees 512 MiB; its console is a hidden, unterminated
# UART0 pad, so U-Boot must never prompt and stage 1 must never block on a
# read; three SD4HC instances probe concurrently, so the eMMC is pinned by
# `aliases { mmc0 = &emmc; }` and split by `blkdevparts=`; and the real
# partition table is a GPT at an offset Linux cannot be told to parse, so
# stage 1 puts a loop device over it.
#
# The layout itself is nixos/lib/emmc-layout.nix, and it is the single
# definition the SPL's compile-time offsets come from as well.
# ===========================================================================

let
  # THE eMMC LAYOUT (#89 rung 4), from the one place it is defined. The root
  # device, /boot and /etc/fw_env.config all follow from it. There is one
  # layout since #97 -- `spl` plus a GPT-carrying `disk`.
  parts = import ../emmc-partitions.nix { inherit lib; };
  cfg = config.nanokvm;
in
{
  options.nanokvm = {
    rootDevice = lib.mkOption {
      type = lib.types.str;
      default = parts.root.device;
      description = ''
        Block device holding the NixOS root filesystem. Derived from the
        `blkdevparts=` clause, which is the only definition of this eMMC's
        layout (there is no on-disk partition table).
      '';
    };
  };

  config = {
    # =====================================================================
    # 1. Platform, and everything NixOS must NOT do
    # =====================================================================
    # mkDefault so a consumer's own `nixosSystem { system = ...; }` wins; the
    # SoC is arm64 and nothing else will run on it.
    nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

    # =====================================================================
    # 1a. The kernel, the device tree, and the bootloader (#99)
    # =====================================================================
    # THE KERNEL IS THE GENERATION'S. `pkgs/kernel-mainline` with no embedded
    # initramfs, wrapped by `linuxPackagesFor` so NixOS's own machinery --
    # `system.build.toplevel`'s `kernel`/`initrd`/`dtbs` links, the extlinux
    # builder, the closure -- treats it as any other kernel. `nanokvm.kernel`
    # is handed in through specialArgs because it is a cross build owned by the
    # flake (nixos/rootfs.nix), not a package in this pkgs set.
    #
    # There are no modules: every driver is built in. `aggregateModules` copes
    # ("No modules found"), and `makeModulesClosure` over an empty tree with an
    # empty root list is a no-op -- which is why the two mkForce'd lists below
    # are not optional.
    boot.kernelPackages = pkgs.linuxPackagesFor nanokvm.kernel;

    # OUR dtb, from dts/ in this repo -- NOT `make dtbs` inside the kernel
    # tree, which on arm64 would build every other vendor's device trees to
    # produce our one file (pkgs/dtb-mainline.nix). `name` makes the builder
    # emit `FDT <dir>/<name>` rather than `FDTDIR <dir>`, which matters: an
    # FDTDIR is resolved against `$fdtfile` or `$soc-$board.dtb` at boot
    # (boot/pxe_utils.c, label_boot()), so it would put a second copy of this
    # filename in the U-Boot environment. FDT names the file outright.
    hardware.deviceTree.enable = true;
    hardware.deviceTree.dtbSource = "${nanokvm.dtb}/dtb";
    hardware.deviceTree.name = "ax630c-nanokvm-pro.dtb";

    # THE BOOTLOADER IS NIXOS'S OWN, and it is the only writer of /boot.
    # `switch-to-configuration boot` runs
    # nixos/modules/system/boot/loader/generic-extlinux-compatible's builder,
    # which copies this generation's kernel, initrd and dtbs into /boot/nixos/
    # and writes /boot/extlinux/extlinux.conf. Nothing in this repo renders
    # that file, and nothing else writes it -- the updater does not, the image
    # build runs this same builder, and `nanokvm-mark-good` only ever derives
    # the fallback FROM it.
    boot.loader.generic-extlinux-compatible.enable = true;

    # TIMEOUT 0 IS NOT A SPEED SETTING, it is what keeps U-Boot off the
    # console. The builder emits a top-level `MENU TITLE` line whenever the
    # timeout is non-zero, and `parse_pxefile_top()` sets `cfg->prompt = 1` on
    # ANY top-level MENU keyword (boot/pxe_utils.c); `menu_get_choice()` then
    # takes `menu_interactive_choice()`, which calls
    # `cli_readline_into_buffer("Enter choice: ", ...)`. This board's console
    # is a hidden, unterminated UART pad: a character of line noise is an
    # unmatched key, the loop prints "<junk> not found" and asks again, and the
    # timeout is reset each time -- forever. With 0 the builder writes no MENU
    # line at all, `cfg->prompt` stays 0, and `menu_default_choice()` picks
    # DEFAULT without reading anything. The per-LABEL `MENU LABEL` lines the
    # builder still emits are parsed by `parse_label_menu()`, which does not
    # touch `cfg->prompt`.
    boot.loader.timeout = 0;

    # HOW MANY GENERATIONS THE BOOT MENU NAMES, and it is squeezed from both
    # sides.
    #
    # FROM BELOW: `nanokvm-mark-good` promotes by setting DEFAULT to the booted
    # generation's LABEL, so that label has to be in the file -- a fallback
    # naming a label U-Boot cannot match falls through to the FIRST label,
    # which is the generation the rollback exists to escape. The deepest gap
    # that can open is one: an update makes generation N+1 the default while
    # the fallback still names N, and `nanokvm-update` refuses to install over
    # a boot that has not been marked good, so N+2 cannot appear first. Two
    # would do; three leaves a spare.
    #
    # FROM ABOVE: /boot. Each generation in the menu is a ~50 MB copy of its
    # kernel, initrd and dtbs under /boot/nixos/, and the builder writes the
    # new set BEFORE collecting the obsolete one -- so the partition has to
    # hold `configurationLimit + 1` of them at the moment of a switch.
    # pkgs/bootfs.nix asserts exactly that against the 272 MiB partition, from
    # the sizes the image actually carries.
    boot.loader.generic-extlinux-compatible.configurationLimit = 3;

    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;

    # THE COMMAND LINE, minus `init=`, which the builder pins per LABEL -- that
    # is what lets extlinux.conf and extlinux-fallback.conf name two different
    # generations. Everything here was hardware-proven in #89 rung 2q round 6,
    # minus that round's two test-only tokens:
    #
    #   * `watchdog.open_timeout=` is a DEADMAN, not a setting. Nothing in the
    #     appliance opens /dev/watchdog, so the watchdog core pets U-Boot's dog
    #     from kernel context forever; with an open deadline it stops and a
    #     perfectly healthy board resets a few minutes in.
    #   * `systemd.mask=systemd-pstore.service` keeps a boot's ramoops readable
    #     by stopping systemd archiving and unlinking it. Also a harness
    #     setting.
    #
    # `mem=512M` STAYS for now. The board has 1 GiB and the appliance sees
    # 428 MB usable; dropping it made the kernel die before any console in
    # rung 2p, and what lives above 512 MB has not been established.
    #
    # `blkdevparts=` is the layout, and it is the same string U-Boot's own
    # `part_cmdline` driver reads. Since #89 rung 4 it is GENERATED from
    # nixos/lib/emmc-layout.nix -- the SPL's stage offsets are compile-time
    # constants derived from that list, so the list is the definition and the
    # DT clause is checked against it, not the other way round.
    #
    # `boot.panic_on_fail` AND `stage1panic=1` CARRY NO `=1`, and that is the
    # whole point. Upstream's stage-1 parser is
    # `case $o in boot.panic_on_fail|stage1panic=1)`, and a shell `case`
    # pattern must match the WHOLE word -- so `boot.panic_on_fail=1`, which is
    # what this line said until 2026-09-09, matched NOTHING and silently left
    # `panicOnFail` unset. It cost the rung-5 drill and a bench trip.
    # `preDeviceCommands` below sets the variable too, depending on no string.
    boot.kernelParams = [
      "mem=512M"
      "console=ttyS0,115200n8"
      "earlycon=uart8250,mmio32,0x4880000"
      "board_id=0x5,boot_reason=0x00,initcall_debug=0"
      "usbcore.autosuspend=-1"
      "root=${parts.root.device}"
      "rootfstype=ext4"
      "rw"
      "rootwait"
      parts.blkdevparts
      "logomode=vo0@dsi_dpi_video"
      "boot.panic_on_fail"
      "stage1panic=1"
      "panic=10"
    ];
    # `loglevel=` is emitted by nixos/modules/system/boot/kernel.nix from this
    # option, so setting it here rather than in kernelParams keeps one of them.
    boot.consoleLogLevel = 8;

    # =====================================================================
    # 2. The initrd -- what replaces the vendor /init
    # =====================================================================
    # Classic (script) stage 1, not systemd-in-initrd. The failure mode of a
    # stage 1 that dies on this board is a board with no console and no
    # autoboot interrupt window; a shell script that mounts one ext4 is the
    # smaller, more inspectable thing, and `panicOnFail` below is a property of
    # that script specifically.
    boot.initrd.enable = true;
    boot.initrd.systemd.enable = false;

    # Compressed the way NixOS compresses an initrd (zstd), because it is a
    # FILE now: U-Boot loads /boot/nixos/<gen>-initrd to `ramdisk_addr_r` and
    # hands the address to `booti`. It used to be `cat`, because
    # pkgs/kernel-mainline.nix fed it to CONFIG_INITRAMFS_SOURCE and let the
    # kernel do the compression -- compress it twice and the Image grew.
    # Nothing embeds it any more (#99).

    # There are no kernel modules in the INITRD. Every driver stage 1 needs is
    # built into the Image, and the kernel derivation ships no /lib/modules
    # tree for `makeModulesClosure` to draw from. The six the video stack
    # loads (#83) are a stage-2 concern and come out of the closure's own
    # `nanokvm.video-modules`.
    #
    # mkForce, not `= [ ]`: option lists MERGE, and nixos/modules/tasks/
    # filesystems/ext.nix adds "ext2 ext4" to availableKernelModules for the
    # root filesystem's type. Merging leaves those two in place, and
    # makeModulesClosure over an empty tree with a non-empty root module list
    # is a hard build failure ("Can not derive a closure of kernel modules").
    boot.initrd.includeDefaultModules = false;
    boot.initrd.kernelModules = lib.mkForce [ ];
    boot.initrd.availableKernelModules = lib.mkForce [ ];

    # `losetup` for the image-file root below and for the GPT mapping. Busybox
    # in the initrd has an applet, but the real one is 100 KB, behaves the same
    # everywhere, and is the only one that takes `-P`.
    # `resize2fs` is the minimal layout's one-time shrink -- see the comment on
    # preLVMCommands below.
    boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${pkgs.util-linux}/bin/losetup
      copy_bin_and_libs ${pkgs.e2fsprogs}/bin/resize2fs
    '';

    # THE STAGE-1 DEADMAN, and it is not optional on this board.
    #
    # NixOS stage 1's `fail()` is INTERACTIVE: it prints a menu and blocks in
    # `read -n 1 reply` on /dev/console. This board's console is a hidden,
    # unterminated UART pad, so that is a board which is powered, warm and
    # unreachable forever -- no reset, no watchdog (nothing arms WDT0 before
    # Linux), and therefore no `bootcount` increment and no rollback. It has to
    # be a panic, so that `panic=10` restarts the board into the count.
    #
    # SETTING IT FROM THE COMMAND LINE ALONE IS NOT ENOUGH, and believing it
    # was cost a bench trip on 2026-09-09. Upstream parses
    # `case $o in boot.panic_on_fail|stage1panic=1)`, and a shell `case`
    # pattern must match the WHOLE word -- so the `boot.panic_on_fail=1` the
    # extlinux APPEND had carried since rung 3 matched nothing at all and
    # `panicOnFail` was never set. The rung-5 rollback drill installed a
    # generation that could not boot, stage 1 sat in `read` instead of
    # panicking, and the board had to be recovered by hand.
    #
    # preDeviceCommands is spliced in AFTER the command-line parse and after
    # `trap 'fail' 0`, which is exactly where the variable has to land. The
    # APPEND now carries the right tokens too; this does not depend on them.
    boot.initrd.preDeviceCommands = lib.mkBefore ''
      panicOnFail=1
    '';

    # =====================================================================
    # MAPPING `disk`: the GPT the kernel cannot be told to look for
    # =====================================================================
    # The eMMC is two logical devices (#89 rung 4): `spl`, the 768 KiB the
    # BootROM reads its first-stage loader from, and `disk`, everything after
    # it. `disk` carries a spec-conformant GPT at its own LBA 0 -- but Linux
    # has no way to be told "parse a partition table at an offset", so the
    # kernel command line splits the raw eMMC in two with
    # `blkdevparts=mmcblk0:768K(spl),-(disk)` and stage 1 puts a loop device
    # over the second half. The in-kernel EFI parser then does the rest, and
    # /dev/loop0p1..5 appear with their GPT names.
    #
    # This has to happen before any filesystem is mounted, which is what
    # preLVMCommands is: after udev has settled, before the root is looked for.
    boot.initrd.preLVMCommands = ''
      # THE eMMC IS NOT RELIABLY mmcblk0 unless something makes it so -- three
      # SD4HC instances probe concurrently on this SoC. `aliases { mmc0 =
      # &emmc; }` in dts/ax630c.dtsi is what pins it, and the blkdevparts=
      # clause binds the split to that name, so if the alias ever lapses the
      # split lands on an empty slot and NOTHING here can recover it. Wait for
      # the device the clause created rather than assuming it is instant.
      nktry=0
      while [ ! -e ${parts.diskDevice} ] && [ "$nktry" -lt 60 ]; do
        sleep 1
        nktry=$((nktry + 1))
      done
      if [ ! -e ${parts.diskDevice} ]; then
        echo "nanokvm: ${parts.diskDevice} never appeared -- is blkdevparts= on the cmdline?" >&2
        cat /proc/partitions >&2 || true
      else
        # The loop module creates loop0..7 at init; udev makes the nodes. Only
        # make one by hand if that has not happened, because the root device is
        # a compile-time constant and it says loop0.
        if [ ! -e ${parts.loopDevice} ]; then
          modprobe loop 2>/dev/null || true
          nktry=0
          while [ ! -e ${parts.loopDevice} ] && [ "$nktry" -lt 10 ]; do
            sleep 1
            nktry=$((nktry + 1))
          done
          [ -e ${parts.loopDevice} ] || mknod ${parts.loopDevice} b 7 0
        fi

        echo "nanokvm: mapping ${parts.diskDevice} -> ${parts.loopDevice} (GPT)"
        losetup -P ${parts.loopDevice} ${parts.diskDevice} \
          || echo "nanokvm: losetup failed" >&2
        udevadm settle || true

        # THE FILESYSTEM IS FIVE BLOCKS TOO BIG ON THE FIRST BOOT AFTER THE
        # MIGRATION, and ext4 refuses to mount rather than truncating. The old
        # 17-partition table ran `rootfs` to the last byte of the eMMC and the
        # filesystem was grown to fill it; a GPT reserves the last 33 LBAs for
        # the alternate header, so the new partition is 16896 bytes shorter.
        #
        # `resize2fs` with no size argument resizes to the device, shrinking
        # included, and it only demands a check when it has to -- so on every
        # boot after the first this is one command, no fsck, "Nothing to do!".
        if [ -e ${parts.root.device} ]; then
          if ! resize2fs ${parts.root.device}; then
            echo "nanokvm: checking ${parts.root.device} before resizing it"
            e2fsck -fp ${parts.root.device} || true
            resize2fs ${parts.root.device} || true
          fi
        fi
      fi
    '';

    # =====================================================================
    # 3. Filesystems -- all three numbers derived from the blkdevparts clause
    # =====================================================================
    fileSystems."/" = {
      device = cfg.rootDevice;
      fsType = "ext4";
      options = [ "noatime" ];
      # make-ext4-fs shrinks the image to its contents, so a partition root is
      # ~1 GB inside a ~30 GB partition. Stage 1 grows it, which is what the
      # vendor /init did with static binaries copied out of the rootfs.
      autoResize = true;
    };

    # /boot, and it must be WRITABLE: the server keeps its USB-gadget feature
    # flags there (usb.ncm, usb.disk0, usb.uac2, eth.nodhcp, ...), the module
    # loader sources /boot/configs, and the vendor initramfs contract still
    # uses /boot/rec and /boot/check_resize2fs on a vendor boot. Since #89
    # rung 3 it also holds the boot payload, and since #99 that payload is
    # NixOS's: /boot/extlinux/extlinux.conf plus one /boot/nixos/<hash>-kernel,
    # -initrd and -dtbs per generation in the menu.
    #
    # EXT4 UNDER THE MINIMAL LAYOUT. The kernel needs ext4 for root anyway, so
    # putting /boot on it retires the CONFIG_VFAT_FS + NLS-codepage trap
    # documented in docs/nixos-rootfs.md (without those tables the mount fails
    # -EINVAL and every USB-gadget flag silently reads as absent). `umask` is
    # a vfat-only option; on ext4 the permissions are in the filesystem.
    fileSystems."/boot" = {
      device = parts.bootfs.device;
      fsType = "ext4";
      options = [ "nofail" "noatime" ];
    };

    swapDevices = [ ];

    assertions = [
      {
        assertion = !config.boot.initrd.systemd.enable;
        message = ''
          nixos/appliance.nix: boot.initrd.systemd.enable must stay false.
          A stage 1 that dies on this board is silent -- no console, no
          autoboot interrupt window -- and the `panicOnFail` deadman below is
          a property of the SCRIPTED stage 1 specifically. top-level.nix also
          swaps <system>/init for a copy of the systemd binary when it is on,
          which breaks the /init contract the rootfs asserts.
        '';
      }
      {
        assertion = config.boot.kernel.enable;
        message = ''
          nixos/appliance.nix: boot.kernel.enable must stay true (#99). The
          kernel, the initrd and the dtb ARE the generation now; with this off
          there is no $out/kernel for the extlinux builder to copy and /boot
          would name files nothing produces.
        '';
      }
      {
        assertion = config.boot.initrd.enable;
        message = ''
          nixos/appliance.nix: boot.initrd.enable must stay true. Nothing else
          mounts the root filesystem -- the vendor initramfs that used to do it
          is not on this kernel.
        '';
      }
      {
        assertion = config.boot.loader.generic-extlinux-compatible.enable;
        message = ''
          nixos/appliance.nix: generic-extlinux-compatible must stay enabled.
          It is the only writer of /boot/extlinux/extlinux.conf, and U-Boot's
          `bootcmd` reads exactly that file. Nothing else on this system
          writes a boot config.
        '';
      }
      {
        assertion = config.boot.loader.timeout == 0;
        message = ''
          nixos/appliance.nix: boot.loader.timeout must be 0. Any other value
          makes the builder emit a top-level `MENU TITLE`, which sets
          `cfg->prompt = 1` in U-Boot's parse_pxefile_top() -- and this board's
          console is a hidden, unterminated UART pad, so the prompt loop reads
          line noise forever and the board never boots.
        '';
      }
      {
        assertion =
          config.boot.loader.generic-extlinux-compatible.configurationLimit >= 3;
        message = ''
          nixos/appliance.nix: the boot menu must name at least three
          generations. nanokvm-mark-good promotes the BOOTED one by name, and
          an update can put the default one generation ahead of it -- so with
          fewer than two the fallback ends up naming a LABEL the file does not
          define, and a DEFAULT U-Boot cannot match falls through to the FIRST
          label, which is the generation the rollback exists to escape. The
          third is a spare. The ceiling is /boot, asserted in pkgs/bootfs.nix.
        '';
      }
      {
        assertion = config.hardware.deviceTree.name != null;
        message = ''
          nixos/appliance.nix: hardware.deviceTree.name must be set. Without
          it the builder writes FDTDIR, which U-Boot resolves through
          $fdtfile / $soc-$board.dtb -- putting the filename in the U-Boot
          environment, where nothing in this repo maintains it.
        '';
      }
    ];
  };
}
