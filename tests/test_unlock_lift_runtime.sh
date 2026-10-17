#!/bin/sh
# Runtime (fix150): Smart lifts the CPU ceilings for a few seconds after a wake.
#
# "Slideshow at unlock after a short idle, then smooth again." Capture 28442 (OP15, Smart): the
# first recorded interval after two wakes drew the launcher with 31 of 262 and 18 of 39 frames
# janky against 1.7% over the day, on MODERATE ceilings of main 1996800 / prime 1862400 and
# top-app uclamp 50, with a raised floor held at them (policy6 min = max). The REAL
# block is cut out of asb_governor.c and run: a wake lifts every managed ceiling to
# unlock_lift_pct of the hardware maximum (and top-app uclamp to the same share) for
# unlock_lift_s; the first touch within 20 s re-arms it once; the lift ends on time, on screen
# off and on a thermal cap; Battery/Balanced, a thermal cap, a warm die and unlock_lift_s=0 do
# not lift and say why; an empty slot stays unmanaged and nothing is ever lowered.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL unlock lift: $*" >&2; exit 1; }

# Wiring: decided before the touch kick is answered, applied after every trim, forces the
# write on an edge, keeps the 2 s cadence while it runs, survives a heartbeat refresh,
# published in the state file, shipped on and registered.
grep -q 'int _ul = asb_unlock_lift_update(metrics.misc.screen_on, g_touch_kick,' "$G" || fail "not decided in the tick"
awk '/int _ul = asb_unlock_lift_update/{a=NR} /int changed = fsm_update\(&fsm, &metrics\);/{b=NR} END{exit !(a && b && a < b)}' "$G" \
  || fail "decided after the touch kick was answered"
grep -q 'if (_ul || !metrics.misc.screen_on) force_write = 1;' "$G" || fail "a lift does not force the write"
grep -q 'int want_apply = (changed || force_write || g_unlock_edge ||' "$G" || fail "the end of a lift waits for the 30 s reassert"
awk '/asb_smart_media_guard_apply_caps\(&_effective_caps\);/{m=NR} /asb_unlock_lift_apply\(&_effective_caps\);/{if(!a)a=NR; l=NR} /int writes = writer_apply_caps\(&_effective_caps, force_write/{w=NR} END{exit !(m && l > m && l < w)}' "$G" \
  || fail "lift not applied between the media guard and the write"
grep -q 'int calm = !metrics.misc.camera_active && !g_unlock_lift_now &&' "$G" || fail "calm cadence during a lift"
grep -q 'A heartbeat refresh inside the unlock window keeps the lift' "$G" || fail "heartbeat refresh drops the lift"
grep -q 'unlock_lift=%d\\nunlock_lifts=%lu\\nunlock_lift_skips=%lu\\nunlock_lift_skip_why=%s' "$G" || fail "state file"
grep -q '^unlock_lift_s=3$' "$ROOT/config/governor.conf" || fail "not shipped at 3 s"
grep -q '^unlock_lift_pct=80$' "$ROOT/config/governor.conf" || fail "not shipped at 80%"
grep -q '^unlock_lift_s|internal|' "$ROOT/config/key_ownership.tsv" || fail "unlock_lift_s not registered"
grep -q '^unlock_lift_pct|internal|' "$ROOT/config/key_ownership.tsv" || fail "unlock_lift_pct not registered"
grep -q 'c->unlock_lift_s                = 3;' "$ROOT/src/asb_config.h" || fail "compiled default"
grep -q 'unlock lift: ' "$ROOT/tools/asb_diag.sh" || fail "asbdiag says nothing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag is stale"

CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS unlock lift (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^#define ASB_UNLOCK_TOUCH_WINDOW_MS/,/^\/\* Smart night slot with the screen on (fix150)/p' "$G" | sed '$d' > "$T/u.c"
grep -q 'static void asb_unlock_lift_apply' "$T/u.c" || fail "lift block not found"

cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
enum { PROFILE_BATTERY, PROFILE_BALANCED, PROFILE_PERFORMANCE, PROFILE_SMART };
typedef struct { int cpu_max[3]; int cpu_min[3]; int uclamp_top_max; int uclamp_bg_max; } asb_profile_caps_t;
static struct { int unlock_lift_s, unlock_lift_pct, bat_comfort_temp; } g_asb_cfg = { 3, 80, 48 };
static int g_cpu_slot_hwmax[3] = { 3628800, 4608000, 0 };
#include "u.c"
static int P = PROFILE_SMART, TC = 0, DIE = 36;
static int up(int scr, int kick, long ms) { return asb_unlock_lift_update(scr, kick, ms, P, TC, DIE); }
int main(void) {
    int bad = 0;
#define CHK(c, what) do { if (!(c)) { printf("%s\n", what); bad = 1; } } while (0)
    CHK(up(1, 0, 1000) == 0, "governor start with the screen on is not a wake");
    CHK(up(0, 0, 2000) == 0, "screen off");
    CHK(up(1, 0, 10000) == 1 && g_unlock_lifts == 1, "a wake lifts");
    asb_profile_caps_t c = { { 1996800, 1862400, 0 }, { 0, 0, 0 }, 50, 32 };
    asb_unlock_lift_apply(&c);
    CHK(c.cpu_max[0] == 2903040 && c.cpu_max[1] == 3686400, "ceilings not at 80% of hardware");
    CHK(c.cpu_max[2] == 0, "an empty slot became managed");
    CHK(c.uclamp_top_max == 80 && c.uclamp_bg_max == 32, "top-app uclamp not lifted, or background touched");
    asb_profile_caps_t hi = { { 3628800, 4608000, 0 }, { 0, 0, 0 }, 100, 32 };
    asb_unlock_lift_apply(&hi);
    CHK(hi.cpu_max[0] == 3628800 && hi.cpu_max[1] == 4608000 && hi.uclamp_top_max == 100, "a higher ceiling was lowered");
    CHK(up(1, 0, 12000) == 1, "still lifted at 2 s");
    CHK(up(1, 0, 13000) == 0, "not over at 3 s");
    /* The swipe that dismisses the lock screen: one more lift, once. */
    CHK(up(1, 1, 16000) == 1 && g_unlock_lifts == 2, "first touch after the wake does not re-arm");
    CHK(up(1, 1, 17000) == 1 && g_unlock_lifts == 2, "a second touch re-armed");
    CHK(up(1, 0, 19000) == 0, "touch lift not over at 3 s");
    CHK(up(1, 1, 22000) == 0 && g_unlock_lifts == 2, "a later touch lifted again");
    /* A touch more than 20 s after the wake is ordinary use. */
    up(0, 0, 30000); up(1, 0, 40000); up(1, 0, 44000);
    CHK(g_unlock_lifts == 3, "second wake");
    CHK(up(1, 1, 61000) == 0 && g_unlock_lifts == 3, "a touch 21 s after the wake lifted");
    /* Screen off ends a running lift at once. */
    up(0, 0, 70000); CHK(up(1, 0, 80000) == 1, "third wake"); CHK(up(0, 0, 81000) == 0, "screen off kept the lift");
    /* A thermal cap ends it too. */
    CHK(up(1, 0, 90000) == 1, "fourth wake");
    TC = 1; CHK(up(1, 0, 91000) == 0, "thermal cap kept the lift"); TC = 0;
    /* Gates: each wake that does not lift says why. */
    unsigned long l0 = g_unlock_lifts;
    up(0, 0, 100000); P = PROFILE_BALANCED; CHK(up(1, 0, 101000) == 0 && !strcmp(g_unlock_skip_why, "profile"), "Balanced lifted"); P = PROFILE_SMART;
    up(0, 0, 102000); P = PROFILE_BATTERY; CHK(up(1, 0, 103000) == 0, "Battery lifted"); P = PROFILE_SMART;
    up(0, 0, 104000); TC = 1; CHK(up(1, 0, 105000) == 0 && !strcmp(g_unlock_skip_why, "thermal"), "thermal-capped wake lifted"); TC = 0;
    up(0, 0, 106000); DIE = 48; CHK(up(1, 0, 107000) == 0 && !strcmp(g_unlock_skip_why, "warm"), "warm die lifted"); DIE = 36;
    up(0, 0, 108000); g_asb_cfg.unlock_lift_s = 0; CHK(up(1, 0, 109000) == 0 && !strcmp(g_unlock_skip_why, "off"), "switched off and lifted"); g_asb_cfg.unlock_lift_s = 3;
    CHK(g_unlock_lifts == l0 && g_unlock_skips == 5, "skips not counted");
    /* A skipped wake still lets the first touch try (the phone may have cooled). */
    up(0, 0, 110000); DIE = 48; up(1, 0, 111000); DIE = 36;
    CHK(up(1, 1, 113000) == 1, "first touch after a warm wake did not lift on a cool die");
    /* 4-cluster part: the prime slot Smart caps at 62% is lifted; the share is clamped to 100. */
    g_cpu_slot_hwmax[0] = 2265600; g_cpu_slot_hwmax[1] = 3148800; g_cpu_slot_hwmax[2] = 3302400;
    g_asb_cfg.unlock_lift_pct = 130;
    asb_profile_caps_t q = { { 1190400, 1824000, 2047488 }, { 0, 0, 0 }, 50, 32 };
    asb_unlock_lift_apply(&q);
    CHK(q.cpu_max[0] == 2265600 && q.cpu_max[1] == 3148800 && q.cpu_max[2] == 3302400 && q.uclamp_top_max == 100, "4-cluster lift / 100% clamp");
    g_asb_cfg.unlock_lift_pct = 20;
    asb_profile_caps_t r = { { 900000, 1000000, 1100000 }, { 0, 0, 0 }, 40, 32 };
    asb_unlock_lift_apply(&r);
    CHK(r.cpu_max[0] == 1132800 && r.uclamp_top_max == 50, "share below 50 not clamped to 50");
    return bad;
}
X
"$CC" -O2 -Wall -Werror -Wno-unused-function -Wno-unused-variable -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "fixture did not compile"; }
"$T/t" || fail "lift wrong"
echo "PASS unlock lift: a wake and its first touch get the ceilings for a few seconds, nothing else moves"
