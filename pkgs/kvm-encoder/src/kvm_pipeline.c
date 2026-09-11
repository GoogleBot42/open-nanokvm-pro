/*
 * kvm_pipeline.c -- the HDMI source poll, the one piece of the pipeline that
 * is neither capture nor encode.
 *
 * The capture backend is kvm_capture_v4l2.c (open_vin_capture over V4L2) and
 * the encode backend is kvm_venc_open.c (the open VC8000E over /dev/es_venc);
 * both used to have vendor-MPI twins in this file, selected at build time.
 * They are gone with the vendor SDK headers (#102) -- what they did is on
 * record in docs/blob-replacement.md and in the git history.
 */
#include <stdio.h>
#include <string.h>

#include "kvm_pipeline.h"

/* ---------------- lt6911 source poll ---------------- */
static int read_int_file(const char *path, int *out)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int v = -1, n = fscanf(f, "%d", &v);
    fclose(f);
    if (n != 1) return -1;
    *out = v;
    return 0;
}

int kvm_read_source(int *w, int *h, int *fps, int *locked)
{
    int ww=0, hh=0, ff=0;
    if (read_int_file("/proc/lt6911_info/width", &ww)) return -1;
    if (read_int_file("/proc/lt6911_info/height", &hh)) return -1;
    read_int_file("/proc/lt6911_info/fps", &ff);
    if (w) *w = ww;
    if (h) *h = hh;
    if (fps) *fps = ff;
    if (locked) {
        char buf[64] = {0};
        FILE *f = fopen("/proc/lt6911_info/hdmi_rx_status", "r");
        *locked = 0;
        if (f) { if (fgets(buf, sizeof(buf), f)) *locked = (strncmp(buf, "access", 6) == 0); fclose(f); }
    }
    return 0;
}
