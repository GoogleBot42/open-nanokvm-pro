/*
 * libkvm.c -- open reimplementation of Sipeed's closed libkvm.so for the
 * NanoKVM-Pro (AX630C), exposing exactly the kvm_vision.h ABI the NanoKVM Go
 * server calls. Backed by our documented-Axera-MPI pipeline (kvm_pipeline.*).
 *
 * Model: the AX_VENC encoder returns ONE NAL/pack per AX_VENC_GetStream call,
 * whose NALU type we translate to the kvmv return codes (SPS/PPS/I/P). Each
 * read_img returns one encoded unit copied into a malloc'd buffer the caller
 * frees via kvmv_free_data. Pipeline auto-inits on first read_img at the
 * requested WxH; type 0 -> MJPEG, else H.264.
 *
 * Audio is a stub (returns empty) this pass -- ALSA+Opus is out of scope.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

#include "ax_base_type.h"
#include "ax_global_type.h"
#include "ax_venc_comm.h"
#include "kvm_pipeline.h"
#include "kvm_vision.h"

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static kvm_cap_ctx s_cap;
static int  s_debug = 0;
static int  s_inited = 0;          /* sys+cap+venc up */
static int  s_cur_type = -1;       /* 0=MJPEG chn, 1=H264 chn currently created */
static int  s_cur_chn = -1;
static int  s_w = 0, s_h = 0;
static int  s_fps = 60, s_gop = 30, s_rc = 0 /*CBR*/, s_qlty = 8000;

/* cached SPS/PPS copies for get_sps/get_pps */
static uint8_t *s_sps = NULL; static uint32_t s_sps_len = 0;
static uint8_t *s_pps = NULL; static uint32_t s_pps_len = 0;

/* One AX_VENC pack may carry several NALs (SPS+PPS+IDR). The kvm_vision ABI
 * returns one NAL per read_img, so we buffer a whole pack and serve its NALs
 * across successive calls. */
static uint8_t *s_pend = NULL; static uint32_t s_pend_cap = 0, s_pend_len = 0;
static AX_VENC_NALU_INFO_T s_nalu[AX_MAX_VENC_NALU_NUM];
static AX_VENC_PICTURE_CODING_TYPE_E s_pend_coding;
static uint32_t s_pend_num = 0, s_pend_idx = 0;

static void cache_nal(uint8_t **dst, uint32_t *dlen, const uint8_t *src, uint32_t len)
{
    uint8_t *n = realloc(*dst, len);
    if (!n) return;
    memcpy(n, src, len); *dst = n; *dlen = len;
}

void kvmv_init(uint8_t _debug_info_en)
{
    s_debug = _debug_info_en;
    /* Distinctive marker so we can PROVE, from the server's own log, that OUR
     * open libkvm (documented Axera MPI, self-capturing, no Sipeed native code,
     * no kvm_vin/vin_sock) is the library serving video -- not the stock blob. */
    fprintf(stderr, "OPEN-KVM libkvm active (open Axera-MPI capture+encode, debug=%u)\n",
            (unsigned)_debug_info_en);
    fflush(stderr);
}

static void teardown_locked(void)
{
    if (s_cur_chn >= 0) { kvm_venc_destroy(s_cur_chn); s_cur_chn = -1; s_cur_type = -1; }
    if (s_inited) { kvm_cap_stop(&s_cap); kvm_venc_module_deinit(); kvm_sys_deinit(&s_cap); s_inited = 0; }
}

/* (re)create the VENC channel for the requested encode type/params */
static int ensure_chn_locked(int want_type, int w, int h, int qlty)
{
    int chn = (want_type == 0) ? KVM_VENC_MJPEG_CHN : KVM_VENC_H264_CHN;
    if (s_cur_type == want_type && s_cur_chn == chn && s_qlty == qlty) return 0;
    if (s_cur_chn >= 0) { kvm_venc_destroy(s_cur_chn); s_cur_chn = -1; s_cur_type = -1; }
    s_qlty = qlty;
    AX_PAYLOAD_TYPE_E pt = (want_type == 0) ? PT_MJPEG : PT_H264;
    if (kvm_venc_create(chn, pt, w, h, s_fps, s_gop, qlty, s_rc) != 0) return -1;
    s_cur_type = want_type; s_cur_chn = chn;
    return 0;
}

static int init_pipeline_locked(int w, int h)
{
    int sw, sh, sf, locked;
    if (kvm_read_source(&sw, &sh, &sf, &locked) == 0 && locked && sw > 0 && sh > 0) {
        w = sw; h = sh; s_fps = sf ? sf : s_fps;   /* trust the live source geometry */
    }
    if (kvm_sys_init(&s_cap, w, h) != 0) return -1;
    if (kvm_cap_start(&s_cap, w, h, s_fps) != 0) { kvm_sys_deinit(&s_cap); return -1; }
    s_w = w; s_h = h; s_inited = 1;
    return 0;
}

/* Copy a fresh VENC pack into the pending buffer; reset the NAL cursor. */
static void stash_pack(AX_VENC_STREAM_T *st)
{
    uint32_t len = st->stPack.u32Len;
    if (len > s_pend_cap) { s_pend = realloc(s_pend, len); s_pend_cap = len; }
    memcpy(s_pend, st->stPack.pu8Addr, len);
    s_pend_len = len;
    s_pend_coding = st->stPack.enCodingType;
    s_pend_num = st->stPack.u32NaluNum;
    if (s_pend_num > AX_MAX_VENC_NALU_NUM) s_pend_num = AX_MAX_VENC_NALU_NUM;
    memcpy(s_nalu, st->stPack.stNaluInfo, s_pend_num * sizeof(s_nalu[0]));
    s_pend_idx = 0;
}

/* Return the next pending NAL (H264) or the whole JPEG (MJPEG). */
static int next_from_pending(int type, uint8_t **out, uint32_t *olen)
{
    if (s_pend_len == 0) return IMG_NOT_EXIST;

    if (type == 0) {  /* MJPEG: whole pack is one image */
        uint8_t *b = malloc(s_pend_len);
        memcpy(b, s_pend, s_pend_len);
        *out = b; *olen = s_pend_len; s_pend_len = 0;
        return IMG_MJPEG_TYPE;
    }

    /* H264: iterate NALs. Fall back to whole-pack if encoder didn't split. */
    if (s_pend_num == 0) {
        uint8_t *b = malloc(s_pend_len);
        memcpy(b, s_pend, s_pend_len);
        *out = b; *olen = s_pend_len; s_pend_len = 0;
        return (s_pend_coding == AX_VENC_INTRA_FRAME) ? IMG_H264_TYPE_IF : IMG_H264_TYPE_PF;
    }
    if (s_pend_idx >= s_pend_num) { s_pend_len = 0; return IMG_NOT_EXIST; }

    AX_VENC_NALU_INFO_T *ni = &s_nalu[s_pend_idx++];
    uint32_t off = ni->u32NaluOffset, len = ni->u32NaluLength;
    if (off + len > s_pend_len) { len = (off < s_pend_len) ? s_pend_len - off : 0; }
    uint8_t *b = malloc(len ? len : 1);
    memcpy(b, s_pend + off, len);
    *out = b; *olen = len;
    if (s_pend_idx >= s_pend_num) s_pend_len = 0;   /* consumed */

    switch (ni->unNaluType.enH264EType) {
        case AX_H264E_NALU_SPS: cache_nal(&s_sps, &s_sps_len, b, len); return IMG_H264_TYPE_SPS;
        case AX_H264E_NALU_PPS: cache_nal(&s_pps, &s_pps_len, b, len); return IMG_H264_TYPE_PPS;
        case AX_H264E_NALU_ISLICE:
        case AX_H264E_NALU_IDRSLICE: return IMG_H264_TYPE_IF;
        case AX_H264E_NALU_PSLICE:   return IMG_H264_TYPE_PF;
        default:                     return IMG_H264_TYPE_PF;
    }
}

int kvmv_read_img(uint16_t _width, uint16_t _height, uint8_t _type, uint16_t _qlty,
                  uint8_t **_pp_kvm_data, uint32_t *_p_kvmv_data_size)
{
    int rc = IMG_NOT_EXIST;
    pthread_mutex_lock(&s_lock);

    if (!s_inited && init_pipeline_locked(_width, _height) != 0) { pthread_mutex_unlock(&s_lock); return IMG_VENC_ERROR; }

    int want_type = (_type == IMG_MJPEG_TYPE) ? 0 : 1;
    int qlty = _qlty ? _qlty : (want_type ? 8000 : 80);
    if (ensure_chn_locked(want_type, s_w, s_h, qlty) != 0) { pthread_mutex_unlock(&s_lock); return IMG_VENC_ERROR; }

    /* 0) still-buffered NALs from the previous pack? serve the next one */
    if (s_pend_len > 0) {
        rc = next_from_pending(want_type, _pp_kvm_data, _p_kvmv_data_size);
        pthread_mutex_unlock(&s_lock);
        return rc;
    }

    /* 1) grab an already-encoded pack if the encoder has one ready */
    AX_VENC_STREAM_T st;
    if (kvm_venc_get(s_cur_chn, &st, 5) == 0) {
        stash_pack(&st);
        kvm_venc_release(s_cur_chn, &st);
        rc = next_from_pending(want_type, _pp_kvm_data, _p_kvmv_data_size);
        pthread_mutex_unlock(&s_lock);
        return rc;
    }

    /* 2) otherwise capture+encode a fresh frame */
    AX_IMG_INFO_T img;
    if (kvm_cap_get(&img, 1000) != 0) { pthread_mutex_unlock(&s_lock); return IMG_NOT_EXIST; }
    kvm_venc_send(s_cur_chn, &img.tFrameInfo);
    kvm_cap_release(&img);
    if (kvm_venc_get(s_cur_chn, &st, 2000) == 0) {
        stash_pack(&st);
        kvm_venc_release(s_cur_chn, &st);
        rc = next_from_pending(want_type, _pp_kvm_data, _p_kvmv_data_size);
    }
    pthread_mutex_unlock(&s_lock);
    return rc;
}

int kvmv_get_sps_frame(uint8_t **_pp_kvm_data, uint32_t *_p_kvmv_data_size)
{
    pthread_mutex_lock(&s_lock);
    if (!s_sps) { pthread_mutex_unlock(&s_lock); return IMG_NOT_EXIST; }
    uint8_t *b = malloc(s_sps_len); memcpy(b, s_sps, s_sps_len);
    *_pp_kvm_data = b; *_p_kvmv_data_size = s_sps_len;
    pthread_mutex_unlock(&s_lock);
    return IMG_H264_TYPE_SPS;
}

int kvmv_get_pps_frame(uint8_t **_pp_kvm_data, uint32_t *_p_kvmv_data_size)
{
    pthread_mutex_lock(&s_lock);
    if (!s_pps) { pthread_mutex_unlock(&s_lock); return IMG_NOT_EXIST; }
    uint8_t *b = malloc(s_pps_len); memcpy(b, s_pps, s_pps_len);
    *_pp_kvm_data = b; *_p_kvmv_data_size = s_pps_len;
    pthread_mutex_unlock(&s_lock);
    return IMG_H264_TYPE_PPS;
}

int kvmv_free_data(uint8_t **_pp_kvm_data)
{
    if (_pp_kvm_data && *_pp_kvm_data) { free(*_pp_kvm_data); *_pp_kvm_data = NULL; }
    return 0;
}

void kvmv_free_all_data(void) { /* per-frame buffers are freed by caller via kvmv_free_data */ }

int kvmv_set_fps(uint8_t _fps)
{
    pthread_mutex_lock(&s_lock);
    s_fps = _fps;
    if (s_cur_chn >= 0) kvm_venc_set_fps(s_cur_chn, (s_cur_type == 0) ? PT_MJPEG : PT_H264, _fps);
    pthread_mutex_unlock(&s_lock);
    return 0;
}

int kvmv_get_fps(void) { return s_fps; }

int kvmv_set_gop(uint8_t _gop)
{
    pthread_mutex_lock(&s_lock);
    s_gop = _gop;
    if (s_cur_chn == KVM_VENC_H264_CHN) kvm_venc_set_gop(s_cur_chn, _gop);
    pthread_mutex_unlock(&s_lock);
    return 0;
}

int kvmv_set_rate_control(uint8_t mode)
{
    pthread_mutex_lock(&s_lock);
    s_rc = (mode == VENC_VBR) ? 1 : 0;
    /* force channel rebuild on next read so new RC mode takes effect */
    if (s_cur_chn == KVM_VENC_H264_CHN) { kvm_venc_destroy(s_cur_chn); s_cur_chn = -1; s_cur_type = -1; }
    pthread_mutex_unlock(&s_lock);
    return 0;
}

int kvmv_hdmi_control(uint8_t _en)
{
    /* Sipeed toggles the LT6911 HDMI-RX power via /proc. We expose the same
     * control; guarded so it is a no-op unless explicitly turning ON, to avoid
     * accidentally blanking the source during unit tests. */
    FILE *f = fopen("/proc/lt6911_info/power", "w");
    if (!f) return -1;
    fputs(_en ? "on" : "off", f);
    fclose(f);
    return 0;
}

int kvmv_read_audio(uint8_t **_pp_kvm_data, uint32_t *_p_kvmv_data_size)
{
    /* stub: audio (ALSA capture + Opus encode) not implemented this pass */
    if (_pp_kvm_data) *_pp_kvm_data = NULL;
    if (_p_kvmv_data_size) *_p_kvmv_data_size = 0;
    return IMG_NOT_EXIST;
}

void kvmv_deinit(void)
{
    pthread_mutex_lock(&s_lock);
    teardown_locked();
    free(s_sps); s_sps = NULL; s_sps_len = 0;
    free(s_pps); s_pps = NULL; s_pps_len = 0;
    free(s_pend); s_pend = NULL; s_pend_cap = s_pend_len = 0; s_pend_num = s_pend_idx = 0;
    pthread_mutex_unlock(&s_lock);
}
