{ pkgs, uboot
, # The stored environment is exactly CONFIG_ENV_SIZE, which is the `env`
  # partition's size in nixos/lib/emmc-layout.nix -- the same number
  # pkgs/uboot-mainline.nix compiles in and the same one /etc/fw_env.config
  # carries. Taking it from the layout is what stops the three disagreeing.
  envSize ? (import ../nixos/emmc-partitions.nix { inherit (pkgs) lib; }).env.size
, ... }:

# ===========================================================================
# The U-Boot environment partition image (the `env` partition), from source.
# GPT partition 3, 1 MiB, at physical byte 0x4C0000 -- and this file takes all
# three numbers from nixos/lib/emmc-layout.nix rather than repeating them.
#
# THE VENDOR .axp SHIPS NO ENVIRONMENT AT ALL. Its only env-related manifest
# entry is an `ERASEENV` action with `select="0"`, and the SDK's XML generator
# skips `env` when it emits image nodes. A stock flash therefore ERASES p7 and
# lets the board repopulate it: the vendor U-Boot's download engine writes
# `bootargs` after the repartition step, and `set_slot_ab` / `update_cmdline`
# write the rest on the first boot. We ship one anyway, because an image whose
# every stored partition is built from source should not have a partition whose
# content is "whatever the bootloader felt like writing".
#
# WHAT IS IN IT, and where each half comes from (#89 rung 3).
#
#   1. THE WHOLE COMPILED-IN DEFAULT ENVIRONMENT of the mainline U-Boot this
#      flake builds, lifted from `config/u-boot-initial-env` -- upstream's own
#      `make u-boot-initial-env`, which dumps `.rodata.default_environment` out
#      of the linked `env/common.o`. So it is the environment the image
#      actually carries, not a transcription of the header it came from.
#
#   2. The delta in ./uboot-env.txt: `bootcount`, `upgrade_available` and
#      `bootsystem` -- runtime state, which by definition is not in a
#      compiled-in default. That file documents each one.
#
# WHY THE WHOLE DEFAULT AND NOT JUST THE DELTA. A stored environment REPLACES
# the built-in one wholesale: `env_load()` -> `env_import()` -> `himport_r()`
# with neither `H_NOCLEAR` nor `CONFIG_ENV_APPEND` destroys the hash table and
# imports only what the image holds. An environment carrying just `bootcount`
# would leave U-Boot with no `bootcmd`, no `bootpart` and no load addresses --
# a board that boots only on the ~50 % of attempts where the environment read
# FAILS (#91). Shipping the default verbatim plus the delta makes the two
# outcomes identical, which is the property this board needs while #91 stands:
# the boot does not depend on whether the environment loaded.
#
# The cost is that a stored environment is a snapshot: reflash or rewrite p7
# whenever p5 changes, or the board runs an old bootcmd against a new U-Boot.
# `.#nixos-firmware-image-mainline` packs the environment and the U-Boot it was
# lifted from in one image, so a flash can never disagree; a hand-written
# `uboot` partition must be paired with a hand-written `env`.
#
# WHERE IT GOES. The eMMC user area, at the `env` partition's offset, a single
# copy (no `CONFIG_SYS_REDUNDAND_ENVIRONMENT`, so the image is a 4-byte CRC32
# followed by the NUL-separated variables, with no flag byte). The image is
# exactly the partition size, which is also CONFIG_ENV_SIZE and the size in
# /etc/fw_env.config -- all three come from nixos/lib/emmc-layout.nix, so they
# cannot drift. #78 confirmed the arrangement ON HARDWARE: the appliance's
# `fw_printenv -n bootsystem` read out of the live environment, which it could
# not have done had either number or the CRC layout been wrong.
#
# U-BOOT ITSELF NO LONGER READS IT (patch 0020, #89 rung 3b):
# `CONFIG_ENV_IS_NOWHERE`, because the read is 2048 single-block transfers
# before the boot has done anything and one timing out is not recoverable.
# The partition stays because `fw_printenv`/`fw_setenv` from Linux still use
# it, and because rung 5's rollback contract wants somewhere to keep state.
# ===========================================================================

pkgs.runCommand "nanokvm-uboot-env.bin"
{
  nativeBuildInputs = [ pkgs.ubootTools pkgs.python3 ];
  meta.description = "NanoKVM-Pro U-Boot environment partition image (${toString (envSize / 1024)} KiB)";
} ''
  builtin=${uboot}/config/u-boot-initial-env

  # ---- 1. the compiled-in default, verbatim ------------------------------
  # Sanity: this must be the AX630C port's environment and not some other
  # board's, and it must carry the four things the boot actually depends on.
  for want in bootcmd bootone bootpart preboot msreg_set; do
    grep -q "^$want=" "$builtin" \
      || { echo "ERROR: $builtin has no '$want=' -- wrong U-Boot?" >&2; exit 1; }
  done
  cp "$builtin" env.txt
  chmod u+w env.txt
  echo "  compiled-in default environment: $(wc -l < env.txt) variables"

  # ---- 2. the committed delta --------------------------------------------
  # Every name here must be ABSENT from the built-in default. A name in both
  # is either a value that belongs in the defconfig (and would be silently
  # overridden here) or a stale copy of one -- both are drift, and both fail
  # the build rather than shipping.
  while IFS= read -r line; do
    case "$line" in ""|"#"*) continue ;; esac
    name=''${line%%=*}
    if grep -q "^$name=" "$builtin"; then
      echo "ERROR: '$name' is already in U-Boot's compiled-in default." >&2
      echo "       pkgs/uboot-env.txt carries the DELTA only; set it in the" >&2
      echo "       defconfig or include/configs/ax630c.h instead." >&2
      exit 1
    fi
    echo "  delta: $line"
    printf '%s\n' "$line" >> env.txt
  done < ${./uboot-env.txt}

  mkenvimage -s ${toString envSize} -o env.bin env.txt
  size=$(stat -c %s env.bin)
  [ "$size" = "${toString envSize}" ] \
    || { echo "ERROR: env image is $size B, expected ${toString envSize}" >&2; exit 1; }

  # ---- round-trip: parse it back exactly as U-Boot's env_import does -----
  # crc32 over everything after the 4-byte header, compared with the header,
  # then the NUL-separated variables. This is the check that decides whether
  # the board gets this environment or silently falls back to the compiled-in
  # default, so it is worth making here rather than discovering on a board
  # with no console.
  #
  # (Not `fw_printenv`: pointed at a regular file it spins forever. On the
  # appliance it reads /dev/mmcblk0 at the partition offset and is fine.)
  python3 ${./uboot-env-verify.py} env.bin env.txt

  install -Dm444 env.bin "$out"
''
