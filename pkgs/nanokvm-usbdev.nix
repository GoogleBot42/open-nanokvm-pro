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
# Implemented: hid.GS0/GS1/GS2 always; mass_storage.disk0 when /boot/usb.disk0
# exists (the server then drives lun.0/{file,cdrom,ro} itself). Not yet:
# ncm.usb0 (needs the udhcpd instance), uac2, acm, disk1 -- each logs one line
# and is skipped, so the server's probes read them as absent.
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
    # from a single write() to report_desc.
    write_hex() {
      local target=$1 hex=$2 want esc="" i
      want=$(( ''${#hex} / 2 ))
      for (( i = 0; i < ''${#hex}; i += 2 )); do esc+="\\x''${hex:i:2}"; done
      # shellcheck disable=SC2059
      printf "$esc" > "$target"
      [ "$(stat -c %s "$target")" = "$want" ] \
        || die "$target: wrote $(stat -c %s "$target") bytes, wanted $want"
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
      rmdir "$G/configs/c.1/$LANG_DIR" 2>/dev/null || true
      rmdir "$G/configs/c.1" 2>/dev/null || true
      for f in "$G"/functions/*; do
        [ -d "$f" ] && rmdir "$f"
      done
      rmdir "$G/$LANG_DIR" 2>/dev/null || true
      rmdir "$G"
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
        if [ -e /boot/usb.disk0 ]; then
          # The virtual CD/USB disk. lun.0 exists on creation; the server
          # writes file/cdrom/ro through configs/c.1/mass_storage.disk0/lun.0
          # when an image is mounted (service/storage/image.go).
          local d="$G/functions/mass_storage.disk0"
          mkdir -p "$d"
          echo 1 > "$d/stall"
          echo 1 > "$d/lun.0/removable"
          ln -s "$d" "$G/configs/c.1/"
          log "mass_storage.disk0 added (/boot/usb.disk0)"
        fi
        local flag
        for flag in usb.ncm usb.rndis usb.uac2 usb.acm usb.udisp usb.disk1.sd usb.disk1.emmc; do
          [ -e "/boot/$flag" ] && log "/boot/$flag: function not implemented on this image, skipped"
        done
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
        echo "usage: usbdev.sh start|restart|hid-only|stop|status" >&2
        exit 2
        ;;
    esac
  '';
}
