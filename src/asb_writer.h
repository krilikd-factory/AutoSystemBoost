#pragma once
/*
 * asb_writer.h — Запись параметров в sysfs/procfs
 *
 * Прямые open/write без fork, без sh, без alloc.
 * Пишет только если значение изменилось (кэш предыдущего значения).
 * Пакетная запись: все изменения за один цикл.
 */

#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include "asb_fsm.h"

/* ─── Low-level write ───────────────────────────────────────── */
static inline int sysfs_write_int(const char *path, int val) {
    char buf[24];
    int len = snprintf(buf, sizeof(buf), "%d\n", val);
    int fd  = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int r = write(fd, buf, len);
    close(fd);
    return (r == len) ? 0 : -1;
}

static inline int sysfs_write_long(const char *path, long val) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%ld\n", val);
    int fd  = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int r = write(fd, buf, len);
    close(fd);
    return (r == len) ? 0 : -1;
}

/* ─── CPU policy paths ──────────────────────────────────────── */
/* CPU frequency paths строятся динамически через cpu_policy_path()
 * из asb_metrics.h. Статические массивы больше не нужны. */
static char g_cpu_max_paths[3][128];
static char g_cpu_min_paths[3][128];
static int  g_writer_paths_ready = 0;

static void writer_init_paths(void) {
    if (g_writer_paths_ready) return;
    cpu_topology_discover(); /* из asb_metrics.h */
    for (int i = 0; i < 3; i++) {
        if (g_cpu_policy_ids[i] >= 0) {
            snprintf(g_cpu_max_paths[i], sizeof(g_cpu_max_paths[i]),
                "/sys/devices/system/cpu/cpufreq/policy%d/scaling_max_freq",
                g_cpu_policy_ids[i]);
            snprintf(g_cpu_min_paths[i], sizeof(g_cpu_min_paths[i]),
                "/sys/devices/system/cpu/cpufreq/policy%d/scaling_min_freq",
                g_cpu_policy_ids[i]);
        } else {
            g_cpu_max_paths[i][0] = '\0';
            g_cpu_min_paths[i][0] = '\0';
        }
    }
    g_writer_paths_ready = 1;
}

/* GPU devfreq */
#define GPU_DEVFREQ_BASE "/sys/class/kgsl/kgsl-3d0/devfreq"

/* WALT */
#define WALT_RAVG_PATH  "/proc/sys/walt/sched_ravg_window_nr_ticks"
#define WALT_IDLE_PATH  "/proc/sys/walt/sched_idle_enough"

/* uclamp */
#define UCLAMP_TOP_MAX  "/dev/cpuctl/top-app/cpu.uclamp.max"
#define UCLAMP_BG_MAX   "/dev/cpuctl/background/cpu.uclamp.max"
#define UCLAMP_SYBG_MAX "/dev/cpuctl/system-background/cpu.uclamp.max"

/* ─── Cache (чтобы не писать одно и то же дважды) ──────────── */
typedef struct {
    int cpu_max[3];
    int cpu_min[3];
    int gpu_max_pct;
    int gpu_min_pct;
    int ravg_ticks;
    int idle_enough;
    int uclamp_top_max;
    int uclamp_bg_max;
    long gpu_hw_max_freq;   /* кэш hardware max freq GPU */
    int  initialized;
} asb_writer_cache_t;

static asb_writer_cache_t g_wcache = {0};

static long writer_gpu_hw_max(void) {
    if (g_wcache.gpu_hw_max_freq > 0) return g_wcache.gpu_hw_max_freq;
    char buf[32] = {0};
    int fd = open(GPU_DEVFREQ_BASE "/available_frequencies", O_RDONLY | O_CLOEXEC);
    if (fd < 0) { g_wcache.gpu_hw_max_freq = 1000000000L; return g_wcache.gpu_hw_max_freq; }
    char abuf[512] = {0};
    read(fd, abuf, sizeof(abuf)-1);
    close(fd);
    /* Частоты разделены пробелом, берём последнюю (max) */
    long max = 0, v;
    char *p = abuf;
    while (*p) {
        v = strtol(p, &p, 10);
        if (v > max) max = v;
        while (*p == ' ' || *p == '\n') p++;
    }
    g_wcache.gpu_hw_max_freq = max > 0 ? max : 1000000000L;
    return g_wcache.gpu_hw_max_freq;
}

/* ─── Write caps ────────────────────────────────────────────── */
/*
 * Применяет caps из FSM в sysfs.
 * Пишет только изменившиеся значения.
 * force=1: писать всё независимо от кэша (при смене профиля).
 */
/* ─── msm_performance kernel interface ─────────────────────────────
 * /sys/kernel/msm_performance/parameters/cpu_max_freq принимает
 * строку вида "0:freq 1:freq ... 7:freq" и применяется на уровне
 * ядра ДО vendor perf HAL. Это более надёжный путь.
 * Формат: "cpu:kHz" через пробел для каждого CPU в кластере.
 * Если интерфейс недоступен — fallback на обычный cpufreq write.
 */
#define PATH_MSM_PERF_CPU_MAX "/sys/kernel/msm_performance/parameters/cpu_max_freq"
#define PATH_MSM_PERF_CPU_MIN "/sys/kernel/msm_performance/parameters/cpu_min_freq"

static int g_msm_perf_available = -1; /* -1=не проверено, 0=нет, 1=да */

static int msm_perf_check(void) {
    if (g_msm_perf_available >= 0) return g_msm_perf_available;
    int fd = open(PATH_MSM_PERF_CPU_MAX, O_WRONLY | O_CLOEXEC);
    if (fd >= 0) { close(fd); g_msm_perf_available = 1; return 1; }
    g_msm_perf_available = 0;
    return 0;
}

/* Записывает max freq для кластера через msm_performance interface.
 * policy_id: номер первого CPU в кластере (0 или 6).
 * n_cpus: количество CPU в кластере (policy0=6 cpus, policy6=2 cpus).
 * freq_khz: целевая частота в кHz.
 */
static int msm_perf_write_cluster_max(int first_cpu, int n_cpus, int freq_khz) {
    if (!msm_perf_check()) return -1;
    char buf[128] = {0};
    int pos = 0;
    for (int c = first_cpu; c < first_cpu + n_cpus && pos < 120; c++) {
        pos += snprintf(buf + pos, sizeof(buf) - pos,
                        "%s%d:%d", (c == first_cpu ? "" : " "), c, freq_khz);
    }
    int fd = open(PATH_MSM_PERF_CPU_MAX, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t r = write(fd, buf, strlen(buf));
    close(fd);
    return (r > 0) ? 0 : -1;
}

/* Таблица: slot → (first_cpu, n_cpus) для OnePlus 15 layout */
static const int g_cluster_first_cpu[3] = {0, 6, -1};
static const int g_cluster_n_cpus[3]   = {6, 2,  0};

static int writer_apply_caps(const asb_profile_caps_t *caps, int force) {
    int writes = 0;
    writer_init_paths(); /* гарантируем что paths инициализированы */

    /* CPU max freq */
    for (int i = 0; i < 3; i++) {
        if (!g_cpu_max_paths[i][0]) continue; /* policy не существует */
        if (force || caps->cpu_max[i] != g_wcache.cpu_max[i]) {
            int ok = 0;
            /* Попытка 1: msm_performance kernel interface (обходит perf HAL) */
            if (g_cluster_first_cpu[i] >= 0 && caps->cpu_max[i] > 0) {
                if (msm_perf_write_cluster_max(g_cluster_first_cpu[i],
                                               g_cluster_n_cpus[i],
                                               caps->cpu_max[i]) == 0) {
                    ok = 1;
                }
            }
            /* Попытка 2: обычный cpufreq (может быть перетёрт perf HAL) */
            if (sysfs_write_int(g_cpu_max_paths[i], caps->cpu_max[i]) == 0) {
                ok = 1;
            }
            if (ok) {
                g_wcache.cpu_max[i] = caps->cpu_max[i];
                writes++;
            } else {
                FILE *ef = fopen("/dev/.asb/write_errors", "a");
                if (ef) {
                    fprintf(ef, "FAIL cpu_max[%d]=%s val=%d\n",
                            i, g_cpu_max_paths[i], caps->cpu_max[i]);
                    fclose(ef);
                }
            }
        }
    }
    /* CPU min freq */
    for (int i = 0; i < 3; i++) {
        if (!g_cpu_min_paths[i][0]) continue; /* policy не существует */
        if (force || caps->cpu_min[i] != g_wcache.cpu_min[i]) {
            if (sysfs_write_int(g_cpu_min_paths[i], caps->cpu_min[i]) == 0) {
                g_wcache.cpu_min[i] = caps->cpu_min[i];
                writes++;
            }
        }
    }

    /* GPU */
    long hw_max = writer_gpu_hw_max();
    long gmax = hw_max * caps->gpu_max_pct / 100;
    long gmin = hw_max * caps->gpu_min_pct / 100;

    if (force || caps->gpu_max_pct != g_wcache.gpu_max_pct) {
        sysfs_write_long(GPU_DEVFREQ_BASE "/max_freq", gmax);
        g_wcache.gpu_max_pct = caps->gpu_max_pct;
        writes++;
    }
    if (force || caps->gpu_min_pct != g_wcache.gpu_min_pct) {
        sysfs_write_long(GPU_DEVFREQ_BASE "/min_freq", gmin);
        g_wcache.gpu_min_pct = caps->gpu_min_pct;
        writes++;
    }

    /* WALT */
    if (force || caps->ravg_ticks != g_wcache.ravg_ticks) {
        sysfs_write_int(WALT_RAVG_PATH, caps->ravg_ticks);
        g_wcache.ravg_ticks = caps->ravg_ticks;
        writes++;
    }
    if (force || caps->idle_enough != g_wcache.idle_enough) {
        sysfs_write_int(WALT_IDLE_PATH, caps->idle_enough);
        g_wcache.idle_enough = caps->idle_enough;
        writes++;
    }

    /* uclamp */
    if (force || caps->uclamp_top_max != g_wcache.uclamp_top_max) {
        sysfs_write_int(UCLAMP_TOP_MAX, caps->uclamp_top_max);
        g_wcache.uclamp_top_max = caps->uclamp_top_max;
        writes++;
    }
    if (force || caps->uclamp_bg_max != g_wcache.uclamp_bg_max) {
        sysfs_write_int(UCLAMP_BG_MAX,   caps->uclamp_bg_max);
        sysfs_write_int(UCLAMP_SYBG_MAX, caps->uclamp_bg_max);
        g_wcache.uclamp_bg_max = caps->uclamp_bg_max;
        writes++;
    }

    return writes;
}

/*
 * Инициализация кэша: читаем текущие значения из sysfs
 * чтобы первый цикл не писал всё подряд без нужды.
 */
static void writer_init_cache(void) {
    extern int sysfs_read_int(const char *, int);
    writer_init_paths(); /* гарантируем динамические пути */
    for (int i = 0; i < 3; i++) {
        if (!g_cpu_max_paths[i][0]) { g_wcache.cpu_max[i] = 0; continue; }
        g_wcache.cpu_max[i] = sysfs_read_int(g_cpu_max_paths[i], 0);
        g_wcache.cpu_min[i] = sysfs_read_int(g_cpu_min_paths[i], 0);
    }
    g_wcache.initialized = 1;
}
