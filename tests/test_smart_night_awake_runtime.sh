#!/bin/sh
# Runtime (fix150): a Smart night slot with the screen on leans no harder than the evening.
#
# "When I stay up late the animations get less smooth." The SLEEP (00-06) and LATE (21-24)
# slots are seeded at alpha 950 / 750 with an interactive bonus of 0 / 20 - for a phone that is
# asleep - and learning moves a slot by a few thousandths per session, so the seeds rule for
# months, screen on included. The REAL asb_smart_night_awake is cut out of asb_governor.c and
# run against the real Smart store code (asb_smart.h): with the screen on, the night slot's
# effective alpha falls to the evening slot's and its bonus rises to the evening's; screen off,
# a day slot, a night slot already leaner than the evening and the switch turned off change
# nothing; a weekend night takes the weekend evening.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL smart night awake: $*" >&2; exit 1; }

grep -q '    asb_smart_night_awake(screen_on, daypart, is_weekend, now);' "$G" || fail "not called in the Smart tick"
awk '/asb_smart_compute_effective\(b, conf, &g_smart_store, &g_smart_rt\);/{a=NR} /asb_smart_night_awake\(screen_on, daypart, is_weekend, now\);/{b=NR} /if \(g_asb_cfg.smart_battery_bias > 0\) \{/{c=NR} END{exit !(a && b == a + 1 && c > b)}' "$G" \
  || fail "must run right after the slot's own values and before the user's bias"
grep -q 'smart_night_awake=%d\\nsmart_night_awake_from=%d\\nsmart_night_awake_to=%d' "$G" || fail "state file"
grep -q '^smart_night_awake=1$' "$ROOT/config/governor.conf" || fail "not shipped on"
grep -q '^smart_night_awake|internal|' "$ROOT/config/key_ownership.tsv" || fail "not registered"
grep -q 'night slot, screen on:' "$ROOT/tools/asb_diag.sh" || fail "asbdiag says nothing"

CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS smart night awake (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  sed -n '/^static int g_smart_night_awake_on = 0;/,/^static unsigned long g_smart_night_awake_ticks = 0;/p' "$G"
  awk '/^static void asb_smart_night_awake\(/{f=1} f{print} f&&/^}$/{exit}' "$G"
} > "$T/n.c"
grep -q 'asb_smart_lookup_bucket' "$T/n.c" || fail "night-awake block not found"

cat > "$T/t.c" <<'X'
#include "asb_smart.h"
asb_runtime_config_t g_asb_cfg;
static asb_smart_store_t   g_smart_store;
static asb_smart_runtime_t g_smart_rt;
#include "n.c"
static void teach(int dp, int we, int alpha, int bonus, time_t now) {
    asb_smart_bucket_t *b = &g_smart_store.buckets[asb_smart_bucket_id(dp, we)];
    b->alpha_battery_x1000 = (uint16_t)alpha;
    b->interactive_bonus_x1000 = (int16_t)bonus;
    b->eff_obs_x100 = 4000; b->observations_raw = 60; b->last_seen_ts = (uint32_t)now;
    b->avg_max_temp_x10 = 0;        /* no thermal lean: compare the learned leans only */
    b->avg_drain_pctph_x10 = 0;
}
static void slot(int dp, int we, time_t now) {
    int fb = 0;
    asb_smart_bucket_t *b = asb_smart_lookup_bucket(&g_smart_store, dp, we, now, &fb);
    asb_smart_compute_effective(b, asb_smart_confidence_x1000(b, now), &g_smart_store, &g_smart_rt);
}
int main(void) {
    int bad = 0;
    time_t now = 1792000000;
    asb_config_defaults(&g_asb_cfg);
    asb_smart_store_seed_defaults(&g_smart_store);
#define CHK(c, what) do { if (!(c)) { printf("%s (alpha=%d bonus=%d on=%d from=%d to=%d)\n", what, \
    g_smart_rt.alpha_battery_x1000, g_smart_rt.interactive_bonus_x1000, g_smart_night_awake_on, \
    g_smart_night_awake_from, g_smart_night_awake_to); bad = 1; } } while (0)
    CHK(g_asb_cfg.smart_night_awake == 1, "default off");
    teach(ASB_DAYPART_SLEEP, 0, 930, 0, now);
    teach(ASB_DAYPART_LATE, 0, 720, 20, now);
    teach(ASB_DAYPART_EVE, 0, 520, 150, now);
    teach(ASB_DAYPART_EVE, 1, 380, 120, now);
    teach(ASB_DAYPART_DAY, 0, 300, 100, now);

    slot(ASB_DAYPART_SLEEP, 0, now); asb_smart_night_awake(1, ASB_DAYPART_SLEEP, 0, now);
    CHK(g_smart_rt.alpha_battery_x1000 == 520 && g_smart_rt.interactive_bonus_x1000 == 150, "00-06 screen on: not the evening's lean");
    CHK(g_smart_night_awake_on == 1 && g_smart_night_awake_from == 930 && g_smart_night_awake_to == 520, "not published");
    unsigned long t0 = g_smart_night_awake_ticks;

    slot(ASB_DAYPART_LATE, 0, now); asb_smart_night_awake(1, ASB_DAYPART_LATE, 0, now);
    CHK(g_smart_rt.alpha_battery_x1000 == 520 && g_smart_rt.interactive_bonus_x1000 == 150, "21-24 screen on: not the evening's lean");
    CHK(g_smart_night_awake_ticks == t0 + 1, "ticks not counted");

    slot(ASB_DAYPART_SLEEP, 1, now); asb_smart_night_awake(1, ASB_DAYPART_SLEEP, 1, now);
    CHK(g_smart_rt.alpha_battery_x1000 == 380 && g_smart_rt.interactive_bonus_x1000 == 120, "weekend night: not the weekend evening");

    slot(ASB_DAYPART_SLEEP, 0, now); asb_smart_night_awake(0, ASB_DAYPART_SLEEP, 0, now);
    CHK(g_smart_rt.alpha_battery_x1000 == 930 && g_smart_night_awake_on == 0, "screen off changed");

    slot(ASB_DAYPART_DAY, 0, now); asb_smart_night_awake(1, ASB_DAYPART_DAY, 0, now);
    CHK(g_smart_rt.alpha_battery_x1000 == 300 && g_smart_night_awake_on == 0, "a day slot changed");

    /* A night slot already leaner than the evening keeps its own lean - only the bonus rises. */
    teach(ASB_DAYPART_LATE, 0, 400, 20, now);
    slot(ASB_DAYPART_LATE, 0, now); asb_smart_night_awake(1, ASB_DAYPART_LATE, 0, now);
    CHK(g_smart_rt.alpha_battery_x1000 == 400 && g_smart_rt.interactive_bonus_x1000 == 150, "a leaner night slot was pushed toward economy");
    CHK(g_smart_night_awake_on == 1 && g_smart_night_awake_from == g_smart_night_awake_to, "bonus-only not published as such");

    g_asb_cfg.smart_night_awake = 0;
    slot(ASB_DAYPART_SLEEP, 0, now); asb_smart_night_awake(1, ASB_DAYPART_SLEEP, 0, now);
    CHK(g_smart_rt.alpha_battery_x1000 == 930 && g_smart_night_awake_on == 0, "switched off and changed");
    return bad;
}
X
"$CC" -O2 -Wall -Werror -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable \
  -I"$ROOT/src" -I"$T" -o "$T/t" "$T/t.c" -lm 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "fixture did not compile"; }
"$T/t" || fail "night lean wrong"
echo "PASS smart night awake: up late with the screen on, Smart leans like your evening"
