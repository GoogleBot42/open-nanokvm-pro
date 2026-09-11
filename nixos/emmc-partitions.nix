{ lib, ... }:

# ===========================================================================
# The eMMC partition map, from the ONE place it is defined:
# nixos/lib/emmc-layout.nix.
#
# Until #89 rung 4 this file PARSED the `blkdevparts=` clause out of
# dts/ax630c-nanokvm-pro.dts, because the vendor's layout was fixed and the DT
# was the only place it was written down. Rung 4 changed the layout, and the
# SPL's stage offsets are compile-time constants derived from it, so the
# direction is now the other way round: the list is Nix data, the DT clause is
# generated from it (asserted equal in emmc-layout.nix), and so is the SPL's
# partition makefile.
#
# There is ONE layout since #97 -- `spl` plus a GPT-carrying `disk`. The
# vendor's 17-partition A/B map went with the 4.19 image.
# ===========================================================================

import ./lib/emmc-layout.nix { inherit lib; }
