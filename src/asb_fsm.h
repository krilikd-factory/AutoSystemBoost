#pragma once

#include <time.h>
#include <string.h>
#include "asb_metrics.h"
#include "asb_config.h"
#include "asb_fsm_bounds.generated.h"  /* bounds from config/profile_bounds.conf */

extern asb_runtime_config_t g_asb_cfg;

typedef enum {
    ASB_STATE_DEEP_IDLE  = 0,
    ASB_STATE_LIGHT_IDLE = 1,
    ASB_STATE_MODERATE   = 2,
    ASB_STATE_HEAVY      = 3,
    ASB_STATE_SUSTAINED  = 4,
    ASB_STATE_GAMING     = 5,
    ASB_STATE_COUNT      = 6
} asb_state_t;

static const char *asb_state_names[] = {
    "DEEP_IDLE", "LIGHT_IDLE", "MODERATE", "HEAVY", "SUSTAINED", "GAMING"
};

typedef struct {
    int cpu_max[3];
    int cpu_min[3];
    int gpu_max_pct;
    int gpu_min_pct;
    int ravg_ticks;
    int idle_enough;
    int uclamp_top_max;
    int uclamp_bg_max;
} asb_profile_caps_t;

typedef struct {
    asb_profile_caps_t floor; 
    asb_profile_caps_t ceil;
} asb_profile_bounds_t;

static const asb_profile_bounds_t g_profile_bounds[3] = {
    /* ALL THREE profile bounds realigned with their .sh scripts.
     *
     * Background: termux probe on real device confirmed the FSM was using its
     * own hardcoded g_profile_bounds table for state interpolation, completely
     * independent of the *.sh profile files. Shell reconcile wrote profile.sh
     * values, the C daemon overwrote them immediately on every tick. This
     * affected all three profiles — battery worst (bounds ~2x above .sh),
     * balanced broken (floor > CPU_CAP AND ceil < CPU_MAX, losing 17% perf),
     * performance partial (BIG floor above cooling-trim CPU_CAP, GPU ceil
     * at 100% bypassing the .sh GPU_MAX_PCT=84%).
     *
     * Uniform semantic applied here:
     *   floor.cpu_max    = CPU_CAP   (state=DEEP_IDLE, t=0.0)
     *   ceil.cpu_max     = CPU_MAX   (state=GAMING,    t=1.0)
     *   floor.cpu_min    = CPU_MIN   (lowest min freq, in DEEP_IDLE)
     *   ceil.cpu_min     = CPU_CAP   (higher min freq during GAMING, prevent drops)
     *   ceil.gpu_max_pct = GPU_MAX_PCT from .sh (was bypassed in battery/perf)
     *   floor.gpu_max_pct kept at ~half of ceil for idle headroom
     *
     * Profile-script values referenced at build time, not loaded at runtime.
     * If user edits CPU_CAP/CPU_MAX/GPU_MAX in .sh, the FSM bounds still reflect
     * the values below until the C binary is rebuilt. */

    /* PROFILE_BATTERY:
     * Caps tuned for Snapdragon 8 Elite Gen 5 (4.6GHz P-cluster, 1200MHz GPU).
     * Numeric values come from asb_fsm_bounds.generated.h, generated from
     * config/profile_bounds.conf via tools/gen_bounds.sh.
     */
    {
        .floor = {
            .cpu_max    = { ASB_BATTERY_FLOOR_CPU_MAX_LITTLE, ASB_BATTERY_FLOOR_CPU_MAX_BIG, 0 },
            .cpu_min    = { ASB_BATTERY_FLOOR_CPU_MIN_LITTLE, ASB_BATTERY_FLOOR_CPU_MIN_BIG, 0 },
            /* GPU floor raised to 45%: SM8850 vendor PowerHAL clamps GPU
             * max_pwrlevel to 17 (160 MHz) when it sees low FSM cpu_max +
             * LIGHT_IDLE. Raising GPU max floor to 45% (540 MHz target) breaks
             * that heuristic and stops stutter during shelf/menu scrolling.
             * gpu_min_pct stays 0 — vendor immediately overrides any
             * min_pwrlevel write, so writing it is wasted. */
            .gpu_max_pct = ASB_BATTERY_FLOOR_GPU_MAX_PCT, .gpu_min_pct = ASB_BATTERY_FLOOR_GPU_MIN_PCT,
            .ravg_ticks = ASB_BATTERY_FLOOR_RAVG_TICKS, .idle_enough = ASB_BATTERY_FLOOR_IDLE_ENOUGH,
            .uclamp_top_max = ASB_BATTERY_FLOOR_UCLAMP_TOP, .uclamp_bg_max = ASB_BATTERY_FLOOR_UCLAMP_BG
        },
        .ceil = {
            .cpu_max    = { ASB_BATTERY_CEIL_CPU_MAX_LITTLE, ASB_BATTERY_CEIL_CPU_MAX_BIG, 0 },
            .cpu_min    = { ASB_BATTERY_CEIL_CPU_MIN_LITTLE, ASB_BATTERY_CEIL_CPU_MIN_BIG, 0 },
            .gpu_max_pct = ASB_BATTERY_CEIL_GPU_MAX_PCT, .gpu_min_pct = ASB_BATTERY_CEIL_GPU_MIN_PCT,
            .ravg_ticks = ASB_BATTERY_CEIL_RAVG_TICKS, .idle_enough = ASB_BATTERY_CEIL_IDLE_ENOUGH,
            .uclamp_top_max = ASB_BATTERY_CEIL_UCLAMP_TOP, .uclamp_bg_max = ASB_BATTERY_CEIL_UCLAMP_BG
        }
    },

    /* PROFILE_BALANCED */
    {
        .floor = {
            .cpu_max    = { ASB_BALANCED_FLOOR_CPU_MAX_LITTLE, ASB_BALANCED_FLOOR_CPU_MAX_BIG, 0 },
            .cpu_min    = { ASB_BALANCED_FLOOR_CPU_MIN_LITTLE, ASB_BALANCED_FLOOR_CPU_MIN_BIG, 0 },
            .gpu_max_pct = ASB_BALANCED_FLOOR_GPU_MAX_PCT, .gpu_min_pct = ASB_BALANCED_FLOOR_GPU_MIN_PCT,
            .ravg_ticks = ASB_BALANCED_FLOOR_RAVG_TICKS, .idle_enough = ASB_BALANCED_FLOOR_IDLE_ENOUGH,
            .uclamp_top_max = ASB_BALANCED_FLOOR_UCLAMP_TOP, .uclamp_bg_max = ASB_BALANCED_FLOOR_UCLAMP_BG
        },
        .ceil = {
            .cpu_max    = { ASB_BALANCED_CEIL_CPU_MAX_LITTLE, ASB_BALANCED_CEIL_CPU_MAX_BIG, 0 },
            .cpu_min    = { ASB_BALANCED_CEIL_CPU_MIN_LITTLE, ASB_BALANCED_CEIL_CPU_MIN_BIG, 0 },
            .gpu_max_pct = ASB_BALANCED_CEIL_GPU_MAX_PCT, .gpu_min_pct = ASB_BALANCED_CEIL_GPU_MIN_PCT,
            .ravg_ticks = ASB_BALANCED_CEIL_RAVG_TICKS, .idle_enough = ASB_BALANCED_CEIL_IDLE_ENOUGH,
            .uclamp_top_max = ASB_BALANCED_CEIL_UCLAMP_TOP, .uclamp_bg_max = ASB_BALANCED_CEIL_UCLAMP_BG
        }
    },

    /* PROFILE_PERFORMANCE — sustained-optimized for COD Mobile and similar.
     * Thermal envelope target: peak ≤ 58 °C, sustained ≤ 48 °C on both stock
     * and custom kernels. Caps stay below vendor PowerHAL's reactive triggers
     * to avoid mid-session clamps. */
    {
        .floor = {
            .cpu_max    = { ASB_PERFORMANCE_FLOOR_CPU_MAX_LITTLE, ASB_PERFORMANCE_FLOOR_CPU_MAX_BIG, 0 },
            .cpu_min    = { ASB_PERFORMANCE_FLOOR_CPU_MIN_LITTLE, ASB_PERFORMANCE_FLOOR_CPU_MIN_BIG, 0 },
            .gpu_max_pct = ASB_PERFORMANCE_FLOOR_GPU_MAX_PCT, .gpu_min_pct = ASB_PERFORMANCE_FLOOR_GPU_MIN_PCT,
            .ravg_ticks = ASB_PERFORMANCE_FLOOR_RAVG_TICKS, .idle_enough = ASB_PERFORMANCE_FLOOR_IDLE_ENOUGH,
            .uclamp_top_max = ASB_PERFORMANCE_FLOOR_UCLAMP_TOP, .uclamp_bg_max = ASB_PERFORMANCE_FLOOR_UCLAMP_BG
        },
        .ceil = {
            .cpu_max    = { ASB_PERFORMANCE_CEIL_CPU_MAX_LITTLE, ASB_PERFORMANCE_CEIL_CPU_MAX_BIG, 0 },
            .cpu_min    = { ASB_PERFORMANCE_CEIL_CPU_MIN_LITTLE, ASB_PERFORMANCE_CEIL_CPU_MIN_BIG, 0 },
            .gpu_max_pct = ASB_PERFORMANCE_CEIL_GPU_MAX_PCT, .gpu_min_pct = ASB_PERFORMANCE_CEIL_GPU_MIN_PCT,
            .ravg_ticks = ASB_PERFORMANCE_CEIL_RAVG_TICKS, .idle_enough = ASB_PERFORMANCE_CEIL_IDLE_ENOUGH,
            .uclamp_top_max = ASB_PERFORMANCE_CEIL_UCLAMP_TOP, .uclamp_bg_max = ASB_PERFORMANCE_CEIL_UCLAMP_BG
        }
    }
};

#define PROFILE_BATTERY     0
static int fsm_profile_is_battery = 0;
/* V50: smart profile spends most of a night exactly like battery, but the
 * idle telemetry below only accumulated under PROFILE_BATTERY. With all
 * counters stuck at zero, idle_quality read 0, classify_environment()
 * reported hostile for flawless nights, clean-night reward was unreachable
 * and the next session was primed IDLE_NOISY. Track idle telemetry for
 * smart too; FSM *shaping* (entry thresholds, gaming suppression) stays
 * battery-only via fsm_profile_is_battery. */
static int fsm_profile_is_smart = 0;
static int fsm_profile_is_performance = 0;
#define fsm_profile_tracks_idle (fsm_profile_is_battery || fsm_profile_is_smart)
static int fsm_profile_is_balanced = 0;
#define PROFILE_BALANCED    1
#define PROFILE_PERFORMANCE 2
#define PROFILE_SMART       3
#define ASB_PROFILE_COUNT   4

/* Smart Mode runtime bounds (mutable, written by smart blend math).
 * Initialized to BALANCED defaults at boot; smart logic blends battery↔balanced
 * into this slot when smart_mode_enabled=1 and FSM profile_idx==PROFILE_SMART.
 * When smart_mode_enabled=0, this slot is unused and FSM uses PROFILE_BATTERY/
 * BALANCED/PERFORMANCE from g_profile_bounds[].
 *
 * g_profile_bounds[] above is const and stays const — the envelope. Smart Mode
 * does NOT modify the profile bounds; it computes a blended struct in this
 * separate slot and reads from it instead.
 */
static asb_profile_bounds_t g_smart_bounds;
static int g_smart_bounds_initialized = 0;

/* Dispatch profile_idx to its bounds source. PROFILE_SMART reads from mutable
 * g_smart_bounds; other profiles read from compile-time const g_profile_bounds.
 * If smart bounds not yet initialized, falls back to BALANCED. */
static inline const asb_profile_bounds_t *asb_profile_bounds_for(int profile_idx) {
    if (profile_idx == PROFILE_SMART) {
        if (g_smart_bounds_initialized) return &g_smart_bounds;
        return &g_profile_bounds[PROFILE_BALANCED];
    }
    if (profile_idx < 0 || profile_idx >= 3) return &g_profile_bounds[PROFILE_BALANCED];
    return &g_profile_bounds[profile_idx];
}

/* Single source of truth: profile_idx → human-readable name string.
 * Used by logging, JSON output, and profile-name display sites. */
static inline const char *asb_profile_name(int profile_idx) {
    switch (profile_idx) {
        case PROFILE_BATTERY:     return "battery";
        case PROFILE_BALANCED:    return "balanced";
        case PROFILE_PERFORMANCE: return "performance";
        case PROFILE_SMART:       return "smart";
        default:                  return "balanced";
    }
}

static const float g_state_level[ASB_STATE_COUNT] = {
    [ASB_STATE_DEEP_IDLE]  = 0.0f,
    [ASB_STATE_LIGHT_IDLE] = 0.15f,
    [ASB_STATE_MODERATE]   = 0.45f,
    [ASB_STATE_HEAVY]      = 0.72f,
    [ASB_STATE_SUSTAINED]  = 0.84f,
    [ASB_STATE_GAMING]     = 1.0f
};

static inline int lerp_int(int a, int b, float t) {
    return (int)(a + (b - a) * t + 0.5f);
}

static void fsm_interpolate_caps(
    const asb_profile_bounds_t *bounds, int profile_idx, asb_state_t state,
    asb_profile_caps_t *out)
{
    float t = (state == ASB_STATE_SUSTAINED)
              ? asb_config_profile_sustained_level(&g_asb_cfg, profile_idx)
              : g_state_level[state];
    const asb_profile_caps_t *f = &bounds->floor;
    const asb_profile_caps_t *c = &bounds->ceil;

    for (int i = 0; i < 3; i++) {
        out->cpu_max[i] = asb_bounds_scale(i, lerp_int(f->cpu_max[i], c->cpu_max[i], t));
        out->cpu_min[i] = asb_bounds_scale(i, lerp_int(f->cpu_min[i], c->cpu_min[i], t));
    }
    out->gpu_max_pct    = lerp_int(f->gpu_max_pct,    c->gpu_max_pct,    t);
    out->gpu_min_pct    = lerp_int(f->gpu_min_pct,    c->gpu_min_pct,    t);
    if (fsm_profile_is_battery &&
        state == ASB_STATE_LIGHT_IDLE &&
        g_asb_cfg.bat_light_idle_gpu >= 0 &&
        out->gpu_max_pct > g_asb_cfg.bat_light_idle_gpu)
        out->gpu_max_pct = g_asb_cfg.bat_light_idle_gpu;
    out->ravg_ticks     = lerp_int(f->ravg_ticks,     c->ravg_ticks,     t > 0.5f ? 1.0f : 0.0f);
    out->idle_enough    = lerp_int(f->idle_enough,    c->idle_enough,    t);
    out->uclamp_top_max = lerp_int(f->uclamp_top_max, c->uclamp_top_max, t);
    out->uclamp_bg_max  = lerp_int(f->uclamp_bg_max,  c->uclamp_bg_max,  t);
}

typedef struct {
    asb_state_t     state;
    asb_state_t     pending;
    int             profile_idx;
    int             thermal_cap;

    int             prev_temp; 
    int             thermal_trend;
    int             trend_buf[3];
    int             trend_idx;

    int             pending_ticks;
    int             up_window;
    int             down_window;

    struct timespec last_transition;
    asb_profile_caps_t current_caps;

    int             caps_changed;
    int             state_changed;
    asb_state_t     prev_state;
    int             gaming_gap_ticks_count;
    time_t          gaming_retry_until;
    int             sustained_reason;
    time_t          sustained_reentry_until;

    int             ses_gaming_entries;
    int             ses_sustained_entries;
    int             ses_thermal_entries;
    int             ses_unreachable_entries;

    long            ses_time_heavy_sec;
    long            ses_time_gaming_sec;
    long            ses_time_sustained_sec;

    long            ses_gap_p0_sum;
    long            ses_gap_p1_sum;
    int             ses_gap_samples;
    int             ses_max_gap_p0;
    int             ses_max_gap_p1;
    int             ses_max_temp;
    int             ses_max_skin_temp;
    int             ses_max_surface_temp;  /* surface hotspot (ghost hotspot channel) */
    int             ses_max_board_temp;    /* board_temp peak for long-gaming heat analysis */
    /* track sensor health across the session for release-quality diagnostics */
    int             ses_temp_invalid_count; /* number of read cycles where temp_valid=0 */
    char            ses_last_temp_reason[16]; /* last value of temp_invalid_reason seen this session */

    struct timespec ses_state_enter;
    int             ses_auto_degraded;

    long            ses_time_to_first_sus;
    long            ses_time_to_first_gaming;
    long            ses_time_to_first_thermal;
    int             ses_sustained_efficiency;
    int             ses_recovery_count;
    time_t          ses_start_ts;

    long            bat_time_deep_idle_sec;
    long            bat_time_light_idle_sec;
    long            bat_time_moderate_sec;
    int             bat_wake_cycles;
    /* Wake Attribution -- track what causes wakes */
    int             bat_wake_screen;    /* wakes due to screen ON */
    int             bat_wake_bg;        /* background wakes (no screen) */
    /* radio-aware -- count ticks with heavy mobile data during battery screen-off */
    int             bat_radio_active_ticks;
    int             bat_gaming_suppressed;
    int             bat_screen_off_count;
    long            bat_time_to_first_deep;

    int             ses_intent;
    int             ses_intent_locked;
    long            ses_degrade_at_age;

    long            ses_headroom_sum;       /* accumulator for avg */
    int             ses_headroom_samples;
    int             ses_headroom_min;       /* min headroom seen */
    int             ses_headroom_below70;   /* ticks with headroom<70% */
    int             ses_headroom_below50;   /* ticks with headroom<50% */

    int             ses_mid_tune_count;     /* number of mid-tune adjustments */
    int             ses_mid_tune_dir;       /* net direction: +1 up, -1 down, 0 mixed */

    int             clamp_hold;             /* 1 = gap-triggered sustained suppressed */
    int             had_clamp_hold;         /* session-latched -- was clamp_hold ever set? */
    int             had_futility;           /* session-latched -- was futility ever triggered? */
    int             throttle_cap_ticks;     /* consecutive ticks with thermal_cap=1 */
    time_t          recovery_cautious_until; /* after clamp lift, stay cautious */
    int             perf_hot_guard_ticks;
    int             perf_hot_guard_active;
    /* multi-sensor advisory (skin/surface/board contribute to soft
     * hot-guard, NOT hard panic). Cold baseline = first 30s avg captured
     * at governor start. Concern = current - baseline (delta-from-cold).
     * Advisory active = weighted score > 50 for >=20 ticks. */
    int             cold_baseline_skin;
    int             cold_baseline_surface;
    int             cold_baseline_board;
    int             cold_baseline_ticks;    /* >= 30: baseline captured */
    int             cold_baseline_sum_skin;
    int             cold_baseline_sum_surface;
    int             cold_baseline_sum_board;
    int             thermal_advisory_score;     /* 0-90 weighted */
    int             thermal_advisory_ticks;     /* consecutive ticks > 50 */
    int             thermal_advisory_active;
    /* P2 observe-only: per-zone vote breakdown + would-bias flag. */
    int             thermal_vote_skin;          /* 0-100 per-zone */
    int             thermal_vote_surface;
    int             thermal_vote_board;
    int             would_bias_exit_gaming;     /* criterion: PERFORMANCE + GAMING + advisory (never fires in field) */
    int             would_bias_mode_a;
    int             would_bias_mode_b;
    int             would_bias_mode_a_count;    /* lifetime fire count (session-level) */
    int             would_bias_mode_b_count;
    int             adv_score_high_streak;      /* consecutive ticks adv_score>=70 (for mode A) */
    /* Ceiling-Adaptive Reshaping -- governor sets these from observed freq */
    int             virtual_ceiling_p0;
    int             virtual_ceiling_p1;

    /* session plan -- pre-computed policy decisions (rebuilt on events, not per-tick) */
    struct {
        uint8_t sensor_tier;    /* 0=FULL 1=REDUCED 2=SPARSE */
        uint8_t thermal_div;    /* thermal read every N ticks (1=every, 3=sparse) */
        uint8_t allow_hr;       /* allow headroom reads */
        uint8_t ac_eligible;    /* anti-clamp allowed */
        uint8_t deep_sleep;     /* use extended tick interval */
        uint8_t ac_prearm;      /* skip first detection delay on clamp (perf only) */
        uint8_t ac_budget;      /* max anti-clamp windows per session */
        uint8_t ac_used;        /* consumed anti-clamp budget (runtime) */
        uint8_t quarantine;     /* 1 = user-switch quarantine active */
        uint8_t plan_class;
        uint8_t sensor_budget;
        uint8_t sensor_used;
    } plan;

    /* low-battery auto-switch state.
     * When battery drops below threshold, FSM auto-switches to PROFILE_BATTERY.
     * Original profile is remembered so we can restore on recharge.
     * Hysteresis prevents flapping near threshold. */
    int             auto_battery_active;       /* 1 if auto-switch triggered, 0 otherwise */
    int             auto_battery_restore_idx;  /* profile to restore (-1 if none) */
    time_t          auto_battery_last_action;  /* rate limit: min interval between switches */
    /* reason + timestamp of last auto-battery state transition.
     * Reasons: "none", "low_pct", "high_pct_restore", "manual_clear"
     * Used by status JSON and audit logs. */
    char            auto_battery_reason[24];
    time_t          auto_battery_since;
} asb_fsm_t;

static inline long fsm_elapsed_sec(const asb_fsm_t *fsm) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long)(now.tv_sec - fsm->last_transition.tv_sec);
}

static inline int fsm_min_dwell_for_state(asb_state_t st) {
    switch (st) {
        case ASB_STATE_HEAVY: return g_asb_cfg.heavy_min_dwell_s;
        case ASB_STATE_SUSTAINED: return g_asb_cfg.sustained_min_dwell_s;
        case ASB_STATE_GAMING: return g_asb_cfg.gaming_min_dwell_s;
        default: return 0;
    }
}

static inline void fsm_flush_state_time(asb_fsm_t *fsm) {
    struct timespec now_ts;
    clock_gettime(CLOCK_MONOTONIC, &now_ts);
    long spent = (long)(now_ts.tv_sec - fsm->ses_state_enter.tv_sec);
    if (spent <= 0) return;
    switch (fsm->state) {
        case ASB_STATE_HEAVY:     fsm->ses_time_heavy_sec     += spent; break;
        case ASB_STATE_GAMING:    fsm->ses_time_gaming_sec    += spent; break;
        case ASB_STATE_SUSTAINED: fsm->ses_time_sustained_sec += spent; break;
        case ASB_STATE_DEEP_IDLE:
            if (fsm_profile_tracks_idle) { fsm->bat_time_deep_idle_sec  += spent; }
            break;
        case ASB_STATE_LIGHT_IDLE:
            if (fsm_profile_tracks_idle) { fsm->bat_time_light_idle_sec += spent; }
            break;
        case ASB_STATE_MODERATE:
            if (fsm_profile_tracks_idle) { fsm->bat_time_moderate_sec   += spent; }
            break;
        default: break;
    }
    fsm->ses_state_enter = now_ts;
}

static void fsm_init(asb_fsm_t *fsm, int profile_idx) {
    memset(fsm, 0, sizeof(*fsm));
    fsm->state       = ASB_STATE_LIGHT_IDLE;
    fsm->pending     = ASB_STATE_LIGHT_IDLE;
    fsm->profile_idx = profile_idx;
    fsm->up_window   = 2;
    fsm->down_window = 5;
    fsm->plan.thermal_div = 1;  /* safe default: read every tick */
    fsm->auto_battery_restore_idx = -1;
    fsm->auto_battery_active = 0;
    fsm->auto_battery_last_action = 0;
    /* */
    strncpy(fsm->auto_battery_reason, "none", sizeof(fsm->auto_battery_reason) - 1);
    fsm->auto_battery_reason[sizeof(fsm->auto_battery_reason) - 1] = '\0';
    fsm->auto_battery_since = 0;
    {
        FILE *_abf = fopen("/data/adb/asb/auto_battery_state", "r");
        if (_abf) {
            int _act = 0, _ridx = -1;
            if (fscanf(_abf, "%d %d", &_act, &_ridx) == 2) {
                if (_act == 1 && _ridx >= 0 && _ridx < ASB_PROFILE_COUNT && _ridx != PROFILE_BATTERY) {
                    fsm->auto_battery_active = 1;
                    fsm->auto_battery_restore_idx = _ridx;
                }
            }
            fclose(_abf);
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);
    clock_gettime(CLOCK_MONOTONIC, &fsm->ses_state_enter);
    fsm_interpolate_caps(asb_profile_bounds_for(profile_idx),
                         profile_idx, fsm->state, &fsm->current_caps);
}

static inline void fsm_auto_battery_persist(const asb_fsm_t *fsm) {
    FILE *f = fopen("/data/adb/asb/auto_battery_state", "w");
    if (!f) return;
    fprintf(f, "%d %d\n", fsm->auto_battery_active, fsm->auto_battery_restore_idx);
    fclose(f);
}

static inline void fsm_session_reset(asb_fsm_t *fsm) {
    fsm->ses_gaming_entries      = 0;
    fsm->ses_sustained_entries   = 0;
    fsm->ses_thermal_entries     = 0;
    fsm->ses_unreachable_entries = 0;
    fsm->ses_time_heavy_sec      = 0;
    fsm->ses_time_gaming_sec     = 0;
    fsm->ses_time_sustained_sec  = 0;
    fsm->ses_gap_p0_sum          = 0;
    fsm->ses_gap_p1_sum          = 0;
    fsm->ses_gap_samples         = 0;
    fsm->ses_max_gap_p0          = 0;
    fsm->ses_max_gap_p1          = 0;
    fsm->ses_max_temp            = 0;
    fsm->ses_max_skin_temp       = 0;
    fsm->ses_max_surface_temp    = 0;
    fsm->ses_max_board_temp      = 0;
    fsm->ses_temp_invalid_count  = 0;
    fsm->ses_last_temp_reason[0] = '\0';
    clock_gettime(CLOCK_MONOTONIC, &fsm->ses_state_enter);
    clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);  /* prevent idle_boundary re-fire */
    fsm->ses_auto_degraded      = 0;
    fsm->bat_time_deep_idle_sec  = 0;
    fsm->bat_time_light_idle_sec = 0;
    fsm->bat_time_moderate_sec   = 0;
    fsm->bat_wake_cycles         = 0;
    fsm->bat_wake_screen         = 0;
    fsm->bat_wake_bg             = 0;
    fsm->bat_radio_active_ticks  = 0;
    fsm->bat_gaming_suppressed   = 0;
    fsm->bat_screen_off_count    = 0;
    fsm->bat_time_to_first_deep  = 0;
    fsm->ses_time_to_first_sus    = 0;
    fsm->ses_time_to_first_gaming = 0;
    fsm->ses_time_to_first_thermal= 0;
    fsm->ses_sustained_efficiency = -1;
    fsm->ses_recovery_count       = 0;
    fsm->ses_start_ts             = time(NULL);
    fsm->ses_intent               = 0;
    fsm->ses_intent_locked        = 0;
    fsm->ses_degrade_at_age       = 0;
    fsm->ses_headroom_sum         = 0;
    fsm->ses_headroom_samples     = 0;
    fsm->ses_headroom_min         = 100;
    fsm->ses_headroom_below70     = 0;
    fsm->ses_headroom_below50     = 0;
    fsm->clamp_hold               = 0;
    fsm->had_clamp_hold           = 0;
    fsm->had_futility             = 0;
    fsm->throttle_cap_ticks       = 0;
    fsm->recovery_cautious_until  = 0;
    fsm->perf_hot_guard_ticks      = 0;
    fsm->perf_hot_guard_active     = 0;
    fsm->cold_baseline_skin        = 0;
    fsm->cold_baseline_surface     = 0;
    fsm->cold_baseline_board       = 0;
    fsm->cold_baseline_ticks       = 0;
    fsm->cold_baseline_sum_skin    = 0;
    fsm->cold_baseline_sum_surface = 0;
    fsm->cold_baseline_sum_board   = 0;
    fsm->thermal_advisory_score    = 0;
    fsm->thermal_advisory_ticks    = 0;
    fsm->thermal_advisory_active   = 0;
    fsm->thermal_vote_skin         = 0;
    fsm->thermal_vote_surface      = 0;
    fsm->thermal_vote_board        = 0;
    fsm->would_bias_exit_gaming    = 0;
    fsm->would_bias_mode_a         = 0;
    fsm->would_bias_mode_b         = 0;
    fsm->would_bias_mode_a_count   = 0;
    fsm->would_bias_mode_b_count   = 0;
    fsm->adv_score_high_streak     = 0;
    fsm->virtual_ceiling_p0       = 0;
    fsm->virtual_ceiling_p1       = 0;
}

static int g_gaming_confirm_streak = 0;

static asb_state_t fsm_desired(const asb_metrics_t *m) {
    if (!m->misc.screen_on) return ASB_STATE_DEEP_IDLE;

    int ma_valid = (m->bat.current_ma > 0 && !m->bat.charging);

    if (m->gpu.load_pct >= g_asb_cfg.gaming_gpu_enter) {
        if (g_gaming_confirm_streak < 10000) g_gaming_confirm_streak++;
    } else if (m->gpu.load_pct < g_asb_cfg.gaming_gpu_exit) {
        g_gaming_confirm_streak = 0;
    }

    if (m->gpu.load_pct >= g_asb_cfg.gaming_gpu_enter) {
        if (g_asb_cfg.bat_suppress_gaming && fsm_profile_is_battery)
            return ASB_STATE_HEAVY;
        if (g_gaming_confirm_streak >= g_asb_cfg.gaming_confirm_ticks)
            return ASB_STATE_GAMING;
        return ASB_STATE_HEAVY;
    }

    /* 3-tier load thresholds: battery > balanced > global(performance)
     * Battery uses bat_*, balanced uses balanced_*, performance uses global */
    float heavy_thr = g_asb_cfg.heavy_load_enter;
    float mod_thr   = g_asb_cfg.moderate_load_enter;
    if (fsm_profile_is_battery && g_asb_cfg.bat_heavy_load_enter > 0) {
        heavy_thr = g_asb_cfg.bat_heavy_load_enter;
        mod_thr   = g_asb_cfg.bat_moderate_load_enter > 0
                    ? g_asb_cfg.bat_moderate_load_enter : mod_thr;
    } else if (fsm_profile_is_balanced) {
        if (g_asb_cfg.balanced_heavy_load_enter > 0)
            heavy_thr = g_asb_cfg.balanced_heavy_load_enter;
        if (g_asb_cfg.balanced_moderate_load_enter > 0)
            mod_thr = g_asb_cfg.balanced_moderate_load_enter;
    }
    /* Safety: heavy must be above moderate */
    if (heavy_thr <= mod_thr) heavy_thr = mod_thr + 0.5f;

    if (m->gpu.load_pct >= g_asb_cfg.heavy_gpu_enter ||
        m->cpu.load1 >= heavy_thr) {
        if (!ma_valid || m->bat.current_ma >= 150)
            return ASB_STATE_HEAVY;
    }

    if (m->cpu.load1 >= mod_thr)
        return ASB_STATE_MODERATE;
    if (ma_valid && m->bat.current_ma >= 120)
        return ASB_STATE_MODERATE;
    /* UI-burst escalation: GPU > 12% with screen on = active UI work
     * (scrolling shelf, app menu, transitions). Skip LIGHT_IDLE so caps
     * support smooth 144Hz UI. Below heavy_gpu_enter (35%) so this is
     * specifically the "user touching screen" zone. */
    if (m->misc.screen_on && m->gpu.load_pct >= 12)
        return ASB_STATE_MODERATE;

    /* Battery profile + screen on: skip LIGHT_IDLE entirely. Deploy logs
     * showed vendor PowerHAL clamps GPU max_pwrlevel to 17 (160MHz) ONLY
     * when state=LIGHT_IDLE on battery — this caused unlock→shelf scroll
     * stutter for the 1-2 seconds before UI-burst escalation kicked in.
     * MODERATE caps are still conservative (cpu_max ~1.5GHz, gpu ~47%) so
     * the drain trade-off is small; the smoothness gain is large. Other
     * profiles (balanced, performance) keep LIGHT_IDLE — they don't
     * trigger this vendor heuristic. */
    if (fsm_profile_is_battery && m->misc.screen_on)
        return ASB_STATE_MODERATE;

    return ASB_STATE_LIGHT_IDLE;
}

static int fsm_update(asb_fsm_t *fsm, const asb_metrics_t *m) {
    fsm->state_changed = 0;
    fsm->caps_changed  = 0;
    fsm->prev_state    = fsm->state;

    if (!m->misc.screen_on && fsm->state != ASB_STATE_DEEP_IDLE) {
        fsm->state   = ASB_STATE_DEEP_IDLE;
        fsm->pending = ASB_STATE_DEEP_IDLE;
        fsm->pending_ticks = 0;
        fsm->state_changed = 1;
        g_gaming_confirm_streak = 0;
    }
    else if (m->misc.screen_on && fsm->state == ASB_STATE_DEEP_IDLE) {
        fsm->state   = ASB_STATE_MODERATE;
        fsm->pending = ASB_STATE_MODERATE;
        fsm->pending_ticks = 0;
        fsm->state_changed = 1;
    }
    else {
        asb_state_t desired = fsm_desired(m);

        /* comfort-first battery brain -- when battery + screen on + device warm,
         * prevent pushing into SUSTAINED/GAMING heat targets.
         *
         * Old behavior capped to MODERATE which crippled UI in mixed-use:
         * any time CPU hit 42C (which on SD8 Elite Gen 5 happens routinely just from
         * scrolling + VPN + bg services), FSM dropped from HEAVY caps to MODERATE caps.
         * Each transition is a write storm + frequency dip + missed UI frames.
         * Now caps to HEAVY (preserves UI burst frequencies) while still preventing
         * the deeper SUSTAINED/GAMING entry that would actually heat the device. */
        if (fsm_profile_is_battery && m->misc.screen_on &&
            m->therm.cpu_max_c >= g_asb_cfg.bat_comfort_temp && desired > ASB_STATE_HEAVY) {
            /* log first time this fires per minute for visibility */
            static time_t g_last_comfort_log = 0;
            time_t _now = time(NULL);
            if (_now - g_last_comfort_log >= 60 && g_asb_cfg.log_level >= 1) {
                FILE *tef = fopen("/dev/.asb/thermal_events", "a");
                if (tef) {
                    fprintf(tef, "ts=%ld event=bat_comfort_cap temp=%d threshold=%d "
                                 "desired_was=%s capped_to=HEAVY\n",
                            (long)_now, m->therm.cpu_max_c, g_asb_cfg.bat_comfort_temp,
                            asb_state_names[desired]);
                    fclose(tef);
                }
                g_last_comfort_log = _now;
            }
            desired = ASB_STATE_HEAVY;
        }

        if (desired != fsm->pending) {
            fsm->pending       = desired;
            fsm->pending_ticks = 0;
        } else {
            fsm->pending_ticks++;
        }

        int thermal_to_sustained = 0;
        int gap_to_sustained = 0;
        int sustained_temp_enter = asb_config_profile_sustained_temp_enter(&g_asb_cfg, fsm->profile_idx);
        int sustained_temp_exit = asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm->profile_idx);
        int perf_hot_guard_temp = asb_config_profile_hot_guard_temp(&g_asb_cfg, fsm->profile_idx);
        int perf_hot_guard_tick_req = asb_config_profile_hot_guard_ticks(&g_asb_cfg, fsm->profile_idx);

        int sustained_reentry_blocked = (fsm->sustained_reentry_until > 0 &&
                                         time(NULL) < fsm->sustained_reentry_until);
        int thermal_floor = (fsm->profile_idx == PROFILE_PERFORMANCE) ? sustained_temp_exit : 40;

        /* throttle signal = real thermal OR hard vendor clamp.
         * soft_clamp (headroom < 70%) is advisory only -- reduces aggression
         * but does NOT trigger sustained entry. */
        int throttle_signal = m->therm.throttling || m->therm.hard_clamp;

        /* track consecutive throttle ticks for debounce */
        if (throttle_signal) {
            fsm->throttle_cap_ticks++;
        } else {
            fsm->throttle_cap_ticks = 0;
        }
        int throttle_confirmed = throttle_signal;
        /* performance requires 2+ consecutive throttle ticks OR temp already high */
        if (fsm->profile_idx == PROFILE_PERFORMANCE && throttle_confirmed) {
            if (fsm->throttle_cap_ticks < 2 && m->therm.cpu_max_c < sustained_temp_enter)
                throttle_confirmed = 0;
        }
        /* balanced requires 2+ ticks when entry is from hard_clamp only (not real thermal).
         * Also raise thermal floor to 48C for balanced to filter vendor advisory noise. */
        if (fsm->profile_idx == PROFILE_BALANCED && throttle_confirmed) {
            if (!m->therm.throttling) {
                /* Entry from hard_clamp only -- stricter gate */
                thermal_floor = 48;
                if (fsm->throttle_cap_ticks < 2) throttle_confirmed = 0;
            }
        }
        /* warmup grace -- don't rush into sustained after session start.
         * Exception: temp >= 60C or headroom < 40% (real emergency). */
        int warmup_grace = 0;
        if (fsm->ses_start_ts > 0 &&
            (time(NULL) - fsm->ses_start_ts) < g_asb_cfg.balanced_warmup_grace_s &&
            fsm->profile_idx == PROFILE_BALANCED) {
            int bypass_temp = (g_asb_cfg.balanced_warmup_bypass_temp > 0)
                              ? g_asb_cfg.balanced_warmup_bypass_temp : 60;
            int bypass_headroom = (g_asb_cfg.balanced_warmup_bypass_headroom > 0)
                                  ? g_asb_cfg.balanced_warmup_bypass_headroom : 40;
            if (m->therm.cpu_max_c < bypass_temp && m->therm.headroom_pct >= bypass_headroom)
                warmup_grace = 1;
        }
        if (warmup_grace) throttle_confirmed = 0;

        if (fsm->profile_idx == PROFILE_PERFORMANCE && perf_hot_guard_temp > 0) {
            if (m->therm.cpu_max_c >= perf_hot_guard_temp && desired >= ASB_STATE_HEAVY) {
                fsm->perf_hot_guard_ticks++;
            } else if (m->therm.cpu_max_c <= sustained_temp_exit) {
                fsm->perf_hot_guard_ticks = 0;
                fsm->perf_hot_guard_active = 0;
            } else if (fsm->perf_hot_guard_ticks > 0 && m->therm.cpu_max_c < perf_hot_guard_temp) {
                fsm->perf_hot_guard_ticks--;
            }

            if (perf_hot_guard_tick_req > 0 && fsm->perf_hot_guard_ticks >= perf_hot_guard_tick_req) {
                fsm->perf_hot_guard_active = 1;
                desired = ASB_STATE_SUSTAINED;
                thermal_to_sustained = 1;
                throttle_confirmed = 1;
                fsm->sustained_reason = 0;
            }

            if (g_asb_cfg.perf_skin_hot_thresh > 0 &&
                desired >= ASB_STATE_HEAVY &&
                fsm->thermal_vote_skin >= g_asb_cfg.perf_skin_hot_thresh &&
                fsm->thermal_vote_surface >= g_asb_cfg.perf_skin_hot_thresh) {
                fsm->perf_hot_guard_active = 1;
                desired = ASB_STATE_SUSTAINED;
                thermal_to_sustained = 1;
                throttle_confirmed = 1;
                fsm->sustained_reason = 0;
            }
        }

        if (fsm->cold_baseline_ticks < 30) {
            if (m->therm.skin_temp_c > 0)
                fsm->cold_baseline_sum_skin += m->therm.skin_temp_c;
            if (m->therm.surface_hotspot_c > 0)
                fsm->cold_baseline_sum_surface += m->therm.surface_hotspot_c;
            if (m->therm.board_temp_c > 0)
                fsm->cold_baseline_sum_board += m->therm.board_temp_c;
            fsm->cold_baseline_ticks++;
            if (fsm->cold_baseline_ticks == 30) {
                fsm->cold_baseline_skin    = fsm->cold_baseline_sum_skin / 30;
                fsm->cold_baseline_surface = fsm->cold_baseline_sum_surface / 30;
                fsm->cold_baseline_board   = fsm->cold_baseline_sum_board / 30;
            }
        } else {
            int score = 0;
            int vote_skin = 0, vote_surface = 0, vote_board = 0;
            if (m->therm.skin_temp_c > 0 && fsm->cold_baseline_skin > 0) {
                int delta = m->therm.skin_temp_c - fsm->cold_baseline_skin;
                if (delta > 0) {
                    int s = (delta * 100) / 8;
                    if (s > 100) s = 100;
                    vote_skin = s;
                    score += (s * 30) / 100;
                }
            }
            if (m->therm.surface_hotspot_c > 0 && fsm->cold_baseline_surface > 0) {
                int delta = m->therm.surface_hotspot_c - fsm->cold_baseline_surface;
                if (delta > 0) {
                    int s = (delta * 100) / 10;
                    if (s > 100) s = 100;
                    vote_surface = s;
                    score += (s * 40) / 100;
                }
            }
            if (m->therm.board_temp_c > 0 && fsm->cold_baseline_board > 0) {
                int delta = m->therm.board_temp_c - fsm->cold_baseline_board;
                if (delta > 0) {
                    int s = (delta * 100) / 10;
                    if (s > 100) s = 100;
                    vote_board = s;
                    score += (s * 20) / 100;
                }
            }
            if (score > 90) score = 90;
            fsm->thermal_advisory_score = score;
            fsm->thermal_vote_skin    = vote_skin;
            fsm->thermal_vote_surface = vote_surface;
            fsm->thermal_vote_board   = vote_board;

            if (score > 50) {
                fsm->thermal_advisory_ticks++;
                if (fsm->thermal_advisory_ticks >= 20) {
                    fsm->thermal_advisory_active = 1;
                    if (fsm->profile_idx == PROFILE_PERFORMANCE &&
                        desired == ASB_STATE_GAMING) {
                        fsm->would_bias_exit_gaming = 1;
                    }
                }
            } else if (score < 30) {
                if (fsm->thermal_advisory_ticks > 0)
                    fsm->thermal_advisory_ticks--;
                if (fsm->thermal_advisory_ticks == 0) {
                    fsm->thermal_advisory_active = 0;
                    fsm->would_bias_exit_gaming = 0;
                }
            }

            /* Mode A: sustained high advisory + significant gaming time, any profile.
             * Captures "device been gaming a while AND secondary zones hot". */
            if (score >= 70) {
                fsm->adv_score_high_streak++;
            } else {
                fsm->adv_score_high_streak = 0;
            }
            int prev_mode_a = fsm->would_bias_mode_a;
            if (fsm->adv_score_high_streak >= 3 &&
                fsm->ses_time_gaming_sec > 300) {  /* >5 min gaming this session */
                fsm->would_bias_mode_a = 1;
                if (!prev_mode_a) {
                    fsm->would_bias_mode_a_count++;
                }
            } else if (fsm->adv_score_high_streak == 0) {
                fsm->would_bias_mode_a = 0;
            }

            /* Mode B: "hot in hand without CPU panic" — skin and surface both warm
             * but CPU is cool. Captures device-comfort issue from passive heat
             * (charging, prolonged playback, warm pocket).
             * cpu_max_c < 60 = CPU is genuinely cool (not just exited from hot state). */
            int prev_mode_b = fsm->would_bias_mode_b;
            if (vote_skin >= 75 && vote_surface >= 75 &&
                m->therm.cpu_max_c > 0 && m->therm.cpu_max_c < 60) {
                fsm->would_bias_mode_b = 1;
                if (!prev_mode_b) {
                    fsm->would_bias_mode_b_count++;
                }
            } else if (vote_skin < 60 || vote_surface < 60) {
                fsm->would_bias_mode_b = 0;
            }
        }

        if (!sustained_reentry_blocked &&
            throttle_confirmed &&
            m->therm.cpu_max_c >= thermal_floor &&
            !(fsm->clamp_hold && m->therm.cpu_max_c < sustained_temp_enter) &&
            fsm->state >= ASB_STATE_HEAVY &&
            desired >= ASB_STATE_HEAVY)
        {
            desired = ASB_STATE_SUSTAINED;
            thermal_to_sustained = 1;
            fsm->sustained_reason = 0;
        }
        if (!thermal_to_sustained && !sustained_reentry_blocked &&
            fsm->thermal_trend >= 6 &&
            m->therm.cpu_max_c >= (sustained_temp_enter - 5) &&
            fsm->state >= ASB_STATE_HEAVY &&
            desired >= ASB_STATE_HEAVY)
        {
            desired = ASB_STATE_SUSTAINED;
            thermal_to_sustained = 1;
            fsm->sustained_reason = 0;
        }
        /* removed legacy headroom<50 shortcut.
         * All SUSTAINED entries go through unified path:
         * throttle_signal -> throttle_confirmed -> warmup_grace -> debounce. */

        if (!thermal_to_sustained && !sustained_reentry_blocked &&
            !fsm->clamp_hold &&
            fsm->state == ASB_STATE_GAMING &&
            g_asb_cfg.gaming_gap_thresh > 0)
        {
            int cur_max_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
            int cur_gap    = (cur_max_p0 > 0)
                             ? (fsm->current_caps.cpu_max[0] - cur_max_p0)
                             : 0;
            if (cur_gap > g_asb_cfg.gaming_gap_thresh) {
                fsm->gaming_gap_ticks_count++;
            } else {
                fsm->gaming_gap_ticks_count = 0;
            }

            if (fsm->gaming_gap_ticks_count >= g_asb_cfg.gaming_gap_ticks &&
                desired >= ASB_STATE_HEAVY)
            {
                desired = ASB_STATE_SUSTAINED;
                gap_to_sustained = 1;
                fsm->gaming_gap_ticks_count = 0;
                fsm->sustained_reason = 1;
            }
        } else if (fsm->state != ASB_STATE_GAMING) {
            fsm->gaming_gap_ticks_count = 0;
        }

        if (!thermal_to_sustained && !gap_to_sustained &&
            desired == ASB_STATE_GAMING)
        {
            /* ceiling_lock -- if virtual ceiling on big cluster
             * is below 1.5GHz, GAMING is pointless. Demote to HEAVY. */
            if (fsm->virtual_ceiling_p1 > 0 && fsm->virtual_ceiling_p1 < 1500000) {
                desired = ASB_STATE_HEAVY;
            }

            time_t now_t = time(NULL);
            int cooldown_active = (fsm->gaming_retry_until > 0 &&
                                   now_t < fsm->gaming_retry_until);
            int temp_max = g_asb_cfg.gaming_retry_temp_max;
            if (temp_max > 0 && fsm->ses_recovery_count >= 2)
                temp_max -= 5;
            if (temp_max < 30) temp_max = 30;
            int too_hot = (g_asb_cfg.gaming_retry_temp_max > 0 &&
                           m->therm.cpu_max_c > temp_max &&
                           fsm->gaming_retry_until > 0);
            if (cooldown_active || too_hot) {
                desired = ASB_STATE_HEAVY;
            } else {
                fsm->gaming_retry_until = 0;
            }
        }
        if (fsm->prev_state == ASB_STATE_SUSTAINED &&
            fsm->state_changed &&
            fsm->state != ASB_STATE_SUSTAINED)
        {
            time_t now_exit = time(NULL);
            if (g_asb_cfg.gaming_retry_cooldown_s > 0)
                fsm->gaming_retry_until = now_exit + g_asb_cfg.gaming_retry_cooldown_s;
            if (g_asb_cfg.sustained_reentry_cooldown_s > 0) {
                int cd = g_asb_cfg.sustained_reentry_cooldown_s;
                if (fsm->clamp_hold) cd *= 2;
                else if (fsm->recovery_cautious_until > 0 &&
                         time(NULL) < fsm->recovery_cautious_until)
                    cd = (int)(cd * 1.5f);
                fsm->sustained_reentry_until = now_exit + cd;
            }
        }

        int window = (desired > fsm->state)
                     ? fsm->up_window
                     : fsm->down_window;
        if (thermal_to_sustained) window = 1;
        /* UI-burst fast escalation: when desired bumped up by gpu.load_pct≥12
         * on screen-on, bypass the battery up_window×2 doubling. The 2× is
         * anti-flap for normal load triggers, but on UI scrolling it adds
         * 8-10 seconds of stutter before FSM gives MODERATE caps to GPU. With
         * this bypass, scroll-triggered MODERATE happens at window=1
         * (immediate next tick). */
        int ui_burst_path = (m->misc.screen_on && m->gpu.load_pct >= 12 &&
                             desired == ASB_STATE_MODERATE &&
                             fsm->state == ASB_STATE_LIGHT_IDLE);
        if (ui_burst_path) {
            window = 1;
        } else if (fsm_profile_is_battery && desired > fsm->state &&
            desired >= ASB_STATE_MODERATE &&
            fsm->state <= ASB_STATE_LIGHT_IDLE) {
            window = fsm->up_window * 2;
        }
        if (fsm_profile_is_battery && desired < fsm->state &&
            fsm->state >= ASB_STATE_MODERATE) {
            int bat_dw = fsm->down_window / 2;
            if (bat_dw < 2) bat_dw = 2;
            if (bat_dw < window) window = bat_dw;
        }
        if (m->misc.screen_on && m->gpu.load_pct >= 5 &&
            desired < ASB_STATE_MODERATE && fsm->state >= ASB_STATE_MODERATE) {
            int ui_hold = fsm->down_window * 3;
            if (ui_hold > window) window = ui_hold;
        }
        if (fsm_profile_is_battery &&
            g_asb_cfg.bat_fast_idle_s > 0 &&
            fsm->state == ASB_STATE_LIGHT_IDLE &&
            desired == ASB_STATE_DEEP_IDLE) {
            int fast_w = g_asb_cfg.bat_fast_idle_s / 2;
            if (fast_w < 1) fast_w = 1;
            if (fast_w < window) window = fast_w;
        }

        if (fsm->pending_ticks >= window && desired != fsm->state) {
            int can_leave = 1;
            if (fsm->state == ASB_STATE_SUSTAINED &&
                sustained_temp_exit > 0 &&
                m->therm.cpu_max_c >= sustained_temp_exit)
                can_leave = 0;
if (!can_leave &&
                fsm->state == ASB_STATE_SUSTAINED &&
                fsm->profile_idx == PROFILE_PERFORMANCE &&
                fsm_elapsed_sec(fsm) >= 180 &&
                sustained_temp_enter > 0 &&
                m->therm.cpu_max_c <= sustained_temp_enter - 3 &&
                fsm->thermal_trend <= 3)
            {
                can_leave = 1;
                /* Mark for logging via sustained_reason — this is an
                 * informational exit not a real temp_dropped exit. */
                fsm->sustained_reason = 2;  /* 2 = time_based_escape */
            }
            if (can_leave && desired < fsm->state) {
                int min_dwell = fsm_min_dwell_for_state(fsm->state);
                if (min_dwell > 0 && fsm_elapsed_sec(fsm) < min_dwell)
                    can_leave = 0;
            }
            if (can_leave) {
                fsm->state         = desired;
                fsm->pending_ticks = 0;
                fsm->state_changed = 1;
                clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);
            }
        }
    }

    /* thermal_cap = real thermal OR hard vendor clamp.
     * soft_clamp (headroom 50-70%) does not set thermal_cap. */
    int new_thermal = m->therm.throttling || m->therm.hard_clamp;
    if (new_thermal != fsm->thermal_cap) {
        fsm->thermal_cap  = new_thermal;
        fsm->caps_changed = 1;
    }

    asb_profile_caps_t new_caps;
    fsm_interpolate_caps(asb_profile_bounds_for(fsm->profile_idx),
                         fsm->profile_idx, fsm->state, &new_caps);
    
    if (fsm->thermal_cap && fsm->state != ASB_STATE_SUSTAINED) {
        float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
        for (int i = 0; i < 3; i++)
            new_caps.cpu_max[i] = (int)(new_caps.cpu_max[i] * keep);
        int gpu_drop = g_asb_cfg.thermal_overlay_pct;
        new_caps.gpu_max_pct = new_caps.gpu_max_pct > gpu_drop
                               ? new_caps.gpu_max_pct - gpu_drop : 0;
    }

    if (fsm->profile_idx == PROFILE_PERFORMANCE && fsm->perf_hot_guard_active) {
        if (new_caps.cpu_max[1] > 3520000) new_caps.cpu_max[1] = 3520000;
        if (new_caps.gpu_max_pct > 90) new_caps.gpu_max_pct = 90;
    }

    if (fsm->state_changed ||
        memcmp(&new_caps, &fsm->current_caps, sizeof(new_caps)) != 0)
    {
        fsm->current_caps = new_caps;
        fsm->caps_changed = 1;
    }

    if (m->therm.cpu_max_c > fsm->ses_max_temp)
        fsm->ses_max_temp = m->therm.cpu_max_c;
    if (m->therm.skin_temp_c > fsm->ses_max_skin_temp)
        fsm->ses_max_skin_temp = m->therm.skin_temp_c;
    if (m->therm.surface_hotspot_c > fsm->ses_max_surface_temp)
        fsm->ses_max_surface_temp = m->therm.surface_hotspot_c;
    if (m->therm.board_temp_c > fsm->ses_max_board_temp)
        fsm->ses_max_board_temp = m->therm.board_temp_c;
    /* sensor health tracking for session-level visibility */
    if (!m->therm.temp_valid) {
        fsm->ses_temp_invalid_count++;
        if (m->therm.temp_invalid_reason[0]) {
            snprintf(fsm->ses_last_temp_reason,
                     sizeof(fsm->ses_last_temp_reason),
                     "%s", m->therm.temp_invalid_reason);
        }
    }
    
    {
        if (fsm->prev_temp == 0) {
            fsm->prev_temp = m->therm.cpu_max_c;
        } else {
            int delta = m->therm.cpu_max_c - fsm->prev_temp;
            fsm->prev_temp = m->therm.cpu_max_c;
            fsm->trend_buf[fsm->trend_idx % 3] = delta;
            fsm->trend_idx++;
            fsm->thermal_trend = fsm->trend_buf[0] + fsm->trend_buf[1] + fsm->trend_buf[2];
        }
    }

    if (fsm->state == ASB_STATE_GAMING) {
        int cur_max_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
        int cur_max_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
        if (cur_max_p0 > 0) {
            /* Ceiling-Adaptive Reshaping -- when virtual ceiling is set,
             * measure gap relative to observed ceiling, not target caps.
             * This reflects real efficiency within the available headroom. */
            int ref_p0 = (fsm->virtual_ceiling_p0 > 0) ? fsm->virtual_ceiling_p0
                         : fsm->current_caps.cpu_max[0];
            int ref_p1 = (fsm->virtual_ceiling_p1 > 0) ? fsm->virtual_ceiling_p1
                         : fsm->current_caps.cpu_max[1];
            int g0 = ref_p0 - cur_max_p0;
            int g1 = (cur_max_p1 > 0) ? (ref_p1 - cur_max_p1) : 0;
            if (g0 > 0) {
                fsm->ses_gap_p0_sum += g0;
                fsm->ses_gap_p1_sum += g1;
                fsm->ses_gap_samples++;
                if (g0 > fsm->ses_max_gap_p0) fsm->ses_max_gap_p0 = g0;
                if (g1 > fsm->ses_max_gap_p1) fsm->ses_max_gap_p1 = g1;
            }
        }
    }

    if (fsm->state_changed) {
        struct timespec now_ts;
        clock_gettime(CLOCK_MONOTONIC, &now_ts);
        long spent = (long)(now_ts.tv_sec - fsm->ses_state_enter.tv_sec);
        switch (fsm->prev_state) {
            case ASB_STATE_HEAVY:    fsm->ses_time_heavy_sec    += spent; break;
            case ASB_STATE_GAMING:   fsm->ses_time_gaming_sec   += spent; break;
            case ASB_STATE_SUSTAINED:fsm->ses_time_sustained_sec+= spent; break;
            case ASB_STATE_DEEP_IDLE:
                if (fsm_profile_tracks_idle) { fsm->bat_time_deep_idle_sec  += spent; } break;
            case ASB_STATE_LIGHT_IDLE:
                if (fsm_profile_tracks_idle) { fsm->bat_time_light_idle_sec += spent; } break;
            case ASB_STATE_MODERATE:
                if (fsm_profile_tracks_idle) { fsm->bat_time_moderate_sec   += spent; } break;
            default: break;
        }
        if (fsm_profile_tracks_idle &&
            fsm->prev_state == ASB_STATE_DEEP_IDLE &&
            fsm->state != ASB_STATE_DEEP_IDLE) {
            fsm->bat_wake_cycles++;
            /* Wake Attribution */
            if (m->misc.screen_on)
                fsm->bat_wake_screen++;
            else
                fsm->bat_wake_bg++;
        }
        if (fsm_profile_tracks_idle &&
            fsm->state == ASB_STATE_DEEP_IDLE &&
            fsm->bat_time_to_first_deep == 0 &&
            fsm->ses_start_ts > 0)
            fsm->bat_time_to_first_deep = time(NULL) - fsm->ses_start_ts;
        fsm->ses_state_enter = now_ts;

        if (fsm->state == ASB_STATE_GAMING) {
            fsm->ses_gaming_entries++;
            if (fsm->ses_time_to_first_gaming == 0 && fsm->ses_start_ts > 0)
                fsm->ses_time_to_first_gaming = time(NULL) - fsm->ses_start_ts;
        }
        if (fsm->state == ASB_STATE_SUSTAINED) {
            fsm->ses_sustained_entries++;
            if (fsm->ses_time_to_first_sus == 0 && fsm->ses_start_ts > 0)
                fsm->ses_time_to_first_sus = time(NULL) - fsm->ses_start_ts;
        }
        if (fsm_profile_is_battery &&
            g_asb_cfg.bat_suppress_gaming &&
            fsm->state == ASB_STATE_HEAVY &&
            fsm->prev_state != ASB_STATE_GAMING)
        {
        }
    }

    return fsm->caps_changed;
}
