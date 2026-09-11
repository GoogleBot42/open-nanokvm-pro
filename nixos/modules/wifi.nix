{ config, lib, pkgs, nanokvm, ... }:

# ===========================================================================
# WiFi on the appliance (#85) -- the AIC8800 SDIO radio.
#
# THREE PIECES, and each is somewhere a reader would not guess:
#
#   1. THE MODULES are out-of-tree (pkgs/aic8800.nix) and ride in this
#      generation's closure exactly the way the video stack's do, loaded by a
#      oneshot unit that walks a `load-order` file with insmod. Two files,
#      bsp then fdrv; nothing else in this kernel is modular except the video
#      stack, so there is no dependency chain to resolve.
#
#   2. THE FIRMWARE goes through `hardware.firmware`, which is what gives it a
#      stable runtime path: /run/current-system/firmware. That matters more
#      than usual here, because this driver does NOT use request_firmware --
#      the SDK builds with CONFIG_USE_FW_REQUEST = n and opens a literal path
#      with filp_open. The path is compiled into aic8800_bsp.ko
#      (pkgs/aic8800.nix `firmwarePath`), and the same fact is why the
#      firmware package opts out of `hardware.firmwareCompression`: a
#      `fmacfw.bin.zst` is, to this driver, a missing file.
#
#   3. THE WEB UI'S WIFI PAGE drives ONE script, and it is not the vendor
#      bring-up script this repo already carries. NanoKVM-Server's network
#      routes exec `/kvmcomm/scripts/wifi.sh` with the verbs `try_scan`,
#      `connect_start <ssid> [pass]`, `connect_stop` and `ap_stop`, and read
#      status from `wpa_cli -i wlan0 status`
#      (server/service/network/wifi.go, wifi_scan.go, server/utils/wifi.go).
#      the 4.19 image's `/opt/scripts/wifi.sh` was a DIFFERENT script at a
#      different path
#      (/opt/scripts/wifi.sh, verbs start|stop|restart) that the vendor's own
#      wifi.service ran at boot; it does not implement any of the four. So the
#      appliance provides /kvmcomm/scripts/wifi.sh, honouring the path the
#      server compiles in rather than inventing a new one.
#
# WPA_SUPPLICANT is nixpkgs' own module, unmodified in the way that counts:
#   * `allowAuxiliaryImperativeNetworks` -- the UI adds networks at runtime and
#     they have to survive a reboot, so the primary config is the writable
#     /etc/wpa_supplicant/imperative.conf with update_config=1.
#   * `userControlled` -- which is what puts the control socket where a BARE
#     `wpa_cli -i wlan0` looks, and a bare wpa_cli is exactly what the server
#     runs. nixpkgs compiles both halves of that path into the binary
#     (/run/wpa_supplicant/control and .../client); it is not upstream's
#     /var/run/wpa_supplicant, and #85 lost a hardware round to assuming it
#     was. See the option itself for the measurement.
#
# NOT DONE HERE: AP mode. The server's AP-mode provisioning flow (the /wifi
# page, `X-AP-Key`, /tmp/ap.pass, `pgrep hostapd`) needs hostapd, a DHCP
# server on wlan0 and a decision about what the appliance's AP SSID and
# password should be -- none of which #85 was asked for. `ap_stop` is
# implemented (it is called on the way IN to every connect), `isAPMode()`
# answers false because no hostapd runs, and the UI therefore shows the
# ordinary station flow.
#
# THIS FILE MOVED in #87 (it was nixos/wifi.nix). Two comments INSIDE the
# generated `kvmcomm-wifi.sh` still name the old path: that text is hashed
# into the script's store path and therefore into the whole appliance
# closure, and the #87 refactor's contract was that the closure does not
# change. They are corrected the next time the script changes for a reason.
# ===========================================================================

let
  cfg = config.nanokvm.wifi;

  # The station interface. The driver names its netdev wlan0 unconditionally
  # (rwnx_main.c's `rwnx_interface_add`), and both the server's status call and
  # nixpkgs' per-interface wpa_supplicant unit need the name up front.
  iface = "wlan0";

  # ---- /kvmcomm/scripts/wifi.sh ------------------------------------------
  # The four verbs the server execs, implemented over wpa_cli. Deliberately
  # NOT a port of the vendor script: that one writes /etc/wpa_supplicant.conf
  # by hand and starts its own supplicant, which on this system would fight
  # the one systemd runs.
  wifiScript = pkgs.writeShellApplication {
    name = "kvmcomm-wifi.sh";
    runtimeInputs = with pkgs; [ coreutils gnugrep gnused wpa_supplicant ];
    text = ''
      IFACE=${iface}

      wcli() { wpa_cli -i "$IFACE" "$@"; }

      # wpa_cli answers "FAIL" on stdout with exit status 0 for most errors,
      # so every call that matters is checked by its output.
      ok() { case "$1" in OK*) return 0 ;; *) return 1 ;; esac; }

      # NO ADAPTER is a first-class answer, not an error. The radio is
      # optional hardware: it may be absent, and it may fail to enumerate on
      # the SDIO bus -- nanokvm-wifi.service deliberately does not fail when
      # that happens (see the unit in nixos/wifi.nix). The server calls this
      # script regardless: `GetWifi` reports `supported: false` only after it
      # has found no interface with a `wireless` directory, and the scan and
      # connect routes have no such guard at all. So every verb below has to
      # behave sensibly with no interface present.
      have_adapter() { [ -e "/sys/class/net/$IFACE" ]; }

      state() { wcli status 2>/dev/null | sed -n 's/^wpa_state=//p'; }
      ipaddr() { wcli status 2>/dev/null | sed -n 's/^ip_address=//p'; }

      # --- try_scan ------------------------------------------------------
      # A JSON array of {ssid,bssid,signal,frequency,security}, which is what
      # server/service/network/wifi_scan.go json.Unmarshal's. SSIDs are
      # emitted exactly as wpa_cli prints them, escapes and all: the server
      # has its own fixer for wpa_cli's `\xNN` form (singleHexEscapeRegex),
      # and rewriting them here would defeat it.
      do_scan() {
        if ! have_adapter; then
          # An empty array is a valid answer the server parses; anything else
          # makes its scan route log a failure the user cannot act on.
          echo "[]"
          return 0
        fi
        wcli scan >/dev/null 2>&1 || true
        # The supplicant scans asynchronously; results accumulate. Three
        # seconds is one full pass of the 2.4/5 GHz channel list on this part.
        sleep 3
        # Captured first, NOT piped into the loop: a `... | while` runs the
        # loop in a subshell, and `first` would be invisible to anything after
        # it. Here it is one shell throughout.
        results=$(wcli scan_results 2>/dev/null | tail -n +2 || true)

        echo -n "["
        first=1
        # scan_results: bssid<TAB>frequency<TAB>signal<TAB>flags<TAB>ssid
        while IFS=$'\t' read -r bssid freq sig flags ssid; do
          [ -n "$bssid" ] || continue
          [ -n "$ssid" ] || continue
          # Security: the first flag group that is not a capability marker.
          sec=""
          case "$flags" in
            *WPA3*|*SAE*) sec="WPA3" ;;
            *WPA2*|*RSN*) sec="WPA2" ;;
            *WPA*) sec="WPA" ;;
            *WEP*) sec="WEP" ;;
            *) sec="" ;;
          esac
          # The SSID is passed through EXACTLY as wpa_cli printed it. Its
          # printf_encode() already emits `\\`, `\"`, `\n`, `\r` and `\t` --
          # every one of them a valid JSON escape -- and `\xNN` for anything
          # non-printable, which is the one form that is not valid JSON and
          # is precisely what the server's own fixer rewrites. Re-escaping
          # here would double the backslashes and defeat it.
          # signal and frequency are JSON NUMBERS in the server's struct, so a
          # blank field would make the whole array unparseable.
          case "$sig" in -[0-9]*|[0-9]*) ;; *) sig=0 ;; esac
          case "$freq" in [0-9]*) ;; *) freq=0 ;; esac
          [ "$first" = 1 ] || echo -n ","
          first=0
          printf '{"ssid":"%s","bssid":"%s","signal":%s,"frequency":%s,"security":"%s"}' \
            "$ssid" "$bssid" "$sig" "$freq" "$sec"
        done <<< "$results"
        echo "]"
      }

      # --- connect_stop ---------------------------------------------------
      # Called before every connect AND as the disconnect route. It has to
      # leave wpa_state != COMPLETED, because that is the server's oracle
      # (isWifiConnected), and it has to be persistent, because a disconnect
      # that comes back after a reboot is not a disconnect.
      do_connect_stop() {
        have_adapter || return 0
        wcli disable_network all >/dev/null 2>&1 || true
        wcli disconnect >/dev/null 2>&1 || true
        wcli save_config >/dev/null 2>&1 || true
      }

      # --- connect_start <ssid> [psk] -------------------------------------
      # Blocking, and the server kills the whole process group after 30 s.
      do_connect_start() {
        if ! have_adapter; then
          echo "connect_start: no wireless adapter ('$IFACE' does not exist)" >&2
          exit 1
        fi
        ssid="$1"
        psk="''${2-}"
        [ -n "$ssid" ] || { echo "connect_start: empty ssid" >&2; exit 1; }

        id=$(wcli add_network 2>/dev/null | tail -n1)
        case "$id" in
          [0-9]*) ;;
          *) echo "connect_start: add_network failed: $id" >&2; exit 1 ;;
        esac

        ok "$(wcli set_network "$id" ssid "\"$ssid\"")" \
          || { echo "connect_start: set ssid failed" >&2; wcli remove_network "$id" >/dev/null; exit 1; }

        if [ -n "$psk" ]; then
          ok "$(wcli set_network "$id" psk "\"$psk\"")" \
            || { echo "connect_start: set psk failed" >&2; wcli remove_network "$id" >/dev/null; exit 1; }
        else
          ok "$(wcli set_network "$id" key_mgmt NONE)" \
            || { echo "connect_start: set key_mgmt failed" >&2; wcli remove_network "$id" >/dev/null; exit 1; }
        fi

        # select_network disables every other network, which is what makes
        # "connect to this one" mean what the UI says it means.
        ok "$(wcli select_network "$id")" \
          || { echo "connect_start: select_network failed" >&2; exit 1; }

        # 25 s, inside the server's own 30 s kill. Association plus the DHCP
        # lease networkd takes out afterwards is what the server waits for; it
        # polls for another 10 s after this returns.
        for _ in $(seq 1 50); do
          if [ "$(state)" = "COMPLETED" ]; then
            wcli save_config >/dev/null 2>&1 || true
            exit 0
          fi
          sleep 0.5
        done

        echo "connect_start: timed out in state $(state)" >&2
        do_connect_stop
        exit 1
      }

      case "''${1-}" in
        try_scan)      do_scan ;;
        connect_start) shift; do_connect_start "$@" ;;
        connect_stop)  do_connect_stop ;;
        # AP mode is not configured on this appliance (see nixos/wifi.nix).
        # The server calls this on the way in to every connect, so it must
        # exist and must succeed.
        ap_stop)       exit 0 ;;
        status)        have_adapter || { echo "no wireless adapter"; exit 0; }
                       wcli status; echo "ip=$(ipaddr)" ;;
        *)
          echo "usage: wifi.sh {try_scan|connect_start <ssid> [psk]|connect_stop|ap_stop}" >&2
          exit 1 ;;
      esac
    '';
  };
in
{
  options.nanokvm.wifi = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Bring up the AIC8800 SDIO radio (#85): the out-of-tree
        `aic8800_bsp`/`aic8800_fdrv` modules from this generation's closure,
        the MD5-pinned radio firmware through `hardware.firmware`, a
        wpa_supplicant on `wlan0`, and the `/kvmcomm/scripts/wifi.sh` shim the
        server's WiFi routes exec.

        The DRIVER is GPL source built from `radxa-pkg/aic8800`; the FIRMWARE
        is the one piece of closed content the blob policy permits
        (docs/provenance.md). Turning this off removes both from the closure
        entirely -- which is what `nixos/qemu-test.nix` wants, since there is
        no SDIO host on `-M virt`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The radio's firmware. `hardware.firmware` links it under
    # /run/current-system/firmware, which is the path compiled into
    # aic8800_bsp.ko.
    hardware.firmware = [ nanokvm.aic8800-firmware ];

    # --- the modules --------------------------------------------------
    # Same shape as nanokvm-video.service, for the same reasons: a load-order
    # file walked with insmod is a mechanism a reader can check, and the
    # module directory is resolved through `uname -r` so a generation running
    # on a kernel it was not built for fails with a path that names the
    # mismatch rather than at insmod with a vermagic error.
    systemd.services.nanokvm-wifi = {
      description = "NanoKVM-Pro WiFi (AIC8800 SDIO modules)";
      wantedBy = [ "multi-user.target" ];
      # After the video stack, because that is what this appliance is for and
      # a radio should not delay it. NOT before `network-pre.target`: nothing
      # that can wait ten seconds belongs in front of the interface the board
      # is reached on.
      after = [ "systemd-modules-load.service" "nanokvm-video.service" ];
      # wpa_supplicant-wlan0.service `requires` the wlan0 .device unit, so it
      # would wait for us anyway; ordering says so explicitly. When the radio
      # is absent that unit reports "Dependency failed" and goes *inactive*,
      # not failed -- measured on the board 2026-09-11 -- so it does not gate
      # boot health either.
      before = [ "wpa_supplicant-${iface}.service" ];
      path = [ pkgs.kmod ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # ===================================================================
      # THIS UNIT NEVER FAILS, AND THAT IS THE POINT.
      #
      # It used to `exit 1` when the radio did not come up, and on 2026-09-11
      # the board showed what that costs: the AIC8800 never enumerated, the
      # unit failed, `systemctl is-system-running` went `degraded`,
      # nanokvm-mark-good polled for 240 s and gave up, `bootcount` was never
      # cleared -- so every reboot counted as a failed boot attempt and the
      # fourth would have rolled the board onto the fallback generation. A
      # KVM whose HDMI, USB and ethernet all work is not unhealthy because it
      # has no wireless.
      #
      # So every failure here is a journal line and an inactive interface.
      # The diagnosis stays in the journal -- including the one line that
      # actually explains a dead radio, which is whether the SDIO HOST probed
      # at all. If `104d0000.mmc` is not in /sys/class/mmc_host then no card
      # can possibly have enumerated and the fault is the host or its power
      # sequencer, not the module, the firmware or the chip.
      # ===================================================================
      script = ''
        say() { echo "nanokvm-wifi: $*"; }
        note() { echo "nanokvm-wifi: $*" >&2; }

        # Which SDIO host, if any. Read first, because it is the answer to
        # every other question below.
        host=""
        for h in /sys/class/mmc_host/*; do
          [ -e "$h" ] || continue
          case "$(readlink -f "$h")" in
            *104d0000.mmc*) host=$(basename "$h") ;;
          esac
        done
        if [ -n "$host" ]; then
          say "SDIO host 104d0000.mmc is $host"
        else
          note "the SDIO host 104d0000.mmc did not probe -- no card can enumerate."
          note "check: dmesg | grep -iE 'mmc|pwrseq', and /sys/kernel/debug/devices_deferred"
        fi

        dir=${nanokvm.aic8800}/lib/modules/$(uname -r)
        if [ ! -r "$dir/load-order" ]; then
          note "$dir does not exist: the aic8800 modules were built for a"
          note "different kernel than the one running ($(uname -r)). No WiFi."
          exit 0
        fi

        failed=""
        while read -r ko; do
          [ -n "$ko" ] || continue
          if [ -d "/sys/module/$(basename "$ko" .ko | tr - _)" ]; then
            say "$ko already loaded"
            continue
          fi
          if insmod "$dir/$ko"; then
            say "insmod $ko"
          else
            # ENODEV from aic8800_fdrv is the ordinary "no card on the SDIO
            # bus" answer: the bsp module's power-on timed out, so the fdrv
            # has nothing to attach a wiphy to.
            note "insmod $ko failed -- see dmesg for the driver's own reason."
            failed=1
            break
          fi
        done < "$dir/load-order"

        if [ -n "$failed" ]; then
          note "no WiFi on this boot. The appliance is otherwise unaffected."
          exit 0
        fi

        # The oracle. A successful insmod proves nothing: the modules load
        # fine on a board whose radio never came out of reset.
        for _ in $(seq 1 40); do
          [ -e /sys/class/net/${iface} ] && break
          sleep 0.25
        done
        if [ ! -e /sys/class/net/${iface} ]; then
          note "modules loaded but ${iface} never appeared."
          note "check dmesg for the SDIO scan and the firmware path."
          note "no WiFi on this boot. The appliance is otherwise unaffected."
          exit 0
        fi
        say "${iface} up"
      '';
    };

    # --- the supplicant -------------------------------------------------
    networking.wireless = {
      enable = true;
      interfaces = [ iface ];
      # The UI adds networks at runtime; they live in the writable primary
      # config and survive reboots.
      allowAuxiliaryImperativeNetworks = true;
      # UPSTREAM'S SETTING, and it is the one that matters most in this file.
      #
      # It emits `ctrl_interface=/run/wpa_supplicant/control`,
      # `ctrl_interface_group=wpa_supplicant` and `update_config=1`, and its
      # ExecStartPre creates /run/wpa_supplicant/client. All four are needed,
      # because NIXPKGS PATCHES BOTH PATHS INTO THE BINARY: `strings` on the
      # board's own wpa_cli gives exactly
      #
      #   /run/wpa_supplicant/control     (where it looks for the server)
      #   /run/wpa_supplicant/client      (where it puts its own socket)
      #
      # NOT upstream wpa_supplicant's /var/run/wpa_supplicant. #85 first
      # shipped `userControlled = false` plus an explicit
      # `ctrl_interface=/run/wpa_supplicant`, reasoning from upstream's
      # default -- and on the board a bare `wpa_cli -i wlan0 status`, which is
      # precisely what NanoKVM-Server runs, failed twice over: first
      # "/run/wpa_supplicant/client: No such file or directory", then
      # "Failed to connect to non-global ctrl_ifname: wlan0". Both paths were
      # wrong and neither was visible offline. Measure the binary; do not
      # reason about its defaults.
      userControlled = true;
    };

    # networkd already brings up a station wlan0 (nixpkgs' generic
    # `99-wireless-client-dhcp`, RouteMetric 1025 so ethernet stays preferred).
    # It does NOT get the appliance's `ClientIdentifier = mac` override, which
    # only patches the ethernet network -- so give the wireless one the same
    # treatment, for the same reason: the same MAC does not get the same lease
    # when networkd sends a DUID in option 61.
    systemd.network.networks."99-wireless-client-dhcp".dhcpV4Config.ClientIdentifier =
      config.nanokvm.dhcp.clientIdentifier;

    # --- the script the server execs ------------------------------------
    systemd.tmpfiles.rules = lib.mkOrder 100 [
      "d /kvmcomm 0755 root root - -"
      "d /kvmcomm/scripts 0755 root root - -"
      "L+ /kvmcomm/scripts/wifi.sh - - - - ${wifiScript}/bin/kvmcomm-wifi.sh"
    ];

    # `iw` for the hardware plan's `iw dev wlan0 scan`, and for anyone
    # debugging a radio that associates but passes no traffic.
    environment.systemPackages = lib.mkOrder 100 [ pkgs.iw ];
  };
}
