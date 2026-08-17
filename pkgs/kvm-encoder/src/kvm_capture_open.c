/*
 * kvm_capture_open.c -- BLOB-FREE HDMI capture backend for the AX630C.
 *
 * Drop-in replacement for the vendor-lib capture half of kvm_pipeline.c
 * (kvm_sys_init / kvm_cap_start / kvm_cap_get / kvm_cap_release / kvm_cap_stop /
 * kvm_sys_deinit). Compiled ONLY when KVM_OPEN_CAPTURE is defined; otherwise
 * kvm_pipeline.c provides the vendor-MPI versions. The VENC (encode) half stays
 * in kvm_pipeline.c and still uses libax_venc -- this file replaces capture,
 * not encode. The public kvm_vision.h ABI and libkvm.c are unchanged.
 *
 * HOW IT WORKS. This is the Stage-6 capture sequence (docs/blob-replacement.md)
 * folded into the library. Instead of calling libax_sys / libax_mipi /
 * libax_proton, it drives the /dev/ax_* char devices directly with the exact
 * ioctl selectors the vendor libs emit, replaying the captured (and
 * disassembly-verified) copy_from_user prefix of each selector. The AX ioctl
 * ABI is a uniform _IOWR(magic,nr,8) selector interface whose leaf handlers
 * copy_from_user a small, hardcoded, POINTER-FREE struct and resolve every
 * device/pipe/chn object in-kernel from an id byte -- so byte-replaying the
 * captured prefix is valid (see Stage 6 in docs/blob-replacement.md). A real
 * 1080p YUYV frame was dequeued end-to-end with zero vendor libraries on the
 * ATX unit and A/B-verified against the untouched vendor pipeline.
 *
 * PROVENANCE OF THE EMBEDDED PAYLOADS. Every PL_* array below is the
 * within-copy_from_user-size prefix captured off the live vendor path
 * (traces/stage6/stage6_payloads.txt, cross-checked against the leaf handler
 * disassembly for the exact cfu size). Bytes past a selector's cfu size are
 * ignored by the kernel; we embed exactly the meaningful prefix.
 *
 * GEOMETRY (#17). The five payloads that carry the frame size (nr17/nr21 dev
 * attr x2, nr35 CreatePipe, nr42 SetPipeAttr, nr48 SetChnAttr) plus the os_mem
 * nr1 descriptor words and the pool BlkSize are built per-resolution by
 * kvm_capture_geom.c from the same captured 1080p bytes. At 1920x1080 the
 * result is bit-identical to the constants this file used to hold, which is
 * the only property the hardware can currently regression-test; that identity
 * is proven mechanically by tests/geom_identity_test.c (nix build
 * .#checks.<system>.open-capture-geometry). Non-1080p geometries are NOT
 * hardware-validated yet -- see the assumption list in kvm_capture_geom.c.
 *
 * DEVICE-VALIDATED (2026-07-21, ATX .221): this backend brings the capture up
 * blob-free, hands the constructed AX_IMG_INFO_T to AX_VENC, and produces a real
 * H.264 stream (SPS+PPS+IDR+P) that decodes to a correct, correctly-strided
 * 1080p frame of the live HDMI source -- no board hang, service restarts clean.
 *
 * ENCODER COUPLING (the reason this is "capture blob-free", not "process blob
 * free"): the closed AX_VENC still pins the vendor libs -- AX_VENC_Init returns
 * AX_ERR_NOT_INIT without AX_SYS_Init (libax_sys), and libax_venc references
 * AX_VIN_PRIV_FindMeStat (libax_proton) + AX_IVPS_* (libax_ivps). So the open
 * build links -lax_venc -lax_sys -lax_ivps -lax_proton and drops only
 * -lax_mipi. Our CAPTURE code calls none of these (raw ioctls); they are loaded
 * solely for the encoder. Fully shedding them is the separate encode gate.
 *
 * Teardown (kvm_cap_stop): selector numbers/order from mv5.log, pointer-free
 * id-scalar args. DEVICE-VALIDATED 2026-08-16 (#16): three warm
 * suspend/resume cycles in one process -- every teardown selector returned 0,
 * the VB pool freed and re-created at the same base each cycle, the persistent
 * isp_model CMM block stayed at exactly one instance (reuse-before-allocate),
 * and capture came back with live frames every time.
 */
#ifdef KVM_OPEN_CAPTURE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include "ax_base_type.h"
#include "ax_global_type.h"
#include "ax_vin_api.h"       /* AX_IMG_INFO_T / AX_VIDEO_FRAME_T */
#include "ax_sys_api.h"       /* AX_SYS_Init/Deinit -- REQUIRED by the encoder */
#include "kvm_pipeline.h"
#include "kvm_capture_geom.h" /* parametric geometry payloads (#17) */

/* ---- ioctl selector words (magic|nr, _IOWR(.,.,8) unless noted) ---- */
#define OSMEM_NR1 0xc0094f01u  /* /dev/ax_os_mem: allocator, arg {u64 desc; u8 flag} */
#define SYS_NR45  0xc008702du  /* /dev/ax_sys */
#define POOL_NR22 0xc0087016u  /* /dev/ax_pool: AX_POOL_SetConfig (floorplan) */
#define POOL_NR20 0x00007014u  /* /dev/ax_pool: AX_POOL_Init (_IO, no arg) */
#define POOL_NR21 0x00007015u  /* /dev/ax_pool: AX_POOL_Exit (_IO, no arg) */
#define CMM_NR10  0xc008700au  /* /dev/ax_cmm */
#define CMM_NR17  0xc0087011u
#define CMM_NR0   0xc0087000u
#define CMM_NR6   0xc0087006u
#define PR(n)     (0xc0087000u | (unsigned)(n))  /* /dev/ax_proton c008 70nn */
#define MIPI_NR0  0x00006d00u   /* /dev/ax_mipi_rx: Init (_IO) */
#define MIPI_NR1  0x00006d01u   /* DeInit (_IO) */
#define MIPI_NR2  0xc0086d02u   /* SetAttr */
#define MIPI_NR4  0xc0086d04u   /* Reset */
#define MIPI_NR6  0xc0086d06u   /* Start */
#define MIPI_NR7  0xc0086d07u   /* Stop */
#define MIPI_NR8  0xc0086d08u   /* SetLaneCombo */

/* isp_model_manger_list CMM block phys -- FALLBACK ONLY (#16). The real
 * address is derived at bring-up: cmm nr0 allocates (or finds) the named
 * block, then /proc/ax_proc/mem_cmm_info reports its actual phys, which is
 * what nr6/nr138/nr12 get fed. This captured constant (carveout base
 * 0x73800000 + the fixed vendor allocation order: comm_pool_0 first, this
 * block right after) is used only if the /proc parse fails, with a loud
 * warning -- device-verified to match the derived value on the current
 * layout. */
#define ISP_MODEL_PHYS 0x74846000ULL
#define CMM_CARVEOUT_BASE 0x73800000ULL
#define CMM_CARVEOUT_END  0x80000000ULL

/* ================= captured selector payloads (within-cfu prefixes) ======== */
/* GEOMETRY-BEARING PAYLOADS LIVE IN kvm_capture_geom.c (#17). The dev-attr
 * (nr17/nr21, 376 B), CreatePipe (nr35), SetPipeAttr (nr42) and SetChnAttr
 * (nr48) payloads are built per-resolution from the same captured 1080p bytes
 * by kvm_geom_build(); at 1920x1080 they are bit-identical to the constants
 * that used to live here (proven by tests/geom_identity_test.c). Everything
 * below is resolution-invariant and stays verbatim. */
/* MIPI-RX 4-lane DPHY attr, 28 B (mipi nr2 SetAttr). */
static const unsigned char PL_mipi_attr[28]={0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x04,0x00,0x00,0x00,0x58,0x02,0x00,0x00,0x00,0x01,0x03,0x04,0x02,0x05,0x00,0x00};
/* proton nr12 VIN_Init global (embeds ISP_MODEL_PHYS at [0..7]). */
static const unsigned char PL_nr12[16]={0x00,0x60,0x84,0x74,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00};
static const unsigned char PL_nr2p[8]={0x04,0x00,0x00,0x00,0x01,0x00,0x00,0x00};                 /* proton nr2 global */
static const unsigned char PL_nr30[56]={0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}; /* SetDevBindPipe */
static const unsigned char PL_nr22p[8]={0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00};                /* SetDevBindMipi */
static const unsigned char PL_nr56[10]={0x00,0x00,0x00,0x04,0x00,0x04,0x00,0x04,0x00,0x04};       /* ISP-bypass black_level */
static const unsigned char PL_nr74[24]={0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}; /* ISP-bypass scene_attr */
static const unsigned char PL_nr54[180]={0x00,0x06,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}; /* ISP-bypass partition_info */
static const unsigned char PL_nr89[424]={0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xc8,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x16,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x4e,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x64,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x64,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x80,0x38,0x01,0x00,0x00,0x00,0x00,0x00,0x80,0x38,0x01,0x00,0xc8,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x29,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x3b,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x64,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x64,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x80,0x38,0x01,0x00,0x00,0x00,0x00,0x00,0x80,0x38,0x01,0x00,0xc8,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x58,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x0d,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x64,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x64,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x80,0x38,0x01,0x00,0x00,0x00,0x00,0x00,0x80,0x38,0x01,0x00,0xc8,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x64,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x64,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x80,0x38,0x01,0x00,0xc8,0x00,0x00,0x00}; /* ISP-bypass npu_throttle */
static const unsigned char PL_nr55[8]={0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00};                 /* EnableChn */
/* GetYuvFrame input descriptor, 248 B. Kernel writes the pool block handle back
 * at offset 0x28 (0x5e0000NN; low byte = block index). */
static const unsigned char PL_nr101[248]={0x00,0x00,0x00,0x00,0x18,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x07,0x00,0x00,0x00,0x02,0x00,0x00,0x00,0xff,0xff,0xff,0xff,0xe8,0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00};

#define FRAME_HANDLE_OFF 0x28   /* nr101 output: block handle location */
/* KVM_POOL_BLKCNT_OPEN / KVM_POOL_METASIZE now live in kvm_capture_geom.h
 * (the floorplan and the payload geometry have to agree). */

/* os_mem nr1 arg flag byte. The Stage-3 differential capture saw this vary
 * across configs (0xf0 = 1080p H.264, 0x70 = 720p H.264, 0x00 = 1080p MJPEG)
 * but never decoded it -- it does not track resolution alone. We keep the
 * device-proven 1080p-H.264 value at every geometry; if a non-1080p bring-up
 * fails at the allocator, this byte is suspect #1 (docs/blob-replacement.md,
 * "Differential field map"). */
#define OSMEM_ALLOC_FLAG 0xf0

/* ---------------- device state (single capture instance) ---------------- */
static struct {
    int fo, fs, fc, fp, fm, fpr;   /* os_mem, sys, cmm, pool, mipi_rx, proton */
    int fmem;                      /* /dev/mem */
    void    *osmem_map;            /* mapping of the allocator shared page */
    uint64_t osmem_phys;
    uint64_t pool_base;            /* comm_pool_0 CMM phys base (region start) */
    uint64_t isp_model_phys;       /* isp_model_manger_list block, derived */
    kvm_geom g;                    /* geometry + every payload derived from it */
    int      phys_logged;          /* one-shot frame-phys provenance log */
    unsigned char last_desc[256];  /* last nr101 descriptor, for ReleaseYuvFrame */
    int      have_frame;
    int      started;
} S;

static const char *es(int e){ return e ? strerror(e) : "ok"; }

/* Issue a selector from a source prefix, padded into a 4096 page. rc==0 => ok. */
static int io_pl(int fd, unsigned long cmd, const void *src, size_t len, const char *tag)
{
    unsigned char *b = aligned_alloc(4096, 4096);
    if (!b) return -1;
    memset(b, 0, 4096);
    if (src && len) memcpy(b, src, len);
    errno = 0;
    int rc = ioctl(fd, cmd, b);
    int e = errno;
    free(b);
    if (rc != 0)
        fprintf(stderr, "[openkvm][FAIL] %-22s rc=%d errno=%d(%s)\n", tag, rc, e, es(e));
    return rc;
}
#define IO_PL(fd, cmd, arr, tag) io_pl((fd), (cmd), (arr), sizeof(arr), (tag))

/* cmm helpers (4096 zeroed buffer, a few scalar fields set). Returns errno on
 * failure (0 on success) so callers can distinguish "already allocated" (EPERM)
 * from real errors on in-process re-init. */
static int cmm_call(unsigned long cmd, void (*fill)(unsigned char *), const char *tag)
{
    unsigned char *s = aligned_alloc(4096, 4096);
    if (!s) return EIO;
    memset(s, 0, 4096);
    if (fill) fill(s);
    errno = 0;
    int rc = ioctl(S.fc, cmd, s);
    int e = errno;
    free(s);
    if (rc != 0)
        fprintf(stderr, "[openkvm][FAIL] %-22s rc=%d errno=%d(%s)\n", tag, rc, e, es(e));
    return rc == 0 ? 0 : (e ? e : EIO);
}
static void f_n10a(unsigned char *s){ *(uint32_t *)s = 4; *(uint64_t *)(s + 8) = 0x02400000ULL; *(uint32_t *)(s + 0x2c) = 0x000d4008U; }
static void f_n10b(unsigned char *s){ *(uint32_t *)s = 4; *(uint64_t *)(s + 8) = 0x02500000ULL; *(uint32_t *)(s + 0x2c) = 0x00002000U; }
static void f_n0 (unsigned char *s){ *(uint32_t *)s = 4; *(uint32_t *)(s + 0x28) = 1; *(uint32_t *)(s + 0x2c) = 0x188; strcpy((char *)(s + 0x3c), "anonymous:isp_model_manger_list"); }
static void f_n6 (unsigned char *s){ *(uint32_t *)s = 4; *(uint64_t *)(s + 8) = S.isp_model_phys; *(uint32_t *)(s + 0x28) = 1; *(uint32_t *)(s + 0x2c) = 0x188; strcpy((char *)(s + 0x3c), "anonymous:isp_model_manger_list"); }
static void f_n17(unsigned char *s){ *(uint32_t *)(s + 0x368) = 17; }

/* Parse /proc/ax_proc/mem_cmm_info for a named CMM block's phys base. */
static int find_cmm_block(const char *name, uint64_t *base)
{
    FILE *f = fopen("/proc/ax_proc/mem_cmm_info", "r");
    if (!f) return -1;
    char line[512];
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        if (strstr(line, name)) {
            char *pp = strstr(line, "phys(");
            /* Parse the base hex by hand. The scanf/strtol families redirect to
             * __isoc23_* (GLIBC_2.38) under the build glibc; the target is glibc
             * 2.35, so we avoid them entirely. */
            if (pp) {
                const char *p = pp + 5;
                if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
                uint64_t b = 0; int n = 0;
                for (; *p; p++, n++) {
                    unsigned c = (unsigned char)*p, d;
                    if (c >= '0' && c <= '9') d = c - '0';
                    else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
                    else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
                    else break;
                    b = (b << 4) | d;
                }
                if (n && b) { *base = b; found = 1; break; }
            }
        }
    }
    fclose(f);
    return found ? 0 : -1;
}

/* ============================ SYS + VB pool ============================ */
int kvm_sys_init(kvm_cap_ctx *c, int w, int h)
{
    memset(c, 0, sizeof(*c));
    memset(&S, 0, sizeof(S));
    /* memset leaves every fd == 0; an early-failure teardown would then
     * close(0)/ioctl(0,...) on stdin. -1 is the only safe "unset" fd. */
    S.fo = S.fs = S.fc = S.fp = S.fm = S.fpr = S.fmem = -1;
    /* Geometry (#17). Every geometry-bearing selector payload, the allocator
     * descriptor and the pool floorplan are derived from {w,h} here; there is
     * no baked-in 1080p left. Unsupported geometries are REFUSED rather than
     * clamped: clamping would drive the pipe at a resolution the source is not
     * sending, i.e. exactly the garbage-frame failure #17 is about. At
     * 1920x1080 every generated byte is identical to the old constants
     * (tests/geom_identity_test.c proves it). */
    {
        const char *why = NULL;
        if (kvm_geom_check(w, h, &why) != 0) {
            fprintf(stderr, "[openkvm][FAIL] unsupported source geometry %dx%d: %s\n",
                    w, h, why ? why : "?");
            return -1;
        }
        kvm_geom_build(&S.g, w, h);
    }
    c->w = w; c->h = h;

    /* AX_SYS_Init is the ONE vendor-lib call the capture path makes, and it is
     * here only because the closed encoder (AX_VENC) hard-requires an
     * initialized libax_sys: AX_VENC_Init returns AX_ERR_NOT_INIT (0x80070212)
     * without it, and libax_venc also pins AX_VIN_PRIV_FindMeStat (libax_proton)
     * + AX_IVPS_* (libax_ivps). Our capture uses raw ioctls for everything else;
     * this initializes libax_sys's userspace CMM/pool state for the encoder. It
     * coexists with the raw allocator below (device-verified: real H.264 out). */
    if (AX_SYS_Init() != 0)
        fprintf(stderr, "[openkvm][WARN] AX_SYS_Init failed (encoder may not init)\n");
    else
        c->sysInit = AX_TRUE;   /* set now so a failed init still deinits it */

    S.fo  = open("/dev/ax_os_mem",  O_RDWR);
    S.fs  = open("/dev/ax_sys",     O_RDWR);
    S.fc  = open("/dev/ax_cmm",     O_RDWR);
    S.fp  = open("/dev/ax_pool",    O_RDWR);
    S.fm  = open("/dev/ax_mipi_rx", O_RDWR);
    S.fpr = open("/dev/ax_proton",  O_RDWR);
    S.fmem = open("/dev/mem", O_RDWR);
    if (S.fo < 0 || S.fs < 0 || S.fc < 0 || S.fp < 0 || S.fm < 0 || S.fpr < 0 || S.fmem < 0) {
        fprintf(stderr, "[openkvm][FAIL] open /dev/ax_* (need root, vendor .ko loaded)\n");
        return -1;
    }

    /* allocator: descriptor first two words = {w,h}; kernel returns phys in place */
    struct __attribute__((packed)) { uint64_t p; uint8_t f; } a1;
    static uint32_t desc[64];
    memset(desc, 0, sizeof desc);
    desc[0] = S.g.osmem_desc[0]; desc[1] = S.g.osmem_desc[1];
    a1.p = (uint64_t)(uintptr_t)desc; a1.f = OSMEM_ALLOC_FLAG;
    if (ioctl(S.fo, OSMEM_NR1, &a1) != 0) { fprintf(stderr, "[openkvm][FAIL] os_mem nr1\n"); return -1; }
    S.osmem_phys = a1.p;
    /* Priming side-effect only (reproduces the vendor allocator handshake): we
     * map the returned page so the kernel-side allocator state is established,
     * but never read/write it -- kept mapped for the capture lifetime. */
    S.osmem_map = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, S.fmem, (off_t)a1.p);
    if (S.osmem_map == MAP_FAILED) S.osmem_map = NULL;

    uint32_t sv[2] = { 0x016e3600u, 0 };
    if (ioctl(S.fs, SYS_NR45, sv) != 0) { fprintf(stderr, "[openkvm][FAIL] sys nr45\n"); return -1; }

    /* AX_POOL_SetConfig floorplan: one common pool, MetaSize/BlkSize/BlkCnt/name */
    unsigned char *fp = aligned_alloc(4096, 4096);
    if (!fp) return -1;
    memset(fp, 0, 4096);
    *(uint64_t *)(fp + 0x28) = KVM_POOL_METASIZE;    /* MetaSize */
    *(uint64_t *)(fp + 0x30) = S.g.blk_size;         /* BlkSize  */
    *(uint32_t *)(fp + 0x38) = KVM_POOL_BLKCNT_OPEN; /* BlkCnt   */
    strcpy((char *)(fp + 0x44), "anonymous");
    int rc22 = ioctl(S.fp, POOL_NR22, fp);
    free(fp);
    if (rc22 != 0) { fprintf(stderr, "[openkvm][FAIL] pool nr22 (SetConfig) rc=%d\n", rc22); return -1; }
    if (ioctl(S.fp, POOL_NR20, NULL) != 0) { fprintf(stderr, "[openkvm][FAIL] pool nr20 (Init)\n"); return -1; }
    c->poolInit = AX_TRUE;

    if (find_cmm_block("comm_pool_0", &S.pool_base) != 0)
        fprintf(stderr, "[openkvm][WARN] comm_pool_0 not in /proc yet; will retry at first frame\n");
    fprintf(stderr, "[openkvm] SYS+pool up: %dx%d stride=%d blk=%u B x %d, "
                    "pool_base=0x%llx (blob-free)\n",
            S.g.w, S.g.h, S.g.stride, S.g.blk_size, KVM_POOL_BLKCNT_OPEN,
            (unsigned long long)S.pool_base);
    return 0;
}

void kvm_sys_deinit(kvm_cap_ctx *c)
{
    /* Best-effort pool/SYS release. Closing the char-device fds drops the
     * kernel-side references our process holds. */
    if (c->poolInit) { if (S.fp >= 0) ioctl(S.fp, POOL_NR21, NULL); c->poolInit = AX_FALSE; }
    if (S.osmem_map) { munmap(S.osmem_map, 4096); S.osmem_map = NULL; }
    int *fds[] = { &S.fpr, &S.fm, &S.fp, &S.fc, &S.fs, &S.fo, &S.fmem };
    for (unsigned i = 0; i < sizeof(fds)/sizeof(fds[0]); i++)
        if (*fds[i] >= 0) { close(*fds[i]); *fds[i] = -1; }
    if (c->sysInit) { AX_SYS_Deinit(); c->sysInit = AX_FALSE; }
}

/* ============================ capture bring-up ============================ */
int kvm_cap_start(kvm_cap_ctx *c, int w, int h, int fps)
{
    /* The payloads were built by kvm_sys_init for ITS {w,h}; a caller that asks
     * kvm_cap_start for a different geometry would get a pipe configured for
     * one resolution and a pool sized for another. libkvm.c always passes the
     * same pair to both, so a mismatch is a bug -- fail loudly instead. */
    if (!S.g.w || w != S.g.w || h != S.g.h) {
        fprintf(stderr, "[openkvm][FAIL] cap_start %dx%d != sys_init geometry %dx%d\n",
                w, h, S.g.w, S.g.h);
        return -1;
    }
    c->w = w; c->h = h; c->fps = fps;

    /* --- global init: mipi/cmm/proton context (vendor order) --- */
    if (ioctl(S.fm, MIPI_NR0, NULL) != 0) { fprintf(stderr, "[openkvm][FAIL] mipi nr0 Init\n"); return -1; }
    c->mipiInit = AX_TRUE;
    if (cmm_call(CMM_NR10, f_n10a, "cmm nr10 #1")) return -1;
    if (cmm_call(CMM_NR10, f_n10b, "cmm nr10 #2")) return -1;
    { uint32_t v[2] = {3,3}; if (io_pl(S.fpr, PR(0), v, sizeof v, "proton nr0 {3,3}")) return -1; }
    c->vinInit = AX_TRUE;
    if (cmm_call(CMM_NR17, f_n17, "cmm nr17")) return -1;
    /* The isp_model_manger_list CMM carveout (nr0/nr6) is a persistent named
     * block our teardown does not free (no CMM-free selector is mapped yet), so
     * on in-process re-init it returns EPERM "already allocated". The existing
     * block stays valid for reuse, so tolerate EPERM here. */
    /* isp_model_manger_list block: REUSE-before-allocate (#16). Our teardown
     * cannot free it (no CMM-free selector is mapped), and cross-session the
     * kernel does NOT EPERM a duplicate cmm nr0 -- it allocates ANOTHER 4 KB
     * block (observed on device: a stale block from a dead process plus a
     * fresh one). So: if a block already exists, adopt its phys and skip the
     * alloc -- this is the same reuse the original EPERM tolerance relied on,
     * and it caps the leak at one persistent block per boot. Only when none
     * exists do we allocate, then re-derive the real phys from /proc instead
     * of trusting the captured carveout-layout constant. */
    S.isp_model_phys = 0;
    if (find_cmm_block("isp_model_manger_list", &S.isp_model_phys) == 0
        && S.isp_model_phys >= CMM_CARVEOUT_BASE && S.isp_model_phys < CMM_CARVEOUT_END) {
        fprintf(stderr, "[openkvm] isp_model block reused @0x%llx\n",
                (unsigned long long)S.isp_model_phys);
    } else {
        int e = cmm_call(CMM_NR0, f_n0, "cmm nr0");
        if (e && e != EPERM) return -1;
        S.isp_model_phys = 0;
        if (find_cmm_block("isp_model_manger_list", &S.isp_model_phys) != 0
            || S.isp_model_phys < CMM_CARVEOUT_BASE || S.isp_model_phys >= CMM_CARVEOUT_END) {
            fprintf(stderr, "[openkvm][WARN] isp_model_manger_list not found/sane "
                            "in mem_cmm_info (got 0x%llx); falling back to captured 0x%llx\n",
                    (unsigned long long)S.isp_model_phys, (unsigned long long)ISP_MODEL_PHYS);
            S.isp_model_phys = ISP_MODEL_PHYS;
        } else {
            fprintf(stderr, "[openkvm] isp_model block allocated @0x%llx%s\n",
                    (unsigned long long)S.isp_model_phys,
                    S.isp_model_phys == ISP_MODEL_PHYS ? " (matches captured constant)" : "");
        }
    }
    { int e = cmm_call(CMM_NR6, f_n6, "cmm nr6");
      if (e == EPERM)
          fprintf(stderr, "[openkvm] (cmm nr6 EPERM tolerated: block already attached)\n");
      else if (e) return -1; }
    { uint64_t p = S.isp_model_phys; if (io_pl(S.fpr, PR(138), &p, sizeof p, "proton nr138")) return -1; }
    { unsigned char nr12[sizeof PL_nr12];
      memcpy(nr12, PL_nr12, sizeof nr12);
      memcpy(nr12, &S.isp_model_phys, 8);   /* [0..7] = block phys, LE */
      if (io_pl(S.fpr, PR(12), nr12, sizeof nr12, "proton nr12 VIN_Init")) return -1; }
    if (IO_PL(S.fpr, PR(2),  PL_nr2p, "proton nr2 global"))    return -1;

    /* --- MIPI-RX PHY bring-up (real 4-lane attr; Stage-5 proven, no hang) --- */
    { uint32_t z = 0; if (io_pl(S.fm, MIPI_NR8, &z, 4, "mipi nr8 lanecombo")) return -1; }
    if (IO_PL(S.fm, MIPI_NR2, PL_mipi_attr, "mipi nr2 SetAttr")) return -1;
    { uint32_t z = 0; if (io_pl(S.fm, MIPI_NR4, &z, 4, "mipi nr4 Reset")) return -1; }
    { uint32_t z = 0; if (io_pl(S.fm, MIPI_NR6, &z, 4, "mipi nr6 Start")) return -1; }
    c->mipiStarted = AX_TRUE;

    /* --- VIN device layer --- */
    if (IO_PL(S.fpr, PR(17), S.g.dev_attr, "proton nr17 CreateDev")) return -1;
    c->devCreated = AX_TRUE;
    if (IO_PL(S.fpr, PR(21), S.g.dev_attr, "proton nr21 SetDevAttr")) return -1;
    if (IO_PL(S.fpr, PR(30), PL_nr30,  "proton nr30 BindPipe")) return -1;
    if (IO_PL(S.fpr, PR(22), PL_nr22p, "proton nr22 BindMipi")) return -1;
    if (IO_PL(S.fpr, PR(21), S.g.dev_attr2, "proton nr21 SetDevAttr#2")) return -1;

    /* --- VIN pipe / ISP-bypass cfg / channel / stream --- */
    if (IO_PL(S.fpr, PR(35), S.g.pipe_create, "proton nr35 CreatePipe")) return -1;
    c->pipeCreated = AX_TRUE;
    if (IO_PL(S.fpr, PR(42), S.g.pipe_attr, "proton nr42 SetPipeAttr")) return -1;
    /* ISP-bypass datapath config -- REQUIRED: skipping these => rc=0 but the SoC
     * hard-hangs when DMA engages (Stage 6). */
    if (IO_PL(S.fpr, PR(56), PL_nr56, "proton nr56 black_level"))   return -1;
    if (IO_PL(S.fpr, PR(74), PL_nr74, "proton nr74 scene_attr"))    return -1;
    if (IO_PL(S.fpr, PR(54), PL_nr54, "proton nr54 partition"))     return -1;
    if (IO_PL(S.fpr, PR(89), PL_nr89, "proton nr89 npu_throttle"))  return -1;
    if (IO_PL(S.fpr, PR(48), S.g.chn_attr, "proton nr48 SetChnAttr")) return -1;
    if (IO_PL(S.fpr, PR(55), PL_nr55, "proton nr55 EnableChn")) return -1;
    c->chnEnabled = AX_TRUE;
    { uint8_t z = 0; if (io_pl(S.fpr, PR(38), &z, 1, "proton nr38 pipe_open")) return -1; }
    { uint8_t z = 0; if (io_pl(S.fpr, PR(40), &z, 1, "proton nr40 StartPipe")) return -1; }
    c->pipeStarted = AX_TRUE;
    { uint8_t z = 0; if (io_pl(S.fpr, PR(19), &z, 1, "proton nr19 EnableDev")) return -1; }
    c->devEnabled = AX_TRUE;
    c->streamOn = AX_TRUE;

    /* Re-derive the pool base on EVERY start: a suspend/resume cycle can
     * re-create the pool at a different phys, and a stale base silently
     * shifts every frame we hand the encoder. */
    { uint64_t nb = 0;
      if (find_cmm_block("comm_pool_0", &nb) == 0 && nb) {
          if (S.pool_base && nb != S.pool_base)
              fprintf(stderr, "[openkvm] comm_pool_0 moved 0x%llx -> 0x%llx\n",
                      (unsigned long long)S.pool_base, (unsigned long long)nb);
          S.pool_base = nb;
      } }
    S.phys_logged = 0;
    S.started = 1;
    fprintf(stderr, "[openkvm] capture up %dx%d (blob-free, pool_base=0x%llx)\n",
            w, h, (unsigned long long)S.pool_base);
    return 0;
}

/* Teardown, reconstructed from the vendor selector order in mv5.log with
 * pointer-free id-scalar args. Each selector's rc is tallied and summarized
 * (io_pl still logs individual failures). DEVICE-VALIDATED 2026-08-16: three
 * warm suspend/resume cycles ran this back-to-back with zero selector
 * failures and clean re-init each time (see the file header). A wrong
 * teardown still cannot poison a fresh process (fds close in
 * kvm_sys_deinit). */
void kvm_cap_stop(kvm_cap_ctx *c)
{
    uint8_t id = 0; uint32_t z = 0;
    int fails = 0;
    if (c->devEnabled)  { fails += !!io_pl(S.fpr, PR(20), &id, 1, "nr20 DisableDev"); c->devEnabled = AX_FALSE; }
    if (c->pipeStarted) { fails += !!io_pl(S.fpr, PR(41), &id, 1, "nr41 StopPipe");
                          fails += !!io_pl(S.fpr, PR(39), &id, 1, "nr39 StopPipe"); c->pipeStarted = AX_FALSE; }
    if (c->chnEnabled)  { fails += !!io_pl(S.fpr, PR(55), &id, 1, "nr55 DisableChn"); c->chnEnabled = AX_FALSE; }
    if (c->pipeCreated) { fails += !!io_pl(S.fpr, PR(36), &id, 1, "nr36 DestroyPipe"); c->pipeCreated = AX_FALSE; }
    if (c->devCreated)  { fails += !!io_pl(S.fpr, PR(18), &id, 1, "nr18 DestroyDev"); c->devCreated = AX_FALSE; }
    if (c->mipiStarted) { fails += !!io_pl(S.fm, MIPI_NR7, &z, 4, "mipi nr7 Stop"); c->mipiStarted = AX_FALSE; }
    if (c->mipiInit)    { fails += !!ioctl(S.fm, MIPI_NR1, NULL); c->mipiInit = AX_FALSE; }
    c->streamOn = AX_FALSE; c->vinInit = AX_FALSE;
    S.started = 0; S.have_frame = 0;
    fprintf(stderr, "[openkvm] capture teardown: %d selector failure%s\n",
            fails, fails == 1 ? "" : "s");
}

/* ============================ frame dequeue ============================ */
int kvm_cap_get(AX_IMG_INFO_T *img, int timeout_ms)
{
    memset(img, 0, sizeof(*img));
    if (!S.started) return -1;
    if (!S.pool_base && find_cmm_block("comm_pool_0", &S.pool_base) != 0) {
        fprintf(stderr, "[openkvm][FAIL] no comm_pool_0 base\n");
        return -1;
    }

    unsigned char *desc = aligned_alloc(4096, 4096);
    if (!desc) return -1;
    int attempts = timeout_ms > 0 ? (timeout_ms / 5 + 1) : 1;
    uint32_t handle = 0;
    for (int i = 0; i < attempts; i++) {
        memset(desc, 0, 4096);
        memcpy(desc, PL_nr101, sizeof PL_nr101);
        errno = 0;
        if (ioctl(S.fpr, PR(101), desc) == 0) {
            handle = *(uint32_t *)(desc + FRAME_HANDLE_OFF);
            if (handle) break;
        }
        usleep(5000);
    }
    if (!handle) { free(desc); return -1; }

    memcpy(S.last_desc, desc, sizeof S.last_desc);
    S.have_frame = 1;
    free(desc);

    int blkidx = handle & 0xff;
    if (blkidx >= KVM_POOL_BLKCNT_OPEN) {   /* stray handle -> would point outside the pool */
        fprintf(stderr, "[openkvm][FAIL] frame block idx %d >= pool blks %d (handle 0x%x)\n",
                blkidx, KVM_POOL_BLKCNT_OPEN, handle);
        /* nr101 DID dequeue this frame -- return the block or repeated stray
         * handles starve the 4-block pool (#16). last_desc/have_frame were
         * just set, so the normal release path applies. */
        kvm_cap_release(img);
        return -1;
    }
    /* Block phys. LAYOUT (device-verified 2026-08-17 by dumping the live pool
     * region over /dev/mem): comm_pool_0 = [BlkCnt x MetaSize meta pages]
     * [blk0][blk1]... with each data block at a PAGE-ALIGNED pitch. The old
     * base + idx*BlkSize formula pointed 16384+2048*idx bytes BEFORE the real
     * frame, so the encoder swallowed the zeroed meta pages as the first ~4
     * lines (the green top bar) and each block index landed at a different
     * horizontal phase (the fast apparent scrolling). Prefer the documented
     * AX_POOL_Handle2PhysAddr (libax_sys is linked for the encoder anyway);
     * fall back to the measured layout if the API doesn't know a pool that
     * was configured via raw ioctl. */
    uint64_t derived = S.pool_base
                     + (uint64_t)KVM_POOL_METASIZE * KVM_POOL_BLKCNT_OPEN
                     + (uint64_t)blkidx * S.g.blk_pitch;
    uint64_t api = AX_POOL_Handle2PhysAddr((AX_BLK)handle);
    uint64_t phys = (api >= S.pool_base && api + S.g.blk_size <= S.pool_base + S.g.pool_span)
                  ? api : derived;
    if (!S.phys_logged) {
        S.phys_logged = 1;
        fprintf(stderr, "[openkvm] frame phys: api=0x%llx derived=0x%llx -> using %s (blk %d)\n",
                (unsigned long long)api, (unsigned long long)derived,
                phys == api ? "api" : "derived", blkidx);
    }

    AX_VIDEO_FRAME_T *f = &img->tFrameInfo.stVFrame;
    f->u32Width      = (AX_U32)S.g.w;
    f->u32Height     = (AX_U32)S.g.h;
    f->enImgFormat   = AX_FORMAT_YUV422_INTERLEAVED_YUYV;  /* 0x0D, VIN bypass out */
    /* Stride in PIXELS, the same value the VIN chn attr was programmed with
     * (== width at 1080p and at every 16-px-aligned width). CONFIRMED on
     * device at 1080p: the encoder accepts it and the decoded H.264 is a
     * correctly-proportioned frame (not sheared/half-width). */
    f->u32PicStride[0] = (AX_U32)S.g.stride;
    f->u64PhyAddr[0]   = phys;
    f->u32BlkId[0]     = handle;
    f->u32FrameSize    = S.g.blk_size;
    img->tFrameInfo.enModId = AX_ID_VIN;
    return 0;
}

void kvm_cap_release(AX_IMG_INFO_T *img)
{
    (void)img;
    if (!S.have_frame) return;
    /* AX_VIN_ReleaseYuvFrame == proton nr104, fed the descriptor GetYuvFrame
     * returned (carries the block handle it must return to the pool). */
    unsigned char *b = aligned_alloc(4096, 4096);
    if (b) { memset(b, 0, 4096); memcpy(b, S.last_desc, sizeof S.last_desc);
             ioctl(S.fpr, PR(104), b); free(b); }
    S.have_frame = 0;
}

#endif /* KVM_OPEN_CAPTURE */
