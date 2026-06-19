#pragma once

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <math.h>
#include "asb_config.h"
extern asb_runtime_config_t g_asb_cfg;

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

#define PATH_SCREEN_STATUS  "/sys/kernel/oplus_display/panel_power_status"
#define PATH_SCREEN_STATUS2 "/sys/kernel/oplus_display/disp_on_notify"
#define PATH_BACKLIGHT      "/sys/class/backlight/panel0-backlight/brightness"

#define PATH_CPU_POLICY0    "/sys/devices/system/cpu/cpufreq/policy0"
#define PATH_CPU_POLICY4    "/sys/devices/system/cpu/cpufreq/policy4"
#define PATH_CPU_POLICY6    "/sys/devices/system/cpu/cpufreq/policy6"
#define PATH_CPU_POLICY7    "/sys/devices/system/cpu/cpufreq/policy7"

#define PATH_CPU_POLICIES_DEFAULT "0,6"

#define THERMAL_BASE        "/sys/class/thermal"
#define THERMAL_MAX_ZONES   128

#define PATH_WALT_RAVG      "/proc/sys/walt/sched_ravg_window_nr_ticks"
#define PATH_WALT_IDLE      "/proc/sys/walt/sched_idle_enough"

#define PATH_WLAN_TX        "/sys/class/net/wlan0/statistics/tx_bytes"
#define PATH_WLAN_RX        "/sys/class/net/wlan0/statistics/rx_bytes"
static long sysfs_read_long(const char *path, long def);

static long rmnet_read_total(const char *direction) {
    /* direction = "tx_bytes" or "rx_bytes" */
    long total = 0;
    char path[128];
    const char *ifaces[] = {"rmnet_data0", "rmnet_data1", "rmnet_data2", "rmnet_ipa0", NULL};
    for (int i = 0; ifaces[i]; i++) {
        snprintf(path, sizeof(path), "/sys/class/net/%s/statistics/%s", ifaces[i], direction);
        long v = sysfs_read_long(path, 0);
        if (v > 0) total += v;
    }
    return total;
}

typedef struct {
    int     current_ua;
    int     voltage_uv;
    int     capacity_pct;
    int     temp_dC;
    int     charging;
    int     current_ma;
} asb_battery_t;

typedef struct {
    int     load_pct;
    long    cur_freq_hz;
    long    max_freq_hz;
} asb_gpu_t;

typedef struct {
    float   load1;
    float   load5;
    int     cur_freq[3];
    int     max_freq[3];
} asb_cpu_t;

typedef struct {
    int     cpu_max_c;
    int     gpu_temp_c;
    int     skin_temp_c;           /* literal shell (front/frame/back) */
    int     surface_hotspot_c;     /* hottest body-adjacent zone (sys-therm-6 etc) */
    int     board_temp_c;          /* explicit board_temp for long-gaming heat analysis */
    int     throttling;     /* real thermal: temp >= threshold */
    int     soft_clamp;     /* vendor advisory: headroom < soft_pct */
    int     hard_clamp;     /* vendor actionable: headroom < hard_pct */
    int     temp_valid;     /* 1=fresh read, 0=stale/skipped */
    int     temp_age_s;     /* seconds since last real thermal read */
    /* when temp_valid=0, this records WHY for diagnostic clarity.
     * Values: "ok", "no_zone", "read_fail", "stale", "raw_too_low", "init", "fb_used" */
    char    temp_invalid_reason[16];
    int     perf_cap_p0;    /* kernel-allowed max freq for policy0 (kHz) */
    int     perf_cap_p6;    /* kernel-allowed max freq for policy6 (kHz) */
    int     headroom_pct;   /* thermal headroom: 100=full, 0=fully throttled */
    int     headroom_valid; /* 1=real read, 0=skipped or failed */
    char    headroom_invalid_reason[16];  /* "ok","stuck_100","read_fail","no_iface" */
    int     used_fallback;  /* 1 if this tick used fallback CPU zone instead of primary */
    int     fallback_just_flipped; /* 1 for one tick when used_fallback state flips */
    /* GPU vendor thermal cap (KGSL pwrlevel). Larger value = lower freq.
     * 0/-1 = unavailable. Used as backstop signal for soft_clamp when
     * msm_performance is dead. */
    int     gpu_thermal_pwrlevel;
    int     gpu_thermal_pwrlevel_active;  /* 1 = vendor capping above our write */
} asb_thermal_t;

typedef struct {
    int     screen_on;
    long    wlan_tx_bps;
    long    wlan_rx_bps;
    /* radio-aware -- mobile data activity */
    long    rmnet_tx_bps;
    long    rmnet_rx_bps;
} asb_misc_t;

typedef struct {
    asb_battery_t   bat;
    asb_gpu_t       gpu;
    asb_cpu_t       cpu;
    asb_thermal_t   therm;
    asb_misc_t      misc;
    struct timespec ts;
} asb_metrics_t;

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
    if (n > 0) {
        out[n] = '\0';
        /* strip trailing newline/CR/space. sysfs text nodes almost
         * always end with '\n' which breaks JSON embedding downstream. */
        while (n > 0 && (out[n-1] == '\n' || out[n-1] == '\r' || out[n-1] == ' ')) {
            out[--n] = '\0';
        }
        return n;
    }
    return -1;
}

static const char *g_batt_current_paths[] = {
    "/sys/class/power_supply/battery/current_now",
    "/sys/class/power_supply/bms/current_now",
    "/sys/class/power_supply/Battery/current_now",
    NULL
};
static int g_batt_current_path_idx = -1;

static int metrics_find_batt_current_path(void) {
    if (g_batt_current_path_idx >= 0) return g_batt_current_path_idx;
    for (int i = 0; g_batt_current_paths[i]; i++) {
        int fd = open(g_batt_current_paths[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) { close(fd); g_batt_current_path_idx = i; return i; }
    }
    return -1;
}

static int g_batt_cur_unit = 0;
static int g_batt_cur_samples = 0;
static long g_batt_cur_peak = 0;

static int asb_batt_current_to_ma(long raw) {
    long a = labs(raw);
    if (g_batt_cur_unit == 0) {
        if (a > g_batt_cur_peak) g_batt_cur_peak = a;
        if (a >= 100000) g_batt_cur_unit = 1;
        else {
            g_batt_cur_samples++;
            if (g_batt_cur_samples >= 30 && g_batt_cur_peak > 0 &&
                g_batt_cur_peak < 50000) {
                g_batt_cur_unit = 2;
            }
        }
    }
    if (g_batt_cur_unit == 2) return (int)(a > 100000 ? 0 : a);
    return (int)(a / 1000);
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
    b->current_ma   = asb_batt_current_to_ma(b->current_ua);

    char st[16] = {0};
    sysfs_read_str(PATH_BATT_STATUS, st, sizeof(st));
    b->charging = (st[0] == 'C') ? 1 : 0;
}

static char g_metrics_gpu_freq_path[160]    = {0};
static char g_metrics_gpu_maxfreq_path[160] = {0};
static int  g_metrics_gpu_paths_ready       = 0;

static void metrics_discover_gpu_paths(void) {
    if (g_metrics_gpu_paths_ready) return;

    static const char *cur_freq_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/cur_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/cur_freq",
        "/sys/class/kgsl/kgsl-3d0/gpuclk",
        NULL
    };
    static const char *max_freq_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/max_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/max_freq",
        "/sys/class/kgsl/kgsl-3d0/max_gpuclk",
        NULL
    };

    for (int i = 0; cur_freq_candidates[i]; i++) {
        int fd = open(cur_freq_candidates[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            close(fd);
            snprintf(g_metrics_gpu_freq_path, sizeof(g_metrics_gpu_freq_path),
                     "%s", cur_freq_candidates[i]);
            break;
        }
    }
    for (int i = 0; max_freq_candidates[i]; i++) {
        int fd = open(max_freq_candidates[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            close(fd);
            snprintf(g_metrics_gpu_maxfreq_path, sizeof(g_metrics_gpu_maxfreq_path),
                     "%s", max_freq_candidates[i]);
            break;
        }
    }
    g_metrics_gpu_paths_ready = 1;
}

static void metrics_read_gpu(asb_gpu_t *g) {
    metrics_discover_gpu_paths();
    g->load_pct  = sysfs_read_int(PATH_GPU_LOAD, 0);
    g->cur_freq_hz = g_metrics_gpu_freq_path[0]
                     ? sysfs_read_long(g_metrics_gpu_freq_path, 0) : 0;
    g->max_freq_hz = g_metrics_gpu_maxfreq_path[0]
                     ? sysfs_read_long(g_metrics_gpu_maxfreq_path, 1000000000L)
                     : 1000000000L;
    if (g->max_freq_hz <= 0) g->max_freq_hz = 1000000000L;
}

static int g_cpu_policy_ids[3]   = {0, 6, -1};
/* Every physical cpufreq policy id discovered (OP12 has 4: 0,2,5,7), plus the
 * slot (0=little,1=big,2=prime) each one is governed by. Lets the writer apply
 * a slot's cap to ALL clusters that belong to it, not just the representative
 * one — without this, OP12's second big cluster (policy2 or policy5) stays
 * unmanaged and pinned low in battery mode. */
static int g_cpu_all_ids[16];
static int g_cpu_all_slot[16];
static int g_cpu_all_count = 0;
static int g_cpu_policy_count    = 0;

static void cpu_topology_discover(void) {
    if (g_cpu_policy_count > 0) return;

    /* Dynamically enumerate the real cpufreq policies instead of assuming a
     * fixed layout. SoCs differ: OP15 canoe / OP13 sun expose policy0+policy6
     * (a 6+2), but OP12 pineapple (SM8650) exposes FOUR policies
     * policy0/2/5/7 (1+3+2+1). The old code only knew policy6 (->{0,6}) or a
     * {0,4,7} fallback — neither matches OP12, so its big clusters policy2 and
     * policy5 were never managed and stayed pinned near their minimum in the
     * battery profile, which is exactly the "phone is unusable in battery
     * mode" sluggishness. We now scan policy0..policy15 and record up to 3
     * representative slots: the first (little), the last (prime), and the
     * widest-range middle cluster, so the governor's 2-3 slot model maps onto
     * whatever the hardware actually has. */
    int found[16]; int nf = 0;
    for (int p = 0; p < 16 && nf < 16; p++) {
        char path[128];
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpufreq/policy%d/scaling_max_freq", p);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) { close(fd); found[nf++] = p; }
    }

    if (nf <= 0) {
        /* nothing found — keep the old safe default */
        g_cpu_policy_ids[0] = 0;
        g_cpu_policy_ids[1] = 6;
        g_cpu_policy_ids[2] = -1;
        g_cpu_policy_count  = 2;
        return;
    }
    if (nf == 1) {
        g_cpu_policy_ids[0] = found[0];
        g_cpu_policy_ids[1] = -1;
        g_cpu_policy_ids[2] = -1;
        g_cpu_policy_count  = 1;
        return;
    }
    if (nf == 2) {
        g_cpu_policy_ids[0] = found[0];
        g_cpu_policy_ids[1] = found[1];
        g_cpu_policy_ids[2] = -1;
        g_cpu_policy_count  = 2;
        g_cpu_all_ids[0] = found[0]; g_cpu_all_slot[0] = 0;
        g_cpu_all_ids[1] = found[1]; g_cpu_all_slot[1] = 1;
        g_cpu_all_count = 2;
        return;
    }
    /* 3+ clusters (OP12 has 4): map slot0=little(first), slot2=prime(last),
     * slot1=the strongest middle cluster (highest cpuinfo_max_freq among the
     * middles) so the "big" slot tracks the cluster that actually carries the
     * interactive load. This keeps every physical cluster represented by one
     * of the three managed slots. */
    int first = found[0];
    int last  = found[nf - 1];
    int mid   = found[1];
    int mid_best = -1;
    for (int i = 1; i < nf - 1; i++) {
        char path[128];
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpufreq/policy%d/cpuinfo_max_freq",
                 found[i]);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        char b[32] = {0};
        int n = read(fd, b, sizeof(b) - 1); close(fd);
        if (n > 0) { int v = atoi(b); if (v > mid_best) { mid_best = v; mid = found[i]; } }
    }
    g_cpu_policy_ids[0] = first;
    g_cpu_policy_ids[1] = mid;
    g_cpu_policy_ids[2] = last;
    g_cpu_policy_count  = 3;

    /* Record EVERY physical policy and which slot governs it, so the writer can
     * mirror a slot's cap onto all clusters it represents. Assignment: the
     * first policy -> little(0); the last -> prime(2); every middle policy ->
     * big(1). On OP12 that puts BOTH policy2 and policy5 under the big slot. */
    g_cpu_all_count = 0;
    for (int i = 0; i < nf && g_cpu_all_count < 16; i++) {
        int slot;
        if (found[i] == first)      slot = 0;
        else if (found[i] == last)  slot = 2;
        else                        slot = 1;
        g_cpu_all_ids[g_cpu_all_count]  = found[i];
        g_cpu_all_slot[g_cpu_all_count] = slot;
        g_cpu_all_count++;
    }
}

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

    char buf[64] = {0};
    sysfs_read_str(PATH_LOADAVG, buf, sizeof(buf));
    sscanf(buf, "%f %f", &c->load1, &c->load5);

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
        c->cur_freq[i] = v / 1000;
        v = sysfs_read_int(max_paths[i], 0);
        c->max_freq[i] = v / 1000;
    }
}

static int g_thermal_cpu_zone     = -1;
static int g_thermal_skin_zone    = -1;  /* literal shell_front/frame/back only */
static int g_thermal_surface_zone = -1;  /* hottest body-adjacent zone (sys-therm-6 etc) */
static int g_thermal_board_zone  = -1;
static int g_thermal_cpu_fallback_zone = -1;
static char g_thermal_cpu_fallback_type[64] = "";
static char g_thermal_cpu_type[64] = "";
static char g_thermal_cpu_reason[256] = "uninitialized";

static inline int thermal_raw_to_c(int raw) {
    if (raw <= 0) return 0;
    return (raw > 200) ? (raw / 1000) : raw;
}

static int thermal_sensor_validate(int zone) {
    char path[128];
    snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/temp", zone);
    int v1 = sysfs_read_int(path, -999);
    if (v1 <= 0 || v1 == -999) return 0;          /* dead or unreadable */
    int c = thermal_raw_to_c(v1);
    if (c <= 0 || c > 120) return 0;               /* out of sane range */
    /* Quick flat check: read again, if identical raw value = suspicious */
    int v2 = sysfs_read_int(path, -999);
    int v3 = sysfs_read_int(path, -999);
    if (v1 == v2 && v2 == v3 && (c > 90 || c < 5)) return 0;  /* flat + extreme = dead */
    return 1;  /* sensor is alive */
}

static void thermal_discover(void) {
    char path[128], type[64];
    int best_cpu_prio = 99;
    int best_skin_prio = 99;
    int best_surface_prio = 99;
int preserve_cpu = (g_thermal_cpu_zone >= 0 && g_thermal_cpu_type[0] != '\0');
    if (!preserve_cpu) {
        g_thermal_cpu_zone = -1;
        g_thermal_cpu_type[0] = '\0';
        snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason), "%s", "no validated cpu thermal source");
    } else {
        /* Keep current best_cpu_prio as high so no new candidate beats the
         * already-validated one just because it happens to read fine now. */
        best_cpu_prio = 0;
    }
    g_thermal_skin_zone = -1;
    g_thermal_surface_zone = -1;
    g_thermal_board_zone = -1;

    for (int z = 0; z < THERMAL_MAX_ZONES; z++) {
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/type", z);
        if (sysfs_read_str(path, type, sizeof(type)) < 0) continue;
        /* strip trailing newline. sysfs reads return "socd\n" not "socd",
         * and the embedded \n later breaks JSON parsing when thermal_cpu_type is
         * emitted into the status payload. */
        {
            int _tl = (int)strlen(type);
            while (_tl > 0 && (type[_tl-1] == '\n' || type[_tl-1] == '\r' || type[_tl-1] == ' ')) {
                type[--_tl] = '\0';
            }
        }
int cpu_prio = -1;
        const char *cpu_reason = NULL;
        if (strcmp(type, "socd") == 0) {
            cpu_prio = 1;
            cpu_reason = "priority=1 socd die hotspot (real peak)";
        } else if (strstr(type, "cpu-1-1-")) {
            cpu_prio = 2;
            cpu_reason = "priority=2 cpu-1-1-* prime core";
        } else if (strstr(type, "cpu-0-5-")) {
            cpu_prio = 3;
            cpu_reason = "priority=3 cpu-0-5-* top perf core";
        } else if (strstr(type, "cpuss-0") || strcmp(type, "cpu-1-1") == 0) {
            /* Legacy pre-OP15 fallback for other SoCs that do have these */
            cpu_prio = 4;
            cpu_reason = "priority=4 legacy cluster aggregate";
        } else if (strstr(type, "cpullc-0")) {
            cpu_prio = 5;
            cpu_reason = "priority=5 cpullc-0 little cluster fallback";
        } else if (strstr(type, "cpu-")) {
            cpu_prio = 6;
            cpu_reason = "priority=6 generic cpu-* last resort";
        }

        if (cpu_prio > 0 && cpu_prio <= best_cpu_prio) {
            /* when same priority (e.g. two cpu-1-1-* sensors), pick the
             * hotter reading for more stable/honest telemetry between boots. */
            int dominated = 0;
            if (cpu_prio == best_cpu_prio && g_thermal_cpu_zone >= 0) {
                char cp1[128], cp2[128];
                snprintf(cp1, sizeof(cp1), THERMAL_BASE "/thermal_zone%d/temp", z);
                snprintf(cp2, sizeof(cp2), THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_zone);
                int c1 = thermal_raw_to_c(sysfs_read_int(cp1, 0));
                int c2 = thermal_raw_to_c(sysfs_read_int(cp2, 0));
                if (c1 <= c2) dominated = 1;  /* existing is hotter or equal, skip */
            }
            if (!dominated) {
            int sensor_ok = thermal_sensor_validate(z);
            /* first pass — accept socd tentatively if the basic sanity floor
             * (c > 10) passes. Cross-reference against peer CPU sensors
             * happens in a second pass after the whole zone table is scanned
             * so we can actually compare values. */
            if (sensor_ok && strcmp(type, "socd") == 0) {
                char vp[128];
                snprintf(vp, sizeof(vp), THERMAL_BASE "/thermal_zone%d/temp", z);
                int raw_now = sysfs_read_int(vp, 0);
                int c_now = thermal_raw_to_c(raw_now);
                if (c_now > 0 && c_now <= 10) {
                    sensor_ok = 0;
                    snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                        "socd rejected: read %dC <= 10C sanity floor (firmware reports garbage)", c_now);
                }
            }
            if (sensor_ok) {
                g_thermal_cpu_zone = z;
                best_cpu_prio = cpu_prio;
                snprintf(g_thermal_cpu_type, sizeof(g_thermal_cpu_type), "%s", type);
                snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason), "%s validated at zone%d", cpu_reason, z);
            }
            } /* end if (!dominated) */
        }

        /* skin_temp = LITERAL shell sensors only. If shell_front/frame/back
         * all return 0 on this firmware, accept skin_temp = 0 and signal
         * that via thermal_skin_zone = -1. Surface hotspot keeps its own
         * channel. Falling back to sys-therm-6 collapses skin and surface
         * into the same channel, which destroys the dual-channel taxonomy. */
        int skin_prio = -1;
        if (strcmp(type, "shell_frame") == 0)
            skin_prio = 1;
        else if (strcmp(type, "shell_front") == 0 || strcmp(type, "shell_back") == 0)
            skin_prio = 2;
        else if (strstr(type, "shell_"))
            skin_prio = 3;
        else if (strstr(type, "skin-virt") || strstr(type, "skin-msm"))
            skin_prio = 4;  /* legacy names for other SoCs */
        else if (strcmp(type, "skin") == 0 || strstr(type, "back-therm"))
            skin_prio = 5;

        if (skin_prio > 0 && skin_prio < best_skin_prio) {
            if (thermal_sensor_validate(z)) {
                g_thermal_skin_zone = z;
                best_skin_prio = skin_prio;
            }
        }

        /* SURFACE HOTSPOT priority (surface_hotspot_c channel).
         * Ghost hotspot -- the hottest general body-adjacent zone, not a
         * literal shell sensor. On OP15 this is sys-therm-6 (40.9C at idle),
         * which is the best proxy for "where the hot spot on the back really
         * is". Used for diagnostics and thermal diagnostics only -- does not
         * drive FSM decisions. We EXCLUDE pmic/pmih010x and svooc zones
         * because those reflect power draw / charging IC, not surface heat. */
        int surface_prio = -1;
        if (strcmp(type, "sys-therm-6") == 0)
            surface_prio = 1;
        else if (strcmp(type, "board_temp") == 0)
            surface_prio = 2;
        else if (strstr(type, "sys-therm-"))
            surface_prio = 3;  /* any sys-therm as fallback */

        if (surface_prio > 0 && surface_prio < best_surface_prio) {
            if (thermal_sensor_validate(z)) {
                g_thermal_surface_zone = z;
                best_surface_prio = surface_prio;
            }
        }
        /* track board_temp zone separately for surface_hotspot = max(sys-therm-6, board_temp) */
        if (strcmp(type, "board_temp") == 0 && thermal_sensor_validate(z)) {
            g_thermal_board_zone = z;
        }
    }

    /* two-pass socd cross-reference sanity check.
     *
     * First pass selected socd if it passed the >10C floor. But socd on some
     * OP15 firmwares drifts — it reads plausibly at boot (e.g. 55C) and then
     * reports 20-22C during runtime while cpu_prime / cpu_perf cores report
     * 30-35C and sys-therm-6 is 40C. That's wrong, not cold.
     *
     * Second pass: if socd was selected, collect reference temps from peer
     * CPU sensors (cpu-1-1-*, cpu-0-5-*, cpullc-0-*) and from sys-therm-6.
     * If socd is more than 12C BELOW the hottest peer, reject it and
     * fall back to the best available cpu-* sensor.
     *
     * Also: always record a fallback zone during the scan so read-time
     * rejections can re-bind without losing the sensor entirely. */
    {
        int ref_max_c = 0;
        char ref_max_type[64] = "";
        int fallback_zone = -1;
        int fallback_prio = 99;
        char fallback_type[64] = "";

        for (int z = 0; z < THERMAL_MAX_ZONES; z++) {
            char tp[128], tt[64];
            snprintf(tp, sizeof(tp), THERMAL_BASE "/thermal_zone%d/type", z);
            if (sysfs_read_str(tp, tt, sizeof(tt)) < 0) continue;
            int tl = (int)strlen(tt);
            while (tl > 0 && (tt[tl-1] == '\n' || tt[tl-1] == '\r' || tt[tl-1] == ' '))
                tt[--tl] = '\0';

            /* Compute current reading for reference / fallback selection */
            char vp[128];
            snprintf(vp, sizeof(vp), THERMAL_BASE "/thermal_zone%d/temp", z);
            int rv = sysfs_read_int(vp, 0);
            int rc = thermal_raw_to_c(rv);

            /* Reference pool for socd cross-check: real per-core CPU sensors
             * and sys-therm-6 which we already trust as a body-adjacent proxy.
             * We only use VALID readings (>5C, <120C). */
            int is_ref = 0;
            if (strstr(tt, "cpu-1-1-")) is_ref = 1;
            else if (strstr(tt, "cpu-0-5-")) is_ref = 1;
            else if (strstr(tt, "cpullc-0")) is_ref = 1;
            else if (strcmp(tt, "sys-therm-6") == 0) is_ref = 1;
            if (is_ref && rc > 5 && rc < 120 && rc > ref_max_c) {
                ref_max_c = rc;
                snprintf(ref_max_type, sizeof(ref_max_type), "%s", tt);
            }

            /* Fallback zone selection: best non-socd CPU sensor with a
             * plausible live reading (>15C) */
            int fbp = -1;
            if (strstr(tt, "cpu-1-1-")) fbp = 2;
            else if (strstr(tt, "cpu-0-5-")) fbp = 3;
            else if (strstr(tt, "cpullc-0")) fbp = 5;
            if (fbp > 0 && fbp < fallback_prio && rc > 15 && rc < 120) {
                if (thermal_sensor_validate(z)) {
                    fallback_zone = z;
                    fallback_prio = fbp;
                    snprintf(fallback_type, sizeof(fallback_type), "%s", tt);
                }
            }
        }

        g_thermal_cpu_fallback_zone = fallback_zone;
        snprintf(g_thermal_cpu_fallback_type, sizeof(g_thermal_cpu_fallback_type),
                 "%s", fallback_type);

        /* Cross-check: if primary is socd and it's significantly colder than
         * the hottest reference sensor, it's reporting garbage. Reject. */
        if (g_thermal_cpu_zone >= 0 && strcmp(g_thermal_cpu_type, "socd") == 0 && ref_max_c > 0) {
            char svp[128];
            snprintf(svp, sizeof(svp), THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_zone);
            int sraw = sysfs_read_int(svp, 0);
            int sc = thermal_raw_to_c(sraw);
            if (sc > 0 && ref_max_c - sc >= 12) {
                /* socd is colder than peers by >= 12C — implausible */
                if (g_thermal_cpu_fallback_zone >= 0) {
                    int old_zone = g_thermal_cpu_zone;
                    int old_c = sc;
                    g_thermal_cpu_zone = g_thermal_cpu_fallback_zone;
                    snprintf(g_thermal_cpu_type, sizeof(g_thermal_cpu_type),
                             "%s", g_thermal_cpu_fallback_type);
                    snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                             "socd rejected (z%d reads %dC vs peer %s=%dC, gap>=12C); fallback to %s at zone%d",
                             old_zone, old_c, ref_max_type, ref_max_c,
                             g_thermal_cpu_type, g_thermal_cpu_zone);
                } else {
                    /* Keep socd but note the issue — no fallback available */
                    snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                             "socd=%dC vs peer %s=%dC (gap>=12C) but no cpu-* fallback available",
                             sc, ref_max_type, ref_max_c);
                }
            }
        }
    }

    if (g_thermal_cpu_zone < 0) {
        snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason), "%s", "no validated cpu thermal source found");
    }
}

static time_t g_last_thermal_read_ts = 0;  /* when we last actually read temp */
static int    g_last_thermal_value = 0;     /* cached last real temp */
static time_t g_last_thermal_rescan = 0;    /* periodic rescan if skin zone missing */

static void metrics_read_thermal(asb_thermal_t *t, int need_headroom) {
    char path[128];

    /* if any of the three thermal zones (cpu / skin / surface) wasn't
     * found at startup (validate failed on a transient read), retry every 60
     * seconds. Cheap — iterates 128 sysfs files. Only triggers while at
     * least one zone is still -1. */
    if (g_thermal_skin_zone < 0 || g_thermal_cpu_zone < 0 || g_thermal_surface_zone < 0) {
        time_t now = time(NULL);
        if (now - g_last_thermal_rescan >= 60) {
            g_last_thermal_rescan = now;
            thermal_discover();
        }
    }

    t->cpu_max_c  = 0;
    t->gpu_temp_c = 0;
    t->skin_temp_c = 0;
    t->surface_hotspot_c = 0;
    t->board_temp_c = 0;
    t->throttling  = 0;
    t->soft_clamp  = 0;
    t->hard_clamp  = 0;
    t->temp_valid  = 0;
    t->temp_age_s  = 0;
    snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "init");
    t->perf_cap_p0 = 0;
    t->perf_cap_p6 = 0;
    t->headroom_pct = 100;
    t->headroom_valid = 0;
    t->used_fallback = 0;
    t->fallback_just_flipped = 0;
    snprintf(t->headroom_invalid_reason, sizeof(t->headroom_invalid_reason), "no_iface");

    if (g_thermal_cpu_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_zone);
        int v = sysfs_read_int(path, 0);
        if (v > 0) {
            int c_now = thermal_raw_to_c(v);
            /* runtime socd drift detection.
             * If the bound zone is socd AND a fallback zone was discovered
             * AND the fallback reads significantly hotter than socd,
             * trust the fallback instead (don't flap: just use it for THIS
             * read, keep socd bound for next cycle — the next cycle will
             * re-check). This prevents socd reporting "20C" during active
             * use while cpu cores are at 33C from cascading into FSM. */
            int used_fallback = 0;
            int fb_c = 0;
            if (strcmp(g_thermal_cpu_type, "socd") == 0 &&
                g_thermal_cpu_fallback_zone >= 0) {
                char fbp[128];
                snprintf(fbp, sizeof(fbp),
                    THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_fallback_zone);
                int fbv = sysfs_read_int(fbp, 0);
                if (fbv > 0) {
                    fb_c = thermal_raw_to_c(fbv);
                    if (fb_c > c_now && (fb_c - c_now) >= 10) {
                        /* Fallback is >=10C hotter — use it instead */
                        c_now = fb_c;
                        used_fallback = 1;
                    }
                }
            }
            /* expose flip detection to governor.c so it can log the
             * transition without needing asb_log linkage from this header. */
            t->used_fallback = used_fallback;
            {
                static int prev_used_fallback = -1;
                t->fallback_just_flipped = (prev_used_fallback != -1 &&
                                            prev_used_fallback != used_fallback) ? 1 : 0;
                prev_used_fallback = used_fallback;
            }

            /* explicit guard for "looks alive but reports nonsense" sensors
             * like socd on broken firmware. If validate accepted the zone but
             * a live read is now <=10C while the rest of the system is hot,
             * treat as invalid for THIS read but keep the zone bound. */
            static int raw_too_low_streak = 0;
            int rebound_this_tick = 0;
            if (c_now > 0 && c_now <= 10) {
                /* RC9: runtime socd rebind.
                 *
                 * Previous behavior: every tick where socd reads <=10C we mark
                 * temp_invalid_reason=raw_too_low and use last cached value.
                 * But logs showed this lasting 442 consecutive ticks — socd
                 * was just permanently broken during the session. The per-tick
                 * workaround kept the governor on a dead sensor forever.
                 *
                 * New behavior: if primary is socd AND raw_too_low happens
                 * for >= 5 consecutive ticks AND fallback is available AND
                 * fallback reads a plausible temperature, permanently rebind
                 * primary to fallback for the rest of this session. Real
                 * re-binding via g_thermal_cpu_zone update, not a per-tick
                 * workaround. */
                raw_too_low_streak++;
                if (raw_too_low_streak >= 5 &&
                    strcmp(g_thermal_cpu_type, "socd") == 0 &&
                    g_thermal_cpu_fallback_zone >= 0 &&
                    g_thermal_cpu_fallback_type[0] != '\0')
                {
                    /* Verify fallback is still plausible before rebinding. */
                    char fbp[128];
                    snprintf(fbp, sizeof(fbp), THERMAL_BASE "/thermal_zone%d/temp",
                             g_thermal_cpu_fallback_zone);
                    int fb_raw = sysfs_read_int(fbp, 0);
                    int fb_c = (fb_raw > 0) ? thermal_raw_to_c(fb_raw) : 0;
                    if (fb_c > 15 && fb_c < 120) {
                        int old_zone = g_thermal_cpu_zone;
                        g_thermal_cpu_zone = g_thermal_cpu_fallback_zone;
                        snprintf(g_thermal_cpu_type, sizeof(g_thermal_cpu_type),
                                 "%s", g_thermal_cpu_fallback_type);
                        snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                                 "socd runtime rebind (streak=%d, old_zone=%d -> %s at zone%d, fb_now=%dC)",
                                 raw_too_low_streak, old_zone,
                                 g_thermal_cpu_type, g_thermal_cpu_zone, fb_c);
                        g_thermal_cpu_fallback_zone = -1;
                        g_thermal_cpu_fallback_type[0] = '\0';
                        c_now = fb_c;
                        t->cpu_max_c = c_now;
                        t->temp_valid = 1;
                        snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "rebind");
                        g_last_thermal_read_ts = time(NULL);
                        g_last_thermal_value = c_now;
                        if (c_now > g_asb_cfg.thermal_throttle_temp) t->throttling = 1;
                        raw_too_low_streak = 0;
                        rebound_this_tick = 1;
                    }
                }
                if (!rebound_this_tick) {
                    t->cpu_max_c = g_last_thermal_value;
                    t->temp_valid = 0;
                    snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "raw_too_low");
                }
            } else {
                /* Plausible reading — reset the streak */
                raw_too_low_streak = 0;
int spike_detected = 0;
                if (g_last_thermal_value > 0 &&
                    c_now >= g_last_thermal_value + 25 &&
                    g_thermal_cpu_fallback_zone >= 0 &&
                    !used_fallback) {
                    char fbpath[128];
                    snprintf(fbpath, sizeof(fbpath),
                        THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_fallback_zone);
                    int fb_raw = sysfs_read_int(fbpath, 0);
                    int fb_cross = (fb_raw > 0) ? thermal_raw_to_c(fb_raw) : 0;
                    if (fb_cross > 0 && c_now >= fb_cross + 25) {
                        spike_detected = 1;
                    }
                }
                if (spike_detected) {
                    /* Hold last good value, don't advance throttling on this tick */
                    t->cpu_max_c = g_last_thermal_value;
                    t->temp_valid = 1;   /* still "valid" — we have a good cached number */
                    snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "spike");
                    /* Don't update g_last_thermal_value or g_last_thermal_read_ts
                     * so next tick compares against the pre-spike baseline.
                     * Don't set throttling from the spike value. */
                } else {
                    t->cpu_max_c = c_now;
                    t->temp_valid = 1;
                    snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason),
                             used_fallback ? "fb_used" : "ok");
                    g_last_thermal_read_ts = time(NULL);
                    g_last_thermal_value = t->cpu_max_c;
                    /* throttling = ONLY real temperature exceeding threshold */
                    if (t->cpu_max_c > g_asb_cfg.thermal_throttle_temp) t->throttling = 1;
                }
            }
        } else {
            /* Read failed -- use cached value, mark as stale */
            t->cpu_max_c = g_last_thermal_value;
            t->temp_valid = 0;
            snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "read_fail");
        }
    } else {
        /* No thermal zone -- use cached */
        t->cpu_max_c = g_last_thermal_value;
        t->temp_valid = 0;
        snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "no_zone");
    }

    /* compute staleness */
    if (g_last_thermal_read_ts > 0) {
        t->temp_age_s = (int)(time(NULL) - g_last_thermal_read_ts);
        /* Mark stale if age exceeds configurable threshold */
        if (g_asb_cfg.thermal_stale_after_s > 0 &&
            t->temp_age_s > g_asb_cfg.thermal_stale_after_s) {
            t->temp_valid = 0;
        }
    }

    if (g_thermal_skin_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_skin_zone);
        int sv = sysfs_read_int(path, 0);
        t->skin_temp_c = thermal_raw_to_c(sv);
    }

    /* surface_hotspot = max(sys-therm-6, board_temp).
     * sys-therm-6 on OP15 reads nearly static 40C even under load.
     * board_temp actually rises (up to 47-50C in heavy gaming) and better
     * reflects heat accumulation across the PCB. Using max() of both gives
     * a surface channel that's actually informative instead of flat 40/41. */
    if (g_thermal_surface_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_surface_zone);
        int sv = sysfs_read_int(path, 0);
        t->surface_hotspot_c = thermal_raw_to_c(sv);
    }
    if (g_thermal_board_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_board_zone);
        int bv = sysfs_read_int(path, 0);
        int bc = thermal_raw_to_c(bv);
        t->board_temp_c = bc;
        if (bc > t->surface_hotspot_c) {
            t->surface_hotspot_c = bc;
        }
    }

    /* Read kernel-enforced freq caps from msm_performance */
    if (need_headroom) {
        char buf[256];
        int fd = open("/sys/kernel/msm_performance/parameters/cpu_max_freq",
                       O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            int n = read(fd, buf, sizeof(buf) - 1);
            close(fd);
            if (n > 0) {
                buf[n] = '\0';
                char *p = buf;
                while (*p) {
                    int cpu = -1, freq = 0;
                    if (sscanf(p, "%d:%d", &cpu, &freq) == 2) {
                        if (cpu == 0 && freq > 0) t->perf_cap_p0 = freq;
                        if (cpu == 6 && freq > 0) t->perf_cap_p6 = freq;
                    }
                    while (*p && *p != ' ' && *p != '\n' && *p != '\t') p++;
                    while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') p++;
                }
                if (t->perf_cap_p0 > 0) {
                    int hw_max_p0 = 3628800;  /* SM8850 policy0 max */
                    t->headroom_pct = (int)((long)t->perf_cap_p0 * 100 / hw_max_p0);
                    if (t->headroom_pct > 100) t->headroom_pct = 100;
                    if (t->headroom_pct < 0)   t->headroom_pct = 0;
                    /* split into soft/hard clamp instead of blunt throttling.
                     * soft_clamp = advisory (reduce aggression, no SUSTAINED)
                     * hard_clamp = actionable (can lead to SUSTAINED if confirmed) */
                    int soft_pct = (g_asb_cfg.soft_clamp_headroom_pct > 0)
                                   ? g_asb_cfg.soft_clamp_headroom_pct : 70;
                    int hard_pct = (g_asb_cfg.hard_clamp_headroom_pct > 0)
                                   ? g_asb_cfg.hard_clamp_headroom_pct : 45;
                    if (t->headroom_pct < soft_pct) t->soft_clamp = 1;
                    if (t->headroom_pct < hard_pct) t->hard_clamp = 1;
                    t->headroom_valid = 1;
                    snprintf(t->headroom_invalid_reason, sizeof(t->headroom_invalid_reason), "ok");
                    /* detect "dead" headroom signal on SoCs like SM8850 where
                     * msm_performance always reports max freq → headroom permanently 100%.
                     * If headroom has been 100% for 10+ consecutive reads, downgrade
                     * to headroom_valid=0 (advisory-only) so the FSM doesn't rely on
                     * a perpetually optimistic signal for decision-making.
                     *
                     * track lifetime stuck count too — once we've seen
                     * 60+ consecutive stuck_100 readings (10 minutes at default tick),
                     * mark the source permanently unreliable for this boot session.
                     * Stops costly read attempts and lets FSM avoid re-checking. */
                    {
                        static int headroom_100_streak = 0;
                        static int headroom_dead_session = 0;
                        static int implausible_hot_streak = 0;
                        if (headroom_dead_session) {
                            t->headroom_valid = 0;
                            snprintf(t->headroom_invalid_reason,
                                     sizeof(t->headroom_invalid_reason), "dead_iface");
                        } else if (t->headroom_pct >= 100) {
                            headroom_100_streak++;
                            /* implausible_hot_100 detector — chatgpt review flagged
                             * that headroom=100 while CPU=60-69°C is physically wrong.
                             * On SM8850 msm_performance overestimates under real thermal
                             * pressure. Track separate streak: 3+ ticks of headroom=100
                             * with CPU>=60°C → downgrade trust immediately. */
                            if (t->cpu_max_c >= 60 && t->headroom_pct >= 95) {
                                implausible_hot_streak++;
                                if (implausible_hot_streak >= 3) {
                                    t->headroom_valid = 0;
                                    snprintf(t->headroom_invalid_reason,
                                             sizeof(t->headroom_invalid_reason),
                                             "implausible_hot");
                                    goto headroom_status_done;
                                }
                            } else {
                                implausible_hot_streak = 0;
                            }
                            if (headroom_100_streak >= 60) {
                                /* msm_performance is permanently broken on this device;
                                 * don't keep paying the cost of reads + don't keep
                                 * re-evaluating. */
                                headroom_dead_session = 1;
                                t->headroom_valid = 0;
                                snprintf(t->headroom_invalid_reason,
                                         sizeof(t->headroom_invalid_reason), "dead_iface");
                            } else if (headroom_100_streak >= 10) {
                                t->headroom_valid = 0;  /* advisory-only */
                                snprintf(t->headroom_invalid_reason,
                                         sizeof(t->headroom_invalid_reason), "stuck_100");
                            }
                        } else {
                            headroom_100_streak = 0;
                            implausible_hot_streak = 0;
                        }
                    headroom_status_done: ;
                    }
                }
            }
        }
    }
}

static int metrics_screen_on(void) {
    const char *paths[] = { PATH_SCREEN_STATUS, PATH_SCREEN_STATUS2, NULL };
    for (int i = 0; paths[i]; i++) {
        int v = sysfs_read_int(paths[i], -1);
        if (v == 1) return 1;
        if (v == 0) return 0;
    }
    int bl = sysfs_read_int(PATH_BACKLIGHT, -1);
    if (bl > 0) return 1;
    if (bl == 0) return 0;
    return 1;
}

static long g_wlan_tx_prev = 0, g_wlan_rx_prev = 0;
static long g_rmnet_tx_prev = 0, g_rmnet_rx_prev = 0;
static struct timespec g_wlan_ts_prev = {0};

static void metrics_read_network(asb_misc_t *m, const struct timespec *now) {
    long tx = sysfs_read_long(PATH_WLAN_TX, 0);
    long rx = sysfs_read_long(PATH_WLAN_RX, 0);
    long mtx = rmnet_read_total("tx_bytes");
    long mrx = rmnet_read_total("rx_bytes");
    if (g_wlan_ts_prev.tv_sec > 0) {
        double dt = (now->tv_sec - g_wlan_ts_prev.tv_sec) +
                    (now->tv_nsec - g_wlan_ts_prev.tv_nsec) * 1e-9;
        if (dt > 0.1) {
            m->wlan_tx_bps = (long)((tx - g_wlan_tx_prev) / dt);
            m->wlan_rx_bps = (long)((rx - g_wlan_rx_prev) / dt);
            m->rmnet_tx_bps = (long)((mtx - g_rmnet_tx_prev) / dt);
            m->rmnet_rx_bps = (long)((mrx - g_rmnet_rx_prev) / dt);
        }
    }
    g_wlan_tx_prev = tx;
    g_wlan_rx_prev = rx;
    g_rmnet_tx_prev = mtx;
    g_rmnet_rx_prev = mrx;
    g_wlan_ts_prev = *now;
}

static void metrics_read_all(asb_metrics_t *m, int need_headroom, int need_thermal) {
    clock_gettime(CLOCK_MONOTONIC, &m->ts);
    metrics_read_battery(&m->bat);
    metrics_read_gpu(&m->gpu);
    metrics_read_cpu(&m->cpu);
    if (need_thermal)
        metrics_read_thermal(&m->therm, need_headroom);
    m->misc.screen_on = metrics_screen_on();
    metrics_read_network(&m->misc, &m->ts);
}
