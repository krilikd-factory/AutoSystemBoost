#ifndef ASB_SMART_DEFS_H
#define ASB_SMART_DEFS_H

#include <stdint.h>

#define ASB_SMART_VER         1
#define ASB_SMART_MAGIC       0x41534253u
#define ASB_SMART_BUCKETS     12
#define ASB_SMART_DAYPARTS    6
#define ASB_SMART_STORE_FILE  "/data/adb/asb/buckets.bin"
#define ASB_SMART_STORE_BAK   "/data/adb/asb/buckets.bin.bak"
#define ASB_SMART_FLAG_FILE   "/data/adb/asb/smart_mode_enabled"
#define ASB_SMART_PREV_PROF   "/data/adb/asb/smart_prev_profile"

typedef enum {
    ASB_DAYPART_SLEEP = 0,
    ASB_DAYPART_WAKE  = 1,
    ASB_DAYPART_MORN  = 2,
    ASB_DAYPART_DAY   = 3,
    ASB_DAYPART_EVE   = 4,
    ASB_DAYPART_LATE  = 5,
    ASB_DAYPART_N     = 6
} asb_daypart_t;

typedef enum {
    ASB_SMART_FALLBACK_EXACT        = 0,
    ASB_SMART_FALLBACK_DAYPART_ONLY = 1,
    ASB_SMART_FALLBACK_CLASS        = 2,
    ASB_SMART_FALLBACK_GLOBAL       = 3,
    ASB_SMART_FALLBACK_SAFE         = 4,
    ASB_SMART_FALLBACK_N            = 5
} asb_smart_fallback_t;

typedef enum {
    ASB_APP_IDLE   = 0,
    ASB_APP_LIGHT  = 1,
    ASB_APP_MEDIUM = 2,
    ASB_APP_HEAVY  = 3,
    ASB_APP_GAMING = 4,
    ASB_APP_N      = 5
} asb_app_hint_t;

#define ASB_SMART_CONF_LOW_X1000   350
#define ASB_SMART_CONF_HIGH_X1000  650
#define ASB_SMART_CONF_MAX_X1000   1000

/* lowered from 2000. Reach full conf in ~8 sessions per bucket
 * instead of 20. Combined with seed_baseline mode (25% min eff_scale),
 * this gives meaningful learning much faster. */
#define ASB_SMART_EFF_OBS_FULL_X100 800

#define ASB_SMART_DECAY_FRESH_DAYS  7
#define ASB_SMART_DECAY_STALE_DAYS  37
#define ASB_SMART_DECAY_FLOOR_X100  30

#define ASB_SMART_ALPHA_BATTERY_MIN_X1000  0
#define ASB_SMART_ALPHA_BATTERY_MAX_X1000  1000

#define ASB_SMART_INTERACTIVE_MIN_X1000    0
#define ASB_SMART_INTERACTIVE_MAX_X1000    150

#define ASB_SMART_IDLE_BIAS_MIN_X1000     -200
#define ASB_SMART_IDLE_BIAS_MAX_X1000      200

#define ASB_SMART_SLEEP_BIAS_MIN_X1000     0
#define ASB_SMART_SLEEP_BIAS_MAX_X1000     1000

#define ASB_SMART_NET_CONSERV_MIN_X1000    0
#define ASB_SMART_NET_CONSERV_MAX_X1000    1000

#define ASB_SMART_DUR_W_SHORT_MIN_S  0
#define ASB_SMART_DUR_W_SHORT_MAX_S  600
#define ASB_SMART_DUR_W_SHORT_X100   25
#define ASB_SMART_DUR_W_MED_MAX_S    1800
#define ASB_SMART_DUR_W_MED_X100     50
#define ASB_SMART_DUR_W_LONG_MAX_S   5400
#define ASB_SMART_DUR_W_LONG_X100    100
#define ASB_SMART_DUR_W_VLONG_X100   125

#define ASB_SMART_TRUST_W_CLEAN_X100   100
#define ASB_SMART_TRUST_W_PARTIAL_X100 40
#define ASB_SMART_TRUST_W_NOISY_X100   15
#define ASB_SMART_TRUST_W_DIRTY_X100   0

/* Trust tier enum (mirror of BAT_TRUST_* from asb_governor.c, kept in sync) */
#define ASB_TRUST_DIRTY    0
#define ASB_TRUST_PARTIAL  1
#define ASB_TRUST_CLEAN    2
#define ASB_TRUST_NOISY    3

#define ASB_SMART_NIGHT_HOUR_START  0
#define ASB_SMART_NIGHT_HOUR_END    6
/* was 60. Battery pct must NOT block night-safe override — the whole
 * point of override is to save battery overnight. At 90% you still want to
 * conserve. Set to 100 to make it effectively unconditional on battery_pct.
 * Override remains gated by: night daypart + screen off + not charging + no heavy app. */
#define ASB_SMART_NIGHT_BAT_PCT_MAX 100
#define ASB_SMART_LOWBAT_ENGAGE_PCT 20
#define ASB_SMART_LOWBAT_RESTORE_PCT 40
#define ASB_SMART_LOWBAT_FORCE_ALPHA_X1000 800
#define ASB_SMART_LOWBAT_CRIT_PCT 10
#define ASB_SMART_LOWBAT_CRIT_ALPHA_X1000 900
#define ASB_SMART_TREND_MIN_TEMP_C 45
#define ASB_SMART_TREND_MIN_SLOPE_MC_MIN 3000
#define ASB_SMART_TREND_MAX_SLOPE_MC_MIN 12000
#define ASB_SMART_TREND_MAX_BUMP_X1000 120
#define ASB_SMART_TREND_WINDOW_S 30
#define ASB_SMART_TREND_STALE_S 180
#define ASB_SMART_TREND_HOT_MIN_TEMP_C 40
#define ASB_SMART_TREND_HOT_MIN_SLOPE_MC_MIN 2000
/* Charge-aware cool gaming: when gaming while charging with a warm battery,
   the worst thermal scenario (render heat + charge heat), engage the lean
   even earlier and on a gentler slope than normal cool gaming. */
#define ASB_SMART_TREND_CHARGE_MIN_TEMP_C 38
#define ASB_SMART_TREND_CHARGE_MIN_SLOPE_MC_MIN 1500
/* Battery temp (deci-C) above which charge-aware cool gaming tightens. */
#define ASB_SMART_CHARGE_WARM_BAT_DC 380
#define ASB_SMART_DRAIN_MIN_ON_SEC 600
#define ASB_SMART_DRAIN_HEAVY_PCTPH_X10 1500
#define ASB_SMART_DRAIN_HI_NUM 5
#define ASB_SMART_DRAIN_HI_DEN 4
#define ASB_SMART_DRAIN_LO_NUM 4
#define ASB_SMART_DRAIN_LO_DEN 5
#define ASB_SMART_APPHEAT_N 16
#define ASB_SMART_APPHEAT_MAGIC 0x41534148u
#define ASB_SMART_APPHEAT_VERSION 1
#define ASB_SMART_APPHEAT_BUMP 2
#define ASB_SMART_APPHEAT_MAX 100
#define ASB_SMART_APPHEAT_HOT_SCORE 10
#define ASB_SMART_APPHEAT_LEARN_SLOPE_MC_MIN 6000
#define ASB_SMART_APPHEAT_DECAY_PER_DAY 1
#define ASB_SMART_APPHEAT_FILE "/data/adb/asb/smart_appheat.bin"
#define ASB_SMART_APPHEAT_DRAIN_BUMP 2
#define ASB_SMART_APPHEAT_DRAIN_SAMPLE_X10 1200
#define ASB_SMART_BUDGET_MAX_PCT 50
#define ASB_BUDGET_SPIKE_WINDOW_S 300
#define ASB_BUDGET_ACC_WINDOW_S 1800
#define ASB_BUDGET_ACC_BIAS_MIN_ERR_PCT 25
#define ASB_BUDGET_ACC_BIAS_STREAK 3
#define ASB_SMART_BUDGET_EMERG_H_X10 20
#define ASB_SMART_BUDGET_WARN_H_X10 40
#define ASB_SMART_BUDGET_EMERG_ALPHA_X1000 700
#define ASB_SMART_BUDGET_WARN_ALPHA_X1000 600
#define ASB_SMART_BUDGET_DWELL_S 120
#define ASB_SMART_QUALITY_BAT_GOOD_X10 50
#define ASB_SMART_QUALITY_BAT_BAD_X10 250
#define ASB_SMART_QUALITY_HEAT_GOOD_C 45
#define ASB_SMART_QUALITY_HEAT_BAD_C 75
#define ASB_ANOM_NONE 0
#define ASB_ANOM_PKG_MISSING 1
#define ASB_ANOM_VENDOR_WAR 2
#define ASB_ANOM_DRAIN_SPIKE 3
#define ASB_ANOM_STUCK_BATTERY 4
#define ASB_ANOM_VENDOR_WAR_CLAMPS_1H 400
#define ASB_ANOM_DRAIN_SPIKE_X10 250

#define ASB_SMART_VETO_CPU_TEMP_C        60
#define ASB_SMART_VETO_VENDOR_CLAMP_1H   300
#define ASB_SMART_VETO_CONF_SCALE_X100   30
#define ASB_SMART_VETO_FORCE_ALPHA_X1000 700

#define ASB_SMART_SMOOTH_S        300

#define ASB_SMART_APP_CACHE_S     10

#define ASB_SMART_DAYPART_SLEEP_START 0
#define ASB_SMART_DAYPART_WAKE_START  6
#define ASB_SMART_DAYPART_MORN_START  9
#define ASB_SMART_DAYPART_DAY_START   12
#define ASB_SMART_DAYPART_EVE_START   17
#define ASB_SMART_DAYPART_LATE_START  21
#define ASB_SMART_DAYPART_LATE_END    24

#define ASB_SMART_BACKUP_PERIOD_S    (24 * 3600 * 7)

/* 50→80. Faster bias adaptation per session outcome. */
#define ASB_SMART_LEARN_RATE_X1000 80

/* V50: charge-aware layer.
 * Power classes derived from |current| × voltage at the pack.
 * Cool-charge floors mirror the idle-screen override levels. */
#define ASB_CHARGE_POWER_FAST_W      12
#define ASB_CHARGE_POWER_SUPER_W     33
#define ASB_CHARGE_CLASS_NONE        0
#define ASB_CHARGE_CLASS_SLOW        1
#define ASB_CHARGE_CLASS_FAST        2
#define ASB_CHARGE_CLASS_SUPER       3
#define ASB_CHARGE_COOL_ALPHA_X1000      850
#define ASB_CHARGE_HOT_ALPHA_X1000       800
#define ASB_CHARGE_SUPER_WARN_BIAS_DC    10

/* V50: night window learner.
 * Minutes-of-day EWMA with circular wrap; onset = screen-off that
 * survives ASB_NIGHT_ONSET_HOLD_S, wake = first screen-on after
 * ASB_NIGHT_MIN_SLEEP_S of cumulative darkness. */
#define ASB_NIGHT_ONSET_HOLD_S     3600
#define ASB_NIGHT_MIN_SLEEP_S      (3 * 3600)
#define ASB_NIGHT_EWMA_NUM         1
#define ASB_NIGHT_EWMA_DEN         4
#define ASB_NIGHT_ONSET_WIN_FROM   (19 * 60)
#define ASB_NIGHT_ONSET_WIN_TO     (5 * 60)
#define ASB_NIGHT_WAKE_WIN_FROM    (4 * 60)
#define ASB_NIGHT_WAKE_WIN_TO      (14 * 60)
#define ASB_NIGHT_MARGIN_PRE_MIN   15
#define ASB_NIGHT_MARGIN_POST_MIN  20

#endif
