/*
 * asb_governor.c — ASB Adaptive Runtime Governor
 *
 * Event loop architecture:
 *
 *   epoll waits for events (blocks without CPU):
 *     ├── timerfd_active  (2s)  — metrics when screen ON
 *     ├── timerfd_idle    (5s)  — metrics when screen OFF
 *     ├── ueventfd        — screen ON/OFF immediately
 *     ├── timerfd_hourly  (1h)  — learner update
 *     └── sockfd          — commands from action.sh
 *
 * In DEEP_IDLE: only timerfd_idle (5s) + ueventfd active.
 * Active metrics timer suspended → CPU not woken needlessly.
 *
 * Power in DEEP_IDLE:
 *   - 0% CPU (epoll blocked)
 *   - ~50KB RSS (full code + data)
 *   - Wakes only on screen uevent or every 5s for
 *     battery/thermal check
 *
 * Build in Termux:
 *   clang -O2 -o asb_governor asb_governor.c -lm
 *   (or via Makefile)
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <time.h>
#include <math.h>
#include <stdint.h>
#include <linux/netlink.h>

#include "asb_metrics.h"
#include "asb_fsm.h"
#include "asb_learner.h"
#include "asb_writer.h"
#include "asb_socket.h"
#include "asb_config.h"

/* ─── Config ────────────────────────────────────────────────── */
#define TIMER_ACTIVE_S  2   /* metrics interval, screen ON  */
#define TIMER_IDLE_S    5   /* metrics interval, screen OFF */
#define TIMER_HOURLY_S  3600

#define STATE_FILE      "/dev/.asb/state"
#define LOG_FILE        "/dev/.asb/governor.log"
#define PID_FILE        "/dev/.asb/governor.pid"
#define PROFILE_FILE    "/data/adb/modules/AutoSystemBoost/current_profile"
#define CONFIG_FILE     "/data/adb/modules/AutoSystemBoost/config/governor.conf"

#define MAX_EVENTS      8

/* ─── Logging ───────────────────────────────────────────────── */
static FILE *g_logf = NULL;
asb_runtime_config_t g_asb_cfg;
static time_t g_last_reassert = 0;
static int g_last_reassert_ok = 0;
static int g_msm_boost_active = 0;

static void asb_log(const char *fmt, ...) __attribute__((format(printf,1,2)));
static void asb_log(const char *fmt, ...) {
    if (!g_logf) return;
    char ts[32];
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", tm);
    fprintf(g_logf, "[%s] ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_logf, fmt, ap);
    va_end(ap);
    fprintf(g_logf, "\n");
    fflush(g_logf);
}

/* ─── State dump ────────────────────────────────────────────── */
/* ─── Persistent session stats ─────────────────────────────── */
#define PERSISTENT_STATS_FILE "/dev/.asb/session_stats.json"
#define PERSISTENT_STATS_MAX_SESSIONS 10

typedef struct {
    int   session_count;
    float avg_time_to_first_sus;    /* rolling avg seconds to first SUSTAINED */
    float avg_time_to_first_thermal;/* rolling avg seconds to first thermal */
    float avg_max_temp;             /* rolling avg peak temp °C */
    float avg_gap_p0;               /* rolling avg cap gap kHz */
    float avg_efficiency;           /* rolling avg sustained efficiency score */
} asb_persistent_stats_t;

static asb_persistent_stats_t g_pstats = {0};


static void write_state(const asb_fsm_t *fsm, const asb_metrics_t *m,
                        asb_prediction_t pred)
{
    static const char *profile_names[] = {"battery","balanced","performance"};
    static const char *pred_names[] = {"unknown","idle","light","active"};

    FILE *f = fopen(STATE_FILE, "w");
    if (!f) return;
    int rmax0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
    int rmax1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
    fprintf(f,
        "state=%s\nprofile=%s\n"
        "mA=%d\ngpu_pct=%d\nload1=%.2f\n"
        "cpu_max=%d,%d,%d\n"
        "thermal=%d\ncap_temp=%d\n"
        "predict=%s\n"
        "screen=%d\ncapacity=%d\n"
        "dwell_sec=%ld\nboost=%d\n"
        "cap_gap_p0=%d\ncap_gap_p1=%d\n"
        "last_sustained_reason=%s\n"
        "highload_mode=%s\n"
        "ses_gaming=%d\nses_sustained=%d\nses_thermal=%d\nses_unreachable=%d\n"
        "ses_t_heavy=%ld\nses_t_gaming=%ld\nses_t_sustained=%ld\n"
        "ses_avg_gap_p0=%d\nses_max_gap_p0=%d\nses_max_temp=%d\nses_auto_degraded=%d\n"
        "bat_deep_idle=%ld\nbat_light_idle=%ld\nbat_wake_cycles=%d\n"
        "ses_t2s=%ld\nses_t2thermal=%ld\nses_efficiency=%d\nses_recovery=%d\n"
        "hist_sessions=%d\nhist_t2s=%.0f\nhist_temp=%.0f\nhist_gap=%.0f\nhist_eff=%.0f\n",
        asb_state_names[fsm->state],
        profile_names[fsm->profile_idx],
        m->bat.current_ma,
        m->gpu.load_pct,
        m->cpu.load1,
        fsm->current_caps.cpu_max[0],
        fsm->current_caps.cpu_max[1],
        fsm->current_caps.cpu_max[2],
        fsm->thermal_cap,
        m->therm.cpu_max_c,
        pred_names[pred],
        m->misc.screen_on,
        m->bat.capacity_pct,
        fsm_elapsed_sec(fsm),
        g_msm_boost_active,
        (rmax0 > 0) ? (fsm->current_caps.cpu_max[0] - rmax0) : 0,
        (rmax1 > 0) ? (fsm->current_caps.cpu_max[1] - rmax1) : 0,
        (fsm->sustained_reason == 1) ? "gaming_unreachable" : "thermal",
        g_asb_cfg.highload_mode == 1 ? "burst" :
        g_asb_cfg.highload_mode == 2 ? "stable" : "default",
        fsm->ses_gaming_entries, fsm->ses_sustained_entries,
        fsm->ses_thermal_entries, fsm->ses_unreachable_entries,
        fsm->ses_time_heavy_sec, fsm->ses_time_gaming_sec, fsm->ses_time_sustained_sec,
        fsm->ses_gap_samples > 0 ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0,
        fsm->ses_max_gap_p0,
        fsm->ses_max_temp,
        fsm->ses_auto_degraded,
        fsm->bat_time_deep_idle_sec,
        fsm->bat_time_light_idle_sec,
        fsm->bat_wake_cycles,
        fsm->ses_time_to_first_sus,
        fsm->ses_time_to_first_thermal,
        fsm->ses_sustained_efficiency,
        fsm->ses_recovery_count,
        g_pstats.session_count,
        g_pstats.avg_time_to_first_sus,
        g_pstats.avg_max_temp,
        g_pstats.avg_gap_p0,
        g_pstats.avg_efficiency);
    fclose(f);
}

/* ─── JSON status ───────────────────────────────────────────── */
static int g_total_writes = 0;        /* total sysfs writes */
static time_t g_last_write_ts = 0;   /* timestamp of last write */

static void build_status_json(const asb_fsm_t *fsm, const asb_metrics_t *m,
                               asb_prediction_t pred,
                               char *out, int outlen)
{
    static const char *profile_names[] = {"battery","balanced","performance"};
    static const char *pred_names[] = {"unknown","idle","light","active"};
    int ma_valid = (m->bat.current_ma > 0 && !m->bat.charging);
    int real_max_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
    int real_max_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
    int cap_gap_p0  = (real_max_p0 > 0) ? (fsm->current_caps.cpu_max[0] - real_max_p0) : 0;
    int cap_gap_p1  = (real_max_p1 > 0) ? (fsm->current_caps.cpu_max[1] - real_max_p1) : 0;
    snprintf(out, outlen,
        "{\"state\":\"%s\",\"profile\":\"%s\","
        "\"mA\":%d,\"mA_valid\":%d,\"charging\":%d,"
        "\"gpu\":%d,\"load\":%.2f,"
        "\"cpu_max\":[%d,%d,%d],"
        "\"thermal\":%d,\"temp\":%d,"
        "\"predict\":\"%s\",\"screen\":%d,\"bat\":%d,"
        "\"writes\":%d,\"last_write\":%ld,"
        "\"dwell_sec\":%ld,\"boost\":%d,"
        "\"cap_gap_p0\":%d,\"cap_gap_p1\":%d,"
        "\"last_sustained_reason\":\"%s\",\"highload_mode\":\"%s\",\"ses_gaming\":%d,\"ses_sustained\":%d,\"ses_thermal\":%d,\"ses_unreachable\":%d,\"ses_t_heavy\":%ld,\"ses_t_gaming\":%ld,\"ses_t_sustained\":%ld,\"ses_avg_gap_p0\":%d,\"ses_max_gap_p0\":%d,\"ses_max_temp\":%d,\"ses_auto_degraded\":%d,\"bat_deep_idle\":%ld,\"bat_light_idle\":%ld,\"bat_wake_cycles\":%d}",
        asb_state_names[fsm->state],
        profile_names[fsm->profile_idx],
        m->bat.current_ma, ma_valid, m->bat.charging,
        m->gpu.load_pct,
        m->cpu.load1,
        fsm->current_caps.cpu_max[0],
        fsm->current_caps.cpu_max[1],
        fsm->current_caps.cpu_max[2],
        fsm->thermal_cap,
        m->therm.cpu_max_c,
        pred_names[pred],
        m->misc.screen_on,
        m->bat.capacity_pct,
        g_total_writes,
        (long)g_last_write_ts,
        fsm_elapsed_sec(fsm),
        g_msm_boost_active,
        cap_gap_p0,
        cap_gap_p1,
        (fsm->sustained_reason == 1) ? "gaming_unreachable" : "thermal",
        g_asb_cfg.highload_mode == 1 ? "burst" :
        g_asb_cfg.highload_mode == 2 ? "stable" : "default",
        fsm->ses_gaming_entries, fsm->ses_sustained_entries,
        fsm->ses_thermal_entries, fsm->ses_unreachable_entries,
        fsm->ses_time_heavy_sec, fsm->ses_time_gaming_sec, fsm->ses_time_sustained_sec,
        fsm->ses_gap_samples > 0 ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0,
        fsm->ses_max_gap_p0,
        fsm->ses_max_temp,
        fsm->ses_auto_degraded,
        fsm->bat_time_deep_idle_sec,
        fsm->bat_time_light_idle_sec,
        fsm->bat_wake_cycles);
}



static void persistent_stats_load(void) {
    FILE *f = fopen(PERSISTENT_STATS_FILE, "r");
    if (!f) return;
    fscanf(f, "{\"count\":%d,\"t2s\":%f,\"t2th\":%f,\"temp\":%f,\"gap\":%f,\"eff\":%f}",
           &g_pstats.session_count,
           &g_pstats.avg_time_to_first_sus,
           &g_pstats.avg_time_to_first_thermal,
           &g_pstats.avg_max_temp,
           &g_pstats.avg_gap_p0,
           &g_pstats.avg_efficiency);
    fclose(f);
    if (g_pstats.session_count > PERSISTENT_STATS_MAX_SESSIONS)
        g_pstats.session_count = PERSISTENT_STATS_MAX_SESSIONS;
}

static void persistent_stats_save(const asb_fsm_t *fsm) {
    /* Only save if we have meaningful data */
    if (fsm->ses_sustained_entries == 0 && fsm->ses_time_heavy_sec < 30)
        return;
    float alpha = 1.0f / (g_pstats.session_count + 1);
    if (alpha < 0.1f) alpha = 0.1f; /* EMA: min weight 10% for new data */
    /* Update rolling averages */
    if (fsm->ses_time_to_first_sus > 0)
        g_pstats.avg_time_to_first_sus =
            g_pstats.avg_time_to_first_sus * (1 - alpha) + fsm->ses_time_to_first_sus * alpha;
    if (fsm->ses_time_to_first_thermal > 0)
        g_pstats.avg_time_to_first_thermal =
            g_pstats.avg_time_to_first_thermal * (1 - alpha) + fsm->ses_time_to_first_thermal * alpha;
    if (fsm->ses_max_temp > 0)
        g_pstats.avg_max_temp =
            g_pstats.avg_max_temp * (1 - alpha) + fsm->ses_max_temp * alpha;
    if (fsm->ses_gap_samples > 0) {
        int avg_gap = (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples);
        g_pstats.avg_gap_p0 =
            g_pstats.avg_gap_p0 * (1 - alpha) + avg_gap * alpha;
    }
    if (fsm->ses_sustained_efficiency >= 0)
        g_pstats.avg_efficiency =
            g_pstats.avg_efficiency * (1 - alpha) + fsm->ses_sustained_efficiency * alpha;
    if (g_pstats.session_count < PERSISTENT_STATS_MAX_SESSIONS)
        g_pstats.session_count++;
    FILE *f = fopen(PERSISTENT_STATS_FILE, "w");
    if (!f) return;
    fprintf(f, "{\"count\":%d,\"t2s\":%.1f,\"t2th\":%.1f,\"temp\":%.1f,\"gap\":%.0f,\"eff\":%.1f}",
            g_pstats.session_count,
            g_pstats.avg_time_to_first_sus,
            g_pstats.avg_time_to_first_thermal,
            g_pstats.avg_max_temp,
            g_pstats.avg_gap_p0,
            g_pstats.avg_efficiency);
    fclose(f);
}

/* ─── Profile reader ────────────────────────────────────────── */
static int read_profile_idx(void) {
    char buf[32] = {0};
    int fd = open(PROFILE_FILE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return PROFILE_BALANCED;
    int n = read(fd, buf, sizeof(buf)-1);
    close(fd);
    if (n <= 0) return PROFILE_BALANCED;
    buf[n] = '\0';
    for (int i = 0; buf[i]; i++)
        if (buf[i] == '\n' || buf[i] == '\r') { buf[i] = '\0'; break; }
    if (strcmp(buf, "battery")     == 0) return PROFILE_BATTERY;
    if (strcmp(buf, "performance") == 0) return PROFILE_PERFORMANCE;
    return PROFILE_BALANCED;
}

/* ─── timerfd helpers ───────────────────────────────────────── */
static int make_timerfd(int secs) {
    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0) return -1;
    struct itimerspec its = {
        .it_interval = { secs, 0 },
        .it_value    = { secs, 0 }
    };
    timerfd_settime(fd, 0, &its, NULL);
    return fd;
}

static void arm_timerfd(int fd, int secs) {
    struct itimerspec its = {
        .it_interval = { secs, 0 },
        .it_value    = { secs, 0 }
    };
    timerfd_settime(fd, 0, &its, NULL);
}

static void disarm_timerfd(int fd) {
    struct itimerspec its = {0};
    timerfd_settime(fd, 0, &its, NULL);
}

static void timerfd_drain(int fd) {
    uint64_t exp;
    read(fd, &exp, sizeof(exp)); /* drain the counter */
}

/* ─── Uevent screen monitor ─────────────────────────────────── */
/*
 * Listen on kernel uevent socket.
 * Filter display/backlight events.
 * On screen event, immediately update timers.
 *
 * uevent format: "ACTION@/path\0key=val\0key=val\0..."
 * We care about SUBSYSTEM=backlight or SUBSYSTEM=drm
 */
static int make_uevent_fd(void) {
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC,
                    NETLINK_KOBJECT_UEVENT);
    if (fd < 0) return -1;
    struct sockaddr_nl addr = {
        .nl_family = AF_NETLINK,
        .nl_pid    = getpid(),
        .nl_groups = 1
    };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd); return -1;
    }
    /* Increase buffer to avoid dropping events */
    int buf = 256 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof(buf));
    return fd;
}

/*
 * Read uevent buffer, find screen-related event.
 * Returns:
 *   1  — screen turned on
 *   0  — screen turned off
 *  -1  — not a screen event (ignore)
 */
static int parse_uevent_screen(int fd) {
    char buf[4096];
    int n = recv(fd, buf, sizeof(buf)-1, MSG_DONTWAIT);
    if (n <= 0) return -1;
    buf[n] = '\0';

    int is_display = 0, is_power = 0;
    char *p = buf;
    while (p < buf + n) {
        if (strstr(p, "SUBSYSTEM=backlight") ||
            strstr(p, "SUBSYSTEM=drm")       ||
            strstr(p, "oplus_display")        ||
            strstr(p, "panel"))
            is_display = 1;

        if (strstr(p, "POWER=0") || strstr(p, "brightness=0") ||
            strstr(p, "screen_off") || strstr(p, "BLANK=1"))
            is_power = 0; /* off */
        else if (strstr(p, "POWER=1") || strstr(p, "screen_on") ||
                 strstr(p, "BLANK=0"))
            is_power = 1; /* on */

        p += strlen(p) + 1;
    }
    if (!is_display) return -1;
    return is_power;
}

/* ─── Signal handling ───────────────────────────────────────── */
static volatile int g_running = 1;
static void sig_handler(int sig) {
    (void)sig;
    g_running = 0;
}

/* ─── Main ──────────────────────────────────────────────────── */
int main(int argc, char **argv) {
    /* Fast mode: "status" or "profile:X" — just send command */
    if (argc >= 2) {
        char reply[512] = {0};
        asb_sock_send_cmd(argv[1], reply, sizeof(reply));
        if (reply[0]) puts(reply);
        return 0;
    }

    /* Daemon: check if already running */
    {
        char pidbuf[16] = {0};
        int pfd = open(PID_FILE, O_RDONLY | O_CLOEXEC);
        if (pfd >= 0) {
            read(pfd, pidbuf, sizeof(pidbuf)-1);
            close(pfd);
            pid_t old = (pid_t)atoi(pidbuf);
            if (old > 1 && kill(old, 0) == 0) {
                fprintf(stderr, "asb_governor already running (pid %d)\n", old);
                return 1;
            }
        }
    }

    mkdir("/dev/.asb", 0700);

    {
        char pidbuf[16];
        snprintf(pidbuf, sizeof(pidbuf), "%d\n", getpid());
        int pfd = open(PID_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (pfd >= 0) { write(pfd, pidbuf, strlen(pidbuf)); close(pfd); }
    }

    g_logf = fopen(LOG_FILE, "a");
    asb_log("=== asb_governor starting (pid %d) ===", getpid());

    signal(SIGTERM, sig_handler);
    signal(SIGINT,  sig_handler);
    signal(SIGPIPE, SIG_IGN);

    /* Config and subsystem initialization */
    asb_config_defaults(&g_asb_cfg);
    asb_config_load_file(CONFIG_FILE, &g_asb_cfg);
    asb_config_apply_highload_mode(&g_asb_cfg);
    thermal_discover();
    writer_init_cache();
    persistent_stats_load();
    asb_log("persistent stats: sessions=%d avg_t2s=%.0fs avg_temp=%.0f°C avg_gap=%.0f avg_eff=%.0f",
            g_pstats.session_count, g_pstats.avg_time_to_first_sus,
            g_pstats.avg_max_temp, g_pstats.avg_gap_p0, g_pstats.avg_efficiency);

    int profile_idx = read_profile_idx();
    asb_log("initial profile: %d", profile_idx);

    asb_fsm_t fsm;
    fsm_init(&fsm, profile_idx);
    fsm_profile_is_battery = (profile_idx == PROFILE_BATTERY);

    asb_learn_db_t learn;
    learner_init(&learn);

    asb_accum_t accum;
    accum_init(&accum);

    asb_prediction_t cur_pred = learner_predict(&learn);
    learner_adjust_windows(&learn, &fsm.up_window, &fsm.down_window);
    asb_log("learner predict: %d, windows up=%d down=%d",
            cur_pred, fsm.up_window, fsm.down_window);

    int epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0) { perror("epoll_create1"); return 1; }

    int tfd_active = make_timerfd(TIMER_ACTIVE_S);
    int tfd_idle   = make_timerfd(TIMER_IDLE_S);
    int tfd_hourly = make_timerfd(TIMER_HOURLY_S);
    int uefd       = make_uevent_fd();
    int sockfd     = asb_sock_create();

    if (tfd_active < 0 || tfd_idle < 0 || tfd_hourly < 0) {
        asb_log("failed to create timerfds");
        return 1;
    }

    /* Initially: active timer armed, idle timer armed.
     * On DEEP_IDLE: disarm active, arm idle timer.  */
    int screen_on = metrics_screen_on();
    if (!screen_on) {
        disarm_timerfd(tfd_active);
    }

    /* Add all fds to epoll */
    struct epoll_event ev = {0};
    ev.events = EPOLLIN;

    ev.data.fd = tfd_active; epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_active, &ev);
    ev.data.fd = tfd_idle;   epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_idle,   &ev);
    ev.data.fd = tfd_hourly; epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_hourly, &ev);
    if (uefd  >= 0) { ev.data.fd = uefd;   epoll_ctl(epfd, EPOLL_CTL_ADD, uefd,   &ev); }
    if (sockfd >= 0) { ev.data.fd = sockfd; epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev); }

    asb_metrics_t metrics;
    memset(&metrics, 0, sizeof(metrics));

    metrics_read_all(&metrics);
    fsm_update(&fsm, &metrics);
    writer_apply_caps(&fsm.current_caps, 1, fsm.state, fsm.thermal_cap); /* force=1 */
    write_state(&fsm, &metrics, cur_pred);
    /* Startup diagnostics — log what we found */
    {
        int bidx = metrics_find_batt_current_path();
        asb_log("diag: battery_current_path=%s (raw=%d uA = %d mA)",
                bidx >= 0 ? g_batt_current_paths[bidx] : "NOT_FOUND",
                metrics.bat.current_ua,
                metrics.bat.current_ma);
        asb_log("diag: screen_on=%d thermal_cpu_zone=%d",
                metrics.misc.screen_on, g_thermal_cpu_zone);
        asb_log("diag: gpu_load=%d%% gpu_maxfreq=%ld",
                metrics.gpu.load_pct, metrics.gpu.max_freq_hz);
        /* CPU topology: log which policies are active */
        cpu_topology_discover();
        if (g_cpu_policy_count == 2)
            asb_log("diag: cpu_topology=policy0+policy6 (2-cluster SD8Elite)");
        else
            asb_log("diag: cpu_topology=policy0+policy4+policy7 (3-cluster fallback)");
        for (int _i = 0; _i < 3; _i++) {
            char _mp[128]; int _maxf;
            if (g_cpu_policy_ids[_i] < 0) continue;
            snprintf(_mp, sizeof(_mp),
                "/sys/devices/system/cpu/cpufreq/policy%d/cpuinfo_max_freq",
                g_cpu_policy_ids[_i]);
            _maxf = sysfs_read_int(_mp, -1);
            asb_log("diag: policy%d cpuinfo_max=%d kHz cap_target=%d kHz",
                    g_cpu_policy_ids[_i], _maxf,
                    (_i < 3) ? fsm.current_caps.cpu_max[_i] : 0);
        }
        asb_log("diag: msm_performance_interface=%s",
                msm_perf_check() ? "available (kernel-level write)" : "not available (cpufreq only)");
        asb_log("diag: cfg heavy_gpu=%d heavy_load=%.1f gaming_gpu=%d sustained_gpu=%d sustained_load=%.1f sustained_temp=%d/%d sustained_lvl=%.2f dwell=%d/%d/%d reassert=%d/%d boost_only=%d throttle_temp=%d highload_mode=%s bat_fast_idle=%d bat_suppress=%d",
                g_asb_cfg.heavy_gpu_enter, g_asb_cfg.heavy_load_enter,
                g_asb_cfg.gaming_gpu_enter, g_asb_cfg.sustained_gpu_min,
                g_asb_cfg.sustained_load_min, g_asb_cfg.sustained_temp_enter,
                g_asb_cfg.sustained_temp_exit,
                g_asb_cfg.sustained_level,
                g_asb_cfg.heavy_min_dwell_s, g_asb_cfg.sustained_min_dwell_s,
                g_asb_cfg.gaming_min_dwell_s,
                g_asb_cfg.reassert_heavy_s, g_asb_cfg.reassert_gaming_s,
                g_asb_cfg.msm_perf_boost_only,
                    g_asb_cfg.thermal_throttle_temp,
                    g_asb_cfg.highload_mode == 1 ? "burst" :
                    g_asb_cfg.highload_mode == 2 ? "stable" : "default",
                    g_asb_cfg.bat_fast_idle_s,
                    g_asb_cfg.bat_suppress_gaming);
        asb_log("diag: bat_fast_idle=%ds bat_light_idle_gpu=%d%% bat_suppress_gaming=%d bat_heavy_load=%.1f",
                g_asb_cfg.bat_fast_idle_s,
                g_asb_cfg.bat_light_idle_gpu,
                g_asb_cfg.bat_suppress_gaming,
                g_asb_cfg.bat_heavy_load_enter);
    }
    asb_log("initial state: %s mA=%d gpu=%d%% load=%.2f",
            asb_state_names[fsm.state],
            metrics.bat.current_ma,
            metrics.gpu.load_pct,
            metrics.cpu.load1);

    /* ─── Reassert tracker ──────────────────────────────────── */
    /* ─── Event loop ─────────────────────────────────────────── */
    struct epoll_event events[MAX_EVENTS];

    while (g_running) {
        /* epoll_wait: block until event.
         * timeout=-1: infinite. CPU = 0% while idle. */
        int nev = epoll_wait(epfd, events, MAX_EVENTS, -1);
        if (nev < 0) {
            if (errno == EINTR) continue;
            break;
        }

        int need_metrics = 0;
        int force_write  = 0;
        int profile_changed = 0;

        /* Keepalive: write state every 60s regardless of caps change.
         * Prevents watchdog from killing governor during long DEEP_IDLE. */
        static time_t g_last_state_touch = 0;
        {
            time_t _now = time(NULL);
            if (_now - g_last_state_touch >= 60) {
                write_state(&fsm, &metrics, cur_pred);
                g_last_state_touch = _now;
            }
        }

        for (int i = 0; i < nev; i++) {
            int fd = events[i].data.fd;

            /* ── Active timer (2s) ─────────────────────────── */
            if (fd == tfd_active) {
                timerfd_drain(fd);
                need_metrics = 1;
            }
            /* ── Idle timer (5s) ────────────────────────────── */
            else if (fd == tfd_idle) {
                timerfd_drain(fd);
                need_metrics = 1;
            }
            /* ── Hourly learner ──────────────────────────────── */
            else if (fd == tfd_hourly) {
                timerfd_drain(fd);
                float avg_drain = 0, avg_screen = 0;
                /* accum_tick not called here — called in need_metrics path */
                if (accum.drain_count > 0) {
                    avg_drain  = accum.drain_sum / accum.drain_count;
                    avg_screen = accum.total_ticks > 0
                                 ? (float)accum.screen_on_ticks / accum.total_ticks
                                 : 0.0f;
                    learner_update(&learn, avg_drain, avg_screen);
                    cur_pred = learner_predict(&learn);
                    learner_adjust_windows(&learn,
                                          &fsm.up_window, &fsm.down_window);
                    asb_log("learner updated: drain=%.1fmA screen=%.0f%% "
                            "predict=%d windows=%d/%d",
                            avg_drain, avg_screen * 100,
                            cur_pred, fsm.up_window, fsm.down_window);
                    accum.drain_sum       = 0;
                    accum.drain_count     = 0;
                    accum.screen_on_ticks = 0;
                    accum.total_ticks     = 0;
                }
            }
            /* ── Uevent (screen events) ──────────────────────── */
            else if (fd == uefd) {
                /* Drain ALL accumulated uevent messages at once.
                 * Kernel sends 20-50 events per millisecond on screen off —
                 * drain all, take the last valid state. */
                int final_scr = -1;
                int cur;
                int drained = 0;
                while ((cur = parse_uevent_screen(uefd)) >= 0 || drained == 0) {
                    if (cur >= 0) final_scr = cur;
                    drained++;
                    if (drained > 64) break; /* guard against infinite loop */
                    cur = parse_uevent_screen(uefd);
                    if (cur < 0 && drained > 0) break;
                    if (cur >= 0) final_scr = cur;
                    drained++;
                }
                if (final_scr >= 0) {
                    int was_on = metrics.misc.screen_on;
                    /* Verify via sysfs for confirmation (one read) */
                    int real_scr = metrics_screen_on();
                    /* If uevent and sysfs agree — accept.
                     * If not — sysfs takes priority (reflects reality). */
                    int confirmed = (final_scr == real_scr) ? final_scr : real_scr;
                    metrics.misc.screen_on = confirmed;

                    if (confirmed != was_on) {
                        asb_log("screen %s (uevent, drained=%d events)",
                                confirmed ? "ON" : "OFF", drained);
                        need_metrics = 1;
                        if (confirmed) {
                            arm_timerfd(tfd_active, TIMER_ACTIVE_S);
                        } else {
                            disarm_timerfd(tfd_active);
                        }
                    }
                }
            }
            /* ── Control socket ──────────────────────────────── */
            else if (fd == sockfd) {
                char cmd[256] = {0};
                struct sockaddr_un src = {0};
                socklen_t srclen = sizeof(src);
                int n = asb_sock_recv(sockfd, cmd, sizeof(cmd), &src, &srclen);
                if (n <= 0) continue;

                asb_log("cmd: %s", cmd);

                if (strncmp(cmd, "profile:", 8) == 0) {
                    const char *pname = cmd + 8;
                    int new_idx = PROFILE_BALANCED;
                    if (strcmp(pname, "battery")     == 0) new_idx = PROFILE_BATTERY;
                    if (strcmp(pname, "performance") == 0) new_idx = PROFILE_PERFORMANCE;
                    if (new_idx != fsm.profile_idx) {
                        fsm.profile_idx = new_idx;
                        fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                        /* Profile-aware highload_mode:
                         * performance → burst (faster retry, better gaming)
                         * battery     → stable (conservative, no burst spikes)
                         * balanced    → keep current config value            */
                        if (new_idx == PROFILE_PERFORMANCE &&
                            g_asb_cfg.highload_mode == 0) {
                            asb_config_apply_burst_override(&g_asb_cfg);
                            asb_log("profile:performance → highload burst applied");
                        } else if (new_idx == PROFILE_BATTERY &&
                                   g_asb_cfg.highload_mode == 1) {
                            asb_config_defaults_highload(&g_asb_cfg);
                            asb_log("profile:battery → highload burst cleared");
                        }
                        profile_changed = 1;
                        force_write = 1;
                        need_metrics = 1;
                        g_last_reassert = 0;
                        asb_sock_reply(sockfd, &src, srclen, "ok");
                        asb_log("profile changed to %d", new_idx);
                    } else {
                        asb_sock_reply(sockfd, &src, srclen, "ok:nochange");
                    }
                }
                else if (strcmp(cmd, "status") == 0) {
                    char jbuf[512];
                    build_status_json(&fsm, &metrics, cur_pred, jbuf, sizeof(jbuf));
                    asb_sock_reply(sockfd, &src, srclen, jbuf);
                }
                else if (strcmp(cmd, "reset-stats") == 0) {
                    fsm_session_reset(&fsm);
                    asb_log("session telemetry reset by cmd");
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strcmp(cmd, "reload") == 0) {
                    int new_idx = read_profile_idx();
                    asb_config_defaults(&g_asb_cfg);
                    asb_config_load_file(CONFIG_FILE, &g_asb_cfg);
                    asb_config_apply_highload_mode(&g_asb_cfg);
                    fsm_session_reset(&fsm);
                    if (new_idx != fsm.profile_idx) {
                        fsm.profile_idx = new_idx;
                        fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                        force_write = 1;
                        need_metrics = 1;
                    }
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strcmp(cmd, "quit") == 0) {
                    asb_sock_reply(sockfd, &src, srclen, "bye");
                    g_running = 0;
                }
                (void)profile_changed;
            }
        } /* for events */

        /* ── Read metrics and update FSM ─────────────────── */
        if (need_metrics) {
            metrics_read_all(&metrics);

            float dummy_drain, dummy_screen;
            if (accum_tick(&accum,
                           metrics.bat.current_ma,
                           metrics.misc.screen_on,
                           &dummy_drain, &dummy_screen)) {
                /* Hour changed inside accum_tick */
                learner_update(&learn, dummy_drain, dummy_screen);
                cur_pred = learner_predict(&learn);
                learner_adjust_windows(&learn, &fsm.up_window, &fsm.down_window);
            }

            int changed = fsm_update(&fsm, &metrics);

            /* AUTO degrade check: burst→stable when gaming caps unreachable */
            if (!fsm.ses_auto_degraded) {
                int avg_gap = (fsm.ses_gap_samples > 0)
                              ? (int)(fsm.ses_gap_p0_sum / fsm.ses_gap_samples) : 0;
                if (asb_config_auto_should_degrade(
                        &g_asb_cfg, avg_gap,
                        fsm.ses_gaming_entries,
                        fsm.ses_sustained_entries,
                        fsm.ses_time_heavy_sec,
                        fsm.ses_time_gaming_sec,
                        fsm.ses_time_sustained_sec,
                        fsm.ses_auto_degraded))
                {
                    asb_config_apply_stable_override(&g_asb_cfg);
                    fsm.ses_auto_degraded = 1;
                    long _total = fsm.ses_time_heavy_sec + fsm.ses_time_gaming_sec
                                 + fsm.ses_time_sustained_sec;
                    int _sus_pct = (_total > 0)
                                  ? (int)(fsm.ses_time_sustained_sec * 100 / _total) : 0;
                    asb_log("auto: degraded burst->stable avg_gap=%d sus=%d gaming=%d sus_pct=%d",
                            avg_gap, fsm.ses_sustained_entries,
                            fsm.ses_gaming_entries, _sus_pct);
                }
            }
            if (changed || force_write) {
                int writes = writer_apply_caps(&fsm.current_caps, force_write, fsm.state, fsm.thermal_cap);
                if (writes > 0) {
                    g_total_writes += writes;
                    g_last_write_ts = time(NULL);
                }
                write_state(&fsm, &metrics, cur_pred);

                if (fsm.state_changed) {
                    int ma_v = (metrics.bat.current_ma > 0 && !metrics.bat.charging) ? 1 : 0;
                    /* cap_gap = difference between our target and actual sysfs max */
                    int fsm_rmax0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                    int fsm_rmax1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                    int gap0 = (fsm_rmax0 > 0) ? (fsm.current_caps.cpu_max[0] - fsm_rmax0) : 0;
                    int gap1 = (fsm_rmax1 > 0) ? (fsm.current_caps.cpu_max[1] - fsm_rmax1) : 0;
                    asb_log("FSM: %s mA=%d(v=%d) gpu=%d%% load=%.2f "
                            "t=%d°C gap0=%d gap1=%d writes=%d total=%d",
                            asb_state_names[fsm.state],
                            metrics.bat.current_ma, ma_v,
                            metrics.gpu.load_pct,
                            metrics.cpu.load1,
                            metrics.therm.cpu_max_c,
                            gap0, gap1,
                            writes, g_total_writes);
                    /* On high-state entry, reset reassert timer
                     * to confirm caps immediately, not wait for interval */
                    if (fsm.state == ASB_STATE_HEAVY || fsm.state == ASB_STATE_GAMING)
                        g_last_reassert = 0;

                    /* Log SUSTAINED entry/exit reasons */
                    if (fsm.state == ASB_STATE_SUSTAINED) {
                        if (fsm.sustained_reason == 1) {
                            fsm.ses_unreachable_entries++;
                            asb_log("enter_sustained: gaming_unreachable"
                                    " gap_ticks=%d gap_thresh=%d",
                                    g_asb_cfg.gaming_gap_ticks,
                                    g_asb_cfg.gaming_gap_thresh);
                        }
                        else {
                            fsm.ses_thermal_entries++;
                            asb_log("enter_sustained: thermal temp>=%d thermal_cap=%d",
                                    g_asb_cfg.sustained_temp_enter, fsm.thermal_cap);
                            /* Record time-to-first thermal SUSTAINED */
                            if (fsm.ses_time_to_first_thermal == 0 && fsm.ses_start_ts > 0)
                                fsm.ses_time_to_first_thermal = time(NULL) - fsm.ses_start_ts;
                            /* Recovery counter: each thermal collapse after the first */
                            if (fsm.ses_sustained_entries > 1)
                                fsm.ses_recovery_count++;
                        }
                    }
                    if (fsm.prev_state == ASB_STATE_SUSTAINED) {
                        const char *reason = (metrics.therm.cpu_max_c < g_asb_cfg.sustained_temp_enter)
                                             ? "temp_dropped"
                                             : "no_longer_heavy";
                        /* Compute sustained_efficiency score 0-100
                         * High score = small cap gap + moderate temperature
                         * Low score  = deep thermal throttle + hot chip */
                        int _avg_gap = (fsm.ses_gap_samples > 0)
                                       ? (int)(fsm.ses_gap_p0_sum / fsm.ses_gap_samples) : 0;
                        int _gap_penalty  = (int)(_avg_gap / 15000);
                        if (_gap_penalty > 50) _gap_penalty = 50;
                        int _temp_penalty = (metrics.therm.cpu_max_c > 55)
                                            ? (metrics.therm.cpu_max_c - 55) * 2 : 0;
                        if (_temp_penalty > 50) _temp_penalty = 50;
                        int _eff = 100 - _gap_penalty - _temp_penalty;
                        if (_eff < 0) _eff = 0;
                        /* Keep the worst (lowest) efficiency seen this session */
                        if (fsm.ses_sustained_efficiency < 0 || _eff < fsm.ses_sustained_efficiency)
                            fsm.ses_sustained_efficiency = _eff;
                        asb_log("exit_sustained: %s t=%d°C (exit_thresh=%d) -> %s cooldown=%ds efficiency=%d/100",
                                reason, metrics.therm.cpu_max_c,
                                g_asb_cfg.sustained_temp_exit,
                                asb_state_names[fsm.state],
                                g_asb_cfg.gaming_retry_cooldown_s, _eff);
                    }
                }
            }

            /* ── Reassert caps for HEAVY/GAMING ─────────────── */
            {
                int boost_want = (fsm.state == ASB_STATE_HEAVY || fsm.state == ASB_STATE_GAMING)
                                 && !fsm.thermal_cap
                                 && (fsm.profile_idx == PROFILE_PERFORMANCE);
                /* Log boost_on / boost_off on state change */
                if (boost_want && !g_msm_boost_active) {
                    asb_log("boost_on: %s", asb_state_names[fsm.state]);
                } else if (!boost_want && g_msm_boost_active) {
                    const char *off_reason = fsm.thermal_cap           ? "thermal"
                                           : (fsm.state == ASB_STATE_SUSTAINED) ? "SUSTAINED"
                                           : (fsm.profile_idx != PROFILE_PERFORMANCE) ? "profile!=perf"
                                           : asb_state_names[fsm.state];
                    asb_log("boost_off: %s", off_reason);
                }
                g_msm_boost_active = boost_want;
            }
            if ((fsm.state == ASB_STATE_HEAVY || fsm.state == ASB_STATE_GAMING) && !fsm.thermal_cap) {
                int reassert_interval = (fsm.state == ASB_STATE_GAMING)
                                        ? g_asb_cfg.reassert_gaming_s
                                        : g_asb_cfg.reassert_heavy_s;
                time_t now = time(NULL);
                if (now - g_last_reassert >= reassert_interval) {
                    int ok = msm_perf_write_all_max(
                                fsm.current_caps.cpu_max[0],
                                fsm.current_caps.cpu_max[1]);
                    g_last_reassert = now;
                    g_last_reassert_ok = (ok == 0) ? 1 : 0;
                    if (ok == 0) {
                        asb_log("reassert: %s cpu_max=[%d,%d] t=%d°C",
                                asb_state_names[fsm.state],
                                fsm.current_caps.cpu_max[0],
                                fsm.current_caps.cpu_max[1],
                                metrics.therm.cpu_max_c);
                    }
                }
            } else {
                if (fsm.state < ASB_STATE_HEAVY || fsm.thermal_cap) {
                    g_last_reassert = 0;
                    g_msm_boost_active = 0;
                }
            }
        }
    } /* while running */

    /* ── Cleanup ─────────────────────────────────────────────── */
    asb_log("governor stopping");
    close(tfd_active);
    close(tfd_idle);
    close(tfd_hourly);
    if (uefd  >= 0) close(uefd);
    if (sockfd >= 0) close(sockfd);
    close(epfd);
    persistent_stats_save(&fsm);
    asb_log("persistent stats saved: sessions=%d", g_pstats.session_count);
    unlink(ASB_SOCK_PATH);
    unlink(PID_FILE);
    if (g_logf) fclose(g_logf);
    return 0;
}
