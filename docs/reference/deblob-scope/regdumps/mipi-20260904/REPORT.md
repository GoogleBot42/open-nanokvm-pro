# Vendor MIPI RX register campaign — 2026-09-04 (spec-mipi-rx.md §9 items 4, 5, 6, 8 + M1)

Method: `tools/mipiprobe.c` (this dir), built ON DEVICE against the published SDK headers
(`/tmp/axwork/axera-libs/include/ax_mipi_rx_api.h`, `ax_sys_api.h`), linked to `/opt/lib/libax_mipi.so`
+ `libax_sys.so`. Sequence per run (fresh process): `AX_SYS_Init → AX_MIPI_RX_Init → AX_MIPI_RX_SetLaneCombo(combo)
→ AX_MIPI_RX_SetAttr(0, {MIPI, DPHY, eLaneNum, nDataRate, DataLaneMap [0,1,3,4], ClkLane [2,5]}) → [AX_MIPI_RX_Reset(0)]
→ AX_MIPI_RX_Start(0) → (300 ms) → AX_MIPI_RX_Stop(0) → DeInit`. At stages pre/attr/[rst]/start/start2/stop it snapshots
`0x02600000` (0x4000), `0x023f0000` (0x1000), `0x02500000` (0x800), `0x02340000` (0x1000) via read-only `/dev/mem`
mmap word loops, and logs key words + `/proc/lt6911_info` + deskew bits. `poll=1` adds a tight-loop thread recording
every transition of 12 watched words across Start..Stop. `nanokvm.service` was stopped for all MPI runs, restarted and
verified (active, web 200, `video_state=active`) before M8's streaming half and at the end. No MMIO writes, no
persistent-file changes; the only hardware configuration was through the vendor public API. No reboot occurred
(uptime continuous 39 → 52 min).

Artifacts: on device `/tmp/axwork/mipi/` (raw `.bin` per run/stage/bank, `<tag>.txt` logs, `<tag>-poll.txt`,
`sweep.out`, sources); retrieved verbatim to `device/` here. `TABLES.md` = generated per-word diff tables
(`analyze.py`, run with `nix shell nixpkgs#python3`). Reference vendor dumps: `docs/reference/deblob-scope/regdumps/frontend/`.

## Sanity: API-driven state == real KVM path
`L4R600-start-*` vs `regdumps/frontend/vendor-streaming-*` (TABLES.md "API-driven state vs ..."): CSI-2 bank differs in 5
status words only (+0x20/+0x1020 = 0xe vs 0x26, +0x104 monitor word, +0x2020/+0x3020 0xc vs 0x4); all config words
(+0x2c=0x11ee1, +0x38, +0x40=0x1f, +0x50=0x111100, +0x100=1, +0x110=0x10, +0x118=0xd1f) identical. D-PHY differs in
+0x48/+0x848 (live lane-status toggler 0x13f3f/0x1bfbf) and +0x44/+0x844: **0 in the full vendor stream, 0x3c00 in every
API-only run** — that is the mirror of SET +0xe8 (deskew debug-ctrl reset, the word the open driver releases in its
step 6); `AX_MIPI_RX_Start` alone leaves it asserted, the VIN/proton stage releases it. isp_sys_glb differs only in ISP
gate words (+0x4/+0x8/+0xa8: no ISP pipeline behind an API-only MIPI start) and counters.

## M4 — DataRate (item 4): NO register depends on nDataRate  → CONFIRMED
Runs `L4R{80,200,400,600,800,1000,1200,1500,2500}` + repeat `L4R600b` (4 lanes, MODE_0; `nDataRate` is a bare `AX_U32`
in the header, no enum; SetAttr returned 0 for every value, Start returned 0 and streamed (+0x100=1) for every value).
Per-word diff at stage `start` (TABLES.md "M4 ..."):
- `0x023f0000` D-PHY: 2/1024 words vary (+0x48, +0x848) and both also change between two dumps of the SAME run → live.
  **No D-PHY configuration word changes with DataRate** (timing words +0x34..+0x44 mirrors constant: 0x0005c540 / 0x820 /
  0x08080808 / 0x3c00 ...). Validates the open driver's fixed presets.
- `0x02600000` CSI: 8/4096 words vary; 4 are live within a run (+0x60, +0x104, +0x1048, +0x1060) and the other 4
  (+0x20, +0x74, +0x1020, +0x1074) differ between the two identical-config runs L4R600 vs L4R600b (0x26/0x66,
  0/0x8400011e) → run-to-run packet/monitor status, not DataRate. +0x40 = 0x1f, +0x100 = 1 in every run.
- `0x02500000`: only the free-running counters +0xb8/+0xc0. `0x02340000`: zero words differ.

## M5 — N_LANES (item 5): +0x40 = 0x1f for LaneNum 1,2,3,4 in MODE_0/1/2 → table NOT recoverable this way
Runs `L{1,2,3,4}R600`, `V_L2C1` (MODE_1), `V_L1C2` (MODE_2), `V_L4C1`, `V_L2rst` (Reset before Start), `P_L1ord`/`P_L2ord`
(SetAttr BEFORE SetLaneCombo): every one reads **+0x40 = 0x0000001f** after Start (TABLES.md "M5 LaneNum sweep" table).
Root cause is visible in the poll logs: the CSI register file is clock-gated, not reset, between Stop and Start — the
FIRST clocked sample after Start already shows +0x40=0x1f and +0x100=0x2 (the previous run's Stop) before any init write
(`P_L4-poll.txt` t=20035 µs, `P_L2ord-poll.txt` t=20424 µs). With the spec's RMW-OR write of `table[LaneNum-1]|0x10`,
a retained 0xf can never be lowered, so on a device whose boot path already started 4 lanes the 1/2/3-lane entries are
unobservable without a module reload (out of envelope: ax_proton holds ax_mipi_rx). `AX_MIPI_RX_GetAttr` returns all
zeros after a successful SetAttr (vendor lib quirk; noted, not pursued).
What DOES land: LaneCombo. D-PHY +0x34/+0x834 (lane-cfg mirror) bit25 (1d2c_en) = 1 for MODE_1 (0x0205c540) vs 0 for
MODE_0/2; D-PHY +0x58/+0x858 (PHY-enable mirror of +0x110) = **0x3f MODE_0 (any LaneNum), 0x3d MODE_1 4-lane, 0x31
MODE_1 2-lane and MODE_2 1-lane** — matching spec §4's 0x3f/0x3d/... selection by combo flag. CSI +0x48 (per-lane
status nibbles) = 0x222206 MODE_0, 0x3306 MODE_1-4L, 0x2206 MODE_1-2L. No other CSI config word changed with lanes or
combo (TABLES.md "M5 CSI-2 ... vs LaneCombo": all remaining diffs are live words or the isolated-deadbeef artifact below).

## M6 — stream-ctrl semantics (item 6)
From `P_L4-poll.txt`, `P_L4rst-poll.txt` (and P_L1ord/P_L2ord/P_L2C1), sample period ~10–20 µs:
- pre/attr/rst stages: whole CSI + D-PHY banks read 0xdeadbeef (unclocked); `AX_MIPI_RX_Reset` does NOT clock them.
- Start: t0+20 ms clocks come up; +0x100 reads **0x2 (retained stop)**, +0x40=0x1f, +0x2c=0x11ee1, +0x50=0x111100,
  +0x110=0x10, +0x118=0xd1f already present (retained). D-PHY +0x34 is then rewritten field-by-field
  (0x0205c540→0x02044540→0x0205c540→0x0205c400→0x0005c540: CLR/SET of the lane-swap fields, bit25 cleared for MODE_0).
  ~30 ms later **+0x100 → 0x1** and stays 1 while streaming. No intermediate value (0x10/0x12 srst pulse, 0x3, 0x0) was
  ever sampled in 5 runs — if the soft-reset toggle exists it is shorter than ~10 µs.
- Stop: D-PHY +0x110 → deadbeef, then +0x34 → deadbeef (D-PHY gated first), then **+0x100 → 0x2** written while
  +0x110/+0x118 already read deadbeef, then the whole CSI bank → deadbeef (~10 µs total).
  Encodings observed: **+0x100: 1 = running, 2 = stopped** (bit0 start / bit1 stop, mutually exclusive, retained across
  clock gating). +0x04 stayed 0 at every sample.
- Deskew: `0x02500000+0x00` = 0x5af (bits[1:0]=3) at EVERY stage including pre/stop with the CSI unclocked — with the
  vendor stack loaded this word is 0x5af whenever the service has ever run (vendor-service-stopped dump too); only the
  deep-idle boot dump reads 0x5ac. So bits[1:0]=3 here reflects the mux/clock select being live, not a per-Start lock.
- ErrorStatus0 +0x28 flickers 0x1020/0x1040/0x1060 (bits 5,6 = STREAM1/2 FIFO overflow, bit12) on API-only runs, W1C'd
  continuously by the vendor ISR; the real streaming dump has 0. Consistent with no VIN consumer draining the FIFOs when
  only the receiver is started. +0x4c stayed 0 (no per-lane errsot).

## M8 — 0x02303000 (item 8): readable, constant
`M8-idle-02303000.bin` (service stopped) and `M8-streaming-02303000.bin` (service running, MJPEG client attached, CSI
+0x40=0x1f/+0x100=1 in `M8-streaming-02600000-head.bin`): both **word0 = 0x00000210, the remaining 63 words 0**.
No bus hang, no reboot. The block is clocked on this boot and its content does not change between idle and streaming,
so nothing in the MIPI path depends on a live write to it (it is not a gate the open driver has to touch).

## M1 — link state
Every dump: `/proc/lt6911_info` = 3840x2160@29 (steady), deskew word 0x5af. Table in TABLES.md "M1 link state".

## Caveats
- Isolated single-word `0xdeadbeef` reads appear in some dumps/poll rows (never the same offset twice, back to the normal
  value on the next sample): a read artifact of hammering the APB while the block is live, not register state. Ignore
  in per-word diffs (they show as "live").
- Runs share one boot, so any register that is set-once-per-boot (N_LANES bits, D-PHY lane cfg) shows the retained value.
