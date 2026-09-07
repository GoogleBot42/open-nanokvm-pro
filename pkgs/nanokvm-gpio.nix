{ pkgs, crossPkgs, ... }:

# ---------------------------------------------------------------------------
# nanokvm-gpio -- the ATX power/reset/LED tool for the mainline stack (#81).
#
# One small C program over libgpiod v2 that resolves a line by its device-tree
# `gpio-line-names` entry and pulses / reads / sets it. It replaces the whole
# legacy-sysfs arrangement the 4.19 image still ships: the boot-time
# `nanokvm-gpio.service` that exported global numbers 7/35/74/75, the
# `devmem 0x02300060` pad poke beside it, and the per-press pinmux re-assert
# inside the Go server. On mainline the GPIO request itself programs the pad
# mux (gpio-ranges -> gpio_request_enable), so none of that has anything left
# to do. The source file's header comment has the full rationale.
#
# Dynamically linked against this flake's crossPkgs glibc + libgpiod, i.e. the
# ordinary Nix store closure -- this tool exists for the NixOS appliance
# (nixos/appliance.nix installs it) and the mainline kernel, not for the vendor
# Ubuntu rootfs, which has neither a named-line device tree nor a GPIO driver
# that honours ->request.
# ---------------------------------------------------------------------------

let
  cc = "${crossPkgs.stdenv.cc.targetPrefix}gcc";
in
pkgs.stdenv.mkDerivation {
  pname = "nanokvm-gpio";
  version = "1.0";

  src = ./nanokvm-gpio;

  nativeBuildInputs = [ crossPkgs.stdenv.cc ];
  buildInputs = [ crossPkgs.libgpiod ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    ${cc} -O2 -Wall -Wextra -Werror -std=c99 \
      nanokvm-gpio.c -lgpiod -o nanokvm-gpio
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0755 nanokvm-gpio "$out/bin/nanokvm-gpio"
    runHook postInstall
  '';

  # A silent fallback to the host cc would produce an x86 binary that "builds"
  # here and does nothing on the board; assert the target instead.
  doInstallCheck = true;
  installCheckPhase = ''
    ${crossPkgs.stdenv.cc.targetPrefix}readelf -h "$out/bin/nanokvm-gpio" \
      | grep -q AArch64 \
      || { echo "ERROR: nanokvm-gpio is not an AArch64 ELF" >&2; exit 1; }
  '';

  meta = {
    description = "NanoKVM-Pro ATX GPIO tool (libgpiod v2, lines resolved by device-tree name; #81)";
    license = pkgs.lib.licenses.gpl3Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
