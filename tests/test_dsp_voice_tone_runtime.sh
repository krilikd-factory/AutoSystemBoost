#!/bin/sh
# fix75: DSP voice tone (dsp_voice). The shared core adds +0.5 dB/step at 350 Hz and
# -0.6 dB/step at 3.2 kHz; measured here through the REAL legacy effect (asb_dsp.c) on
# sines below the compressor threshold, so only the EQ moves the level. Also checks the
# wiring config -> apply script -> vendor prop -> both effects -> WebUI -> freshness gate.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL dsp voice tone: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

for f in config/governor.conf config/governor.conf.shipped; do
  grep -qx 'dsp_voice=0' "$ROOT/$f" || fail "$f lacks dsp_voice=0"
done
grep -qx 'dsp_voice|advanced|webui_sensitive' "$ROOT/config/key_ownership.tsv" || fail "ownership registry"
[ "$(grep -c ' dsp_voice ' "$ROOT/common/install.sh")" = 2 ] || fail "installer does not carry dsp_voice over on update"
grep -q '_dspp voice "$_vox"' "$ROOT/runtime/asb_audio_apply.sh" || fail "apply script does not publish the voice prop"
grep -q 'bass_db voice; do' "$ROOT/runtime/asb_audio_apply.sh" || fail "voice prop not mirrored into the vendor namespace"
grep -q 'asb_core_set_voice(&c->core, asb_dsp_prop("voice", 0), rate);' "$ROOT/src/DSP/asb_dsp.c" || fail "legacy effect ignores voice"
grep -q 'asb_core_set_voice(&mCore, voice' "$ROOT/src/DSP_AIDL/asb_effect_aidl.cpp" || fail "AIDL effect ignores voice"
grep -q 'for _lit in " voice="; do' "$ROOT/src/build_ndk_release.sh" || fail "build does not warn about a pre-voice AIDL prebuilt"
UI="$ROOT/webroot/index.html"
grep -q "{ key:'dsp_voice', type:'range', def:'0', min:0, max:10" "$UI" || fail "WebUI card missing"
grep -q "dsp_voice:APPLY_LIVE" "$UI" || fail "WebUI apply mode missing"
grep -q "var AUDIO_DSP_KEYS = \['dsp_loudness','dsp_bass','dsp_voice'" "$UI" || fail "WebUI does not push voice live"
grep -q "key:'dsp_voice', on:function(v){ return Number(v) > 0; }," "$UI" || fail "dependency on DSP Loudness not explained"
for l in ar de es fr hy id it pt ru tr uk zh; do
  grep -q '"dsp_voice"' "$ROOT/webroot/i18n/$l.json" || fail "no $l translation"
done

mkdir -p "$T/inc/sys"
cat > "$T/inc/sys/system_properties.h" <<'X'
#pragma once
#include <string.h>
#include <stdlib.h>
#define PROP_VALUE_MAX 92
static const char *g_voice = "0";
static int __system_property_get(const char *k, char *v) {
    if (!strcmp(k, "persist.vendor.asb.dsp.enable")) { strcpy(v, "1"); return 1; }
    if (!strcmp(k, "persist.vendor.asb.dsp.gain_mb")) { strcpy(v, "300"); return 3; }
    if (!strcmp(k, "persist.vendor.asb.dsp.voice")) { strcpy(v, g_voice); return (int)strlen(v); }
    v[0] = 0; return 0;
}
X
cat > "$T/drv.c" <<'X'
#include "asb_dsp.c"
#include <stdio.h>
#define N 48000
static float in[N * 2], out[N * 2];
static double level(float hz, const char *voice) {
    g_voice = voice;
    effect_handle_t h; const effect_uuid_t u = g_asb_descriptor.uuid;
    AELI.create_effect(&u, 0, 0, &h);
    effect_config_t cfg; memset(&cfg, 0, sizeof(cfg));
    cfg.outputCfg.samplingRate = 48000; cfg.outputCfg.channels = 3; cfg.outputCfg.format = AUDIO_FORMAT_PCM_FLOAT;
    int r = 0; uint32_t rs = 4;
    (*h)->command(h, EFFECT_CMD_SET_CONFIG, sizeof(cfg), &cfg, &rs, &r);
    (*h)->command(h, EFFECT_CMD_ENABLE, 0, NULL, &rs, &r);
    for (int i = 0; i < N; i++) in[2*i] = in[2*i+1] = 0.01f * sinf(2.0f * 3.14159265f * hz * (float)i / 48000.0f);
    audio_buffer_t a = { .frameCount = N, .f32 = in }, b = { .frameCount = N, .f32 = out };
    (*h)->process(h, &a, &b);
    double e = 0; for (int i = N; i < 2 * N; i++) e += (double)out[i] * out[i];   /* second half: settled */
    AELI.release_effect(h);
    return 10.0 * log10(e);
}
int main(void) {
    double b0 = level(350, "0"),  b10 = level(350, "10");
    double p0 = level(3200, "0"), p10 = level(3200, "10");
    double f0 = level(60, "0"),   f10 = level(60, "10");
    printf("350Hz %+.2f dB  3.2kHz %+.2f dB  60Hz %+.2f dB\n", b10 - b0, p10 - p0, f10 - f0);
    if (b10 - b0 < 4.0 || b10 - b0 > 5.5) return 1;
    if (p10 - p0 > -5.0 || p10 - p0 < -6.5) return 1;
    if (f10 - f0 > 1.0 || f10 - f0 < -1.0) return 1;   /* bass region left alone */
    return 0;
}
X
"$CC" -std=gnu11 -O1 -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Werror \
  -I"$T/inc" -I"$ROOT/src/DSP" -I"$ROOT/src/DSP_AIDL" "$T/drv.c" -lm -o "$T/drv" || fail "does not compile"
out="$("$T/drv")" || fail "response off target: $out"
echo "PASS DSP voice tone ($out)"
