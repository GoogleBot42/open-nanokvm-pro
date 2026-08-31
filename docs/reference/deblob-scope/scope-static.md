# Static-analysis scoping: 10 Axera AX630C vendor kernel modules

Target: open-nanokvm-pro issue #55 — replacing the closed ISP/VIN capture stack.
Inputs: `scratchpad/axp/ko/{ax_sys,ax_base,ax_cmm,ax_pool,ax_npu,ax_ivps,ax_vpp,ax_gdc,ax_mipi_rx,ax_proton}.ko`
(ET_REL aarch64, vermagic `4.19.125 SMP preempt mod_unload aarch64`).
Tools: `llvm-readelf`, `llvm-objdump -dr`, `modinfo`, `strings`. Derived artifacts in `scratchpad/an/`.

Everything below is derived from the binaries unless explicitly marked **[speculative]**.

---

## 0. Headline findings

1. **The modules are not stripped.** Full `.symtab` with local `FUNC`/`OBJECT` symbols
   survives in every module (ax_proton alone: 8173 symtab entries, 3264 defined functions,
   3338 defined objects). Function names are descriptive and hierarchical. This is a
   near-complete map of the vendor source tree's function inventory.
2. **`ax_proton.ko` is 4.5 MB on disk but only 1.33 MB of code.** The bulk is relocations
   (`.rela.text` = 2,069,424 B), `.eh_frame` (200 KB), and symtab/strtab (327 KB).
   Do not scope effort off the file size.
3. **There is an 11th, invisible component: the Axera OSAL, and it is GPL source in-tree.**
   All ten modules import 188 distinct `AX_OSAL_*` / `ax_os_*` / `ax_printk` symbols that
   none of them export. `pkgs/kernel.nix` in this repo already documents why:
   `drivers/soc/axera/Makefile` pulls `osal/linux/kernel/` into the kernel build via
   `CONFIG_AXERA_OSAL=y`. So the entire OS-abstraction layer these blobs sit on is
   **already available as source** and does not need reverse-engineering. Only 41 genuine
   mainline kernel symbols are imported across all ten modules.
4. **The NPU dependency is confined to AI-noise-reduction.** ax_proton imports exactly 9
   `AX_NPU_Kernel_*` symbols, and every one of them is called from exactly one
   `vin_nnw_*` ("neural network wrapper") function. Nothing in the VIN/MIPI/DMA path
   touches the NPU. A capture-only replacement needs zero NPU code.
5. **The vendor already ships a minimal capture topology.** ax_proton contains
   `AX620E_TOP_NODE_MODE10` — string: *"TOP_NODE_MODE10: BYPASS PPL, only IFE WDMA working."* —
   plus `IFE_NODE_MODE3: Whole frame, IFE_IN_ONELINE(YUV)->IFE_OUT_OFFLINE(DUMP)` and
   `isp_sif_mipi_yuv_sns_setup`. That is precisely the HDMI case: digital YUV in over MIPI,
   straight out to DDR, no bayer processing. A direct call-graph closure over the bypass +
   IFE + SIF entry points is **17.1 % of ax_proton's code** (550 functions, 229 KB) and pulls
   in **no** NPU, GDC, VPP or IVPS symbols.
6. **ax_ivps and ax_pool are pure software.** No platform driver, no IRQ, no clocks;
   ax_ivps's only `ioremap` calls are inside `ivps_dump_reg_by_phyaddr` / `ivps_proc_save_file`
   debug helpers.

---

## 1. Per-module table

Sizes in bytes. `text` = `.text` + `.text.unlikely` + `.init.text` + `.exit.text`.
`rodata` = `.rodata` + `.rodata.str1.8`. `exp` = `__ksymtab_*` count.
Undefined symbols are split three ways: `sib` = resolved by one of the other nine modules,
`osal` = Axera OSAL (kernel-resident, GPL source available), `kern` = genuine mainline symbols.

| module | file | text | rodata | .data | .bss | funcs | objs | exp | und | sib | osal | kern |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ax_sys | 60,112 | 12,244 | 8,116 | 192 | 5,024 | 42 | 84 | 21 | 29 | 0 | 29 | 0 |
| ax_base | 57,864 | 12,612 | 4,111 | 1,360 | 1,072 | 45 | 84 | 21 | 41 | 2 | 31 | 8 |
| ax_cmm | 92,944 | 23,704 | 8,408 | 656 | 50,528 | 94 | 101 | 49 | 54 | 0 | 47 | 7 |
| ax_pool | 114,976 | 31,496 | 15,953 | 120 | 273,496 | 50 | 87 | 18 | 60 | 10 | 47 | 3 |
| ax_npu | 362,736 | 100,648 | 23,879 | 1,096 | 6,560 | 422 | 318 | 18 | 102 | 6 | 92 | 4 |
| ax_ivps | 347,968 | 106,840 | 38,880 | 1,968 | 8,760 | 220 | 358 | 98 | 68 | 17 | 43 | 8 |
| ax_vpp | 306,248 | 102,884 | 35,928 | 3,464 | 14,328 | 185 | 240 | 24 | 102 | 36 | 61 | 5 |
| ax_gdc | 218,472 | 68,292 | 26,389 | 456 | 2,760 | 160 | 183 | 9 | 126 | 56 | 63 | 7 |
| ax_mipi_rx | 105,944 | 24,372 | 8,149 | 240 | 1,200 | 128 | 143 | 1 | 44 | 0 | 41 | 3 |
| ax_proton | 4,524,216 | 1,359,584 | 298,703 | 69,136 | 32,500 | 3,264 | 3,338 | 1 | 216 | 65 | 128 | 23 |
| **total** | 6,191,480 | 1,942,676 | | | | 4,610 | | 260 | | | | |

### modinfo essentials

| module | depends | parm | notes |
|---|---|---|---|
| ax_sys | *(none)* | — | v1.0, GPL, `alias` none but string `axera,sys` present |
| ax_base | ax_cmm | `sys` (array of charp): `sys=isp,vpu,mm_core,npu` | v1.1 |
| ax_cmm | *(none)* | `cmmpool` (`name,0,start,size`), `map_cmmpool`, `cmmpool_allocator` | no version/author |
| ax_pool | ax_cmm | `test_kernel_api` (int) | v1.1 |
| ax_npu | ax_cmm, ax_sys | — | "npu driver" |
| ax_ivps | ax_pool, ax_cmm, ax_sys | — | v1.1, "IVPS" |
| ax_vpp | ax_ivps, ax_base, ax_pool, ax_cmm | — | aliases `of:N*T*Caxera,_vpp-dev` |
| ax_gdc | ax_pool, ax_ivps, ax_vpp, ax_cmm, ax_base | — | no OF alias (uses `axera, gdc-dev` string) |
| ax_mipi_rx | *(none)* | — | Dual BSD/GPL, "Axera MIPI Soc Chip Driver", alias `axera,mipi` |
| ax_proton | ax_ivps, ax_cmm, ax_pool, ax_vpp, ax_sys, ax_base, ax_gdc, ax_npu, ax_mipi_rx | `mem_iq_level` (uint) | Dual BSD/GPL, "Axera AI ISP Soc Chip Driver"; aliases `axera,proton`, `axera,proton_top`, `axera,proton_axi`, `axera,proton_ir` |

All ten share `srcversion: 533BB7E5866E52F63B9ACCB` except ax_base (`59BE32996245685C708656F`) and
ax_cmm (none) — i.e. they come from one source drop.

---

## 2. Inter-module dependency graph

Export map built from all ten `__ksymtab_*` sets (260 exported symbols total), then each
module's `UND` set resolved against it.

```
                       ax_cmm  (49 exports)        <- SUBSTRATE (memory)
                        ^  ^  ^  ^  ^  ^
        ax_base(2) ax_pool(10) ax_npu(5) ax_ivps(4) ax_vpp(1) ax_gdc(2) ax_proton(7)

                       ax_sys  (21 exports)        <- SUBSTRATE (link routing + PTS)
                        ^        ^        ^
              ax_npu(1)     ax_ivps(7)      ax_proton(10)

                       ax_pool (18 exports)        <- SUBSTRATE (frame buffers)
                        ^        ^        ^        ^
            ax_ivps(6)  ax_vpp(2)  ax_gdc(5)  ax_proton(15)

                       ax_base (21 exports)        <- CDMA/DMA/FBCDC engine
                        ^        ^        ^
              ax_vpp(2)   ax_gdc(2)   ax_proton(6)

                       ax_ivps (98 exports)        <- MID-LEVEL FRAMEWORK
                        ^          ^          ^
            ax_vpp(31)    ax_gdc(37)    ax_proton(7)

     ax_vpp(24 exp) --10--> ax_gdc          ax_vpp --3--> consumed by ax_proton
     ax_gdc(9 exp)  --7--> ax_proton
     ax_npu(18 exp) --9--> ax_proton   (ONLY consumer)
     ax_mipi_rx(1 exp) --1--> ax_proton (ONLY consumer)
     ax_proton(1 exp: ax_vin_kernel_ext_handle) --> ax_mipi_switch.ko only (outside the 10)
```

**Substrate** (everyone consumes): `ax_cmm` (7 of 9 others), `ax_pool` (4), `ax_sys` (3),
`ax_base` (3). Plus `ax_ivps` as a second-tier substrate for the video path (3 consumers,
but heavy ones — 31 and 37 symbols).

**Leaves**: `ax_proton` (exports 1 symbol, consumed by nothing in this set),
`ax_mipi_rx` (exports 1), `ax_gdc` (exports 9, consumed only by ax_proton within the 10).

**Kernel vs sibling imports.** The split is lopsided: of 229 symbols the ten import from
outside their own set, **188 are Axera OSAL** and only **41 are mainline kernel**. The full
mainline list is:

```
__arch_copy_to_user, __cpu_possible_mask, __kfifo_out, __ll_sc_atomic64_or, capable,
cpumask_next, down, dump_stack, gpio_free, gpio_request, gpio_to_desc,
gpiod_direction_output_raw, gpiod_get_raw_value, gpiod_set_raw_value,
irq_set_affinity_hint, ktime_get, ktime_get_real_ts64, memcmp, memcpy, memset,
module_put, nr_cpu_ids, of_find_compatible_node, of_irq_get, of_node_put,
param_array_ops, param_ops_charp, param_ops_int, param_ops_string, param_ops_uint,
printk, snprintf, sprintf, sscanf, strcmp, strcpy, strlen, strsep, strstr,
try_module_get, up
```

OSAL groups by prefix: `DEV` 61, `SYNC` 48, `LIB` 21, `MEM` 7, `TM` 7, `TMR` 5, `DBG` 5,
`FS` 4, `TASK` 4, misc 26. These are 1:1 thin wrappers over standard kernel APIs
(`ioremap`, `request_threaded_irq`, `clk_prepare_enable`, `reset_control_deassert`,
`platform_get_irq`, `devm_devfreq_add_device`, mutexes, spinlocks, waitqueues, kthreads,
timers). Three are *not* thin wrappers and are worth flagging:
`AX_OSAL_mailbox_send_message`, `AX_OSAL_mailbox_set_callback`, and the ax_proton-only
`ax_riscv_entry_sleep` / `ax_riscv_release_mem` / `ax_free_isp_image_mem` — evidence of a
**RISC-V companion core** in the ISP subsystem reached over a mailbox
(`__vin_pipe_mbox_receive_message`, `ax_vin_stat_riscv_attr_get`,
`%s(%d)ax_mailbox_send_message fail`). **[speculative]** the RISC-V core runs 3A/statistics
firmware; the only proton-side users found are `vin_stat_*` and sleep/resume paths, so a
capture-only replacement probably never has to talk to it.

---

## 3. Hardware footprint per module

Signals used: presence of `AX_OSAL_DEV_platform_driver_register`, `request_threaded_irq` /
`platform_get_irq`, `devm_clk_get` / `clk_prepare_enable`, `reset_control_*`,
`ioremap*`, plus literal `ioremap` base addresses recovered by scanning back from each
`R_AARCH64_CALL26 AX_OSAL_DEV_ioremap*` relocation for the `mov x0,#imm` / `movk` pair.

| module | class | plat drv | IRQ | clk | reset | OF compatible | literal MMIO bases | /proc |
|---|---|---|---|---|---|---|---|---|
| ax_sys | **thin HW** (timer/PTS + 1 glb reg) | yes | no | no | no | `axera,sys` | `0x02250000` (len 0xac), `0x02340220` (len 4) | `ax_proc/sys`, `ax_proc/link_table` |
| ax_base | **HW driver** (CDMA + FBCDC) | no (manual `of_find_compatible_node` + `of_irq_get`) | yes | no | no | `axera,dma` | `0x10034000`, `0x10038000` (len 0x20 each), `0x10460000` (len 0x200); plus DT-derived bases of len 0x1000/0x468 | — |
| ax_cmm | **pure software** (+DT carveout parse) | yes | no | no | no | `axera,cmm` | none (maps CMA/carveout pages) | `ax_proc/mem_cmm_info` |
| ax_pool | **pure software** | no | no | no | no | none | none | `ax_proc/pool` |
| ax_npu | **HW driver** | yes | yes (8 refs) | yes (9 refs) | soft-reset regs, no reset ctl | `axera,npu` | none (DT `reg`) | `ax_proc/npu` |
| ax_ivps | **pure software** framework | no | no | no | no | none | only in `ivps_dump_reg_by_phyaddr` / `ivps_proc_save_file` debug paths | `ax_proc/ivps`, `ax_proc/rgn` |
| ax_vpp | **HW driver** (scaler) | yes | yes | yes | yes | `axera,_vpp-dev` / `axera, vpp-dev` | none (DT `reg`, `platform_get_resource_byname`) | `ax_proc/vpp` |
| ax_gdc | **HW driver** (dewarp/LDC) | yes | yes | yes | yes | `axera, gdc-dev` | `0x04404000` | `ax_proc/gdc` |
| ax_mipi_rx | **HW driver** (D-PHY + CSI-2 RX) | yes | yes | reg-level clk gating | reg-level soft resets | `axera,mipi` | `0x02300000`, `0x02303000`, `0x02340000`, `0x023f0000`, `0x02500000`, `0x02600000`, `0x02602000` | `ax_proc/mipi_rx`, `ax_proc/mipi_tx` |
| ax_proton | **HW driver** (VIN/ISP, largest) | yes | yes | yes | yes | `axera,proton`, `axera,proton_top`, `axera,proton_axi`, `axera,proton_ir` | `0x02340000` (x2), `0x02340208`, `0x02400000` (len 0xd4008), `0x02500000` (x4), `0x04403060` | `ax_proc/isp`, `ax_proc/vin`, `ax_proc/sensor` |

Cross-check: `ax_mipi_rx` ioremaps `0x02300000` — the same block that
`CLAUDE.md` records as the pinmux register file (`0x02300060` = VI_D7 pad / SW_PWR trap).
That is consistent and increases confidence in the extraction method.
`ax_proton` and `ax_mipi_rx` share `0x02500000` and `0x02340000` (ISP-sys global /
"isp_sys_glb" register block) — the two drivers poke the same glue registers.

Additional hardware surface, ax_proton only:
- **I2C master**: `AX_OSAL_DEV_i2c_dev_init/read/write` — sensor (here: HDMI-to-MIPI bridge)
  control bus.
- **GPIO**: raw `gpio_request` / `gpiod_direction_output_raw` / `gpiod_set_raw_value` —
  reset/standby lines, and `dphy_dvp_gpio_pin_mux` in ax_mipi_rx does pad muxing.
  This is the family of behaviour behind the documented SW_PWR pinmux trap.
- **devfreq/OPP** (`pm_opp_of_add_table`, `devm_devfreq_add_device`) and a
  bandwidth limiter (`bwlimiter_register_with_clk`) — DVFS, not required for correctness.
- **Firmware/file path** string `/opt/data/mc20e_isp_reg_reset_value.bin` — a register
  reset-value blob loaded from the filesystem. **[speculative]** likely only needed for
  full ISP init, not for the bypass path; worth checking whether it exists on the device.

Device nodes: each module registers a chardev through `AX_OSAL_DEV_createdev` with the
module's own name (`ax_sys`, `ax_base`, `ax_cmm`, `ax_pool`, `ax_npu`, `ax_ivps`, `ax_gdc`,
`ax_mipi_rx`, `ax_proton`), plus the `/proc/ax_proc/*` tree listed above.

IRQ handler names recovered: ax_vpp `vpp_irq_v0`, `vpp_irq_v1`, `vpp_irq_isp`, `vpp_irq_gdc`
(+ threaded variants); ax_gdc `gdc_irq` / `gdc_irq_thread`; ax_mipi_rx
`ax_mipi_register_mipi_rx_irq`, `csi_rx_ctrl_err_irqs_handle`; ax_proton
`__vin_int_handler`, `vin_irq_exec_thread`, and per-node `*_wait_*_irq_event` helpers.
Clock/reset names as strings: ax_vpp `vpp_clk`, `vpp_pclk`, `cmd_clk`, `cmd_pclk`;
ax_gdc `gdc_clk`, `gdc_pclk`; ax_proton `ax_sen_mclk_*` (sensor master clock),
`ax_isp_clk_rst0_set` / `rst1_set` / `ax_isp_reset_assert_isp_domain`.

---

## 4. Internal structure (symbols survive — this is the map)

### 4.1 ax_proton (3264 functions, 1,354,188 B of FUNC text)

Top-level prefix families:

| family | funcs | bytes | % FUNC text |
|---|---|---|---|
| `vin_*` / `ax_vin_*` | 1721 | 741,328 | 54.7 % |
| `isp_*` / `ax_isp_*` | 504 | 156,336 | 11.5 % |
| `itp_*` / `ax_itp_*` | 322 | 112,052 | 8.3 % |
| `regio_*` | 64 | 28,336 | 2.1 % |
| `wrapper_*` | 25 | 16,624 | 1.2 % |
| `ife_*` | 63 | 16,192 | 1.2 % |
| everything else (yuv, gdc, rawscl, dis, fio, ainr, priv_pool, work, top, drv, stat…) | ~565 | ~283,000 | ~20.9 % |

Second-level under `vin_` (61.5 % of module when `ax_vin_`/`__vin_` variants are folded in):

| sub-family | funcs | bytes | % module |
|---|---|---|---|
| `vin_itp_yuv_*` | 170 | 85,532 | 6.32 |
| `vin_itp_nrlite_*` | 119 | 66,844 | 4.94 |
| `vin_top_node_*` | 116 | 49,284 | 3.64 |
| `vin_ipc_pipe_*` | 25 | 43,008 | 3.18 |
| `vin_ai3dnr_node_*` | 69 | 39,252 | 2.90 |
| `vin_ife_node_*` | 70 | 36,924 | 2.73 |
| `vin_pipe_comm_*` | 60 | 33,508 | 2.47 |
| `vin_itp_raw_*` | 75 | 26,576 | 1.96 |
| `vin_itp_rgb_*` | 65 | 20,324 | 1.50 |
| `vin_gdc_node_*` | 84 | 18,812 | 1.39 |
| `vin_yuv_pipe_*` | 20 | 16,816 | 1.24 |
| `vin_test_pipe0..6_*` | 140 | 85,988 | 6.35 |
| `vin_bypass_pipe_*` | 20 | 12,380 | 0.91 |
| `vin_rawscl_node_*` | 25 | 12,368 | 0.91 |
| `vin_iq_sync_*` | 34 | 11,960 | 0.88 |
| `vin_dev_node_*` | 18 | 10,932 | 0.81 |
| `vin_itp_thdr_*` | 31 | 10,184 | 0.75 |

Second-level under `isp_` (the hardware-register layer): `isp_cdma_*` 16.2 KB,
`isp_yuv_rdma/wdma_*` 30.1 KB, `isp_itp_rdma/wdma_*` 21.9 KB, `isp_ife_wdma/rdma/top_*`
16.5 KB, `isp_sif_*` (CSI/DVP front-end + sensor timing) 21.9 KB, `isp_sync_*` 7 KB,
`isp_fw_kernel_*` 2.9 KB, `isp_clk_*`/`isp_reset_*` ~3 KB.

Second-level under `itp_` (the per-IQ-module register drivers): `itp_yuv_eis` 12.8 KB,
`itp_nrlite_pre/pst` 19.4 KB, `itp_raw_pre/pst` 15.3 KB, `itp_yuv_pre/pst` 16.0 KB,
`itp_rgb_pre/pst` 14.8 KB, `itp_thdr` 6.2 KB, `itp_raw2dnr` 5.7 KB, `itp_pfd` 5.0 KB,
then the classic IQ blocks in the low hundreds of bytes each: `itp_ae_mod` 2.1 KB,
`itp_awb_mod` 1.1 KB, `itp_af_mod` 0.7 KB, `itp_wbc_mod`, `itp_rltm_mod`, `itp_dpc_mod`,
`itp_hdr_mod`.

**Semantic split (keyword classifier over all 3264 functions, first-match-wins ordering):**

| category | funcs | bytes | % |
|---|---|---|---|
| YUV-domain ISP (yuv / eis / dis / scl / gdc) | 620 | 247,812 | 18.30 % |
| RAW-domain ISP (raw / rgb / ife / pfd / raw2dnr / ptn) | 617 | 215,884 | 15.94 % |
| AI-NR & NPU glue (ai3dnr, ainr, nrlite, 3dnr) | 367 | 164,436 | 12.14 % |
| Clock / reset / power / regio / top | 327 | 117,244 | 8.66 % |
| Test-pattern pipes (`test_pipe0..6`, tpg) | 147 | 87,504 | 6.46 % |
| IRQ / scheduler / IPC / mailbox / sync | 166 | 95,356 | 7.04 % |
| Buffer / pool / mem management | 141 | 71,816 | 5.30 % |
| DMA engines (cdma / wdma / rdma) | 115 | 67,996 | 5.02 % |
| 3A + IQ tuning (ae/awb/af/iq/wbc/rltm/dpc/dehaze/hdr) | 225 | 65,752 | 4.86 % |
| proc / debug / ioctl / cdev plumbing | 111 | 52,688 | 3.89 % |
| Sensor / SIF / I2C / MIPI front-end | 59 | 32,136 | 2.37 % |
| unclassified (mostly `vin_pipe_*` generic param plumbing) | 369 | 135,564 | 10.01 % |

Reading this against "HDMI capture is already digital RGB/YUV, no bayer sensor":

- **Certainly not needed**: AI-NR/NPU (12.1 %), RAW-domain ISP (15.9 %), 3A + IQ tuning
  (4.9 %), test-pattern pipes (6.5 %). ≈ **39 % of ax_proton is dead weight for HDMI capture.**
- **Probably not needed**: most of the YUV-domain ISP (18.3 %) — YUV 3DNR, EIS, DIS, GDC
  node modes exist for camera stabilisation/dewarp, not KVM. Even the parts that survive
  (a plain YUV pass-through) are a fraction of that.
- **Needed**: `regio` (register-block abstraction, 347 funcs / 122 KB / 9.0 %),
  `cdma` (77 / 40.7 KB / 3.0 %), `isp_sif_*` (39 / 22 KB), `ife` (226 / 82.9 KB, of which
  only the WDMA + top parts matter), `top_node` topology manager (116 / 49.3 KB),
  `vin_dev_node` (91 / 44.4 KB), `pipe_comm` (74 / 45.9 KB), IRQ (112 / 61.6 KB),
  buffers (330 / 144.7 KB).

**Direct call-graph closures** (built from `bl` targets + `R_AARCH64_CALL26` relocations;
**these are lower bounds** — see the vtable caveat below):

| seed set | reachable local funcs | bytes | % of ax_proton |
|---|---|---|---|
| `vin_bypass_pipe_*` only | 124 | 56,536 | 4.2 % |
| bypass + IFE node + SIF + top_node + dev_node | 550 | 228,884 | **17.1 %** |
| `__ax_isp_probe` / `ax_isp_open` / `ax_isp_close` / `ax_isp_ioctl` | 311 | 119,304 | 8.9 % |

External symbols the bypass+IFE closure needs (62 total): OSAL only, plus
`ax_base_cdma_add_virtual_queue`, `ax_base_cdma_trigger`, `ax_chip_type_get`,
`ax_cmm_is_phyaddr_in_partition`, `ax_sys_get_mem_param`, `ax_sys_convert_pts_to_us`,
`ax_tmr64_get_pts_offset`, four `ax_pool_*`, and `ax_free_isp_image_mem`.
**No NPU, no GDC, no VPP, no IVPS.**

**Vtable caveat (important).** `.rela.data` carries 1801 relocations reaching **1483 distinct
functions totalling 604,260 B (45 % of the module's code)**. The architecture is a set of
"node mode" ops tables: 51 objects of exactly 360 bytes each — `vin_top_node_mode1..10`,
`vin_ife_node_mode1..3`, `vin_itp_*_node_mode*`, `vin_ai3dnr_node_mode1..4`,
`vin_gdc_node_mode1..4`, `vin_rawscl_node_mode1`, `vin_dis_node_mode1`,
`vin_iq_sync_node_mode1` — i.e. ~45 function pointers per pipeline node type. Static direct
call-graph closure therefore under-counts; the real minimal set is somewhere between the
17 % closure and the ~39 %-of-code "needed" categories above. **Plan on ~25–35 % of
ax_proton's logic for a capture-only reimplementation** — but note that "reimplement" here
does not mean "port"; a purpose-built driver for one topology does not need the mode-table
machinery at all.

Largest data objects: `dump_info` 24,496 B, `default_context` 22,600 B,
`g_ainr_stat_time` 4,032 B, `itp_reginfo_list` 2,356 B, `ife_reginfo_list` 1,368 B,
`yuv_reginfo_list` 1,292 B, `vin_reset_mapping_tbl` 1,116 B, `ax_isp_match` 1,000 B (the OF
match table). Version string present: `AX620E_ISP_V4.0.39`.

### 4.2 ax_mipi_rx (128 functions, 24,356 B) — the most tractable target

| family | funcs | bytes | % |
|---|---|---|---|
| `mipi_*` / `ax_mipi_*` | 45 | 10,132 | 41.6 |
| `dphyrx_*` | 35 | 3,948 | 16.2 |
| `isp_sys_glb_*` (clock-gate / soft-reset bit pokes) | 18 | 2,852 | 11.7 |
| `csi_*` / `csi2rx_*` | 7+1 | 2,416 | 9.9 |
| proc/debug | 2 | 1,668 | 6.9 |
| `common_glb_*`, `dphy_*`, `dvp_*` | 14 | 2,256 | 9.3 |

Largest single functions are `__ax_mipi_proc_read` (1660, debug), `csi_rx_ctrl_err_irqs_handle`
(1200), `ax_mipi_rx_csi_ctrl_init` (1108), `ax_mipi_rx_start` (996). User ABI is an ioctl set
on `/dev/ax_mipi_rx` driving an attr struct with fields visible in the proc dump strings:
`LaneNum`, `DataRate`, `DataLaneMap`, `ClkLane`, `LaneComboMode`, `ResetCount`, `ErrorStatus0/1`.
Register/bit-field names are fully spelled out
(`isp_sys_glb_csirx0_ppi_rx_byte_swrst`, `dphyrx_glb_rg_hsrx_clk_pre_time_grp0`,
`csi_ctrl_dphy_err_irq_mask_cfg`, `csi_ctrl_stream_ctrl_soft_rst`, …), which is effectively a
register map in symbol form.

**[speculative]** The error string *"Overflow detected in resynchronization FIFO between DPHY
lane Management and protocol blocks"* is verbatim Synopsys DesignWare MIPI CSI-2 Host
controller wording; combined with `csi2rx_soft_reset` and the `ppi_rx_byte` naming, the CSI-2
receive controller is very likely a licensed DWC/Cadence CSI-2 host core, meaning an existing
mainline driver (`dw-mipi-csi2`-family) may be adaptable rather than written from scratch.
Worth confirming by reading the version register.

### 4.3 ax_npu (422 functions, 99,980 B)

`npu_*` 70.1 %, `model_*` 18.9 %, plus clock/reset/vnpu partitioning helpers
(`g_npu_clk_mux_value`, `g_sw_rst_bit_lookup`, `ensure_vnpu_safe_reset`,
`g_npu_irq_ringbuffer`). It is a real hardware driver (clk, DVFS/OPP, IRQ, `ax_proc/npu`).
For issue #55 the relevant fact is §5 below: it is only reachable from AI-NR.

### 4.4 ax_ivps (220 functions, 107,432 B) — pure-software framework

`ivps_*` 73.7 %, `rgn_*` (privacy-mask regions) 7.5 %, `proc_*` 7.3 %, plus format/stride
conversion helpers. Its 98 exports are the "video processing subsystem" API: group/channel
lifecycle, frame FIFOs, link dispatch, buffer pools, format and stride math, refcounting
(`ax_ivps_block_incref/decref`), frame-rate control. No registers of its own.

### 4.5 ax_vpp (185 functions, 102,704 B) and ax_gdc (160 functions, 68,148 B)

ax_vpp: `vpp_*` 63.1 %, `vppscl_*` 15.5 % (the scaler proper), `axvpp_*` 10.4 %,
`vppdev_*` 5.0 %, `piston_*` 2.9 %, `vpptile_*` 1.1 %. Four IRQ lines
(`vpp_irq_v0/v1/isp/gdc`), two clocks, three reset controls, DVFS.
ax_gdc: `gdc_*` 38.2 %, `axgdc_*` 36.9 %, `gdcdev_*` 8.3 %, `ldc_*`/`transform_*`/
`inverse_*`/`mesh_*` — geometric distortion correction, i.e. lens dewarp.

### 4.6 The four substrate modules

- **ax_sys** (42 funcs, 12,244 B): `sys_*` 52 %, `link_*` 36.8 % — a module-to-module link
  routing table (`ax_link_dispatch`, `ax_link_table_add`) plus a 64-bit timer / PTS source
  (`ax_tmr64_reg32_read`, `ax_sys_get_pts`, `ax_sys_convert_pts_to_us`) and
  `ax_chip_type_get`. Two tiny MMIO windows.
- **ax_base** (45 funcs, 12,612 B): `base_*` 60 %, `dma_*` 22 %, `fbcdc_*` 12 % — a
  command-DMA ("CDMA") engine used to push register-write queues to the video IPs, plus a
  frame-buffer compression/decompression (FBCDC) block and a 2D crop-copy DMA.
- **ax_cmm** (94 funcs, 23,592 B, 50 KB .bss): contiguous-memory-manager. Partition create/
  find/destroy over DT-declared carveouts, block alloc/free, cache maintenance,
  user mmap, `/proc/ax_proc/mem_cmm_info`. The `cmmpool=name,0,start,size` module parameter
  is the carveout declaration.
- **ax_pool** (50 funcs, 31,432 B, 267 KB .bss): the video-buffer pool ("VB") layer —
  create/destroy pool, get/release block, refcounting, handle↔physaddr↔kvirt translation,
  mmap. 52 % of its code is ioctl marshalling.

---

## 5. What ax_proton imports from ax_npu

Exactly nine symbols, each with exactly one call site, all inside the `vin_nnw_*`
("neural-network wrapper") family:

| symbol | sole caller |
|---|---|
| `AX_NPU_Kernel_create_task` | `vin_nnw_run_async` |
| `AX_NPU_Kernel_cancel_task` | `vin_nnw_run_cancel` |
| `AX_NPU_Kernel_destroy_handle` | `vin_nnw_destroy_handle` |
| `AX_NPU_Kernel_get_io_info` | `vin_nnw_get` |
| `AX_NPU_Kernel_get_throttle` | `vin_nnw_get_throttle` |
| `AX_NPU_kernel_set_throttle` | `vin_nnw_set_throttle` |
| `AX_NPU_Kernel_set_isp_conf` | `vin_nnw_sm_reset` |
| `AX_NPU_Hsk_status_clear` | `vin_nnw_sm_reset` |
| `AX_NPU_Kernel_vnpu_reset` | `vin_nnw_vnpu_reset` |

The `vin_nnw_*` family is reached only from the AI-NR node modes
(`__ainr_mode1..4_npu_task_backward` / `_finish_cb` / `_release`,
`ainr_node_npu_timeout_reset_sm`, `ax_vin_pipe_npu_throttle_info_set`), which correspond to
the documented modes `AI3DNR_NODE_MODE1..4`, `ITP_NRLITE_PRE/PST_MODE*` and
`ITP_THDR_NODE_MODE2` (all strings say "NPU … HSK/OCM"). The "hard dependency even with no
NN loaded" is therefore a **link-time `depends=` artifact, not a runtime one**: the symbols
are referenced, so modpost records the dependency and modprobe loads ax_npu, but on a
bypass/IFE-only topology none of those functions ever execute.

ax_npu is the only importer of its own exports (9 of its 18 exports used, all by ax_proton;
the other 9 — `get_affinity`, `set_affinity`, `get_isp_conf`, `get_model_type`,
`get_ocm_info`, `get_sync_info`, `hard_reset`, `register_reset_cb`, `unregister_reset_cb` —
are consumed only from userspace, if at all).

**Conclusion for #55: ax_npu can be dropped entirely from a capture-only stack.**

---

## 6. The inter-blob ABI surface (what a partial replacement must honour)

Counts of exported symbols and how many are actually imported by another kernel module.
Two consumer scopes are given: the other nine of these ten, and *any* `ax_*.ko` in the
firmware (including ax_vo, ax_tdp, ax_avs, ax_audio, ax_vdec, ax_fb, ax_ive,
ax_mipi_switch — several of which this project has already dropped, and ax_venc/ax_jenc
which are already removed).

| module | exports | used by the other 9 | used by any `ax_*.ko` | never imported (userspace-only or dead) |
|---|---|---|---|---|
| ax_cmm | 49 | 13 | 13 | **36** |
| ax_pool | 18 | 16 | 16 | 2 |
| ax_sys | 21 | 14 | 16 | 5 |
| ax_base | 21 | 9 | 11 | 10 |
| ax_ivps | 98 | 53 | 68 | 30 |
| ax_vpp | 24 | 13 | 13 | 11 |
| ax_gdc | 9 | 7 | 9 | 0 |
| ax_npu | 18 | 9 | 9 | 9 |
| ax_mipi_rx | 1 | 1 | 1 | 0 |
| ax_proton | 1 | 0 | 1 (`ax_mipi_switch`) | 0 |

**The real substrate ABI is small.** If the four substrate modules were replaced and
ax_proton/ax_vpp/ax_gdc/ax_ivps left as blobs, the contract to honour is:

- **ax_cmm — 13 symbols.** `AX_OSAL_MemAlloc`, `AX_OSAL_MemAllocCached`, `AX_OSAL_MemFree`,
  `AX_OSAL_MemFlushCache`, `AX_OSAL_MemInvalidateCache`, `AX_OSAL_Mmap`, `AX_OSAL_MmapCache`,
  `AX_OSAL_Munmap`, `ax_block_alloc`, `ax_block_free`, `ax_cmm_is_phyaddr_in_partition`,
  `ax_sys_get_mem_config`, `ax_sys_get_mem_param`. Semantics: allocate physically contiguous,
  optionally cached memory from a named DT carveout; return phys+kvirt; flush/invalidate by
  range; map into a user VMA; and answer "which partition is this phys in / how big is it".
  This is a thin shim over CMA or a reserved-memory region — the project already has the
  hard-won knowledge here (docs/vcmd-cma-unblock.md). The other 36 exports are the
  userspace ioctl/partition-management API and are not part of the inter-blob contract.
- **ax_pool — 16 of 18 symbols**, essentially the whole surface: `create_pool`,
  `destroy_pool`, `delay_destroy_pool`, `getblock`, `releaseblock`, `incref`, `decref`,
  `checkref`, `checkref_detail`, `handle2physaddr`, `handle2blkkvirtaddr`,
  `handle2metakvirtaddr`, `handle2blksize`, `handle2poolid`, `mmap`, `unmap`. Semantics: a
  refcounted fixed-block frame-buffer pool with an opaque 64-bit handle carrying pool id +
  block index, and a per-block metadata area. Straightforward to reimplement, but the handle
  encoding must be bit-compatible if blobs stay.
- **ax_sys — 14 symbols**: `ax_link_dispatch`, `ax_link_register_callback`,
  `ax_link_unregister_callback`, `ax_sys_get_vin_by_ivps`, `ax_sys_get_ivps_by_vin`,
  `ax_sys_query_fifo_status`, `ax_sys_register/unregister_fifo_status_callback`,
  `ax_sys_get_pts`, `ax_sys_get_current_us`, `ax_sys_convert_pts_to_us`,
  `ax_tmr64_get_pts_offset`, `ax_tmr64_reg32_read`, `ax_chip_type_get`. Semantics: a
  (src module,id)→(dst module,id) routing table with callbacks, plus a global 64-bit
  timestamp source. Small.
- **ax_base — 9 symbols**: `ax_base_cdma_push` (ax_gdc), `ax_base_cdma_trigger`,
  `ax_base_cdma_add_virtual_queue`, `ax_base_cdma_debug_dump_queue`,
  `ax_base_cdma_debug_get_queue_info`, `ax_base_cdma_debug_pulse_set`,
  `ax_dma_xfer_crop` (all ax_proton), `ax_base_cdma_filter_config` (ax_vpp),
  `ax_fbcdc_hw_enable` (ax_vpp + ax_gdc). Two more — `ax_base_cdma_req` and
  `ax_mm_cdma_req_group_push_trigger` — are used only by modules outside these ten
  (ax_tdp/ax_vo/ax_jenc/ax_venc). This one is genuinely hard: the CDMA
  queue format is an undocumented hardware descriptor layout that ax_proton's `regio` layer
  builds. Replacing ax_base while keeping ax_proton means matching that descriptor format
  exactly.

**If the whole closure is replaced at once, this entire ABI cost is zero** — 260 exported
symbols and their struct layouts evaporate, and the only frozen interface left is the
userspace one (`/dev/ax_*` ioctls used by libkvm/kvm-app, which this project already
controls) plus the AX_OSAL layer (which is source).

---

## 7. Effort estimates

Scoped to "replace from source, for HDMI capture on this device", assuming the OSAL layer
is reused as-is (it is GPL source already in the kernel build).

| module | size | verdict | rationale |
|---|---|---|---|
| **ax_npu** | 100 KB text | **DROP — XS (delete)** | Only ax_proton imports it, and only from `vin_nnw_*`/AI-NR. No capture path touches it. Cost is removing the `depends=` edge, not writing code. |
| **ax_gdc** | 68 KB text | **DROP — XS** | Lens dewarp / LDC. Meaningless for a flat HDMI source. Only consumers are ax_proton (7 syms, all in `vin_gdc_node_mode*`) and ax_avs. |
| **ax_sys** | 12 KB text, 42 funcs | **S** | A routing table plus a timer read from two small MMIO windows whose addresses we have (`0x02250000`, `0x02340220`). Semantics fully legible from 21 export names. |
| **ax_pool** | 31 KB text, 50 funcs, no HW | **S–M** | Pure software refcounted block pool; half the code is ioctl marshalling that a purpose-built driver would not need. Risk is only handle-encoding compatibility, and only if blobs remain. |
| **ax_cmm** | 24 KB text, 94 funcs, no IRQ/clk | **M** | Carveout allocator + cache maintenance + user mmap. Conceptually simple, but this is exactly where #49 was lost — CMA/coherency/`migratetype` interactions are the risk, not the code volume. Prior art exists in-repo. |
| **ax_mipi_rx** | 24 KB text, 128 funcs | **M** | The single best-scoped hardware target: small, all seven MMIO bases recovered as literals, register/bit names spelled out in symbols, narrow ioctl ABI (`LaneNum`/`DataRate`/`DataLaneMap`/`ClkLane`/`LaneComboMode`). **[speculative]** likely a licensed DWC CSI-2 host core, which would cut this to S. |
| **ax_base** | 12.6 KB text, 45 funcs | **M–L** | Small in code but it is a command-DMA engine with an undocumented descriptor/queue format that everything else programs registers through. Bases known (`0x10034000`/`0x10038000`/`0x10460000`). Effort is dominated by RE of the queue format, not by lines of code. Cannot be skipped: ax_proton's `regio` layer sits on it. |
| **ax_ivps** | 107 KB text, 220 funcs, no HW | **M** *(as a rewrite)* / **L** *(as a port)* | Pure-software group/channel/FIFO/link framework with 98 exports. If the whole closure is replaced, most of it is generality this project does not need (regions/privacy masks, EIS, mesh, 20+ format converters); a capture-only equivalent is a small fraction. If vendor ax_vpp/ax_gdc are kept, the 53–68-symbol ABI must be matched exactly → L. |
| **ax_vpp** | 103 KB text, 185 funcs, 4 IRQs, clk+reset+DVFS | **L** | Real scaler hardware, no literal bases (DT `reg`), 36 sibling imports. Needed only if hardware scaling is required; if the open encoder or software can handle 4K→1080p, this is deferrable. Evaluate need before scoping. |
| **ax_proton** | 1.33 MB text, 3264 funcs | **XL overall; L for the capture-only subset** | ~39 % of its code (AI-NR, RAW/bayer ISP, 3A/IQ tuning, test pipes) is provably irrelevant to a digital-YUV source. The vendor's own `TOP_NODE_MODE10` "BYPASS PPL, only IFE WDMA working" plus `IFE_NODE_MODE3` (`IFE_IN_ONELINE(YUV)->IFE_OUT_OFFLINE`) is the target topology; its direct call closure is 17 % of the module and needs no NPU/GDC/VPP/IVPS. A purpose-built driver — SIF/CSI front-end config, IFE top + WDMA, `regio`/CDMA register programming, IRQ + frame handoff — is realistically a few thousand lines, not 3264 functions. The hard parts are the CDMA/regio descriptor format (shared with ax_base) and the IFE WDMA register map, neither of which is documented. |

### Suggested order

1. **ax_mipi_rx** — smallest self-contained hardware win, and the closest thing to a
   mainline-adaptable IP block. Also independently testable (link up + error counters).
2. **ax_sys**, **ax_pool** — trivial-to-moderate software substrate; unblocks the rest.
3. **ax_cmm** — reuse the #49 carveout knowledge.
4. **ax_base (CDMA/regio descriptor format)** — the true gate for ax_proton. Do the RE here
   before committing to a ax_proton timeline.
5. **ax_proton bypass/IFE subset** — the payload.
6. **ax_ivps / ax_vpp** — only if hardware scaling turns out to be required.
7. **ax_npu, ax_gdc** — delete.

### Cross-cutting risks

- **Struct-layout/ABI hazards while blobs remain loaded.** Already burned once (#49:
  `CONFIG_DMA_CMA` → `struct device.cma_area`). Any staged replacement leaves blobs sharing
  kernel structs with new code; the whole-closure replacement removes this class of bug.
- **The vtable architecture hides call edges.** 45 % of ax_proton's code is only reachable
  through `.data` ops tables. Any RE plan that relies on static call graphs must be
  supplemented with on-device tracing (the project's `device-re-subagent` route).
- **The `/opt/data/mc20e_isp_reg_reset_value.bin` register-reset blob** may be required for
  ISP init even in bypass mode. **[speculative]** — check whether it is present on the
  device and whether the bypass path reads it.
- **RISC-V companion core + mailbox** in the ISP subsystem. Only proton users found are
  statistics and sleep/resume; **[speculative]** it can probably be left asleep for capture.
