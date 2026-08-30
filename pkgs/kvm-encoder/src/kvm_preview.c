/*
 * kvm_preview.c -- mini-display live-preview side channel (see kvm_preview.h).
 *
 * Design constraints, in order:
 *  - Fed from the frames libkvm already holds -- NEVER a second capture
 *    pipeline (docs/mini-display.md, "Coexistence with the web KVM").
 *  - Zero work in the encode path unless a preview lease is active, and
 *    bounded work (rate-limited, ~12 fps) while it is.
 *  - The consumer is a pure-stdlib Python daemon, so all pixel work happens
 *    here: output is the panel's native fb byte layout (172x320 portrait,
 *    RGB565-LE, stride 344 = 172*2), pre-rotated with the verified mapping
 *    fb[319-x][y] = landscape (x,y), letterboxed to preserve aspect.
 *
 * Delivery is atomic-by-rename: write /dev/shm/nanokvm-preview.tmp, then
 * rename(2) over /dev/shm/nanokvm-preview. A reader that opens the old inode
 * sees a complete old frame; there is no shared-memory tearing to manage.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>

#include "ax_base_type.h"
#include "ax_global_type.h"
#include "ax_sys_api.h"
#include "kvm_preview.h"

#define PV_PATH      "/dev/shm/nanokvm-preview"
#define PV_TMP       "/dev/shm/nanokvm-preview.tmp"
#define PV_MAGIC     0x56504B4Eu   /* "NKPV" little-endian */
#define PV_VERSION   1u
#define PV_FB_W      172
#define PV_FB_H      320
#define PV_PIXELS    (PV_FB_W * PV_FB_H)
#define PV_MIN_US    80000         /* publish at most every 80 ms (~12 fps) */
#define PV_NOPX      0xFFFFFFFFu   /* scaler-table entry: letterbox black */

struct pv_hdr {
    uint32_t magic;
    uint32_t version;
    uint32_t seq;
    uint16_t fb_w, fb_h;      /* payload geometry: 172 x 320 portrait */
    uint16_t src_w, src_h;    /* live source geometry the frame came from */
    uint64_t mono_us;         /* CLOCK_MONOTONIC at publish (staleness check) */
    uint32_t payload_len;     /* PV_PIXELS * 2 */
} __attribute__((packed));

/* One buffer, one write(2): header + payload. */
static struct {
    struct pv_hdr hdr;
    uint16_t px[PV_PIXELS];
} __attribute__((packed)) s_buf;

static int64_t  s_last_pub_us = 0;

/* scaler table: fb linear index -> source pixel index (sy*stride_px + sx),
 * or PV_NOPX for the letterbox bars. Rebuilt when the geometry changes. */
static uint32_t s_tab[PV_PIXELS];
static uint32_t s_tab_w = 0, s_tab_h = 0, s_tab_stride = 0;
static int      s_tab_ok = 0;

/* phys->virt cache for the (few) pool blocks frames arrive in. devmem is the
 * fallback if AX_SYS_Mmap declines (both routes are proven on this pool:
 * AX_SYS_Mmap is the documented API, /dev/mem is the Stage-6 route). */
static struct { uint64_t phys; uint32_t size; void *virt; int devmem; size_t maplen; } s_map[8];
static int s_devmem_fd = -1;

static int64_t mono_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void *map_phys(uint64_t phys, uint32_t size)
{
    for (unsigned i = 0; i < sizeof(s_map)/sizeof(s_map[0]); i++)
        if (s_map[i].virt && s_map[i].phys == phys && s_map[i].size >= size)
            return s_map[i].virt;

    unsigned slot;
    for (slot = 0; slot < sizeof(s_map)/sizeof(s_map[0]); slot++)
        if (!s_map[slot].virt) break;
    if (slot == sizeof(s_map)/sizeof(s_map[0])) return NULL;  /* reset() clears */

#ifndef KVM_OPEN_VENC   /* fully-open build links no libax_sys: devmem only */
    void *v = AX_SYS_Mmap(phys, size);
    if (v) {
        s_map[slot] = (typeof(s_map[0])){ phys, size, v, 0, 0 };
        return v;
    }
#endif

    if (s_devmem_fd < 0) s_devmem_fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (s_devmem_fd < 0) return NULL;
    uint64_t pa = phys & ~4095ULL;
    size_t   off = (size_t)(phys - pa), len = (size_t)size + off;
    void *m = mmap(NULL, len, PROT_READ, MAP_SHARED, s_devmem_fd, (off_t)pa);
    if (m == MAP_FAILED) return NULL;
    s_map[slot] = (typeof(s_map[0])){ phys, size, (uint8_t *)m + off, 1, len };
    return s_map[slot].virt;
}

const void *kvm_frame_map(uint64_t phys, uint32_t size)
{
    return map_phys(phys, size);
}

void kvm_preview_reset(void)
{
    for (unsigned i = 0; i < sizeof(s_map)/sizeof(s_map[0]); i++) {
        if (!s_map[i].virt) continue;
        if (s_map[i].devmem)
            munmap((void *)((uintptr_t)s_map[i].virt & ~4095UL), s_map[i].maplen);
#ifndef KVM_OPEN_VENC
        else
            AX_SYS_Munmap(s_map[i].virt, s_map[i].size);
#endif
        s_map[i].virt = NULL;
    }
    s_tab_ok = 0;
}

/* Build the fb-index -> source-pixel table: letterbox-fit (sw,sh) into the
 * 320x172 landscape face, then fold in the panel rotation. */
static void build_tab(uint32_t sw, uint32_t sh, uint32_t stride_px, uint32_t fsz)
{
    s_tab_w = sw; s_tab_h = sh; s_tab_stride = stride_px; s_tab_ok = 0;

    uint32_t dw, dh;                       /* scaled source on the 320x172 face */
    if ((uint64_t)PV_FB_H * sh <= (uint64_t)PV_FB_W * sw) {  /* width-limited */
        dw = PV_FB_H; dh = (uint32_t)((uint64_t)sh * PV_FB_H / sw);
        if (dh == 0) dh = 1;
        if (dh > PV_FB_W) dh = PV_FB_W;
    } else {
        dh = PV_FB_W; dw = (uint32_t)((uint64_t)sw * PV_FB_W / sh);
        if (dw == 0) dw = 1;
        if (dw > PV_FB_H) dw = PV_FB_H;
    }
    uint32_t x0 = (PV_FB_H - dw) / 2, y0 = (PV_FB_W - dh) / 2;

    for (uint32_t r = 0; r < PV_FB_H; r++) {          /* fb row    */
        uint32_t x = PV_FB_H - 1 - r;                 /* landscape x */
        for (uint32_t c = 0; c < PV_FB_W; c++) {      /* fb col == landscape y */
            uint32_t i = r * PV_FB_W + c;
            if (x < x0 || x >= x0 + dw || c < y0 || c >= y0 + dh) {
                s_tab[i] = PV_NOPX;
                continue;
            }
            uint32_t sx = (uint32_t)((uint64_t)(x - x0) * sw / dw);
            uint32_t sy = (uint32_t)((uint64_t)(c - y0) * sh / dh);
            if (sx >= sw) sx = sw - 1;
            if (sy >= sh) sy = sh - 1;
            s_tab[i] = sy * stride_px + sx;
        }
    }

    /* The worst-case macropixel read must stay inside the frame buffer. */
    uint32_t max_t = (sh - 1) * stride_px + (sw - 1);
    if (fsz && ((uint64_t)(max_t >> 1) * 4 + 4) > fsz) {
        fprintf(stderr, "OPEN-KVM preview: geometry %ux%u stride %u exceeds "
                        "frame size %u -- preview disabled for this mode\n",
                sw, sh, stride_px, fsz);
        return;                                       /* s_tab_ok stays 0 */
    }
    s_tab_ok = 1;
}

void kvm_preview_publish(const AX_VIDEO_FRAME_T *vf)
{
    int64_t now = mono_us();
    if (now - s_last_pub_us < PV_MIN_US) return;

    uint32_t sw = vf->u32Width, sh = vf->u32Height;
    uint32_t stride_px = vf->u32PicStride[0] ? vf->u32PicStride[0] : sw;
    if (!sw || !sh) return;
    if (stride_px & 1) stride_px = sw;    /* YUYV macropixels need even stride */
    uint32_t fsz = vf->u32FrameSize ? vf->u32FrameSize : stride_px * 2 * sh;

    const uint8_t *src = (const uint8_t *)(uintptr_t)vf->u64VirAddr[0];
    if (!src) src = map_phys(vf->u64PhyAddr[0], fsz);
    if (!src) return;

    if (!s_tab_ok || s_tab_w != sw || s_tab_h != sh || s_tab_stride != stride_px)
        build_tab(sw, sh, stride_px, fsz);
    if (!s_tab_ok) return;

    for (uint32_t i = 0; i < PV_PIXELS; i++) {
        uint32_t t = s_tab[i];
        if (t == PV_NOPX) { s_buf.px[i] = 0; continue; }
        const uint8_t *p = src + (uint64_t)(t >> 1) * 4;   /* YUYV macropixel */
        int y = p[(t & 1) ? 2 : 0], u = p[1], v = p[3];
        int c298 = 298 * (y - 16);
        int r = (c298 + 409 * (v - 128) + 128) >> 8;
        int g = (c298 - 100 * (u - 128) - 208 * (v - 128) + 128) >> 8;
        int b = (c298 + 516 * (u - 128) + 128) >> 8;
        if (r < 0) r = 0; else if (r > 255) r = 255;
        if (g < 0) g = 0; else if (g > 255) g = 255;
        if (b < 0) b = 0; else if (b > 255) b = 255;
        s_buf.px[i] = (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
    }

    s_buf.hdr.magic = PV_MAGIC;
    s_buf.hdr.version = PV_VERSION;
    s_buf.hdr.seq++;
    s_buf.hdr.fb_w = PV_FB_W;  s_buf.hdr.fb_h = PV_FB_H;
    s_buf.hdr.src_w = (uint16_t)sw;  s_buf.hdr.src_h = (uint16_t)sh;
    s_buf.hdr.mono_us = (uint64_t)now;
    s_buf.hdr.payload_len = PV_PIXELS * 2;

    int fd = open(PV_TMP, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    ssize_t wr = write(fd, &s_buf, sizeof(s_buf));
    close(fd);
    if (wr != (ssize_t)sizeof(s_buf)) { unlink(PV_TMP); return; }
    if (rename(PV_TMP, PV_PATH) != 0) { unlink(PV_TMP); return; }

    s_last_pub_us = now;
}
