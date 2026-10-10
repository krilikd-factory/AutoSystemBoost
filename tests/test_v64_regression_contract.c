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
