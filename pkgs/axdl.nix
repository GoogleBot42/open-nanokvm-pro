{ pkgs, ... }:

# ===========================================================================
# axdl-cli -- the AXDL (Axera image DownLoad) USB flasher.
#
# Rust reimplementation of Axera's proprietary download protocol by Kenta Ida
# (ciniml, https://github.com/ciniml/axdl-rs, Apache-2.0). Talks the BootROM USB
# download protocol (VID:PID 32c9:1000) to push a .axp firmware bundle onto an
# AX630C in download mode -- the host-side flasher for our firmware-image /
# base-axp .axp outputs:
#
#     nix run .#axdl -- --file result/*.axp --wait-for-device
#
# PIN: fetchFromGitHub at main HEAD as of 2026-07-18 (rev below, upstream commit
# dated 2025-04-04; axdl-rs is low-traffic). Re-pin with:
#   nix-prefetch-url --unpack https://github.com/ciniml/axdl-rs/archive/<rev>.tar.gz
#   nix hash convert --to sri --hash-algo sha256 <hex>
# and refresh pkgs/axdl-Cargo.lock from the repo at the same rev:
#   curl -sL https://raw.githubusercontent.com/ciniml/axdl-rs/<rev>/Cargo.lock \
#     -o pkgs/axdl-Cargo.lock
# The vendored pkgs/axdl-Cargo.lock drives cargoLock, so no cargoHash is needed
# and the dep set is pinned/offline-reproducible (a clean crates.io lock, no git
# sources -> no cargoLock.outputHashes).
#
# WORKSPACE: axdl-rs is a 3-member cargo workspace (axdl, axdl-cli, axdl-gui). We
# build ONLY axdl-cli (--package axdl-cli --bin axdl-cli) so the GUI member (rfd
# / wasm / web-sys deps) is never compiled. axdl-cli pulls axdl with "usb" +
# "serial".
#
# NATIVE DEPS (via pkg-config):
#   rusb       -> libusb-1.0  (USB BootROM transport)      -> libusb1
#   serialport -> libudev     (serial-port enumeration)    -> udev
# ===========================================================================

let
  rev = "0d4479faa484632cc57e5a20d43958eca5889bf4";
in
pkgs.rustPlatform.buildRustPackage {
  pname = "axdl-cli";
  version = "0.1.2-unstable-2025-04-04";

  src = pkgs.fetchFromGitHub {
    owner = "ciniml";
    repo = "axdl-rs";
    inherit rev;
    hash = "sha256-LBgLX5oxu6Wuz6kThzzAGWa8kGoOgogc1KpzE1581W8=";
  };

  # Use the repo's own Cargo.lock (vendored in-tree) -> no cargoHash needed.
  cargoLock.lockFile = ./axdl-Cargo.lock;

  nativeBuildInputs = [ pkgs.pkg-config ];
  # libusb1 -> rusb (USB transport); udev -> serialport's libudev on Linux.
  buildInputs = [ pkgs.libusb1 pkgs.udev ];

  # Build ONLY the CLI member of the workspace (skip axdl-gui entirely).
  cargoBuildFlags = [ "--package" "axdl-cli" "--bin" "axdl-cli" ];
  # Same scoping for the check phase so we don't drag the GUI into tests.
  cargoTestFlags = [ "--package" "axdl-cli" ];

  meta = {
    description = "Unofficial CLI image-download (AXDL) USB flasher for Axera SoCs (AX630C)";
    homepage = "https://github.com/ciniml/axdl-rs";
    license = pkgs.lib.licenses.asl20;
    mainProgram = "axdl-cli";
    platforms = pkgs.lib.platforms.linux;
  };
}
