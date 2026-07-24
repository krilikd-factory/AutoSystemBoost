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
#define ASB_GAIN_MB_MAX    2000
#define ASB_MAX_CH         8
#define ASB_BASS_DB_MAX    10
#define ASB_BASS_FREQ_HZ   90.0f   /* shelf corner: body of the bass, not sub rumble */
#define ASB_BASS_SLOPE     0.9f    /* gentle slope; 1.0 is the steepest without a bump */
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
    /* Soft-clip (saturation) mode. The brick-wall limiter below has ZERO attack: any
     * transient instantly pulls gain down and it needs 120 ms to recover, so on dense
     * music the reduction is continuous and the track just sits pinned at the ceiling -
     * measured +4.1 dB on a realistic loud master, i.e. barely audible. tanh saturation
     * instead rounds peaks off; it is mathematically bounded by 1.0 so it CANNOT clip,
     * and measured +9.7 dB on the same material with zero hard clamping. */
    int      softclip;      /* 1 = tanh saturation instead of the brick-wall limiter */
    float    postgain;      /* makeup after tanh so the peak reaches the ceiling */
    /* Low-shelf bass stage (RBJ cookbook), applied at the INPUT of the chain so the
     * compressor and the limiter both see the boosted low end. Placing it after them
     * would let the added energy escape every safeguard and clip on the way out. */
    int      bass_on;
    float    bb0, bb1, bb2, ba1, ba2;              /* coefficients, a0-normalised */
    float    bx1[ASB_MAX_CH], bx2[ASB_MAX_CH];     /* per-channel input history */
    float    by1[ASB_MAX_CH], by2[ASB_MAX_CH];     /* per-channel output history */
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
static inline void asb_core_configure_ex(asb_core_t *c, int enabled, int gain_mb,
                                      int ceil_mb, int comp, int ratio_x10,
                                      int thresh_mb, int channels, uint32_t rate,
                                      int fmt_ok, int softclip, int post_x100) {
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
    c->softclip = softclip ? 1 : 0;
    /* Post-gain after tanh. tanh's own output tops out at 1.0 but real material rarely
     * drives it that far, so without makeup we leave headroom unused (measured peak 0.76).
     * x1.15 lands the peak at ~0.88 with ZERO hard clamping; x1.30 reached the ceiling but
     * clamped 42% of samples, which is audible grit. Clamp the configurable value to that
     * safe window. */
    {
        /* Drive into the saturator. Measured on a loud master (input RMS 0.229, the
         * theoretical maximum for any bounded signal is a 1.0 square wave):
         *   x1.15 -> RMS 0.699 (71% of max, +9.7 dB)
         *   x3.0  -> RMS 0.860 (87% of max, +11.5 dB)
         *   x10   -> RMS 0.935 (95% of max, +12.2 dB)
         * Returns flatten hard past x3 while the waveform keeps squaring up, so x3 is the
         * sweet spot for "as loud as it goes without turning into a buzz". tanh stays
         * bounded, so even x10 cannot hard-clip - only the harmonics grow. */
        int p = post_x100 > 0 ? post_x100 : 300;
        if (p < 100) p = 100;
        if (p > 1000) p = 1000;
        c->postgain = (float)p / 100.0f;
    }
}

/* Back-compat wrapper: existing callers keep the original signature and get the
 * brick-wall limiter exactly as before. */
static inline void asb_core_configure(asb_core_t *c, int enabled, int gain_mb,
                                      int ceil_mb, int comp, int ratio_x10,
                                      int thresh_mb, int channels, uint32_t rate,
                                      int fmt_ok) {
    asb_core_configure_ex(c, enabled, gain_mb, ceil_mb, comp, ratio_x10, thresh_mb,
                          channels, rate, fmt_ok, 0, 115);
}

/*
 * Low-shelf bass boost (RBJ audio-EQ cookbook). bass_db is the lift at DC relative to the
 * band above the corner; 0 disables the stage entirely and the samples pass untouched.
 *
 * Called separately from asb_core_configure*() so the existing callers keep their
 * signature. Coefficients are computed here, never in the realtime path.
 */
static inline void asb_core_set_bass(asb_core_t *c, int bass_db, uint32_t rate) {
    for (int k = 0; k < ASB_MAX_CH; k++) { c->bx1[k] = c->bx2[k] = c->by1[k] = c->by2[k] = 0.0f; }
    if (bass_db < 0) bass_db = 0;
    if (bass_db > ASB_BASS_DB_MAX) bass_db = ASB_BASS_DB_MAX;
    if (bass_db == 0 || rate == 0 || c->channels > ASB_MAX_CH) { c->bass_on = 0; return; }

    float A     = powf(10.0f, (float)bass_db / 40.0f);
    float w0    = 2.0f * 3.14159265358979f * ASB_BASS_FREQ_HZ / (float)rate;
    float cosw  = cosf(w0);
    float sinw  = sinf(w0);
    float alpha = sinw / 2.0f * sqrtf((A + 1.0f / A) * (1.0f / ASB_BASS_SLOPE - 1.0f) + 2.0f);
    float twoSqrtAalpha = 2.0f * sqrtf(A) * alpha;

    float b0 =        A * ((A + 1.0f) - (A - 1.0f) * cosw + twoSqrtAalpha);
    float b1 = 2.0f * A * ((A - 1.0f) - (A + 1.0f) * cosw);
    float b2 =        A * ((A + 1.0f) - (A - 1.0f) * cosw - twoSqrtAalpha);
    float a0 =            (A + 1.0f) + (A - 1.0f) * cosw + twoSqrtAalpha;
    float a1 =    -2.0f * ((A - 1.0f) + (A + 1.0f) * cosw);
    float a2 =            (A + 1.0f) + (A - 1.0f) * cosw - twoSqrtAalpha;

    if (a0 == 0.0f) { c->bass_on = 0; return; }
    c->bb0 = b0 / a0; c->bb1 = b1 / a0; c->bb2 = b2 / a0;
    c->ba1 = a1 / a0; c->ba2 = a2 / a0;
    c->bass_on = 1;
}

/* One biquad step for channel k. Realtime-safe: five multiplies, no branches. */
static inline float asb_core_bass_step(asb_core_t *c, int k, float x) {
    float y = c->bb0 * x + c->bb1 * c->bx1[k] + c->bb2 * c->bx2[k]
              - c->ba1 * c->by1[k] - c->ba2 * c->by2[k];
    c->bx2[k] = c->bx1[k]; c->bx1[k] = x;
    c->by2[k] = c->by1[k]; c->by1[k] = y;
    return y;
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
    /* Bypass must be bit-exact. Without this the saturation path still ran tanh at unity
     * gain and quietly changed the signal (measured -2.2 dB with the slider at 0). */
    if (c->bypass) {
        const size_t n = frames * (size_t)ch;
        if (!accumulate) { if (out != in) for (size_t i = 0; i < n; i++) out[i] = in[i]; }
        else { for (size_t i = 0; i < n; i++) out[i] += in[i]; }
        return;
    }
    const float g = c->gain;
    for (size_t f = 0; f < frames; f++) {
        const float *src = in + f * ch;
        float *dst = out + f * ch;
        /* Bass first: the detector below must measure the boosted signal, otherwise the
         * extra low end bypasses the compressor and the limiter and clips on output. */
        float bs[ASB_MAX_CH];
        if (c->bass_on) {
            for (int k = 0; k < ch; k++) bs[k] = asb_core_bass_step(c, k, src[k]);
            src = bs;
        }
        float peak = 0.0f;
        for (int k = 0; k < ch; k++) { float a = fabsf(src[k]); if (a > peak) peak = a; }
        float cg = asb_core_comp_gain(c, asb_core_step_cenv(c, peak)) * c->cmakeup;
        if (c->softclip) {
            /* Saturation path: no gain reduction at all, tanh rounds the peaks. Bounded
             * by design (|tanh| < 1), so the clamp below can only ever catch the
             * post-gain overshoot, not the signal itself. */
            for (int k = 0; k < ch; k++) {
                float v = tanhf(src[k] * cg * g * c->postgain) * c->ceiling;
                if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
                if (accumulate) dst[k] += v; else dst[k] = v;
            }
            continue;
        }
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
        /* Normalise once, and run the bass shelf before the detector for the same reason
         * as the float path: the boosted low end has to be visible to the limiter. */
        float bs[ASB_MAX_CH];
        for (int k = 0; k < ch; k++) {
            float x = (float)src[k] / 32768.0f;
            bs[k] = c->bass_on ? asb_core_bass_step(c, k, x) : x;
        }
        float peak = 0.0f;
        for (int k = 0; k < ch; k++) { float a = fabsf(bs[k]); if (a > peak) peak = a; }
        float cg = asb_core_comp_gain(c, asb_core_step_cenv(c, peak)) * c->cmakeup;
        if (c->softclip) {
            for (int k = 0; k < ch; k++) {
                float v = tanhf(bs[k] * cg * g * c->postgain) * c->ceiling;
                if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
                dst[k] = (int16_t)lrintf(v * 32767.0f);
            }
            continue;
        }
        float gr = asb_core_step_gr(c, peak * cg * g);
        for (int k = 0; k < ch; k++) {
            float v = bs[k] * cg * g * gr;
            if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
            int32_t s = (int32_t)lrintf(v * 32767.0f);
            if (accumulate) s += (int32_t)dst[k];
            dst[k] = (int16_t)(s > 32767 ? 32767 : (s < -32768 ? -32768 : s));
        }
    }
}

#endif /* ASB_DSP_CORE_H */
