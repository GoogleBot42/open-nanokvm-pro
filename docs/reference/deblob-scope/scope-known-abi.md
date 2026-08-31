# #55 scoping — what of the 10 vendor capture/ISP `.ko` is already mapped

Mining pass over `docs/blob-replacement.md` (3216 lines, read in full),
`docs/vcmd-cma-unblock.md`, `docs/architecture.md`, the historical Pro RE in
`docs/plan-sg2002-research.md`, and the shipped open capture source
(`pkgs/kvm-encoder/src/kvm_capture_open.c`, `kvm_capture_geom.{c,h}`,
`kvm_pipeline.{c,h}`), with `pkgs/vc8000-vcmd/` as the reference for what a
finished blob retirement looks like.

Every claim below carries a `file:line` citation. Line numbers are as of the
commit at the top of this session (`d1259b8`).

---

## 0. One-paragraph orientation

Capture userspace is blob-free: `kvm_capture_open.c` drives `/dev/ax_os_mem`,
`/dev/ax_sys`, `/dev/ax_cmm`, `/dev/ax_pool`, `/dev/ax_mipi_rx`,
`/dev/ax_proton` and `/dev/mem` with raw ioctls, no `libax_*` linked
(`pkgs/kvm-encoder/src/kvm_capture_open.c:276-286`; `docs/architecture.md:158-168`).
The *whole* userspace→kernel contract for capture is therefore already written
down in our own source. What is NOT mapped is everything *below* that
contract: register write order, clock/reset/PLL, IRQ, DMA descriptor
programming — which is exactly what a from-scratch `.ko` has to supply
(`docs/blob-replacement.md:635-645`, `:760-766`).

The `.ko` de-blobbing roadmap already sorts these modules by tractability
(`docs/blob-replacement.md:2663-2716`): VC8000E family = done/tractable,
`ax_cmm` = "high-value linchpin, RE-able but hard", the ISP/VIN stack
(`ax_proton`, `ax_mipi_rx`, `ax_gdc`, `ax_vpp`, `ax_ivps`) = "the wall — no open
driver of this lineage exists". Standing direction from Jeremy (2026-08-30) is
that "keep as blobs" entries are waypoints, not endpoints
(`docs/blob-replacement.md:2707-2716`).

---

## 1. Per-module ABI coverage

### Global facts that apply to every module

- Uniform selector interface: every AX ioctl is `_IOWR(magic, nr, 8)` (a few
  `_IO(magic, nr)` with no arg) — `docs/blob-replacement.md:397-417`.
- **`_IOC_SIZE=8` is a lie.** The kernel handlers ignore the declared size and
  `copy_from_user` a much larger struct straight from the arg pointer. This one
  fact was the whole Stage-3 wall — `docs/blob-replacement.md:1286-1297`.
- The pointed-to structs are **pointer-free scalars**; the kernel resolves every
  device/pipe/chn object in-kernel from an id byte, so byte-replay of the
  captured `copy_from_user` prefix is valid — `docs/blob-replacement.md:1613-1627`.
- Both `ax_mipi_rx.ko` (106 KB) and `ax_proton.ko` (4.5 MB) are **unstripped**
  and disassemble cleanly with on-device `objdump` — `docs/blob-replacement.md:1481-1486`.
  So is `ax_cmm.ko` — `docs/blob-replacement.md:1385-1400`.
- Per-device magic table (vendor trace, 2026-07-20) — `docs/blob-replacement.md:407-417`.

| Device node | magic | distinct selectors in vendor trace |
|---|---|---|
| `/dev/ax_mipi_rx` | `'m'` 0x6d | 7 |
| `/dev/ax_proton` | `'p'` 0x70 | 36 |
| `/dev/ax_cmm` | `'p'` 0x70 | 10 |
| `/dev/ax_pool` | `'p'` 0x70 | 6 |
| `/dev/ax_hrtimer` | `'u'` 0x75 | 1 (1145 calls — pure frame-wait timing) |
| `/dev/ax_sys`, `/dev/ax_os_mem` | `'p'`, `'O'` | 1 each |

Capture half = **43 selectors** (7 mipi_rx + 36 proton); the whole
capture→encode path was ~101 — `docs/blob-replacement.md:418-424`.
Full `/dev` node inventory: `/dev/ax_{sys,cmm,pool,sysmap,os_mem,hrtimer,log}`,
`/dev/ax_proton`, `/dev/ax_mipi_rx`, `/dev/ax_venc`, `/dev/ax_jenc`, `/dev/mem`
— `docs/blob-replacement.md:132-133`.

---

### 1.1 `ax_sys` — `/dev/ax_sys` + `/dev/ax_os_mem` (+ `ax_sysmap`, `ax_hrtimer`, `ax_log`)

**We call 2 selectors.**

| dev | nr | cmd word | arg | decoded |
|---|---|---|---|---|
| `ax_os_mem` | 1 | `0xc0094f01` (`_IOC_SIZE=9`) | `{u64 desc_ptr; u8 flag}` | The **only genuine pointer arg** on the capture path. Descriptor words 0/1 = `{width, height}`; kernel returns the allocated **phys in place** (`arg[0..7] ← phys`). `docs/blob-replacement.md:1166-1172`, `:1195-1202`; code `kvm_capture_open.c:288-300`. |
| `ax_sys` | 45 | `0xc008702d` | `{u32 0x016e3600, u32 0}` | sys-mem size scalar (≈24 MB). Identical byte-for-byte at 1080p **and 4K30** on the vendor path — `docs/blob-replacement.md:3180-3184`; code `kvm_capture_open.c:302-303`. |

Decoded further: the returned phys is immediately `mmap`'d as a 4 KB management
page; our code maps it as a **priming side-effect only** and never reads/writes
it (`kvm_capture_open.c:296-300`). The `4d 4d 53 4f` "MMSO" magic once seen in
that page is **residual physical-RAM content from an earlier run**, not a
kernel-populated control block — `docs/blob-replacement.md:1415-1420`.
The management pages carry **zero** CPU-visible command traffic
(`docs/blob-replacement.md:1185-1189`).

The `flag` byte (`arg[8]`) is `0xf0` for 1080p H.264, `0x70` for 720p H.264,
`0x00` for 1080p MJPEG — **never decoded**; `docs/blob-replacement.md:1230-1245`.
We hardcode `0xf0` (`kvm_capture_open.c:136-142`), and it was **replayed
verbatim at 4K and worked** — `docs/blob-replacement.md:3198-3203`.

`/dev/ax_hrtimer` nr1 is the vendor's frame/DMA-done wait
(`docs/blob-replacement.md:415`, `:565`). **Our open path never uses it** — it
polls `nr101` with a 5 ms `usleep` (`kvm_capture_open.c:515-526`). `ax_sysmap`
and `ax_log` are never touched by our code at all.

### 1.2 `ax_cmm` — `/dev/ax_cmm`, magic `'p'`

**We call 5 selector invocations (4 distinct nrs).** All args are 4096-byte
zeroed buffers with a few scalar fields set (`kvm_capture_open.c:181-199`).

| nr | cmd word | cfu size | fields we set | decoded |
|---|---|---|---|---|
| 10 (#1) | `0xc008700a` | ~48 B | `count@0x00=4`, `@0x08=0x02400000`, `size@0x2c=0x000d4008` | Kernel allocates and **writes back a mapped userspace vaddr at `@0x20`**. `docs/blob-replacement.md:1316-1323`; code `:195`. Note `@0x08` = the **ISP MMIO base**, i.e. these are the ISP/MIPI register-window mappings. |
| 10 (#2) | `0xc008700a` | ~48 B | `count=4`, `@0x08=0x02500000`, `size@0x2c=0x2000` | same shape; `@0x08` = a second register window. Code `:196`. |
| 17 | `0xc0087011` | **888 B (`0x378`)** | `u32@0x368 = 17` | Fully RE'd by disassembly: dispatch in `ax_cmm_userdev_adapter_ioctl @0x4480` → `_ioctrl_get_mem_config.isra.0 @0x3a60`; range-checks `@0x368∈[1,46]`, `@0x36c∈[0,31]`, `@0x370∈[0,15]`, `u8@0x374∈[0,2]`, returns `-EFAULT` as a *validation* rejection. `docs/blob-replacement.md:1385-1412`; code `:199`. |
| 0 | `0xc0087000` | ~64 B | `count=4`, `flag@0x28=1`, `size@0x2c=0x188` (392 B), `name@0x3c="anonymous:isp_model_manger_list"` | Named CMM allocation for ISP metadata; **not** the frame pool. `docs/blob-replacement.md:1325-1330`; code `:197`. |
| 6 | `0xc0087006` | ~64 B | same + `phys@0x08 = isp_model_phys` | Kernel returns that phys in place; attaches the named block. `docs/blob-replacement.md:1325-1330`; code `:198`. |

Behavioural facts banked: `cmm nr10` is **content-multiplexed** — an inline
`{small,0}` selects a pool-block branch, an 8-byte *pointer* selects a branch
that copies back a large response struct
(`docs/blob-replacement.md:1206-1214`). Cross-session the kernel does **not**
EPERM a duplicate `nr0` — it allocates another 4 KB block, hence our
reuse-before-allocate discipline (`kvm_capture_open.c:365-398`;
`docs/blob-replacement.md:1802-1810`). A fixed CMM **partition-name table**
lives at phys `0x71022000` holding 40 module carveout names (ISP/VENC/VIN/
SENSOR/…), populated once at boot — `docs/blob-replacement.md:1310-1313`.
The allocator layout is bottom-up first-fit over the 200 MB carveout
`0x73800000–0x7FFFFFFF` — `docs/vcmd-cma-unblock.md:56-63`.
`cmmpool=` is a **mandatory** insmod parameter (the OTA brick)
— `pkgs/rootfs/ax-load-drv.sh:75-109`.

Roadmap position: `ax_cmm` is called out as the "high-value linchpin" —
everything imports its `AX_OSAL_*`/pool symbols, so replacing it means
re-implementing the inter-blob ABI, not just one driver
(`docs/blob-replacement.md:2682-2687`). Note we already have a **from-source
contiguous allocator** for the encode side to crib from:
`pkgs/vc8000-vcmd/framebuf_alloc.c` (first-fit over a module-param carveout,
per-fd ownership) — `docs/blob-replacement.md:2813-2831`.

### 1.3 `ax_pool` — `/dev/ax_pool`, magic `'p'`

**We call 3 selectors.**

| nr | cmd word | arg | decoded |
|---|---|---|---|
| 22 | `0xc0087016` | struct: 40-byte zero header then `AX_POOL_CONFIG_T` at **0x28** | `MetaSize@0x28=0x1000`, `BlkSize@0x30` (=`stride·h·2`), `BlkCnt@0x38=4`, `CacheMode@0x40=0`, `PartitionName@0x44="anonymous"`. `docs/blob-replacement.md:1301-1307`; code `kvm_capture_open.c:305-315`. |
| 20 | `0x00007014` (`_IO`, no arg) | — | `AX_POOL_Init`. `docs/blob-replacement.md:1308-1309`; code `:316`. |
| 21 | `0x00007015` (`_IO`, no arg) | — | `AX_POOL_Exit` (teardown). Code `kvm_capture_open.c:82-83`, `:332`. |

Decoded pool memory layout (device-verified by dumping the live region over
`/dev/mem`, 2026-08-17): `comm_pool_0 = [BlkCnt × MetaSize meta pages][blk0]
[blk1]…` with each data block at a **page-aligned pitch** `ALIGN_UP(BlkSize,
4096)` — `docs/blob-replacement.md:1831-1847`; implemented at
`kvm_capture_geom.c:247-257` and `kvm_capture_open.c:543-563`. The old
`base + idx*BlkSize` formula was the green-bar/scrolling bug. The pool base is
scraped from `/proc/ax_proc/mem_cmm_info` (`kvm_capture_open.c:201-232`).
`BlkSize` appears in **no** shared region — geometry crosses to the kernel only
via this struct + the os_mem nr1 descriptor (`docs/blob-replacement.md:1308-1314`).

### 1.4 `ax_base` — no device node exercised

Never opened, never ioctl'd by our code. Documented as "shared MPI plumbing"
and kept because everything links it (`docs/blob-replacement.md:229`);
classified with `ax_sys`/`ax_pool` as "Infrastructure (small, follow the CMM
decision) — thin glue/OSAL layers; only worth touching once `ax_cmm` is open,
since they share its symbol ABI" (`docs/blob-replacement.md:2697-2699`).
The one behavioural fact recorded: the #50 crash trace passes through
`ax_isp_close ← osal_release ← __fput`, i.e. the OSAL/`ax_base` layer owns the
char-device fops that proton hangs off (`docs/blob-replacement.md:2949-2954`).

### 1.5 `ax_npu` — no device node exercised

Never called. Loaded **only** because `ax_proton.ko` hard-depends on it (AI-ISP
glue) even though no network is ever run — `docs/blob-replacement.md:128-130`,
`:230`; `pkgs/rootfs/ax-load-drv.sh:112`. The only NPU-adjacent traffic we ever
issue is `proton nr89 npu_throttle_info_set` (424 B, replayed verbatim), and
the AI-ISP model-manager ioctl `nr138`, which we now deliberately **do not**
issue (§4).

### 1.6 `ax_ivps`, `ax_vpp`, `ax_gdc` — no device nodes, zero ioctls

See §5. Not exercised at all by the open capture path or the open encode path.

### 1.7 `ax_mipi_rx` — `/dev/ax_mipi_rx`, magic `'m'` 0x6d — **100% of the selector surface recovered**

Handler ABI fully recovered by disassembly: `ax_mipi_rx_ioctl @0x690` is
`(cmd_w0, user_arg_x1, ctx_x2)`; `*(ctx+8)` = the in-kernel device object,
`user_arg` = the userspace struct pointer — `docs/blob-replacement.md:1488-1503`.

| nr | cmd word | `AX_*` | in-kernel handler | cfu size | struct | we call it? |
|---|---|---|---|---|---|---|
| 0 | `0x00006d00` (`_IO`) | `MIPI_RX_Init` | `ax_mipi_rx_reg_init @0x3c90` | 0 | none — **ioremaps `0x2600000`** | yes (`kvm_capture_open.c:358`) |
| 1 | `0x00006d01` (`_IO`) | `DeInit` | `ax_mipi_deinit` | 0 | none | yes (teardown, `:496`) |
| 2 | `0xc0086d02` | `SetAttr` | `ax_mipi_set_attr @0x35c0` | **28** | `{u32 idx, …, u32 lanes, u32 rate, u8[8] lanemap}` | yes (`:428`) |
| 4 | `0xc0086d04` | `Reset` | `ax_mipi_reset @0x36d0` | **4** | `{u8 idx}` | yes (`:429`) |
| 5 | — | `Unreset` | `ax_mipi_unreset @0x3778` | **4** | `{u8 idx}` | **no** |
| 6 | `0xc0086d06` | `Start` | `ax_mipi_start @0x3800` | **4** | `{u8 idx}` | yes (`:430`) |
| 7 | `0xc0086d07` | `Stop` | `ax_mipi_stop` | **4** | `{u8 idx}` | yes (teardown, `:495`) |
| 8 | `0xc0086d08` | `SetLaneCombo` | `ax_mipi_set_lanecombo @0x39b0` | **4** | `{u32 combo}` | yes (`:427`) |

Source: `docs/blob-replacement.md:1494-1503`.

The live 28-byte `SetAttr` payload (1080p, ISP-bypass) is byte-documented:
`00000000 00000000 00000000 04000000 58020000 00010304 02050000` =
`idx=0, lanes=4, rate-field=0x258 (600), lanemap 00 01 03 04 02 05` —
`docs/blob-replacement.md:1505-1511`; embedded verbatim at
`kvm_capture_open.c:117`. Cross-checked against the documented MPI struct the
vendor backend fills: DPHY, 4 lanes, `nDataRate=600`, DataLaneMap `{0,1,3,4}`,
ClkLane `{2,5}`, `AX_LANE_COMBO_MODE_0` (`kvm_pipeline.c:119-134`;
`kvm_pipeline.h:9-11,27-29`).

**`nDataRate=600` is a PHY timing band, not a per-lane Mbps ceiling** — the
vendor path captures 4K30 (~4 Gbps) with the identical MIPI config, because
D-PHY is source-synchronous off the LT6911's clock lane
(`docs/blob-replacement.md:3167-3186`; `kvm_capture_geom.h:40-50`).

### 1.8 `ax_proton` — `/dev/ax_proton`, magic `'p'` 0x70 — the big one, substantially mapped

Dispatch structure recovered: `ax_isp_ioctl @0x982e0` is a two-level dispatch —
`attr = *(ctx+8)`, `nr` routed by range to `isp_vin_dev_ioctl` (nr ≤ 0x21),
`isp_vin_pipe_ioctl` (≤ 0x61), `isp_vin_frame_ioctl` (≤ 0x68), plus
`irq`/`stat`/`sync` handlers — `docs/blob-replacement.md:1515-1517`, `:1629-1637`.
`isp_vin_pipe_ioctl @0x98790` uses a **63-entry jump table at `.rodata+0xbb04`**:
index `= nr-35`, target `= 0x987d0 + 4*int16(table[index])`
(`docs/blob-replacement.md:1633-1637`). `AX_ISP_*` and `AX_VIN_*` share this
one fd and one `nr` namespace — the "ISP" API is not a separate driver
(`docs/blob-replacement.md:562-568`).

**Selectors our open backend actually issues** (in call order;
`kvm_capture_open.c:344-501`, payload arrays `:117-130` + `kvm_capture_geom.c`):

| nr | cmd word | cfu size | handler / role | our payload source |
|---|---|---|---|---|
| 0 | `0xc0087000` | 8 | `AX_VIN_Init` global, `{3,3}` | inline `:362` |
| 2 | `0xc0087002` | 8 | VIN global, `{4,1}` | `PL_nr2p` `:120` |
| 12 | `0xc008700c` | 16 | `AX_VIN_Init` global — **embeds the isp_model block phys at [0..7]** | `PL_nr12` `:119`, patched `:420-423` |
| 17 | `0xc0087011` | **376** | `ax_vin_dev_create @0x8dd18` — CreateDev, pure scalar | `kvm_geom.dev_attr` |
| 21 | `0xc0087015` | **376** | `ax_vin_dev_attr_set @0x8e1b0` — SetDevAttr (issued **twice**, 2nd with distinct bytes) | `dev_attr` / `dev_attr2` |
| 30 | `0xc008701e` | 56 | `SetDevBindPipe` | `PL_nr30` `:121` |
| 22 | `0xc0087016` | 8 | `SetDevBindMipi` | `PL_nr22p` `:122` |
| 35 | `0xc0087023` | **76** | `ax_vin_pipe_create` — CreatePipe (scalar, pipe_id@0) | `pipe_create` |
| 42 | `0xc008702a` | **76** | `ax_vin_pipe_attr_set` — SetPipeAttr (pure input) | `pipe_attr` |
| 56 | `0xc0087038` | **10** | `ax_vin_pipe_black_level_set` — ISP-bypass cfg | `PL_nr56` `:123` |
| 74 | `0xc008704a` | **24** | `ax_vin_pipe_scene_attr_set` — ISP-bypass cfg | `PL_nr74` `:124` |
| 54 | `0xc0087036` | **180** | `ax_vin_pipe_partition_info_set` — ISP-bypass cfg | `PL_nr54` `:125` |
| 89 | `0xc0087059` | **424** | `ax_vin_pipe_npu_throttle_info_set` — ISP-bypass cfg | `PL_nr89` `:126` |
| 48 | `0xc0087030` | **48** | `ax_vin_pipe_yuv_chn_attr_set` (pipe@0, fmt@20 ≤8) | `chn_attr` |
| 55 | `0xc0087037` | **8** | `ax_vin_pipe_yuv_chn_enable` (pipe@0, chn@1, u32@4) | `PL_nr55` `:127` |
| 38 | `0xc0087026` | **1** | `ax_vin_pipe_open` (pipe_id only) | inline `:454` |
| 40 | `0xc0087028` | **1** | `ax_vin_pipe_start` — StartPipe | inline `:455` |
| 19 | `0xc0087013` | **1** | `ax_vin_dev_enable` — EnableDev | inline `:457` |
| 101 | `0xc0087065` | **248** | `ax_vin_pipe_frame_get` — GetYuvFrame; out: 248 B descriptor, **pool block handle `0x5e0000NN` at offset 0x28** | `PL_nr101` `:130`, `FRAME_HANDLE_OFF` `:132` |
| 104 | `0xc0087068` | (desc) | `AX_VIN_ReleaseYuvFrame`, fed the nr101 descriptor back | `:587-597` |
| **138** | `0xc008708a` | 8 (phys) | AI-ISP/AINR `vin_model_manager_init` — **deliberately NOT issued** (#50), gated behind `OPENKVM_NR138` | `:403-419` |
| 20 / 41 / 39 / 55 / 36 / 18 | `0xc0087014/29/27/37/24/12` | 1 | teardown: DisableDev / StopPipe ×2 / DisableChn / DestroyPipe / DestroyDev | `:485-501` |

cfu sizes are from the leaf-handler disassembly tables at
`docs/blob-replacement.md:1519-1527` and `:1638-1656`; the selector→`AX_*` map
is at `:516-561`.

**Vendor selectors we do NOT issue** (mapped but unexercised by the open path
— relevant because a from-scratch driver may or may not need them):
`nr43` `ax_vin_pipe_attr_get` (readback, `copy_to_user`, `:1641`);
`nr53`, `nr158`, `nr160`/`nr163` (`AX_ISP_Create`/`Open`/`Destroy`, `:545-560`);
`nr69`/`nr70` = `regio_switch`/`regio_sync`, 1 byte each, the vendor's streaming
loop (`:1655-1656`); `nr109` frame poll (`:555`); `nr139` `AX_VIN_Deinit`
(`:557`); `nr1` `AX_VIN_Deinit` (`:526`). Plus `hrtimer nr1`.

Geometry-word map inside the replayed structs (mechanically re-derived, #17) —
`docs/blob-replacement.md:1880-1893`, implemented `kvm_capture_geom.c:10-18`,
`:55-64`:

| payload | width | height | stride |
|---|---|---|---|
| os_mem nr1 descriptor | word 0 | word 1 | — |
| pool nr22 floorplan | — | — | `BlkSize@0x30 = stride·h·2` |
| proton nr17/nr21 dev attr (376 B) | `@0x58` | `@0x5c` | `@0xdc` |
| proton nr21 dev attr **#2** | `@0x58` | `@0x5c` | stays 0 |
| proton nr35 CreatePipe (76 B) | `@0x1c` | `@0x20` | none |
| proton nr42 SetPipeAttr (76 B) | `@0x1c` | `@0x20` | `@0x24` |
| proton nr48 SetChnAttr (48 B) | `@0x08` | `@0x0c` | `@0x10` |

Everything else in those structs is opaque replayed vendor bytes. Decoded
extras inside the 376-byte dev attr: lane map `00 01 02 03 1e`, format `0x05`,
dev id at offset 240 (range-checked ≤3) — `docs/blob-replacement.md:1526-1527`.
Stride == width, hardware-proven (was assumption A2, falsified 2026-08-31) —
`kvm_capture_geom.h:54-61`; `docs/blob-replacement.md:3138-3145`.

---

## 2. The working blob-free bring-up sequence (Stage 6 + #17), cold module-load → YUV frames

This is the shipped sequence, read off `kvm_capture_open.c` and cross-checked
against the Stage-6 write-up (`docs/blob-replacement.md:1657-1670`).

**Phase 0 — module load** (`pkgs/rootfs/ax-load-drv.sh:102-127`), strictly ordered:
`ax_sys` → `ax_cmm cmmpool=anonymous,0,<offset>,<size-8>M` → `ax_pool` →
`ax_base` → `ax_npu` → `ax_ivps` → `ax_vpp` → `ax_gdc` →
[`ax630c_venc_vcmd` (ours)] → `ax_mipi_rx` → **`ax_proton mem_iq_level=1`**.

**Phase 1 — SYS + VB pool** (`kvm_sys_init`, `kvm_capture_open.c:235-326`):
1. `kvm_geom_check(w,h)` / `kvm_geom_build` — refuse out-of-envelope geometry
   rather than clamp (`:249-257`).
2. open `/dev/ax_os_mem`, `/dev/ax_sys`, `/dev/ax_cmm`, `/dev/ax_pool`,
   `/dev/ax_mipi_rx`, `/dev/ax_proton`, `/dev/mem` (`:276-286`).
3. **os_mem nr1** with `{desc_ptr → {w,h}, flag=0xf0}` → returns phys (`:288-295`).
4. `mmap` that phys, 4 KB — priming side-effect only (`:296-300`).
5. **sys nr45** `{0x016e3600, 0}` (`:302-303`).
6. **pool nr22** floorplan: MetaSize 4096, BlkSize `stride·h·2`, BlkCnt 4,
   name "anonymous" (`:305-315`).
7. **pool nr20** Init (`:316`).
8. scrape `comm_pool_0` phys base from `/proc/ax_proc/mem_cmm_info` (`:319-320`).

**Phase 2 — global context + MIPI PHY + VIN** (`kvm_cap_start`, `:344-476`):
9. **mipi nr0** Init (ioremaps `0x2600000`) (`:358`).
10. **cmm nr10** ×2 — `{count=4, @0x08=0x02400000, size=0xd4008}` then
    `{@0x08=0x02500000, size=0x2000}` (`:360-361`).
11. **proton nr0** `{3,3}` (`:362`).
12. **cmm nr17** — 888-byte struct, `u32@0x368=17` (`:364`).
13. isp_model block: **reuse-before-allocate** from `/proc`, else **cmm nr0**,
    then **cmm nr6** with the phys (EPERM tolerated) (`:365-402`).
14. *(**proton nr138 SKIPPED** — see §4/#50)* (`:403-419`).
15. **proton nr12** VIN_Init, 16 B with the isp_model phys at `[0..7]` (`:420-423`).
16. **proton nr2** `{4,1}` (`:424`).
17. **mipi nr8** SetLaneCombo(0) → **mipi nr2** SetAttr(28 B, 4-lane) →
    **mipi nr4** Reset → **mipi nr6** Start (`:426-431`).
18. **proton nr17** CreateDev(376) → **nr21** SetDevAttr(376) → **nr30**
    BindPipe(56) → **nr22** BindMipi(8) → **nr21** SetDevAttr **#2** (`:433-439`).
19. **proton nr35** CreatePipe(76) → **nr42** SetPipeAttr(76) (`:442-444`).
20. **ISP-bypass datapath config — REQUIRED:** **nr56**(10) → **nr74**(24) →
    **nr54**(180) → **nr89**(424) (`:445-450`).
21. **proton nr48** SetChnAttr(48) → **nr55** EnableChn(8) (`:451-453`).
22. **proton nr38** pipe_open(1) → **nr40** StartPipe(1) → **nr19** EnableDev(1)
    (`:454-458`).
23. re-derive `comm_pool_0` base (it can move across suspend/resume) (`:461-470`).

**Phase 3 — frame loop** (`kvm_cap_get`, `:504-585`):
24. **proton nr101** with the 248-byte descriptor, retried every 5 ms; success
    when the handle at `+0x28` is non-zero (`:517-527`).
25. `blkidx = handle & 0xff`, bounds-checked against BlkCnt; a stray handle is
    **released before erroring** so it can't starve the 4-block pool (`:533-542`).
26. `phys = pool_base + MetaSize·BlkCnt + blkidx·blk_pitch`
    (`blk_pitch = ALIGN4K(blk_size)`); on the vendor-encoder build
    `AX_POOL_Handle2PhysAddr` is preferred with this as a bounds-checked
    fallback; on the openvenc build the measured layout **is** the source of
    truth (`:543-569`).
27. Hand up `AX_IMG_INFO_T`: `AX_FORMAT_YUV422_INTERLEAVED_YUYV` (0x0D),
    `u32PicStride[0] = stride`, `u64PhyAddr[0] = phys`, `u32BlkId = handle`
    (`:571-584`).
28. **proton nr104** with the saved descriptor to return the block (`:587-597`).

**Phase 4 — teardown** (`kvm_cap_stop` `:485-501`, `kvm_sys_deinit` `:328-341`):
nr20 DisableDev → nr41 + nr39 StopPipe → nr55 DisableChn → nr36 DestroyPipe →
nr18 DestroyDev → mipi nr7 Stop → mipi nr1 DeInit → pool nr21 Exit → munmap →
close all fds. Device-validated over three warm suspend/resume cycles
(`kvm_capture_open.c:52-57`; `docs/blob-replacement.md:1811-1817`).

### The "one thing that mattered" notes

- **The four ISP-bypass config selectors are load-bearing.** A first run that
  skipped nr56/74/54/89 returned rc=0 on every ioctl and then **hard-hung the
  SoC** when the channel/DMA engaged → watchdog reboot (~60 s). Adding them
  makes StartPipe/EnableChn/GetYuvFrame run clean and a frame appear on attempt
  0 — `docs/blob-replacement.md:1664-1669`; code comment `kvm_capture_open.c:445-446`.
- **The MIPI attr must be real.** A **zeroed** PHY attr into `mipi nr6 Start`
  (0 lanes → PHY never locks) spun the `.ko` and tripped the watchdog →
  board reboot. The faithful 4-lane struct is the entire difference —
  `docs/blob-replacement.md:700-706`, `:1505-1511`, `:1546-1551`.
- **Reproduce the FULL pointed-to struct, not the 8-byte prefix.** Every
  earlier stage's "wall" (cmm nr10 "kernel-global context", cmm nr17 "MMSO
  control block") was this one marshaling artifact —
  `docs/blob-replacement.md:1286-1297`, `:1350-1366`, `:1452-1462`.
- **Do not issue nr138** (§4).
- **Pool block phys = meta pages + page-aligned pitch**, not `idx·BlkSize` —
  `docs/blob-replacement.md:1831-1847`.
- **Geometry never crosses the config-selector wire** as a runtime value; it is
  cached in the kernel from the allocation, and the config doorbells are
  invariant across resolution — `docs/blob-replacement.md:1238-1245`.
- Envelope now 64×64 … **3840×2160**, hardware-proven at 4K30 with the
  identical MIPI/nr45/nr54/flag bytes — `docs/blob-replacement.md:3167-3216`;
  `kvm_capture_geom.h:40-50`.
  *(Nit found while reading: `kvm_geom_check()`'s rejection string still says
  "max 1920x1200 … the fixed 4x600 Mbps DPHY link cannot carry more" —
  `kvm_capture_geom.c:188-197` — stale prose against the 3840×2160 macros in the
  header. Cosmetic, message-only, but it contradicts the superseded reasoning
  the header explicitly retracts.)*

---

## 3. Hardware-register knowledge already banked

| Block | Base | What is known | Citation |
|---|---|---|---|
| **ISP / VIN** | `0x2400000` | Readable read-only via `/dev/mem`, **no bus fault**; ~140 live registers across a whole bring-up; per-lifecycle diff enumerated (below) | `docs/blob-replacement.md:598-622` |
| **MIPI-RX** | `0x2600000` | Same window readable; `ax_mipi_rx_reg_init` ioremaps this base | `:1496`, `:598-613` |
| clk/reset | `0x2340000` len 768 | `common_clk`/`comm_sys_reset@2340000` in the DTB; userspace's entire footprint is **2 reads of one 64-bit word at `0x2340220` (value 0x4), zero writes** | `:428-431`, `:570-596` |
| PLL | `0x2250000` len 8 (`pllc_clk@2210000` region) | mapped by userspace but **never accessed** in the bypass path | `:429`, `:586-588` |
| efuse | `COMM_SYS_BOND_OPT @0x02340098` bit 26 | `SECURE_BOOT_EN` reads 0 on the units checked | `docs/architecture.md:62-65` |
| pinmux | `0x02300060` | `VI_D7` pad mux; function 6 = `GPIO0_A7`, correct word `0x00060003`; **capture init re-muxes it** | `docs/mini-display.md:105-124` |
| CMM carveout | `0x73800000–0x7FFFFFFF` (200 MB) | outside kernel-managed DRAM; bottom-up first-fit; partition-name table at `0x71022000` | `docs/vcmd-cma-unblock.md:56-63`; `docs/blob-replacement.md:1310-1313` |
| venc / jenc / vdec | `0x4010000` / `0x4000000` / `0x4020000` | kernel-claimed in `/proc/iomem`; VCMD engine `hw_version_id=0x43421500`; reads `0xdeadbeef` when clock-gated | `:437-442`, `:2022-2036`, `:2038-2045` |

**Per-lifecycle ISP/MIPI register diff** (Exp 3, `docs/blob-replacement.md:605-613`):

| transition | ISP regs changed | note |
|---|---|---|
| start → CreateDev | ~83 ISP (+ ~2048 MIPI un-gating from `0xDEADBEEF`) | bulk ISP core config, block `0x2406xxx`; MIPI clocks enabled here |
| CreateDev → CreatePipe | 20 ISP + 3 MIPI | pipe geometry — `0x2406518 = 0x04380780` (1080h × 1920w) |
| CreatePipe → StartPipe | 3 ISP + 4 MIPI | link enable; MIPI status regs (`…104`) toggle |
| StartPipe → StreamOn | ~38 ISP + 3 MIPI | VIN/DMA path in `0x2400xxx` (per-channel mirrored triplets) |
| StreamOn → capture | 7 | free-running counters (`0x24001bc`, `0x240650c`, `0x240105c`) |

**Per-selector register attribution** (Task B, `docs/blob-replacement.md:730-748`):

| selector | registers programmed |
|---|---|
| `AX_VIN_Init` (proton 0) | block power-on: whole ISP+MIPI window `0xDEADBEEF`→live (in-kernel clock un-gate, not discrete writes) |
| `CreateDev` (proton 17) | 82 ISP regs — bulk core config, geometry band `0x2406xxx`; `0x2406518=0x01000100` default, `0x2406520/28/2c` |
| `SetDevAttr` (proton 21) | 20 ISP regs — **writes frame geometry** `0x2406518: 0x01000100 → 0x04380780`, plus `0x2406504=1`, `0x240650c` |
| `SetDevBindPipe/Mipi` (30/22) | `0x2406448`, `0x240650c` + MIPI link regs |
| `MIPI_RX_Reset` (mipi 4) | 8 MIPI PHY regs (`0x260x048/100` lane band) |
| `MIPI_RX_Start` (mipi 6) | 28 MIPI regs — PHY/link enable, `0x2600000–0x2601118` |
| `EnableDev` (proton 19) | 29 ISP regs in the `0x2400xxx` VIN/DMA datapath band |
| runtime loop (69/70/109) | `0x2400xxx` DMA/status + counters `0x24001bc`, `0x240105c` |
| `GetYuvFrame` (101) | `0x2400160/168`, `0x24001bc` (frame-done handshake) |
| `MIPI_RX_Stop` (mipi 7) | 2048 MIPI regs (block re-gate live→`0xDEADBEEF`) |
| noise | counter `0x0240643c` ticks on ~half of all ioctls, excluded |

Directly legible registers already: frame geometry `0x2406518`; the MIPI
PHY/link config+status band `0x2600048/60/104`, `0x2601048/104`; several
frame/line counters (`docs/blob-replacement.md:614-622`).

**What the register work does NOT give:** intra-transition **write order**,
read-modify-write logic, polling, and which of the CreateDev block are control
regs vs coefficient/LUT tables — `docs/blob-replacement.md:618-622`, `:635-645`.

Tooling that produced all of this still exists off-device in
`~/nanokvm-backups/atx-221/traces/` (`axtrace`, `ax_marker`, `ax_clocktrap`,
`ax_ispdiff`, `axdeep`, `poolcap`, `mv5cap`, plus `mipi_full_disasm.txt` /
`proton_handlers_disasm.txt` / `ax_cmm_nr17_disasm.txt`) —
`docs/blob-replacement.md:482-485`, `:647-651`, `:793-796`, `:1265-1270`,
`:1464-1469`, `:1596-1601`, `:1721-1727`.

---

## 4. **The ISP-processing question — does the KVM path run real ISP work?**

### Verdict

**No. The KVM capture path is an ISP-*bypass* / raw-DMA path.** The ISP block is
used as a MIPI-RX→DDR writer with geometry, not as an image processor. There is
no demosaic, no 3A, no AI-ISP, no scaling, no CSC and no format conversion on
this data path. The evidence is convergent and includes a pixel-level A/B against
the vendor pipeline.

### The affirmative evidence

1. **Mode is literally ISP bypass.** `KVM_PIPE_MODE 12 = AX_VIN_PIPE_ISP_BYPASS_MODE`
   (`pkgs/kvm-encoder/src/kvm_pipeline.h:29`), documented as
   `VIN pipe (ISP_BYPASS_MODE — dummy sensor via libsns_dummy.so)`
   (`docs/architecture.md:147`; `kvm_pipeline.h:8-13`). Stage 1 traced the whole
   ABI *in ISP-bypass, 1080p* — `docs/blob-replacement.md:508`.
2. **No 3A, no demosaic, no ISP blobs are needed.** "run VIN in **ISP-bypass
   mode** (YUV pass-through from the LT6911UXC — no 3A, no demosaic). Most of
   proton is dead code for a KVM" — `docs/blob-replacement.md:121-123`; also
   `docs/architecture.md:152-155`.
3. **No tuning data, no ISP `.bin`, no AI-ISP model is ever loaded.**
   "NO closed datapath blobs: no ISP tuning .bin (kvm_vin never loads one), no
   AI-ISP .axmodel (raw path only, no NPU symbols)" —
   `docs/plan-sg2002-research.md:169-171`; and "dlopen(libsns_dummy.so); no 3A
   libs, no tuning bin — matches kvm_vin's imports exactly" (`:215`).
   `libsns_dummy` is an **AE stub / ISP-framework placeholder** that carries no
   MIPI or format information (`:162-165`); we build it from SDK source at 73 KB
   vs the vendor's 1.3 MB, "the difference is AI-ISP glue and debug baggage
   irrelevant to bypass mode" (`docs/blob-replacement.md:189-194`).
   The 173 MB of `/opt/etc` Axera sensor tuning `.ini` is flagged as "probably
   dead weight" — `docs/nixos-rootfs.md:603-606`.
4. **The AI-ISP entry point is now provably unnecessary.** `#50`: `proton nr138`
   (`0xc008708a`) is `vin_model_manager_init`, reachable only from
   `isp_vin_ai_isp_ioctl` (the AI-ISP/AINR handler). It was a vestigial
   carry-over in our replay; **removing it entirely leaves capture working** and
   fixes the oops — `docs/blob-replacement.md:3002-3063`; code
   `kvm_capture_open.c:403-419`. That is a direct experiment showing the AINR
   model does nothing for this data path.
5. **The pixels are untouched, proven by A/B.** The Stage-6 blob-free frame and
   the *untouched vendor pipeline's* frame on the second unit (same HDMI via a
   splitter) have **identical Y statistics** (min/max/mean 28/83/51.7, row
   correlation 0.982 vs 0.984) and are the same desktop image —
   `docs/blob-replacement.md:1682-1700`.
6. **No CSC and no conversion anywhere on the path.** Input is CSI-2
   `AX_MIPI_CSI_DT_YUV422_8BIT` (DT 0x1E) (`kvm_pipeline.c:151`); output is
   packed **YUYV 4:2:2, 2 B/px** (`kvm_capture_geom.h:36-38`), which is exactly
   the encoder's input format — "open capture reads **YUYV** out of the CMM pool
   (Stage 6), so the encoder consumes capture output directly — **no format
   conversion sits between them**" (`docs/blob-replacement.md:2802-2807`), and
   the openvenc backend points `swreg12` **straight at the capture-pool frame,
   zero-copy** (`:2893-2900`).
7. **No scaling.** Every geometry-bearing field is set to the *source* width and
   height, stride == width (`kvm_capture_geom.c:203-241`;
   `kvm_capture_geom.h:54-61`), and 4K30 passes through at 3840×2160
   (`docs/blob-replacement.md:3186-3196`).
8. **The HDR investigation independently confirms zero color processing.**
   "No tone-mapping exists on the path — the only CSC prims (IVPS
   `AX_IVPS_CscTdp`, VO `AX_VO_SetCSC`, ISP `CscParam`) are LINEAR 3x3 …
   The bypassed ISP is a Bayer-RAW/sensor-WDR pipeline, doesn't help HDMI PQ."
   — `docs/plan-sg2002-research.md:258-268`.
9. **The pipeline lies to itself about format, and the ISP ignores it.** The
   vendor-MPI backend declares the dev as `MIPI_RAW` / `BAYER_RAW_16BPP` / BGGR
   and the chn as `YUV420_SEMIPLANAR` (`kvm_pipeline.c:142-145`, `:202`), yet
   frames come out as YUYV fmt 0x0D (`kvm_pipeline.h:12`). RAW16 is just the
   plumbing trick that makes the bypass work: "ISP_BYPASS_MODE (12) but only
   WITH the RAW16 dev; NORMAL_MODE1 and SUB_YUV_MODE both delivered 0 frames"
   — `docs/plan-sg2002-research.md:210-215`. i.e. the block is deliberately told
   "these are opaque 16-bit samples, just DMA them".
10. **No DRAM raw buffering.** "the VIN dev runs ONLINE (`AX_VIN_DEV_ONLINE`)
    into an ISP-bypass pipe, so raw frames stream on-chip and are never buffered
    in DRAM. Only the VIN output channel draws from the common pool"
    — `kvm_pipeline.c:39-53`; the RAW16 pool was dropped entirely
    (`docs/plan-sg2002-research.md:236-244`).

### The counter-evidence / caveats (do not overclaim "no ISP")

- **"Bypass" is a pixel-processing statement, not a hardware-idleness statement.**
  The ISP register block is heavily programmed: ~83 registers at CreateDev, 20 at
  SetDevAttr, 29 in the `0x2400xxx` VIN/DMA band at EnableDev
  (`docs/blob-replacement.md:605-613`, `:730-748`). A from-scratch driver must
  reproduce the ISP block's **front-end/DMA** programming even though no
  algorithm runs.
- **Four "ISP-bypass config" selectors are mandatory and undecoded**:
  `nr56 black_level_set` (10 B), `nr74 scene_attr_set` (24 B),
  `nr54 partition_info_set` (180 B), `nr89 npu_throttle_info_set` (424 B).
  Skipping them = SoC hard hang at DMA engage
  (`docs/blob-replacement.md:1664-1669`). Their names imply ISP-ish semantics
  (black level, scene, line partitions, NPU throttling), their contents are
  replayed vendor bytes, and **Task B's per-selector register table does not
  cover them** — their register footprint has never been measured
  (`:730-748` has no row for 56/74/54/89). `nr54`'s first word is
  `00 06 01 00` with 176 zero bytes; whether any of it is an ISP line-partition
  width was listed as undecoded (`:1948-1950`) — but it was later **replayed
  verbatim at 4K and capture was clean**, so it is not resolution-dependent
  (`:3198-3203`).
- **`ax_proton mem_iq_level=1`** is a mandatory module parameter
  (`pkgs/rootfs/ax-load-drv.sh:124`; asserted by the build,
  `docs/blob-replacement.md:238`, `:265-271`) whose meaning is **nowhere
  decoded** in the docs. "IQ" = image quality; plausibly an IQ-memory
  provisioning level, and level 1 is presumably the minimum. Unverified.
- **`ax_npu` is a hard dependency of `ax_proton`** even with no network loaded
  (`docs/blob-replacement.md:128-130`, `:230`) — the AI-ISP scaffolding is
  compiled in even when unused.
- HDR: a genuinely open question whether the AX630C VIN/ISP could capture HDR
  correctly *at all* in bypass — `docs/plan-sg2002-research.md:270-277`.

### What this means for #55

A from-scratch `ax_proton` replacement for the KVM use case does **not** need to
reimplement an ISP: it needs a **CSI-2 → VIN → DDR writer** (geometry, buffer
addressing, frame-done) plus whatever the four bypass-config writes actually
program. That is a materially smaller target than "reverse an ISP", and it is
the single most important scoping fact in this document.

---

## 5. What `ax_ivps` / `ax_vpp` / `ax_gdc` are actually for here

**Our path calls none of them — VIN hands frames straight to the encoder by
physical address.**

- Zero `AX_IVPS_*` calls in our code, on either backend
  (`docs/blob-replacement.md:183-188`). The vendor-MPI capture backend goes
  `VIN chn → AX_VENC_SendFrame` with no intermediate stage
  (`kvm_pipeline.c:199-217`, `:238-246`; `kvm_pipeline.h:8-13`).
- The open backend hands the encoder a raw CMM physical address:
  `u64PhyAddr[0] = phys` in `AX_IMG_INFO_T` (`kvm_capture_open.c:571-584`), and
  the open encoder points `swreg12` (input luma) directly at it
  (`docs/blob-replacement.md:2893-2900`). Independently confirmed from the
  vendor cmdbuf: "cmdbuf `swreg11` (input-luma base) = `0x73c45000`, the exact
  capture-pool frame phys — independent proof … that capture feeds the encoder
  by raw physical address" (`:2013-2016`).
- The **open capture path issues no ioctl to any of the three** — the only
  device nodes opened are os_mem/sys/cmm/pool/mipi_rx/proton/mem
  (`kvm_capture_open.c:276-282`).
- Why they are loaded at all, per the curated-loader table
  (`docs/blob-replacement.md:231-233`): `ax_ivps` "in the closure; also the
  module behind the `AX_IVPS_*` symbols `libax_venc.so` leaves undeclared";
  `ax_vpp` "in the closure (video-processing path under ivps/proton)";
  `ax_gdc` "in the closure (geometric-distortion block under the same chain)".
  I.e. they are in the **module symbol-dependency closure of `ax_proton`**
  (`:209`, `pkgs/rootfs/ax-load-drv.sh:1-12`), not in the data path.
- The `libax_venc` link-line reason is now **obsolete**: the shipped libkvm is
  the openvenc build and `DT_NEEDED`s zero `libax_*`
  (`docs/architecture.md:158-168`; `docs/provenance.md:52`). So the only
  surviving reason to load ivps/vpp/gdc is the kernel symbol closure.
- Contrast with the *vendor* stack (`kvmcomm`/`kvm_vin`), which genuinely did
  use IVPS: 11 `AX_IVPS_*` calls, "Frames flow IVPS→VENC via in-kernel
  `AX_SYS_Link` + CMM physical-memory pools" —
  `docs/plan-sg2002-research.md:127-131`. That is not our architecture
  (`docs/architecture.md:229-251`).

**Gap worth flagging:** only `ax_tdp` was ever *measured* at refcount 0 during
active streaming (`docs/blob-replacement.md:218-222`, `:240`). Nobody has
measured whether `ax_ivps`/`ax_vpp`/`ax_gdc` are refcount-0 during capture, or
whether `ax_proton` genuinely imports symbols from them (vs. the reverse). If
the dependency is one-way (they import from proton/base), three of the ten
modules could potentially be dropped from the loader today with no code written
at all — a cheap, high-value experiment for #55.

---

## 6. Known unknowns — the gaps the docs explicitly flag as never crossed

Kernel-side (these are the actual #55 work items):

1. **In-kernel register write ORDER, RMW logic and polling** for `0x2400000`
   and `0x2600000`. Exp 3 / Task B give before/after *values* per selector, not
   sequence — `docs/blob-replacement.md:618-622`, `:635-645`, `:760-766`.
2. **Clock / reset / PLL sequencing is 100% in-kernel.** Exp 2 proved userspace
   does *zero writes* to `0x2340000` and never touches the PLL page even on a
   cold boot; all clock-enable/reset-deassert/PLL programming is done by
   `ax_proton.ko`/`ax_mipi_rx.ko` triggered by bring-up ioctls (the MIPI
   sub-blocks visibly un-gate during `AX_VIN_CreateDev`) —
   `docs/blob-replacement.md:570-596`, `:630-632`, `:637-639`.
   *(For contrast: the venc block's clk/reset was open in-tree DT and needed no
   RE — `:921-948`, and the working glue just does `clk_venc_eb` +
   `of_irq_get` — `docs/vcmd-cma-unblock.md:76-89`. Whether the ISP/MIPI clocks
   also have in-tree `clk-ax620e.c` gates has NOT been checked in any doc I
   read. That is a cheap host-side lookup and a likely early win.)*
3. **Interrupt handling is entirely dark for capture.** Nothing in the docs
   describes the ISP/MIPI IRQ lines, handlers, or frame-done interrupt
   semantics. Userspace never sees an IRQ: the vendor waits via `hrtimer nr1`
   (`:415`, `:565`) and we poll `nr101` every 5 ms
   (`kvm_capture_open.c:515-526`). The only IRQ knowledge banked anywhere is
   for venc (GIC_SPI 93 → GIC hwirq 125, wired with `of_irq_get`) —
   `docs/vcmd-cma-unblock.md:86-89`; `docs/blob-replacement.md:2973-2975`.
   `ax_isp_ioctl` does route an `isp_vin_irq_ioctl` range (`:1631-1632`), never
   explored.
4. **DMA descriptor / buffer-address programming is unobserved.** We only ever
   see an opaque pool-block handle `0x5e0000NN` at descriptor offset 0x28
   (`docs/blob-replacement.md:1671-1680`); how the driver turns that into
   ISP-register buffer pointers was never traced. The `0x2400xxx` band is known
   to hold "per-channel mirrored triplets" (`:610`) and the frame-done handshake
   regs `0x2400160/168/1bc` (`:740`), but no field decode exists.
5. **Which CreateDev registers are control vs coefficient/LUT tables** — `:620-622`.
6. **The four ISP-bypass config selectors** (nr56/74/54/89): payloads replayed,
   semantics and register effects undecoded (§4).
7. **The opaque bulk of every replayed struct.** Only w/h/stride are decoded in
   the 376 B dev attr, 76 B pipe attr, 48 B chn attr; the 424 B nr89, 180 B
   nr54, 248 B nr101 descriptor (beyond `+0x28`), 56 B nr30, 16 B nr12
   (beyond the phys), and the scalars `proton nr0 {3,3}` / `nr2 {4,1}` are
   undecoded — see the payload arrays `kvm_capture_open.c:117-130` and
   `kvm_capture_geom.c:66-163`.
8. **os_mem nr1 flag byte `0xf0`** — varies with codec/config, never decoded
   (`docs/blob-replacement.md:1236`, `:1942-1946`; `kvm_capture_open.c:136-142`).
9. **`mem_iq_level=1`** semantics (§4).
10. **The inter-module symbol ABI** (`AX_OSAL_*` and the cmm/pool exports) that
    every blob imports — replacing `ax_cmm` means re-implementing that contract,
    not just one driver (`docs/blob-replacement.md:2682-2687`, `:2697-2699`).
    Partially absorbed already: our glue satisfies venc-side contracts, and the
    standing note says each absorbed contract is a piece of the ABI map
    (`:2711-2716`).
11. **No open driver lineage and no register spec exist for this ISP/CSI IP** —
    the structural reason this is "the wall" (`:2689-2695`, `:158-169`).
12. **ABI fragility constrains incremental replacement.** Any kernel config
    change must be audited for `#ifdef` fields in structs the remaining blobs
    touch — `CONFIG_CMA`/`CONFIG_DMA_CMA` killed boot despite identical vermagic
    (`docs/vcmd-cma-unblock.md:22-47`). And a replacement module cannot coexist
    with the blob it replaces: `request_mem_region` + shared IRQ line
    (`docs/blob-replacement.md:2971-2975`).
13. **Latent blob bugs bite during transitions.** #50 showed `ax_proton`'s
    exception-exit path wild-writes through a `kmalloc`(not `kzalloc`) slot array
    (`:3010-3021`), and that an oopsed task wedges any later `systemctl stop`
    until reboot (`:2944-2947`).

Userspace-side residuals (all closed, listed for completeness): none — every
capture-side `.so` (`libax_sys`, `libax_mipi`, `libax_proton`) is demonstrably
replaced (`docs/blob-replacement.md:1702-1714`).

---

## 7. Verdict per module — already banked vs still dark

| Module | Already banked | Still dark | Call |
|---|---|---|---|
| **`ax_sys`** (+`os_mem`) | 2 selectors fully driven blob-free (os_mem nr1 descriptor decoded to `{w,h}`+flag; sys nr45 scalar); MMSO red herring disproven; hrtimer/sysmap/log unused by us | its exported symbol ABI to every other blob; the rest of its 1-selector-per-node surface; what the returned management page is *for* | **Thin.** Follows `ax_cmm`; the ioctl surface we need is 2 calls. |
| **`ax_cmm`** | 4 nrs driven blob-free with full structs; nr17 handler disassembled to field-range level; allocator layout (bottom-up first-fit, carveout bounds, partition table phys) known; a from-source contiguous allocator already exists for encode | full ioctl set (10 selectors), the pointer-branch of nr10, cache-op selectors, the `AX_OSAL_*` exports every other blob links | **Linchpin, tractable.** Best first target after venc; unblocks the "infrastructure" trio. |
| **`ax_pool`** | 3 of 6 selectors driven; floorplan struct field-decoded; block layout (meta pages + page-aligned pitch) device-verified | the other 3 selectors; block get/put path; the handle encoding beyond `&0xff` | **Thin, follows `ax_cmm`.** |
| **`ax_base`** | nothing beyond "it owns the char-dev fops/OSAL seam" (`osal_release` in the #50 trace) | essentially everything | **Dark but small.** Glue; do it with `ax_cmm`. |
| **`ax_npu`** | that it is a hard dep of `ax_proton` and does nothing for us; the one AI-ISP entry point (nr138) is provably skippable | whether a stub satisfying proton's symbol imports would suffice | **Dark, but likely stubbable.** Cheap experiment: does proton load against a symbol-stub NPU module? |
| **`ax_ivps`** | zero ioctls from any of our code; loaded for symbol closure only; the vendor's own KVM stack used it, ours never has | its symbol relationship to proton; whether it can simply be dropped | **Dark but probably droppable.** Measure refcount first. |
| **`ax_vpp`** | same as ivps — "in the closure", never called | same | **Same.** |
| **`ax_gdc`** | same — "in the closure", never called | same | **Same.** |
| **`ax_mipi_rx`** | **the best-mapped module.** All 7 selectors mapped to handlers with cfu sizes and struct layouts; the 28-byte PHY attr byte-decoded; PHY bring-up (attr→reset→start) driven blob-free with no fault; register band `0x2600000–0x2601118`, ~28 regs at Start, 8 at Reset; clock un-gate point identified | write order/RMW/polling inside those ~28+8 register writes; the clock/reset sequence; IRQ; lane-combo semantics beyond "0" | **Closest to writable.** 106 KB, no algorithms, unstripped, and the userspace contract is a 7-entry table. Realistic first ISP-stack target. |
| **`ax_proton`** | 26 selectors exercised by our shipped code with exact cfu sizes; two-level dispatch + the 63-entry pipe jump table decoded; ~140 live ISP registers with per-selector attribution and per-lifecycle diffs; geometry pinned to `0x2406518`; the **whole bring-up order** proven to a frame at 1080p and 4K; two functions (`vin_model_manager_{init,deinit}`) disassembled | register write order/RMW/polling across ~140 regs; clock/reset/PLL; IRQ; DMA buffer programming; the 4 bypass-config selectors; the opaque ~90% of every attr struct; 10+ vendor selectors we never issue | **The wall — but a narrower wall than "an ISP".** §4 says the KVM path needs a CSI→DDR writer, not an image processor. 4.5 MB blob, but our slice of it is small and fully enumerated on the userspace side. |

**Overall:** the *contract* (what userspace asks the kernel to do) is ~100%
mapped for capture and is in-tree as executable, device-proven code. The
*implementation* (what the kernel does to the silicon) is ~30% mapped for
`ax_mipi_rx`, ~15% for `ax_proton` (end-state register values only, no
sequencing/IRQ/DMA), ~40% for `ax_cmm` (behaviour + one disassembled handler,
plus a working open allocator to crib from), and ~0% for
`ax_base`/`ax_npu`/`ax_ivps`/`ax_vpp`/`ax_gdc`.

Sequencing suggestion implied by the above (not a decision):
(a) prove `ax_ivps`/`ax_vpp`/`ax_gdc` are droppable → 10 modules becomes 7 for
free; (b) check whether ISP/MIPI clocks/resets have in-tree `clk-ax620e.c` /
`axera_reset.c` providers like venc did — that would delete unknown #2, the
single largest black box; (c) `ax_mipi_rx` from source (7 selectors, 106 KB,
bounded register band); (d) `ax_cmm` + the infrastructure trio; (e) `ax_proton`
last, scoped as a VIN/DMA writer rather than an ISP.
