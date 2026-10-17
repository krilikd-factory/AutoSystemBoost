#!/bin/sh
# Runtime (fix126): the Smart prime escape opens only where it can do something.
#
# OP15 fix124 capture: a lift at 46 C and its release at 48 C in the same second (Smart
# leaves SUSTAINED at 48), the prime left on the escape rail while the lowering write caught
# up - and, for the last 25 minutes, the prime under a 1632000 vendor ceiling against ASB's
# 1862400, where lifting ASB's request changes nothing. The REAL escape block is cut out of
# asb_fsm.h and run on a stub FSM: a pinned prime at a foreign ceiling opens nothing, a
# pinned prime within 3 C of the exit mark waits (counted once), and the first cooler
# pinned tick opens the burst at once.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL prime escape gates: $*" >&2; exit 1; }
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "SKIP prime escape gates: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

sed -n '/^\/\* Prime escape gates (fix126)\./,/^}/p' "$F" > "$T/g.c"
_a="$(grep -n '^    /\* HEAVY prime escape (Smart only)' "$F" | head -1 | cut -d: -f1)"
_b="$(grep -n 'fsm->prime_escape_edge = (fsm->prime_escape != _was)' "$F" | head -1 | cut -d: -f1)"
[ -s "$T/g.c" ] && [ -n "$_a" ] && [ -n "$_b" ] || fail "escape code not found"
sed -n "${_a},$((_b + 1))p" "$F" > "$T/b.c"
grep -q 'asb_esc_ceiling_foreign' "$T/b.c" || fail "escape does not check whose ceiling it is"

cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <time.h>
enum { ASB_STATE_DEEP_IDLE, ASB_STATE_LIGHT_IDLE, ASB_STATE_MODERATE, ASB_STATE_HEAVY,
       ASB_STATE_SUSTAINED, ASB_STATE_GAMING, ASB_STATE_COUNT };
enum { PROFILE_BATTERY, PROFILE_BALANCED, PROFILE_PERFORMANCE, PROFILE_SMART };
enum { ASB_APP_LIGHT = 1, ASB_APP_MEDIUM = 2, ASB_APP_HEAVY = 3, ASB_APP_GAMING = 4 };
typedef struct { int cpu_max[3]; } asb_profile_caps_t;
typedef struct { asb_profile_caps_t floor, ceil; } asb_profile_bounds_t;
typedef struct { int max_freq[3], cur_freq[3]; } cpu_t;
typedef struct { int skin_temp_c, temp_valid, cpu_max_c; } therm_t;
typedef struct { int screen_on, camera_active, app_hint; } misc_t;
typedef struct { int charging; } bat_t;
typedef struct { cpu_t cpu; therm_t therm; misc_t misc; bat_t bat; } asb_metrics_t;
typedef struct { int prime_escape, prime_escape_edge, prime_escape_mid, profile_idx, state, thermal_cap;
                 unsigned long prime_escape_count; } asb_fsm_t;
typedef struct { int prime_escape_burst_s, prime_escape_rest_s, heavy_prime_escape, thermal_skin_c,
                 sustained_temp_exit; } cfg_t;
static cfg_t g_asb_cfg = { 20, 40, 1, 47, 48 };
static int asb_config_profile_sustained_temp_exit(const cfg_t *c, int p) { (void)p; return c->sustained_temp_exit; }
static int g_cpu_policy_ids[3] = { 0, 6, -1 };
static int g_cpu_slot_hwmax[3] = { 3628800, 4608000, 0 };
static asb_profile_bounds_t g_profile_bounds[4];
static const float g_state_level[ASB_STATE_COUNT] = { 0.f, .15f, .4f, .75f, .6f, 1.f };
static int lerp_int(int a, int b, float t) { return a + (int)((b - a) * t); }
#include "g.c"
static asb_fsm_t fsm_s;
static int step(asb_metrics_t *M, int *prime_cap) {
    asb_fsm_t *fsm = &fsm_s; const asb_metrics_t *m = M;
    asb_profile_caps_t new_caps = { { 1785600, 1862400, 0 } };
#include "b.c"
    *prime_cap = new_caps.cpu_max[1];
    return fsm->prime_escape_edge;
}
int main(void) {
    int bad = 0, cap = 0, e;
    asb_metrics_t M = { { { 1785, 1632, 0 }, { 1000, 1632, 0 } }, { 30, 1, 44 }, { 1, 0, ASB_APP_MEDIUM }, { 0 } };
    g_profile_bounds[PROFILE_BALANCED].floor.cpu_max[1] = 1000000;
    g_profile_bounds[PROFILE_BALANCED].ceil.cpu_max[1]  = 3000000;
    fsm_s.profile_idx = PROFILE_SMART; fsm_s.state = ASB_STATE_HEAVY;
    /* Unknown request (nothing written yet): no verdict, the old behaviour. */
    if (asb_esc_ceiling_foreign(&M, 1)) { printf("no request recorded must not read as foreign\n"); bad = 1; }
    g_fsm_slot_req_khz[1] = 1862400;
    /* 1. Pinned at a 1632 MHz vendor ceiling under ASB's 1862400: nothing opens. */
    for (int i = 0; i < 4; i++) { e = step(&M, &cap); if (e || fsm_s.prime_escape) { printf("burst opened under a foreign ceiling\n"); bad = 1; } }
    if (g_esc_skip_foreign != 1) { printf("foreign spell counted %lu times, want 1\n", g_esc_skip_foreign); bad = 1; }
    /* 2. ASB's own ceiling, pinned, die 46 with Smart exiting at 48: waits, counted once. */
    M.cpu.max_freq[1] = 1862; M.cpu.cur_freq[1] = 1862; M.therm.cpu_max_c = 46;
    for (int i = 0; i < 4; i++) { e = step(&M, &cap); if (e || fsm_s.prime_escape) { printf("burst opened 2 C under its own exit mark\n"); bad = 1; } }
    if (g_esc_skip_warm != 1) { printf("warm refusal counted %lu times, want 1\n", g_esc_skip_warm); bad = 1; }
    /* 3. First cooler pinned tick: opens at once (streak kept), lifted to Balanced HEAVY. */
    M.therm.cpu_max_c = 45;
    e = step(&M, &cap);
    if (e != 1 || !fsm_s.prime_escape) { printf("burst did not open at 45 C (edge %d)\n", e); bad = 1; }
    if (cap != 2500000) { printf("lifted to %d, want the Balanced HEAVY rail 2500000\n", cap); bad = 1; }
    /* 4. The die reaching the exit mark still ends it. */
    M.therm.cpu_max_c = 48;
    e = step(&M, &cap);
    if (e != -1 || fsm_s.prime_escape) { printf("burst not released at the exit mark (edge %d)\n", e); bad = 1; }
    if (cap != 1862400) { printf("ceiling not back on the Smart rail: %d\n", cap); bad = 1; }
    return bad;
}
X
"$CC" -O2 -Wall -Werror -Wno-unused-function -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "fixture did not compile"; }
"$T/t" || fail "escape gates wrong"
echo "PASS prime escape gates: no burst under a foreign ceiling or 2 C from its exit mark, opens on the first cooler tick"
