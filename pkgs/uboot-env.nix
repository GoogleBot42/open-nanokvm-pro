{ pkgs, uboot, envSize ? 1048576, ... }:

# ===========================================================================
# The U-Boot environment partition image (p7 `env`, 1 MiB), from source.
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
# `.#nixos-firmware-image` packs both members from the same build, so a flash
# can never disagree; a hand-written p5 must be paired with a hand-written p7.
#
# WHERE IT GOES. `CONFIG_ENV_IS_IN_MMC=y`, `CONFIG_SYS_MMC_ENV_DEV 0`,
# `CONFIG_SYS_MMC_ENV_PART 0` -- the eMMC user area, at the `env` partition's
# offset, a single copy (no `CONFIG_SYS_REDUNDAND_ENVIRONMENT`, so the image is
# a 4-byte CRC32 followed by the NUL-separated variables, with no flag byte).
# The image is `envRegionSize` (16 KiB), NOT the 1 MiB partition -- see
# nixos/emmc-partitions.nix for why that number is what it is.
# nixos/emmc-partitions.nix computes that offset (0x4C0000) from the
# `blkdevparts=` clause, and #78 confirmed it ON HARDWARE: the
# appliance's `fw_printenv -n bootsystem` read out of the live environment
# there, which it could not have done had either number or the CRC layout been
# wrong. It is also what /etc/fw_env.config on the appliance points at.
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
