#pragma once
/* ASB V22 runtime config: simple key=value parser */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef struct {
    int   heavy_gpu_enter;
    float heavy_load_enter;
    int   gaming_gpu_enter;
    int   sustained_gpu_min;
    float sustained_load_min;
    int   sustained_temp_enter;
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
} asb_runtime_config_t;

static inline void asb_config_defaults(asb_runtime_config_t *c) {
    memset(c, 0, sizeof(*c));
    c->heavy_gpu_enter     = 35;
    c->heavy_load_enter    = 2.0f;
    c->gaming_gpu_enter    = 65;
    c->sustained_gpu_min   = 45;
    c->sustained_load_min  = 4.0f;
    c->sustained_temp_enter= 42;
    c->heavy_gpu_exit      = 25;
    c->gaming_gpu_exit     = 55;
    c->sustained_gpu_exit  = 35;
    c->heavy_min_dwell_s   = 8;
    c->sustained_min_dwell_s = 24;
    c->gaming_min_dwell_s  = 12;
    c->reassert_heavy_s    = 12;
    c->reassert_gaming_s   = 6;
    c->msm_perf_boost_only = 1;
    c->thermal_overlay_pct = 20;
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
