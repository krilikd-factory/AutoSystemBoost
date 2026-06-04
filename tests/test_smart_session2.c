/* tests/test_smart_session2.c — unit test seam */

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
