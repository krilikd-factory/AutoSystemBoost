#pragma once

#include <time.h>
#include <string.h>
#include "asb_metrics.h"
#include "asb_config.h"

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
    {
        .floor = {
            .cpu_max    = { 1190400, 1344000, 0 },
            .cpu_min    = {  384000,  768000, 0 },
            .gpu_max_pct = 15, .gpu_min_pct = 0,
            .ravg_ticks = 8, .idle_enough = 95,
            .uclamp_top_max = 10, .uclamp_bg_max = 5
        },
        .ceil = {
            .cpu_max    = { 1612800, 2265600, 0 },
            .cpu_min    = {  576000,  883200, 0 },
            .gpu_max_pct = 30, .gpu_min_pct = 0,
            .ravg_ticks = 8, .idle_enough = 95,
            .uclamp_top_max = 25, .uclamp_bg_max = 10
        }
    },
    {
        .floor = {
            .cpu_max    = { 1728000, 2265600, 0 },
            .cpu_min    = {  576000,  883200, 0 },
            .gpu_max_pct = 45, .gpu_min_pct = 0,
            .ravg_ticks = 4, .idle_enough = 50,
            .uclamp_top_max = 50, .uclamp_bg_max = 25
        },
        .ceil = {
            .cpu_max    = { 2745600, 3648000, 0 },
            .cpu_min    = {  787200,  883200, 0 },
            .gpu_max_pct = 85, .gpu_min_pct = 0,
            .ravg_ticks = 3, .idle_enough = 45,
            .uclamp_top_max = 80, .uclamp_bg_max = 35
        }
    },
    {
        .floor = {
            .cpu_max    = { 2265600, 3072000, 0 },
            .cpu_min    = { 1190400, 1881600, 0 },
            .gpu_max_pct = 60, .gpu_min_pct = 20,
            .ravg_ticks = 2, .idle_enough = 10,
            .uclamp_top_max = 80, .uclamp_bg_max = 55
        },
        .ceil = {
            .cpu_max    = { 3628800, 4608000, 0 },
            .cpu_min    = { 2112000, 2438400, 0 },
            .gpu_max_pct = 100, .gpu_min_pct = 30,
            .ravg_ticks = 2, .idle_enough = 8,
            .uclamp_top_max = 100, .uclamp_bg_max = 75
        }
    }
};

#define PROFILE_BATTERY     0
static int fsm_profile_is_battery = 0;
#define PROFILE_BALANCED    1
#define PROFILE_PERFORMANCE 2

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
    const asb_profile_bounds_t *bounds, asb_state_t state,
    asb_profile_caps_t *out)
{
    float t = (state == ASB_STATE_SUSTAINED)
              ? g_asb_cfg.sustained_level
              : g_state_level[state];
    const asb_profile_caps_t *f = &bounds->floor;
    const asb_profile_caps_t *c = &bounds->ceil;

    for (int i = 0; i < 3; i++) {
        out->cpu_max[i] = lerp_int(f->cpu_max[i], c->cpu_max[i], t);
        out->cpu_min[i] = lerp_int(f->cpu_min[i], c->cpu_min[i], t);
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
    int             bat_gaming_suppressed;
    int             bat_screen_off_count;
    long            bat_time_to_first_deep;

    int             ses_intent;
    int             ses_intent_locked;
    long            ses_degrade_at_age;

    /* V29-r10: headroom telemetry per session */
    long            ses_headroom_sum;       /* accumulator for avg */
    int             ses_headroom_samples;
    int             ses_headroom_min;       /* min headroom seen */
    int             ses_headroom_below70;   /* ticks with headroom<70% */
    int             ses_headroom_below50;   /* ticks with headroom<50% */

    /* V30: mid-session tune tracking */
    int             ses_mid_tune_count;     /* number of mid-tune adjustments */
    int             ses_mid_tune_dir;       /* net direction: +1 up, -1 down, 0 mixed */

    /* V32: clamp-stable hold -- suppress gap-triggered SUSTAINED jitter
     * after anti-clamp futility is confirmed */
    int             clamp_hold;             /* 1 = gap-triggered sustained suppressed */
    int             had_clamp_hold;         /* V32: session-latched -- was clamp_hold ever set? */
    int             had_futility;           /* V32: session-latched -- was futility ever triggered? */

    /* V31: session plan -- pre-computed policy decisions (rebuilt on events, not per-tick) */
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
        uint8_t plan_class;     /* V31: session class enum (see PLAN_CLASS_*) */
        uint8_t sensor_budget;  /* V31: max full-mode sensor reads per plan epoch */
        uint8_t sensor_used;    /* V31: consumed sensor budget (runtime) */
    } plan;
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
            if (fsm_profile_is_battery) { fsm->bat_time_deep_idle_sec  += spent; }
            break;
        case ASB_STATE_LIGHT_IDLE:
            if (fsm_profile_is_battery) { fsm->bat_time_light_idle_sec += spent; }
            break;
        case ASB_STATE_MODERATE:
            if (fsm_profile_is_battery) { fsm->bat_time_moderate_sec   += spent; }
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
    clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);
    clock_gettime(CLOCK_MONOTONIC, &fsm->ses_state_enter);
    fsm_interpolate_caps(&g_profile_bounds[profile_idx],
                         fsm->state, &fsm->current_caps);
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
    clock_gettime(CLOCK_MONOTONIC, &fsm->ses_state_enter);
    clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);  /* prevent idle_boundary re-fire */
    fsm->ses_auto_degraded      = 0;
    fsm->bat_time_deep_idle_sec  = 0;
    fsm->bat_time_light_idle_sec = 0;
    fsm->bat_time_moderate_sec   = 0;
    fsm->bat_wake_cycles         = 0;
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
}

static asb_state_t fsm_desired(const asb_metrics_t *m) {
    if (!m->misc.screen_on) return ASB_STATE_DEEP_IDLE;

    int ma_valid = (m->bat.current_ma > 0 && !m->bat.charging);

    if (m->gpu.load_pct >= g_asb_cfg.gaming_gpu_enter) {
        if (g_asb_cfg.bat_suppress_gaming && fsm_profile_is_battery)
            return ASB_STATE_HEAVY;
        return ASB_STATE_GAMING;
    }

    if (m->gpu.load_pct >= g_asb_cfg.heavy_gpu_enter ||
        m->cpu.load1 >= (fsm_profile_is_battery && g_asb_cfg.bat_heavy_load_enter > 0
                         ? g_asb_cfg.bat_heavy_load_enter
                         : g_asb_cfg.heavy_load_enter)) {
        if (!ma_valid || m->bat.current_ma >= 150)
            return ASB_STATE_HEAVY;
    }

    if (m->cpu.load1 >= (fsm_profile_is_battery && g_asb_cfg.bat_moderate_load_enter > 0
                         ? g_asb_cfg.bat_moderate_load_enter
                         : g_asb_cfg.moderate_load_enter))
        return ASB_STATE_MODERATE;
    if (ma_valid && m->bat.current_ma >= 120)
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
    }
    else if (m->misc.screen_on && fsm->state == ASB_STATE_DEEP_IDLE) {
        fsm->state   = ASB_STATE_LIGHT_IDLE;
        fsm->pending = ASB_STATE_LIGHT_IDLE;
        fsm->pending_ticks = 0;
        fsm->state_changed = 1;
    }
    else {
        asb_state_t desired = fsm_desired(m);

        if (desired != fsm->pending) {
            fsm->pending       = desired;
            fsm->pending_ticks = 0;
        } else {
            fsm->pending_ticks++;
        }

        int thermal_to_sustained = 0;
        int gap_to_sustained = 0;

        int sustained_reentry_blocked = (fsm->sustained_reentry_until > 0 &&
                                         time(NULL) < fsm->sustained_reentry_until);
        if (!sustained_reentry_blocked &&
            m->therm.throttling &&
            !(fsm->clamp_hold && m->therm.cpu_max_c < g_asb_cfg.sustained_temp_enter) &&
            fsm->state >= ASB_STATE_HEAVY &&
            desired >= ASB_STATE_HEAVY)
        {
            desired = ASB_STATE_SUSTAINED;
            thermal_to_sustained = 1;
            fsm->sustained_reason = 0;
        }
        if (!thermal_to_sustained && !sustained_reentry_blocked &&
            fsm->thermal_trend >= 6 &&
            m->therm.cpu_max_c >= (g_asb_cfg.sustained_temp_enter - 5) &&
            fsm->state >= ASB_STATE_HEAVY &&
            desired >= ASB_STATE_HEAVY)
        {
            desired = ASB_STATE_SUSTAINED;
            thermal_to_sustained = 1;
            fsm->sustained_reason = 0;
        }
        /* V29: Headroom-based early thermal detection.
         * If kernel already capped freq to <50% of max, burst is futile
         * even if thermal zone temp hasn't crossed threshold yet.
         * This gives ~1-2s earlier detection than temp-based path. */
        if (!thermal_to_sustained && !sustained_reentry_blocked &&
            m->therm.headroom_pct > 0 && m->therm.headroom_pct < 50 &&
            fsm->state >= ASB_STATE_HEAVY &&
            desired >= ASB_STATE_HEAVY)
        {
            desired = ASB_STATE_SUSTAINED;
            thermal_to_sustained = 1;
            fsm->sustained_reason = 0;
        }

        if (!thermal_to_sustained && !sustained_reentry_blocked &&
            !fsm->clamp_hold &&  /* V32: suppress gap jitter after futility */
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
                /* V33: when vendor already clamping, rapid sustained cycling
                 * is useless -- extend cooldown to reduce FSM jitter. */
                int cd = g_asb_cfg.sustained_reentry_cooldown_s;
                if (fsm->clamp_hold) cd *= 2;
                fsm->sustained_reentry_until = now_exit + cd;
            }
        }

        int window = (desired > fsm->state)
                     ? fsm->up_window
                     : fsm->down_window;
        if (thermal_to_sustained) window = 1;
        if (fsm_profile_is_battery && desired > fsm->state &&
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
                g_asb_cfg.sustained_temp_exit > 0 &&
                m->therm.cpu_max_c >= g_asb_cfg.sustained_temp_exit)
                can_leave = 0;
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

    int new_thermal = m->therm.throttling;
    if (new_thermal != fsm->thermal_cap) {
        fsm->thermal_cap  = new_thermal;
        fsm->caps_changed = 1;
    }

    asb_profile_caps_t new_caps;
    fsm_interpolate_caps(&g_profile_bounds[fsm->profile_idx],
                         fsm->state, &new_caps);
    
    if (fsm->thermal_cap && fsm->state != ASB_STATE_SUSTAINED) {
        float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
        for (int i = 0; i < 3; i++)
            new_caps.cpu_max[i] = (int)(new_caps.cpu_max[i] * keep);
        int gpu_drop = g_asb_cfg.thermal_overlay_pct;
        new_caps.gpu_max_pct = new_caps.gpu_max_pct > gpu_drop
                               ? new_caps.gpu_max_pct - gpu_drop : 0;
    }

    if (fsm->state_changed ||
        memcmp(&new_caps, &fsm->current_caps, sizeof(new_caps)) != 0)
    {
        fsm->current_caps = new_caps;
        fsm->caps_changed = 1;
    }

    if (m->therm.cpu_max_c > fsm->ses_max_temp)
        fsm->ses_max_temp = m->therm.cpu_max_c;
    
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
            int g0 = fsm->current_caps.cpu_max[0] - cur_max_p0;
            int g1 = (cur_max_p1 > 0) ? (fsm->current_caps.cpu_max[1] - cur_max_p1) : 0;
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
                if (fsm_profile_is_battery) { fsm->bat_time_deep_idle_sec  += spent; } break;
            case ASB_STATE_LIGHT_IDLE:
                if (fsm_profile_is_battery) { fsm->bat_time_light_idle_sec += spent; } break;
            case ASB_STATE_MODERATE:
                if (fsm_profile_is_battery) { fsm->bat_time_moderate_sec   += spent; } break;
            default: break;
        }
        if (fsm_profile_is_battery &&
            fsm->prev_state == ASB_STATE_DEEP_IDLE &&
            fsm->state != ASB_STATE_DEEP_IDLE)
            fsm->bat_wake_cycles++;
        if (fsm_profile_is_battery &&
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
