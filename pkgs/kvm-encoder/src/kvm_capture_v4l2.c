/*
 * kvm_capture_v4l2.c -- capture backend over the open V4L2 driver
 * (pkgs/open-vin-capture -> /dev/videoN, driver "open_vin_capture").
 * Epic #55 / issue #60 (M3).
 *
 * Replaced the raw-ioctl replay of the vendor ax_proton path with plain
 * V4L2:
 *
 *   S_FMT(YUYV, WxH) -> REQBUFS(MMAP) -> QUERYBUF+mmap -> EXPBUF
 *   -> QBUF all -> STREAMON -> poll+DQBUF ... QBUF (release)
 *
 * The open encoder is zero-copy: the capture buffer's bus address becomes
 * the VC8000E input (swreg12). Userspace cannot learn a vb2 buffer's bus
 * address from V4L2 alone, so each buffer's dma-buf (VIDIOC_EXPBUF) is
 * imported once through our open VCMD driver (HANTRO_IOCH_IMPORT_DMABUF),
 * which resolves it to the address and keeps the import for the life of
 * this backend's /dev/es_venc file. The CPU view for the soft-JPEG MJPEG
 * path and the mini-display preview is the ordinary V4L2 mmap, so no
 * /dev/mem window is needed either.
 *
 * Nothing vendor-specific is involved: no vendor module, library, ioctl or
 * payload -- and since #102 no vendor header either. Frames leave here as
 * our own kvm_frame (kvm_types.h), which is what libkvm.c, kvm_venc_open.c
 * and kvm_preview.c exchange.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>

#include "kvm_pipeline.h"
#include "vcmd_abi.h"       /* VCMD_DEV_NODE + HANTRO_IOCH_IMPORT_DMABUF */

/* THE TWO REAL ABIs THIS FILE SPEAKS, asserted against kvm_frame (#102).
 * kvm_frame's layout is ours and crosses no boundary, but every field here
 * carries a UAPI value out of this translation unit and must not truncate
 * it: v4l2_pix_format's geometry/bytesperline/sizeimage and
 * v4l2_buffer.sequence are __u32, and the open VC8000E driver's dma-buf
 * import (drivers/media/platform/axera/vc8000e/framebuf_alloc.h, mirrored in
 * vcmd_abi.h) hands back an `unsigned long` bus address. */
_Static_assert(sizeof(((struct v4l2_pix_format *)0)->width)
               <= sizeof(((kvm_frame *)0)->width), "kvm_frame.width narrower than V4L2's");
_Static_assert(sizeof(((struct v4l2_pix_format *)0)->height)
               <= sizeof(((kvm_frame *)0)->height), "kvm_frame.height narrower than V4L2's");
_Static_assert(sizeof(((struct v4l2_pix_format *)0)->bytesperline)
               <= sizeof(((kvm_frame *)0)->stride_px), "kvm_frame.stride_px narrower than V4L2's");
_Static_assert(sizeof(((struct v4l2_pix_format *)0)->sizeimage)
               <= sizeof(((kvm_frame *)0)->size), "kvm_frame.size narrower than V4L2's");
_Static_assert(sizeof(((struct v4l2_buffer *)0)->sequence)
               <= sizeof(((kvm_frame *)0)->seq), "kvm_frame.seq narrower than V4L2's");
_Static_assert(sizeof(((struct dmabuf_import_parameter *)0)->bus_addr)
               <= sizeof(((kvm_frame *)0)->bus), "kvm_frame.bus narrower than the VCMD driver's");

#define V4L2_DRIVER_NAME "open_vin_capture"
#define V4L2_NBUF        4         /* 3 in flight + the one being encoded */
#define V4L2_MIN_W       64
#define V4L2_MIN_H       64
/* The capture envelope, and it must match open_vin_capture's OVC_MAX_* --
 * the driver CLAMPS an out-of-range format instead of refusing it, so a
 * mismatch shows up as "driver negotiated WxH, wanted W'xH'" below rather
 * than as a clean rejection here. 4096x2400 (#98): the bench host emits DCI
 * 4K and the 16:10 EDID (#61) advertises 3840x2400. */
#define V4L2_MAX_W       4096
#define V4L2_MAX_H       2400

static struct {
    int vfd;                       /* /dev/videoN, -1 when closed */
    int efd;                       /* /dev/es_venc for dma-buf imports, -1 */
    char node[32];
    int w, h;                      /* negotiated geometry */
    uint32_t stride_px, sizeimage;
    unsigned nbuf;
    struct {
        void    *map;
        size_t   len;
        int      dmabuf;           /* EXPBUF fd, -1 */
        uint64_t bus;              /* imported bus address, 0 = none */
    } b[V4L2_NBUF];
    int streaming;
    int dq;                        /* index of the frame handed out, -1 */
    int logged;
} S = { .vfd = -1, .efd = -1, .dq = -1 };

static const char *es(int e) { return e ? strerror(e) : "ok"; }

/* The envelope, published so libkvm.c can name it in a user-visible error
 * before it tries to bring anything up (#98). */
void kvm_cap_envelope(int *max_w, int *max_h)
{
    if (max_w) *max_w = V4L2_MAX_W;
    if (max_h) *max_h = V4L2_MAX_H;
}

int kvm_cap_geom_ok(int w, int h)
{
    return w >= V4L2_MIN_W && h >= V4L2_MIN_H &&
           w <= V4L2_MAX_W && h <= V4L2_MAX_H && !((w | h) & 1);
}

/* Find the open capture node by driver name (env OPENKVM_V4L2_DEV overrides). */
static int open_node(void)
{
    const char *force = getenv("OPENKVM_V4L2_DEV");
    for (int i = 0; i < 16; i++) {
        char path[32];
        if (force) snprintf(path, sizeof path, "%s", force);
        else       snprintf(path, sizeof path, "/dev/video%d", i);
        int fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd < 0) { if (force) break; continue; }
        struct v4l2_capability cap;
        memset(&cap, 0, sizeof cap);
        if (ioctl(fd, VIDIOC_QUERYCAP, &cap) == 0 &&
            /* cap.driver is 16 bytes: the kernel truncates our 16-char name */
            (force || strncmp((const char *)cap.driver, V4L2_DRIVER_NAME,
                              sizeof(cap.driver) - 1) == 0) &&
            (cap.device_caps & V4L2_CAP_VIDEO_CAPTURE) &&
            (cap.device_caps & V4L2_CAP_STREAMING)) {
            snprintf(S.node, sizeof S.node, "%s", path);
            return fd;
        }
        close(fd);
        if (force) break;
    }
    return -1;
}

static void unmap_all(void)
{
    for (unsigned i = 0; i < V4L2_NBUF; i++) {
        if (S.b[i].map) { munmap(S.b[i].map, S.b[i].len); S.b[i].map = NULL; }
        if (S.b[i].dmabuf >= 0) { close(S.b[i].dmabuf); }
        S.b[i].dmabuf = -1;
        S.b[i].bus = 0;
    }
    S.nbuf = 0;
}

int kvm_sys_init(kvm_cap_ctx *c, int w, int h)
{
    memset(c, 0, sizeof(*c));
    memset(&S, 0, sizeof S);
    S.vfd = S.efd = -1; S.dq = -1;
    for (unsigned i = 0; i < V4L2_NBUF; i++) S.b[i].dmabuf = -1;

    if (w <= 0 || h <= 0) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] no source geometry (%dx%d)\n", w, h);
        return -1;
    }
    if ((w | h) & 1) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] odd geometry %dx%d (YUYV macropixel is 2 px)\n", w, h);
        return -1;
    }
    if (w < V4L2_MIN_W || h < V4L2_MIN_H || w > V4L2_MAX_W || h > V4L2_MAX_H) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] %dx%d outside %dx%d..%dx%d\n",
                w, h, V4L2_MIN_W, V4L2_MIN_H, V4L2_MAX_W, V4L2_MAX_H);
        return -1;
    }

    S.vfd = open_node();
    if (S.vfd < 0) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] no V4L2 node with driver \"%s\" "
                        "(is open_vin_capture.ko loaded?)\n", V4L2_DRIVER_NAME);
        return -1;
    }

    struct v4l2_format f;
    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    f.fmt.pix.width = (uint32_t)w;
    f.fmt.pix.height = (uint32_t)h;
    f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    f.fmt.pix.field = V4L2_FIELD_NONE;
    if (ioctl(S.vfd, VIDIOC_S_FMT, &f) != 0) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] S_FMT %dx%d: %s\n", w, h, es(errno));
        close(S.vfd); S.vfd = -1;
        return -1;
    }
    if (f.fmt.pix.width != (uint32_t)w || f.fmt.pix.height != (uint32_t)h ||
        f.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] driver negotiated %ux%u fourcc %#x, wanted %dx%d YUYV\n",
                f.fmt.pix.width, f.fmt.pix.height, f.fmt.pix.pixelformat, w, h);
        close(S.vfd); S.vfd = -1;
        return -1;
    }
    S.w = w; S.h = h;
    S.stride_px = f.fmt.pix.bytesperline ? f.fmt.pix.bytesperline / 2 : (uint32_t)w;
    S.sizeimage = f.fmt.pix.sizeimage ? f.fmt.pix.sizeimage : (uint32_t)w * 2u * (uint32_t)h;
    c->w = w; c->h = h;
    c->sysInit = 1;
    return 0;
}

void kvm_sys_deinit(kvm_cap_ctx *c)
{
    (void)c;
    if (S.streaming) kvm_cap_stop(c);
    if (S.vfd >= 0) { close(S.vfd); S.vfd = -1; }
    S.w = S.h = 0;
}

int kvm_cap_start(kvm_cap_ctx *c, int w, int h, int fps)
{
    if (S.vfd < 0 || w != S.w || h != S.h) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] cap_start %dx%d != sys_init geometry %dx%d\n",
                w, h, S.w, S.h);
        return -1;
    }
    c->w = w; c->h = h; c->fps = fps;

    struct v4l2_requestbuffers rb;
    memset(&rb, 0, sizeof rb);
    rb.count = V4L2_NBUF;
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rb.memory = V4L2_MEMORY_MMAP;
    if (ioctl(S.vfd, VIDIOC_REQBUFS, &rb) != 0 || rb.count == 0) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] REQBUFS(%d): %s\n", V4L2_NBUF, es(errno));
        return -1;
    }
    S.nbuf = rb.count > V4L2_NBUF ? V4L2_NBUF : rb.count;

    /* The importer: our open VCMD driver. One file per backend instance so the
     * imports die with it (driver drops them on close). */
    S.efd = open(VCMD_DEV_NODE, O_RDWR | O_CLOEXEC);
    if (S.efd < 0) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] open %s for dma-buf import: %s\n",
                VCMD_DEV_NODE, es(errno));
        goto fail;
    }

    for (unsigned i = 0; i < S.nbuf; i++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        if (ioctl(S.vfd, VIDIOC_QUERYBUF, &b) != 0) {
            fprintf(stderr, "[openkvm-v4l2][FAIL] QUERYBUF %u: %s\n", i, es(errno));
            goto fail;
        }
        S.b[i].len = b.length;
        S.b[i].map = mmap(NULL, b.length, PROT_READ, MAP_SHARED, S.vfd, b.m.offset);
        if (S.b[i].map == MAP_FAILED) {
            S.b[i].map = NULL;
            fprintf(stderr, "[openkvm-v4l2][FAIL] mmap buffer %u: %s\n", i, es(errno));
            goto fail;
        }

        struct v4l2_exportbuffer eb;
        memset(&eb, 0, sizeof eb);
        eb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        eb.index = i;
        eb.flags = O_RDONLY | O_CLOEXEC;
        if (ioctl(S.vfd, VIDIOC_EXPBUF, &eb) != 0) {
            fprintf(stderr, "[openkvm-v4l2][FAIL] EXPBUF %u: %s\n", i, es(errno));
            goto fail;
        }
        S.b[i].dmabuf = eb.fd;

        struct dmabuf_import_parameter im;
        memset(&im, 0, sizeof im);
        im.fd = eb.fd;
        if (ioctl(S.efd, HANTRO_IOCH_IMPORT_DMABUF, &im) != 0) {
            fprintf(stderr, "[openkvm-v4l2][FAIL] dma-buf import of buffer %u: %s\n", i, es(errno));
            goto fail;
        }
        if (im.size < S.sizeimage) {
            fprintf(stderr, "[openkvm-v4l2][FAIL] buffer %u is %lu B, frame needs %u\n",
                    i, im.size, S.sizeimage);
            goto fail;
        }
        S.b[i].bus = im.bus_addr;

        if (ioctl(S.vfd, VIDIOC_QBUF, &b) != 0) {
            fprintf(stderr, "[openkvm-v4l2][FAIL] QBUF %u: %s\n", i, es(errno));
            goto fail;
        }
    }

    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (ioctl(S.vfd, VIDIOC_STREAMON, &type) != 0) {
        fprintf(stderr, "[openkvm-v4l2][FAIL] STREAMON: %s\n", es(errno));
        goto fail;
    }
    S.streaming = 1;
    c->streamOn = 1;
    if (!S.logged) {
        S.logged = 1;
        fprintf(stderr, "[openkvm-v4l2] capture up %dx%d YUYV stride=%u px via %s, %u buffers, "
                        "bus[0]=0x%llx (V4L2 + dma-buf, blob-free)\n",
                w, h, S.stride_px, S.node, S.nbuf, (unsigned long long)S.b[0].bus);
    }
    return 0;

fail:
    unmap_all();
    if (S.efd >= 0) { close(S.efd); S.efd = -1; }
    memset(&rb, 0, sizeof rb);
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rb.memory = V4L2_MEMORY_MMAP;
    ioctl(S.vfd, VIDIOC_REQBUFS, &rb);
    return -1;
}

void kvm_cap_stop(kvm_cap_ctx *c)
{
    (void)c;
    if (S.vfd < 0) return;
    if (S.streaming) {
        int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        ioctl(S.vfd, VIDIOC_STREAMOFF, &type);
        S.streaming = 0;
    }
    S.dq = -1;
    /* closing the importer file releases every import this backend made */
    if (S.efd >= 0) { close(S.efd); S.efd = -1; }
    unmap_all();
    struct v4l2_requestbuffers rb;
    memset(&rb, 0, sizeof rb);
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rb.memory = V4L2_MEMORY_MMAP;
    ioctl(S.vfd, VIDIOC_REQBUFS, &rb);
    if (c) c->streamOn = 0;
}

int kvm_cap_get(kvm_frame *f, int timeout_ms)
{
    memset(f, 0, sizeof(*f));
    if (!S.streaming) return -1;

    /* libkvm releases before it gets again; tolerate a caller that does not */
    if (S.dq >= 0) {
        struct v4l2_buffer q;
        memset(&q, 0, sizeof q);
        q.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; q.memory = V4L2_MEMORY_MMAP; q.index = (uint32_t)S.dq;
        ioctl(S.vfd, VIDIOC_QBUF, &q);
        S.dq = -1;
    }

    struct pollfd p = { .fd = S.vfd, .events = POLLIN };
    int r = poll(&p, 1, timeout_ms > 0 ? timeout_ms : 0);
    if (r <= 0) return -1;

    struct v4l2_buffer b;
    memset(&b, 0, sizeof b);
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    if (ioctl(S.vfd, VIDIOC_DQBUF, &b) != 0) return -1;
    if (b.index >= S.nbuf) { return -1; }
    S.dq = (int)b.index;

    f->width     = (uint32_t)S.w;
    f->height    = (uint32_t)S.h;
    f->fmt       = KVM_PIX_YUYV;
    f->stride_px = S.stride_px;               /* pixels */
    f->bus       = S.b[b.index].bus;          /* encoder input */
    f->cpu       = S.b[b.index].map;          /* CPU view */
    f->index     = b.index;
    f->size      = S.sizeimage;
    f->seq       = b.sequence;
    return 0;
}

void kvm_cap_release(kvm_frame *f)
{
    (void)f;
    if (S.dq < 0 || !S.streaming) { S.dq = -1; return; }
    struct v4l2_buffer b;
    memset(&b, 0, sizeof b);
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    b.index = (uint32_t)S.dq;
    if (ioctl(S.vfd, VIDIOC_QBUF, &b) != 0)
        fprintf(stderr, "[openkvm-v4l2] QBUF %d failed: %s\n", S.dq, es(errno));
    S.dq = -1;
}

