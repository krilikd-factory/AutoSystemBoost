#!/bin/sh
# fix74: the legacy (HIDL / AELI) DSP effect runs the shared core and takes the gain the
# attach daemon pushes. Before, it had its own gain+limiter copy (no saturation, no bass,
# no bit-exact bypass), configured itself from persist.asb.dsp.* alone - which a vendor
# HAL process cannot read, leaving a loaded effect in bypass - and declared the null type
# while the daemon creates it by Loudness Enhancer type + implementation uuid.
#
# Executable fixture: the REAL src/DSP/asb_dsp.c compiled on the host against a property
# stub, driven through its own AELI create / command() / process() entry points.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/DSP/asb_dsp.c"
fail() { echo "FAIL legacy dsp core: $*" >&2; exit 1; }
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || CC=gcc
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

grep -q '#include "asb_dsp_core.h"' "$SRC" || fail "legacy effect does not include the shared core"
grep -q 'asb_core_configure_ex' "$SRC" || fail "legacy effect does not configure the shared core"
grep -q 'persist.vendor.asb.dsp.%s' "$SRC" || fail "legacy effect ignores the vendor-namespace props"
grep -q 'I"$SCRIPT_DIR/DSP_AIDL"' "$ROOT/src/build_ndk_release.sh" || fail "NDK build lacks the core include path"
for w in build-debug build-release; do
  grep -q 'src/DSP_AIDL/asb_dsp_core.h' "$ROOT/.github/workflows/$w.yml" || fail "$w.yml does not require the core header"
done

mkdir -p "$T/inc/sys"
cat > "$T/inc/sys/system_properties.h" <<'X'
#pragma once
#include <string.h>
#define PROP_VALUE_MAX 92
#define ASB_TEST_PROPS 16
static char g_tp_key[ASB_TEST_PROPS][96];
static char g_tp_val[ASB_TEST_PROPS][PROP_VALUE_MAX];
static int  g_tp_n;
static void tp_set(const char *k, const char *v) {
    for (int i = 0; i < g_tp_n; i++) if (!strcmp(g_tp_key[i], k)) { strcpy(g_tp_val[i], v); return; }
    strcpy(g_tp_key[g_tp_n], k); strcpy(g_tp_val[g_tp_n], v); g_tp_n++;
}
static void tp_clear(void) { g_tp_n = 0; }
static int __system_property_get(const char *k, char *v) {
    for (int i = 0; i < g_tp_n; i++) if (!strcmp(g_tp_key[i], k)) { strcpy(v, g_tp_val[i]); return (int)strlen(v); }
    v[0] = 0; return 0;
}
X

cat > "$T/drv.c" <<'X'
#include "asb_dsp.c"
#include <stdio.h>

static effect_handle_t h;
static int cmd(uint32_t code, uint32_t sz, void *data) {
    int reply = 12345; uint32_t rs = sizeof(int);
    int r = (*h)->command(h, code, sz, data, &rs, &reply);
    if (r != 0) return r;
    return reply;
}
static void make(int ch, uint8_t fmt, uint8_t access) {
    const effect_uuid_t u = g_asb_descriptor.uuid;
    if (AELI.create_effect(&u, 0, 0, &h) != 0) { puts("create"); exit(1); }
    effect_config_t cfg; memset(&cfg, 0, sizeof(cfg));
    cfg.inputCfg.samplingRate = cfg.outputCfg.samplingRate = 48000;
    uint32_t mask = (1u << ch) - 1u;
    cfg.inputCfg.channels = cfg.outputCfg.channels = mask;
    cfg.inputCfg.format = cfg.outputCfg.format = fmt;
    cfg.outputCfg.accessMode = access;
    if (cmd(EFFECT_CMD_INIT, 0, NULL) != 0) { puts("init"); exit(1); }
    if (cmd(EFFECT_CMD_SET_CONFIG, sizeof(cfg), &cfg) != 0) { puts("cfg"); exit(1); }
    if (cmd(EFFECT_CMD_ENABLE, 0, NULL) != 0) { puts("enable"); exit(1); }
}
static int push(int32_t param, int32_t value, uint32_t size_override) {
    uint8_t buf[sizeof(effect_param_t) + 8] = {0};
    effect_param_t *p = (effect_param_t *)buf;
    p->psize = 4; p->vsize = 4;
    memcpy(p->data, &param, 4); memcpy(p->data + 4, &value, 4);
    return cmd(EFFECT_CMD_SET_PARAM, size_override ? size_override : sizeof(buf), buf);
}
#define N 4800
static float in_f[N * 10], out_f[N * 10];
static void sig_f(int ch, float amp) {
    for (int i = 0; i < N; i++) for (int k = 0; k < ch; k++)
        in_f[i * ch + k] = amp * sinf(2.0f * 3.14159f * 440.0f * (float)i / 48000.0f + (float)k);
}
static float run_f(int ch) {
    audio_buffer_t a = { .frameCount = N, .f32 = in_f }, b = { .frameCount = N, .f32 = out_f };
    memset(out_f, 0, sizeof(out_f));
    if ((*h)->process(h, &a, &b) != 0) { puts("process"); exit(1); }
    double si = 0, so = 0;
    for (int i = 0; i < N * ch; i++) { si += in_f[i] * in_f[i]; so += out_f[i] * out_f[i]; }
    return (float)(10.0 * log10(so / si));
}
static int bitexact(int ch) { return memcmp(in_f, out_f, sizeof(float) * N * ch) == 0; }
static float peak_out(int ch) { float m = 0; for (int i = 0; i < N * ch; i++) if (fabsf(out_f[i]) > m) m = fabsf(out_f[i]); return m; }

int main(void) {
    /* descriptor: Loudness Enhancer type, ASB uuid */
    const effect_uuid_t le = { 0xfe3199be, 0xaed0, 0x413f, 0x87bb, { 0x11, 0x26, 0x0e, 0xb6, 0x3c, 0xf1 } };
    if (memcmp(&g_asb_descriptor.type, &le, sizeof(le))) { puts("FAIL type is not Loudness Enhancer"); return 1; }

    /* 1. props invisible (vendor HAL view): bit-exact bypass */
    tp_clear(); make(2, AUDIO_FORMAT_PCM_FLOAT, EFFECT_BUFFER_ACCESS_WRITE); sig_f(2, 0.2f);
    run_f(2); if (!bitexact(2)) { puts("FAIL no props should be a bit-exact bypass"); return 1; }

    /* 2. the daemon's gain push turns it on without any readable property */
    if (push(0, 600, 0) != 0) { puts("FAIL set_param status"); return 1; }
    float d = run_f(2);
    if (d < 3.0f) { printf("FAIL pushed +6 dB delivered %.2f dB\n", d); return 1; }
    if (peak_out(2) > 0.984f) {   /* default ceiling -15 mB = 0.983 */ printf("FAIL limiter ceiling broken: %.3f\n", peak_out(2)); return 1; }

    /* 3. route not selected -> daemon pushes 0 -> bit-exact again */
    push(0, 0, 0); run_f(2);
    if (!bitexact(2)) { puts("FAIL gain 0 push should bypass bit-exact"); return 1; }

    /* 4. malformed / foreign parameters are ignored, not applied */
    push(0, 900, 10); run_f(2);
    if (!bitexact(2)) { puts("FAIL truncated SET_PARAM was applied"); return 1; }
    push(7, 900, 0); run_f(2);
    if (!bitexact(2)) { puts("FAIL foreign parameter id was applied as gain"); return 1; }
    (*h)->command(h, EFFECT_CMD_DISABLE, 0, NULL, &(uint32_t){4}, &(int){0});
    AELI.release_effect(h);

    /* 5. vendor-namespace props win over the legacy name */
    tp_clear();
    tp_set("persist.asb.dsp.enable", "1"); tp_set("persist.asb.dsp.gain_mb", "0");
    tp_set("persist.vendor.asb.dsp.enable", "1"); tp_set("persist.vendor.asb.dsp.gain_mb", "600");
    make(2, AUDIO_FORMAT_PCM_FLOAT, EFFECT_BUFFER_ACCESS_WRITE); sig_f(2, 0.2f);
    d = run_f(2); if (d < 3.0f) { printf("FAIL vendor prop not preferred (%.2f dB)\n", d); return 1; }
    AELI.release_effect(h);

    /* 6. shared-core features reach the legacy effect: softclip is bounded */
    tp_set("persist.vendor.asb.dsp.softclip", "1"); tp_set("persist.vendor.asb.dsp.gain_mb", "2500");
    make(2, AUDIO_FORMAT_PCM_FLOAT, EFFECT_BUFFER_ACCESS_WRITE); sig_f(2, 0.9f);
    run_f(2); if (peak_out(2) > 1.0f) { puts("FAIL softclip escaped [-1,1]"); return 1; }
    AELI.release_effect(h);

    /* 7. 16-bit ACCUMULATE with softclip adds into the output instead of overwriting */
    make(2, AUDIO_FORMAT_PCM_16_BIT, EFFECT_BUFFER_ACCESS_ACCUMULATE);
    {
        static int16_t i16[N * 2], o16[N * 2];
        for (int i = 0; i < N * 2; i++) { i16[i] = 0; o16[i] = 1000; }
        audio_buffer_t a = { .frameCount = N, .s16 = i16 }, b = { .frameCount = N, .s16 = o16 };
        (*h)->process(h, &a, &b);
        for (int i = 0; i < N * 2; i++) if (o16[i] != 1000) { puts("FAIL s16 accumulate overwrote the mix"); return 1; }
    }
    AELI.release_effect(h);

    /* 8. more channels than the core's state holds: passthrough, no out-of-bounds */
    tp_set("persist.vendor.asb.dsp.bass_db", "6");
    make(10, AUDIO_FORMAT_PCM_FLOAT, EFFECT_BUFFER_ACCESS_WRITE); sig_f(10, 0.2f);
    run_f(10); if (!bitexact(10)) { puts("FAIL 10-channel stream was processed"); return 1; }
    AELI.release_effect(h);

    puts("ok");
    return 0;
}
X

_san=""
printf 'int main(void){return 0;}\n' > "$T/probe.c"
if "$CC" -fsanitize=address,undefined "$T/probe.c" -o "$T/probe" >/dev/null 2>&1 && "$T/probe" >/dev/null 2>&1; then
  _san="-fsanitize=address,undefined -fno-sanitize-recover=all"
fi
# shellcheck disable=SC2086
"$CC" -std=gnu11 -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Werror \
  $_san -I"$T/inc" -I"$ROOT/src/DSP" -I"$ROOT/src/DSP_AIDL" "$T/drv.c" -lm -o "$T/drv" \
  || fail "the legacy effect does not compile against the shared core"
out="$("$T/drv" 2>&1)" || fail "$out"
[ "$out" = "ok" ] || fail "$out"
echo "PASS legacy DSP runs the shared core"
