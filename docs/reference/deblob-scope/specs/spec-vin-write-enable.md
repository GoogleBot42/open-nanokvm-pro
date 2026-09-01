<!--
Clean-room behavioral spec (epic #55, resolving the #59/M2 write-enable wall).
Produced by a DESCRIBING subagent from ax_proton.ko disassembly (no vendor code
reproduced) and cross-checked against our own /dev/mem golden dumps. Main-session
VERIFIED 2026-08-31: the two decisive device claims re-derived from the raw dumps
(docs/reference/deblob-scope/regdumps/) --
  MUX_RD  0x02500000+0x00: 0x5af vendor-live vs 0x5ac base-only (delta = bits[1:0])
  sys_glb 0x02500000+0x90: 0x230001 vendor-live vs 0x0 base-only
Disassembly function+offset citations are taken on the describing-subagent's
authority per the clean-room rule (drivers written from this spec, never from
vendor disasm). Folded into pkgs/open-vin-capture (ovc_clk_mux_apply); on-device
readback verification (MUX_RD -> 0x5af, then a 0x024140d4 write/read round-trip)
is the remaining device-loop step.
-->

# Behavioral spec — the "write-enable" wall: why SIF/IFE/WDMA config writes don't stick after clocks+reset

Resolves spec-vin-reset's REMAINING GAP ("clocked + reset-deasserted, config regs
still read 0 after a write"). Recovered from `ax_proton.ko` (ET_REL aarch64,
unstripped); no vendor code reproduced; claims cite `function+offset`.

## 0. TL;DR — there is NO write-protect register; "write-enable" = three missing conditions

An exhaustive pass over every RST-bank (`0x02500000`) write in the module found the
driver touches only `0xC8/0xCC` (clk-source mux), `0xD0/D4/D8/DC` (clk gates),
`0xE0/E4/E8/EC` (resets), and reads `0x00` (mux status). **No hidden
write-enable / write-protect / unlock register exists.** A block that is
un-DEADBEEFed (bus responds, reads 0) but silently drops config writes is
**clocked-on-bus but its register flops have no functional clock edge and/or are
still held in functional reset.** Ranked, device-grounded causes:

| # | Missing operation | Evidence | Confidence |
|---|---|---|---|
| 1 | **Clock-SOURCE MUX (`0x025000C8`/`CC`) never applied** — done ONLY at module probe (`ax_isp_clk_prepare`), not per-open. M1 sets only the *gates* (`0xD0`/`0xD8`). Unclocked flops ⇒ writes don't latch, reads return 0. | Static diff: `MUX_RD 0x02500000+0x00` = **0x5af vendor-live vs 0x5ac base-only** (bits [1:0] raised only by the vendor apply). | **High** |
| 2 | **Reset was a bare deassert, not an assert→deassert PULSE.** The vendor IFE reset is a mode-2 masked pulse; a lone `0xE4` write on a wedged base boot is a no-op strobe. | `ax_isp_reset_ife_legacy` @`0x84078` = `ax_isp_clk_rst0_set_all(mode=2, mask=0x5E000)`; `_set_all` @`0x96f8` mode-2 writes `mask→0xE0` then `mask→0xE4`. | **High** |
| 3 | **AXI-ctrl regs left non-zero** (`0x02400184`/`0x02480144`/`0x024C0148`). A manual quiesce that set them to `0xFFFFFFFF` and never released them freezes the datapath. | Live dump: `0x02400184 = 0` while streaming 4K. Reset tail zeroes all three (`ax_isp_reset_all_legacy` @`0x84000–0x84024`). | Medium (only if the experiment asserted them) |

These are **additive** — do all three. #1 is the primary, newly-identified cause and
is NOT performed by M1 or any per-open path.

## 1. The clock-source MUX is a PROBE-TIME-ONLY step (the primary gap)

`ax_isp_clk_prepare` @`0x82c20` is called **only** from `__ax_isp_probe` @`0x146608`
(call @`0x146890`) — once at module load, NOT in `VIN_glb_create`, NOT per-open. It:
- `ioremap(0x02500000, 0x100)` @`0x82c5c-60`, base at `drv[+0x50]`.
- Writes `0x00100000` (bit20) to `base+0xE8` @`0x82c70` then `base+0xEC` @`0x82c78` —
  a **rst1 bit20 assert→deassert pulse** (global/PLL-domain kick) preceding rate setup.
- Calls `__isp_clk_set_rate(base, rate_table)` @`0x82c7c`.

`__isp_clk_set_rate` @`0x82b28`, per ISP clock domain:
- `code = __isp_clk_domain_match_rate(domain, target_rate)` @`0x825c0` (rate→3-bit code).
- `writel(7<<shift, base+0xCC)` @`0x82b68` (clear 3-bit field), then
  `writel(code<<shift, base+0xC8)` @`0x82b6c` (set it). `shift` = **8, 5, 2** ⇒ three
  3-bit fields `[10:8]`,`[7:5]`,`[4:2]` for domains 0/1/2.

Target rates (from the immediates at `0x82c24-44`): domain0 = 416 MHz, domain1 =
533.33 MHz, domain2 = 297 MHz (a 4th ≈ 312 MHz follows).

**Main-session note (from the golden dumps):** on a base-only boot the three
source-select fields ALREADY read `3/5/5` (`MUX_RD` = `0x5ac`, i.e. `[4:2]=3`,
`[7:5]=5`, `[10:8]=5`) — identical to vendor-live. The only delta is `MUX_RD[1:0]`
(`0`→`3`). So the source codes are already correct; the missing action is the
**CLR-then-SET apply-strobe itself**, whose side effect is the hardware raising the
domains' clock-active status in `[1:0]`. This is why the driver re-applies the codes
it reads live from `MUX_RD` rather than decoding `__isp_clk_domain_match_rate` — no
rate-table decode needed, and it stays correct if a future boot's defaults differ.

**Driver action (once, at bring-up):**
1. `writel(0x00100000, 0x025000E8); writel(0x00100000, 0x025000EC);` (rst1 bit20 pulse)
2. for each domain (shift ∈ {8,5,2}): `code = (MUX_RD >> shift) & 7;
   writel(7<<shift, 0x025000CC); writel(code<<shift, 0x025000C8);`
3. **Verify `readl(0x02500000+0x00) == 0x5af`** — the authoritative success test.

## 2. Reset is an assert→deassert PULSE with a masked write

Resolves spec-vin-reset's internal contradiction (per-index vs masked): **masked is
correct and is the vendor's own method.**
- `ax_isp_clk_rst0_set_all` @`0x96f8`: `mode==2` → write `mask→0xE0` @`0x9720` then
  `mask→0xE4` @`0x9730`. Raw mask, no per-bit tables. mode1→0xE0 only; mode0→0xE4 only.
- `ax_isp_reset_ife_legacy` @`0x84078` = `_set_all(mode=2, mask=0x0005E000)`.
- The per-index `ax_isp_clk_rst0_set` @`0x91a0` reads `0xE4`, overwrites all 32 bits
  from identity bit-tables, writes back — so `set(idx,mode=0)` ≡ `writel(1<<idx,0xE4)`;
  looping per-index ≡ one masked write. **Equivalent.**

`0xE0/E4/E8/EC` read 0 even in the live vendor dump ⇒ write-1 self-clearing strobes.
A base-only boot leaves the block wedged; you must assert (`0xE0`) then deassert
(`0xE4`) to cycle it. Minimal IFE/WDMA: `writel(0x5E000,0x025000E0);
writel(0x5E000,0x025000E4);`. SIF has no standalone mask (spec-vin-reset §3); the
full rst0 pulse-all releases it but hangs the SoC on this config — hence M2 ships the
narrow IFE-only reset and depends on §1 for datapath writability.

**Reset-bit attribution (authoritative = code masks, NOT the name table).** The
vendor's `vin_reset_mapping_tbl` (`.data+0x46f0`) reset-bit *names* are unreliable for
bit positions — its linear id order would put `reset_ife`'s `0x5E000` on ITP, which is
absurd. Trust the code masks instead: IFE = `0x5E000`, ITP/YUV = `0x31F00000` (disjoint
from IFE); there is **no `isp_rst_sif` line at all**. The hang-suspect in the full rst0
sweep is the ISP AXI-master reset (`isp_rst_axim`) — which is exactly why the vendor
wraps its pulse in the §3 AXI quiesce/release. This is the bit to keep OUT of any
narrowed SIF-releasing mask if the mux (§1) proves insufficient on its own.

## 3. AXI quiesce must be RELEASED (ctrl → 0)

`ax_isp_axi_busy_check_legacy` @`0x83d28` (before the pulse): sets the three AXI-ctrl
regs to `0xFFFFFFFF` (idle request), polls status to 0 (`udelay(200)`, 51 tries).
`ax_isp_reset_all_legacy` tail @`0x84000–0x84024` writes 0 back (release). Regs
(spec-proton-bypass §4.2): IFE `0x02400184`/status `188`; ITP `0x02480144`/`148`;
YUV `0x024C0148`/`14C`. Device-confirmed `0x02400184 = 0` while streaming. **Any
bring-up that asserts the quiesce MUST zero it afterward** or the IFE datapath stays
frozen. If never touched, defaults are 0 (fine).

## 4. Create-time ordering (no extra gate)

`VIN_glb_create` @`0x84228`: map windows → 16× `ax_isp_clk_eb_set(bank 0..15)`
@`0x842f8-84308` (RMW `0xD0[5:0]`=`0x3F`, `0xD8[9:0]`=`0x3FE`) → `ax_isp_reset_all_legacy`
@`0x84314` → pipe-callback → `ax_regio_backup` @`0x8437c` (reads the whole reg file
immediately after reset ⇒ blocks expected live) → `ax_isp_int_reset` →
`ax_isp_sys_glb_init` @`0x12b80` (writes GLB `0x90=0x00230001`, `0x94=1` — deskew-lock
config/kick; static diff confirms `0x90`=`0x230001` vendor vs `0` base). No datapath
write-enable register appears here; the mux (§1) is the missing piece, and it lives
in probe.

## 5. Driver checklist ("do exactly this", in order) — RST bank `0x02500000`

Prereqs (M1): gates `0xD0=0x3F`, `0xD8=0x3FE`; CMU `0x02340024`.
1. **Clock-source mux (the fix):** rst1 bit20 pulse (`+0xE8`,`+0xEC`), then per domain
   re-strobe the live code through `+0xCC`(clear) then `+0xC8`(set), shifts {8,5,2}.
   **Verify `+0x00 == 0x5af`.**
2. **Reset pulse (masked):** IFE/WDMA — `0x5E000→+0xE0` then `+0xE4`.
3. **AXI release:** ensure `0x02400184/0x02480144/0x024C0148 == 0` (only run the
   quiesce+release dance if you asserted it).
4. **sys_glb:** `GLB 0x90=0x230001`, `0x94=1`.
5. **Verify:** `readl(0x02414000) != 0xDEADBEEF` and a `writel/readl` round-trip on a
   **non-shadowed** register now **sticks** — use SIF `0x02406408` (SIF_STOP) or another
   plain config reg, **NOT** `0x024140d4`: the WDMA base reg is shadow/double-buffered
   (`ife_wdma_shadow` @`0x4f18`), so a readback-0 there is a measurement artifact, not
   proof of a dropped write. (This corrects the earlier "0x024140d4 round-trip" test.)

**Single most-likely fix:** the clock-source mux (step 1) — device-proven absent on
base-only boots (`+0x00` = `0x5ac` vs `0x5af`) and the only bring-up op that runs
exclusively at proton probe and is not reproduced by M1 or any per-open path.

## 6. Confidence & what still needs the device

- Masked==per-index reset, mode-2 pulse, IFE mask `0x5E000`, AXI release, probe-only
  mux, no write-protect register: **high** (read from disasm; corroborated by dumps).
- Exact `0x025000C8` code word: not statically observable (write-only, reads 0 live) —
  hence the read-live-and-re-strobe approach, verified against the `+0x00`=`0x5af`
  golden.
- Whether the mux alone unblocks writes vs. mux+pulse+AXI together: needs the on-device
  experiment — apply step 1, retest a **non-shadowed** round-trip (SIF `0x02406408`, not
  the double-buffered `0x024140d4`); if still stuck, the reset pulse (already in the
  driver) and AXI release are the next additions. The `+0x00` readback (`0x5ac`→`0x5af`)
  is the cheap decisive check that step 1 landed.
- Ruled out: CDMA routing (the direct path `ax_regio_blk_io_write` @`0x3bff0` is a plain
  `writel` to the same physaddr our driver uses — hardware state, not access method, is
  the difference) and any lock/key/unlock register (none exists in the bring-up path).
