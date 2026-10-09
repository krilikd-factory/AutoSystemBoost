/*
 * asb_dsp.c — AutoSystemBoost DSP effect, legacy (HIDL / AELI) effect ABI.
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
 * ONE CORE FOR BOTH ABIs (fix74)
 * ------------------------------
 * This file used to carry its own copy of the gain + compressor + limiter. The AIDL effect
 * moved on - saturation (softclip/postgain), the bass shelf, a bit-exact bypass, the gain
 * pushed over binder - and the copy here did not follow. Worse, it configured itself from
 * persist.asb.dsp.* alone: those land in default_prop, which the vendor audio HAL process
 * cannot read on the phones checked (getprop -Z on OP15), so a loaded effect computed
 * enable=0 gain=0 and sat in bypass. That is the OnePlus 12 / Ace 5 (HIDL HAL) picture once
 * fix73 made the HAL load the library at all.
 *
 * Now:
 * - the math is src/DSP_AIDL/asb_dsp_core.h, the same object the AIDL effect runs;
 * - tunables are read from persist.vendor.asb.dsp.* first (asb_audio_apply.sh writes both
 *   names; the vendor copy is the one a vendor domain may read), the legacy name second;
 * - EFFECT_CMD_SET_PARAM accepts LOUDNESS_ENHANCER_PARAM_TARGET_GAIN_MB, the parameter the
 *   attach daemon pushes (it reads the settings from the system side and also sends 0 when
 *   the live route is not one the user selected), exactly as the AIDL effect does;
 * - the descriptor's TYPE is the standard Loudness Enhancer type. The attach daemon creates
 *   the effect by type AND implementation uuid; with the null type this file had, the two
 *   did not describe the same effect and AudioFlinger can refuse the pair.
 *
 * DESIGN NOTES
 * ------------
 * - process() is strictly realtime-safe: no malloc/free, no syscalls, no locks, no
 *   file or property reads. Everything it needs is precomputed in command().
 * - PCM float and PCM 16-bit are handled. Any other format, or more channels than the
 *   core's per-channel state holds, falls back to a clean passthrough.
 */

#include "asb_effect_abi.h"
#include "asb_dsp_core.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>

#define ASB_DSP_NAME       "ASB Loudness"
#define ASB_DSP_IMPLEMENTOR "AutoSystemBoost"

/* android/system/audio_effects/effect_loudnessenhancer.h: the only parameter of that type. */
#define ASB_LE_PARAM_TARGET_GAIN_MB 0

/* Unique to ASB — must not collide with any other effect on the device. */
static const effect_descriptor_t g_asb_descriptor = {
    /* Standard Loudness Enhancer type (fe3199be-aed0-413f-87bb-11260eb63cf1), the same type
     * the AIDL effect declares and the attach daemon asks for. */
    .type = { 0xfe3199be, 0xaed0, 0x413f, 0x87bb, { 0x11, 0x26, 0x0e, 0xb6, 0x3c, 0xf1 } },
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
    int      gain_override_mb;  /* >= 0: pushed by the attach daemon, wins over properties */

    asb_core_t core;            /* the shared realtime state (asb_dsp_core.h) */
} asb_ctx_t;

/* ---------------------------------------------------------------- helpers */

static int asb_parse_int(const char *buf, int *out) {
    char *end = NULL;
    long v = strtol(buf, &end, 10);
    if (end == buf) return 0;
    *out = (int)v;
    return 1;
}

/* persist.vendor.asb.dsp.<leaf> first, persist.asb.dsp.<leaf> second, then the default. */
static int asb_dsp_prop(const char *leaf, int fallback) {
    char key[96];
    char buf[PROP_VALUE_MAX];
    int v;
    snprintf(key, sizeof(key), "persist.vendor.asb.dsp.%s", leaf);
    if (__system_property_get(key, buf) > 0 && asb_parse_int(buf, &v)) return v;
    snprintf(key, sizeof(key), "persist.asb.dsp.%s", leaf);
    if (__system_property_get(key, buf) > 0 && asb_parse_int(buf, &v)) return v;
    return fallback;
}

static int asb_channel_count(uint32_t mask) {
    int n = __builtin_popcount(mask);
    return n > 0 ? n : 2;
}

/* Recompute everything process() depends on. Called from command() only. */
static void asb_refresh(asb_ctx_t *c) {
    int enable = asb_dsp_prop("enable", 0);
    int gain   = asb_dsp_prop("gain_mb", 0);
    if (c->gain_override_mb >= 0) {
        gain = c->gain_override_mb;
        if (gain > 0) enable = 1;
    }
    uint32_t rate = c->cfg.outputCfg.samplingRate ? c->cfg.outputCfg.samplingRate : 48000u;
    int ch = asb_channel_count(c->cfg.outputCfg.channels);
    int fmt_ok = (c->cfg.outputCfg.format == AUDIO_FORMAT_PCM_FLOAT
                  || c->cfg.outputCfg.format == AUDIO_FORMAT_PCM_16_BIT);
    /* The core keeps per-channel filter state for ASB_MAX_CH channels. More than that is
     * passed through untouched rather than indexed past the arrays. */
    if (ch > ASB_MAX_CH) fmt_ok = 0;

    asb_core_configure_ex(&c->core, enable, gain,
                          asb_dsp_prop("ceiling_mb", -15),
                          asb_dsp_prop("comp", 1),
                          asb_dsp_prop("comp_ratio_x10", 60),
                          asb_dsp_prop("comp_thresh_mb", -2400),
                          ch, rate, fmt_ok,
                          asb_dsp_prop("softclip", 0),
                          asb_dsp_prop("postgain_x100", 300));
    /* After configure: it sets the channel count the shelf needs. */
    asb_core_set_bass(&c->core, asb_dsp_prop("bass_db", 0), rate);
    asb_core_set_voice(&c->core, asb_dsp_prop("voice", 0), rate);
}

/* Copy or accumulate without touching the samples. */
static void asb_passthrough(asb_ctx_t *c, audio_buffer_t *in, audio_buffer_t *out) {
    size_t n = in->frameCount * (size_t)asb_channel_count(c->cfg.outputCfg.channels);
    int acc = (c->cfg.outputCfg.accessMode == EFFECT_BUFFER_ACCESS_ACCUMULATE);

    if (c->cfg.outputCfg.format == AUDIO_FORMAT_PCM_FLOAT) {
        if (acc) { for (size_t i = 0; i < n; i++) out->f32[i] += in->f32[i]; }
        else if (in->f32 != out->f32) memcpy(out->f32, in->f32, n * sizeof(float));
    } else if (c->cfg.outputCfg.format == AUDIO_FORMAT_PCM_16_BIT) {
        if (acc) {
            for (size_t i = 0; i < n; i++) {
                int32_t s = (int32_t)out->s16[i] + (int32_t)in->s16[i];
                out->s16[i] = (int16_t)(s > 32767 ? 32767 : (s < -32768 ? -32768 : s));
            }
        } else if (in->s16 != out->s16) memcpy(out->s16, in->s16, n * sizeof(int16_t));
    }
    /* Any other format: we never claimed to handle it, the framework's own copy stands. */
}

/* ------------------------------------------------- effect_interface_s impl */

static int32_t asb_process(effect_handle_t self, audio_buffer_t *inBuffer, audio_buffer_t *outBuffer) {
    asb_ctx_t *c = (asb_ctx_t *)self;
    if (c == NULL) return -EINVAL;
    if (inBuffer == NULL || outBuffer == NULL) return -EINVAL;
    if (inBuffer->raw == NULL || outBuffer->raw == NULL) return -EINVAL;
    if (inBuffer->frameCount == 0) return 0;
    if (!c->configured) return -EINVAL;

    if (!c->enabled || c->core.bypass) {
        asb_passthrough(c, inBuffer, outBuffer);
        return 0;
    }

    int acc = (c->cfg.outputCfg.accessMode == EFFECT_BUFFER_ACCESS_ACCUMULATE);
    if (c->cfg.outputCfg.format == AUDIO_FORMAT_PCM_FLOAT)
        asb_core_process_f32(&c->core, inBuffer->f32, outBuffer->f32, inBuffer->frameCount, acc);
    else
        asb_core_process_s16(&c->core, inBuffer->s16, outBuffer->s16, inBuffer->frameCount, acc);
    return 0;
}

/* EFFECT_CMD_SET_PARAM payload: effect_param_t { status, psize, vsize, data[psize padded
 * to 4 bytes, then vsize] }. Returns 1 and the gain when it is the Loudness Enhancer
 * target-gain parameter, 0 for anything else. */
static int asb_param_gain(uint32_t cmdSize, const void *pCmdData, int32_t *gain_mb) {
    if (pCmdData == NULL || cmdSize < sizeof(effect_param_t)) return 0;
    const effect_param_t *p = (const effect_param_t *)pCmdData;
    if (p->psize != sizeof(int32_t) || p->vsize < sizeof(int32_t)) return 0;
    uint32_t voff = ((p->psize - 1) / sizeof(int32_t) + 1) * sizeof(int32_t);
    if ((size_t)cmdSize < sizeof(effect_param_t) + voff + sizeof(int32_t)) return 0;
    int32_t param;
    memcpy(&param, p->data, sizeof(param));
    if (param != ASB_LE_PARAM_TARGET_GAIN_MB) return 0;
    memcpy(gain_mb, p->data + voff, sizeof(*gain_mb));
    return 1;
}

static int32_t asb_command(effect_handle_t self, uint32_t cmdCode, uint32_t cmdSize,
                           void *pCmdData, uint32_t *replySize, void *pReplyData) {
    asb_ctx_t *c = (asb_ctx_t *)self;
    if (c == NULL) return -EINVAL;

    switch (cmdCode) {
    case EFFECT_CMD_INIT:
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        asb_core_reset(&c->core);
        asb_refresh(c);
        *(int *)pReplyData = 0;
        return 0;

    case EFFECT_CMD_SET_CONFIG:
        if (pCmdData == NULL || cmdSize != sizeof(effect_config_t)
            || pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        memcpy(&c->cfg, pCmdData, sizeof(effect_config_t));
        c->configured = 1;
        asb_core_reset(&c->core);
        asb_refresh(c);
        *(int *)pReplyData = 0;
        return 0;

    case EFFECT_CMD_GET_CONFIG:
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(effect_config_t)) return -EINVAL;
        memcpy(pReplyData, &c->cfg, sizeof(effect_config_t));
        return 0;

    case EFFECT_CMD_RESET:
        asb_core_reset(&c->core);
        return 0;

    case EFFECT_CMD_ENABLE:
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        if (!c->configured) { *(int *)pReplyData = -EINVAL; return 0; }
        asb_core_reset(&c->core);
        asb_refresh(c);            /* pick up any WebUI change on (re)enable */
        c->enabled = 1;
        *(int *)pReplyData = 0;
        return 0;

    case EFFECT_CMD_DISABLE:
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        c->enabled = 0;
        *(int *)pReplyData = 0;
        return 0;

    /* The attach daemon's gain push. Every tunable is re-read with it, so one push carries
     * a compressor / saturation / bass edit as well (the daemon pushes on any change).
     * Other parameters are accepted and ignored so nothing upstream errors out. */
    case EFFECT_CMD_SET_PARAM: {
        if (pReplyData == NULL || replySize == NULL || *replySize != sizeof(int)) return -EINVAL;
        int32_t g;
        if (asb_param_gain(cmdSize, pCmdData, &g)) {
            c->gain_override_mb = asb_core_clamp(g, 0, ASB_GAIN_MB_MAX);
            asb_refresh(c);
        }
        *(int *)pReplyData = 0;
        return 0;
    }

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
    c->gain_override_mb = -1;
    c->core.gain = 1.0f;
    c->core.ceiling = 0.891f;
    c->core.channels = 2;
    c->core.bypass = 1;     /* stay out of the way until SET_CONFIG/ENABLE says otherwise */
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
