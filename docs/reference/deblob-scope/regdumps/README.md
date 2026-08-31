# Golden register dumps — live vendor 4K capture vs base-only (M2 bring-up, 2026-08-31)

Our own `/dev/mem` observations of AX630C register state (NOT vendor code/DWARF).
Captured during the #59 M2 bring-up to seed a register-diff bring-up of the open
`open_vin_capture` driver. Little-endian u32 images.

| file | phys base | length | state |
|---|---|---|---|
| `regfile-vendor-live.bin` | 0x02400000 | 0xD4008 | full ISP/VIN register file, VENDOR stack streaming live 4K (3840x2160) |
| `glb-vendor-live.bin`  | 0x02500000 | 0x2000 | isp_sys_glb, vendor live |
| `cglb-vendor-live.bin` | 0x02340000 | 0x100  | common_glb, vendor live |
| `glb-now.bin` / `cglb-now.bin` | as above | | base-only boot (no capture stack) for diffing |

## Confirmed golden values (resolve spec [speculative]/checklist items)
- **WDMA gate**: 0x024140d4 = 0x0e8fc000 -> <<3 = 0x747e0000 (in CMM). `phys>>3` proven.
- WDMA chn8: enable 0x024140dc=1, shadow 0x024140d8=0x000f951f, mode 0x024140d0=0x1e2d1e2d.
- WDMA fmt bank chn8 at (8+0xf)<<5=0x2e0: 0x024142ec=0x08700f00 (W|H 3840x2160), 0x024142f0/f4=0x3c0.
- IFE-go 0x024146dc=1 (bit0). Int grp4 en 0x02400050=0x200 (bit9 chn8 frame-done); grp1 0x02400020=1 (FSOF).

## Spec CORRECTIONS found here (driver must adopt)
- **SIF IN_FMT** 0x02406510 = **0x40** (the driver's OVC_SIF_IN_FMT_YUV422_8=0x00030003 is WRONG for this HDMI YUV422 path).
- SIF DT-match: 0x02406540/44 = 0x00001e00 (DT 0x1E in byte<<8), park 0x02406548 = 0x3a3a3a00, VC/DT ctrl 0x0653c=1; WIN1 park 0x0651c=0x00200020.
- **MODE10 bypass masks are NOT at 0x14154/0x14158** — 0x14154 reads 0x00101720 (a WDMA per-channel stride), so the IFE-top bypass block base is ELSEWHERE and still unlocated.

## The M2 wall (why frames don't flow yet)
On a base-only boot the SIF (0x02406xxx) and IFE/WDMA (0x02414xxx) sub-blocks read
0xDEADBEEF and drop writes — held in reset/unclocked. The interrupt-controller
sub-block (0x02400000-0xff) IS writable (probe/IRQ setup work). The `cglb`
diff shows only 0x2340024 bit9 differs, but M1 already sets it and the blocks stay
dead -> the missing piece is the vendor `VIN_glb_create` SIF/IFE reset-deassert
(W1S/W1C pulses at the AXI-ctrl regs + the 0x0440306C hold), which self-clear and
are NOT observable in a static dump. Needs clean-room RE of ax_proton
VIN_glb_create / ax_isp_reset_all_legacy. This is the single blocker; the WDMA
address gate and the frame-done IRQ are already device-confirmed above.
