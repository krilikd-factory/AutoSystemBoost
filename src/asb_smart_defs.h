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

/* V48: lowered from 2000. Reach full conf in ~8 sessions per bucket
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
/* V48: was 60. Battery pct must NOT block night-safe override — the whole
 * point of override is to save battery overnight. At 90% you still want to
 * conserve. Set to 100 to make it effectively unconditional on battery_pct.
 * Override remains gated by: night daypart + screen off + not charging + no heavy app. */
#define ASB_SMART_NIGHT_BAT_PCT_MAX 100

#define ASB_SMART_VETO_CPU_TEMP_C        65
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

/* V48: 50→80. Faster bias adaptation per session outcome. */
#define ASB_SMART_LEARN_RATE_X1000 80

#endif
