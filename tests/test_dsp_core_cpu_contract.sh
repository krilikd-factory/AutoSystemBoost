#!/bin/sh
# fix78: the compressor gain (log10f + powf) is evaluated every ASB_COMP_EVERY frames and
# skipped below the knee instead of 48000 times a second; the limiter stays per frame.
# Host measurement at +12 dB on a 60 s music-like signal: 101 -> 45 ms CPU, output
# difference -55 dB relative, peak still under the ceiling. Runtime: same signal through the
# real core, every output sample within the ceiling.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/src/DSP_AIDL/asb_dsp_core.h"
fail() { echo "FAIL dsp core cpu: $*" >&2; exit 1; }
grep -q '#define ASB_COMP_EVERY   16' "$H" || fail "no decimation constant"
grep -q 'if (env <= c->knee_lo_lin) return 1.0f;' "$H" || fail "no below-knee shortcut"
[ "$(grep -c 'float cg = asb_core_comp_step(c, peak);' "$H")" = 2 ] || fail "a process path still evaluates the gain per frame"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <stdlib.h>
#include "asb_dsp_core.h"
#define N 96000
static float in[N*2], out[N*2];
int main(void){
  srand(3);
  for(int i=0;i<N;i++){ float e=0.3f+0.7f*fabsf(sinf(i*0.0003f)); float x=e*(0.6f*sinf(i*0.05f)+0.3f*((rand()/(float)RAND_MAX)-0.5f)); in[2*i]=x; in[2*i+1]=-x; }
  asb_core_t c={0}; asb_core_reset(&c);
  asb_core_configure_ex(&c,1,2500,-15,1,60,-2400,2,48000,1,0,300);
  for(int o=0;o<N;o+=480) asb_core_process_f32(&c,in+2*o,out+2*o,480,0);
  for(int i=0;i<N*2;i++) if (fabsf(out[i]) > c.ceiling + 1e-6f) { printf("over ceiling at %d: %f\n", i, out[i]); return 1; }
  return 0;
}
X
cc -O2 -I"$ROOT/src/DSP_AIDL" "$T/t.c" -lm -o "$T/t" && "$T/t" || fail "limiter ceiling broken"
echo "PASS DSP core evaluates the compressor gain per block"
