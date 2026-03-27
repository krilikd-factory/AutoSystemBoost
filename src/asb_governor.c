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

#define TIMER_ACTIVE_S  2   /* metrics interval, screen ON  */
#define TIMER_IDLE_S    5   /* metrics interval, screen OFF */
#define TIMER_DEEP_S   10   /* metrics interval, battery deep idle (V30) */
#define TIMER_HOURLY_S  3600

#define STATE_FILE      "/dev/.asb/state"
#define LOG_FILE        "/dev/.asb/governor.log"
#define LOG_MAX_BYTES   409600  /* 400KB max, then rotate */
#define LOG_BACKUP      "/dev/.asb/governor.log.1"
#define PID_FILE        "/dev/.asb/governor.pid"
#define PROFILE_FILE    "/data/adb/modules/AutoSystemBoost/current_profile"
#define CONFIG_FILE     "/data/adb/modules/AutoSystemBoost/config/governor.conf"

#define MAX_EVENTS      8

static FILE *g_logf = NULL;
asb_runtime_config_t g_asb_cfg;
static time_t g_last_reassert = 0;
static int g_last_reassert_ok = 0;
static int g_msm_boost_active = 0;

static void asb_log(const char *fmt, ...) __attribute__((format(printf,1,2)));
static int g_log_writes = 0;
static void asb_log(const char *fmt, ...) {
    if (!g_logf) return;
    if (++g_log_writes % 200 == 0) {
        long pos = ftell(g_logf);
        if (pos > LOG_MAX_BYTES) {
            fclose(g_logf);
            rename(LOG_FILE, LOG_BACKUP);
            g_logf = fopen(LOG_FILE, "w");
            if (!g_logf) return;
            fprintf(g_logf, "[rotated] previous log: %s\n", LOG_BACKUP);
        }
    }
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

#define PERSISTENT_STATS_DIR  "/data/adb/modules/AutoSystemBoost/runtime"
#define PERSISTENT_STATS_FILE "/data/adb/modules/AutoSystemBoost/runtime/session_stats.json"
static const char *g_pstats_files[3] = {
    PERSISTENT_STATS_DIR "/pstats_battery.json",
    PERSISTENT_STATS_DIR "/pstats_balanced.json",
    PERSISTENT_STATS_DIR "/pstats_performance.json"
};
#define SESSION_HISTORY_FILE  "/data/adb/modules/AutoSystemBoost/runtime/session_history.jsonl"
#define SESSION_HISTORY_MAX   10
#define SESSION_HISTORY_LINE_MAX 1024
#define STATUS_JSON_MAX          1024
#define PERSISTENT_STATS_MAX_SESSIONS 10
#define BAT_FAST_IDLE_FLOOR  5  /* safety: feedback loops cannot go below 5s */

#define ASB_VERSION "V31"

#define INTENT_UNKNOWN    0
#define INTENT_BENCHMARK  1
#define INTENT_LONG_GAME  2
#define INTENT_IDLE       3
#define INTENT_MIXED      4
#define INTENT_SLEEP_IDLE 5
static const char *intent_names[] = {"unknown","benchmark","long_game","idle","mixed","sleep_idle"};

/* --- Atomic file write helper --- */
static int atomic_write_file(const char *path, const char *content) {
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return -1;
    fputs(content, f);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    return rename(tmp, path);
}

/* --- Stale session sweeper --- */
static int rewrite_last_history_end(const char *new_end) {
    FILE *rf = fopen(SESSION_HISTORY_FILE, "r");
    if (!rf) return 0;

    char **lines = NULL;
    size_t count = 0, cap = 0;
    char buf[2048];
    int last_json_idx = -1;

    while (fgets(buf, sizeof(buf), rf)) {
        if (count == cap) {
            size_t new_cap = cap ? cap * 2 : 64;
            char **tmp = (char **)realloc(lines, new_cap * sizeof(char *));
            if (!tmp) {
                fclose(rf);
                for (size_t i = 0; i < count; i++) free(lines[i]);
                free(lines);
                return 0;
            }
            lines = tmp;
            cap = new_cap;
        }
        size_t blen = strlen(buf);
        lines[count] = (char *)malloc(blen + 1);
        if (!lines[count]) {
            fclose(rf);
            for (size_t i = 0; i < count; i++) free(lines[i]);
            free(lines);
            return 0;
        }
        memcpy(lines[count], buf, blen + 1);
        if (buf[0] == '{') last_json_idx = (int)count;
        count++;
    }
    fclose(rf);
    if (last_json_idx < 0) {
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }

    char *line = lines[last_json_idx];
    size_t len = strlen(line);
    int had_nl = (len > 0 && line[len-1] == '\n');
    if (had_nl) line[len-1] = '\0';

    char *tag = strstr(line, "\"end\":\"");
    if (!tag) {
        if (had_nl) line[len-1] = '\n';
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }
    char *val_start = tag + strlen("\"end\":\"");
    char *val_end = strchr(val_start, '"');
    if (!val_end) {
        if (had_nl) line[len-1] = '\n';
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }

    size_t prefix_len = (size_t)(val_start - line);
    const char *suffix = val_end;
    int add_partial = (strstr(line, "\"partial\":1") == NULL);
    size_t need = prefix_len + strlen(new_end) + strlen(suffix) +
                  (add_partial ? strlen(",\"partial\":1") : 0) + 8;
    char *patched = (char *)calloc(1, need);
    if (!patched) {
        if (had_nl) line[len-1] = '\n';
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }

    snprintf(patched, need, "%.*s%s%s", (int)prefix_len, line, new_end, suffix);
    if (add_partial) {
        char *brace = strrchr(patched, '}');
        if (brace) {
            *brace = '\0';
            strncat(patched, ",\"partial\":1}", need - strlen(patched) - 1);
        }
    }
    if (had_nl) strncat(patched, "\n", need - strlen(patched) - 1);

    free(lines[last_json_idx]);
    lines[last_json_idx] = patched;

    char tmp_path[256];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", SESSION_HISTORY_FILE);
    FILE *wf = fopen(tmp_path, "w");
    if (!wf) {
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }
    for (size_t i = 0; i < count; i++) fputs(lines[i], wf);
    fflush(wf);
    fsync(fileno(wf));
    fclose(wf);
    rename(tmp_path, SESSION_HISTORY_FILE);

    for (size_t i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 1;
}

static void sweep_stale_session(void) {
    FILE *rf = fopen(SESSION_HISTORY_FILE, "r");
    char last_line[2048] = {0};
    char buf[2048];
    if (rf) {
        while (fgets(buf, sizeof(buf), rf)) {
            if (buf[0] == '{') {
                strncpy(last_line, buf, sizeof(last_line)-1);
                last_line[sizeof(last_line)-1] = '\0';
            }
        }
        fclose(rf);
    }

    int end_missing = (last_line[0] != '\0' &&
        (strstr(last_line, "\"end\":\"\"") || strstr(last_line, "\"end\":\"none\"")));
    if (end_missing) {
        if (rewrite_last_history_end("stale_recovered"))
            asb_log("sweep: stale history session patched -> end=stale_recovered, partial=1");
        else
            asb_log("sweep: detected stale history session but failed to patch");
    }

    FILE *lf = fopen(LOG_FILE, "r");
    if (!lf) return;
    int has_session_start = 0;
    int has_session_end = 0;
    while (fgets(buf, sizeof(buf), lf)) {
        if (strstr(buf, "session_start")) has_session_start = 1;
        if (strstr(buf, "profile changed") || strstr(buf, "session_end") || strstr(buf, "idle_boundary"))
            has_session_end = 1;
    }
    fclose(lf);
    if (has_session_start && !has_session_end) {
        asb_log("sweep: previous governor session may not have closed cleanly");
        if (!end_missing && last_line[0] != '\0')
            asb_log("sweep: history already finalized or no patchable end field found");
    }
}

typedef struct {
    int   session_count;
    float avg_time_to_first_sus;
    float avg_time_to_first_thermal;
    float avg_max_temp;
    float avg_gap_p0;
    float avg_efficiency;
    int   degrade_count;
    int   hot_fail_count;
    float avg_degrade_age;
    int   bat_tune_cooldown;
    /* V30: cause streak -- consecutive sessions with same limiter/reason */
    int   cause_streak;       /* how many consecutive same-cause sessions */
    int   cause_streak_type;  /* 0=none 1=wake_noise 2=screen_on 3=no_settle 4=vendor_clamp 5=thermal */
    /* V30: OTA quarantine -- skip learning after environment change */
    int   quarantine_remaining; /* >0 = skip pstats learning for N more clean sessions */
} asb_persistent_stats_t;

static asb_persistent_stats_t g_pstats_per[3] = {{0},{0},{0}};
static asb_persistent_stats_t g_pstats = {0};


static void write_state(const asb_fsm_t *fsm, const asb_metrics_t *m,
                        asb_prediction_t pred)
{
    static const char *profile_names[] = {"battery","balanced","performance"};
    static const char *pred_names[] = {"unknown","idle","light","active"};

    FILE *f = fopen(STATE_FILE ".tmp", "w");
    if (!f) return;
    int rmax0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
    int rmax1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
    fprintf(f,
        "state=%s\nprofile=%s\n"
        "mA=%d\ngpu_pct=%d\nload1=%.2f\n"
        "cpu_max=%d,%d,%d\n"
        "thermal=%d\ncap_temp=%d\n"
        "headroom_pct=%d\nperf_cap_p0=%d\nperf_cap_p6=%d\n"
        "predict=%s\n"
        "screen=%d\ncapacity=%d\n"
        "dwell_sec=%ld\nboost=%d\n"
        "cap_gap_p0=%d\ncap_gap_p1=%d\n"
        "last_sustained_reason=%s\n"
        "highload_mode=%s\n"
        "ses_gaming=%d\nses_sustained=%d\nses_thermal=%d\nses_unreachable=%d\n"
        "ses_t_heavy=%ld\nses_t_gaming=%ld\nses_t_sustained=%ld\n"
        "ses_avg_gap_p0=%d\nses_max_gap_p0=%d\nses_max_temp=%d\nses_auto_degraded=%d\n"
        "bat_deep_idle=%ld\nbat_light_idle=%ld\nbat_moderate=%ld\nbat_wake_cycles=%d\n"
        "bat_screen_off=%d\nbat_ttd=%ld\n"
        "ses_t2s=%ld\nses_t2thermal=%ld\nses_t2g=%ld\nses_efficiency=%d\nses_recovery=%d\n"
        "hist_sessions=%d\nhist_t2s=%.0f\nhist_temp=%.0f\nhist_gap=%.0f\nhist_eff=%.0f\nhist_deg=%d\n",
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
        m->therm.headroom_pct,
        m->therm.perf_cap_p0,
        m->therm.perf_cap_p6,
        pred_names[pred],
        m->misc.screen_on,
        m->bat.capacity_pct,
        fsm_elapsed_sec(fsm),
        g_msm_boost_active,
        (rmax0 > 0) ? (fsm->current_caps.cpu_max[0] - rmax0) : 0,
        (rmax1 > 0) ? (fsm->current_caps.cpu_max[1] - rmax1) : 0,
        (fsm->sustained_reason == 1) ? "gaming_unreachable" : "thermal",
        g_asb_cfg.highload_mode == 1 ? "burst" :
        g_asb_cfg.highload_mode == 2 ? "stable" :
        g_asb_cfg.highload_mode == 3 ? "auto" : "default",
        fsm->ses_gaming_entries, fsm->ses_sustained_entries,
        fsm->ses_thermal_entries, fsm->ses_unreachable_entries,
        fsm->ses_time_heavy_sec, fsm->ses_time_gaming_sec, fsm->ses_time_sustained_sec,
        fsm->ses_gap_samples > 0 ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0,
        fsm->ses_max_gap_p0,
        fsm->ses_max_temp,
        fsm->ses_auto_degraded,
        fsm->bat_time_deep_idle_sec,
        fsm->bat_time_light_idle_sec,
        fsm->bat_time_moderate_sec,
        fsm->bat_wake_cycles,
        fsm->bat_screen_off_count,
        fsm->bat_time_to_first_deep,
        fsm->ses_time_to_first_sus,
        fsm->ses_time_to_first_thermal,
        fsm->ses_time_to_first_gaming,
        fsm->ses_sustained_efficiency,
        fsm->ses_recovery_count,
        g_pstats.session_count,
        g_pstats.avg_time_to_first_sus,
        g_pstats.avg_max_temp,
        g_pstats.avg_gap_p0,
        g_pstats.avg_efficiency,
        g_pstats.degrade_count);
    long _active = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec + fsm->ses_time_sustained_sec;
    int _sus_pct = (_active > 0) ? (int)(fsm->ses_time_sustained_sec * 100 / _active) : 0;
    long _bat_tot = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec + fsm->bat_time_moderate_sec;
    int _idle_q = -1;
    if (_bat_tot > 30) {
        _idle_q = (int)(fsm->bat_time_deep_idle_sec * 100 / _bat_tot);
        int _wp = (fsm->bat_wake_cycles > 2) ? (fsm->bat_wake_cycles - 2) * 5 : 0;
        _idle_q -= _wp;
        if (_idle_q < 0) _idle_q = 0;
    }
    int _cap_eff = -1;
    if (fsm->ses_gaming_entries > 0 && fsm->ses_gap_samples > 0) {
        int _avg_gap = (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples);
        int _target = (fsm->current_caps.cpu_max[0] > 0) ? fsm->current_caps.cpu_max[0] / 10 : 1;
        _cap_eff = (int)((_target - _avg_gap) * 100 / _target);
        if (_cap_eff < 0) _cap_eff = 0;
        if (_cap_eff > 100) _cap_eff = 100;
    }
    fprintf(f, "sus_pct=%d\nidle_q=%d\ncap_eff=%d\n", _sus_pct, _idle_q, _cap_eff);
    {
        int _pidx = fsm->profile_idx;
        if (_pidx < 0 || _pidx > 2) _pidx = 1;
        fprintf(f, "intent=%s\nhot_fail=%d\ndegrade_at_age=%ld\nprofile_deg=%d\n",
                (fsm->ses_intent >= 0 && fsm->ses_intent <= 5)
                    ? intent_names[fsm->ses_intent] : "unknown",
                g_pstats_per[_pidx].hot_fail_count,
                fsm->ses_degrade_at_age,
                g_pstats_per[_pidx].degrade_count);
    }
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    rename(STATE_FILE ".tmp", STATE_FILE);
}

static int g_total_writes = 0;
static time_t g_last_write_ts = 0;

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
        "\"headroom_pct\":%d,\"perf_cap_p0\":%d,\"perf_cap_p6\":%d,"
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
        m->therm.headroom_pct,
        m->therm.perf_cap_p0,
        m->therm.perf_cap_p6,
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
        g_asb_cfg.highload_mode == 2 ? "stable" :
        g_asb_cfg.highload_mode == 3 ? "auto" : "default",
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
    {
        long _act = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec + fsm->ses_time_sustained_sec;
        int _sp = (_act > 0) ? (int)(fsm->ses_time_sustained_sec * 100 / _act) : 0;
        long _bt = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec + fsm->bat_time_moderate_sec;
        int _iq = -1;
        if (_bt > 30) {
            _iq = (int)(fsm->bat_time_deep_idle_sec * 100 / _bt);
            int _wp = (fsm->bat_wake_cycles > 2) ? (fsm->bat_wake_cycles - 2) * 5 : 0;
            _iq -= _wp; if (_iq < 0) _iq = 0;
        }
        int _ce = -1;
        if (fsm->ses_gaming_entries > 0 && fsm->ses_gap_samples > 0) {
            int _ag = (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples);
            int _tg = fsm->current_caps.cpu_max[0] > 0 ? fsm->current_caps.cpu_max[0] / 10 : 1;
            _ce = (int)((_tg - _ag) * 100 / _tg);
            if (_ce < 0) _ce = 0;
            if (_ce > 100) _ce = 100;
        }
        snprintf(out + strlen(out) - 1, outlen - (int)strlen(out),
            ",\"sus_pct\":%d,\"idle_q\":%d,\"cap_eff\":%d,"
            "\"eff_sus_lvl\":%.2f,\"eff_sus_temp\":%d,\"eff_gr_cd\":%d,\"eff_gr_temp\":%d,"
            "\"eff_bat_fi\":%d,\"eff_bat_hl\":%.1f,\"eff_bat_ml\":%.1f,\"eff_bat_idle_gpu\":%d}",
            _sp, _iq, _ce,
            g_asb_cfg.sustained_level, g_asb_cfg.sustained_temp_enter,
            g_asb_cfg.gaming_retry_cooldown_s, g_asb_cfg.gaming_retry_temp_max,
            g_asb_cfg.bat_fast_idle_s,
            g_asb_cfg.bat_heavy_load_enter,
            g_asb_cfg.bat_moderate_load_enter,
            g_asb_cfg.bat_light_idle_gpu);
        int _pidx = fsm->profile_idx;
        if (_pidx < 0 || _pidx > 2) _pidx = 1;
        snprintf(out + strlen(out) - 1, outlen - (int)strlen(out),
            ",\"intent\":\"%s\",\"hot_fail\":%d,\"deg_age\":%ld}",
            (fsm->ses_intent >= 0 && fsm->ses_intent <= 5)
                ? intent_names[fsm->ses_intent] : "unknown",
            g_pstats_per[_pidx].hot_fail_count,
            fsm->ses_degrade_at_age);
    }
}



static void pstats_load_one(const char *path, asb_persistent_stats_t *ps) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    fscanf(f, "{\"count\":%d,\"t2s\":%f,\"t2th\":%f,\"temp\":%f,\"gap\":%f,\"eff\":%f",
           &ps->session_count, &ps->avg_time_to_first_sus,
           &ps->avg_time_to_first_thermal, &ps->avg_max_temp,
           &ps->avg_gap_p0, &ps->avg_efficiency);
    if (fscanf(f, ",\"deg\":%d", &ps->degrade_count) != 1)
        ps->degrade_count = 0;
    if (fscanf(f, ",\"hot\":%d", &ps->hot_fail_count) != 1)
        ps->hot_fail_count = 0;
    if (fscanf(f, ",\"deg_age\":%f", &ps->avg_degrade_age) != 1)
        ps->avg_degrade_age = 0;
    if (fscanf(f, ",\"btcd\":%d", &ps->bat_tune_cooldown) != 1)
        ps->bat_tune_cooldown = 0;
    if (fscanf(f, ",\"cstrk\":%d", &ps->cause_streak) != 1)
        ps->cause_streak = 0;
    if (fscanf(f, ",\"ctype\":%d", &ps->cause_streak_type) != 1)
        ps->cause_streak_type = 0;
    if (fscanf(f, ",\"quar\":%d", &ps->quarantine_remaining) != 1)
        ps->quarantine_remaining = 0;
    fclose(f);
    if (ps->session_count > PERSISTENT_STATS_MAX_SESSIONS)
        ps->session_count = PERSISTENT_STATS_MAX_SESSIONS;
}

static void pstats_save_one(const char *path, const asb_persistent_stats_t *ps) {
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"count\":%d,\"t2s\":%.1f,\"t2th\":%.1f,\"temp\":%.1f,\"gap\":%.0f,\"eff\":%.1f,\"deg\":%d,\"hot\":%d,\"deg_age\":%.1f,\"btcd\":%d,\"cstrk\":%d,\"ctype\":%d,\"quar\":%d}",
            ps->session_count, ps->avg_time_to_first_sus,
            ps->avg_time_to_first_thermal, ps->avg_max_temp,
            ps->avg_gap_p0, ps->avg_efficiency, ps->degrade_count,
            ps->hot_fail_count, ps->avg_degrade_age,
            ps->bat_tune_cooldown, ps->cause_streak,
            ps->cause_streak_type, ps->quarantine_remaining);
    if (atomic_write_file(path, buf) != 0)
        asb_log("pstats: atomic write failed for %s", path);
}

static void persistent_stats_load(void) {
    pstats_load_one(PERSISTENT_STATS_FILE, &g_pstats);
    for (int i = 0; i < 3; i++)
        pstats_load_one(g_pstats_files[i], &g_pstats_per[i]);
}

#define BAT_TRUST_DIRTY   0
#define BAT_TRUST_PARTIAL 1
#define BAT_TRUST_CLEAN   2
#define BAT_CAUSE_NONE       0
#define BAT_CAUSE_WAKE_NOISE 1
#define BAT_CAUSE_SCREEN_ON  2
#define BAT_CAUSE_NO_SETTLE  3
static int battery_session_trust(const asb_fsm_t *fsm);
static int battery_fail_cause(const asb_fsm_t *fsm, int iq);

static void persistent_stats_save(const asb_fsm_t *fsm) {
    if (fsm->ses_sustained_entries == 0 && fsm->ses_time_heavy_sec < 30
        && fsm->bat_time_deep_idle_sec < 60)
        return;

    int pidx = fsm->profile_idx;
    if (pidx < 0 || pidx > 2) pidx = 1;

    asb_persistent_stats_t *ps = &g_pstats_per[pidx];

    int skip_per_profile = 0;
    if (pidx == PROFILE_BATTERY) {
        int trust = battery_session_trust(fsm);
        if (trust != BAT_TRUST_CLEAN) {
            skip_per_profile = 1;
            asb_log("pstats: battery trust=%d, skipping per-profile memory update",
                    trust);
        }
    }
    if (pidx == PROFILE_PERFORMANCE && fsm->ses_intent == INTENT_BENCHMARK) {
        skip_per_profile = 1;
        asb_log("pstats: benchmark session, skipping per-profile memory update");
    }

    /* V30: OTA quarantine -- skip learning during environment adjustment
     * Only decrement on quality sessions (dur >= 120, not benchmark) */
    if (!skip_per_profile && ps->quarantine_remaining > 0) {
        long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
        skip_per_profile = 1;
        if (dur >= 120 && fsm->ses_intent != INTENT_BENCHMARK) {
            ps->quarantine_remaining--;
            asb_log("pstats: quarantine active (%d remaining), skipping per-profile learning",
                    ps->quarantine_remaining);
        } else {
            asb_log("pstats: quarantine active (session too short/benchmark, not counting down)");
        }
        pstats_save_one(g_pstats_files[pidx], ps);
    }

    if (!skip_per_profile) {
        float alpha = 1.0f / (ps->session_count + 1);
        if (alpha < 0.1f) alpha = 0.1f;

        if (fsm->ses_time_to_first_sus > 0)
            ps->avg_time_to_first_sus =
                ps->avg_time_to_first_sus * (1 - alpha) + fsm->ses_time_to_first_sus * alpha;
        if (fsm->ses_time_to_first_thermal > 0)
            ps->avg_time_to_first_thermal =
                ps->avg_time_to_first_thermal * (1 - alpha) + fsm->ses_time_to_first_thermal * alpha;
        if (fsm->ses_max_temp > 0)
            ps->avg_max_temp =
                ps->avg_max_temp * (1 - alpha) + fsm->ses_max_temp * alpha;
        if (fsm->ses_gap_samples > 0) {
            int avg_gap = (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples);
            ps->avg_gap_p0 =
                ps->avg_gap_p0 * (1 - alpha) + avg_gap * alpha;
        }
        if (fsm->ses_sustained_efficiency >= 0)
            ps->avg_efficiency =
                ps->avg_efficiency * (1 - alpha) + fsm->ses_sustained_efficiency * alpha;
        if (ps->session_count < PERSISTENT_STATS_MAX_SESSIONS)
            ps->session_count++;
        if (fsm->ses_auto_degraded) {
            ps->degrade_count++;
            if (fsm->ses_degrade_at_age > 0)
                ps->avg_degrade_age =
                    ps->avg_degrade_age * (1 - alpha) + fsm->ses_degrade_at_age * alpha;
        }
        {
            long total_act = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec
                            + fsm->ses_time_sustained_sec;
            int sp = (total_act > 0)
                     ? (int)(fsm->ses_time_sustained_sec * 100 / total_act) : 0;
            if (fsm->ses_max_temp >= 100 &&
                (sp >= 50 || (fsm->ses_time_to_first_sus > 0 && fsm->ses_time_to_first_sus <= 90))) {
                ps->hot_fail_count++;
                const char *reason = (sp >= 50 && fsm->ses_time_to_first_sus > 0 &&
                                      fsm->ses_time_to_first_sus <= 90) ? "temp+sus+t2s"
                                   : (sp >= 50) ? "temp+sus" : "temp+t2s";
                asb_log("pstats: hot_fail #%d reason=%s temp=%d sus_pct=%d t2s=%ld",
                        ps->hot_fail_count, reason, fsm->ses_max_temp, sp,
                        fsm->ses_time_to_first_sus);
            }
            if (pidx == PROFILE_PERFORMANCE &&
                fsm->ses_max_temp < 90 && !fsm->ses_auto_degraded) {
                if (ps->hot_fail_count > 0) {
                    ps->hot_fail_count--;
                    asb_log("pstats: good perf session (temp=%d) -> hot_fail decayed to %d",
                            fsm->ses_max_temp, ps->hot_fail_count);
                } else if (ps->degrade_count > 0) {
                    ps->degrade_count--;
                    asb_log("pstats: good perf session -> degrade_count decayed to %d",
                            ps->degrade_count);
                }
                if (ps->avg_degrade_age > 0 && ps->avg_degrade_age < 300.0f) {
                    float old_da = ps->avg_degrade_age;
                    ps->avg_degrade_age += 15.0f;
                    if (ps->avg_degrade_age > 300.0f) ps->avg_degrade_age = 300.0f;
                    asb_log("pstats: good perf session -> avg_degrade_age %.0f->%.0f (rehab)",
                            old_da, ps->avg_degrade_age);
                }
            }
        }

        /* V30: cause_streak -- track consecutive same-cause sessions */
        {
            int cur_cause = 0;
            if (pidx == PROFILE_BATTERY) {
                long bt = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec
                         + fsm->bat_time_moderate_sec;
                int iq = -1;
                if (bt > 60) {
                    iq = (int)(fsm->bat_time_deep_idle_sec * 100 / bt);
                    int wp = (fsm->bat_wake_cycles > 2) ? (fsm->bat_wake_cycles - 2) * 5 : 0;
                    iq -= wp; if (iq < 0) iq = 0;
                }
                int bc = battery_fail_cause(fsm, iq);
                if (bc == BAT_CAUSE_WAKE_NOISE) cur_cause = 1;
                else if (bc == BAT_CAUSE_SCREEN_ON) cur_cause = 2;
                else if (bc == BAT_CAUSE_NO_SETTLE) cur_cause = 3;
            } else if (fsm->ses_headroom_samples >= 10) {
                int _b50 = (int)(100L * fsm->ses_headroom_below50 / fsm->ses_headroom_samples);
                int _hmin = fsm->ses_headroom_min;
                if (fsm->ses_max_temp >= 90) cur_cause = 5;
                else if (_b50 >= 15 || _hmin < 50) cur_cause = 4;
            }
            if (cur_cause > 0 && cur_cause == ps->cause_streak_type) {
                ps->cause_streak++;
            } else {
                ps->cause_streak = (cur_cause > 0) ? 1 : 0;
                ps->cause_streak_type = cur_cause;
            }
            if (ps->cause_streak >= 3 &&
                (ps->cause_streak == 3 || ps->cause_streak == 5 ||
                 ps->cause_streak == 10 || ps->cause_streak % 10 == 0)) {
                static const char *_cn[] = {"none","wake_noise","screen_on","no_settle","vendor_clamp","thermal"};
                asb_log("cause_streak: %s x%d consecutive", _cn[ps->cause_streak_type], ps->cause_streak);
            }
        }

        pstats_save_one(g_pstats_files[pidx], ps);
    }

    float ga = 1.0f / (g_pstats.session_count + 1);
    if (ga < 0.1f) ga = 0.1f;
    if (fsm->ses_time_to_first_sus > 0)
        g_pstats.avg_time_to_first_sus =
            g_pstats.avg_time_to_first_sus * (1-ga) + fsm->ses_time_to_first_sus * ga;
    if (fsm->ses_time_to_first_thermal > 0)
        g_pstats.avg_time_to_first_thermal =
            g_pstats.avg_time_to_first_thermal * (1-ga) + fsm->ses_time_to_first_thermal * ga;
    if (fsm->ses_max_temp > 0)
        g_pstats.avg_max_temp =
            g_pstats.avg_max_temp * (1-ga) + fsm->ses_max_temp * ga;
    if (fsm->ses_gap_samples > 0) {
        int avg_gap = (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples);
        g_pstats.avg_gap_p0 =
            g_pstats.avg_gap_p0 * (1-ga) + avg_gap * ga;
    }
    if (fsm->ses_sustained_efficiency >= 0)
        g_pstats.avg_efficiency =
            g_pstats.avg_efficiency * (1-ga) + fsm->ses_sustained_efficiency * ga;
    if (g_pstats.session_count < PERSISTENT_STATS_MAX_SESSIONS)
        g_pstats.session_count++;
    if (fsm->ses_auto_degraded)
        g_pstats.degrade_count++;
    pstats_save_one(PERSISTENT_STATS_FILE, &g_pstats);
}

/* V30-r3: Session confidence -- how trustworthy is this session's data */
static const char *classify_confidence(
    const asb_fsm_t *fsm, long dur, int hr_n, int idle_quality)
{
    (void)idle_quality;  /* used by caller for classify_signature */
    if (fsm->profile_idx == PROFILE_PERFORMANCE || fsm->profile_idx == PROFILE_BALANCED) {
        /* For non-battery profiles, trust = duration-based only.
         * battery_session_trust() checks bat_total which is always 0
         * for performance sessions -- don't reuse it here. */
        if (dur < 120) return "low";  /* too short to be meaningful */
        if (dur >= 300 && hr_n >= 30) return "high";
        if (dur >= 120 && hr_n >= 10) return "medium";
        return "low";
    }
    if (fsm->profile_idx == PROFILE_BATTERY) {
        int trust = battery_session_trust(fsm);
        if (trust == BAT_TRUST_CLEAN && dur >= 300) return "high";
        if (trust != BAT_TRUST_DIRTY && dur >= 120) return "medium";
        return "low";
    }
    return "low";
}

/* V30-r3: Session signature -- what kind of session was this */
static const char *classify_signature(
    const asb_fsm_t *fsm, int sus_pct,
    const char *limiter, int reach, const char *bat_reason,
    const char *conf, int idle_quality)
{
    if (fsm->profile_idx == PROFILE_PERFORMANCE || fsm->profile_idx == PROFILE_BALANCED) {
        if (strcmp(limiter, "vendor_clamp") == 0) return "vendor_clamped";
        /* thermal_limited beats stable_dominant when session is hot */
        int thermal_hot = (fsm->profile_idx == PROFILE_PERFORMANCE)
                          ? (fsm->ses_max_temp >= 90)
                          : (fsm->ses_max_temp >= 80);
        if (strcmp(limiter, "thermal") == 0 || thermal_hot) return "thermal_limited";
        if (fsm->ses_time_to_first_sus > 0 && fsm->ses_time_to_first_sus < 60 && reach < 50)
            return "early_collapse";
        if (reach >= 70 && fsm->ses_time_to_first_sus >= 90 && strcmp(limiter, "reachable") == 0)
            return "clean_burst";
        if (sus_pct >= 60) return "stable_dominant";
        return "mixed";
    }
    if (fsm->profile_idx == PROFILE_BATTERY) {
        /* clean_sleep requires high confidence + good idle + no heavy */
        if (strcmp(bat_reason, "none") == 0 &&
            strcmp(conf, "high") == 0 &&
            idle_quality >= 70 &&
            fsm->ses_time_heavy_sec == 0)
            return "clean_sleep";
        if (strcmp(bat_reason, "wake_noise") == 0) return "wake_noisy";
        if (strcmp(bat_reason, "screen_on") == 0) return "screen_on_drag";
        if (strcmp(bat_reason, "no_settle") == 0) return "no_settle";
        return "mixed";
    }
    return "mixed";
}

/* V30-r3: Anomaly tag -- quick flag for obvious problems */
static const char *classify_anomaly(
    const asb_fsm_t *fsm, long dur, int idle_quality, int cap_eff)
{
    /* extreme_temp: profile-aware (98 perf, 100 others) */
    int extreme_thresh = (fsm->profile_idx == PROFILE_PERFORMANCE) ? 98 : 100;
    if (fsm->ses_max_temp >= extreme_thresh) return "extreme_temp";
    if (fsm->ses_unreachable_entries >= 5) return "unreachable";
    /* efficiency_collapse: performance with very low cap_eff + degraded or low efficiency */
    if ((fsm->profile_idx == PROFILE_PERFORMANCE || fsm->profile_idx == PROFILE_BALANCED)
        && dur >= 600 && cap_eff >= 0 && cap_eff < 45
        && (fsm->ses_sustained_efficiency < 60 || fsm->ses_auto_degraded))
        return "efficiency_collapse";
    /* failed_settle: battery session with terrible idle quality */
    if (fsm->profile_idx == PROFILE_BATTERY && dur >= 900
        && idle_quality >= 0 && idle_quality < 25)
        return "failed_settle";
    if (fsm->profile_idx == PROFILE_BATTERY && fsm->bat_wake_cycles >= 10) return "wake_spike";
    if (dur < 60) return "too_short";
    return "none";
}

static void session_history_append_ex(const asb_fsm_t *fsm, const char *reason) {
    if (fsm->ses_sustained_entries == 0 && fsm->ses_time_heavy_sec < 10
        && fsm->bat_time_deep_idle_sec < 60)
        return;

    /* V30: skip boundary carry-over sessions
     * dur<=0: impossible real session for any profile -- always skip
     * dur<60: short hot profile switches for non-battery non-benchmark */
    long _dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (_dur <= 0) return;
    if (_dur < 60 && fsm->profile_idx != PROFILE_BATTERY
        && fsm->ses_intent != INTENT_BENCHMARK) {
        asb_log("session_history: skipping short boundary session (%lds, profile=%d)", _dur, fsm->profile_idx);
        return;
    }

    static const char *profile_names[] = {"battery","balanced","performance"};
    static const char *mode_names[] = {"default","burst","stable","auto"};
    int mode_idx = g_asb_cfg.highload_mode;
    if (mode_idx < 0 || mode_idx > 3) mode_idx = 0;
    int avg_gap = (fsm->ses_gap_samples > 0)
                  ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0;
    long total_active = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec
                       + fsm->ses_time_sustained_sec;
    int sus_pct = (total_active > 0)
                  ? (int)(fsm->ses_time_sustained_sec * 100 / total_active) : 0;

    char lines[SESSION_HISTORY_MAX][SESSION_HISTORY_LINE_MAX];
    int line_count = 0;
    FILE *rf = fopen(SESSION_HISTORY_FILE, "r");
    if (rf) {
        char buf[SESSION_HISTORY_LINE_MAX];
        while (fgets(buf, sizeof(buf), rf) && line_count < SESSION_HISTORY_MAX) {
            int len = strlen(buf);
            if (len > 0 && buf[len-1] == '\n') buf[len-1] = '\0';
            if (buf[0] == '{') {
                strncpy(lines[line_count], buf, SESSION_HISTORY_LINE_MAX - 1);
                lines[line_count][SESSION_HISTORY_LINE_MAX - 1] = '\0';
                line_count++;
            }
        }
        fclose(rf);
    }

    int start = (line_count >= SESSION_HISTORY_MAX) ? line_count - SESSION_HISTORY_MAX + 1 : 0;

    char tmp_path[256];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", SESSION_HISTORY_FILE);
    FILE *wf = fopen(tmp_path, "w");
    if (!wf) return;
    for (int i = start; i < line_count; i++)
        fprintf(wf, "%s\n", lines[i]);

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M", tm);
    
    long dur = (fsm->ses_start_ts > 0) ? (now - fsm->ses_start_ts) : 0;
    int idle_quality = -1;
    if (fsm->profile_idx == PROFILE_BATTERY) {
        long bat_total = fsm->bat_time_deep_idle_sec +
                         fsm->bat_time_light_idle_sec +
                         fsm->bat_time_moderate_sec;
        if (bat_total > 60) {
            idle_quality = (int)(fsm->bat_time_deep_idle_sec * 100 / bat_total);
            int wake_penalty = (fsm->bat_wake_cycles > 2)
                               ? (fsm->bat_wake_cycles - 2) * 5 : 0;
            idle_quality -= wake_penalty;
            if (idle_quality < 0) idle_quality = 0;
        }
    }
    int cap_eff = -1;
    if (fsm->ses_gaming_entries > 0 && avg_gap > 0) {
        int target = g_profile_bounds[fsm->profile_idx].ceil.cpu_max[0];
        if (target > 0) {
            cap_eff = (int)((target - avg_gap) * 100 / target);
            if (cap_eff < 0) cap_eff = 0;
            if (cap_eff > 100) cap_eff = 100;
        }
    }
    /* V29-r10: headroom session metrics */
    int hr_avg = (fsm->ses_headroom_samples > 0)
                 ? (int)(fsm->ses_headroom_sum / fsm->ses_headroom_samples) : -1;
    int hr_min = (fsm->ses_headroom_samples > 0) ? fsm->ses_headroom_min : -1;
    int hr_b70 = fsm->ses_headroom_below70;
    int hr_b50 = fsm->ses_headroom_below50;

    /* V30: session-level limiter, reachability, battery reason */
    const char *limiter = "none";
    int reach = -1;
    const char *bat_reason = "none";

    if (fsm->profile_idx == PROFILE_BATTERY) {
        /* Battery: compute reason from same logic as self_tune */
        int cause = battery_fail_cause(fsm, idle_quality);
        static const char *br_names[] = {"none","wake_noise","screen_on","no_settle"};
        bat_reason = (cause >= 0 && cause <= 3) ? br_names[cause] : "none";
    } else if (hr_avg >= 0 && fsm->ses_headroom_samples >= 10) {
        /* Performance/Balanced: classify limiter from headroom data */
        int hr_n = fsm->ses_headroom_samples;
        int b50_pct = (hr_n > 0) ? (int)(100L * hr_b50 / hr_n) : 0;
        int b70_pct = (hr_n > 0) ? (int)(100L * hr_b70 / hr_n) : 0;
        /* thermal_hot: profile-aware threshold
         * performance: 90degC (high thermal headroom expected)
         * balanced/other: 80degC (lower threshold matches Python fallback) */
        int thermal_hot = 0;
        if (fsm->profile_idx == PROFILE_PERFORMANCE) {
            thermal_hot = (fsm->ses_max_temp >= 90);
        } else {
            thermal_hot = (fsm->ses_max_temp >= 80);
        }

        if (cap_eff >= 70 && b70_pct < 10 && hr_min >= 70)
            limiter = "reachable";
        else if (cap_eff >= 0 && cap_eff < 55 && (b50_pct >= 15 || hr_min < 50) && !thermal_hot)
            limiter = "vendor_clamp";
        else if (thermal_hot && (b70_pct >= 20 || (cap_eff >= 0 && cap_eff < 60)))
            limiter = "thermal";
        else
            limiter = "mixed";

        /* Reachability score: 0-100, combines cap_eff and headroom */
        if (cap_eff >= 0 && hr_avg >= 0) {
            reach = (cap_eff + hr_avg) / 2;
            if (reach > 100) reach = 100;
        } else if (cap_eff >= 0) {
            reach = cap_eff;
        } else if (hr_avg >= 0) {
            reach = hr_avg;
        }
    }

    /* V30-r3: session-level classification fields */
    const char *conf = classify_confidence(fsm, dur, fsm->ses_headroom_samples, idle_quality);
    const char *sig  = classify_signature(fsm, sus_pct, limiter, reach, bat_reason, conf, idle_quality);
    const char *anomaly = classify_anomaly(fsm, dur, idle_quality, cap_eff);

    /* V30: cap reach when anomaly shows session was clearly limited */
    if (strcmp(anomaly, "extreme_temp") == 0 && reach > 75) {
        reach = 75;
        if (fsm->ses_time_to_first_sus > 0 && fsm->ses_time_to_first_sus < 90)
            reach = 65;
    }
    int mid_tune_n = fsm->ses_mid_tune_count;
    const char *mid_tune = "none";
    if (mid_tune_n > 0) mid_tune = (mid_tune_n >= 3) ? "heavy" : "light";

    fprintf(wf,
        "{\"v\":7,\"ts\":\"%s\",\"profile\":\"%s\",\"mode\":\"%s\",\"end\":\"%s\","
        "\"gaming\":%d,\"sustained\":%d,\"thermal\":%d,\"unreachable\":%d,"
        "\"t_heavy\":%ld,\"t_gaming\":%ld,\"t_sustained\":%ld,"
        "\"avg_gap\":%d,\"max_temp\":%d,\"degraded\":%d,"
        "\"t2s\":%ld,\"t2th\":%ld,\"t2g\":%ld,\"eff\":%d,\"recovery\":%d,"
        "\"sus_pct\":%d,"
        "\"bat_deep\":%ld,\"bat_light\":%ld,\"bat_mod\":%ld,"
        "\"bat_wake\":%d,\"bat_ttd\":%ld,"
        "\"idle_q\":%d,\"cap_eff\":%d,\"dur\":%ld,"
        "\"intent\":\"%s\",\"deg_age\":%ld,"
        "\"asb\":\"%s\",\"learn_exempt\":%d,"
        "\"hr_avg\":%d,\"hr_min\":%d,\"hr_b70\":%d,\"hr_b50\":%d,\"hr_n\":%d,"
        "\"limiter\":\"%s\",\"reach\":%d,\"bat_reason\":\"%s\","
        "\"conf\":\"%s\",\"sig\":\"%s\",\"mid_tune\":\"%s\",\"mid_n\":%d,\"anomaly\":\"%s\"}\n",
        ts, profile_names[fsm->profile_idx], mode_names[mode_idx], reason,
        fsm->ses_gaming_entries, fsm->ses_sustained_entries,
        fsm->ses_thermal_entries, fsm->ses_unreachable_entries,
        fsm->ses_time_heavy_sec, fsm->ses_time_gaming_sec,
        fsm->ses_time_sustained_sec,
        avg_gap, fsm->ses_max_temp, fsm->ses_auto_degraded,
        fsm->ses_time_to_first_sus, fsm->ses_time_to_first_thermal,
        fsm->ses_time_to_first_gaming,
        fsm->ses_sustained_efficiency, fsm->ses_recovery_count,
        sus_pct,
        fsm->bat_time_deep_idle_sec, fsm->bat_time_light_idle_sec,
        fsm->bat_time_moderate_sec,
        fsm->bat_wake_cycles, fsm->bat_time_to_first_deep,
        idle_quality, cap_eff, dur,
        (fsm->ses_intent >= 0 && fsm->ses_intent <= 5)
            ? intent_names[fsm->ses_intent] : "unknown",
        fsm->ses_degrade_at_age,
        ASB_VERSION,
        (fsm->ses_intent == INTENT_BENCHMARK) ? 1 : 0,
        hr_avg, hr_min, hr_b70, hr_b50, fsm->ses_headroom_samples,
        limiter, reach, bat_reason,
        conf, sig, mid_tune, mid_tune_n, anomaly);
    fflush(wf);
    fsync(fileno(wf));
    fclose(wf);
    rename(tmp_path, SESSION_HISTORY_FILE);
}

static int battery_session_trust(const asb_fsm_t *fsm) {
    long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (dur < 120) return BAT_TRUST_DIRTY;
    long bat_total = fsm->bat_time_deep_idle_sec +
                     fsm->bat_time_light_idle_sec +
                     fsm->bat_time_moderate_sec;
    if (dur > 3600 && bat_total < 120 && fsm->bat_wake_cycles <= 2)
        return BAT_TRUST_PARTIAL;
    if (fsm->ses_intent == INTENT_SLEEP_IDLE)
        return BAT_TRUST_PARTIAL;
    return BAT_TRUST_CLEAN;
}

static int battery_fail_cause(const asb_fsm_t *fsm, int iq) {
    long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (dur < 120) return BAT_CAUSE_NONE;
    long bat_total = fsm->bat_time_deep_idle_sec +
                     fsm->bat_time_light_idle_sec +
                     fsm->bat_time_moderate_sec;
    float wph = (dur > 0) ? (float)fsm->bat_wake_cycles * 3600 / dur : 0;
    float heavy_pct = (bat_total + fsm->ses_time_heavy_sec > 0)
                      ? (float)fsm->ses_time_heavy_sec /
                        (bat_total + fsm->ses_time_heavy_sec) : 0;
    if (iq >= 0 && iq < 20 && fsm->bat_time_to_first_deep > 600)
        return BAT_CAUSE_NO_SETTLE;
    if (wph > 12.0f && iq < 40)
        return BAT_CAUSE_WAKE_NOISE;
    if (heavy_pct > 0.5f && iq < 40)
        return BAT_CAUSE_SCREEN_ON;
    if (iq >= 0 && iq < 30)
        return BAT_CAUSE_NO_SETTLE;
    return BAT_CAUSE_NONE;
}

static void session_end_self_tune(const asb_fsm_t *fsm) {
    int tuned = 0;

    if (fsm->ses_gaming_entries >= 2 &&
        fsm->ses_intent != INTENT_BENCHMARK) {
        int avg_gap = (fsm->ses_gap_samples > 0)
                      ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0;

        if (avg_gap > 1500000 && g_asb_cfg.sustained_level > 0.75f) {
            float old = g_asb_cfg.sustained_level;
            g_asb_cfg.sustained_level -= 0.02f;
            if (g_asb_cfg.sustained_level < 0.75f)
                g_asb_cfg.sustained_level = 0.75f;
            asb_log("self_tune: avg_gap=%d >1.5M -> sustained_level %.2f->%.2f",
                    avg_gap, old, g_asb_cfg.sustained_level);
            tuned++;
        }

        if (fsm->ses_sustained_efficiency >= 0 &&
            fsm->ses_sustained_efficiency < 50 &&
            g_asb_cfg.highload_mode != 2) {
            g_asb_cfg.highload_mode = 2;
            asb_config_apply_highload_mode(&g_asb_cfg);
            asb_log("self_tune: efficiency=%d <50 -> forced stable mode",
                    fsm->ses_sustained_efficiency);
            tuned++;
        }

        if (fsm->ses_time_to_first_sus > 0 &&
            fsm->ses_time_to_first_sus < 60 &&
            g_asb_cfg.sustained_temp_enter < 68) {
            int old = g_asb_cfg.sustained_temp_enter;
            g_asb_cfg.sustained_temp_enter += 2;
            if (g_asb_cfg.sustained_temp_enter > 68)
                g_asb_cfg.sustained_temp_enter = 68;
            asb_log("self_tune: t2s=%lds <60s -> sustained_temp_enter %d->%d",
                    fsm->ses_time_to_first_sus, old, g_asb_cfg.sustained_temp_enter);
            tuned++;
        }

        if (fsm->ses_max_temp >= 100 && g_asb_cfg.highload_mode != 2) {
            long total_act = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec
                            + fsm->ses_time_sustained_sec;
            int sp = (total_act > 0)
                     ? (int)(fsm->ses_time_sustained_sec * 100 / total_act) : 0;
            if (sp >= 40) {
                g_asb_cfg.highload_mode = 2;
                asb_config_apply_highload_mode(&g_asb_cfg);
                asb_log("self_tune: max_temp=%d>=100 sus_pct=%d>=40 -> forced stable",
                        fsm->ses_max_temp, sp);
                tuned++;
            }
        }
    }

    if (fsm_profile_is_battery) {
        long bat_total = fsm->bat_time_deep_idle_sec +
                         fsm->bat_time_light_idle_sec +
                         fsm->bat_time_moderate_sec;

        int iq = -1;
        if (bat_total > 60) {
            iq = (int)(fsm->bat_time_deep_idle_sec * 100 / bat_total);
            int wake_pen = (fsm->bat_wake_cycles > 2)
                           ? (fsm->bat_wake_cycles - 2) * 5 : 0;
            iq -= wake_pen;
            if (iq < 0) iq = 0;
        }

        int trust = battery_session_trust(fsm);
        int cause = battery_fail_cause(fsm, iq);
        static const char *cause_names[] = {"none","wake_noise","screen_on","no_settle"};
        asb_persistent_stats_t *bps = &g_pstats_per[PROFILE_BATTERY];

        if (trust == BAT_TRUST_DIRTY) {
            asb_log("self_tune: bat session dirty (too short), skipping");
        } else if (trust == BAT_TRUST_PARTIAL) {
            asb_log("self_tune: bat session partial (sleep/insufficient signal), skipping");
        } else if (bps->bat_tune_cooldown > 0) {
            bps->bat_tune_cooldown--;
            asb_log("self_tune: bat cooldown=%d, skipping tune this session", bps->bat_tune_cooldown + 1);
        } else if (iq >= 70 && bat_total > 300) {
            if (g_asb_cfg.bat_fast_idle_s < 8) {
                int old = g_asb_cfg.bat_fast_idle_s;
                g_asb_cfg.bat_fast_idle_s += 1;
                asb_log("self_tune: bat good iq=%d -> bat_fast_idle %d->%d (relax)",
                        iq, old, g_asb_cfg.bat_fast_idle_s);
                tuned++;
            }
            if (g_asb_cfg.bat_heavy_load_enter > 10.0f) {
                float old = g_asb_cfg.bat_heavy_load_enter;
                g_asb_cfg.bat_heavy_load_enter -= 1.0f;
                asb_log("self_tune: bat good iq=%d -> bat_heavy_load %.1f->%.1f (relax)",
                        iq, old, g_asb_cfg.bat_heavy_load_enter);
                tuned++;
            }
            if (g_asb_cfg.bat_moderate_load_enter > 8.0f) {
                float old = g_asb_cfg.bat_moderate_load_enter;
                g_asb_cfg.bat_moderate_load_enter -= 1.0f;
                asb_log("self_tune: bat good iq=%d -> bat_moderate_load %.1f->%.1f (relax)",
                        iq, old, g_asb_cfg.bat_moderate_load_enter);
                tuned++;
            }
            bps->bat_tune_cooldown = 1;
        } else if (iq >= 0 && iq < 40 && bat_total > 300 && cause != BAT_CAUSE_NONE) {
            asb_log("self_tune: bat bad iq=%d cause=%s, tuning by cause",
                    iq, cause_names[cause]);
            switch (cause) {
            case BAT_CAUSE_WAKE_NOISE:
                if (g_asb_cfg.bat_fast_idle_s > BAT_FAST_IDLE_FLOOR) {
                    int old = g_asb_cfg.bat_fast_idle_s;
                    g_asb_cfg.bat_fast_idle_s -= 1;
                    if (g_asb_cfg.bat_fast_idle_s < BAT_FAST_IDLE_FLOOR)
                        g_asb_cfg.bat_fast_idle_s = BAT_FAST_IDLE_FLOOR;
                    asb_log("self_tune: wake_noise -> bat_fast_idle %d->%d",
                            old, g_asb_cfg.bat_fast_idle_s);
                    tuned++;
                }
                break;
            case BAT_CAUSE_SCREEN_ON:
                if (g_asb_cfg.bat_moderate_load_enter < 15.0f) {
                    float old = g_asb_cfg.bat_moderate_load_enter;
                    g_asb_cfg.bat_moderate_load_enter += 1.0f;
                    asb_log("self_tune: screen_on -> bat_moderate_load %.1f->%.1f",
                            old, g_asb_cfg.bat_moderate_load_enter);
                    tuned++;
                }
                if (g_asb_cfg.bat_heavy_load_enter < 20.0f) {
                    float old = g_asb_cfg.bat_heavy_load_enter;
                    g_asb_cfg.bat_heavy_load_enter += 1.0f;
                    asb_log("self_tune: screen_on -> bat_heavy_load %.1f->%.1f",
                            old, g_asb_cfg.bat_heavy_load_enter);
                    tuned++;
                }
                break;
            case BAT_CAUSE_NO_SETTLE:
                if (g_asb_cfg.bat_fast_idle_s > BAT_FAST_IDLE_FLOOR) {
                    int old = g_asb_cfg.bat_fast_idle_s;
                    g_asb_cfg.bat_fast_idle_s -= 1;
                    if (g_asb_cfg.bat_fast_idle_s < BAT_FAST_IDLE_FLOOR)
                        g_asb_cfg.bat_fast_idle_s = BAT_FAST_IDLE_FLOOR;
                    asb_log("self_tune: no_settle -> bat_fast_idle %d->%d",
                            old, g_asb_cfg.bat_fast_idle_s);
                    tuned++;
                }
                if (g_asb_cfg.bat_moderate_load_enter < 15.0f) {
                    float old = g_asb_cfg.bat_moderate_load_enter;
                    g_asb_cfg.bat_moderate_load_enter += 1.0f;
                    asb_log("self_tune: no_settle -> bat_moderate_load %.1f->%.1f",
                            old, g_asb_cfg.bat_moderate_load_enter);
                    tuned++;
                }
                break;
            }
            bps->bat_tune_cooldown = 2;
        }

        if (bat_total > 300 && fsm->bat_time_moderate_sec > 0) {
            int mod_pct = (int)(fsm->bat_time_moderate_sec * 100 / bat_total);
            if (mod_pct > 40 && g_asb_cfg.bat_light_idle_gpu > 5) {
                int old = g_asb_cfg.bat_light_idle_gpu;
                g_asb_cfg.bat_light_idle_gpu -= 2;
                if (g_asb_cfg.bat_light_idle_gpu < 5)
                    g_asb_cfg.bat_light_idle_gpu = 5;
                asb_log("self_tune: bat MODERATE=%d%% -> bat_light_idle_gpu %d->%d",
                        mod_pct, old, g_asb_cfg.bat_light_idle_gpu);
                tuned++;
            }
        }
    }

    if (tuned > 0)
        asb_log("self_tune: %d adjustments applied (no restart needed)", tuned);
}

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
    read(fd, &exp, sizeof(exp));
}

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
    int buf = 256 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof(buf));
    return fd;
}

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

static volatile int g_running = 1;
static void sig_handler(int sig) {
    (void)sig;
    g_running = 0;
}

int main(int argc, char **argv) {
    if (argc >= 2) {
        char reply[512] = {0};
        asb_sock_send_cmd(argv[1], reply, sizeof(reply));
        if (reply[0]) puts(reply);
        return 0;
    }

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

    asb_config_defaults(&g_asb_cfg);
    asb_config_load_file(CONFIG_FILE, &g_asb_cfg);
    asb_config_apply_highload_mode(&g_asb_cfg);
    thermal_discover();
    writer_init_cache();
    persistent_stats_load();
    sweep_stale_session();

    /* V30: OTA quarantine -- detect environment changes */
    {
        #define ENV_FP_FILE PERSISTENT_STATS_DIR "/env_fingerprint"
        #define QUARANTINE_SESSIONS 3
        char cur_fp[256] = {0};
        char kern[128] = {0};
        FILE *kf = fopen("/proc/version", "r");
        if (kf) { fgets(kern, sizeof(kern), kf); fclose(kf); }
        /* trim newline */
        char *nl = strchr(kern, '\n'); if (nl) *nl = '\0';
        snprintf(cur_fp, sizeof(cur_fp), "%s|%s", ASB_VERSION, kern);

        char old_fp[256] = {0};
        FILE *ef = fopen(ENV_FP_FILE, "r");
        if (ef) { fgets(old_fp, sizeof(old_fp), ef); fclose(ef); }
        nl = strchr(old_fp, '\n'); if (nl) *nl = '\0';

        if (old_fp[0] && strcmp(cur_fp, old_fp) != 0) {
            asb_log("quarantine: environment changed, activating %d-session quarantine", QUARANTINE_SESSIONS);
            asb_log("quarantine: old=%s", old_fp);
            asb_log("quarantine: new=%s", cur_fp);
            for (int i = 0; i < 3; i++) {
                g_pstats_per[i].quarantine_remaining = QUARANTINE_SESSIONS;
                pstats_save_one(g_pstats_files[i], &g_pstats_per[i]);
            }
        }
        /* Always write current fingerprint */
        atomic_write_file(ENV_FP_FILE, cur_fp);
    }

    asb_log("asb_governor %s started", ASB_VERSION);
    asb_log("persistent stats: sessions=%d avg_t2s=%.0fs avg_temp=%.0fdegC avg_gap=%.0f avg_eff=%.0f degraded=%d",
            g_pstats.session_count, g_pstats.avg_time_to_first_sus,
            g_pstats.avg_max_temp, g_pstats.avg_gap_p0, g_pstats.avg_efficiency,
            g_pstats.degrade_count);

    if (g_pstats.session_count >= 3) {
        if (g_pstats.avg_time_to_first_sus > 0) {
            FILE *_hf = fopen(SESSION_HISTORY_FILE, "r");
            if (_hf) {
                char _hbuf[SESSION_HISTORY_LINE_MAX];
                float _ttd_sum = 0; int _ttd_n = 0;
                while (fgets(_hbuf, sizeof(_hbuf), _hf)) {
                    if (!strstr(_hbuf, "\"profile\":\"battery\"")) continue;
                    if (strstr(_hbuf, "\"intent\":\"sleep_idle\"")) continue;
                    char *_pdur = strstr(_hbuf, "\"dur\":");
                    if (_pdur && atol(_pdur + 5) < 120) continue;
                    char *_p = strstr(_hbuf, "\"bat_ttd\":");
                    if (_p) {
                        int _ttd = atoi(_p + 10);
                        if (_ttd > 0) { _ttd_sum += _ttd; _ttd_n++; }
                    }
                }
                fclose(_hf);
                if (_ttd_n >= 2) {
                    float avg_ttd = _ttd_sum / _ttd_n;
                    if (avg_ttd > 60 && g_asb_cfg.bat_fast_idle_s > 10) {
                        int old = g_asb_cfg.bat_fast_idle_s;
                        g_asb_cfg.bat_fast_idle_s = 10;
                        asb_log("feedback: avg_bat_ttd=%.0fs >60s -> bat_fast_idle %d->%d",
                                avg_ttd, old, g_asb_cfg.bat_fast_idle_s);
                    } else if (avg_ttd > 30 && g_asb_cfg.bat_fast_idle_s > 12) {
                        int old = g_asb_cfg.bat_fast_idle_s;
                        g_asb_cfg.bat_fast_idle_s = 12;
                        asb_log("feedback: avg_bat_ttd=%.0fs >30s -> bat_fast_idle %d->%d",
                                avg_ttd, old, g_asb_cfg.bat_fast_idle_s);
                    }
                }
            }
        }
        {
            FILE *_hf2 = fopen(SESSION_HISTORY_FILE, "r");
            if (_hf2) {
                char _hbuf2[SESSION_HISTORY_LINE_MAX];
                long _mod_sum = 0, _total_sum = 0; int _bat_n = 0;
                while (fgets(_hbuf2, sizeof(_hbuf2), _hf2)) {
                    if (!strstr(_hbuf2, "\"profile\":\"battery\"")) continue;
                    if (strstr(_hbuf2, "\"intent\":\"sleep_idle\"")) continue;
                    char *_pdur2 = strstr(_hbuf2, "\"dur\":");
                    if (_pdur2 && atol(_pdur2 + 5) < 120) continue;
                    char *_pd = strstr(_hbuf2, "\"bat_deep\":");
                    char *_pl = strstr(_hbuf2, "\"bat_light\":");
                    char *_pm = strstr(_hbuf2, "\"bat_mod\":");
                    if (_pd && _pl && _pm) {
                        long bd = atol(_pd + 11);
                        long bl = atol(_pl + 12);
                        long bm = atol(_pm + 10);
                        long bt = bd + bl + bm;
                        if (bt > 60) {
                            _mod_sum += bm; _total_sum += bt; _bat_n++;
                        }
                    }
                }
                fclose(_hf2);
                if (_bat_n >= 2 && _total_sum > 0) {
                    int mod_pct = (int)(_mod_sum * 100 / _total_sum);
                    if (mod_pct > 60 && g_asb_cfg.bat_fast_idle_s > 8) {
                        int old = g_asb_cfg.bat_fast_idle_s;
                        g_asb_cfg.bat_fast_idle_s = 8;
                        asb_log("feedback: battery MODERATE=%d%% of idle time "
                                "-> bat_fast_idle %d->%d (tighter wake discipline)",
                                mod_pct, old, g_asb_cfg.bat_fast_idle_s);
                    }
                }
            }
        }
        if (g_asb_cfg.highload_mode == 3 &&
            g_pstats.degrade_count > g_pstats.session_count / 2) {
            asb_config_apply_stable_override(&g_asb_cfg);
            asb_log("feedback: %d/%d sessions degraded -> auto starting as stable",
                    g_pstats.degrade_count, g_pstats.session_count);
        }
    }
    if (g_asb_cfg.bat_fast_idle_s > 0 && g_asb_cfg.bat_fast_idle_s < BAT_FAST_IDLE_FLOOR) {
        asb_log("feedback: bat_fast_idle_s=%d clamped to floor=%d",
                g_asb_cfg.bat_fast_idle_s, BAT_FAST_IDLE_FLOOR);
        g_asb_cfg.bat_fast_idle_s = BAT_FAST_IDLE_FLOOR;
    }

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

    int screen_on = metrics_screen_on();
    if (!screen_on) {
        disarm_timerfd(tfd_active);
    }

    struct epoll_event ev = {0};
    ev.events = EPOLLIN;

    ev.data.fd = tfd_active; epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_active, &ev);
    ev.data.fd = tfd_idle;   epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_idle,   &ev);
    ev.data.fd = tfd_hourly; epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_hourly, &ev);
    if (uefd  >= 0) { ev.data.fd = uefd;   epoll_ctl(epfd, EPOLL_CTL_ADD, uefd,   &ev); }
    if (sockfd >= 0) { ev.data.fd = sockfd; epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev); }

    asb_metrics_t metrics;
    memset(&metrics, 0, sizeof(metrics));

    metrics_read_all(&metrics, 1, 1);  /* startup: always read headroom + thermal */
    fsm_update(&fsm, &metrics);
    writer_apply_caps(&fsm.current_caps, 1, fsm.state, fsm.thermal_cap);
    write_state(&fsm, &metrics, cur_pred);
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
                    g_asb_cfg.highload_mode == 2 ? "stable" :
                    g_asb_cfg.highload_mode == 3 ? "auto" : "default",
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
    asb_log("session_start profile=%s highload=%s bat=%d%% temp=%d sus_enter=%d sus_exit=%d gaming_gpu=%d",
            profile_idx == 0 ? "battery" : profile_idx == 2 ? "performance" : "balanced",
            g_asb_cfg.highload_mode == 1 ? "burst" :
            g_asb_cfg.highload_mode == 2 ? "stable" :
            g_asb_cfg.highload_mode == 3 ? "auto" : "default",
            metrics.bat.capacity_pct, metrics.therm.cpu_max_c,
                    g_asb_cfg.sustained_temp_enter,
                    g_asb_cfg.sustained_temp_exit,
                    g_asb_cfg.gaming_gpu_enter);

    struct epoll_event events[MAX_EVENTS];

    while (g_running) {
        int nev = epoll_wait(epfd, events, MAX_EVENTS, -1);
        if (nev < 0) {
            if (errno == EINTR) continue;
            break;
        }

        int need_metrics = 0;
        int force_write  = 0;
        int profile_changed = 0;

        static time_t g_last_state_touch = 0;
        static time_t g_last_heartbeat   = 0;
        {
            time_t _now = time(NULL);
            if (_now - g_last_state_touch >= 60) {
                write_state(&fsm, &metrics, cur_pred);
                g_last_state_touch = _now;
            }
            if (g_last_heartbeat == 0) g_last_heartbeat = _now;
            if (_now - g_last_heartbeat >= 900) {
                static const char *_snames[] = {"DEEP_IDLE","LIGHT_IDLE","MODERATE","HEAVY","GAMING","SUSTAINED"};
                asb_log("heartbeat: state=%s profile=%d temp=%d headroom=%d%% load=%.1f gpu=%d bat=%d "
                        "ses_heavy=%lds ses_sus=%lds bat_deep=%lds",
                        (fsm.state >= 0 && fsm.state < 6) ? _snames[fsm.state] : "?",
                        fsm.profile_idx,
                        metrics.therm.cpu_max_c,
                        metrics.therm.headroom_pct,
                        metrics.cpu.load1,
                        metrics.gpu.load_pct,
                        metrics.bat.capacity_pct,
                        fsm.ses_time_heavy_sec,
                        fsm.ses_time_sustained_sec,
                        fsm.bat_time_deep_idle_sec);
                g_last_heartbeat = _now;
            }
        }

        for (int i = 0; i < nev; i++) {
            int fd = events[i].data.fd;

            if (fd == tfd_active) {
                timerfd_drain(fd);
                need_metrics = 1;
            }
            else if (fd == tfd_idle) {
                timerfd_drain(fd);
                need_metrics = 1;
            }
            else if (fd == tfd_hourly) {
                timerfd_drain(fd);
                float avg_drain = 0, avg_screen = 0;
                if (accum.drain_count > 0) {
                    avg_drain  = accum.drain_sum / accum.drain_count;
                    avg_screen = accum.total_ticks > 0
                                 ? (float)accum.screen_on_ticks / accum.total_ticks
                                 : 0.0f;
                    learner_update(&learn, avg_drain, avg_screen);
                    cur_pred = learner_predict(&learn);
                    learner_adjust_windows(&learn,
                                          &fsm.up_window, &fsm.down_window);
                    if (g_asb_cfg.log_level >= 1) asb_log("learner updated: drain=%.1fmA screen=%.0f%% "
                            "predict=%d windows=%d/%d",
                            avg_drain, avg_screen * 100,
                            cur_pred, fsm.up_window, fsm.down_window);
                    accum.drain_sum       = 0;
                    accum.drain_count     = 0;
                    accum.screen_on_ticks = 0;
                    accum.total_ticks     = 0;
                }
            }
            else if (fd == uefd) {
                int final_scr = -1;
                int cur;
                int drained = 0;
                while ((cur = parse_uevent_screen(uefd)) >= 0 || drained == 0) {
                    if (cur >= 0) final_scr = cur;
                    drained++;
                    if (drained > 64) break;
                    cur = parse_uevent_screen(uefd);
                    if (cur < 0 && drained > 0) break;
                    if (cur >= 0) final_scr = cur;
                    drained++;
                }
                if (final_scr >= 0) {
                    int was_on = metrics.misc.screen_on;
                    int real_scr = metrics_screen_on();
                    int confirmed = (final_scr == real_scr) ? final_scr : real_scr;
                    metrics.misc.screen_on = confirmed;

                    if (confirmed != was_on) {
                        if (g_asb_cfg.log_level >= 1) asb_log("screen %s (uevent, drained=%d events)",
                                confirmed ? "ON" : "OFF", drained);
                        need_metrics = 1;
                        if (confirmed) {
                            arm_timerfd(tfd_active, TIMER_ACTIVE_S);
                        } else {
                            disarm_timerfd(tfd_active);
                            persistent_stats_save(&fsm);
                            if (fsm_profile_is_battery)
                                fsm.bat_screen_off_count++;
                        }
                    }
                }
            }
            else if (fd == sockfd) {
                char cmd[256] = {0};
                struct sockaddr_un src = {0};
                socklen_t srclen = sizeof(src);
                int n = asb_sock_recv(sockfd, cmd, sizeof(cmd), &src, &srclen);
                if (n <= 0) continue;

                if (g_asb_cfg.log_level >= 1) asb_log("cmd: %s", cmd);

                if (strncmp(cmd, "profile:", 8) == 0) {
                    const char *pname = cmd + 8;
                    int new_idx = PROFILE_BALANCED;
                    if (strcmp(pname, "battery")     == 0) new_idx = PROFILE_BATTERY;
                    if (strcmp(pname, "performance") == 0) new_idx = PROFILE_PERFORMANCE;
                    if (new_idx != fsm.profile_idx) {
                        fsm_flush_state_time(&fsm);
                        session_history_append_ex(&fsm, "profile_change");
                        session_end_self_tune(&fsm);
                        fsm_session_reset(&fsm);

                        fsm.profile_idx = new_idx;
                        fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                        if (new_idx == PROFILE_PERFORMANCE) {
                            asb_config_apply_burst_override(&g_asb_cfg);
                            fsm.gaming_retry_until = 0;
                            asb_persistent_stats_t *pps = &g_pstats_per[PROFILE_PERFORMANCE];
                            if (pps->session_count >= 3 &&
                                pps->avg_max_temp >= 95.0f &&
                                pps->avg_efficiency < 60.0f) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> history says burst futile "
                                        "(avg_temp=%.0f avg_eff=%.0f %d sessions) -> stable",
                                        pps->avg_max_temp, pps->avg_efficiency,
                                        pps->session_count);
                            } else if (pps->session_count >= 2 &&
                                       pps->degrade_count > pps->session_count / 2) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> %d/%d degraded -> stable",
                                        pps->degrade_count, pps->session_count);
                            } else if (pps->hot_fail_count >= 2) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> %d thermal wall hits -> stable",
                                        pps->hot_fail_count);
                            } else if (pps->session_count >= 3 &&
                                       pps->avg_time_to_first_sus > 0 &&
                                       pps->avg_time_to_first_sus < 90.0f) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> avg_t2s=%.0fs <90s -> stable",
                                        pps->avg_time_to_first_sus);
                            } else if (pps->degrade_count >= 2 &&
                                       pps->avg_degrade_age > 0 &&
                                       pps->avg_degrade_age < 120.0f) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> avg_degrade_age=%.0fs <120s -> stable",
                                        pps->avg_degrade_age);
                            } else {
                                asb_log("profile:performance -> auto-burst applied, cooldown cleared");
                            }
                        } else if (new_idx == PROFILE_BATTERY &&
                                   (g_asb_cfg.highload_mode == 1 ||
                                    g_asb_cfg.highload_mode == 3)) {
                            asb_config_defaults_highload(&g_asb_cfg);
                            asb_log("profile:battery -> highload burst/auto cleared");
                        }
                        profile_changed = 1;
                        force_write = 1;
                        need_metrics = 1;
                        g_last_reassert = 0;
                        asb_sock_reply(sockfd, &src, srclen, "ok");
                        asb_log("profile changed to %d (session reset)", new_idx);
                    } else {
                        asb_sock_reply(sockfd, &src, srclen, "ok:nochange");
                    }
                }
                else if (strcmp(cmd, "status") == 0) {
                    char jbuf[STATUS_JSON_MAX];
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
                else if (strncmp(cmd, "start-session:", 14) == 0) {
                    char *rest = cmd + 14;
                    char *colon = strchr(rest, ':');
                    int new_idx = PROFILE_BALANCED;
                    if (strncmp(rest, "battery", 7) == 0)     new_idx = PROFILE_BATTERY;
                    if (strncmp(rest, "performance", 11) == 0) new_idx = PROFILE_PERFORMANCE;
                    fsm_flush_state_time(&fsm);
                    persistent_stats_save(&fsm);
                    session_history_append_ex(&fsm, "new_session");
                    session_end_self_tune(&fsm);
                    fsm.profile_idx = new_idx;
                    fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                    if (colon && *(colon+1)) {
                        char *mode = colon + 1;
                        if (strcmp(mode, "burst") == 0)  g_asb_cfg.highload_mode = 1;
                        else if (strcmp(mode, "stable") == 0) g_asb_cfg.highload_mode = 2;
                        else if (strcmp(mode, "auto") == 0)   g_asb_cfg.highload_mode = 3;
                        else g_asb_cfg.highload_mode = 0;
                        asb_config_apply_highload_mode(&g_asb_cfg);
                    }
                    fsm_session_reset(&fsm);
                    force_write = 1;
                    need_metrics = 1;
                    g_last_reassert = 0;
                    asb_log("session_start profile=%s highload=%s (start-session cmd)",
                            new_idx == 0 ? "battery" : new_idx == 2 ? "performance" : "balanced",
                            g_asb_cfg.highload_mode == 1 ? "burst" :
                            g_asb_cfg.highload_mode == 2 ? "stable" :
                            g_asb_cfg.highload_mode == 3 ? "auto" : "default");
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strcmp(cmd, "end-session") == 0) {
                    fsm_flush_state_time(&fsm);
                    session_history_append_ex(&fsm, "manual_end");
                    session_end_self_tune(&fsm);
                    persistent_stats_save(&fsm);
                    fsm_session_reset(&fsm);
                    asb_log("session_end: manual end-session cmd");
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strcmp(cmd, "quit") == 0) {
                    asb_sock_reply(sockfd, &src, srclen, "bye");
                    g_running = 0;
                }
                (void)profile_changed;
            }
        }

        if (need_metrics) {
            /* V30: cost-aware sensor scheduler
             * Headroom: skip in battery when not under load (screen-off or light state)
             * Thermal: sparse read only in battery screen-off deep idle (strictest gate) */
            static int g_sensor_skip = 0;
            int need_hr = 1;
            int need_thermal = 1;
            if (fsm.profile_idx == PROFILE_BATTERY &&
                (!metrics.misc.screen_on || fsm.state < ASB_STATE_MODERATE)) {
                need_hr = 0;
            }
            if (fsm.profile_idx == PROFILE_BATTERY &&
                !metrics.misc.screen_on &&
                fsm.state <= ASB_STATE_LIGHT_IDLE) {
                g_sensor_skip++;
                if (g_sensor_skip % 3 != 0) need_thermal = 0;
            } else {
                g_sensor_skip = 0;
            }
            metrics_read_all(&metrics, need_hr, need_thermal);

            float dummy_drain, dummy_screen;
            if (accum_tick(&accum,
                           metrics.bat.current_ma,
                           metrics.misc.screen_on,
                           &dummy_drain, &dummy_screen)) {
                learner_update(&learn, dummy_drain, dummy_screen);
                cur_pred = learner_predict(&learn);
                learner_adjust_windows(&learn, &fsm.up_window, &fsm.down_window);
            }

            int changed = fsm_update(&fsm, &metrics);

            /* V29-r10: accumulate headroom telemetry (only real reads) */
            if (metrics.therm.headroom_valid) {
                fsm.ses_headroom_sum += metrics.therm.headroom_pct;
                fsm.ses_headroom_samples++;
                if (metrics.therm.headroom_pct < fsm.ses_headroom_min)
                    fsm.ses_headroom_min = metrics.therm.headroom_pct;
                if (metrics.therm.headroom_pct < 70)
                    fsm.ses_headroom_below70++;
                if (metrics.therm.headroom_pct < 50)
                    fsm.ses_headroom_below50++;
            }

            if (!fsm.ses_auto_degraded &&
                fsm.ses_intent != INTENT_BENCHMARK) {
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
                    fsm.ses_degrade_at_age = (fsm.ses_start_ts > 0)
                                             ? (long)(time(NULL) - fsm.ses_start_ts) : 0;
                    long _total = fsm.ses_time_heavy_sec + fsm.ses_time_gaming_sec
                                 + fsm.ses_time_sustained_sec;
                    int _sus_pct = (_total > 0)
                                  ? (int)(fsm.ses_time_sustained_sec * 100 / _total) : 0;
                    asb_log("auto: degraded burst->stable avg_gap=%d sus=%d gaming=%d sus_pct=%d",
                            avg_gap, fsm.ses_sustained_entries,
                            fsm.ses_gaming_entries, _sus_pct);
                }
            }
            if (!fsm.ses_intent_locked && fsm.ses_start_ts > 0) {
                long ses_age = time(NULL) - fsm.ses_start_ts;
                int have_thermal = (fsm.ses_thermal_entries > 0);
                int have_gaming  = (fsm.ses_gaming_entries > 0);

                if (ses_age >= 90 || have_thermal) {
                    fsm_flush_state_time(&fsm);
                    long total_act = fsm.ses_time_heavy_sec +
                                     fsm.ses_time_gaming_sec +
                                     fsm.ses_time_sustained_sec;

                    if (fsm_profile_is_battery) {
                        if (fsm.state == ASB_STATE_DEEP_IDLE &&
                            fsm.bat_wake_cycles <= 1 &&
                            ses_age >= 1800 &&
                            fsm.bat_time_deep_idle_sec > ses_age / 2) {
                            fsm.ses_intent = INTENT_SLEEP_IDLE;
                        } else if (fsm.bat_time_deep_idle_sec > 60) {
                            fsm.ses_intent = INTENT_IDLE;
                        } else {
                            fsm.ses_intent = INTENT_MIXED;
                        }
                    } else if (have_thermal && total_act > 30 && ses_age < 600 &&
                               (have_gaming || fsm.profile_idx == PROFILE_PERFORMANCE)) {
                        fsm.ses_intent = INTENT_BENCHMARK;
                    } else if (have_gaming && ses_age >= 300) {
                        fsm.ses_intent = INTENT_LONG_GAME;
                    } else if (total_act > 60) {
                        fsm.ses_intent = INTENT_MIXED;
                    }

                    if (fsm.ses_intent != INTENT_UNKNOWN) {
                        fsm.ses_intent_locked = 1;
                        asb_log("intent: classified as %s (age=%lds gaming=%d thermal=%d)",
                                intent_names[fsm.ses_intent], ses_age,
                                have_gaming, have_thermal);

                        if (fsm.profile_idx == PROFILE_PERFORMANCE) {
                            if (fsm.ses_intent == INTENT_BENCHMARK && have_thermal) {
                                asb_log("intent: benchmark+thermal detected but burst preserved (letting kernel thermal protect)");
                            } else if (fsm.ses_intent == INTENT_LONG_GAME) {
                                if (g_asb_cfg.sustained_reentry_cooldown_s < 30)
                                    g_asb_cfg.sustained_reentry_cooldown_s = 30;
                                asb_log("intent: long_game -> reentry_cooldown=30s");
                            }
                        }
                    }
                }
            }
            if (fsm.state == ASB_STATE_DEEP_IDLE) {
                long idle_sec = fsm_elapsed_sec(&fsm);
                if (idle_sec >= 1800) {
                    fsm_flush_state_time(&fsm);
                    if (fsm.ses_time_heavy_sec > 0 ||
                        fsm.bat_time_deep_idle_sec > 60) {
                        session_history_append_ex(&fsm, "idle_boundary");
                        session_end_self_tune(&fsm);
                        persistent_stats_save(&fsm);
                        fsm_session_reset(&fsm);
                        asb_log("session_boundary: 30min DEEP_IDLE, stats saved+reset");
                    }
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
                    int fsm_rmax0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                    int fsm_rmax1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                    int gap0 = (fsm_rmax0 > 0) ? (fsm.current_caps.cpu_max[0] - fsm_rmax0) : 0;
                    int gap1 = (fsm_rmax1 > 0) ? (fsm.current_caps.cpu_max[1] - fsm_rmax1) : 0;
                    if (g_asb_cfg.log_level >= 1) asb_log("FSM: %s mA=%d(v=%d) gpu=%d%% load=%.2f "
                            "t=%ddegC gap0=%d gap1=%d writes=%d total=%d",
                            asb_state_names[fsm.state],
                            metrics.bat.current_ma, ma_v,
                            metrics.gpu.load_pct,
                            metrics.cpu.load1,
                            metrics.therm.cpu_max_c,
                            gap0, gap1,
                            writes, g_total_writes);
                    if (fsm.state == ASB_STATE_HEAVY || fsm.state == ASB_STATE_GAMING)
                        g_last_reassert = 0;

                    if (fsm.state == ASB_STATE_SUSTAINED) {
                        if (fsm.sustained_reason == 1) {
                            fsm.ses_unreachable_entries++;
                            asb_log("enter_sustained: gaming_unreachable"
                                    " gap_ticks=%d gap_thresh=%d",
                                    g_asb_cfg.gaming_gap_ticks,
                                    g_asb_cfg.gaming_gap_thresh);
                            if (fsm.ses_unreachable_entries >= 3 &&
                                g_asb_cfg.sustained_level > 0.72f) {
                                float _old_sl = g_asb_cfg.sustained_level;
                                g_asb_cfg.sustained_level -= 0.02f;
                                if (g_asb_cfg.sustained_level < 0.72f)
                                    g_asb_cfg.sustained_level = 0.72f;
                                asb_log("mid_tune: gap_episodes=%d >=3 -> sustained_level %.2f->%.2f",
                                        fsm.ses_unreachable_entries, _old_sl, g_asb_cfg.sustained_level);
                                fsm.ses_mid_tune_count++;
                                fsm.ses_mid_tune_dir = -1;  /* downward adjustment */
                            }
                        }
                        else {
                            fsm.ses_thermal_entries++;
                            if (metrics.therm.headroom_pct > 0 && metrics.therm.headroom_pct < 50) {
                                asb_log("enter_sustained: headroom=%d%% (perf_cap p0=%d p6=%d) -- kernel thermal cap detected before temp threshold",
                                        metrics.therm.headroom_pct,
                                        metrics.therm.perf_cap_p0,
                                        metrics.therm.perf_cap_p6);
                            } else {
                                asb_log("enter_sustained: thermal temp>=%d thermal_cap=%d headroom=%d%%",
                                        g_asb_cfg.sustained_temp_enter, fsm.thermal_cap,
                                        metrics.therm.headroom_pct);
                            }
                            if (fsm.ses_time_to_first_thermal == 0 && fsm.ses_start_ts > 0)
                                fsm.ses_time_to_first_thermal = time(NULL) - fsm.ses_start_ts;
                            if (fsm.ses_sustained_entries > 1)
                                fsm.ses_recovery_count++;
                        }
                    }
                    if (fsm.prev_state == ASB_STATE_SUSTAINED) {
                        const char *reason = (metrics.therm.cpu_max_c < g_asb_cfg.sustained_temp_enter)
                                             ? "temp_dropped"
                                             : "no_longer_heavy";
                        int _avg_gap = (fsm.ses_gap_samples > 0)
                                       ? (int)(fsm.ses_gap_p0_sum / fsm.ses_gap_samples) : 0;
                        int _gap_penalty  = (int)(_avg_gap / 15000);
                        if (_gap_penalty > 50) _gap_penalty = 50;
                        int _temp_penalty = (metrics.therm.cpu_max_c > 55)
                                            ? (metrics.therm.cpu_max_c - 55) * 2 : 0;
                        if (_temp_penalty > 50) _temp_penalty = 50;
                        int _eff = 100 - _gap_penalty - _temp_penalty;
                        if (_eff < 0) _eff = 0;
                        if (fsm.ses_sustained_efficiency < 0 || _eff < fsm.ses_sustained_efficiency)
                            fsm.ses_sustained_efficiency = _eff;
                        asb_log("exit_sustained: %s t=%ddegC (exit_thresh=%d) -> %s cooldown=%ds efficiency=%d/100",
                                reason, metrics.therm.cpu_max_c,
                                g_asb_cfg.sustained_temp_exit,
                                asb_state_names[fsm.state],
                                g_asb_cfg.gaming_retry_cooldown_s, _eff);
                    }
                }
            }

            {
                int boost_want = (fsm.state == ASB_STATE_HEAVY || fsm.state == ASB_STATE_GAMING)
                                 && !fsm.thermal_cap
                                 && (fsm.profile_idx == PROFILE_PERFORMANCE);
                if (boost_want && !g_msm_boost_active) {
                    if (g_asb_cfg.log_level >= 1) asb_log("boost_on: %s", asb_state_names[fsm.state]);
                } else if (!boost_want && g_msm_boost_active) {
                    const char *off_reason = fsm.thermal_cap           ? "thermal"
                                           : (fsm.state == ASB_STATE_SUSTAINED) ? "SUSTAINED"
                                           : (fsm.profile_idx != PROFILE_PERFORMANCE) ? "profile!=perf"
                                           : asb_state_names[fsm.state];
                    if (g_asb_cfg.log_level >= 1) asb_log("boost_off: %s", off_reason);
                }
                g_msm_boost_active = boost_want;
            }
            if ((fsm.state == ASB_STATE_HEAVY || fsm.state == ASB_STATE_GAMING
                 || fsm.state == ASB_STATE_SUSTAINED) && !fsm.thermal_cap) {
                /* V31: anti-clamp -- detect vendor override on BOTH clusters
                 * Conditions: gap > 500kHz on either cluster + temp < 95 + headroom >= 60%
                 * Backoff: if 5 consecutive attempts fail to improve, pause 30s */
                static int g_anticlamp_fails = 0;
                static time_t g_anticlamp_backoff_until = 0;
                int vendor_clamping = 0;
                if (fsm.profile_idx == PROFILE_PERFORMANCE || fsm.profile_idx == PROFILE_BALANCED) {
                    time_t now_ac = time(NULL);
                    if (now_ac < g_anticlamp_backoff_until) {
                        /* In backoff period -- skip aggressive mode */
                    } else {
                        int actual_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                        int actual_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                        int desired_p0 = fsm.current_caps.cpu_max[0];
                        int desired_p1 = fsm.current_caps.cpu_max[1];
                        int gap0 = (desired_p0 > 0 && actual_p0 > 0) ? desired_p0 - actual_p0 : 0;
                        int gap1 = (desired_p1 > 0 && actual_p1 > 0) ? desired_p1 - actual_p1 : 0;
                        int max_gap = (gap0 > gap1) ? gap0 : gap1;
                        /* Headroom gate: only fight vendor clamp, not real thermal wall */
                        int headroom_ok = (!metrics.therm.headroom_valid || metrics.therm.headroom_pct >= 60);
                        if (max_gap > 500000 && metrics.therm.cpu_max_c < 95 && headroom_ok)
                            vendor_clamping = 1;
                    }
                }
                int reassert_interval = vendor_clamping ? 2
                    : (fsm.state == ASB_STATE_GAMING) ? g_asb_cfg.reassert_gaming_s
                    : g_asb_cfg.reassert_heavy_s;
                time_t now = time(NULL);
                if (now - g_last_reassert >= reassert_interval) {
                    int pre_p0 = vendor_clamping ? sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0) : 0;
                    /* Write msm_performance */
                    int ok = msm_perf_write_all_max(
                                fsm.current_caps.cpu_max[0],
                                fsm.current_caps.cpu_max[1]);
                    /* Anti-clamp: also force scaling_max_freq on both clusters */
                    if (vendor_clamping) {
                        for (int ci = 0; ci < 2; ci++) {
                            if (fsm.current_caps.cpu_max[ci] > 0)
                                sysfs_write_int(cpu_policy_path(ci, "scaling_max_freq"),
                                               fsm.current_caps.cpu_max[ci]);
                        }
                        /* Backoff: check if we actually improved anything */
                        int post_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                        if (post_p0 > 0 && pre_p0 > 0 && post_p0 - pre_p0 < 100000) {
                            g_anticlamp_fails++;
                            if (g_anticlamp_fails >= 5) {
                                g_anticlamp_backoff_until = now + 30;
                                g_anticlamp_fails = 0;
                                asb_log("anti_clamp: backoff 30s (5 ineffective attempts, actual stuck at %d)", post_p0);
                            }
                        } else {
                            g_anticlamp_fails = 0;
                        }
                    }
                    g_last_reassert = now;
                    g_last_reassert_ok = (ok == 0) ? 1 : 0;
                    if (ok == 0 && g_asb_cfg.log_level >= 1) {
                        if (vendor_clamping)
                            asb_log("anti_clamp: %s cpu_max=[%d,%d] actual=[%d,%d] hr=%d%% t=%ddegC",
                                    asb_state_names[fsm.state],
                                    fsm.current_caps.cpu_max[0], fsm.current_caps.cpu_max[1],
                                    sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0),
                                    sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0),
                                    metrics.therm.headroom_pct, metrics.therm.cpu_max_c);
                        else
                            asb_log("reassert: %s cpu_max=[%d,%d] t=%ddegC",
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

            /* V30: adaptive tick interval
             * Battery screen-off DEEP_IDLE -> 10s ticks instead of 5s
             * Halves governor wakeups during sleep (~2880 saved per 8h night)
             * FSM is time-based (clock_gettime), so longer intervals are safe */
            {
                static int g_idle_interval = TIMER_IDLE_S;
                int want = TIMER_IDLE_S;
                if (fsm.profile_idx == PROFILE_BATTERY &&
                    !metrics.misc.screen_on &&
                    fsm.state == ASB_STATE_DEEP_IDLE) {
                    want = TIMER_DEEP_S;
                }
                if (want != g_idle_interval) {
                    int old = g_idle_interval;
                    arm_timerfd(tfd_idle, want);
                    g_idle_interval = want;
                    if (g_asb_cfg.log_level >= 1)
                        asb_log("adaptive_tick: idle interval %ds->%ds", old, want);
                }
            }
        }
    }

    fsm_flush_state_time(&fsm);
    {
        long total_active = fsm.ses_time_heavy_sec + fsm.ses_time_gaming_sec
                           + fsm.ses_time_sustained_sec;
        int sus_pct = (total_active > 0)
                      ? (int)(fsm.ses_time_sustained_sec * 100 / total_active) : 0;
        int avg_gap = (fsm.ses_gap_samples > 0)
                      ? (int)(fsm.ses_gap_p0_sum / fsm.ses_gap_samples) : 0;
        asb_log("session_end gaming=%d sustained=%d thermal=%d unreachable=%d "
                "t_heavy=%lds t_gaming=%lds t_sustained=%lds "
                "avg_gap=%d max_temp=%d auto_degraded=%d "
                "t2s=%lds t2thermal=%lds t2g=%lds efficiency=%d recovery=%d "
                "bat_deep=%lds bat_light=%lds bat_mod=%lds bat_wake=%d bat_ttd=%lds "
                "sus_pct=%d%%",
                fsm.ses_gaming_entries, fsm.ses_sustained_entries,
                fsm.ses_thermal_entries, fsm.ses_unreachable_entries,
                fsm.ses_time_heavy_sec, fsm.ses_time_gaming_sec,
                fsm.ses_time_sustained_sec,
                avg_gap, fsm.ses_max_temp, fsm.ses_auto_degraded,
                fsm.ses_time_to_first_sus, fsm.ses_time_to_first_thermal,
                fsm.ses_time_to_first_gaming,
                fsm.ses_sustained_efficiency, fsm.ses_recovery_count,
                fsm.bat_time_deep_idle_sec, fsm.bat_time_light_idle_sec,
                fsm.bat_time_moderate_sec, fsm.bat_wake_cycles,
                fsm.bat_time_to_first_deep, sus_pct);
    }
    asb_log("governor stopping");
    close(tfd_active);
    close(tfd_idle);
    close(tfd_hourly);
    if (uefd  >= 0) close(uefd);
    if (sockfd >= 0) close(sockfd);
    close(epfd);
    session_end_self_tune(&fsm);
    fsm_flush_state_time(&fsm);
    persistent_stats_save(&fsm);
    session_history_append_ex(&fsm, "shutdown");
    asb_log("persistent stats saved: sessions=%d degrade=%d", g_pstats.session_count, g_pstats.degrade_count);
    unlink(ASB_SOCK_PATH);
    unlink(PID_FILE);
    if (g_logf) fclose(g_logf);
    return 0;
}
