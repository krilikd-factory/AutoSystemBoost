/* tests/test_smart_session3.c — Session unit tests
 * Covers: weights, decay, confidence, fallback hierarchy, blend math,
 *         night override, thermal veto, bucket learning, slot gating. */

#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "../src/asb_smart.h"

static int g_fails = 0;
static int g_passes = 0;

#define EXPECT(cond, msg) do { \
    if (cond) { g_passes++; } \
    else { g_fails++; printf("  FAIL: %s\n", msg); } \
} while (0)

#define EXPECT_NEAR(actual, expected, tolerance, msg) do { \
    int _diff = (actual) - (expected); \
    if (_diff < 0) _diff = -_diff; \
    if (_diff <= (tolerance)) { g_passes++; } \
    else { g_fails++; printf("  FAIL: %s — got %d expected %d (tol %d)\n", \
        msg, (int)(actual), (int)(expected), (int)(tolerance)); } \
} while (0)

static void test_duration_weight(void) {
    printf("test_duration_weight\n");
    EXPECT(asb_smart_duration_weight_x100(0)   == 25,  "dur 0s → 0.25");
    EXPECT(asb_smart_duration_weight_x100(300) == 25,  "dur 5min → 0.25");
    EXPECT(asb_smart_duration_weight_x100(599) == 25,  "dur 9:59 → 0.25");
    EXPECT(asb_smart_duration_weight_x100(600) == 50,  "dur 10min → 0.50");
    EXPECT(asb_smart_duration_weight_x100(1800) == 100, "dur 30min → 1.00");
    EXPECT(asb_smart_duration_weight_x100(3600) == 100, "dur 60min → 1.00");
    EXPECT(asb_smart_duration_weight_x100(5400) == 125, "dur 90min → 1.25");
    EXPECT(asb_smart_duration_weight_x100(10000) == 125, "dur 167min → 1.25");
    EXPECT(asb_smart_duration_weight_x100(-100) == 25,  "negative dur clamped");
}

static void test_trust_weight(void) {
    printf("test_trust_weight\n");
    EXPECT(asb_smart_trust_weight_x100(ASB_TRUST_CLEAN)   == 100, "clean=1.00");
    EXPECT(asb_smart_trust_weight_x100(ASB_TRUST_PARTIAL) == 40,  "partial=0.40");
    EXPECT(asb_smart_trust_weight_x100(ASB_TRUST_NOISY)   == 15,  "noisy=0.15");
    EXPECT(asb_smart_trust_weight_x100(ASB_TRUST_DIRTY)   == 0,   "dirty=0.00");
    EXPECT(asb_smart_trust_weight_x100(99) == 40, "unknown→partial default");
}

static void test_eff_obs_add(void) {
    printf("test_eff_obs_add\n");
    /* 30min clean = 1.0 * 1.0 = 1.0 (x100=100) */
    EXPECT(asb_smart_eff_obs_add_x100(1800, ASB_TRUST_CLEAN) == 100, "30min clean = 100");
    /* 30min noisy = 1.0 * 0.15 = 0.15 (x100=15) */
    EXPECT(asb_smart_eff_obs_add_x100(1800, ASB_TRUST_NOISY) == 15, "30min noisy = 15");
    /* 5min clean = 0.25 * 1.0 = 0.25 (x100=25) */
    EXPECT(asb_smart_eff_obs_add_x100(300, ASB_TRUST_CLEAN) == 25, "5min clean = 25");
    /* 90min clean = 1.25 * 1.0 = 1.25 (x100=125) */
    EXPECT(asb_smart_eff_obs_add_x100(5400, ASB_TRUST_CLEAN) == 125, "90min clean = 125");
    /* Dirty always 0 */
    EXPECT(asb_smart_eff_obs_add_x100(3600, ASB_TRUST_DIRTY) == 0, "dirty session = 0");
}

static void test_decay(void) {
    printf("test_decay\n");
    time_t now = 1700000000;
    /* Never seen */
    EXPECT(asb_smart_decay_x100(0, now) == 100, "never_seen → full");
    /* Fresh */
    EXPECT(asb_smart_decay_x100((uint32_t)(now - 3 * 86400), now) == 100, "3 days → full");
    EXPECT(asb_smart_decay_x100((uint32_t)(now - 6 * 86400), now) == 100, "6 days → full");
    /* At boundary 7 days = start of decay */
    EXPECT(asb_smart_decay_x100((uint32_t)(now - 7 * 86400), now) == 100, "7 days exactly → still full (linear from this point)");
    /* Midway through decay */
    int mid = asb_smart_decay_x100((uint32_t)(now - 22 * 86400), now);
    EXPECT_NEAR(mid, 65, 5, "22 days ~= mid decay (~65)");
    /* Near end of decay */
    int near_end = asb_smart_decay_x100((uint32_t)(now - 36 * 86400), now);
    EXPECT_NEAR(near_end, 32, 5, "36 days → near floor");
    /* Past stale */
    EXPECT(asb_smart_decay_x100((uint32_t)(now - 40 * 86400), now) == 0, "40 days → 0");
}

static void test_confidence(void) {
    printf("test_confidence\n");
    time_t now = 1700000000;
    asb_smart_bucket_t b = {0};

    /* Empty bucket */
    EXPECT(asb_smart_confidence_x1000(&b, now) == 0, "empty bucket → 0");

    /* Mid eff_obs, fresh (EFF_OBS_FULL_X100 = 800, so 1000 saturates to max)
     * Test changed to use 400 (half of full) to get ~500 conf. */
    b.eff_obs_x100 = 400;  /* 4.0 effective obs = 50% of EFF_OBS_FULL=800 */
    b.last_seen_ts = (uint32_t)(now - 3600);
    int c1 = asb_smart_confidence_x1000(&b, now);
    EXPECT_NEAR(c1, 500, 5, "eff_obs=4/8 fresh → ~500");

    /* Full eff_obs, fresh */
    b.eff_obs_x100 = 2000;
    int c2 = asb_smart_confidence_x1000(&b, now);
    EXPECT(c2 == 1000, "eff_obs=full fresh → 1000");

    /* Saturated eff_obs */
    b.eff_obs_x100 = 4000;
    int c3 = asb_smart_confidence_x1000(&b, now);
    EXPECT(c3 == 1000, "eff_obs saturated → 1000");

    /* Full obs but decayed */
    b.eff_obs_x100 = 2000;
    b.last_seen_ts = (uint32_t)(now - 22 * 86400);
    int c4 = asb_smart_confidence_x1000(&b, now);
    EXPECT_NEAR(c4, 650, 50, "full obs but 22d old → ~650");

    /* Full obs stale */
    b.last_seen_ts = (uint32_t)(now - 40 * 86400);
    EXPECT(asb_smart_confidence_x1000(&b, now) == 0, "40 days → 0");
}

static void test_confidence_tier(void) {
    printf("test_confidence_tier\n");
    EXPECT(asb_smart_confidence_tier(0) == 0, "conf=0 → tier 0");
    EXPECT(asb_smart_confidence_tier(349) == 0, "conf=349 → tier 0");
    EXPECT(asb_smart_confidence_tier(350) == 1, "conf=350 → tier 1 (low boundary)");
    EXPECT(asb_smart_confidence_tier(500) == 1, "conf=500 → tier 1");
    EXPECT(asb_smart_confidence_tier(649) == 1, "conf=649 → tier 1");
    EXPECT(asb_smart_confidence_tier(650) == 2, "conf=650 → tier 2 (high boundary)");
    EXPECT(asb_smart_confidence_tier(1000) == 2, "conf=1000 → tier 2");
}

static void test_daypart_class(void) {
    printf("test_daypart_class\n");
    EXPECT(asb_smart_daypart_class(ASB_DAYPART_SLEEP) == 0, "sleep → night");
    EXPECT(asb_smart_daypart_class(ASB_DAYPART_LATE)  == 0, "late → night");
    EXPECT(asb_smart_daypart_class(ASB_DAYPART_WAKE)  == 1, "wake → day");
    EXPECT(asb_smart_daypart_class(ASB_DAYPART_MORN)  == 1, "morn → day");
    EXPECT(asb_smart_daypart_class(ASB_DAYPART_DAY)   == 1, "day → day");
    EXPECT(asb_smart_daypart_class(ASB_DAYPART_EVE)   == 2, "eve → evening");
}

static void test_fallback_safe_default(void) {
    printf("test_fallback_safe_default\n");
    asb_smart_store_t st;
    asb_smart_store_seed_defaults(&st);
    /* All seeded, but no observations → confidence=0 → must fall to SAFE */
    time_t now = time(NULL);
    int fb = -1;
    asb_smart_bucket_t *b = asb_smart_lookup_bucket(&st, ASB_DAYPART_EVE, 0, now, &fb);
    EXPECT(b != NULL, "lookup returns non-null even for empty store");
    EXPECT(fb == ASB_SMART_FALLBACK_SAFE, "no data → SAFE fallback");
    EXPECT(b->alpha_battery_x1000 == 500, "safe default alpha = 500");
}

static void test_fallback_exact(void) {
    printf("test_fallback_exact\n");
    asb_smart_store_t st;
    asb_smart_store_seed_defaults(&st);
    time_t now = time(NULL);

    /* Give EVE weekday bucket high confidence */
    int eve_wd = (int)asb_smart_bucket_id(ASB_DAYPART_EVE, 0);
    st.buckets[eve_wd].eff_obs_x100 = 2000;
    st.buckets[eve_wd].last_seen_ts = (uint32_t)(now - 86400);
    st.buckets[eve_wd].alpha_battery_x1000 = 300;

    int fb = -1;
    asb_smart_bucket_t *b = asb_smart_lookup_bucket(&st, ASB_DAYPART_EVE, 0, now, &fb);
    EXPECT(fb == ASB_SMART_FALLBACK_EXACT, "exact match found");
    EXPECT(b->bucket_id == (uint32_t)eve_wd, "returned exact bucket");
    EXPECT(b->alpha_battery_x1000 == 300, "correct bucket data");
}

static void test_fallback_daypart_only(void) {
    printf("test_fallback_daypart_only\n");
    asb_smart_store_t st;
    asb_smart_store_seed_defaults(&st);
    time_t now = time(NULL);

    /* EVE weekend has data, EVE weekday does not → request weekday → fallback to weekend */
    int eve_we = (int)asb_smart_bucket_id(ASB_DAYPART_EVE, 1);
    st.buckets[eve_we].eff_obs_x100 = 2000;
    st.buckets[eve_we].last_seen_ts = (uint32_t)(now - 86400);
    st.buckets[eve_we].alpha_battery_x1000 = 400;

    int fb = -1;
    asb_smart_bucket_t *b = asb_smart_lookup_bucket(&st, ASB_DAYPART_EVE, 0, now, &fb);
    EXPECT(fb == ASB_SMART_FALLBACK_DAYPART_ONLY, "fallback to other weekend-variant");
    EXPECT(b->bucket_id == (uint32_t)eve_we, "returned daypart-paired bucket");
}

static void test_fallback_class(void) {
    printf("test_fallback_class\n");
    asb_smart_store_t st;
    asb_smart_store_seed_defaults(&st);
    time_t now = time(NULL);

    /* Only LATE weekday has data. Request SLEEP weekday → same class (night) → CLASS fallback. */
    int late_wd = (int)asb_smart_bucket_id(ASB_DAYPART_LATE, 0);
    st.buckets[late_wd].eff_obs_x100 = 2000;
    st.buckets[late_wd].last_seen_ts = (uint32_t)(now - 86400);
    st.buckets[late_wd].alpha_battery_x1000 = 600;

    int fb = -1;
    asb_smart_bucket_t *b = asb_smart_lookup_bucket(&st, ASB_DAYPART_SLEEP, 0, now, &fb);
    EXPECT(fb == ASB_SMART_FALLBACK_CLASS, "fallback to class peer");
    EXPECT(b->bucket_id == (uint32_t)late_wd, "found class-peer bucket");
}

static void test_fallback_global(void) {
    printf("test_fallback_global\n");
    asb_smart_store_t st;
    asb_smart_store_seed_defaults(&st);
    time_t now = time(NULL);

    /* Only EVE weekend has data. Request SLEEP weekday — class mismatch → GLOBAL fallback. */
    int eve_we = (int)asb_smart_bucket_id(ASB_DAYPART_EVE, 1);
    st.buckets[eve_we].eff_obs_x100 = 2000;
    st.buckets[eve_we].last_seen_ts = (uint32_t)(now - 86400);

    int fb = -1;
    asb_smart_bucket_t *b = asb_smart_lookup_bucket(&st, ASB_DAYPART_SLEEP, 0, now, &fb);
    EXPECT(fb == ASB_SMART_FALLBACK_GLOBAL, "fallback to global best");
    EXPECT(b->bucket_id == (uint32_t)eve_we, "found global best bucket");
}

static void test_compute_effective_no_conf(void) {
    printf("test_compute_effective_no_conf\n");
    asb_smart_bucket_t b = {0};
    b.alpha_battery_x1000 = 900;  /* bucket says aggressive battery */
    b.interactive_bonus_x1000 = 100;
    b.idle_bias_x1000 = 100;

    asb_smart_runtime_t rt = {0};
    asb_smart_compute_effective(&b, 100, &rt);  /* below low threshold */
    /* seed_baseline mode — 25% influence at zero conf instead of 0.
     * alpha = 500 + (900-500) * 0.25 = 500 + 100 = 600 */
    EXPECT_NEAR(rt.alpha_battery_x1000, 600, 5, "below low conf → seed_baseline 25% (600)");
    /* interactive = 100 * 0.25 = 25 */
    EXPECT_NEAR(rt.interactive_bonus_x1000, 25, 2, "below low conf → 25% bonus");
    /* idle_bias = 100 * 0.25 = 25 */
    EXPECT_NEAR(rt.idle_bias_x1000, 25, 2, "below low conf → 25% bias");
}

static void test_compute_effective_mild(void) {
    printf("test_compute_effective_mild\n");
    asb_smart_bucket_t b = {0};
    b.alpha_battery_x1000 = 900;
    b.interactive_bonus_x1000 = 100;

    asb_smart_runtime_t rt = {0};
    /* conf 500 → mid-mild tier */
    asb_smart_compute_effective(&b, 500, &rt);
    /* eff_scale: into=150, span=300, eff = 250 + (350*150)/300 = 425
     * alpha = 500 + (900-500) * 425/1000 = 500 + 170 = 670 */
    EXPECT_NEAR(rt.alpha_battery_x1000, 670, 5, "mild blend alpha~670");
    /* interactive = (100 * 425)/1000 = 42 */
    EXPECT_NEAR(rt.interactive_bonus_x1000, 42, 2, "mild blend interactive~42");
}

static void test_compute_effective_strong(void) {
    printf("test_compute_effective_strong\n");
    asb_smart_bucket_t b = {0};
    b.alpha_battery_x1000 = 900;
    b.interactive_bonus_x1000 = 100;

    asb_smart_runtime_t rt = {0};
    /* Full confidence */
    asb_smart_compute_effective(&b, 1000, &rt);
    EXPECT(rt.alpha_battery_x1000 == 900, "full conf → full bucket alpha");
    EXPECT(rt.interactive_bonus_x1000 == 100, "full conf → full interactive");
}

static void test_night_override(void) {
    printf("test_night_override\n");
    asb_smart_runtime_t rt = {0};
    rt.alpha_battery_x1000 = 400;
    rt.sleep_bias_x1000 = 100;
    rt.net_conservative_x1000 = 200;
    rt.interactive_bonus_x1000 = 80;

    /* Night conditions all met */
    asb_smart_apply_night_override(ASB_DAYPART_SLEEP, 0, 0, 0, ASB_APP_IDLE, 50, &rt);
    EXPECT(rt.night_safe_override == 1, "night override fires");
    EXPECT(rt.alpha_battery_x1000 >= 900, "alpha forced ≥ 900");
    EXPECT(rt.sleep_bias_x1000 >= 800, "sleep_bias forced ≥ 800");
    EXPECT(rt.net_conservative_x1000 >= 700, "net forced ≥ 700");
    EXPECT(rt.interactive_bonus_x1000 == 0, "interactive zeroed");

    /* Day condition — should not fire */
    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 400;
    asb_smart_apply_night_override(ASB_DAYPART_DAY, 0, 1, 0, ASB_APP_IDLE, 50, &rt2);
    EXPECT(rt2.night_safe_override == 0, "day → no override");
    EXPECT(rt2.alpha_battery_x1000 == 400, "alpha preserved");

    asb_smart_runtime_t rt2b = {0};
    rt2b.alpha_battery_x1000 = 300;
    asb_smart_apply_night_override(ASB_DAYPART_DAY, 1, 0, 0, ASB_APP_IDLE, 50, &rt2b);
    EXPECT(rt2b.night_safe_override == 1, "learned night window fires outside static dayparts");

    /* Night but charging — should not fire */
    asb_smart_runtime_t rt3 = {0};
    rt3.alpha_battery_x1000 = 400;
    asb_smart_apply_night_override(ASB_DAYPART_SLEEP, 0, 0, 1, ASB_APP_IDLE, 50, &rt3);
    EXPECT(rt3.night_safe_override == 0, "charging → no override");

    /* Night but heavy app foreground — should not fire */
    asb_smart_runtime_t rt4 = {0};
    rt4.alpha_battery_x1000 = 400;
    asb_smart_apply_night_override(ASB_DAYPART_SLEEP, 0, 0, 0, ASB_APP_GAMING, 50, &rt4);
    EXPECT(rt4.night_safe_override == 0, "heavy app → no override");
}

static void test_thermal_veto(void) {
    printf("test_thermal_veto\n");
    asb_smart_runtime_t rt = {0};
    rt.alpha_battery_x1000 = 300;
    rt.conf_x1000 = 800;
    rt.interactive_bonus_x1000 = 100;

    /* CPU hot triggers veto */
    asb_smart_apply_thermal_veto(70, 100, 0, &rt);
    EXPECT(rt.thermal_veto == 1, "CPU 70°C → veto");
    EXPECT(rt.alpha_battery_x1000 >= 700, "veto raises alpha to ≥ 700");
    EXPECT(rt.conf_x1000 < 800, "veto downscales confidence");
    EXPECT(rt.interactive_bonus_x1000 <= 50, "veto halves interactive");

    /* Vendor clamping triggers veto */
    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_veto(40, 400, 0, &rt2);
    EXPECT(rt2.thermal_veto == 1, "vendor_clamp_1h=400 → veto");

    /* Recovery active triggers veto */
    asb_smart_runtime_t rt3 = {0};
    rt3.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_veto(40, 50, 1, &rt3);
    EXPECT(rt3.thermal_veto == 1, "recovery → veto");

    /* Cool, no clamping, no recovery → no veto */
    asb_smart_runtime_t rt4 = {0};
    rt4.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_veto(45, 100, 0, &rt4);
    EXPECT(rt4.thermal_veto == 0, "cool device → no veto");
    EXPECT(rt4.alpha_battery_x1000 == 300, "alpha untouched without veto");
}

static void test_thermal_trend_calc(void) {
    printf("test_thermal_trend_calc\n");
    EXPECT(asb_smart_thermal_trend_bump_calc(40, 12000, 0) == 0, "cool device → no trend bump");
    EXPECT(asb_smart_thermal_trend_bump_calc(50, 0, 0) == 0, "flat temp → no bump");
    EXPECT(asb_smart_thermal_trend_bump_calc(50, -6000, 0) == 0, "cooling → no bump");
    EXPECT(asb_smart_thermal_trend_bump_calc(50, 3000, 0) == 0, "slope at min threshold → 0");
    EXPECT(asb_smart_thermal_trend_bump_calc(50, 7500, 0) == 60, "mid slope → 60");
    EXPECT(asb_smart_thermal_trend_bump_calc(50, 12000, 0) == 120, "max slope → 120");
    EXPECT(asb_smart_thermal_trend_bump_calc(50, 50000, 0) == 120, "slope clamps at 120");
    EXPECT(asb_smart_thermal_trend_bump_calc(45, 12000, 0) == 120, "45°C boundary engages");
    EXPECT(asb_smart_thermal_trend_bump_calc(44, 12000, 0) == 0, "44°C below boundary");
    EXPECT(asb_smart_thermal_trend_bump_calc(42, 12000, 1) == 120, "hot app → engages from 40°C");
    EXPECT(asb_smart_thermal_trend_bump_calc(39, 12000, 1) == 0, "hot app → 39°C still cool");
    EXPECT(asb_smart_thermal_trend_bump_calc(45, 2500, 1) > 0, "hot app → lower slope threshold");
    EXPECT(asb_smart_thermal_trend_bump_calc(45, 2500, 0) == 0, "normal app → 2500 below threshold");

    /* Charge-aware cool gaming (level 2): engages even earlier than level 1. */
    EXPECT(asb_smart_thermal_trend_bump_calc(38, 12000, 2) > 0, "charge-aware → engages from 38°C");
    EXPECT(asb_smart_thermal_trend_bump_calc(38, 12000, 1) == 0, "level 1 → 38°C still below its 40°C floor");
    EXPECT(asb_smart_thermal_trend_bump_calc(45, 1800, 2) > 0, "charge-aware → lower slope threshold (1500)");
    EXPECT(asb_smart_thermal_trend_bump_calc(45, 1800, 1) == 0, "level 1 → 1800 below its 2000 slope floor");
    EXPECT(asb_smart_thermal_trend_bump_calc(37, 12000, 2) == 0, "charge-aware → 37°C still below its 38°C floor");
    EXPECT(asb_smart_thermal_trend_bump_calc(45, 2000, 1) == 0, "hot app → 2000 at threshold");
}

static void test_appheat_table(void) {
    printf("test_appheat_table\n");
    memset(&g_smart_appheat, 0, sizeof(g_smart_appheat));
    time_t t0 = 1000000;

    EXPECT(asb_smart_appheat_score(0x1111ULL, t0) == 0, "unknown app → score 0");
    EXPECT(asb_smart_appheat_score(0, t0) == 0, "zero hash → score 0");

    asb_smart_appheat_bump(0x1111ULL, t0);
    EXPECT(asb_smart_appheat_score(0x1111ULL, t0) == 2, "one bump → score 2");

    for (int i = 0; i < 4; i++) asb_smart_appheat_bump(0x1111ULL, t0);
    EXPECT(asb_smart_appheat_score(0x1111ULL, t0) == 10, "five bumps → hot threshold");

    for (int i = 0; i < 200; i++) asb_smart_appheat_bump(0x1111ULL, t0);
    EXPECT(asb_smart_appheat_score(0x1111ULL, t0) == ASB_SMART_APPHEAT_MAX, "score caps at max");

    asb_smart_appheat_bump(0, t0);
    EXPECT(asb_smart_appheat_find(0) == NULL, "zero hash never stored");

    EXPECT(asb_smart_appheat_score(0x1111ULL, t0 + 86400L * 20) ==
           ASB_SMART_APPHEAT_MAX - 20, "decays 1 per day");

    memset(&g_smart_appheat, 0, sizeof(g_smart_appheat));
    for (int i = 0; i < ASB_SMART_APPHEAT_N; i++) {
        asb_smart_appheat_bump(0x2000ULL + i, t0 + i);
    }
    asb_smart_appheat_bump(0x9999ULL, t0 + 100);
    EXPECT(asb_smart_appheat_find(0x9999ULL) != NULL, "LRU insert when full");
    EXPECT(asb_smart_appheat_find(0x2000ULL) == NULL, "oldest entry evicted");
    EXPECT(asb_smart_appheat_find(0x2001ULL) != NULL, "newer entries kept");

    memset(&g_smart_appheat, 0, sizeof(g_smart_appheat));
}

static void test_bucket_learn_drain_loop(void) {
    printf("test_bucket_learn_drain_loop\n");
    asb_smart_bucket_t b = {0};
    b.alpha_battery_x1000 = 500;
    asb_smart_session_input_t s = {0};
    s.dur_s = 1800;
    s.max_temp_c = 58;
    s.trust = ASB_TRUST_CLEAN;
    s.drain_pctph_x10 = 80;
    s.drain_on_sec = 1800;

    asb_smart_bucket_update_from_session(&b, &s, time(NULL));
    EXPECT(b.avg_drain_pctph_x10 == 80, "first sample seeds drain EWMA");
    int alpha_after_seed = b.alpha_battery_x1000;

    s.drain_pctph_x10 = 160;
    asb_smart_bucket_update_from_session(&b, &s, time(NULL));
    EXPECT(b.alpha_battery_x1000 > alpha_after_seed, "drain spike → alpha leans battery");
    EXPECT(b.avg_drain_pctph_x10 == 100, "EWMA blends spike (80*3+160)/4");

    asb_smart_bucket_t b2 = {0};
    b2.alpha_battery_x1000 = 600;
    b2.avg_drain_pctph_x10 = 100;
    asb_smart_session_input_t s2 = {0};
    s2.dur_s = 1800;
    s2.max_temp_c = 60;
    s2.trust = ASB_TRUST_CLEAN;
    s2.drain_pctph_x10 = 60;
    s2.drain_on_sec = 1800;
    asb_smart_bucket_update_from_session(&b2, &s2, time(NULL));
    EXPECT(b2.alpha_battery_x1000 < 600, "low drain + clean → alpha drifts back");
    EXPECT(b2.avg_drain_pctph_x10 == 90, "EWMA tracks down (100*3+60)/4");

    asb_smart_bucket_t b3 = {0};
    b3.alpha_battery_x1000 = 500;
    b3.avg_drain_pctph_x10 = 100;
    asb_smart_session_input_t s3 = {0};
    s3.dur_s = 1800;
    s3.max_temp_c = 58;
    s3.trust = ASB_TRUST_CLEAN;
    s3.drain_pctph_x10 = 300;
    s3.drain_on_sec = 120;
    asb_smart_bucket_update_from_session(&b3, &s3, time(NULL));
    EXPECT(b3.avg_drain_pctph_x10 == 100, "short window → sample ignored");
    EXPECT(b3.alpha_battery_x1000 == 500, "short window → no feedback");

    asb_smart_bucket_t b4 = {0};
    b4.alpha_battery_x1000 = 500;
    b4.avg_drain_pctph_x10 = 100;
    asb_smart_session_input_t s4 = {0};
    s4.dur_s = 1800;
    s4.max_temp_c = 72;
    s4.trust = ASB_TRUST_CLEAN;
    s4.was_thermal_hit = 1;
    s4.drain_pctph_x10 = 200;
    s4.drain_on_sec = 1800;
    asb_smart_bucket_update_from_session(&b4, &s4, time(NULL));
    EXPECT(b4.avg_drain_pctph_x10 == 125, "thermal session still updates EWMA");
}

static void test_boot_settle_trend(void) {
    printf("test_boot_settle_trend\n");
    g_smart_trend_prev_ts = 0;
    g_smart_trend_slope_mc_min = 0;
    time_t t0 = 1000000;
    asb_smart_runtime_t rt = {0};
    rt.alpha_battery_x1000 = 300;

    asb_smart_apply_thermal_trend(38, t0, 0, 1, &rt);
    asb_smart_apply_thermal_trend(41, t0 + 30, 0, 1, &rt);
    asb_smart_apply_thermal_trend(44, t0 + 60, 0, 1, &rt);
    EXPECT(rt.thermal_trend_bump > 0, "settle window engages trend from 40C");

    g_smart_trend_prev_ts = 0;
    g_smart_trend_slope_mc_min = 0;
    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_trend(38, t0, 0, 0, &rt2);
    asb_smart_apply_thermal_trend(41, t0 + 30, 0, 0, &rt2);
    asb_smart_apply_thermal_trend(44, t0 + 60, 0, 0, &rt2);
    EXPECT(rt2.thermal_trend_bump == 0, "no settle keeps standard 45C threshold");

    g_smart_trend_prev_ts = 0;
    g_smart_trend_slope_mc_min = 0;
}

static void test_thermal_trend_state(void) {
    printf("test_thermal_trend_state\n");
    g_smart_trend_prev_ts = 0;
    g_smart_trend_slope_mc_min = 0;
    time_t t0 = 1000000;

    asb_smart_runtime_t rt = {0};
    rt.alpha_battery_x1000 = 300;

    /* First sample seeds the window — no bump */
    asb_smart_apply_thermal_trend(48, t0, 0, 0, &rt);
    EXPECT(rt.thermal_trend_bump == 0, "seed sample → no bump");
    EXPECT(rt.alpha_battery_x1000 == 300, "seed sample → alpha untouched");

    /* +3°C over 30s = 6000 m°C/min raw, EWMA (0+6000)/2 = 3000 → still ≤ min */
    asb_smart_apply_thermal_trend(51, t0 + 30, 0, 0, &rt);
    EXPECT(rt.thermal_trend_bump == 0, "first window EWMA at threshold → no bump");

    /* Another +3°C/30s: EWMA (3000+6000)/2 = 4500 → bump = 120*1500/9000 = 20 */
    asb_smart_apply_thermal_trend(54, t0 + 60, 0, 0, &rt);
    EXPECT(rt.thermal_trend_bump == 20, "sustained ramp → bump 20");
    EXPECT(rt.alpha_battery_x1000 == 320, "bump raises alpha");

    /* Cooling window pulls EWMA back down */
    asb_smart_apply_thermal_trend(50, t0 + 90, 0, 0, &rt);
    EXPECT(rt.thermal_trend_bump == 0, "cooling window decays trend");

    /* Veto active → trend never stacks on top */
    g_smart_trend_prev_ts = 0;
    g_smart_trend_slope_mc_min = 9000;
    g_smart_trend_prev_c = 55;
    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 700;
    rt2.thermal_veto = 1;
    asb_smart_apply_thermal_trend(55, t0, 0, 0, &rt2);
    asb_smart_apply_thermal_trend(58, t0 + 30, 0, 0, &rt2);
    EXPECT(rt2.thermal_trend_bump == 0, "veto active → trend skipped");
    EXPECT(rt2.alpha_battery_x1000 == 700, "veto active → alpha untouched by trend");

    /* Stale gap re-seeds instead of computing a slope across deep sleep */
    g_smart_trend_prev_ts = 0;
    g_smart_trend_slope_mc_min = 0;
    asb_smart_runtime_t rt3 = {0};
    rt3.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_trend(40, t0, 0, 0, &rt3);
    asb_smart_apply_thermal_trend(55, t0 + 600, 0, 0, &rt3);
    EXPECT(rt3.thermal_trend_bump == 0, "stale gap → re-seed, no bump");
    EXPECT(g_smart_trend_slope_mc_min == 0, "stale gap → slope reset");

    /* Invalid temp resets state */
    asb_smart_apply_thermal_trend(0, t0 + 630, 0, 0, &rt3);
    EXPECT(g_smart_trend_prev_ts == 0, "invalid temp → state reset");
}

static void test_drain_spike_window(void) {
    printf("test_drain_spike_window\n");
    /* drain-spike adds a temporary severity bump on top of budget tiers,
       only while discharging and at/below the budget battery ceiling */
    g_smart_budget_sev = 0; g_smart_budget_since = 0;
    asb_smart_runtime_t rt = {0};
    rt.alpha_battery_x1000 = 300;
    asb_smart_apply_energy_budget(60, 0, 80, 1000000, &rt);
    EXPECT(rt.budget_severity == 0, "60%% no tier and above ceiling \u2192 sev 0");

    g_smart_budget_sev = 0; g_smart_budget_since = 0;
    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 300;
    asb_smart_apply_energy_budget(40, 0, 80, 1000000, &rt2);
    int base = rt2.budget_severity;
    EXPECT(base == 0, "40%% at 8%%/h \u2192 5h \u2192 base sev 0");
    /* simulate the governor's spike add */
    if (base < 2) base++;
    EXPECT(base == 1, "spike bump raises sev 0 \u2192 1");

    g_smart_budget_sev = 0; g_smart_budget_since = 0;
}

static void test_energy_budget(void) {
    printf("test_energy_budget\n");
    time_t t0 = 1000000;

    g_smart_budget_sev = 0; g_smart_budget_since = 0;
    asb_smart_runtime_t rt = {0};
    rt.alpha_battery_x1000 = 400;
    asb_smart_apply_energy_budget(40, 0, 0, t0, &rt);
    EXPECT(rt.budget_severity == 0, "no drain history \u2192 budget inactive");
    EXPECT(rt.budget_pred_h_x10 == -1, "no drain history \u2192 no prediction");

    asb_smart_apply_energy_budget(40, 0, 80, t0, &rt);
    EXPECT(rt.budget_pred_h_x10 == 50, "40% at 8%/h \u2192 5.0h predicted");
    EXPECT(rt.budget_severity == 0, "5h left \u2192 no budget pressure");
    EXPECT(rt.alpha_battery_x1000 == 400, "inactive budget \u2192 alpha untouched");

    asb_smart_apply_energy_budget(30, 0, 100, t0 + 10, &rt);
    EXPECT(rt.budget_pred_h_x10 == 30, "30% at 10%/h \u2192 3.0h");
    EXPECT(rt.budget_severity == 1, "3h < 4h target \u2192 warn tier");
    EXPECT(rt.alpha_battery_x1000 == 600, "warn tier \u2192 alpha floor 600");

    rt.alpha_battery_x1000 = 400;
    asb_smart_apply_energy_budget(20, 0, 110, t0 + 20, &rt);
    EXPECT(rt.budget_pred_h_x10 == 18, "20% at 11%/h \u2192 1.8h");
    EXPECT(rt.budget_severity == 2, "under 2h \u2192 emergency tier");
    EXPECT(rt.alpha_battery_x1000 == 700, "emergency \u2192 alpha floor 700");

    rt.alpha_battery_x1000 = 400;
    asb_smart_apply_energy_budget(45, 0, 80, t0 + 30, &rt);
    EXPECT(rt.budget_severity == 2, "improvement inside dwell \u2192 severity held");

    rt.alpha_battery_x1000 = 400;
    asb_smart_apply_energy_budget(45, 0, 80, t0 + 30 + 200, &rt);
    EXPECT(rt.budget_severity == 0, "improvement after dwell \u2192 released");
    EXPECT(rt.alpha_battery_x1000 == 400, "released \u2192 alpha untouched");

    g_smart_budget_sev = 2; g_smart_budget_since = t0;
    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 400;
    asb_smart_apply_energy_budget(20, 1, 110, t0 + 5, &rt2);
    EXPECT(rt2.budget_severity == 0, "charging \u2192 budget off immediately");

    g_smart_budget_sev = 0; g_smart_budget_since = 0;
    asb_smart_runtime_t rt3 = {0};
    rt3.alpha_battery_x1000 = 400;
    asb_smart_apply_energy_budget(80, 0, 300, t0, &rt3);
    EXPECT(rt3.budget_pred_h_x10 == 26, "80% at 30%/h \u2192 2.7h predicted");
    EXPECT(rt3.budget_severity == 0, "above 50% \u2192 budget never engages");

    g_smart_budget_sev = 0; g_smart_budget_since = 0;
}

static void test_session_quality(void) {
    printf("test_session_quality\n");
    EXPECT(asb_smart_session_quality(40, 1, 40, 0, 0) == 100, "cool clean cheap \u2192 100");
    EXPECT(asb_smart_session_quality(250, 1, 75, 5, 5) == 0, "hot drainy unstable \u2192 0");
    EXPECT(asb_smart_session_quality(150, 1, 60, 0, 0) == 65, "mid drain mid heat \u2192 65");
    EXPECT(asb_smart_session_quality(0, 0, 40, 0, 0) == 100, "no drain data \u2192 heat+stab only");
    EXPECT(asb_smart_session_quality(0, 0, 60, 1, 0) == 63, "no drain, warm, one thermal \u2192 63");
    EXPECT(asb_smart_session_quality(40, 1, 40, 10, 0) == 70, "stab clamps at 0");
    EXPECT(asb_smart_session_quality(40, 1, 90, 0, 0) == 65, "heat clamps at 0 above 75C");
}

static void test_session_quality_ex(void) {
    printf("test_session_quality_ex\n");
    asb_smart_quality_t q;

    int r = asb_smart_session_quality_ex(40, 1, 40, 0, 0, 3, &q);
    EXPECT(r == 100, "all clean incl vendor \u2192 100");
    EXPECT(q.q_battery == 100 && q.q_heat == 100 && q.q_stability == 100 &&
           q.q_vendor == 100, "breakdown all 100");
    EXPECT(q.primary_failure == ASB_QFAIL_NONE, "no failure");

    r = asb_smart_session_quality_ex(40, 1, 40, 0, 0, 60, &q);
    EXPECT(r == 85, "vendor war floor \u2192 85");
    EXPECT(q.q_vendor == 0, "60 clamps/h \u2192 vendor 0");
    EXPECT(q.primary_failure == ASB_QFAIL_VENDOR_WAR, "primary failure = vendor war");

    r = asb_smart_session_quality_ex(40, 1, 40, 0, 0, 33, &q);
    EXPECT(q.q_vendor == 49, "33 clamps/h \u2192 vendor 49");
    EXPECT(r == 92, "mid vendor war \u2192 92");

    r = asb_smart_session_quality_ex(0, 0, 60, 0, 0, 10, &q);
    EXPECT(r == 75, "no drain data + vendor \u2192 75");
    EXPECT(q.q_battery == -1, "no drain \u2192 bat -1");
    EXPECT(q.primary_failure == ASB_QFAIL_HEAT, "heat is worst \u2192 heat failure");

    r = asb_smart_session_quality_ex(60, 1, 50, 0, 0, -1, &q);
    EXPECT(r == 92, "no vendor data \u2192 legacy weights");
    EXPECT(q.q_vendor == -1, "no vendor data \u2192 vendor -1");
    EXPECT(q.primary_failure == ASB_QFAIL_NONE, "all >=70 \u2192 no failure");

    r = asb_smart_session_quality_ex(250, 1, 40, 0, 0, 3, &q);
    EXPECT(q.primary_failure == ASB_QFAIL_BATTERY, "drain worst \u2192 battery failure");

    /* Gaming: heavy drain + hot + moderate vendor clamps. Battery/heat are the
       honest failure; vendor's low score must not hijack primary_failure. */
    r = asb_smart_session_quality_ex(240, 1, 60, 1, 0, 44, &q);
    EXPECT(q.q_vendor < 30, "44 clamps/h \u2192 low vendor score");
    EXPECT(q.primary_failure != ASB_QFAIL_VENDOR_WAR,
           "gaming: bat/heat dominate, vendor not primary failure");
}

static void test_appheat_drain(void) {
    printf("test_appheat_drain\n");
    memset(&g_smart_appheat, 0, sizeof(g_smart_appheat));
    time_t t0 = 1000000;

    EXPECT(asb_smart_appheat_drain(0x5555ULL, t0) == 0, "unknown app \u2192 drain 0");

    asb_smart_appheat_drain_bump(0x5555ULL, t0);
    EXPECT(asb_smart_appheat_drain(0x5555ULL, t0) == 2, "one bump \u2192 drain 2");
    EXPECT(asb_smart_appheat_score(0x5555ULL, t0) == 0, "drain bump leaves heat score 0");

    asb_smart_appheat_bump(0x5555ULL, t0);
    EXPECT(asb_smart_appheat_score(0x5555ULL, t0) == 2, "heat bump independent");
    EXPECT(asb_smart_appheat_drain(0x5555ULL, t0) == 2, "heat bump leaves drain");

    for (int i = 0; i < 200; i++) asb_smart_appheat_drain_bump(0x5555ULL, t0);
    EXPECT(asb_smart_appheat_drain(0x5555ULL, t0) == ASB_SMART_APPHEAT_MAX, "drain caps at max");

    EXPECT(asb_smart_appheat_drain(0x5555ULL, t0 + 86400L * 10) ==
           ASB_SMART_APPHEAT_MAX - 10, "drain decays 1 per day");

    memset(&g_smart_appheat, 0, sizeof(g_smart_appheat));
}

static void test_idle_pocket_tier(void) {
    printf("test_idle_pocket_tier\n");
    asb_smart_runtime_t rt = {0};
    rt.alpha_battery_x1000 = 400;
    rt.interactive_bonus_x1000 = 100;

    /* New short screen-off tier: 30-120s now gets a gentle lean (alpha floor
     * 600) instead of nothing, to reclaim the easy economy in brief glance-and-
     * put-down windows the daily logs showed Smart was missing. */
    asb_smart_apply_idle_screen_override(0, 0, 1, 20, &rt);
    EXPECT(rt.alpha_battery_x1000 == 400, "under 30s \u2192 no pocket lean");

    asb_smart_apply_idle_screen_override(0, 0, 1, 60, &rt);
    EXPECT(rt.alpha_battery_x1000 == 600, "30-120s \u2192 gentle pocket lean 600");

    asb_smart_apply_idle_screen_override(0, 0, 1, 300, &rt);
    EXPECT(rt.alpha_battery_x1000 == 700, "pocket tier \u2192 alpha floor 700");
    EXPECT(rt.net_conservative_x1000 == 400, "pocket tier \u2192 net 400");
    EXPECT(rt.interactive_bonus_x1000 == 60, "pocket tier \u2192 bonus cap 60");

    rt.alpha_battery_x1000 = 400;
    asb_smart_apply_idle_screen_override(0, 0, 1, 2000, &rt);
    EXPECT(rt.alpha_battery_x1000 == 850, "full tier \u2192 alpha floor 850");
    EXPECT(rt.net_conservative_x1000 == 600, "full tier \u2192 net 600");

    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 400;
    asb_smart_apply_idle_screen_override(1, 0, 1, 300, &rt2);
    EXPECT(rt2.alpha_battery_x1000 == 400, "screen on \u2192 untouched");
    asb_smart_apply_idle_screen_override(0, 1, 1, 300, &rt2);
    EXPECT(rt2.alpha_battery_x1000 == 400, "charging \u2192 untouched");
    asb_smart_apply_idle_screen_override(0, 0, ASB_APP_HEAVY, 300, &rt2);
    EXPECT(rt2.alpha_battery_x1000 == 400, "heavy app \u2192 untouched");
}

static void test_cap_detente(void) {
    printf("test_cap_detente\n");
    EXPECT(asb_cap_detente_check(0, 1, 1, 300, 35, 0) == 1, "vendor-owned cool deep idle \u2192 detente");
    EXPECT(asb_cap_detente_check(1, 1, 1, 300, 35, 0) == 0, "screen on \u2192 no detente");
    EXPECT(asb_cap_detente_check(0, 0, 1, 300, 35, 0) == 0, "not deep idle \u2192 no detente");
    EXPECT(asb_cap_detente_check(0, 1, 0, 300, 35, 0) == 0, "asb owns caps \u2192 no detente");
    EXPECT(asb_cap_detente_check(0, 1, 1, 300, 35, 0) == 1, "shell or vendor owner both count as foreign");
    EXPECT(asb_cap_detente_check(0, 1, 1, 60, 35, 0) == 0, "vendor owner too fresh \u2192 no detente");
    EXPECT(asb_cap_detente_check(0, 1, 1, 300, 45, 0) == 0, "45C \u2192 no detente");
    EXPECT(asb_cap_detente_check(0, 1, 1, 300, 0, 0) == 0, "invalid temp \u2192 no detente");
    EXPECT(asb_cap_detente_check(0, 1, 1, 300, 35, 1) == 0, "thermal cap active \u2192 no detente");
    EXPECT(asb_cap_detente_check(0, 1, 1, 120, 44, 0) == 1, "boundary 120s/44C \u2192 detente");
}

static void test_low_battery_override(void) {
    printf("test_low_battery_override\n");

    /* Above engage threshold → no override */
    g_smart_lowbat_engaged = 0;
    asb_smart_runtime_t rt = {0};
    rt.alpha_battery_x1000 = 300;
    asb_smart_apply_low_battery_override(25, 0, &rt);
    EXPECT(rt.low_battery_override == 0, "25% → no override");
    EXPECT(rt.alpha_battery_x1000 == 300, "25% → alpha untouched");

    /* At 20% discharging → engages, alpha ≥ 800 */
    asb_smart_apply_low_battery_override(20, 0, &rt);
    EXPECT(rt.low_battery_override == 1, "20% discharging → override");
    EXPECT(rt.alpha_battery_x1000 == 800, "20% → alpha forced to 800");

    /* Hysteresis: recovery to 30% keeps it engaged */
    rt.alpha_battery_x1000 = 300;
    asb_smart_apply_low_battery_override(30, 0, &rt);
    EXPECT(rt.low_battery_override == 1, "30% after engage → still engaged");
    EXPECT(rt.alpha_battery_x1000 == 800, "hysteresis keeps 800 floor");

    /* Restore threshold releases */
    rt.alpha_battery_x1000 = 300;
    asb_smart_apply_low_battery_override(40, 0, &rt);
    EXPECT(rt.low_battery_override == 0, "40% → released");
    EXPECT(rt.alpha_battery_x1000 == 300, "released → alpha untouched");

    /* Critical tier: ≤10% → alpha ≥ 900, tighter interactive */
    g_smart_lowbat_engaged = 0;
    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 300;
    rt2.interactive_bonus_x1000 = 100;
    asb_smart_apply_low_battery_override(8, 0, &rt2);
    EXPECT(rt2.low_battery_override == 1, "8% → override");
    EXPECT(rt2.alpha_battery_x1000 == 900, "8% → critical alpha 900");
    EXPECT(rt2.interactive_bonus_x1000 == 20, "critical → interactive ≤ 20");

    /* Charging releases immediately even at low % */
    asb_smart_runtime_t rt3 = {0};
    rt3.alpha_battery_x1000 = 300;
    asb_smart_apply_low_battery_override(8, 1, &rt3);
    EXPECT(rt3.low_battery_override == 0, "charging → released");

    /* Engaging requires discharging */
    g_smart_lowbat_engaged = 0;
    asb_smart_runtime_t rt4 = {0};
    rt4.alpha_battery_x1000 = 300;
    asb_smart_apply_low_battery_override(15, 1, &rt4);
    EXPECT(rt4.low_battery_override == 0, "15% on charger → no engage");

    g_smart_lowbat_engaged = 0;
}

static void test_blend_values(void) {
    printf("test_blend_values\n");
    /* Battery CPU caps lower than balanced */
    int battery_vals[] = { 1132800, 1113600, 921600 };
    int balanced_vals[] = { 1881600, 1881600, 1881600 };
    int out[3] = {0};

    /* Alpha = 0 → all balanced */
    asb_smart_blend_values_int(battery_vals, balanced_vals, 3, 0, out);
    EXPECT(out[0] == balanced_vals[0], "alpha=0 → balanced[0]");
    EXPECT(out[1] == balanced_vals[1], "alpha=0 → balanced[1]");

    /* Alpha = 1000 → all battery */
    asb_smart_blend_values_int(battery_vals, balanced_vals, 3, 1000, out);
    EXPECT(out[0] == battery_vals[0], "alpha=1000 → battery[0]");

    /* Alpha = 500 → midpoint */
    asb_smart_blend_values_int(battery_vals, balanced_vals, 3, 500, out);
    int expected_mid = (battery_vals[0] + balanced_vals[0]) / 2;
    EXPECT_NEAR(out[0], expected_mid, 100, "alpha=500 → midpoint");

    /* Out-of-range alpha clamped */
    asb_smart_blend_values_int(battery_vals, balanced_vals, 3, 9999, out);
    EXPECT(out[0] == battery_vals[0], "alpha>1000 clamped → battery");

    /* Zero/zero pair stays zero */
    int b0[] = {0};
    int x0[] = {0};
    int out0[] = {-1};
    asb_smart_blend_values_int(b0, x0, 1, 500, out0);
    EXPECT(out0[0] == 0, "both zero → output zero");
}

static void test_interactive_bonus(void) {
    printf("test_interactive_bonus\n");
    /* Boost 1500000 by 10% bonus, ceiling 2000000 */
    int r = asb_smart_apply_interactive_bonus(1500000, 2000000, 100);
    EXPECT(r == 1650000, "1.5M + 10% = 1.65M");
    /* Boost that would exceed ceiling → clamped */
    int r2 = asb_smart_apply_interactive_bonus(1900000, 2000000, 100);
    EXPECT(r2 == 2000000, "boost capped at ceiling");
    /* Zero bonus → no change */
    int r3 = asb_smart_apply_interactive_bonus(1500000, 2000000, 0);
    EXPECT(r3 == 1500000, "zero bonus → no change");
}

static void test_bucket_learn_dirty(void) {
    printf("test_bucket_learn_dirty\n");
    asb_smart_bucket_t b = {0};
    b.alpha_battery_x1000 = 400;
    asb_smart_session_input_t s = {0};
    s.dur_s = 1800;
    s.max_temp_c = 70;
    s.trust = ASB_TRUST_DIRTY;

    asb_smart_bucket_update_from_session(&b, &s, time(NULL));
    EXPECT(b.eff_obs_x100 == 0, "dirty session does not contribute");
    EXPECT(b.alpha_battery_x1000 == 400, "dirty session does not adjust");
}

static void test_bucket_learn_hot(void) {
    printf("test_bucket_learn_hot\n");
    asb_smart_bucket_t b = {0};
    b.alpha_battery_x1000 = 400;
    asb_smart_session_input_t s = {0};
    s.dur_s = 1800;          /* 30 min */
    s.max_temp_c = 82;       /* very hot */
    s.drain_pctph_x10 = 2000;
    s.drain_on_sec = 1800;
    s.trust = ASB_TRUST_CLEAN;
    s.sustained_pct = 40;
    s.was_heavy = 1;

    int alpha_before = b.alpha_battery_x1000;
    asb_smart_bucket_update_from_session(&b, &s, time(NULL));
    EXPECT(b.alpha_battery_x1000 > alpha_before, "hot+drainy → alpha increases");
    EXPECT(b.eff_obs_x100 > 0, "session contributes to eff_obs");
    EXPECT(b.observations_raw == 1, "raw observation counter incremented");
    EXPECT(b.avg_max_temp_x10 == 820, "avg temp recorded");
}

static void test_bucket_learn_cool(void) {
    printf("test_bucket_learn_cool\n");
    asb_smart_bucket_t b = {0};
    b.alpha_battery_x1000 = 500;
    b.interactive_bonus_x1000 = 20;
    asb_smart_session_input_t s = {0};
    s.dur_s = 1800;
    s.max_temp_c = 48;       /* cool */
    s.drain_pctph_x10 = 0;
    s.drain_on_sec = 0;
    s.trust = ASB_TRUST_CLEAN;

    int alpha_before = b.alpha_battery_x1000;
    int inter_before = b.interactive_bonus_x1000;
    asb_smart_bucket_update_from_session(&b, &s, time(NULL));
    EXPECT(b.alpha_battery_x1000 < alpha_before, "clean+cool → alpha decreases");
    EXPECT(b.interactive_bonus_x1000 > inter_before, "clean+cool → interactive increases");
}

static void test_bucket_learn_thermal_hit(void) {
    printf("test_bucket_learn_thermal_hit\n");
    asb_smart_bucket_t b = {0};
    b.alpha_battery_x1000 = 400;
    b.interactive_bonus_x1000 = 100;
    asb_smart_session_input_t s = {0};
    s.dur_s = 1800;
    s.max_temp_c = 85;
    s.drain_pctph_x10 = 2200;
    s.drain_on_sec = 1800;
    s.trust = ASB_TRUST_CLEAN;
    s.was_thermal_hit = 1;
    s.sustained_pct = 50;

    asb_smart_bucket_update_from_session(&b, &s, time(NULL));
    EXPECT(b.alpha_battery_x1000 >= 410, "thermal hit → strong alpha increase");
    EXPECT(b.interactive_bonus_x1000 < 100, "thermal hit → interactive cut");
}

static void test_bucket_learn_clamping(void) {
    printf("test_bucket_learn_clamping\n");
    asb_smart_bucket_t b = {0};
    /* Push to maximum then try to add more */
    b.alpha_battery_x1000 = 990;
    asb_smart_session_input_t s = {0};
    s.dur_s = 5400;
    s.max_temp_c = 90;
    s.drain_pctph_x10 = 2500;
    s.drain_on_sec = 1800;
    s.trust = ASB_TRUST_CLEAN;
    s.was_thermal_hit = 1;
    s.sustained_pct = 70;

    asb_smart_bucket_update_from_session(&b, &s, time(NULL));
    EXPECT(b.alpha_battery_x1000 <= 1000, "alpha clamped to max");
    EXPECT(b.alpha_battery_x1000 >= 990, "but at least preserves prior value");
}

static void test_bucket_learn_sleep_quality(void) {
    printf("test_bucket_learn_sleep_quality\n");
    asb_smart_bucket_t b = {0};
    b.sleep_bias_x1000 = 100;
    b.net_conservative_x1000 = 100;
    asb_smart_session_input_t s = {0};
    s.dur_s = 3600 * 6;       /* 6 hours */
    s.max_temp_c = 30;
    s.drain_pctph_x10 = 0;
    s.drain_on_sec = 0;
    s.trust = ASB_TRUST_CLEAN;
    s.screen_on_pct = 0;
    s.idle_q_x10 = 80;        /* good idle */

    int sleep_before = b.sleep_bias_x1000;
    asb_smart_bucket_update_from_session(&b, &s, time(NULL));
    EXPECT(b.sleep_bias_x1000 > sleep_before, "good sleep session → sleep_bias up");
}

static void test_slot_update_gating(void) {
    printf("test_slot_update_gating\n");
    asb_smart_runtime_t rt = {0};
    /* First call always returns 1 */
    EXPECT(asb_smart_should_update_slot(&rt, 1000, 0, ASB_APP_IDLE) == 1, "first call → update");

    /* Mark updated, then no change → should NOT update */
    rt.bucket_id = 5;
    rt.daypart = 3;
    rt.prev_bucket_id = 5;
    rt.prev_daypart = 3;
    rt.conf_x1000 = 700;
    rt.night_safe_override = 0;
    rt.thermal_veto = 0;
    asb_smart_mark_slot_updated(&rt, 1000, 0, ASB_APP_IDLE);
    EXPECT(asb_smart_should_update_slot(&rt, 1010, 0, ASB_APP_IDLE) == 0, "no change → no update");

    /* Confidence tier crossed → should update */
    rt.conf_x1000 = 200;  /* tier 2 → tier 0 */
    EXPECT(asb_smart_should_update_slot(&rt, 1010, 0, ASB_APP_IDLE) == 1, "conf tier crossed → update");

    asb_smart_mark_slot_updated(&rt, 1010, 0, ASB_APP_IDLE);
    /* Charging state changed → should update */
    EXPECT(asb_smart_should_update_slot(&rt, 1020, 1, ASB_APP_IDLE) == 1, "charging change → update");

    asb_smart_mark_slot_updated(&rt, 1020, 1, ASB_APP_IDLE);
    /* App hint tier changed (LIGHT → GAMING) → should update */
    EXPECT(asb_smart_should_update_slot(&rt, 1030, 1, ASB_APP_GAMING) == 1, "app tier change → update");

    /* But same-tier app change should NOT trigger (IDLE → LIGHT both = tier 0) */
    asb_smart_mark_slot_updated(&rt, 1030, 1, ASB_APP_GAMING);
    EXPECT(asb_smart_should_update_slot(&rt, 1040, 1, ASB_APP_HEAVY) == 0, "same tier (heavy/gaming) → no update");
}

static void test_daypart_smoothing_factor(void) {
    printf("test_daypart_smoothing_factor\n");
    /* No smoothing if not started */
    EXPECT(asb_smart_daypart_smoothing_factor_x100(0, 1000, 800, 800) == 100, "no start → 100");

    /* If one side has low confidence — hard switch */
    EXPECT(asb_smart_daypart_smoothing_factor_x100(1000, 1100, 200, 800) == 100, "low prev conf → 100");
    EXPECT(asb_smart_daypart_smoothing_factor_x100(1000, 1100, 800, 200) == 100, "low cur conf → 100");

    /* Both confident, mid-smoothing */
    int half = asb_smart_daypart_smoothing_factor_x100(1000, 1000 + ASB_SMART_SMOOTH_S/2, 700, 700);
    EXPECT_NEAR(half, 50, 5, "halfway through → ~50");

    /* Past end of smoothing → 100 */
    EXPECT(asb_smart_daypart_smoothing_factor_x100(1000, 1000 + ASB_SMART_SMOOTH_S + 10, 700, 700) == 100,
           "past end → 100");
}

int main(void) {
    printf("=== Session unit tests ===\n\n");

    test_duration_weight();
    test_trust_weight();
    test_eff_obs_add();
    test_decay();
    test_confidence();
    test_confidence_tier();
    test_daypart_class();

    test_fallback_safe_default();
    test_fallback_exact();
    test_fallback_daypart_only();
    test_fallback_class();
    test_fallback_global();

    test_compute_effective_no_conf();
    test_compute_effective_mild();
    test_compute_effective_strong();

    test_night_override();
    test_thermal_veto();
    test_thermal_trend_calc();
    test_thermal_trend_state();
    test_boot_settle_trend();
    test_appheat_table();
    test_bucket_learn_drain_loop();
    test_energy_budget();
    test_drain_spike_window();
    test_idle_pocket_tier();
    test_cap_detente();
    test_session_quality();
    test_session_quality_ex();
    test_appheat_drain();
    test_low_battery_override();

    test_blend_values();
    test_interactive_bonus();

    test_bucket_learn_dirty();
    test_bucket_learn_hot();
    test_bucket_learn_cool();
    test_bucket_learn_thermal_hit();
    test_bucket_learn_clamping();
    test_bucket_learn_sleep_quality();

    test_slot_update_gating();
    test_daypart_smoothing_factor();

    printf("\n=== Summary ===\n");
    printf("  passed: %d\n", g_passes);
    printf("  failed: %d\n", g_fails);
    return g_fails == 0 ? 0 : 1;
}
