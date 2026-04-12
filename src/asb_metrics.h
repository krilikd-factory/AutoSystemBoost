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
/* V34: radio-aware v2 -- scan multiple mobile data interfaces */
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
    int     surface_hotspot_c;     /* V37-r7: hottest body-adjacent zone (sys-therm-6 etc) */
    int     throttling;     /* real thermal: temp >= threshold */
    int     soft_clamp;     /* V35: vendor advisory: headroom < soft_pct */
    int     hard_clamp;     /* V35: vendor actionable: headroom < hard_pct */
    int     temp_valid;     /* V35: 1=fresh read, 0=stale/skipped */
    int     temp_age_s;     /* V35: seconds since last real thermal read */
    int     perf_cap_p0;    /* kernel-allowed max freq for policy0 (kHz) */
    int     perf_cap_p6;    /* kernel-allowed max freq for policy6 (kHz) */
    int     headroom_pct;   /* thermal headroom: 100=full, 0=fully throttled */
    int     headroom_valid; /* 1=real read, 0=skipped or failed */
} asb_thermal_t;

typedef struct {
    int     screen_on;
    long    wlan_tx_bps;
    long    wlan_rx_bps;
    /* V34: radio-aware -- mobile data activity */
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
        /* V37-r7 fix: strip trailing newline/CR/space. sysfs text nodes almost
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
    b->current_ma   = abs(b->current_ua) / 1000;

    char st[16] = {0};
    sysfs_read_str(PATH_BATT_STATUS, st, sizeof(st));
    b->charging = (st[0] == 'C') ? 1 : 0;
}

static void metrics_read_gpu(asb_gpu_t *g) {
    g->load_pct  = sysfs_read_int(PATH_GPU_LOAD, 0);
    g->cur_freq_hz = sysfs_read_long(PATH_GPU_FREQ, 0);
    g->max_freq_hz = sysfs_read_long(PATH_GPU_MAXFREQ, 1000000000L);
    if (g->max_freq_hz <= 0) g->max_freq_hz = 1000000000L;
}

static int g_cpu_policy_ids[3]   = {0, 6, -1};
static int g_cpu_policy_count    = 0;

static void cpu_topology_discover(void) {
    if (g_cpu_policy_count > 0) return;

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
    g_cpu_policy_ids[0] = 0;
    g_cpu_policy_ids[1] = 4;
    g_cpu_policy_ids[2] = 7;
    g_cpu_policy_count  = 3;
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
static int g_thermal_surface_zone = -1;  /* V37-r7: hottest body-adjacent zone (sys-therm-6 etc) */
static char g_thermal_cpu_type[64] = "";
static char g_thermal_cpu_reason[160] = "uninitialized";

/* V33: priority-based thermal discovery with V34 sensor reliability layer.
 * After finding a candidate, validate it with a real read.
 * Dead sensors (0, negative, >120C, flat 95000 mC) are rejected. */
/* V37-r7: unified dual-format normalization.
 * Most thermal_zone/temp sysfs nodes return millidegrees (e.g. 40500 = 40.5C),
 * but some sensors on certain SoCs return raw Celsius directly (e.g. socd on
 * OP15 returns 74). Heuristic: values > 200 are almost certainly millidegrees
 * (raw Celsius above 200C would mean the silicon is literally on fire).
 * Everything below 200 is treated as already-normalized Celsius. */
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

    g_thermal_cpu_zone = -1;
    g_thermal_skin_zone = -1;
    g_thermal_surface_zone = -1;
    g_thermal_cpu_type[0] = '\0';
    snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason), "%s", "no validated cpu thermal source");

    for (int z = 0; z < THERMAL_MAX_ZONES; z++) {
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/type", z);
        if (sysfs_read_str(path, type, sizeof(type)) < 0) continue;
        /* V37-r7 fix: strip trailing newline. sysfs reads return "socd\n" not "socd",
         * and the embedded \n later breaks JSON parsing when thermal_cpu_type is
         * emitted into the status payload. */
        {
            int _tl = (int)strlen(type);
            while (_tl > 0 && (type[_tl-1] == '\n' || type[_tl-1] == '\r' || type[_tl-1] == ' ')) {
                type[--_tl] = '\0';
            }
        }

        /* V37-r6/r7: OP15-accurate CPU hotspot priority.
         * Confirmed on OnePlus 15 (SM8850 / SD8 Elite Gen5) from thermal_zones dump:
         *   - socd (zone 57): the real die hotspot, 74C under load
         *   - cpu-1-1-* (zone 26/27): prime core per-core sensors
         *   - cpu-0-5-* (zone 15/16): top perf core sensors
         *   - cpullc-0-* (zone 0/1): little cluster aggregate (highest of LLC sensors)
         *   - cpuss-0 / cpu-1-1 (no suffix): DO NOT EXIST on this SoC
         * socd returns RAW degrees (74), not millidegrees. thermal_raw_to_c() handles both.
         */
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

        if (cpu_prio > 0 && cpu_prio < best_cpu_prio) {
            if (thermal_sensor_validate(z)) {
                g_thermal_cpu_zone = z;
                best_cpu_prio = cpu_prio;
                snprintf(g_thermal_cpu_type, sizeof(g_thermal_cpu_type), "%s", type);
                snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason), "%s validated at zone%d", cpu_reason, z);
            }
        }

        /* V37-r7: LITERAL shell priority (skin_temp channel).
         * This is the direct surface sensor -- what the user's hand physically
         * touches. We do NOT mix general body-adjacent thermistors here because
         * those read hotter and would misrepresent "surface temperature".
         * OP15 has three shell sensors at zones 55/58/65. shell_frame is
         * typically the hottest of the three under load (side rails heat up
         * fastest from CPU die bleeding through chassis), so it's priority 1. */
        int skin_prio = -1;
        if (strcmp(type, "shell_frame") == 0)
            skin_prio = 1;
        else if (strcmp(type, "shell_front") == 0 || strcmp(type, "shell_back") == 0)
            skin_prio = 2;
        else if (strstr(type, "shell_"))
            skin_prio = 3;
        /* V37-r8: on current OP15 firmware shell_* sensors return 0. Fall back
         * to sys-therm-6 (and other sys-therm-N) as valid skin sources so
         * skin_temp isn't permanently stuck at 0. */
        else if (strcmp(type, "sys-therm-6") == 0)
            skin_prio = 4;
        else if (strstr(type, "sys-therm-"))
            skin_prio = 5;
        else if (strstr(type, "skin-virt") || strstr(type, "skin-msm"))
            skin_prio = 6;  /* legacy names for other SoCs */
        else if (strcmp(type, "skin") == 0 || strstr(type, "back-therm"))
            skin_prio = 5;

        if (skin_prio > 0 && skin_prio < best_skin_prio) {
            if (thermal_sensor_validate(z)) {
                g_thermal_skin_zone = z;
                best_skin_prio = skin_prio;
            }
        }

        /* V37-r7: SURFACE HOTSPOT priority (surface_hotspot_c channel).
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
    }

    if (g_thermal_cpu_zone < 0) {
        snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason), "%s", "no validated cpu thermal source found");
    }
}

static time_t g_last_thermal_read_ts = 0;  /* V35: when we last actually read temp */
static int    g_last_thermal_value = 0;     /* V35: cached last real temp */
static time_t g_last_thermal_rescan = 0;    /* V37-r6: periodic rescan if skin zone missing */

static void metrics_read_thermal(asb_thermal_t *t, int need_headroom) {
    char path[128];

    /* V37-r6: if any of the three thermal zones (cpu / skin / surface) wasn't
     * found at startup (validate failed on a transient read), retry every 60
     * seconds. Cheap -- iterates 128 sysfs files. Only triggers while at least
     * one zone is still -1. V37-r7 polish: include surface channel for full
     * symmetry across all three thermal sources. */
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
    t->throttling  = 0;
    t->soft_clamp  = 0;
    t->hard_clamp  = 0;
    t->temp_valid  = 0;
    t->temp_age_s  = 0;
    t->perf_cap_p0 = 0;
    t->perf_cap_p6 = 0;
    t->headroom_pct = 100;
    t->headroom_valid = 0;

    if (g_thermal_cpu_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_zone);
        int v = sysfs_read_int(path, 0);
        if (v > 0) {
            t->cpu_max_c = thermal_raw_to_c(v);
            t->temp_valid = 1;
            g_last_thermal_read_ts = time(NULL);
            g_last_thermal_value = t->cpu_max_c;
            /* V35: throttling = ONLY real temperature exceeding threshold */
            if (t->cpu_max_c > g_asb_cfg.thermal_throttle_temp) t->throttling = 1;
        } else {
            /* Read failed -- use cached value, mark as stale */
            t->cpu_max_c = g_last_thermal_value;
            t->temp_valid = 0;
        }
    } else {
        /* No thermal zone -- use cached */
        t->cpu_max_c = g_last_thermal_value;
        t->temp_valid = 0;
    }

    /* V35: compute staleness */
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

    if (g_thermal_surface_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_surface_zone);
        int sv = sysfs_read_int(path, 0);
        t->surface_hotspot_c = thermal_raw_to_c(sv);
    }

    /* V29: Read kernel-enforced freq caps from msm_performance */
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
                    /* V35: split into soft/hard clamp instead of blunt throttling.
                     * soft_clamp = advisory (reduce aggression, no SUSTAINED)
                     * hard_clamp = actionable (can lead to SUSTAINED if confirmed) */
                    int soft_pct = (g_asb_cfg.soft_clamp_headroom_pct > 0)
                                   ? g_asb_cfg.soft_clamp_headroom_pct : 70;
                    int hard_pct = (g_asb_cfg.hard_clamp_headroom_pct > 0)
                                   ? g_asb_cfg.hard_clamp_headroom_pct : 45;
                    if (t->headroom_pct < soft_pct) t->soft_clamp = 1;
                    if (t->headroom_pct < hard_pct) t->hard_clamp = 1;
                    t->headroom_valid = 1;
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
