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
    asb_smart_apply_night_override(ASB_DAYPART_SLEEP, 0, 0, ASB_APP_IDLE, 50, &rt);
    EXPECT(rt.night_safe_override == 1, "night override fires");
    EXPECT(rt.alpha_battery_x1000 >= 900, "alpha forced ≥ 900");
    EXPECT(rt.sleep_bias_x1000 >= 800, "sleep_bias forced ≥ 800");
    EXPECT(rt.net_conservative_x1000 >= 700, "net forced ≥ 700");
    EXPECT(rt.interactive_bonus_x1000 == 0, "interactive zeroed");

    /* Day condition — should not fire */
    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 400;
    asb_smart_apply_night_override(ASB_DAYPART_DAY, 1, 0, ASB_APP_IDLE, 50, &rt2);
    EXPECT(rt2.night_safe_override == 0, "day → no override");
    EXPECT(rt2.alpha_battery_x1000 == 400, "alpha preserved");

    /* Night but charging — should not fire */
    asb_smart_runtime_t rt3 = {0};
    rt3.alpha_battery_x1000 = 400;
    asb_smart_apply_night_override(ASB_DAYPART_SLEEP, 0, 1, ASB_APP_IDLE, 50, &rt3);
    EXPECT(rt3.night_safe_override == 0, "charging → no override");

    /* Night but heavy app foreground — should not fire */
    asb_smart_runtime_t rt4 = {0};
    rt4.alpha_battery_x1000 = 400;
    asb_smart_apply_night_override(ASB_DAYPART_SLEEP, 0, 0, ASB_APP_GAMING, 50, &rt4);
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
    s.drain_mah_per_hour = 700;  /* drainy */
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
    s.drain_mah_per_hour = 200;  /* low drain */
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
    s.drain_mah_per_hour = 800;
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
    s.drain_mah_per_hour = 900;
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
    s.drain_mah_per_hour = 50;  /* low drain */
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
