{ pkgs, ... }:

# Clean-room EDID set for the LT6911UXC HDMI front-end. Generated from source
# (pkgs/edid/mkedid.py, E-EDID 1.3 + CTA-861, no vendor bytes) to replace the
# same-role entries in Sipeed's shipped /kvmcomm/edid set, fixing two real
# defects: shared monitor identity across modes (hosts that cache per-display
# settings don't re-probe on switch) and edid-decode --check failures. Each
# variant has a DISTINCT product id + serial; byte 12 keeps the server's
# EDIDMap selector so the web UI still names it. Every bin passes
# `edid-decode --check` (verified in the build).
#
#   nix build .#edid   -> result/*.bin

pkgs.runCommand "nanokvm-edid"
  {
    nativeBuildInputs = [ pkgs.python3 pkgs.edid-decode ];
  }
  ''
    mkdir -p "$out"
    python3 ${./edid/mkedid.py} "$out"
    echo "verifying conformity..."
    for f in "$out"/*.bin; do
      echo "== $(basename "$f") =="
      edid-decode --check "$f" | tail -3
      edid-decode --check "$f" | grep -q "conformity: PASS" \
        || { echo "FAIL: $f did not pass edid-decode --check"; exit 1; }
    done
    echo "all EDIDs pass --check"
  ''
