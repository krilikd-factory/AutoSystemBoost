/*
 * asb_dsp.c — AutoSystemBoost DSP effect (makeup gain + true peak limiter).
 *
 * Copyright (c) 2026 Dima Krylov. MIT license (same as the rest of AutoSystemBoost).
 * Original work. No GPL sources were used. The effect ABI in asb_effect_abi.h is the
 * public AOSP audio-effect interface (Apache-2.0), attributed in that header.
 *
 * WHY THIS EXISTS
 * ---------------
 * The audio-policy volume curves (see media_loudness in install.sh) can make every
 * slider position louder, but they physically cannot exceed 0 dB at 100% — that is
 * unity, and going past it in the curve just clips. Real loudness ABOVE unity needs
 * a gain stage with a limiter in front of the output. That is this effect.
 *
 * DESIGN NOTES
 * ------------
 * - process() is strictly realtime-safe: no malloc/free, no syscalls, no locks, no
 *   file or property reads. Everything it needs is precomputed in command().
 * - The limiter is feed-forward, stereo/multichannel-linked (all channels share one
 *   gain-reduction value, so the stereo image never wobbles), with a fast attack and
 *   a slow release. There is no look-ahead, so the attack is deliberately quick and a
 *   final hard clamp catches any residual overshoot.
 * - Both PCM float (what the modern mixer uses) and PCM 16-bit are handled. Any other
 *   format falls back to a clean passthrough rather than corrupting audio.
 * - Gain is read from properties at INIT/ENABLE, so the WebUI can change it and a
 *   reconnect/restart picks it up without any app attaching to the session.
 */

#include "asb_effect_abi.h"

#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>

#define ASB_DSP_NAME       "ASB Loudness"
#define ASB_DSP_IMPLEMENTOR "AutoSystemBoost"

/* Tunables (properties, read at INIT/ENABLE — never in process()) */
#define ASB_PROP_ENABLE  "persist.asb.dsp.enable"
#define ASB_PROP_GAIN_MB "persist.asb.dsp.gain_mb"
#define ASB_PROP_CEIL_MB "persist.asb.dsp.ceiling_mb"
#define ASB_PROP_COMP    "persist.asb.dsp.comp"           /* 0 = gain+limiter only */
#define ASB_PROP_RATIO   "persist.asb.dsp.comp_ratio_x10"
#define ASB_PROP_THRESH  "persist.asb.dsp.comp_thresh_mb"

/* Safety rails: never let a bad config blow up the output. */
#define ASB_GAIN_MB_MIN    0       /* +0 dB  */
#define ASB_GAIN_MB_MAX    1800    /* +18 dB (limiter still holds the ceiling) */
#define ASB_CEIL_MB_MIN   (-600)   /* -6 dBFS  */
#define ASB_CEIL_MB_MAX   (-30)    /* -0.3 dBFS */
#define ASB_RATIO_MIN      10      /* 1.0:1 = compressor off */
#define ASB_RATIO_MAX      80      /* 8.0:1 */
#define ASB_THRESH_MB_MIN (-4000)  /* -40 dBFS */
#define ASB_THRESH_MB_MAX (-300)   /*  -3 dBFS */

#define ASB_RELEASE_MS   120.0f    /* limiter release */
#define ASB_COMP_ATK_MS  8.0f
#define ASB_COMP_REL_MS  180.0f
#define ASB_COMP_KNEE_DB 8.0f

/* Unique to ASB — must not collide with any other effect on the device. */
static const effect_descriptor_t g_asb_descriptor = {
    .type = EFFECT_UUID_INITIALIZER,   /* no standard OpenSL type: proprietary insert */
    .uuid = { 0xa5b10001, 0x7e55, 0x4c60, 0x9f21, { 0x41, 0x53, 0x42, 0x44, 0x53, 0x50 } },
    .apiVersion = EFFECT_CONTROL_API_VERSION,
    /* POST_PROC (not INSERT): required for an effect hooked into
     * <postprocess><stream type="music"> in audio_effects_config.xml. With INSERT the
     * audiopolicy manager never attached us to the stream, so the gain did nothing at
     * any value - the bug the user saw. OFFLOAD_SUPPORTED lets us ride compress-offloaded
     * music (common on Snapdragon) instead of being bypassed by it. */
    .flags = EFFECT_FLAG_TYPE_POST_PROC | EFFECT_FLAG_INSERT_LAST
             | EFFECT_FLAG_OFFLOAD_SUPPORTED
             | EFFECT_FLAG_OUTPUT_DIRECT | EFFECT_FLAG_INPUT_DIRECT,
    .cpuLoad = 3,        /* 0.1 MIPS units on ARM9E — gain+limiter is very cheap */
    .memoryUsage = 1,    /* KB, dynamically allocated */
    .name = ASB_DSP_NAME,
    .implementor = ASB_DSP_IMPLEMENTOR
};

typedef struct {
    const struct effect_interface_s *iface;  /* MUST stay first (effect_handle_t casts to it) */

    effect_config_t cfg;
    int      configured;
    int      enabled;

    /* precomputed, realtime-read-only */
    float    gain;        /* linear makeup gain */
    float    ceiling;     /* linear limiter threshold */
    float    rel;         /* one-pole release coefficient */
    int      channels;
    int      bypass;      /* 1 = pure passthrough (disabled or unsupported format) */

    /* compressor */
    int      comp_on;
    float    thresh_db;
    float    inv_ratio;   /* 1/ratio, precomputed */
    float    cmakeup;     /* auto make-up for the compressor */
    float    catk;
    float    crel;

    /* limiter state */
    float    env;         /* peak envelope, instant attack / slow release */
    float    cenv;        /* compressor envelope, smoothed both ways */
} asb_ctx_t;

/* ---------------------------------------------------------------- helpers */

static int asb_prop_int(const char *key, int fallback) {
    char buf[PROP_VALUE_MAX];
    if (__system_property_get(key, buf) <= 0) return fallback;
    char *end = NULL;
    long v = strtol(buf, &end, 10);
    if (end == buf) return fallback;
    return (int)v;
}

static int asb_clamp_int(int v, int lo, int hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static float asb_mb_to_lin(int mb) {
    return powf(10.0f, (float)mb / 2000.0f);
}

static int asb_channel_count(uint32_t mask) {
    int n = __builtin_popcount(mask);
    return n > 0 ? n : 2;
}

/* One-pole smoothing coefficient for a given time constant. */
static float asb_coef(float ms, uint32_t rate) {
    if (rate == 0 || ms <= 0.0f) return 0.0f;
    return expf(-1.0f / ((ms / 1000.0f) * (float)rate));
}

/* Recompute everything process() depends on. Called from command() only. */
static void asb_refresh(asb_ctx_t *c) {
    int on     = asb_prop_int(ASB_PROP_ENABLE, 0);
    int gainmb = asb_clamp_int(asb_prop_int(ASB_PROP_GAIN_MB, 0), ASB_GAIN_MB_MIN, ASB_GAIN_MB_MAX);
    int ceilmb = asb_clamp_int(asb_prop_int(ASB_PROP_CEIL_MB, -15), ASB_CEIL_MB_MIN, ASB_CEIL_MB_MAX);

    uint32_t rate = c->cfg.outputCfg.samplingRate ? c->cfg.outputCfg.samplingRate : 48000u;

    int comp   = asb_prop_int(ASB_PROP_COMP, 1);
    int ratio  = asb_clamp_int(asb_prop_int(ASB_PROP_RATIO, 60), ASB_RATIO_MIN, ASB_RATIO_MAX);
    int thrmb  = asb_clamp_int(asb_prop_int(ASB_PROP_THRESH, -2400), ASB_THRESH_MB_MIN, ASB_THRESH_MB_MAX);

    c->gain    = asb_mb_to_lin(gainmb);
    c->ceiling = asb_mb_to_lin(ceilmb);
    c->comp_on   = (comp && ratio > ASB_RATIO_MIN) ? 1 : 0;
    c->thresh_db = (float)thrmb / 100.0f;
    c->inv_ratio = 10.0f / (float)ratio;
    /* Auto make-up. Without this the compressor is a LOUDNESS LOSS, not a gain: it only
     * ever turns things down, so "compress then apply the same makeup" lands quieter
     * than no compressor at all (measured: +6 dB setting delivered +1.2 dB RMS instead
     * of +5.0 dB). Compensate by what the curve costs a full-scale signal, halved -
     * full compensation pins everything at the ceiling and the limiter then does all
     * the work, which is exactly the squashed sound we are trying to avoid. */
    if (c->comp_on) {
        float over0 = -c->thresh_db;                       /* 0 dBFS above threshold */
        float mk_db = -over0 * (c->inv_ratio - 1.0f) * 0.5f;
        c->cmakeup = powf(10.0f, mk_db / 20.0f);
    } else {
        c->cmakeup = 1.0f;
    }
    c->rel     = asb_coef(ASB_RELEASE_MS, rate);
    c->catk    = asb_coef(ASB_COMP_ATK_MS, rate);
    c->crel    = asb_coef(ASB_COMP_REL_MS, rate);
    c->channels = asb_channel_count(c->cfg.outputCfg.channels);

    /* Bypass whenever there is nothing to do or the format is not one we handle. */
    int fmt_ok = (c->cfg.outputCfg.format == AUDIO_FORMAT_PCM_FLOAT
                  || c->cfg.outputCfg.format == AUDIO_FORMAT_PCM_16_BIT);
    c->bypass = (!on || gainmb <= 0 || !fmt_ok) ? 1 : 0;
}

/* Copy or accumulate without touching the samples. */
static void asb_passthrough(asb_ctx_t *c, audio_buffer_t *in, audio_buffer_t *out) {
    size_t n = in->frameCount * (size_t)c->channels;
    int acc = (c->cfg.outputCfg.accessMode == EFFECT_BUFFER_ACCESS_ACCUMULATE);

    if (c->cfg.outputCfg.format == AUDIO_FORMAT_PCM_FLOAT) {
        if (acc) { for (size_t i = 0; i < n; i++) out->f32[i] += in->f32[i]; }
        else if (in->f32 != out->f32) memcpy(out->f32, in->f32, n * sizeof(float));
    } else {
        if (acc) {
            for (size_t i = 0; i < n; i++) {
                int32_t s = (int32_t)out->s16[i] + (int32_t)in->s16[i];
                out->s16[i] = (int16_t)(s > 32767 ? 32767 : (s < -32768 ? -32768 : s));
            }
        } else if (in->s16 != out->s16) memcpy(out->s16, in->s16, n * sizeof(int16_t));
    }
}

/* ------------------------------------------------------------ the DSP core */

/*
 * Per-frame: find the post-gain peak across all channels, derive the gain reduction
 * needed to stay under the ceiling, apply it to every channel with the SAME value so
 * the stereo image stays put.
 *
 * The envelope uses INSTANT attack and exponential release. Instant attack is not a
 * shortcut — without look-ahead it is the only way a limiter can guarantee it never
 * overshoots: smoothing the gain downwards lets the very peak we are trying to catch
 * escape while the gain is still travelling (measured: it pinned the output at full
 * scale, i.e. it degenerated into a clipper). Because the envelope can only ever be
 * >= the current peak, out = peak * gain * (ceiling/env) <= ceiling by construction.
 * Release stays smooth, which is what the ear actually notices.
 */
/*
 * Soft-knee downward compressor, run BEFORE the makeup gain.
 *
 * Why this exists: gain + limiter alone is a poor loudness maximiser. On dense material
 * the limiter simply shaves the peaks, so "+6 dB" delivers far less than +6 dB of
 * perceived loudness and the shaving is what you hear. Compressing first lowers the
 * crest factor, which lets the same makeup gain lift the BODY of the track instead of
 * spending itself on transients the limiter then throws away.
 *
 * The knee is quadratic-interpolated so gain reduction eases in instead of switching on
 * at the threshold - a hard knee is audible as a click on percussive material.
 * The limiter downstream is untouched and still guarantees the ceiling on its own; this
 * stage is only ever allowed to turn the signal DOWN, so it cannot break that promise.
 */
static inline float asb_comp_gain(asb_ctx_t *c, float env) {
    if (!c->comp_on || env < 1e-7f) return 1.0f;

    float db   = 20.0f * log10f(env);
    float over = db - c->thresh_db;
    float half = ASB_COMP_KNEE_DB * 0.5f;

    if (over <= -half) return 1.0f;

    float gr_db;
    if (over >= half) {
        gr_db = over * (c->inv_ratio - 1.0f);
    } else {
        float x = over + half;
        gr_db = (c->inv_ratio - 1.0f) * x * x / (2.0f * ASB_COMP_KNEE_DB);
    }
    return powf(10.0f, gr_db / 20.0f);
}

/* Compressor envelope: smoothed in BOTH directions, unlike the limiter's instant
 * attack. A compressor is meant to ride the loudness, not to catch every sample. */
static inline float asb_step_cenv(asb_ctx_t *c, float peak) {
    float coef = (peak > c->cenv) ? c->catk : c->crel;
    c->cenv = peak + (c->cenv - peak) * coef;
    if (c->cenv < 1e-9f) c->cenv = 0.0f;
    return c->cenv;
}

static inline float asb_step_gr(asb_ctx_t *c, float peak) {
    if (peak > c->env) c->env = peak;                       /* instant attack */
    else c->env = peak + (c->env - peak) * c->rel;          /* slow release   */

    /* keep the envelope out of denormal territory */
    if (c->env < 1e-9f) c->env = 0.0f;

    if (c->env > c->ceiling) return c->ceiling / c->env;
    return 1.0f;
}

static void asb_process_f32(asb_ctx_t *c, audio_buffer_t *in, audio_buffer_t *out) {
    const int ch = c->channels;
    const float g = c->gain;
    const int acc = (c->cfg.outputCfg.accessMode == EFFECT_BUFFER_ACCESS_ACCUMULATE);

    for (size_t f = 0; f < in->frameCount; f++) {
        const float *src = in->f32 + f * ch;
        float *dst = out->f32 + f * ch;

        float peak = 0.0f;
        for (int k = 0; k < ch; k++) {
            float a = fabsf(src[k]);
            if (a > peak) peak = a;
        }
        /* compressor sees the RAW level; the limiter sees what actually reaches it. */
        float cg = asb_comp_gain(c, asb_step_cenv(c, peak)) * c->cmakeup;
        float gr = asb_step_gr(c, peak * cg * g);

        for (int k = 0; k < ch; k++) {
            float v = src[k] * cg * g * gr;
            /* absolute safety net: the limiter should already keep us below this */
            if (v > 1.0f) v = 1.0f;
            else if (v < -1.0f) v = -1.0f;
            if (acc) dst[k] += v; else dst[k] = v;
        }
    }
}

static void asb_process_s16(asb_ctx_t *c, audio_buffer_t *in, audio_buffer_t *out) {
    const int ch = c->channels;
    const float g = c->gain;
    const int acc = (c->cfg.outputCfg.accessMode == EFFECT_BUFFER_ACCESS_ACCUMULATE);

    for (size_t f = 0; f < in->frameCount; f++) {
        const int16_t *src = in->s16 + f * ch;
        int16_t *dst = out->s16 + f * ch;

        float peak = 0.0f;
        for (int k = 0; k < ch; k++) {
            float a = fabsf((float)src[k] / 32768.0f);
            if (a > peak) peak = a;
        }
        float cg = asb_comp_gain(c, asb_step_cenv(c, peak)) * c->cmakeup;
        float gr = asb_step_gr(c, peak * cg * g);

        for (int k = 0; k < ch; k++) {
            float v = ((float)src[k] / 32768.0f) * cg * g * gr;
            if (v > 1.0f) v = 1.0f;
            else if (v < -1.0f) v = -1.0f;
            int32_t s = (int32_t)lrintf(v * 32767.0f);
            if (acc) s += (int32_t)dst[k];
            dst[k] = (int16_t)(s > 32767 ? 32767 : (s < -32768 ? -32768 : s));
        }
    }
}

/* ------------------------------------------------- effect_interface_s impl */

static int32_t asb_process(effect_handle_t self, audio_buffer_t *inBuffer, audio_buffer_t *outBuffer) {
    asb_ctx_t *c = (asb_ctx_t *)self;
    if (c == NULL) return -EINVAL;
    if (inBuffer == NULL || outBuffer == NULL) return -EINVAL;
    if (inBuffer->raw == NULL || outBuffer->raw == NULL) return -EINVAL;
    if (inBuffer->frameCount == 0) return 0;
    if (!c->configured) return -EINVAL;

    if (!c->enabled || c->bypass) {
        asb_passthrough(c, inBuffer, outBuffer);
        return 0;
    }

    if (c->cfg.outputCfg.format == AUDIO_FORMAT_PCM_FLOAT) asb_process_f32(c, inBuffer, outBuffer);
    else                                                   asb_process_s16(c, inBuffer, outBuffer);
    return 0;
}

static int32_t asb_command(effect_handle_t self, uint32_t cmdCode, uint32_t cmdSize,
                           void *pCmdData, uint32_t *replySize, void *pReplyData) {
    asb_ctx_t *c = (asb_ctx_t *)self;
    if (c == NULL) return -EINVAL;

    switch (cmdCode) {
    case EFFECT_CMD_INIT:
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        c->env = 0.0f; c->cenv = 0.0f;
        asb_refresh(c);
        *(int *)pReplyData = 0;
        return 0;

    case EFFECT_CMD_SET_CONFIG:
        if (pCmdData == NULL || cmdSize != sizeof(effect_config_t)
            || pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        memcpy(&c->cfg, pCmdData, sizeof(effect_config_t));
        c->configured = 1;
        c->env = 0.0f; c->cenv = 0.0f;
        asb_refresh(c);
        *(int *)pReplyData = 0;
        return 0;

    case EFFECT_CMD_GET_CONFIG:
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(effect_config_t)) return -EINVAL;
        memcpy(pReplyData, &c->cfg, sizeof(effect_config_t));
        return 0;

    case EFFECT_CMD_RESET:
        c->env = 0.0f; c->cenv = 0.0f;
        return 0;

    case EFFECT_CMD_ENABLE:
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        if (!c->configured) { *(int *)pReplyData = -EINVAL; return 0; }
        c->env = 0.0f; c->cenv = 0.0f;
        asb_refresh(c);            /* pick up any WebUI change on (re)enable */
        c->enabled = 1;
        *(int *)pReplyData = 0;
        return 0;

    case EFFECT_CMD_DISABLE:
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        c->enabled = 0;
        *(int *)pReplyData = 0;
        return 0;

    /* We advertise no param interface; accept and no-op so nothing errors out. */
    case EFFECT_CMD_SET_PARAM:
    case EFFECT_CMD_SET_PARAM_COMMIT:
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        *(int *)pReplyData = 0;
        return 0;

    case EFFECT_CMD_SET_DEVICE:
    case EFFECT_CMD_SET_VOLUME:
    case EFFECT_CMD_SET_AUDIO_MODE:
    case EFFECT_CMD_SET_AUDIO_SOURCE:
    case EFFECT_CMD_SET_CONFIG_REVERSE:
    case EFFECT_CMD_SET_INPUT_DEVICE:
    case EFFECT_CMD_OFFLOAD:
        /* Accept the offload-mode handoff. AudioFlinger sends this when the effect is on
         * an offloaded output; it expects a status int written back. Returning success
         * (0) with no reply made some frameworks treat the effect as offload-incapable
         * and drop it, so write the status when a reply buffer is provided. */
        if (pReplyData != NULL && replySize != NULL && *replySize >= (int)sizeof(int)) {
            *(int *)pReplyData = 0;
        }
        return 0;

    default:
        return -EINVAL;
    }
}

static int32_t asb_get_descriptor(effect_handle_t self, effect_descriptor_t *pDescriptor) {
    if (self == NULL || pDescriptor == NULL) return -EINVAL;
    *pDescriptor = g_asb_descriptor;
    return 0;
}

static const struct effect_interface_s g_asb_interface = {
    .process = asb_process,
    .command = asb_command,
    .get_descriptor = asb_get_descriptor,
    .process_reverse = NULL
};

/* --------------------------------------------- audio_effect_library_t impl */

static int32_t asb_lib_create(const effect_uuid_t *uuid, int32_t sessionId, int32_t ioId,
                              effect_handle_t *pHandle) {
    (void)sessionId; (void)ioId;
    if (uuid == NULL || pHandle == NULL) return -EINVAL;
    if (memcmp(uuid, &g_asb_descriptor.uuid, sizeof(effect_uuid_t)) != 0) return -ENOENT;

    asb_ctx_t *c = (asb_ctx_t *)calloc(1, sizeof(asb_ctx_t));
    if (c == NULL) return -ENOMEM;

    c->iface = &g_asb_interface;
    c->env = 0.0f; c->cenv = 0.0f;
    c->gain = 1.0f;
    c->ceiling = 0.891f;
    c->channels = 2;
    c->bypass = 1;          /* stay out of the way until SET_CONFIG/ENABLE says otherwise */
    c->configured = 0;
    c->enabled = 0;

    *pHandle = (effect_handle_t)c;
    return 0;
}

static int32_t asb_lib_release(effect_handle_t handle) {
    if (handle == NULL) return -EINVAL;
    free(handle);
    return 0;
}

static int32_t asb_lib_get_descriptor(const effect_uuid_t *uuid, effect_descriptor_t *pDescriptor) {
    if (uuid == NULL || pDescriptor == NULL) return -EINVAL;
    if (memcmp(uuid, &g_asb_descriptor.uuid, sizeof(effect_uuid_t)) != 0) return -ENOENT;
    *pDescriptor = g_asb_descriptor;
    return 0;
}

__attribute__((visibility("default")))
audio_effect_library_t AUDIO_EFFECT_LIBRARY_INFO_SYM = {
    .tag = AUDIO_EFFECT_LIBRARY_TAG,
    .version = EFFECT_LIBRARY_API_VERSION,
    .name = ASB_DSP_NAME,
    .implementor = ASB_DSP_IMPLEMENTOR,
    .create_effect = asb_lib_create,
    .release_effect = asb_lib_release,
    .get_descriptor = asb_lib_get_descriptor
};
