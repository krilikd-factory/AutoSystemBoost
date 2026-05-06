#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef struct {
    int   heavy_gpu_enter;
    float heavy_load_enter;
    float moderate_load_enter;
    int   gaming_gpu_enter;
    int   sustained_gpu_min;
    float sustained_load_min;
    int   sustained_temp_enter;
    int   sustained_temp_exit;
    float sustained_level;
    int   perf_sustained_temp_enter;
    int   perf_sustained_temp_exit;
    float perf_sustained_level;
    int   perf_hot_guard_temp;
    int   perf_hot_guard_ticks;
    /* V36: balanced-specific thermal ceiling (softer than perf) */
    int   balanced_sustained_temp_enter;
    int   balanced_sustained_temp_exit;
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
    int   thermal_throttle_temp;
    int   gaming_gap_thresh;
    int   gaming_gap_ticks;
    int   gaming_retry_cooldown_s;
    int   gaming_retry_temp_max;
    int   sustained_reentry_cooldown_s;
    int   highload_mode;
    int   auto_degrade_gap_thresh;
    int   auto_degrade_sus_ratio;
    int   auto_degrade_thermal_pct;

    int   bat_fast_idle_s;
    int   bat_light_idle_gpu;
    int   bat_suppress_gaming;
    float bat_heavy_load_enter;
    float bat_moderate_load_enter;
    int   log_level;

    /* V39: thermal_pwrlevel monitoring rate control.
     * thermal_pwrlevel_div_idle: in LIGHT_IDLE/MODERATE on battery, read
     *   thermal_pwrlevel only every Nth tick. Default 3 = read every ~30-45s.
     *   Set to 1 to read every tick (more responsive, slightly more energy).
     *   Set to 0 to disable thermal_pwrlevel monitoring entirely.
     * thermal_pwrlevel_audit_log_s: how often to write audit log line summarising
     *   read counts and CPU time spent. Default 3600 = once per hour. */
    int   thermal_pwrlevel_div_idle;
    int   thermal_pwrlevel_audit_log_s;

    /* V34: configurable thresholds (previously hardcoded) */
    int   env_iq_quiet;            /* idle quality threshold for quiet env */
    int   env_iq_hostile;          /* idle quality threshold for hostile env */
    float env_wph_noisy;           /* wakes/hour threshold for noisy env */
    float env_wph_hostile;         /* wakes/hour threshold for hostile env */
    int   quiet_entry_ticks;       /* ticks of DEEP_IDLE before quiet mode */
    int   quiet_fast_ticks;        /* ticks with clean-night reward */
    int   quiet_tick_s;            /* tick interval in ultra-quiet mode */
    int   quiet_exit_grace;        /* consecutive noise ticks to exit quiet */
    int   bat_comfort_temp;        /* CPU temp to cap HEAVY in battery */
    int   clamp_economy_after_s;   /* seconds of clamp before economy kicks in */
    int   clamp_thermal_every_n;   /* thermal read frequency under clamp */
    int   action_waste_threshold;  /* waste level that doubles intervals */
    int   virtual_ceiling_alpha;   /* EMA weight for virtual ceiling (0-100, /8) */

    /* V35: balanced-specific thresholds */
    float balanced_heavy_load_enter;    /* load threshold for HEAVY in balanced */
    float balanced_moderate_load_enter; /* load threshold for MODERATE in balanced */
    int   balanced_warmup_grace_s;      /* seconds to suppress sustained after start */
    int   balanced_warmup_bypass_temp;  /* bypass grace if temp already above this */
    int   balanced_warmup_bypass_headroom; /* bypass grace if headroom below this */
    int   thermal_stale_after_s;        /* seconds before temp is considered stale */
    int   soft_clamp_headroom_pct;      /* advisory headroom threshold */
    int   hard_clamp_headroom_pct;      /* actionable headroom threshold */
} asb_runtime_config_t;

static inline void asb_config_defaults(asb_runtime_config_t *c) {
    memset(c, 0, sizeof(*c));
    c->heavy_gpu_enter     = 35;
    /* V39: HEAVY load thresholds raised for Snapdragon 8 Elite Gen 5.
     *
     * Linux loadavg-1min represents avg # tasks in run queue over 1 min.
     * On 8-core Oryon with modern Android (VPN + GMS + LSPosed + ZygiskNeo +
     * background services), idle loadavg routinely sits at 6-12 even with
     * minimal real CPU work. Old V36 thresholds (heavy=15, moderate=10) cause
     * FSM to enter HEAVY almost permanently — confirmed in user log where
     * ses_heavy=7747s (2h9min continuous HEAVY at temp=27-32C, gpu=0%).
     *
     * Recalibrated:
     *   moderate_load_enter: 10 → 14   (above typical idle, below true work)
     *   heavy_load_enter:    15 → 20   (real CPU pressure, not background noise)
     * Battery profile gets stricter still (idle is more permissive there).
     */
    c->heavy_load_enter    = 20.0f;
    c->moderate_load_enter = 14.0f;
    c->gaming_gpu_enter    = 65;
    c->sustained_gpu_min   = 45;
    c->sustained_load_min  = 4.0f;
    c->sustained_temp_enter= 65;
    c->sustained_temp_exit = 55;
    c->perf_sustained_temp_enter = 0;
    c->perf_sustained_temp_exit  = 0;
    c->perf_sustained_level      = 0.0f;
    c->perf_hot_guard_temp       = 0;
    c->perf_hot_guard_ticks      = 0;
    c->balanced_sustained_temp_enter = 0;  /* 0 = use global sustained_temp_enter */
    c->balanced_sustained_temp_exit  = 0;  /* 0 = use global sustained_temp_exit */
    c->heavy_gpu_exit      = 25;
    c->gaming_gpu_exit     = 55;
    c->sustained_gpu_exit  = 35;
    c->heavy_min_dwell_s   = 8;
    c->sustained_min_dwell_s = 24;
    c->gaming_min_dwell_s  = 20;
    c->reassert_heavy_s    = 12;
    c->reassert_gaming_s   = 6;
    c->msm_perf_boost_only = 1;
    c->thermal_overlay_pct   = 20;
    c->thermal_throttle_temp = 65;
    c->sustained_level       = 0.80f;
    c->gaming_gap_thresh        = 1500000;
    c->gaming_gap_ticks         = 4;
    c->gaming_retry_cooldown_s  = 20;
    c->gaming_retry_temp_max    = 50;
    c->sustained_reentry_cooldown_s = 20;
    c->highload_mode = 0;
    c->auto_degrade_gap_thresh  = 800000;
    c->auto_degrade_sus_ratio   = 2;
    c->auto_degrade_thermal_pct = 45;

    c->bat_fast_idle_s     = 12;
    c->bat_light_idle_gpu  = 10;
    c->bat_suppress_gaming = 1;
    /* V39: same recalibration for battery profile */
    c->bat_heavy_load_enter = 20.0f;     /* was 15 */
    c->bat_moderate_load_enter = 14.0f;  /* was 10 */
    c->log_level = 0;

    /* V39: thermal_pwrlevel monitoring */
    c->thermal_pwrlevel_div_idle      = 3;     /* every 3rd tick in LIGHT_IDLE/MODERATE */
    c->thermal_pwrlevel_audit_log_s   = 3600;  /* hourly audit summary */

    /* V34 defaults */
    c->env_iq_quiet         = 25;
    c->env_iq_hostile       = 10;
    c->env_wph_noisy        = 6.0f;
    c->env_wph_hostile      = 12.0f;
    c->quiet_entry_ticks    = 60;   /* ~10min at 10s ticks */
    c->quiet_fast_ticks     = 30;   /* ~5min with clean-night reward */
    c->quiet_tick_s         = 20;
    c->quiet_exit_grace     = 3;
    c->bat_comfort_temp     = 48;
    c->clamp_economy_after_s = 120;
    c->clamp_thermal_every_n = 3;
    c->action_waste_threshold = 5;
    c->virtual_ceiling_alpha = 7;   /* EMA: (old*7 + new*1)/8 */

    /* V35: balanced-specific */
    c->balanced_heavy_load_enter    = 0;  /* 0 = use global heavy_load_enter */
    c->balanced_moderate_load_enter = 0;  /* 0 = use global moderate_load_enter */
    c->balanced_warmup_grace_s      = 45;
    c->balanced_warmup_bypass_temp  = 60;
    c->balanced_warmup_bypass_headroom = 40;
    c->thermal_stale_after_s        = 60;
    c->soft_clamp_headroom_pct      = 70;
    c->hard_clamp_headroom_pct      = 45;
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
    else if (!strcmp(k, "perf_sustained_temp_enter")) c->perf_sustained_temp_enter = atoi(v);
    else if (!strcmp(k, "perf_sustained_temp_exit"))  c->perf_sustained_temp_exit  = atoi(v);
    else if (!strcmp(k, "balanced_sustained_temp_enter")) c->balanced_sustained_temp_enter = atoi(v);
    else if (!strcmp(k, "balanced_sustained_temp_exit"))  c->balanced_sustained_temp_exit  = atoi(v);
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
    else if (!strcmp(k, "thermal_pwrlevel_div_idle"))    c->thermal_pwrlevel_div_idle    = atoi(v);
    else if (!strcmp(k, "thermal_pwrlevel_audit_log_s")) c->thermal_pwrlevel_audit_log_s = atoi(v);
    else if (!strcmp(k, "bat_heavy_load_enter")) c->bat_heavy_load_enter = (float)atof(v);
    else if (!strcmp(k, "moderate_load_enter"))  c->moderate_load_enter = (float)atof(v);
    else if (!strcmp(k, "bat_moderate_load_enter")) c->bat_moderate_load_enter = (float)atof(v);
    else if (!strcmp(k, "log_level"))            c->log_level = atoi(v);
    /* V34 configurable thresholds */
    else if (!strcmp(k, "env_iq_quiet"))          c->env_iq_quiet = atoi(v);
    else if (!strcmp(k, "env_iq_hostile"))        c->env_iq_hostile = atoi(v);
    else if (!strcmp(k, "env_wph_noisy"))         c->env_wph_noisy = (float)atof(v);
    else if (!strcmp(k, "env_wph_hostile"))       c->env_wph_hostile = (float)atof(v);
    else if (!strcmp(k, "quiet_entry_ticks"))     c->quiet_entry_ticks = atoi(v);
    else if (!strcmp(k, "quiet_fast_ticks"))      c->quiet_fast_ticks = atoi(v);
    else if (!strcmp(k, "quiet_tick_s"))          c->quiet_tick_s = atoi(v);
    else if (!strcmp(k, "quiet_exit_grace"))      c->quiet_exit_grace = atoi(v);
    else if (!strcmp(k, "bat_comfort_temp"))      c->bat_comfort_temp = atoi(v);
    else if (!strcmp(k, "clamp_economy_after_s")) c->clamp_economy_after_s = atoi(v);
    else if (!strcmp(k, "clamp_thermal_every_n")) c->clamp_thermal_every_n = atoi(v);
    else if (!strcmp(k, "action_waste_threshold"))c->action_waste_threshold = atoi(v);
    else if (!strcmp(k, "virtual_ceiling_alpha")) c->virtual_ceiling_alpha = atoi(v);
    else if (!strcmp(k, "balanced_heavy_load_enter"))    c->balanced_heavy_load_enter = (float)atof(v);
    else if (!strcmp(k, "balanced_moderate_load_enter")) c->balanced_moderate_load_enter = (float)atof(v);
    else if (!strcmp(k, "balanced_warmup_grace_s"))      c->balanced_warmup_grace_s = atoi(v);
    else if (!strcmp(k, "balanced_warmup_bypass_temp"))  c->balanced_warmup_bypass_temp = atoi(v);
    else if (!strcmp(k, "balanced_warmup_bypass_headroom")) c->balanced_warmup_bypass_headroom = atoi(v);
    else if (!strcmp(k, "thermal_stale_after_s"))        c->thermal_stale_after_s = atoi(v);
    else if (!strcmp(k, "soft_clamp_headroom_pct"))      c->soft_clamp_headroom_pct = atoi(v);
    else if (!strcmp(k, "hard_clamp_headroom_pct"))      c->hard_clamp_headroom_pct = atoi(v);
    else if (!strcmp(k, "sustained_reentry_cooldown_s")) c->sustained_reentry_cooldown_s = atoi(v);
    else if (!strcmp(k, "highload_mode")) {
        if (!strcmp(v, "burst"))   c->highload_mode = 1;
        else if (!strcmp(v, "stable")) c->highload_mode = 2;
        else if (!strcmp(v, "auto"))   c->highload_mode = 3;
        else c->highload_mode = 0;
    }
    else if (!strcmp(k, "sustained_level")) {
        float v_f = (float)atof(v);
        if (v_f < 0.50f) v_f = 0.50f;
        if (v_f > 0.95f) v_f = 0.95f;
        c->sustained_level = v_f;
    }
    else if (!strcmp(k, "perf_sustained_level")) {
        float v_f = (float)atof(v);
        if (v_f < 0.50f) v_f = 0.50f;
        if (v_f > 0.95f) v_f = 0.95f;
        c->perf_sustained_level = v_f;
    }
    else if (!strcmp(k, "perf_hot_guard_temp")) c->perf_hot_guard_temp = atoi(v);
    else if (!strcmp(k, "perf_hot_guard_ticks")) c->perf_hot_guard_ticks = atoi(v);
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
}

static inline void asb_config_defaults_highload(asb_runtime_config_t *c) {
    c->highload_mode = 0;
}

static inline void asb_config_apply_burst_override(asb_runtime_config_t *c) {
    c->highload_mode             = 3;
    c->gaming_gap_ticks          = 3;
    c->gaming_retry_cooldown_s      = 20;
    c->gaming_retry_temp_max        = 47;
    c->sustained_level              = 0.82f;
    c->sustained_reentry_cooldown_s = 20;
}

static inline void asb_config_apply_stable_override(asb_runtime_config_t *c) {
    c->highload_mode                = 2;
    c->gaming_gap_ticks             = 4;
    c->gaming_retry_cooldown_s      = 35;
    c->gaming_retry_temp_max        = 45;
    c->sustained_level              = 0.78f;
    c->sustained_reentry_cooldown_s = 25;
}

static inline int asb_config_profile_sustained_temp_enter(const asb_runtime_config_t *c, int profile_idx) {
    if (profile_idx == 2 && c->perf_sustained_temp_enter > 0) return c->perf_sustained_temp_enter;
    if (profile_idx == 1 && c->balanced_sustained_temp_enter > 0) return c->balanced_sustained_temp_enter;
    return c->sustained_temp_enter;
}

static inline int asb_config_profile_sustained_temp_exit(const asb_runtime_config_t *c, int profile_idx) {
    if (profile_idx == 2 && c->perf_sustained_temp_exit > 0) return c->perf_sustained_temp_exit;
    if (profile_idx == 1 && c->balanced_sustained_temp_exit > 0) return c->balanced_sustained_temp_exit;
    return c->sustained_temp_exit;
}

static inline float asb_config_profile_sustained_level(const asb_runtime_config_t *c, int profile_idx) {
    if (profile_idx == 2 && c->perf_sustained_level >= 0.50f) return c->perf_sustained_level;
    return c->sustained_level;
}

static inline int asb_config_profile_hot_guard_temp(const asb_runtime_config_t *c, int profile_idx) {
    if (profile_idx == 2 && c->perf_hot_guard_temp > 0) return c->perf_hot_guard_temp;
    return 0;
}

static inline int asb_config_profile_hot_guard_ticks(const asb_runtime_config_t *c, int profile_idx) {
    if (profile_idx == 2 && c->perf_hot_guard_ticks > 0) return c->perf_hot_guard_ticks;
    return 0;
}

static inline int asb_config_auto_should_degrade(
        const asb_runtime_config_t *c,
        int avg_gap_p0, int gaming_entries, int sustained_entries,
        long time_heavy, long time_gaming, long time_sustained,
        int already_degraded)
{
    if (c->highload_mode != 3 || already_degraded) return 0;

    if (gaming_entries >= 2) {
        int gap_bad   = (c->auto_degrade_gap_thresh > 0 &&
                         avg_gap_p0 > c->auto_degrade_gap_thresh);
        int ratio_bad = (c->auto_degrade_sus_ratio  > 0 &&
                         sustained_entries >= gaming_entries * c->auto_degrade_sus_ratio);
        if (gap_bad && ratio_bad) return 1;
    }

    if (c->auto_degrade_thermal_pct > 0) {
        long total = time_heavy + time_gaming + time_sustained;
        if (total >= 120 && time_sustained > 0) {
            int sus_pct = (int)(time_sustained * 100 / total);
            if (sus_pct >= c->auto_degrade_thermal_pct) return 1;
        }
    }

    if (avg_gap_p0 > 2000000 && gaming_entries >= 3) return 1;

    return 0;
}
