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

/* V39: GPU control on Qualcomm KGSL uses POWER LEVELS, not Hz values.
 *
 * On SM8850 (and most modern Qualcomm SoCs) the KGSL driver does NOT expose
 * writable /max_freq nodes. The control interface is:
 *   /sys/class/kgsl/kgsl-3d0/max_pwrlevel  — integer 0..N-1 (0=HIGHEST freq)
 *   /sys/class/kgsl/kgsl-3d0/min_pwrlevel  — integer 0..N-1 (N-1=LOWEST freq)
 *   /sys/class/kgsl/kgsl-3d0/num_pwrlevels — read: count of levels
 *   /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies — freq list (desc order)
 *
 * IMPORTANT: Power levels are INVERTED — 0 = maximum frequency, N-1 = minimum.
 * Writing max_pwrlevel=2 means "cannot go to level 0 or 1" i.e. freq capped.
 *
 * r5's kludge (open(O_WRONLY)-probe on max_gpuclk/max_freq) on SM8850 picked
 * max_gpuclk which opens writable but EINVAL's actual writes (it's a status
 * node). Result: 18 silent FAIL lines in write_errors during HEAVY session.
 *
 * This rewrite:
 *   1. Skip Hz-path candidates (max_freq nodes) since they don't exist on this SoC
 *   2. Use kgsl /max_pwrlevel+/min_pwrlevel directly if present
 *   3. Fall back to /devfreq/max_freq only if pwrlevel interface absent
 *   4. Translate gpu_max_pct into the closest pwrlevel by scanning the freq table
 */

#define GPU_PATH_CANDIDATES_MAX 6
static char g_gpu_max_path[160]      = {0};   /* either pwrlevel or max_freq */
static char g_gpu_min_path[160]      = {0};
static char g_gpu_avail_path[160]    = {0};
static int  g_gpu_paths_ready        = 0;
static int  g_gpu_uses_pwrlevel      = 0;     /* 1 = integer pwrlevel; 0 = Hz */
static int  g_gpu_num_pwrlevels      = 0;     /* count of levels if pwrlevel mode */
static long g_gpu_freq_table[32]     = {0};   /* frequencies in descending order */
static int  g_gpu_freq_table_len     = 0;

/* V39: thermal_pwrlevel monitoring infrastructure.
 *
 * On Qualcomm KGSL, /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel is a vendor cap
 * that the kernel raises when the GPU gets thermally stressed. It works as an
 * additional ceiling on top of our max_pwrlevel write — effective level is
 * max(max_pwrlevel, thermal_pwrlevel). When thermal_pwrlevel > our max_pwrlevel,
 * the kernel is overriding our cap, which is a useful signal for FSM.
 *
 * Cost-conscious design (per user request — "must not eat battery"):
 *   - fd cached at discovery (no open/close per read)
 *   - pread() instead of seek+read (one syscall instead of two)
 *   - skip read entirely on screen-off
 *   - skip in DEEP_IDLE (thermal does not change without load)
 *   - in LIGHT_IDLE/MODERATE: read every 3rd tick (configurable via bat_thermal_pwrlevel_div)
 *   - in HEAVY/SUSTAINED/GAMING: read every tick (thermal can change rapidly under load)
 *
 * Estimated cost: ~5,000 reads/day = 0.05s CPU/day = below noise floor.
 */
static char g_gpu_thermal_pwrlevel_path[160] = {0};
static int  g_gpu_thermal_pwrlevel_fd        = -1;   /* cached read fd, -1 if absent */
static int  g_gpu_thermal_pwrlevel_last      = -1;   /* last read value */

/* Audit counters — exposed in status JSON / governor.log to validate cost claim */
static unsigned long g_thermal_pl_reads_count   = 0;  /* total successful reads */
static unsigned long g_thermal_pl_skip_count    = 0;  /* gated skips */
static unsigned long g_thermal_pl_us_total      = 0;  /* total microseconds spent reading */

static int gpu_try_readable(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

/* Probe whether a path accepts writes (not just O_WRONLY open).
 * Writes current value back to itself — non-destructive. Returns 1 if write
 * succeeded, 0 if write failed with any error (EINVAL, EACCES, etc.). */
static int gpu_try_probe_write(const char *path) {
    int rfd = open(path, O_RDONLY | O_CLOEXEC);
    if (rfd < 0) return 0;
    char buf[64] = {0};
    ssize_t n = read(rfd, buf, sizeof(buf) - 1);
    close(rfd);
    if (n <= 0) return 0;

    int wfd = open(path, O_WRONLY | O_CLOEXEC);
    if (wfd < 0) return 0;
    /* Strip trailing newline; write exactly what we read back. */
    size_t len = (size_t)n;
    while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r' || buf[len-1] == ' '))
        len--;
    ssize_t w = write(wfd, buf, len);
    close(wfd);
    return (w == (ssize_t)len) ? 1 : 0;
}

static void gpu_read_freq_table(void) {
    if (!g_gpu_avail_path[0]) return;
    int fd = open(g_gpu_avail_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    char abuf[512] = {0};
    ssize_t _rd = read(fd, abuf, sizeof(abuf) - 1);
    (void)_rd;
    close(fd);

    /* Parse space-separated frequencies (Qualcomm format: descending order
     * "1100000000 1000000000 900000000 ..."). Store in table. */
    char *p = abuf;
    int idx = 0;
    while (*p && idx < 32) {
        long v = strtol(p, &p, 10);
        if (v > 0) g_gpu_freq_table[idx++] = v;
        while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') p++;
    }
    g_gpu_freq_table_len = idx;

    /* Ensure descending: Qualcomm normally outputs descending but some
     * kernels sort ascending. Bubble-sort descending if needed. */
    for (int i = 0; i < g_gpu_freq_table_len - 1; i++) {
        for (int j = 0; j < g_gpu_freq_table_len - 1 - i; j++) {
            if (g_gpu_freq_table[j] < g_gpu_freq_table[j+1]) {
                long t = g_gpu_freq_table[j];
                g_gpu_freq_table[j] = g_gpu_freq_table[j+1];
                g_gpu_freq_table[j+1] = t;
            }
        }
    }
}

static void writer_discover_gpu_paths(void) {
    if (g_gpu_paths_ready) return;

    /* Prefer Hz-based max_freq nodes (traditional devfreq devices). */
    static const char *max_freq_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/max_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/max_freq",
        NULL
    };
    static const char *min_freq_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/min_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/min_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/min_freq",
        NULL
    };
    /* Fallback: KGSL-native pwrlevel interface (present on SM8850). */
    static const char *pwrlevel_max_path = "/sys/class/kgsl/kgsl-3d0/max_pwrlevel";
    static const char *pwrlevel_min_path = "/sys/class/kgsl/kgsl-3d0/min_pwrlevel";
    static const char *num_pwrlevels_path = "/sys/class/kgsl/kgsl-3d0/num_pwrlevels";

    static const char *avail_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/available_frequencies",
        "/sys/class/devfreq/3d00000.qcom,gpu/available_frequencies",
        "/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies",
        NULL
    };

    /* Try Hz path first; require actual write success, not just open. */
    for (int i = 0; max_freq_candidates[i]; i++) {
        if (gpu_try_probe_write(max_freq_candidates[i])) {
            snprintf(g_gpu_max_path, sizeof(g_gpu_max_path), "%s", max_freq_candidates[i]);
            g_gpu_uses_pwrlevel = 0;
            break;
        }
    }
    if (g_gpu_max_path[0]) {
        for (int i = 0; min_freq_candidates[i]; i++) {
            if (gpu_try_probe_write(min_freq_candidates[i])) {
                snprintf(g_gpu_min_path, sizeof(g_gpu_min_path), "%s", min_freq_candidates[i]);
                break;
            }
        }
    } else {
        /* No Hz control — try pwrlevel interface. */
        if (gpu_try_probe_write(pwrlevel_max_path)) {
            snprintf(g_gpu_max_path, sizeof(g_gpu_max_path), "%s", pwrlevel_max_path);
            g_gpu_uses_pwrlevel = 1;
            if (gpu_try_probe_write(pwrlevel_min_path)) {
                snprintf(g_gpu_min_path, sizeof(g_gpu_min_path), "%s", pwrlevel_min_path);
            }
            /* Read num_pwrlevels if available */
            int fd = open(num_pwrlevels_path, O_RDONLY | O_CLOEXEC);
            if (fd >= 0) {
                char nbuf[16] = {0};
                ssize_t _r = read(fd, nbuf, sizeof(nbuf) - 1);
                (void)_r;
                close(fd);
                g_gpu_num_pwrlevels = atoi(nbuf);
            }
        }
    }

    /* Available frequencies (read-only, used for hw_max + pwrlevel translation) */
    for (int i = 0; avail_candidates[i]; i++) {
        if (gpu_try_readable(avail_candidates[i])) {
            snprintf(g_gpu_avail_path, sizeof(g_gpu_avail_path), "%s", avail_candidates[i]);
            break;
        }
    }

    /* V39: thermal_pwrlevel discovery — vendor thermal cap, read-only for us
     * but kernel writes to it dynamically. Cache fd to avoid open/close per read.
     * If the file doesn't exist, g_gpu_thermal_pwrlevel_fd stays -1 and reader
     * functions short-circuit. */
    static const char *thermal_pl_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/thermal_pwrlevel",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/thermal_pwrlevel",
        NULL
    };
    for (int i = 0; thermal_pl_candidates[i]; i++) {
        int fd = open(thermal_pl_candidates[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            snprintf(g_gpu_thermal_pwrlevel_path, sizeof(g_gpu_thermal_pwrlevel_path),
                     "%s", thermal_pl_candidates[i]);
            g_gpu_thermal_pwrlevel_fd = fd;
            break;
        }
    }

    /* Populate freq_table early — needed for pwrlevel translation */
    gpu_read_freq_table();

    /* Observability */
    FILE *lf = fopen("/dev/.asb/gpu_path_discovery", "w");
    if (lf) {
        fprintf(lf, "max=%s\nmin=%s\navail=%s\nthermal=%s\nmode=%s\nnum_pwrlevels=%d\nfreq_table_len=%d\n",
                g_gpu_max_path[0]   ? g_gpu_max_path   : "(none)",
                g_gpu_min_path[0]   ? g_gpu_min_path   : "(none)",
                g_gpu_avail_path[0] ? g_gpu_avail_path : "(none)",
                g_gpu_thermal_pwrlevel_path[0] ? g_gpu_thermal_pwrlevel_path : "(none)",
                g_gpu_uses_pwrlevel ? "pwrlevel" : "hz",
                g_gpu_num_pwrlevels,
                g_gpu_freq_table_len);
        for (int i = 0; i < g_gpu_freq_table_len; i++)
            fprintf(lf, "freq[%d]=%ld\n", i, g_gpu_freq_table[i]);
        fclose(lf);
    }

    g_gpu_paths_ready = 1;
}

/* V39: read thermal_pwrlevel using cached fd + pread (single syscall).
 * Returns level or -1 if unavailable. Includes audit timing.
 *
 * Three levels of caution as discussed:
 *   1. Skip if screen off (thermal doesn't matter when GPU is idle)
 *   2. Skip in DEEP_IDLE (thermal doesn't change without load)
 *   3. Skip every 2nd/3rd tick in LIGHT_IDLE/MODERATE (configurable)
 * Caller is responsible for the gating; this function just performs the read.
 */
static int gpu_read_thermal_pwrlevel(void) {
    if (g_gpu_thermal_pwrlevel_fd < 0) return -1;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    char buf[16] = {0};
    ssize_t n = pread(g_gpu_thermal_pwrlevel_fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) return g_gpu_thermal_pwrlevel_last;  /* keep last known */

    clock_gettime(CLOCK_MONOTONIC, &t1);
    long elapsed_us = (t1.tv_sec - t0.tv_sec) * 1000000L
                    + (t1.tv_nsec - t0.tv_nsec) / 1000L;
    g_thermal_pl_us_total += (unsigned long)elapsed_us;
    g_thermal_pl_reads_count++;

    int v = atoi(buf);
    if (v >= 0 && v < 32) g_gpu_thermal_pwrlevel_last = v;
    return g_gpu_thermal_pwrlevel_last;
}

static int gpu_thermal_pwrlevel_last(void) {
    return g_gpu_thermal_pwrlevel_last;
}

static void gpu_thermal_pl_record_skip(void) {
    g_thermal_pl_skip_count++;
}

static int gpu_thermal_pl_audit_path(char *out, size_t outlen) {
    return snprintf(out, outlen,
        "{\"reads\":%lu,\"skips\":%lu,\"total_us\":%lu,\"last_level\":%d,\"path\":\"%s\"}",
        g_thermal_pl_reads_count,
        g_thermal_pl_skip_count,
        g_thermal_pl_us_total,
        g_gpu_thermal_pwrlevel_last,
        g_gpu_thermal_pwrlevel_path[0] ? g_gpu_thermal_pwrlevel_path : "(none)");
}

/* Translate a target Hz into a pwrlevel index (0 = highest freq, larger = lower).
 * Returns the lowest index (== highest freq) that is <= target_hz. */
static int gpu_hz_to_pwrlevel_max(long target_hz) {
    if (g_gpu_freq_table_len <= 0) return 0;
    for (int i = 0; i < g_gpu_freq_table_len; i++) {
        if (g_gpu_freq_table[i] <= target_hz) return i;
    }
    /* All frequencies exceed target — clamp to lowest (last index) */
    return g_gpu_freq_table_len - 1;
}

/* For min: return the highest index (== lowest freq) that is >= target_hz.
 * This becomes the floor of allowed frequencies. */
static int gpu_hz_to_pwrlevel_min(long target_hz) {
    if (g_gpu_freq_table_len <= 0) return 0;
    for (int i = g_gpu_freq_table_len - 1; i >= 0; i--) {
        if (g_gpu_freq_table[i] >= target_hz) return i;
    }
    return 0;
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
    /* Freq table already populated by discovery. Index 0 = highest freq. */
    if (g_gpu_freq_table_len > 0) {
        g_wcache.gpu_hw_max_freq = g_gpu_freq_table[0];
        return g_wcache.gpu_hw_max_freq;
    }
    g_wcache.gpu_hw_max_freq = 1000000000L;
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
            if (g_gpu_uses_pwrlevel) {
                /* Translate target Hz into pwrlevel index. max_pwrlevel is the
                 * HIGHEST-frequency level we're allowed to use; larger index = lower freq.
                 * So for a max Hz target, find the smallest index whose freq <= target. */
                int pl = gpu_hz_to_pwrlevel_max(gmax);
                gpu_ok = (sysfs_write_int(g_gpu_max_path, pl) == 0);
            } else {
                gpu_ok = (sysfs_write_long(g_gpu_max_path, gmax) == 0);
            }
        }
        if (!gpu_ok) {
            /* Log once per transition — helps diagnose stale paths without flooding */
            FILE *ef = fopen("/dev/.asb/write_errors", "a");
            if (ef) {
                fprintf(ef, "FAIL gpu_max path=%s val=%ld mode=%s discovered=%d\n",
                        g_gpu_max_path[0] ? g_gpu_max_path : "(none)", gmax,
                        g_gpu_uses_pwrlevel ? "pwrlevel" : "hz",
                        g_gpu_paths_ready);
                fclose(ef);
            }
        }
        g_wcache.gpu_max_pct = caps->gpu_max_pct;
        writes++;
    }
    if (force || caps->gpu_min_pct != g_wcache.gpu_min_pct) {
        if (g_gpu_min_path[0]) {
            if (g_gpu_uses_pwrlevel) {
                /* min_pwrlevel is the LOWEST-frequency level allowed; larger index = lower freq.
                 * For a min Hz target, find the largest index whose freq >= target. */
                int pl = gpu_hz_to_pwrlevel_min(gmin);
                sysfs_write_int(g_gpu_min_path, pl);
            } else {
                sysfs_write_long(g_gpu_min_path, gmin);
            }
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
