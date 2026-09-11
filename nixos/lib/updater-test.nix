{ pkgs
, lib ? pkgs.lib
, ...
}:

# ===========================================================================
# THE OFFLINE UPDATER LOOP (#100) -- `nix flake check`'s `nanokvm-updater-loop`.
#
# It runs the REAL `nanokvm-update` against REAL nix stores inside a build
# sandbox: a signed `file://` binary cache plays the release cache, a chroot
# store plays the device's, and the whole update happens -- signature check,
# substitution, profile generation, activation, collection. Nothing here is a
# mock except the toplevels themselves (three tiny synthetic "systems", see
# nixos/lib/update-fixture.nix) and switch-to-configuration, which is a stub
# that records the action it was asked for.
#
# WHAT THAT BUYS, and it is most of what can be known before hardware:
#
#   1. an update INSTALLS       -- the closure substitutes, the profile
#                                  advances, `switch-to-configuration boot` is
#                                  called, and `switch` never is.
#   2. an update is AUTHENTICATED -- a NAR signed by a key the device does not
#                                  trust does not install, and NOTHING lands
#                                  when it is refused. This is the property the
#                                  tar bundle never had (#86 checked a hash out
#                                  of its own manifest, which authenticates
#                                  nobody), so it is checked first.
#   3. an update is INCREMENTAL -- what the device already has is not fetched.
#   4. collection is SAFE       -- the generation the ROLLBACK boot config
#                                  names survives a `gc` that drops everything
#                                  else, and the paths only it uses survive
#                                  with it.
#
# WHY THE SCRIPT IS INSTANTIATED AGAINST `pkgs` AND NOT THE APPLIANCE'S. The
# appliance is aarch64; running its copies would need binfmt, which a release
# runner does not have. The script TEXT is identical either way -- the only
# difference is which coreutils and which nix are on PATH -- so this is a test
# of the logic, which is what the logic needs.
#
# WHAT IT CANNOT PROVE: the real switch-to-configuration (it writes a
# bootloader and wants /etc/NIXOS), the eMMC, and whether U-Boot can read what
# was written. Those are the hardware plan in docs/updates.md.
# ===========================================================================

let
  fixture = import ./update-fixture.nix { inherit pkgs lib; };

  tools = import ./updater.nix {
    inherit pkgs lib;
    stableUrl = "https://example.invalid/latest";
    previewUrl = "https://example.invalid/preview";
    # The device's configured cache and keys are placeholders here: the check
    # passes the real (throwaway) ones on the command line, the way a recovery
    # or a bring-up run does.
    cacheUrl = "https://example.invalid/cache";
    trustedPublicKeys = [ "nobody:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ];
    keepGenerations = 2;
  };
in
pkgs.runCommand "nanokvm-updater-loop"
{
  nativeBuildInputs = [
    tools.updater pkgs.nix
    pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.findutils
  ];
  # Deliberately NOT the fixture toplevels: a store path in this environment is
  # a GC root inside the sandbox, and the collection assertions would then hold
  # for the wrong reason. See update-fixture.nix.
  inherit (fixture) releaseClosure deviceClosure paths;
  meta.description =
    "Offline proof of the #100 update: substitute a signed closure into a real store, switch the profile, collect";
} ''
  set -euo pipefail
  ${fixture.shellLib}

  fail() { echo "FAIL: $*" >&2; exit 1; }
  ok()   { echo "  ok: $*"; }

  nix_sandbox_setup
  # Non-exported, so the collector cannot see them (see the header).
  V1=$(sed -n 1p "$paths"); V2=$(sed -n 2p "$paths"); V3=$(sed -n 3p "$paths")
  RELEASE=$releaseClosure; DEVICE=$deviceClosure
  export -n releaseClosure deviceClosure paths
  unset releaseClosure deviceClosure paths

  R="$PWD/root"      # the device
  SRC="$PWD/release" # the build host
  CACHE="$PWD/cache" # the binary cache between them
  export STC_LOG="$PWD/stc.log"

  # =====================================================================
  # The release side: every generation, signed into a file:// cache.
  # =====================================================================
  nix key generate-secret --key-name nanokvm-test-1 > release.key
  nix key convert-secret-to-public < release.key > release.pub
  nix key generate-secret --key-name attacker-1 > attacker.key
  nix key convert-secret-to-public < attacker.key > attacker.pub
  make_store "$SRC" "$RELEASE"
  sign_into_cache "$CACHE" "$SRC" "$V2" "$V3"
  ok "release cache holds two generations, signed by $(cut -d: -f1 release.pub)"

  # =====================================================================
  # The device: one generation, a registered store, a boot config naming it.
  # =====================================================================
  make_store "$R" "$DEVICE"
  mkdir -p "$R/boot/extlinux" "$R/run" "$R/etc/kvm" "$R/var/lib/nanokvm"
  ln -s "$V1" "$R/nix/var/nix/profiles/system-1-link"
  ln -s system-1-link "$R/nix/var/nix/profiles/system"
  ln -s "$R$V1" "$R/run/booted-system"
  ln -s "$R$V1" "$R/run/current-system"
  # A config shaped like the one NixOS's extlinux builder writes since #99: a
  # MENU of every generation, and one DEFAULT that picks among them. The decoy
  # label is first on purpose -- a collector that reads "the init= in this
  # file" pins the wrong generation, and the one it leaves collectable is the
  # fallback's.
  bootcfg() {
    printf 'MENU TITLE ------ NixOS ------\nTIMEOUT 1\nDEFAULT nixos-%s\n\n' "$2"
    printf 'LABEL nixos-decoy\n  MENU LABEL NixOS - decoy\n  LINUX ../nixos/decoy-Image\n  APPEND init=%s/init loglevel=4\n\n' "$3"
    printf 'LABEL nixos-%s\n  MENU LABEL NixOS - this one\n  LINUX ../nixos/Image\n  APPEND init=%s/init loglevel=4\n' "$2" "$1"
  }
  bootcfg "$V1" 1 "$V2" > "$R/boot/extlinux/extlinux.conf"
  bootcfg "$V1" 1 "$V2" > "$R/boot/extlinux/extlinux-fallback.conf"

  nix-store --store "local?root=$R" --verify --check-contents \
    || fail "the fixture device store is not valid before we touch it"
  ok "device store is valid, one generation, both boot configs name it"

  U() { nanokvm-update --root "$R" --cache "file://$CACHE" "$@"; }

  # =====================================================================
  # 1. AUTHENTICITY -- a closure this device does not trust does not install.
  # =====================================================================
  echo "=== an update signed by a key the device does not trust ==="
  if U --trusted-key "$(cat attacker.pub)" install-toplevel "$V2" 9.9.9 \
       > "$PWD/untrusted.log" 2>&1; then
    cat "$PWD/untrusted.log" >&2
    fail "a closure signed by an untrusted key installed"
  fi
  grep -q "lacks a signature by a trusted key" "$PWD/untrusted.log" \
    || { cat "$PWD/untrusted.log" >&2; fail "the refusal was not a signature refusal"; }
  [ ! -e "$R$V2" ] || fail "the untrusted closure landed in the store anyway"
  [ "$(generation "$R")" = "system-1-link" ] \
    || fail "the profile moved on a refused update"
  [ ! -s "$STC_LOG" ] || fail "switch-to-configuration ran for a refused update"
  ok "refused, nothing landed, the profile did not move"

  # The manifest cannot smuggle anything either: it names a path, and a path
  # is all it can name.
  echo '{"version":"9.9.9","toplevel":"/etc/passwd"}' > "$PWD/bad-manifest.json"
  if U --trusted-key "$(cat release.pub)" install-manifest "$PWD/bad-manifest.json" \
       > "$PWD/badpath.log" 2>&1; then
    fail "a manifest naming a non-store path installed"
  fi
  grep -q "not a store path" "$PWD/badpath.log" \
    || { cat "$PWD/badpath.log" >&2; fail "the refusal was for the wrong reason"; }
  ok "a manifest that names something other than a store path is refused"

  # =====================================================================
  # 2. THE UPDATE -- from a manifest, the way the timer does it.
  # =====================================================================
  echo "=== nanokvm-update install-manifest (trusted key) ==="
  jq -n --arg t "$V2" \
    '{format:"nanokvm-nix-closure/1", version:"9.9.9", toplevel:$t, size:4096, closureCount:2}' \
    > "$PWD/manifest.json"
  U --trusted-key "$(cat release.pub)" install-manifest "$PWD/manifest.json"

  [ -e "$R$V2" ] || fail "the new toplevel is not in the store"
  [ -e "$R$V1" ] || fail "the old generation was destroyed by an update"
  ok "the new closure landed; the old one is untouched"

  nix-store --store "local?root=$R" --verify --check-contents \
    || fail "the store is not valid after an update -- nix would refuse to collect"
  ok "the store is still valid (db and contents agree)"

  [ "$(generation "$R")" = "system-2-link" ] \
    || fail "the profile is $(generation "$R"), expected system-2-link"
  [ "$(system_path "$R")" = "$V2" ] \
    || fail "generation 2 does not resolve to the new toplevel"
  ok "the system profile is generation 2 -> the new toplevel"

  grep -q "$V2/bin/switch-to-configuration boot" "$STC_LOG" \
    || { cat "$STC_LOG" >&2; fail "the NEW generation's switch-to-configuration was not run with 'boot'"; }
  ! grep -qE ' switch$| test$| dry-activate$' "$STC_LOG" \
    || { cat "$STC_LOG" >&2; fail "a generation was activated with something other than 'boot'"; }
  ok "switch-to-configuration boot, and never switch"

  # The updater writes no boot files of its own (#99 owns /boot): the stub does
  # nothing, so the configs must still name generation 1 afterwards.
  grep -q "init=$V1/init" "$R/boot/extlinux/extlinux.conf" \
    || fail "something other than the bootloader builder rewrote extlinux.conf"
  ok "nothing in the updater touched /boot"

  [ -r "$R/var/lib/nanokvm/update-pending" ] || fail "no persistent note after an install"
  [ "$(sed -n 's/^VERSION=//p' "$R/var/lib/nanokvm/update-pending")" = "9.9.9" ] \
    || fail "the note does not name the installed version"
  ok "the pending note names 9.9.9"

  # =====================================================================
  # 3. INCREMENTAL -- the second update fetches only what is missing.
  # =====================================================================
  echo "=== a second update, with most of the closure already present ==="
  before=$(find "$R/nix/store" -mindepth 1 -maxdepth 1 | wc -l)
  jq -n --arg t "$V3" \
    '{format:"nanokvm-nix-closure/1", version:"9.9.10", toplevel:$t, size:4096, closureCount:2}' \
    > "$PWD/manifest3.json"
  U --trusted-key "$(cat release.pub)" install-manifest "$PWD/manifest3.json" \
    > "$PWD/second.log" 2>&1 || { cat "$PWD/second.log" >&2; fail "the second update failed"; }
  after=$(find "$R/nix/store" -mindepth 1 -maxdepth 1 | wc -l)
  [ "$after" = "$((before + 2))" ] \
    || fail "the second update added $((after - before)) paths, expected exactly 2 (its toplevel and its dep)"
  ok "only the two paths this generation adds were fetched"
  [ "$(generation "$R")" = "system-3-link" ] || fail "the profile did not advance to generation 3"

  # An update that is already installed is not installed twice.
  U --trusted-key "$(cat release.pub)" install-manifest "$PWD/manifest3.json" \
    > "$PWD/again.log" 2>&1
  grep -q "already in the store" "$PWD/again.log" \
    || { cat "$PWD/again.log" >&2; fail "a closure that was already present was fetched again"; }
  ok "re-installing the same closure fetches nothing"

  # =====================================================================
  # 4. COLLECTION -- while the fallback still names generation 1.
  # =====================================================================
  # The device is now on generation 3 (v9.9.10) with 4 generations of profile
  # link and a fallback config that still names the FIRST one. --keep 2 would
  # drop it; the pin must not let that happen.
  echo "=== nanokvm-update gc --keep 2, fallback naming generation 1 ==="
  rm -f "$R/run/booted-system" "$R/run/current-system"
  ln -s "$R$V3" "$R/run/booted-system"
  ln -s "$R$V3" "$R/run/current-system"
  bootcfg "$V3" 3 "$V2" > "$R/boot/extlinux/extlinux.conf"
  # ...and the fallback is still the generation that last booted healthy.
  bootcfg "$V1" 1 "$V2" > "$R/boot/extlinux/extlinux-fallback.conf"

  U --keep 2 gc > "$PWD/gc1.log" 2>&1 || { cat "$PWD/gc1.log" >&2; fail "gc failed"; }
  cat "$PWD/gc1.log"
  [ -e "$R$V1" ] || fail "gc deleted the generation the ROLLBACK config names"
  [ -e "$R$V1/dep" ] || fail "gc deleted a path only the fallback generation uses"
  [ -e "$R$V3" ] || fail "gc deleted the running system"
  ok "the fallback generation and its dependencies survive --keep 2"

  # ...and it survived because it was PINNED, not because it was recent.
  [ -L "$R/nix/var/nix/gcroots/nanokvm/pin-1" ] || fail "gc wrote no pins"
  grep -q "gc: pinned $V1" "$PWD/gc1.log" \
    || { cat "$PWD/gc1.log" >&2; fail "gc did not pin the fallback generation"; }
  ok "the fallback was pinned by name before anything was deleted"

  nix-store --store "local?root=$R" --verify --check-contents \
    || fail "the store is not valid after a collection"
  ok "the store is still valid after collecting"

  # =====================================================================
  # 5. COLLECTION -- after the fallback has been promoted (what mark-good does)
  # =====================================================================
  echo "=== nanokvm-update gc --keep 1, nothing pinning generation 1 ==="
  bootcfg "$V3" 3 "$V2" > "$R/boot/extlinux/extlinux-fallback.conf"
  U --keep 1 gc > "$PWD/gc2.log" 2>&1 || { cat "$PWD/gc2.log" >&2; fail "the second gc failed"; }
  cat "$PWD/gc2.log"
  [ ! -e "$R$V1" ] || fail "gc kept a generation nothing pins any more"
  # V2 is a LABEL in both configs and the DEFAULT of neither -- the decoy. A
  # collector that pinned every init= in the file would have kept it, and
  # would keep every generation the menu lists, forever.
  [ ! -e "$R$V2" ] || fail "gc kept a generation that is only a non-DEFAULT label"
  [ -e "$R$V3" ] || fail "gc deleted the running system"
  [ -e "$R$V3/dep" ] || fail "gc deleted a dependency of the running system"
  ok "the unpinned generations and their exclusive paths are gone; the live one is intact"

  [ "$(find "$R/nix/var/nix/profiles" -maxdepth 1 -name 'system-*-link' | wc -l)" = 1 ] \
    || fail "old generation links survived --keep 1"
  ok "one generation link left"

  nix-store --store "local?root=$R" --verify --check-contents \
    || fail "the store is not valid after the second collection"

  # =====================================================================
  # 6. THE REFUSAL -- a boot config we cannot read pins NOTHING, and an
  #    empty keep-list must collect nothing rather than everything.
  # =====================================================================
  # The #86 collector shipped exactly this bug in a different file: a
  # keep-list that came out empty read as "keep nothing". The failure is not
  # theoretical either -- a `die` inside a function on the left of a pipe
  # exits only the subshell.
  echo "=== a fallback config whose DEFAULT names no LABEL in the file ==="
  printf 'DEFAULT nixos-nonexistent\n\nLABEL nixos-3\n  APPEND init=%s/init\n' "$V3" \
    > "$R/boot/extlinux/extlinux-fallback.conf"
  before=$(find "$R/nix/store" -mindepth 1 -maxdepth 1 | wc -l)
  if U --keep 1 gc > "$PWD/gc3.log" 2>&1; then
    cat "$PWD/gc3.log" >&2; fail "gc collected with a boot config it could not read"
  fi
  grep -q "names no generation on its DEFAULT entry" "$PWD/gc3.log" \
    || { cat "$PWD/gc3.log" >&2; fail "gc failed for the wrong reason"; }
  [ "$(find "$R/nix/store" -mindepth 1 -maxdepth 1 | wc -l)" = "$before" ] \
    || fail "gc deleted something before refusing"
  ok "gc refuses, and deletes nothing, when a boot config resolves to no generation"

  # =====================================================================
  # 7. THE OTHER REFUSAL -- a fallback generation that is on disk but is NOT
  #    VALID IN THE DATABASE.
  # =====================================================================
  # This is the bootstrap hazard, and it is the board's real state: the
  # generations a pre-nix board was given by tar are directories nix knows
  # nothing about. A gc root pointing at one PROTECTS NOTHING -- measured: nix
  # collects an unregistered path with a gcroot naming it -- so if the fallback
  # config still names one, a collection deletes the generation the rollback
  # boots. The only safe answer is to refuse and say how to fix it.
  echo "=== a fallback generation that is on disk but unregistered ==="
  UNREG="$R/nix/store/00000000000000000000000000000009-nixos-system-nanokvm-untarred"
  mkdir -p "$UNREG/bin"
  echo "8.8.8" > "$UNREG/etc-version"
  bootcfg "/nix/store/00000000000000000000000000000009-nixos-system-nanokvm-untarred" 9 "$V3" \
    > "$R/boot/extlinux/extlinux-fallback.conf"
  before=$(find "$R/nix/store" -mindepth 1 -maxdepth 1 | wc -l)
  if U --keep 1 gc > "$PWD/gc4.log" 2>&1; then
    cat "$PWD/gc4.log" >&2; fail "gc collected while the fallback generation was unregistered"
  fi
  grep -q "NOT VALID in the store database" "$PWD/gc4.log" \
    || { cat "$PWD/gc4.log" >&2; fail "gc failed for the wrong reason"; }
  grep -q "nix-store --load-db" "$PWD/gc4.log" \
    || { cat "$PWD/gc4.log" >&2; fail "the refusal does not say how to fix it"; }
  [ "$(find "$R/nix/store" -mindepth 1 -maxdepth 1 | wc -l)" = "$before" ] \
    || fail "gc deleted something before refusing"
  [ -e "$UNREG/etc-version" ] || fail "gc deleted the unregistered fallback generation"
  ok "gc refuses, deletes nothing, and names the registration fix"

  echo
  echo "the #100 update holds offline: signed, incremental, and safe to collect."
  touch "$out"
''
