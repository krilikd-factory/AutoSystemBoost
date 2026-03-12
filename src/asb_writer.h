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
static const char *cpu_max_paths[3] = {
    "/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq",
    "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq",
    "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq",
};
static const char *cpu_min_paths[3] = {
    "/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq",
    "/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq",
    "/sys/devices/system/cpu/cpufreq/policy7/scaling_min_freq",
};

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
static int writer_apply_caps(const asb_profile_caps_t *caps, int force) {
    int writes = 0;

    /* CPU max freq */
    for (int i = 0; i < 3; i++) {
        if (force || caps->cpu_max[i] != g_wcache.cpu_max[i]) {
            if (sysfs_write_int(cpu_max_paths[i], caps->cpu_max[i]) == 0) {
                g_wcache.cpu_max[i] = caps->cpu_max[i];
                writes++;
            }
        }
    }
    /* CPU min freq */
    for (int i = 0; i < 3; i++) {
        if (force || caps->cpu_min[i] != g_wcache.cpu_min[i]) {
            if (sysfs_write_int(cpu_min_paths[i], caps->cpu_min[i]) == 0) {
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
    for (int i = 0; i < 3; i++) {
        g_wcache.cpu_max[i] = sysfs_read_int(cpu_max_paths[i], 0);
        g_wcache.cpu_min[i] = sysfs_read_int(cpu_min_paths[i], 0);
    }
    g_wcache.initialized = 1;
}
