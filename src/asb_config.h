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
    int   sustained_temp_enter;  /* °C — вход в SUSTAINED (default 65) */
    int   sustained_temp_exit;   /* °C — выход из SUSTAINED (default 55, < enter) */
    float sustained_level;      /* 0.0-1.0 в диапазоне профиля (default 0.80) */
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
    int   thermal_throttle_temp; /* °C — реальный порог throttle для SD8Elite (default 65) */
    /* Gap-aware SUSTAINED (V22-r5) */
    int   gaming_gap_thresh;    /* kHz — gap при котором GAMING считается недостижимым */
    int   gaming_gap_ticks;     /* тиков подряд с большим gap для входа в SUSTAINED */
    int   gaming_retry_cooldown_s; /* сек cooldown перед повторной попыткой GAMING после SUSTAINED */
    int   gaming_retry_temp_max;   /* °C — retry в GAMING только если temp <= этого значения */
    int   sustained_reentry_cooldown_s; /* сек — минимум между двумя SUSTAINED эпизодами */
    int   highload_mode; /* 0=default, 1=burst, 2=stable — high-load стратегия */
} asb_runtime_config_t;

static inline void asb_config_defaults(asb_runtime_config_t *c) {
    memset(c, 0, sizeof(*c));
    c->heavy_gpu_enter     = 35;
    c->heavy_load_enter    = 2.0f;
    c->gaming_gpu_enter    = 65;
    c->sustained_gpu_min   = 45;
    c->sustained_load_min  = 4.0f;
    c->sustained_temp_enter= 65;
    c->sustained_temp_exit = 55; /* гистерезис 10°C — не выходить пока t > 55 */
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
    /* gap-aware SUSTAINED: вход если GAMING cap_gap > 1500 MHz за 4 тика (~8с) */
    c->gaming_gap_thresh        = 1500000; /* kHz */
    c->gaming_gap_ticks         = 4;
    c->gaming_retry_cooldown_s  = 30;
    c->gaming_retry_temp_max    = 50;
    c->sustained_reentry_cooldown_s = 20;
    c->highload_mode = 0; /* default */
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
    else if (!strcmp(k, "sustained_reentry_cooldown_s")) c->sustained_reentry_cooldown_s = atoi(v);
    else if (!strcmp(k, "highload_mode")) {
        if (!strcmp(v, "burst"))  c->highload_mode = 1;
        else if (!strcmp(v, "stable")) c->highload_mode = 2;
        else c->highload_mode = 0; /* default */
    }
    else if (!strcmp(k, "sustained_level")) {
        float v_f = (float)atof(v);
        /* clamp: защита от опечаток вроде 1.8 или 0.05 */
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

/* Применяет highload_mode поверх конфига.
 * Вызывать после asb_config_parse() — переопределяет только high-load параметры.
 * Явно заданные параметры в governor.conf перекроются стратегией —
 * это сделано намеренно: mode задаёт "характер" поведения целиком. */
static inline void asb_config_apply_highload_mode(asb_runtime_config_t *c) {
    if (c->highload_mode == 1) {        /* BURST: benchmark / short sessions */
        c->gaming_gap_ticks             = 3;
        c->gaming_retry_cooldown_s      = 20;
        c->gaming_retry_temp_max        = 55;
        c->sustained_level              = 0.85f;
        c->sustained_reentry_cooldown_s = 10;
    } else if (c->highload_mode == 2) { /* STABLE: long gaming sessions */
        c->gaming_gap_ticks             = 4;
        c->gaming_retry_cooldown_s      = 35;
        c->gaming_retry_temp_max        = 45;
        c->sustained_level              = 0.78f;
        c->sustained_reentry_cooldown_s = 25;
    }
    /* mode=0 (default): параметры из конфига не меняются */
}
