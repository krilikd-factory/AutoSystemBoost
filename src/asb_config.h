#pragma once
/*
 * asb_fsm.h — Hysteresis state machine
 *
 * 5 states × 3 profiles (battery/balanced/performance).
 * Each state sets CPU/GPU caps within the profile range.
 *
 * HYSTERESIS PRINCIPLE:
 *   Upward transition (IDLE→MODERATE): fast, 2-tick window
 *   Downward transition (MODERATE→IDLE): slow, 10-tick window
 *   Prevents flickering on brief load spikes.
 *
 * EVENT PRIORITY:
 *   1. screen OFF → DEEP_IDLE immediately (uevent)
 *   2. screen ON  → LIGHT_IDLE immediately (uevent)
 *   3. thermal throttle → overlay, does not change FSM state
 *   4. battery drain → FSM transition via windows
 */

#include <time.h>
#include <string.h>
#include "asb_metrics.h"
#include "asb_config.h"

extern asb_runtime_config_t g_asb_cfg;

/* ─── States ───────────────────────────────────────────────── */
typedef enum {
    ASB_STATE_DEEP_IDLE  = 0, /* screen OFF, full idle          */
    ASB_STATE_LIGHT_IDLE = 1, /* screen ON, low activity       */
    ASB_STATE_MODERATE   = 2, /* active use            */
    ASB_STATE_HEAVY      = 3, /* video, maps, rendering           */
    ASB_STATE_SUSTAINED  = 4, /* sustained load under thermal pressure   */
    ASB_STATE_GAMING     = 5, /* gaming, GPU load > threshold    */
    ASB_STATE_COUNT      = 6
} asb_state_t;

static const char *asb_state_names[] = {
    "DEEP_IDLE", "LIGHT_IDLE", "MODERATE", "HEAVY", "SUSTAINED", "GAMING"
};

/* ─── Profile constraints ──────────────────────────────────── */
/* Each profile defines a [floor, ceil] range for the FSM.
 * FSM operates within the range — never exceeds it.
 * Units: kHz for CPU, % of max for GPU.                    */
typedef struct {
    /* CPU caps per policy (0=little, 1=mid/big, 2=prime) */
    int cpu_max[3];   /* policy max frequency in kHz */
    int cpu_min[3];   /* policy min frequency in kHz  */
    /* GPU */
    int gpu_max_pct;
    int gpu_min_pct;
    /* WALT */
    int ravg_ticks;
    int idle_enough;
    /* Scheduler */
    int uclamp_top_max;
    int uclamp_bg_max;
} asb_profile_caps_t;

/* Profile bounds — FSM CANNOT exceed these */
typedef struct {
    asb_profile_caps_t floor; /* most conservative profile variant */
    asb_profile_caps_t ceil;  /* most performant          */
} asb_profile_bounds_t;

/*
 * Values for OnePlus 15 / Snapdragon 8 Elite
 * policy0 = little (0-5), policy6 = prime (6-7)
 * Frequencies in kHz.
 */
/* ─── Profile bounds — OnePlus 15 / Snapdragon 8 Elite ─────────────
 * CPU topology: policy0 (cpus 0-5, max 3628800)
 *               policy6 (cpus 6-7, max 4608000)
 * cpu_max[2] = 0 → unused (only 2 policies on this device)
 *
 * Ranges chosen within vendor-permitted windows:
 * - battery: hard limit, power efficiency
 * - balanced: balanced range
 * - performance: full hardware ceiling
 *
 * WALT/uclamp are the primary influence mechanism —
 * they work reliably even with vendor perf HAL overrides.    */
static const asb_profile_bounds_t g_profile_bounds[3] = {
    /* [0] BATTERY — strongly limited */
    {
        .floor = {
            /* DEEP_IDLE floor: policy0@1190400, policy6@1344000 */
            .cpu_max    = { 1190400, 1344000, 0 },
            .cpu_min    = {  384000,  768000, 0 },
            .gpu_max_pct = 15, .gpu_min_pct = 0,
            .ravg_ticks = 8, .idle_enough = 95,
            .uclamp_top_max = 10, .uclamp_bg_max = 5
        },
        .ceil = {
            /* MODERATE ceiling: policy0@1612800, policy6@2265600 */
            .cpu_max    = { 1612800, 2265600, 0 },
            .cpu_min    = {  576000,  883200, 0 },
            .gpu_max_pct = 30, .gpu_min_pct = 0,
            .ravg_ticks = 8, .idle_enough = 95,
            .uclamp_top_max = 25, .uclamp_bg_max = 10
        }
    },
    /* [1] BALANCED — working range */
    {
        .floor = {
            /* LIGHT_IDLE floor: moderate limits */
            .cpu_max    = { 1728000, 2265600, 0 },
            .cpu_min    = {  576000,  883200, 0 },
            .gpu_max_pct = 45, .gpu_min_pct = 0,
            .ravg_ticks = 4, .idle_enough = 50,
            .uclamp_top_max = 50, .uclamp_bg_max = 25
        },
        .ceil = {
            /* GAMING ceiling: limits lifted */
            .cpu_max    = { 2745600, 3648000, 0 },
            .cpu_min    = {  787200,  883200, 0 },
            .gpu_max_pct = 85, .gpu_min_pct = 0,
            .ravg_ticks = 3, .idle_enough = 45,
            .uclamp_top_max = 80, .uclamp_bg_max = 35
        }
    },
    /* [2] PERFORMANCE — full potential */
    {
        .floor = {
            /* MODERATE floor at performance: already high */
            .cpu_max    = { 2265600, 3072000, 0 },
            .cpu_min    = { 1190400, 1881600, 0 },
            .gpu_max_pct = 60, .gpu_min_pct = 20,
            .ravg_ticks = 2, .idle_enough = 10,
            .uclamp_top_max = 80, .uclamp_bg_max = 55
        },
        .ceil = {
            /* GAMING ceiling: hardware maximum */
            .cpu_max    = { 3628800, 4608000, 0 },
            .cpu_min    = { 2112000, 2438400, 0 },
            .gpu_max_pct = 100, .gpu_min_pct = 30,
            .ravg_ticks = 2, .idle_enough = 8,
            .uclamp_top_max = 100, .uclamp_bg_max = 75
        }
    }
};

/* Profile index */
#define PROFILE_BATTERY     0
/* Current profile for fsm_desired (updated by governor.c) */
static int fsm_profile_is_battery = 0;
#define PROFILE_BALANCED    1
#define PROFILE_PERFORMANCE 2

/* ─── State → caps mapping ─────────────────────────────────── */
/*
 * For each state: how high in the profile range?
 * 0.0 = floor, 1.0 = ceil.
 * Linear interpolation between floor and ceil.
 */
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
    /* Battery: cap GPU in LIGHT_IDLE to reduce idle power draw */
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

/* ─── FSM context ──────────────────────────────────────────── */
typedef struct {
    asb_state_t     state;
    asb_state_t     pending;
    int             profile_idx;
    int             thermal_cap;

    /* Hysteresis */
    int             pending_ticks;  /* ticks spent in pending */
    /* Up: 2 ticks (2s/tick = 4s), down: 5 ticks = 10s  */
    int             up_window;
    int             down_window;

    struct timespec last_transition;
    asb_profile_caps_t current_caps;

    /* For logging: what changed */
    int             caps_changed;
    int             state_changed;
    asb_state_t     prev_state;     /* state before last transition */
    /* Gap-aware SUSTAINED */
    int             gaming_gap_ticks_count; /* consecutive ticks with GAMING gap above threshold */
    time_t          gaming_retry_until;     /* cooldown: do not attempt GAMING until this time */
    int             sustained_reason;       /* 0=thermal, 1=gap_unreachable — reason for last entry */
    time_t          sustained_reentry_until; /* cooldown: do not enter SUSTAINED until this time */

    /* ── Session telemetry (V22-r11) ──────────────────────────
     * Reset on fsm_init() and on 'reload' command.
     * Answers: how did the governor run this session?  */
    int             ses_gaming_entries;      /* GAMING entry count */
    int             ses_sustained_entries;   /* SUSTAINED entry count */
    int             ses_thermal_entries;     /* of which — via thermal path */
    int             ses_unreachable_entries; /* of which — via gaming_unreachable path */

    long            ses_time_heavy_sec;      /* total time in HEAVY (s) */
    long            ses_time_gaming_sec;     /* total time in GAMING (s) */
    long            ses_time_sustained_sec;  /* total time in SUSTAINED (s) */

    long            ses_gap_p0_sum;          /* for avg_gap_p0 in GAMING */
    long            ses_gap_p1_sum;
    int             ses_gap_samples;
    int             ses_max_gap_p0;
    int             ses_max_gap_p1;
    int             ses_max_temp;            /* peak temperature this session (°C) */

    struct timespec ses_state_enter;         /* timestamp of current state entry */
    int             ses_auto_degraded;       /* 1 = auto has degraded to stable-like mode */

    /* Session intelligence — time-to-first metrics */
    long            ses_time_to_first_sus;    /* seconds from session start to first SUSTAINED */
    long            ses_time_to_first_thermal;/* seconds from session start to first thermal SUSTAINED */
    int             ses_sustained_efficiency; /* 0-100 score: how good was SUSTAINED this session */
    int             ses_recovery_count;       /* thermal collapses requiring recovery this session */
    time_t          ses_start_ts;             /* session start timestamp for time-to-first calcs */

    /* Battery-mode telemetry */
    long            bat_time_deep_idle_sec;   /* total time in DEEP_IDLE in battery mode (s) */
    long            bat_time_light_idle_sec;  /* total time in LIGHT_IDLE in battery mode */
    int             bat_wake_cycles;          /* wake-from-DEEP_IDLE count in battery mode */
    int             bat_gaming_suppressed;    /* times GAMING was suppressed by bat_suppress_gaming */
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

static void fsm_init(asb_fsm_t *fsm, int profile_idx) {
    memset(fsm, 0, sizeof(*fsm));
    fsm->state       = ASB_STATE_LIGHT_IDLE;
    fsm->pending     = ASB_STATE_LIGHT_IDLE;
    fsm->profile_idx = profile_idx;
    fsm->up_window   = 2;
    fsm->down_window = 5;
    clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);
    clock_gettime(CLOCK_MONOTONIC, &fsm->ses_state_enter);
    /* Initial caps */
    fsm_interpolate_caps(&g_profile_bounds[profile_idx],
                         fsm->state, &fsm->current_caps);
}

/* Resets accumulated session telemetry (on reload) */
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
    fsm->ses_auto_degraded      = 0;
    fsm->bat_time_deep_idle_sec  = 0;
    fsm->bat_time_light_idle_sec = 0;
    fsm->bat_wake_cycles         = 0;
    fsm->bat_gaming_suppressed   = 0;
    fsm->ses_time_to_first_sus    = 0;
    fsm->ses_time_to_first_thermal= 0;
    fsm->ses_sustained_efficiency = -1; /* -1 = not yet computed */
    fsm->ses_recovery_count       = 0;
    fsm->ses_start_ts             = time(NULL);
}

/* ─── Transition logic ─────────────────────────────────────── */
/*
 * Determines desired state from current metrics.
 * Ignores hysteresis — only what the metrics want.
 */
static asb_state_t fsm_desired(const asb_metrics_t *m) {
    if (!m->misc.screen_on) return ASB_STATE_DEEP_IDLE;

    int ma_valid = (m->bat.current_ma > 0 && !m->bat.charging);

    /* GAMING: GPU load only, no mA guard.
     * In battery profile GAMING is suppressed — efficiency over peak. */
    if (m->gpu.load_pct >= g_asb_cfg.gaming_gpu_enter) {
        if (g_asb_cfg.bat_suppress_gaming && fsm_profile_is_battery)
            return ASB_STATE_HEAVY; /* battery: GAMING → HEAVY */
        return ASB_STATE_GAMING;
    }

    /* SUSTAINED is not returned directly from fsm_desired.
     * Promotion to SUSTAINED happens in fsm_update only if
     * we are already in HEAVY/GAMING (not from idle).                */

    if (m->gpu.load_pct >= g_asb_cfg.heavy_gpu_enter ||
        m->cpu.load1 >= (fsm_profile_is_battery && g_asb_cfg.bat_heavy_load_enter > 0
                         ? g_asb_cfg.bat_heavy_load_enter
                         : g_asb_cfg.heavy_load_enter)) {
        if (!ma_valid || m->bat.current_ma >= 150)
            return ASB_STATE_HEAVY;
    }

    if (m->cpu.load1 >= 1.5f)
        return ASB_STATE_MODERATE;
    if (ma_valid && m->bat.current_ma >= 120)
        return ASB_STATE_MODERATE;

    return ASB_STATE_LIGHT_IDLE;
}

/*
 * Updates FSM based on current metrics.
 * Returns 1 if caps changed (sysfs write needed).
 */
static int fsm_update(asb_fsm_t *fsm, const asb_metrics_t *m) {
    fsm->state_changed = 0;
    fsm->caps_changed  = 0;
    fsm->prev_state    = fsm->state;  /* save before any transition */

    /* ── Screen OFF: immediate transition, no hysteresis ──── */
    if (!m->misc.screen_on && fsm->state != ASB_STATE_DEEP_IDLE) {
        fsm->state   = ASB_STATE_DEEP_IDLE;
        fsm->pending = ASB_STATE_DEEP_IDLE;
        fsm->pending_ticks = 0;
        fsm->state_changed = 1;
    }
    /* ── Screen ON from DEEP_IDLE: immediate wake ─────────── */
    else if (m->misc.screen_on && fsm->state == ASB_STATE_DEEP_IDLE) {
        fsm->state   = ASB_STATE_LIGHT_IDLE;
        fsm->pending = ASB_STATE_LIGHT_IDLE;
        fsm->pending_ticks = 0;
        fsm->state_changed = 1;
    }
    else {
        asb_state_t desired = fsm_desired(m);

        if (desired != fsm->pending) {
            /* New candidate — reset counter */
            fsm->pending       = desired;
            fsm->pending_ticks = 0;
        } else {
            fsm->pending_ticks++;
        }

        int thermal_to_sustained = 0;
        int gap_to_sustained = 0;

        /* ── Path 1: SUSTAINED via thermal (existing) ─────── */
        int sustained_reentry_blocked = (fsm->sustained_reentry_until > 0 &&
                                         time(NULL) < fsm->sustained_reentry_until);
        if (!sustained_reentry_blocked &&
            m->therm.throttling &&
            fsm->state >= ASB_STATE_HEAVY &&
            desired >= ASB_STATE_HEAVY)
        {
            desired = ASB_STATE_SUSTAINED;
            thermal_to_sustained = 1;
            fsm->sustained_reason = 0;
        }

        /* ── Path 2: SUSTAINED via gap-aware logic ──────────── */
        /* If GAMING caps are physically unreachable for several consecutive ticks,
         * transition to SUSTAINED without waiting for thermal threshold.        */
        if (!thermal_to_sustained && !sustained_reentry_blocked &&
            fsm->state == ASB_STATE_GAMING &&
            g_asb_cfg.gaming_gap_thresh > 0)
        {
            /* Read current real gap for policy0 (primary cluster) */
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
            fsm->gaming_gap_ticks_count = 0; /* reset if we left GAMING */
        }

        /* ── Cooldown: protection against immediate GAMING retry ──── */
        /* After SUSTAINED exit, if cooldown active and desired=GAMING,
         * demote to HEAVY — let system cool/stabilize.  */
        if (!thermal_to_sustained && !gap_to_sustained &&
            desired == ASB_STATE_GAMING)
        {
            time_t now_t = time(NULL);
            int cooldown_active = (fsm->gaming_retry_until > 0 &&
                                   now_t < fsm->gaming_retry_until);
            /* Temperature gate: retry only if chip has cooled.
             * Recovery discipline: after multiple thermal collapses this session,
             * apply a stricter temperature gate (5°C lower than config). */
            int temp_max = g_asb_cfg.gaming_retry_temp_max;
            if (temp_max > 0 && fsm->ses_recovery_count >= 2)
                temp_max -= 5; /* stricter after repeated thermal collapses */
            if (temp_max < 30) temp_max = 30;
            int too_hot = (g_asb_cfg.gaming_retry_temp_max > 0 &&
                           m->therm.cpu_max_c > temp_max &&
                           fsm->gaming_retry_until > 0); /* only after SUSTAINED */
            if (cooldown_active || too_hot) {
                desired = ASB_STATE_HEAVY;
            } else {
                fsm->gaming_retry_until = 0;
            }
        }
        /* Set cooldowns on SUSTAINED exit */
        if (fsm->prev_state == ASB_STATE_SUSTAINED &&
            fsm->state_changed &&
            fsm->state != ASB_STATE_SUSTAINED)
        {
            time_t now_exit = time(NULL);
            if (g_asb_cfg.gaming_retry_cooldown_s > 0)
                fsm->gaming_retry_until = now_exit + g_asb_cfg.gaming_retry_cooldown_s;
            if (g_asb_cfg.sustained_reentry_cooldown_s > 0)
                fsm->sustained_reentry_until = now_exit + g_asb_cfg.sustained_reentry_cooldown_s;
        }

        int window = (desired > fsm->state)
                     ? fsm->up_window
                     : fsm->down_window;
        if (thermal_to_sustained) window = 1;
        /* Battery: faster transition from LIGHT_IDLE to DEEP_IDLE */
        if (fsm_profile_is_battery &&
            g_asb_cfg.bat_fast_idle_s > 0 &&
            fsm->state == ASB_STATE_LIGHT_IDLE &&
            desired == ASB_STATE_DEEP_IDLE) {
            /* bat_fast_idle_s is in seconds; convert to ticks (2s each) */
            int fast_w = g_asb_cfg.bat_fast_idle_s / 2;
            if (fast_w < 1) fast_w = 1;
            if (fast_w < window) window = fast_w;
        }

        if (fsm->pending_ticks >= window && desired != fsm->state) {
            int can_leave = 1;
            /* SUSTAINED temperature hysteresis applies in ALL exit directions.
             * Bug r8: GAMING exit (desired > state) bypassed the check because
             * block was inside 'if (desired < state)'. Now moved outside.   */
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

    /* ── Thermal overlay ─────────────────────────────────────── */
    int new_thermal = m->therm.throttling;
    if (new_thermal != fsm->thermal_cap) {
        fsm->thermal_cap  = new_thermal;
        fsm->caps_changed = 1; /* caps need rewrite with new limits */
    }

    /* ── Recalculate caps ───────────────────────────────────────── */
    asb_profile_caps_t new_caps;
    fsm_interpolate_caps(&g_profile_bounds[fsm->profile_idx],
                         fsm->state, &new_caps);

    /* Thermal overlay: for non-sustained states, slightly reduce targets.
     * For SUSTAINED, no additional cut — this state already is
     * the soft retreat path from the thermal wall. */
    if (fsm->thermal_cap && fsm->state != ASB_STATE_SUSTAINED) {
        float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
        for (int i = 0; i < 3; i++)
            new_caps.cpu_max[i] = (int)(new_caps.cpu_max[i] * keep);
        int gpu_drop = g_asb_cfg.thermal_overlay_pct;
        new_caps.gpu_max_pct = new_caps.gpu_max_pct > gpu_drop
                               ? new_caps.gpu_max_pct - gpu_drop : 0;
    }

    /* Check for change */
    if (fsm->state_changed ||
        memcmp(&new_caps, &fsm->current_caps, sizeof(new_caps)) != 0)
    {
        fsm->current_caps = new_caps;
        fsm->caps_changed = 1;
    }

    /* ── Session telemetry update (V22-r11) ──────────────────── */
    /* 1. Temperature */
    if (m->therm.cpu_max_c > fsm->ses_max_temp)
        fsm->ses_max_temp = m->therm.cpu_max_c;

    /* 2. Gap in GAMING — accumulate each tick */
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

    /* 3. State counters and time — on transition */
    if (fsm->state_changed) {
        /* Accumulate time in previous state */
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
            default: break;
        }
        /* Battery wake cycle counter */
        if (fsm_profile_is_battery &&
            fsm->prev_state == ASB_STATE_DEEP_IDLE &&
            fsm->state != ASB_STATE_DEEP_IDLE)
            fsm->bat_wake_cycles++;
        fsm->ses_state_enter = now_ts;

        /* Count state entries */
        if (fsm->state == ASB_STATE_GAMING)
            fsm->ses_gaming_entries++;
        if (fsm->state == ASB_STATE_SUSTAINED) {
            fsm->ses_sustained_entries++;
            /* Record time-to-first-SUSTAINED */
            if (fsm->ses_time_to_first_sus == 0 && fsm->ses_start_ts > 0)
                fsm->ses_time_to_first_sus = time(NULL) - fsm->ses_start_ts;
        }
        /* Battery: count suppressed GAMING entries */
        if (fsm_profile_is_battery &&
            g_asb_cfg.bat_suppress_gaming &&
            fsm->state == ASB_STATE_HEAVY &&
            fsm->prev_state != ASB_STATE_GAMING) /* new entry only, not reassert */
        {
            /* gpu >= gaming_gpu_enter → would be GAMING but suppressed */
        }
    }

    return fsm->caps_changed;
}
    else if (!strcmp(k, "gaming_gpu_enter")) c->gaming_gpu_enter = atoi(v);
    else if (!strcmp(k, "sustained_gpu_min")) c->sustained_gpu_min = atoi(v);
    else if (!strcmp(k, "sustained_load_min")) c->sustained_load_min = (float)atof(v);
    else if (!strcmp(k, "sustained_temp_enter")) c->sustained_temp_enter = atoi(v);
    else if (!strcmp(k, "sustained_temp_exit"))  c->sustained_temp_exit  = atoi(v);
    else if (!strcmp(k, "heavy_gpu_exit")) c->heavy_gpu_exit = atoi(v);
    else if (!strcmp(k, "gaming_gpu_exit")) c->gaming_gpu_exit = atoi(v);
    else if (!strcmp(k, "sustained_gpu_exit")) c->sustained_gpu_exit = atoi(v);
    else if (!strcmp(k, "heavy_min_dwell_s")) c->heavy_min_dwell_s = atoi(v);
    else if (!strcmp(k, "sustained_min_dwell_s")) c->sustained_min_dwell_s = atoi(v);
    else if (!strcmp(k, "gaming_min_dwell_s")) c->gaming_min_dwell_s = atoi(v);
    else if (!strcmp(k, "reassert_heavy_s")) c->reassert_heavy_s = atoi(v);
    else if (!strcmp(k, "reassert_gaming_s")) c->reassert_gaming_s = atoi(v);
    else if (!strcmp(k, "msm_perf_boost_only")) c->msm_perf_boost_only = atoi(v);
    else if (!strcmp(k, "thermal_overlay_pct")) c->thermal_overlay_pct = atoi(v);
    else if (!strcmp(k, "thermal_throttle_temp")) c->thermal_throttle_temp = atoi(v);
    else if (!strcmp(k, "gaming_gap_thresh"))    c->gaming_gap_thresh = atoi(v);
    else if (!strcmp(k, "gaming_gap_ticks"))     c->gaming_gap_ticks  = atoi(v);
    else if (!strcmp(k, "gaming_retry_cooldown_s")) c->gaming_retry_cooldown_s = atoi(v);
    else if (!strcmp(k, "gaming_retry_temp_max"))   c->gaming_retry_temp_max   = atoi(v);
    else if (!strcmp(k, "auto_degrade_gap_thresh")) c->auto_degrade_gap_thresh = atoi(v);
    else if (!strcmp(k, "auto_degrade_sus_ratio"))  c->auto_degrade_sus_ratio  = atoi(v);
    else if (!strcmp(k, "auto_degrade_thermal_pct")) c->auto_degrade_thermal_pct = atoi(v);
    else if (!strcmp(k, "bat_fast_idle_s"))     c->bat_fast_idle_s     = atoi(v);
    else if (!strcmp(k, "bat_light_idle_gpu"))  c->bat_light_idle_gpu  = atoi(v);
    else if (!strcmp(k, "bat_suppress_gaming")) c->bat_suppress_gaming = atoi(v);
    else if (!strcmp(k, "bat_heavy_load_enter")) c->bat_heavy_load_enter = (float)atof(v);
    else if (!strcmp(k, "sustained_reentry_cooldown_s")) c->sustained_reentry_cooldown_s = atoi(v);
    else if (!strcmp(k, "highload_mode")) {
        if (!strcmp(v, "burst"))   c->highload_mode = 1;
        else if (!strcmp(v, "stable")) c->highload_mode = 2;
        else if (!strcmp(v, "auto"))   c->highload_mode = 3;
        else c->highload_mode = 0;
    }
    else if (!strcmp(k, "sustained_level")) {
        float v_f = (float)atof(v);
        /* clamp: guard against typos like 1.8 or 0.05 */
        if (v_f < 0.50f) v_f = 0.50f;
        if (v_f > 0.95f) v_f = 0.95f;
        c->sustained_level = v_f;
    }
}

static inline int asb_config_load_file(const char *path, asb_runtime_config_t *c) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *s = asb_cfg_trim(line);
        if (!*s || *s == '#') continue;
        char *eq = strchr(s, '=');
        if (!eq) continue;
        *eq = '\0';
        char *k = asb_cfg_trim(s);
        char *v = asb_cfg_trim(eq + 1);
        char *hash = strchr(v, '#');
        if (hash) *hash = '\0';
        v = asb_cfg_trim(v);
        asb_cfg_apply_kv(c, k, v);
    }
    fclose(f);
    return 0;
}

/* Applies highload_mode over config.
 * Call after asb_config_parse() — overrides only high-load parameters.
 * Explicitly set parameters in governor.conf will be overridden by the mode —
 * this is intentional: mode sets the behavioral character entirely. */
/* Applies base mode parameters on start/reload.
 * auto=3 starts as burst; degrades at runtime. */
static inline void asb_config_apply_highload_mode(asb_runtime_config_t *c) {
    if (c->highload_mode == 1 || c->highload_mode == 3) {
        c->gaming_gap_ticks             = 3;
        c->gaming_retry_cooldown_s      = 20;
        c->gaming_retry_temp_max        = 50;
        c->sustained_level              = 0.85f;
        c->sustained_reentry_cooldown_s = 10;
    } else if (c->highload_mode == 2) {
        c->gaming_gap_ticks             = 4;
        c->gaming_retry_cooldown_s      = 35;
        c->gaming_retry_temp_max        = 45;
        c->sustained_level              = 0.78f;
        c->sustained_reentry_cooldown_s = 25;
    }
    /* mode=0 (default): config parameters are not changed */
}

/* Applies stable parameters over current config (auto degrade).
 * Called once per session when governor decides burst is futile. */
/* Reset highload burst override back to config defaults */
static inline void asb_config_defaults_highload(asb_runtime_config_t *c) {
    /* Reload from defaults — burst was applied by profile:performance */
    c->highload_mode = 0; /* back to default */
    /* Reset to config file values (caller should reload if needed) */
}

/* Apply burst parameters for performance profile */
static inline void asb_config_apply_burst_override(asb_runtime_config_t *c) {
    c->highload_mode             = 1; /* burst */
    c->gaming_gap_ticks          = 3;
    c->gaming_retry_cooldown_s   = 20;
    c->gaming_retry_temp_max     = 50;
    c->sustained_level           = 0.85f;
    c->sustained_reentry_cooldown_s = 10;
}

static inline void asb_config_apply_stable_override(asb_runtime_config_t *c) {
    c->gaming_gap_ticks             = 4;
    c->gaming_retry_cooldown_s      = 35;
    c->gaming_retry_temp_max        = 45;
    c->sustained_level              = 0.78f;
    c->sustained_reentry_cooldown_s = 25;
}

/* AUTO degrade: burst→stable on poor gaming viability.
 * Both conditions must be met:
 *  1. avg_gap_p0 > auto_degrade_gap_thresh  (caps persistently unreachable)
 *  2. sus_entries >= gaming_entries * ratio  (GAMING rare, SUSTAINED dominant)
 * Minimum 2 gaming_entries required for statistics. */
static inline int asb_config_auto_should_degrade(
        const asb_runtime_config_t *c,
        int avg_gap_p0, int gaming_entries, int sustained_entries,
        long time_heavy, long time_gaming, long time_sustained,
        int already_degraded)
{
    if (c->highload_mode != 3 || already_degraded) return 0;
    if (gaming_entries < 2) return 0;
    /* Path 1: gaming entries exist, caps unreachable */
    int gap_bad   = (c->auto_degrade_gap_thresh > 0 &&
                     avg_gap_p0 > c->auto_degrade_gap_thresh);
    int ratio_bad = (c->auto_degrade_sus_ratio  > 0 &&
                     sustained_entries >= gaming_entries * c->auto_degrade_sus_ratio);
    if (gaming_entries >= 2 && gap_bad && ratio_bad) return 1;

    /* Path 2: thermal pressure — even without gaming entries.
     * If > auto_degrade_thermal_pct% of heavy time was in SUSTAINED
     * and enough data accumulated (>120s) — burst is futile.         */
    if (c->auto_degrade_thermal_pct > 0) {
        long total = time_heavy + time_gaming + time_sustained;
        if (total >= 120 && time_sustained > 0) {
            int sus_pct = (int)(time_sustained * 100 / total);
            if (sus_pct >= c->auto_degrade_thermal_pct) return 1;
        }
    }
    return 0;
}
    else if (!strcmp(k, "sustained_load_min")) c->sustained_load_min = (float)atof(v);
    else if (!strcmp(k, "sustained_temp_enter")) c->sustained_temp_enter = atoi(v);
    else if (!strcmp(k, "sustained_temp_exit"))  c->sustained_temp_exit  = atoi(v);
    else if (!strcmp(k, "heavy_gpu_exit")) c->heavy_gpu_exit = atoi(v);
    else if (!strcmp(k, "gaming_gpu_exit")) c->gaming_gpu_exit = atoi(v);
    else if (!strcmp(k, "sustained_gpu_exit")) c->sustained_gpu_exit = atoi(v);
    else if (!strcmp(k, "heavy_min_dwell_s")) c->heavy_min_dwell_s = atoi(v);
    else if (!strcmp(k, "sustained_min_dwell_s")) c->sustained_min_dwell_s = atoi(v);
    else if (!strcmp(k, "gaming_min_dwell_s")) c->gaming_min_dwell_s = atoi(v);
    else if (!strcmp(k, "reassert_heavy_s")) c->reassert_heavy_s = atoi(v);
    else if (!strcmp(k, "reassert_gaming_s")) c->reassert_gaming_s = atoi(v);
    else if (!strcmp(k, "msm_perf_boost_only")) c->msm_perf_boost_only = atoi(v);
    else if (!strcmp(k, "thermal_overlay_pct")) c->thermal_overlay_pct = atoi(v);
    else if (!strcmp(k, "thermal_throttle_temp")) c->thermal_throttle_temp = atoi(v);
    else if (!strcmp(k, "gaming_gap_thresh"))    c->gaming_gap_thresh = atoi(v);
    else if (!strcmp(k, "gaming_gap_ticks"))     c->gaming_gap_ticks  = atoi(v);
    else if (!strcmp(k, "gaming_retry_cooldown_s")) c->gaming_retry_cooldown_s = atoi(v);
    else if (!strcmp(k, "gaming_retry_temp_max"))   c->gaming_retry_temp_max   = atoi(v);
    else if (!strcmp(k, "auto_degrade_gap_thresh")) c->auto_degrade_gap_thresh = atoi(v);
    else if (!strcmp(k, "auto_degrade_sus_ratio"))  c->auto_degrade_sus_ratio  = atoi(v);
    else if (!strcmp(k, "auto_degrade_thermal_pct")) c->auto_degrade_thermal_pct = atoi(v);
    else if (!strcmp(k, "bat_fast_idle_s"))     c->bat_fast_idle_s     = atoi(v);
    else if (!strcmp(k, "bat_light_idle_gpu"))  c->bat_light_idle_gpu  = atoi(v);
    else if (!strcmp(k, "bat_suppress_gaming")) c->bat_suppress_gaming = atoi(v);
    else if (!strcmp(k, "sustained_reentry_cooldown_s")) c->sustained_reentry_cooldown_s = atoi(v);
    else if (!strcmp(k, "highload_mode")) {
        if (!strcmp(v, "burst"))   c->highload_mode = 1;
        else if (!strcmp(v, "stable")) c->highload_mode = 2;
        else if (!strcmp(v, "auto"))   c->highload_mode = 3;
        else c->highload_mode = 0;
    }
    else if (!strcmp(k, "sustained_level")) {
        float v_f = (float)atof(v);
        /* clamp: guard against typos like 1.8 or 0.05 */
        if (v_f < 0.50f) v_f = 0.50f;
        if (v_f > 0.95f) v_f = 0.95f;
        c->sustained_level = v_f;
    }
}

static inline int asb_config_load_file(const char *path, asb_runtime_config_t *c) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *s = asb_cfg_trim(line);
        if (!*s || *s == '#') continue;
        char *eq = strchr(s, '=');
        if (!eq) continue;
        *eq = '\0';
        char *k = asb_cfg_trim(s);
        char *v = asb_cfg_trim(eq + 1);
        char *hash = strchr(v, '#');
        if (hash) *hash = '\0';
        v = asb_cfg_trim(v);
        asb_cfg_apply_kv(c, k, v);
    }
    fclose(f);
    return 0;
}

/* Applies highload_mode over config.
 * Call after asb_config_parse() — overrides only high-load parameters.
 * Explicitly set parameters in governor.conf will be overridden by the mode —
 * this is intentional: mode sets the behavioral character entirely. */
/* Applies base mode parameters on start/reload.
 * auto=3 starts as burst; degrades at runtime. */
static inline void asb_config_apply_highload_mode(asb_runtime_config_t *c) {
    if (c->highload_mode == 1 || c->highload_mode == 3) {
        c->gaming_gap_ticks             = 3;
        c->gaming_retry_cooldown_s      = 20;
        c->gaming_retry_temp_max        = 50;
        c->sustained_level              = 0.85f;
        c->sustained_reentry_cooldown_s = 10;
    } else if (c->highload_mode == 2) {
        c->gaming_gap_ticks             = 4;
        c->gaming_retry_cooldown_s      = 35;
        c->gaming_retry_temp_max        = 45;
        c->sustained_level              = 0.78f;
        c->sustained_reentry_cooldown_s = 25;
    }
    /* mode=0 (default): config parameters are not changed */
}

/* Applies stable parameters over current config (auto degrade).
 * Called once per session when governor decides burst is futile. */
static inline void asb_config_apply_stable_override(asb_runtime_config_t *c) {
    c->gaming_gap_ticks             = 4;
    c->gaming_retry_cooldown_s      = 35;
    c->gaming_retry_temp_max        = 45;
    c->sustained_level              = 0.78f;
    c->sustained_reentry_cooldown_s = 25;
}

/* AUTO degrade: burst→stable on poor gaming viability.
 * Both conditions must be met:
 *  1. avg_gap_p0 > auto_degrade_gap_thresh  (caps persistently unreachable)
 *  2. sus_entries >= gaming_entries * ratio  (GAMING rare, SUSTAINED dominant)
 * Minimum 2 gaming_entries required for statistics. */
static inline int asb_config_auto_should_degrade(
        const asb_runtime_config_t *c,
        int avg_gap_p0, int gaming_entries, int sustained_entries,
        long time_heavy, long time_gaming, long time_sustained,
        int already_degraded)
{
    if (c->highload_mode != 3 || already_degraded) return 0;
    if (gaming_entries < 2) return 0;
    /* Path 1: gaming entries exist, caps unreachable */
    int gap_bad   = (c->auto_degrade_gap_thresh > 0 &&
                     avg_gap_p0 > c->auto_degrade_gap_thresh);
    int ratio_bad = (c->auto_degrade_sus_ratio  > 0 &&
                     sustained_entries >= gaming_entries * c->auto_degrade_sus_ratio);
    if (gaming_entries >= 2 && gap_bad && ratio_bad) return 1;

    /* Path 2: thermal pressure — even without gaming entries.
     * If > auto_degrade_thermal_pct% of heavy time was in SUSTAINED
     * and enough data accumulated (>120s) — burst is futile.         */
    if (c->auto_degrade_thermal_pct > 0) {
        long total = time_heavy + time_gaming + time_sustained;
        if (total >= 120 && time_sustained > 0) {
            int sus_pct = (int)(time_sustained * 100 / total);
            if (sus_pct >= c->auto_degrade_thermal_pct) return 1;
        }
    }
    return 0;
}
