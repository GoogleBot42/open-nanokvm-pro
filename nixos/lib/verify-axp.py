"""Read a built .axp back and check it against the contract AXDL enforces.

Usage: verify-axp.py <bundle.axp> <expected.json>

`expected.json` is generated from nixos/emmc-partitions.nix -- the same
`blkdevparts=` clause U-Boot and Linux parse -- so this re-derives the manifest
from the source of truth rather than trusting the packer that wrote it.

The rules checked here are the ones the host flasher (axdl-rs, pkgs/axdl.nix)
actually enforces, read out of its source:

  * exactly one `.xml` member, found by a scan for the first name ending in
    `.xml` -- a second one is a coin flip;
  * every `<Img>` needs `flag`, `name`, `select`, `<ID>`, `<Type>`, `<Block>`
    with BOTH `<Base>` and `<Size>`, `<File>` (may be empty), `<Auth algo=>`
    and `<Description>`: the deserializer declares no defaults, so any
    omission is a hard parse error;
  * `<Type>` must be one of INIT|EIP|FDL1|FDL2|FDL|ERASEFLASH|CODE -- an
    unknown value gets past serde and then panics on an `unwrap`;
  * FDL1 and FDL2 are located by their `name` ATTRIBUTE, and their `<Block>`
    must carry no `id` so it resolves to an absolute RAM address;
  * a CODE image's `<Block id>` must name a partition, and its `<File>` must
    match a ZIP member name EXACTLY (`by_name`, no basename fallback);
  * `<Partition size>` is passed to the device unscaled, so the `unit`
    attribute is the only thing that makes it KiB;
  * a partition name may not exceed 32 UTF-16 units (the table serializer
    panics past that).

Plus the things AXDL will not catch and the board would: an image bigger than
the partition it is written to, a lost Axera signed header, and an A/B pair
that is not one image.
"""

import hashlib
import json
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile

axp, expected_path = sys.argv[1], sys.argv[2]
expected = json.load(open(expected_path))

fails = []
notes = []


def check(ok, msg):
    print(("  ok   " if ok else "  FAIL ") + msg)
    if not ok:
        fails.append(msg)


z = zipfile.ZipFile(axp)
names = z.namelist()
sizes = {i.filename: i.file_size for i in z.infolist()}

print("=== container ===")
xmls = [n for n in names if n.endswith(".xml")]
check(len(xmls) == 1, f"exactly one .xml manifest ({xmls})")
check(all("/" not in n for n in names), "flat archive, no directory members")
check(
    all(i.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) for i in z.infolist()),
    "every member is stored or deflated (the flasher supports nothing else)",
)

root = ET.fromstring(z.read(xmls[0]).decode())
project = root.find("Project")
check(project is not None, "<Project> present")
for attr in ("alias", "name", "version"):
    check(project.get(attr) is not None, f'<Project {attr}=> present')
check(project.findtext("FDLLevel") == "2", "<FDLLevel> is 2")

print("=== partition table vs the blkdevparts= clause ===")
parts = project.find("Partitions")
check(parts.get("strategy") == "1", 'strategy="1"')
check(parts.get("unit") == "2", 'unit="2" (KiB)')
got = [(p.get("id"), p.get("size")) for p in parts.findall("Partition")]
want = [
    (p["name"], "0xffffffff" if p["size"] is None else str(p["size"] // 1024))
    for p in expected["parts"]
]
check(got == want, f"{len(want)} partitions, in order, with the sizes the DT declares")
if got != want:
    for a, b in zip(got, want):
        if a != b:
            print(f"      got {a}, expected {b}")
check(
    all(len(p.get("id")) <= 32 for p in parts.findall("Partition")),
    "no partition name over 32 UTF-16 units",
)
for p in parts.findall("Partition"):
    check(p.get("gap") is not None, f'<Partition id="{p.get("id")}" gap=> present')

print("=== images ===")
TYPES = {"INIT", "EIP", "FDL1", "FDL2", "FDL", "ERASEFLASH", "CODE"}
part_ids = {p.get("id") for p in parts.findall("Partition")}
part_size = {p["name"]: p["size"] for p in expected["parts"]}
imgs = project.find("ImgList").findall("Img")
check(len(imgs) > 0, "<ImgList> is not empty")

code_for = {}
for img in imgs:
    name = img.get("name")
    for attr in ("flag", "name", "select"):
        check(img.get(attr) is not None, f"<Img {attr}=> on {name}")
    for el in ("ID", "Type", "Block", "File", "Auth", "Description"):
        check(img.find(el) is not None, f"<{el}> on {name}")
    t = img.findtext("Type")
    check(t in TYPES, f"<Type>{t}</Type> on {name} is a type the flasher knows")
    block = img.find("Block")
    check(block.find("Base") is not None, f"<Base> on {name}")
    check(block.find("Size") is not None, f"<Size> on {name}")
    auth = img.find("Auth")
    check(auth.get("algo") is not None, f"<Auth algo=> on {name}")
    f = (img.findtext("File") or "").strip()
    if f:
        check(f in sizes, f"{name}: <File>{f}</File> is a member of the archive")
    if t == "CODE":
        pid = block.get("id")
        check(pid in part_ids, f"{name}: <Block id={pid}> names a partition")
        code_for[pid] = f

for fdl in ("FDL1", "FDL2"):
    hit = [i for i in imgs if i.get("name") == fdl]
    check(len(hit) == 1, f"exactly one <Img name={fdl}> (the flasher finds it by name)")
    if hit:
        b = hit[0].find("Block")
        check(b.get("id") is None, f"{fdl}'s <Block> has no id, so it resolves absolute")
        check(b.findtext("Base", "").startswith("0x"), f"{fdl}'s <Base> is hex-prefixed")

print("=== every stored partition, and only from source ===")
for pid, member in sorted(code_for.items()):
    cap = part_size[pid]
    raw = expected["rawSizes"].get(member, sizes.get(member))
    if cap is None:
        check(True, f"{pid} <- {member} ({raw} B, remainder of the device)")
    else:
        check(raw <= cap, f"{pid} <- {member} ({raw} B <= {cap} B)")

for want_part in expected["stored"]:
    check(want_part in code_for, f"{want_part} has an image")

print("=== A/B slots ===")
for a, b in expected["slotPairs"]:
    ha = hashlib.sha256(z.read(code_for[a])).hexdigest()
    hb = hashlib.sha256(z.read(code_for[b])).hexdigest()
    check(ha == hb, f"{a} and {b} are one image ({ha[:16]})")

print("=== Axera signed headers ===")
for pid in expected["signed"]:
    blob = z.read(code_for[pid])[:1024]
    magic, _cap, img = struct.unpack_from("<III", blob, 4)
    total = sizes[code_for[pid]]
    check(magic == 0x55543322, f"{pid}: header magic 0x55543322")
    check(img <= total - 1024, f"{pid}: img_size {img} fits the {total} B member")

print()
if fails:
    print(f"{len(fails)} FAILURES:")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("the bundle satisfies every rule the flasher and the board impose.")
