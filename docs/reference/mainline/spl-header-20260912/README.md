# #93 — does the AX630C BootROM check the SPL header, with secure boot off?

Run 2026-09-12 on the test device (mainline chain, rung 5 state). One question,
two one-boot experiments; the first one answered it and cost the board.

## What was measured, exactly

`.#spl-minimal`'s signed container is 256 KiB: a 1 KiB header at 0 with the SPL
payload at `0x400`, and an identical second copy at `0x20000` / `0x20400`.
`capability` = `0x54FAFE` has `IMG_BAK_ENABLE` (bit 11) and `IMG_CHECK_ENABLE`
(bit 13) set, so a ROM that rejects the primary header may fall back to the
backup one. **Both copies were corrupted identically** — otherwise "it booted"
would not have been an answer.

The flip is header offset `0x300`, inside `signature[384]` (header bytes
444–827): the exact region a hybrid protective-MBR + GPT header would occupy.

`docs/reference/mainline/spl-header-20260912/mk-experiments.py` builds both
images and asserts, against the good image, that the checksum is reproduced two
ways before either is written:

| | window | value on the good image |
|---|---|---|
| `spl_AX620E_sign.py` (`range(2, (1024-8)//4)`) | header bytes 8–1015 | `0x8F64934A` |
| `boot.c` `verify_img_header` (`calc_word_chksum(&header->capability, sizeof(struct img_header) - 8)`) | header bytes 8–1023 | `0x8F64934A` |

The two windows differ by the last two header words, which are zero inside
`reserved[17]`, so both reproduce the stored `check_sum`. Experiment 2 writes
the wider (`boot.c`) value, which the script shows equals the sign-tool one.

## The images

| file | sha256 | header `check_sum` | differs from good at |
|---|---|---|---|
| `spl-good.bin` (= `.#spl-minimal` signed) | `b2051547219b7e16bc105835a86e289a01c1653d80eaaef12064d5692fc034e4` | `0x8F64934A` | — |
| `spl-exp1-badsum.bin` | `4262bddcabebc88c38e4c0d71a26220e4c09cf9ce2b0baaa64084a1312129e40` | `0x8F64934A` (stale; true sum `0x8F649449`) | `0x300`, `0x20300` |
| `spl-exp2-goodsum.bin` | `f6a53c3e0677b4fc38c2fb557fbe8b824fdf5fcfd6dd2d1cf0859870f20337be` | `0x8F649449` (correct) | `0x0`, `0x1`, `0x300`, `0x20000`, `0x20001`, `0x20300` |

The flipped byte was `0x00` → `0xFF`, which is why the corrected sum is exactly
`0x8F64934A + 0xFF`.

## Baseline (before anything was written)

```
uname -r                7.1.3-nanokvm
devmem 0x02390024 32    0x70000018
devmem 0x02390030 32    0xB0010000     (bootcount healthy)
systemctl is-active nanokvm   active
curl -sk https://127.0.0.1/   200
first 262144 B of /dev/mmcblk0  b2051547…  == .#spl-minimal signed image
```

`/root/rung6/spl-good.bin` held the backup (on the rootfs, so an AXDL recovery
destroys it — the store copy is the real one).

## Experiment 1 — checksum wrong AND signature wrong: **REFUSED**

```
dd if=/root/rung6/spl-exp1-badsum.bin of=/dev/mmcblk0p1 bs=4096 seek=0 conv=fsync,notrunc
sync; echo 3 > /proc/sys/vm/drop_caches
dd if=/dev/mmcblk0p1 bs=4096 count=64 | sha256sum   4262bddc…   (from the medium)
dd if=/dev/mmcblk0  bs=4096 count=64 | sha256sum   4262bddc…   (physical byte 0)
systemctl reboot                                    17:21:01 UTC
```

- Warm reboot: polled to 17:36:55 UTC — **15 min 54 s, no SSH.** A good boot on
  this board reaches SSH in 2–3.5 min.
- One cold power cycle (plug off 17:37:10, on 17:37:39, 29 s off): polled to
  17:48 UTC — **10 min, no SSH.**
- Smart-plug draw stayed at 2.9–3.1 W / 0.04–0.05 A across both, unchanged from
  the dark state.
- The register could not be read: no SSH, and this unit has no serial console.

Nothing else on the eMMC was touched. The image on p1 differed from the one the
board had been booting by exactly two bytes, both inside `signature[]`, and the
board stopped booting. **The BootROM validates the SPL header's signature
region with the secure-boot efuse unburned.**

Experiment 1 changes the checksum *and* the signature at once, so on its own it
proves only that *something* over that region is checked. Experiment 2 (same
flip, `check_sum` corrected) is the disambiguator, and it needs the board back:
p1 is the one partition a shell cannot recover from.

## Experiment 2 — not run

Blocked on an AXDL reflash. The image to flash is

```
/nix/store/awvby4qxmsm7rymqwvlalkbz0mqbn81v-nanokvm-pro-nixos-firmware-image-mainline-2.1.0-alpha.6
nix run .#axdl -- --file …/AX630C_emmc_arm64_k419_sipeed_nanokvm-nixos_mainline.axp --wait-for-device
```

It is a whole-chain image (SPL, mainline TF-A, mainline U-Boot, env, `/boot`,
NixOS rootfs) for this same minimal layout, so it restores the board to a known
state rather than to the rung-5 one; the rung-5 `/root/*-prev` files and
generation 3 do not survive it.

## What this already settles

Either answer to experiment 2 leaves the hybrid header worse off than the split
layout, which is why `docs/nixos-rootfs.md` §6 keeps the split:

- checksum only → every GPT edit needs a compensating fix-up word written by a
  step no partition tool knows about, and a plain `sgdisk` run bricks the board;
- checksum + RSA → the region is not writable at all and the hybrid is dead.

The measured half is the one that matters for a writer's-path argument: a
mismatched header checksum is not tolerated, so the SPL header cannot be a
place other tools write.
