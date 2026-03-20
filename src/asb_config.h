#pragma once
/* ASB V23 runtime config: key=value parser */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef struct {
    int   heavy_gpu_enter;
    float heavy_load_enter;
    float moderate_load_enter;  /* V26: load threshold for MODERATE (SD8 Elite idle=8+) */
    int   gaming_gpu_enter;
    int   sustained_gpu_min;
    float sustained_load_min;
    int   sustained_temp_enter;  /* degC -- SUSTAINED entry threshold (default 65) */
    int   sustained_temp_exit;   /* degC -- SUSTAINED exit hysteresis (default 55, < enter) */
    float sustained_level;      /* 0.0-1.0 within profile range (default 0.80) */
    int   heavy_gpu_exit;
    int   gaming_gpu_exit;
    int   sustained_gpu_exit;
    int   heavy_min_dwell_s;
    int   sustained_min_dwell_s;
    int   gaming_min_dwell_s;
    int   reassert_heavy_s;
    int   reassert_gaming_s;
    int   msm_perf_boost_only;
    int   thermal_overlay_pct;
    int   thermal_throttle_temp; /* degC -- throttle detection threshold for SD8Elite (default 65) */
    /* Gap-aware SUSTAINED */
    int   gaming_gap_thresh;    /* kHz -- gap above which GAMING is considered unreachable */
    int   gaming_gap_ticks;     /* consecutive ticks with large gap to trigger SUSTAINED */
    int   gaming_retry_cooldown_s; /* seconds cooldown before GAMING retry after SUSTAINED */
    int   gaming_retry_temp_max;   /* degC -- GAMING retry only if temp <= this value */
    int   sustained_reentry_cooldown_s; /* seconds -- minimum interval between SUSTAINED episodes */
    int   highload_mode; /* 0=default, 1=burst, 2=stable, 3=auto */
    /* auto-mode thresholds: when to degrade burst->stable */
    int   auto_degrade_gap_thresh;   /* avg_gap_p0 > X -> gaming caps unreachable */
    int   auto_degrade_sus_ratio;    /* sus_entries / gaming_entries >= X -> degrade to stable */
    int   auto_degrade_thermal_pct;  /* % time in SUSTAINED of total -> degrade without gaming entries */

    /* Battery profile tuning */
    int   bat_fast_idle_s;       /* seconds to DEEP_IDLE in battery profile (0=off) */
    int   bat_light_idle_gpu;    /* GPU % cap in LIGHT_IDLE in battery mode */
    int   bat_suppress_gaming;   /* 1 = GAMING blocked in battery profile */
    float bat_heavy_load_enter; /* separate load threshold for HEAVY in battery (0=use global) */
    float bat_moderate_load_enter; /* V26: MODERATE threshold in battery */
    int   log_level;            /* V26: 0=normal, 1=verbose (FSM ticks, reasserts) */
} asb_runtime_config_t;

static inline void asb_config_defaults(asb_runtime_config_t *c) {
    memset(c, 0, sizeof(*c));
    c->heavy_gpu_enter     = 35;
    c->heavy_load_enter    = 15.0f; /* V25: SD8 Elite loadavg is 8+ even idle */
    c->moderate_load_enter = 10.0f; /* V26: loadavg above idle noise -> MODERATE */
    c->gaming_gpu_enter    = 65;
    c->sustained_gpu_min   = 45;
    c->sustained_load_min  = 4.0f;
    c->sustained_temp_enter= 65;
    c->sustained_temp_exit = 55; /* hysteresis 10degC -- do not exit while t > 55 */
    c->heavy_gpu_exit      = 25;
    c->gaming_gpu_exit     = 55;
    c->sustained_gpu_exit  = 35;
    c->heavy_min_dwell_s   = 8;
    c->sustained_min_dwell_s = 24;
    c->gaming_min_dwell_s  = 12;
    c->reassert_heavy_s    = 12;
    c->reassert_gaming_s   = 6;
    c->msm_perf_boost_only = 1;
    c->thermal_overlay_pct   = 20;
    c->thermal_throttle_temp = 65;
    c->sustained_level       = 0.80f;
    /* gap-aware SUSTAINED: enter if GAMING cap_gap > 1500 MHz for 4 ticks (~8s) */
    c->gaming_gap_thresh        = 1500000;
    c->gaming_gap_ticks         = 4;
    c->gaming_retry_cooldown_s  = 20;
    c->gaming_retry_temp_max    = 50;
    c->sustained_reentry_cooldown_s = 20;
    c->highload_mode = 0;
    c->auto_degrade_gap_thresh  = 800000; /* kHz: avg gap > 800MHz -> gaming unreachable */
    c->auto_degrade_sus_ratio   = 2;  /* V24: was 4, too strict for CoD (ratio=1.09) */
    c->auto_degrade_thermal_pct = 45; /* V24: was 60, CoD showed sus_pct=51% and didn't fire */

    /* Battery profile */
    c->bat_fast_idle_s     = 15; /* battery: 15s without activity -> DEEP_IDLE */
    c->bat_light_idle_gpu  = 10; /* battery: GPU max 10% in LIGHT_IDLE */
    c->bat_suppress_gaming = 1;
    c->bat_heavy_load_enter = 4.0f;
    c->bat_moderate_load_enter = 3.0f;
    c->log_level = 0; /* V26: 0=normal (clean), 1=verbose (debug) */
}

static inline char *asb_cfg_trim(char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    if (!*s) return s;
    char *e = s + strlen(s) - 1;
    while (e >= s && isspace((unsigned char)*e)) *e-- = '\0';
    return s;
}

static inline void asb_cfg_apply_kv(asb_runtime_config_t *c, const char *k, const char *v) {
    if (!strcmp(k, "heavy_gpu_enter")) c->heavy_gpu_enter = atoi(v);
    else if (!strcmp(k, "heavy_load_enter")) c->heavy_load_enter = (float)atof(v);
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
    else if (!strcmp(k, "moderate_load_enter"))  c->moderate_load_enter = (float)atof(v);
    else if (!strcmp(k, "bat_moderate_load_enter")) c->bat_moderate_load_enter = (float)atof(v);
    else if (!strcmp(k, "log_level"))            c->log_level = atoi(v);
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
 * Call after asb_config_parse() -- overrides only high-load parameters.
 * Explicitly set parameters in governor.conf will be overridden by the mode --
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
    /* Reload from defaults -- burst was applied by profile:performance */
    c->highload_mode = 0; /* back to default */
    /* Reset to config file values (caller should reload if needed) */
}

/* Apply burst parameters for performance profile.
 * V28: starts as AUTO (3) -- identical burst-like params at cold start,
 * but auto-degrade can kick in mid-session when thermal wall is hit.
 * Previously mode=1 (burst) blocked all three degrade paths entirely. */
static inline void asb_config_apply_burst_override(asb_runtime_config_t *c) {
    c->highload_mode             = 3; /* auto: starts as burst, degrades if needed */
    c->gaming_gap_ticks          = 3;
    c->gaming_retry_cooldown_s      = 10;
    c->gaming_retry_temp_max        = 50;
    c->sustained_level              = 0.85f;
    c->sustained_reentry_cooldown_s = 10;
}

static inline void asb_config_apply_stable_override(asb_runtime_config_t *c) {
    c->gaming_gap_ticks             = 4;
    c->gaming_retry_cooldown_s      = 35;
    c->gaming_retry_temp_max        = 45;
    c->sustained_level              = 0.78f;
    c->sustained_reentry_cooldown_s = 25;
}

/* AUTO degrade: burst->stable on poor gaming viability.
 * Three independent paths, each sufficient alone:
 *  Path 1: avg_gap_p0 unreachable + SUSTAINED dominant (needs gaming data)
 *  Path 2: thermal pressure alone (no gaming entries needed)
 *  Path 3: extreme gap (needs 3+ gaming entries)
 *
 * V28: Path 2 no longer gated by gaming_entries >= 2.
 * In benchmark/thermal scenarios device can go HEAVY->thermal->SUSTAINED
 * with 0-1 gaming entries; thermal path must still fire. */
static inline int asb_config_auto_should_degrade(
        const asb_runtime_config_t *c,
        int avg_gap_p0, int gaming_entries, int sustained_entries,
        long time_heavy, long time_gaming, long time_sustained,
        int already_degraded)
{
    if (c->highload_mode != 3 || already_degraded) return 0;

    /* Path 1: gaming entries exist, caps unreachable + SUSTAINED dominant */
    if (gaming_entries >= 2) {
        int gap_bad   = (c->auto_degrade_gap_thresh > 0 &&
                         avg_gap_p0 > c->auto_degrade_gap_thresh);
        int ratio_bad = (c->auto_degrade_sus_ratio  > 0 &&
                         sustained_entries >= gaming_entries * c->auto_degrade_sus_ratio);
        if (gap_bad && ratio_bad) return 1;
    }

    /* Path 2: thermal pressure -- even without gaming entries.
     * If > auto_degrade_thermal_pct% of heavy time was in SUSTAINED
     * and enough data accumulated (>120s) -- burst is futile.         */
    if (c->auto_degrade_thermal_pct > 0) {
        long total = time_heavy + time_gaming + time_sustained;
        if (total >= 120 && time_sustained > 0) {
            int sus_pct = (int)(time_sustained * 100 / total);
            if (sus_pct >= c->auto_degrade_thermal_pct) return 1;
        }
    }

    /* Path 3 (V24): extreme gap -- vendor HAL cuts caps by >2 GHz.
     * If avg gap > 2M kHz with 3+ gaming entries, burst is clearly
     * futile regardless of ratio. Real data from CoD: gap=2.37 GHz,
     * ratio=1.09 (nearly equal GAMING/SUSTAINED), auto never fired. */
    if (avg_gap_p0 > 2000000 && gaming_entries >= 3) return 1;

    return 0;
}
