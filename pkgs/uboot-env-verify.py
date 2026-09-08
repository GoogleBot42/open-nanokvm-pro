"""Parse a U-Boot environment image the way U-Boot's env_import() does.

Layout for a NON-redundant environment (no CONFIG_SYS_REDUNDAND_ENVIRONMENT):

    u32 crc32   little-endian, over the ENV_SIZE bytes that follow
    char data[] NUL-separated "name=value", terminated by an empty entry

Usage: uboot-env-verify.py <env.bin> <env.txt>
Exits non-zero, loudly, if the image would not import on the board.
"""

import binascii
import sys

img, txt = sys.argv[1], sys.argv[2]

blob = open(img, "rb").read()
stored = int.from_bytes(blob[:4], "little")
actual = binascii.crc32(blob[4:]) & 0xFFFFFFFF
if stored != actual:
    sys.exit(f"ERROR: env CRC32 {stored:#010x} != computed {actual:#010x}")

entries = {}
for raw in blob[4:].split(b"\0"):
    if not raw:
        break
    name, _, value = raw.decode().partition("=")
    entries[name] = value

want = {}
for line in open(txt):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    name, _, value = line.partition("=")
    want[name] = value

if entries != want:
    sys.exit(f"ERROR: env image holds {entries}, text says {want}")

print(f"env: crc32 {stored:#010x} ok, {len(entries)} variables:")
for k in sorted(entries):
    print(f"  {k}={entries[k]}")
