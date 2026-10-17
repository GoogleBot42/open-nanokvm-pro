{ pkgs, crossPkgs, ... }:

# ---------------------------------------------------------------------------
# usbdev.sh -- the USB gadget the KVM presents to the host (#82, policy half).
#
# The vendor image built its gadget with /kvmapp/scripts/usbdev.sh, a script
# that shipped only in the vendor rootfs and was never captured. This is NOT a
# port of it: it is written from the contract the GPL server and web UI in this
# tree define, plus public documents --
#
#   * paths and verbs: NanoKVM-Server execs `bash /kvmapp/scripts/usbdev.sh
#     {restart,hid-only}` (service/hid/status.go) and
#     `/dev/shm/kvmapp/scripts/usbdev.sh restart` (service/storage/image.go),
#     opens /dev/hidg{0,1,2} (service/hid/hid.go), reads the mode from the
#     flag file /dev/shm/tmp/hid_only, and probes the gadget's configfs tree
#     for which optional functions are present (service/vm/virtual_devices.go,
#     service/storage/image.go);
#   * report layouts: web/src/lib/keyboard.ts and web/src/lib/mouse.ts --
#     8-byte boot keyboard, 4-byte relative mouse (5 buttons, X, Y, wheel),
#     6-byte absolute mouse (5 buttons, X and Y as 0..32767 little-endian,
#     wheel);
#   * descriptors: the boot keyboard one is the kernel's own
#     Documentation/usb/gadget_hid.rst; the two mouse ones are plain HID
#     usage-table constructs sized to those reports.
#
# Identity is Linux Foundation 1d6b:0104 ("Multifunction Composite Gadget"),
# not Sipeed's: this gadget is not the vendor's and must not claim to be. The
# board's /boot/usb.{vid,pid,manufacturer,product,serialnumber} files override
# it, the same knobs the vendor firmware honoured.
#
# What a BIOS sees is the point. Firmware speaks HID boot protocol only, so the
# keyboard and the relative mouse are boot-protocol interfaces, the absolute
# mouse is a plain HID interface the OS driver picks up later, and NO other
# function is in the configuration unless the host-facing flag file asks for
# it. `hid-only` is the fallback for hosts that still choke on the composite:
# the three HID interfaces and nothing else, flags or no flags.
#
# Implemented: hid.GS0/GS1/GS2 always; then, each behind its /boot flag and
# admitted against the controller's endpoint budget in this order,
# mass_storage.disk0 (usb.disk0; the server drives lun.0/{file,cdrom,ro}
# itself), ncm.usb0 (usb.ncm; networkd serves DHCP on usb0), uac2.usb0
# (usb.uac2; the server's virtual mic plays into it and libkvm captures the
# host's speaker out of it) and acm.usb0 (usb.acm; a getty on ttyGS0). rndis, udisp and disk1 log one line and are skipped, so
# the server's probes read them as absent.
# ---------------------------------------------------------------------------

crossPkgs.writeShellApplication {
  name = "usbdev.sh";
  runtimeInputs = with crossPkgs; [ coreutils gnused ];
  # The server runs this as `bash <path>`, so the shebang is not what selects
  # the interpreter; PATH is set inside the script by writeShellApplication,
  # which is what makes the `bash` invocation self-sufficient.
  text = ''
    G=/sys/kernel/config/usb_gadget/g0
    HID_ONLY_FLAG=/dev/shm/tmp/hid_only
    LANG_DIR=strings/0x409

    log() { echo "usbdev: $*"; }
    die() { echo "usbdev: ERROR: $*" >&2; exit 1; }

    # /boot/usb.<name> overrides a descriptor value; one line, whitespace
    # stripped, empty file = default.
    knob() {
      local f="/boot/usb.$1" v
      if [ -r "$f" ]; then
        v=$(tr -d '[:space:]' < "$f")
        [ -n "$v" ] && { printf '%s\n' "$v"; return; }
      fi
      printf '%s\n' "$2"
    }

    # A hex string to bytes, in ONE write: f_hid takes the whole descriptor
    # from a single write() to report_desc. Verified by reading it BACK --
    # `stat` on a configfs attribute reports the page size, not the content
    # (4096 for a 63-byte descriptor, measured 2026-10-03).
    write_hex() {
      local target=$1 hex=''${2,,} esc="" got i
      for (( i = 0; i < ''${#hex}; i += 2 )); do esc+="\\x''${hex:i:2}"; done
      # shellcheck disable=SC2059
      printf "$esc" > "$target"
      got=$(od -An -v -tx1 "$target" | tr -d ' \n')
      [ "$got" = "$hex" ] \
        || die "$target: read back ''${#got} hex digits, wanted ''${#hex}"
    }

    udc_name() {
      local u
      for u in /sys/class/udc/*; do
        [ -e "$u" ] && { basename "$u"; return; }
      done
      die "no UDC under /sys/class/udc -- is the dwc3 glue bound?"
    }

    # --- report descriptors ------------------------------------------------
    # Boot keyboard, Documentation/usb/gadget_hid.rst, 63 bytes: 8 modifier
    # bits, 1 reserved byte, 5 LED output bits + 3 pad, 6 key array bytes.
    DESC_KBD=05010906a101050719e029e71500250175019508810295017508810395057501050819012905910295017503910395067508150025650507190029658100c0
    # Relative mouse, 52 bytes: 5 buttons + 3 pad, X/Y/wheel int8 (4-byte report).
    DESC_MOUSE_REL=05010902a1010901a1000509190129051500250195057501810295017503810305010930093109381581257f750895038106c0c0
    # Absolute mouse, 63 bytes: 5 buttons + 3 pad, X/Y uint16 logical
    # 0..32767, wheel int8 (6-byte report).
    DESC_MOUSE_ABS=05010902a1010901a10005091901290515002501950575018102950175038103050109300931150026ff7f75109502810209381581257f750895018106c0c0

    # hid_function <name> <subclass> <protocol> <report_length> <desc-hex>
    hid_function() {
      local d="$G/functions/hid.$1"
      mkdir -p "$d"
      echo "$2" > "$d/subclass"
      echo "$3" > "$d/protocol"
      echo "$4" > "$d/report_length"
      write_hex "$d/report_desc" "$5"
      ln -s "$d" "$G/configs/c.1/"
    }

    # The function symlinks in the configuration, space-separated.
    functions_bound() {
      local f
      for f in "$G"/configs/c.1/*; do
        [ -L "$f" ] && printf '%s ' "$(basename "$f")"
      done
      echo
    }

    # --- teardown ----------------------------------------------------------
    teardown() {
      [ -d "$G" ] || return 0
      # Unbind first; the host sees a detach, and every configfs rmdir below
      # is legal only on an unbound gadget.
      if [ -s "$G/UDC" ]; then echo "" > "$G/UDC" 2>/dev/null || true; fi
      local f
      for f in "$G"/functions/mass_storage.*/lun.*/file; do
        [ -e "$f" ] && { echo "" > "$f" 2>/dev/null || true; }
      done
      for f in "$G"/configs/c.1/*.*; do
        [ -L "$f" ] && rm -f "$f"
      done
      # ncm's Microsoft OS descriptor links the configuration; c.1 cannot be
      # removed while that link exists.
      [ -L "$G/os_desc/c.1" ] && rm -f "$G/os_desc/c.1"
      rmdir "$G/configs/c.1/$LANG_DIR" 2>/dev/null || true
      rmdir "$G/configs/c.1" 2>/dev/null || true
      for f in "$G"/functions/*; do
        [ -d "$f" ] && rmdir "$f"
      done
      rmdir "$G/$LANG_DIR" 2>/dev/null || true
      rmdir "$G"
    }

    # --- optional functions ------------------------------------------------
    # The endpoint budget. GHWPARAMS3 (0x0800c14c) reads 0x08210084 on this
    # DWC3: 16 physical endpoints, 8 of them IN, so 7 IN and 7 OUT once ep0
    # has its pair (measured 2026-10-17). Per function, counted from each
    # driver's usb_ep_autoconfig() calls in the 7.1 tree:
    #
    #   hid x3        3 IN 3 OUT  interrupt IN + OUT each (f_hid; the
    #                             keyboard's OUT carries the LED report)
    #   mass_storage  1 IN 1 OUT  bulk pair
    #   ncm           2 IN 1 OUT  bulk pair + notify
    #   uac2          1 IN 1 OUT  iso IN = the host's microphone, iso OUT =
    #                             the host's speaker. The OUT is ADAPTIVE: an
    #                             async one adds a feedback IN
    #                             (EPOUT_FBACK_IN_EN in f_uac2.c), and feature
    #                             units add an interrupt IN; both are off.
    #   acm           2 IN 1 OUT  bulk pair + notify
    #
    # IN is the one that runs out: HID + disk0 + ncm + acm is 8 IN, and a
    # configuration that asks for one more endpoint than the controller has
    # does not lose that function -- the whole UDC bind fails with it
    # (`failed to start g0: -19`), keyboard included. OUT peaks at 6 and cannot
    # run out with these five, but it is counted, so that one more function
    # cannot quietly make it the limit. Every function is admitted against both
    # in priority order (the ones the web UI toggles first, the flag-only
    # console last); one that does not fit is logged and skipped, never bound.
    # plan() is the only place that decides, and `usbdev.sh plan` prints its
    # answer without touching configfs -- .#checks.<sys>.usb-gadget-budget runs
    # it over all sixteen flag combinations.
    BOOT_DIR=''${USBDEV_BOOT_DIR:-/boot}
    IN_FREE=7
    OUT_FREE=7
    PLAN=()
    admit() {  # admit <name> <in-endpoints> <out-endpoints>
      if [ "$2" -gt "$IN_FREE" ] || [ "$3" -gt "$OUT_FREE" ]; then
        log "$1: needs $2 IN + $3 OUT endpoints, $IN_FREE IN + $OUT_FREE OUT left after the functions above -- skipped"
        return 1
      fi
      IN_FREE=$(( IN_FREE - $2 ))
      OUT_FREE=$(( OUT_FREE - $3 ))
    }

    # plan normal|hid-only: fill PLAN with the optional functions to bind, in
    # bind order. The HID set is always charged first.
    plan() {
      IN_FREE=7
      OUT_FREE=7
      PLAN=()
      admit hid 3 3 || die "the HID set alone does not fit the endpoint budget"
      [ "$1" = normal ] || return 0
      if [ -e "$BOOT_DIR/usb.disk0" ] && admit mass_storage.disk0 1 1; then PLAN+=(mass_storage.disk0); fi
      if [ -e "$BOOT_DIR/usb.ncm" ]   && admit ncm.usb0 2 1;           then PLAN+=(ncm.usb0); fi
      if [ -e "$BOOT_DIR/usb.uac2" ]  && admit uac2.usb0 1 1;          then PLAN+=(uac2.usb0); fi
      if [ -e "$BOOT_DIR/usb.acm" ]   && admit acm.usb0 2 1;           then PLAN+=(acm.usb0); fi
      return 0
    }

    # Two locally administered unicast MACs (02:, 06:) from the same hash, so
    # the host sees ONE stable NIC across boots and rebuilds instead of a new
    # interface each time (Windows keeps a registry entry per MAC). Same
    # stable input as the serial number.
    ncm_mac() {  # ncm_mac <first-octet> <serial>
      local h
      h=$(printf 'ncm:%s' "$2" | sha256sum)
      printf '%s:%s:%s:%s:%s:%s\n' "$1" "''${h:0:2}" "''${h:2:2}" "''${h:4:2}" "''${h:6:2}" "''${h:8:2}"
    }

    optional_functions() {
      local serial=$1 flag fn
      plan normal
      for fn in "''${PLAN[@]}"; do
        case $fn in
          mass_storage.disk0) add_disk0 ;;
          ncm.usb0)           add_ncm "$serial" ;;
          uac2.usb0)          add_uac2 ;;
          acm.usb0)           add_acm ;;
          *)                  die "plan named $fn, which nothing builds" ;;
        esac
      done

      # rndis is Windows-only and superseded by ncm; udisp is the vendor's
      # USB display function, which has no mainline driver; disk1 needs the
      # vendor's mount_emmc.py exFAT-over-/data scheme (docs/mainline-port.md
      # "#82 residuals").
      for flag in usb.rndis usb.udisp usb.disk1.sd usb.disk1.emmc; do
        [ -e "$BOOT_DIR/$flag" ] && log "$BOOT_DIR/$flag: function not implemented on this image, skipped"
      done
      return 0
    }

    add_disk0() {
      local d
      # The virtual CD/USB disk. lun.0 exists on creation; the server
      # writes file/cdrom/ro through configs/c.1/mass_storage.disk0/lun.0
      # when an image is mounted (service/storage/image.go).
      d="$G/functions/mass_storage.disk0"
      mkdir -p "$d"
      echo 1 > "$d/stall"
      echo 1 > "$d/lun.0/removable"
      ln -s "$d" "$G/configs/c.1/"
      log "mass_storage.disk0 added (/boot/usb.disk0)"
    }

    add_ncm() {
      local serial=$1 d
      # CDC-NCM: Linux (cdc_ncm), macOS and Windows 11 bind it by class.
      # The device end is usb0, served by networkd (nixos/modules/usb.nix).
      d="$G/functions/ncm.usb0"
      mkdir -p "$d"
      # Logged from the computed values: reading dev_addr back returns a
      # trailing NUL, which bash warns about on every bind.
      local dev host
      dev=$(ncm_mac 02 "$serial")
      host=$(ncm_mac 06 "$serial")
      echo "$dev"  > "$d/dev_addr"
      echo "$host" > "$d/host_addr"
      # Windows 10 binds UsbNcm.sys only through the Microsoft OS
      # descriptor; Sipeed's SG2002 S03usbdev sets the same WINNCM id.
      echo WINNCM > "$d/os_desc/interface.ncm/compatible_id"
      echo 1       > "$G/os_desc/use"
      echo 0xcd    > "$G/os_desc/b_vendor_code"
      echo MSFT100 > "$G/os_desc/qw_sign"
      ln -s "$G/configs/c.1" "$G/os_desc/"
      ln -s "$d" "$G/configs/c.1/"
      log "ncm.usb0 added (/boot/usb.ncm): dev $dev host $host"
    }

    add_uac2() {
      local d fu
      # Two 48 kHz stereo S16 streams. PLAYBACK (p_*, gadget to host) is
      # the host's microphone: the server pipes the browser's decoded Opus
      # into `aplay -D plughw:UAC2Gadget,0 -r 48000 -f S16_LE -c 2`
      # (service/stream/opus/player.go); u_audio names the card
      # "UAC2_Gadget", which ALSA turns into the id UAC2Gadget. CAPTURE
      # (c_*, host to gadget) is the host's speaker: libkvm reads it as the
      # KVM's outgoing audio whenever the host is streaming into it
      # (kvm-encoder's libkvm.c). c_sync adaptive costs one iso OUT and
      # nothing else -- async would add the feedback IN the budget above
      # has no room for. No mute/volume feature units: their interrupt
      # endpoint is one more IN.
      d="$G/functions/uac2.usb0"
      mkdir -p "$d"
      echo 3        > "$d/p_chmask"
      echo 48000    > "$d/p_srate"
      echo 2        > "$d/p_ssize"
      echo 3        > "$d/c_chmask"
      echo 48000    > "$d/c_srate"
      echo 2        > "$d/c_ssize"
      echo adaptive > "$d/c_sync"
      for fu in p_mute_present p_volume_present c_mute_present c_volume_present; do
        [ -e "$d/$fu" ] && echo 0 > "$d/$fu"
      done
      ln -s "$d" "$G/configs/c.1/"
      log "uac2.usb0 added (/boot/usb.uac2): mic + speaker, 48 kHz stereo S16"
    }

    add_acm() {
      local d
      # A CDC-ACM serial port, /dev/ttyGS0 here, cdc_acm / usbser.sys on
      # the host: the only console this board has that needs neither the
      # network nor the hidden UART pads. serial-getty@ttyGS0 follows the
      # device node (nixos/modules/usb.nix).
      d="$G/functions/acm.usb0"
      mkdir -p "$d"
      ln -s "$d" "$G/configs/c.1/"
      log "acm.usb0 added (/boot/usb.acm): /dev/ttyGS$(cat "$d/port_num")"
    }

    # --- build -------------------------------------------------------------
    # build normal|hid-only
    build() {
      local mode=$1 serial
      mkdir -p "$G"
      echo "0x0200"                  > "$G/bcdUSB"
      echo "0x0100"                  > "$G/bcdDevice"
      knob vid 0x1d6b                > "$G/idVendor"
      knob pid 0x0104                > "$G/idProduct"
      # Composite device: class/subclass/protocol 0 at the device level, so
      # the host reads each interface's own class (the HID ones included).
      echo "0x00" > "$G/bDeviceClass"
      echo "0x00" > "$G/bDeviceSubClass"
      echo "0x00" > "$G/bDeviceProtocol"

      # The serial must be stable across boots or Windows enumerates a new
      # device every time. The SoC UID (what identity derives the MAC from)
      # when the board has one, the machine id otherwise.
      serial=$(cat /device_key 2>/dev/null || cut -c1-16 /etc/machine-id 2>/dev/null || echo 0000000000000000)
      mkdir -p "$G/$LANG_DIR"
      knob manufacturer open-nanokvm-pro > "$G/$LANG_DIR/manufacturer"
      knob product NanoKVM-Pro           > "$G/$LANG_DIR/product"
      knob serialnumber "$serial"        > "$G/$LANG_DIR/serialnumber"

      mkdir -p "$G/configs/c.1/$LANG_DIR"
      echo "250"        > "$G/configs/c.1/MaxPower"
      echo "0x80"       > "$G/configs/c.1/bmAttributes"   # bus powered, no remote wakeup
      echo "NanoKVM"    > "$G/configs/c.1/$LANG_DIR/configuration"

      # The HID set, in the order the server opens them: hidg0 keyboard,
      # hidg1 relative mouse, hidg2 absolute mouse. f_hid numbers the device
      # nodes in creation order, so this order IS the /dev/hidgN contract.
      hid_function GS0 1 1 8 "$DESC_KBD"        # boot subclass, keyboard protocol
      hid_function GS1 1 2 4 "$DESC_MOUSE_REL"  # boot subclass, mouse protocol
      hid_function GS2 0 0 6 "$DESC_MOUSE_ABS"  # plain HID: no boot equivalent

      if [ "$mode" = normal ]; then
        optional_functions "$serial"
      fi

      udc_name > "$G/UDC"

      # devtmpfs creates /dev/hidgN when the function binds; give it a moment
      # so the server's first open() does not race it.
      local _
      for _ in $(seq 1 20); do
        [ -c /dev/hidg0 ] && [ -c /dev/hidg1 ] && [ -c /dev/hidg2 ] && break
        sleep 0.1
      done
      [ -c /dev/hidg2 ] || die "/dev/hidg{0,1,2} did not appear after binding"
      log "gadget bound to $(cat "$G/UDC") ($mode): $(functions_bound)"
    }

    status() {
      if [ ! -d "$G" ]; then echo "gadget: not built"; return 1; fi
      echo "gadget: $(cat "$G/idVendor"):$(cat "$G/idProduct") on '$(cat "$G/UDC")'"
      echo "mode: $([ -e "$HID_ONLY_FLAG" ] && echo hid-only || echo normal)"
      echo "functions: $(functions_bound)"
      echo "udc state: $(cat /sys/class/udc/*/state 2>/dev/null | head -1)"
      ls -l /dev/hidg* 2>/dev/null || echo "no /dev/hidg*"
    }

    # `plan [normal|hid-only]`: the functions a build would bind and the
    # endpoints left over, from the flags alone -- no configfs, no root.
    # USBDEV_BOOT_DIR points it at a directory of flag files other than
    # /boot (the budget check does).
    if [ "''${1:-}" = plan ]; then
      plan "''${2:-normal}"
      echo "functions: hid.GS0 hid.GS1 hid.GS2 ''${PLAN[*]}"
      echo "endpoints left: $IN_FREE IN $OUT_FREE OUT"
      exit 0
    fi

    [ -d /sys/kernel/config/usb_gadget ] || die "configfs usb_gadget not available"
    mkdir -p "$(dirname "$HID_ONLY_FLAG")"

    case "''${1:-}" in
      start|restart)
        teardown
        rm -f "$HID_ONLY_FLAG"
        build normal
        ;;
      hid-only)
        teardown
        build hid-only
        : > "$HID_ONLY_FLAG"
        ;;
      stop)
        teardown
        log "gadget removed"
        ;;
      status)
        status
        ;;
      *)
        echo "usage: usbdev.sh start|restart|hid-only|stop|status|plan [normal|hid-only]" >&2
        exit 2
        ;;
    esac
  '';
}
