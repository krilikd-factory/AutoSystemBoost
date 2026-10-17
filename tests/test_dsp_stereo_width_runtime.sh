#!/bin/sh
# Runtime (fix160): DSP stereo width ("Sound Space", dsp_width 0..10).
#
# Mid/side widening in the shared core (src/DSP_AIDL/asb_dsp_core.h), the object both the
# AIDL and the legacy effect run. The REAL header is compiled on the host and driven with
# sines:
#   - level 0 is bit-identical to a core that never heard of width;
#   - a mono or centred signal (L == R) comes out bit-identical at any level - voices and mono
#     recordings are not touched;
#   - the side signal grows by 1 + 0.1 * level above the 180 Hz corner (x2.0 at level 10) and
#     far less at 50 Hz, so the low end stays mono;
#   - only two-channel streams are processed;
#   - the limiter still holds the ceiling with +25 dB and full width, in float and int16;
#   - both effects and the attach daemon read the new property, and the build gate knows it.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL dsp stereo width: $*" >&2; exit 1; }
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP dsp stereo width: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q 'asb_core_set_width(&mCore, width, (uint32_t)rate);' "$ROOT/src/DSP_AIDL/asb_effect_aidl.cpp" || fail "AIDL effect does not apply the width"
grep -q 'int width  = asb_dsp_prop("width", 0);' "$ROOT/src/DSP_AIDL/asb_effect_aidl.cpp" || fail "AIDL effect does not read the width"
grep -q 'asb_core_set_width(&c->core, asb_dsp_prop("width", 0), rate);' "$ROOT/src/DSP/asb_dsp.c" || fail "legacy effect does not apply the width"
grep -q '__system_property_get("persist.asb.dsp.width", w);' "$ROOT/src/DSP_AIDL/asb_dsp_attach.cpp" || fail "a width edit does not trigger a push"
grep -q '" stereo_width="' "$ROOT/src/build_ndk_release.sh" || fail "build gate does not know the width marker"
cat > "$T/w.c" <<'X'
#include "asb_dsp_core.h"
#include <stdio.h>
#include <string.h>
#define N 9600
#define R 48000u
static float in[N * 6], o0[N * 6], o1[N * 6];
static void cfg(asb_core_t *c, int ch, int gain, int width) {
    memset(c, 0, sizeof(*c));
    asb_core_configure_ex(c, 1, gain, -30, 0, 60, -2400, ch, R, 1, 0, 300);
    asb_core_set_bass(c, 0, R);
    asb_core_set_voice(c, 0, R);
    if (width >= 0) asb_core_set_width(c, width, R);
    asb_core_reset(c);
}
static void sig(int ch, float f, float al, float ar) {
    for (int i = 0; i < N; i++) {
        float v = sinf(2.0f * 3.14159265f * f * (float)i / (float)R);
        for (int k = 0; k < ch; k++) in[i * ch + k] = (k == 0 ? al : (k == 1 ? ar : al)) * v;
    }
}
static double side_rms(const float *b) {
    double s = 0; for (int i = N / 2; i < N; i++) { double d = 0.5 * (b[i * 2] - b[i * 2 + 1]); s += d * d; } return s;
}
static float peak(const float *b, int n) { float m = 0; for (int i = 0; i < n; i++) if (fabsf(b[i]) > m) m = fabsf(b[i]); return m; }
static double ratio(float f, int level) {
    asb_core_t a, b;
    sig(2, f, 0.05f, -0.05f);
    cfg(&a, 2, 100, 0); asb_core_process_f32(&a, in, o0, N, 0);
    cfg(&b, 2, 100, level); asb_core_process_f32(&b, in, o1, N, 0);
    return sqrt(side_rms(o1) / side_rms(o0));
}
int main(void) {
    asb_core_t a, b; int bad = 0;
    sig(2, 1000.0f, 0.3f, 0.1f);
    cfg(&a, 2, 600, -1); asb_core_process_f32(&a, in, o0, N, 0);
    cfg(&b, 2, 600, 0);  asb_core_process_f32(&b, in, o1, N, 0);
    if (b.width_on || memcmp(o0, o1, sizeof(float) * N * 2)) { puts("FAIL level 0 changes the signal"); bad++; }
    sig(2, 1000.0f, 0.2f, 0.2f);
    cfg(&a, 2, 600, 0);  asb_core_process_f32(&a, in, o0, N, 0);
    cfg(&b, 2, 600, 10); asb_core_process_f32(&b, in, o1, N, 0);
    if (!b.width_on || memcmp(o0, o1, sizeof(float) * N * 2)) { puts("FAIL a centred signal is not bit-identical at level 10"); bad++; }
    double r10 = ratio(2000.0f, 10), r5 = ratio(2000.0f, 5), r1 = ratio(4000.0f, 1), rlo = ratio(50.0f, 10);
    printf("side x%.3f at 2 kHz level 10, x%.3f level 5, x%.3f 4 kHz level 1, x%.3f at 50 Hz level 10\n", r10, r5, r1, rlo);
    if (r10 < 1.90 || r10 > 2.02) { puts("FAIL level 10 is not about x2.0 on the side"); bad++; }
    if (r5 < 1.45 || r5 > 1.51) { puts("FAIL level 5 is not about x1.5"); bad++; }
    if (r1 < 1.08 || r1 > 1.11) { puts("FAIL level 1 is not about x1.1"); bad++; }
    if (rlo > 1.35) { puts("FAIL the low end is widened"); bad++; }
    cfg(&a, 1, 600, 10); if (a.width_on) { puts("FAIL width on a mono stream"); bad++; }
    cfg(&a, 6, 600, 10); if (a.width_on) { puts("FAIL width on a 5.1 stream"); bad++; }
    cfg(&a, 2, 600, 11); if (!a.width_on || a.wside > 1.0001f) { puts("FAIL level not clamped to 10"); bad++; }
    sig(2, 3000.0f, 0.9f, -0.9f);
    cfg(&a, 2, 2500, 10); asb_core_process_f32(&a, in, o1, N, 0);
    if (peak(o1, N * 2) > asb_core_mb_to_lin(-30) + 1e-4f) { printf("FAIL ceiling broken with full width: %.4f\n", peak(o1, N * 2)); bad++; }
    {
        static int16_t si[N * 2], so[N * 2];
        for (int i = 0; i < N; i++) { int16_t v = (int16_t)(12000.0f * sinf(2.0f * 3.14159265f * 1500.0f * (float)i / (float)R)); si[i * 2] = v; si[i * 2 + 1] = v; }
        cfg(&a, 2, 600, 10); asb_core_process_s16(&a, si, so, N, 0);
        for (int i = 0; i < N; i++) if (so[i * 2] != so[i * 2 + 1]) { puts("FAIL int16 centred signal split by width"); bad++; break; }
        for (int i = 0; i < N; i++) { int16_t v = (int16_t)(30000.0f * sinf(2.0f * 3.14159265f * 2500.0f * (float)i / (float)R)); si[i * 2] = v; si[i * 2 + 1] = (int16_t)-v; }
        cfg(&a, 2, 2500, 10); asb_core_process_s16(&a, si, so, N, 0);
        int lim = (int)lrintf(asb_core_mb_to_lin(-30) * 32767.0f) + 1;
        for (int i = 0; i < N * 2; i++) if (so[i] > lim || so[i] < -lim) { printf("FAIL int16 ceiling broken: %d\n", so[i]); bad++; break; }
    }
    return bad ? 1 : 0;
}
X
"$CC" -O2 -std=c11 -Wall -Wextra -I"$ROOT/src/DSP_AIDL" "$T/w.c" -lm -o "$T/w" 2> "$T/cc.log" || { cat "$T/cc.log" >&2; fail "core does not compile"; }
[ -s "$T/cc.log" ] && { cat "$T/cc.log" >&2; fail "core compiles with warnings"; }
out="$("$T/w")" || fail "$out"
echo "PASS dsp stereo width: $out; centred sound and level 0 bit-exact, mono/5.1 untouched, ceiling held"
