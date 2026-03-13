#pragma once
/*
 * asb_metrics.h — быстрое чтение системных метрик из sysfs
 * Без fork, без sh, без alloc в hot-path.
 * Все функции читают напрямую через open/read/close.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <math.h>

/* ─── Paths ────────────────────────────────────────────────── */
#define PATH_BATT_CURRENT   "/sys/class/power_supply/battery/current_now"
#define PATH_BATT_VOLTAGE   "/sys/class/power_supply/battery/voltage_now"
#define PATH_BATT_CAPACITY  "/sys/class/power_supply/battery/capacity"
#define PATH_BATT_STATUS    "/sys/class/power_supply/battery/status"
#define PATH_BATT_TEMP      "/sys/class/power_supply/battery/temp"

#define PATH_GPU_LOAD       "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage"
#define PATH_GPU_FREQ       "/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq"
#define PATH_GPU_MAXFREQ    "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq"

#define PATH_LOADAVG        "/proc/loadavg"
#define PATH_MEMINFO        "/proc/meminfo"

/* OxygenOS / OnePlus 15 display state */
#define PATH_SCREEN_STATUS  "/sys/kernel/oplus_display/panel_power_status"
#define PATH_SCREEN_STATUS2 "/sys/kernel/oplus_display/disp_on_notify"
#define PATH_BACKLIGHT      "/sys/class/backlight/panel0-backlight/brightness"

/* CPU policy paths для OnePlus 15 (Snapdragon 8 Elite) */
#define PATH_CPU_POLICY0    "/sys/devices/system/cpu/cpufreq/policy0"
#define PATH_CPU_POLICY4    "/sys/devices/system/cpu/cpufreq/policy4"
#define PATH_CPU_POLICY6    "/sys/devices/system/cpu/cpufreq/policy6"
#define PATH_CPU_POLICY7    "/sys/devices/system/cpu/cpufreq/policy7"

/* OnePlus 15 (Snapdragon 8 Elite) реальная topology:
 *   policy0: cpus 0-5 (little+mid cluster, max 3628800)
 *   policy6: cpus 6-7 (big cluster, max 4608000)
 * policy4/policy7 не существуют на этом устройстве.
 * Используем auto-discovery при старте. */
#define PATH_CPU_POLICIES_DEFAULT "0,6"

/* Thermal — ищем CPU cluster thermal zone */
#define THERMAL_BASE        "/sys/class/thermal"
#define THERMAL_MAX_ZONES   30

/* WALT sched */
#define PATH_WALT_RAVG      "/proc/sys/walt/sched_ravg_window_nr_ticks"
#define PATH_WALT_IDLE      "/proc/sys/walt/sched_idle_enough"

/* Network */
#define PATH_WLAN_TX        "/sys/class/net/wlan0/statistics/tx_bytes"
#define PATH_WLAN_RX        "/sys/class/net/wlan0/statistics/rx_bytes"

/* ─── Structs ───────────────────────────────────────────────── */
typedef struct {
    int     current_ua;     /* μA, negative = discharging */
    int     voltage_uv;     /* μV */
    int     capacity_pct;   /* 0..100 */
    int     temp_dC;        /* °C × 10 */
    int     charging;       /* 1 = charging */
    int     current_ma;     /* abs(current_ua / 1000) */
} asb_battery_t;

typedef struct {
    int     load_pct;       /* 0..100 */
    long    cur_freq_hz;    /* Hz */
    long    max_freq_hz;    /* Hz */
} asb_gpu_t;

typedef struct {
    float   load1;          /* /proc/loadavg 1-min */
    float   load5;          /* /proc/loadavg 5-min */
    int     cur_freq[3];    /* policy0, policy4, policy7 в MHz */
    int     max_freq[3];
} asb_cpu_t;

typedef struct {
    int     cpu_max_c;      /* °C, лучший proxy для CPU temp */
    int     gpu_temp_c;     /* °C */
    int     skin_temp_c;    /* °C */
    int     throttling;     /* 1 если любая зона > 42°C */
} asb_thermal_t;

typedef struct {
    int     screen_on;      /* 1 = ON */
    long    wlan_tx_bps;    /* байт/сек с прошлого опроса */
    long    wlan_rx_bps;
} asb_misc_t;

/* Полный снимок метрик */
typedef struct {
    asb_battery_t   bat;
    asb_gpu_t       gpu;
    asb_cpu_t       cpu;
    asb_thermal_t   therm;
    asb_misc_t      misc;
    struct timespec ts;     /* время снимка */
} asb_metrics_t;

/* ─── Helpers ───────────────────────────────────────────────── */
static inline int sysfs_read_int(const char *path, int def) {
    char buf[32];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return def;
    int n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return def;
    buf[n] = '\0';
    return (int)strtol(buf, NULL, 10);
}

static inline long sysfs_read_long(const char *path, long def) {
    char buf[32];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return def;
    int n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return def;
    buf[n] = '\0';
    return strtol(buf, NULL, 10);
}

static inline int sysfs_read_str(const char *path, char *out, int maxlen) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int n = read(fd, out, maxlen - 1);
    close(fd);
    if (n > 0) { out[n] = '\0'; return n; }
    return -1;
}

/* ─── Battery ───────────────────────────────────────────────── */
/* Пути к current_now в порядке приоритета для OnePlus / Qualcomm */
static const char *g_batt_current_paths[] = {
    "/sys/class/power_supply/battery/current_now",
    "/sys/class/power_supply/bms/current_now",
    "/sys/class/power_supply/Battery/current_now",
    NULL
};
static int g_batt_current_path_idx = -1; /* -1 = не найден ещё */

static int metrics_find_batt_current_path(void) {
    if (g_batt_current_path_idx >= 0) return g_batt_current_path_idx;
    for (int i = 0; g_batt_current_paths[i]; i++) {
        int fd = open(g_batt_current_paths[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) { close(fd); g_batt_current_path_idx = i; return i; }
    }
    return -1;
}

static void metrics_read_battery(asb_battery_t *b) {
    int idx = metrics_find_batt_current_path();
    if (idx >= 0) {
        b->current_ua = sysfs_read_int(g_batt_current_paths[idx], 0);
    } else {
        b->current_ua = 0;
    }
    b->voltage_uv   = sysfs_read_int(PATH_BATT_VOLTAGE, 3800000);
    b->capacity_pct = sysfs_read_int(PATH_BATT_CAPACITY, 50);
    b->temp_dC      = sysfs_read_int(PATH_BATT_TEMP, 250);
    /* OnePlus: при разряде current_now ОТРИЦАТЕЛЬНЫЙ (-1500000 = 1500мА)
     * abs() → always positive mA значение                               */
    b->current_ma   = abs(b->current_ua) / 1000;

    char st[16] = {0};
    sysfs_read_str(PATH_BATT_STATUS, st, sizeof(st));
    b->charging = (st[0] == 'C') ? 1 : 0; /* "Charging" */
}

/* ─── GPU ───────────────────────────────────────────────────── */
static void metrics_read_gpu(asb_gpu_t *g) {
    g->load_pct  = sysfs_read_int(PATH_GPU_LOAD, 0);
    g->cur_freq_hz = sysfs_read_long(PATH_GPU_FREQ, 0);
    g->max_freq_hz = sysfs_read_long(PATH_GPU_MAXFREQ, 1000000000L);
    if (g->max_freq_hz <= 0) g->max_freq_hz = 1000000000L;
}

/* ─── CPU ───────────────────────────────────────────────────── */
/* ─── CPU topology auto-discovery ──────────────────────────────
 * При первом чтении определяем реальный policy layout.
 * Пробуем стандартный SD8 Elite: policy0/policy6.
 * Fallback на legacy: policy0/policy4/policy7.
 */
static int g_cpu_policy_ids[3]   = {0, 6, -1}; /* -1 = не существует */
static int g_cpu_policy_count    = 0;           /* инициализировано? */

static void cpu_topology_discover(void) {
    if (g_cpu_policy_count > 0) return; /* уже определено */

    /* Пробуем предпочтительный layout: policy0 + policy6 */
    int fd6 = open("/sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq",
                   O_RDONLY | O_CLOEXEC);
    if (fd6 >= 0) {
        close(fd6);
        g_cpu_policy_ids[0] = 0;
        g_cpu_policy_ids[1] = 6;
        g_cpu_policy_ids[2] = -1;
        g_cpu_policy_count  = 2;
        return;
    }
    /* Fallback: policy0 + policy4 + policy7 */
    g_cpu_policy_ids[0] = 0;
    g_cpu_policy_ids[1] = 4;
    g_cpu_policy_ids[2] = 7;
    g_cpu_policy_count  = 3;
}

/* Возвращает путь к policy[slot]/file в статическом буфере */
static const char *cpu_policy_path(int slot, const char *file) {
    static char buf[4][128];
    static int idx = 0;
    idx = (idx + 1) & 3;
    if (g_cpu_policy_ids[slot] < 0) { buf[idx][0] =  0;    return buf[idx]; }
    snprintf(buf[idx], sizeof(buf[idx]),
             "/sys/devices/system/cpu/cpufreq/policy%d/%s",
             g_cpu_policy_ids[slot], file);
    return buf[idx];
}

static void metrics_read_cpu(asb_cpu_t *c) {
    cpu_topology_discover();

    /* loadavg */
    char buf[64] = {0};
    sysfs_read_str(PATH_LOADAVG, buf, sizeof(buf));
    sscanf(buf, "%f %f", &c->load1, &c->load5);

    /* per-policy freq — используем auto-discovered topology */
    const char *cur_paths[3] = {
        cpu_policy_path(0, "scaling_cur_freq"),
        cpu_policy_path(1, "scaling_cur_freq"),
        (g_cpu_policy_ids[2] >= 0) ? cpu_policy_path(2, "scaling_cur_freq") : "",
    };
    const char *max_paths[3] = {
        cpu_policy_path(0, "scaling_max_freq"),
        cpu_policy_path(1, "scaling_max_freq"),
        (g_cpu_policy_ids[2] >= 0) ? cpu_policy_path(2, "scaling_max_freq") : "",
    };
    for (int i = 0; i < 3; i++) {
        int v = sysfs_read_int(cur_paths[i], 0);
        c->cur_freq[i] = v / 1000; /* kHz → MHz */
        v = sysfs_read_int(max_paths[i], 0);
        c->max_freq[i] = v / 1000;
    }
}

/* ─── Thermal ───────────────────────────────────────────────── */
/*
 * Ищем нужные thermal zones один раз при старте.
 * Критерий: type содержит "cpu-1-1" или "cpuss" → CPU кластер.
 */
static int g_thermal_cpu_zone  = -1;
static int g_thermal_skin_zone = -1;

static void thermal_discover(void) {
    char path[128], type[64];
    for (int z = 0; z < THERMAL_MAX_ZONES; z++) {
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/type", z);
        if (sysfs_read_str(path, type, sizeof(type)) < 0) break;
        if (strstr(type, "cpu-1-1") || strstr(type, "cpuss-0") ||
            strstr(type, "cpu-1-4")) {
            if (g_thermal_cpu_zone < 0) g_thermal_cpu_zone = z;
        }
        if (strstr(type, "skin") || strstr(type, "back-therm")) {
            if (g_thermal_skin_zone < 0) g_thermal_skin_zone = z;
        }
    }
}

static void metrics_read_thermal(asb_thermal_t *t) {
    char path[128];
    t->cpu_max_c  = 0;
    t->gpu_temp_c = 0;
    t->skin_temp_c = 0;
    t->throttling  = 0;

    if (g_thermal_cpu_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_zone);
        int v = sysfs_read_int(path, 0);
        /* Android thermal: обычно в миллиградусах (38000=38°C).
         * Некоторые ядра дают напрямую в °C (38=38°C).
         * Эвристика: если > 200 → миллиградусы, иначе уже °C. */
        t->cpu_max_c = (v > 200) ? (v / 1000) : v;
        if (t->cpu_max_c > 42) t->throttling = 1;
    }
    if (g_thermal_skin_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_skin_zone);
        t->skin_temp_c = sysfs_read_int(path, 0) / 1000;
    }
}

/* ─── Screen ────────────────────────────────────────────────── */
static int metrics_screen_on(void) {
    /* OxygenOS sysfs — самый быстрый способ (~5μs) */
    const char *paths[] = { PATH_SCREEN_STATUS, PATH_SCREEN_STATUS2, NULL };
    for (int i = 0; paths[i]; i++) {
        int v = sysfs_read_int(paths[i], -1);
        if (v == 1) return 1;
        if (v == 0) return 0;
    }
    /* Fallback: backlight > 0 */
    int bl = sysfs_read_int(PATH_BACKLIGHT, -1);
    if (bl > 0) return 1;
    if (bl == 0) return 0;
    return 1; /* unknown → assume ON (safe) */
}

/* ─── Network ──────────────────────────────────────────────── */
static long g_wlan_tx_prev = 0, g_wlan_rx_prev = 0;
static struct timespec g_wlan_ts_prev = {0};

static void metrics_read_network(asb_misc_t *m, const struct timespec *now) {
    long tx = sysfs_read_long(PATH_WLAN_TX, 0);
    long rx = sysfs_read_long(PATH_WLAN_RX, 0);
    if (g_wlan_ts_prev.tv_sec > 0) {
        double dt = (now->tv_sec - g_wlan_ts_prev.tv_sec) +
                    (now->tv_nsec - g_wlan_ts_prev.tv_nsec) * 1e-9;
        if (dt > 0.1) {
            m->wlan_tx_bps = (long)((tx - g_wlan_tx_prev) / dt);
            m->wlan_rx_bps = (long)((rx - g_wlan_rx_prev) / dt);
        }
    }
    g_wlan_tx_prev = tx;
    g_wlan_rx_prev = rx;
    g_wlan_ts_prev = *now;
}

/* ─── Full snapshot ─────────────────────────────────────────── */
static void metrics_read_all(asb_metrics_t *m) {
    clock_gettime(CLOCK_MONOTONIC, &m->ts);
    metrics_read_battery(&m->bat);
    metrics_read_gpu(&m->gpu);
    metrics_read_cpu(&m->cpu);
    metrics_read_thermal(&m->therm);
    m->misc.screen_on = metrics_screen_on();
    metrics_read_network(&m->misc, &m->ts);
}
