#ifndef KVM_VISION_H_
#define KVM_VISION_H_

#ifdef __cplusplus
extern "C" {
#endif
#include <fcntl.h> /* low-level i/o */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define IMG_BUFFER_FULL   -3
#define IMG_VENC_ERROR    -2
#define IMG_NOT_EXIST     -1
#define IMG_MJPEG_TYPE    0
#define IMG_H264_TYPE_SPS 1
#define IMG_H264_TYPE_PPS 2
#define IMG_H264_TYPE_IF  3
#define IMG_H264_TYPE_PF  4
#define IMG_H265_TYPE_SPS 5
#define IMG_H265_TYPE_PPS 6
#define IMG_H265_TYPE_IF  7
#define IMG_H265_TYPE_PF  8

#define VENC_CBR 0
#define VENC_VBR 1

void kvmv_init(uint8_t _debug_info_en);
void kvmv_free_all_data();
void kvmv_deinit();
/**********************************************************************************
 * @name    kvmv_read_img
 * @author  Sipeed BuGu
 * @date    2024/10/25
 * @version R1.0
 * @brief   Acquire the encoded image with auto init
 * @param	_width				@input: 	Output image width
 * @param	_height				@input: 	Output image height
 * @param	_type				@input: 	Encode type
 * @param	_qlty				@input: 	MJPEG: (50-100) | H264:  (500-10000)
 * @param	_pp_kvm_data		@output: 	Encode data
 * @param	_p_kvmv_data_size	@output: 	Encode data size
 * @return
        -3: img buffer full
        -2: VENC Error
        -1: No images were acquired
         0: Acquire MJPEG encoded images
         1: Acquire H264 encoded images(SPS)
         2: Acquire H264 encoded images(PPS)
         3: Acquire H264 encoded images(I)
         4: Acquire H264 encoded images(P)
 **********************************************************************************/
int kvmv_read_img(uint16_t _width,
                  uint16_t _height,
                  uint8_t _type,
                  uint16_t _qlty,
                  uint8_t** _pp_kvm_data,
                  uint32_t* _p_kvmv_data_size);
int kvmv_get_sps_frame(uint8_t** _pp_kvm_data, uint32_t* _p_kvmv_data_size);
int kvmv_get_pps_frame(uint8_t** _pp_kvm_data, uint32_t* _p_kvmv_data_size);
int kvmv_free_data(uint8_t** _pp_kvm_data);
int kvmv_set_fps(uint8_t _fps);
int kvmv_get_fps(void);
int kvmv_set_gop(uint8_t _gop);
int kvmv_hdmi_control(uint8_t _en);
int kvmv_read_audio(uint8_t** _pp_kvm_data, uint32_t* _p_kvmv_data_size);
int kvmv_set_rate_control(uint8_t mode);

/* ---- OUR ABI EXTENSION (not in Sipeed's libkvm) ---------------------------
 * Idle power management. kvmv_video_suspend tears down the SoC-side capture
 * pipeline (VENC channel + module, VIN/ISP/MIPI_RX, VB pool, ALSA audio
 * capture) via the exact teardown path kvmv_deinit uses. It deliberately does
 * NOT touch LT6911 power: that chip supplies EDID/HPD to the attached host,
 * and cutting it looks like a monitor unplug. kvmv_video_resume re-runs the
 * normal auto-init path at the live /proc/lt6911_info source geometry (the
 * same re-slice that runs on the first kvmv_read_img), so a resolution change
 * while suspended is handled exactly like a fresh process start. Both return
 * 0 on success. Resume is also implicit: the first kvmv_read_img after a
 * suspend re-inits on its own; the explicit call just fronts the latency. */
int kvmv_video_suspend(void);
int kvmv_video_resume(void);

/* Mini-display live preview (also ours). One call = one preview beat: keeps
 * the read-path preview tap leased for 1 s and, when no web viewer is pulling
 * frames, captures a frame itself (VENC untouched -- no pack stealing, no
 * codec interaction) and publishes it as RGB565 in the panel's native fb
 * layout to /dev/shm/nanokvm-preview (see kvm_preview.c for the format). The
 * Go server ticks this ~10x/s while the display daemon's loopback keep-alive
 * lease is fresh. Returns 0 if a frame was published or the web read path is
 * covering it, negative if capture is not possible right now (e.g. no HDMI
 * signal). */
int kvmv_preview_tick(void);
#ifdef __cplusplus
}
#endif

#endif  // KVM_VISION_H_
