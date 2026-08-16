{ pkgs, ... }:

# ---------------------------------------------------------------------------
# nanokvm-display -- the mini-display status daemon (see docs/mini-display.md).
#
# A pure-stdlib Python daemon that draws a status screen (IP, video-stream
# state, HDMI input, firmware version, uptime) on the built-in JD9853 SPI TFT
# via /dev/fb0, with inactivity sleep (backlight off) and wake on the knob
# button. It runs with the python3 already present on the Ubuntu-arm64 base
# rootfs -- no interpreter or library is added to the image.
#
# ZERO new blobs: the bitmap fonts are converted AT BUILD TIME from
# terminus_font's PSF console fonts (a nixpkgs package built from source,
# SIL-OFL/GPL-with-font-exception) into a plain-Python literal module
# (font_data.py) by gen_font.py. Nothing opaque ships; every byte of the
# payload is derived from source in this build.
#
# Output layout (mirrors the on-device paths; rootfs.nix / update-package.nix
# copy these subtrees into the image):
#   opt/nanokvm-display/nanokvm_display.py   the daemon
#   opt/nanokvm-display/font_data.py         generated fonts (plain python)
#   etc/systemd/system/nanokvm-display.service
# ---------------------------------------------------------------------------

pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-display";
  version = "1.0";

  src = ./nanokvm-display;

  nativeBuildInputs = [ pkgs.python3 ];

  buildPhase = ''
    runHook preBuild

    # Fonts: small = Terminus 8x16 (PSF1), big = Terminus Bold 14x28 (PSF2).
    python3 ./gen_font.py font_data.py \
      small=${pkgs.terminus_font}/share/consolefonts/ter-u16n.psf.gz \
      big=${pkgs.terminus_font}/share/consolefonts/ter-u28b.psf.gz

    # Both files must at least be valid python3 (the device runs them as-is).
    python3 -m py_compile nanokvm_display.py font_data.py

    # ATX GPIO setup: the vendor's kvmcomm stack (disabled in our image) was
    # what exported the power/reset pins; without this unit neither the web
    # UI's power menu (POST /api/vm/gpio -> sysfs writes) nor the knob control
    # page can actuate anything. Pins (config/hardware.go, kvmcomm gpio.sh):
    #   gpio7  = SW_PWR  (out, idle low -- pulse high to press)
    #   gpio35 = SW_RST  (out, idle low)
    #   gpio75 = power LED sense (in; host on = reads 0)
    #   gpio74 = HDD LED sense   (in; declared but unused by the server)
    # The pinmux register (0x02302024) already holds the required value at
    # boot, so export + direction is all that's needed. "low" = output
    # driving 0 in one write (no high glitch on the power line).
    cat > nanokvm-gpio.service <<'EOF'
[Unit]
Description=NanoKVM-Pro ATX GPIO setup (target power/reset pins)
Before=nanokvm.service nanokvm-display.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'cd /sys/class/gpio && for p in 7:low 35:low 74:in 75:in; do n=''${p%%:*} d=''${p##*:}; [ -d gpio$n ] || echo $n > export; echo $d > gpio$n/direction; done'

[Install]
WantedBy=multi-user.target
EOF

    cat > nanokvm-display.service <<'EOF'
[Unit]
Description=NanoKVM-Pro mini-display status screen
# The display driver stack (fbtft + fb_jd9853) is modprobed by
# systemd-modules-load (/etc/modules-load.d/nanokvm.conf); the daemon itself
# also waits for /dev/fb0, so this ordering is belt-and-braces.
After=systemd-modules-load.service
# Draw whether or not the KVM server is up (it reports "server not running").

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/nanokvm-display/nanokvm_display.py
Restart=on-failure
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0755 nanokvm_display.py "$out/opt/nanokvm-display/nanokvm_display.py"
    install -Dm0644 font_data.py       "$out/opt/nanokvm-display/font_data.py"
    install -Dm0644 nanokvm-display.service "$out/etc/systemd/system/nanokvm-display.service"
    install -Dm0644 nanokvm-gpio.service    "$out/etc/systemd/system/nanokvm-gpio.service"
    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro mini-display status daemon (pure-Python fbdev renderer + build-time-generated fonts; no blobs)";
    license = pkgs.lib.licenses.gpl3Only;
    platforms = pkgs.lib.platforms.all;
  };
}
