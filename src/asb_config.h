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
} asb_runtime_config_t;

static inline void asb_config_defaults(asb_runtime_config_t *c) {
    memset(c, 0, sizeof(*c));
    c->heavy_gpu_enter     = 35;
    c->heavy_load_enter    = 15.0f;
    c->moderate_load_enter = 10.0f;
    c->gaming_gpu_enter    = 65;
    c->sustained_gpu_min   = 45;
    c->sustained_load_min  = 4.0f;
    c->sustained_temp_enter= 65;
    c->sustained_temp_exit = 55;
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
    c->gaming_gap_thresh        = 1500000;
    c->gaming_gap_ticks         = 4;
    c->gaming_retry_cooldown_s  = 20;
    c->gaming_retry_temp_max    = 50;
    c->sustained_reentry_cooldown_s = 20;
    c->highload_mode = 0;
    c->auto_degrade_gap_thresh  = 800000;
    c->auto_degrade_sus_ratio   = 2;
    c->auto_degrade_thermal_pct = 45;

    c->bat_fast_idle_s     = 15;
    c->bat_light_idle_gpu  = 10;
    c->bat_suppress_gaming = 1;
    c->bat_heavy_load_enter = 15.0f;  /* SM8850: idle loadavg 6-10, need higher */
    c->bat_moderate_load_enter = 10.0f;
    c->log_level = 0;
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
