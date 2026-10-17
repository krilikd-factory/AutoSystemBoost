#!/bin/sh
# Runtime (fix130): Smart keeps the main-core ceiling level with the prime's on 6+2 phones.
#
# The scheduler places work by each cluster's capacity at its ceiling. On the 40% floors an
# OP15 offers main 1555200 (capacity 327) against prime 1862400 (414), so ordinary screen-on
# work moved to the two prime cores: prime busy in 91% of screen-on samples on one phone,
# 27-100% on another whenever the main ceiling sat under the prime's. The REAL parity block
# is cut out of asb_governor.c and run on OP15 tables: light idle and moderate get the first
# main step at the prime's capacity; a vendor-held prime lowers the target; a thermal cap,
# GAMING, a 4-cluster part, a truly little first cluster and the switch turned off change
# nothing; a prime burst keeps the level it found. fix132: when the level step is over 60% of
# the main maximum (PLQ110, SM8750: 2227200 = 63%) the highest step inside the limit is taken
# if it reaches 90% of the prime's capacity, and the state says so. fix156: a thermal budget
# trim, HEAVY and SUSTAINED keep the level too - warm OP15 samples with the main under the prime
# had the prime working in 67% at 456 mA against 9% at 337 mA level - and the state says when
# the raise is the one held while the phone cools.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL main capacity parity: $*" >&2; exit 1; }
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "SKIP main capacity parity: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Up to the next block (the fix150 unlock lift sits between parity and the budget caps).
sed -n '/^static int g_parity_cap0 = -2;/,/^\/\* Unlock lift (fix150)\./p' "$G" \
  | sed '$d' > "$T/p.c"
grep -q 'asb_main_capacity_parity' "$T/p.c" || fail "parity block not found"
grep -q '    asb_main_capacity_parity(caps, m, fsm, trim);' "$G" || fail "parity not applied with the budget caps"
grep -q '^main_capacity_parity=1$' "$ROOT/config/governor.conf" || fail "switch not shipped on"
grep -q '^main_capacity_parity|internal|' "$ROOT/config/key_ownership.tsv" || fail "switch not registered"
grep -q 'main_parity_khz=%d' "$G" || fail "state file does not say what parity did"
grep -q 'main_parity_cooling=%d' "$G" || fail "state file does not say the raise is held while cooling"

cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
enum { ASB_STATE_DEEP_IDLE, ASB_STATE_LIGHT_IDLE, ASB_STATE_MODERATE, ASB_STATE_HEAVY,
       ASB_STATE_SUSTAINED, ASB_STATE_GAMING };
enum { PROFILE_BATTERY, PROFILE_BALANCED, PROFILE_PERFORMANCE, PROFILE_SMART };
enum { ASB_APP_MEDIUM = 2, ASB_APP_GAMING = 4 };
typedef struct { int cpu_max[3]; } asb_profile_caps_t;
typedef struct { int max_freq[3]; } cpu_t;
typedef struct { int screen_on, camera_active, app_hint; } misc_t;
typedef struct { cpu_t cpu; misc_t misc; } asb_metrics_t;
typedef struct { int profile_idx, thermal_cap, state, prime_escape; } asb_fsm_t;
static struct { int main_capacity_parity; } g_asb_cfg = { 1 };
static int g_cpu_all_count = 2;
static int g_cpu_policy_ids[3] = { 0, 6, -1 };
static int g_cpu_slot_hwmax[3] = { 3628800, 4608000, 0 };
static int g_cap[8] = { 762, 762, 762, 762, 762, 762, 1024, 1024 };
static const long T0[] = { 384000,537600,691200,787200,883200,998400,1113600,1228800,1324800,1440000,
  1555200,1670400,1785600,1900800,1996800,2112000,2227200,2361600,2496000,2611200,2745600,2899200,
  3033600,3187200,3302400,3398400,3513600,3628800 };
static const long T1[] = { 768000,883200,1017600,1132800,1267200,1382400,1497600,1632000,1747200,
  1862400,1977600,2112000,2227200,2438400,2668800,2880000,3129600,3398400,3648000,3763200,3859200,
  3974400,4070400,4185600,4262400,4339200,4396800,4608000 };
/* PLQ110 (SM8750, fix132): the prime floor rounds up to 1958400 (45%) and the level main step
 * 2227200 is 63% of 3532800 - over the 60% limit. */
static const long Q0[] = { 384000,556800,748800,960000,1152000,1363200,1555200,1785600,1996800,
  2227200,2400000,2745600,2918400,3072000,3321600,3532800 };
static const long Q1[] = { 1017600,1209600,1401600,1689600,1958400,2246400,2438400,2649600,2841600,
  3072000,3283200,3513600,3801600,4089600,4204800,4320000 };
static int g_plq = 0;
static const long *tab(int s, int *n) {
    if (g_plq) {
        if (s == 0) { *n = (int)(sizeof(Q0) / sizeof(Q0[0])); return Q0; }
        *n = (int)(sizeof(Q1) / sizeof(Q1[0])); return Q1;
    }
    if (s == 0) { *n = (int)(sizeof(T0) / sizeof(T0[0])); return T0; }
    *n = (int)(sizeof(T1) / sizeof(T1[0])); return T1;
}
static int sysfs_read_int(const char *p, int d) {
    int cpu = -1;
    if (sscanf(p, "/sys/devices/system/cpu/cpu%d/cpu_capacity", &cpu) == 1 && cpu >= 0 && cpu < 8) return g_cap[cpu];
    return d;
}
static int writer_slot_ceiling(int s, int want, int tc) {
    int n; const long *t = tab(s, &n); long best = 0, hw = t[n - 1], up = 0;
    for (int i = 0; i < n; i++) if (t[i] <= want && t[i] > best) best = t[i];
    if (!best) best = t[0];
    if (tc) return (int)best;
    for (int i = 0; i < n; i++) if (t[i] >= hw * 40 / 100 && (!up || t[i] < up)) up = t[i];
    return (int)(best >= hw * 40 / 100 ? best : up);
}
static int writer_slot_step_at_least(int s, long khz) {
    int n; const long *t = tab(s, &n); long up = 0;
    for (int i = 0; i < n; i++) if (t[i] >= khz && (!up || t[i] < up)) up = t[i];
    return (int)up;
}
#include "p.c"
static asb_metrics_t M; static asb_fsm_t F;
static int run(int state, int main_want, int prime_want, int prime_live_mhz, int trim) {
    asb_profile_caps_t c = { { main_want, prime_want, 0 } };
    F.state = state; M.cpu.max_freq[1] = prime_live_mhz;
    asb_main_capacity_parity(&c, &M, &F, trim);
    return c.cpu_max[0];
}
int main(void) {
    int bad = 0, r;
    M.misc.screen_on = 1; M.misc.app_hint = ASB_APP_MEDIUM; F.profile_idx = PROFILE_SMART;
#define WANT(x, v, what) do { r = (x); if (r != (v)) { printf("%s: main %d, want %d\n", what, r, v); bad = 1; } } while (0)
    WANT(run(ASB_STATE_LIGHT_IDLE, 1440000, 1497600, 1862, 0), 1996800, "light idle on the floors");
    if (g_parity_lifts != 1 || g_parity_main_khz != 1996800) { printf("lift not recorded\n"); bad = 1; }
    WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1996800, "moderate on the floors");
    if (g_parity_lifts != 1) { printf("a held level counted as a new lift\n"); bad = 1; }
    WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1632, 0), 1785600, "prime held at 1632 MHz by the vendor");
    WANT(run(ASB_STATE_MODERATE, 2112000, 1862400, 1862, 0), 2112000, "main already above the prime");
    if (g_parity_main_khz != 0) { printf("no raise must publish 0\n"); bad = 1; }
    WANT(run(ASB_STATE_HEAVY, 1996800, 1862400, 1862, 0), 1996800, "HEAVY already level");
    if (g_parity_main_khz != 0 || g_parity_cooling != 0) { printf("HEAVY already level counted as a raise\n"); bad = 1; }
    WANT(run(ASB_STATE_HEAVY, 1555200, 1862400, 1862, 18), 1996800, "HEAVY with the main trimmed");
    if (g_parity_cooling != 1 || g_parity_cool_lifts != 1) { printf("HEAVY trim raise not published: %d %lu\n", g_parity_cooling, g_parity_cool_lifts); bad = 1; }
    WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 18), 1996800, "thermal budget trim");
    if (g_parity_cooling != 1 || g_parity_cool_lifts != 1) { printf("a held cooling raise counted again: %d %lu\n", g_parity_cooling, g_parity_cool_lifts); bad = 1; }
    WANT(run(ASB_STATE_MODERATE, 1900800, 1862400, 1862, 8), 1996800, "light trim within 10% of the prime");
    WANT(run(ASB_STATE_SUSTAINED, 1785600, 1862400, 1862, 0), 1996800, "SUSTAINED rail under the prime");
    WANT(run(ASB_STATE_SUSTAINED, 1555200, 1632000, 1632, 0), 1785600, "SUSTAINED with the vendor holding the prime");
    WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1996800, "moderate without a trim");
    if (g_parity_cooling != 0) { printf("an ordinary raise published as cooling\n"); bad = 1; }
    WANT(run(ASB_STATE_SUSTAINED, 1785600, 1862400, 1862, 0), 1996800, "SUSTAINED again");
    if (g_parity_cool_lifts != 2) { printf("a new cooling raise not counted: %lu\n", g_parity_cool_lifts); bad = 1; }
    WANT(run(ASB_STATE_GAMING, 1555200, 1862400, 1862, 0), 1555200, "GAMING");
    if (g_parity_cooling != 0 || g_parity_main_khz != 0) { printf("GAMING kept a raise\n"); bad = 1; }
    F.thermal_cap = 1; WANT(run(ASB_STATE_SUSTAINED, 1555200, 1862400, 1862, 0), 1555200, "SUSTAINED under a thermal cap"); F.thermal_cap = 0;
    F.thermal_cap = 1; WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1555200, "thermal cap"); F.thermal_cap = 0;
    M.misc.screen_on = 0; WANT(run(ASB_STATE_LIGHT_IDLE, 1555200, 1862400, 1862, 0), 1555200, "screen off"); M.misc.screen_on = 1;
    M.misc.camera_active = 1; WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1555200, "camera"); M.misc.camera_active = 0;
    WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1996800, "raise again");
    F.prime_escape = 1;
    WANT(run(ASB_STATE_MODERATE, 1555200, 2668800, 2668, 0), 1996800, "prime burst keeps the level it found");
    F.prime_escape = 0;
    F.profile_idx = PROFILE_BALANCED; WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1555200, "manual profile"); F.profile_idx = PROFILE_SMART;
    g_asb_cfg.main_capacity_parity = 0; WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1555200, "switched off"); g_asb_cfg.main_capacity_parity = 1;
    g_cpu_all_count = 4; g_cpu_policy_ids[2] = 7; WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1555200, "4-cluster part");
    g_cpu_all_count = 2; g_cpu_policy_ids[2] = -1;
    /* fix132: the level step over the limit -> the highest step inside it when it gets within
     * 10% of the prime. OP15 with the prime at 2112000: level 2361600 (65%), 2112000 = 443 of 469. */
    WANT(run(ASB_STATE_MODERATE, 1555200, 2112000, 2112, 0), 2112000, "OP15 prime above its floor: nearest step");
    if (g_parity_near != 1 || g_parity_over_khz != 2361600) { printf("OP15 near not published: %d %d\n", g_parity_near, g_parity_over_khz); bad = 1; }
    WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1996800, "exact level again");
    if (g_parity_near != 0 || g_parity_over_khz != 0) { printf("exact level published as near\n"); bad = 1; }
    for (int i = 0; i < 6; i++) { g_cap[i] = 400; }
    g_parity_cap0 = -2;
    WANT(run(ASB_STATE_MODERATE, 1555200, 1862400, 1862, 0), 1555200, "a truly little first cluster");
    if (g_parity_near != 0) { printf("a truly little cluster got a near raise\n"); bad = 1; }
    /* PLQ110: main 792, prime 1024. */
    g_plq = 1; g_cpu_slot_hwmax[0] = 3532800; g_cpu_slot_hwmax[1] = 4320000;
    for (int i = 0; i < 6; i++) { g_cap[i] = 792; }
    g_parity_cap0 = -2;
    WANT(run(ASB_STATE_LIGHT_IDLE, 1555200, 1401600, 1958, 0), 1996800, "PLQ110 light idle on the floors");
    if (g_parity_near != 1 || g_parity_over_khz != 2227200) { printf("PLQ110 near not published: %d %d\n", g_parity_near, g_parity_over_khz); bad = 1; }
    WANT(run(ASB_STATE_MODERATE, 1785600, 1958400, 1958, 0), 1996800, "PLQ110 moderate");
    WANT(run(ASB_STATE_MODERATE, 1555200, 1958400, 1689, 0), 1996800, "PLQ110 prime held at 1689 MHz: exact level");
    if (g_parity_near != 0) { printf("PLQ110 exact level published as near\n"); bad = 1; }
    WANT(run(ASB_STATE_MODERATE, 1555200, 2649600, 2649, 0), 1555200, "PLQ110 prime well above its floor: no step gets close");
    if (g_parity_main_khz != 0 || g_parity_over_khz != 2918400) { printf("PLQ110 refusal not published: %d %d\n", g_parity_main_khz, g_parity_over_khz); bad = 1; }
    WANT(run(ASB_STATE_HEAVY, 1555200, 1958400, 1958, 0), 1996800, "PLQ110 HEAVY under the prime");
    WANT(run(ASB_STATE_GAMING, 1555200, 1958400, 1958, 0), 1555200, "PLQ110 GAMING");
    if (g_parity_over_khz != 0 || g_parity_near != 0) { printf("GAMING kept a stale over value\n"); bad = 1; }
    return bad;
}
X
"$CC" -O2 -Wall -Werror -Wno-unused-function -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "fixture did not compile"; }
"$T/t" || fail "parity wrong"
echo "PASS main capacity parity: the main cores stay level with the prime in light work, under a trim, in HEAVY and SUSTAINED; a thermal cap and GAMING keep their own path"
