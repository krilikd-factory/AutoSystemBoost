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

/*
 * Was `const`: now a mutable copy initialised from the compile-time values below.
 * If the override file is absent, malformed, or the flag is off, these values stand unchanged
 * — i.e.
 */
static asb_profile_bounds_t g_profile_bounds[3] = {
    /*
     * ALL THREE profile bounds realigned with their .sh scripts.
     */

    /*
     * PROFILE_BATTERY: Caps tuned for Snapdragon 8 Elite Gen 5 (4.6GHz P-cluster, 1200MHz
     * GPU).
     */
    {
        .floor = {
            .cpu_max    = { ASB_BATTERY_FLOOR_CPU_MAX_LITTLE, ASB_BATTERY_FLOOR_CPU_MAX_BIG, 0 },
            .cpu_min    = { ASB_BATTERY_FLOOR_CPU_MIN_LITTLE, ASB_BATTERY_FLOOR_CPU_MIN_BIG, 0 },
            /*
             * GPU floor raised to 45%: SM8850 vendor PowerHAL clamps GPU max_pwrlevel to 17
             * (160 MHz) when it sees low FSM cpu_max + LIGHT_IDLE.
             * Raising GPU max floor to 45% (540 MHz target) breaks that heuristic and stops
             * stutter during shelf/menu scrolling.
             */
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

    /*
     * PROFILE_PERFORMANCE — sustained-optimized for COD Mobile and similar.
     */
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
/*
 * V50: smart profile spends most of a night exactly like battery, but the idle telemetry below
 * only accumulated under PROFILE_BATTERY.
 * With all counters stuck at zero, idle_quality read 0, classify_environment() reported
 * hostile for flawless nights, clean-night reward was unreachable and the next session was
 * primed IDLE_NOISY.
 */
static int fsm_profile_is_smart = 0;
static int fsm_profile_is_performance = 0;
#define fsm_profile_tracks_idle (fsm_profile_is_battery || fsm_profile_is_smart)
static int fsm_profile_is_balanced = 0;
#define PROFILE_BALANCED    1
#define PROFILE_PERFORMANCE 2
#define PROFILE_SMART       3
#define ASB_PROFILE_COUNT   4

/*
 * --------------------------------------------------------------------------- Per-device
 * bounds override (Phase 2 of device-adaptive tuning).
 */
#define ASB_DEVICE_BOUNDS_FILE "/data/adb/asb/device_bounds.env"

/* Apply one KEY=val pair to g_profile_bounds if KEY is in the allow-list and
 * val passes range validation. Returns 1 if applied, 0 otherwise. */
static int asb_device_bounds_apply_kv(const char *key, long val) {
    /*
     * Range guard: CPU freqs are in kHz.
     */
    if (val <= 0 || val > 6000000) return 0;

    struct { const char *name; int prof; int is_ceil; int field; int slot; } map[] = {
        /*
         * field: 0=cpu_max, 1=cpu_min ; slot: 0=little, 1=big/mid, 2=prime.
         * On a 3/4-cluster SoC (OP12) it emits *_MID -> slot 1 (the strongest middle, which
         * the writer also mirrors onto the other middles) and *_PRIME -> slot 2 (the
         * last/prime cluster, which is otherwise left at the compiled 0 = unmanaged).
         */
        { "BATTERY_CPU_MAX_LITTLE",     PROFILE_BATTERY,     1, 0, 0 },
        { "BATTERY_CPU_MAX_BIG",        PROFILE_BATTERY,     1, 0, 1 },
        { "BATTERY_CPU_MAX_MID",        PROFILE_BATTERY,     1, 0, 1 },
        { "BATTERY_CPU_MAX_PRIME",      PROFILE_BATTERY,     1, 0, 2 },
        { "BATTERY_CPU_CAP_LITTLE",     PROFILE_BATTERY,     0, 0, 0 },
        { "BATTERY_CPU_CAP_BIG",        PROFILE_BATTERY,     0, 0, 1 },
        { "BALANCED_CPU_MAX_LITTLE",    PROFILE_BALANCED,    1, 0, 0 },
        { "BALANCED_CPU_MAX_BIG",       PROFILE_BALANCED,    1, 0, 1 },
        { "BALANCED_CPU_MAX_MID",       PROFILE_BALANCED,    1, 0, 1 },
        /*
         * BALANCED_CPU_MAX_PRIME and PERFORMANCE_CPU_MAX_PRIME are deliberately absent.
         * Filtering here rather than only in the synthesiser matters: device_bounds.env lives
         * in /data/adb/asb and outlives module updates, and the synthesiser itself is not
         * shipped in release builds - so a file written once by a debug build would otherwise
         * keep capping the prime forever, with nothing able to rewrite it.
         */
        { "BALANCED_CPU_CAP_LITTLE",    PROFILE_BALANCED,    0, 0, 0 },
        { "BALANCED_CPU_CAP_BIG",       PROFILE_BALANCED,    0, 0, 1 },
        { "PERFORMANCE_CPU_MAX_LITTLE", PROFILE_PERFORMANCE, 1, 0, 0 },
        { "PERFORMANCE_CPU_MAX_BIG",    PROFILE_PERFORMANCE, 1, 0, 1 },
        { "PERFORMANCE_CPU_MAX_MID",    PROFILE_PERFORMANCE, 1, 0, 1 },
    };
    for (unsigned i = 0; i < sizeof(map)/sizeof(map[0]); i++) {
        if (strcmp(key, map[i].name) != 0) continue;
        asb_profile_bounds_t *b = &g_profile_bounds[map[i].prof];
        asb_profile_caps_t *cs = map[i].is_ceil ? &b->ceil : &b->floor;
        if (map[i].field == 0) cs->cpu_max[map[i].slot] = (int)val;
        else                   cs->cpu_min[map[i].slot] = (int)val;
        return 1;
    }
    return 0;
}

/*
 * Load + apply the override file.
 */
static int asb_load_device_bounds_override(int enabled,
                                           const asb_profile_bounds_t *defaults) {
    if (!enabled) return 0;
    FILE *f = fopen(ASB_DEVICE_BOUNDS_FILE, "r");
    if (!f) return 0;
    int applied = 0;
    char line[160];
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        char *key = line;
        char *valstr = eq + 1;
        /* trim trailing whitespace/newline on key */
        char *ke = key + strlen(key);
        while (ke > key && (ke[-1] == ' ' || ke[-1] == '\t')) *--ke = '\0';
        long val = atol(valstr);
        applied += asb_device_bounds_apply_kv(key, val);
    }
    fclose(f);
    /*
     * Post-validate the invariant floor.cpu_max <= ceil.cpu_max for every slot.
     * In that case we clamp the floor DOWN to the new ceiling rather than discarding the
     * override — the override is the intent, the floor is just the DEEP_IDLE start and must
     * not exceed it.
     */
    for (int p = 0; p < 3; p++) {
        int corrupt = 0;
        for (int s = 0; s < 3; s++) {
            int ce = g_profile_bounds[p].ceil.cpu_max[s];
            int fl = g_profile_bounds[p].floor.cpu_max[s];
            if (ce < 0) { corrupt = 1; break; }
            if (ce > 0 && fl > ce) g_profile_bounds[p].floor.cpu_max[s] = ce;  /* clamp floor down */
        }
        if (corrupt) g_profile_bounds[p] = defaults[p];
    }
    return applied;
}


/*
 * Smart Mode runtime bounds (mutable, written by smart blend math).
 */
static asb_profile_bounds_t g_smart_bounds;
static int g_smart_bounds_initialized = 0;

/*
 * Dispatch profile_idx to its bounds source.
 */
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

/* Minimum 1-minute load average before high GPU counts as gaming.
 *
 * 2.0 on an 8-core phone is roughly a quarter of the cores busy - well below what any
 * real game produces, and well above a feed scrolling with hardware-decoded video, which
 * typically sits under 1.0 because the decode never touches the CPU.
 *
 * Chosen to reject the reported false positive with room to spare rather than to sit
 * tightly between the two: a game misclassified as HEAVY loses a little headroom, while a
 * feed misclassified as GAMING runs the phone flat out for as long as the user scrolls.
 * The costs are not symmetric, so the threshold does not sit in the middle.
 */
#define ASB_GAMING_MIN_LOAD1 2.0f

/* Minimum load1 before a busy GPU alone may escalate to HEAVY.
 *
 * Lower than the gaming gate because HEAVY is a much smaller commitment than GAMING - it
 * is the difference between "give this some headroom" and "hold nothing back". 1.2 on an
 * eight-core phone is roughly one core saturated: enough to say the CPU is participating,
 * low enough that anything genuinely interactive passes.
 */
#define ASB_HEAVY_GPU_MIN_LOAD1 1.2f

/* Minimum load1 before battery current may corroborate an escalation.
 *
 * Low on purpose - 0.5 is a fraction of one core. This is not asking the CPU to be busy,
 * only to be doing something, so that "current is high because the screen is on" no longer
 * counts as a reason to raise clocks. Anything a person is actively interacting with
 * clears it easily; a paused screen showing static content does not.
 */
#define ASB_CURRENT_MIN_LOAD1 0.5f

/* How long after the screen lights up the battery profile skips LIGHT_IDLE.
 * Covers the vendor GPU clamp that makes the first scroll stutter, without keeping the
 * phone out of idle for the whole time the screen is on. */
#define ASB_BAT_SCREENON_GRACE_S 4

/* When the screen last came on. File-scope like g_gaming_confirm_streak, because the
 * state classifier is a pure function of the metrics and does not receive the fsm. */
static time_t g_screen_on_since = 0;

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
        /* Scale the ceiling in proportion to how much performance the state is asking
         * for, not by the same factor everywhere.
         *
         * asb_bounds_scale exists so a faster chip may peak higher, which is right at the
         * top of the ladder. Applied flat it also raises the IDLE ceiling: on an OP15 the
         * LIGHT_IDLE cap of 1190400 became 2122505, so a phone doing nothing was permitted
         * twice the clock it needed. That is heat and drain during ordinary use - the part
         * users describe as "no improvement during the day", separate from the floor bug
         * that dominated the night.
         *
         * t is already the state's position on the ladder: 0 at deep idle, 1 at gaming.
         * Weighting the scale by t means idle keeps the reference numbers, peaks get the
         * full hardware benefit, and everything between moves smoothly.
         */
        {
            int _raw = lerp_int(f->cpu_max[i], c->cpu_max[i], t);
            int _scaled = asb_bounds_scale(i, _raw);
            /* Weight by the ladder position, except in SUSTAINED.
             *
             * SUSTAINED is the cooling state - it is entered because the phone is too hot.
             * Its level sits at 0.62 (0.84 in the compiled table), above MODERATE's 0.45,
             * because the ladder measures how much work is being asked of the phone rather
             * than how much it should be allowed. That ordering is deliberate for the
             * interpolation itself, but it must not also buy extra hardware scaling: a
             * device that has thermally escalated would be handed a HIGHER ceiling than the
             * same device running normally, which is the opposite of what the state exists
             * to do.
             *
             * Capped at MODERATE's weight there: the scaling follows the reference numbers
             * while the interpolation keeps its own shape.
             */
            float _w = t;
            if (state == ASB_STATE_SUSTAINED && _w > 0.45f) _w = 0.45f;
            out->cpu_max[i] = _raw + (int)((_scaled - _raw) * _w);
        }
        /* Floors are NOT scaled by the cluster ceiling.
         *
         * asb_bounds_scale multiplies a reference value by hw_max/ref, which is right for
         * a ceiling: a chip that peaks higher should be allowed to peak higher. It is
         * wrong for a floor, because idle frequency does not rise with peak frequency -
         * SM8650's lowest step is ~300 MHz and SM8850's is ~364 MHz, near-identical, while
         * their ceilings differ by 1.78x.
         *
         * So the scaling turned a 787200 floor into 1549800 on an OP15: six cores forbidden
         * from ever dropping below 1.55 GHz, including with the screen off. Field logs from
         * two different devices show it - min=1555200 on one, min=1747200 on another, both
         * far above anything the profiles ask for. This is the single largest idle drain
         * the module was causing, and it looked like a vendor override in every capture.
         *
         * The floor is clamped to the cluster's real minimum instead, so a device whose
         * lowest step happens to be higher than the reference still gets a legal value.
         */
        out->cpu_min[i] = asb_bounds_clamp_floor(i, lerp_int(f->cpu_min[i], c->cpu_min[i], t));
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
    /*
     * V56: peak memory-pressure (PSI some avg10, x100) seen during the session, and count of
     * ticks under meaningful pressure.
     */
    int             mem_psi_peak_x100;
    int             mem_pressure_ticks;
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
    /* Consecutive ticks at or above OUR sustained_temp_enter while under real load.
     * Separate from throttle_cap_ticks, which counts the vendor's signal - the two answer
     * different questions and sharing a counter would let one reset the other. */
    int             own_temp_ticks;
    int             gpu_video_ticks;        /* consecutive ticks of sustained-high GPU at low CPU load = likely video; gates GPU-ceiling trim */
    time_t          recovery_cautious_until; /* after clamp lift, stay cautious */
    int             perf_hot_guard_ticks;
    int             perf_hot_guard_active;
    /*
     * multi-sensor advisory (skin/surface/board contribute to soft hot-guard, NOT hard panic).
     */
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

    /*
     * low-battery auto-switch state.
     */
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
                } else if (_act == 1) {
                    /* Active, but the target did not survive. Recover it by name from
                     * auto_battery_origin rather than starting with -1 and letting the
                     * restore path fall back to BALANCED - which is how a Smart user came
                     * back from a charge cycle on the wrong profile. */
                    fsm->auto_battery_active = 1;
                    FILE *_orf = fopen("/data/adb/asb/auto_battery_origin", "r");
                    if (_orf) {
                        char _on[24] = {0};
                        if (fgets(_on, sizeof(_on), _orf)) {
                            size_t _ol = strlen(_on);
                            while (_ol > 0 && (_on[_ol-1] == '\n' || _on[_ol-1] == '\r' ||
                                               _on[_ol-1] == ' ')) _on[--_ol] = '\0';
                            if      (!strcmp(_on, "balanced"))    fsm->auto_battery_restore_idx = PROFILE_BALANCED;
                            else if (!strcmp(_on, "performance")) fsm->auto_battery_restore_idx = PROFILE_PERFORMANCE;
                            else if (!strcmp(_on, "smart"))       fsm->auto_battery_restore_idx = PROFILE_SMART;
                        }
                        fclose(_orf);
                    }
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
    fsm->mem_psi_peak_x100       = 0;
    fsm->mem_pressure_ticks      = 0;
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

static asb_state_t fsm_desired_base(const asb_metrics_t *m) {
    if (!m->misc.screen_on) { g_screen_on_since = 0; return ASB_STATE_DEEP_IDLE; }
    if (g_screen_on_since == 0) g_screen_on_since = time(NULL);

    int ma_valid = (m->bat.current_ma > 0 && !m->bat.charging);

    if (m->gpu.load_pct >= g_asb_cfg.gaming_gpu_enter) {
        if (g_gaming_confirm_streak < 10000) g_gaming_confirm_streak++;
    } else if (m->gpu.load_pct < g_asb_cfg.gaming_gpu_exit) {
        g_gaming_confirm_streak = 0;
    }

    if (m->gpu.load_pct >= g_asb_cfg.gaming_gpu_enter) {
        if (g_asb_cfg.bat_suppress_gaming && fsm_profile_is_battery)
            return ASB_STATE_HEAVY;
        /* GPU load alone does not mean a game.
         *
         * Reported: FSM stuck in GAMING while scrolling Instagram, Facebook and Threads.
         * Autoplaying video in a feed drives the GPU past this threshold easily -
         * compositing plus scroll animation plus decode output - and the state that was
         * meant for games unlocked full clocks for a social feed. That is heat and drain
         * paid for nothing, and it fires on the most common thing anyone does with a phone.
         *
         * What separates them is the CPU. A game runs its own simulation, physics and draw
         * calls on the CPU every frame; feed video is decoded by dedicated silicon and
         * leaves the CPU nearly idle. So require both to be busy, not just the GPU.
         *
         * The threshold is deliberately low - this rejects "GPU busy, CPU idle", it does not
         * try to grade how hard the game works. Anything genuinely interactive clears it.
         */
        int cpu_busy_enough = (m->cpu.load1 >= ASB_GAMING_MIN_LOAD1);
        if (g_gaming_confirm_streak >= g_asb_cfg.gaming_confirm_ticks && cpu_busy_enough)
            return ASB_STATE_GAMING;
        /* Above the gaming GPU threshold but the CPU is not participating: this fell
         * through to HEAVY, which is the same mistake one step down. A feed of autoplaying
         * video reaches 60% GPU with the CPU under 1.0, and HEAVY's clocks do nothing for
         * it - the decode is already in hardware. Graded by what the CPU is doing, like
         * every other branch here. */
        if (m->cpu.load1 >= ASB_HEAVY_GPU_MIN_LOAD1)
            return ASB_STATE_HEAVY;
        return ASB_STATE_MODERATE;
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

    /* HEAVY needs more than a busy GPU - same reasoning as the gaming gate above.
     *
     * heavy_gpu_enter is 35%, which video playback clears without effort: the decoder is
     * dedicated silicon and what shows up here is only the compositing of its output. So
     * watching a clip, or scrolling a feed that autoplays them, was landing in HEAVY and
     * being handed HEAVY's clocks - for work the CPU was not doing.
     *
     * MODERATE already carries enough GPU allowance for smooth video and scrolling. What
     * HEAVY adds is CPU headroom, so it should be reached when the CPU is actually the
     * thing under pressure.
     *
     * A busy CPU on its own still qualifies: compiling, unpacking or a heavy web page have
     * no GPU signature at all, and refusing them HEAVY would be the mirror of this bug.
     */
    int gpu_says_heavy = (m->gpu.load_pct >= g_asb_cfg.heavy_gpu_enter);
    int cpu_says_heavy = (m->cpu.load1 >= heavy_thr);
    if (cpu_says_heavy ||
        (gpu_says_heavy && m->cpu.load1 >= ASB_HEAVY_GPU_MIN_LOAD1)) {
        if (!ma_valid || m->bat.current_ma >= 150)
            return ASB_STATE_HEAVY;
    }
    /* GPU busy but CPU quiet: video, or an animation. MODERATE, not HEAVY. */
    if (gpu_says_heavy)
        return ASB_STATE_MODERATE;

    if (m->cpu.load1 >= mod_thr)
        return ASB_STATE_MODERATE;
    /* Battery current is not a CPU-demand signal.
     *
     * The display dominates it: a screen at minimum brightness already draws 250-400 mA,
     * against a 120 mA threshold. So this line read "screen is on" and answered "give the
     * CPU more headroom", which are unrelated statements. Music with the screen on showed
     * 19.9%/h at 63 C with the GPU at 7% - the phone held MODERATE clocks for an hour
     * while the actual work was being done by the audio offload path.
     *
     * Current still tells us something real, just not on its own: high current WITH some
     * CPU activity is a genuinely busy phone, while high current with an idle CPU is a lit
     * screen. Keep it as corroboration, drop it as a trigger.
     */
    if (ma_valid && m->bat.current_ma >= 120 &&
        m->cpu.load1 >= ASB_CURRENT_MIN_LOAD1)
        return ASB_STATE_MODERATE;
    /*
     * UI-burst escalation: GPU > 12% with screen on = active UI work (scrolling shelf, app
     * menu, transitions).
     */
    if (m->misc.screen_on && m->gpu.load_pct >= 12)
        return ASB_STATE_MODERATE;

    /*
     * Battery profile + screen on: skip LIGHT_IDLE entirely.
     * Deploy logs showed vendor PowerHAL clamps GPU max_pwrlevel to 17 (160MHz) ONLY when
     * state=LIGHT_IDLE on battery — this caused unlock→shelf scroll stutter for the 1-2
     * seconds before UI-burst escalation kicked in.
     */
    /* Time-bounded, not permanent.
     *
     * The stutter this fixes is real - the vendor PowerHAL drops GPU max_pwrlevel to
     * 160 MHz in LIGHT_IDLE on battery, so the first scroll after unlock jerks. But the
     * cure was "battery profile never idles while the screen is on", which means reading a
     * static page, or a paused video, or a form you are thinking about, all sat at
     * MODERATE for as long as the screen stayed lit. On the profile whose entire purpose
     * is spending less.
     *
     * The problem lasts a second or two after the screen comes on; the fix now lasts the
     * same. After that, a genuinely idle screen is allowed to be idle, and UI-burst above
     * still catches any real scrolling within one tick.
     */
    if (fsm_profile_is_battery && m->misc.screen_on) {
        if (g_screen_on_since > 0 &&
            (time(NULL) - g_screen_on_since) <= ASB_BAT_SCREENON_GRACE_S)
            return ASB_STATE_MODERATE;
    }

    return ASB_STATE_LIGHT_IDLE;
}

/*
 * Camera floor.
 * Holding at HEAVY for as long as the pipeline streams is the difference between a smooth 4K60
 * capture and a dropped-frame one; it never lowers a state, so GAMING and SUSTAINED are
 * untouched, and the thermal guards downstream still apply normally.
 */
/*
 * Camera hold is BOUNDED - by time and by temperature.
 *
 * Forcing HEAVY while the camera streams stops a dropped frame in a burst or in 4K60
 * recording. Those last seconds to a few minutes. A video call streams the camera exactly
 * the same way for forty minutes, and the hold had no limit at all: it pinned interactive
 * caps, full sensor polling and the anti-clamp for the whole call. A OnePlus 13 owner
 * reported the phone getting hot on video calls, which is this and nothing else.
 *
 * Past a couple of minutes the situation is no longer a burst - it is a sustained session,
 * and sustained sessions are what the thermal path exists to manage. Holding interactive
 * caps through one does not prevent dropped frames either: the vendor thermal engine
 * throttles anyway, and ASB re-raising its limits is the write war seen in the field logs.
 *
 * Two releases, whichever comes first:
 *   - camera_hold_max_s of continuous streaming (0 = keep the old unbounded behaviour)
 *   - the CPU reaching the profile's own throttle point, where holding is counter-productive
 *
 * Released only means "stop FORCING heavy". Real load still raises the state on its own,
 * so a recording that genuinely needs the clocks keeps them.
 */
/* Separate flag rather than a 0 sentinel: 0 is a legitimate timestamp at boot, and using
 * it to mean "not started" restarts the clock on the next tick instead - which quietly
 * extends the hold past its limit. Caught by a unit test, not on a device. */
static long cam_hold_start = 0;
static int  cam_hold_running = 0;

static asb_state_t fsm_desired(const asb_metrics_t *m) {
    asb_state_t s = fsm_desired_base(m);
    if (g_asb_cfg.camera_hold_enable && m->misc.camera_active &&
        m->misc.screen_on && s < ASB_STATE_HEAVY) {

        long now_s = (long)m->ts.tv_sec;
        if (!cam_hold_running) { cam_hold_start = now_s; cam_hold_running = 1; }

        int hold_ok = 1;
        int max_s = g_asb_cfg.camera_hold_max_s;
        if (max_s > 0 && (now_s - cam_hold_start) >= max_s)
            hold_ok = 0;

        int trip = asb_config_profile_sustained_temp_enter(&g_asb_cfg, 1);
        if (trip > 0 && m->therm.cpu_max_c >= trip)
            hold_ok = 0;

        if (hold_ok) s = ASB_STATE_HEAVY;
    } else {
        cam_hold_running = 0;   /* not streaming: the next session starts its own clock */
    }
    return s;
}

static int fsm_update(asb_fsm_t *fsm, const asb_metrics_t *m) {
    fsm->state_changed = 0;
    fsm->caps_changed  = 0;
    fsm->prev_state    = fsm->state;

    /* Screen off is not the same as idle.
     *
     * This forced DEEP_IDLE the moment the screen went off, whatever the phone was doing.
     * A capture of Bluetooth playback with the screen off shows the cost: the state reads
     * DEEP_IDLE while load1 sits at 18.9, 13.9, 13.2 - real work, running on the deepest
     * rails the module has. Capping work that has to happen anyway does not save energy,
     * it stretches it: the phase drew 165 mA against 59 for actual sleep, and stayed awake
     * 99.8% of its 35 minutes because the work never got to finish.
     *
     * With genuine load the state settles at LIGHT_IDLE instead - still far below anything
     * screen-on, but high enough to let a decode finish and the core go quiet. An idle
     * phone is unaffected: load below the threshold still goes straight to DEEP_IDLE.
     */
    int _off_busy = (m->cpu.load1 >= 8.0f);
    if (!m->misc.screen_on && _off_busy && fsm->state != ASB_STATE_LIGHT_IDLE &&
        fsm->state != ASB_STATE_MODERATE) {
        fsm->state   = ASB_STATE_LIGHT_IDLE;
        fsm->pending = ASB_STATE_LIGHT_IDLE;
        fsm->pending_ticks = 0;
        fsm->state_changed = 1;
        g_gaming_confirm_streak = 0;
    }
    else if (!m->misc.screen_on && !_off_busy && fsm->state != ASB_STATE_DEEP_IDLE) {
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

        /*
         * comfort-first battery brain -- when battery + screen on + device warm, prevent
         * pushing into SUSTAINED/GAMING heat targets.
         */
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

        /* Anticipate a known-hot app instead of waiting for the heat.
         *
         * The module already records which apps make this phone hot - appheat has been
         * feeding the learner's battery lean for releases. The thermal path never used it:
         * SUSTAINED engaged strictly on temperature, so the governor always arrived after
         * the phone was already at the trip point and then spent the session climbing back
         * down. That is the whole shape of "heats up fast, cools down slowly".
         *
         * For an app this device has repeatedly run hot on, the trip point moves down by
         * four degrees. Nothing else changes: same state, same rails, same exit condition -
         * it simply starts sooner, while there is still thermal headroom to spend. An app
         * with no history is untouched, so a phone that has learnt nothing behaves exactly
         * as before.
         *
         * Four degrees is deliberately small. The point is to be early, not to be strict:
         * a large shift would make a known-hot app feel slower than an unknown one, which
         * users would notice long before they noticed the temperature.
         */
        if (g_asb_appheat_hot && sustained_temp_enter > 48) {
            sustained_temp_enter -= 4;
        }

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

        /* Our own threshold is a trigger, not just a filter.
         *
         * sustained_temp_enter was only ever consulted to qualify a signal the VENDOR
         * raised - so if the vendor HAL stayed quiet, ASB never entered SUSTAINED no
         * matter how hot the SoC got. A day capture with the slider at 60 C shows peaks of
         * 69 C and throttle=0 in every phase: the setting the user reached for, named
         * "Throttling Temperature", never once did what its name says.
         *
         * Vendor thresholds sit well above ours by design - they protect the silicon, not
         * the person holding it. Waiting for them makes this control decorative.
         *
         * Debounced by two consecutive ticks: a single sample above the line is as likely
         * to be one core spiking as the phone genuinely running hot, and entering
         * SUSTAINED on noise costs performance for no thermal reason. Only for a state
         * that would otherwise be HEAVY or above - throttling an idle phone because a
         * sensor read high once helps nobody.
         */
        if (sustained_temp_enter > 0 && m->therm.cpu_max_c >= sustained_temp_enter
            && desired >= ASB_STATE_HEAVY) {
            fsm->own_temp_ticks++;
            if (fsm->own_temp_ticks >= 2) throttle_signal = 1;
        } else if (m->therm.cpu_max_c < sustained_temp_exit) {
            fsm->own_temp_ticks = 0;
        }

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

            /*
             * Mode B: "hot in hand without CPU panic" — skin and surface both warm but CPU is
             * cool.
             */
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
            /*
             * ceiling_lock -- if virtual ceiling on big cluster is below 1.5GHz, GAMING is
             * pointless.
             */
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
                /* Too hot must not mean "allow more".
                 *
                 * This is the gaming-retry cooldown: after leaving GAMING it holds the
                 * state down so the phone does not immediately climb back. HEAVY is the
                 * right answer for the cooldown case - it is below GAMING.
                 *
                 * But SUSTAINED sits at 0.62 on the cap ladder, BELOW HEAVY at 0.72, and
                 * this branch runs for too_hot as well. So a phone that had thermally
                 * escalated into SUSTAINED was pushed back up to HEAVY precisely because
                 * it was too hot: the hotter it got, the more it was allowed. A capture
                 * shows 88 C during a game with 65 seconds of SUSTAINED in the whole
                 * session, which is this loop letting go as soon as it engaged.
                 *
                 * Only lower, never raise. If the state is already at or below HEAVY,
                 * leave it where the thermal logic put it.
                 */
                if (desired > ASB_STATE_HEAVY) desired = ASB_STATE_HEAVY;
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
        /*
         * UI-burst fast escalation: when desired bumped up by gpu.load_pct≥12 on screen-on,
         * bypass the battery up_window×2 doubling.
         */
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
    
    /* SUSTAINED gets a cap that deepens with temperature.
     *
     * The overlay below deliberately skipped SUSTAINED, on the reasoning that its rail is
     * already the thermal answer. Measurement says otherwise: across a full day of logs the
     * prime ceiling was 2064577 at 40-49 degC, 1875495 at 60-69 and 1866290 at 80-89 - i.e.
     * once past the trip point, getting 20 degrees hotter bought no further clamping at
     * all, which is exactly the "heats up and cools down slowly" the field reports describe.
     *
     * One step of the rail per 4 degC above the trip point, no more than four steps. Small
     * on purpose: SUSTAINED is a state a phone can sit in for an hour of gaming, so the
     * response has to be gradual enough that nobody notices a cliff, and bounded so it can
     * never collapse the clock to something unusable. It also unwinds by itself - the cap
     * follows the temperature back down as the phone cools.
     */
    /* While hot, the cap may fall but never rise.
     *
     * SUSTAINED sits below HEAVY on the ladder, but ABOVE MODERATE - so a phone that had
     * settled at the MODERATE rail and then crossed the trip point was handed a HIGHER
     * ceiling than it had a second earlier. The trace shows it plainly: the median prime
     * cap is 1017600 at 50-54 degC, 1132800 at 55-59, and 1862400 at 60-64. Getting hotter
     * bought more clock, which is the opposite of what entering a thermal state means, and
     * it is why SUSTAINED drew 650 mA in this capture against 608 for GAMING.
     *
     * Remembering the last cap and refusing to exceed it makes the thermal path monotonic:
     * once the phone is hot, the only direction is down until it cools and thermal_cap
     * clears, which resets the memory. */
    /* Seeded from the cap that was in force BEFORE the phone went hot.
     *
     * The memory used to start empty, so the first tick inside the thermal state accepted
     * whatever SUSTAINED's rail offered and only then began refusing rises. That left the
     * entry itself free to raise the ceiling - which is precisely where the jump happens.
     * A gaming capture on this build shows it with 35 samples: the median prime cap is
     * 1017600 at 55-59 degC and 1862400 at 60-64, and SUSTAINED still drew 684 mA against
     * 593 for GAMING.
     *
     * Remembering the cool cap on every tick and seeding from it closes that gap: crossing
     * the trip point can now only lower the ceiling, never raise it. */
    static int _hot_cap_p0 = 0, _hot_cap_p1 = 0;
    static int _cool_cap_p0 = 0, _cool_cap_p1 = 0;
    if (!fsm->thermal_cap) {
        _hot_cap_p0 = 0; _hot_cap_p1 = 0;
        if (new_caps.cpu_max[0] > 0) _cool_cap_p0 = new_caps.cpu_max[0];
        if (new_caps.cpu_max[1] > 0) _cool_cap_p1 = new_caps.cpu_max[1];
    }
    else if (_hot_cap_p0 == 0 && _hot_cap_p1 == 0) {
        /* First tick of a hot spell: inherit the cool ceiling rather than start blank. */
        _hot_cap_p0 = _cool_cap_p0;
        _hot_cap_p1 = _cool_cap_p1;
    }
    else {
        if (_hot_cap_p0 > 0 && new_caps.cpu_max[0] > _hot_cap_p0)
            new_caps.cpu_max[0] = _hot_cap_p0;
        if (_hot_cap_p1 > 0 && new_caps.cpu_max[1] > _hot_cap_p1)
            new_caps.cpu_max[1] = _hot_cap_p1;
    }

    if (fsm->thermal_cap && fsm->state == ASB_STATE_SUSTAINED) {
        int trip = asb_config_profile_sustained_temp_enter(&g_asb_cfg, 1);
        int over = (trip > 0) ? (m->therm.cpu_max_c - trip) : 0;
        if (over > 0) {
            int steps = over / 4;
            if (steps > 4) steps = 4;
            /* 6% per step: roughly one frequency step on the tables these chips ship,
               applied as a ratio so it lands sanely whatever the rail happens to be. */
            int keep_pct = 100 - steps * 6;
            for (int i = 0; i < 3; i++)
                new_caps.cpu_max[i] = (int)((long)new_caps.cpu_max[i] * keep_pct / 100);
            if (new_caps.gpu_max_pct > 0) {
                int g = new_caps.gpu_max_pct - steps * 5;
                new_caps.gpu_max_pct = (g < 30) ? 30 : g;
            }
        }
    }
    if (fsm->thermal_cap) {
        /* Recorded after the proportional step, so the memory holds the value actually
           applied rather than the rail it started from. */
        _hot_cap_p0 = new_caps.cpu_max[0];
        _hot_cap_p1 = new_caps.cpu_max[1];
    }

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

    /*
     * ── Video-aware GPU ceiling trim (battery/heat saver) ──────────────── A full-day capture
     * showed the GPU is the dominant power/heat driver (~728 mA at >40% busy vs ~231 mA near
     * idle) and that high-GPU moments split into two kinds: video playback (high GPU + LOW cpu
     * load) and gaming (high GPU + high cpu load / GAMING state).
     */
    {
        int vid_gpu = g_asb_cfg.gpu_video_busy_min > 0
                      ? g_asb_cfg.gpu_video_busy_min : 40;   /* GPU% that counts as "media-heavy" */
        /* video heuristic: GPU busy high AND cpu load low (not gaming-like) */
        int load_x100 = (int)(m->cpu.load1 * 100.0f);
        int low_cpu   = load_x100 < 1200;                    /* load < 12.0 */
        if (m->gpu.load_pct >= vid_gpu && low_cpu &&
            fsm->state != ASB_STATE_GAMING) {
            if (fsm->gpu_video_ticks < 1000) fsm->gpu_video_ticks++;
        } else {
            fsm->gpu_video_ticks = 0;
        }
        int video_active = fsm->gpu_video_ticks >= 2;        /* ~2 polls sustained */

        int trim = g_asb_cfg.gpu_idle_trim_pct;              /* 0 disables (default set below) */
        if (trim > 0 &&
            fsm->profile_idx != PROFILE_PERFORMANCE &&
            !video_active &&
            !fsm->thermal_cap &&
            (fsm->state == ASB_STATE_LIGHT_IDLE ||
             fsm->state == ASB_STATE_MODERATE)) {
            int floor_gpu = g_asb_cfg.gpu_idle_trim_floor > 0
                            ? g_asb_cfg.gpu_idle_trim_floor : 55;
            int trimmed = new_caps.gpu_max_pct - trim;
            if (trimmed < floor_gpu) trimmed = floor_gpu;    /* never below a usable floor */
            if (trimmed < new_caps.gpu_max_pct) new_caps.gpu_max_pct = trimmed;
        }

        /*
         * Video playback gets its own, gentler GPU ceiling.
         *
         * The trim above is skipped while video is active, and that was the whole of the
         * handling: the phase the comment itself calls the dominant power driver (~728 mA
         * at >40% GPU busy) was the one phase left at the full ceiling. A field capture
         * bears it out - playback with the screen on drained 25.4 %/h against 14.2 %/h for
         * gaming on the same device, with the GPU at 55% and the CPU nearly idle.
         *
         * Skipping the idle trim was right: that trim is aimed at an idle GPU and would
         * cut into a decoder mid-frame. But "do not trim aggressively" is not the same as
         * "do not cap at all". Playback is steady-state and predictable - the decode block
         * does the work and the GPU only composites - so a ceiling well above what
         * compositing needs still saves the ramp to maximum that nothing was asking for.
         *
         * Deliberately conservative: only below the profile's own ceiling, never in
         * PERFORMANCE, never on top of a thermal cap, and 0 disables it outright.
         */
        int vmax = g_asb_cfg.gpu_video_max_pct;
        if (vmax > 0 && video_active &&
            fsm->profile_idx != PROFILE_PERFORMANCE &&
            !fsm->thermal_cap &&
            new_caps.gpu_max_pct > vmax) {
            new_caps.gpu_max_pct = vmax;
        }
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
