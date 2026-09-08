{ pkgs
, lib ? pkgs.lib
, parts # nixos/emmc-partitions.nix -- the ONE partition table
, project # "AX630C_emmc_arm64_k419_sipeed_nanokvm"
, projectVersion # <Project version="..."> -- free text, ours
, pname
, version
, artifact # output file name under $out
, partitionImages # partition name -> { member; file; rawSize ? null; }
, downloadAgents ? [ ] # ordered [{ id; type; flag; base; file ? null; member ? null; }]
, imgOrder # partition names, in the order the flasher should write them
, slotPairs ? [ ] # [{ a = <partition>; b = <partition>; }] -- must be identical
, signedMembers ? [ ] # partitions whose member carries the 1 KB AX signed header
, notes ? ""
}:

# ===========================================================================
# make-axp-image -- an AXDL `.axp` firmware bundle, built FROM SCRATCH.
#
# `pkgs/image.nix` (the shipping 4.19 `firmware-image`) takes the vendor's
# release .axp and rewrites members inside it. This builder takes no vendor
# bundle at all: it emits the partition manifest and every stored member
# itself, so nothing that lands on the eMMC comes from a binary we did not
# build. It is the packer behind `.#nixos-firmware-image` (#78/#26).
#
# ---------------------------------------------------------------------------
# THE CONTAINER, and where the knowledge comes from.
#
# The format is learned from the SDK's own packer, `tools/mkaxp/make_axp_v2.py`
# (a build script in maix_ax620e_sdk, pinned by this flake), from the vendor
# .axp's own central directory, and from `pkgs/axdl.nix` -- ciniml's axdl-rs,
# the open host flasher this project uses. Written from that understanding, not
# copied.
#
#   * An .axp is a PLAIN ZIP (deflate, allowZip64), FLAT -- no directories.
#   * One member is an XML manifest. Everything else is a partition image or a
#     host-side download agent, stored under the BASENAME of the file the
#     packer was handed; `<File>` in the manifest names it.
#   * make_axp_v2.py dedups colliding basenames by appending `.1`, which is
#     why the vendor bundle carries `boot_signed.bin` + `boot_signed.bin.1`
#     for the A/B kernel slots. We generate the manifest ourselves, so we give
#     every member a distinct, descriptive name instead and never rely on that
#     rule -- but the shape is identical, and the vendor's own names are kept
#     wherever the member plays the same role.
#
# THE MANIFEST:
#
#   <Config><Project alias="AX620E" name="AX630C" version="...">
#     <FDLLevel>2</FDLLevel>
#     <Partitions strategy="1" unit="2">        unit 2 = KiB
#       <Partition gap="0" id="spl" size="768"/>   ... 0xffffffff = rest of device
#     </Partitions>
#     <ImgList>
#       <Img flag="N" name="..." select="1">
#         <ID>SPL</ID><Type>CODE</Type>
#         <Block id="spl"><Base>0x0</Base><Size>0x0</Size></Block>
#         <File>spl_..._signed.bin</File>
#         <Auth algo="0"/>
#         <Description>...</Description>
#       </Img>
#     </ImgList>
#   </Project></Config>
#
#   `flag` bit 0 means "this entry consumes a file from the bundle"
#   (make_axp_v2.py `check_need_input_file`); the host agents additionally set
#   bit 1 and carry a memory `<Base>`. `Auth algo="0"` means no digest -- the
#   vendor ships algo 0 for every entry, so `<Auth>` stays empty (algo 1 would
#   be an MD5 of the member, algo 2 a CRC-16).
#
#   `<Block id>` is the PARTITION id: it is matched against the `<Partitions>`
#   table, which is why the two must agree. Here they cannot disagree: both are
#   generated from `nixos/emmc-partitions.nix`, which parses the one
#   `blkdevparts=mmcblk0:` clause in `dts/ax630c-nanokvm-pro.dts` -- the same
#   string U-Boot parses to find `kernel`/`dtb`/`rootfs`, and the same string
#   the kernel turns into `/dev/mmcblk0pN`. There is no on-disk partition table
#   on this eMMC; that clause IS the table.
#
# WRITE ORDER matters, and `imgOrder` preserves the vendor's: `spl` is written
# LAST, so an interrupted flash leaves a board that goes to AXDL rather than
# one that runs a first-stage loader with nothing behind it.
# ===========================================================================

let
  inherit (lib) concatMapStrings concatStringsSep;

  kib = 1024;

  # <Partitions> -- straight out of the blkdevparts= clause.
  partitionXml = concatMapStrings
    (p: "      <Partition gap=\"0\" id=\"${p.name}\" size=\""
      + (if p.size == null then "0xffffffff" else toString (p.size / kib))
      + "\" />\n")
    parts.parts;

  imgXml = { id, type, flag, base ? "0x0", block ? null, file ? null, description }:
    ''
          <Img flag="${toString flag}" name="${id}" select="1">
            <ID>${id}</ID>
            <Type>${type}</Type>
            <Block${lib.optionalString (block != null) " id=\"${block}\""}>
              <Base>${base}</Base>
              <Size>0x0</Size>
            </Block>
            ${if file == null then "<File />" else "<File>${file}</File>"}
            <Auth algo="0" />
            <Description>${description}</Description>
          </Img>
    '';

  agentXml = concatMapStrings
    (a: imgXml {
      inherit (a) id type flag;
      base = a.base or "0x0";
      file = a.member or null;
      description = "Download ${lib.toLower a.id} image file";
    })
    downloadAgents;

  storedXml = concatMapStrings
    (name:
      let m = partitionImages.${name}; in
      imgXml {
        id = lib.toUpper name;
        type = "CODE";
        flag = 1;
        block = name;
        file = m.member;
        description = "Download ${name} image file";
      })
    imgOrder;

  manifest = ''
    <Config>
      <Project alias="AX620E" name="AX630C" version="${projectVersion}">
        <FDLLevel>2</FDLLevel>
        <Partitions strategy="1" unit="2">
    ${partitionXml}    </Partitions>
        <ImgList>
    ${agentXml}${storedXml}    </ImgList>
      </Project>
    </Config>
  '';

  manifestFile = pkgs.writeText "${project}.xml" manifest;

  # member name -> source file, for every member the ZIP will carry.
  members =
    lib.listToAttrs (map (a: lib.nameValuePair a.member a.file)
      (lib.filter (a: (a.member or null) != null) downloadAgents))
    // lib.listToAttrs (map (n: lib.nameValuePair partitionImages.${n}.member partitionImages.${n}.file) imgOrder);

  # member -> the partition byte cap it must fit, and the RAW size to check
  # against it (an Android-sparse member is smaller than what it expands to,
  # so the caller passes `rawSize` for those).
  caps = lib.listToAttrs (map
    (n:
      let
        m = partitionImages.${n};
        p = parts.byName.${n};
      in
      lib.nameValuePair m.member {
        cap = if p.size == null then 0 else p.size;
        raw = m.rawSize or null;
      })
    imgOrder);

  packJSON = builtins.toJSON {
    inherit members caps;
    xml = "${manifestFile}";
    xmlName = "${project}.xml";
    # A/B pairs, as MEMBER names, and the partitions each is bound to.
    slots = map
      (p: {
        a = partitionImages.${p.a}.member;
        b = partitionImages.${p.b}.member;
        pa = p.a;
        pb = p.b;
      })
      slotPairs;
    signed = map (n: partitionImages.${n}.member) signedMembers;
  };

  packPy = pkgs.writeText "pack-axp.py" ''
    import hashlib, json, os, struct, sys, zipfile

    spec = json.load(open(sys.argv[1]))
    out = sys.argv[2]

    # Deterministic: fixed member order and a fixed DOS timestamp. The manifest
    # goes in first, the way the SDK packer emits it.
    order = [spec["xmlName"]] + sorted(spec["members"])
    files = dict(spec["members"])
    files[spec["xmlName"]] = spec["xml"]

    for name in order:
        path = files[name]
        if not os.path.isfile(path):
            sys.exit(f"ERROR: member '{name}' has no file at {path}")

    # Every stored member must fit the partition the manifest sends it to.
    for name, c in spec["caps"].items():
        size = c["raw"] if c["raw"] is not None else os.path.getsize(files[name])
        if c["cap"] and size > c["cap"]:
            sys.exit(f"ERROR: {name} is {size} B, partition cap is {c['cap']} B")
        print(f"[fit ] {name}: {size} B <= {c['cap'] or 'rest of device'}")

    # The 1 KB Axera signed header, on every member that must carry one:
    # magic 0x55543322 at offset 4, and img_size at offset 12 == the compressed
    # payload that follows it. A member that lost its header boots nothing.
    for name in spec["signed"]:
        with open(files[name], "rb") as f:
            head = f.read(1024)
        total = os.path.getsize(files[name])
        magic, _cap_, img = struct.unpack_from("<III", head, 4)
        if magic != 0x55543322:
            sys.exit(f"ERROR: {name}: bad AX header magic {magic:#x}")
        if img != total - 1024:
            sys.exit(f"ERROR: {name}: header img_size {img} != payload {total - 1024}")
        print(f"[sign] {name}: AX header ok, {img} B payload")

    # A/B SLOTS. There is no slot field anywhere in that header: which slot an
    # image belongs to is decided by the partition it is written to. The vendor
    # bundle proves it -- every one of its A/B pairs is byte-identical. So the
    # check that matters is that the pair really is one image, and that the
    # manifest sends the A member to the A partition and the B member to the B.
    xml = open(spec["xml"]).read()
    for s in spec["slots"]:
        ha = hashlib.sha256(open(files[s["a"]], "rb").read()).hexdigest()
        hb = hashlib.sha256(open(files[s["b"]], "rb").read()).hexdigest()
        if ha != hb:
            sys.exit(f"ERROR: slot pair {s['pa']}/{s['pb']} differs: {ha} vs {hb}")
        for part, member in ((s["pa"], s["a"]), (s["pb"], s["b"])):
            frag = f'<Block id="{part}">'
            if frag not in xml:
                sys.exit(f"ERROR: manifest has no <Block id=\"{part}\">")
            # the <File> that follows that Block must be this member
            tail = xml.split(frag, 1)[1]
            got = tail.split("<File>", 1)[1].split("</File>", 1)[0]
            if got != member:
                sys.exit(f"ERROR: partition {part} is fed '{got}', expected '{member}'")
        print(f"[slot] {s['pa']}/{s['pb']}: one image, {ha[:16]}, correctly bound")

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        for name in order:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(files[name], "rb") as f, z.open(info, "w") as w:
                while True:
                    chunk = f.read(8 << 20)
                    if not chunk:
                        break
                    w.write(chunk)
            print(f"[pack] {name}  ({os.path.getsize(files[name])} B)")
    print(f"[ok] {len(order)} members")
  '';
in
pkgs.stdenvNoCC.mkDerivation {
  inherit pname version;

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [ pkgs.python3 ];

  buildPhase = ''
    runHook preBuild
    set -euo pipefail

    cat > spec.json <<'JSON'
    ${packJSON}
    JSON

    echo "=== every stored member is from source: no base .axp in the inputs ==="
    if grep -q 'nanokvm-pro-base' spec.json; then
      echo "ERROR: a member is sourced from the vendor base .axp" >&2
      grep -o '[^"]*nanokvm-pro-base[^"]*' spec.json >&2
      exit 1
    fi
    echo "  none."

    python3 ${packPy} "$PWD/spec.json" "$PWD/${artifact}"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp ${artifact} "$out/${artifact}"
    cp ${manifestFile} "$out/${project}.xml"
    cat > "$out/IMAGE-NOTES.txt" <<'EOF'
    ${notes}
    EOF
    echo "Installed:"; ls -l "$out"
    runHook postInstall
  '';

  passthru = { inherit manifestFile members; manifest = manifest; };

  meta = {
    description = "AXDL .axp firmware bundle, packed from scratch (manifest + every stored partition from source)";
    platforms = [ "x86_64-linux" ];
  };
}
