/*
 * kvm_preview.h -- mini-display live-preview side channel.
 *
 * Converts a held capture frame (YUYV 4:2:2 interleaved, the VIN bypass
 * output) into the JD9853 panel's native framebuffer layout (172x320
 * portrait, RGB565-LE, pre-rotated) and publishes it atomically to
 * /dev/shm/nanokvm-preview, where the display daemon blits it verbatim.
 * See docs/mini-display.md ("Live HDMI preview").
 *
 * Both entry points are called with libkvm's s_lock held; all state here is
 * private to this module and needs no further locking.
 */
#ifndef KVM_PREVIEW_H_
#define KVM_PREVIEW_H_

#include <stdint.h>

#include "ax_global_type.h"

/* Convert + publish one frame. Internally rate-limited (a call more often
 * than ~12 fps is a cheap no-op), so callers may invoke it per frame. */
void kvm_preview_publish(const AX_VIDEO_FRAME_T *vf);

/* Drop cached phys->virt mappings and the scaler table. Must be called when
 * the capture pipeline is torn down (pool phys addresses change across a
 * suspend/resume cycle). */
void kvm_preview_reset(void);

/* CPU view of a captured frame's phys block (read-only). Same cached
 * AX_SYS_Mmap-or-/dev/mem route the preview scaler uses; the cache lives as
 * long as the capture pipeline (kvm_preview_reset drops it). NULL on failure. */
const void *kvm_frame_map(uint64_t phys, uint32_t size);

#endif /* KVM_PREVIEW_H_ */
