/*
 * asb_dsp_core.h — AutoSystemBoost loudness DSP, interface-agnostic core.
 *
 * The processing math (soft-knee compressor + auto make-up + true-peak limiter +
 * make-up gain) is lifted verbatim from src/DSP/asb_dsp.c. It is deliberately free
 * of any HAL / AIDL type so the same object serves both the legacy effect and the
 * new AIDL wrapper. Everything the realtime path needs is precomputed in
 * asb_core_configure(); asb_core_process_*() is realtime-safe (no alloc, no lock,
 * no syscalls).
 */
#ifndef ASB_DSP_CORE_H
#define ASB_DSP_CORE_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>

#define ASB_GAIN_MB_MIN    0
#define ASB_GAIN_MB_MAX    1800
#define ASB_CEIL_MB_MIN   (-600)
#define ASB_CEIL_MB_MAX   (-30)
#define ASB_RATIO_MIN      10
#define ASB_RATIO_MAX      80
#define ASB_THRESH_MB_MIN (-4000)
#define ASB_THRESH_MB_MAX (-300)

#define ASB_RELEASE_MS   120.0f
#define ASB_COMP_ATK_MS  8.0f
#define ASB_COMP_REL_MS  180.0f
#define ASB_COMP_KNEE_DB 8.0f

typedef struct {
    float    gain;
    float    ceiling;
    float    rel;
    float    env;
    int      comp_on;
    float    thresh_db;
    float    inv_ratio;
    float    cmakeup;
    float    catk;
    float    crel;
    float    cenv;
    int      channels;
    int      bypass;
} asb_core_t;

static inline int  asb_core_clamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline float asb_core_mb_to_lin(int mb) { return powf(10.0f, (float)mb / 2000.0f); }

static inline float asb_core_coef(float ms, uint32_t rate) {
    if (rate == 0 || ms <= 0.0f) return 0.0f;
    return expf(-1.0f / ((ms / 1000.0f) * (float)rate));
}

/*
 * Recompute the realtime state from raw tunables (already read from wherever the
 * caller keeps them: properties for legacy, the same properties for AIDL).
 * gain_mb/ceil_mb/thresh_mb are in millibels, ratio_x10 is ratio*10.
 */
static inline void asb_core_configure(asb_core_t *c, int enabled, int gain_mb,
                                      int ceil_mb, int comp, int ratio_x10,
                                      int thresh_mb, int channels, uint32_t rate,
                                      int fmt_ok) {
    gain_mb   = asb_core_clamp(gain_mb, ASB_GAIN_MB_MIN, ASB_GAIN_MB_MAX);
    ceil_mb   = asb_core_clamp(ceil_mb, ASB_CEIL_MB_MIN, ASB_CEIL_MB_MAX);
    ratio_x10 = asb_core_clamp(ratio_x10, ASB_RATIO_MIN, ASB_RATIO_MAX);
    thresh_mb = asb_core_clamp(thresh_mb, ASB_THRESH_MB_MIN, ASB_THRESH_MB_MAX);
    if (rate == 0) rate = 48000u;

    c->gain      = asb_core_mb_to_lin(gain_mb);
    c->ceiling   = asb_core_mb_to_lin(ceil_mb);
    c->comp_on   = (comp && ratio_x10 > ASB_RATIO_MIN) ? 1 : 0;
    c->thresh_db = (float)thresh_mb / 100.0f;
    c->inv_ratio = 10.0f / (float)ratio_x10;
    if (c->comp_on) {
        float over0 = -c->thresh_db;
        float mk_db = -over0 * (c->inv_ratio - 1.0f) * 0.5f;
        c->cmakeup = powf(10.0f, mk_db / 20.0f);
    } else {
        c->cmakeup = 1.0f;
    }
    c->rel      = asb_core_coef(ASB_RELEASE_MS, rate);
    c->catk     = asb_core_coef(ASB_COMP_ATK_MS, rate);
    c->crel     = asb_core_coef(ASB_COMP_REL_MS, rate);
    c->channels = channels > 0 ? channels : 2;
    c->bypass   = (!enabled || gain_mb <= 0 || !fmt_ok) ? 1 : 0;
}

static inline void asb_core_reset(asb_core_t *c) { c->env = 0.0f; c->cenv = 0.0f; }

static inline float asb_core_comp_gain(asb_core_t *c, float env) {
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

static inline float asb_core_step_cenv(asb_core_t *c, float peak) {
    float coef = (peak > c->cenv) ? c->catk : c->crel;
    c->cenv = peak + (c->cenv - peak) * coef;
    if (c->cenv < 1e-9f) c->cenv = 0.0f;
    return c->cenv;
}

static inline float asb_core_step_gr(asb_core_t *c, float peak) {
    if (peak > c->env) c->env = peak;
    else c->env = peak + (c->env - peak) * c->rel;
    if (c->env < 1e-9f) c->env = 0.0f;
    if (c->env > c->ceiling) return c->ceiling / c->env;
    return 1.0f;
}

/* Interleaved float. accumulate=0 overwrites, =1 mixes into dst. in may alias out. */
static inline void asb_core_process_f32(asb_core_t *c, const float *in, float *out,
                                        size_t frames, int accumulate) {
    const int ch = c->channels;
    const float g = c->gain;
    for (size_t f = 0; f < frames; f++) {
        const float *src = in + f * ch;
        float *dst = out + f * ch;
        float peak = 0.0f;
        for (int k = 0; k < ch; k++) { float a = fabsf(src[k]); if (a > peak) peak = a; }
        float cg = asb_core_comp_gain(c, asb_core_step_cenv(c, peak)) * c->cmakeup;
        float gr = asb_core_step_gr(c, peak * cg * g);
        for (int k = 0; k < ch; k++) {
            float v = src[k] * cg * g * gr;
            if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
            if (accumulate) dst[k] += v; else dst[k] = v;
        }
    }
}

/* Interleaved int16. */
static inline void asb_core_process_s16(asb_core_t *c, const int16_t *in, int16_t *out,
                                        size_t frames, int accumulate) {
    const int ch = c->channels;
    const float g = c->gain;
    for (size_t f = 0; f < frames; f++) {
        const int16_t *src = in + f * ch;
        int16_t *dst = out + f * ch;
        float peak = 0.0f;
        for (int k = 0; k < ch; k++) { float a = fabsf((float)src[k] / 32768.0f); if (a > peak) peak = a; }
        float cg = asb_core_comp_gain(c, asb_core_step_cenv(c, peak)) * c->cmakeup;
        float gr = asb_core_step_gr(c, peak * cg * g);
        for (int k = 0; k < ch; k++) {
            float v = ((float)src[k] / 32768.0f) * cg * g * gr;
            if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
            int32_t s = (int32_t)lrintf(v * 32767.0f);
            if (accumulate) s += (int32_t)dst[k];
            dst[k] = (int16_t)(s > 32767 ? 32767 : (s < -32768 ? -32768 : s));
        }
    }
}

#endif /* ASB_DSP_CORE_H */
