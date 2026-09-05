# Vendor MIPI CSI-2 receiver under its public API — register campaign (2026-09-04)

Our own `/dev/mem` observations (read-only mmap, word loops) of the AX630C CSI-2
receiver (`0x02600000`), D-PHY (`0x023f0000`), isp_sys_glb (`0x02500000`) and
common_glb (`0x02340000`) while the VENDOR `ax_mipi_rx` driver was driven through
its published SDK API (`tools/mipiprobe.c`, built on the device against the SDK
headers; `tools/sweep.sh` runs it). No vendor binary was read; no MMIO writes.
The device ran the full vendor stack for this session (open state backed up to
`/root/open-state-20260904`, restored afterwards).

Resolves `specs/spec-mipi-rx.md` §9 items 4 (DataRate: no register depends on it),
6 (`+0x100`: 1 running / 2 stopped, retained across clock gating, no srst) and 8
(`0x02303000` is a constant, readable block); item 5 (lane table) is only partly
recoverable within one boot — see the spec.

- `REPORT.md` — the campaign report; `TABLES.md` — generated per-word diff tables
  (`analyze.py`, `w2.py`).
- `device/` — a bounded subset of the raw dumps: `L4R600`/`L4R600b`/`L4R2500`/`L4R80`
  (4-lane, DataRate 600/600/2500/80; stages pre/attr/start/start2/stop, four banks
  each), `L1R600`/`L2R600`/`L3R600` CSI bank at start (the `+0x40` lane word),
  `P_L4-*` (the ~10 µs poll of 12 words across Start..Stop), `M8-*` (`0x02303000`),
  and every run's `<tag>.txt` summary. The full 571-file set lives only in the
  session scratchpad.
- `poll-runs.log`, `sweep.out`, `m8-streaming.log` — run logs.
