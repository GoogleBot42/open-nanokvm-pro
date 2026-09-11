{ pkgs, roots, ... }:

# ===========================================================================
# checks.<system>.no-x86-blobs -- #95's acceptance test, as a build.
#
#   nix build .#checks.x86_64-linux.no-x86-blobs -L
#
# Two assertions, of two different kinds.
#
#   1. CONTENT. Every regular file in the boot chain's and the image's OWN
#      outputs is walked, and must be neither an ELF for EM_X86_64
#      (e_machine 62) nor a file named `ax_gzip` -- the Axera prebuilt packer
#      #95 retired.
#   2. PLATFORM. None of those packages may still declare
#      `meta.platforms = [ "x86_64-linux" ]`. That declaration is how this
#      tree says "this needs a prebuilt x86-64 host tool", so removing the
#      tool and leaving the declaration would be a lie, and keeping the tool
#      while dropping the declaration would be a broken build on aarch64.
#
# THE ROOTS' OWN FILES, NOT THEIR CLOSURE. The transitive closure of anything
# cross-compiled contains the x86-64 cross toolchain -- `atf-mainline` and
# `uboot-mainline` keep unstripped `.elf`/`.map` debug artefacts, which carry
# store-path references to `aarch64-unknown-linux-gnu-gcc` and friends. Those
# are build tools the outputs merely *name*; scanning the closure for x86-64
# ELFs therefore can never pass, and a check that can never pass is a check
# nobody runs. What is worth asserting is that no x86-64 binary is IN the
# artefacts, and that is what this does.
#
# WHAT IT THEREFORE DOES NOT PROVE: that no x86-64 binary was RUN to make
# them. A build-time tool leaves no trace in the output. That half is asserted
# where it belongs -- `pkgs/boot.nix` deletes `tools/ax_gzip_tool` from its own
# build tree, `pkgs/ax-sign.nix` stages it only under `gzip = true`, and
# `pkgs/atf-mainline.nix` references it only under the same flag -- and
# assertion 2 above is its proxy.
# ===========================================================================

let
  inherit (pkgs) lib;

  rootList = pkgs.writeText "no-x86-blobs-roots"
    (lib.concatMapStrings (p: "${p}\n") (lib.attrValues roots));

  # A package whose meta says x86_64-linux only is a package that still needs a
  # prebuilt host tool. After #95 none of these may.
  hostAgnostic = lib.mapAttrsToList
    (n: p:
      let plats = p.meta.platforms or [ ]; in
      if plats == [ "x86_64-linux" ]
      then throw ("no-x86-blobs: ${n} still declares meta.platforms = "
        + "[\"x86_64-linux\"], i.e. it still needs a prebuilt host tool (#95)")
      else "${n}: platforms ok")
    roots;
in
pkgs.runCommand "no-x86-blobs"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    inherit rootList;
    platformNotes = lib.concatStringsSep "\n" hostAgnostic;
  }
  ''
    set -euo pipefail
    echo "$platformNotes"
    echo

    # Write the report, PRINT it, then fail on it: a check whose own output is
    # swallowed on failure is a check nobody can act on.
    #
    # (The first version of this file ran the scanner as
    # `python3 - … | tee $out <<'PYEOF'`. A heredoc attaches to the LAST
    # command of a pipeline, so `tee` was handed the script, wrote it to $out
    # and exited 0 while python read an empty stdin and did nothing. It
    # "passed". Never trust a check you have not watched fail.)
    ok=1
    python3 ${./no-x86-blobs.py} "$rootList" > report.txt 2>&1 || ok=0
    cat report.txt
    test "$ok" = 1
    cp report.txt "$out"
  ''
