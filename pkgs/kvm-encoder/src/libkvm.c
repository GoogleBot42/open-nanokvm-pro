/*
 * libkvm.c -- open reimplementation of Sipeed's closed libkvm.so for the
 * NanoKVM-Pro (AX630C), exposing exactly the kvm_vision.h ABI the NanoKVM Go
 * server calls. Backed by our documented-Axera-MPI pipeline (kvm_pipeline.*).
 *
 * Model: the AX_VENC encoder returns ONE NAL/pack per AX_VENC_GetStream call,
 * whose NALU type we translate to the kvmv return codes (SPS/PPS/I/P). Each
 * read_img returns one encoded unit in a LIBRARY-OWNED buffer, valid until
 * the next video call: the Go server copies via C.GoBytes and NEVER calls
 * kvmv_free_data (verified against the pinned server source), so a malloc
 * per NAL would leak at up to 120 Hz. Same ownership rule the audio path
 * (s_aout) has always used. kvmv_free_data stays ABI-compatible and is a
 * no-op for the library-owned buffer. Pipeline auto-inits on first read_img
 * at the requested WxH; type 0 -> MJPEG, else H.264.
 *
 * Audio: REAL HDMI-audio capture+encode. The LT6911UXC HDMI-RX de-embeds the
 * HDMI audio onto an I2S link exposed as ALSA capture card "Lt6911UXC". We
 * open it (S16_LE / 48kHz / stereo / 960-frame period), Opus-encode each 20ms
 * period (matching the stock libkvm's params, reverse-engineered from its
 * AudioCapturer: opus_encoder_create(48000,2,AUDIO) + bitrate 128k, complexity
 * 4, FULLBAND, SIGNAL_MUSIC), and return the encoded packet. Ownership: the Go
 * server copies the bytes (C.GoBytes) and never frees audio, so the returned
 * buffer is LIBRARY-OWNED (a persistent static, valid until the next call).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#ifdef KVM_AUDIO_SELFTEST
#include <math.h>
#endif

#include <time.h>

#include <opus/opus.h>
#include <alsa/asoundlib.h>

#include "ax_base_type.h"
#include "ax_global_type.h"
#include "ax_venc_comm.h"
#include "kvm_pipeline.h"
#include "kvm_preview.h"
#include "kvm_vision.h"

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static kvm_cap_ctx s_cap;
static int  s_debug = 0;
static int  s_inited = 0;          /* sys+cap+venc up */
static int  s_cur_type = -1;       /* 0=MJPEG chn, 1=H264 chn currently created */
static int  s_cur_chn = -1;
static int  s_w = 0, s_h = 0;
static int  s_fps = 60, s_gop = 30, s_rc = 0 /*CBR*/, s_qlty = 8000;
static int64_t s_chn_fail_until = 0;  /* VENC-create cooldown: no 120 Hz retry storms */

/* mini-display preview lease (kvmv_preview_tick): while fresh, the encoder
 * read path also feeds kvm_preview_publish; when the encoder path is quiet,
 * the tick captures for itself. Both under s_lock. */
static int64_t s_prev_lease_us = 0;    /* read-path tap active until then */
static int64_t s_last_enc_cap_us = 0;  /* last kvm_cap_get by the read path */
static int64_t s_last_geom_us = 0;     /* last live source-geometry poll */
static int64_t s_last_frame_us = 0;    /* last successful kvm_cap_get */
static int64_t s_reinit_after_us = 0;  /* throttle: no re-init before this */

static int64_t kvm_mono_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

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

/* The library-owned serve buffer every video read returns (see header
 * comment). Grown on demand, reused across calls; the server copies the
 * bytes out (C.GoBytes) before its next call, so one buffer suffices. */
static uint8_t *s_serve = NULL; static uint32_t s_serve_cap = 0;

static uint8_t *serve_buf(uint32_t len)
{
    if (len > s_serve_cap) {
        uint8_t *n = realloc(s_serve, len);
        if (!n) return NULL;
        s_serve = n; s_serve_cap = len;
    }
    return s_serve;
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
    /* Release the preview's frame mappings BEFORE the SYS layer goes away:
     * kvm_preview_reset() calls AX_SYS_Munmap(), which is only valid while
     * libax_sys is initialized. Reset is idempotent, and pool phys addrs
     * change across teardown/re-init anyway, so it must run every teardown. */
    kvm_preview_reset();
    if (s_inited) { kvm_cap_stop(&s_cap); kvm_venc_module_deinit(); kvm_sys_deinit(&s_cap); s_inited = 0; }
}

/* Resolve the frame rate a VENC channel is actually built with. The web UI
 * legitimately sends fps=0 ("auto") on every page load; the VC8000E rejects a
 * zero frame rate (AX_VENC_CreateChn -> AX_ERR_VENC_ILLEGAL_PARAM), so 0 is a
 * SENTINEL here, never a value: resolve it from the live LT6911 source at each
 * channel (re)build, falling back to 60. */
static int effective_fps_locked(void)
{
    int f = s_fps;
    if (f <= 0) {
        int sw, sh, sf, locked;
        if (kvm_read_source(&sw, &sh, &sf, &locked) == 0 && sf > 0) f = sf;
        else f = 60;
    }
    if (f > 120) f = 120;
    return f;
}

/* (re)create the VENC channel for the requested encode type/params */
static int ensure_chn_locked(int want_type, int w, int h, int qlty)
{
    int chn = (want_type == 0) ? KVM_VENC_MJPEG_CHN : KVM_VENC_H264_CHN;
    if (s_cur_type == want_type && s_cur_chn == chn && s_qlty == qlty) return 0;
    /* A failing create must not be retried at the caller's 120 Hz read rate. */
    if (kvm_mono_us() < s_chn_fail_until) return -1;
    if (s_cur_chn >= 0) { kvm_venc_destroy(s_cur_chn); s_cur_chn = -1; s_cur_type = -1; }
    /* Any buffered pack belongs to the channel just destroyed: serving it
     * after the switch would hand e.g. an H.264 SPS+IDR back as a "JPEG". */
    s_pend_len = 0; s_pend_num = 0; s_pend_idx = 0;
    s_qlty = qlty;
    AX_PAYLOAD_TYPE_E pt = (want_type == 0) ? PT_MJPEG : PT_H264;
    if (kvm_venc_create(chn, pt, w, h, effective_fps_locked(), s_gop, qlty, s_rc) != 0) {
        /* CreateChn can succeed and a later step fail: destroy the half-created
         * channel or every future create gets AX_ERR_VENC_EXIST forever. */
        kvm_venc_destroy(chn);
        s_chn_fail_until = kvm_mono_us() + 500000;
        return -1;
    }
    s_cur_type = want_type; s_cur_chn = chn;
    return 0;
}

static int init_pipeline_locked(int w, int h)
{
    int sw, sh, sf, locked;
    if (kvm_read_source(&sw, &sh, &sf, &locked) == 0 && locked && sw > 0 && sh > 0) {
        w = sw; h = sh; s_fps = sf ? sf : s_fps;   /* trust the live source geometry */
    }
    /* BENCH HOOK (unset in production): capture a WxH top-left crop of the
     * live source instead of its full geometry. The open V4L2 driver's SIF
     * window crops, so a 4K-only bench source can exercise the sub-4K encode
     * paths (#60 parity runs; the open H.264 encoder is 1920-wide until #52). */
    {
        const char *fg = getenv("OPENKVM_FORCE_GEOM");
        int fw = 0, fh = 0;
        if (fg && sscanf(fg, "%dx%d", &fw, &fh) == 2 && fw > 0 && fh > 0) {
            fprintf(stderr, "OPEN-KVM: OPENKVM_FORCE_GEOM=%dx%d overrides source %dx%d\n", fw, fh, w, h);
            w = fw; h = fh;
        }
    }
    if (w <= 0 || h <= 0) {
        /* HDMI unlocked and the caller passed 0x0 (screen.go forwards the raw
         * /proc values): a 0-byte VB pool and a 0x0 VIN dev "succeed" partway
         * and then loop on AX_ERR_VIN_ILLEGAL_PARAM. Refuse bring-up instead. */
        fprintf(stderr, "OPEN-KVM: no source geometry (%dx%d, HDMI unlocked?); refusing bring-up\n", w, h);
        return -1;
    }
    if (kvm_sys_init(&s_cap, w, h) != 0) { kvm_sys_deinit(&s_cap); return -1; }
    if (kvm_cap_start(&s_cap, w, h, s_fps) != 0) { kvm_cap_stop(&s_cap); kvm_sys_deinit(&s_cap); return -1; }
    s_w = w; s_h = h; s_inited = 1;
    s_last_frame_us = kvm_mono_us();   /* start the starvation clock fresh */
    return 0;
}

/* Copy a fresh VENC pack into the pending buffer; reset the NAL cursor.
 * On allocation failure the pack is dropped (pending state cleared) and the
 * caller's next_from_pending returns IMG_NOT_EXIST -- a skipped frame, not a
 * crash. */
static void stash_pack(AX_VENC_STREAM_T *st)
{
    uint32_t len = st->stPack.u32Len;
    if (len > s_pend_cap) {
        uint8_t *n = realloc(s_pend, len);
        if (!n) { s_pend_len = 0; s_pend_num = 0; s_pend_idx = 0; return; }
        s_pend = n; s_pend_cap = len;
    }
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
        uint8_t *b = serve_buf(s_pend_len);
        if (!b) return IMG_NOT_EXIST;   /* pack kept; retried on the next call */
        memcpy(b, s_pend, s_pend_len);
        *out = b; *olen = s_pend_len; s_pend_len = 0;
        return IMG_MJPEG_TYPE;
    }

    /* H264: iterate NALs. Fall back to whole-pack if encoder didn't split. */
    if (s_pend_num == 0) {
        uint8_t *b = serve_buf(s_pend_len);
        if (!b) return IMG_NOT_EXIST;   /* pack kept; retried on the next call */
        memcpy(b, s_pend, s_pend_len);
        *out = b; *olen = s_pend_len; s_pend_len = 0;
        return (s_pend_coding == AX_VENC_INTRA_FRAME) ? IMG_H264_TYPE_IF : IMG_H264_TYPE_PF;
    }
    if (s_pend_idx >= s_pend_num) { s_pend_len = 0; return IMG_NOT_EXIST; }

    AX_VENC_NALU_INFO_T *ni = &s_nalu[s_pend_idx];
    uint32_t off = ni->u32NaluOffset, len = ni->u32NaluLength;
    if (off + len > s_pend_len) { len = (off < s_pend_len) ? s_pend_len - off : 0; }
    uint8_t *b = serve_buf(len ? len : 1);
    if (!b) return IMG_NOT_EXIST;       /* cursor not advanced; NAL retried */
    s_pend_idx++;
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

    /* Absorb a LIVE source mode change (host switched resolution while we are
     * streaming). init_pipeline_locked reads the source geometry only once, so
     * without this a 4K->1080p switch keeps the old SIF/WDMA geometry against
     * the new signal -- one garbage ("pink") frame, then a permanent wedge that
     * a switch back to the original mode does NOT clear (the read path never
     * re-reads, so s_w/s_h stay pinned and nothing re-inits). Poll the live
     * geometry at most ~2 Hz; on a real change, tear down so the block below
     * re-inits at the new resolution -- the same recovery the resume path gets.
     * OPENKVM_FORCE_GEOM pins a bench geometry deliberately, so skip then. */
    if (s_inited) {
        int64_t now = kvm_mono_us();
        if (now - s_last_geom_us > 500000 && !getenv("OPENKVM_FORCE_GEOM")) {
            s_last_geom_us = now;
            int sw, sh, sf, locked;
            if (kvm_read_source(&sw, &sh, &sf, &locked) == 0 && locked &&
                sw > 0 && sh > 0 && (sw != s_w || sh != s_h)) {
                fprintf(stderr, "OPEN-KVM: source geometry changed %dx%d -> %dx%d; "
                        "re-initialising capture pipeline\n", s_w, s_h, sw, sh);
                teardown_locked();
            }
        }
    }

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
    if (kvm_cap_get(&img, 1000) != 0) {
        /* Frame-starvation self-heal. A capture that STREAMON'd fine can stop
         * delivering frames after an HPD/link glitch (host sleep/wake, a cable
         * event, an EDID/HPD cycle) even at the SAME resolution: the CSI-2
         * receiver re-locks but the WDMA never resumes, and a fresh STREAMON
         * alone does not clear it -- only a full teardown+re-init does (proven
         * on device). The geometry poll above misses this (resolution is
         * unchanged). So if no frame has arrived for >2 s while the source
         * still reads locked, tear down (throttled) -- the next read rebuilds
         * the pipeline, which recovers once the link settles. */
        int64_t now = kvm_mono_us();
        if (s_inited && now - s_last_frame_us > 2000000 && now > s_reinit_after_us) {
            int sw, sh, sf, locked;
            if (kvm_read_source(&sw, &sh, &sf, &locked) == 0 && locked) {
                fprintf(stderr, "OPEN-KVM: capture starved %lldms (source %dx%d "
                        "locked); re-initialising pipeline\n",
                        (long long)((now - s_last_frame_us) / 1000), sw, sh);
                teardown_locked();
                s_reinit_after_us = now + 1500000;
            }
        }
        pthread_mutex_unlock(&s_lock);
        return IMG_NOT_EXIST;
    }
    s_last_enc_cap_us = kvm_mono_us();
    s_last_frame_us = s_last_enc_cap_us;
    if (s_last_enc_cap_us < s_prev_lease_us)          /* preview page open: tap */
        kvm_preview_publish(&img.tFrameInfo.stVFrame);
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
    uint8_t *b = serve_buf(s_sps_len);
    if (!b) { pthread_mutex_unlock(&s_lock); return IMG_NOT_EXIST; }
    memcpy(b, s_sps, s_sps_len);
    *_pp_kvm_data = b; *_p_kvmv_data_size = s_sps_len;
    pthread_mutex_unlock(&s_lock);
    return IMG_H264_TYPE_SPS;
}

int kvmv_get_pps_frame(uint8_t **_pp_kvm_data, uint32_t *_p_kvmv_data_size)
{
    pthread_mutex_lock(&s_lock);
    if (!s_pps) { pthread_mutex_unlock(&s_lock); return IMG_NOT_EXIST; }
    uint8_t *b = serve_buf(s_pps_len);
    if (!b) { pthread_mutex_unlock(&s_lock); return IMG_NOT_EXIST; }
    memcpy(b, s_pps, s_pps_len);
    *_pp_kvm_data = b; *_p_kvmv_data_size = s_pps_len;
    pthread_mutex_unlock(&s_lock);
    return IMG_H264_TYPE_PPS;
}

int kvmv_free_data(uint8_t **_pp_kvm_data)
{
    /* Video buffers are library-owned (s_serve) -- never free them. The Go
     * server never calls this; a legacy caller passing our buffer back just
     * gets its pointer cleared. */
    if (_pp_kvm_data && *_pp_kvm_data) {
        if (*_pp_kvm_data != s_serve)
            free(*_pp_kvm_data);
        *_pp_kvm_data = NULL;
    }
    return 0;
}

void kvmv_free_all_data(void) { /* per-frame buffers are freed by caller via kvmv_free_data */ }

int kvmv_set_fps(uint8_t _fps)
{
    pthread_mutex_lock(&s_lock);
    s_fps = _fps;   /* 0 = "auto": resolved per rebuild by effective_fps_locked */
    if (s_cur_chn >= 0)
        kvm_venc_set_fps(s_cur_chn, (s_cur_type == 0) ? PT_MJPEG : PT_H264,
                         effective_fps_locked());
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
    /* Sipeed toggles the LT6911 HDMI-RX power via /proc. Cutting it kills the
     * whole chip INCLUDING the EDID/HPD it presents to the attached host (the
     * host sees its monitor unplug), so "off" is refused -- same policy as the
     * idle suspend above, which deliberately leaves the LT6911 powered. The
     * server has no caller for this ABI entry point anyway. */
    if (!_en) {
        fprintf(stderr, "OPEN-KVM: kvmv_hdmi_control(0) refused "
                        "(would cut LT6911 power and drop host EDID/HPD)\n");
        return 0;
    }
    FILE *f = fopen("/proc/lt6911_info/power", "w");
    if (!f) return -1;
    fputs("on", f);
    fclose(f);
    return 0;
}

/* ---- HDMI audio: ALSA(LT6911UXC) capture + Opus encode --------------------
 * All params below are the stock libkvm's, recovered from its AudioCapturer. */
#define KVM_AUD_RATE     48000
#define KVM_AUD_CH       2
#define KVM_AUD_FRAME    960      /* samples/ch per Opus frame == 20ms @48k */
#define KVM_AUD_BITRATE  128000
#define KVM_AUD_MAXPKT   1500     /* stock caps the encoded packet at 1500 B */

static pthread_mutex_t s_alock = PTHREAD_MUTEX_INITIALIZER;
static OpusEncoder *s_opus = NULL;
static snd_pcm_t   *s_pcm  = NULL;
static int          s_audio_ready = 0;
static int          s_audio_fail_logged = 0;
static opus_int16   s_apcm[KVM_AUD_FRAME * KVM_AUD_CH];  /* interleaved S16 */
static uint8_t      s_aout[KVM_AUD_MAXPKT];              /* library-owned */

static void audio_teardown_locked(void)
{
    if (s_pcm)  { snd_pcm_close(s_pcm); s_pcm = NULL; }
    if (s_opus) { opus_encoder_destroy(s_opus); s_opus = NULL; }
    s_audio_ready = 0;
}

/* Open the HDMI-audio capture PCM. Prefer the exact device the stock lib picks
 * (enumerate hints, match the "Lontium Lt6911UXC" DESC, open its NAME); fall
 * back to well-known names for the same card. */
static snd_pcm_t *audio_open_capture(void)
{
    static const char *cands[] = {
        "hw:CARD=Lt6911UXC,DEV=0", "plughw:CARD=Lt6911UXC,DEV=0",
        "hw:0,0", "plughw:0,0", "default", NULL
    };
    snd_pcm_t *pcm = NULL;
    void **hints = NULL;

    if (snd_device_name_hint(-1, "pcm", &hints) == 0 && hints) {
        for (void **h = hints; *h && !pcm; ++h) {
            char *desc = snd_device_name_get_hint(*h, "DESC");
            char *name = snd_device_name_get_hint(*h, "NAME");
            if (desc && name && strstr(desc, "Lt6911")) {
                if (snd_pcm_open(&pcm, name, SND_PCM_STREAM_CAPTURE, 0) < 0) pcm = NULL;
            }
            free(desc); free(name);
        }
        snd_device_name_free_hint(hints);
    }
    for (int i = 0; !pcm && cands[i]; ++i)
        if (snd_pcm_open(&pcm, cands[i], SND_PCM_STREAM_CAPTURE, 0) < 0) pcm = NULL;
    return pcm;
}

/* Bring up the Opus encoder + ALSA capture once. Caller holds s_alock. */
static int audio_init_locked(void)
{
    int err = 0;
    s_opus = opus_encoder_create(KVM_AUD_RATE, KVM_AUD_CH, OPUS_APPLICATION_AUDIO, &err);
    if (!s_opus || err != OPUS_OK) { s_opus = NULL; return -1; }
    opus_encoder_ctl(s_opus, OPUS_SET_BITRATE(KVM_AUD_BITRATE));
    opus_encoder_ctl(s_opus, OPUS_SET_COMPLEXITY(4));
    opus_encoder_ctl(s_opus, OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_FULLBAND));
    opus_encoder_ctl(s_opus, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));

#ifdef KVM_AUDIO_SELFTEST
    /* Test-only build: skip the ALSA capture open and synthesize PCM in the
     * read loop, so the real encode+ownership path can be validated when the
     * HDMI input carries no audio. NEVER defined in the shipped library. */
    s_audio_ready = 1;
    return 0;
#endif

    s_pcm = audio_open_capture();
    if (!s_pcm) { opus_encoder_destroy(s_opus); s_opus = NULL; return -1; }

    snd_pcm_hw_params_t *hw = NULL;
    snd_pcm_hw_params_alloca(&hw);
    unsigned int rate = KVM_AUD_RATE;
    snd_pcm_uframes_t period = KVM_AUD_FRAME;
    if (snd_pcm_hw_params_any(s_pcm, hw) < 0) goto fail;
    if (snd_pcm_hw_params_set_access(s_pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED) < 0) goto fail;
    if (snd_pcm_hw_params_set_format(s_pcm, hw, SND_PCM_FORMAT_S16_LE) < 0) goto fail;
    if (snd_pcm_hw_params_set_channels(s_pcm, hw, KVM_AUD_CH) < 0) goto fail;
    if (snd_pcm_hw_params_set_rate_near(s_pcm, hw, &rate, 0) < 0) goto fail;
    if (rate != KVM_AUD_RATE) goto fail;   /* Opus needs an exact 48k source */
    if (snd_pcm_hw_params_set_period_size_near(s_pcm, hw, &period, 0) < 0) goto fail;
    if (snd_pcm_hw_params(s_pcm, hw) < 0) goto fail;
    if (snd_pcm_prepare(s_pcm) < 0) goto fail;

    s_audio_ready = 1;
    return 0;
fail:
    audio_teardown_locked();
    return -1;
}

int kvmv_read_audio(uint8_t **_pp_kvm_data, uint32_t *_p_kvmv_data_size)
{
    if (_pp_kvm_data) *_pp_kvm_data = NULL;
    if (_p_kvmv_data_size) *_p_kvmv_data_size = 0;

    pthread_mutex_lock(&s_alock);

    if (!s_audio_ready && audio_init_locked() != 0) {
        if (!s_audio_fail_logged) {
            fprintf(stderr, "OPEN-KVM: audio capture init failed "
                    "(no LT6911 HDMI-audio PCM available yet)\n");
            fflush(stderr);
            s_audio_fail_logged = 1;
        }
        pthread_mutex_unlock(&s_alock);
        return IMG_NOT_EXIST;
    }
    s_audio_fail_logged = 0;

#ifdef KVM_AUDIO_SELFTEST
    /* Synthesize a 440Hz + 660Hz stereo tone so we can validate the encode +
     * ownership path without a live HDMI audio source. */
    {
        static double ph = 0.0;
        for (int i = 0; i < KVM_AUD_FRAME; i++) {
            double t = ph + (double)i / KVM_AUD_RATE;
            s_apcm[i*2+0] = (opus_int16)(9000.0 * sin(2*3.14159265*440.0*t));
            s_apcm[i*2+1] = (opus_int16)(9000.0 * sin(2*3.14159265*660.0*t));
        }
        ph += (double)KVM_AUD_FRAME / KVM_AUD_RATE;
        int enc0 = opus_encode(s_opus, s_apcm, KVM_AUD_FRAME, s_aout, KVM_AUD_MAXPKT);
        if (enc0 < 0) { pthread_mutex_unlock(&s_alock); return IMG_NOT_EXIST; }
        if (_pp_kvm_data) *_pp_kvm_data = s_aout;
        if (_p_kvmv_data_size) *_p_kvmv_data_size = (uint32_t)enc0;
        pthread_mutex_unlock(&s_alock);
        return 0;
    }
#endif

    /* Read exactly one 960-frame stereo period; recover from xruns like stock. */
    snd_pcm_uframes_t got = 0;
    while (got < KVM_AUD_FRAME) {
        snd_pcm_sframes_t n = snd_pcm_readi(s_pcm, s_apcm + got * KVM_AUD_CH,
                                            KVM_AUD_FRAME - got);
        if (n == -EPIPE) { snd_pcm_prepare(s_pcm); continue; }
        if (n < 0) { audio_teardown_locked(); pthread_mutex_unlock(&s_alock); return IMG_NOT_EXIST; }
        got += (snd_pcm_uframes_t)n;
    }

    int enc = opus_encode(s_opus, s_apcm, KVM_AUD_FRAME, s_aout, KVM_AUD_MAXPKT);
    if (enc < 0) { pthread_mutex_unlock(&s_alock); return IMG_NOT_EXIST; }

    /* Library-owned buffer (server copies via C.GoBytes, never frees audio). */
    if (_pp_kvm_data) *_pp_kvm_data = s_aout;
    if (_p_kvmv_data_size) *_p_kvmv_data_size = (uint32_t)enc;
    pthread_mutex_unlock(&s_alock);
    return 0;
}

/* ---- idle power management (our ABI extension; see kvm_vision.h) ----------
 *
 * Suspend depth: FULL SoC-side teardown -- the same proven sequence as
 * kvmv_deinit (VENC chn destroy + AX_VENC_Deinit, ISP/VIN/MIPI_RX stop and
 * destroy, AX_POOL_Exit releasing the ~16 MB CMM pool, AX_SYS_Deinit) plus the
 * ALSA/Opus audio capture. Resume is the unmodified lazy auto-init path
 * (init_pipeline_locked + ensure_chn_locked), which re-reads the LIVE source
 * geometry from /proc/lt6911_info -- so an HDMI mode change during the nap is
 * absorbed exactly like a fresh server start.
 *
 * What is deliberately NOT suspended: the LT6911UXC HDMI receiver. Its only
 * power control (/proc/lt6911_info/power -> lt6911_pwr_ctrl -> PWR_PIN GPIO,
 * see drivers/misc/lt6911_manage.c; this is what kvmv_hdmi_control toggles)
 * cuts the whole chip -- including the EDID/HPD it presents to the attached
 * host, which would make the host's desktop see a monitor unplug. Zero
 * host-visible side effects beats the extra few hundred mW. */
int kvmv_video_suspend(void)
{
    pthread_mutex_lock(&s_lock);
    int was_up = s_inited;
    teardown_locked();
    /* Drop cached SPS/PPS and any half-served pack: they describe the
     * pre-suspend geometry; the fresh VENC channel re-emits SPS/PPS + IDR. */
    free(s_sps); s_sps = NULL; s_sps_len = 0;
    free(s_pps); s_pps = NULL; s_pps_len = 0;
    s_pend_len = 0; s_pend_num = 0; s_pend_idx = 0;
    pthread_mutex_unlock(&s_lock);

    pthread_mutex_lock(&s_alock);
    audio_teardown_locked();   /* reopens lazily on the next kvmv_read_audio */
    pthread_mutex_unlock(&s_alock);

    fprintf(stderr, "OPEN-KVM: video pipeline suspended (%s; LT6911/HPD untouched)\n",
            was_up ? "was active" : "was already down");
    fflush(stderr);
    return 0;
}

/* One preview beat for the mini-display (our ABI extension; the Go server
 * calls this ~10x/s while the display daemon holds a preview lease). Extends
 * the read-path tap window; when the encoder path has captured recently a
 * web viewer's own reads feed the preview and this is a no-op. Otherwise it
 * captures one frame itself and publishes it -- WITHOUT touching VENC, so it
 * never steals an encoded pack from (or switches codecs under) a web viewer,
 * and it works with zero viewers connected. */
int kvmv_preview_tick(void)
{
    int rc = 0;
    pthread_mutex_lock(&s_lock);
    int64_t now = kvm_mono_us();
    s_prev_lease_us = now + 1000000;
    if (now - s_last_enc_cap_us < 300000) {   /* read path is feeding the tap */
        pthread_mutex_unlock(&s_lock);
        return 0;
    }
    if (!s_inited && init_pipeline_locked(s_w > 0 ? s_w : 1920,
                                          s_h > 0 ? s_h : 1080) != 0) {
        pthread_mutex_unlock(&s_lock);
        return -1;
    }
    AX_IMG_INFO_T img;
    if (kvm_cap_get(&img, 200) != 0) {
        rc = -1;
    } else {
        kvm_preview_publish(&img.tFrameInfo.stVFrame);
        kvm_cap_release(&img);
    }
    pthread_mutex_unlock(&s_lock);
    return rc;
}

int kvmv_video_resume(void)
{
    int rc = 0;
    pthread_mutex_lock(&s_lock);
    if (!s_inited) {
        /* init_pipeline_locked prefers the live /proc/lt6911_info geometry;
         * the last-known (or default) size is only the no-signal fallback. */
        int w = (s_w > 0) ? s_w : 1920;
        int h = (s_h > 0) ? s_h : 1080;
        rc = init_pipeline_locked(w, h);
    }
    fprintf(stderr, "OPEN-KVM: video pipeline resume%s (%dx%d)\n",
            (rc == 0) ? "d" : " FAILED (will retry on next read)", s_w, s_h);
    fflush(stderr);
    pthread_mutex_unlock(&s_lock);
    return rc;
}

void kvmv_deinit(void)
{
    pthread_mutex_lock(&s_lock);
    teardown_locked();
    free(s_sps); s_sps = NULL; s_sps_len = 0;
    free(s_pps); s_pps = NULL; s_pps_len = 0;
    free(s_pend); s_pend = NULL; s_pend_cap = s_pend_len = 0; s_pend_num = s_pend_idx = 0;
    free(s_serve); s_serve = NULL; s_serve_cap = 0;
    pthread_mutex_unlock(&s_lock);

    pthread_mutex_lock(&s_alock);
    audio_teardown_locked();
    pthread_mutex_unlock(&s_alock);
}
