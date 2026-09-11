{ pkgs
, lib ? pkgs.lib
}:

# ===========================================================================
# THE FIXTURE BOTH OFFLINE UPDATE CHECKS RUN AGAINST (#100).
#
# Three synthetic "NixOS systems" and the shell needed to put them into REAL
# nix stores: a chroot store standing in for the device's, a second one
# standing in for the build host's, and a signed `file://` binary cache between
# them. `nanokvm-update` then runs against those with `--root`, and every step
# of an update -- the signature check, the substitution, the profile switch,
# the collection -- is the real thing rather than a simulation of it.
#
# WHY THE FIXTURES ARE DERIVATIONS AND NOT `mkdir -p`. Signature verification
# is the point of this fixture, and nix does not check signatures on
# CONTENT-ADDRESSED paths -- they are self-verifying, so `require-sigs` does
# not apply to them. Anything added with `nix store add-path` inside the
# sandbox is content-addressed and would sail past an untrusted key, making the
# negative test a lie. A `runCommand` output is INPUT-addressed, exactly like a
# real toplevel, so the only thing that can make it valid in the destination
# store is a signature by a key that store trusts.
#
# HOW A REAL CLOSURE GETS INTO A SANDBOX. The build sandbox has the fixture
# FILES (they are inputs) but no Nix database, so nothing in it is a valid
# store path. `closureInfo` hands us the registration for those exact paths --
# computed outside, by `exportReferencesGraph`, with no daemon -- and
# `nix-store --load-db` into a chroot store makes them valid there. That is the
# same mechanism nixpkgs' image builders use, and the same one
# nixos/lib/appliance-artifacts.nix uses to ship a valid store on the image.
#
# THE ONE THING THAT MUST NOT LEAK: a fixture's store path in an environment
# variable. `nix-collect-garbage` scans /proc for store paths that running
# processes reference, so a derivation attribute holding a toplevel path makes
# that toplevel a GC ROOT and the collection half of the check silently proves
# nothing. Hence `paths` -- one file listing them, read into shell variables
# that are never exported.
# ===========================================================================

let
  # A dependency each system has to itself, so "collect what only the old
  # generation used" has something to collect that is not the toplevel.
  mkDep = name: pkgs.runCommand "nanokvm-fixture-${name}" { } ''
    mkdir -p $out/lib
    echo ${name} > $out/lib/${name}.txt
  '';

  # The stand-in for a NixOS system: a version stamp and a
  # switch-to-configuration that records the action it was asked for.
  #
  # The stub is what makes activation observable offline. The real one is an
  # aarch64 binary that writes a bootloader and refuses to run without
  # /etc/NIXOS; what these checks need to know is that the updater CALLED it,
  # with `boot` and never `switch`, after the profile moved and not before.
  mkSystem = { version, dep }: pkgs.runCommand "nixos-system-nanokvm-${version}" { } ''
    mkdir -p $out/bin $out/etc
    echo "${version}" > $out/etc/nanokvm-version
    ln -s ${dep} $out/dep
    printf '%s\n' \
      '#!/bin/sh' \
      'printf "%s %s\n" "$0" "$*" >> "''${STC_LOG:-/dev/stderr}"' \
      'exit 0' > $out/bin/switch-to-configuration
    chmod +x $out/bin/switch-to-configuration
  '';

  v1 = mkSystem { version = "1.0.0"; dep = mkDep "dep-one"; };
  v2 = mkSystem { version = "9.9.9"; dep = mkDep "dep-two"; };
  v3 = mkSystem { version = "9.9.10"; dep = mkDep "dep-three"; };

  all = [ v1 v2 v3 ];
in
rec {
  systems = { inherit v1 v2 v3; };

  # Everything the release side has: all three systems, registered.
  releaseClosure = pkgs.closureInfo { rootPaths = all; };
  # What a flashed device starts with: generation 1 only.
  deviceClosure = pkgs.closureInfo { rootPaths = [ v1 ]; };

  # The paths, as a FILE -- never as an environment variable. See the header.
  paths = pkgs.writeText "nanokvm-fixture-paths" ''
    ${v1}
    ${v2}
    ${v3}
  '';

  # Bash the checks source. Every function here is plumbing; the assertions
  # live in the checks themselves.
  shellLib = ''
    # A private nix state directory, because the sandbox has /nix/store
    # read-only and no /nix/var at all.
    nix_sandbox_setup() {
      export HOME="$PWD/home" XDG_CACHE_HOME="$PWD/xdg-cache" NIX_CONF_DIR="$PWD/nixconf"
      mkdir -p "$HOME" "$XDG_CACHE_HOME" "$NIX_CONF_DIR"
      printf 'experimental-features = nix-command\nbuild-users-group =\n' \
        > "$NIX_CONF_DIR/nix.conf"
    }

    # make_store <dir> <closureInfo>  -- a real chroot store holding those paths
    make_store() {
      local d="$1" ci="$2" p
      mkdir -p "$d/nix/store" "$d/nix/var/nix/profiles" "$d/nix/var/nix/gcroots"
      while read -r p; do
        [ -n "$p" ] || continue
        [ -e "$d/nix/store/$(basename "$p")" ] || cp -a "$p" "$d/nix/store/"
      done < "$ci/store-paths"
      chmod -R u+w "$d/nix/store"
      nix-store --store "local?root=$d" --load-db < "$ci/registration"
      # What makes the profile a GC root inside the chroot, exactly as the
      # image build writes it (nixos/lib/appliance-artifacts.nix).
      ln -sfn /nix/var/nix/profiles "$d/nix/var/nix/gcroots/profiles"
    }

    # sign_into_cache <cachedir> <srcstore> <path>...  -- the release push
    sign_into_cache() {
      local cache="$1" src="$2"; shift 2
      nix copy --store "local?root=$src" \
        --to "file://$cache?secret-key=$PWD/release.key" "$@"
    }

    # generation <root> -- what the system profile points at, by name
    generation() { readlink "$1/nix/var/nix/profiles/system"; }
    # system_path <root> -- ...and what that resolves to, as a store path
    system_path() {
      readlink "$1/nix/var/nix/profiles/$(generation "$1")"
    }
  '';
}
