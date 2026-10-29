#!/usr/bin/env bash
# ASB host tests: Smart, governor, thermal and CPU/GPU policy, with the native C fixtures.
#
# Each test is a function t_<name> whose body runs in its own subshell, exactly as the
# standalone script it used to be; the C fixtures it builds are the functions _c_<name>.
#   bash tests/asb_smart.sh                 run every test in this file
#   bash tests/asb_smart.sh NAME [NAME...]  run the named tests
#   bash tests/asb_smart.sh --list          list the tests
#   bash tests/asb_smart.sh --source NAME   print an embedded C fixture
# tools/asb_full_regression.sh runs every test of every tests/asb_*.sh in parallel.

_c_quiet_night_behaviour() {
  cat <<'ASB_C_EOF'
/* Quiet Night skip decision, exercised as behaviour rather than as source text.
 *
 * The source-level test next to this one checks WHERE the reset lives, which is what the
 * original bug was about. But a placement test can only ever prove placement: it would
 * pass on a rewrite that moved the reset correctly and still got the sequence wrong.
 *
 * This isolates the decision itself - given "is the mode active" and a tick counter, may
 * this tick skip its battery reads - and walks the transition that actually broke:
 * a skipping tick, then the mode ending. The flag must be clear on that next tick, because
 * everything downstream (auto-battery, charge awareness, the learner's drain, the
 * time-to-empty estimate) reads values that would otherwise be hours old.
 */
#include <stdio.h>

static int g_flag;
static int g_counter;

/* Mirrors the governor: clear unconditionally, then let an active skipping tick set it. */
static void quiet_night_tick(int active) {
    g_flag = 0;
    if (active) {
        g_counter++;
        if (g_counter % 2 != 0) g_flag = 1;
    }
}

static int fails;

static void check(const char *what, int got, int want) {
    if (got != want) {
        printf("  FAIL %-44s got %d want %d\n", what, got, want);
        fails++;
    } else {
        printf("  ok   %-44s %d\n", what, got);
    }
}

int main(void) {
    g_flag = 0; g_counter = 0;

    quiet_night_tick(1);  check("night tick 1 skips", g_flag, 1);
    quiet_night_tick(1);  check("night tick 2 reads", g_flag, 0);
    quiet_night_tick(1);  check("night tick 3 skips", g_flag, 1);

    /* The transition the bug lived in: mode ends immediately after a skipping tick. */
    quiet_night_tick(0);  check("first tick after mode ends reads", g_flag, 0);
    quiet_night_tick(0);  check("and keeps reading", g_flag, 0);
    quiet_night_tick(0);  check("and still keeps reading", g_flag, 0);

    /* Re-entry must not carry state that makes the first tick back skip unexpectedly. */
    quiet_night_tick(1);  check("re-entry alternates from where it left off", g_flag, 0);
    quiet_night_tick(1);  check("next night tick skips", g_flag, 1);
    quiet_night_tick(0);  check("exit again reads", g_flag, 0);

    if (fails) { printf("\n  failed: %d\n", fails); return 1; }
    printf("\n  passed: 9\n  failed: 0\n");
    return 0;
}
ASB_C_EOF
}

_c_smart_session2() {
  cat <<'ASB_C_EOF'
/* tests/test_smart_session2.c — unit test seam */

#ifndef _GNU_SOURCE   /* the build script passes -D_GNU_SOURCE as well */
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "asb_smart.h"

static int g_fails = 0;
static int g_passes = 0;

#define EXPECT(cond, msg) do { \
    if (cond) { g_passes++; } \
    else { g_fails++; printf("  FAIL: %s\n", msg); } \
} while (0)

static void test_daypart(void) {
    printf("test_daypart\n");
    time_t base = 1717200000;  /* 2024-06-01 00:00:00 UTC (Saturday) */
    struct tm tmv;
    localtime_r(&base, &tmv);
    int tz_offset = tmv.tm_gmtoff;
    (void)tz_offset;

    /* We test by setting TZ-independent — build hour-of-day directly */
    for (int h = 0; h < 24; h++) {
        time_t t = base + h * 3600;
        int dp = asb_smart_daypart_now(t);
        int expected;
        struct tm lt;
        localtime_r(&t, &lt);
        int lh = lt.tm_hour;
        if      (lh <  6) expected = ASB_DAYPART_SLEEP;
        else if (lh <  9) expected = ASB_DAYPART_WAKE;
        else if (lh < 12) expected = ASB_DAYPART_MORN;
        else if (lh < 17) expected = ASB_DAYPART_DAY;
        else if (lh < 21) expected = ASB_DAYPART_EVE;
        else              expected = ASB_DAYPART_LATE;
        char buf[64];
        snprintf(buf, sizeof(buf), "daypart at h=%d → %d (expected %d)", lh, dp, expected);
        EXPECT(dp == expected, buf);
    }
}

static void test_bucket_id(void) {
    printf("test_bucket_id\n");
    EXPECT(asb_smart_bucket_id(ASB_DAYPART_SLEEP, 0) == 0,  "sleep weekday=0");
    EXPECT(asb_smart_bucket_id(ASB_DAYPART_SLEEP, 1) == 1,  "sleep weekend=1");
    EXPECT(asb_smart_bucket_id(ASB_DAYPART_WAKE,  0) == 2,  "wake weekday=2");
    EXPECT(asb_smart_bucket_id(ASB_DAYPART_MORN,  0) == 4,  "morn weekday=4");
    EXPECT(asb_smart_bucket_id(ASB_DAYPART_DAY,   1) == 7,  "day weekend=7");
    EXPECT(asb_smart_bucket_id(ASB_DAYPART_EVE,   0) == 8,  "eve weekday=8");
    EXPECT(asb_smart_bucket_id(ASB_DAYPART_LATE,  1) == 11, "late weekend=11");
    EXPECT(asb_smart_bucket_id(-1, 0) == 6, "invalid daypart fallback DAY*2+0=6");
    EXPECT(asb_smart_bucket_id(ASB_DAYPART_DAY, 99) == 6, "invalid weekend fallback to 0 → bucket 6");
}

static void test_pkg_hash(void) {
    printf("test_pkg_hash\n");
    EXPECT(asb_smart_pkg_hash64(NULL) == 0, "null pkg → 0");
    EXPECT(asb_smart_pkg_hash64("") == 0,   "empty pkg → 0");
    uint64_t h1 = asb_smart_pkg_hash64("com.activision.callofduty.shooter");
    uint64_t h2 = asb_smart_pkg_hash64("com.activision.callofduty.shooter");
    EXPECT(h1 == h2, "same input → same hash");
    uint64_t h3 = asb_smart_pkg_hash64("com.whatsapp");
    EXPECT(h1 != h3, "different inputs → different hashes");
    uint64_t h4 = asb_smart_pkg_hash64("com.activision.callofduty.shooterX");
    EXPECT(h1 != h4, "one char diff → different hash");
    /* Stability fingerprint */
    char hex[32];
    asb_smart_app_hash_to_hex(h1, hex, sizeof(hex));
    printf("    cod hash hex: %s\n", hex);
    EXPECT(strlen(hex) == 16, "hex hash 16 chars");
}

static void test_app_hint(void) {
    printf("test_app_hint\n");
    EXPECT(asb_smart_app_hint_from_pkg("com.activision.callofduty.shooter") == ASB_APP_GAMING, "COD → gaming");
    EXPECT(asb_smart_app_hint_from_pkg("com.miHoYo.GenshinImpact") == ASB_APP_GAMING, "Genshin → gaming");
    EXPECT(asb_smart_app_hint_from_pkg("com.whatsapp") == ASB_APP_LIGHT, "whatsapp → light");
    EXPECT(asb_smart_app_hint_from_pkg("org.telegram.messenger") == ASB_APP_LIGHT, "telegram → light");
    EXPECT(asb_smart_app_hint_from_pkg("com.google.android.youtube") == ASB_APP_MEDIUM, "YT → medium");
    EXPECT(asb_smart_app_hint_from_pkg("com.adobe.lrmobile") == ASB_APP_HEAVY, "lightroom → heavy");
    EXPECT(asb_smart_app_hint_from_pkg("com.unknown.app.xyz") == ASB_APP_MEDIUM, "unknown → medium");
    EXPECT(asb_smart_app_hint_from_pkg("") == ASB_APP_IDLE, "empty → idle");
    EXPECT(asb_smart_app_hint_from_pkg(NULL) == ASB_APP_IDLE, "null → idle");
}

static void test_store_seed_validate(void) {
    printf("test_store_seed_validate\n");
    asb_smart_store_t s;
    asb_smart_store_seed_defaults(&s);
    EXPECT(s.magic == ASB_SMART_MAGIC, "seeded magic correct");
    EXPECT(s.version == ASB_SMART_VER, "seeded version correct");
    EXPECT(s.bucket_count == ASB_SMART_BUCKETS, "seeded bucket count correct");
    EXPECT(asb_smart_store_validate(&s) == 0, "seeded store validates");

    /* Check bucket IDs assigned correctly */
    for (int i = 0; i < ASB_SMART_BUCKETS; i++) {
        char buf[64];
        snprintf(buf, sizeof(buf), "bucket[%d].bucket_id == %d", i, i);
        EXPECT(s.buckets[i].bucket_id == (uint32_t)i, buf);
    }

    /* Sleep bucket should have aggressive battery bias */
    int sleep_wd_bid = asb_smart_bucket_id(ASB_DAYPART_SLEEP, 0);
    EXPECT(s.buckets[sleep_wd_bid].alpha_battery_x1000 >= 800,
           "sleep bucket aggressive battery bias");

    /* Day bucket should be balanced-leaning */
    int day_wd_bid = asb_smart_bucket_id(ASB_DAYPART_DAY, 0);
    EXPECT(s.buckets[day_wd_bid].alpha_battery_x1000 <= 500,
           "day bucket balanced-leaning");

    /* Corrupt and verify validate fails */
    s.magic = 0xdeadbeef;
    EXPECT(asb_smart_store_validate(&s) != 0, "bad magic → invalid");

    asb_smart_store_seed_defaults(&s);
    s.buckets[0].alpha_battery_x1000 = 9999;  /* out of range */
    EXPECT(asb_smart_store_validate(&s) != 0, "out-of-range alpha → invalid");

    asb_smart_store_seed_defaults(&s);
    s.buckets[5].interactive_bonus_x1000 = -50;  /* below min */
    EXPECT(asb_smart_store_validate(&s) != 0, "negative interactive_bonus → invalid");

    /* Smart V5 (fix185): a V4 store keeps what it learned, an older one is reset as before. */
    EXPECT(ASB_SMART_VER == 5, "Smart engine is V5");
    asb_smart_store_seed_defaults(&s);
    s.version = 4; s.buckets[3].alpha_battery_x1000 = 731; s.buckets[3].sleep_bias_x1000 = 222;
    EXPECT(asb_smart_store_validate(&s) == 0, "a V4 store validates");
    asb_smart_store_migrate(&s);
    EXPECT(s.version == ASB_SMART_VER, "V4 -> V5");
    EXPECT(s.buckets[3].alpha_battery_x1000 == 731 && s.buckets[3].sleep_bias_x1000 == 222,
           "V4 -> V5 keeps the learned outputs");
    asb_smart_store_seed_defaults(&s);
    s.version = 3; s.buckets[3].alpha_battery_x1000 = 731;
    asb_smart_store_migrate(&s);
    EXPECT(s.version == ASB_SMART_VER && s.buckets[3].alpha_battery_x1000 == 500,
           "V3 -> V5 still resets the outputs");
}

static void test_clamps(void) {
    printf("test_clamps\n");
    EXPECT(asb_clamp_int(5, 0, 10) == 5, "in-range no change");
    EXPECT(asb_clamp_int(-3, 0, 10) == 0, "below clamps to lo");
    EXPECT(asb_clamp_int(99, 0, 10) == 10, "above clamps to hi");
    EXPECT(asb_clamp_u16(150, 0, 100) == 100, "u16 clamp");
    EXPECT(asb_clamp_i16(-300, -200, 200) == -200, "i16 clamp neg");
    EXPECT(asb_clamp_i16(300, -200, 200) == 200, "i16 clamp pos");
}

static void test_persistence_roundtrip(void) {
    printf("test_persistence_roundtrip\n");
    const char *tmpfile = "/tmp/asb_smart_test_store.bin";
    asb_smart_store_t s1, s2;

    asb_smart_store_seed_defaults(&s1);
    /* Modify one bucket so we can detect roundtrip */
    s1.buckets[3].alpha_battery_x1000 = 432;
    s1.buckets[3].interactive_bonus_x1000 = 88;
    s1.buckets[7].sleep_bias_x1000 = 555;

    int rc = asb_smart_store_save_atomic(&s1, tmpfile);
    EXPECT(rc == 0, "save_atomic succeeded");

    memset(&s2, 0xff, sizeof(s2));
    int rl = asb_smart_store_load_from(tmpfile, &s2);
    EXPECT(rl == 0, "load_from succeeded");

    EXPECT(memcmp(&s1, &s2, sizeof(s1)) == 0, "roundtrip byte-exact");
    EXPECT(s2.buckets[3].alpha_battery_x1000 == 432, "alpha preserved");
    EXPECT(s2.buckets[3].interactive_bonus_x1000 == 88, "interactive preserved");
    EXPECT(s2.buckets[7].sleep_bias_x1000 == 555, "sleep_bias preserved");

    unlink(tmpfile);
}

int main(void) {
    printf("=== Session unit tests ===\n\n");

    test_daypart();
    test_bucket_id();
    test_pkg_hash();
    test_app_hint();
    test_store_seed_validate();
    test_clamps();
    test_persistence_roundtrip();

    printf("\n=== Summary ===\n");
    printf("  passed: %d\n", g_passes);
    printf("  failed: %d\n", g_fails);
    return g_fails == 0 ? 0 : 1;
}
ASB_C_EOF
}

_c_smart_session3() {
  cat <<'ASB_C_EOF'
/* tests/test_smart_session3.c — Session unit tests
 * Covers: weights, decay, confidence, fallback hierarchy, blend math,
 *         night override, thermal veto, bucket learning, slot gating. */

#ifndef _GNU_SOURCE   /* the build script passes -D_GNU_SOURCE as well */
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "asb_smart.h"

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
    asb_smart_compute_effective(&b, 100, NULL, &rt);  /* below low threshold */
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
    asb_smart_compute_effective(&b, 500, NULL, &rt);
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
    asb_smart_compute_effective(&b, 1000, NULL, &rt);
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
    asb_runtime_config_t cfg;
    asb_config_defaults(&cfg);
    asb_smart_runtime_t rt = {0};
    rt.alpha_battery_x1000 = 300;
    rt.conf_x1000 = 800;
    rt.interactive_bonus_x1000 = 100;

    /* CPU hot triggers veto (junction fallback: no usable skin reading) */
    asb_smart_apply_thermal_veto(70, 0, &cfg, 100, 0, &rt);
    EXPECT(rt.thermal_veto == 1, "CPU 70°C → veto");
    EXPECT(rt.alpha_battery_x1000 >= 700, "veto raises alpha to ≥ 700");
    EXPECT(rt.conf_x1000 < 800, "veto downscales confidence");
    EXPECT(rt.interactive_bonus_x1000 <= 50, "veto halves interactive");

    /* Vendor clamping triggers the veto only when the phone is at least warm.
     *
     * Routine OEM clamping on a cool phone is policy, not heat: with an honest rolling
     * count it runs ~330/h at 42 C on the reference device and would otherwise hold the
     * veto on all day. The two cases below pin both sides of that line. No skin sensor
     * here (skin=0), so the band is the die fallback: 50 C. */
    asb_smart_runtime_t rt2 = {0};
    rt2.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_veto(40, 0, &cfg, 400, 0, &rt2);
    EXPECT(rt2.thermal_veto == 0, "vendor_clamp_1h=400 at 40 C → no veto (cool, OEM policy)");
    asb_smart_runtime_t rt2w = {0};
    rt2w.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_veto(55, 0, &cfg, 400, 0, &rt2w);
    EXPECT(rt2w.thermal_veto == 1, "vendor_clamp_1h=400 at 55 C → veto (vendor fighting heat)");
    EXPECT(rt2w.thermal_veto_reason == 4, "reason names vendor clamps");

    /* Recovery active triggers veto */
    asb_smart_runtime_t rt3 = {0};
    rt3.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_veto(40, 0, &cfg, 50, 1, &rt3);
    EXPECT(rt3.thermal_veto == 1, "recovery → veto");

    /* Cool, no clamping, no recovery → no veto */
    asb_smart_runtime_t rt4 = {0};
    rt4.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_veto(45, 0, &cfg, 100, 0, &rt4);
    EXPECT(rt4.thermal_veto == 0, "cool device → no veto");
    EXPECT(rt4.alpha_battery_x1000 == 300, "alpha untouched without veto");

    /* Skin-primary path: hot junction but cool skin must NOT veto */
    asb_smart_runtime_t rt5 = {0};
    rt5.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_veto(70, 40, &cfg, 0, 0, &rt5);
    EXPECT(rt5.thermal_veto == 0, "junction 70°C but skin 40°C → no veto (skin-primary)");

    /* Skin-primary path: hot skin vetoes even with cool junction */
    asb_smart_runtime_t rt6 = {0};
    rt6.alpha_battery_x1000 = 300;
    asb_smart_apply_thermal_veto(40, 50, &cfg, 0, 0, &rt6);
    EXPECT(rt6.thermal_veto == 1, "skin 50°C ≥ 47 → veto (cool junction)");
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

static void test_bucket_learn_relative_thresholds(void) {
    printf("test_bucket_learn_relative_thresholds\n");
    /* fix209: the hot/cool verdicts are offsets from THIS device's learned median.
     * A cool-running device (median 38 C) must treat 64 C as hot (64 >= 38+25), while the
     * same absolute session on a warm-silicon device (median 52 C) is ordinary and must
     * not teach a battery lean. The reference phone (median ~45 C) reproduces the old
     * absolutes exactly: hot at 70, very hot at 80, clean-cool below 55. */
    asb_smart_session_input_t s = {0};
    s.dur_s = 1800;
    s.trust = ASB_TRUST_CLEAN;
    s.max_temp_c = 64;
    s.drain_on_sec = 0;    /* no drain feedback: the temperature verdict alone moves alpha */

    asb_smart_bucket_t cool_dev = {0}; cool_dev.alpha_battery_x1000 = 500;
    asb_smart_bucket_update_from_session_ex(&cool_dev, &s, time(NULL), 38);
    EXPECT(cool_dev.alpha_battery_x1000 > 500,
           "64C on a median-38C device teaches a battery lean");

    asb_smart_bucket_t warm_dev = {0}; warm_dev.alpha_battery_x1000 = 500;
    asb_smart_bucket_update_from_session_ex(&warm_dev, &s, time(NULL), 52);
    EXPECT(warm_dev.alpha_battery_x1000 == 500,
           "64C on a median-52C device is its ordinary day: no lean");

    asb_smart_bucket_t ref_dev = {0}; ref_dev.alpha_battery_x1000 = 500;
    s.max_temp_c = 69;
    asb_smart_bucket_update_from_session_ex(&ref_dev, &s, time(NULL), 45);
    EXPECT(ref_dev.alpha_battery_x1000 == 500,
           "69C at the reference median 45C stays below the old absolute 70");
    s.max_temp_c = 70;
    asb_smart_bucket_update_from_session_ex(&ref_dev, &s, time(NULL), 45);
    EXPECT(ref_dev.alpha_battery_x1000 > 500,
           "70C at the reference median 45C reproduces the old absolute hot");

    /* No median: the absolutes apply, exactly as before fix209. */
    asb_smart_bucket_t no_med = {0}; no_med.alpha_battery_x1000 = 500;
    s.max_temp_c = 64;
    asb_smart_bucket_update_from_session_ex(&no_med, &s, time(NULL), 0);
    EXPECT(no_med.alpha_battery_x1000 == 500, "without a median 64C is not hot");
    s.max_temp_c = 72;
    asb_smart_bucket_update_from_session_ex(&no_med, &s, time(NULL), 0);
    EXPECT(no_med.alpha_battery_x1000 > 500, "without a median 72C is hot");

    /* The old wrapper passes no median: identical to the pre-fix209 behaviour. */
    asb_smart_bucket_t wrap = {0}; wrap.alpha_battery_x1000 = 500;
    s.max_temp_c = 64;
    asb_smart_bucket_update_from_session(&wrap, &s, time(NULL));
    EXPECT(wrap.alpha_battery_x1000 == 500, "the wrapper keeps the absolute thresholds");
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

    int r = asb_smart_session_quality_ex(40, 1, 40, 0, 0, 3, 0, &q);
    EXPECT(r == 100, "all clean incl vendor \u2192 100");
    EXPECT(q.q_battery == 100 && q.q_heat == 100 && q.q_stability == 100 &&
           q.q_vendor == 100, "breakdown all 100");
    EXPECT(q.primary_failure == ASB_QFAIL_NONE, "no failure");

    r = asb_smart_session_quality_ex(40, 1, 40, 0, 0, 60, 0, &q);
    EXPECT(r == 85, "vendor war floor \u2192 85");
    EXPECT(q.q_vendor == 0, "60 clamps/h \u2192 vendor 0");
    EXPECT(q.primary_failure == ASB_QFAIL_VENDOR_WAR, "primary failure = vendor war");

    r = asb_smart_session_quality_ex(40, 1, 40, 0, 0, 33, 0, &q);
    EXPECT(q.q_vendor == 49, "33 clamps/h \u2192 vendor 49");
    EXPECT(r == 92, "mid vendor war \u2192 92");

    r = asb_smart_session_quality_ex(0, 0, 60, 0, 0, 10, 0, &q);
    EXPECT(r == 75, "no drain data + vendor \u2192 75");
    EXPECT(q.q_battery == -1, "no drain \u2192 bat -1");
    EXPECT(q.primary_failure == ASB_QFAIL_HEAT, "heat is worst \u2192 heat failure");

    r = asb_smart_session_quality_ex(60, 1, 50, 0, 0, -1, 0, &q);
    EXPECT(r == 92, "no vendor data \u2192 legacy weights");
    EXPECT(q.q_vendor == -1, "no vendor data \u2192 vendor -1");
    EXPECT(q.primary_failure == ASB_QFAIL_NONE, "all >=70 \u2192 no failure");

    r = asb_smart_session_quality_ex(250, 1, 40, 0, 0, 3, 0, &q);
    EXPECT(q.primary_failure == ASB_QFAIL_BATTERY, "drain worst \u2192 battery failure");

    /* Gaming: heavy drain + hot + moderate vendor clamps. Battery/heat are the
       honest failure; vendor's low score must not hijack primary_failure. */
    r = asb_smart_session_quality_ex(240, 1, 60, 1, 0, 44, 0, &q);
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

/* fix185: a session whose drain the climate or the charger explains teaches nothing about
 * drain - in either direction - while heat still teaches. */
static void test_bucket_learn_climate(void) {
    printf("test_bucket_learn_climate\n");
    asb_smart_bucket_t b = {0}, c = {0};
    b.alpha_battery_x1000 = 500; b.avg_drain_pctph_x10 = 100;
    c = b;
    asb_smart_session_input_t s = {0};
    s.dur_s = 1800; s.max_temp_c = 60; s.drain_pctph_x10 = 400; s.drain_on_sec = 1800;
    s.trust = ASB_TRUST_NOISY;
    asb_smart_bucket_update_from_session(&b, &s, time(NULL));
    EXPECT(b.alpha_battery_x1000 > 500, "a dear session in normal weather leans to battery");
    s.climate = 1;
    asb_smart_bucket_update_from_session(&c, &s, time(NULL));
    EXPECT(c.alpha_battery_x1000 == 500, "a dear session in the cold teaches nothing");
    EXPECT(c.avg_drain_pctph_x10 == 100, "and does not move the drain average");
    /* Cheap because the pack came in warm / off the charger: no credit either. */
    asb_smart_bucket_t d = {0};
    d.alpha_battery_x1000 = 500; d.avg_drain_pctph_x10 = 300;
    asb_smart_session_input_t w = {0};
    w.dur_s = 1800; w.max_temp_c = 60; w.drain_pctph_x10 = 50; w.drain_on_sec = 1800;
    w.trust = ASB_TRUST_CLEAN; w.climate = 1;
    asb_smart_bucket_update_from_session(&d, &w, time(NULL));
    EXPECT(d.alpha_battery_x1000 == 500, "a cheap session the room explains takes no credit");
    /* Heat still counts. */
    asb_smart_bucket_t h = {0};
    h.alpha_battery_x1000 = 500;
    asb_smart_session_input_t hs = {0};
    hs.dur_s = 1800; hs.max_temp_c = 82; hs.trust = ASB_TRUST_NOISY; hs.climate = 1;
    asb_smart_bucket_update_from_session(&h, &hs, time(NULL));
    EXPECT(h.alpha_battery_x1000 > 500, "heat still teaches with the climate flag set");
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

    /* The lean moved with nothing else changing - the screen-off floor (850) lifting when
     * the screen comes back - must re-blend, or the phone keeps Battery rails while used. */
    rt.alpha_battery_x1000 = 850;
    rt.interactive_bonus_x1000 = 20;
    asb_smart_mark_slot_updated(&rt, 1040, 1, ASB_APP_HEAVY);
    rt.alpha_battery_x1000 = 620;
    EXPECT(asb_smart_should_update_slot(&rt, 1050, 1, ASB_APP_HEAVY) == 1, "alpha dropped after wake → update");
    asb_smart_mark_slot_updated(&rt, 1050, 1, ASB_APP_HEAVY);
    rt.alpha_battery_x1000 = 650;
    EXPECT(asb_smart_should_update_slot(&rt, 1060, 1, ASB_APP_HEAVY) == 0, "small alpha wobble → no update");
    rt.interactive_bonus_x1000 = 98;
    EXPECT(asb_smart_should_update_slot(&rt, 1070, 1, ASB_APP_HEAVY) == 1, "interactive bonus restored → update");
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
    test_bucket_learn_relative_thresholds();
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
    test_bucket_learn_climate();
    test_bucket_learn_clamping();
    test_bucket_learn_sleep_quality();

    test_slot_update_gating();
    test_daypart_smoothing_factor();

    printf("\n=== Summary ===\n");
    printf("  passed: %d\n", g_passes);
    printf("  failed: %d\n", g_fails);
    return g_fails == 0 ? 0 : 1;
}
ASB_C_EOF
}

_c_thermal_socd_validation() {
  cat <<'ASB_C_EOF'
/* P0 thermal source selection fixture.
 *
 * This includes the production selector directly and overrides only THERMAL_BASE before
 * that include. The fixture consequently exercises thermal_discover() and
 * metrics_read_thermal(), rather than a look-alike threshold implementation. No Android
 * runtime node is written: all synthetic zones live below /tmp and are removed on exit.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define THERMAL_BASE "/tmp/asb_p0_thermal_fixture"
#include "asb_metrics.h"

/* asb_metrics.h references this governor-owned config from other static helpers. */
asb_runtime_config_t g_asb_cfg;

static int g_failures;

static void check_i(const char *name, int got, int want) {
    if (got != want) {
        printf("  FAIL %-48s got=%d want=%d\n", name, got, want);
        g_failures++;
    } else {
        printf("  ok   %-48s %d\n", name, got);
    }
}

static void check_s(const char *name, const char *got, const char *want) {
    if (strcmp(got, want) != 0) {
        printf("  FAIL %-48s got=%s want=%s\n", name, got, want);
        g_failures++;
    } else {
        printf("  ok   %-48s %s\n", name, got);
    }
}

static void ensure_dir(const char *path) {
    if (mkdir(path, 0700) != 0 && errno != EEXIST) {
        perror(path);
        exit(2);
    }
}

static void write_text(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (!f) {
        perror(path);
        exit(2);
    }
    fputs(text, f);
    fclose(f);
}

static void fixture_reset(void) {
    char path[256];
    for (int z = 0; z < THERMAL_MAX_ZONES; z++) {
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/type", z);
        unlink(path);
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/temp", z);
        unlink(path);
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d", z);
        rmdir(path);
    }
    rmdir(THERMAL_BASE);
    ensure_dir(THERMAL_BASE);

    g_thermal_source_confidence = 0;
    g_thermal_cpu_zone = -1;
    g_thermal_skin_zone = -1;
    g_thermal_surface_zone = -1;
    g_thermal_board_zone = -1;
    g_thermal_cpu_fallback_zone = -1;
    g_thermal_cpu_fallback_type[0] = '\0';
    g_thermal_cpu_type[0] = '\0';
    g_thermal_cpu_reason[0] = '\0';
    g_thermal_rejected_type[0] = '\0';
    g_thermal_rejected_raw = 0;
    g_last_thermal_rescan = 0;
}

static void add_zone(int zone, const char *type, int raw) {
    /* path holds dir plus "/type": sized for it, or gcc warns that it may truncate. */
    char dir[256], path[272], raw_text[32];
    snprintf(dir, sizeof(dir), THERMAL_BASE "/thermal_zone%d", zone);
    ensure_dir(dir);
    snprintf(path, sizeof(path), "%s/type", dir);
    write_text(path, type);
    snprintf(raw_text, sizeof(raw_text), "%d\n", raw);
    snprintf(path, sizeof(path), "%s/temp", dir);
    write_text(path, raw_text);
}

static void write_temp(int zone, int raw) {
    char path[256], raw_text[32];
    snprintf(raw_text, sizeof(raw_text), "%d\n", raw);
    snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/temp", zone);
    write_text(path, raw_text);
}

static void add_three_cpu_peers(int a, int b, int c) {
    add_zone(1, "cpu-1-1-0\n", a);
    add_zone(2, "cpu-0-5-0\n", b);
    add_zone(3, "cpullc-0-0\n", c);
}

static void case_high_socd_rebinds_to_live_peer(void) {
    fixture_reset();
    add_zone(0, "socd\n", 70000);
    add_three_cpu_peers(35000, 36000, 39000);
    thermal_discover();

    check_i("high socd selects real fallback zone", g_thermal_cpu_zone, 1);
    check_s("high socd selects prime peer type", g_thermal_cpu_type, "cpu-1-1-0");
    check_i("high socd confidence is fallback", g_thermal_source_confidence, 1);
    check_s("high socd rejection provenance", g_thermal_rejected_type, "socd");
    check_i("high socd retains raw evidence", g_thermal_rejected_raw, 70000);
    check_i("selected fallback clears runtime fallback zone", g_thermal_cpu_fallback_zone, -1);
}

static void case_valid_socd_is_retained(void) {
    fixture_reset();
    add_zone(0, "socd\n", 58000);
    add_three_cpu_peers(53000, 54000, 56000);
    thermal_discover();

    check_i("valid socd remains control zone", g_thermal_cpu_zone, 0);
    check_s("valid socd remains source", g_thermal_cpu_type, "socd");
    check_i("valid socd is peer-validated", g_thermal_source_confidence, 2);
    check_s("valid socd has no rejection", g_thermal_rejected_type, "");
}

static void case_low_socd_rebinds_symmetrically(void) {
    fixture_reset();
    add_zone(0, "socd\n", 24000);
    add_three_cpu_peers(38000, 39000, 40000);
    thermal_discover();

    check_i("low socd selects real fallback zone", g_thermal_cpu_zone, 1);
    check_i("low socd confidence is fallback", g_thermal_source_confidence, 1);
    check_s("low socd rejection provenance", g_thermal_rejected_type, "socd");
    check_i("low socd retains raw evidence", g_thermal_rejected_raw, 24000);
    check_i("low selected fallback clears runtime fallback zone", g_thermal_cpu_fallback_zone, -1);
}

static void case_rejected_socd_without_valid_fallback_stays_conservative(void) {
    fixture_reset();
    add_zone(0, "socd\n", 50000);
    /* These participate in the peer median but are static extremes, so basic validation
     * must not promote any as a usable control fallback. */
    add_three_cpu_peers(93000, 94000, 95000);
    thermal_discover();

    check_i("no-fallback retains socd control source", g_thermal_cpu_zone, 0);
    check_s("no-fallback keeps socd type", g_thermal_cpu_type, "socd");
    check_i("no-fallback is low confidence", g_thermal_source_confidence, 1);
    check_s("no-fallback publishes rejection", g_thermal_rejected_type, "socd");
    check_i("no-fallback has no runtime peer fallback", g_thermal_cpu_fallback_zone, -1);
}

static void case_no_fallback_recovery_revalidates_socd(void) {
    asb_thermal_t t;
    fixture_reset();
    add_zone(0, "socd\n", 50000);
    add_three_cpu_peers(93000, 94000, 95000);
    thermal_discover();
    check_i("recovery setup retains conservative socd", g_thermal_cpu_zone, 0);
    check_i("recovery setup starts low-confidence", g_thermal_source_confidence, 1);

    write_temp(0, 58000);
    write_temp(1, 53000);
    write_temp(2, 54000);
    write_temp(3, 56000);
    g_last_thermal_rescan = time(NULL) - 61;
    metrics_read_thermal(&t, 0);

    check_i("recovery keeps validated socd control zone", g_thermal_cpu_zone, 0);
    check_i("recovery restores peer-validated confidence", g_thermal_source_confidence, 2);
    check_s("recovery clears stale rejected type", g_thermal_rejected_type, "");
    check_i("recovery clears stale rejected raw", g_thermal_rejected_raw, 0);
    check_i("recovery reports current socd temp", t.cpu_max_c, 58);
}

static void case_non_cpu_peer_never_replaces_cpu_control(void) {
    asb_thermal_t t;
    fixture_reset();
    add_zone(0, "socd\n", 40000);
    add_three_cpu_peers(39000, 40000, 41000);
    add_zone(4, "shell_frame\n", 70000);
    add_zone(5, "sys-therm-6\n", 69000);
    add_zone(6, "board_temp\n", 71000);
    thermal_discover();
    metrics_read_thermal(&t, 0);

    check_i("non-CPU peer leaves CPU control temperature intact", t.cpu_max_c, 40);
    check_i("non-CPU peer captures current board temperature", t.board_temp_c, 71);
    check_i("non-CPU peer consensus has current peers", g_thermal_peer_n, 3);
    check_i("non-CPU peer consensus records hottest evidence", g_thermal_peer_hi, 71);
}

static void case_consensus_clears_when_peers_disappear(void) {
    asb_thermal_t t;
    char path[256];
    fixture_reset();
    add_zone(0, "socd\n", 45000);
    add_three_cpu_peers(44000, 45000, 46000);
    add_zone(4, "shell_frame\n", 42000);
    add_zone(5, "sys-therm-6\n", 43000);
    add_zone(6, "board_temp\n", 44000);
    thermal_discover();
    metrics_read_thermal(&t, 0);
    check_i("consensus setup has peer evidence", g_thermal_peer_n, 3);

    for (int z = 4; z <= 6; z++) {
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/temp", z);
        unlink(path);
    }
    metrics_read_thermal(&t, 0);
    check_i("missing peer sensors clear consensus count", g_thermal_peer_n, 0);
    check_i("missing peer sensors clear consensus high", g_thermal_peer_hi, 0);
    check_i("missing peer sensors clear consensus low", g_thermal_peer_lo, 0);
    check_s("missing peer sensors clear consensus note", g_thermal_consensus_note, "");
}

static void case_periodic_socd_revalidation_recovers(void) {
    asb_thermal_t t;
    fixture_reset();
    add_zone(0, "socd\n", 58000);
    add_three_cpu_peers(53000, 54000, 56000);
    thermal_discover();
    check_i("revalidation setup starts on valid socd", g_thermal_cpu_zone, 0);

    write_temp(0, 70000);
    write_temp(1, 35000);
    write_temp(2, 36000);
    write_temp(3, 39000);
    g_last_thermal_rescan = time(NULL) - 61;
    metrics_read_thermal(&t, 0);

    check_i("periodic rescan rebinds divergent socd", g_thermal_cpu_zone, 1);
    check_i("periodic rescan stays fallback confidence", g_thermal_source_confidence, 1);
    check_s("periodic rescan publishes rejection", g_thermal_rejected_type, "socd");
    check_i("periodic rescan reports live fallback temp", t.cpu_max_c, 35);
}

/* Field shape: socd reads a percentage (22-27 raw) while the cores report millidegrees.
 * On a cold boot the cores sit near 30 C, so "25 C" was inside the agreement band and the
 * percentage became the control temperature. Scale alone must reject it, and the CPU
 * fallback that agrees with its peers must not be left at confidence 1 for it. */
static void case_percentage_socd_rejected_on_scale(void) {
    fixture_reset();
    add_zone(0, "socd\n", 25);
    add_three_cpu_peers(29000, 30000, 31000);
    thermal_discover();

    check_i("percent socd: control moves to a core zone", g_thermal_cpu_zone, 1);
    check_s("percent socd: core zone type", g_thermal_cpu_type, "cpu-1-1-0");
    check_s("percent socd: rejection recorded", g_thermal_rejected_type, "socd");
    check_i("percent socd: raw evidence kept", g_thermal_rejected_raw, 25);
    check_i("percent socd: agreeing core fallback is full confidence", g_thermal_source_confidence, 2);
}

/* The promotion needs agreement: a fallback far from its peers stays doubtful. */
static void case_percentage_socd_disputed_fallback_stays_low(void) {
    fixture_reset();
    add_zone(0, "socd\n", 25);
    add_three_cpu_peers(60000, 40000, 41000);
    thermal_discover();

    check_s("disputed fallback: still a core zone", g_thermal_cpu_type, "cpu-1-1-0");
    check_i("disputed fallback: confidence stays 1", g_thermal_source_confidence, 1);
}

/* fix129: a fallback that disagreed at boot earns full confidence once the cores agree. */
static void case_disputed_fallback_promoted_at_runtime(void) {
    asb_thermal_t t;
    fixture_reset();
    add_zone(0, "socd\n", 25);
    add_three_cpu_peers(56000, 40000, 41000);
    thermal_discover();
    check_i("boot dispute: confidence 1 at discovery", g_thermal_source_confidence, 1);
    g_thermal_conf_recheck_ts = 0;
    metrics_read_thermal(&t, 0);
    check_i("still hot: re-check keeps confidence 1", g_thermal_source_confidence, 1);
    write_temp(1, 43000);
    g_thermal_conf_recheck_ts = 0;
    metrics_read_thermal(&t, 0);
    check_i("cores agree later: promoted to 2", g_thermal_source_confidence, 2);
    check_i("promotion counted", (int)g_thermal_conf_promotions, 1);
    /* A socd that reads like a real temperature is a genuine dispute: no promotion. */
    fixture_reset();
    add_zone(0, "socd\n", 70000);
    add_three_cpu_peers(41000, 40000, 41000);
    thermal_discover();
    int conf0 = g_thermal_source_confidence;
    g_thermal_conf_recheck_ts = 0;
    metrics_read_thermal(&t, 0);
    check_i("real-temperature socd dispute: no runtime promotion", g_thermal_source_confidence, conf0);
}

/* fix123: a Dimensity kernel names its sensors cpu_big0 / cpu_little0 / soc_max. None of
 * them matched, so an MTK OnePlus ran with no CPU thermal source at all. */
static void case_mediatek_lvts_names(void) {
    asb_thermal_t t;
    fixture_reset();
    add_zone(0, "soc_max\n", 52000);
    add_zone(1, "cpu_little0\n", 45000);
    add_zone(2, "cpu_big0\n", 50000);
    add_zone(3, "cpu_big1\n", 51000);
    add_zone(4, "gpu0\n", 60000);
    add_zone(5, "ap_ntc\n", 38000);
    thermal_discover();
    metrics_read_thermal(&t, 0);

    check_s("mtk: hottest big-core sensor is the control source", g_thermal_cpu_type, "cpu_big1");
    check_i("mtk: control zone", g_thermal_cpu_zone, 3);
    check_i("mtk: full confidence (nothing rejected)", g_thermal_source_confidence, 2);
    check_i("mtk: temperature is valid", t.temp_valid, 1);
    check_i("mtk: control temperature", t.cpu_max_c, 51);
    check_i("mtk: AP board thermistor is the surface fallback", g_thermal_surface_zone, 5);
}

static void case_mediatek_helio_single_zone(void) {
    fixture_reset();
    add_zone(0, "mtktsAP\n", 40000);
    add_zone(1, "mtktscpu\n", 47000);
    add_zone(2, "mtktsbattery\n", 33000);
    thermal_discover();

    check_s("helio: mtktscpu is the control source", g_thermal_cpu_type, "mtktscpu");
    check_i("helio: control zone", g_thermal_cpu_zone, 1);
}

/* A Snapdragon table with an MTK-looking name in it keeps its own sensor. */
static void case_qualcomm_keeps_priority(void) {
    fixture_reset();
    add_three_cpu_peers(44000, 45000, 46000);
    add_zone(4, "cpu_therm\n", 70000);
    thermal_discover();

    check_s("qcom: prime sensor still wins over a generic cpu_ zone", g_thermal_cpu_type, "cpu-1-1-0");
}

int main(void) {
    puts("P0 thermal socd validation fixtures");
    case_high_socd_rebinds_to_live_peer();
    case_valid_socd_is_retained();
    case_low_socd_rebinds_symmetrically();
    case_rejected_socd_without_valid_fallback_stays_conservative();
    case_no_fallback_recovery_revalidates_socd();
    case_non_cpu_peer_never_replaces_cpu_control();
    case_consensus_clears_when_peers_disappear();
    case_periodic_socd_revalidation_recovers();
    case_percentage_socd_rejected_on_scale();
    case_percentage_socd_disputed_fallback_stays_low();
    case_disputed_fallback_promoted_at_runtime();
    case_mediatek_lvts_names();
    case_mediatek_helio_single_zone();
    case_qualcomm_keeps_priority();

    fixture_reset();
    if (g_failures) {
        printf("failed: %d\n", g_failures);
        return 1;
    }
    puts("passed: thermal socd P0 fixture suite");
    return 0;
}
ASB_C_EOF
}

_c_v64_regression_contract() {
  cat <<'ASB_C_EOF'
/*
 * Guards for the defects fixed in V64.
 *
 * Each case here cost a round of field logs to find, and several were introduced by a
 * change that looked like an improvement and passed every existing test. They are cheap
 * to check and expensive to rediscover.
 *
 * Build: gcc -O2 -I src -o /tmp/t tests/test_v64_regression_contract.c -lm
 */

#include <stdio.h>
#include <string.h>
#include <math.h>

#include "asb_config.h"
#include "asb_smart_defs.h"
#include "asb_fsm_bounds.generated.h"

static int failures = 0;

static void check(int ok, const char *what) {
    if (ok) {
        printf("  PASS  %s\n", what);
    } else {
        printf("  FAIL  %s\n", what);
        failures++;
    }
}

/* ------------------------------------------------------------------------------
 * 1. Learner blend direction.
 *
 * blended = (battery*alpha + balanced*(1000-alpha)) / 1000, and the battery bounds are
 * the LOWER ones - so a higher alpha must produce a lower ceiling. The learner shipped
 * with this inverted: warm buckets raised the ceiling, which made the next sample worse
 * and the one after that worse still.
 */
static int blend(int battery, int balanced, int alpha) {
    /* long, mirroring the fix in asb_smart.h: the int product overflows on a wide
     * ladder and wraps the ceiling negative. */
    return (int)(((long)battery * alpha + (long)balanced * (1000 - alpha)) / 1000);
}

static void test_blend_direction(void) {
    const int bat = ASB_BATTERY_CEIL_CPU_MAX_LITTLE;
    const int bal = ASB_BALANCED_CEIL_CPU_MAX_LITTLE;

    int low  = blend(bat, bal, 300);
    int mid  = blend(bat, bal, 500);
    int high = blend(bat, bal, 700);

    check(high < mid && mid < low,
          "higher alpha leans toward battery (lower ceiling)");
}

/* ------------------------------------------------------------------------------
 * 2. Profile bounds stay ordered.
 *
 * floor must be at or below ceil on every profile and cluster. A generator change that
 * swaps them would produce a ladder that cannot be interpolated.
 */
static void test_bounds_ordered(void) {
    struct { const char *name; int floor_l, ceil_l, floor_b, ceil_b; } p[] = {
        { "battery",     ASB_BATTERY_FLOOR_CPU_MAX_LITTLE,     ASB_BATTERY_CEIL_CPU_MAX_LITTLE,
                         ASB_BATTERY_FLOOR_CPU_MAX_BIG,        ASB_BATTERY_CEIL_CPU_MAX_BIG },
        { "balanced",    ASB_BALANCED_FLOOR_CPU_MAX_LITTLE,    ASB_BALANCED_CEIL_CPU_MAX_LITTLE,
                         ASB_BALANCED_FLOOR_CPU_MAX_BIG,       ASB_BALANCED_CEIL_CPU_MAX_BIG },
        { "performance", ASB_PERFORMANCE_FLOOR_CPU_MAX_LITTLE, ASB_PERFORMANCE_CEIL_CPU_MAX_LITTLE,
                         ASB_PERFORMANCE_FLOOR_CPU_MAX_BIG,    ASB_PERFORMANCE_CEIL_CPU_MAX_BIG },
    };
    int ok = 1;
    for (unsigned i = 0; i < sizeof(p)/sizeof(p[0]); i++) {
        if (p[i].floor_l > p[i].ceil_l || p[i].floor_b > p[i].ceil_b) ok = 0;
    }
    check(ok, "every profile has floor <= ceil on both clusters");
}

/* ------------------------------------------------------------------------------
 * 3. perf_ceiling_pct clamp.
 *
 * Below 65 the weighted trim inverts the ladder: GAMING computes lower than HEAVY, so
 * the phone runs SLOWER under load than at rest. The parser must clamp, because the
 * WebUI slider is not the only way a value reaches the config file.
 */
static void test_perf_ceiling_clamp(void) {
    asb_runtime_config_t c;
    asb_config_defaults(&c);

    asb_cfg_apply_kv(&c, "perf_ceiling_pct", "10");
    int lo = c.perf_ceiling_pct;

    asb_cfg_apply_kv(&c, "perf_ceiling_pct", "250");
    int hi = c.perf_ceiling_pct;

    check(lo >= 65 && hi <= 100, "perf_ceiling_pct is clamped to 65..100");
}

/* ------------------------------------------------------------------------------
 * 4. clamp_thermal_every_n is never zero.
 *
 * The governor uses it as a modulus. atoi("0") is 0, and integer division by zero is a
 * crash, not a bad reading - reachable by hand-editing the config or by a truncated file.
 */
static void test_thermal_divisor_clamp(void) {
    asb_runtime_config_t c;
    asb_config_defaults(&c);

    asb_cfg_apply_kv(&c, "clamp_thermal_every_n", "0");
    int zero = c.clamp_thermal_every_n;

    asb_cfg_apply_kv(&c, "clamp_thermal_every_n", "-5");
    int neg = c.clamp_thermal_every_n;

    check(zero >= 1 && neg >= 1, "clamp_thermal_every_n never reaches 0");
}

/* ------------------------------------------------------------------------------
 * 5. Sustained temperature thresholds keep their hysteresis.
 *
 * enter must sit above exit on every profile. A bare threshold with no gap is what made
 * the surface-comfort trim engage 78% of the time on a phone sitting exactly at it.
 */
static void test_temp_hysteresis(void) {
    asb_runtime_config_t c;
    asb_config_defaults(&c);
    check(c.sustained_temp_enter > c.sustained_temp_exit,
          "sustained_temp_enter > sustained_temp_exit");
}

/* ------------------------------------------------------------------------------
 * 6. Thermal budget stages stay ordered.
 *
 * severe < moderate < light, in headroom percent. Reversing them would apply the
 * harshest trim at the coolest point.
 */
static void test_budget_stage_order(void) {
    asb_runtime_config_t c;
    asb_config_defaults(&c);
    check(c.thermal_budget_severe_headroom_pct < c.thermal_budget_moderate_headroom_pct &&
          c.thermal_budget_moderate_headroom_pct < c.thermal_budget_light_headroom_pct,
          "thermal budget stages ordered severe < moderate < light");
}

/* ------------------------------------------------------------------------------
 * 7. ASB_APP_GAMING keeps its value.
 *
 * asb_fsm.h compares against this class to lower the GPU gate for known games, and for a
 * while it had to spell the value as a literal because the enum header is included later.
 * If the enum is renumbered, that comparison silently starts matching the wrong class.
 */
static void test_app_gaming_value(void) {
    check(ASB_APP_GAMING == 4, "ASB_APP_GAMING is still 4 (asb_fsm.h depends on it)");
}

int main(void) {
    printf("V64 regression contract\n");

    test_blend_direction();
    test_bounds_ordered();
    test_perf_ceiling_clamp();
    test_thermal_divisor_clamp();
    test_temp_hysteresis();
    test_budget_stage_order();
    test_app_gaming_value();

    printf("\n  failed: %d\n", failures);
    return failures ? 1 : 0;
}
ASB_C_EOF
}

t_battery_touch_light_idle_runtime() (
# Runtime (fix240): on Battery a finger on the glass leaves LIGHT_IDLE at once.
#
# OP15, ColorOS 17, Battery: the first seconds of a launcher page swipe, the shade, the app
# drawer and every app open/close stuttered, then the phone was smooth. Battery's LIGHT_IDLE
# carries the governor's own GPU ceiling bat_light_idle_gpu=10 - the lowest pwrlevel, 160 MHz
# on SM8850 - and Battery was excluded from the fix117 touch floor and first-touch lift, so a
# swipe that started from a calm screen was drawn at that step until a later tick (2-8 s on
# Battery's doubled up window) left light idle. The unlock lift never touched the GPU, and in
# the field asbdiag 7 of 8 taps were not lifted at all (warm die).
# The REAL governor translation unit is compiled and its FSM driven: a quiet Battery screen
# stays in light idle; a fresh touch moves it to MODERATE in the same update; it holds while
# the touches continue and returns to light idle once they stop; a sampled touch without a
# kick does not wait on the doubled window; Battery's MODERATE GPU ceiling stays inside its
# own 40-44 % envelope while light idle keeps bat_light_idle_gpu; Smart keeps its lift.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL battery touch light idle: $*" >&2; exit 1; }
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "SKIP battery touch light idle: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'X'
#define main asb_governor_main_unused
#include "asb_governor.c"
#undef main
static int bad = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
static asb_metrics_t quiet_screen(void) {
    asb_metrics_t m;
    memset(&m, 0, sizeof(m));
    m.misc.screen_on = 1;
    m.cpu.load1 = 1.0f;
    m.cpu.awake_tick_pct = 100;
    m.gpu.load_pct = 0;
    m.therm.cpu_max_c = 40;
    m.therm.source_confidence = 2;
    m.bat.current_ma = 100;
    return m;
}
static void set_profile(asb_fsm_t *f, int p) {
    fsm_init(f, p);
    fsm_profile_is_battery = (p == PROFILE_BATTERY);
    fsm_profile_is_smart = (p == PROFILE_SMART);
    fsm_profile_is_performance = (p == PROFILE_PERFORMANCE);
    f->state = f->pending = ASB_STATE_LIGHT_IDLE;
    f->pending_ticks = 0;
    clock_gettime(CLOCK_MONOTONIC, &f->last_transition);
    f->last_transition.tv_sec -= 600;
    g_screen_on_since = time(NULL) - 600;
    g_touch_last_ts = 0;
    g_touch_kick = 0;
}
int main(void) {
    asb_config_defaults(&g_asb_cfg);
    asb_fsm_t f;
    asb_metrics_t m = quiet_screen();

    set_profile(&f, PROFILE_BATTERY);
    for (int i = 0; i < 8; i++) fsm_update(&f, &m);
    CHECK(f.state == ASB_STATE_LIGHT_IDLE, "a quiet Battery screen left light idle: %s", asb_state_names[f.state]);

    unsigned long lifts = g_touch_lifts;
    g_touch_last_ts = time(NULL);
    g_touch_kick = 1;
    fsm_update(&f, &m);
    g_touch_kick = 0;
    CHECK(f.state == ASB_STATE_MODERATE, "a fresh touch on Battery stayed in %s", asb_state_names[f.state]);
    CHECK(g_touch_lifts == lifts + 1, "the Battery touch lift was not counted");

    for (int i = 0; i < 4; i++) fsm_update(&f, &m);
    CHECK(f.state == ASB_STATE_MODERATE, "Battery fell to %s while the finger was still on the glass", asb_state_names[f.state]);

    g_touch_last_ts = time(NULL) - 30;
    f.last_transition.tv_sec -= 600;
    for (int i = 0; i < 12; i++) fsm_update(&f, &m);
    CHECK(f.state == ASB_STATE_LIGHT_IDLE, "quiet reading after the touches never returned to light idle: %s", asb_state_names[f.state]);

    g_touch_last_ts = time(NULL);
    g_touch_kick = 0;
    fsm_update(&f, &m);
    CHECK(f.state == ASB_STATE_MODERATE, "a sampled touch without a kick waited on Battery's doubled window: %s", asb_state_names[f.state]);

    asb_profile_caps_t li, mo;
    memset(&li, 0, sizeof(li));
    memset(&mo, 0, sizeof(mo));
    fsm_profile_is_battery = 1;
    fsm_interpolate_caps(&g_profile_bounds[PROFILE_BATTERY], PROFILE_BATTERY, ASB_STATE_LIGHT_IDLE, 0, 0.0f, &li);
    fsm_interpolate_caps(&g_profile_bounds[PROFILE_BATTERY], PROFILE_BATTERY, ASB_STATE_MODERATE, 0, 0.0f, &mo);
    CHECK(li.gpu_max_pct == g_asb_cfg.bat_light_idle_gpu, "Battery light-idle GPU ceiling is %d, not bat_light_idle_gpu", li.gpu_max_pct);
    CHECK(mo.gpu_max_pct >= 40 && mo.gpu_max_pct <= 44, "Battery MODERATE GPU ceiling %d is outside its own 40-44 envelope", mo.gpu_max_pct);
    CHECK(mo.uclamp_top_max <= 50, "Battery MODERATE top-app uclamp %d is above its profile ceiling", mo.uclamp_top_max);

    set_profile(&f, PROFILE_SMART);
    g_touch_last_ts = time(NULL);
    g_touch_kick = 1;
    fsm_update(&f, &m);
    g_touch_kick = 0;
    CHECK(f.state == ASB_STATE_MODERATE, "Smart lost its touch lift: %s", asb_state_names[f.state]);

    if (bad) return 1;
    printf("ok\n");
    return 0;
}
X
"$CC" -std=gnu11 -O0 -w -I"$ROOT/src" -DASB_DEBUG_BUILD=0 -o "$T/t" "$T/t.c" -lm -ldl -lpthread 2>"$T/cc.err" \
  || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS battery touch light idle: a touch leaves Battery's lowest-step GPU light idle at once, holds while touching, quiet reading still idles, Smart unchanged"
)

t_budget_current_scale_runtime() (
# fix85: the thermal-budget mA gates were tuned on OP15 readings (gauge x0.38 of real drain).
# A CPH2769 gauge reads x0.88, so the same workload crossed every gate 2.3x earlier. The
# reading is converted to the reference scale once the phone's own ratio is on record.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL budget current scale: $*" >&2; exit 1; }
# fix121: the comfort gates read the smoothed draw (asb_ma_ref(_cma)); still on the reference scale.
n="$(awk '/^static int asb_adaptive_budget_trim_pct/,/caps->uclamp_bg_max = target;/' "$G" | grep -cE 'asb_ma_ref\((m->bat\.current_ma|_cma)\) >=')"
[ "$n" -ge 6 ] || fail "only $n budget mA gates use the reference scale"
awk '/^static int asb_adaptive_budget_trim_pct/,/caps->uclamp_bg_max = target;/' "$G" | grep -E '(m->bat\.current_ma|_cma) >= [0-9c]' && fail "a budget mA gate still compares raw current"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS budget current scale (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  echo '#include <stdio.h>'
  echo 'static int g_curscale_x100 = -1, g_curscale_n = 0;'
  sed -n '/^#define ASB_CURSCALE_REF_X100/p; /^static int asb_ma_ref(/,/^}$/p' "$G"
  cat <<'X'
int main(void) {
    int bad = 0;
    if (asb_ma_ref(880) != 880) { puts("no ratio yet must be raw"); bad = 1; }
    g_curscale_x100 = 88; g_curscale_n = 3;
    if (asb_ma_ref(880) != 880) { puts("too few windows must be raw"); bad = 1; }
    g_curscale_n = 14;
    if (asb_ma_ref(880) != 380) { printf("CPH2769 880 -> %d, want 380\n", asb_ma_ref(880)); bad = 1; }
    g_curscale_x100 = 38;
    if (asb_ma_ref(450) != 450) { puts("OP15 must be unchanged"); bad = 1; }
    g_curscale_x100 = 900;
    if (asb_ma_ref(450) != 450) { puts("nonsense ratio must be raw"); bad = 1; }
    return bad;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -o "$T/t" "$T/t.c" || fail "fixture did not compile"
"$T/t" || fail "conversion wrong"
echo "PASS budget mA gates use the reference gauge scale"
)

t_cgroup_detach_runtime() (
# Runtime (fix141): watchers the WebUI starts leave the manager app's cgroups.
#
# OP15 capture 2830: the recorder ran all night in "cpuset:/top-app cpu:/top-app memory:/apps"
# and reported cgroup_escape=not_needed. The video-refresh, Wi-Fi fallback and LTE light
# watchers are started from the WebUI the same way when their switch is turned on.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL cgroup detach: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
. "$ROOT/runtime/asb_cgroup.sh"
true > "$T/r1"; true > "$T/r2"
# The capture's own cgroup file, v1 groups of the foreground app, v2 root.
printf '5:freezer:/\n4:memory:/apps\n3:cpuset:/top-app\n2:cpu:/top-app\n1:blkio:/\n0::/\n' > "$T/cg"
out="$(ASB_CG_FILE="$T/cg" ASB_CG_ROOTS="$T/r1 $T/r2 $T/absent" asb_cgroup_detach 777)"
[ "$(cat "$T/r1")" = 777 ] && [ "$(cat "$T/r2")" = 777 ] || fail "pid not written to every writable root"
# The fixture still lists top-app (nothing really moved it): reported as partial, not moved.
[ "$out" = partial:2 ] || fail "top-app left behind reported as '$out'"
printf '0::/uid_10853/pid_4242\n' > "$T/cg"
[ "$(ASB_CG_FILE="$T/cg" ASB_CG_ROOTS="$T/r1" asb_cgroup_detach 778)" = failed ] || fail "still in uid_ not reported as failed"
printf '0::/\n3:cpuset:/\n' > "$T/cg"
[ "$(ASB_CG_FILE="$T/cg" ASB_CG_ROOTS="$T/r1" asb_cgroup_detach 779)" = not_needed ] || fail "a boot-started process moved"
# A move the kernel accepted: the cgroup file no longer names an app group afterwards.
printf '3:cpuset:/top-app\n' > "$T/cg"
[ "$(ASB_CG_FILE="$T/cg" ASB_CG_ROOTS="$T/cg" asb_cgroup_detach 780)" = moved:1 ] || fail "an accepted move not reported"

# The logkit's copy follows the same rule.
out="$( (set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$ROOT/tools/logkit/_asb_logkit_common.sh" >/dev/null 2>&1
         printf '4:memory:/apps\n3:cpuset:/top-app\n0::/\n' > "$T/cg"
         ASB_LK_CG_FILE="$T/cg" ASB_LK_CG_ROOTS="$T/r1" lk_escape_app_cgroup 781) )"
[ "$out" = partial:1 ] || fail "logkit still calls a top-app recorder not_needed ($out)"

# Wiring: every watcher the WebUI can start detaches before it forks.
for f in asb_ltpo_video.sh asb_wifi_fallback.sh asb_lte_screenoff.sh; do
  grep -q 'asb_cgroup_detach \$\$' "$ROOT/runtime/$f" || fail "$f does not leave the app cgroups"
done
[ "$(grep -c 'asb_cgroup_detach \$\$' "$ROOT/runtime/asb_ltpo_video.sh")" -ge 2 ] || fail "video watcher: reconcile and watch both detach"
echo "PASS cgroup detach: WebUI-started watchers and the recorder leave the app's cgroups"
)

t_comfort_current_runtime() (
# Runtime (fix121): the comfort trims read a running mean of the discharge current, updated
# once per metrics sample, restarted on the charger / with the screen off / after a gap, and
# a trim in force has an exit band (80% of the entry current, 2 C below the entry temperature).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL comfort current: $*" >&2; exit 1; }

grep -q 'int _cma = asb_comfort_ma(m);' "$G" || fail "comfort gates do not read the smoothed current"
grep -q 'asb_ma_ref(_cma) >= (_cin ? comfort_current_ma \* 4 / 5 : comfort_current_ma)' "$G" || fail "no exit band on the comfort current"
grep -q 'm->therm.cpu_max_c >= g_asb_cfg.bat_comfort_temp - (_cin ? 2 : 0)' "$G" || fail "no exit band on the comfort temperature"
grep -q '(reason && strncmp(reason, "screenon_comfort", 16) == 0) ? 1 : 0;' "$G" || fail "engaged flag not tracked with the budget reason"
# The spike tie-breaker stays on the raw sample: it exists for spikes.
grep -q 'if (!m->bat.charging && asb_ma_ref(m->bat.current_ma) >= 1800)' "$G" || fail "1800 mA tie-breaker must stay raw"

CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS comfort current (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  cat <<'X'
#include <stdio.h>
#include <time.h>
typedef struct { int charging; int current_ma; } bat_t;
typedef struct { int screen_on; } misc_t;
typedef struct { struct timespec ts; bat_t bat; misc_t misc; } asb_metrics_t;
X
  sed -n '/^static int  g_comfort_ma_ema = 0;/,/^\/\* A warm die, not one hot sample/p' "$G" | sed '$d'
  cat <<'X'
static asb_metrics_t M;
static int feed(long sec, int ma) { M.ts.tv_sec = sec; M.ts.tv_nsec = 0; M.bat.current_ma = ma; return asb_comfort_ma(&M); }
int main(void) {
    int bad = 0, v;
    (void)g_budget_comfort_engaged;
    M.misc.screen_on = 1;
    /* The 24817 sequence, one sample per 6 s tick: the mean stays in one band. */
    int seq[] = { 391, 516, 437, 258, 748, 328, 384, 268, 517, 304 };
    int lo = 100000, hi = 0;
    for (int i = 0; i < 10; i++) { v = feed(100 + 6 * i, seq[i]); if (i >= 3) { if (v < lo) lo = v; if (v > hi) hi = v; } }
    if (hi - lo > 160) { printf("mean swings %d..%d - not smoothed\n", lo, hi); bad = 1; }
    if (lo < 350 * 4 / 5) { printf("mean %d drops out of the exit band on this sequence\n", lo); bad = 1; }
    /* Same sample asked twice: one update. */
    int a = feed(200, 1000); int b = asb_comfort_ma(&M);
    if (a != b) { printf("second caller moved the mean %d -> %d\n", a, b); bad = 1; }
    /* Gap over 30 s: restart from the sample. */
    v = feed(260, 200);
    if (v != 200) { printf("stale mean not restarted: %d\n", v); bad = 1; }
    /* Charger and screen-off restart it too. */
    feed(262, 900); M.bat.charging = 1; feed(264, 900); M.bat.charging = 0;
    v = feed(266, 300);
    if (v != 300) { printf("charging did not restart the mean: %d\n", v); bad = 1; }
    M.misc.screen_on = 0; feed(268, 900); M.misc.screen_on = 1;
    v = feed(270, 310);
    if (v != 310) { printf("screen-off did not restart the mean: %d\n", v); bad = 1; }
    return bad;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -o "$T/t" "$T/t.c" || fail "fixture did not compile"
"$T/t" || fail "smoothing wrong"
echo "PASS comfort trims: smoothed current, once per sample, restarts, exit band"
)

t_comfort_burst_hold_runtime() (
# Runtime (fix169): a screen-on comfort trim needs a warm die, not the peak of a burst.
#
# OP15 capture 8689: prime_escape lifted the prime at 41 C, the burst ended at 48-50 C, and on
# that same tick screenon_comfort_smart_medium trimmed the ceilings by 9% with the shell at
# 28-31 C; the die was back at 39 C on the next tick, the dwell held the trim for 30 s, and the
# round repeated four times in eight minutes. Entry now needs the gate to hold for 10 s. The
# REAL helper is compiled and fed that sequence; the wiring is pinned.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL comfort burst hold: $*" >&2; exit 1; }
[ "$(grep -c '_cin, _cnow, &g_comfort_med_hold))' "$G")" = 1 ] || fail "the medium comfort gate is not held"
[ "$(grep -c '_cin, _cnow, &g_comfort_hc_hold))' "$G")" = 1 ] || fail "the high-current comfort gate is not held"
grep -q 'fprintf(f, "comfort_trim_burst_skips=%lu\\n", g_comfort_burst_skips);' "$G" || fail "held-back entries not published"
grep -q 'screen-on comfort trims held back on a die burst' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show them"
grep -q 'm->therm.surface_hotspot_c >= (g_budget_surface_engaged ? 42 : 46)' "$G" || fail "the surface comfort must keep reading at once"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS comfort burst hold (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  printf '#include <stdio.h>\n#include <time.h>\n'
  sed -n '/^#define ASB_COMFORT_ENTER_HOLD_S/,/^static int asb_adaptive_budget_trim_pct/p' "$G" | sed '$d'
  cat <<'X'
static int gate(int cond, int engaged, long t) { return asb_comfort_held(cond, engaged, (time_t)t, &g_comfort_med_hold); }
int main(void) {
    int bad = 0;
    (void)g_comfort_hc_hold;
    /* 8689, 13:36:58: lift at 41 C, release at 49 C on one tick, 39 C ten seconds later. */
    if (gate(1, 0, 1000)) { printf("one hot reading trimmed\n"); bad = 1; }
    if (gate(0, 0, 1010)) { printf("cool reading trimmed\n"); bad = 1; }
    if (g_comfort_burst_skips != 1) { printf("burst not counted: %lu\n", g_comfort_burst_skips); bad = 1; }
    /* A die that stays warm: on at the 10 s mark, not before. */
    if (gate(1, 0, 1100) || gate(1, 0, 1104) || gate(1, 0, 1108)) { printf("trimmed before 10 s\n"); bad = 1; }
    if (!gate(1, 0, 1110)) { printf("a warm die was not trimmed after 10 s\n"); bad = 1; }
    /* In force: the exit band is not delayed by the hold. */
    if (!gate(1, 1, 1112)) { printf("an engaged trim was dropped\n"); bad = 1; }
    if (gate(0, 1, 1116)) { printf("exit did not release\n"); bad = 1; }
    if (g_comfort_burst_skips != 1) { printf("a release counted as a burst\n"); bad = 1; }
    /* A reading after a pause over 30 s starts the hold again. */
    gate(1, 0, 2000);
    if (gate(1, 0, 2045)) { printf("a stale start let one reading through\n"); bad = 1; }
    if (!gate(1, 0, 2055)) { printf("hold did not restart from the fresh reading\n"); bad = 1; }
    return bad;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -o "$T/t" "$T/t.c" || fail "fixture did not compile"
"$T/t" || fail "hold wrong"
echo "PASS comfort burst hold: a burst peak does not trim, a die warm for 10 s does, a trim in force leaves on its band"
)

t_cpu_gpu_portability_contract() (
# Contract: CPU/GPU portability must be capability-driven and fail closed outside known sysfs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
METRICS="$ROOT/src/asb_metrics.h"
WRITER="$ROOT/src/asb_writer.h"
GOV="$ROOT/src/asb_governor.c"
WEB="$ROOT/webroot/index.html"
CAPS="$ROOT/runtime/asb_capabilities.sh"
DIAG="$ROOT/tools/asb_diag.sh"

fail() { echo "FAIL cpu/gpu portability: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }

# CPU policies are classified by actual OPP ceiling, never directory/CPU number alone.
need "$METRICS" 'Policy IDs are CPU-number based implementation details'
need "$METRICS" 'found_hwmax[16]'
need "$METRICS" 'cpuinfo_max_freq'
need "$METRICS" 'policy directory numbers are not ordered by OPP'
need "$METRICS" 'g_cpu_all_ids'
need "$WRITER" 'EXTRA CLUSTERS'
need "$WRITER" 'cpu_snap_freq(j, (long)target)'

# GPU discovery supports standard graphics-named devfreq backends, but never guesses a
# generic max_freq node that could belong to memory/ISP/NPU.
need "$METRICS" 'metrics_discover_generic_gpu_devfreq'
need "$METRICS" 'metrics_gpu_devfreq_name_is_graphics'
need "$WRITER" 'writer_discover_generic_gpu_devfreq'
need "$WRITER" 'writer_gpu_devfreq_name_is_graphics'
need "$METRICS" 'Never guess from an arbitrary devfreq node'
need "$METRICS" 'strstr(lower, "mali")'
need "$WRITER" 'strstr(lower, "powervr")'
need "$CAPS" '*mali*/max_freq'
need "$CAPS" '*xclipse*/max_freq'

# No readable utilisation node must remain an honest unavailable signal, not a fabricated 0%.
need "$METRICS" 'int     load_valid'
need "$METRICS" 'g->load_valid = (load >= 0 && load <= 100) ? 1 : 0;'
need "$GOV" 'gpu_valid=%d'
need "$GOV" 'g_device_caps.has_gpu_load = (uint8_t)(metrics.gpu.load_valid ? 1 : 0);'
need "$WEB" 'Object.prototype.hasOwnProperty.call(st, '\''gpu_valid'\'')'
need "$WEB" 'GPU utilisation node is unavailable on this driver'
need "$DIAG" 'generic devfreq'
need "$DIAG" 'no recognised GPU devfreq backend'

# Native source must compile with its direct headers on the host; this catches missing POSIX
# includes from directory discovery before Android NDK release compilation.
CC_BIN="${CC:-cc}"
command -v "$CC_BIN" >/dev/null 2>&1 || fail 'C compiler unavailable'
"$CC_BIN" -std=gnu11 -fsyntax-only -I"$ROOT/src" "$ROOT/src/asb_governor.c" || fail 'native portability source does not compile'
sh -n "$CAPS" || fail 'capability script syntax'
sh -n "$DIAG" || fail 'diagnostic script syntax'

echo 'PASS: CPU/GPU portability contract'
)

t_cpu_min_opp_contract() (
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WRITER="$ROOT/src/asb_writer.h"
DISCOVER="$ROOT/tools/asb_discover.sh"
DIAG="$ROOT/tools/asb_diag.sh"
POLICY="$ROOT/tools/asb_effective_policy.sh"
SERVICE="$ROOT/service.sh"

fail() { printf '%s\n' "FAIL cpu min OPP: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden $2 in ${1#$ROOT/}" || true; }

# The native writer must discover the actual first OPP from every physical policy table.
need "$WRITER" 'static long cpu_lowest_opp(int path_idx)'
need "$WRITER" 'A missing/empty table returns 0'
need "$WRITER" 'if (fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED)'
need "$WRITER" 'long smart_opp = cpu_lowest_opp(_mi);'
need "$WRITER" 'long smart_opp = cpu_lowest_opp(j);'
need "$WRITER" 'manual profiles and'
need "$WRITER" 'HEAVY/GAMING keep their requested floors unchanged'
# No literal cross-device floor may be introduced by this policy.
absent "$WRITER" 'DEEP_IDLE_MIN_KHZ'
absent "$WRITER" 'LOWEST_OPP_KHZ'

# Discovery and diagnostics must expose whether the actual policy is usable and accepted.
need "$DISCOVER" 'cpu_policy${_pid}_lowest_opp='
need "$DISCOVER" 'cpu_policy${_pid}_min_writable='
need "$DIAG" 'smart minimum: [PASS] Smart requested hardware lowest OPP'
need "$DIAG" 'smart minimum: [WARN]'
need "$DIAG" 'DEEP_IDLE|LIGHT_IDLE|MODERATE|SUSTAINED'
need "$DIAG" 'scaling_min=$_minwf'
need "$SERVICE" '[ "${ASB_PROFILE:-$PROFILE}" = "smart" ]'
need "$SERVICE" 'cpuinfo_min_freq'
need "$POLICY" '"cpu_min_policy"'
need "$POLICY" 'hardware_lowest_opp'
need "$POLICY" 'smart_non_gaming'

printf '%s\n' 'PASS CPU minimum OPP contract'
)

t_display_waiter_runtime() (
# Runtime (fix116): wakes are seen the moment Android switches the display on.
#
# OnePlus 15 captures found 6 of 31 and 14 of 35 wakes only on the next 45 s idle tick, the
# OnePlus 13R 19 of 30 - unlock and launch on deep-idle rails. A thread now blocks in
# __system_property_wait on debug.tracing.screen_state and pokes an eventfd only when the
# display enters or leaves ON; always-on-display doze flips never reach the main loop.
# Executable fixture: the REAL waiter cut out of asb_governor.c, a fake property store
# whose __system_property_wait blocks on a condition variable.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; M="$ROOT/src/asb_metrics.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL display waiter: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP display waiter: no C compiler"; exit 0; }

# From the waiter's globals to the end of asb_disp_waiter_start().
_a="$(grep -n "^/\* \.\.\. and by Android's own display state" "$G" | cut -d: -f1)"
_b="$(awk '/^static int asb_disp_waiter_start\(/{f=1} f&&/^}/{print NR; exit}' "$G")"
[ -n "$_a" ] && [ -n "$_b" ] || fail "waiter code not found"
sed -n "${_a},${_b}p" "$G" > "$T/w.c"
awk '/^#ifndef ASB_DISPLAY_STATE_FIXTURE$/{on=1} on{print} on&&/^#endif$/{n++} n==2{exit}' "$M" > "$T/r.c"
grep -q 'pthread_sigmask(SIG_BLOCK' "$T/w.c" || fail "signals are not blocked on the waiter thread"
grep -q 'cur == 2 || prev == 2' "$T/w.c" || fail "waiter signals more than ON transitions"
grep -q 'debug.tracing.screen_state' "$T/r.c" || fail "property reader not found"

cat > "$T/t.c" <<'X'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <poll.h>
#include <pthread.h>
#include <dlfcn.h>
#include <sys/eventfd.h>
#define __ANDROID__ 1
#define PROP_VALUE_MAX 92
typedef struct prop_info { int dummy; } prop_info;
static prop_info g_pi;
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_cv = PTHREAD_COND_INITIALIZER;
static char g_val[8] = "1";
static uint32_t g_serial = 1;
static int g_waits = 0;
int __system_property_get(const char *n, char *v) {
    pthread_mutex_lock(&g_mx); strcpy(v, g_val); pthread_mutex_unlock(&g_mx); return (int)strlen(v); }
static int g_prop_exists = 0;   /* created at the first display transition after boot */
const prop_info *__system_property_find(const char *n) {
    if (strcmp(n, "debug.tracing.screen_state")) return NULL;
    pthread_mutex_lock(&g_mx); int e = g_prop_exists; pthread_mutex_unlock(&g_mx);
    return e ? &g_pi : NULL; }
uint32_t __system_property_serial(const prop_info *pi) {
    pthread_mutex_lock(&g_mx); uint32_t s = g_serial; pthread_mutex_unlock(&g_mx); return s; }
_Bool __system_property_wait(const prop_info *pi, uint32_t old, uint32_t *ns, const struct timespec *to) {
    pthread_mutex_lock(&g_mx);
    g_waits++;
    while (g_serial == old) pthread_cond_wait(&g_cv, &g_mx);
    *ns = g_serial;
    pthread_mutex_unlock(&g_mx);
    return 1;
}
static void setp(const char *v) {
    pthread_mutex_lock(&g_mx); strcpy(g_val, v); g_serial++; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mx);
    usleep(30000);
}
#include "r.c"
#include "w.c"
static int fired(int fd) {
    struct pollfd p = { fd, POLLIN, 0 };
    if (poll(&p, 1, 200) <= 0) return 0;
    uint64_t v; if (read(fd, &v, sizeof(v)) != sizeof(v)) return 0;
    return 1;
}
int main(void) {
    int bad = 0;
    #define CHECK(c, msg) do { if (!(c)) { printf("%s\n", msg); bad = 1; } } while (0)
    int fd = asb_disp_waiter_start();
    CHECK(fd >= 0, "waiter did not start");
    if (fd < 0) return 1;
    usleep(50000);
    CHECK(g_disp_waiter_up == 1, "waiter gave up before the property existed");
    /* the property appears only after the screen stayed on past the old 10-minute limit */
    usleep(2500000);
    CHECK(g_disp_waiter_up == 1, "waiter stopped looking");
    pthread_mutex_lock(&g_mx); g_prop_exists = 1; pthread_mutex_unlock(&g_mx);
    usleep(1300000);
    CHECK(g_disp_waiter_up == 2, "waiter did not pick up a property created late");
    setp("2"); CHECK(fired(fd), "OFF -> ON did not reach the main loop");
    setp("3"); CHECK(fired(fd), "ON -> DOZE did not reach the main loop");
    setp("4"); CHECK(!fired(fd), "DOZE -> DOZE_SUSPEND woke the main loop");
    setp("3"); CHECK(!fired(fd), "DOZE_SUSPEND -> DOZE woke the main loop");
    setp("1"); CHECK(!fired(fd), "DOZE -> OFF woke the main loop");
    setp("2"); CHECK(fired(fd), "second wake missed");
    setp("2"); CHECK(!fired(fd), "a rewrite of the same value woke the main loop");
    setp("1"); CHECK(fired(fd), "ON -> OFF missed");
    /* SIGTERM must land on the main thread: blocked on the waiter */
    sigset_t cur; pthread_sigmask(SIG_BLOCK, NULL, &cur);
    CHECK(!sigismember(&cur, SIGTERM), "the main thread was left with signals blocked");
    return bad;
}
X
"$CC" -std=gnu99 -Wall -Wno-unused-function -DASB_DISP_FIND_RETRY_S=1 -pthread -rdynamic -o "$T/t" "$T/t.c" -I"$T" -ldl 2>"$T/cc.err" \
  || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"

# Main-loop wiring: the eventfd is watched, a fresh ON is trusted for 3 s, wakes are counted.
grep -q 'fd == g_disp_prop_evfd' "$G" || fail "main loop does not watch the waiter"
grep -q 'g_disp_prop_on_ts = time(NULL);' "$G" || fail "ON transition not stamped"
grep -q 'now - g_disp_prop_on_ts <= 3' "$M" || fail "fresh ON not trusted (or trusted without a window)"
grep -q 'display:%lu' "$G" || fail "state file does not count display-state wakes"
grep -q 'display_waiter=%d' "$G" || fail "state file does not say whether the waiter runs"
echo "PASS display-state waiter: instant wake detection, no doze wakeups"
)

t_forecast_one_source_runtime() (
# Runtime (fix127): one screen-time forecast, the same on every screen.
#
# OP15, V65 fix126: Monitor "Forecast (screen) 5 h 44 m · average" under "Average drain
# 12.9 %/h", while the action sheet printed "5.7 h at an average drain of 9.4 %/h" next to
# "this hour usually 12.9 %/h" - three rates, two called "average". The governor now
# publishes its forecast rate and basis; the REAL action.sh block and the REAL WebUI block
# are cut out and fed the same state: same minutes, same rate, the rate's own name.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
A="$ROOT/action.sh"; W="$ROOT/webroot/index.html"; G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL forecast one source: $*" >&2; exit 1; }

grep -q 'fprintf(f, "forecast_rate_x10=%d\\nforecast_basis=%s\\n", _fr, _fb);' "$G" || fail "governor does not publish the forecast"
grep -q 'g_smart_budget_rate_x10 = _budget_rate;' "$G" || fail "published rate is not the one the budget divided by"

awk '/^_frx=\$\(grep -m1 "\^forecast_rate_x10="/{f=1} f{print} /^# Idle half: the governor/{if(f) exit}' "$A" \
  | sed "s#/dev/.asb/state#\$STATE#g" > "$T/a.sh"
[ -s "$T/a.sh" ] || fail "action forecast block not found"
for v in T_ETA_MEASURED T_ETA_AVG T_ETA_SLOT T_ETA_HEUR T_ETA_SCREEN; do
  grep -m1 "^$v=" "$ROOT/runtime/i18n/action_ru.sh" >> "$T/ru.sh" || fail "$v missing in ru"
done
echo 'U_PCTH="%/ч"' >> "$T/ru.sh"

run_action() {   # $1 state file -> "minutes|note"
  STATE="$1" sh -c '
    . "$1"; _s() { _sfmt="$1"; shift; printf "$_sfmt" "$@"; }
    PROFILE=smart; _lvl=55; _cap_uah=7300000
    . "$2"
    echo "$(( _ton_h * 60 + _ton_m ))|$_eta_note|$(_s "$T_ETA_SCREEN" "$_ton_h" "$_ton_m")"
  ' x "$T/ru.sh" "$T/a.sh"
}

_s="$(grep -n '    let on_ma, eta_note;' "$W" | head -1 | cut -d: -f1)"
_e="$(grep -n '      : ((remain_mah > 0 && on_ma > 0) ? Math.floor(remain_mah \* 60 / on_ma) : 0);' "$W" | head -1 | cut -d: -f1)"
[ -n "$_s" ] && [ -n "$_e" ] || fail "WebUI forecast block not found"
{
  echo "let _selectedProfile = 'smart'; const _lvMeter = { p: {} };"
  for fn in lvSlotToMeter lvMeterTip; do sed -n "/^function $fn(/,/^}/p" "$W"; done
  sed -n "${_s},${_e}p" "$W"
} > "$T/w.js"
cat > "$T/run.js" <<'X'
const fs = require('fs');
const ru = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const kv = {};
for (const l of fs.readFileSync(process.argv[3], 'utf8').split('\n')) { const i = l.indexOf('='); if (i > 0) kv[l.slice(0, i)] = l.slice(i + 1); }
const T = (k, d) => (k in ru ? ru[k] : d);
const st = null, bcap = 55, cap_full_mah = 7300, profile = 'smart';
let __out = '';
eval(fs.readFileSync(process.argv[4], 'utf8') + "\n__out = ton_min + '|' + eta_note;");
console.log(__out);
X
run_web() { node "$T/run.js" "$ROOT/webroot/i18n/ru.json" "$1" "$T/w.js"; }

# 1. The actual drain (fix128): 15.4 %/h measured over the last minutes, at 55 %.
printf 'forecast_rate_x10=154\nforecast_basis=now\nsmart_drain_pctph_x10=154\nsmart_drain_window_s=698\nsmart_drain_ewma_x10=162\nsmart_bucket_drain_x10=93\nsmart_confidence=1000\n' > "$T/s0"
a="$(run_action "$T/s0")"; w="$(run_web "$T/s0")"
[ "${a%%|*}" = 214 ] || fail "action minutes $a, want 214 (55 % / 15.4 %/h)"
[ "${w%%|*}" = 214 ] || fail "WebUI minutes $w, want 214"
printf '%s' "$a" | grep -q '(по факту 15.4%/ч)' || fail "action note for the actual drain: $a"
printf '%s' "$a" | grep -q '|~3 ч 34 мин$' || fail "Smart card time differs from the header: $a"
[ "${w#*|}" = ' · по факту' ] || fail "WebUI note must be short - '· по факту': $w"
# 2. An estimate from recent sessions: 9.4 %/h.
printf 'forecast_rate_x10=94\nforecast_basis=recent\nsmart_drain_pctph_x10=103\nsmart_drain_window_s=300\nsmart_drain_ewma_x10=94\nsmart_bucket_drain_x10=129\nsmart_confidence=1000\n' > "$T/s1"
a="$(run_action "$T/s1")"; w="$(run_web "$T/s1")"
[ "${a%%|*}" = 351 ] && [ "${w%%|*}" = 351 ] || fail "estimate minutes: action $a, WebUI $w (want 351)"
printf '%s' "$a" | grep -q '(оценка по прошлым сессиям 9.4%/ч)' || fail "action estimate note: $a"
[ "${w#*|}" = ' · оценка' ] || fail "WebUI estimate note must be short: $w"
# 3. Slot basis right after boot.
printf 'forecast_rate_x10=129\nforecast_basis=slot\nsmart_drain_window_s=0\n' > "$T/s2"
a="$(run_action "$T/s2")"; w="$(run_web "$T/s2")"
[ "${a%%|*}" = "${w%%|*}" ] || fail "slot forecast differs: action $a, WebUI $w"
printf '%s' "$a" | grep -q '(оценка по этому часу 12.9%/ч)' || fail "slot note wrong: $a"
[ "${w#*|}" = ' · оценка' ] || fail "WebUI slot note wrong: $w"
# 4. An older governor without forecast keys: both fall back to the same live rate.
printf 'smart_drain_pctph_x10=103\nsmart_drain_window_s=1200\n' > "$T/s3"
a="$(run_action "$T/s3")"; w="$(run_web "$T/s3")"
[ "${a%%|*}" = 320 ] && [ "${w%%|*}" = 320 ] || fail "fallback differs: action $a, WebUI $w (want 320)"
printf '%s' "$a" | grep -q '(по факту 10.3%/ч)' || fail "live note wrong: $a"
# 5. The Monitor tile shows the actual drain, in one word.
grep -q '"lv_avgdrain": "Расход"' "$ROOT/webroot/i18n/ru.json" || fail "drain tile not the actual drain"
grep -q "if (_fbs === 'now') _act = _frt;" "$W" || fail "tile does not show the actual rate"
# fix131: until a window is measured the tile shows the same estimate the action screen
# prints (marked "~"), not "measuring" - nearly always the case in short screen-on use.
grep -Fq "} else if (_frt > 0 && (_fbs === 'recent' || _fbs === 'slot' || _fbs === 'meter') && !_chg) {" "$W" || fail "tile hides the estimate the action screen shows"
grep -Fq "_bdEl.textContent = '~' + (_frt / 10).toFixed(1)" "$W" || fail "estimate not marked as one"
grep -q '_fb = "now";' "$G" || fail "governor forecast does not lead with the actual drain"

echo "PASS forecast one source: actual drain first, same minutes on every screen, short labels"
)

t_gov_liveness_runtime() (
# Runtime (fix144): a governor that died is restarted, and nothing pretends to check it.
#
# The governor scheduled "asb_watchdog.sh --once" and "asb_reconcile.sh --once" itself. The
# watchdog exited on its first line (ASB_GOV_ENABLED is not in the governor's environment) and
# could never catch the death of the process that scheduled it; reconcile's --once broke out
# of its loop before the first check. Both forked shells every few minutes for nothing, and
# a crashed governor left its last ceilings in place until a reboot. service.sh's housekeeping
# loop now checks the pid (asb_gov_liveness); asbdiag tells boots, clean restarts and crashes
# apart from the persistent log. The REAL function runs here.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL gov liveness: $*" >&2; fail=1; }

sed -n '/^# asb_gov_liveness_begin$/,/^# asb_gov_liveness_end$/p' "$ROOT/service.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || { echo "FAIL gov liveness: no asb_gov_liveness block in service.sh" >&2; exit 1; }
grep -q '^    asb_gov_liveness$' "$ROOT/service.sh" || f "housekeeping loop does not call asb_gov_liveness"

sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
mkdir -p "$T/mod"; echo smart > "$T/mod/current_profile"

out="$(MODDIR="$T/mod" ASB_GOV_PIDFILE="$T/gov.pid" ASB_SAFE_MODE_FILE="$T/safe" ASB_WD_RESIDENT_FILE="$T/wdres" T="$T" DEAD="$DEAD" sh -c '
  . "$T/fn.sh"
  asb_feature_enabled() { [ "$(cat "$T/cpu" 2>/dev/null)" != 0 ]; }
  asb_log() { echo "LOG $*"; }
  asb_governor_start() { echo START; echo "$$" > "$ASB_GOV_PIDFILE"; }
  echo "-- none";  asb_gov_liveness
  echo "$$" > "$ASB_GOV_PIDFILE"
  echo "-- alive"; asb_gov_liveness
  echo "$DEAD" > "$ASB_GOV_PIDFILE"
  echo "-- dead";  asb_gov_liveness
  echo "-- after"; asb_gov_liveness
  touch "$T/safe"; echo "$DEAD" > "$ASB_GOV_PIDFILE"
  echo "-- safe";  asb_gov_liveness
  rm -f "$T/safe"; echo stock > "$MODDIR/current_profile"
  echo "-- stock"; asb_gov_liveness; [ -e "$ASB_GOV_PIDFILE" ] && echo "PIDFILE KEPT"
  echo smart > "$MODDIR/current_profile"
  for i in 2 3 4 5; do echo "$DEAD" > "$ASB_GOV_PIDFILE"; echo "-- loop$i"; asb_gov_liveness; done
  _gl_w0=$(( _gl_w0 - 1900 )); echo "$DEAD" > "$ASB_GOV_PIDFILE"
  echo "-- window"; asb_gov_liveness
  echo 0 > "$T/cpu"; echo "$DEAD" > "$ASB_GOV_PIDFILE"
  echo "-- nocpu"; asb_gov_liveness; [ -e "$ASB_GOV_PIDFILE" ] && echo "PIDFILE KEPT"
  rm -f "$T/cpu"; echo "$DEAD" > "$ASB_GOV_PIDFILE"; : > "$T/wdres"
  echo "-- wdres"; asb_gov_liveness
' 2>&1)"
sec() { printf '%s\n' "$out" | awk -v s="-- $1" '$0 == s { f = 1; next } /^-- / { f = 0 } f'; }
[ -z "$(sec none)" ] || f "acted with no pid file: $(sec none)"
[ -z "$(sec alive)" ] || f "acted on a live governor: $(sec alive)"
sec dead | grep -q '^START$' || f "dead governor not restarted: $out"
sec dead | grep -q "^LOG governor: pid $DEAD had died without a clean stop - restarted (1 in 30 min)$" || f "restart not logged: $out"
[ -z "$(sec after)" ] || f "acted again on the restarted governor: $(sec after)"
[ -z "$(sec safe)" ] || f "restarted in safe mode: $(sec safe)"
[ -z "$(sec stock)" ] || f "restarted under stock: $(sec stock)"
printf '%s\n' "$out" | grep -q 'PIDFILE KEPT' && f "a stale pid file left where no governor belongs: $out"
sec loop2 | grep -q 'restarted (2 in 30 min)' || f "second restart: $out"
sec loop3 | grep -q 'restarted (3 in 30 min)' || f "third restart: $out"
sec loop4 | grep -q '^START$' && f "a fourth restart inside 30 min (crash loop fed): $out"
sec loop4 | grep -q 'died again after 3 restarts in 30 min' || f "crash loop not logged: $out"
[ -z "$(sec loop5)" ] || f "crash-loop line repeated: $(sec loop5)"
sec window | grep -q 'restarted (1 in 30 min)' || f "no restart once the window passed: $out"
[ -z "$(sec nocpu)" ] || f "restarted with the CPU feature off: $(sec nocpu)"
# A resident watchdog loop (the no-governor fallback in service.sh) owns recovery; liveness
# must defer to its marker instead of racing a second restart path.
[ -z "$(sec wdres)" ] || f "acted while the resident watchdog owns recovery: $(sec wdres)"
grep -q 'touch "${ASB_WD_RESIDENT_FILE:-/dev/.asb/watchdog_resident}"' "$ROOT/service.sh" \
  || f "watchdog fallback does not mark resident ownership"
grep -q '\[ -f "${ASB_WD_RESIDENT_FILE:-/dev/.asb/watchdog_resident}" \] && return 0' "$ROOT/service.sh" \
  || f "liveness does not defer to a resident watchdog"

# The governor no longer spawns the two no-op scripts.
G="$ROOT/src/asb_governor.c"
grep -q 'runtime/asb_reconcile.sh"' "$G" && f "governor still spawns asb_reconcile.sh --once"
grep -q 'runtime/asb_watchdog.sh"' "$G" && f "governor still spawns asb_watchdog.sh --once"
grep -q 'started (pid %d, %lds after boot)' "$G" || f "start line without seconds since boot"
grep -q 'asb_governor stopped cleanly (pid %d)' "$G" || f "clean exit not logged"

# asbdiag: boots, clean restarts and crashes apart.
sed -n '/^# asb_gov_starts_begin$/,/^# asb_gov_starts_end$/p' "$ROOT/tools/asb_diag.sh" > "$T/gs.sh"
[ -s "$T/gs.sh" ] || f "asbdiag has no asb_gov_starts block"
cat > "$T/persist" <<'EOF'
[10-12 22:44:48] asb_governor V65 started (pid 15917)
[10-13 10:35:20] asb_governor V65 started (pid 15147, 45s after boot)
[10-13 11:02:00] smart store flushed on shutdown
[10-13 11:02:00] asb_governor stopped cleanly (pid 15147)
[10-13 11:02:02] asb_governor V65 started (pid 16001, 1662s after boot)
[10-13 12:40:10] asb_governor V65 started (pid 16420, 7530s after boot)
[10-13 20:00:00] asb_governor V65 started (pid 1500, 38s after boot)
EOF
r="$(sh -c '. "$1"; asb_gov_starts < "$2"' x "$T/gs.sh" "$T/persist")"
[ "$r" = "4 2 1 1" ] || f "asbdiag start classification: '$r' (want 4 starts: 2 at boot, 1 after a clean stop, 1 after a crash)"
r="$(printf '[x] asb_governor V65 started (pid 1)\n' | sh -c '. "$1"; asb_gov_starts' x "$T/gs.sh")"
[ -z "$r" ] || f "asbdiag classified pre-fix144 lines: $r"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

[ "$fail" = 0 ] && echo "PASS gov liveness: dead governor restarted (not under stock/safe mode, no crash-loop feeding), no-op spawns gone, starts classified"
exit "$fail"
)

t_kernel_uv_coexist_contract() (
# Contract: external kernel/UV coexistence detection is evidence-only and never owns voltage policy.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TOOL="$ROOT/tools/asb_kernel_uv_coexist.sh"
DIAG="$ROOT/tools/asb_diag.sh"
BIN_DIAG="$ROOT/system/bin/asbdiag"
TEST_WF="$ROOT/.github/workflows/build-test.yml"
REL_WF="$ROOT/.github/workflows/build-release.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL kernel-uv coexistence: $*" >&2; exit 1; }
get() { grep -E "^$1=" "$1" 2>/dev/null; }
value() { grep -E "^$1=" "$2" 2>/dev/null | tail -1 | sed 's/^[^=]*=//'; }
run_probe() {
  ASB_SYSROOT="$TMP/sys" ASB_MODULES_ROOT="$TMP/modules" ASB_PROP_FILE="$TMP/props" \
    sh "$TOOL" > "$TMP/out"
}

[ -x "$TOOL" ] || fail "probe must be executable"
sh -n "$TOOL" || fail "probe syntax"
mkdir -p "$TMP/sys" "$TMP/modules"
: > "$TMP/props"
run_probe
[ "$(value status "$TMP/out")" = "not_observable" ] || fail "clean device must be not_observable"
[ "$(value asb_voltage_owner "$TMP/out")" = "external_or_vendor" ] || fail "ASB ownership wording"
# `opp` is generic operating-point metadata and appears in unrelated Bluetooth properties;
# it must never by itself produce an external voltage-policy verdict.
printf '%s\n' '[bluetooth.profile.opp.enabled]: [true]' > "$TMP/props"
run_probe
[ "$(value status "$TMP/out")" = "not_observable" ] || fail "Bluetooth OPP property is not UV evidence"
# Stock battery shutdown threshold: has "voltage" in its name, says nothing about CPU tables.
printf '%s\n' '[ro.cutoff_voltage_mv]: [3100]' '[persist.vendor.battery.voltage_max]: [4500]' > "$TMP/props"
run_probe
[ "$(value status "$TMP/out")" = "not_observable" ] || fail "battery voltage property is not UV evidence"
printf '%s\n' '[persist.kernel.cpu_voltage_offset]: [1]' > "$TMP/props"
run_probe
[ "$(value status "$TMP/out")" = "external_uv_hint" ] || fail "explicit voltage property should remain a hint"
: > "$TMP/props"
[ "$(value asb_action "$TMP/out")" = "diagnostics_only" ] || fail "diagnostics-only action"

mkdir -p "$TMP/modules/MyUV"
cat > "$TMP/modules/MyUV/module.prop" <<'EOF'
id=example_undervolt_kernel
name=Example Undervolt Kernel Controller
EOF
run_probe
[ "$(value status "$TMP/out")" = "external_uv_hint" ] || fail "external module should be a hint"
[ "$(value confidence "$TMP/out")" = "name_or_property_hint" ] || fail "module hint confidence"

rm -rf "$TMP/modules/MyUV"
mkdir -p "$TMP/sys/devices/system/cpu/cpufreq/policy0"
: > "$TMP/sys/devices/system/cpu/cpufreq/policy0/opp_voltage"
run_probe
[ "$(value status "$TMP/out")" = "voltage_surface_observed" ] || fail "readable voltage surface must be observed"
[ "$(value confidence "$TMP/out")" = "observed_surface" ] || fail "surface confidence"

# The executable body must not contain mutation commands. Comments are not policy paths.
if sed '/^[[:space:]]*#/d' "$TOOL" | grep -Eqi '(^|[;[:space:]])(setprop|mount|umount|chmod|chown|insmod|rmmod|dd)[[:space:]]|>[[:space:]]*/(sys|proc|data)'; then
  fail "probe contains a mutation primitive"
fi

grep -Fq 'frequency_temperature_or_kernel_name_alone_do_not_prove_undervolt' "$TOOL" || fail "uncertainty warning missing"
grep -Fq 'ASB does not own, write, validate, disable or revert external voltage policy' "$TOOL" || fail "non-ownership warning missing"
grep -Fq 'EXTERNAL KERNEL / UV COEXISTENCE' "$DIAG" || fail "asbdiag integration missing"
grep -Fq 'asb_kernel_uv_coexist.sh' "$DIAG" || fail "asbdiag helper invocation missing"
cmp -s "$DIAG" "$BIN_DIAG" || fail "asbdiag copies differ"

# Test package identity changes only in staged package. It intentionally preserves base code.
grep -Fq 'ASB_VER="${BASE_VER}-test${TEST_SEQ}"' "$TEST_WF" || fail "V65-test1 naming contract missing"
grep -Fq 'TEST_CODE="$BASE_CODE"' "$TEST_WF" || fail "test versionCode preservation missing"
grep -Fq 'sed -i "s/^version=.*/version=${ASB_VER}/" "$PKG_TEST/module.prop"' "$TEST_WF" || fail "staged version-only patch missing"
grep -Fq 'grep -qx "versionCode=${BASE_CODE}" "$PKG_TEST/module.prop"' "$TEST_WF" || fail "staged versionCode check missing"
! grep -Fq 'TEST_CODE=$((BASE_CODE + TEST_SEQ))' "$TEST_WF" || fail "legacy test code ladder remains"
[ ! -e "$ROOT/.github/workflows/build-debug.yml" ] || fail "separate debug workflow still exists"

grep -Fq 'tools/asb_kernel_uv_coexist.sh' "$REL_WF" || fail "release package does not carry probe"
grep -Fq 'tools/asb_kernel_uv_coexist.sh' "$TEST_WF" || fail "test package does not carry probe"

echo "PASS kernel/UV coexistence and V64-debug identity contract"
)

t_learner_charging_runtime() (
# Runtime (fix148): the hour-of-week learner takes no drain from a charging hour.
#
# The governor passed the battery current's magnitude whatever its direction, so an hour on
# the charger was learned as drain: CPH2769's log read "learner updated: drain=2317.0mA
# screen=0%" for an hour of 3.4 A charging. A charging tick now carries no drain; an hour of
# them still teaches the screen share and leaves the drain as it was. The REAL header runs.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CC="${CC:-}"; [ -n "$CC" ] || CC="$(command -v gcc || command -v clang || true)"
[ -n "$CC" ] || { echo "SKIP learner charging: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'C'
#include <stdint.h>
#include <unistd.h>
#include "asb_learner.h"
#include <stdio.h>
static int roll(asb_accum_t *a, float *d, float *s) {   /* force the hour to change */
  a->last_hour = (a->last_hour + 1) % 24;
  return accum_tick(a, -1, 0, d, s);
}
int main(void) {
  asb_accum_t a; asb_learn_db_t db; float d, s; int bad = 0;
  memset(&db, 0, sizeof db); accum_init(&a);
  int slot = learner_slot();
  db.slots[slot].samples = 5; db.slots[slot].drain_ma_ema = 300.0f; db.slots[slot].screen_on_ema = 0.5f;
  /* An hour on the charger: 10 ticks, screen on in 4, no drain sample. */
  for (int i = 0; i < 10; i++) accum_tick(&a, -1, i < 4, &d, &s);
  if (!roll(&a, &d, &s)) { puts("no rollover"); return 1; }
  if (d >= 0) { printf("charging hour produced a drain of %.1f\n", d); bad = 1; }
  if (s < 0.35f || s > 0.37f) { printf("screen share %.3f (want 4 of 11 ticks)\n", s); bad = 1; }
  learner_update(&db, d, s);
  if (db.slots[slot].drain_ma_ema != 300.0f) { printf("drain moved to %.1f by a charging hour\n", db.slots[slot].drain_ma_ema); bad = 1; }
  if (db.slots[slot].screen_on_ema >= 0.5f) { printf("screen share not learned (%.3f)\n", db.slots[slot].screen_on_ema); bad = 1; }
  /* A battery hour still moves the drain. */
  for (int i = 0; i < 10; i++) accum_tick(&a, 400, 1, &d, &s);
  roll(&a, &d, &s);
  if (d < 399.0f || d > 401.0f) { printf("battery hour drain %.1f (want 400)\n", d); bad = 1; }
  learner_update(&db, d, s);
  if (db.slots[slot].drain_ma_ema <= 300.0f) { puts("battery hour did not move the drain"); bad = 1; }
  return bad;
}
C
"$CC" -I"$ROOT/src" -o "$T/t" "$T/t.c" -lm 2>"$T/err" || { echo "FAIL learner charging: does not compile: $(head -3 "$T/err")" >&2; exit 1; }
"$T/t" || { echo "FAIL learner charging" >&2; exit 1; }
grep -q 'metrics.bat.charging ? -1 : metrics.bat.current_ma' "$ROOT/src/asb_governor.c" || { echo "FAIL learner charging: governor still feeds charging current" >&2; exit 1; }
echo "PASS learner charging: an hour on the charger teaches the screen share and no drain"
)

t_main_capacity_parity_runtime() (
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
)

t_msm_perf_topology_runtime() (
# fix76: msm_performance ceilings follow the real CPU topology, ASB's own registration is
# not read back as lost headroom, and the boost-time registration is released.
#
# Before: cpus 0-5 got the little cap and 6-7 the big one (a 6+2 layout). On a 1+3+2+1
# part (OP12 / Ace 5: 0-1, 2-4, 5-6, 7) that capped four mid cores at the little ceiling
# and the prime at the mid ceiling in HEAVY/GAMING, and the governor then read its own cap
# back as "headroom 34% - kernel thermal cap detected" and entered SUSTAINED.
# Executable fixture: the REAL functions cut out of asb_metrics.h / asb_writer.h, run
# against a fake sysfs tree.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"; W="$ROOT/src/asb_writer.h"; G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL msm topology: $*" >&2; exit 1; }

grep -q 'msm_perf_write_all_max' "$W" "$G" && fail "the fixed 6+2 writer is still referenced"
grep -q 'msm_perf_release();' "$W" || fail "boost-time registration is never released"
grep -q '"own_cap"' "$M" || fail "headroom still reads ASB's own msm cap as a kernel clamp"
# fix191: the reassert passes every slot through writer_reassert_target, the third included.
grep -Fq 'int ok = msm_perf_write_caps(rtc[0], rtc[1], rtc[2]);' "$G" && grep -Fq 'for (int _rs = 0; _rs < 3; _rs++)' "$G" || fail "anti-clamp reassert drops the prime slot"

awk '/^static int g_asb_msm_written\[3\]/{on=1} on{print} on&&/^static int cpu_slot_of\(/{f=1} f&&/^}/{exit}' "$M" > "$T/topo.c"
awk '/^#define PATH_MSM_PERF_CPU_MAX/{on=1} on{print} on&&/^static void msm_perf_release\(/{f=1} f&&/^}/{exit}' "$W" > "$T/msm.c"
[ -s "$T/topo.c" ] && [ -s "$T/msm.c" ] || fail "functions not found"

mk() {  # mk <root> <policy> <cpus...>
  r="$1"; p="$2"; shift 2
  mkdir -p "$r/sys/devices/system/cpu/cpufreq/policy$p"
  echo "$*" > "$r/sys/devices/system/cpu/cpufreq/policy$p/related_cpus"
}
R="$T/op12"; mk "$R" 0 0 1; mk "$R" 2 2 3 4; mk "$R" 5 5 6; mk "$R" 7 7
mkdir -p "$R/sys/kernel/msm_performance/parameters"; : > "$R/sys/kernel/msm_performance/parameters/cpu_max_freq"

cat > "$T/t.c" <<X
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int fake_open(const char *p, int fl) {
    char b[512]; snprintf(b, sizeof(b), "%s%s", "$R", p); return open(b, fl | (fl & O_WRONLY ? O_TRUNC : 0));
}
#define open(p, f) fake_open(p, f)
static int g_cpu_all_ids[16]  = {0, 2, 5, 7};
static int g_cpu_all_slot[16] = {0, 1, 1, 2};
static int g_cpu_all_count = 4;
static int g_cpu_slot_hwmax[3] = {2265600, 3014400, 3302400};
#include "topo.c"
#include "msm.c"
static void node(char *b) { FILE *f = fopen("$R/sys/kernel/msm_performance/parameters/cpu_max_freq", "r"); b[0]=0; if (f) { if (!fgets(b, 400, f)) b[0]=0; fclose(f); } }
int main(void) {
    char b[400];
    if (msm_perf_write_caps(1363200, 2035200, 2496000) != 0) { puts("write failed"); return 1; }
    node(b);
    if (strcmp(b, "0:1363200 1:1363200 2:2035200 3:2035200 4:2035200 5:2035200 6:2035200 7:2496000")) { printf("layout: %s\n", b); return 1; }
    if (g_asb_msm_written[0] != 1363200 || g_asb_msm_written[2] != 2496000) { puts("own-cap record"); return 1; }
    // prime unmanaged (0): it gets the hardware maximum, not the mid cap
    g_msm_cur_max[2] = 0;
    msm_perf_write_caps(1363200, 2035200, 0); node(b);
    if (!strstr(b, "7:3302400")) { printf("unmanaged prime: %s\n", b); return 1; }
    msm_perf_release(); node(b);
    if (strcmp(b, "0:2265600 1:2265600 2:3014400 3:3014400 4:3014400 5:3014400 6:3014400 7:3302400")) { printf("release: %s\n", b); return 1; }
    if (g_msm_holding) { puts("still holding"); return 1; }
    return 0;
}
X
cc -std=gnu11 -Wall -Wno-unused-function -I"$T" "$T/t.c" -o "$T/t" || fail "fixture does not compile"
"$T/t" || fail "runtime check failed"
echo "PASS msm_performance follows the CPU topology"
)

t_asbdiag_msm_owner_runtime() (
# Runtime (fix188): asbdiag says whose ceilings msm_performance holds. An OP15 report a minute
# after boot listed "0:2227200 .. 6:1632000" there, the prime at 35 % beside "cap written by
# ASB: prime 1862400", and "profile=smart -> prime cluster at 35%" - reading as Smart's cap.
# The REAL asbdiag block runs against a fake sysfs and the governor's msm_asb_hold/msm_asb.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL asbdiag msm owner: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
D="$ROOT/tools/asb_diag.sh"
grep -q 'fprintf(f, "msm_asb_hold=%d\\nmsm_asb=%d,%d,%d\\n", g_msm_holding ? 1 : 0,' "$ROOT/src/asb_governor.c" || fail "the governor does not publish what it holds in msm_performance"
awk '/^if \[ -r \/sys\/kernel\/msm_performance\/parameters\/cpu_max_freq \]; then$/ { b = 1 } b { print } b && /^fi$/ { exit }' "$D" > "$T/blk.sh"
[ -s "$T/blk.sh" ] || fail "block not found"
sed -i "s#/sys/kernel/msm_performance/parameters/cpu_max_freq#$T/msm#g; s#/sys/devices/system/cpu/cpufreq#$T/cpufreq#g; s#/dev/.asb/state#$T/state#g" "$T/blk.sh"
mkdir -p "$T/cpufreq/policy0" "$T/cpufreq/policy6"
echo '0 1 2 3 4 5' > "$T/cpufreq/policy0/related_cpus"; echo 3628800 > "$T/cpufreq/policy0/cpuinfo_max_freq"
echo '6 7' > "$T/cpufreq/policy6/related_cpus"; echo 4608000 > "$T/cpufreq/policy6/cpuinfo_max_freq"
run() { printf '%s\n' "$1" > "$T/msm"; printf '%b' "$2" > "$T/state"; ( P() { echo "$*"; }; . "$T/blk.sh" ); }
out="$(run '0:2227200 1:2227200 2:2227200 3:2227200 4:2227200 5:2227200 6:1632000 7:1632000' 'msm_asb_hold=0\nmsm_asb=3628800,4608000,0\n')"
printf '%s\n' "$out" | grep -q "NOT ASB's: .*cpu0 2227200, cpu6 1632000" || fail "a vendor ceiling not named as such: $out"
out="$(run '0:1996800 1:1996800 2:1996800 3:1996800 4:1996800 5:1996800 6:1862400 7:1862400' 'msm_asb_hold=1\nmsm_asb=1996800,1862400,0\n')"
printf '%s\n' "$out" | grep -q "ASB's own HEAVY/GAMING registration" || fail "ASB's registration not recognised: $out"
out="$(run '0:1996800 6:1862400' 'msm_asb_hold=0\nmsm_asb=1996800,1862400,0\n')"
printf '%s\n' "$out" | grep -q "still in the node" || fail "a release that did not land is blamed on the vendor: $out"
out="$(run '0:3628800 1:3628800 6:4608000 7:4608000' 'msm_asb_hold=0\n')"
printf '%s\n' "$out" | grep -q "no ceiling held there" || fail "hardware maximum read as a ceiling: $out"
out="$(run '0:2227200 6:1632000' '')"
printf '%s\n' "$out" | grep -q "unknown" || fail "an older governor's state is not admitted as unknown: $out"
grep -q 'below the ${_prime_req} kHz ASB wrote' "$D" || fail "section 7 still credits a foreign ceiling to the profile"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS asbdiag msm owner: msm_performance's ceilings are named as ASB's, left behind, or the vendor's"
)

t_native_crash_names_runtime() (
# Runtime (fix141): asbdiag and the full-day report name the processes behind native crashes
# and say when ASB code is in one - the crashed process or the crashing thread's backtrace,
# not the memory map (every audio HAL maps libasbdsp, whatever crashed it).
#
# The 22:45 OP15 asbdiag: "dropbox SYSTEM_TOMBSTONE : 18 (latest 22:45:25)" and nothing else.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL native crash names: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
D="$T/tomb"; mkdir -p "$D"
tomb() {   # $1 file  $2 cmdline  $3 frame library
  cat > "$D/$1" <<X
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
Build fingerprint: 'OnePlus/CPH2745IN/OP611FL1:16/x:user/release-keys'
Timestamp: 2026-10-12 22:45:25.123456789+0200
Process uptime: 3s
Cmdline: $2
pid: 1234, tid: 1240, name: HwBinder:1234_2  >>> $2 <<<
uid: 1041
signal 6 (SIGABRT), code -1 (SI_QUEUE), fault addr --------
Abort message: 'FORTIFY: pthread_mutex_lock called on a destroyed mutex'

backtrace:
      #00 pc 0000000000061f0c  /apex/com.android.runtime/lib64/bionic/libc.so (abort+164)
      #01 pc 0000000000012345  $3

memory map (2 entries):
    7a00000000-7a00010000 r-xp  /vendor/lib64/soundfx/libasbdsp.so
    7b00000000-7b00010000 r-xp  /apex/com.android.runtime/lib64/bionic/libc.so
X
}
tomb tombstone_00 /vendor/bin/hw/audiohalservice.qti /vendor/lib64/libaudioroute.so
tomb tombstone_01 /vendor/bin/hw/audiohalservice.qti '/vendor/lib64/soundfx/libasbdsp.so (asb_core_process_f32+88)'
tomb tombstone_02 /data/adb/asb/asb_dsp_attach /system/lib64/libaudioclient.so
true > "$D/tombstone_00.pb"
touch -d '2026-10-12 22:40:00' "$D/tombstone_00"; touch -d '2026-10-12 22:41:00' "$D/tombstone_01"; touch -d '2026-10-12 22:42:00' "$D/tombstone_02"

# asbdiag: the real function, with its print helpers stubbed.
sed -n '/^_asb_tombstones() {$/,/^}$/p' "$ROOT/tools/asb_diag.sh" > "$T/fn.sh"
grep -q '_asb_tombstones' "$T/fn.sh" || fail "function not found in asbdiag"
out="$(P() { echo "$*"; }; NOTE() { echo "NOTE $*"; }; . "$T/fn.sh"; ASB_TOMBSTONE_DIR="$D" _asb_tombstones)"
printf '%s\n' "$out" | grep -q 'audiohalservice.qti  signal 6 (SIGABRT)$' || fail "unrelated audio HAL crash not listed plainly: $out"
[ "$(printf '%s\n' "$out" | grep -c '<< ASB code in this crash')" = 2 ] || fail "ASB crashes not told apart from the memory map: $out"
printf '%s\n' "$out" | grep -q 'asb_dsp_attach .*<< ASB code' || fail "a crash of the attach daemon not flagged: $out"
printf '%s\n' "$out" | grep -q "Abort message: 'FORTIFY" || fail "abort message missing"
printf '%s\n' "$out" | grep -q '^NOTE 2 of these crashes have ASB code' || fail "summary missing: $out"
printf '%s\n' "$out" | grep -q 'pb' && fail "a .pb tombstone listed"
# fix142: whose code asked for the abort, and one message in many processes read as one cause.
printf '%s\n' "$out" | grep -q 'first frame outside libc: /vendor/lib64/libaudioroute.so$' || fail "first non-libc frame not named: $out"
printf '%s\n' "$out" | grep -q 'first frame outside libc: /vendor/lib64/soundfx/libasbdsp.so (asb_core_process_f32+88)' || fail "frame function not kept: $out"
printf '%s\n' "$out" | grep -q '^NOTE 3 of the listed crashes end with the same abort message' || fail "same abort not grouped: $out"
printf '%s\n' "$out" | grep -q 'start in code of' && fail "an injected-module note without one: $out"
# fix178: a hook module's code inside a system process is named (a CPH2691: LuckyTool's
# libdexkit.so first in eight com.oplus.battery / com.oplus.ota aborts).
D2="$T/tomb2"; mkdir -p "$D2"; _keep="$D"; D="$D2"
_lt='/data/app/~~YGeVTP2n1kPkEgS4384O3Q==/com.luckyzyx.luckytool-aI8mTJHJqW11-BdKHZEvyQ==/base.apk!libdexkit.so (offset 0x1d4000)'
tomb tombstone_00 com.oplus.battery "$_lt"
tomb tombstone_01 com.oplus.ota "$_lt"
tomb tombstone_02 com.example.app '/data/app/~~abc==/com.example.app-xyz==/base.apk!libown.so'
# fix188: WebView is loaded by every app with a web page - an OP15 com.booking crash in it was
# reported as a hook module to switch off.
tomb tombstone_03 com.booking '/data/app/~~GF2kHWKKkBSh4mNzquh6mQ==/com.google.android.webview-jJs3KMob7bK15eAP5Kkmlw==/base.apk!libwebviewchromium.so'
D="$_keep"
out="$(P() { echo "$*"; }; NOTE() { echo "NOTE $*"; }; . "$T/fn.sh"; ASB_TOMBSTONE_DIR="$D2" _asb_tombstones)"
printf '%s\n' "$out" | grep -q '^NOTE 2 of the listed crashes start in code of com.luckyzyx.luckytool, loaded into another app' || fail "injected module not named: $out"
printf '%s\n' "$out" | grep -q 'code of com.example.app' && fail "an app crashing in its own code was called injected: $out"
printf '%s\n' "$out" | grep -q 'code of com.google.android.webview' && fail "WebView called a hook module: $out"
printf '%s\n' "$out" | grep -q '^NOTE 1 of the listed crashes are in Android System WebView, inside com.booking - shared browser code' || fail "WebView crash not named as such: $out"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"

# Full-day report: only tombstones newer than the capture start.
out="$( (set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$ROOT/tools/logkit/_asb_logkit_common.sh" >/dev/null 2>&1
         LK_START_EPOCH="$(date -d '2026-10-12 22:40:30' +%s)" ASB_TOMBSTONE_DIR="$D" lk_emit_native_crashes) )"
# libasbdsp may appear only as the crashing frame of the one crash it is in, never from a map.
[ "$(printf '%s\n' "$out" | grep -c 'libasbdsp')" = 1 ] || fail "memory-map library leaked into the report: $out"
[ "$(printf '%s\n' "$out" | grep -c '^  [0-9]')" = 2 ] || fail "capture window not applied: $out"
printf '%s\n' "$out" | grep -q '^2 of them with ASB code in the crash' || fail "report summary missing: $out"
printf '%s\n' "$out" | grep -q 'first frame outside libc: /system/lib64/libaudioclient.so' || fail "report does not name the frame: $out"
grep -q '^    lk_emit_native_crashes$' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "report does not include the section"
echo "PASS native crash names: crashed processes named, ASB code told apart from the memory map"
)

t_native_werror_gate() (
# Native build gate: the governor must compile cleanly with -O2 -Wall -Wextra -Werror.
#
# Without -Werror the build always passed, so warnings could accumulate unnoticed; an
# external audit found 16 (unused parameters, devfreq path truncation, strncpy). They are
# fixed, and this gate keeps them from coming back. Skipped when no C compiler is present.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC_BIN="${CC:-}"
[ -n "$CC_BIN" ] || for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC_BIN="$c"; break; }; done
if [ -z "$CC_BIN" ]; then echo "SKIP native -Werror gate (no C compiler)"; exit 0; fi
TMP="$(mktemp)"; trap 'rm -f "$TMP" "$TMP.o"' EXIT
if ! "$CC_BIN" -O2 -Wall -Wextra -Werror -I"$ROOT/src" -c "$ROOT/src/asb_governor.c" -o "$TMP.o" >"$TMP" 2>&1; then
  echo "FAIL native -Werror gate:"; head -20 "$TMP"; exit 1
fi
echo "PASS native -Werror gate ($CC_BIN -O2 -Wall -Wextra -Werror)"
)

t_odm_bind_reinstall_runtime() (
# Runtime (fix146): an install over a running module keeps its /odm runtime binds.
#
# PLQ110 (Ace 6, non-reference): "effects config WITHOUT ASB: /odm/etc/audio_effects_config.xml",
# "library mapped into the audio HAL: absent", no "odm-side audio/media" line in the install
# log. The generator's reset ran after the audio stage and deleted the effects-config bind
# the DSP registration had just queued; its own copy of the live file - after an update, the
# previous install's bind - was then dropped as "identical to the live file". Each install
# over a running module lost every /odm audio bind, and the next one restored them.
# The REAL install functions run here on fake /odm paths, a fake mountinfo and stub patchers.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
I="$ROOT/common/install.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL odm bind reinstall: $*" >&2; fail=1; }

: > "$T/fns.sh"
for fn in asb_reset_odm_binds asb_odm_fingerprint asb_odm_bound_by_asb asb_generate_odm_binds asb_bind_register_odm_effects; do
  awk -v n="$fn" '$0 ~ "^" n "\\(\\) \\{" { f = 1 } f { print } f && /^}/ { exit }' "$I" >> "$T/fns.sh"
  grep -q "^$fn() {" "$T/fns.sh" || { echo "FAIL odm bind reinstall: $fn not found in install.sh" >&2; exit 1; }
done

L="$T/live"; P="$T/patched"; M="$T/man"; MI="$T/mountinfo"
mkdir -p "$L/odm/etc/audio" "$L/odm/etc/camera"
stock() {
  printf '<audioPolicyConfiguration rates="48000"/>\n' > "$L/odm/etc/audio/audio_policy_configuration.xml"
  printf '<mixer>\n<ctl name="RX Digital Volume" value="84"/>\n</mixer>\n' > "$L/odm/etc/mixer_paths.xml"
  printf '<audio_effects_conf>\n<libraries>\n</libraries>\n<effects>\n</effects>\n</audio_effects_conf>\n' > "$L/odm/etc/audio_effects_config.xml"
  printf '<MediaSettings unchanged="1"/>\n' > "$L/odm/etc/media_profiles_V1_0.xml"
}
cat > "$T/stubs.sh" <<'X'
ui_print() { echo "$*" >> "$UILOG"; }
getprop() { case "$1" in ro.odm.build.fingerprint) printf '%s\n' "$FP" ;; esac; }
chcon() { :; }
asb_lift_hires_policy() { sed -i 's/rates="48000"/rates="48000,96000,192000"/' "$1"; }
asb_patch_one_mixer() { sed -i 's/value="84"/value="88"/' "$1"; }
asb_media_lift_file() { :; }
asb_audio_ensure_volume_libs() { :; }
asb_register_dsp_effect() { sed -i '/asb_loudness/d' "$1"; sed -i 's#</effects>#<effect name="asb_loudness" library="asbdsp"/>\n</effects>#' "$1"; }
X
run() {   # one install: reset, the audio stage's DSP registration, the generator
  : > "$T/ui"
  UILOG="$T/ui" FP="$1" ASB_AUDIO=true ASB_MEDIA=true ASB_ODM_PATCHED="$P" ASB_ODM_MAN="$M" \
  ASB_ODM_LIVE_PREFIX="$L" ASB_ODM_MOUNTINFO="$MI" sh -c '
    . "$1"; . "$2"
    asb_reset_odm_binds
    asb_bind_register_odm_effects /odm/etc/audio_effects_config.xml >/dev/null
    asb_generate_odm_binds' x "$T/stubs.sh" "$T/fns.sh"
}
# The boot after an install: the rebind puts each payload in front of its target.
boot() {
  : > "$MI"
  while IFS='|' read -r _t _p; do
    [ -n "$_t" ] || continue
    cp -f "$_p" "$L$_t"
    printf '100 50 254:79 /adb/asb/odm_patched%s %s rw - f2fs /dev/block/dm-79 rw\n' "$_t" "$_t" >> "$MI"
  done < "$M"
}
queued() { grep -q "^$1|" "$M" 2>/dev/null; }

# 1. A first install over stock /odm.
stock; : > "$MI"; run FP1
queued /odm/etc/audio_effects_config.xml || f "fresh install: effects config not queued: $(cat "$M" 2>/dev/null)"
queued /odm/etc/mixer_paths.xml || f "fresh install: mixer not queued"
queued /odm/etc/audio/audio_policy_configuration.xml || f "fresh install: audio policy not queued"
queued /odm/etc/media_profiles_V1_0.xml && f "a file the patch left unchanged was queued"
[ "$(grep -c '^/odm/etc/audio_effects_config.xml|' "$M")" = 1 ] || f "effects config queued twice"
grep -q 'odm-side audio/media: 2 file(s) patched' "$T/ui" || f "install line: $(cat "$T/ui")"
grep -q 'value="84"' "$P/odm/etc/mixer_paths.xml.stock" || f "no stock snapshot of the mixer"
p1="$(cat "$P/odm/etc/mixer_paths.xml")"

# 2. Reboot, then install again over the running module - the case that lost every bind.
boot; run FP1
queued /odm/etc/audio_effects_config.xml || f "reinstall: effects config bind lost (the PLQ110 DSP): $(cat "$M" 2>/dev/null)"
queued /odm/etc/mixer_paths.xml || f "reinstall: mixer bind lost"
queued /odm/etc/audio/audio_policy_configuration.xml || f "reinstall: audio policy bind lost"
[ "$(cat "$P/odm/etc/mixer_paths.xml")" = "$p1" ] || f "reinstall: mixer payload not built from the stock snapshot"
grep -q 'value="84"' "$P/odm/etc/mixer_paths.xml.stock" || f "reinstall: stock snapshot overwritten by the bound copy"
[ "$(grep -c asb_loudness "$P/odm/etc/audio_effects_config.xml")" = 1 ] || f "reinstall: effects payload without exactly one ASB effect"
# and a third time
boot; run FP1
queued /odm/etc/audio_effects_config.xml && queued /odm/etc/mixer_paths.xml || f "third install lost a bind: $(cat "$M" 2>/dev/null)"

# 3. A device installed by a build before fix146: bound, no stock snapshot.
boot; rm -f "$P"/odm/etc/*.stock "$P"/odm/etc/audio/*.stock "$P/.base_fp"
run FP1
queued /odm/etc/mixer_paths.xml || f "pre-fix146 device: mixer bind lost"
[ "$(cat "$P/odm/etc/mixer_paths.xml")" = "$p1" ] || f "pre-fix146 device: re-patching the bound copy is not idempotent"
[ -e "$P/odm/etc/mixer_paths.xml.stock" ] && f "pre-fix146 device: the bound copy was saved as the stock snapshot"

# 4. A system update with the binds in front: the generator's own files are held back once.
boot; run FP2
queued /odm/etc/mixer_paths.xml && f "after an update a stale base was queued"
grep -q 'changed with a system update' "$T/ui" || f "update not said: $(cat "$T/ui")"
queued /odm/etc/audio_effects_config.xml || f "after an update the DSP bind was dropped"
# The reboot shows the new stock; the next install snapshots and queues it again.
boot; stock; sed -i 's/value="84"/value="84" new="1"/' "$L/odm/etc/mixer_paths.xml"; : > "$MI"; run FP2
queued /odm/etc/mixer_paths.xml || f "after the update's reboot the mixer was not queued again"
grep -q 'new="1"' "$P/odm/etc/mixer_paths.xml" || f "the new stock was not the base"

# 5. /odm a link to /vendor/odm: the kernel records the resolved mount point.
rm -rf "$L" "$P" "$M"; mkdir -p "$L/vendor/odm/etc/audio" "$L/vendor/odm/etc/camera"; ln -s vendor/odm "$L/odm"
stock; : > "$MI"; run FP1
sed 's#^/odm/#/vendor/odm/#' "$M" > "$M.r"; mv "$M.r" "$M.v"
boot_v() { : > "$MI"; while IFS='|' read -r _t _p; do printf '100 50 254:79 /adb/asb/odm_patched%s %s rw - f2fs /dev/block/dm-79 rw\n' "${_t#/vendor}" "$_t" >> "$MI"; done < "$M.v"; }
for _t in /odm/etc/mixer_paths.xml /odm/etc/audio_effects_config.xml; do cp -f "$P$_t" "$L$_t"; done
boot_v; run FP1
queued /odm/etc/mixer_paths.xml || f "/odm as a link: the bind in front was not recognised and the mixer was dropped"

# 6. Wiring: the reset runs before the audio stage of the non-reference path.
awk '/asb_reset_odm_binds$/ { r = NR } /asb_apply_device_native_tuning "\$ASB_DEVICE_NAME" "OnePlus"/ { if (!a) a = NR } END { exit !(r && a && r < a) }' "$I" \
  || f "asb_reset_odm_binds is not called before the non-reference audio stage"
sed -n '/^asb_generate_odm_binds() {/,/^}/p' "$I" | grep -q 'rm -rf "\$_ob_root"' && f "the generator still wipes the payload directory"
sed -n '/^asb_generate_odm_binds() {/,/^}/p' "$I" | grep -q '/odm/etc/audio_effects_config.xml \\' && f "the generator still writes the effects config"

[ "$fail" = 0 ] && echo "PASS odm bind reinstall: binds survive an install over a running module, stock snapshots kept, updates handled"
exit "$fail"
)

t_odm_rebind_runtime() (
# Runtime: the /odm rebind judges every manifest line by what the path reads back after the
# bind, peels a stale layer in front of it once, and logs a verdict per target - the field
# case was "odm_bind_late result=applied" on a boot where neither camera file was live.
# mount/umount are stubbed: a bind copies the payload over the target and records a layer;
# a "shadow" target swallows binds until the layer on it is peeled; a "stuck" target
# swallows them for good.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL odm rebind: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/odm/camera" "$T/odm/audio" "$T/p"
S="$ROOT/runtime/asb_odm_rebind.sh"

cat > "$T/bin/mount" <<'X'
#!/bin/sh
[ "$1" = --bind ] || exit 1
p="$2"; t="$3"
echo "$t" >> "$CALLS"
[ -f "$t.stuck" ] && { echo "1 1 0:1 / $t rw - overlay KSU rw" >> "$MI"; exit 0; }
if [ -f "$t.shadow" ]; then echo "1 1 0:1 / $t rw - overlay KSU rw" >> "$MI"; exit 0; fi
cp "$t" "$t.under.$(grep -c " $t " "$MI")"
cp "$p" "$t"
echo "1 1 0:1 / $t rw - f2fs /dev/block/dm-50 rw" >> "$MI"
X
cat > "$T/bin/umount" <<'X'
#!/bin/sh
t="$1"
grep -q " $t " "$MI" || exit 1
rm -f "$t.shadow"
grep -v " $t " "$MI" > "$MI.n"; mv "$MI.n" "$MI"
exit 0
X
cat > "$T/bin/getprop" <<'X'
#!/bin/sh
printf '%s\n' '[init.svc.cameraserver]: [running]' '[init.svc.vendor.camera-provider]: [running]' '[init.svc.vendor.camera-provider-ext]: [stopped]'
X
cat > "$T/bin/setprop" <<'X'
#!/bin/sh
echo "$*" >> "$PROPS"
X
chmod +x "$T/bin/"*
export PROPS="$T/props" PATH="$T/bin:$PATH" CALLS="$T/calls" MI="$T/mi" ASB_ODM_NS=none \
       ASB_ODM_MAN="$T/man" ASB_ODM_LOG="$T/log" ASB_ODM_MOUNTINFO="$T/mi"
true > "$T/mi"; true > "$T/calls"

echo stock4 > "$T/odm/camera/vb";   echo apps19 > "$T/p/vb"
echo stockT > "$T/odm/camera/ct";   echo graded > "$T/p/ct"
echo same   > "$T/odm/audio/fx";   echo same   > "$T/p/fx"
echo stockM > "$T/odm/audio/mx";   echo patched > "$T/p/mx"
{
  echo "$T/odm/camera/vb|$T/p/vb"
  echo "$T/odm/camera/ct|$T/p/ct"
  echo "$T/odm/audio/fx|$T/p/fx"
} > "$T/man"
# ct has a stale layer in front that swallows the first bind.
touch "$T/odm/camera/ct.shadow"; echo "1 1 0:1 / $T/odm/camera/ct rw - overlay KSU rw" >> "$T/mi"

sh "$S" apply; rc=$?
[ "$(cat "$T/odm/camera/vb")" = apps19 ] || f "retouch list not bound"
[ "$(cat "$T/odm/camera/ct")" = graded ] || f "shadowed tone table not bound after peeling"
grep -q "target=$T/odm/camera/vb result=ok" "$T/log" || f "no ok verdict for vb: $(cat "$T/log")"
grep -q "target=$T/odm/camera/ct result=retry_ok" "$T/log" || f "no retry_ok verdict for ct"
grep -q "target=$T/odm/audio/fx result=already" "$T/log" || f "unchanged file not reported as already"
grep -q "$T/odm/audio/fx" "$T/calls" && f "mounted over a file that already read the payload"
[ "$rc" = 0 ] || f "camera-only change must not ask for an audioserver restart (rc=$rc)"

[ -s "$T/props" ] && f "camera stack restarted without being asked: $(cat "$T/props")"
# Boot asks for it: a newly bound camera file restarts the running provider + cameraserver.
echo stock9 > "$T/odm/camera/vb"; true > "$T/mi"; true > "$T/props"
ASB_ODM_RESTART_CAM=1 sh "$S" apply camera
grep -q '^ctl.restart vendor.camera-provider$' "$T/props" || f "provider not restarted after a new camera bind: $(cat "$T/props")"
grep -q '^ctl.restart cameraserver$' "$T/props" || f "cameraserver not restarted"
grep -q 'camera-provider-ext' "$T/props" && f "restarted a stopped service"
true > "$T/props"; ASB_ODM_RESTART_CAM=1 sh "$S" apply camera
[ -s "$T/props" ] && f "camera restarted although nothing changed"
# Payload sync: the bound payload follows the module's own (boot-graded) copy, in place,
# and a change under an existing bind still counts as a camera change.
mkdir -p "$T/odm/etc/camera" "$T/mod/odm/etc/camera" "$T/p/odm/etc/camera"
echo '{ "BlendWeight": [0.35, 0.5, 0.7] }' > "$T/odm/etc/camera/tune"
echo '{ "BlendWeight": [0.35, 0.5, 0.7] }' > "$T/p/odm/etc/camera/tune"
echo '{ "BlendWeight": [1, 1, 1] }' > "$T/mod/odm/etc/camera/tune"
cp "$T/man" "$T/man.keep"
echo "$T/odm/etc/camera/tune|$T/p/odm/etc/camera/tune" > "$T/man"
# Simulate "already bound": the stub's mount copies, so bind once and then change the module copy.
ASB_ODM_MODDIR="$T/mod" sh "$S" apply camera
grep -q 'BlendWeight": \[1, 1, 1\]' "$T/p/odm/etc/camera/tune" || f "payload not synced from the module copy"
grep -q 'BlendWeight": \[1, 1, 1\]' "$T/odm/etc/camera/tune" || f "synced payload not live"
grep -q "action=odm_payload_sync target=$T/odm/etc/camera/tune result=updated" "$T/log" || f "payload sync not logged"
echo '{ "BlendWeight": [0.9, 0.9, 0.9] }' > "$T/mod/odm/etc/camera/tune"
cp "$T/mod/odm/etc/camera/tune" "$T/odm/etc/camera/tune"   # in-place payload = live bind content
true > "$T/props"
ASB_ODM_MODDIR="$T/mod" ASB_ODM_RESTART_CAM=1 sh "$S" apply camera
grep -q 'ctl.restart cameraserver' "$T/props" || f "a payload rewritten under a live bind did not restart the camera stack"
echo '{ "broken": [' > "$T/mod/odm/etc/camera/tune"
ASB_ODM_MODDIR="$T/mod" sh "$S" apply camera
grep -q '0.9, 0.9, 0.9' "$T/p/odm/etc/camera/tune" || f "an unbalanced module copy replaced the payload"
grep -q 'result=rejected_unbalanced' "$T/log" || f "unbalanced copy not reported"
# A module copy with whole-line // comments reaches the payload stripped.
mkdir -p "$T/mod/odm/etc/camera/config" "$T/p/odm/etc/camera/config" "$T/odm/etc/camera/config"
printf '{\n// vendor note\n"a": 1\n}\n' > "$T/mod/odm/etc/camera/config/vb"
echo '{ "a": 0 }' > "$T/p/odm/etc/camera/config/vb"; echo '{ "a": 0 }' > "$T/odm/etc/camera/config/vb"
echo "$T/odm/etc/camera/config/vb|$T/p/odm/etc/camera/config/vb" > "$T/man"
ASB_ODM_MODDIR="$T/mod" sh "$S" apply camera
grep -q '//' "$T/p/odm/etc/camera/config/vb" && f "comments copied into the payload"
grep -q '"a": 1' "$T/p/odm/etc/camera/config/vb" || f "commented module copy not synced"
ls "$T/p/odm/etc/camera/config/" | grep -q 'sync\.' && f "sync temp file left behind"
grep -Fq 'find "$MODPATH/odm" "$MODPATH/system" "$MODPATH/deferred_overlay"' "$ROOT/common/install.sh" \
  || f "installer does not strip comments from the module-root camera copy"
mv "$T/man.keep" "$T/man"
# Second run: everything live, nothing mounted.
true > "$T/calls"
sh "$S" apply
[ -s "$T/calls" ] && f "re-run mounted again over live files: $(cat "$T/calls")"

# An audio file change asks for the audioserver restart (exit 10); camera scope skips it.
echo "$T/odm/audio/mx|$T/p/mx" >> "$T/man"
sh "$S" apply camera
[ "$(cat "$T/odm/audio/mx")" = stockM ] || f "camera scope touched an audio file"
sh "$S" apply; rc=$?
[ "$rc" = 10 ] || f "audio change did not return 10 (rc=$rc)"

# A layer that never yields: reported as hidden with its mountinfo, not as applied.
echo stockZ > "$T/odm/camera/zz"; echo want > "$T/p/zz"; touch "$T/odm/camera/zz.stuck"
echo "$T/odm/camera/zz|$T/p/zz" >> "$T/man"
true > "$T/log"
sh "$S" apply camera
grep -q "target=$T/odm/camera/zz result=hidden mountinfo=.*overlay" "$T/log" || f "stuck layer not reported hidden: $(cat "$T/log")"
grep -q "result=incomplete" "$T/log" || f "incomplete pass not summarised"
grep -q "result=applied" "$T/log" && f "a pass with nothing newly bound claimed applied"

# Missing payload.
echo "$T/odm/camera/vb|$T/p/nope" >> "$T/man"
true > "$T/log"; sh "$S" apply camera
grep -q "target=$T/odm/camera/vb result=missing" "$T/log" || f "missing payload not reported"

# status
st="$(sh "$S" status)"
echo "$st" | grep -q "$T/odm/camera/vb state=live" || f "status: vb should be live: $st"
echo "$st" | grep -q "$T/odm/camera/zz state=NOT_LIVE mounted=yes" || f "status: zz should be NOT_LIVE: $st"

# Wiring: boot uses it (with a later camera pass), action self-heals, install queues always.
grep -q 'asb_odm_rebind.sh" apply' "$ROOT/service.sh" || f "service.sh does not use the checked rebind"
grep -q 'asb_odm_rebind.sh" apply camera' "$ROOT/service.sh" || f "no second camera pass at boot"
grep -q 'asb_odm_rebind.sh" apply camera' "$ROOT/action.sh" || f "action does not self-heal the camera bind"
grep -q 'odm_bind_late result=applied" >>' "$ROOT/service.sh" && f "service.sh still logs applied on any mount rc"
sed -n '/^asb_generate_odm_camera_binds()/,/^}/p' "$ROOT/common/install.sh" | grep -q 'cmp -s' \
  && f "install still skips a camera bind on a live-file comparison"
grep -q 'runtime/asb_odm_rebind.sh' "$ROOT/.github/workflows/build-release.yml" || f "release workflow misses the script"

# Verdicts read the camera files through init's namespace (where the HAL reads them).
grep -q '_c_bw="$(_camg ' "$ROOT/action.sh" || f "action judges the tone table in its own namespace"
grep -q '_vb_try_n="$(_camg ' "$ROOT/action.sh" || f "action counts retouch apps in its own namespace"
grep -q 'nsenter -t 1 -m -- cat "$CT"' "$ROOT/tools/asb_diag.sh" || f "asbdiag judges the tone table in its own namespace"
grep -q 'nsenter -t 1 -m -- cat \$_f' "$ROOT/webroot/index.html" || f "WebUI camera badge reads its own namespace"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "system/bin/asbdiag out of sync"

[ "$fail" = 0 ] && echo "PASS odm rebind runtime"
exit "$fail"
)

t_prime_escape_gates_runtime() (
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
)

t_quiet_night_behaviour() (
# Quiet Night skip decision as behaviour: the metrics-skip flag is clear on the tick after the mode ends.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CCX="${HOST_CC:-${CC:-}}"
[ -n "$CCX" ] || for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && { CCX="$c"; break; }; done
[ -n "$CCX" ] || { echo "FAIL quiet_night_behaviour: no host C compiler" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_c_quiet_night_behaviour > "$T/t.c"
"$CCX" -O2 "$T/t.c" -o "$T/t"
"$T/t"
)

t_quiet_night_skip() (
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
python3 - "$ROOT" <<'ASB_PY_EOF'
"""Quiet Night must never leave the metrics-skip flag set after the mode ends.

The first implementation cleared the flag in the else branch of the "is this a skipping
tick" test, which sits inside `if (g_quiet_night_active)`. So the reset only ran while the
mode was still active: if Quiet Night ended on a skipping tick, the flag stayed set and
metrics_read_battery() returned immediately for the rest of the session.

That is worse than the economy it buys. Current, voltage, temperature and level feed
auto-battery switching, charge awareness, the drain the learner banks and the
time-to-empty estimates - all of which would silently run on values read hours earlier.

This test reads the source rather than running the daemon, because the bug is structural:
it is about WHERE the reset lives, and that is exactly what a behavioural test on a
short run would miss.
"""
import re
import sys
import pathlib

SRC = pathlib.Path(sys.argv[1]) / "src" / "asb_governor.c"


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def main():
    text = SRC.read_text(encoding="utf-8", errors="replace")

    if "g_qn_skip_this_tick" not in text:
        print("SKIP: Quiet Night skip flag not present in this build")
        return

    # Per-tick resets only. `int g_qn_skip_this_tick = 0;` is the definition, not a
    # reset - counting it made the first version of this test pass against the very bug it
    # was written for, because a definition at the top of the file is trivially "before
    # the guard".The check is done on the whole line: a definition carries a type, a reset
    # does not.
    reset = []
    for m in re.finditer(r"g_qn_skip_this_tick\s*=\s*0\s*;", text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        line = text[line_start:m.end()]
        if re.match(r"\s*(static\s+)?int\s+", line):
            continue          # definition
        reset.append(m.start())

    setit = [m.start() for m in re.finditer(r"g_qn_skip_this_tick\s*=\s*1\s*;", text)]

    if not reset:
        fail("the flag is set but never cleared - it would stay on for the whole session")
    if not setit:
        fail("the flag is cleared but never set - Quiet Night saves nothing")

    # The relevant guard is the one that owns the skip flag, not the first
    # `if (g_quiet_night_active)` in the file - there are three, and anchoring on the
    # wrong one made this test report a failure on correct code. Locate it by the line
    # that sets the flag and walk back.
    set_pos = setit[0]
    guard = text.rfind("if (g_quiet_night_active)", 0, set_pos)
    if guard < 0:
        fail("cannot locate the Quiet Night guard that owns the skip flag")

    # The reset must belong to THIS block, not merely appear earlier in the file.
    #
    # The first version asked only `any(pos < guard)`, which a mutation defeats trivially:
    # delete the real per-tick reset, add a meaningless one next to the global definition,
    # and the test still passes while the bug is fully restored. File order is not
    # ownership.
    #
    # Scope is bounded by the enclosing metrics block. Anything outside it is in a
    # different control-flow path and cannot clear the flag on the ticks that matter -
    # the ones after Quiet Night has ended.
    block_start = text.rfind("if (need_metrics)", 0, guard)
    if block_start < 0:
        block_start = text.rfind("\n\n", 0, guard)

    local = [pos for pos in reset if block_start < pos < guard]
    if len(local) != 1:
        fail("expected exactly one per-tick reset between the metrics block and the "
             "Quiet Night guard, found %d - a reset elsewhere in the file does not run "
             "on the ticks after the mode ends" % len(local))

    # And nothing may close a scope between the reset and the guard: a reset that sits
    # inside a brace that ends before the guard is in a different block again.
    between = text[local[0]:guard]
    if between.count("}") > between.count("{"):
        fail("the reset is separated from the guard by a closing brace - it is in a "
             "different scope and will not run every tick")

    if any(pos < guard for pos in setit):
        fail("the flag is set outside the Quiet Night guard - reads would be skipped "
             "during normal operation")

    print("PASS: skip flag is cleared unconditionally before the Quiet Night guard")


if __name__ == "__main__":
    main()
ASB_PY_EOF
)

t_service_thermal_vm_contract() (
# Regression guard for ASB-03 and ASB-05 service-side contracts.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE="$ROOT/service.sh"

fail() { printf '%s\n' "FAIL: $*" >&2; exit 1; }
need() { grep -Fq "$1" "$SERVICE" || fail "missing: $1"; }

# Stock thermal must read the paired type file and only resolve a passive trip as
# an active control value. Active data remains explicit diagnostics, not policy.
need '_typef="${_base}_type"'
need 'case "$_tt" in'
need 'passive)'
need 'SOURCE=passive_trip_point'
need 'SOURCE=active_fallback'
need 'SOURCE=none'
need 'no passive stock trip'

# VM_PAGE_CLUSTER is declared by the selected profile. service.sh must not reapply
# old hard-coded per-profile values after profile_core.sh has set the profile value.
need 'VM_PAGE_CLUSTER belongs to the selected profile'
need 'writef_retry /proc/sys/vm/page-cluster "$VM_PAGE_CLUSTER"'
if grep -Eq 'page-cluster[[:space:]]+(0|1|3)[[:space:]]+1[[:space:]]+0' "$SERVICE"; then
  fail 'legacy hard-coded page-cluster write remains in service.sh'
fi

# The boot-only compatibility audio path must match the validated live path. 255 is outside
# the documented resampler enum and is silently rejected on current OPlus stacks.
need 'setprop af.resampler.quality 0 2>/dev/null || true'
if grep -Fq 'setprop af.resampler.quality 255' "$SERVICE"; then
  fail 'legacy audio writer still sets unsupported resampler value 255'
fi

printf '%s\n' 'PASS service thermal/vm contract'
)

t_smart_night_awake_runtime() (
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
)

t_smart_reset_complete_contract() (
# Contract: "reset Smart learning" clears every persisted policy input, not only buckets.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RESET="$ROOT/runtime/asb_smart_reset.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"; STATE="$TMP/state"; RUNTIME="$TMP/runtime"; VOL="$TMP/volatile/learner_state.json"
mkdir -p "$MOD/runtime" "$STATE" "$RUNTIME" "$(dirname "$VOL")"
printf 'user-config-must-survive\n' > "$MOD/config.keep"
printf 'baseline-must-survive\n' > "$STATE/baseline.txt"
for f in buckets.bin buckets.bin.bak smart_appheat.bin smart_records.bin smart_prev_profile night_window.conf session_history.jsonl; do
  printf 'learned:%s\n' "$f" > "$STATE/$f"
done
for f in session_stats.json pstats_battery.json pstats_balanced.json pstats_performance.json session_history.jsonl; do
  printf 'aggregate:%s\n' "$f" > "$RUNTIME/$f"
done
printf 'volatile learning\n' > "$VOL"

OUT="$(MODDIR="$MOD" ASB_SMART_STATE="$STATE" ASB_RUNTIME_STATE="$RUNTIME" ASB_SMART_VOLATILE_STATE="$VOL" sh "$RESET")"
printf '%s\n' "$OUT" | grep -Fq 'session history and learned stats are cleared' || { echo 'FAIL smart reset: outcome message missing' >&2; exit 1; }
for f in buckets.bin buckets.bin.bak smart_appheat.bin smart_records.bin smart_prev_profile night_window.conf session_history.jsonl; do
  [ ! -e "$STATE/$f" ] || { echo "FAIL smart reset: retained state/$f" >&2; exit 1; }
done
for f in session_stats.json pstats_battery.json pstats_balanced.json pstats_performance.json session_history.jsonl; do
  [ ! -e "$RUNTIME/$f" ] || { echo "FAIL smart reset: retained runtime/$f" >&2; exit 1; }
done
[ ! -e "$VOL" ] || { echo 'FAIL smart reset: retained volatile learner state' >&2; exit 1; }
grep -Fqx 'user-config-must-survive' "$MOD/config.keep" || { echo 'FAIL smart reset: changed user config' >&2; exit 1; }
grep -Fqx 'baseline-must-survive' "$STATE/baseline.txt" || { echo 'FAIL smart reset: changed baseline' >&2; exit 1; }
echo 'PASS complete Smart reset contract'
)

t_smart_session2() (
# smart_session2 — build and run Session unit tests
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="/tmp/asb_test_smart_session2.c"
_c_smart_session2 > "$SRC"
BIN="/tmp/asb_test_smart_session2"

CC="${CC:-cc}"
CFLAGS="-Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function -I${ROOT_DIR}/src -D_GNU_SOURCE"

echo "Building Session unit tests..."
"$CC" $CFLAGS "$SRC" -o "$BIN"

echo "Running..."
"$BIN"
RC=$?

rm -f "$BIN" "$SRC"
exit "$RC"
)

t_smart_session3() (
# smart_session3 — build and run Session unit tests
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="/tmp/asb_test_smart_session3.c"
_c_smart_session3 > "$SRC"
BIN="/tmp/asb_test_smart_session3"

CC="${CC:-cc}"
CFLAGS="-Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function -I${ROOT_DIR}/src -D_GNU_SOURCE"

echo "Building Session unit tests..."
"$CC" $CFLAGS "$SRC" -o "$BIN"

echo "Running..."
"$BIN"
RC=$?

rm -f "$BIN" "$SRC"
exit "$RC"
)

t_smart_trend_cool_runtime() (
# Runtime (fix160): Smart no longer cuts the ceilings by a third on a fast thermal trend while the
# body is cool, and a ceiling ASB asked for itself is no longer counted as a vendor raise.
#
# Owner's OP15, capture 31599: every thermal-trend trim in the captured log tails came at a skin
# of 28-31 C with the HAL headroom at 83-100% - "trim=34 stage=3 reason=thermal_trend_fast
# skin=28 trend=20" - and read "cool" 30-60 s later. The trend sums rises of the hottest CPU
# sensor, which follows load: an app launch or camera start is enough. The trend now needs the
# skin within 8 C of thermal_skin_c (the band the light headroom stage already uses).
# The same day's action screen said the ROM raised the CPU ceiling above ASB's in 100 checks and
# the clock ran above it in 59; both log lines behind it carried "req 3648000" - the 80% unlock
# lift ASB itself had written. The REAL helpers are cut out of asb_governor.c and run on those
# numbers.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL smart trend cool: $*" >&2; exit 1; }
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "SKIP smart trend cool: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^static int asb_trend_body_cool(/,/^}/p' "$G" > "$T/h.c"
sed -n '/^enum { ASB_CEIL_OVER_NONE/,/^}/p' "$G" >> "$T/h.c"
grep -q 'asb_trend_body_cool' "$T/h.c" && grep -q 'asb_ceiling_over_kind' "$T/h.c" || fail "helpers not found"
_gate="$(grep -n 'asb_trend_body_cool(m->therm.temp_valid, m->therm.skin_temp_c, g_asb_cfg.thermal_skin_c)' "$G" | cut -d: -f1)"
_fast="$(grep -n '"thermal_trend_fast");' "$G" | cut -d: -f1)"
_mark="$(grep -n 'int _trend_warm = (!m->therm.temp_valid) || m->therm.cpu_max_c >= _trend_mark;' "$G" | cut -d: -f1)"
[ -n "$_gate" ] && [ -n "$_fast" ] && [ -n "$_mark" ] || fail "trend gate not wired"
[ "$_mark" -lt "$_gate" ] && [ "$_gate" -lt "$_fast" ] || fail "the cool-body gate is not between the warm mark and the trend trims"
grep -q 'int leak0 = (k0 == ASB_CEIL_OVER_VENDOR);' "$G" || fail "vendor leak still counts ASB's own requests"
grep -q 'int req_p1 = g_write_health\[ASB_WRITE_CPU_MAX0 + 1\].requested;' "$G" && grep -q 'asb_ceiling_over_kind(actual_p1, want_p1, req_p1)' "$G" || fail "prime classification does not read the writer's request"
grep -q 'own_ceiling_ticks=%lu' "$G" || fail "own lifts not published"
grep -q 'trend_trim_held_cool=%lu' "$G" || fail "held trend trims not published"
grep -q 'own_ceiling_ticks' "$ROOT/tools/asb_diag.sh" && grep -q 'trend_trim_held_cool' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show them"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include "h.c"
static int bad;
static void chk(int c, const char *m) { if (!c) { printf("FAIL %s\n", m); bad++; } }
int main(void) {
    chk(asb_trend_body_cool(1, 28, 47) == 1, "skin 28 C with a 47 C limit is cool (17:48:52 trim)");
    chk(asb_trend_body_cool(1, 31, 47) == 1, "skin 31 C is cool (16:58:44 and 19:04:25 trims)");
    chk(asb_trend_body_cool(1, 38, 47) == 1, "skin 38 C is still under the pre-lean band");
    chk(asb_trend_body_cool(1, 39, 47) == 0, "skin 39 C is in the band - the trend counts");
    chk(asb_trend_body_cool(1, 44, 47) == 0, "a warm body keeps the trend trim");
    chk(asb_trend_body_cool(0, 28, 47) == 0, "no valid reading keeps the old trend-only behaviour");
    chk(asb_trend_body_cool(1, 0, 47) == 0, "no skin sensor keeps the old behaviour");
    chk(asb_trend_body_cool(1, 85, 47) == 0, "an implausible skin reading is not taken as cool");
    chk(asb_trend_body_cool(1, 28, 0) == 0, "no limit configured keeps the old behaviour");
    chk(asb_ceiling_over_kind(3648000, 1862400, 3648000) == ASB_CEIL_OVER_OWN, "unlock-lift rail ASB wrote is its own (18:45:27)");
    chk(asb_ceiling_over_kind(2496000, 1996800, 2841600) == ASB_CEIL_OVER_OWN, "a vendor-held value under ASB's own lift is the lift");
    chk(asb_ceiling_over_kind(3648000, 1862400, 1862400) == ASB_CEIL_OVER_VENDOR, "a raise above what ASB asked is the vendor's");
    chk(asb_ceiling_over_kind(1900000, 1862400, 0) == ASB_CEIL_OVER_NONE, "within 100 MHz is no raise");
    chk(asb_ceiling_over_kind(3648000, 1862400, 0) == ASB_CEIL_OVER_VENDOR, "no request on record reads as the vendor");
    chk(asb_ceiling_over_kind(0, 1862400, 3648000) == ASB_CEIL_OVER_NONE, "an unreadable node is not a raise");
    return bad ? 1 : 0;
}
X
"$CC" -O2 -Wall -Wextra -I"$T" "$T/t.c" -o "$T/t" 2> "$T/cc.log" || { cat "$T/cc.log" >&2; fail "harness does not compile"; }
out="$("$T/t")" || fail "$out"
echo "PASS smart trend cool: trend trims need a body within 8 C of the skin limit; ASB's own lifts are not counted as vendor raises"
)

t_thermal_socd_validation() (
# Thermal zone selection (SoC/die sensors on Qualcomm and MediaTek), built against src/asb_metrics.h.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CCX="${HOST_CC:-${CC:-}}"
[ -n "$CCX" ] || for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && { CCX="$c"; break; }; done
[ -n "$CCX" ] || { echo "FAIL thermal_socd_validation: no host C compiler" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_c_thermal_socd_validation > "$T/t.c"
"$CCX" -D_GNU_SOURCE -std=c11 -O2 -Wno-unused-function -I "$ROOT/src" "$T/t.c" -lm -o "$T/t"
"$T/t"
)

t_throttle_cause_runtime() (
# Runtime (fix126): the full-day capture says, per cluster, WHO put a ceiling under ASB's
# profile rail - ASB's own thermal-budget trim or a ceiling ASB did not write.
#
# The fix124 capture logged 20 minutes as "owner=asb" while the prime sat at a 1632000 vendor
# ceiling under ASB's 1862400 request; and the prime column was compared with governor slot 1,
# which is a middle cluster on 1+3+2+1 parts (OP12, Ace 5).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
FD="$ROOT/tools/logkit/asb_log_full_day.sh"
G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL throttle cause: $*" >&2; fail=1; }

cat > "$T/tt" <<'EOF'
# throttle trace
1791715890|active|p0_max=1670400/3628800|p6_max=1862400/4608000|cpu_temp=54|surface=41|cap_owner=asb|main_by=asb_trim|prime_by=-
1791715985|audio|p0_max=1785600/3628800|p6_max=1632000/4608000|cpu_temp=42|surface=39|cap_owner=asb|main_by=-|prime_by=vendor
1791716032|audio|p0_max=1555200/3628800|p6_max=1632000/4608000|cpu_temp=39|surface=38|cap_owner=asb|main_by=asb_trim|prime_by=vendor
1791716079|audio|p0_max=1555200/3628800|p6_max=1632000/4608000|cpu_temp=39|surface=38|cap_owner=asb
EOF
out="$(sh -c '
  . "$0" >/dev/null 2>&1
  echo "c1=$(lk_cap_cause 1632000 1862400 1862400)"
  echo "c2=$(lk_cap_cause 1555200 1785600 1555200)"
  echo "c3=$(lk_cap_cause 1862400 1862400 1862400)"
  echo "c4=$(lk_cap_cause 1555200 1785600 "")"
  echo "c5=$(lk_cap_cause "" 1785600 1555200)"
  lk_emit_cap_cause_split "$1"
' "$C" "$T/tt" 2>&1)"
printf '%s\n' "$out" | grep -qx 'c1=vendor'   || f "live under ASB's request is not a foreign ceiling: $out"
printf '%s\n' "$out" | grep -qx 'c2=asb_trim' || f "live == ASB's trimmed request is not ASB's trim: $out"
printf '%s\n' "$out" | grep -qx 'c3=-'        || f "at the rail must read '-': $out"
printf '%s\n' "$out" | grep -qx 'c4=?'        || f "no request must read '?': $out"
printf '%s\n' "$out" | grep -qx 'c5=?'        || f "no live value must read '?': $out"
printf '%s\n' "$out" | grep -q 'who held the lower ceiling, per cluster (3 samples):' || f "old rows without *_by must be skipped: $out"
printf '%s\n' "$out" | grep -qE '^  main: +asb_trim 2$'  || f "main split wrong: $out"
printf '%s\n' "$out" | grep -qE '^  prime: +vendor 2$'   || f "prime split wrong: $out"

# The verdict names the vendor when it held the prime in most samples (fix127).
sed -n '/^lk_emit_cap_ownership_verdict() {/,/^}/p' "$FD" > "$T/v.sh"
mkdir -p "$T/o"; cp "$T/tt" "$T/o/throttle_trace.txt"
v="$(LK_OUT_DIR="$T/o" sh -c '. "$1"; lk_emit_cap_ownership_verdict' x "$T/v.sh" 2>&1)"
printf '%s\n' "$v" | grep -q 'per cluster: the prime sat under a ceiling ASB did not write in 2 of 3 samples' || f "verdict ignores the per-cluster cause: $v"
printf '%s\n' "$v" | grep -q 'main cores sat under a ceiling' && f "main cores wrongly blamed on the vendor: $v"

# The recorder and the governor.
grep -q 'lk_state_kv desired_cpu_max_prime' "$FD" || f "prime compared with slot 1, not the prime"
grep -q '|main_by=${_mb}|prime_by=${_pb}|writer=${_cw:-asb}"' "$FD" || f "rows carry no per-cluster cause"
grep -q 'lk_emit_cap_cause_split "$LK_OUT_DIR/throttle_trace.txt"' "$FD" || f "report does not print the split"
grep -q 'requested_cpu_max0=%d\\nrequested_cpu_max_prime=%d' "$G" || f "governor does not publish what it wrote"
grep -q 'g_fsm_slot_req_khz\[i\] = cmax\[i\];' "$ROOT/src/asb_writer.h" || f "writer does not record its kept request"
grep -q 'writer_slot_ceiling(1, fsm->current_caps.cpu_max\[1\], fsm->thermal_cap)' "$G" || f "slot 1 figure still snapped with table index 1"

[ "$fail" = 0 ] && echo "PASS throttle cause: per-cluster asb_trim / vendor, prime compared with the prime"
exit "$fail"
)

t_topapp_pkg_runtime() (
# Runtime (fix124): the foreground package comes from the top-app cgroup, not from
# `dumpsys activity top` - which makes the app dump its view hierarchy on its UI thread
# every time it is asked (a field OP15: 129 times in 64 minutes of screen-on).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
S="$ROOT/src/asb_smart.h"
fail() { echo "FAIL topapp pkg: $*" >&2; exit 1; }

# No live call to `dumpsys activity top` anywhere in the native code.
awk '/^#if 0$/{skip=1} /^#endif$/{skip=0; next} !skip' "$S" | grep -q 'popen(".*dumpsys activity top' \
  && fail "dumpsys activity top is still called"
grep -q 'popen(".*dumpsys activity top\|system(".*dumpsys activity top' "$ROOT/src/asb_governor.c" && fail "governor calls dumpsys activity top"
grep -q 'int _topapp = asb_smart_pkg_via_topapp(pkg, sizeof(pkg));' "$S" || fail "top-app cgroup not asked first"
grep -q 'probe_topapp=%lu' "$ROOT/src/asb_governor.c" || fail "top-app answers not published"

CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS topapp pkg (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
proc() {   # pid uid adj cmdline
  mkdir -p "$T/proc/$1"
  printf 'Name:\tx\nUmask:\t0077\nState:\tS\nTgid:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$1" "$2" "$2" "$2" "$2" > "$T/proc/$1/status"
  echo "$3" > "$T/proc/$1/oom_score_adj"
  printf '%s\0' "$4" > "$T/proc/$1/cmdline"
}
proc 1000  1000  -900 system_server                       # system threads in top-app
proc 2001  10234 0    com.instagram.android
proc 2002  10234 0    com.instagram.android:videoplayer
proc 2003  99123 0    com.google.android.webview:sandboxed_process0
proc 2004  10150 100  com.google.android.inputmethod.latin
proc 2005  10300 0    com.netflix.mediaclient
proc 3001  1010234 0  com.whatsapp                        # work profile (user 10)
{
  cat <<X
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#define ASB_PROC_ROOT "$T/proc"
#define ASB_TOPAPP_PROCS_A "$T/cpuset.procs"
#define ASB_TOPAPP_PROCS_B "$T/cpuctl.procs"
static inline void asb_copy_str(char *dst, const char *src, size_t n) {
    if (!dst || n == 0) return;
    if (!src) { dst[0] = 0; return; }
    size_t i = 0;
    for (; i + 1 < n && src[i]; i++) dst[i] = src[i];
    dst[i] = 0;
}
X
  awk '/^#ifndef ASB_PROC_ROOT/{on=1} on&&/^static int asb_smart_pkg_via_topapp/{f=1} on{print} f&&/^}$/{exit}' "$S"
  cat <<'X'
int main(int argc, char **argv) {
    (void)argc;
    char pkg[128];
    int r = asb_smart_pkg_via_topapp(pkg, sizeof(pkg));
    printf("%s|%s|%lu\n", r ? "1" : "0", r ? pkg : "-", g_stat_probe_topapp);
    return 0;
    (void)argv;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -Wno-unused-function -o "$T/t" "$T/t.c" || fail "fixture did not compile"
run() { "$T/t"; }

# Instagram in front, its second process, a system_server thread, an isolated renderer and a
# visible keyboard in the cgroup: Instagram.
printf '1000\n2001\n2002\n2003\n2004\n' > "$T/cpuset.procs"
[ "$(run | cut -d'|' -f1-2)" = "1|com.instagram.android" ] || fail "front app not found: $(run)"
# Split screen - two packages at adj 0: not answered here (the dumpsys chain decides).
printf '2001\n2005\n' > "$T/cpuset.procs"
[ "$(run | cut -d'|' -f1)" = 0 ] || fail "split screen answered with a guess: $(run)"
# cpuset unreadable: the cpuctl group answers.
rm -f "$T/cpuset.procs"; printf '1000\n2005\n' > "$T/cpuctl.procs"
[ "$(run | cut -d'|' -f1-2)" = "1|com.netflix.mediaclient" ] || fail "cpuctl fallback failed: $(run)"
# A work-profile app (uid 10xxxxx) counts.
printf '3001\n' > "$T/cpuctl.procs"
[ "$(run | cut -d'|' -f1-2)" = "1|com.whatsapp" ] || fail "secondary-user app rejected: $(run)"
# Only system processes in front (keyguard on some ROMs): nothing.
printf '1000\n' > "$T/cpuctl.procs"
[ "$(run | cut -d'|' -f1)" = 0 ] || fail "system process taken for the front app: $(run)"
# A vanished pid is skipped.
printf '4242\n2005\n' > "$T/cpuctl.procs"
[ "$(run | cut -d'|' -f1-2)" = "1|com.netflix.mediaclient" ] || fail "a vanished pid broke the lookup: $(run)"
echo "PASS foreground app from the top-app cgroup (no dumpsys activity top)"
)

t_touch_watch_runtime() (
# Runtime (fix117): a touch on a calm screen is answered at once.
#
# The governor learnt about interaction only from load and GPU sampled every 2-6 s, and
# light idle needed two agreeing ticks - so a scroll starting from a calm screen ran on
# light-idle ceilings for up to ~12 s. The touchscreen node is now watched while the screen
# is on, SAMPLED (out of epoll after each touch until the next active tick), and a fresh
# touch lifts LIGHT_IDLE to MODERATE on the spot; a touch within 3 s floors at MODERATE.
# Executable fixture: the REAL touch_drain()/touch_watch_set() cut out of asb_governor.c,
# driven through a pipe and a real epoll set.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; F="$ROOT/src/asb_fsm.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL touch watch: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP touch watch: no C compiler"; exit 0; }

_a="$(grep -n '^static int           g_touch_fd = -1;' "$G" | cut -d: -f1)"
_b="$(awk '/^static int touch_watch_set\(/{f=1} f&&/^}/{print NR; exit}' "$G")"
[ -n "$_a" ] && [ -n "$_b" ] || fail "touch watch code not found"
sed -n "${_a},${_b}p" "$G" | sed '/^static int touch_open(void) {$/,/^}$/d' > "$T/w.c"
grep -q 'touch_drain' "$T/w.c" || fail "touch_drain not extracted"

cat > "$T/t.c" <<'X'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/epoll.h>
#include <linux/input.h>
#include "w.c"
static void ev(int wfd, int type, int code, int value) {
    struct input_event e; memset(&e, 0, sizeof(e));
    e.type = (unsigned short)type; e.code = (unsigned short)code; e.value = value;
    if (write(wfd, &e, sizeof(e)) != sizeof(e)) perror("write");
}
static int ready(int ep, int fd) {
    struct epoll_event e[4];
    int n = epoll_wait(ep, e, 4, 50);
    for (int i = 0; i < n; i++) if (e[i].data.fd == fd) return 1;
    return 0;
}
int main(void) {
    int bad = 0;
    #define CHECK(c, msg) do { if (!(c)) { printf("%s\n", msg); bad = 1; } } while (0)
    int p[2]; if (pipe2(p, O_NONBLOCK)) return 1;
    int ep = epoll_create1(0);
    g_touch_fd = p[0];
    /* screen on: watched */
    touch_watch_set(ep, 1);
    CHECK(g_touch_in_epoll == 1, "screen-on did not watch the panel");
    ev(p[1], EV_ABS, ABS_MT_TRACKING_ID, 7); ev(p[1], EV_ABS, ABS_MT_POSITION_X, 300); ev(p[1], EV_SYN, SYN_REPORT, 0);
    CHECK(ready(ep, p[0]), "a touch did not wake the loop");
    CHECK(touch_drain(p[0]) == 1, "a touch was not recognised");
    /* sampled out: no wakeups while out */
    touch_watch_set(ep, 0);
    ev(p[1], EV_ABS, ABS_MT_POSITION_Y, 500); ev(p[1], EV_SYN, SYN_REPORT, 0);
    CHECK(!ready(ep, p[0]), "sampled-out watch still woke the loop");
    /* re-armed on the tick: what came meanwhile counts, then quiet */
    CHECK(touch_watch_set(ep, 1) == 1, "touches queued while out were lost");
    CHECK(!ready(ep, p[0]), "re-arm did not drain the queue");
    /* a key that is not BTN_TOUCH (e.g. a gesture key) is not a touch */
    ev(p[1], EV_KEY, KEY_F4, 1); ev(p[1], EV_SYN, SYN_REPORT, 0);
    CHECK(ready(ep, p[0]), "event not delivered");
    CHECK(touch_drain(p[0]) == 0, "a gesture key was read as a touch");
    ev(p[1], EV_KEY, BTN_TOUCH, 1); ev(p[1], EV_SYN, SYN_REPORT, 0);
    CHECK(touch_drain(p[0]) == 1, "BTN_TOUCH down not a touch");
    /* screen off: unwatched, no re-arm pending */
    g_touch_rearm = 1;
    touch_watch_set(ep, 0);
    CHECK(g_touch_in_epoll == 0 && g_touch_rearm == 0, "screen-off left the watch or a re-arm pending");
    /* no device: harmless */
    g_touch_fd = -1;
    CHECK(touch_watch_set(ep, 1) == 0 && g_touch_in_epoll == 0, "no device still armed something");
    return bad;
}
X
"$CC" -std=gnu99 -Wall -Wno-unused-function -o "$T/t" "$T/t.c" -I"$T" 2>"$T/cc.err" || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"

# The FSM side: the touch floor sits before the light-idle return, the camera excluded; the
# first touch lifts LIGHT_IDLE at once; the kick is cleared after each update.
# fix240: Battery is no longer excluded from the floor or the lift - its LIGHT_IDLE carries
# the governor's own lowest-step GPU ceiling, which is what the first seconds of a swipe
# were drawn at (battery_touch_light_idle_runtime runs the real FSM). The pin escalation
# stays CPU-only and keeps Battery out.
awk '/A finger on the glass is interaction/{t=NR} /The light-idle ceiling is binding/{p=NR} END{exit !(t && p && t < p)}' "$F" \
  || fail "touch floor is not ahead of the light-idle decision"
grep -q 'g_touch_last_ts > 0 && time(NULL) - g_touch_last_ts <= ASB_TOUCH_RECENT_S)' "$F" || fail "touch floor has no time window"
grep -q 'm->misc.screen_on && g_touch_kick && fsm->state == ASB_STATE_LIGHT_IDLE &&' "$F" || fail "first touch does not lift light idle"
_lift="$(grep -A1 'm->misc.screen_on && g_touch_kick && fsm->state == ASB_STATE_LIGHT_IDLE &&' "$F")"
case "$_lift" in *'!m->misc.camera_active) {'*) ;; *) fail "the camera is not excluded from the touch lift" ;; esac
case "$_lift" in *fsm_profile_is_battery*) fail "Battery is excluded from the touch lift again" ;; esac
_floor="$(grep -B1 -A1 'g_touch_last_ts > 0 && time(NULL) - g_touch_last_ts <= ASB_TOUCH_RECENT_S)$' "$F" | head -3)"
case "$_floor" in *fsm_profile_is_battery*) fail "Battery is excluded from the touch floor again" ;; esac
grep -q 'g_touch_kick = 0;   /\* answered (fix117) \*/' "$G" || fail "touch kick never cleared"
grep -q 'touch_watch=%d' "$G" || fail "state file does not report the touch watch"
grep -q '(void)touch_watch_set(epfd, 0);   /\* screen off' "$G" || fail "screen-off does not stop the touch watch"
echo "PASS touch watch: sampled, instant on a calm screen, off with the screen"
)

t_uclamp_gmin_drift_contract() (
# Contract: reconcile watches the GLOBAL uclamp.min ceiling for drift, with the same
# target formula as the writer (profile_core), and the new reason is wired into every
# place a drift reason must reach: the drift streak, the apply ledger and the
# governor-mode re-apply branch.
#
# Why: a field capture showed /proc/sys/kernel/sched_util_clamp_min back at the OxygenOS
# default 1024 on a phone whose profile applies 512. asb_apply_uclamp writes it on
# profile apply and nothing re-asserted it afterwards, so the ROM's boost framework could
# quietly outrank every per-cgroup ceiling the module sets. The C governor never writes
# this node, so the check must live OUTSIDE the governor-running gate that guards the
# per-cgroup uclamp tiers.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REC="$ROOT/runtime/asb_reconcile.sh"
PC="$ROOT/runtime/profile_core.sh"
DIAG="$ROOT/tools/asb_diag.sh"
DIAG2="$ROOT/system/bin/asbdiag"
fail() { echo "FAIL uclamp-gmin drift contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in ${1#$ROOT/}"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden [$2] in ${1#$ROOT/}" || true; }

[ -f "$REC" ] || fail "asb_reconcile.sh not found"

# The check exists, reads the node and carries the reason end to end.
need "$REC" '/proc/sys/kernel/sched_util_clamp_min'
need "$REC" '_reason="uclamp-gmin"'
need "$REC" 'walt-topapp|walt-edboost|walt-ravg|uclamp|uclamp-fg|uclamp-bg|uclamp-gmin)'
need "$REC" 'uclamp|uclamp-fg|uclamp-bg|uclamp-gmin)'
need "$REC" 'elif [ "$_reason" = "uclamp-gmin" ]; then'

# Governor mode restores ONLY the global node there, never the governor-owned tiers.
absent "$REC" '_reason" = "uclamp-gmin" ] ; then
          asb_apply_uclamp'

# Write-war stand-down: gate on the check, reset on profile/screen change, and the
# restore counter must advance on BOTH apply paths. Governor mode writes the node
# directly; without the governor the restore rides apply_runtime_profile_now - and a
# counter that only increments on one path never arms on the other.
need "$REC" '[ "${_gmin_restores:-0}" -lt 3 ]'
need "$REC" '_drift_streak=0; _gmin_restores=0 ;;'
[ "$(grep -cF '_gmin_restores=$(( ${_gmin_restores:-0} + 1 ))' "$REC")" -ge 2 ] \
  || fail "uclamp-gmin restore counter advances on only one apply path (write war in the other)"
need "$REC" 'held externally, standing down until profile/screen change'

# The 20% floor is present in BOTH the writer and the watcher; the formula must be the
# same shape in both, or one day one of them changes and they silently disagree.
need "$REC" '_want_gmin=$(( ( ${UCL_TOP_MIN:-50} * 1024 ) / 100 ))'
need "$PC"  '_gmin="$(( ( ${UCL_TOP_MIN:-50} * 1024 ) / 100 ))"'
[ "$(grep -cF -- '-lt 205' "$REC")" -ge 2 ] || fail "205 floor missing in reconcile (check + fix branch)"
need "$PC" '[ "$_gmin" -lt 205 ] && _gmin=205'

# The check sits outside the governor-running gate: it must appear AFTER the closing
# of the per-cgroup block, which the uclamp-bg drift line marks the end of.
_bg=$(grep -nF '_reason="uclamp-bg"' "$REC" | head -1 | cut -d: -f1)
_gm=$(grep -nF '_reason="uclamp-gmin"' "$REC" | head -1 | cut -d: -f1)
[ -n "$_bg" ] && [ -n "$_gm" ] || fail "uclamp drift lines not found"
[ "$_gm" -gt "$_bg" ] || fail "uclamp-gmin check must follow the per-cgroup block (governor-gate escape)"

# Diagnosis names the live value so the next capture shows drift without a diff.
need "$DIAG" 'global sched_util_clamp_min'
cmp -s "$DIAG" "$DIAG2" || fail "tools/asb_diag.sh and system/bin/asbdiag differ"

echo "PASS uclamp-gmin drift contract"
)

t_walt_window_runtime() (
# Runtime (fix244): the WALT window is left to a ROM that sizes it itself; Smart blends its
# packing threshold instead of writing 0.
#
# Every OnePlus capture on file (OP12, OP13, OP15, Ace 6) shows sched_ravg_window_nr_ticks
# moving between 2, 3 and 4 on its own - the ROM's frame-time window - while ASB wrote its
# profile value back on every forced apply (116 physical writes in one Battery evening). The
# REAL observer is cut out of asb_writer.h: three NEW values ASB did not write within ten
# minutes hand the node to the ROM and leave the marker the shell honours; one stray value (the
# shell's own profile write landing late) or values spread over more than ten minutes do not.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
G="$ROOT/src/asb_governor.c"
F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL walt window: $*" >&2; exit 1; }
grep -q '    writer_ravg_observe(force);' "$W" || fail "the observer is not called before the window write"
grep -q '    if (!g_ravg_rom_owned && caps->ravg_ticks > 0 &&' "$W" || fail "the window is still written once the ROM owns it"
grep -q 'walt_window_owner=%s' "$G" || fail "the state file does not say who owns the window"
grep -q 'WALT window: left to the ROM' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not say the window is the ROM's"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag is stale"
for f in "$ROOT/runtime/profile_core.sh" "$ROOT/service.sh"; do
  n="$(grep -c 'sched_ravg_window_nr_ticks \] && \[ ! -e /dev/.asb/walt_ravg_rom \] && writef_retry' "$f")"
  [ "$n" -ge 1 ] || fail "${f##*/} still writes the window over the ROM"
  grep 'writef_retry /proc/sys/walt/sched_ravg_window_nr_ticks' "$f" | grep -vq 'walt_ravg_rom' && fail "${f##*/} has an unguarded window write"
done
grep -q '_reason="walt-ravg"' "$ROOT/runtime/asb_reconcile.sh" && fail "reconcile re-applies the whole profile when the ROM moves its window"
# Smart: both fields blended, packing capped on screen at the kernel default.
grep -q 'out.floor.idle_enough = wo\[0\];' "$G" && grep -q 'out.ceil.ravg_ticks  = wo\[1\];' "$G" || fail "Smart does not blend the window and packing threshold"
grep -q '#define ASB_SMART_SCREEN_IDLE_ENOUGH 30' "$F" || fail "no on-screen packing for Smart"
grep -q 'if (profile_idx == PROFILE_SMART && fsm_screen_is_on && out->idle_enough > ASB_SMART_SCREEN_IDLE_ENOUGH)' "$F" || fail "Smart on screen is not held at the kernel default"
grep -q '^BATTERY_FLOOR_IDLE_ENOUGH=85$' "$ROOT/config/profile_bounds.conf" && grep -q '^BATTERY_CEIL_IDLE_ENOUGH=45$' "$ROOT/config/profile_bounds.conf" \
  || fail "Battery packing rails"
grep -q '#define ASB_BATTERY_FLOOR_IDLE_ENOUGH    85' "$ROOT/src/asb_fsm_bounds.generated.h" || fail "generated bounds are stale"

CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS walt window (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^#define WALT_RAVG_ROM_MARK/,/^static void writer_ravg_observe(int force) {$/p' "$W" | sed '$d' > "$T/o.c"
sed -n '/^static void writer_ravg_observe(int force) {$/,/^}$/p' "$W" >> "$T/o.c"
grep -q 'g_ravg_rom_owned = 1;' "$T/o.c" || fail "observer not found"
sed -i "s#\"/dev/.asb/walt_ravg_rom\"#\"$T/mark\"#" "$T/o.c"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <limits.h>
#include <time.h>
#define WALT_RAVG_PATH "x"
static int NODE = 4;
static time_t NOW = 100000;
#define time(p) (NOW)
static int sysfs_read_int(const char *p, int d) { (void)p; (void)d; return NODE; }
static struct { int ravg_ticks; } g_wcache = { 4 };
#include "o.c"
static void reset(void) { g_ravg_rom_owned = 0; g_ravg_foreign = 0; g_ravg_check_at = 0; g_ravg_first_at = 0; g_ravg_last_seen = 4; g_wcache.ravg_ticks = 4; NODE = 4; }
static void tick(int node, int secs) { NODE = node; NOW += secs; writer_ravg_observe(0); }
int main(void) {
    int bad = 0;
#define CHK(c, what) do { if (!(c)) { printf("%s\n", what); bad = 1; } } while (0)
    reset();
    for (int i = 0; i < 20; i++) tick(4, 30);
    CHK(!g_ravg_rom_owned && g_ravg_foreign == 0, "a node holding ASB's value is not foreign");
    reset();
    for (int i = 0; i < 20; i++) tick(3, 30);
    CHK(!g_ravg_rom_owned && g_ravg_foreign == 1, "one stray value counts once");
    reset();
    tick(2, 30); tick(2, 30); tick(3, 30); tick(3, 30);
    CHK(!g_ravg_rom_owned, "two values are not yet the ROM");
    tick(2, 30);
    CHK(g_ravg_rom_owned && g_ravg_rom_seen == 2, "three new values within ten minutes hand the window to the ROM");
    reset();
    tick(2, 30); tick(3, 300); tick(2, 400);
    CHK(!g_ravg_rom_owned, "values spread over more than ten minutes are not the ROM");
    reset();
    tick(2, 10); tick(3, 10); tick(2, 10);
    CHK(!g_ravg_rom_owned && g_ravg_foreign == 1, "checks run every 30 s, not every tick");
    NOW += 30; writer_ravg_observe(1);
    CHK(g_ravg_foreign == 1, "a forced check of the same value adds nothing");
    reset();
    g_wcache.ravg_ticks = 0;
    tick(2, 30); tick(3, 30); tick(2, 30);
    CHK(!g_ravg_rom_owned, "nothing is judged before ASB has written the node");
    return bad;
}
X
"$CC" -O1 -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.err" || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"
[ -e "$T/mark" ] && grep -q '^rom=2 asb=4$' "$T/mark" || fail "the shell marker was not left: $(cat "$T/mark" 2>/dev/null)"
echo "PASS walt window: three new ROM values in ten minutes hand the window to the ROM and leave the shell marker; a stray value, spread values and ASB's own value do not; Smart blends its packing and holds it at the kernel default on screen"
)

t_unlock_lift_runtime() (
# Runtime (fix150): Smart lifts the CPU ceilings for a few seconds after a wake.
#
# "Slideshow at unlock after a short idle, then smooth again." Capture 28442 (OP15, Smart): the
# first recorded interval after two wakes drew the launcher with 31 of 262 and 18 of 39 frames
# janky against 1.7% over the day, on MODERATE ceilings of main 1996800 / prime 1862400 and
# top-app uclamp 50, with a raised floor held at them (policy6 min = max). The REAL
# block is cut out of asb_governor.c and run: a wake lifts every managed ceiling to
# unlock_lift_pct of the hardware maximum (and top-app uclamp to the same share) for
# unlock_lift_s; the first touch within 20 s re-arms it once; the lift ends on time, on screen
# off and on a thermal cap; Performance, a thermal cap, a warm die and unlock_lift_s=0 do
# not lift and say why; an empty slot stays unmanaged and nothing is ever lowered.
# fix212: Battery and Balanced lift too - their static shell ceilings are exactly what janked
# (32% of SystemUI frames on an OP15 Battery day against 3.5-4.4% on Smart) - and a
# foreground-app switch arms the same window once per 5 s while no lift runs.
# fix220: the app-switch arm is seen on the next metrics tick - up to 2 s after the tap, past
# the animation's first frames. The tap itself (a fresh touch after a calm spell) and the
# lock press (the power key with the screen on) now arm the same window, same 5 s gap, same
# gates - so the open/close/unlock/lock animations of ColorOS 17 run on lifted ceilings.
# fix223: on manual Battery, continuous touch extends an already-armed window; quiet reading,
# Smart/Balanced/Performance and a vetoed (off/warm/thermal) start gain no new lift path.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
W="$ROOT/src/asb_writer.h"
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
# fix212: the lift reaches the manual profiles, an app switch arms it, and the writer lets the
# borrowed ceilings through while it runs.
grep -q 'static int asb_unlock_lift_profile_ok(int profile_idx)' "$G" || fail "profile gate helper missing"
grep -q '#define ASB_LAUNCH_LIFT_GAP_MS 5000L' "$G" || fail "launch rate limit missing"
grep -q 'static long g_launch_prev_hash = 0;' "$G" || fail "app-switch detection not wired in the tick"
grep -q '_launch_kick,' "$G" || fail "the launch kick does not reach the update"
grep -q 'g_unlock_arm_why,' "$G" || fail "the log line does not say what armed the lift"
grep -Fq 'const int manual_lift     = manual_profile && g_unlock_lift_now && !thermal_cap &&' "$W" || fail "the writer clamps the borrowed ceilings"
grep -Fq 'int manual_cap_skip = manual_profile && !manual_override && !manual_lift;' "$W" || fail "manual_cap_skip does not yield to the lift"
grep -Fq '!g_fsm_cooldown_active && !g_unlock_lift_now;' "$G" || fail "the lift would classify its own ceilings as the shell's"
# fix220: the lock press reaches the update, is answered after the decision, and the wake keys
# stay in epoll with the screen on - except the touch panel's own gesture node.
grep -q 'static int           g_lock_key_kick = 0;' "$ROOT/src/asb_fsm.h" || fail "lock kick not declared"
grep -q 'g_lock_key_kick, _launch_kick,' "$G" || fail "the lock kick does not reach the update"
grep -qF '_touch_active, g_lock_key_kick, _launch_kick,' "$G" || fail "continuous touch does not reach the Battery lift"
grep -qF 'time(NULL) - g_touch_last_ts <= ASB_TOUCH_RECENT_S;' "$G" || fail "the continuous-touch window is not tied to the sampled touch clock"
grep -q 'g_lock_key_kick = 1;' "$G" || fail "the power key with the screen on raises no kick"
grep -q 'g_lock_key_kick = 0;   /\* answered (fix220) \*/' "$G" || fail "the lock kick is never answered"
grep -q 'wakes, first touches, app opens/closes, lock presses' "$ROOT/tools/asb_diag.sh" || fail "asbdiag still says wakes + first touches"
sed -n '/^static void wake_keys_park(int epfd, int park) {/,/^}/p' "$G" | grep -q 'if (g_wake_key_touch\[i\])' \
  || fail "wake_keys_park parks the power key with the screen on"
sed -n '/^static void wake_keys_park(int epfd, int park) {/,/^}/p' "$G" | grep -q 'e.data.fd = g_wake_key_fd\[i\];' \
  || fail "unpark no longer re-adds the keys"

CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS unlock lift (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^#define ASB_UNLOCK_TOUCH_WINDOW_MS/,/^\/\* Smart night slot with the screen on (fix150)/p' "$G" | sed '$d' > "$T/u.c"
grep -q 'static void asb_unlock_lift_apply' "$T/u.c" || fail "lift block not found"

cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
#include <time.h>
enum { PROFILE_BATTERY, PROFILE_BALANCED, PROFILE_PERFORMANCE, PROFILE_SMART };
typedef struct { int cpu_max[3]; int cpu_min[3]; int uclamp_top_max; int uclamp_bg_max; } asb_profile_caps_t;
static struct { int unlock_lift_s, unlock_lift_pct, bat_comfort_temp; } g_asb_cfg = { 3, 80, 48 };
static int g_cpu_slot_hwmax[3] = { 3628800, 4608000, 0 };
#include "u.c"
static int P = PROFILE_SMART, TC = 0, DIE = 36;
static int upa(int scr, int kick, int active, long ms) { return asb_unlock_lift_update(scr, kick, active, 0, 0, ms, P, TC, DIE); }
static int up(int scr, int kick, long ms) { return upa(scr, kick, 0, ms); }
static int upl(int scr, int kick, int launch, long ms) { return asb_unlock_lift_update(scr, kick, 0, 0, launch, ms, P, TC, DIE); }
static int uplk(int scr, int lock, long ms) { return asb_unlock_lift_update(scr, 0, 0, lock, 0, ms, P, TC, DIE); }
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
    /* fix220: a fresh touch after a calm spell is the tap that opens or closes an app - it
     * arms the same window, once per 5 s. */
    CHK(up(1, 1, 22000) == 1 && g_unlock_lifts == 3 && !strcmp(g_unlock_arm_why, "touch"),
        "fix220: the tap that opens an app did not lift");
    CHK(up(1, 1, 23000) == 1 && g_unlock_lifts == 3, "a touch inside 5 s re-armed");
    up(0, 0, 30000); up(1, 0, 40000); up(1, 0, 44000);
    CHK(g_unlock_lifts == 4, "second wake");
    CHK(up(1, 1, 61000) == 1 && g_unlock_lifts == 5 && !strcmp(g_unlock_arm_why, "touch"),
        "fix220: a tap past the wake window is still an app open");
    /* Screen off ends a running lift at once. */
    up(0, 0, 70000); CHK(up(1, 0, 80000) == 1, "third wake"); CHK(up(0, 0, 81000) == 0, "screen off kept the lift");
    /* A thermal cap ends it too. */
    CHK(up(1, 0, 90000) == 1, "fourth wake");
    TC = 1; CHK(up(1, 0, 91000) == 0, "thermal cap kept the lift"); TC = 0;
    /* fix212: Battery and Balanced lift on a wake too - their static shell ceilings are what
     * made one jank. Performance is never capped and skips with "profile". */
    unsigned long l0 = g_unlock_lifts;
    up(0, 0, 100000); P = PROFILE_BALANCED; CHK(up(1, 0, 101000) == 1, "Balanced did not lift"); P = PROFILE_SMART;
    up(0, 0, 102000); P = PROFILE_BATTERY; CHK(up(1, 0, 103000) == 1, "Battery did not lift"); P = PROFILE_SMART;
    CHK(g_unlock_lifts == l0 + 2, "manual-profile wakes not counted");
    up(0, 0, 104000); P = PROFILE_PERFORMANCE; CHK(up(1, 0, 105000) == 0 && !strcmp(g_unlock_skip_why, "profile"), "Performance lifted"); P = PROFILE_SMART;
    up(0, 0, 106000); TC = 1; CHK(up(1, 0, 107000) == 0 && !strcmp(g_unlock_skip_why, "thermal"), "thermal-capped wake lifted"); TC = 0;
    up(0, 0, 108000); DIE = 48; CHK(up(1, 0, 109000) == 0 && !strcmp(g_unlock_skip_why, "warm"), "warm die lifted"); DIE = 36;
    up(0, 0, 110000); g_asb_cfg.unlock_lift_s = 0; CHK(up(1, 0, 111000) == 0 && !strcmp(g_unlock_skip_why, "off"), "switched off and lifted"); g_asb_cfg.unlock_lift_s = 3;
    CHK(g_unlock_lifts == l0 + 2 && g_unlock_skips == 4, "skips not counted");
    /* A skipped wake still lets the first touch try (the phone may have cooled). */
    up(0, 0, 112000); DIE = 48; up(1, 0, 113000); DIE = 36;
    CHK(up(1, 1, 115000) == 1, "first touch after a warm wake did not lift on a cool die");
    /* fix166: "warm" is the lower of the die at the wake and the last reading in the dark. */
    {
        time_t n = 1792305000;
        CHK(asb_unlock_gate_die(49, 36, n - 120, n) == 36, "a wake burst on a cool phone counted as warm");
        CHK(asb_unlock_gate_die(49, 52, n - 120, n) == 49, "a phone that slept hot was not judged warm");
        CHK(asb_unlock_gate_die(49, 36, n - 1801, n) == 49, "a dark reading older than half an hour was trusted");
        CHK(asb_unlock_gate_die(49, 0, 0, n) == 49 && asb_unlock_gate_die(49, 36, n + 5, n) == 49, "no or future dark reading");
        up(0, 0, 120000); DIE = asb_unlock_gate_die(49, 36, n - 120, n);
        CHK(up(1, 0, 121000) == 1, "29835: the 08:4x wake was skipped warm on a cool phone"); DIE = 36;
    }
    /* fix212: an app switch arms the same window - never while a lift runs, once per 5 s,
     * gated like a wake. */
    up(0, 0, 130000); up(1, 0, 131000);
    unsigned long l1 = g_unlock_lifts;
    CHK(upl(1, 0, 1, 132000) == 1 && g_unlock_lifts == l1, "a switch during a running lift re-armed");
    CHK(upl(1, 0, 1, 140000) == 1 && g_unlock_lifts == l1 + 1, "an app switch did not lift");
    CHK(!strcmp(g_unlock_arm_why, "app switch"), "the log does not say what armed the lift");
    CHK(upl(1, 0, 1, 144000) == 0 && g_unlock_lifts == l1 + 1, "a switch inside 5 s re-armed");
    CHK(upl(1, 0, 1, 146000) == 1 && g_unlock_lifts == l1 + 2, "a switch after 5 s did not lift");
    /* A switch to Performance ends a running lift (its ceilings are uncapped anyway). */
    up(0, 0, 160000); up(1, 0, 161000);
    P = PROFILE_PERFORMANCE;
    CHK(up(1, 0, 162000) == 0, "a lift survived a switch to Performance");
    unsigned long l2 = g_unlock_lifts;
    CHK(upl(1, 0, 1, 170000) == 0 && g_unlock_lifts == l2 && !strcmp(g_unlock_skip_why, "profile"),
        "an app switch lifted on Performance");
    P = PROFILE_SMART;
    TC = 1; CHK(upl(1, 0, 1, 180000) == 0 && !strcmp(g_unlock_skip_why, "thermal"),
        "a launch lift slipped past a thermal cap"); TC = 0;
    /* fix220: the lock press with the screen on arms the same window - the fade-out animation
     * renders before Android publishes the display state. Same 5 s gap, same gates, and a
     * press in the dark is a wake hint, not a lift (the screen-on edge does that). */
    up(0, 0, 190000); up(1, 0, 191000);
    unsigned long l3 = g_unlock_lifts;
    CHK(uplk(1, 1, 192000) == 1 && g_unlock_lifts == l3, "a lock press during a running lift re-armed");
    CHK(uplk(1, 1, 200000) == 1 && g_unlock_lifts == l3 + 1 && !strcmp(g_unlock_arm_why, "lock key"),
        "the lock press did not lift");
    CHK(uplk(1, 1, 204000) == 0 && g_unlock_lifts == l3 + 1, "a lock press inside 5 s re-armed");
    CHK(uplk(1, 1, 206000) == 1 && g_unlock_lifts == l3 + 2, "a lock press after 5 s did not lift");
    up(0, 0, 210000);
    CHK(uplk(0, 1, 211000) == 0 && g_unlock_lifts == l3 + 2, "a lock press in the dark lifted");
    P = PROFILE_PERFORMANCE;
    up(1, 0, 212000);
    unsigned long l4 = g_unlock_lifts;
    CHK(uplk(1, 1, 220000) == 0 && g_unlock_lifts == l4 && !strcmp(g_unlock_skip_why, "profile"),
        "a lock press lifted on Performance");
    P = PROFILE_SMART;
    TC = 1; CHK(uplk(1, 1, 230000) == 0 && g_unlock_lifts == l4 && !strcmp(g_unlock_skip_why, "thermal"),
        "a lock lift slipped past a thermal cap"); TC = 0;
    CHK(up(1, 1, 240000) == 1 && g_unlock_lifts == l4 + 1 && !strcmp(g_unlock_arm_why, "touch"),
        "a tap after the lock run did not lift");
    /* fix223: manual Battery keeps an already-armed lift while the finger is active. The
     * original three seconds would have elapsed at 263000; 264000 proves the extension.
     * No extra lift is counted for continuation, quiet touch state cannot start one, and
     * stopping the finger gives the ceilings back on the normal expiry. */
    up(0, 0, 250000); P = PROFILE_BATTERY;
    unsigned long lb = g_unlock_lifts;
    CHK(up(1, 0, 251000) == 1 && g_unlock_lifts == lb + 1, "Battery test wake did not lift");
    CHK(up(1, 0, 254000) == 0, "Battery test wake did not expire");
    CHK(upa(1, 1, 1, 260000) == 1 && g_unlock_lifts == lb + 2, "Battery touch did not arm");
    CHK(upa(1, 0, 1, 262000) == 1 && g_unlock_lifts == lb + 2, "Battery continuation counted as a new lift");
    CHK(upa(1, 0, 1, 264000) == 1 && g_unlock_lifts == lb + 2, "continuous Battery scrolling expired after the original 3 s");
    CHK(upa(1, 0, 0, 266000) == 1, "Battery handback started before the quiet window ended");
    CHK(up(1, 0, 268000) == 0, "Battery ceilings did not return after the touch stopped");
    CHK(upa(1, 0, 1, 270000) == 0 && g_unlock_lifts == lb + 2,
        "touch-active alone started a Battery lift without an arm event");
    CHK(upa(1, 1, 1, 280000) == 1 && g_unlock_lifts == lb + 3, "second Battery touch did not arm");
    TC = 1; CHK(upa(1, 0, 1, 282000) == 0, "thermal cap did not cancel a held Battery lift"); TC = 0;
    CHK(upa(1, 0, 1, 283000) == 0 && g_unlock_lifts == lb + 3,
        "touch hold restarted a thermally cancelled Battery lift");
    DIE = 48; up(0, 0, 290000); up(1, 0, 291000);
    CHK(upa(1, 1, 1, 292000) == 0 && !strcmp(g_unlock_skip_why, "warm"), "a warm Battery touch armed");
    CHK(upa(1, 0, 1, 293000) == 0, "touch hold bypassed the warm-start veto"); DIE = 36;
    /* Smart and Balanced keep the old fixed-length touch window: no permanent boost. */
    up(0, 0, 300000); P = PROFILE_SMART; up(1, 0, 301000); up(1, 0, 304000);
    unsigned long ls = g_unlock_lifts;
    CHK(upa(1, 1, 1, 310000) == 1 && g_unlock_lifts == ls + 1, "Smart control touch did not arm");
    CHK(upa(1, 0, 1, 312000) == 1, "Smart control touch ended early");
    CHK(upa(1, 0, 1, 313000) == 0, "Smart gained the Battery continuous-touch hold");
    up(0, 0, 320000); P = PROFILE_BALANCED; up(1, 0, 321000); up(1, 0, 324000);
    unsigned long ll = g_unlock_lifts;
    CHK(upa(1, 1, 1, 330000) == 1 && g_unlock_lifts == ll + 1, "Balanced control touch did not arm");
    CHK(upa(1, 0, 1, 333000) == 0, "Balanced gained the Battery continuous-touch hold");
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
    /* fix243: Battery lifts to four fifths of the shared share - 80 -> 64 % of each cluster's
     * own maximum, never under the 50 % floor; Smart and Balanced keep the full share. */
    g_cpu_slot_hwmax[0] = 3628800; g_cpu_slot_hwmax[1] = 4608000; g_cpu_slot_hwmax[2] = 0;
    g_asb_cfg.unlock_lift_pct = 80;
    up(0, 0, 400000); P = PROFILE_BATTERY; up(1, 0, 401000);
    asb_profile_caps_t b = { { 1785600, 1747200, 0 }, { 0, 0, 0 }, 50, 30 };
    asb_unlock_lift_apply(&b);
    CHK(b.cpu_max[0] == 2322432 && b.cpu_max[1] == 2949120 && b.uclamp_top_max == 64,
        "fix243: Battery lift is not 64 % of each cluster");
    g_asb_cfg.unlock_lift_pct = 55;
    asb_profile_caps_t b2 = { { 1785600, 1747200, 0 }, { 0, 0, 0 }, 40, 30 };
    asb_unlock_lift_apply(&b2);
    CHK(b2.cpu_max[0] == 1814400 && b2.uclamp_top_max == 50, "fix243: Battery share fell under the 50 % floor");
    g_asb_cfg.unlock_lift_pct = 80;
    up(0, 0, 410000); P = PROFILE_SMART; up(1, 0, 411000);
    asb_profile_caps_t s2 = { { 1996800, 1862400, 0 }, { 0, 0, 0 }, 50, 32 };
    asb_unlock_lift_apply(&s2);
    CHK(s2.cpu_max[0] == 2903040 && s2.uclamp_top_max == 80, "fix243: Smart lost its full lift share");
    return bad;
}
X
"$CC" -O2 -Wall -Werror -Wno-unused-function -Wno-unused-variable -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "fixture did not compile"; }
"$T/t" || fail "lift wrong"
echo "PASS unlock lift: wakes, app taps and lock presses get the ceilings for a few seconds, nothing else moves"
)

t_v64_regression_contract() (
# v64_regression_contract — build and run Session unit tests
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="/tmp/asb_test_v64_regression_contract.c"
_c_v64_regression_contract > "$SRC"
BIN="/tmp/asb_test_v64_regression_contract"

CC="${CC:-cc}"
CFLAGS="-Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function -I${ROOT_DIR}/src -D_GNU_SOURCE"

echo "Building V64 regression contract..."
"$CC" $CFLAGS "$SRC" -o "$BIN"

echo "Running..."
"$BIN"
RC=$?

rm -f "$BIN" "$SRC"
exit "$RC"
)

t_v65_smart_thermal_cap_contract() (
# Contract: Smart must lower its ceiling before the vendor thermal owner clamps it, and must
# never re-raise a vendor cap through the anti-clamp path.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FSM="$ROOT/src/asb_fsm.h"
GOV="$ROOT/src/asb_governor.c"
fail() { echo "FAIL Smart thermal cap contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
need "$FSM" '#define ASB_SMART_PROACTIVE_P0_MODERATE_MAX 1996800'
need "$FSM" '#define ASB_SMART_PROACTIVE_P6_MODERATE_MAX 1632000'
need "$FSM" '#define ASB_SMART_PROACTIVE_P0_SUSTAINED_MAX 1785600'
need "$FSM" '#define ASB_SMART_PROACTIVE_P6_SUSTAINED_MAX 1382400'
need "$FSM" 'profile_idx == PROFILE_SMART'
need "$FSM" 'state >= ASB_STATE_MODERATE && state < ASB_STATE_GAMING'
need "$GOV" 'Smart is an energy/heat profile, not a hidden Balanced profile'
need "$GOV" 'p = PROFILE_BATTERY;'
need "$GOV" 'fsm->plan.ac_eligible  = 0'
need "$GOV" 'fsm.profile_idx != PROFILE_SMART'
need "$GOV" 'it must never enter the anti-clamp reassert path'
# Host syntax/warning compilation is covered by the main regression; this test only protects the
# source-level policy invariants that a host cannot observe through sysfs.
echo 'PASS Smart proactive thermal cap contract'
)

t_wake_key_hint_runtime() (
# fix86: wake keys (power / KEY_WAKEUP) arm the screen-on re-check while the screen is off.
# OP15: a third of wakes had no display uevent and were found only by the 45 s idle tick.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL wake key hint: $*" >&2; exit 1; }
grep -Fq 'int ok = caps && !is_abs &&' "$G" || fail "touchscreens (EV_ABS) must not be admitted for power/wakeup alone"
# fix101: a touch panel is admitted only for its off-screen gesture keys (double-tap wake).
grep -Fq '(asb_bit_test(keyb, KEY_WAKEUP) || asb_bit_test(keyb, KEY_F4))' "$G" || fail "touch gesture keys not admitted"
grep -Fq 'else if (wake_key_is_fd(fd)) {' "$G" || fail "key fds not handled in the event loop"
grep -Fq 'wake_keys_park(epfd, 1);' "$G" || fail "keys not parked with the uevent socket while the screen is on"
grep -Fq 'wake_keys_park(epfd, 0);' "$G" || fail "keys not unparked at screen-off"
grep -q 'O_RDONLY | O_NONBLOCK | O_CLOEXEC' "$G" || fail "input devices must be opened read-only, non-blocking"
grep -q 'EVIOCGRAB' "$G" && fail "input devices must never be grabbed"
# fix87: every screen transition publishes the state file (shell helpers read screen= there)
[ "$(grep -c 'write_state(&fsm, &metrics, cur_pred);' "$G")" -ge 6 ] || fail "screen transitions do not publish the state file"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS wake key hint (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  printf '#include <stdio.h>\n#include <string.h>\n#include <unistd.h>\n#include <fcntl.h>\n#include <linux/input.h>\n'
  printf '#define ASB_WAKE_KEY_MAX 6\nstatic int g_wake_key_fd[ASB_WAKE_KEY_MAX], g_wake_key_touch[ASB_WAKE_KEY_MAX], g_wake_key_n = 0;\n'
  sed -n '/^static int wake_key_drain(int fd) {/,/^}$/p' "$G"
  cat <<'X'
static int feed_t(int code, int value, int type, int touch) {
    int p[2]; if (pipe(p)) return -1;
    fcntl(p[0], F_SETFL, O_NONBLOCK);
    g_wake_key_n = 1; g_wake_key_fd[0] = p[0]; g_wake_key_touch[0] = touch;
    struct input_event e[2]; memset(e, 0, sizeof(e));
    e[0].type = type; e[0].code = code; e[0].value = value;
    e[1].type = EV_SYN;
    if (write(p[1], e, sizeof(e)) != (ssize_t)sizeof(e)) return -1;
    close(p[1]);
    int r = wake_key_drain(p[0]); close(p[0]); return r;
}
static int feed(int code, int value, int type) { return feed_t(code, value, type, 0); }
int main(void) {
    int bad = 0;
    if (feed(KEY_POWER, 1, EV_KEY) != 1) { puts("power press"); bad = 1; }
    if (feed(KEY_WAKEUP, 1, EV_KEY) != 1) { puts("wakeup press"); bad = 1; }
    if (feed(KEY_POWER, 0, EV_KEY) != 0) { puts("release must not count"); bad = 1; }
    if (feed(KEY_VOLUMEUP, 1, EV_KEY) != 0) { puts("volume must not count"); bad = 1; }
    if (feed_t(KEY_F4, 1, EV_KEY, 1) != 1) { puts("touch gesture F4 must count"); bad = 1; }
    if (feed_t(KEY_F4, 1, EV_KEY, 0) != 0) { puts("F4 on a plain key device must not count"); bad = 1; }
    if (feed_t(BTN_TOUCH, 1, EV_KEY, 1) != 0) { puts("a touch press must not count"); bad = 1; }
    return bad;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -o "$T/t" "$T/t.c" || fail "fixture did not compile"
"$T/t" || fail "drain classification wrong"
echo "PASS wake keys arm the screen-on re-check"
)

t_writer_ceiling_below_min_contract() (
# Contract: a min-freq clamped down to the ceiling is applied, not failed.
#
# Field report: eight FAILs for cpu_min (want 2438400, live 1632000/1747200) on a kernel
# doing exactly what it should - scaling_min_freq cannot exceed scaling_max_freq, and the
# vendor pulls the ceiling back down right after ASB writes it. The writer classifies this
# as ceiling_below_min: counted as applied, with a floor_holds backoff so a vendor that
# holds the ceiling for good is not re-asked on every transition.
#
# The danger in such a branch is scope creep: a wider condition would start excusing real
# write failures. These checks pin the branch to CPU_MIN nodes only, below the request
# only, and with the backoff wired to the existing retry_at mechanism.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WRITER="$ROOT/src/asb_writer.h"

fail() { printf '%s\n' "FAIL writer ceiling_below_min: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in ${1#$ROOT/}"; }

[ -f "$WRITER" ] || fail "asb_writer.h not found"

# The branch exists and is scoped to the CPU minimum nodes, success path only.
need "$WRITER" 'ceiling_below_min'
need "$WRITER" 'rc == 0 && node >= ASB_WRITE_CPU_MIN0 && node < ASB_WRITE_CPU_MIN0 + 3'
need "$WRITER" 'observed > 0 && observed < requested'

# It counts as applied and clears the failure counter - never the other way round.
need "$WRITER" 'h->applied++;'
need "$WRITER" 'h->consecutive_failures = 0;'

# The backoff: three holds -> leave the vendor alone for an hour; otherwise retry freely.
# The backoff is 300 s, matching the kernel_floor_higher branch.
#
# It was 3600 here and 300 there - the same situation seen from two sides, with two
# different answers. A capture showed the little cores held at 1.8 GHz because the module
# would not retry for an hour; shortening one branch and not the other left the asymmetry
# in place, and this assertion was what pinned it there.
#
# What the contract is really about is that the branch backs off at all, after three
# holds. That part is unchanged.
need "$WRITER" 'if (++h->floor_holds >= 3) h->retry_at = now + 300;'

# floor_holds must be state, not a local: the field lives in the writer state struct and
# is initialised where the other counters are.
need "$WRITER" 'unsigned long floor_holds;'
need "$WRITER" 'h->floor_holds = 0;'

# The branch must sit BEFORE the generic failure accounting, or failures would be
# counted first and the classification would never run. Order check, not just presence.
_branch_line="$(grep -Fn 'ceiling_below_min' "$WRITER" | head -1 | cut -d: -f1)"
_unsup_line="$(grep -Fn 'unsupported node is not a failure' "$WRITER" | head -1 | cut -d: -f1)"
[ -n "$_branch_line" ] && [ -n "$_unsup_line" ] || fail "cannot locate branch anchors"
[ "$_branch_line" -lt "$_unsup_line" ] || \
  fail "ceiling_below_min branch must precede the unsupported/failure classification"

printf '%s\n' 'PASS writer ceiling_below_min contract'
)

t_writer_hold_bypass_runtime() (
# Runtime (fix133): a vendor hold defers the request that was held, not a new one.
#
# After three readbacks above ASB's request (a vendor boost holding the CPU minimum up, so
# the ceiling reads back higher), writer_write_int_confirmed backs the node off for five
# minutes. That is right for the held value - it stays in the kernel's QoS set and takes
# effect when the boost ends. It was wrong for every OTHER value: a PLQ110 capture shows
# MODERATE wanting the main ceiling at 1785600 while the node was still backed off from
# three holds of the light-idle 1555200 - desired 1785600, requested 1555200, live 1555200
# for minutes. The REAL writer function is cut out of asb_writer.h and run against a fake
# node whose readback is max(request, vendor floor).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { echo "FAIL writer hold bypass: $*" >&2; exit 1; }
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "SKIP writer hold bypass: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Enum, health struct, counters and helpers up to and including the confirmed write.
sed -n '/^typedef enum {$/,/^static void writer_write_health_dump(FILE \*f) {$/p' "$W" | sed '$d' > "$T/w.c"
grep -q '^static int writer_write_int_confirmed(asb_write_node_t node, const char \*path, int requested) {$' "$T/w.c" \
  || fail "writer function not found"

: > "$T/node"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#include <unistd.h>
static int g_live = 0, g_vendor_floor = 0, g_writes = 0;
static int sysfs_read_int(const char *p, int d) { (void)p; return g_live ? g_live : d; }
static int sysfs_write_int(const char *p, int v) { (void)p; g_writes++; g_live = v > g_vendor_floor ? v : g_vendor_floor; return 0; }
static int sysfs_read_str(const char *p, char *b, size_t n) { (void)p; (void)b; (void)n; return -1; }
#include "w.c"
static const char *NODE;
static int put(int v) { return writer_write_int_confirmed(ASB_WRITE_CPU_MAX0, NODE, v); }
int main(int argc, char **argv) {
    int bad = 0;
    NODE = argc > 1 ? argv[1] : "/dev/null";
    asb_write_health_t *h = &g_write_health[ASB_WRITE_CPU_MAX0];
    /* A boost holds the floor at 1785600: three holds of 1555200 -> five-minute back-off. */
    g_vendor_floor = 1785600; g_live = 1785600;
    for (int i = 0; i < 3; i++) put(1555200);
    if (h->retry_at <= time(NULL)) { printf("no back-off after three holds\n"); bad = 1; }
    /* The held value itself waits. */
    int w0 = g_writes;
    if (put(1555200) != 1 || g_writes != w0) { printf("held value re-sent during the back-off\n"); bad = 1; }
    /* The boost ends; MODERATE wants 1785600 - a new request is sent at once. */
    g_vendor_floor = 0; g_live = 1555200;
    if (put(1785600) != 0 || g_live != 1785600) { printf("new ceiling swallowed by the back-off (live %d)\n", g_live); bad = 1; }
    if (h->hold_bypass != 1) { printf("bypass not counted\n"); bad = 1; }
    /* A clean write ends the run of holds: one later hold must not back off at once. */
    g_vendor_floor = 1996800;
    put(1555200);
    if (h->retry_at > time(NULL)) { printf("one hold after a clean write started the back-off\n"); bad = 1; }
    /* A failing node still waits, whatever it is asked: holddown is not a vendor hold. */
    h->retry_at = time(NULL) + 90; snprintf(h->status, sizeof(h->status), "%s", "external_policy_holddown");
    w0 = g_writes;
    if (put(1900800) != 1 || g_writes != w0) { printf("a holddown node was written\n"); bad = 1; }
    /* Not a CPU node: no bypass even on a vendor-hold status. */
    asb_write_health_t *u = &g_write_health[ASB_WRITE_UCL_TOP];
    u->retry_at = time(NULL) + 300; u->requested = 50; snprintf(u->status, sizeof(u->status), "%s", "kernel_floor_higher");
    w0 = g_writes;
    if (writer_write_int_confirmed(ASB_WRITE_UCL_TOP, NODE, 60) != 1 || g_writes != w0) { printf("non-CPU node bypassed\n"); bad = 1; }
    return bad;
}
X
"$CC" -O1 -Wall -Wno-unused-function -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "harness did not compile"; }
"$T/t" "$T/node" || fail "hold bypass wrong"
echo "PASS writer hold bypass: a held request waits, a new one is sent, a clean write ends the hold run"
)

t_night_window_chain_runtime() (
# Runtime (fix166): one night is one dark chain.
#
# Capture 29835 logged "onset sample 03:50 -> learned 00:47": asleep about 03:10, a one-minute
# glance at 03:50, and the second screen-off was learned as bedtime. Older captures carry two or
# three onsets in one night and "wake sample 13:06 -> learned 12:42" - a phone on a desk summing
# three hours of darkness by noon. The REAL learner, cut from the governor, runs those days tick
# by tick: one sample per night, onset = the chain's first screen-off, a glance changes nothing,
# ten minutes awake ends the chain, a daytime chain teaches nothing, a chain that began in the
# evening gives its wake but no bedtime, and a wake outside the window is rejected once.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL night window chain: $*" >&2; exit 1; }
grep -q 'asb_log("night_window: onset sample' "$G" && fail "the per-screen-off onset sample is back"
grep -q '^#define ASB_NIGHT_AWAKE_BREAK_S    600$' "$ROOT/src/asb_smart_defs.h" || fail "awake break constant"
CC=""; for c in ${HOST_CC:-} gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS night window chain (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
awk '/^#define NIGHT_WINDOW_FILE /{on=1} on{print} on&&/^static void asb_night_window_tick\(/{f=1} f&&/^}$/{exit}' "$G" \
  | sed "s|/data/adb/asb/night_window.conf|$T/nw.conf|" > "$T/n.c"
grep -q 'asb_night_wake_confirm' "$T/n.c" || fail "learner block not found"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "asb_smart_defs.h"
static struct { int night_quiet_auto; int night_quiet_auto_min_samples; } g_asb_cfg = { 1, 3 };
static char g_last_log[256];
static void asb_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static void asb_log(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vsnprintf(g_last_log, sizeof(g_last_log), fmt, ap); va_end(ap);
}
#define ASB_REC_FILE "rec.bin"
#define ASB_REC_SUMMARY "rec.txt"
#include "asb_record.h"   /* fix184: the night checks are learned from the same chain */
#include "n.c"
#define DAY0 1792022400L
static time_t at(int day, int h, int m) { return (time_t)(DAY0 + day * 86400L + h * 3600L + m * 60L); }
static time_t g_t;
static void run(int screen, time_t until) {
    for (; g_t < until; g_t += 30) asb_night_window_tick(screen, g_t);
}
static void fresh(time_t start) {
    g_night_sleep_min = -1; g_night_wake_min = -1; g_night_samples = 0;
    g_night_samples_accepted = 0; g_night_samples_rejected = 0;
    g_night_prev_screen = -1; g_night_off_since = 0; g_night_on_since = 0;
    asb_night_chain_end();
    g_last_log[0] = 0;
    g_t = start;
}
static int bad = 0;
#define CHK(c, what) do { if (!(c)) { printf("%s (sleep=%d wake=%d n=%d acc=%d rej=%d log=%s)\n", what, \
    g_night_sleep_min, g_night_wake_min, g_night_samples, g_night_samples_accepted, \
    g_night_samples_rejected, g_last_log); bad = 1; } } while (0)
int main(void) {
    /* Capture 29835: on until 03:10, a minute's glance at 03:50, face unlock at 06:20, up at 08:25. */
    fresh(at(0, 1, 50));
    run(1, at(0, 3, 10)); run(0, at(0, 3, 50)); run(1, at(0, 3, 51)); run(0, at(0, 6, 20));
    run(1, at(0, 6, 21)); run(0, at(0, 8, 25)); run(1, at(0, 8, 45));
    CHK(g_night_samples == 1 && g_night_samples_accepted == 1, "29835: not exactly one night");
    CHK(g_night_sleep_min == 3 * 60 + 10, "29835: bedtime is not the first screen-off (03:10)");
    CHK(g_night_wake_min == 8 * 60 + 25, "29835: the face unlock or a glance was learned as the wake");
    CHK(strstr(g_last_log, "night 03:10-08:25") != NULL, "29835: log line");
    /* fix184: the 03:50 glance came 40 min after bedtime - not a night check; the 06:20 face
     * unlock after three hours asleep is one. */
    CHK(g_rec.mw.total == 1 && g_rec.mw.nights == 1 && g_rec.mw.dur_ewma_s <= 90.0f, "29835: night checks learned wrong");
    /* The rest of that morning on a desk: glances under ten minutes, a long pickup at 13:06. */
    run(0, at(0, 10, 0)); run(1, at(0, 10, 5)); run(0, at(0, 11, 30)); run(1, at(0, 11, 33));
    run(0, at(0, 13, 6)); run(1, at(0, 13, 30));
    CHK(g_night_samples == 1 && g_night_wake_min == 8 * 60 + 25 && g_night_samples_rejected == 0,
        "desk: a midday pickup after three dark hours was learned (or rejected) as a night");
    /* Asleep at 23:00, a look at the clock at 02:30, up at 07:00: one night, nothing rejected. */
    fresh(at(1, 22, 0));
    run(1, at(1, 23, 0)); run(0, at(2, 2, 30)); run(1, at(2, 2, 31)); run(0, at(2, 7, 0)); run(1, at(2, 7, 20));
    CHK(g_night_samples == 1 && g_night_samples_rejected == 0, "glance at 02:30 rejected or split the night");
    CHK(g_night_sleep_min == 23 * 60 && g_night_wake_min == 7 * 60, "glance at 02:30 moved bedtime or wake");
    CHK(g_rec.mw.total == 2 && g_rec.mw.nights == 2, "the 02:30 night check was not learned (or the desk glances were)");
    /* Twenty minutes awake at 00:20 ends the first chain: bedtime is 00:40, learned once. */
    fresh(at(3, 22, 0));
    run(1, at(3, 23, 0)); run(0, at(4, 0, 20)); run(1, at(4, 0, 40)); run(0, at(4, 7, 0)); run(1, at(4, 7, 20));
    CHK(g_night_samples == 1 && g_night_sleep_min == 40 && g_night_wake_min == 7 * 60,
        "awake at 00:20 for 20 min: want one night 00:40-07:00");
    /* Phone down at 18:30, a glance at 21:35, up at 07:00: wake learned, bedtime not. */
    fresh(at(5, 18, 0));
    run(1, at(5, 18, 30)); run(0, at(5, 21, 35)); run(1, at(5, 21, 36)); run(0, at(6, 7, 0)); run(1, at(6, 7, 20));
    CHK(g_night_samples == 1 && g_night_sleep_min == -1 && g_night_wake_min == 7 * 60,
        "evening chain: want the wake and no bedtime");
    CHK(strstr(g_last_log, "bedtime not learned") != NULL, "evening chain: log line");
    /* Asleep 23:00, up at 15:00: rejected once, nothing learned. */
    fresh(at(7, 22, 0));
    run(1, at(7, 23, 0)); run(0, at(8, 15, 0)); run(1, at(8, 15, 30));
    CHK(g_night_samples == 0 && g_night_samples_rejected == 1 && g_night_wake_min == -1,
        "wake at 15:00: want one rejection");
    /* A wake whose confirming tick never ran: on 12 min, off before the tick saw ten. */
    fresh(at(9, 22, 0));
    run(1, at(9, 23, 0)); run(0, at(10, 6, 50));
    asb_night_window_tick(1, at(10, 6, 50)); asb_night_window_tick(0, at(10, 7, 2));
    CHK(g_night_samples == 1 && g_night_wake_min == 6 * 60 + 50, "a held wake seen only at the screen-off edge was lost");
    /* Learned window persists through the real save/load pair. */
    fresh(at(11, 22, 0));
    run(1, at(11, 23, 30)); run(0, at(12, 7, 10)); run(1, at(12, 7, 30));
    g_night_sleep_min = -1; g_night_wake_min = -1; g_night_samples = 0;
    asb_night_window_load();
    CHK(g_night_sleep_min == 23 * 60 + 30 && g_night_wake_min == 7 * 60 + 10 && g_night_samples == 1,
        "save/load round trip");
    if (!bad) printf("ok\n");
    return bad;
}
X
TZ=UTC0 "$CC" -O1 -Wall -Wno-unused-function -I"$ROOT/src" -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "harness did not compile"; }
out="$(TZ=UTC0 "$T/t")" || { printf '%s\n' "$out" >&2; fail "learner wrong"; }
echo "PASS night window chain: one sample per night, bedtime = the chain's first screen-off, glances and face unlock change nothing, a desk day teaches nothing"
)

t_current_corroboration_runtime() (
# Runtime (fix179): battery current corroborates a busy CPU only above THIS phone's idle load.
#
# "current >= 250 mA and load1 >= 60% of the MODERATE threshold" read 8.4 on a CPH2769 that
# idles at 6.3-8.3 with the screen on and draws over 250 mA on any content: it was the only
# reason for MODERATE in 240 of 535 quiet screen-on samples of capture 30423. The REAL helper
# is cut out of asb_fsm.h and fed the device floors from the captures.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL current corroboration: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP current corroboration: no C compiler"; exit 0; }
awk '/^static float asb_current_corroboration_bar\(/ { f = 1 } f { print } f && /^}/ { exit }' "$F" > "$T/h.c"
grep -q 'quiet_floor' "$T/h.c" || fail "helper not found"
# The rule uses it, and the fixed 60% bar is gone from the rule.
grep -q 'm->cpu.load1 >= asb_current_corroboration_bar(mod_thr, asb_ui_quiet_floor(m)))' "$F" || fail "the current rule does not use the device floor"
grep -q 'm->cpu.load1 >= mod_thr \* 0.6f)' "$F" && fail "the fixed 60% bar is still in the current rule"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <math.h>
#include "h.c"
static int bad = 0;
static void near(float got, float want, const char *msg) {
    if (fabsf(got - want) > 0.05f) { printf("%s: got %.2f want %.2f\n", msg, got, want); bad = 1; }
}
int main(void) {
    near(asb_current_corroboration_bar(14.0f, -1.0f), 8.4f, "no floor learned keeps the old bar");
    near(asb_current_corroboration_bar(14.0f, 0.5f),  8.6f, "a phone idling near zero keeps about the old bar");
    near(asb_current_corroboration_bar(14.0f, 6.27f), 10.91f, "CPH2769 capture 30423 floor");
    near(asb_current_corroboration_bar(14.0f, 5.86f), 10.74f, "CPH2769 capture 13290 floor");
    near(asb_current_corroboration_bar(14.0f, 20.0f), 8.4f, "a floor above the threshold is ignored");
    near(asb_current_corroboration_bar(20.0f, 6.0f),  14.4f, "follows the profile's own threshold");
    /* Never lower than the old bar: no device gains MODERATE from this. */
    for (float q = 0.01f; q < 14.0f; q += 0.37f)
        if (asb_current_corroboration_bar(14.0f, q) < 8.4f - 0.001f) { printf("below the old bar at %.2f\n", q); bad = 1; }
    /* The quiet CPH2769 loads (median 8.34) no longer clear it; real work near 14 still does. */
    float qf = 6.27f, b = asb_current_corroboration_bar(14.0f, qf);
    if (8.34f >= b || 7.74f >= b) { printf("an idle CPH2769 still clears the bar\n"); bad = 1; }
    if (!(12.5f >= b)) { printf("work just under the threshold no longer corroborates\n"); bad = 1; }
    if (!bad) printf("ok\n");
    return bad;
}
X
"$CC" -std=gnu99 -Wall -o "$T/t" "$T/t.c" -lm 2>"$T/cc.err" || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS current corroboration: the battery-current shortcut to MODERATE starts above this phone's own idle load, never below the old bar"
)

t_sustained_repeat_runtime() (
# Runtime (fix181): SUSTAINED that keeps coming back stays longer, and its cooldowns are armed.
#
# CPH2691 capture 8952: eight SUSTAINED entries in 22 minutes, each left after ~30 s, one
# re-entered 16 s after leaving under a 24 s re-entry cooldown - the hook that armed it sat
# before the ladder transition, where state_changed could never be set. The REAL helpers are
# cut out of asb_fsm.h and driven through an enter/exit sequence.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL sustained repeat: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP sustained repeat: no C compiler"; exit 0; }
# Placement: armed after every transition of the tick, the dead pre-transition hook gone,
# and the dwell doubled where SUSTAINED is left.
grep -q '^    fsm_sustained_edges(fsm, time(NULL));$' "$F" || fail "edges not recorded after the transitions"
awk '/^static int fsm_update\(/ { f = 1 } f && /fsm_sustained_edges\(fsm, time\(NULL\)\)/ { e = NR } f && /thermal_cap = real thermal OR hard vendor clamp/ { t = NR; exit } END { exit !(e && t && e < t) }' "$F" \
  || fail "edges recorded after the caps instead of right after the transitions"
grep -q 'fsm->prev_state == ASB_STATE_SUSTAINED &&$' "$F" && fail "the pre-transition SUSTAINED hook is back"
grep -q 'min_dwell = asb_sustained_dwell_s(min_dwell, fsm->sus_repeat);' "$F" || fail "the dwell is not doubled on quick re-entries"
{
  echo '#include <stdio.h>'
  echo '#include <time.h>'
  echo 'enum { ASB_STATE_DEEP_IDLE = 0, ASB_STATE_LIGHT_IDLE, ASB_STATE_MODERATE, ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, ASB_STATE_GAMING };'
  echo 'typedef struct { int state, prev_state, state_changed, clamp_hold, sus_repeat; time_t recovery_cautious_until, sus_last_exit, gaming_retry_until, sustained_reentry_until; } asb_fsm_t;'
  echo 'static struct { int gaming_retry_cooldown_s, sustained_reentry_cooldown_s; } g_asb_cfg = { 18, 24 };'
  sed -n '/^#define ASB_SUS_REPEAT_WINDOW_S/,/^#define ASB_SUS_DWELL_MAX_S/p' "$F"
  awk '/^static int asb_sustained_dwell_s\(/ { f = 1 } f { print } f && /^}/ { exit }' "$F"
  awk '/^static void fsm_sustained_edges\(/ { f = 1 } f { print } f && /^}/ { exit }' "$F"
  cat <<'EOF'
static int bad = 0;
#define CHK(c, m) do { if (!(c)) { printf("%s\n", m); bad = 1; } } while (0)
static asb_fsm_t f;
static void step(int from, int to, time_t now) { f.prev_state = from; f.state = to; f.state_changed = (from != to); fsm_sustained_edges(&f, now); }
int main(void) {
    CHK(asb_sustained_dwell_s(24, 0) == 24, "a single entry keeps its dwell");
    CHK(asb_sustained_dwell_s(24, 1) == 48 && asb_sustained_dwell_s(24, 2) == 96, "doubling");
    CHK(asb_sustained_dwell_s(24, 3) == 180 && asb_sustained_dwell_s(100, 3) == 180, "capped at 180 s");
    CHK(asb_sustained_dwell_s(0, 3) == 0, "no dwell configured stays none");
    time_t t = 1000;
    step(ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, t);          CHK(f.sus_repeat == 0, "first entry");
    step(ASB_STATE_SUSTAINED, ASB_STATE_MODERATE, t + 30);   CHK(f.sus_last_exit == t + 30, "exit time");
    CHK(f.sustained_reentry_until == t + 30 + 24, "re-entry cooldown armed on an ordinary ladder exit");
    CHK(f.gaming_retry_until == t + 30 + 18, "gaming retry cooldown armed");
    step(ASB_STATE_MODERATE, ASB_STATE_MODERATE, t + 40);    CHK(f.sustained_reentry_until == t + 54, "no transition, nothing moves");
    step(ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, t + 120);     CHK(f.sus_repeat == 1, "re-entered within 5 min");
    step(ASB_STATE_SUSTAINED, ASB_STATE_MODERATE, t + 170);
    step(ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, t + 200);     CHK(f.sus_repeat == 2, "again");
    step(ASB_STATE_SUSTAINED, ASB_STATE_MODERATE, t + 300);
    step(ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, t + 330);     CHK(f.sus_repeat == 3, "third quick re-entry");
    step(ASB_STATE_SUSTAINED, ASB_STATE_MODERATE, t + 500);
    step(ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, t + 520);     CHK(f.sus_repeat == 3, "held at 3");
    step(ASB_STATE_SUSTAINED, ASB_STATE_DEEP_IDLE, t + 600);  CHK(f.sus_last_exit == t + 600, "a forced screen-off exit counts");
    step(ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, t + 600 + 301); CHK(f.sus_repeat == 0, "five quiet minutes reset it");
    f.clamp_hold = 1; step(ASB_STATE_SUSTAINED, ASB_STATE_MODERATE, t + 1000);
    CHK(f.sustained_reentry_until == t + 1000 + 48, "clamp hold doubles the re-entry cooldown");
    if (!bad) printf("ok\n");
    return bad;
}
EOF
} > "$T/t.c"
"$CC" -std=gnu99 -Wall -Wno-unused-function -o "$T/t" "$T/t.c" 2>"$T/cc.err" || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS sustained repeat: quick SUSTAINED re-entries hold longer (24/48/96/180 s), re-entry and gaming-retry cooldowns armed on every exit"
)

t_shell_cap_owner_runtime() (
# Runtime (fix182/fix183): in a manual profile the governor judges the live ceiling against the
# one the shell wrote, holds a thermal cap or cooldown at or under it, and hands its own writes
# back. OP15 Battery capture 25307: the shell's own 1785600/1747200 classified vendor_clamp all
# day; CPH2747 capture 22454: 5.5 h of "Battery" on Smart's last 1555200/1862400. The REAL
# helpers are cut out of asb_writer.h and asb_governor.c and run against a fake cpufreq tree.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; W="$ROOT/src/asb_writer.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL shell cap owner: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP shell cap owner: no C compiler"; exit 0; }
awk '/^#ifndef ASB_SHELL_CAPS_PATH/{on=1} /^static const int g_cluster_first_cpu/{on=0} on' "$W" > "$T/w.c"
awk '/^static int asb_manual_shell_owns_caps/{on=1} /^static int atomic_write_file/{on=0} on' "$G" > "$T/g.c"
grep -q 'writer_manual_handback' "$T/w.c" && grep -q 'cap_source_classify_shell' "$T/g.c" || fail "helpers not found"
grep -Fq 'int shell_cap_p0 = asb_shell_cap_khz(fsm, 0);' "$G" || fail "status classification does not use the shell record"
grep -Fq 'const int shell_mode = asb_manual_shell_owns_caps(&fsm);' "$G" || fail "ceiling watch does not use the shell record"
grep -Fq 'cap_writer=%s\nshell_cpu_max0=%d\nshell_cpu_max_prime=%d\n' "$G" || fail "state does not publish cap_writer / shell_cpu_max*"
grep -Fq 'writes += writer_manual_handback(manual_prof_idx, state);' "$W" || fail "the writer does not hand ceilings back in a manual profile"
grep -Fq 'const int manual_override = manual_profile && (thermal_cap || g_fsm_cooldown_active);' "$W" || fail "the cooldown still never reaches a manual profile's ceilings"
[ "$(grep -c 'writer_manual_clamp(manual_prof_idx' "$W")" -ge 3 ] || fail "an override path can still raise a manual ceiling"
grep -Fq 'writer_mark_slot_held(ci, 2);' "$G" || fail "anti-clamp writes are not handed back"
for p in 0 6; do mkdir -p "$T/cpufreq/policy$p"; done
cat > "$T/t.c" <<X
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>
#define PROFILE_BATTERY 0
#define PROFILE_BALANCED 1
#define PROFILE_PERFORMANCE 2
#define PROFILE_SMART 3
#define ASB_SHELL_CAPS_PATH "$T/shell_cpu_caps"
typedef enum { ASB_STATE_DEEP_IDLE, ASB_STATE_LIGHT_IDLE, ASB_STATE_MODERATE, ASB_STATE_HEAVY,
               ASB_STATE_SUSTAINED, ASB_STATE_GAMING } asb_state_t;
typedef struct { int profile_idx; int thermal_cap; } asb_fsm_t;
static int fsm_profile_is_smart = 0, fsm_profile_is_performance = 0, g_fsm_cooldown_active = 0;
static int g_unlock_lift_now = 0;   /* fix212: while 1, the governor owns the ceilings */
static int g_cpu_policy_ids[3] = {0, 6, -1};
static char g_cpu_max_paths[3][128];
static char g_cpu_all_max_paths[16][128];
static int  g_cpu_all_paths_slot[16];
static int  g_cpu_all_paths_n = 0;
static struct { int cpu_max[3]; } g_wcache;
static int g_fsm_slot_req_khz[3];
static const char *asb_profile_name(int i) {
    return i == 0 ? "battery" : i == 2 ? "performance" : i == 3 ? "smart" : "balanced";
}
static int sysfs_read_int(const char *p, int d) { FILE *f = fopen(p, "r"); int v = d; if (f) { if (fscanf(f, "%d", &v) != 1) v = d; fclose(f); } return v; }
static int sysfs_write_int(const char *p, int v) { FILE *f = fopen(p, "w"); if (!f) return -1; fprintf(f, "%d\n", v); fclose(f); return 0; }
static int g_writes_seen = 0;
#include "$T/w.c"
#include "$T/g.c"
static void put(const char *path, const char *body) { FILE *o = fopen(path, "w"); fputs(body, o); fclose(o); }
static void again(void) { g_shell_live.checked = 0; g_shell_pre[0].checked = 0; g_shell_pre[1].checked = 0; }
int main(void) {
    int bad = 0;
    asb_fsm_t f = { PROFILE_BATTERY, 0 };
    if (asb_shell_cap_khz(&f, 0) != 0) { puts("no record must mean unknown"); bad = 1; }
    /* Booted in Smart: only the precomputed screen-on rungs exist. */
    put("$T/shell_cpu_caps.battery", "profile=battery\nscreen_on=1\nts=1\nprecomputed=1\npolicy0=1785600\npolicy6=1747200\n");
    put("$T/shell_cpu_caps.balanced", "profile=balanced\nscreen_on=1\nts=1\nprecomputed=1\npolicy0=3628800\npolicy6=4608000\n");
    again();
    if (asb_shell_cap_khz(&f, 0) != 1785600 || asb_shell_cap_khz(&f, 1) != 1747200) { puts("precomputed battery rung not used"); bad = 1; }
    f.profile_idx = PROFILE_BALANCED;
    if (asb_shell_cap_khz(&f, 1) != 4608000) { puts("precomputed balanced rung not used"); bad = 1; }
    /* What the shell actually wrote wins for its own profile. */
    put("$T/shell_cpu_caps", "profile=battery\nscreen_on=1\nts=2\npolicy0=1670400\npolicy6=1632000\n");
    again(); f.profile_idx = PROFILE_BATTERY;
    if (asb_shell_cap_khz(&f, 0) != 1670400) { puts("the written record must win over the precomputed one"); bad = 1; }
    f.profile_idx = PROFILE_BALANCED;
    if (asb_shell_cap_khz(&f, 0) != 3628800) { puts("a written battery record was used for balanced"); bad = 1; }
    /* fix189: a written record with no value for a policy (the boot clamp read every write
     * back lower) must not hide the precomputed rung - Balanced kept 1555200/1862400. */
    put("$T/shell_cpu_caps", "profile=balanced\nscreen_on=1\nts=3\n");
    again();
    if (asb_shell_cap_khz(&f, 0) != 3628800 || asb_shell_cap_khz(&f, 1) != 4608000) { puts("an empty written record hid the precomputed balanced rung"); bad = 1; }
    put("$T/shell_cpu_caps", "profile=battery\nscreen_on=1\nts=2\npolicy0=1670400\npolicy6=1632000\n");
    again();
    f.profile_idx = PROFILE_BATTERY;
    if (strcmp(cap_source_classify_shell(1670400, 1670400, 3628800), "shell_applied")) { puts("own cap"); bad = 1; }
    if (strcmp(cap_source_classify_shell(1747200, 1632000, 4608000), "vendor_clamp")) { puts("clamp under the shell cap"); bad = 1; }
    if (strcmp(cap_source_classify_shell(1785600, 2361600, 3628800), "shell_overridden_up")) { puts("raised above the shell cap"); bad = 1; }
    if (strcmp(cap_source_classify_shell(1785600, 3700000, 3628800), "policy_unknown")) { puts("above hardware"); bad = 1; }
    f.thermal_cap = 1;
    if (asb_shell_cap_khz(&f, 0) != 0) { puts("thermal cap: the governor writes, the shell record must not be the owner"); bad = 1; }
    f.thermal_cap = 0; g_fsm_cooldown_active = 1;
    if (asb_manual_shell_owns_caps(&f)) { puts("cooldown: the governor writes, the shell is not the owner"); bad = 1; }
    g_fsm_cooldown_active = 0;
    g_unlock_lift_now = 1;
    if (asb_manual_shell_owns_caps(&f)) { puts("lift: the governor owns the ceilings"); bad = 1; }
    g_unlock_lift_now = 0;
    f.profile_idx = PROFILE_SMART; fsm_profile_is_smart = 1;
    if (asb_manual_shell_owns_caps(&f) || asb_shell_cap_khz(&f, 0) != 0) { puts("Smart owns its ceilings"); bad = 1; }
    fsm_profile_is_smart = 0; f.profile_idx = PROFILE_BATTERY;
    /* An override never raises a manual ceiling. */
    if (writer_manual_clamp(PROFILE_BATTERY, "$T/cpufreq/policy6/scaling_max_freq", 1862400) != 1632000) { puts("the race-to-idle floor raised the Battery prime"); bad = 1; }
    if (writer_manual_clamp(PROFILE_BATTERY, "$T/cpufreq/policy0/scaling_max_freq", 1440000) != 1440000) { puts("a lower override value was lifted"); bad = 1; }
    if (asb_policy_id_of_path("$T/cpufreq/policy6/scaling_max_freq") != 6) { puts("policy id"); bad = 1; }
    /* Hand-back: Smart left its ceilings, a switch to Battery gives the shell's back. */
    snprintf(g_cpu_all_max_paths[0], 128, "%s", "$T/cpufreq/policy0/scaling_max_freq");
    snprintf(g_cpu_all_max_paths[1], 128, "%s", "$T/cpufreq/policy6/scaling_max_freq");
    g_cpu_all_paths_slot[0] = 0; g_cpu_all_paths_slot[1] = 1; g_cpu_all_paths_n = 2;
    memcpy(g_cpu_max_paths[0], g_cpu_all_max_paths[0], 128);
    memcpy(g_cpu_max_paths[1], g_cpu_all_max_paths[1], 128);
    sysfs_write_int(g_cpu_all_max_paths[0], 1555200); sysfs_write_int(g_cpu_all_max_paths[1], 1862400);
    g_writer_path_held[0] = 1; g_writer_path_held[1] = 1; g_wcache.cpu_max[0] = 1555200; g_wcache.cpu_max[1] = 1862400;
    int w = writer_manual_handback(PROFILE_BATTERY, ASB_STATE_LIGHT_IDLE);
    if (w != 2 || sysfs_read_int(g_cpu_all_max_paths[0], 0) != 1670400 || sysfs_read_int(g_cpu_all_max_paths[1], 0) != 1632000) {
        printf("hand-back after a switch: writes=%d main=%d prime=%d\n", w, sysfs_read_int(g_cpu_all_max_paths[0], 0), sysfs_read_int(g_cpu_all_max_paths[1], 0)); bad = 1; }
    if (g_writer_path_held[0] || g_writer_path_held[1] || g_wcache.cpu_max[0] || g_wcache.cpu_max[1]) { puts("hand-back left the paths marked as ASB's"); bad = 1; }
    if (writer_manual_handback(PROFILE_BATTERY, ASB_STATE_LIGHT_IDLE) != 0) { puts("a second pass wrote again"); bad = 1; }
    /* The anti-clamp's write stays while HEAVY runs, goes back after it. */
    sysfs_write_int(g_cpu_all_max_paths[0], 2400000); writer_mark_slot_held(0, 2);
    writer_manual_handback(PROFILE_BALANCED, ASB_STATE_HEAVY);
    if (sysfs_read_int(g_cpu_all_max_paths[0], 0) != 2400000) { puts("the anti-clamp write was undone during HEAVY"); bad = 1; }
    writer_manual_handback(PROFILE_BALANCED, ASB_STATE_MODERATE);
    if (sysfs_read_int(g_cpu_all_max_paths[0], 0) != 3628800) { puts("the anti-clamp write was not handed back after HEAVY"); bad = 1; }
    /* No record for a path: nothing is written, the mark stays for a later pass. */
    remove("$T/shell_cpu_caps"); remove("$T/shell_cpu_caps.battery"); again();
    sysfs_write_int(g_cpu_all_max_paths[1], 1862400); g_writer_path_held[1] = 1;
    if (writer_manual_handback(PROFILE_BATTERY, ASB_STATE_LIGHT_IDLE) != 0 || !g_writer_path_held[1]) { puts("handed back with no shell value"); bad = 1; }
    (void)g_writes_seen;
    return bad;
}
X
"$CC" -std=gnu11 -Wall -Werror -Wno-unused-function -o "$T/t" "$T/t.c" || fail "harness does not compile"
"$T/t" || fail "behaviour"
echo "PASS shell cap owner: the shell's ceiling is the reference, overrides stay under it, the governor's writes go back"
)

t_smart_records_runtime() (
# Runtime (fix184, Smart V5 in fix185): Smart records. Per situation the governor measures the
# POWER drawn (charge counter x battery voltage), alternates the best setting with one
# neighbour and compares them side by side - each challenger block with the champion block
# next to it, only when the two were close in time, battery temperature and charge. The
# cheaper one is kept only when the gain clears the noise (screen on: without pinning the
# cores more); a loss turns round; the plateau stops it. Charging, the 20 minutes after it,
# a battery under 10 % and a battery warming or cooling by 3 C are set aside with the reason
# counted. Night checks are learned by time and length and survive the fix184 -> fix185 store
# change. The REAL asb_record.h runs against a simulated battery whose power depends on the
# setting and whose voltage falls with the charge.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/src/asb_record.h"; G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL smart records: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP smart records: no C compiler"; exit 0; }
grep -q '#include "asb_record.h"' "$G" || fail "governor does not include the records"
grep -Fq 'asb_rec_tick(&_ri);' "$G" || fail "no records tick"
grep -Fq '_ri.voltage_uv  = metrics.bat.voltage_uv;' "$G" || fail "no voltage: power cannot be measured"
grep -Fq '_ri.bat_temp_dc = metrics.bat.temp_dC;' "$G" || fail "no battery temperature: climate cannot be seen"
grep -Fq '_ri.soc         = metrics.bat.capacity_pct;' "$G" || fail "no charge level"
grep -Fq 'if (_rc_prev_chg == 1 && !metrics.bat.charging) _rc_unplug_ms = _ri.now_ms;' "$G" || fail "the unplug moment is not tracked"
grep -Fq 'asb_rec_apply_offcaps(&_effective_caps, &fsm, metrics.misc.screen_on);   /* fix184 */' "$G" || fail "screen-off setting not applied before the writer"
[ "$(grep -c 'asb_rec_apply_offcaps(&_effective_caps, &fsm, metrics.misc.screen_on)' "$G")" -ge 2 ] || fail "the heartbeat write would undo the screen-off setting"
grep -Fq 'if (screen_on && (g_rec_on_offset != 0 || g_smooth_lean != 0)) {' "$G" || fail "screen-on lean not applied in the Smart tick"
awk '/g_rec_on_applied = _off;/{a=NR} /4\. Safety overrides/{if(a) {print "ok"; exit}}' "$G" | grep -qx ok || fail "the lean must come before the safety layers"
grep -Fq '(!metrics.misc.screen_on || g_mw_active) &&' "$G" || fail "night checks do not keep the night radio mode"
grep -Fq 'asb_mw_note((long)g_night_on_since, (long)(now - g_night_on_since));' "$G" || fail "night checks are not learned"
grep -q '^smart_records=1$' "$ROOT/config/governor.conf" && grep -q '^smart_microwake=1$' "$ROOT/config/governor.conf" || fail "not shipped on"
grep -q '^smart_records|internal|' "$ROOT/config/key_ownership.tsv" || fail "keys not registered"
cat > "$T/t.c" <<X
#define ASB_REC_FILE "$T/rec.bin"
#define ASB_REC_SUMMARY "$T/rec.txt"
#include "$R"
#include <stdlib.h>
#define CAP_UAH 7000000.0
static double g_uah = 3500000.0;   /* the simulated counter, µAh (50 %) */
static int g_cc_ok = 1, g_bright = 20;
static long long g_net = 0;
static long fake_cc(void) { return g_cc_ok ? ((long)(g_uah / 1000.0)) * 1000L : -1; }
static long long fake_net(void) { return g_net; }
static int fake_bright(void) { return g_bright; }
static unsigned g_seed = 12345;
static double noise(void) { g_seed = g_seed * 1103515245u + 12345u; return ((double)((g_seed >> 16) % 2001) / 1000.0) - 1.0; }
static long long g_ms = 0; static long g_wall = 1792440000L, g_unplug_wall = 0;
static int soc(void) { int p = (int)(g_uah * 100.0 / CAP_UAH); return p < 0 ? 0 : p > 100 ? 100 : p; }
static double volts(void) { return 3.50 + 0.80 * soc() / 100.0; }
/* Power is the setting's property; the current is what the voltage makes of it.
 * Screen off: x0.875 is 8 % cheaper than today's, x0.75 back up again. */
static double off_mw(int scale) { switch (scale) { case 750: return 183.0; case 875: return 177.0; case 1000: return 192.0; case 1250: return 200.0; default: return 212.0; } }
/* Screen on: more economy is cheaper, but +0.2 pins the cores far more often. */
static double on_mw(int off) { return 1540.0 - 0.6 * off; }
static double (*g_mul)(asb_rec_in_t *in) = 0;   /* a climate effect on the drain, per test */
static int g_flat = 0;                          /* every setting costs the same */
static int (*g_temp)(void) = 0;                 /* battery temperature, per test */
static void fill(asb_rec_in_t *in) {
    in->now_ms = g_ms; in->wall = g_wall;
    in->soc = soc(); in->voltage_uv = (int)(volts() * 1e6);
    in->bat_temp_dc = g_temp ? g_temp() : 250;
    in->unplug_age_s = g_unplug_wall ? g_wall - g_unplug_wall : 1000000L;
}
static void run(asb_rec_in_t *in, int ticks, int step_s, int screen) {
    for (int i = 0; i < ticks; i++) {
        double mw = screen ? on_mw(g_rec_on_offset) : (g_flat ? 190.0 : off_mw(g_rec_off_scale));
        if (g_mul) mw *= g_mul(in);
        mw *= 1.0 + noise() * (screen ? 0.015 : 0.012);
        double ma = mw / volts();
        if (in->charging) g_uah += 3000.0 * step_s / 3.6; else g_uah -= ma * step_s / 3.6;
        if (g_uah > CAP_UAH) g_uah = CAP_UAH;
        g_ms += (long long)step_s * 1000; g_wall += step_s;
        fill(in);
        in->at_ceiling = screen ? ((g_rec_on_offset >= 200) ? (i % 2 == 0) : (i % 5 == 0)) : 0;
        asb_rec_tick(in);
    }
}
/* Charge back to 95 % when low - the real day: the records must ride over it. */
static void maybe_charge(asb_rec_in_t *in, int screen) {
    if (soc() >= 30) return;
    in->charging = 1;
    while (soc() < 95) run(in, 1, 60, screen);
    in->charging = 0; g_unplug_wall = g_wall;
}
static int arm_temp(void) { return (g_rec_blk.active && g_rec_blk.slot == 1) ? 248 : 220; }
static double arm_cold(asb_rec_in_t *in) { return (in->bat_temp_dc < 235) ? 1.10 : 1.0; }
static int g_ramp_t = 250;
static int ramp_temp(void) { return g_ramp_t; }
int main(void) {
    int bad = 0;
    g_rec_read_cc = fake_cc; g_rec_read_net = fake_net; g_rec_read_bright_pct = fake_bright;
    if (asb_rec_load() != 0) { puts("fresh start expected"); bad = 1; }
    for (int i = 0; i < ASB_REC_CTX_N; i++)
        if (g_rec.ctx[i].champion != ASB_REC_ARM_DEFAULT) { puts("champion must start at today's setting"); bad = 1; }
    asb_rec_in_t in; memset(&in, 0, sizeof(in));
    in.enabled = 1; in.explore = 1;
    in.screen_on = 0; in.idle_state = 1; in.night = 1;
    fill(&in);
    /* Charging: nothing is measured, nothing is changed. */
    in.charging = 1; run(&in, 10, 60, 0);
    if (g_rec.ctx[ASB_REC_OFF_NIGHT].blocks != 0 || g_rec_blk.active) { puts("a charging block was counted"); bad = 1; }
    /* The first 20 minutes after the charger: the pack is warm, the voltage relaxing - not yet. */
    in.charging = 0; g_unplug_wall = g_wall;
    run(&in, 15, 60, 0);
    if (g_rec_blk.active) { puts("a block started right after the charger"); bad = 1; }
    run(&in, 7, 60, 0);
    if (!g_rec_blk.active) { puts("no block once the pack settled"); bad = 1; }
    /* A busy radio (20 KiB/s): set aside, counted as radio. */
    for (int i = 0; i < 45; i++) { g_net += 20 * 1024 * 60; run(&in, 1, 60, 0); }
    if (g_rec.ctx[ASB_REC_OFF_NIGHT].blocks != 0) { puts("a radio-dominated block was counted"); bad = 1; }
    if (g_rec_rej[REJ_RADIO] == 0) { puts("the radio block was not counted as radio"); bad = 1; }
    /* In from the cold: the pack warms by 4 C with the screen off - the room, not the setting. */
    g_temp = ramp_temp; g_ramp_t = 60; g_rec_blk.active = 0;
    for (int i = 0; i < 41; i++) { g_ramp_t = 60 + i; run(&in, 1, 60, 0); }
    if (g_rec.ctx[ASB_REC_OFF_NIGHT].blocks != 0 || g_rec_rej[REJ_CLIMATE] == 0) { puts("a block that warmed by 4 C was counted"); bad = 1; }
    g_temp = 0;
    /* Many nights of quiet screen-off blocks, with recharges. */
    int scale_seen_875 = 0;
    for (int n = 0; n < 60 * 10 && !g_rec.ctx[ASB_REC_OFF_NIGHT].converged; n++) {
        run(&in, 41, 60, 0);
        maybe_charge(&in, 0);
        if (g_rec_off_scale == 875) scale_seen_875 = 1;
    }
    asb_rec_ctx_t *c = &g_rec.ctx[ASB_REC_OFF_NIGHT];
    if (!c->converged) { printf("screen off never reached its plateau: champion %d trials %u\n", c->champion, c->trials); bad = 1; }
    if (g_rec_off_scale_x1000[c->champion] != 875) { printf("screen off kept %d, the cheapest is 875\n", g_rec_off_scale_x1000[c->champion]); bad = 1; }
    if (c->wins < 1 || c->baseline_n == 0 || c->baseline_mw < 186.0f || c->baseline_mw > 198.0f) { printf("baseline %.1f mW (%u) wins %u\n", c->baseline_mw, c->baseline_n, c->wins); bad = 1; }
    if (c->record_mw < 171.0f || c->record_mw > 183.0f) { printf("record %.1f mW is not the cheap setting's\n", c->record_mw); bad = 1; }
    if (c->gain_total > 0.96f || c->gain_total < 0.88f) { printf("side-by-side gain %.3f, ~0.92 expected\n", c->gain_total); bad = 1; }
    if (!scale_seen_875) { puts("the knob never showed the setting being measured"); bad = 1; }
    if (g_rec_rej[REJ_CHARGE] + g_rec_blocks_ok == 0) { puts("nothing measured"); bad = 1; }
    /* After the plateau the best setting stays in force. */
    run(&in, 5, 60, 0);
    if (g_rec_off_scale != 875) { printf("off scale %d after the plateau\n", g_rec_off_scale); bad = 1; }
    /* The cooldown takes the ceilings: the knob steps aside. */
    in.cooldown = 1; run(&in, 2, 60, 0);
    if (g_rec_off_scale != 1000) { puts("the setting was applied under the cooldown"); bad = 1; }
    in.cooldown = 0;
    /* Music with the screen off keeps the CPU awake: x1, and a mostly-busy block is set aside. */
    in.idle_state = 0; run(&in, 1, 60, 0);
    if (g_rec_off_scale != 1000) { puts("a setting was tried under screen-off music"); bad = 1; }
    unsigned long rj = g_rec_rej[REJ_BUSY]; unsigned bl = g_rec.ctx[ASB_REC_OFF_NIGHT].blocks;
    g_rec_blk.active = 0; run(&in, 45, 60, 0);
    if (g_rec.ctx[ASB_REC_OFF_NIGHT].blocks != bl || g_rec_rej[REJ_BUSY] <= rj) { puts("a block full of music was counted"); bad = 1; }
    in.idle_state = 1;
    /* The climate must not be credited to a setting. By day, the two settings cost the same,
     * but every champion block happens to run 2.8 C colder and 10 % dearer: block by block
     * the challenger looks about 9 % cheaper. No pair forms across that gap, so nothing is
     * promoted - an unpaired comparison would have declared a winner. */
    in.night = 0; g_temp = arm_temp; g_mul = arm_cold; g_flat = 1; g_rec_blk.active = 0;
    for (int n = 0; n < 60; n++) { run(&in, 41, 60, 0); maybe_charge(&in, 0); }
    asb_rec_ctx_t *dy = &g_rec.ctx[ASB_REC_OFF_DAY];
    if (dy->challenger == dy->champion || dy->trial[1].n < 10 || dy->trial[0].n < 10) { printf("the day trial did not run (%u/%u)\n", dy->trial[0].n, dy->trial[1].n); bad = 1; }
    if (!(dy->trial[1].mean < dy->trial[0].mean * 0.95)) { printf("the setup is wrong: %.1f vs %.1f\n", dy->trial[1].mean, dy->trial[0].mean); bad = 1; }
    if (dy->wins != 0 || dy->champion != ASB_REC_ARM_DEFAULT || dy->pairs != 0) { printf("the climate was credited: wins %u champion %d pairs %u\n", dy->wins, dy->champion, dy->pairs); bad = 1; }
    g_temp = 0; g_mul = 0; g_flat = 0;
    /* Under 10 %: the voltage sags, the gauge's model is at its edge - not measured. */
    { double keep = g_uah; g_uah = CAP_UAH * 0.08; g_rec_blk.active = 0; run(&in, 30, 60, 0);
      if (g_rec_blk.active) { puts("a block under 10 %"); bad = 1; } g_uah = keep; }
    /* Screen on, dim, light apps. */
    in.screen_on = 1; in.idle_state = 0; in.night = 0; g_unplug_wall = 0;
    for (int n = 0; n < 600 && !g_rec.ctx[ASB_REC_ON_LIGHT_DIM].converged; n++) { run(&in, 11, 60, 1); maybe_charge(&in, 1); }
    asb_rec_ctx_t *o = &g_rec.ctx[ASB_REC_ON_LIGHT_DIM];
    if (!o->converged) { printf("screen on never reached its plateau: champion %d trials %u\n", o->champion, o->trials); bad = 1; }
    if (g_rec_on_offset_x1000[o->champion] != 100) { printf("screen on kept %+d - +200 is cheaper but pins the cores, +100 is the answer\n", g_rec_on_offset_x1000[o->champion]); bad = 1; }
    /* Screen on, the pack cooling by 3 C (out into the cold): set aside. */
    { unsigned long cl = g_rec_rej[REJ_CLIMATE]; g_temp = ramp_temp; g_rec_blk.active = 0;
      for (int i = 0; i < 11; i++) { g_ramp_t = 250 - 4 * i; run(&in, 1, 60, 1); }
      g_ramp_t = 200; run(&in, 1, 60, 1); g_rec_blk.active = 0; g_temp = 0;
      run(&in, 1, 60, 1);
      if (g_rec_rej[REJ_CLIMATE] <= cl) { puts("a screen-on block that cooled by 4 C was counted"); bad = 1; } }
    /* Heavy work and a night check get no lean at all. */
    in.heavy_state = 1; run(&in, 1, 60, 1);
    if (g_rec_on_offset != 0) { puts("a lean under heavy work"); bad = 1; }
    in.heavy_state = 0; in.microwake = 1; run(&in, 1, 60, 1);
    if (g_rec_on_offset != 0) { puts("a lean during a night check"); bad = 1; }
    in.microwake = 0;
    /* A smoothness test for the app in front: the records leave that time out. */
    g_rec_smooth_testing = 1; g_rec_blk.active = 0; run(&in, 3, 60, 1);
    if (g_rec_blk.active) { puts("a block during a smoothness test"); bad = 1; }
    g_rec_smooth_testing = 0;
    /* Bright screen is its own situation. */
    g_bright = 80; g_rec_bright_ts = 0; run(&in, 3, 60, 1);
    if (!g_rec_blk.active || g_rec_blk.ctx != ASB_REC_ON_LIGHT_BRIGHT) { puts("a bright screen was not its own situation"); bad = 1; }
    /* Persistence: what was learned survives a restart. */
    if (asb_rec_save() != 0) { puts("save failed"); bad = 1; }
    int ch = c->champion, oc = o->champion;
    memset(&g_rec, 0, sizeof(g_rec)); g_rec_loaded = 0;
    if (asb_rec_load() != 1 || g_rec.ctx[ASB_REC_OFF_NIGHT].champion != ch ||
        g_rec.ctx[ASB_REC_ON_LIGHT_DIM].champion != oc || !g_rec.ctx[ASB_REC_OFF_NIGHT].converged) { puts("records lost across a restart"); bad = 1; }
    /* Re-check after 21 days: exploring opens again. */
    g_wall += ASB_REC_RECHECK_S + 60; in.screen_on = 0; in.idle_state = 1; in.night = 1;
    run(&in, 2, 60, 0);
    if (g_rec.ctx[ASB_REC_OFF_NIGHT].converged || g_rec.ctx[ASB_REC_OFF_NIGHT].challenger == g_rec.ctx[ASB_REC_OFF_NIGHT].champion) { puts("no re-check after 21 days"); bad = 1; }
    /* No meter: nothing is measured. */
    g_cc_ok = 0; g_rec_blk.active = 0; unsigned b0 = g_rec.ctx[ASB_REC_OFF_DAY].blocks; in.night = 0;
    run(&in, 100, 60, 0);
    if (g_rec.ctx[ASB_REC_OFF_DAY].blocks != b0 || g_rec_cc_state != -1) { puts("measured without a charge counter"); bad = 1; }
    /* Night wakes: three nights with a check around 03:10. */
    struct tm tmv; memset(&tmv, 0, sizeof(tmv));
    tmv.tm_year = 126; tmv.tm_mon = 9; tmv.tm_mday = 20; tmv.tm_hour = 3; tmv.tm_min = 10; tmv.tm_isdst = -1;
    long t310 = (long)mktime(&tmv);
    for (int d = 0; d < 3; d++) { asb_mw_note(t310 + d * 86400L, 200 + d * 20); asb_mw_night_end(); }
    if (g_rec.mw.total != 3 || g_rec.mw.nights != 3 || g_rec.mw.per_night_ewma < 0.9f) { printf("night wakes %u/%u %.2f\n", g_rec.mw.total, g_rec.mw.nights, g_rec.mw.per_night_ewma); bad = 1; }
    if (!asb_mw_predict(t310 + 3 * 86400L + 600, 1, 4 * 3600)) { puts("a 03:20 check after 4 h asleep was not recognised"); bad = 1; }
    if (asb_mw_predict(t310 + 3 * 86400L + 600, 1, 20 * 60)) { puts("20 minutes after going to bed is not a night check"); bad = 1; }
    if (asb_mw_predict(t310 + 3 * 86400L + 600, 0, 4 * 3600)) { puts("outside the night window is not a night check"); bad = 1; }
    long h = asb_mw_hold_s();
    if (h < 180 || h > 600) { printf("hold %ld s\n", h); bad = 1; }
    asb_rec_summary_write();
    FILE *f = fopen("$T/rec.txt", "r"); char line[400]; int saw_plateau = 0, saw_mw = 0, saw_hdr = 0, saw_rej = 0, saw_sm = 0;
    while (f && fgets(line, sizeof(line), f)) {
        if (!strncmp(line, "off_night|", 10) && strstr(line, "|x0.875|")) saw_plateau = 1;
        if (!strncmp(line, "microwake|learned=3|", 20)) saw_mw = 1;
        if (!strncmp(line, "# ctx|status|best|record_mW|record_mA|", 38)) saw_hdr = 1;
        if (!strncmp(line, "rejected|meter=", 15) && strstr(line, "|climate=")) saw_rej = 1;
        if (!strncmp(line, "smooth|watching=", 16)) saw_sm = 1;
    }
    if (f) fclose(f);
    if (!saw_plateau || !saw_mw || !saw_hdr || !saw_rej || !saw_sm) { printf("summary does not show the result (%d %d %d %d %d)\n", saw_plateau, saw_mw, saw_hdr, saw_rej, saw_sm); bad = 1; }
    /* fix209: a night whose morning never confirmed is closed by the next note ten or more
     * hours later - tonight folds into the per-night average, the habits fade, and a
     * tonight built over an unknown number of nights counts as no more than four checks. */
    memset(&g_rec.mw, 0, sizeof(g_rec.mw));
    asb_mw_note(t310, 200);
    asb_mw_note(t310 + 11 * 3600L, 200);
    if (g_rec.mw.nights != 1 || g_rec.mw.tonight != 1 || g_rec.mw.total != 2 ||
        g_rec.mw.per_night_ewma != 1.0f) { printf("the unconfirmed night did not close (%u/%u %.2f)\n", g_rec.mw.nights, g_rec.mw.tonight, g_rec.mw.per_night_ewma); bad = 1; }
    /* A confirmed night_end already folded the night: the next note must not fold it again. */
    memset(&g_rec.mw, 0, sizeof(g_rec.mw));
    asb_mw_note(t310, 200); asb_mw_night_end();
    asb_mw_note(t310 + 86400L, 200);
    if (g_rec.mw.nights != 1 || g_rec.mw.tonight != 1) { printf("a confirmed night folded twice (%u/%u)\n", g_rec.mw.nights, g_rec.mw.tonight); bad = 1; }
    /* Twenty checks banked with nights=0 (the capture's own case): the fold counts four. */
    memset(&g_rec.mw, 0, sizeof(g_rec.mw));
    g_rec.mw.tonight = 20; g_rec.mw.last_ts = (uint32_t)t310;
    asb_mw_note(t310 + 11 * 3600L, 200);
    if (g_rec.mw.nights != 1 || g_rec.mw.tonight != 1 || g_rec.mw.per_night_ewma != 4.0f) { printf("a poisoned tonight was not capped (%.2f)\n", g_rec.mw.per_night_ewma); bad = 1; }
    /* A check within the same night is still one night. */
    memset(&g_rec.mw, 0, sizeof(g_rec.mw));
    asb_mw_note(t310, 200); asb_mw_note(t310 + 1800, 240);
    if (g_rec.mw.nights != 0 || g_rec.mw.tonight != 2) { puts("two checks in one night folded early"); bad = 1; }
    /* A fix184 store: the night-check habit comes across, the situations start over. */
    {
        asb_rec_store_v1_t v1; memset(&v1, 0, sizeof(v1));
        v1.magic = ASB_REC_MAGIC; v1.version = 1; v1.size = sizeof(v1);
        v1.ctx[0].b[0] = 3; v1.mw.total = 7; v1.mw.nights = 5; v1.mw.dur_ewma_s = 240.0f;
        v1.mw.per_night_ewma = 1.2f; v1.mw.slot_w[6] = 4.0f;
        FILE *w = fopen("$T/rec.bin", "wb"); fwrite(&v1, 1, sizeof(v1), w); fclose(w);
        memset(&g_rec, 0, sizeof(g_rec)); g_rec_loaded = 0;
        int rl = asb_rec_load();
        if (rl != 2 || g_rec.mw.total != 7 || g_rec.mw.nights != 5 || g_rec.mw.slot_w[6] != 4.0f ||
            g_rec.ctx[0].champion != ASB_REC_ARM_DEFAULT || g_rec.version != ASB_REC_VERSION) { printf("fix184 store not carried over (rl %d, total %u)\n", rl, g_rec.mw.total); bad = 1; }
        if (asb_rec_save() != 0) { puts("re-save failed"); bad = 1; }
        memset(&g_rec, 0, sizeof(g_rec)); g_rec_loaded = 0;
        if (asb_rec_load() != 1 || g_rec.mw.total != 7) { puts("the carried-over store does not load as fix185"); bad = 1; }
        /* Garbage of the right size is not taken for a night habit. */
        v1.mw.dur_ewma_s = -5.0f;
        w = fopen("$T/rec.bin", "wb"); fwrite(&v1, 1, sizeof(v1), w); fclose(w);
        memset(&g_rec, 0, sizeof(g_rec)); g_rec_loaded = 0;
        if (asb_rec_load() != 0 || g_rec.mw.total != 0) { puts("a corrupt fix184 store was used"); bad = 1; }
    }
    return bad;
}
X
"$CC" -std=gnu11 -Wall -Werror -Wno-unused-function -o "$T/t" "$T/t.c" || fail "harness does not compile"
"$T/t" || fail "behaviour"
echo "PASS smart records: power compared side by side - the climate is not credited, charging and its aftermath are set aside, the plateau stops it, night checks carry over and unconfirmed nights close on their own"
)

t_smart_smoothness_runtime() (
# Runtime (fix185): Smart's smoothness check. Android's own frame statistics per app; an app
# that misses 5 % of 3000+ frames under the normal lean is TESTED (8 % until fix198, which
# two full-day flagship captures showed is above anything a healthy flagship's apps reach) -
# windows alternate the normal lean and 0.15 more headroom - and the headroom is kept for
# that app only when it cuts the janky share by a quarter and 1.5 points; otherwise the app
# is marked as not helped by clocks. fix198 also made the test truly bounded: six windows
# per arm always end it, even when the app draws too few frames for a verdict (then it is
# simply left as it was, never kept). Windows under the wrong arm are ignored, 24 apps are
# remembered, the verdicts are re-checked after 21 days. The probe script parses
# graphicsstats text for one package. The REAL asb_record.h and runtime/asb_gfx_probe.sh
# run here.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/src/asb_record.h"; G="$ROOT/src/asb_governor.c"; P="$ROOT/runtime/asb_gfx_probe.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL smart smoothness: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP smart smoothness: no C compiler"; exit 0; }
[ -f "$P" ] || fail "no probe script"
grep -Fq 'asb_smooth_probe_tick(&fsm, &metrics);' "$G" || fail "the governor never probes"
grep -Fq 'asb_run_modscript("runtime/asb_gfx_probe.sh", pk);' "$G" || fail "the probe is not run for the app in front"
grep -Fq '#define ASB_SMOOTH_PROBE_S 180' "$G" || fail "probe cadence"
grep -Fq '#define ASB_SMOOTH_TRIGGER_JANK    0.05' "$R" || fail "fix198: the test trigger is 5 % of 3000+ frames"
grep -Fq 'if (!enough && !full) return 0;' "$R" || fail "fix198: a full test must end even on thin frames"
grep -Fq 'else if (g_smooth_win_arm != arm) g_smooth_win_arm = -2;' "$G" || fail "a window whose arm changed would be counted"
grep -Fq 'g_smart_rt.app_hint < ASB_APP_GAMING && !m->misc.camera_active &&' "$G" || fail "games / the camera are not left out"
grep -Fq '!asb_smart_is_system_ui(g_smart_rt.app_pkg_cached)' "$G" || fail "the system UI is not left out"
grep -Fq 'int _off = g_rec_on_offset + g_smooth_lean;' "$G" || fail "the smoothness lean is not applied"
grep -q '^smart_smooth=1$' "$ROOT/config/governor.conf" || fail "not shipped on"
grep -q '^smart_smooth|internal|' "$ROOT/config/key_ownership.tsv" || fail "key not registered"
# The probe: a fake dumpsys with two entries for the app (live + a past day) and a neighbour.
mkdir -p "$T/bin"
cat > "$T/bin/dumpsys" <<'D'
#!/bin/sh
[ "$1" = graphicsstats ] || exit 1
cat <<'E'
Package: com.other.app
Version: 3
Total frames rendered: 999
Janky frames: 500 (50.00%)
Package: com.example.feed
Version: 41
Stats since: 1000ns
Total frames rendered: 12000
Janky frames: 960 (8.00%)
Janky frames (legacy): 2000 (16.66%)
Package: com.example.feed
Version: 40
Total frames rendered: 3000
Janky frames: 90 (3.00%)
E
D
chmod +x "$T/bin/dumpsys"
PATH="$T/bin:$PATH" ASB_GFX_OUT="$T/gfx.txt" ASB_GFX_LOCK="$T/gfx.lock" sh "$P" com.example.feed
[ "$(cat "$T/gfx.txt")" = "com.example.feed 15000 1050" ] || fail "probe parse: $(cat "$T/gfx.txt")"
[ ! -d "$T/gfx.lock" ] || fail "probe left its lock"
PATH="$T/bin:$PATH" ASB_GFX_OUT="$T/gfx2.txt" ASB_GFX_LOCK="$T/gfx.lock" sh "$P" 'com.x;rm -rf /'
[ ! -e "$T/gfx2.txt" ] || fail "a bad package name reached dumpsys"
mkdir "$T/gfx.lock"
PATH="$T/bin:$PATH" ASB_GFX_OUT="$T/gfx3.txt" ASB_GFX_LOCK="$T/gfx.lock" sh "$P" com.example.feed
[ ! -e "$T/gfx3.txt" ] || fail "a second probe ran while one held the lock"
rmdir "$T/gfx.lock"
PATH="$T/bin:$PATH" ASB_GFX_OUT="$T/gfx4.txt" ASB_GFX_LOCK="$T/gfx.lock" sh "$P" com.absent.app
[ -e "$T/gfx4.txt" ] && [ ! -s "$T/gfx4.txt" ] || fail "an app with no frames should leave an empty answer"
cat > "$T/t.c" <<X
#define ASB_REC_FILE "$T/rec.bin"
#define ASB_REC_SUMMARY "$T/rec.txt"
#include "$R"
static long g_now = 1792440000L;
/* One three-minute window of an app drawing 2000 frames, janky share by arm. */
static int win(uint64_t h, const char *pkg, double j0, double j1) {
    int arm = asb_smooth_offset_for(h, g_now) != 0 ? 1 : 0;
    long df = 2000, dj = (long)(df * (arm ? j1 : j0) + 0.5);
    g_now += 180;
    return asb_smooth_window(h, pkg, df, dj, arm, g_now);
}
int main(void) {
    int bad = 0;
    asb_rec_store_init(&g_rec); g_rec_loaded = 1;
    const uint64_t A = 0x1111, B = 0x2222, C = 0x3333;
    /* A smooth app is only watched. */
    for (int i = 0; i < 10; i++) win(C, "com.smooth", 0.02, 0.02);
    if (asb_smooth_find(C, g_now, 0)->state != 0 || asb_smooth_offset_for(C, g_now) != 0) { puts("a smooth app was touched"); bad = 1; }
    /* fix198: the trigger is 5 % now - 6.5 % of 3000+ frames starts a test, 4 % does not. */
    const uint64_t D = 0x4444, E = 0x5555;
    win(D, "com.chatty", 0.065, 0.065);
    if (asb_smooth_find(D, g_now, 0)->state != 0) { puts("tested before 3000 frames"); bad = 1; }
    win(D, "com.chatty", 0.065, 0.065);
    if (asb_smooth_find(D, g_now, 0)->state != 1) { puts("a 6.5 percent app was not tested"); bad = 1; }
    for (int i = 0; i < 10; i++) win(E, "com.okish", 0.04, 0.04);
    if (asb_smooth_find(E, g_now, 0)->state != 0) { puts("a 4 percent app was tested"); bad = 1; }
    /* A janky app whose jank is the clocks: tested, then kept. */
    int ev = 0;
    for (int i = 0; i < 2; i++) ev |= win(A, "com.feed", 0.10, 0.04);
    if (asb_smooth_find(A, g_now, 0)->state != 1 || !ev || !strstr(g_smooth_event_msg, "testing more headroom")) { puts("a janky app was not tested"); bad = 1; }
    if (asb_smooth_offset_for(A, g_now) != ASB_SMOOTH_LEAN_X1000 || !g_rec_smooth_testing) { puts("the test does not start with the headroom arm / records not told"); bad = 1; }
    /* A window under the wrong arm is not counted. */
    asb_smooth_app_t *a = asb_smooth_find(A, g_now, 0);
    unsigned w0 = a->t_windows[0], w1 = a->t_windows[1];
    asb_smooth_window(A, "com.feed", 2000, 200, a->arm ^ 1, g_now);
    if (a->t_windows[0] != w0 || a->t_windows[1] != w1) { puts("a window under the other arm was counted"); bad = 1; }
    int n = 0;
    while (a->state == 1 && n++ < 40) win(A, "com.feed", 0.10, 0.04);
    if (a->state != 2 || asb_smooth_offset_for(A, g_now) != ASB_SMOOTH_LEAN_X1000 || g_rec_smooth_testing) { printf("headroom that helps was not kept (state %d)\n", a->state); bad = 1; }
    if (!strstr(g_smooth_event_msg, "more headroom helps")) { puts("no log of the verdict"); bad = 1; }
    if (a->t_windows[0] < ASB_SMOOTH_MIN_WINDOWS || a->t_windows[1] < ASB_SMOOTH_MIN_WINDOWS) { puts("decided on too few windows"); bad = 1; }
    /* A janky app whose jank is not the clocks: tested, then left alone. */
    for (int i = 0; i < 2; i++) win(B, "com.chat", 0.12, 0.115);
    asb_smooth_app_t *b = asb_smooth_find(B, g_now, 0);
    n = 0;
    while (b->state == 1 && n++ < 60) win(B, "com.chat", 0.12, 0.115);
    if (b->state != 3 || asb_smooth_offset_for(B, g_now) != 0) { printf("headroom that does not help was kept (state %d)\n", b->state); bad = 1; }
    if (!strstr(g_smooth_event_msg, "does not help")) { puts("no log of the negative verdict"); bad = 1; }
    /* 21 days on, both verdicts are re-checked. */
    g_now += ASB_REC_RECHECK_S + 10;
    win(B, "com.chat", 0.01, 0.01);
    if (b->state != 0) { puts("no re-check after 21 days"); bad = 1; }
    /* fix198: a test is bounded even on thin frames - an app that draws little while it is
     * watched (a chat left on screen) reaches its verdict at six windows per arm and is
     * left as it was, headroom never kept. */
    const uint64_t F = 0x6666;
    for (int i = 0; i < 8; i++) { g_now += 180; asb_smooth_window(F, "com.quiet", 400, 32, 0, g_now); }
    asb_smooth_app_t *fa = asb_smooth_find(F, g_now, 0);
    if (fa->state != 1) { puts("the quiet janky app was not tested"); bad = 1; }
    int armf = 1, nf = 0;
    while (fa->state == 1 && nf++ < 40) {
        g_now += 180;
        asb_smooth_window(F, "com.quiet", 300, 24, armf, g_now);
        armf ^= 1;
    }
    if (fa->state != 3 || asb_smooth_offset_for(F, g_now) != 0) { puts("a full test on thin frames did not end, or kept the headroom"); bad = 1; }
    if (!strstr(g_smooth_event_msg, "without enough frames")) { puts("no log of the thin-frames verdict"); bad = 1; }
    if (nf > 13) { printf("a thin-frames test took %d windows\n", nf); bad = 1; }
    /* 24 apps remembered: the least recently seen makes room, the rest stay. */
    for (uint64_t k = 0; k < 30; k++) { g_now += 60; asb_smooth_window(0x9000 + k, "com.many", 100, 1, 0, g_now); }
    if (asb_smooth_find(0x9000, g_now, 0) || !asb_smooth_find(0x9000 + 29, g_now, 0)) { puts("the app table did not evict the oldest"); bad = 1; }
    /* Nonsense windows are ignored. */
    if (asb_smooth_window(A, "x", 100, 200, 0, g_now) || asb_smooth_window(A, "x", 0, 0, 0, g_now) || asb_smooth_window(0, "x", 100, 1, 0, g_now)) { puts("a nonsense window counted"); bad = 1; }
    /* Persisted with the records. */
    asb_smooth_app_t *s29 = asb_smooth_find(0x9000 + 29, g_now, 0);
    s29->state = 2; s29->decided_ts = (uint32_t)g_now;
    if (asb_rec_save() != 0) { puts("save failed"); bad = 1; }
    memset(&g_rec, 0, sizeof(g_rec)); g_rec_loaded = 0;
    if (asb_rec_load() != 1 || asb_smooth_offset_for(0x9000 + 29, g_now) != ASB_SMOOTH_LEAN_X1000) { puts("the verdict was lost across a restart"); bad = 1; }
    return bad;
}
X
"$CC" -std=gnu11 -Wall -Werror -Wno-unused-function -o "$T/t" "$T/t.c" || fail "harness does not compile"
"$T/t" || fail "behaviour"
echo "PASS smart smoothness: real frame statistics, an A/B test per app, headroom kept only where it cuts the jank, the probe reads one app"
)

t_msm_final_ceiling_runtime() (
# Runtime (fix186): msm_performance gets the ceiling scaling_max_freq gets.
#
# In HEAVY the writer registers its ceilings with msm_performance - a second ceiling the
# kernel also obeys - and it registered the value BEFORE the race-to-idle floor. On an OP15
# in Smart the prime then ran at the profile's raw 1497600 in every HEAVY sample while
# scaling_max_freq read 1862400, and the capture blamed the vendor. The REAL helpers run
# against the OP15 prime table: the msm value equals the per-path value, floor and manual
# clamp included, and a thermal cap still goes under the floor.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL msm final ceiling: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP msm final ceiling: no C compiler"; exit 0; }
grep -Fq '? writer_slot_final_max(0, c0_target, thermal_cap, manual_override, manual_prof_idx)' "$W" || fail "slot 0 msm value is not the final ceiling"
grep -Fq '? writer_slot_final_max(1, c1_target, thermal_cap, manual_override, manual_prof_idx)' "$W" || fail "slot 1 msm value is not the final ceiling"
grep -Fq 'msm_perf_write_caps(msm_c0, msm_c1, msm_c2);' "$W" || fail "msm write does not use the final values"
grep -Fq 'msm_perf_write_caps(msm_c0, msm_c1, cmax[2] > 0 ? cmax[2] : 0);' "$W" && fail "the raw slot-2 value still goes to msm"
cat > "$T/t.c" <<'C'
#include <stdio.h>
#include <string.h>
static long g_cpu_freq_tables[16][32]; static int g_cpu_freq_table_len[16];
static char g_cpu_max_paths[3][128]; static char g_cpu_all_max_paths[16][128]; static int g_cpu_all_paths_n;
static void cpu_read_freq_tables(void) {}
static void writer_init_paths(void) {}
static long cpu_snap_freq(int p, long w) { long b=0; for (int i=0;i<g_cpu_freq_table_len[p];i++){long v=g_cpu_freq_tables[p][i]; if(v<=w&&v>b)b=v;} return b?b:w; }
#define ASB_MIN_CEILING_PCT_OF_HW 40
static int g_writer_floor_pct = 0;
static int g_shell_cap = 0;
static int writer_manual_clamp(int pi, const char *path, int want) { (void)pi; (void)path; return (g_shell_cap > 0 && want > g_shell_cap) ? g_shell_cap : want; }
C
awk '/^static int cpu_floor_ceiling/,/^}/' "$W" >> "$T/t.c"
awk '/^static int writer_slot_path_idx/,/^}/' "$W" >> "$T/t.c"
awk '/^static int writer_slot_ceiling/,/^}/' "$W" >> "$T/t.c"
awk '/^static int writer_slot_final_max/,/^}/' "$W" >> "$T/t.c"
cat >> "$T/t.c" <<'C'
int main(void) {
  /* OP15: policy0 main, policy6 prime (4608000 max, 40 % = 1843200 -> 1862400). */
  long p0[] = {384000, 1555200, 1996800, 3628800}, p6[] = {768000, 1497600, 1632000, 1862400, 2380800, 4608000};
  for (int i = 0; i < 4; i++) g_cpu_freq_tables[0][i] = p0[i];
  for (int i = 0; i < 6; i++) g_cpu_freq_tables[1][i] = p6[i];
  g_cpu_freq_table_len[0] = 4; g_cpu_freq_table_len[1] = 6;
  strcpy(g_cpu_max_paths[0], "/p0"); strcpy(g_cpu_max_paths[1], "/p6");
  strcpy(g_cpu_all_max_paths[0], "/p0"); strcpy(g_cpu_all_max_paths[1], "/p6"); g_cpu_all_paths_n = 2;
  int bad = 0;
  int v = writer_slot_final_max(1, 1497600, 0, 0, 0);
  if (v != 1862400) { printf("HEAVY prime %d, want the floor 1862400\n", v); bad = 1; }
  if (writer_slot_final_max(1, 1632000, 0, 0, 0) != 1862400) { puts("1632000 not lifted"); bad = 1; }
  if (writer_slot_final_max(1, 1497600, 1, 0, 0) != 1497600) { puts("a thermal cap must go under the floor"); bad = 1; }
  if (writer_slot_final_max(1, 2500000, 0, 0, 0) != 2380800) { puts("not snapped to the table"); bad = 1; }
  if (writer_slot_final_max(0, 1996800, 0, 0, 0) != 1996800) { puts("main above the floor changed"); bad = 1; }
  g_shell_cap = 1747200;
  if (writer_slot_final_max(1, 1497600, 0, 1, 0) != 1747200) { puts("manual clamp not applied"); bad = 1; }
  if (writer_slot_final_max(1, 1497600, 0, 0, 0) != 1862400) { puts("manual clamp applied without an override"); bad = 1; }
  if (writer_slot_final_max(2, 1000000, 0, 0, 0) != 1000000) { puts("an unmanaged slot was altered"); bad = 1; }
  return bad;
}
C
"$CC" -std=gnu11 -Wall -Werror -Wno-unused-function -o "$T/t" "$T/t.c" || fail "harness does not compile"
"$T/t" || fail "behaviour"
echo "PASS msm final ceiling: HEAVY's msm_performance registration carries the floor-lifted ceiling, not the raw one"
)

t_reassert_manual_ceiling_runtime() (
# Runtime (fix191): in Battery and Balanced the HEAVY/GAMING reassert asks for no less than the
# profile's own ceiling, SUSTAINED for no more. It registered the FSM rail in msm_performance -
# on an OP15 Balanced (no screen-on cap: 3628800/4608000) a rail of 2611200/3974400, on Battery
# (1785600/1747200) 1670400/1632000 - so app launches ran capped harder than ordinary use; a
# Balanced capture's cap_verify found msm holding the governor's declared 2361600. The REAL
# helpers run against the OP15 tables.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"; G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL reassert manual ceiling: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP reassert manual ceiling: no C compiler"; exit 0; }
grep -Fq 'int ok = msm_perf_write_caps(rtc[0], rtc[1], rtc[2]);' "$G" || fail "the reassert still registers the raw rail"
grep -Fq 'rtc[_rs] = writer_reassert_target(_rs, fsm.current_caps.cpu_max[_rs], fsm.state);' "$G" || fail "targets not computed"
grep -Fq 'int desired_p0 = rtc[0];' "$G" || fail "the anti-clamp gap is measured against the raw rail"
grep -Fq 'sysfs_write_int(cpu_policy_path(ci, "scaling_max_freq"),' "$G" && grep -Fq 'rtc[ci]) == 0)' "$G" || fail "the anti-clamp write uses the raw rail"
cat > "$T/t.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define PROFILE_BATTERY 0
#define PROFILE_BALANCED 1
#define PROFILE_PERFORMANCE 2
#define PROFILE_SMART 3
typedef enum { ASB_STATE_DEEP_IDLE, ASB_STATE_LIGHT_IDLE, ASB_STATE_MODERATE, ASB_STATE_HEAVY,
               ASB_STATE_SUSTAINED, ASB_STATE_GAMING } asb_state_t;
static int fsm_profile_is_smart = 0, fsm_profile_is_performance = 0, fsm_profile_is_battery = 0;
static long g_cpu_freq_tables[16][32]; static int g_cpu_freq_table_len[16];
static char g_cpu_max_paths[3][128]; static char g_cpu_all_max_paths[16][128]; static int g_cpu_all_paths_n;
static void cpu_read_freq_tables(void) {}
static void writer_init_paths(void) {}
static long cpu_snap_freq(int p, long w) { long b=0; for (int i=0;i<g_cpu_freq_table_len[p];i++){long v=g_cpu_freq_tables[p][i]; if(v<=w&&v>b)b=v;} return b?b:w; }
#define ASB_MIN_CEILING_PCT_OF_HW 40
static int g_writer_floor_pct = 0;
static int g_sh[16];
static int asb_shell_cap_for_policy(int prof, int pol) { (void)prof; return (pol >= 0 && pol < 16) ? g_sh[pol] : 0; }
static int writer_manual_clamp(int pi, const char *path, int want) { (void)pi; (void)path; return want; }
C
awk '/^static int asb_policy_id_of_path/,/^}/' "$W" >> "$T/t.c"
awk '/^static int cpu_floor_ceiling/,/^}/' "$W" >> "$T/t.c"
awk '/^static int writer_slot_path_idx/,/^}/' "$W" >> "$T/t.c"
awk '/^static int writer_slot_ceiling/,/^}/' "$W" >> "$T/t.c"
awk '/^static int writer_slot_final_max/,/^}/' "$W" >> "$T/t.c"
awk '/^static int writer_reassert_target/,/^}/' "$W" >> "$T/t.c"
grep -q 'writer_reassert_target' "$T/t.c" || fail "helper not found"
cat >> "$T/t.c" <<'C'
int main(void) {
  long p0[] = {384000, 1440000, 1670400, 1785600, 2361600, 2611200, 3628800};
  long p6[] = {768000, 1632000, 1747200, 1862400, 3974400, 4608000};
  for (int i = 0; i < 7; i++) g_cpu_freq_tables[0][i] = p0[i];
  for (int i = 0; i < 6; i++) g_cpu_freq_tables[1][i] = p6[i];
  g_cpu_freq_table_len[0] = 7; g_cpu_freq_table_len[1] = 6;
  strcpy(g_cpu_max_paths[0], "/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq");
  strcpy(g_cpu_max_paths[1], "/sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq");
  strcpy(g_cpu_all_max_paths[0], g_cpu_max_paths[0]); strcpy(g_cpu_all_max_paths[1], g_cpu_max_paths[1]); g_cpu_all_paths_n = 2;
  int bad = 0;
  /* Balanced on an OP15: no screen-on cap. */
  g_sh[0] = 3628800; g_sh[6] = 4608000;
  if (writer_reassert_target(0, 2611200, ASB_STATE_HEAVY) != 3628800 || writer_reassert_target(1, 3974400, ASB_STATE_HEAVY) != 4608000) {
    printf("Balanced HEAVY: %d/%d, want the uncapped 3628800/4608000\n", writer_reassert_target(0, 2611200, ASB_STATE_HEAVY), writer_reassert_target(1, 3974400, ASB_STATE_HEAVY)); bad = 1; }
  if (writer_reassert_target(0, 2361600, ASB_STATE_SUSTAINED) != 2361600) { puts("Balanced SUSTAINED must keep its cooling rail"); bad = 1; }
  /* Battery: shell 1785600/1747200, rail 1670400/1632000. */
  fsm_profile_is_battery = 1; g_sh[0] = 1785600; g_sh[6] = 1747200;
  if (writer_reassert_target(0, 1670400, ASB_STATE_GAMING) != 1785600 || writer_reassert_target(1, 1632000, ASB_STATE_HEAVY) != 1747200) {
    printf("Battery HEAVY: %d/%d, want the profile's 1785600/1747200\n", writer_reassert_target(0, 1670400, ASB_STATE_GAMING), writer_reassert_target(1, 1632000, ASB_STATE_HEAVY)); bad = 1; }
  if (writer_reassert_target(1, 1632000, ASB_STATE_SUSTAINED) != 1747200 && writer_reassert_target(1, 1632000, ASB_STATE_SUSTAINED) != 1632000) { puts("Battery SUSTAINED"); bad = 1; }
  if (writer_reassert_target(1, 1632000, ASB_STATE_SUSTAINED) > 1747200) { puts("the floor raised a SUSTAINED Battery prime above the profile's ceiling"); bad = 1; }
  if (writer_reassert_target(1, 2400000, ASB_STATE_SUSTAINED) > 1747200) { puts("SUSTAINED asked for more than the profile's ceiling"); bad = 1; }
  /* No shell value known: the rail, snapped and floored, as before. */
  g_sh[0] = 0; g_sh[6] = 0;
  if (writer_reassert_target(1, 1632000, ASB_STATE_HEAVY) != 1862400) { puts("without a shell value the old path changed"); bad = 1; }
  /* Performance and Smart keep their rail. */
  fsm_profile_is_battery = 0; fsm_profile_is_performance = 1; g_sh[0] = 3628800;
  if (writer_reassert_target(0, 2611200, ASB_STATE_HEAVY) != 2611200) { puts("Performance's own rail was replaced"); bad = 1; }
  return bad;
}
C
"$CC" -std=gnu11 -Wall -Werror -Wno-unused-function -o "$T/t" "$T/t.c" || fail "harness does not compile"
"$T/t" || fail "behaviour"
echo "PASS reassert manual ceiling: HEAVY never under a manual profile's own ceiling, SUSTAINED never over it"
)

t_fg_classify_manual_gaming_runtime() (
# Runtime (fix210): foreground-app classification on the MANUAL profiles.
#
# The FSM's GAMING gate asks the package table (pkg_agrees), but the classification ran
# only inside asb_smart_tick - on Battery/Balanced/Performance the hint stayed 0, the
# gate's "no package information" fallback fired permanently, and a busy GPU plus a busy
# CPU read as GAMING (BALANCED field capture: FSM=GAMING at GPU 57 %, load 7.1, while the
# owner was not playing). The REAL asb_fg_classify_tick is cut out of asb_governor.c and
# driven with a scripted detector: a feed app under exactly that load is NOT a game, a
# known game is, a hot GPU-busy unlisted app is (the heat inference, as on Smart), the
# camera and media are not, the no-signal fallback never invents GAMING, and with Smart
# active the function keeps its hands off.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL fg classify manual gaming: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP fg classify manual gaming: no C compiler"; exit 0; }
grep -q '^static void asb_fg_classify_tick' "$G" || fail "no manual-profile classification"
[ "$(grep -c 'asb_fg_classify_tick(&metrics, &fsm);' "$G")" -eq 2 ] || fail "must run before both app_hint publishes (startup and the main loop)"
grep -q 'if (g_smart_rt.enabled && g_smart_store_loaded) return;' "$G" || fail "Smart must keep owning the classification"
awk '/^static void asb_fg_classify_tick/,/^}/' "$G" > "$T/f.c"
grep -q 'asb_fg_classify_tick' "$T/f.c" || fail "extraction failed"
cat > "$T/t.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
enum { ASB_APP_IDLE = 0, ASB_APP_LIGHT, ASB_APP_MEDIUM, ASB_APP_HEAVY, ASB_APP_GAMING };
enum { ASB_STATE_DEEP_IDLE = 0, ASB_STATE_LIGHT_IDLE, ASB_STATE_MODERATE, ASB_STATE_HEAVY,
       ASB_STATE_SUSTAINED, ASB_STATE_GAMING };
typedef enum { ASB_PKG_OK = 0, ASB_PKG_MISSING = 1, ASB_PKG_STALE = 2, ASB_PKG_SYS_UI = 3 } asb_pkg_status_t;
#define ASB_SMART_APP_CACHE_S 0   /* every call classifies - the cache cadence is not under test */
typedef struct { float load1; } cpu_t;
typedef struct { int load_pct; } gpu_t;
typedef struct { int cpu_max_c; } therm_t;
typedef struct { int screen_on, camera_active; } misc_t;
typedef struct { cpu_t cpu; gpu_t gpu; therm_t therm; misc_t misc; } asb_metrics_t;
typedef struct { int state; } asb_fsm_t;
static struct { int enabled; int app_hint; uint64_t app_hash; char app_pkg_cached[128]; } g_smart_rt;
static int g_smart_store_loaded = 0;
static int g_pkg_detect_ok = 0, g_pkg_detect_status = 0, g_pkg_detect_source = 0;
static float g_ui_quiet_floor = 0.0f;
static long g_gov_start_ts = 0;
static struct { int bat_suppress_gaming; } g_asb_cfg = { 1 };
/* The scripted detector: the package the device "sees" in front. */
static const char *g_det_pkg = "";
static int g_det_hint = ASB_APP_MEDIUM;
static asb_pkg_status_t g_det_status = ASB_PKG_OK;
static int g_det_media = 0;
static asb_pkg_status_t asb_smart_detect_foreground_pkg(
        char *out_pkg, size_t outsz, uint64_t *out_hash, int *out_hint, int *out_source,
        int screen_on_now, int interacting_now) {
    (void)screen_on_now; (void)interacting_now;
    if (g_det_status == ASB_PKG_OK || g_det_status == ASB_PKG_STALE) {
        snprintf(out_pkg, outsz, "%s", g_det_pkg);
        *out_hash = 0x1234; *out_hint = g_det_hint; *out_source = 1;
    }
    return g_det_status;
}
static int asb_smart_pkg_is_media_candidate(const char *pkg) { (void)pkg; return g_det_media; }
#include "f.c"
static asb_metrics_t M; static asb_fsm_t F;
static void det(const char *pkg, int hint, asb_pkg_status_t st, int media) {
    g_det_pkg = pkg; g_det_hint = hint; g_det_status = st; g_det_media = media;
}
int main(void) {
    int bad = 0;
    M.misc.screen_on = 1; F.state = ASB_STATE_MODERATE;
    /* The field case: Balanced, a feed app, GPU 57 %, load 7.1 - NOT a game. */
    det("com.reddit.frontpage", ASB_APP_MEDIUM, ASB_PKG_OK, 0);
    M.gpu.load_pct = 57; M.cpu.load1 = 7.1f; M.therm.cpu_max_c = 45;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint != ASB_APP_MEDIUM) { printf("a feed under load read as %d, want medium\n", g_smart_rt.app_hint); bad = 1; }
    if (!g_pkg_detect_ok) { puts("a detected package not marked as such"); bad = 1; }
    /* A known game under the same load IS a game. */
    det("com.miHoYo.GenshinImpact", ASB_APP_GAMING, ASB_PKG_OK, 0);
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint != ASB_APP_GAMING) { puts("a known game lost its hint"); bad = 1; }
    /* A paused game (idle FSM, quiet GPU) is one step down, not GAMING. */
    det("com.miHoYo.GenshinImpact", ASB_APP_GAMING, ASB_PKG_OK, 0);
    F.state = ASB_STATE_LIGHT_IDLE; M.gpu.load_pct = 4; M.cpu.load1 = 5.0f;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint != ASB_APP_HEAVY) { printf("a paused game read as %d\n", g_smart_rt.app_hint); bad = 1; }
    /* A backgrounded game (quiet run queue) is LIGHT. */
    M.cpu.load1 = 1.2f;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint != ASB_APP_LIGHT) { puts("a backgrounded game was not demoted"); bad = 1; }
    /* The heat inference: an unlisted real game (hot die, busy GPU, SUSTAINED) reaches
     * GAMING even though the table calls it medium - this is how Smart treats it too. */
    det("com.newgame.unlisted", ASB_APP_MEDIUM, ASB_PKG_OK, 0);
    F.state = ASB_STATE_SUSTAINED; M.therm.cpu_max_c = 60; M.gpu.load_pct = 45; M.cpu.load1 = 6.0f;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint != ASB_APP_GAMING) { puts("a hot GPU-busy unknown was not inferred as a game"); bad = 1; }
    /* ... but the camera is not a game, whatever the heat. */
    det("com.newgame.unlisted", ASB_APP_MEDIUM, ASB_PKG_OK, 0);
    M.misc.camera_active = 1;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint == ASB_APP_GAMING) { puts("the camera was inferred as a game"); bad = 1; }
    M.misc.camera_active = 0;
    /* ... and neither is a video app. */
    det("com.google.android.youtube", ASB_APP_MEDIUM, ASB_PKG_OK, 1);
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint == ASB_APP_GAMING) { puts("a media app was inferred as a game"); bad = 1; }
    /* Below 60 C there is no inference at all - the old bug's exact territory. */
    det("com.newgame.unlisted", ASB_APP_MEDIUM, ASB_PKG_OK, 0);
    M.therm.cpu_max_c = 52;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint == ASB_APP_GAMING) { puts("GPU-busy at 52 C read as a game"); bad = 1; }
    /* No detection answer at all: the load heuristic, and never GAMING from it. */
    det("", 0, ASB_PKG_MISSING, 0);
    M.cpu.load1 = 13.0f; M.therm.cpu_max_c = 70; F.state = ASB_STATE_HEAVY;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint != ASB_APP_HEAVY || g_pkg_detect_ok) { printf("no-signal load heuristic: hint %d ok %d\n", g_smart_rt.app_hint, g_pkg_detect_ok); bad = 1; }
    M.cpu.load1 = 7.0f;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint != ASB_APP_MEDIUM) { puts("load 7 without detection is medium"); bad = 1; }
    /* Screen off: idle, nothing cached. */
    M.misc.screen_on = 0;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint != ASB_APP_IDLE || g_smart_rt.app_hash != 0) { puts("screen off is not idle"); bad = 1; }
    M.misc.screen_on = 1;
    /* Smart active: the function keeps its hands off Smart's classification. */
    g_smart_rt.enabled = 1; g_smart_store_loaded = 1; g_smart_rt.app_hint = ASB_APP_LIGHT;
    det("com.miHoYo.GenshinImpact", ASB_APP_GAMING, ASB_PKG_OK, 0);
    F.state = ASB_STATE_SUSTAINED; M.therm.cpu_max_c = 60; M.gpu.load_pct = 45;
    asb_fg_classify_tick(&M, &F);
    if (g_smart_rt.app_hint != ASB_APP_LIGHT) { puts("Smart's classification was overwritten"); bad = 1; }
    if (!bad) printf("ok\n");
    return bad;
}
C
"$CC" -std=gnu11 -Wall -Werror -Wno-unused-function -o "$T/t" "$T/t.c" -I"$T" || fail "harness does not compile"
"$T/t" || fail "behaviour"
echo "PASS fg classify manual gaming: a feed under load is not a game, a known game is, the heat inference keeps the camera and media out, Smart keeps owning its own"
)

_asb_tests() { declare -F | awk '$3 ~ /^t_/ { print substr($3, 3) }'; }
case "${1:-}" in
  --list) _asb_tests ;;
  --source) "_c_${2:?fixture name}" ;;
  *)
    _asb_failed=0
    for _asb_t in ${*:-$(_asb_tests)}; do
      "t_$_asb_t"
      [ $? -eq 0 ] || { printf 'FAILED: %s\n' "$_asb_t" >&2; _asb_failed=$((_asb_failed + 1)); }
    done
    [ "$_asb_failed" -eq 0 ]
    ;;
esac

