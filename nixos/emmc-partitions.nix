{ lib, layout ? "minimal" }:

# ===========================================================================
# The eMMC partition map, selected by name from the ONE place it is defined:
# nixos/lib/emmc-layout.nix.
#
# Until #89 rung 4 this file PARSED the `blkdevparts=` clause out of
# dts/ax630c-nanokvm-pro.dts, because the vendor's layout was fixed and the DT
# was the only place it was written down. Rung 4 changes the layout, and the
# SPL's stage offsets are compile-time constants derived from it, so the
# direction is now the other way round: the list is Nix data, the DT clause is
# generated from it (asserted equal in emmc-layout.nix), and so is the SPL's
# partition makefile.
#
#   layout = "minimal"   six partitions, mainline chain    (the default)
#   layout = "vendor"    the shipped 17, A/B twins and all
#
# Everything the old file exported is still exported, with the same names.
# ===========================================================================

let
  layouts = import ./lib/emmc-layout.nix { inherit lib; };
in
if layouts.byLayoutName ? ${layout} then layouts.byLayoutName.${layout}
else throw "emmc-partitions: no layout named '${layout}' (have: ${
  lib.concatStringsSep ", " (lib.attrNames layouts.byLayoutName)})"
