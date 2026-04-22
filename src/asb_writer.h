#pragma once

#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include "asb_fsm.h"
#include "asb_config.h"

extern asb_runtime_config_t g_asb_cfg;
#include <string.h>
#include "asb_fsm.h"

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

static char g_cpu_max_paths[3][128];
static char g_cpu_min_paths[3][128];
static int  g_writer_paths_ready = 0;

static void writer_init_paths(void) {
    if (g_writer_paths_ready) return;
    cpu_topology_discover();
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

#define GPU_DEVFREQ_BASE "/sys/class/kgsl/kgsl-3d0/devfreq"

/* V39r5: GPU sysfs path discovery — kgsl-3d0/devfreq/max_freq does not exist
 * on all Qualcomm devices (confirmed absent on OP15/SM8850). We probe known
 * paths at startup, cache whichever is writable, and log which one we use.
 *
 * Write order matters: newer GKI devices expose the writable node under
 * /sys/class/devfreq/<bus-id>.qcom,gpu/max_freq, older ones under kgsl-3d0/devfreq,
 * some non-devfreq boards only have /sys/class/kgsl/kgsl-3d0/max_gpuclk.
 */
#define GPU_PATH_CANDIDATES_MAX 6
static char g_gpu_max_path[160]   = {0};
static char g_gpu_min_path[160]   = {0};
static char g_gpu_avail_path[160] = {0};
static int  g_gpu_paths_ready     = 0;

static int gpu_try_writable(const char *path) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

static int gpu_try_readable(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

static void writer_discover_gpu_paths(void) {
    if (g_gpu_paths_ready) return;

    /* Candidates for MAX freq node, most-preferred first */
    static const char *max_candidates[GPU_PATH_CANDIDATES_MAX] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/max_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/max_freq",
        "/sys/class/kgsl/kgsl-3d0/max_gpuclk",
        "/sys/devices/platform/soc/3d00000.qcom,kgsl-3d0/devfreq/3d00000.qcom,kgsl-3d0/max_freq",
        NULL
    };
    static const char *min_candidates[GPU_PATH_CANDIDATES_MAX] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/min_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/min_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/min_freq",
        "/sys/class/kgsl/kgsl-3d0/min_pwrlevel",
        "/sys/devices/platform/soc/3d00000.qcom,kgsl-3d0/devfreq/3d00000.qcom,kgsl-3d0/min_freq",
        NULL
    };
    static const char *avail_candidates[GPU_PATH_CANDIDATES_MAX] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/available_frequencies",
        "/sys/class/devfreq/3d00000.qcom,gpu/available_frequencies",
        "/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies",
        NULL
    };

    for (int i = 0; max_candidates[i]; i++) {
        if (gpu_try_writable(max_candidates[i])) {
            snprintf(g_gpu_max_path, sizeof(g_gpu_max_path), "%s", max_candidates[i]);
            break;
        }
    }
    for (int i = 0; min_candidates[i]; i++) {
        if (gpu_try_writable(min_candidates[i])) {
            snprintf(g_gpu_min_path, sizeof(g_gpu_min_path), "%s", min_candidates[i]);
            break;
        }
    }
    for (int i = 0; avail_candidates[i]; i++) {
        if (gpu_try_readable(avail_candidates[i])) {
            snprintf(g_gpu_avail_path, sizeof(g_gpu_avail_path), "%s", avail_candidates[i]);
            break;
        }
    }

    /* Observability: write discovery result for asb_session_report.py */
    FILE *lf = fopen("/dev/.asb/gpu_path_discovery", "w");
    if (lf) {
        fprintf(lf, "max=%s\nmin=%s\navail=%s\n",
                g_gpu_max_path[0]   ? g_gpu_max_path   : "(none)",
                g_gpu_min_path[0]   ? g_gpu_min_path   : "(none)",
                g_gpu_avail_path[0] ? g_gpu_avail_path : "(none)");
        fclose(lf);
    }

    g_gpu_paths_ready = 1;
}

#define WALT_RAVG_PATH  "/proc/sys/walt/sched_ravg_window_nr_ticks"
#define WALT_IDLE_PATH  "/proc/sys/walt/sched_idle_enough"

#define UCLAMP_TOP_MAX  "/dev/cpuctl/top-app/cpu.uclamp.max"
#define UCLAMP_BG_MAX   "/dev/cpuctl/background/cpu.uclamp.max"
#define UCLAMP_SYBG_MAX "/dev/cpuctl/system-background/cpu.uclamp.max"

typedef struct {
    int cpu_max[3];
    int cpu_min[3];
    int gpu_max_pct;
    int gpu_min_pct;
    int ravg_ticks;
    int idle_enough;
    int uclamp_top_max;
    int uclamp_bg_max;
    long gpu_hw_max_freq;
    int  initialized;
} asb_writer_cache_t;

static asb_writer_cache_t g_wcache = {0};

static long writer_gpu_hw_max(void) {
    if (g_wcache.gpu_hw_max_freq > 0) return g_wcache.gpu_hw_max_freq;
    writer_discover_gpu_paths();
    if (!g_gpu_avail_path[0]) { g_wcache.gpu_hw_max_freq = 1000000000L; return g_wcache.gpu_hw_max_freq; }
    int fd = open(g_gpu_avail_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { g_wcache.gpu_hw_max_freq = 1000000000L; return g_wcache.gpu_hw_max_freq; }
    char abuf[512] = {0};
    ssize_t _rd = read(fd, abuf, sizeof(abuf)-1);
    (void)_rd;
    close(fd);
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

#define PATH_MSM_PERF_CPU_MAX "/sys/kernel/msm_performance/parameters/cpu_max_freq"
#define PATH_MSM_PERF_CPU_MIN "/sys/kernel/msm_performance/parameters/cpu_min_freq"

static int g_msm_perf_available = -1;

static int msm_perf_check(void) {
    if (g_msm_perf_available >= 0) return g_msm_perf_available;
    int fd = open(PATH_MSM_PERF_CPU_MAX, O_WRONLY | O_CLOEXEC);
    if (fd >= 0) { close(fd); g_msm_perf_available = 1; return 1; }
    g_msm_perf_available = 0;
    return 0;
}

static int g_msm_cur_max[2] = {0, 0};

static int msm_perf_write_all_max(int c0_freq, int c1_freq) {
    if (!msm_perf_check()) return -1;
    if (c0_freq > 0) g_msm_cur_max[0] = c0_freq;
    if (c1_freq > 0) g_msm_cur_max[1] = c1_freq;
    if (!g_msm_cur_max[0] || !g_msm_cur_max[1]) return -1;
    char buf[256] = {0};
    int pos = 0;
    for (int c = 0; c <= 5; c++)
        pos += snprintf(buf+pos, sizeof(buf)-pos, "%d:%d ", c, g_msm_cur_max[0]);
    for (int c = 6; c <= 7; c++)
        pos += snprintf(buf+pos, sizeof(buf)-pos, "%d:%d ", c, g_msm_cur_max[1]);
    if (pos > 0) buf[pos-1] = 0;
    int fd = open(PATH_MSM_PERF_CPU_MAX, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t r = write(fd, buf, strlen(buf));
    close(fd);
    return (r > 0) ? 0 : -1;
}

static const int g_cluster_first_cpu[3] = {0, 6, -1};
static const int g_cluster_n_cpus[3]   = {6, 2,  0};

static int writer_apply_caps(const asb_profile_caps_t *caps, int force, asb_state_t state, int thermal_cap) {
    int writes = 0;
    writer_init_paths();

    {
        int c0_target = -1, c1_target = -1;
        int c0_changed = 0, c1_changed = 0;
        if (g_cpu_max_paths[0][0] && (force || caps->cpu_max[0] != g_wcache.cpu_max[0])) {
            c0_target = caps->cpu_max[0]; c0_changed = 1;
        }
        if (g_cpu_max_paths[1][0] && (force || caps->cpu_max[1] != g_wcache.cpu_max[1])) {
            c1_target = caps->cpu_max[1]; c1_changed = 1;
        }
        if (c0_changed || c1_changed) {
            int use_msm = msm_perf_check() &&
                          (!g_asb_cfg.msm_perf_boost_only ||
                           ((state == ASB_STATE_HEAVY || state == ASB_STATE_GAMING) && !thermal_cap));
            if (use_msm) {
                int msm_c0 = (c0_target > 0) ? c0_target : g_msm_cur_max[0];
                int msm_c1 = (c1_target > 0) ? c1_target : g_msm_cur_max[1];
                msm_perf_write_all_max(msm_c0, msm_c1);
            }
        }
        for (int i = 0; i < 3; i++) {
            if (!g_cpu_max_paths[i][0]) continue;
            if (force || caps->cpu_max[i] != g_wcache.cpu_max[i]) {
                if (caps->cpu_max[i] <= 0) continue;
                if (sysfs_write_int(g_cpu_max_paths[i], caps->cpu_max[i]) == 0) {
                    g_wcache.cpu_max[i] = caps->cpu_max[i];
                    writes++;
                } else {
                    FILE *ef = fopen("/dev/.asb/write_errors", "a");
                    if (ef) {
                        fprintf(ef, "FAIL cpu_max[%d]=%s val=%d\n",
                                i, g_cpu_max_paths[i], caps->cpu_max[i]);
                        fclose(ef);
                    }
                    if (c0_changed && i == 0) g_wcache.cpu_max[0] = caps->cpu_max[0];
                    if (c1_changed && i == 1) g_wcache.cpu_max[1] = caps->cpu_max[1];
                }
            }
        }
    }
    if (!thermal_cap) {
        for (int i = 0; i < 3; i++) {
            if (!g_cpu_min_paths[i][0]) continue;
            int want_min = caps->cpu_min[i];
            if (want_min <= 0) continue;
            int cur_max = sysfs_read_int(g_cpu_max_paths[i], 0);
            if (cur_max > 0 && want_min > cur_max)
                want_min = cur_max;
            if (force || want_min != g_wcache.cpu_min[i]) {
                if (sysfs_write_int(g_cpu_min_paths[i], want_min) == 0) {
                    g_wcache.cpu_min[i] = want_min;
                    writes++;
                }
            }
        }
    }

    writer_discover_gpu_paths();
    long hw_max = writer_gpu_hw_max();
    long gmax = hw_max * caps->gpu_max_pct / 100;
    long gmin = hw_max * caps->gpu_min_pct / 100;

    if (force || caps->gpu_max_pct != g_wcache.gpu_max_pct) {
        int gpu_ok = 0;
        if (g_gpu_max_path[0]) {
            gpu_ok = (sysfs_write_long(g_gpu_max_path, gmax) == 0);
        }
        if (!gpu_ok) {
            /* Log once per transition — helps diagnose stale paths without flooding */
            FILE *ef = fopen("/dev/.asb/write_errors", "a");
            if (ef) {
                fprintf(ef, "FAIL gpu_max path=%s val=%ld discovered=%d\n",
                        g_gpu_max_path[0] ? g_gpu_max_path : "(none)", gmax,
                        g_gpu_paths_ready);
                fclose(ef);
            }
        }
        g_wcache.gpu_max_pct = caps->gpu_max_pct;
        writes++;
    }
    if (force || caps->gpu_min_pct != g_wcache.gpu_min_pct) {
        if (g_gpu_min_path[0]) {
            sysfs_write_long(g_gpu_min_path, gmin);
        }
        g_wcache.gpu_min_pct = caps->gpu_min_pct;
        writes++;
    }

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

static void writer_init_cache(void) {
    writer_init_paths();
    for (int i = 0; i < 3; i++) {
        if (!g_cpu_max_paths[i][0]) { g_wcache.cpu_max[i] = 0; continue; }
        g_wcache.cpu_max[i] = sysfs_read_int(g_cpu_max_paths[i], 0);
        g_wcache.cpu_min[i] = sysfs_read_int(g_cpu_min_paths[i], 0);
    }
    g_wcache.initialized = 1;
}
