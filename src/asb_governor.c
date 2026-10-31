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
#include <linux/input.h>
#include <sys/ioctl.h>
#include <sys/eventfd.h>
#if defined(__ANDROID__)
#include <pthread.h>
#include <dlfcn.h>
#endif

#include "asb_metrics.h"
#include "asb_fsm.h"
#include "asb_learner.h"

/* fix212: the writer borrows the CPU ceilings on the manual profiles while the
 * unlock/launch lift runs, so it reads this flag - the lift machinery itself sits far
 * below the includes and defines it there. */
static int g_unlock_lift_now;

#include "asb_writer.h"
#include "asb_socket.h"
#include "asb_config.h"
#include "asb_smart.h"
#include "asb_record.h"
#include "asb_log_feedback.h"
#include "asb_lspd.h"   /* fix187 */

#define TIMER_ACTIVE_S  2   /* metrics interval, screen ON, something happening */
/* Screen on but idle: reading, a feed at rest, music with the display lit. The state
 * machine does not move on a two-second scale there, so neither does the sampling. */
#define TIMER_ACTIVE_CALM_S 6
/* Screen-off policy does not need frame-rate feedback.  The previous 5/10 s cadence kept
 * reopening sysfs nodes hundreds of times per hour during a quiet night.  These intervals
 * retain prompt response to uevents and socket commands while materially reducing resident
 * governor wakeups and telemetry I/O. Verified deep idle can use a 45-second cadence because
 * screen-on, socket and display uevents remain independently epoll-driven. */
#define TIMER_IDLE_S   10   /* metrics interval, screen OFF */
#define TIMER_DEEP_S   45   /* metrics interval, verified deep idle */
/* Screen off with background work: one third of the idle tier's wakeup rate. Display,
 * input and socket events stay epoll-driven, so this slows only background re-evaluation. */
#define TIMER_IDLE_NOISY_S 30
#define TIMER_HOURLY_S  3600

#define STATE_FILE      "/dev/.asb/state"
#define LOG_FILE        "/dev/.asb/governor.log"
#define LOG_MAX_BYTES   409600  /* 400KB max, then rotate */
#define LOG_BACKUP      "/dev/.asb/governor.log.1"

#ifndef ASB_DEBUG_BUILD
#define ASB_DEBUG_BUILD 0
#endif
#define PID_FILE        "/dev/.asb/governor.pid"
#define PROFILE_FILE    "/data/adb/modules/AutoSystemBoost/current_profile"
#define CONFIG_FILE     "/data/adb/modules/AutoSystemBoost/config/governor.conf"
#define ACTIVE_EFFICIENCY_FILE "/data/adb/asb/active_efficiency.env"

#define MAX_EVENTS      8

static FILE *g_logf = NULL;
static void asb_log(const char *fmt, ...) __attribute__((format(printf,1,2)));  /* forward decl */
asb_runtime_config_t g_asb_cfg;
/* Acknowledged lifecycle refreshes are observability too: an accepted request means
 * "fresh metrics will be evaluated", never "a frequency was raised" or "power was saved". */
static unsigned long g_zygisk_refresh_accepted = 0;
static unsigned long g_zygisk_refresh_vetoed = 0;
static unsigned long g_zygisk_launch_accepted = 0;   /* fix272: new top-app processes heard */
static unsigned long g_zygisk_launch_vetoed = 0;
static time_t g_last_reassert = 0;
static int g_last_reassert_ok = 0;

/* Smart Mode globals */
static asb_smart_store_t   g_smart_store;
static asb_smart_runtime_t g_smart_rt;

/*
 * V50: smart profile with a strong battery lean behaves like the battery profile at night, but
 * quiet-night ultra-economy and deep-idle sensor economy were hard-gated on PROFILE_BATTERY —
 * so on a full night in smart the governor never reduced its own sensor cadence.
 */
static int asb_profile_battery_like(int profile_idx) {
    if (profile_idx == PROFILE_BATTERY) return 1;
    if (profile_idx == PROFILE_SMART &&
        g_smart_rt.enabled &&
        g_smart_rt.alpha_battery_x1000 >= 800) return 1;
    return 0;
}
static int                 g_smart_store_loaded = 0;
static time_t              g_smart_last_save_ts = 0;
static time_t              g_smart_last_backup_ts = 0;
static int                 g_smart_sessions_since_save = 0;

/*
 * — Foreground package detection observability.
 * These mirror the most recent detection outcome so write_state() can publish them to
 * /dev/.asb/state for logkit + WebUI.
 */
static int g_pkg_detect_ok = 0;        /* 1 if last detection got a real pkg */
static int g_pkg_detect_source = 0;    /* 2=resumed, 3=window focus, 4=top-app cgroup (fix124; 1=activity top, retired) */
static int g_pkg_detect_status = 0;    /* asb_pkg_status_t code */

/* Opt-in Smart Media Guard runtime. These flags are deliberately separate from the
 * learner and from fsm.current_caps: the guard only narrows the writer-local GPU cap
 * after a confirmed known-media workload and becomes a no-op the instant its evidence fades. */
static int    g_smart_media_pkg_known = 0;
static int    g_smart_media_guard_active = 0;
static time_t g_smart_media_guard_since = 0;
static char   g_smart_media_guard_reason[40] = "disabled";

/* Smart Mode session counters, kept separate from the legacy battery/balanced/
 * performance counters so learner_state.json shows Smart activity honestly. */
static time_t g_smart_drain_prev_ts  = 0;
static int    g_smart_drain_prev_pct = -1;
static long   g_smart_drain_on_sec   = 0;
/* A rolling screen-on drain that does NOT reset when a session ends.
 *
 * The per-session measurement is right for the learner - mixing a gaming session into a
 * reading one describes neither - but it is the wrong thing to show on screen. Sessions end
 * on every state change, so the accumulator rarely reached the 300 s it needs and the
 * banner kept publishing the last completed reading instead: a user watched it sit at
 * 6.5 %/h all day while the phone was visibly draining faster. A state file captured
 * mid-use shows the cause plainly - smart_drain_window_s=10.
 *
 * This pair accumulates across sessions and halves itself every two hours, so it forgets
 * slowly instead of all at once and always has something current to report. */
static long   g_drain_roll_sec    = 0;
static long   g_drain_roll_x100   = 0;
static long   g_smart_drain_drop_x100 = 0;
/* Last completed screen-on drain measurement, kept across sessions so short bursts of use
 * still produce a number. Zero until the first session long enough to measure. */
#define ASB_DRAIN_STALE_SEC (6 * 3600)
static long   g_smart_drain_last_x10 = 0;
static time_t g_smart_drain_last_ts  = 0;
static int    g_smart_drain_rate_ewma_x10 = 0;
static long   g_drain_rs_drop_x100 = 0;   /* fix186: decayed sums behind the recent rate */
static long   g_drain_rs_on_s = 0;
/* Last computed battery-lean verdict, published for the state file.
 *
 * It decides whether a HEAVY state still gets the modem's fast LPM mode, so it changes
 * radio behaviour - and it was computed, used, and thrown away. The logkit has had a
 * column for it all along: every capture so far wrote that column empty, and any question
 * about why the modem stayed in "normal" under load had no answer in the data. */
static int    g_smart_battery_lean_pub = 0;
static int    g_smart_last_quality = -1;
static int    g_smart_budget_src = 0;
/* The rate the budget's forecast was divided by, after the self-correction (fix127). The
 * forecast is published WITH this rate, so every screen that prints "x h at y %/h" shows a
 * pair that multiplies back to the battery level. */
static int    g_smart_budget_rate_x10 = 0;
static time_t g_gov_start_ts = 0;
static int    g_smart_boot_settle = 0;
/* Sessions kept as telemetry but withheld from learning because they landed inside the
 * post-boot window. Counted so the quarantine is visible rather than silent. */
static unsigned long g_startup_quarantined = 0;
/* How long after governor start a session is considered untrusted for learning.
 * Five minutes covers package rescan and restore on the slowest device seen in the
 * captures, without swallowing a genuine early-morning usage session. */
#define ASB_STARTUP_QUARANTINE_S 300
static int    g_smart_cool_gaming_lvl = 0;
/* Gaming-session peak tracking (reset when a game session is not active).
   Cheap running maxima surfaced in the report card so charge-aware cooling
   can be judged on numbers, not feel. */
static int    g_game_bat_temp_peak_dc = 0;
static int    g_game_cpu_max_peak_c   = 0;
static int    g_game_cool_lvl_peak    = 0;
static int    g_game_charging_seen    = 0;
static int    g_smart_q_bat = -1;
static int    g_smart_q_heat = -1;
static int    g_smart_q_stab = -1;
static int    g_smart_q_vendor = -1;
static int    g_smart_q_fail = 0;
static unsigned long g_smart_ses_clamp_start = 0;
static int    g_smart_quality_ewma = -1;
static int    g_anom_code = 0;
static int    g_anom_count_1h = 0;
static time_t g_anom_window_start = 0;
static long   g_anom_pkg_total = 0;
static long   g_anom_pkg_ok = 0;

static int g_smart_sessions_total    = 0;
static int g_smart_sessions_day      = 0;
static int g_smart_sessions_night    = 0;
static int g_smart_sessions_gaming   = 0;
static int g_smart_bucket_updates    = 0;
static int g_smart_last_bucket_id    = -1;
static int g_smart_last_daypart      = -1;
static int g_smart_last_confidence   = 0;
static time_t g_smart_last_update_ts = 0;

static int    g_smart_last_seen_bucket = -1;
static time_t g_smart_last_periodic_ts = 0;
static time_t g_smart_screen_off_since = 0;
static int    g_smart_last_screen_on = 1;

/* Suspend tracking: is the phone actually sleeping while the screen is off?
 *
 * CLOCK_MONOTONIC stops during suspend; CLOCK_BOOTTIME does not. The ratio between
 * them over a screen-off window is the share of that window the CPU stayed awake.
 *
 * Nothing measured this at runtime. An overnight capture showed 73% awake across 8.9
 * hours of screen-off against a <5% target, and 1.58%/h drain against 0.3-0.7 - and the
 * module had no idea, because the figure was only computed afterwards by the log tools.
 * A governor that cannot see the phone failing to sleep cannot say so, let alone react.
 *
 * This only measures and publishes. Deciding what to do about a wakelock held by
 * someone else is a separate question, and guessing at it is how a performance module
 * starts breaking alarms. */
static long   g_awake_win_mono_ms = 0;   /* monotonic ms accumulated this screen-off window */
static long   g_awake_win_boot_ms = 0;   /* boottime ms over the same window */
static long   g_awake_last_mono_ms = 0;
static long   g_awake_last_boot_ms = 0;
static int    g_awake_pct = -1;          /* -1 = not measured yet */

static long asb_clock_ms(clockid_t which) {
    struct timespec ts;
    if (clock_gettime(which, &ts) != 0) return 0;
    return (long)ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* Measured screen-off drain, in %/h x100, learned across real screen-off stretches.
 *
 * The "idle" half of every time-to-empty on the action screen and in the WebUI was a guess:
 * a tenth of the screen-on draw, clamped to 40-90 mA. Nothing measured it, though this
 * governor already watches every screen-off window. A OnePlus 15 night drained 0.51 %/h
 * (about 37 mA) - below the guess's own floor - so the idle forecast was wrong in the same
 * direction on every phone that sleeps well, and on a phone that sleeps badly it was wrong
 * the other way with nothing to say so.
 *
 * A window opens when the screen goes off on battery and closes when the screen comes on
 * or a charger is attached (that window is thrown away - it measures the charger). Only a
 * window of 60+ minutes that lost at least 2 whole percent counts: capacity is quantised to
 * whole percent, and anything shorter is rounding, not drain. Smoothed 3:1 and kept on disk
 * so one good night survives a reboot. */
#define ASB_OFFDRAIN_FILE "/data/adb/asb/offdrain_pctph_x100"
/* File format "rate windows 2". The trailing 2 marks a figure measured without music
 * (fix141); a file without it is discarded once, see below. */
#define ASB_OFFDRAIN_FMT 2
static int    g_offdrain_x100 = -1;      /* -1 = never measured */
static int    g_offdrain_n = 0;          /* windows that counted */
static int    g_offdrain_loaded = 0;
static long   g_offdrain_start_ms = 0;   /* boottime ms at window open, 0 = closed */
static int    g_offdrain_start_pct = -1;
static long   g_offdrain_on_ms = 0;      /* boottime ms the screen came on, 0 = still off */
static int    g_offdrain_on_pct = -1;
/* Playback seen in the open window, and windows left out for it (fix141).
 *
 * "Idle" on the action screen read 1.48 %/h on an OP15 whose night measured 0.59 %/h in the
 * same capture (2830): every screen-off hour counted, and this user listens to YouTube over
 * Bluetooth with the screen off (2.96 %/h, 100% awake) - music, not idle. A window in which
 * a playback stream ran is no longer an idle sample. The kernel's PCM state is read only on
 * screen-off ticks and only until the window is marked; with no readable /proc/asound
 * (-1) every window counts, as before. */
static int    g_offdrain_media = 0;
static int    g_offdrain_media_skipped = 0;
/* The same windows, per profile (fix189).
 *
 * The figure above is the phone's: every window counts, whatever profile ran. The WebUI put
 * it on the running profile's card ("~0.70 %/h" on Smart, fix187) - and an OP15 switched to
 * Balanced showed Smart's 0.70 on Balanced's card a minute later. A window now also counts
 * for the profile it ran in, when the same profile held from the screen going off to it
 * coming back on; "offdrain_by_profile" carries those figures, the card shows only them.
 * Kept in a file of its own ("name rate windows" per line), so the phone-wide figure and its
 * format stay as they were. Indexed by PROFILE_*, 0..3. */
#define ASB_OFFDRAIN_PROF_FILE "/data/adb/asb/offdrain_profiles"
#define ASB_OFFDRAIN_NPROF 4
static int    g_offdrain_p_x100[ASB_OFFDRAIN_NPROF] = {-1, -1, -1, -1};
static int    g_offdrain_p_n[ASB_OFFDRAIN_NPROF] = {0, 0, 0, 0};
static int    g_offdrain_prof = -1;      /* profile at window open */
static int    g_offdrain_prof_mixed = 0; /* another profile ran during the window */
static const char *const g_offdrain_p_name[ASB_OFFDRAIN_NPROF] = {"battery", "balanced", "performance", "smart"};
static void asb_offdrain_prof_save(void) {
    FILE *f = fopen(ASB_OFFDRAIN_PROF_FILE ".tmp", "w");
    if (!f) return;
    for (int i = 0; i < ASB_OFFDRAIN_NPROF; i++)
        if (g_offdrain_p_x100[i] > 0) fprintf(f, "%s %d %d\n", g_offdrain_p_name[i], g_offdrain_p_x100[i], g_offdrain_p_n[i]);
    fclose(f);
    rename(ASB_OFFDRAIN_PROF_FILE ".tmp", ASB_OFFDRAIN_PROF_FILE);
}
static void asb_offdrain_prof_load(void) {
    FILE *f = fopen(ASB_OFFDRAIN_PROF_FILE, "r");
    if (!f) return;
    char name[24]; int v = 0, n = 0;
    while (fscanf(f, "%23s %d %d", name, &v, &n) == 3) {
        for (int i = 0; i < ASB_OFFDRAIN_NPROF; i++)
            if (strcmp(name, g_offdrain_p_name[i]) == 0 && v > 0 && v < 5000) {
                g_offdrain_p_x100[i] = v; g_offdrain_p_n[i] = n > 0 ? n : 1;
            }
    }
    fclose(f);
}
static void asb_offdrain_save(void) {
    FILE *f = fopen(ASB_OFFDRAIN_FILE ".tmp", "w");
    if (f) {
        fprintf(f, "%d %d %d\n", g_offdrain_x100, g_offdrain_n, ASB_OFFDRAIN_FMT);
        fclose(f);
        rename(ASB_OFFDRAIN_FILE ".tmp", ASB_OFFDRAIN_FILE);
    }
}
static void asb_offdrain_track(int screen_on, int pct, int charging, int prof) {
    if (!g_offdrain_loaded) {
        g_offdrain_loaded = 1;
        asb_offdrain_prof_load();
        FILE *f = fopen(ASB_OFFDRAIN_FILE, "r");
        if (f) {
            int v = -1, n = 0, fmt = 0;
            int got = fscanf(f, "%d %d %d", &v, &n, &fmt);
            fclose(f);
            /* A figure from before fix141 mixed music windows into "idle" and only one
             * clean night replaces it - start over instead of averaging into it. */
            if (got >= 3 && fmt == ASB_OFFDRAIN_FMT && v > 0 && v < 5000) {
                g_offdrain_x100 = v; g_offdrain_n = n > 0 ? n : 1;
            } else if (got >= 1) {
                unlink(ASB_OFFDRAIN_FILE);
            }
        }
    }
    long now = asb_clock_ms(CLOCK_BOOTTIME);
    if (pct <= 0 || pct > 100) return;
    if (charging) { g_offdrain_start_ms = 0; g_offdrain_on_ms = 0; g_offdrain_media = 0; return; }   /* the charger */
    /* A glance at the clock at 3 am must not split the night into two windows too short
     * to count: a screen-on of under two minutes is folded into the surrounding window. */
    if (!screen_on) {
        g_offdrain_on_ms = 0;
        if (g_offdrain_start_ms == 0) {
            g_offdrain_start_ms = now; g_offdrain_start_pct = pct; g_offdrain_media = 0;
            g_offdrain_prof = prof; g_offdrain_prof_mixed = 0;
        }
        if (prof != g_offdrain_prof) g_offdrain_prof_mixed = 1;
        if (!g_offdrain_media && metrics_pcm_playing() == 1) g_offdrain_media = 1;
        return;
    }
    if (g_offdrain_start_ms > 0 && g_offdrain_on_ms == 0) {
        g_offdrain_on_ms = now; g_offdrain_on_pct = pct;          /* remember where it ended */
        /* The window closes here; a switch while the screen is on comes after it. */
        if (prof != g_offdrain_prof) g_offdrain_prof_mixed = 1;
    }
    if (g_offdrain_start_ms > 0 && now - g_offdrain_on_ms >= 120000L) {
        long dur = g_offdrain_on_ms - g_offdrain_start_ms;
        int dpct = g_offdrain_start_pct - g_offdrain_on_pct;
        int media = g_offdrain_media;
        int wp = g_offdrain_prof_mixed ? -1 : g_offdrain_prof;
        g_offdrain_start_ms = 0;
        g_offdrain_on_ms = 0;
        g_offdrain_media = 0;
        g_offdrain_prof = -1; g_offdrain_prof_mixed = 0;
        if (dur >= 3600000L && dpct >= 2) {
            long r = (long)dpct * 100L * 3600000L / dur;
            if (media) {
                g_offdrain_media_skipped++;
            } else if (r > 0 && r < 5000) {
                g_offdrain_x100 = (g_offdrain_x100 > 0) ? (int)((g_offdrain_x100 * 3L + r) / 4L) : (int)r;
                g_offdrain_n++;
                asb_offdrain_save();
                if (wp >= 0 && wp < ASB_OFFDRAIN_NPROF) {
                    g_offdrain_p_x100[wp] = (g_offdrain_p_x100[wp] > 0)
                        ? (int)((g_offdrain_p_x100[wp] * 3L + r) / 4L) : (int)r;
                    g_offdrain_p_n[wp]++;
                    asb_offdrain_prof_save();
                }
            }
        }
    }
}

/* Battery current gauge scale, measured on this device.
 *
 * current_now is not the same quantity on every phone. Full-day captures show it: on the
 * OnePlus 15 the sampled current integrates to 0.44-0.57 of what the falling SOC says was
 * drawn, in every screen-on phase type alike, while the OnePlus 12 lines up within 2-8%.
 * A ratio that does not depend on the load is a property of the gauge (one cell of a
 * dual-cell pack is the likely reading), and it means every milliamp threshold in this
 * file is effectively twice as high on one model as on the other.
 *
 * This measures the ratio and publishes it; it does not yet rescale anything. Thresholds
 * were tuned on raw readings, mostly from one model, so applying a factor blind would move
 * every current-gated decision at once. With the scale on record from several devices the
 * thresholds can be expressed in real milliamps.
 *
 * Screen-on only. With the screen off the CPU suspends between ticks and the integral only
 * sees the moments it was awake - the recorder's own "CHECK high" in sleep phases is that
 * bias. Screen-on, the device is awake and every tick is a fair sample. Segments are summed
 * until the SOC has fallen 5 whole steps, so one quantisation step is at most a 20% error
 * per window, and the EWMA over windows smooths the rest. */
static int  g_device_bounds_applied = -1;  /* overrides loaded from device_bounds.env at start */
/* Screen-on memory stalls seen by the tuner signature (fix108), published (fix111). */
static unsigned long g_mem_stall_entries = 0;
static int g_mem_stall_now = 0;
static long g_prime_escape_since_ms = 0;   /* boottime ms of the open lift, 0 = none */
static long g_prime_escape_total_ms = 0;   /* lifted time this session */

#define ASB_CURSCALE_FILE "/data/adb/asb/current_scale_x100"
static int    g_curscale_x100 = -1;      /* sampled / SOC-derived drain x100; -1 = not yet */
static int    g_curscale_n = 0;
static int    g_curscale_loaded = 0;
static long   g_cs_last_ms = 0;          /* previous screen-on discharge tick */
static int    g_cs_seg_pct = -1;         /* SOC at the start of the current screen-on segment */
static double g_cs_mas = 0;              /* mA x seconds integrated over finished segments */
static double g_cs_seg_mas = 0;          /* ... and over the open one */
static int    g_cs_dpct = 0;             /* whole SOC steps fallen over finished segments */
static long   g_cs_cap_mah = 0;

static void asb_curscale_close_segment(int pct) {
    if (g_cs_seg_pct > 0 && pct > 0 && pct <= g_cs_seg_pct) {
        g_cs_dpct += g_cs_seg_pct - pct;
        g_cs_mas  += g_cs_seg_mas;
    }
    g_cs_seg_pct = -1; g_cs_seg_mas = 0; g_cs_last_ms = 0;
}

static void asb_curscale_track(int screen_on, int pct, int charging, int current_ma) {
    if (!g_curscale_loaded) {
        g_curscale_loaded = 1;
        FILE *f = fopen(ASB_CURSCALE_FILE, "r");
        if (f) {
            int v = -1, n = 0;
            if (fscanf(f, "%d %d", &v, &n) >= 1 && v > 10 && v < 500) { g_curscale_x100 = v; g_curscale_n = n > 0 ? n : 1; }
            fclose(f);
        }
        long cf = sysfs_read_long("/sys/class/power_supply/battery/charge_full", 0);
        if (cf <= 0) cf = sysfs_read_long("/sys/class/power_supply/battery/charge_full_design", 0);
        if (cf > 100000L) g_cs_cap_mah = cf / 1000L;            /* uAh */
        else if (cf > 500L && cf < 30000L) g_cs_cap_mah = cf;   /* already mAh */
    }
    if (g_cs_cap_mah < 800 || pct <= 0 || pct > 100) return;
    if (charging) {          /* the charger invalidates the whole window, not just a segment */
        g_cs_seg_pct = -1; g_cs_seg_mas = 0; g_cs_last_ms = 0; g_cs_mas = 0; g_cs_dpct = 0;
        return;
    }
    if (!screen_on || current_ma <= 0) { asb_curscale_close_segment(pct); return; }
    long now = asb_clock_ms(CLOCK_BOOTTIME);
    if (g_cs_seg_pct < 0) { g_cs_seg_pct = pct; g_cs_last_ms = now; return; }
    long dt = now - g_cs_last_ms;
    g_cs_last_ms = now;
    if (dt <= 0 || dt > 120000L) { asb_curscale_close_segment(pct); return; }   /* a gap is not a sample */
    g_cs_seg_mas += (double)current_ma * (double)dt / 1000.0;
    if (g_cs_dpct + (g_cs_seg_pct - pct) < 5) return;
    asb_curscale_close_segment(pct);
    /* sampled mAh against the mAh the SOC drop represents */
    double meas_mah = g_cs_mas / 3600.0;
    double soc_mah  = (double)g_cs_dpct * (double)g_cs_cap_mah / 100.0;
    g_cs_mas = 0; g_cs_dpct = 0;
    if (soc_mah <= 0) return;
    long r = (long)(meas_mah * 100.0 / soc_mah + 0.5);
    if (r < 15 || r > 400) return;                   /* not a gauge, a broken window */
    g_curscale_x100 = (g_curscale_x100 > 0) ? (int)((g_curscale_x100 * 3L + r) / 4L) : (int)r;
    g_curscale_n++;
    FILE *f = fopen(ASB_CURSCALE_FILE ".tmp", "w");
    if (f) {
        fprintf(f, "%d %d\n", g_curscale_x100, g_curscale_n);
        fclose(f);
        rename(ASB_CURSCALE_FILE ".tmp", ASB_CURSCALE_FILE);
    }
}

/* Called once per tick. screen_on resets the window: the figure is only meaningful
 * across a continuous screen-off stretch, and mixing screen-on time into it would
 * dilute exactly the problem it exists to expose. */
static void asb_awake_track(int screen_on) {
    long mono = asb_clock_ms(CLOCK_MONOTONIC);
    long boot = asb_clock_ms(CLOCK_BOOTTIME);
    if (screen_on) {
        g_awake_win_mono_ms = 0;
        g_awake_win_boot_ms = 0;
        g_awake_last_mono_ms = mono;
        g_awake_last_boot_ms = boot;
        g_awake_pct = -1;
        return;
    }
    if (g_awake_last_boot_ms > 0) {
        long d_mono = mono - g_awake_last_mono_ms;
        long d_boot = boot - g_awake_last_boot_ms;
        /* Guard against a clock that went backwards or a wildly long gap - both mean
         * the sample is not comparable, not that the phone was busy. */
        if (d_mono >= 0 && d_boot > 0 && d_boot < 6L * 3600L * 1000L) {
            g_awake_win_mono_ms += d_mono;
            g_awake_win_boot_ms += d_boot;
        }
    }
    g_awake_last_mono_ms = mono;
    g_awake_last_boot_ms = boot;
    /* Ten minutes before the first verdict: a phone that just locked has not had the
     * chance to suspend yet, and calling that "awake" would cry wolf every evening. */
    if (g_awake_win_boot_ms >= 600000L) {
        g_awake_pct = (int)((g_awake_win_mono_ms * 100L) / g_awake_win_boot_ms);
        if (g_awake_pct > 100) g_awake_pct = 100;
    }
}

static int    g_smart_last_tune_sig = -1;
static time_t g_smart_last_tune_ts  = 0;

static int    g_leak_streak_p0        = 0;
static int    g_leak_streak_p1        = 0;
static time_t g_last_leak_reassert    = 0;
static int    g_leak_reassert_count   = 0;
/* A raised ceiling only costs energy if the cluster actually runs above our limit.
 * ceiling = ticks the vendor's ceiling sat above ours; used = ticks the clock was really
 * above ours. Published so a capture says whether a vendor raise mattered, not just
 * that it happened. */
static unsigned long g_leak_ceiling_ticks = 0;
static unsigned long g_leak_used_ticks    = 0;
/* fix160: a ceiling above the FSM's wish that ASB itself asked for - the unlock lift, a prime
 * burst, or a lowering write not landed yet. The owner's OP15 action screen read "vendor
 * ceiling above ASB's in 100 checks, the clock above our limit in 59"; both log lines behind
 * it said "writer p1: ..., req 3648000" - the 80% unlock-lift rail ASB had just written. A
 * request of our own is not a vendor raise, and counting it as one sent the reader looking for
 * a PowerHAL fight that was not there. Counted apart, published as own_ceiling_ticks. */
static unsigned long g_own_ceiling_ticks  = 0;
enum { ASB_CEIL_OVER_NONE = 0, ASB_CEIL_OVER_OWN = 1, ASB_CEIL_OVER_VENDOR = 2 };
static int asb_ceiling_over_kind(int actual, int want, int requested) {
    if (actual <= 0 || want <= 0 || actual <= want + 100000) return ASB_CEIL_OVER_NONE;
    if (requested > 0 && actual <= requested + 100000) return ASB_CEIL_OVER_OWN;
    return ASB_CEIL_OVER_VENDOR;
}
static int g_msm_boost_active = 0;

#define AC_STAGE_IDLE    0
#define AC_STAGE_BURST   1  /* aggressive 2s, max 3 attempts */
#define AC_STAGE_HOLD    2  /* maintenance 4s */
#define AC_STAGE_BACKOFF 3  /* pause 30s */

#define PLAN_CLASS_IDLE_CLEAN    0  /* battery screen-off deep idle */
#define PLAN_CLASS_IDLE_NOISY    1  /* battery screen-off but noisy (wakes/moderate) */
#define PLAN_CLASS_DAILY_ACTIVE  2  /* battery/balanced screen-on daily use */
#define PLAN_CLASS_PERF_ACTIVE   3  /* performance or heavy balanced */
#define PLAN_CLASS_PERF_CLAMPED  4  /* performance under vendor clamp */
#define PLAN_CLASS_BENCHMARK     5  /* benchmark session */
#define PLAN_CLASS_QUARANTINE    6  /* user-switch quarantine */

#define INTENT_UNKNOWN    0
#define INTENT_BENCHMARK  1
#define INTENT_LONG_GAME  2
#define INTENT_IDLE       3
#define INTENT_MIXED      4
#define INTENT_SLEEP_IDLE 5
#define INTENT_IDLE_WARM  6

static struct {
    uint8_t has_msm_perf;       /* /sys/kernel/msm_performance writable */
    uint8_t has_headroom;       /* msm_performance/cpu_max_freq readable */
    uint8_t has_thermal_cpu;    /* thermal_zone for CPU found */
    uint8_t has_thermal_skin;   /* thermal_zone for skin found */
    uint8_t has_gpu_load;       /* GPU load sysfs readable */
    uint8_t has_uclamp;         /* cpuctl/top-app/cpu.uclamp.max exists */
} g_device_caps;
static int g_ac_stage = AC_STAGE_IDLE;
static int g_ac_burst_count = 0;
static int g_ac_fails = 0;
static time_t g_ac_backoff_until = 0;
static int g_ac_backoff_count = 0;  /* backoffs this session */
static int g_ac_futile = 0;        /* 1 = anti-clamp suspended (futility) */
static int g_clamp_probe_skip = 0; /* ticks until next recovery probe */
static int g_probe_good_hits = 0;  /* consecutive good probes needed to lift hold */
static time_t g_clamp_hold_since = 0;  /* when clamp_hold was first set */
static int g_virtual_ceiling_p0 = 0;
static int g_virtual_ceiling_p1 = 0;

static int g_burst_probation = 0;     /* 1 = in probation window */
static int g_burst_early_collapse = 0; /* 1 = early collapse detected */

static void anti_clamp_reset(void) {
    g_ac_stage = AC_STAGE_IDLE;
    g_ac_burst_count = 0;
    g_ac_fails = 0;
    g_ac_backoff_until = 0;
    g_ac_backoff_count = 0;
    g_ac_futile = 0;
    g_clamp_probe_skip = 0;
    g_probe_good_hits = 0;
    g_clamp_hold_since = 0;
    g_burst_probation = 0;
    g_burst_early_collapse = 0;
}

static int g_action_waste = 0;

static void action_waste_reset(void) { g_action_waste = 0; }

static int g_quiet_night_active = 0;
/* Ticks genuinely skipped by Quiet Night. Published so the economy can be verified. */
static unsigned long g_qn_ticks_skipped = 0;
/* Set for the current tick when Quiet Night is economising. Read at the battery and
 * thermal probe sites - the ones that cost an I/O round trip - rather than skipping the
 * whole tick, which would also skip the bookkeeping the next tick relies on. */
int g_qn_skip_this_tick = 0;
static time_t g_quiet_night_since = 0;
static int g_quiet_night_ticks = 0;       /* consecutive quiet deep-idle ticks */

/* A sleeping phone still needs a temperature now and then (fix166).
 *
 * Deep-idle economy and the quiet-night wake ramp skip the zones for as long as the state
 * holds, and for the decisions that run in deep idle that is fine. The screen-off cooldown is
 * the exception: it releases only when a reading says 40 C, and with no reading there is no
 * release. Capture 29835: a 9 s face unlock at 06:20 left the die at 46 C, the cooldown
 * engaged on that reading, and for the next two hours the governor published temp=46 with
 * age 0 while the zones read 30-39 C - thermal_cooldown=1 still held when the capture ended.
 *
 * One read every five minutes, every minute while the cooldown holds. The tick runs anyway
 * on those wakeups, so this adds a few file reads to a wakeup that happens regardless, never
 * a wakeup of its own. */
#define ASB_THERM_KEEPALIVE_S      300
#define ASB_THERM_KEEPALIVE_COOL_S 60
static unsigned long g_therm_keepalive_reads = 0;
static int asb_therm_keepalive_due(time_t now, time_t last_read, int cooldown) {
    if (last_read <= 0 || now < last_read) return 1;
    return (now - last_read) >= (cooldown ? ASB_THERM_KEEPALIVE_COOL_S : ASB_THERM_KEEPALIVE_S);
}

static int g_last_bat_clean_night = 0;

#define ENV_QUIET    0
#define ENV_NOISY    1
#define ENV_HOSTILE  2

static int g_last_session_env = ENV_QUIET;

static int g_quiet_wake_ramp = 0;
static int g_quiet_noise_ticks = 0;  /* hysteresis -- consecutive non-quiet ticks */

#define USER_QUARANTINE_SEC 90
static int g_last_user_id = -1;
static time_t g_user_quarantine_until = 0;
static int g_user_quarantine_active = 0;

static int get_current_user_id(void) {
    FILE *p = popen("cmd user get-current-user 2>/dev/null", "r");
    if (!p) return -1;
    char buf[32];
    int uid = -1;
    if (fgets(buf, sizeof(buf), p)) uid = atoi(buf);
    pclose(p);
    return uid;
}

static int user_quarantine_check(asb_fsm_t *fsm) {
    time_t now = time(NULL);
    if (g_user_quarantine_active && now >= g_user_quarantine_until) {
        g_user_quarantine_active = 0;
        fsm->plan.quarantine = 0;
        return 1;  /* expired -- caller should log */
    }
    return 0;
}

static time_t g_last_perf_end_ts = 0;
static int g_last_perf_max_temp = 0;
static int g_last_perf_was_clamped = 0;

static int g_storm_shield_active = 0;
static int g_shield_calm_ticks = 0;
static int g_shield_last_wakes = -1;
static int g_shield_exit_wakes = 0;      /* wake count at last smart exit */
static time_t g_shield_rearm_until = 0;  /* cooldown after smart exit */

static void storm_shield_reset(void) {
    g_storm_shield_active = 0;
    g_shield_calm_ticks = 0;
    g_shield_last_wakes = -1;
    g_shield_exit_wakes = 0;
    g_shield_rearm_until = 0;
}

static void session_plan_build(asb_fsm_t *fsm, int screen_on) {
    /* Cleared every pass: the branches below set what applies, and a flag left over from
     * the previous tick would keep a slower cadence after the reason for it was gone. */
    fsm->plan.idle_noisy_slow = 0;
    int p = fsm->profile_idx;
    /*
     * V56 HEAT FIX: SMART matched none of the branches below and fell through to the else =
     * the PERFORMANCE plan — full sensor polling + headroom reads + the anti-clamp armed (ASB
     * re-raising vendor thermal clamps up to 95°C) even with the screen OFF, and deep_sleep
     * never enabled.
     * Field logs showed exactly that: cap_owner=vendor on 59% of ticks (a write war with the
     * vendor thermal engine), 96-235 mA and 40°C surface in DEEP_IDLE, and the user report
     * "smart = boiler, balanced = fine".
     */
    if (p == PROFILE_SMART) {
        /* Smart is an energy/heat profile, not a hidden Balanced profile.  The previous
         * screen-on mapping selected the Balanced plan and armed anti-clamp, which could
         * re-raise vendor thermal caps.  Smart now uses the Battery-like plan for all states:
         * its adaptive bounds still choose the requested ceiling, but it never fights the
         * vendor thermal owner and its sensor cadence stays economical. */
        p = PROFILE_BATTERY;
    }
    int idle_band = (fsm->state <= ASB_STATE_LIGHT_IDLE);
    int heavy_band = (fsm->state >= ASB_STATE_HEAVY);

    /* ac_prearm recomputed on each rebuild; ac_used preserved (per-session budget) */
    fsm->plan.ac_prearm = 0;
    /* sensor_used resets on plan rebuild (per-epoch, not per-session) */
    fsm->plan.sensor_used = 0;

    if (p == PROFILE_BATTERY && !screen_on && idle_band) {
        fsm->plan.sensor_tier  = 2;
        fsm->plan.thermal_div  = 3;
        fsm->plan.allow_hr     = 0;
        fsm->plan.ac_eligible  = 0;
        fsm->plan.deep_sleep   = 1;
        fsm->plan.ac_budget    = 0;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class   = PLAN_CLASS_IDLE_CLEAN;
        if (g_last_session_env == ENV_HOSTILE) {
            long _bt_in_s = fsm->bat_time_deep_idle_sec
                          + fsm->bat_time_light_idle_sec
                          + fsm->bat_time_moderate_sec;
            int _in_iq = (_bt_in_s > 0)
                ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt_in_s) : 0;
            /* V56: judge cleanliness by BACKGROUND wakes only -- the user
             * checking the phone (screen wakes) is not environment noise. */
            int strict_clean = (fsm->bat_time_deep_idle_sec >= 600 &&
                                fsm->bat_wake_bg <= 3);
            int relaxed_clean = (fsm->bat_time_deep_idle_sec >= 900 &&
                                 fsm->bat_wake_bg <= 8 &&
                                 _in_iq >= 60);
            if (!strict_clean && !relaxed_clean) {
                fsm->plan.thermal_div = 1;
                fsm->plan.plan_class = PLAN_CLASS_IDLE_NOISY;
                asb_log("plan: primed as IDLE_NOISY (last session env=hostile)");
            } else {
                asb_log("plan: clean in-session override hostile prime (deep=%lds, wake=%d, iq=%d, mode=%s)",
                        fsm->bat_time_deep_idle_sec, fsm->bat_wake_cycles, _in_iq,
                        strict_clean ? "strict" : "relaxed");
            }
        }
    } else if (p == PROFILE_BATTERY && !screen_on) {
        /* Screen off with the state above LIGHT_IDLE: something is running, but nobody is
         * looking at it.
         *
         * Background work keeps the state above the deep-idle tier for long stretches. The
         * work is real - a sync or a download - but ASB's policy decisions here change on
         * the scale of minutes, not seconds. A 30 s cadence bounds the governor's own cost
         * to 120 timer wakeups an hour; display, input and socket events still arrive via
         * epoll immediately. With the screen off nobody is waiting on an intermediate cap.
         */
        fsm->plan.sensor_tier  = 1;  /* REDUCED */
        fsm->plan.thermal_div  = 1;
        fsm->plan.allow_hr     = 0;
        fsm->plan.ac_eligible  = 0;
        fsm->plan.deep_sleep   = 0;
        fsm->plan.idle_noisy_slow = 1;
        fsm->plan.ac_budget    = 0;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class   = PLAN_CLASS_IDLE_NOISY;
    } else if (!screen_on && idle_band) {
        /*
         * ANY profile, screen off, idle -> the quiet plan. This branch did not exist.
         *
         * The V56 note above describes SMART falling through to the PERFORMANCE plan and
         * being called "a boiler". SMART was remapped and fixed; BALANCED was not, and it
         * has the same shape: the branch below matches BALANCED for every state that is
         * not heavy, WITHOUT looking at the screen. So with the screen off and the phone
         * doing nothing, BALANCED still ran sensor_tier 0 (full polling), ac_eligible 1
         * (the anti-clamp armed, re-raising vendor thermal limits) and deep_sleep 0 - a
         * 5-second tick that never stretched.
         *
         * Two field captures on BALANCED show the cost: idle 95 min at 83% awake and
         * charging_idle 58 min at 100% awake against a <5% target, deep sleep 3.3%, and
         * 416 throttle events of which 274 landed while charging - the anti-clamp and the
         * vendor thermal engine writing over each other. On a OnePlus 13 that was enough
         * for OxygenOS to disable its own display enhancement with "device overheated".
         *
         * Written as a rule about the STATE, not a list of profiles, because that is where
         * the bug came from: the quiet plan was granted per profile, so each one had to be
         * remembered separately. SMART was fixed in V56, BALANCED was missed until two
         * field captures showed it, and PERFORMANCE would have been the next report -
         * with the screen off it also polled fully with the anti-clamp armed, and there is
         * no reading of "performance" under which that helps a phone in someone's pocket.
         *
         * Idle with the screen off is idle whatever the profile is called. Every profile
         * keeps its full behaviour the moment the screen comes on or real load arrives -
         * this branch cannot be reached in either case.
         */
        fsm->plan.sensor_tier  = 2;
        fsm->plan.thermal_div  = 3;
        fsm->plan.allow_hr     = 0;
        fsm->plan.ac_eligible  = 0;
        fsm->plan.deep_sleep   = 1;
        fsm->plan.ac_budget    = 0;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class   = PLAN_CLASS_IDLE_CLEAN;
    } else if (p == PROFILE_BATTERY || (p == PROFILE_BALANCED && !heavy_band)) {
        fsm->plan.sensor_tier  = (p == PROFILE_BALANCED) ? 0 : 1;
        fsm->plan.thermal_div  = 1;
        fsm->plan.allow_hr     = (p == PROFILE_BALANCED);
        fsm->plan.ac_eligible  = (p == PROFILE_BALANCED);
        fsm->plan.deep_sleep   = 0;
        fsm->plan.ac_budget    = (p == PROFILE_BALANCED) ? 3 : 0;
        fsm->plan.sensor_budget = (p == PROFILE_BALANCED) ? 60 : 0;
        fsm->plan.plan_class   = PLAN_CLASS_DAILY_ACTIVE;
    } else {
        /* performance or heavy balanced */
        fsm->plan.sensor_tier  = 0;  /* FULL */
        fsm->plan.thermal_div  = 1;
        fsm->plan.allow_hr     = 1;
        fsm->plan.ac_eligible  = 1;
        fsm->plan.deep_sleep   = 0;
        fsm->plan.ac_budget    = (p == PROFILE_PERFORMANCE) ? 6 : 3;
        fsm->plan.sensor_budget = 120;  /* ~10 min of full reads at 5s ticks */
        fsm->plan.plan_class   = (fsm->ses_intent == INTENT_BENCHMARK)
                                  ? PLAN_CLASS_BENCHMARK : PLAN_CLASS_PERF_ACTIVE;

        /* thermal debt -- halve ac_budget if last perf session
         * was hot (>=75degC) and ended less than 120s ago */
        if (p == PROFILE_PERFORMANCE && g_last_perf_end_ts > 0) {
            time_t elapsed = time(NULL) - g_last_perf_end_ts;
            if (elapsed < 120 && g_last_perf_max_temp >= 75) {
                fsm->plan.ac_budget = fsm->plan.ac_budget / 2;
                if (fsm->plan.ac_budget < 1) fsm->plan.ac_budget = 1;
            }
            /* clamp debt -- if last perf session was vendor_clamped,
             * reduce budget and sensor reads for less aggressive start */
            if (elapsed < 300 && g_last_perf_was_clamped) {
                fsm->plan.ac_budget = fsm->plan.ac_budget / 2;
                if (fsm->plan.ac_budget < 1) fsm->plan.ac_budget = 1;
                asb_log("plan: clamp_debt active (prev session vendor_clamped %lds ago), ac_budget=%d",
                        elapsed, fsm->plan.ac_budget);
            }
        }
    }

    /* user-switch quarantine overrides aggressive settings */
    if (g_user_quarantine_active) {
        fsm->plan.quarantine   = 1;
        fsm->plan.ac_eligible  = 0;
        fsm->plan.ac_prearm    = 0;
        fsm->plan.ac_budget    = 0;
        fsm->plan.allow_hr     = 0;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class   = PLAN_CLASS_QUARANTINE;
    } else {
        fsm->plan.quarantine   = 0;
    }

    /* storm shield -- ultra-light for noisy battery screen-off */
    if (g_storm_shield_active && p == PROFILE_BATTERY && !screen_on) {
        fsm->plan.sensor_tier   = 2;
        fsm->plan.thermal_div   = 5;
        fsm->plan.allow_hr      = 0;
        fsm->plan.ac_eligible   = 0;
        fsm->plan.deep_sleep    = 1;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class    = PLAN_CLASS_IDLE_NOISY;
    }
}

static int g_log_writes = 0;
#define LOG_PERSIST_FILE   "/data/adb/asb/governor_persist.log"
#define LOG_PERSIST_BACKUP "/data/adb/asb/governor_persist.log.1"
#define LOG_PERSIST_MAX_BYTES (256 * 1024)
static FILE *g_logf_persist = NULL;
static int g_log_persist_writes = 0;

static void asb_log_persist(const char *fmt, va_list ap_in) {
    if (!g_logf_persist) {
        g_logf_persist = fopen(LOG_PERSIST_FILE, "a");
        if (!g_logf_persist) return;
    }
    if (++g_log_persist_writes % 50 == 0) {
        long pos = ftell(g_logf_persist);
        if (pos > LOG_PERSIST_MAX_BYTES) {
            fclose(g_logf_persist);
            rename(LOG_PERSIST_FILE, LOG_PERSIST_BACKUP);
            g_logf_persist = fopen(LOG_PERSIST_FILE, "w");
            if (!g_logf_persist) return;
            fprintf(g_logf_persist, "[rotated] previous: %s\n", LOG_PERSIST_BACKUP);
        }
    }
    char ts[32];
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", tm);
    fprintf(g_logf_persist, "[%s] ", ts);
    vfprintf(g_logf_persist, fmt, ap_in);
    fprintf(g_logf_persist, "\n");
    fflush(g_logf_persist);
}

static void asb_log_critical(const char *fmt, ...) __attribute__((format(printf,1,2)));
static void asb_log_critical(const char *fmt, ...) {
    /* Write to transient log first */
    if (g_logf) {
        char ts[32];
        time_t t = time(NULL);
        struct tm *tm = localtime(&t);
        strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", tm);
        fprintf(g_logf, "[%s] [crit] ", ts);
        va_list ap;
        va_start(ap, fmt);
        vfprintf(g_logf, fmt, ap);
        va_end(ap);
        fprintf(g_logf, "\n");
        fflush(g_logf);
    }
    /* Mirror to persistent log */
    va_list ap2;
    va_start(ap2, fmt);
    asb_log_persist(fmt, ap2);
    va_end(ap2);
}

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

/* Module directory for shelling out to our own scripts.
 *
 * Every spawn used to hardcode /data/adb/modules/AutoSystemBoost. That path is fixed by
 * the module id, but only by convention: a renamed module, a manual install into a
 * different directory, or a root solution with another modules root breaks each of those
 * references in silence - the command is backgrounded into /dev/null and its failure is
 * invisible by construction. The governor's own binary lives at <moddir>/bin/asb, so
 * /proc/self/exe resolves the real install location; the standard path stays as the
 * fallback for the odd environment where readlink is denied. */
static const char *asb_moddir(void) {
    static char md[256];
    static int resolved = 0;
    if (!resolved) {
        resolved = 1;
        md[0] = '\0';
        ssize_t n = readlink("/proc/self/exe", md, sizeof(md) - 1);
        if (n > 0) {
            md[n] = '\0';
            char *tail = strstr(md, "/bin/asb");
            if (tail && strcmp(tail, "/bin/asb") == 0) *tail = '\0';
            else md[0] = '\0';
        }
        if (md[0] == '\0')
            snprintf(md, sizeof(md), "%s", "/data/adb/modules/AutoSystemBoost");
    }
    return md;
}

/* Spawn a module script in the background, and SAY when it cannot run.
 *
 * The old pattern was `system("sh <hardcoded path> ... >/dev/null 2>&1 &")` with the
 * return value cast to void: a missing or unreadable script failed in complete silence
 * (the Smart dynamic tuner never ran on any device for exactly this reason - it was
 * exec'd directly and EACCES'd forever). Check readability first and log nonzero
 * returns; rc only reflects the shell spawn itself, the script's own exit stays
 * asynchronous by design. */
static void asb_run_modscript(const char *relpath, const char *args) {
    char path[288];
    snprintf(path, sizeof(path), "%s/%s", asb_moddir(), relpath);
    if (access(path, R_OK) != 0) {
        asb_log("modscript not readable: %s (wanted: %s) - skipped", path, args);
        return;
    }
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "sh %s %s >/dev/null 2>&1 &", path, args);
    int rc = system(cmd);
    if (rc != 0)
        asb_log("modscript %s %s: system() rc=%d", relpath, args, rc);
}

/* Persistent stats live beside session_history.jsonl in /data/adb/asb, for the same reason:
 * the module directory is replaced on every update. Kept there, the per-profile stats, the
 * session aggregate and the OTA-quarantine fingerprint were all wiped by each update - so
 * the quarantine never saw an "old" fingerprint to compare against, and the learning reset
 * in install.sh/service.sh (which already deletes /data/adb/asb/pstats_*) aimed at files
 * that were never there. The old directory is read once as a fallback. */
#define PERSISTENT_STATS_DIR        "/data/adb/asb"
#define PERSISTENT_STATS_DIR_LEGACY "/data/adb/modules/AutoSystemBoost/runtime"
#define PERSISTENT_STATS_FILE       PERSISTENT_STATS_DIR "/session_stats.json"
static const char *g_pstats_files[3] = {
    PERSISTENT_STATS_DIR "/pstats_battery.json",
    PERSISTENT_STATS_DIR "/pstats_balanced.json",
    PERSISTENT_STATS_DIR "/pstats_performance.json"
};
/*
 * session_history.jsonl moved to persistent /data/adb/asb/ so learning survives module
 * reinstall/upgrade.
 */
#define SESSION_HISTORY_FILE        "/data/adb/asb/session_history.jsonl"
#define SESSION_HISTORY_FILE_LEGACY "/data/adb/modules/AutoSystemBoost/runtime/session_history.jsonl"
#define SESSION_HISTORY_MAX   500
#define SESSION_HISTORY_LINE_MAX 2048
/* Hard size cap to prevent unbounded growth. 5 MB = ~2500 max-size lines,
 * comfortably above SESSION_HISTORY_MAX=500 × 2KB/line worst case. */
#define SESSION_HISTORY_SIZE_CAP_BYTES (5 * 1024 * 1024)
#define STATUS_JSON_MAX          4096
#define PERSISTENT_STATS_MAX_SESSIONS 10
#define BAT_FAST_IDLE_FLOOR  5  /* safety: feedback loops cannot go below 5s */

#define ASB_VERSION "V65"

static const char *intent_names[] = {"unknown","benchmark","long_game","idle","mixed","sleep_idle","idle_warm"};

static inline const char *sustained_reason_name(int r) {
    switch (r) {
        case 0:  return "thermal";
        case 1:  return "gaming_unreachable";
        case 2:  return "time_based_escape";
        default: return "unknown";
    }
}

static inline const char *cap_source_classify(int profile_cap,
                                              int runtime_declared,
                                              int actual_sysfs,
                                              int hw_ceiling,
                                              int asb_written) {
    if (actual_sysfs <= 0)  return "policy_unknown";
    if (hw_ceiling > 0 && actual_sysfs > hw_ceiling + 50000) return "policy_unknown";

    /*
     * The ceiling ASB itself wrote to scaling_max_freq is ASB's, whatever msm_performance says.
     *
     * runtime_declared is read back from msm_performance, and the writer only goes through
     * msm_performance in HEAVY/GAMING (msm_perf_boost_only). In every other state it writes
     * scaling_max_freq directly and the msm_performance cap stays at the hardware maximum -
     * so the live ceiling sat below runtime_declared on every Smart tick and fell through to
     * "vendor_clamp" below. Field OP15 capture, LIGHT_IDLE at 35 C: cpu_max 1440000/1747200
     * (exactly what ASB wrote), cap_source vendor_clamp on both clusters, vendor_clamp_1h=424,
     * cap_vendor_holddown_active=1 - the governor backing off from its own writes, the
     * thermal veto counting them as vendor pressure, and the logkit's throttle owner split
     * reading "vendor" for an ASB cap.
     *
     * Equal is the only test: a live value below ours is still somebody else's clamp (a
     * freq QoS request lower than ours), a value above ours is somebody rewriting the node.
     */
    if (asb_written > 0 && actual_sysfs == asb_written) {
        return (profile_cap > 0 && actual_sysfs == profile_cap) ? "asb" : "asb_dynamic";
    }

    /*
     * Shell-only branch: runtime_declared==0 means governor didn't register caps via
     * msm_performance (typical for battery profile where caps are applied via service.sh
     * shell-layer only).
     */
    if (runtime_declared <= 0) {
        if (profile_cap <= 0) return "policy_unknown";
        if (actual_sysfs == profile_cap) return "shell_applied";
        if (actual_sysfs >  profile_cap) return "shell_overridden_up";
        /* actual < profile — could be legitimate vendor thermal cooldown,
         * not necessarily a problem. */
        return "shell_overridden_down";
    }

    /* Runtime-tracked branch: governor registered caps via msm_performance. */
    if (profile_cap > 0 && runtime_declared == profile_cap
        && actual_sysfs == profile_cap) {
        return "asb";
    }
    if (actual_sysfs == runtime_declared && runtime_declared != profile_cap) {
        return "asb_dynamic";
    }
    if (profile_cap > 0 && actual_sysfs == profile_cap
        && runtime_declared != profile_cap) {
        return "thermal_overlay";
    }
    if (actual_sysfs > runtime_declared) {
        return "vendor_raised";
    }
    if (actual_sysfs < runtime_declared
        && (hw_ceiling <= 0 || actual_sysfs < hw_ceiling)) {
        return "vendor_clamp";
    }
    return "mismatch";
}

/*
 * fix182: the ceiling the SHELL wrote in a manual profile.
 *
 * In battery and balanced the writer leaves the CPU ceilings to service.sh
 * (manual_cap_skip in asb_writer.h): per-device percentages of each cluster's maximum,
 * applied by apply_cpufreq_caps. The classifier above never knew those values. It only had
 * msm_performance (the vendor's own cap, near the hardware maximum outside HEAVY/GAMING) and
 * the governor's write cache, so every tick on a phone holding the shell's cap read
 * "vendor_clamp". A OnePlus 15 day on Battery: cpu_max 1785600/1747200 - exactly the
 * shell's 50/38 % - reported as vendor_clamp, vendor_clamp_1h up to 441, the throttle
 * report "foreign cap ownership dominated" and cap_verify comparing against a legacy
 * 921600 that nothing writes any more.
 *
 * That count is not only a label. The governor process lives across a profile switch, and
 * Smart's thermal veto fires on vendor_clamp_1h >= 300 once the body is warm: for up to an
 * hour after leaving Battery, Smart could be held at alpha_battery >= 700 by clamps that
 * were the shell's own ceiling.
 *
 * service.sh records what it wrote (/dev/.asb/shell_cpu_caps) and, from fix183, the
 * screen-on rung of every manual profile ahead of time; the reader lives in asb_writer.h
 * (asb_shell_cap_for_policy), which needs it to hand ceilings back. It is trusted only while
 * the governor itself stays off the ceiling - a manual profile with no thermal cap and no
 * screen-off cooldown - and only for the profile that is running.
 */
/* The writer's own rule for "the shell owns the CPU ceilings" (manual_cap_skip).
 * fix212: while the unlock/launch lift runs on a manual profile the ceilings above are
 * the governor's own, not the shell's - reading them as the shell's would classify the
 * lift itself as a vendor clamp once the lift ends. */
static int asb_manual_shell_owns_caps(const asb_fsm_t *fsm) {
    return fsm && !fsm_profile_is_smart && !fsm_profile_is_performance && !fsm->thermal_cap &&
           !g_fsm_cooldown_active && !g_unlock_lift_now;
}

/* The shell's ceiling for a governor slot, or 0 when it is not the owner or not known. */
static int asb_shell_cap_khz(const asb_fsm_t *fsm, int slot) {
    if (slot < 0 || slot > 2 || !asb_manual_shell_owns_caps(fsm)) return 0;
    return asb_shell_cap_for_policy(fsm->profile_idx, g_cpu_policy_ids[slot]);
}

/* Classification against the shell's value. Equal is the shell's own ceiling; above it
 * someone raised the node (the existing "shell_overridden_up", counted against the
 * shell); below it is a ceiling nobody in ASB wrote - a vendor clamp, and only that is
 * counted as one. */
static inline const char *cap_source_classify_shell(int shell_cap, int actual_sysfs,
                                                    int hw_ceiling) {
    if (actual_sysfs <= 0 || shell_cap <= 0) return "policy_unknown";
    if (hw_ceiling > 0 && actual_sysfs > hw_ceiling + 50000) return "policy_unknown";
    if (actual_sysfs == shell_cap) return "shell_applied";
    if (actual_sysfs >  shell_cap) return "shell_overridden_up";
    return "vendor_clamp";
}

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
            if (new_cap > SIZE_MAX / sizeof(char *)) {
                fclose(rf);
                for (size_t i = 0; i < count; i++) free(lines[i]);
                free(lines);
                return 0;
            }
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
                size_t bn = strlen(buf);
                if (bn >= sizeof(last_line)) bn = sizeof(last_line) - 1;
                memcpy(last_line, buf, bn);
                last_line[bn] = '\0';
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
    /* cause streak -- consecutive sessions with same limiter/reason */
    int   cause_streak;       /* how many consecutive same-cause sessions */
    int   cause_streak_type;  /* 0=none 1=wake_noise 2=screen_on 3=no_settle 4=vendor_clamp 5=thermal */
    /* OTA quarantine -- skip learning after environment change */
    int   quarantine_remaining; /* >0 = skip pstats learning for N more clean sessions */
    
    float avg_idle_q;            /* average idle quality across clean sessions */
    float avg_wph;               /* average wakes per hour */
    int   clean_night_count;     /* how many clean_night sessions recorded */
    float avg_quiet_duration_min;/* average quiet night duration in minutes */
    /* Battery Memory Split -- separate night vs day tracking */
    float night_avg_iq;
    float night_avg_wph;
    int   night_count;
    float day_avg_iq;
    float day_avg_wph;
    int   day_count;
    long  last_tune_ts_fast_idle;
    long  last_tune_ts_heavy_load;
    long  last_tune_ts_moderate_load;
    long  last_tune_ts_light_gpu;
} asb_persistent_stats_t;

static asb_persistent_stats_t g_pstats_per[3] = {{0},{0},{0}};
static asb_persistent_stats_t g_pstats = {0};

static void session_plan_apply_prearm(asb_fsm_t *fsm) {
    if (fsm->profile_idx != PROFILE_PERFORMANCE) return;
    if (fsm->state < ASB_STATE_HEAVY) return;
    asb_persistent_stats_t *ps = &g_pstats_per[PROFILE_PERFORMANCE];
    if (ps->cause_streak_type == 4 && ps->cause_streak >= 3)
        fsm->plan.ac_prearm = 1;
}

static void session_reset_and_replan(asb_fsm_t *fsm, int screen_on) {
    fsm_session_reset(fsm);
    fsm->plan.ac_used = 0;
    storm_shield_reset();
    anti_clamp_reset();
    action_waste_reset();
    session_plan_build(fsm, screen_on);
    session_plan_apply_prearm(fsm);
}

/* vendor clamp counters — declared early so write_state can emit them.
 * Incremented from v44_conflict_record() during status JSON build. */
static unsigned long g_v44_clamp_total = 0;       /* total times we saw "vendor_clamp" */
static unsigned long g_v44_raised_total = 0;      /* total times we saw "vendor_raised" */
static unsigned long g_v44_clamp_1h = 0;          /* rolling 1h window */
/* An actual rolling hour, not a tumbling one.
 *
 * The comment above always said "rolling", but the code reset the count to zero at a
 * fixed hour boundary. So the number climbed for sixty minutes and fell off a cliff: on a
 * device clamping ~300 times an hour the thermal veto, which trips at 300, came on for
 * the last 6-10 minutes of every hour and went off at the reset - 18:07-18:25, 20:20-
 * 20:26, 21:17-21:26 - each window ending a minute or two before the hourly snapshot.
 * The snapshots, taken just after the reset, read 5-9 and made the veto look causeless.
 *
 * An exponential decay with a one-hour time constant: steady clamping at R per hour
 * settles at R, a burst fades smoothly instead of vanishing on the hour, and the veto
 * follows the actual rate instead of the position of the clock. */
static double        g_v44_clamp_rate = 0.0;
static time_t        g_v44_clamp_rate_ts = 0;
static void v44_clamp_decay(time_t now) {
    if (g_v44_clamp_rate_ts == 0) { g_v44_clamp_rate_ts = now; return; }
    long dt = (long)(now - g_v44_clamp_rate_ts);
    if (dt <= 0) return;
    g_v44_clamp_rate *= exp(-(double)dt / 3600.0);
    if (g_v44_clamp_rate < 0.01) g_v44_clamp_rate = 0.0;
    g_v44_clamp_rate_ts = now;
}
static unsigned long v44_clamp_1h_now(void);

/* cap ownership — declared early so write_state can emit them.
 * Updated by asb_cap_compute_owner() from status JSON path. */
static int    g_cap_owner_eff = 0;
static time_t g_cap_owner_since = 0;
static int    g_cap_recent_vendor_clamps = 0;
static time_t g_cap_recent_window_start = 0;
static int    g_cap_slow_vendor_clamps = 0;
static time_t g_cap_slow_window_start = 0;
static time_t g_cap_vendor_hold_until = 0;
/* Set when the vendor owns the cap outright - see asb_cap_writes_should_back_off. Declared
   here with the rest of the cap state because write_state() reports it and runs earlier in
   the file than the function that maintains it. */
/* One read of scaling_max_freq per policy per tick, not five.
 *
 * The main loop reads the same two nodes from at least six places - the reconcile check,
 * the drift detector, the clamp probe, the ownership classifier and the state writer -
 * and each one opens, reads and closes independently. On a tick where nothing changed
 * that is ten syscalls to learn two numbers that cannot have moved between them, because
 * nothing in the loop writes them in that window.
 *
 * Cached for the tick and invalidated at the top of the next one. Deliberately not longer:
 * the vendor CAN move these behind our back, and a stale reading there is how the
 * ownership classifier starts lying.
 */
static int  g_tick_smax[3]       = { -1, -1, -1 };
static int  g_tick_smax_valid    = 0;

static int tick_scaling_max(int slot) {
    if (slot < 0 || slot > 2) return 0;
    if (!g_tick_smax_valid) {
        for (int i = 0; i < 3; i++) g_tick_smax[i] = -1;
        g_tick_smax_valid = 1;
    }
    if (g_tick_smax[slot] < 0)
        g_tick_smax[slot] = sysfs_read_int(cpu_policy_path(slot, "scaling_max_freq"), 0);
    return g_tick_smax[slot];
}

static void tick_scaling_max_invalidate(void) { g_tick_smax_valid = 0; }

static int    g_cap_vendor_passive    = 0;
/* Set once at startup; the denominator for every per-hour rate in the report. */
static time_t g_governor_start_ts     = 0;
static int    g_cap_detente_active = 0;
static time_t g_cap_detente_since = 0;
static long   g_cap_detente_skipped = 0;
static long   g_write_attempts = 0;
static long   g_write_skipped_detente = 0;
static long   g_write_skipped_backoff = 0;
static int    g_drain_spike_bump = 0;
static time_t g_drain_spike_until = 0;
/* Budget accuracy: snapshot a prediction, then grade it after a window. */
static time_t g_budget_acc_anchor_ts = 0;
static int    g_budget_acc_anchor_pct = -1;
static int    g_budget_acc_pred_h_x10 = -1;
static int    g_budget_acc_error_pct = -1;
static int    g_budget_acc_score = -1;
static int    g_budget_bias_dir = 0;
static int    g_budget_bias_streak = 0;

/* Forward declarations for write_state */
static int asb_cap_writes_should_back_off(void);
static const char *asb_cap_owner_name(int o);

/*
 * — V50 night window learner.
 * Both are EWMA'd as minutes-of-day with circular midnight wrap and persisted, so after
 * night_quiet_auto_min_samples nights the learned window replaces the static hours for
 * quiet-night acceleration and for the Smart sleep override (which previously ended at the
 * fixed 09:00 daypart boundary even when the user was still asleep).
 */
#define NIGHT_WINDOW_FILE "/data/adb/asb/night_window.conf"
static int    g_night_sleep_min = -1;
static int    g_night_wake_min  = -1;
static int    g_night_samples   = 0;
static time_t g_night_off_since = 0;
static int    g_night_off_minute = -1;
static int    g_night_chain_min = -1;   /* first screen-off minute of the dark chain, -1 = none */
static int    g_night_chain_night = 0;  /* one of the chain's dark periods began in the onset window */
static time_t g_night_on_since = 0;     /* when the screen last came on, 0 = screen off */
static int    g_night_samples_accepted = 0;
static int    g_night_samples_rejected = 0;
static int    g_night_reject_reason = 0;
#define ASB_NIGHT_REJECT_NONE 0
#define ASB_NIGHT_REJECT_WAKE_OUT_OF_WINDOW 1
static long   g_night_dark_accum_s = 0;
static int    g_night_prev_screen = -1;
static int    g_night_pending_wake_min = -1;
static time_t g_night_pending_wake_ts = 0;

static int asb_minute_of_day(time_t t) {
    struct tm tmv;
    if (!localtime_r(&t, &tmv)) return -1;
    return tmv.tm_hour * 60 + tmv.tm_min;
}

static int asb_min_in_window(int m, int from, int to) {
    if (m < 0) return 0;
    return (from > to) ? (m >= from || m < to) : (m >= from && m < to);
}

static void asb_night_ewma(int *cur, int sample) {
    if (*cur < 0) { *cur = sample; return; }
    int d = ((sample - *cur) % 1440 + 1440) % 1440;
    if (d > 720) d -= 1440;
    *cur = ((*cur + (d * ASB_NIGHT_EWMA_NUM) / ASB_NIGHT_EWMA_DEN) + 1440) % 1440;
}

static void asb_night_window_save(void) {
    FILE *f = fopen(NIGHT_WINDOW_FILE ".tmp", "w");
    if (!f) return;
    fprintf(f, "sleep_min=%d\nwake_min=%d\nsamples=%d\n",
            g_night_sleep_min, g_night_wake_min, g_night_samples);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    rename(NIGHT_WINDOW_FILE ".tmp", NIGHT_WINDOW_FILE);
}

static void asb_night_window_load(void) {
    FILE *f = fopen(NIGHT_WINDOW_FILE, "r");
    if (!f) return;
    char line[64];
    while (fgets(line, sizeof(line), f)) {
        int v;
        if (sscanf(line, "sleep_min=%d", &v) == 1 && v >= -1 && v < 1440)
            g_night_sleep_min = v;
        else if (sscanf(line, "wake_min=%d", &v) == 1 && v >= -1 && v < 1440)
            g_night_wake_min = v;
        else if (sscanf(line, "samples=%d", &v) == 1 && v >= 0 && v <= 100000)
            g_night_samples = v;
    }
    fclose(f);
    if (g_night_sleep_min >= 0 && g_night_wake_min >= 0)
        asb_log("night_window: loaded learned %02d:%02d -> %02d:%02d (n=%d)",
                g_night_sleep_min / 60, g_night_sleep_min % 60,
                g_night_wake_min / 60, g_night_wake_min % 60, g_night_samples);
}

static int asb_night_window_ready(void) {
    return g_asb_cfg.night_quiet_auto &&
           g_night_samples >= g_asb_cfg.night_quiet_auto_min_samples &&
           g_night_sleep_min >= 0 && g_night_wake_min >= 0;
}

static int asb_night_window_active(time_t now) {
    if (!asb_night_window_ready()) return 0;
    int m = asb_minute_of_day(now);
    if (m < 0) return 0;
    int from = (g_night_sleep_min - ASB_NIGHT_MARGIN_PRE_MIN + 1440) % 1440;
    int to   = (g_night_wake_min  - ASB_NIGHT_MARGIN_POST_MIN + 1440) % 1440;
    return asb_min_in_window(m, from, to);
}

/* One night is one dark chain (fix166).
 *
 * The learner used to take an onset from any screen-off that lasted an hour inside
 * 19:00-05:00, and a wake from any screen-on after three hours of darkness summed since the
 * last accepted wake. Both read single events as nights:
 *
 *   - Capture 29835: asleep about 03:10, a one-minute glance at 03:50, and the 03:50
 *     screen-off became "onset sample 03:50", moving the learned bedtime from 23:46 to
 *     00:47. Earlier captures log two and three onsets in one night (23:15, 00:30, 02:00),
 *     each one an EWMA step of its own.
 *   - "wake sample 13:06 -> learned 12:42": a phone on a desk since the morning wake, picked
 *     up for a few minutes now and then, sums three hours of darkness by noon - and the
 *     midday pickup was learned as the wake. On this OP15 the learned wake reads 08:52
 *     against real mornings of 06:43-08:10.
 *
 * Now the screen-off periods joined by checks shorter than ASB_NIGHT_AWAKE_BREAK_S form a
 * chain, and ten minutes on screen ends it. The chain is a night only if it holds three
 * hours of darkness and one of its dark periods began inside the onset window; then onset
 * and wake are learned together, once, when the wake has held for ten minutes. A chain that
 * began before the window still gives its wake, but no onset - its first screen-off was the
 * evening, not bedtime. */
static void asb_night_chain_end(void) {
    g_rec.mw.tonight = 0;   /* fix184: the checks of a chain that was not a night are not counted */
    g_night_dark_accum_s = 0;
    g_night_chain_min = -1;
    g_night_chain_night = 0;
    g_night_pending_wake_min = -1;
    g_night_pending_wake_ts = 0;
}

/* A screen-on that held for ten minutes ends the chain; decide what it was.
 *
 * Every verdict waits for this point. A glance shorter than that is part of the night, so a
 * look at the clock at 02:30 neither rejects the night nor restarts it - deciding at the
 * screen-on edge did both. */
static void asb_night_wake_confirm(void) {
    int wake = g_night_pending_wake_min;
    if (!g_night_chain_night) {
        /* Three hours of darkness that never began at night: a phone on a desk. */
        asb_night_chain_end();
        return;
    }
    if (!asb_min_in_window(wake, ASB_NIGHT_WAKE_WIN_FROM, ASB_NIGHT_WAKE_WIN_TO)) {
        /* Woke outside the plausible wake window — likely an
           irregular night (nap, travel, odd schedule). Reject the
           sample rather than dragging the learned wake time toward
           a one-off outlier. */
        asb_night_chain_end();
        g_night_samples_rejected++;
        g_night_reject_reason = ASB_NIGHT_REJECT_WAKE_OUT_OF_WINDOW;
        return;
    }
    int onset = asb_min_in_window(g_night_chain_min, ASB_NIGHT_ONSET_WIN_FROM,
                                  ASB_NIGHT_ONSET_WIN_TO) ? g_night_chain_min : -1;
    if (onset >= 0) asb_night_ewma(&g_night_sleep_min, onset);
    asb_night_ewma(&g_night_wake_min, wake);
    if (g_night_samples < 100000) g_night_samples++;
    g_night_samples_accepted++;
    asb_mw_night_end();   /* fix184: this night's checks, before the chain is cleared */
    if (onset >= 0)
        asb_log("night_window: night %02d:%02d-%02d:%02d -> learned %02d:%02d-%02d:%02d (n=%d)",
                onset / 60, onset % 60, wake / 60, wake % 60,
                g_night_sleep_min / 60, g_night_sleep_min % 60,
                g_night_wake_min / 60, g_night_wake_min % 60, g_night_samples);
    else
        asb_log("night_window: night ?-%02d:%02d (dark since the evening, bedtime not learned)"
                " -> learned wake %02d:%02d (n=%d)",
                wake / 60, wake % 60, g_night_wake_min / 60, g_night_wake_min % 60,
                g_night_samples);
    asb_night_chain_end();
    asb_night_window_save();
}

static void asb_night_window_tick(int screen_on, time_t now) {
    if (!g_asb_cfg.night_quiet_auto) return;
    if (g_night_prev_screen < 0) {
        g_night_prev_screen = screen_on;
        if (!screen_on) {
            g_night_off_since = now;
            g_night_off_minute = asb_minute_of_day(now);
            g_night_chain_min = g_night_off_minute;
            g_night_chain_night = asb_min_in_window(g_night_off_minute, ASB_NIGHT_ONSET_WIN_FROM,
                                                    ASB_NIGHT_ONSET_WIN_TO);
        } else {
            g_night_on_since = now;
        }
        return;
    }
    if (screen_on != g_night_prev_screen) {
        if (!screen_on) {
            /* The tick that should have confirmed may not have run before the screen went
               off again; the screen-on duration decides, not which tick saw it. */
            if (g_night_on_since > 0 && now - g_night_on_since >= ASB_NIGHT_AWAKE_BREAK_S) {
                if (g_night_pending_wake_min >= 0) asb_night_wake_confirm();
                else asb_night_chain_end();
            } else {
                /* mid-night check, not a real wake — keep accumulating */
                g_night_pending_wake_min = -1;
                g_night_pending_wake_ts = 0;
                /* fix184: a check in the middle of a night - an hour of darkness behind it,
                 * inside this user's learned night or a chain that began at bedtime - is a
                 * night wake the Smart records learn (time of night, length, how many). */
                if (g_night_on_since > 0 && g_night_dark_accum_s >= 3600 &&
                    (g_night_chain_night || asb_night_window_active(g_night_on_since)))
                    asb_mw_note((long)g_night_on_since, (long)(now - g_night_on_since));
            }
            g_night_off_since = now;
            g_night_off_minute = asb_minute_of_day(now);
            if (g_night_chain_min < 0) g_night_chain_min = g_night_off_minute;
            if (asb_min_in_window(g_night_off_minute, ASB_NIGHT_ONSET_WIN_FROM,
                                  ASB_NIGHT_ONSET_WIN_TO))
                g_night_chain_night = 1;
            g_night_on_since = 0;
        } else {
            long off_dur = (g_night_off_since > 0)
                           ? (long)(now - g_night_off_since) : 0;
            if (off_dur > 0) g_night_dark_accum_s += off_dur;
            if (g_night_dark_accum_s >= ASB_NIGHT_MIN_SLEEP_S) {
                g_night_pending_wake_min = asb_minute_of_day(now);
                g_night_pending_wake_ts = now;
            }
            g_night_off_since = 0;
            g_night_on_since = now;
        }
        g_night_prev_screen = screen_on;
        return;
    }
    if (!screen_on || g_night_on_since <= 0 || now - g_night_on_since < ASB_NIGHT_AWAKE_BREAK_S)
        return;
    if (g_night_pending_wake_min >= 0) asb_night_wake_confirm();
    else if (g_night_chain_min >= 0 || g_night_dark_accum_s > 0) asb_night_chain_end();
}

/* ---- fix184: Smart records - the governor's side of asb_record.h -------------------- */
static long long asb_rec_net_bytes(void) {
    long long w = (long long)sysfs_read_long(PATH_WLAN_RX, 0) + (long long)sysfs_read_long(PATH_WLAN_TX, 0);
    long long r = (long long)rmnet_read_total("rx_bytes") + (long long)rmnet_read_total("tx_bytes");
    return w + r;
}
static int asb_rec_bright_pct(void) {
    int b  = sysfs_read_int(PATH_BACKLIGHT, -1);
    int mx = sysfs_read_int("/sys/class/backlight/panel0-backlight/max_brightness", 0);
    if (b < 0 || mx <= 0) return -1;
    return (int)((long)b * 100 / mx);
}
/* Screen on: does a cluster sit at its ceiling right now (within one ~100 MHz step)? The
 * records' comfort guard - a cheaper setting that keeps the cores pinned more is slower, not
 * better. cur_freq is MHz, the ceiling kHz. */
static int asb_rec_at_ceiling(const asb_metrics_t *m) {
    for (int s = 0; s < 3; s++) {
        if (g_cpu_policy_ids[s] < 0) continue;
        int live = tick_scaling_max(s);
        int cur  = m->cpu.cur_freq[s];
        if (live <= 0 || cur <= 0) continue;
        if ((long)cur * 1000L >= (long)live - 100000L) return 1;
    }
    return 0;
}

/* Night wakes (fix184). Decided at the screen-on edge from this user's own habit, held for at
 * most asb_mw_hold_s(); a screen-on that outlasts it is a real wake. */
static int           g_mw_active    = 0;   /* this screen-on is treated as a night check */
static int           g_mw_predicted = 0;
static unsigned long g_mw_holds     = 0;   /* screen-ons kept in the night radio mode */
static int           g_mw_prev_screen = -1;
static void asb_mw_update(int screen_on, int smart, time_t now) {
    if (screen_on != g_mw_prev_screen) {
        g_mw_predicted = 0;
        if (screen_on && g_mw_prev_screen == 0 && smart && g_asb_cfg.smart_microwake) {
            g_mw_predicted = asb_mw_predict((long)now, asb_night_window_active(now),
                                            g_night_dark_accum_s);
            if (g_mw_predicted) {
                g_mw_holds++;
                asb_log("microwake: screen on after %ld min of darkness - looks like a night check "
                        "(%u learned, usually %.0f s): night radio mode kept for up to %ld s",
                        g_night_dark_accum_s / 60, g_rec.mw.total, g_rec.mw.dur_ewma_s, asb_mw_hold_s());
            }
        }
        g_mw_prev_screen = screen_on;
    }
    int was = g_mw_active;
    g_mw_active = screen_on && g_mw_predicted && smart && g_night_on_since > 0 &&
                  (long)(now - g_night_on_since) < asb_mw_hold_s();
    if (was && !g_mw_active && screen_on)
        asb_log("microwake: still on after %ld s - a real wake, day radio mode", (long)(now - g_night_on_since));
}

/* ---- fix185: smoothness probe ----------------------------------------------------------
 * Android's frame statistics for the app in front, at most every three minutes of screen-on
 * time, read in the background (runtime/asb_gfx_probe.sh writes /dev/.asb/gfx.txt: one line
 * "package frames janky" per package, from dumpsys graphicsstats - served by system_server
 * from the buffer each app shares with it, so the app itself is not called). The delta
 * between two probes is one window for asb_smooth_window. A window counts only if the same
 * app was in front, the screen stayed on and one smoothness arm was in force throughout. */
#define ASB_GFX_FILE     "/dev/.asb/gfx.txt"
#define ASB_SMOOTH_PROBE_S 180
static long     g_unplug_age_s = 1000000L;
static int      g_smooth_lean = 0;          /* x1000, the smoothness lean for the app in front */
static uint64_t g_smooth_win_hash = 0;      /* app the current window belongs to */
static char     g_smooth_win_pkg[64];
static long     g_smooth_win_frames = -1, g_smooth_win_janky = -1;
static int      g_smooth_win_arm = -1;      /* arm in force since the window began, -1 = mixed */
static long     g_smooth_probe_ts = 0;      /* when the last probe was asked for */
static long     g_smooth_gfx_seen = 0;      /* mtime of the gfx file last parsed */
static unsigned long g_smooth_probes = 0, g_smooth_windows = 0;

/* "frames janky" of one package in the probe file; 0 found, -1 not. */
static int asb_gfx_read_pkg(const char *pkg, long *frames, long *janky) {
    FILE *f = fopen(ASB_GFX_FILE, "r");
    if (!f || !pkg || !*pkg) { if (f) fclose(f); return -1; }
    char line[256];
    size_t pl = strlen(pkg);
    int rc = -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, pkg, pl) == 0 && line[pl] == ' ') {
            long fr = -1, jk = -1;
            if (sscanf(line + pl + 1, "%ld %ld", &fr, &jk) == 2 && fr >= 0 && jk >= 0) {
                *frames = fr; *janky = jk; rc = 0;
            }
            break;
        }
    }
    fclose(f);
    return rc;
}

static void asb_smooth_window_reset(uint64_t hash, const char *pkg) {
    g_smooth_win_hash = hash;
    snprintf(g_smooth_win_pkg, sizeof(g_smooth_win_pkg), "%s", pkg ? pkg : "");
    g_smooth_win_frames = -1; g_smooth_win_janky = -1;
    g_smooth_win_arm = -1;
}

/* fix258: the opt-in infinite logger may ask for an earlier NATIVE probe after two
 * comparable, sufficiently large jank intervals. It never supplies an A/B window:
 * GraphicsStats is read again below and counted exactly once. All freshness,
 * capture/sequence, scenario, plateau and rate gates live here in the single owner. */
#define ASB_SMOOTH_LOG_READ_S       10
#define ASB_SMOOTH_LOG_MIN_PROBE_S  45
#define ASB_SMOOTH_LOG_APP_COOLDOWN_S 600
static long g_smooth_log_read_ts = 0, g_smooth_log_due = 0, g_smooth_log_accept_ts = 0;
static uint64_t g_smooth_log_accept_hash = 0;
static char g_smooth_log_capture[32] = {0};
static unsigned long g_smooth_log_seq = 0;
static unsigned long g_smooth_log_accepted = 0, g_smooth_log_rejected = 0, g_smooth_log_suppressed = 0;
static unsigned long g_smooth_log_checks = 0, g_smooth_log_reads = 0, g_smooth_log_changes = 0, g_smooth_log_unchanged = 0;
static struct stat g_smooth_log_seen;
static int g_smooth_log_seen_valid = 0;
static long g_smooth_log_last_epoch = 0, g_smooth_log_last_jank = 0;
static char g_smooth_log_status[24] = "disabled";

static void asb_smooth_log_hint_tick(uint64_t hash, long now) {
    if (g_smooth_log_read_ts && now - g_smooth_log_read_ts < ASB_SMOOTH_LOG_READ_S &&
        now >= g_smooth_log_read_ts) return;
    g_smooth_log_read_ts = now;
    g_smooth_log_checks++;
    struct stat st;
    if (stat(ASB_LOG_FEEDBACK_FILE, &st) != 0) {
        g_smooth_log_seen_valid = 0;
        g_smooth_log_due = 0;
        snprintf(g_smooth_log_status, sizeof(g_smooth_log_status), "disabled");
        return;
    }
    /* A full file identity, not just mtime/size: atomic replacement, same-size rewrites and
     * timestamp-only updates are all detected. Unchanged bodies are neither read nor parsed. */
    if (g_smooth_log_seen_valid && st.st_dev == g_smooth_log_seen.st_dev &&
        st.st_ino == g_smooth_log_seen.st_ino && st.st_size == g_smooth_log_seen.st_size &&
        st.st_mtime == g_smooth_log_seen.st_mtime && st.st_mtim.tv_nsec == g_smooth_log_seen.st_mtim.tv_nsec &&
        st.st_ctime == g_smooth_log_seen.st_ctime && st.st_ctim.tv_nsec == g_smooth_log_seen.st_ctim.tv_nsec) {
        g_smooth_log_unchanged++;
        return;
    }
    g_smooth_log_seen = st;
    g_smooth_log_seen_valid = 1;
    g_smooth_log_changes++;
    FILE *f = fopen(ASB_LOG_FEEDBACK_FILE, "rb");
    if (!f) {
        g_smooth_log_due = 0;
        snprintf(g_smooth_log_status, sizeof(g_smooth_log_status), "disabled");
        return;
    }
    g_smooth_log_reads++;
    char buf[ASB_LOG_FEEDBACK_MAX_BYTES];
    size_t n = fread(buf, 1, sizeof(buf), f);
    int truncated = !feof(f);
    fclose(f);
    if (truncated) { g_smooth_log_rejected++; snprintf(g_smooth_log_status, sizeof(g_smooth_log_status), "invalid"); return; }
    asb_log_feedback_t fb;
    int rc = asb_log_feedback_parse(buf, n, now, &fb);
    if (rc != ASB_LOG_FEEDBACK_VALID) {
        g_smooth_log_rejected++;
        snprintf(g_smooth_log_status, sizeof(g_smooth_log_status), "%s",
                 rc == ASB_LOG_FEEDBACK_STALE ? "stale" : rc == ASB_LOG_FEEDBACK_FUTURE ? "future" : "invalid");
        return;
    }
    int new_capture = strcmp(g_smooth_log_capture, fb.capture) != 0;
    if (!new_capture && fb.seq <= g_smooth_log_seq) return; /* atomic file reread: deduplicated */
    snprintf(g_smooth_log_capture, sizeof(g_smooth_log_capture), "%s", fb.capture);
    g_smooth_log_seq = fb.seq;
    g_smooth_log_last_epoch = fb.epoch; g_smooth_log_last_jank = fb.jank_x1000;
    if (fb.app_hash != hash || fb.app_hint != g_smart_rt.app_hint ||
        fb.app_hint >= ASB_APP_GAMING || fb.bucket_id != (int)g_smart_rt.bucket_id ||
        fb.bucket_id < 0 || fb.bucket_id >= ASB_SMART_BUCKETS) {
        g_smooth_log_rejected++; snprintf(g_smooth_log_status, sizeof(g_smooth_log_status), "scenario");
        return;
    }
    if (!asb_smooth_log_hint_useful(hash, now)) {
        g_smooth_log_suppressed++; snprintf(g_smooth_log_status, sizeof(g_smooth_log_status), "plateau");
        return;
    }
    if (g_smooth_log_accept_hash == hash && g_smooth_log_accept_ts &&
        now - g_smooth_log_accept_ts < ASB_SMOOTH_LOG_APP_COOLDOWN_S &&
        now >= g_smooth_log_accept_ts) {
        g_smooth_log_suppressed++; snprintf(g_smooth_log_status, sizeof(g_smooth_log_status), "cooldown");
        return;
    }
    g_smooth_log_accept_hash = hash; g_smooth_log_accept_ts = now;
    g_smooth_log_due = now;
    if (g_smooth_probe_ts > 0 && g_smooth_probe_ts + ASB_SMOOTH_LOG_MIN_PROBE_S > now)
        g_smooth_log_due = g_smooth_probe_ts + ASB_SMOOTH_LOG_MIN_PROBE_S;
    g_smooth_log_accepted++;
    snprintf(g_smooth_log_status, sizeof(g_smooth_log_status), "accepted");
}

static void asb_smooth_probe_tick(const asb_fsm_t *fsm, const asb_metrics_t *m) {
    long now = (long)time(NULL);
    int on = g_asb_cfg.smart_smooth && fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
             m->misc.screen_on && g_pkg_detect_ok && g_smart_rt.app_hash != 0 &&
             g_smart_rt.app_hint < ASB_APP_GAMING && !m->misc.camera_active &&
             g_smart_rt.app_pkg_cached[0] && !asb_smart_is_system_ui(g_smart_rt.app_pkg_cached);
    if (!on) {
        g_smooth_lean = 0; g_rec_smooth_testing = 0; g_smooth_log_due = 0;
        if (g_smooth_win_hash) asb_smooth_window_reset(0, NULL);
        return;
    }
    uint64_t h = g_smart_rt.app_hash;
    asb_smooth_log_hint_tick(h, now);
    g_smooth_lean = asb_smooth_offset_for(h, now);
    int arm = (g_smooth_lean != 0) ? 1 : 0;
    if (h != g_smooth_win_hash) {              /* another app: a fresh window */
        g_smooth_log_due = 0;                  /* a hint never crosses an app boundary */
        asb_smooth_window_reset(h, g_smart_rt.app_pkg_cached);
    }
    /* No probe out of turn on an app switch (fix186). It used to probe at once to start the
     * new app's window, and an OP15 capture counted 91 probes in about 85 minutes of screen
     * time - one a minute, for 7 complete windows - against "at most every three minutes".
     * The next regular probe starts the window instead. */
    if (g_smooth_win_arm == -1) g_smooth_win_arm = arm;
    else if (g_smooth_win_arm != arm) g_smooth_win_arm = -2;   /* the arm changed mid-window */
    /* A finished probe: one window (if there was a start), and the start of the next. */
    struct stat st;
    if (stat(ASB_GFX_FILE, &st) == 0 && (long)st.st_mtime != g_smooth_gfx_seen &&
        g_smooth_probe_ts > 0 && (long)st.st_mtime >= g_smooth_probe_ts) {
        g_smooth_gfx_seen = (long)st.st_mtime;
        long fr = -1, jk = -1;
        if (asb_gfx_read_pkg(g_smooth_win_pkg, &fr, &jk) == 0) {
            if (g_smooth_win_frames >= 0 && fr >= g_smooth_win_frames && jk >= g_smooth_win_janky &&
                g_smooth_win_arm >= 0) {
                g_smooth_windows++;
                /* The log names the app the way the rest of Smart does: by hash, unless this
                 * is a debug build or smart_pkg_plaintext=1. */
                char disp[64];
                if (g_asb_cfg.smart_pkg_plaintext || ASB_DEBUG_BUILD)
                    snprintf(disp, sizeof(disp), "%s", g_smooth_win_pkg);
                else
                    snprintf(disp, sizeof(disp), "app %016llx", (unsigned long long)h);
                if (asb_smooth_window(h, disp, fr - g_smooth_win_frames,
                                      jk - g_smooth_win_janky, g_smooth_win_arm, now) && g_smooth_event) {
                    asb_log("%s", g_smooth_event_msg);
                    g_smooth_event = 0;
                    g_rec_saved_ts = 0;
                }
            }
            g_smooth_win_frames = fr; g_smooth_win_janky = jk;
            /* The next window runs under whatever arm is in force from now on. */
            g_smooth_lean = asb_smooth_offset_for(h, now);
            g_smooth_win_arm = (g_smooth_lean != 0) ? 1 : 0;
        }
    }
    int log_due = g_smooth_log_due > 0 && now >= g_smooth_log_due;
    if (g_smooth_probe_ts == 0 || now - g_smooth_probe_ts >= ASB_SMOOTH_PROBE_S ||
        now < g_smooth_probe_ts || log_due) {
        g_smooth_log_due = 0;
        /* The package goes to a shell: only the characters a package name can have. */
        const char *pk = g_smooth_win_pkg;
        int ok = (pk[0] != 0);
        for (const char *c = pk; *c && ok; c++)
            ok = ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
                  (*c >= '0' && *c <= '9') || *c == '.' || *c == '_');
        g_smooth_probe_ts = now;
        if (!ok) return;
        g_smooth_probes++;
        asb_run_modscript("runtime/asb_gfx_probe.sh", pk);
    }
}

/* Screen-off deep-idle ceilings scaled by the records' setting (x0.75..x1.5 of what Smart and
 * the race-to-idle floor would write). Below x1 the writer's 40 % floor is lowered to 25 % for
 * exactly this write; the cooldown, a thermal cap and every other state are left alone, and the
 * records already return x1 while the CPU is kept awake (music). */
static void asb_rec_apply_offcaps(asb_profile_caps_t *caps, const asb_fsm_t *fsm, int screen_on) {
    g_writer_floor_pct = 0;
    if (!caps || !fsm || screen_on || g_rec_off_scale == 1000 || g_rec_off_scale <= 0) return;
    if (fsm->profile_idx != PROFILE_SMART || fsm->thermal_cap || g_fsm_cooldown_active) return;
    if (fsm->state != ASB_STATE_DEEP_IDLE) return;   /* busy screen-off (LIGHT_IDLE, music) untouched */
    for (int i = 0; i < 3; i++) {
        long hw = g_cpu_slot_hwmax[i];
        if (hw <= 0 || caps->cpu_max[i] <= 0) continue;
        long base = caps->cpu_max[i];
        if (base < hw * 40 / 100) base = hw * 40 / 100;
        long t = base * g_rec_off_scale / 1000;
        if (t < hw * 25 / 100) t = hw * 25 / 100;
        if (t > hw) t = hw;
        caps->cpu_max[i] = (int)t;
        if (caps->cpu_min[i] > caps->cpu_max[i]) caps->cpu_min[i] = caps->cpu_max[i];
    }
    if (g_rec_off_scale < 1000) g_writer_floor_pct = 25;
}

/*
 * Adaptive thermal budget. It is deliberately computed inside the native FSM
 * instead of a second shell loop: no extra wakeups, one owner for state, and
 * the policy sees the same headroom/thermal-cap data as the writer.
 *
 * Increasing restraint is immediate. Releasing restraint is dwell-limited so
 * noisy headroom samples do not oscillate caps and create sysfs churn.
 */
/* Last valid control temperature, kept so the thermal read can be skipped without
 * losing the distance-to-threshold check that decides whether skipping is safe. */
static int g_last_cpu_max_c = 0;
/* Last time the caps were re-applied, for the periodic drift re-assert above. */
static time_t g_last_caps_reassert = 0;
/* Running mean of modem throughput over the current learner session, KiB/s.
 * Fed to the bucket update so drain caused by the radio is not read as evidence that the
 * CPU ceiling is too high. Reset when a session is banked. */
static long g_ses_net_kib_sum = 0;
/* fix185: the battery's own temperature across the session and whether it ran right after
 * the charger - the learner's climate guard (asb_smart_session_input_t.climate). */
static int g_ses_bat_t0_dc = -10000, g_ses_bat_tmin_dc = 10000, g_ses_bat_tmax_dc = -10000;
static int g_ses_post_unplug = 0;
static int g_ses_climate_last = 0;
static long g_ses_net_samples = 0;

/* Wakeup ledger, by source.
 *
 * The overhead line counts timer wakeups in total - 674/h in a field capture, which is
 * the module's real cost now that physical writes turned out to be 21/h. Cutting that
 * total without knowing the split is how the last two "savings" went wrong: a flat 20%
 * trim that made the phone hotter, and a ceiling cut that inverted the ladder.
 *
 * Three sources, matching the three timerfds. An audit asked for owner/reason tagging;
 * this is the owner half, which is the part that can be acted on. */
typedef enum { ASB_WAKE_ACTIVE = 0, ASB_WAKE_IDLE, ASB_WAKE_HOURLY, ASB_WAKE_SRC_COUNT } asb_wake_src_t;
static unsigned long g_wake_by_src[ASB_WAKE_SRC_COUNT];
/* How each screen-on was noticed: directly from a display uevent, by the quick re-check
 * a display uevent armed, or only by a later timer tick. The last one is the slow path:
 * two field captures show 22 of 54 wakes found that way, each exactly one 45 s idle tick
 * after the previous one, with the governor still on deep-idle rails meanwhile. */
static unsigned long g_scr_on_by_uevent = 0, g_scr_on_by_recheck = 0, g_scr_on_by_tick = 0;
/* ... and by Android's own display state, through the waiter below (fix116). */
static unsigned long g_scr_on_by_display = 0;
/* The same for screen OFF (fix126). Every screen-off the waiter reported was logged as
 * "screen OFF (tick)", because the branch that applies it is the tick's - so a capture could
 * not tell an immediate screen-off from one found seconds later on the next active tick. */
static unsigned long g_scr_off_by_uevent = 0, g_scr_off_by_display = 0, g_scr_off_by_tick = 0;
static time_t        g_disp_prop_off_ts = 0;
static unsigned long g_disp_prop_events = 0;
static int           g_disp_prop_evfd = -1;
/* 0 = not started, 1 = started, 2 = waiting on the property, -1 = unavailable / gave up.
 * Written by the waiter thread too; a plain flag for the state file, nothing waits on it. */
static volatile int  g_disp_waiter_up = 0;

/* Display-state waiter (fix116).
 *
 * The display uevent misses wakes on some panels, and the fallbacks behind it (a wake key,
 * a re-check after a resume) miss the rest: OnePlus 15 captures show 6 of 31 and 14 of 35
 * wakes found only by the next idle tick - up to 45 s of unlock and launch animations on
 * deep-idle rails, the kind of lag users report as "the phone is slow right after unlock".
 * The OnePlus 13R: 19 of 30.
 *
 * Android publishes every display transition in debug.tracing.screen_state (fix115). One
 * thread blocks in __system_property_wait on that property - a futex: no polling, no timer,
 * nothing while the phone sleeps - and pokes an eventfd only when the display enters or
 * leaves ON. Doze <-> doze-suspend flips of an always-on display (one a minute) wake the
 * thread but never the main loop. Resolved with dlsym: the binary targets API 24 and the
 * calls are API 26; where either is missing nothing starts and the old paths work as before. */
#ifndef ASB_DISP_FIND_RETRY_S
#define ASB_DISP_FIND_RETRY_S 30
#endif
#if defined(__ANDROID__)
typedef _Bool (*asb_prop_wait_fn)(const prop_info *, uint32_t, uint32_t *, const struct timespec *);
typedef uint32_t (*asb_prop_serial_fn)(const prop_info *);

static void *asb_disp_waiter(void *arg) {
    (void)arg;
    asb_prop_wait_fn w = (asb_prop_wait_fn)dlsym(RTLD_DEFAULT, "__system_property_wait");
    asb_prop_serial_fn s = (asb_prop_serial_fn)dlsym(RTLD_DEFAULT, "__system_property_serial");
    if (!w || !s) { g_disp_waiter_up = -1; return NULL; }
    const prop_info *pi = NULL;
    /* The framework creates the property at the first display transition after boot, not
     * at boot (fix118): an OP15 kept the screen on for 12 minutes after a reboot and the
     * first version gave up after ten - seconds before the property appeared. Look every
     * 30 s for as long as it takes; a sleeping thread costs nothing. */
    while (!pi) {
        pi = __system_property_find("debug.tracing.screen_state");
        if (!pi) sleep(ASB_DISP_FIND_RETRY_S);
    }
    g_disp_waiter_up = 2;
    uint32_t serial = s(pi);
    int prev = asb_display_state_read();
    int idle_fail = 0;
    for (;;) {
        uint32_t ns = serial;
        if (!w(pi, serial, &ns, NULL)) {
            /* A NULL timeout never times out; a false return is unexpected - back off
             * rather than spin, and stop after a few in a row. */
            if (++idle_fail >= 5) { g_disp_waiter_up = -1; return NULL; }
            sleep(5);
            continue;
        }
        idle_fail = 0;
        serial = ns;
        int cur = asb_display_state_read();
        if (cur != prev && (cur == 2 || prev == 2)) {
            uint64_t one = 1;
            ssize_t _r = write(g_disp_prop_evfd, &one, sizeof(one));
            (void)_r;
        }
        prev = cur;
    }
    return NULL;
}
#endif

/* Start the waiter; returns the eventfd to watch, or -1. */
static int asb_disp_waiter_start(void) {
#if defined(__ANDROID__)
    if (!dlsym(RTLD_DEFAULT, "__system_property_wait")) {
        g_disp_waiter_up = -1;
        return -1;
    }
    int efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (efd < 0) { g_disp_waiter_up = -1; return -1; }
    g_disp_prop_evfd = efd;
    /* No signal may land on this thread: SIGTERM's handler only clears g_running, and the
     * main loop has to be the one interrupted out of epoll_wait. */
    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, &old);
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&at, 64 * 1024);
    pthread_t th;
    int rc = pthread_create(&th, &at, asb_disp_waiter, NULL);
    pthread_attr_destroy(&at);
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    if (rc != 0) { close(efd); g_disp_prop_evfd = -1; g_disp_waiter_up = -1; return -1; }
    g_disp_waiter_up = 1;
    return efd;
#else
    g_disp_waiter_up = -1;
    return -1;
#endif
}
static unsigned long g_scr_recheck_single = 0;
static unsigned long g_scr_resume_chains = 0;   /* re-check chains armed because a tick followed a resume */
static long          g_scr_tick_late_max_s = 0;
static time_t        g_scr_off_since = 0;
static const char *const g_wake_src_name[ASB_WAKE_SRC_COUNT] = { "active", "idle", "hourly" };

/* Uevent bookkeeping: the epoll wake counter says HOW OFTEN the uevent fd fired, but
 * not WHAT fired it. A one-hour field capture read 14258 event wakeups against 884
 * timer ticks - 40x the design rate - and nothing on disk could name the source.
 * Bucket every drained event by subsystem; the metrics line answers the next
 * capture's question without a repro. Display events are credited by the screen
 * parser's own verdict, so the bucket always agrees with the state machine. */
typedef enum {
    ASB_UEV_DISPLAY = 0, ASB_UEV_POWER, ASB_UEV_NET, ASB_UEV_SOUND,
    ASB_UEV_USB, ASB_UEV_THERMAL, ASB_UEV_WAKEUP, ASB_UEV_OTHER, ASB_UEV_COUNT
} asb_uev_src_t;
static unsigned long g_uev_by_src[ASB_UEV_COUNT];
static const char *const g_uev_src_name[ASB_UEV_COUNT] = {
    "display", "power_supply", "net", "sound", "usb", "thermal", "wakeup", "other"
};
static unsigned long g_uev_events_total = 0;

/* Uevent parking while the screen is on.
 *
 * The uevent socket exists to notice the screen coming ON while every timer is slow. With
 * the screen on, the active tick (2-6 s) reads the panel state anyway - and a field OP15
 * capture shows what listening costs then: 29298 display uevents in about seven hours
 * (brightness / refresh / DRM chatter, ~1.1 a second), each one an epoll wake plus a sysfs
 * read of the panel, against ~3800 active ticks. So while the screen is on the socket is
 * taken out of epoll; the tick that sees the screen go off puts it back, discarding what
 * queued meanwhile (nothing in it matters once the state is known). Screen-on detection is
 * unchanged, and screen-off is noticed by the next active tick instead of the event - a
 * few seconds, on rails that are already set for an awake screen. */
static int           g_uev_parked = 0;
static unsigned long g_uev_parks = 0, g_uev_unpark_dropped = 0;
/* Resumes Android reported as off/doze, so no wake re-check chain was armed (fix118). */
static unsigned long g_scr_resume_skipped = 0;

/* Wake keys as a screen-on hint.
 *
 * The display uevent is the fast path for noticing a wake, and on some panels it is not
 * sent for every wake: an OP15 day logged 10 wakes found by the uevent, 6-8 by the display
 * re-check and 5-14 only by the next idle tick - up to 45 s on deep-idle rails (GPU at 15%,
 * screen-off CPU caps) while the user was already unlocking. The CPH2769 and PLQ110 caught
 * every wake by uevent, so it is the panel, not the module.
 *
 * Most wakes start with a key: the power key, or the KEY_WAKEUP a double-tap or fingerprint
 * gesture reports. Those input devices are read-only listened to while the screen is off
 * (never grabbed - Android's InputReader still gets every event), and a press only arms the
 * same short re-check chain a display event arms; sysfs still decides whether the screen is
 * on. Devices with absolute axes (touchscreens) are skipped, so nothing floods epoll, and
 * the fds are parked together with the uevent socket while the screen is on. */
#define ASB_WAKE_KEY_MAX 6
static int           g_wake_key_fd[ASB_WAKE_KEY_MAX];
/* 1 = a touch panel admitted only for its gesture keys (fix101). */
static int           g_wake_key_touch[ASB_WAKE_KEY_MAX];
static int           g_wake_key_n = 0;
static unsigned long g_wake_key_hints = 0;

static int asb_bit_test(const unsigned long *bits, int bit) {
    return (bits[bit / (8 * (int)sizeof(long))] >> (bit % (8 * (int)sizeof(long)))) & 1UL;
}

static void wake_keys_open(int epfd) {
    for (int i = 0; i < 32 && g_wake_key_n < ASB_WAKE_KEY_MAX; i++) {
        char path[48];
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        unsigned long evb[(EV_MAX + 8 * sizeof(long)) / (8 * sizeof(long))];
        unsigned long keyb[(KEY_MAX + 8 * sizeof(long)) / (8 * sizeof(long))];
        memset(evb, 0, sizeof(evb)); memset(keyb, 0, sizeof(keyb));
        int caps = ioctl(fd, EVIOCGBIT(0, sizeof(evb)), evb) >= 0 &&
                   asb_bit_test(evb, EV_KEY) &&
                   ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keyb)), keyb) >= 0;
        int is_abs = caps && asb_bit_test(evb, EV_ABS);
        int ok = caps && !is_abs &&
                 (asb_bit_test(keyb, KEY_POWER) || asb_bit_test(keyb, KEY_WAKEUP));
        /* Touch panels too, but only for their screen-off gesture keys (fix101).
         *
         * OPlus panels report double-tap-to-wake and the other off-screen gestures as a key
         * on the touchscreen's OWN input device (KEY_F4 in the oplus touchpanel driver,
         * KEY_WAKEUP on some vendors) - and that device has absolute axes, so the first
         * version skipped it and a double-tap wake on OP12/OP13/OP15 had no hint at all.
         * Safe to listen: these fds are parked with the uevent socket while the screen is
         * on, and with the screen off the panel is in gesture mode and sends no motion. */
        int touch = 0;
        if (!ok && is_abs &&
            (asb_bit_test(keyb, KEY_WAKEUP) || asb_bit_test(keyb, KEY_F4))) {
            ok = 1; touch = 1;
        }
        if (!ok) { close(fd); continue; }
        struct epoll_event e;
        memset(&e, 0, sizeof(e));
        e.events = EPOLLIN;
        e.data.fd = fd;
        if (epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &e) != 0) { close(fd); continue; }
        g_wake_key_touch[g_wake_key_n] = touch;
        g_wake_key_fd[g_wake_key_n++] = fd;
    }
}

static int wake_key_is_fd(int fd) {
    for (int i = 0; i < g_wake_key_n; i++) if (g_wake_key_fd[i] == fd) return 1;
    return 0;
}

/* Drain one device; 1 if a wake key was pressed. */
static int wake_key_drain(int fd) {
    struct input_event iev[16];
    int pressed = 0, guard = 0, touch = 0;
    for (int i = 0; i < g_wake_key_n; i++)
        if (g_wake_key_fd[i] == fd) { touch = g_wake_key_touch[i]; break; }
    ssize_t r;
    while (guard++ < 8 && (r = read(fd, iev, sizeof(iev))) > 0) {
        int n = (int)(r / (ssize_t)sizeof(iev[0]));
        for (int k = 0; k < n; k++)
            if (iev[k].type == EV_KEY && iev[k].value == 1 &&
                (iev[k].code == KEY_POWER || iev[k].code == KEY_WAKEUP ||
                 (touch && iev[k].code == KEY_F4)))
                pressed = 1;
    }
    return pressed;
}

static void wake_keys_park(int epfd, int park) {
    for (int i = 0; i < g_wake_key_n; i++) {
        if (park) {
            /* fix220: park only the touch PANEL's gesture node with the screen on - it is
             * the one that would wake the loop on every frame of a scroll. A pure key
             * device (the power key) fires a handful of times a day, and its press with
             * the screen on is the lock animation the lift now covers - keep it live. */
            if (g_wake_key_touch[i])
                epoll_ctl(epfd, EPOLL_CTL_DEL, g_wake_key_fd[i], NULL);
        } else {
            (void)wake_key_drain(g_wake_key_fd[i]);   /* what queued while on is stale */
            struct epoll_event e;
            memset(&e, 0, sizeof(e));
            e.events = EPOLLIN;
            e.data.fd = g_wake_key_fd[i];
            epoll_ctl(epfd, EPOLL_CTL_ADD, g_wake_key_fd[i], &e);
        }
    }
}

/* Screen-on touch watch (fix117).
 *
 * The governor learnt about interaction only from load and GPU, sampled every 2 s - or 6 s
 * once the screen had been calm - so the start of a scroll after reading ran on light-idle
 * ceilings until two ticks agreed. The touchscreen says it directly. Its evdev node is
 * opened read-only (never grabbed; Android's InputReader gets every event as before) and
 * SAMPLED: in epoll only while the screen is on, and taken out again after each touch until
 * the next active tick, so a long scroll costs one extra wakeup per tick, not one per frame. */
static int           g_touch_fd = -1;
static int           g_touch_in_epoll = 0;
static int           g_touch_rearm = 0;      /* sampled out; put back on the next active tick */
static unsigned long g_touch_starts = 0;     /* touches that began after a quiet spell */

static int touch_open(void) {
    for (int i = 0; i < 32; i++) {
        char path[48];
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        unsigned long evb[(EV_MAX + 8 * sizeof(long)) / (8 * sizeof(long))];
        unsigned long absb[(ABS_MAX + 8 * sizeof(long)) / (8 * sizeof(long))];
        memset(evb, 0, sizeof(evb)); memset(absb, 0, sizeof(absb));
        int ok = ioctl(fd, EVIOCGBIT(0, sizeof(evb)), evb) >= 0 &&
                 asb_bit_test(evb, EV_ABS) &&
                 ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absb)), absb) >= 0 &&
                 asb_bit_test(absb, ABS_MT_POSITION_X) && asb_bit_test(absb, ABS_MT_TRACKING_ID);
        if (ok) {
            /* A direct-touch panel, not a touchpad or a pen digitiser's hover-only node. */
            unsigned long propb[(INPUT_PROP_MAX + 8 * sizeof(long)) / (8 * sizeof(long))];
            memset(propb, 0, sizeof(propb));
            if (ioctl(fd, EVIOCGPROP(sizeof(propb)), propb) >= 0 &&
                !asb_bit_test(propb, INPUT_PROP_DIRECT))
                ok = 0;
        }
        if (ok) { g_touch_fd = fd; return fd; }
        close(fd);
    }
    return -1;
}

/* Drain the node; 1 if anything said a finger is (or was just) on the panel. */
static int touch_drain(int fd) {
    struct input_event iev[32];
    int touched = 0, guard = 0;
    ssize_t r;
    while (guard++ < 16 && (r = read(fd, iev, sizeof(iev))) > 0) {
        int n = (int)(r / (ssize_t)sizeof(iev[0]));
        for (int k = 0; k < n; k++)
            if (iev[k].type == EV_ABS ||
                (iev[k].type == EV_KEY && iev[k].code == BTN_TOUCH && iev[k].value == 1))
                touched = 1;
    }
    return touched;
}

/* Returns 1 when turning the watch on found touches queued while it was out. */
static int touch_watch_set(int epfd, int on) {
    int queued = 0;
    if (g_touch_fd < 0) return 0;
    if (on && !g_touch_in_epoll) {
        queued = touch_drain(g_touch_fd);       /* touched while sampled out */
        struct epoll_event e;
        memset(&e, 0, sizeof(e));
        e.events = EPOLLIN;
        e.data.fd = g_touch_fd;
        if (epoll_ctl(epfd, EPOLL_CTL_ADD, g_touch_fd, &e) == 0) g_touch_in_epoll = 1;
    } else if (!on && g_touch_in_epoll) {
        epoll_ctl(epfd, EPOLL_CTL_DEL, g_touch_fd, NULL);
        g_touch_in_epoll = 0;
    }
    if (!on) g_touch_rearm = 0;
    return queued;
}

static void uev_park(int epfd, int uefd) {
    (void)touch_watch_set(epfd, 1);   /* screen on: watch touches (fix117) */
    /* The display-state waiter already keeps the uevent socket parked (fix118); the touch
     * panel's gesture node still has to come out of epoll - it would otherwise wake the
     * loop on every frame of a scroll. The power key stays (fix220: the lock press). */
    if (g_disp_waiter_up == 2 && g_uev_parked) { wake_keys_park(epfd, 1); return; }
    if (uefd < 0 || g_uev_parked) return;
    if (epoll_ctl(epfd, EPOLL_CTL_DEL, uefd, NULL) == 0) {
        g_uev_parked = 1;
        g_uev_parks++;
        wake_keys_park(epfd, 1);
    }
}

static void uev_unpark(int epfd, int uefd) {
    (void)touch_watch_set(epfd, 0);   /* screen off: the panel is in gesture mode */
    /* Android's display state is being watched (fix118): it reports every wake, so the
     * uevent socket stays parked with the screen off too. That socket woke the governor for
     * every kernel uevent - an OP15 night delivered 250-500 an hour (AOD pulses, battery,
     * thermal, "other"), each discarded. The wake keys keep listening as the backstop. */
    if (g_disp_waiter_up == 2 && g_uev_parked) { wake_keys_park(epfd, 0); return; }
    if (uefd < 0 || !g_uev_parked) return;
    char _ub[4096];
    int _k = 0, _guard = 0;
    while (_k < 8192 && _guard < 8) {
        ssize_t _r = recv(uefd, _ub, sizeof(_ub), MSG_DONTWAIT);
        if (_r > 0) { _k++; continue; }
        /* A buffer that overflowed while parked reports ENOBUFS once; the queue behind it
         * is still readable. */
        if (_r < 0 && errno == ENOBUFS) { _guard++; continue; }
        break;
    }
    g_uev_unpark_dropped += (unsigned long)_k;
    struct epoll_event _ev;
    memset(&_ev, 0, sizeof(_ev));
    _ev.events = EPOLLIN;
    _ev.data.fd = uefd;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, uefd, &_ev) == 0) {
        g_uev_parked = 0;
        wake_keys_park(epfd, 0);
    }
}
/* Last banked session as it was handed to the learner, for diagnostics. */
static int  g_ses_last_temp = 0;
static int  g_ses_last_dur  = 0;
static char g_ses_last_reason[24] = "none";
/* Current screen-on tick interval, so the timer is only re-armed when it actually
 * changes rather than on every pass. */
static int g_active_interval = TIMER_ACTIVE_S;
static int g_active_by_touch = 0;   /* the current 2 s cadence was set by a touch (fix117) */

static int g_budget_trim_pct = 0;
/* Whether the surface-comfort trim is currently engaged, for hysteresis.
 *
 * The threshold was a bare >= 43 with no exit band, and a field capture shows the cost:
 * mean surface temperature across 122 phases was exactly 43 C, so a 20% ceiling trim was
 * active essentially all the time - on a phone whose owner reported it running hotter and
 * draining faster WITH the module than without.
 *
 * That is race-to-idle arriving from the other direction. Trimming the ceiling makes every
 * task take longer, and a longer task keeps the cores, the panel and the radio awake for
 * the whole of it. Past a point the trim costs more heat than it saves.
 *
 * 43 C is also not a comfort problem. A phone in the hand sits there under any real use;
 * the temperature people actually describe as too hot to hold is closer to 46-48. Entering
 * at 46 and leaving at 42 keeps the guard for the case it was written for and stops it
 * living permanently in ordinary use. */
static int g_budget_surface_engaged = 0;
static time_t g_budget_trim_changed_at = 0;
static char g_budget_reason[32] = "disabled";
static int g_budget_base_trim_pct = 0;
static int g_budget_stage = 0;
static int g_budget_envelope_bonus_pct = 0;

/*
 * Device-specific active-use policy is a derived manifest, not an alternative
 * thermal controller. The shell writes it from observed platform/topology/GPU
 * facts before this daemon starts; the values are percentage/uclamp deltas only.
 * A missing, malformed or unrecognised manifest is a deliberate no-op.
 */
typedef struct {
    int active;
    int light_bonus_pct;
    int moderate_bonus_pct;
    int severe_bonus_pct;
    int gpu_idle_bonus_pct;
    int bg_uclamp_moderate_delta;
    int bg_uclamp_severe_delta;
    char tier[16];
    char reason[48];
} asb_active_efficiency_t;

static asb_active_efficiency_t g_active_efficiency;

static void asb_active_efficiency_reset(const char *reason) {
    memset(&g_active_efficiency, 0, sizeof(g_active_efficiency));
    snprintf(g_active_efficiency.tier, sizeof(g_active_efficiency.tier), "generic");
    snprintf(g_active_efficiency.reason, sizeof(g_active_efficiency.reason), "%s",
             reason ? reason : "inactive");
}

static int asb_active_efficiency_int(const char *text, int low, int high, int *out) {
    char *end = NULL;
    long value;
    if (!text || !*text || !out) return -1;
    errno = 0;
    value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < low || value > high) return -1;
    *out = (int)value;
    return 0;
}

static void asb_active_efficiency_load(void) {
    FILE *f;
    char line[128];
    int schema = 0, active = 0, seen = 0, malformed = 0;

    asb_active_efficiency_reset("manifest_missing");
    f = fopen(ACTIVE_EFFICIENCY_FILE, "r");
    if (!f) return;

    while (fgets(line, sizeof(line), f)) {
        char *key = line;
        char *value = strchr(line, '=');
        size_t len;
        if (!value || key[0] == '#') continue;
        *value++ = '\0';
        len = strcspn(value, "\r\n");
        value[len] = '\0';
        if (!strcmp(key, "schema")) {
            malformed |= asb_active_efficiency_int(value, 1, 1, &schema) != 0;
        } else if (!strcmp(key, "status")) {
            active = !strcmp(value, "active");
        } else if (!strcmp(key, "tier")) {
            snprintf(g_active_efficiency.tier, sizeof(g_active_efficiency.tier), "%s", value);
            seen |= 1;
        } else if (!strcmp(key, "reason")) {
            snprintf(g_active_efficiency.reason, sizeof(g_active_efficiency.reason), "%s", value);
        } else if (!strcmp(key, "budget_light_bonus_pct")) {
            malformed |= asb_active_efficiency_int(value, 0, 8, &g_active_efficiency.light_bonus_pct) != 0;
            seen |= 2;
        } else if (!strcmp(key, "budget_moderate_bonus_pct")) {
            malformed |= asb_active_efficiency_int(value, 0, 8, &g_active_efficiency.moderate_bonus_pct) != 0;
            seen |= 4;
        } else if (!strcmp(key, "budget_severe_bonus_pct")) {
            malformed |= asb_active_efficiency_int(value, 0, 8, &g_active_efficiency.severe_bonus_pct) != 0;
            seen |= 8;
        } else if (!strcmp(key, "gpu_idle_trim_bonus_pct")) {
            malformed |= asb_active_efficiency_int(value, 0, 8, &g_active_efficiency.gpu_idle_bonus_pct) != 0;
            seen |= 16;
        } else if (!strcmp(key, "bg_uclamp_moderate_delta")) {
            malformed |= asb_active_efficiency_int(value, 0, 256,
                                                   &g_active_efficiency.bg_uclamp_moderate_delta) != 0;
            seen |= 32;
        } else if (!strcmp(key, "bg_uclamp_severe_delta")) {
            malformed |= asb_active_efficiency_int(value, 0, 320,
                                                   &g_active_efficiency.bg_uclamp_severe_delta) != 0;
            seen |= 64;
        }
    }
    fclose(f);

    if (schema != 1 || !active || malformed || seen != 127 ||
        (strcmp(g_active_efficiency.tier, "sm8750") &&
         strcmp(g_active_efficiency.tier, "sm8850") &&
         strcmp(g_active_efficiency.tier, "sm8650") &&
         strcmp(g_active_efficiency.tier, "sm8550") &&
         strcmp(g_active_efficiency.tier, "capability"))) {
        asb_active_efficiency_reset(malformed ? "manifest_invalid" : "manifest_inactive");
        return;
    }
    if (g_active_efficiency.moderate_bonus_pct < g_active_efficiency.light_bonus_pct ||
        g_active_efficiency.severe_bonus_pct < g_active_efficiency.moderate_bonus_pct ||
        g_active_efficiency.bg_uclamp_severe_delta < g_active_efficiency.bg_uclamp_moderate_delta) {
        asb_active_efficiency_reset("manifest_nonmonotonic");
        return;
    }
    g_active_efficiency.active = 1;
    asb_log("active_efficiency: tier=%s reason=%s bonus=%d/%d/%d gpu=%d bg=%d/%d",
            g_active_efficiency.tier, g_active_efficiency.reason,
            g_active_efficiency.light_bonus_pct, g_active_efficiency.moderate_bonus_pct,
            g_active_efficiency.severe_bonus_pct, g_active_efficiency.gpu_idle_bonus_pct,
            g_active_efficiency.bg_uclamp_moderate_delta,
            g_active_efficiency.bg_uclamp_severe_delta);
}

static int asb_active_efficiency_bonus(int stage) {
    if (!g_active_efficiency.active) return 0;
    if (stage >= 3) return g_active_efficiency.severe_bonus_pct;
    if (stage == 2) return g_active_efficiency.moderate_bonus_pct;
    if (stage == 1) return g_active_efficiency.light_bonus_pct;
    return 0;
}
/* Self-overhead counters: event-driven native loop only, no extra sampler. */
static unsigned long g_governor_event_wakeups = 0;
static unsigned long g_governor_timer_wakeups = 0;

static void asb_budget_raise(int *candidate, const char **reason, int trim, const char *why) {
    if (trim > *candidate) {
        *candidate = trim;
        *reason = why;
    }
}

/* Battery current on the scale the thresholds were tuned on.
 *
 * Every mA gate in the thermal budget (250 / 350 / 450 / 600 / 1800) was tuned on OnePlus 15
 * readings, and the OP15 gauge integrates to x0.38 of the real drain (measured above over
 * 40+ screen-on windows; a PLQ110 reads the same). A CPH2769 gauge reads x0.88 - the same
 * workload shows 2.3 times the milliamps - so the comfort trims fired on ordinary use: 27
 * "screenon_comfort_smart_high_cur" trims in one evening against 3 on the OP15.
 *
 * Once this phone's own ratio is on record (5+ windows) the reading is converted to the
 * reference scale; before that, and for nonsense ratios, the raw value is used unchanged. */
#define ASB_CURSCALE_REF_X100 38
static int asb_ma_ref(int raw_ma) {
    if (raw_ma <= 0 || g_curscale_n < 5 || g_curscale_x100 < 15 || g_curscale_x100 > 400)
        return raw_ma;
    return (int)((long)raw_ma * ASB_CURSCALE_REF_X100 / g_curscale_x100);
}

/* A fast trend on a cool body is a burst, not heat (fix160).
 *
 * The trend sums the last rises of the hottest CPU sensor, and that hotspot follows load, not
 * the phone: an app launch, a camera start or a feed full of video lifts it past the warm mark
 * in a couple of ticks. The owner's OP15 day (31599) has every trend trim of the captured log
 * tails at a skin of 28-31 C with the HAL headroom at 83-100% - stage 3, CPU and GPU ceilings
 * cut by 34% for the next dwell window, exactly while the burst wanted them - and "cool" 30-60 s
 * later. The trend exists to get ahead of heat the user will feel, so it now also needs the
 * skin in the same pre-lean band the light headroom stage uses: within 8 C of thermal_skin_c.
 * A die that really runs away is still caught by SUSTAINED, the hot guard, the junction guard
 * and the headroom stages, none of which read this. No usable skin keeps the old behaviour. */
static unsigned long g_trend_held_cool = 0;
static int asb_trend_body_cool(int temp_valid, int skin_c, int skin_limit_c) {
    if (!temp_valid || skin_c <= 20 || skin_c >= 70 || skin_limit_c <= 0) return 0;
    return skin_c < skin_limit_c - 8;
}

/* Discharge current for the comfort trims, smoothed - and a band to leave them (fix121).
 *
 * The comfort gates read one current_now sample, and on these phones that is the
 * instantaneous draw: a frame, a radio burst, a pause. OP15 24817, twelve minutes of a warm
 * feed: the light trim went on at 391 mA, off at 258, on at 437, off at 328, on at 384 eight
 * seconds later - thirteen budget changes in 21 minutes, each one a ceiling rewrite, while
 * nothing about the workload changed. "Draws a lot" is a property of the last half minute,
 * not of the last sample.
 *
 * So the gates see a running mean over about four ticks (8-24 s on the screen-on cadence),
 * restarted on the charger and with the screen off, updated once per metrics sample however
 * many callers ask. And a comfort trim that is in force stays while the draw is above 80% of
 * its entry gate and the die within 2 C of its entry temperature, the same entry/exit band the
 * surface comfort has had since it was written. Entry thresholds are unchanged. */
static int  g_comfort_ma_ema = 0;
static long g_comfort_ma_s = -1, g_comfort_ma_ns = -1;
static int  g_budget_comfort_engaged = 0;
static int asb_comfort_ma(const asb_metrics_t *m) {
    if (m->bat.charging || !m->misc.screen_on || m->bat.current_ma <= 0) {
        g_comfort_ma_ema = 0;
        return m->bat.current_ma;
    }
    if ((long)m->ts.tv_sec != g_comfort_ma_s || (long)m->ts.tv_nsec != g_comfort_ma_ns) {
        /* A mean older than half a minute (SUSTAINED or a thermal cap skipped the budget)
         * describes a different workload: start again from this sample. */
        int _stale = (g_comfort_ma_s < 0 || (long)m->ts.tv_sec - g_comfort_ma_s > 30);
        g_comfort_ma_s = (long)m->ts.tv_sec;
        g_comfort_ma_ns = (long)m->ts.tv_nsec;
        if (g_comfort_ma_ema <= 0 || _stale) g_comfort_ma_ema = m->bat.current_ma;
        else g_comfort_ma_ema += (m->bat.current_ma - g_comfort_ma_ema) / 4;
    }
    return g_comfort_ma_ema;
}

/* A warm die, not one hot sample, for the screen-on comfort trims (fix169).
 *
 * The comfort gates read the die as it is at this tick, and the die is the fastest sensor on
 * the phone. OP15 capture 8689: prime_escape lifted the prime at 41 C, the burst ended a few
 * seconds later at 48-50 C, and on that same tick screenon_comfort_smart_medium trimmed the
 * ceilings by 9% - with the shell at 28-31 C, and the die back at 39 C on the next tick. The
 * dwell then held the trim for 30 s, and the next pinned burst started the round again: four
 * lift / trim / release rounds in eight minutes, ASB answering the heat of its own lift.
 *
 * Entry now needs the gate to hold for ASB_COMFORT_ENTER_HOLD_S: two readings at least that
 * far apart, all of them warm. A burst peak is one reading; a feed or a page that keeps the die
 * warm passes on the next tick. A trim already in force keeps its exit band and is not
 * delayed, and every other stage - headroom, skin, trend, surface - reads as before. */
#define ASB_COMFORT_ENTER_HOLD_S 10
#define ASB_COMFORT_HOLD_GAP_S   30
typedef struct { time_t since, last; } asb_comfort_hold_t;
static asb_comfort_hold_t g_comfort_med_hold = { 0, 0 };
static asb_comfort_hold_t g_comfort_hc_hold = { 0, 0 };
static unsigned long g_comfort_burst_skips = 0;
static int asb_comfort_held(int cond, int engaged, time_t now, asb_comfort_hold_t *h) {
    if (!cond) {
        if (h->since > 0 && !engaged) g_comfort_burst_skips++;
        h->since = 0;
        h->last = 0;
        return 0;
    }
    /* A reading more than half a minute after the last one (SUSTAINED or a thermal cap
     * skipped the budget) starts the hold again, as the comfort current does. */
    if (h->since <= 0 || now < h->since || now - h->last > ASB_COMFORT_HOLD_GAP_S) h->since = now;
    h->last = now;
    if (engaged) return 1;
    return (now - h->since) >= ASB_COMFORT_ENTER_HOLD_S;
}

static int asb_adaptive_budget_trim_pct(const asb_metrics_t *m, const asb_fsm_t *fsm) {
    int candidate = 0;
    int base_candidate = 0;
    int stage = 0;
    int envelope_bonus = 0;
    const char *reason = "cool";
    if (g_asb_cfg.thermal_budget_enable && !fsm->thermal_cap &&
        fsm->state != ASB_STATE_SUSTAINED) {
        if (m->therm.headroom_valid) {
            int hr = m->therm.headroom_pct;
            /* Hysteresis on the headroom stages.
             *
             * Three bare thresholds with no exit band, and headroom wanders by a couple of
             * points from tick to tick. A capture shows the result: 193 ceiling changes
             * across 613 samples - almost every third tick - with a mean temperature delta
             * of 2.5 C behind them, cycling through six different p0 values while the die
             * sat between 47 and 49 C.
             *
             * That is not thermal management, it is chatter. Every change is a write, the
             * governor re-plans around it, and the cluster ramps to a new ceiling for a few
             * seconds before the next tick moves it again - which costs more energy than
             * the trim saves.
             *
             * Widening by 4 points on the way OUT only: entering a stage is as prompt as
             * before, leaving it requires the headroom to have genuinely recovered rather
             * than to have jittered across the line.
             */
            /* Light trim needs a sustained deficit, not one sample.
             *
             * headroom_pct is a vendor estimate that moves on its own, and the light band is the
             * one it crosses most often. Trimming 8% on a single dip is the pattern this project
             * keeps finding: an action taken on noise, which then has to be undone, costing a ramp
             * in each direction and buying nothing.
             *
             * Two consecutive ticks below the light threshold before it applies. Moderate and
             * severe are deliberately NOT gated - those bands mean the phone is actually in
             * trouble, and waiting a tick there would trade safety for tidiness. */
            static int _lt_streak = 0;
            if (hr <= g_asb_cfg.thermal_budget_light_headroom_pct) {
                if (_lt_streak < 100) _lt_streak++;
            } else {
                _lt_streak = 0;
            }
            /* Enter fast, leave slowly - and leave over a band the sensor cannot jump.
             *
             * The headroom figure comes from the thermal HAL's forecast and moves in coarse
             * steps; a 4-point exit band is narrower than one of those steps, so a reading
             * sitting near a threshold toggled the stage on consecutive evaluations. Two
             * audits of the same capture independently flagged the result - trim 0 -> 9
             * -> 0 and 9 -> 20 -> 9 at 35 C skin, each toggle a round of cap writes - and
             * both asked for the same shape: quick entry, stable release.
             *
             * Entry thresholds are untouched, so protection engages exactly as before. Only
             * the release needs the reading to clear the line by 8 points instead of 4. */
            int hyst = (g_budget_trim_pct > 0) ? 8 : 0;
            /* The LIGHT stage needs the phone to be at least warm.
             *
             * The HAL headroom is a forecast, and this device's HAL forecasts early: it
             * reads 83-100 when idle and drops to 55-65 under ordinary use with the skin at
             * 33-36 C. The light threshold is 70, so the stage was on in every snapshot of
             * a capture - and the new cap telemetry showed exactly what it cost: the prime
             * ceiling cut from 1.61 to 1.47 GHz, reason headroom_light, on a cool phone.
             * That is a permanent 9% performance trim with no heat behind it.
             *
             * Moderate and severe stay headroom-only: when the HAL forecasts real throttling
             * the module should get ahead of it. The light stage is a gentle early nudge, and
             * a nudge is only worth paying for when the surface is getting warm - eight
             * degrees under the skin limit, the same pre-lean band the thermal veto uses. No
             * usable skin reading falls back to the die against the sustained-exit mark; no
             * valid reading at all keeps the old behaviour, as the trend gate does. */
            int _light_warm;
            {
                int _sk = m->therm.skin_temp_c;
                if (_sk > 20 && _sk < 70)
                    _light_warm = (_sk >= g_asb_cfg.thermal_skin_c - 8);
                else if (m->therm.temp_valid)
                    _light_warm = (m->therm.cpu_max_c >=
                        asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm->profile_idx));
                else
                    _light_warm = 1;
            }
            if (hr <= g_asb_cfg.thermal_budget_severe_headroom_pct + hyst)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_severe_trim_pct, "headroom_severe");
            else if (hr <= g_asb_cfg.thermal_budget_moderate_headroom_pct + hyst)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_moderate_trim_pct, "headroom_moderate");
            else if (hr <= g_asb_cfg.thermal_budget_light_headroom_pct + hyst &&
                     _lt_streak >= 2 && _light_warm)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_light_trim_pct, "headroom_light");
        }
        /* Skin is the user-facing safety signal. A fast trend anticipates heat
         * before the emergency CPU junction guard is crossed. */
        if (m->therm.temp_valid && m->therm.skin_temp_c > 0) {
            if (m->therm.skin_temp_c >= g_asb_cfg.thermal_skin_c + 3)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_severe_trim_pct, "skin_severe");
            else if (m->therm.skin_temp_c >= g_asb_cfg.thermal_skin_c)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_moderate_trim_pct, "skin_moderate");
        }
        /* A trend means something only when the CPU is already warm.
         *
         * thermal_trend is the sum of the last three tick-to-tick rises of the hottest CPU
         * sensor, and on screen the ticks are 2-6 s apart. Launching an app lifts that hotspot
         * from about 40 C to the low 50s in a couple of ticks and lets it fall just as fast,
         * so the trend read 12-13 and the severe trim cut CPU and GPU ceilings by a third for
         * the next dwell window - in the middle of the burst, which is exactly when the speed
         * was wanted. A capture shows two such cuts at 31-34 C skin with the prime near 47 C,
         * back to 39 C a minute later. Below the temperature at which SUSTAINED itself lets go
         * there is no thermal case to anticipate; skin, the throttling flag and the
         * own-temperature path still guard real heat, and they do not depend on this gate. */
        /* No reading is not the same as a cool phone.
         *
         * Gating the trend on temperature is right - a rising trend at 32 C is noise, and
         * trimming on it costs performance for nothing. But with temp_valid at 0 the gate
         * closes permanently, and the trend is precisely the signal that still works when
         * the sensor does not: a capture on this device showed the thermal headroom API
         * stuck at 100 for 13 of 145 samples, and other devices report no usable CPU
         * sensor at all. Those are the phones that most need a fallback, and this would
         * have left them with none.
         *
         * So: when the reading is trustworthy, require it to be warm; when there is no
         * reading, fall back to the old trend-only behaviour. */
        /* Smart: "warm" is this phone's own warm, when it has been measured.
         *
         * The fixed mark is the sustained-exit temperature (48 C in Smart). A CPH2769 runs
         * its ordinary day at 45-53 C - that is what Smart learned as its normal band - so a
         * launch nudging the die from 46 to 49 read as a rising trend on a phone doing
         * nothing unusual: a diag shows the prime cut from 1248 to 1018 MHz in HEAVY at
         * 49 C, reason thermal_trend_rising. The learned warm mark (bucket peak median +4 C)
         * is the same line the Smart lean already uses for "this phone is running hot", so
         * the trend now starts counting from there. Unlearned devices keep the fixed mark,
         * since the fallback warm mark (42 C) is below it. */
        int _trend_mark = asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm->profile_idx);
        if (fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
            g_smart_rt.therm_warm_x10 / 10 > _trend_mark)
            _trend_mark = g_smart_rt.therm_warm_x10 / 10;
        int _trend_warm = (!m->therm.temp_valid) || m->therm.cpu_max_c >= _trend_mark;
        if (_trend_warm && fsm->thermal_trend >= 6 &&
            asb_trend_body_cool(m->therm.temp_valid, m->therm.skin_temp_c, g_asb_cfg.thermal_skin_c)) {
            _trend_warm = 0;
            g_trend_held_cool++;
        }
        if (_trend_warm && fsm->thermal_trend >= 10)
            asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_severe_trim_pct, "thermal_trend_fast");
        else if (_trend_warm && fsm->thermal_trend >= 6)
            asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_moderate_trim_pct, "thermal_trend_rising");
        /* Battery current is a tie-breaker only; it never escalates beyond a
         * light trim and is ignored while charging because its semantics vary. */
        if (!m->bat.charging && asb_ma_ref(m->bat.current_ma) >= 1800)
            asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_light_trim_pct, "battery_current");
        /* Screen-on comfort is intentionally a tie-breaker, not a generic cap.
         *
         * Battery keeps its proven 450 mA evidence gate. Debug 6 telemetry adds a second
         * safe case: ordinary screen-on feed/browser use averaged about 430 mA with a warm
         * CPU, while its foreground load was not gaming or camera work. Waiting for the old
         * Battery-bias opt-in misses that common Smart profile use case.
         *
         * Admit only a freshly identified light/medium Smart foreground app at a modest
         * 350 mA. It still reuses the existing light trim (not a new cap ladder), requires
         * valid thermal evidence, and excludes games, camera, charging and screen-off work.
         * Unknown/stale package context fails closed; the explicit battery-bias setting retains
         * its earlier 250 mA path. */
        int smart_screenon_comfort =
            fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled && g_pkg_detect_ok &&
            (g_smart_rt.app_hint <= ASB_APP_MEDIUM || g_asb_cfg.smart_battery_bias >= 400);
        int comfort_current_ma = g_asb_cfg.smart_battery_bias >= 400 ? 250 :
                                 (smart_screenon_comfort ? 350 : 450);
        int _cma = asb_comfort_ma(m);
        int _cin = g_budget_comfort_engaged;
        time_t _cnow = time(NULL);
        if (asb_comfort_held(!m->bat.charging && m->misc.screen_on && !m->misc.camera_active &&
            fsm->state != ASB_STATE_GAMING && m->therm.temp_valid &&
            m->therm.cpu_max_c >= g_asb_cfg.bat_comfort_temp - (_cin ? 2 : 0) &&
            asb_ma_ref(_cma) >= (_cin ? comfort_current_ma * 4 / 5 : comfort_current_ma) &&
            (fsm->profile_idx == PROFILE_BATTERY || smart_screenon_comfort),
            _cin, _cnow, &g_comfort_med_hold))
            asb_budget_raise(&candidate, &reason,
                             g_asb_cfg.thermal_budget_light_trim_pct,
                             smart_screenon_comfort ? "screenon_comfort_smart_medium" : "screenon_comfort");
        /* The multi-user V64 captures repeat a second safe Smart-only foreground pattern:
         * a fresh light/medium app at a high sampled discharge current can warm the CPU/body
         * before the ordinary 48C comfort point.  Do not turn that into a universal current
         * cap: require valid low-GPU data, current >=600mA, a recognised non-heavy app,
         * screen-on discharge and a small 42C CPU floor. Games, camera, charging, screen-off,
         * SUSTAINED and unknown/stale app context all fail closed. It reuses the same light
         * trim rather than changing the profile's frequency tables or radio policy. */
        int smart_high_current_comfort =
            fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled && g_pkg_detect_ok &&
            g_smart_rt.app_hint <= ASB_APP_MEDIUM && m->gpu.load_valid &&
            m->gpu.load_pct < g_asb_cfg.heavy_gpu_enter &&
            fsm->state != ASB_STATE_GAMING && fsm->state != ASB_STATE_SUSTAINED;
        if (asb_comfort_held(smart_high_current_comfort && !m->bat.charging && m->misc.screen_on &&
            !m->misc.camera_active && m->therm.temp_valid &&
            m->therm.cpu_max_c >= (_cin ? 40 : 42) && asb_ma_ref(_cma) >= (_cin ? 480 : 600),
            _cin, _cnow, &g_comfort_hc_hold))
            asb_budget_raise(&candidate, &reason,
                             g_asb_cfg.thermal_budget_light_trim_pct,
                             "screenon_comfort_smart_high_current");
        /* Some vendor `skin` zones are internal/remote and remain 35-40C while the
         * body-adjacent hotspot that the user actually feels reaches 43-45C.  The
         * new capture on canoe showed exactly that: CPU/skin remained below the
         * configured skin threshold, so Smart only kept the headroom light trim
         * despite sustained screen-on LTE/media drain and a 44C surface hotspot.
         *
         * Treat that verified surface signal as an earlier, bounded Smart-only
         * comfort trigger.  It reuses the existing moderate budget ladder rather
         * than introducing a per-device frequency table.  Battery, gaming, camera,
         * charging and screen-off paths remain excluded; vendor thermal is still
         * authoritative above it. */
        /* SUSTAINED is normally excluded from the generic budget ladder to protect a
         * genuinely heavy/video workload. The capture here exposes a narrow exception:
         * a high-bias Smart session can be SUSTAINED while the CPU/body hotspot is warm,
         * yet the foreground classification is only idle/light/medium and GPU remains below
         * the HEAVY gate. Waiting for SUSTAINED to exit leaves the user under a vendor cap
         * without ASB first lowering its own requested rail. Keep this fail-closed: no
         * package evidence, heavy/gaming hint, invalid/high GPU, camera, charging or screen
         * off all retain the existing no-trim SUSTAINED behavior. */
        int surface_comfort_sustained =
            fsm->state == ASB_STATE_SUSTAINED && g_pkg_detect_ok &&
            g_smart_rt.app_hint <= ASB_APP_MEDIUM && m->gpu.load_valid &&
            m->gpu.load_pct < g_asb_cfg.heavy_gpu_enter;
        if (smart_screenon_comfort && !m->bat.charging && m->misc.screen_on &&
            !m->misc.camera_active && fsm->state != ASB_STATE_GAMING &&
            m->therm.temp_valid &&
            m->therm.surface_hotspot_c >= (g_budget_surface_engaged ? 42 : 46) &&
            asb_ma_ref(_cma) >= 250 &&
            (fsm->state != ASB_STATE_SUSTAINED || surface_comfort_sustained))
            asb_budget_raise(&candidate, &reason,
                             g_asb_cfg.thermal_budget_moderate_trim_pct,
                             surface_comfort_sustained ? "surface_comfort_smart_sustained"
                                                       : "surface_comfort_smart");
        /* Camera deadlines are a QoS lease: do not introduce a light-only trim
         * during capture. Real thermal stress still wins at moderate/severe. */
        if (m->misc.camera_active && candidate <= g_asb_cfg.thermal_budget_light_trim_pct) {
            candidate = 0;
            reason = "camera_qos";
        }
    } else if (fsm->thermal_cap || fsm->state == ASB_STATE_SUSTAINED) {
        reason = "platform_thermal";
    }
    /*
     * Universal active thermal recovery for recognised media/feed use. Sustained state keeps
     * its normal conservative rail, but a warm LTE/video/feed session can keep generating heat
     * after the interactive burst ends. Reduce that residual generation with the existing light
     * budget only when a fresh foreground package is positively known as media. This is not a
     * broad SUSTAINED cap: games and unknown/heavy apps fail closed, as do camera, charging,
     * screen-off and any missing/stale package signal. It therefore works across SoCs through
     * capabilities and QoS evidence rather than device names or fixed frequencies.
     */
    if (g_asb_cfg.thermal_budget_enable && !fsm->thermal_cap &&
        fsm->state == ASB_STATE_SUSTAINED &&
        fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
        m->misc.screen_on && !m->misc.camera_active && !m->bat.charging &&
        m->therm.temp_valid && m->therm.cpu_max_c >= g_asb_cfg.bat_comfort_temp &&
        asb_ma_ref(m->bat.current_ma) >= 450 &&
        g_pkg_detect_ok && g_smart_media_pkg_known &&
        g_smart_rt.app_hint < ASB_APP_GAMING) {
        asb_budget_raise(&candidate, &reason,
                         g_asb_cfg.thermal_budget_light_trim_pct, "media_recovery");
    }
    base_candidate = candidate;
    if (candidate > 0) {
        if (candidate >= g_asb_cfg.thermal_budget_severe_trim_pct) stage = 3;
        else if (candidate >= g_asb_cfg.thermal_budget_moderate_trim_pct) stage = 2;
        else stage = 1;
        envelope_bonus = asb_active_efficiency_bonus(stage);
        candidate += envelope_bonus;
        if (candidate > 60) candidate = 60;
    }
    time_t now = time(NULL);
    if (candidate > g_budget_trim_pct ||
        now - g_budget_trim_changed_at >= g_asb_cfg.thermal_budget_dwell_s) {
        if (candidate != g_budget_trim_pct || strcmp(reason, g_budget_reason) != 0) {
            g_budget_trim_pct = candidate;
            /* Track engagement for the surface hysteresis: the band only means anything
             * if the exit threshold is checked against a state we actually recorded. */
            g_budget_surface_engaged =
                (reason && strncmp(reason, "surface_comfort", 15) == 0) ? 1 : 0;
            g_budget_comfort_engaged =
                (reason && strncmp(reason, "screenon_comfort", 16) == 0) ? 1 : 0;
            g_budget_trim_changed_at = now;
            g_budget_base_trim_pct = base_candidate;
            g_budget_stage = stage;
            g_budget_envelope_bonus_pct = envelope_bonus;
            snprintf(g_budget_reason, sizeof(g_budget_reason), "%s", reason);
            asb_log("thermal_budget: trim=%d base=%d bonus=%d stage=%d reason=%s headroom=%d skin=%d trend=%d ma=%d camera=%d state=%s",
                    g_budget_trim_pct, g_budget_base_trim_pct, g_budget_envelope_bonus_pct,
                    g_budget_stage, g_budget_reason, m->therm.headroom_pct,
                    m->therm.skin_temp_c, fsm->thermal_trend, m->bat.current_ma,
                    m->misc.camera_active, asb_state_names[fsm->state]);
        }
    }
    return g_budget_trim_pct;
}

static void asb_active_efficiency_apply_caps(asb_profile_caps_t *caps,
                                              const asb_metrics_t *m,
                                              const asb_fsm_t *fsm) {
    int delta;
    int media_recovery;
    if (!g_asb_cfg.thermal_budget_enable || !g_active_efficiency.active ||
        g_budget_stage <= 0 || fsm->thermal_cap) return;

    /* A warm recognised media/feed SUSTAINED session may shrink background cgroups only.
     * Re-check every QoS gate here instead of trusting the dwell-held budget reason: an app
     * switch to a game, camera launch, charging event or stale package evidence immediately
     * restores the normal policy. Foreground/top-app caps are deliberately untouched. */
    media_recovery = !strcmp(g_budget_reason, "media_recovery") &&
                     fsm->state == ASB_STATE_SUSTAINED &&
                     fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
                     m && m->misc.screen_on && !m->misc.camera_active && !m->bat.charging &&
                     m->therm.temp_valid && m->therm.cpu_max_c >= g_asb_cfg.bat_comfort_temp &&
                     asb_ma_ref(m->bat.current_ma) >= 450 && g_pkg_detect_ok &&
                     g_smart_media_pkg_known && g_smart_rt.app_hint < ASB_APP_GAMING;
    if (fsm->state == ASB_STATE_SUSTAINED && !media_recovery) return;

    /* Extend existing idle trim only outside PERFORMANCE, gaming/video and thermal-cap paths. */
    if (g_active_efficiency.gpu_idle_bonus_pct > 0 &&
        fsm->profile_idx != PROFILE_PERFORMANCE && fsm->gpu_video_ticks < 2 &&
        (fsm->state == ASB_STATE_LIGHT_IDLE || fsm->state == ASB_STATE_MODERATE) &&
        g_asb_cfg.gpu_idle_trim_pct > 0) {
        int floor_gpu = g_asb_cfg.gpu_idle_trim_floor > 0
                        ? g_asb_cfg.gpu_idle_trim_floor : 55;
        int trimmed = caps->gpu_max_pct - g_active_efficiency.gpu_idle_bonus_pct;
        if (trimmed < floor_gpu) trimmed = floor_gpu;
        if (trimmed < caps->gpu_max_pct) caps->gpu_max_pct = trimmed;
    }

    /* Keep foreground/top-app caps intact: only background cgroups lean further. Known
     * media recovery is allowed at light stage; every other workload still needs the existing
     * moderate/severe threshold before background restraint changes. */
    if ((!media_recovery && g_budget_stage < 2) || caps->uclamp_bg_max <= 0) return;
    delta = g_budget_stage >= 3 ? g_active_efficiency.bg_uclamp_severe_delta
                                : g_active_efficiency.bg_uclamp_moderate_delta;
    if (delta > 0) {
        int target = caps->uclamp_bg_max - delta;
        if (target < 128) target = 128;
        if (target < caps->uclamp_bg_max) caps->uclamp_bg_max = target;
    }
}

/* Why the prime ceiling is where it is, for the state file.
 *
 * Both audits of the same capture asked the same question - in a 4-hour screen-on video
 * phase ASB owned the cap in ~90% of the throttle samples, and nothing said whether that
 * was thermal protection, the efficiency envelope or simply the profile's own ceiling.
 * One of them proposed exactly this: base, effective, and the stage that lowered it.
 *
 * The prime slot is the one that matters for both heat and responsiveness. "profile"
 * means neither stage below touched it; the figures let anyone see whether the cap ever
 * bit, which in that capture it did not (1.64 GHz ceiling, 1.13 GHz peak demand). */
static int    g_cfg_load_rc = 0;
static time_t g_cfg_load_ts = 0;
static int  g_cap_prime_base_khz = 0;
static int  g_cap_prime_eff_khz  = 0;
static char g_cap_prime_reason[64] = "profile";  /* "thermal_budget:" + 32-byte reason */

/* Main cores kept level with the prime (fix130).
 *
 * The scheduler places a task by each cluster's capacity at its CURRENT ceiling. On a 6+2
 * part both clusters sit on the 40% race-to-idle floor in light states: OP15 main 1555200
 * of 3628800 (capacity 762 -> 327), prime 1862400 of 4608000 (1024 -> 414). The two prime
 * cores then look like the bigger cluster and ordinary screen-on work moves there. Field
 * captures: an OP15 on V65-debug5 had the prime above its lowest step in 91% of screen-on
 * samples and the main cores in 39%, the split following the ceilings (main 1440000 ->
 * prime busy 96-100%; main 1900800 -> 14-41%). Five earlier OP15 captures, MODERATE, the
 * prime at 1862400: main 1555200 -> prime busy 27-100%, 412 mA mean; main 1900800 -> 9-36%,
 * 274 mA, at similar load and GPU.
 *
 * So in LIGHT_IDLE and MODERATE the main ceiling is raised to the first step whose capacity
 * matches the prime's ceiling. Nothing else moves: the prime keeps its floor and the work
 * stays on the cores built for it. Two clusters only, never above 60% of the main cluster's
 * hardware (a phone whose first cluster is truly little never qualifies), and not while a
 * thermal cap is in force (a thermal budget trim was excluded too until fix156 - see below).
 * A prime burst keeps the level it found. main_capacity_parity=0 turns it off.
 *
 * Nearest step inside the limit (fix132). A PLQ110 (SM8750, main 792 of 1024 at 3532800,
 * prime 4320000) never got the raise: 40% of the prime is 1728000, the step under it is
 * 1689600 (39.1%), so the floor takes 1958400 (45%, capacity 464), and the level main step
 * is 2227200 = 63% - over the limit, refused. 153 of its 159 screen-on samples had the main
 * ceiling under the prime's while asbdiag said "not needed right now". When the exact step is
 * over the limit, the highest step inside it is taken if it reaches 90% of the prime's
 * capacity: 1996800 there (447 of 464), the same kHz an OP15 is lifted to. A cluster that
 * cannot get close (a truly little one, or a prime raised well above its floor) still stays
 * where it was. The state file says which happened (main_parity_near, main_parity_over_khz).
 *
 * Also under a trim, in HEAVY and in SUSTAINED (fix156). Those were left out on the reasoning
 * that lifting six cores is not how a warm phone cools - and the captures show the opposite.
 * The budget trim and SUSTAINED's 49% rail take the main ceiling to 1555200-1785600 while the
 * prime cannot follow (its 40% floor holds it at 1862400), so the prime becomes the bigger
 * cluster exactly when the phone is warm. Nine OP15 captures, warm (surface 40 C+) MODERATE
 * screen-on samples: main level with the prime - prime working in 9%, 337 mA, die 44.1 C;
 * main more than 10% below it - prime working in 67%, 456 mA, die 47.7 C. SUSTAINED: 73-86%
 * prime, 52-56 C. The trim still lowers the GPU and the background tier, and a real thermal
 * cap (throttling or a hard vendor clamp) still keeps the raise out. GAMING keeps its own path.
 * main_parity_cooling says the raise is the one held under a trim or in HEAVY/SUSTAINED. */
static int g_parity_cap0 = -2;              /* cpu_capacity, first cpu of policy0; -2 unread */
static int g_parity_cap1 = -2;              /* ... of the prime policy; -1 unreadable */
static int g_parity_main_khz = 0;           /* main ceiling raised this pass, 0 = none */
static unsigned long g_parity_lifts = 0;    /* passes that started a raise */
static int g_parity_near = 0;               /* 1 = the raise is the nearest step inside the limit */
static int g_parity_over_khz = 0;           /* the level step when it sat over the limit, else 0 */
#define ASB_PARITY_NEAR_PCT 90              /* the nearest step must reach this share of the prime */
static int g_parity_cooling = 0;            /* fix156: the raise is held under a trim or in HEAVY/SUSTAINED */
static unsigned long g_parity_cool_lifts = 0;

static int asb_cpu_capacity_of(int cpu) {
    char p[96];
    snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d/cpu_capacity", cpu);
    int v = sysfs_read_int(p, 0);
    return (v > 0 && v <= 4096) ? v : -1;
}

static void asb_main_capacity_parity(asb_profile_caps_t *caps, const asb_metrics_t *m,
                                     const asb_fsm_t *fsm, int trim) {
    int was = g_parity_main_khz;
    int lift = 0, near = 0, over = 0;
    int ok = g_asb_cfg.main_capacity_parity && fsm->profile_idx == PROFILE_SMART &&
             g_cpu_all_count == 2 && g_cpu_policy_ids[0] >= 0 && g_cpu_policy_ids[1] >= 0 &&
             g_cpu_policy_ids[2] < 0 && m->misc.screen_on && !fsm->thermal_cap &&
             !m->misc.camera_active && m->misc.app_hint < ASB_APP_GAMING &&
             fsm->state >= ASB_STATE_LIGHT_IDLE && fsm->state <= ASB_STATE_SUSTAINED &&
             caps->cpu_max[0] > 0 && caps->cpu_max[1] > 0;
    if (ok && fsm->prime_escape) {
        lift = was; near = g_parity_near; over = g_parity_over_khz;
    } else if (ok) {
        if (g_parity_cap0 == -2) {
            g_parity_cap0 = asb_cpu_capacity_of(g_cpu_policy_ids[0]);
            g_parity_cap1 = asb_cpu_capacity_of(g_cpu_policy_ids[1]);
        }
        long long hw0 = g_cpu_slot_hwmax[0], hw1 = g_cpu_slot_hwmax[1];
        if (g_parity_cap0 > 0 && g_parity_cap1 > 0 && hw0 > 0 && hw1 > 0) {
            long long p = writer_slot_ceiling(1, caps->cpu_max[1], 0);
            long long live = (long long)m->cpu.max_freq[1] * 1000LL;
            if (live > 0 && live < p) p = live;
            long long den = hw1 * g_parity_cap0;
            long long need = (p * g_parity_cap1 * hw0 + den - 1) / den;
            long long m0 = writer_slot_ceiling(0, caps->cpu_max[0], 0);
            if (p > 0 && need > m0) {
                long long step = writer_slot_step_at_least(0, (long)need);
                if (step > 0 && step * 100 <= hw0 * 60) lift = (int)step;
                else {
                    /* fix132: the highest step inside the limit, if it gets close enough.
                     * main capacity at top >= 90% of the prime's at p:
                     * cap0*top/hw0 >= 0.9*cap1*p/hw1. Products stay under 2^63. */
                    long long top = writer_slot_ceiling(0, (int)(hw0 * 60 / 100), 0);
                    over = step > 0 ? (int)step : 0;
                    if (top > m0 && top * 100 <= hw0 * 60 &&
                        top * g_parity_cap0 * hw1 * 100 >= p * g_parity_cap1 * hw0 * ASB_PARITY_NEAR_PCT) {
                        lift = (int)top; near = 1;
                    }
                }
            }
        }
    }
    if (lift > 0 && caps->cpu_max[0] < lift) caps->cpu_max[0] = lift;
    else { lift = 0; near = 0; }
    if (lift > 0 && was <= 0) g_parity_lifts++;
    {
        int cool = (lift > 0 && (trim > 0 || fsm->state >= ASB_STATE_HEAVY));
        if (cool && !g_parity_cooling) g_parity_cool_lifts++;
        g_parity_cooling = cool;
    }
    g_parity_main_khz = lift;
    g_parity_near = near;
    g_parity_over_khz = over;
}

/* Unlock lift (fix150).
 *
 * "Slideshow at unlock after a short idle, then smooth again" - several users of the same
 * build. The owner's capture 28442 (OP15, Smart) could not record the unlock itself (the
 * recorder dropped its baseline with the screen off - fixed beside this), but the first
 * recorded interval after two wakes drew the launcher with 31 of 262 and 18 of 39 frames
 * janky, against 1.7% over the whole capture, and every wake landed on Smart's MODERATE
 * ceilings: main 1996800 of 3628800 (55%), prime 1862400 of 4608000 (40%), top-app uclamp 50.
 * A boost asks for more by raising scaling_min_freq, and the kernel clamps a minimum to the
 * maximum: the capture's first kernel snapshot reads policy0 min 1785600 / max 1996800 and
 * policy6 min = max = 1862400 - a floor somebody else raised, held at ASB's ceiling. The unlock
 * animation, the resumed app and the work Doze held back all run under ceilings sized for
 * ordinary use.
 *
 * For unlock_lift_s seconds after the screen comes on - and once more at the first touch
 * within 20 s of it, the swipe that dismisses the lock screen on a phone woken by the power key
 * - every managed CPU ceiling is lifted to unlock_lift_pct of its cluster's hardware maximum,
 * and the top-app uclamp ceiling to the same share. Ceilings only: no floor is raised, so the
 * clocks climb only if the unlock asks for it, and the vendor's own boost is honoured again.
 * Not while thermally capped, not on a die already at the comfort mark.
 *
 * fix212: Smart, Battery and Balanced all lift now - the field captures behind it show the
 * Battery profile janking exactly here (32 % of SystemUI frames on an OP15 day against
 * 3.5-4.4 % on Smart), because the shell's static 50/38 % ceilings are all a wake ever
 * got. On a manual profile the writer borrows the ceilings above the shell's caps for the
 * window (manual_lift) and hands them back when it ends. Performance never needs it - its
 * ceilings are uncapped already. An app switch arms the same window once per 5 s while no
 * lift is running: opening or closing an app is the same burst as a wake.
 *
 * fix220: the app-switch arm alone reaches the animation late. It is seen on the next
 * metrics tick - up to 2 s after the tap - while the open/close animation runs in the first
 * half second, and the ColorOS 17 captures show it: 8-22 % janky in the wake rows that
 * landed in LIGHT_IDLE on Battery, SystemUI the top janker at every unlock (13.6 % of its
 * wake frames on Battery, 7.3 % on Smart). Two earlier signals now arm the same window:
 * the first touch after a calm spell (the tap that starts the open/close/switch - the
 * touchscreen is already in epoll, so the lift lands before the animation's first frames),
 * and the power key with the screen on (the lock press: the fade-out animation renders
 * before Android publishes the display state, at whatever ceilings the moment had). Both
 * share the app switch's 5 s gap and its gates, so a reading session buys one short lift
 * per burst of interaction, not an unbroken boost - ceilings only, the clocks still climb
 * just for the work that asks. To hear the lock press the wake keys stay in epoll with the
 * screen on, except the touch panel's own gesture node, which would wake the loop on every
 * frame of a scroll.
 *
 * fix223: on manual Battery the shell still owns the static ceilings, so changing its FSM
 * touch state would not make a continuous scroll any faster. The post-fix219 captures show
 * why that matters: CPH2745 Battery touch intervals in LIGHT_IDLE had 9.7% janky frames
 * versus 7.1% in MODERATE; on CPH2747, the same Telegram session class measured 8.1% under
 * Battery versus 3.7% after switching to Smart, and TikTok 15.6% versus 6.8%. A touch on
 * Battery now keeps the ALREADY ARMED lift alive while the finger remains active. It never
 * starts a lift by itself, and therefore cannot bypass the off/profile/thermal/warm gates.
 * Quiet reading gets the old static Battery ceilings back after the usual three seconds;
 * Smart, Balanced and Performance are unchanged. The lift remains a percentage of each
 * slot's own hardware maximum, with no Android/ColorOS-version dependency.
 *
 * fix240: the premise above held for the CPU only. Battery's LIGHT_IDLE also carries the
 * governor's own GPU ceiling of bat_light_idle_gpu (the lowest pwrlevel), and this lift never
 * touched the GPU - so even a lifted Battery wake or tap was drawn at 160 MHz until the FSM
 * left light idle a tick or more later. The FSM now treats a touch as interaction on Battery
 * too (asb_fsm.h, touch floor), which also covers the taps the warm-die veto keeps from
 * lifting. The lift itself is unchanged. */
#define ASB_UNLOCK_TOUCH_WINDOW_MS 20000L
#define ASB_LAUNCH_LIFT_GAP_MS 5000L
static int    g_unlock_prev_screen = -1;  /* screen state of the last pass, -1 before the first */
static long   g_unlock_on_ms       = 0;   /* boottime ms the screen last came on, 0 = off */
static long   g_unlock_until_ms    = 0;   /* boottime ms the running lift ends, 0 = none */
static int    g_unlock_touch_used  = 0;   /* the touch re-arm is spent for this screen-on */
static int    g_unlock_lift_now    = 0;   /* the lift is in force for this pass */
static int    g_unlock_applied     = 0;   /* the last caps written carried the lift */
static int    g_unlock_edge        = 0;   /* the lift started or ended: this pass must apply */
static unsigned long g_unlock_lifts = 0;  /* lifts started: screen-on edges and touch re-arms */
static unsigned long g_unlock_skips = 0;  /* edges that did not lift */
static char   g_unlock_skip_why[16] = "-";/* why the last one did not: off/profile/thermal/warm */
static long   g_launch_arm_ms      = 0;   /* boottime ms of the last app-switch arm */
static int    g_unlock_profile     = -1;  /* profile the last update ran for (fix243) */
static const char *g_unlock_arm_why = "-";/* what armed the running lift, for the log line */
static long   g_unlock_armed_ms    = 0;   /* boottime ms of the arm behind the running lift (fix248) */
static int    g_unlock_level_khz   = 0;   /* prime ceiling a held Battery lift was levelled to, 0 = none */
static unsigned long g_unlock_levels = 0; /* held lifts that were levelled */
static int    g_bhold_allow        = 1;   /* fix271: a finger may hold the Battery lift for the app in front */
static int    g_unlock_cold_kick   = 0;   /* fix272: Zygisk saw zygote start a new top-app process */
static unsigned long g_unlock_cold_lifts = 0;   /* lifts a cold start armed */
static unsigned long g_unlock_cold_extends = 0; /* running lifts a cold start carried over the launch */

/* Who the lift is for. Battery and Balanced are exactly the profiles that jank on a wake -
 * their ceilings are the shell's static caps - and Smart has always had it. Performance is
 * never capped, so a lift there would only mark paths held for no gain. */
static int asb_unlock_lift_profile_ok(int profile_idx) {
    return profile_idx != PROFILE_PERFORMANCE;
}

/* "Warm" is judged on the die before the wake as well as at it (fix166).
 *
 * The screen-on tick reads the zones at the very moment the wake runs every core at once,
 * and a single-core sensor reads that burst, not the phone. Capture 29835: zones at 34-37 C
 * at 08:25 and 27-29 C at 08:48, and the one wake in between was not lifted "warm" - the die
 * read at or above the 48 C comfort mark on that tick. The same burst engaged the screen-off
 * cooldown at 06:20 on a 46 C reading taken nine seconds into a face unlock.
 *
 * With the screen off the die mostly cools, and background work that heats it is read by the
 * screen-off ticks themselves (every tick outside deep idle, the keepalive inside it), so the
 * last reading taken in the dark is a fair bound on the phone's own temperature at the wake.
 * The lower of the two is used: a phone that went to sleep hot is still skipped, a cool one
 * is not skipped for its own wake. Half an hour bounds it - long enough for any screen-off
 * between two uses, short enough that a phone left in a hot car is judged on what it reads
 * now. */
#define ASB_UNLOCK_DARK_MAX_AGE_S 1800
static int    g_unlock_dark_c  = 0;       /* last die reading taken with the screen off */
static time_t g_unlock_dark_ts = 0;
static int asb_unlock_gate_die(int die_now, int dark_c, time_t dark_ts, time_t now) {
    if (die_now <= 0 || dark_c <= 0 || dark_ts <= 0 || now < dark_ts ||
        now - dark_ts > ASB_UNLOCK_DARK_MAX_AGE_S) return die_now;
    return dark_c < die_now ? dark_c : die_now;
}

static int asb_unlock_lift_update(int screen_on, int touch_kick, int touch_active,
                                  int lock_kick, int launch_kick,
                                  long now_ms, int profile_idx, int thermal_cap, int die_c) {
    int prev = g_unlock_prev_screen;
    int arm = 0, cold = 0;
    /* fix272: a cold start is heard once, whatever this pass decides. */
    int cold_kick = g_unlock_cold_kick;
    g_unlock_cold_kick = 0;
    g_unlock_prev_screen = screen_on ? 1 : 0;
    g_unlock_profile = profile_idx;
    if (!screen_on) {
        g_unlock_on_ms = 0;
        g_unlock_until_ms = 0;
        g_unlock_touch_used = 0;
        g_unlock_lift_now = 0;
        return 0;
    }
    if (prev == 0) {
        g_unlock_on_ms = now_ms;
        g_unlock_touch_used = 0;
        arm = 1;
        g_unlock_arm_why = "screen on";
    } else if (touch_kick && !g_unlock_touch_used && g_unlock_on_ms > 0 &&
               now_ms - g_unlock_on_ms <= ASB_UNLOCK_TOUCH_WINDOW_MS) {
        g_unlock_touch_used = 1;
        g_launch_arm_ms = now_ms;
        arm = 1;
        g_unlock_arm_why = "first touch";
    } else if (cold_kick) {
        /* fix272: zygote is starting a new process for the app being opened. The tap that
         * asked for it usually armed a lift already; that window is carried over the start
         * (bounded by unlock_lift_s from now), so a heavy cold start does not finish on the
         * static ceilings. With no lift running, the start arms one even inside the 5 s
         * anti-chatter gap - the companion already limits cold starts to 1 s apart and 20 a
         * minute, and every profile/thermal/warm gate below still applies. */
        if (g_unlock_until_ms > now_ms) {
            if (g_asb_cfg.unlock_lift_s > 0 && asb_unlock_lift_profile_ok(profile_idx) && !thermal_cap) {
                long until = now_ms + (long)g_asb_cfg.unlock_lift_s * 1000L;
                if (until > g_unlock_until_ms) {
                    g_unlock_until_ms = until;
                    g_unlock_cold_extends++;
                }
            }
        } else {
            g_launch_arm_ms = now_ms;
            arm = 1;
            cold = 1;
            g_unlock_arm_why = "cold start";
        }
    } else if ((touch_kick || lock_kick || launch_kick) && g_unlock_until_ms <= now_ms &&
               now_ms - g_launch_arm_ms >= ASB_LAUNCH_LIFT_GAP_MS) {
        /* fix212: a foreground-app change. fix220: the tap that starts an open/close and
         * the lock press are the same burst, heard earlier than the app hash can change.
         * Rate-limited and refused while a lift runs, so scrolling through the recents
         * list buys one window, not an unbroken boost. */
        g_launch_arm_ms = now_ms;
        arm = 1;
        g_unlock_arm_why = touch_kick ? "touch" : (lock_kick ? "lock key" : "app switch");
    }
    if (arm) {
        const char *why = NULL;
        if (g_asb_cfg.unlock_lift_s <= 0) why = "off";
        else if (!asb_unlock_lift_profile_ok(profile_idx)) why = "profile";
        else if (thermal_cap) why = "thermal";
        else if (die_c > 0 && g_asb_cfg.bat_comfort_temp > 0 &&
                 die_c >= g_asb_cfg.bat_comfort_temp) why = "warm";
        if (why) {
            g_unlock_skips++;
            snprintf(g_unlock_skip_why, sizeof(g_unlock_skip_why), "%s", why);
        } else {
            long until = now_ms + (long)g_asb_cfg.unlock_lift_s * 1000L;
            if (until > g_unlock_until_ms) g_unlock_until_ms = until;
            g_unlock_armed_ms = now_ms;
            g_unlock_lifts++;
            if (cold) g_unlock_cold_lifts++;
        }
    }
    /* A continuous Battery scroll is one interaction, not a new lift on every tick. Extend
     * only an existing, successfully armed window; a zero/unarmed window stays zero, so the
     * setting-off, warm-die and profile vetoes above cannot be bypassed by holding a finger
     * down. The two-second active cadence is shorter than the three-second window, and the
     * normal expiry/handback runs as soon as the touch stream stops. */
    if (touch_active && profile_idx == PROFILE_BATTERY && g_unlock_until_ms > 0 &&
        g_asb_cfg.unlock_lift_s > 0 && !thermal_cap && g_bhold_allow) {
        long until = now_ms + (long)g_asb_cfg.unlock_lift_s * 1000L;
        if (until > g_unlock_until_ms) g_unlock_until_ms = until;
    }
    if (g_unlock_until_ms > 0 &&
        (thermal_cap || !asb_unlock_lift_profile_ok(profile_idx) || now_ms >= g_unlock_until_ms))
        g_unlock_until_ms = 0;
    g_unlock_lift_now = (g_unlock_until_ms > 0);
    if (!g_unlock_lift_now) g_unlock_level_khz = 0;
    return g_unlock_lift_now;
}

/* fix243: Battery lifts to four fifths of the shared share (80 -> 64 % of each cluster's
 * maximum). Two OP15 Battery captures (fix241/fix242 builds) had the lift in force for 54 %
 * and 52 % of the screen-on intervals - the continuous-touch hold keeps it up through a
 * scroll - while the main cluster sat at its lifted ceiling in only 1-2 % of them: the extra
 * clock bought 6.5 vs 8.0 % and 9.7 vs 11.7 % janky frames against the static ceilings, and
 * the slow-UI share hardly moved (3.6 vs 4.3 %). What was slow was the scheduler's response
 * (Battery ran a 32 ms WALT window and discounted top-app demand to 80 %), which the Battery
 * rails now fix; the peaks above ~64 % are the least efficient part of every OnePlus DVFS
 * table. A share, so it follows each cluster's own maximum; never below the 50 % floor. */
static int asb_unlock_lift_share(int profile_idx) {
    int pct = g_asb_cfg.unlock_lift_pct;
    if (pct < 50) pct = 50;
    if (pct > 100) pct = 100;
    if (profile_idx == PROFILE_BATTERY) {
        pct = pct * 4 / 5;
        if (pct < 50) pct = 50;
    }
    return pct;
}

/* A Battery lift held by a finger keeps the clusters level (fix248).
 *
 * The lift raises every cluster to the same share of its OWN maximum, and the clusters are
 * not the same size: on a 6+2 part the prime's capacity is a third above the main cores'
 * (OP15: 1024 against 762), so at 64 % of each the prime becomes the bigger cluster and the
 * scheduler moves ordinary foreground work onto the two dearest cores - the very imbalance
 * fix130 removed from Smart. On Battery the touch hold (fix223) keeps the lift up through a
 * whole scroll: in an OP15 Battery day the screen-on samples with the main ceiling more than
 * 10 % under the prime's had the prime working in 20 % of them against 7-8 % with the two
 * level, and a mean sampled current of 300 against 246 mA.
 *
 * So once a Battery lift outlives its own window and is only held up by the finger, the
 * prime is lifted no further than the step whose capacity is within 10 % of the lifted main
 * ceiling (OP15: 2227200 instead of 2880000 kHz, 495 against 468). The main lift, the
 * top-app uclamp raise and the first unlock_lift_s seconds of every wake, first touch, app
 * switch and lock press are untouched - those are the animations - and so is the jank
 * guard's lift. Two clusters only, from each device's own cpu_capacity and frequency table;
 * never below the prime's ceiling before the lift; main_capacity_parity=0 turns it off. */
static int g_bjank_armed;
static void asb_unlock_lift_apply(asb_profile_caps_t *caps) {
    int pct = asb_unlock_lift_share(g_unlock_profile);
    int prime_before = caps->cpu_max[1];
    for (int i = 0; i < 3; i++) {
        long hw = g_cpu_slot_hwmax[i];
        /* 0 is "not managed" (an empty slot, or a prime left to the vendor): nothing to lift. */
        if (hw <= 0 || caps->cpu_max[i] <= 0) continue;
        int want = (int)(hw * pct / 100);
        if (caps->cpu_max[i] < want) caps->cpu_max[i] = want;
    }
    if (caps->uclamp_top_max > 0 && caps->uclamp_top_max < pct) caps->uclamp_top_max = pct;
    int lvl = 0;
    if (g_unlock_profile == PROFILE_BATTERY && g_asb_cfg.main_capacity_parity && !g_bjank_armed &&
        g_asb_cfg.unlock_lift_s > 0 && g_unlock_armed_ms > 0 &&
        asb_clock_ms(CLOCK_BOOTTIME) - g_unlock_armed_ms >= (long)g_asb_cfg.unlock_lift_s * 1000L &&
        g_cpu_all_count == 2 && g_cpu_policy_ids[0] >= 0 && g_cpu_policy_ids[1] >= 0 &&
        g_cpu_policy_ids[2] < 0 && caps->cpu_max[0] > 0 && prime_before > 0 &&
        caps->cpu_max[1] > prime_before) {
        if (g_parity_cap0 == -2) {
            g_parity_cap0 = asb_cpu_capacity_of(g_cpu_policy_ids[0]);
            g_parity_cap1 = asb_cpu_capacity_of(g_cpu_policy_ids[1]);
        }
        long long hw0 = g_cpu_slot_hwmax[0], hw1 = g_cpu_slot_hwmax[1];
        if (g_parity_cap0 > 0 && g_parity_cap1 > g_parity_cap0 && hw0 > 0 && hw1 > 0) {
            long long m = writer_slot_ceiling(0, caps->cpu_max[0], 0);
            long long lim = m * g_parity_cap0 * hw1 * 110 / (hw0 * g_parity_cap1 * 100);
            long long p = lim > 0 ? writer_slot_ceiling(1, (int)lim, 0) : 0;
            if (p > 0 && p < caps->cpu_max[1]) {
                if (p < prime_before) p = prime_before;
                caps->cpu_max[1] = (int)p;
                lvl = (int)p;
            }
        }
    }
    if (lvl > 0 && g_unlock_level_khz <= 0) g_unlock_levels++;
    g_unlock_level_khz = lvl;
}

/* Smart night slot with the screen on (fix150) - see asb_smart_night_awake. */

/* Battery scroll hold, measured per app (fix271).
 *
 * fix223 keeps a Battery lift up for as long as a finger stays on the glass, so a feed scrolls
 * at 64 % of each cluster's maximum instead of the static Battery ceilings. An OP15 Battery
 * evening (capture 30677, 3 h, screen on 96 % of it) had the main ceiling lifted in 78 % of
 * its samples and the main cores at the lifted 2227200 kHz for 13 % of the whole capture, and
 * the hold paid off in one app: a social feed drew 14.8 % janky frames of its own at the static
 * ceilings and 7.6 % under the levelled hold. A chat client (0.7-5.1 % against 1.3-6.6 %) and a
 * photo feed (1.2-2.4 % against 1.3-2.7 %) were as smooth either way, while the lifted intervals sampled
 * 1.4-1.8 times the current - touching and scrolling draw more by themselves, so that is an
 * upper bound on what the hold cost, but an app the hold does not help pays it for nothing.
 *
 * So whether a finger may hold the lift is decided per app, from the app's own frames: windows
 * of Android's frame statistics (the probe Smart's smoothness check uses) alternate between
 * hold and no hold. The hold is kept where, after at least three windows and 4000 frames on
 * each side, it removes a quarter of the janky frames and at least 1.5 points - Smart's bar
 * for more headroom; after six windows a side without that it is released. A released app
 * still gets the lift for the first unlock_lift_s seconds of every wake, app open or close,
 * first touch after a calm spell and lock press - the animations - and scrolls at the static
 * Battery ceilings after that. A test short of frames, or an app that draws no frames Android
 * counts, keeps the hold. Verdicts persist in /data/adb/asb/battery_hold.tsv (24 apps, the
 * least recently used replaced) and are tested again after 21 days. A probe runs only while
 * the app in front is under test, at most every three minutes; SystemUI and launchers, games,
 * the camera and a thermal cap stay out. The recorder-only jank guard does not arm for an app
 * whose hold was released, and any window it lifted is discarded rather than counted.
 * battery_hold_learn=0 turns the measuring off and every app keeps the hold, as before. */
#ifndef ASB_BHOLD_FILE
#define ASB_BHOLD_FILE        "/data/adb/asb/battery_hold.tsv"
#endif
#define ASB_BHOLD_APPS        24
#define ASB_BHOLD_PROBE_S     180
#define ASB_BHOLD_MIN_WINDOWS 3
#define ASB_BHOLD_MAX_WINDOWS 6
#define ASB_BHOLD_MIN_FRAMES  4000L
#define ASB_BHOLD_GAIN_REL    0.25
#define ASB_BHOLD_GAIN_ABS    0.015
#define ASB_BHOLD_MAX_EMPTY   6
#define ASB_BHOLD_RECHECK_S   (21L * 24 * 3600)
typedef struct {
    uint64_t hash;
    long     last_ts, decided_ts;
    int      state;             /* 0 under test, 1 hold kept, 2 hold released */
    int      arm;               /* under test: the side the next window runs on, 1 hold, 0 none */
    int      empty;             /* probes in a row that found no frames for the app */
    long     frames[2], janky[2];
    int      windows[2];
} asb_bhold_app_t;
static asb_bhold_app_t g_bhold[ASB_BHOLD_APPS];
static int      g_bhold_loaded = 0;
static uint64_t g_bhold_win_hash = 0;
static char     g_bhold_win_pkg[64];
static long     g_bhold_win_frames = -1, g_bhold_win_janky = -1;
static int      g_bhold_win_arm = -1;   /* side in force since the window began, -2 spoiled */
static long     g_bhold_probe_ts = 0, g_bhold_gfx_seen = 0;
static int      g_bhold_now = -1;       /* app in front: -1 not measured, 0 released, 1 kept, 2 under test */
static unsigned long g_bhold_probes = 0, g_bhold_windows = 0;
static char     g_bhold_msg[220];
static int      g_bhold_spoil = 0;      /* the jank guard lifted during the window */

static void asb_bhold_load(void) {
    g_bhold_loaded = 1;
    memset(g_bhold, 0, sizeof(g_bhold));
    FILE *f = fopen(ASB_BHOLD_FILE, "r");
    if (!f) return;
    char line[256];
    int n = 0;
    while (n < ASB_BHOLD_APPS && fgets(line, sizeof(line), f)) {
        unsigned long long h = 0;
        int st = -1, arm = -1, em = -1, w0 = -1, w1 = -1;
        long f0 = -1, j0 = -1, f1 = -1, j1 = -1, dt = 0, lt = 0;
        if (sscanf(line, "%llx %d %d %d %ld %ld %ld %ld %d %d %ld %ld", &h, &st, &arm, &em,
                   &f0, &j0, &f1, &j1, &w0, &w1, &dt, &lt) != 12) continue;
        if (!h || st < 0 || st > 2 || arm < 0 || arm > 1 || em < 0 || em > 1000 ||
            f0 < 0 || f1 < 0 || j0 < 0 || j1 < 0 || j0 > f0 || j1 > f1 ||
            w0 < 0 || w1 < 0 || w0 > 1000 || w1 > 1000 || dt < 0 || lt < 0) continue;
        int dup = 0;
        for (int i = 0; i < n; i++) if (g_bhold[i].hash == (uint64_t)h) dup = 1;
        if (dup) continue;
        asb_bhold_app_t *a = &g_bhold[n++];
        a->hash = (uint64_t)h; a->state = st; a->arm = arm; a->empty = em;
        a->frames[0] = f0; a->janky[0] = j0; a->frames[1] = f1; a->janky[1] = j1;
        a->windows[0] = w0; a->windows[1] = w1; a->decided_ts = dt; a->last_ts = lt;
    }
    fclose(f);
}

static void asb_bhold_save(void) {
    char tmp[96];
    snprintf(tmp, sizeof(tmp), "%s.tmp", ASB_BHOLD_FILE);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    for (int i = 0; i < ASB_BHOLD_APPS; i++) {
        const asb_bhold_app_t *a = &g_bhold[i];
        if (!a->hash) continue;
        fprintf(f, "%016llx %d %d %d %ld %ld %ld %ld %d %d %ld %ld\n", (unsigned long long)a->hash,
                a->state, a->arm, a->empty, a->frames[0], a->janky[0], a->frames[1], a->janky[1],
                a->windows[0], a->windows[1], a->decided_ts, a->last_ts);
    }
    int ok = (fflush(f) == 0);
    if (fclose(f) != 0) ok = 0;
    if (!ok || rename(tmp, ASB_BHOLD_FILE) != 0) remove(tmp);
}

static asb_bhold_app_t *asb_bhold_find(uint64_t hash, long now) {
    asb_bhold_app_t *lru = NULL;
    for (int i = 0; i < ASB_BHOLD_APPS; i++) {
        asb_bhold_app_t *a = &g_bhold[i];
        if (a->hash == hash) return a;
        if (!lru || (lru->hash != 0 && (a->hash == 0 || a->last_ts < lru->last_ts))) lru = a;
    }
    memset(lru, 0, sizeof(*lru));
    lru->hash = hash; lru->last_ts = now; lru->arm = 1;
    return lru;
}

/* The side in force for the app: 1 the finger may hold the lift, 0 it may not. */
static int asb_bhold_side(asb_bhold_app_t *a, long now) {
    if ((a->state == 1 || a->state == 2) && now - a->decided_ts >= ASB_BHOLD_RECHECK_S) {
        a->state = 0; a->arm = 1; a->empty = 0;
        a->frames[0] = a->frames[1] = a->janky[0] = a->janky[1] = 0;
        a->windows[0] = a->windows[1] = 0;
    }
    if (a->state == 1) return 1;
    if (a->state == 2) return 0;
    return a->arm;
}

/* One finished window of the app under side `arm`. Returns 1 when the app got its verdict
 * (the message is in g_bhold_msg). */
static int asb_bhold_window(asb_bhold_app_t *a, const char *disp, long df, long dj, int arm, long now) {
    if (!a || a->state != 0 || arm != a->arm || df < 0 || dj < 0 || dj > df) return 0;
    a->frames[arm] += df; a->janky[arm] += dj; a->windows[arm]++;
    a->arm ^= 1;
    int enough = a->windows[0] >= ASB_BHOLD_MIN_WINDOWS && a->windows[1] >= ASB_BHOLD_MIN_WINDOWS &&
                 a->frames[0] >= ASB_BHOLD_MIN_FRAMES && a->frames[1] >= ASB_BHOLD_MIN_FRAMES;
    int full = a->windows[0] >= ASB_BHOLD_MAX_WINDOWS && a->windows[1] >= ASB_BHOLD_MAX_WINDOWS;
    double j0 = a->frames[0] > 0 ? (double)a->janky[0] / (double)a->frames[0] : 0.0;
    double j1 = a->frames[1] > 0 ? (double)a->janky[1] / (double)a->frames[1] : 0.0;
    if (enough && j1 <= j0 * (1.0 - ASB_BHOLD_GAIN_REL) && j0 - j1 >= ASB_BHOLD_GAIN_ABS) {
        a->state = 1;
        snprintf(g_bhold_msg, sizeof(g_bhold_msg),
                 "battery_hold: %s - holding the lift through a scroll helps (janky %.1f %% without, %.1f %% with): kept",
                 disp, 100.0 * j0, 100.0 * j1);
    } else if (full && enough) {
        a->state = 2;
        snprintf(g_bhold_msg, sizeof(g_bhold_msg),
                 "battery_hold: %s - the hold does not help (janky %.1f %% without, %.1f %% with): a scroll runs at the Battery ceilings",
                 disp, 100.0 * j0, 100.0 * j1);
    } else if (full) {
        a->state = 1;
        snprintf(g_bhold_msg, sizeof(g_bhold_msg),
                 "battery_hold: %s - a full test without enough frames for a verdict: the hold stays", disp);
    } else {
        return 0;
    }
    a->decided_ts = now;
    return 1;
}

static void asb_bhold_tick(const asb_fsm_t *fsm, const asb_metrics_t *m) {
    long now = (long)time(NULL);
    int on = g_asb_cfg.battery_hold_learn && g_asb_cfg.unlock_lift_s > 0 &&
             fsm->profile_idx == PROFILE_BATTERY && m->misc.screen_on && !m->misc.camera_active &&
             g_pkg_detect_ok && g_smart_rt.app_hash != 0 && g_smart_rt.app_hint < ASB_APP_GAMING &&
             g_smart_rt.app_pkg_cached[0] && !asb_smart_is_system_ui(g_smart_rt.app_pkg_cached);
    if (!on) {
        g_bhold_allow = 1;
        g_bhold_now = -1;
        g_bhold_win_hash = 0; g_bhold_win_pkg[0] = 0;
        g_bhold_win_frames = -1; g_bhold_win_janky = -1; g_bhold_win_arm = -1;
        return;
    }
    if (!g_bhold_loaded) asb_bhold_load();
    uint64_t h = g_smart_rt.app_hash;
    if (h != g_bhold_win_hash) {
        g_bhold_win_hash = h;
        snprintf(g_bhold_win_pkg, sizeof(g_bhold_win_pkg), "%s", g_smart_rt.app_pkg_cached);
        g_bhold_win_frames = -1; g_bhold_win_janky = -1; g_bhold_win_arm = -1;
    }
    asb_bhold_app_t *a = asb_bhold_find(h, now);
    a->last_ts = now;
    int side = asb_bhold_side(a, now);
    if (g_bhold_win_arm == -1) g_bhold_win_arm = side;
    else if (g_bhold_win_arm != side) g_bhold_win_arm = -2;
    if (fsm->thermal_cap || g_bhold_spoil) g_bhold_win_arm = -2;
    g_bhold_spoil = 0;
    struct stat st;
    if (stat(ASB_GFX_FILE, &st) == 0 && (long)st.st_mtime != g_bhold_gfx_seen &&
        g_bhold_probe_ts > 0 && (long)st.st_mtime >= g_bhold_probe_ts) {
        g_bhold_gfx_seen = (long)st.st_mtime;
        long fr = -1, jk = -1;
        if (asb_gfx_read_pkg(g_bhold_win_pkg, &fr, &jk) == 0) {
            a->empty = 0;
            if (a->state == 0 && g_bhold_win_frames >= 0 && fr >= g_bhold_win_frames &&
                jk >= g_bhold_win_janky && g_bhold_win_arm >= 0) {
                char disp[64];
                if (g_asb_cfg.smart_pkg_plaintext || ASB_DEBUG_BUILD)
                    snprintf(disp, sizeof(disp), "%s", g_bhold_win_pkg);
                else
                    snprintf(disp, sizeof(disp), "app %016llx", (unsigned long long)h);
                g_bhold_windows++;
                if (asb_bhold_window(a, disp, fr - g_bhold_win_frames, jk - g_bhold_win_janky,
                                     g_bhold_win_arm, now))
                    asb_log("%s", g_bhold_msg);
                asb_bhold_save();
            }
            g_bhold_win_frames = fr; g_bhold_win_janky = jk;
        } else if (a->state == 0 && ++a->empty >= ASB_BHOLD_MAX_EMPTY) {
            a->state = 1; a->decided_ts = now;
            asb_log("battery_hold: an app with no frames Android counts after %d probes - the hold stays",
                    ASB_BHOLD_MAX_EMPTY);
            asb_bhold_save();
        }
        side = asb_bhold_side(a, now);
        g_bhold_win_arm = side;
    }
    g_bhold_allow = side;
    g_bhold_now = a->state == 0 ? 2 : (a->state == 1 ? 1 : 0);
    if (a->state == 0 && (g_bhold_probe_ts == 0 || now - g_bhold_probe_ts >= ASB_BHOLD_PROBE_S ||
                          now < g_bhold_probe_ts)) {
        const char *pk = g_bhold_win_pkg;
        int ok = pk[0] != 0;
        for (const char *c = pk; *c && ok; c++)
            ok = ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
                  (*c >= '0' && *c <= '9') || *c == '.' || *c == '_');
        g_bhold_probe_ts = now;
        if (!ok) return;
        g_bhold_probes++;
        asb_run_modscript("runtime/asb_gfx_probe.sh", pk);
    }
}

/* kept, released, under test: the verdicts on record. */
static void asb_bhold_counts(int *kept, int *released, int *testing) {
    *kept = *released = *testing = 0;
    if (!g_bhold_loaded) asb_bhold_load();
    for (int i = 0; i < ASB_BHOLD_APPS; i++) {
        if (!g_bhold[i].hash) continue;
        if (g_bhold[i].state == 1) (*kept)++;
        else if (g_bhold[i].state == 2) (*released)++;
        else (*testing)++;
    }
}

/* Battery jank insurance (fix236).
 *
 * This is deliberately NOT Smart's per-app learner. It runs only in Battery and only while
 * the user-owned session recorder is live in this boot. The existing on-demand graphicsstats
 * probe supplies a foreground window; a sufficiently large, genuinely janky window arms the
 * same short, ceiling-only unlock lift. There is no frequency floor, persistent offset, app
 * table or background polling worker. The ordinary lift expiry performs exact handback, and
 * camera/thermal/profile gates remain ahead of it. */
#define ASB_BJANK_PROBE_S       60
#define ASB_BJANK_TTL_MS        10000L
#define ASB_BJANK_MIN_FRAMES    300L
#define ASB_BJANK_MIN_JANKY     12L
#define ASB_BJANK_MIN_PCT       8L
/* A short launcher/app-transition window can be visibly rough and still end before the
 * primary 300-frame sample exists. Keep a second, stricter high-jank ratio for that case;
 * it uses the same 60-second on-demand dump and the same bounded ceiling-only lift. */
#define ASB_BJANK_SHORT_FRAMES  120L
#define ASB_BJANK_SHORT_JANKY   8L
#define ASB_BJANK_SHORT_PCT     12L
#define ASB_BJANK_LOCK          "/data/adb/asb/logkit/full_day_webui.lock"
static uint64_t g_bjank_hash = 0;
static char     g_bjank_pkg[64];
static long     g_bjank_frames = -1, g_bjank_janky = -1;
static long     g_bjank_sys_frames = -1, g_bjank_sys_janky = -1;
static long     g_bjank_probe_ts = 0, g_bjank_gfx_seen = 0;
static long     g_bjank_log_ts = 0;
static int      g_bjank_log_ok = 0, g_bjank_armed = 0;
static unsigned long g_bjank_probes = 0, g_bjank_windows = 0, g_bjank_triggers = 0;

static int asb_bjank_read(const char *path, char *buf, size_t cap) {
    if (!buf || cap < 2) return -1;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, cap - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' '))
        buf[--n] = 0;
    return n > 0 ? 0 : -1;
}

static int asb_bjank_capture_live(long now) {
    if (g_bjank_log_ts > 0 && now >= g_bjank_log_ts && now - g_bjank_log_ts < 5)
        return g_bjank_log_ok;
    g_bjank_log_ts = now;
    g_bjank_log_ok = 0;
    char boot[80], lock_boot[80], pid_s[24];
    if (asb_bjank_read("/proc/sys/kernel/random/boot_id", boot, sizeof(boot)) < 0 ||
        asb_bjank_read(ASB_BJANK_LOCK "/boot_id", lock_boot, sizeof(lock_boot)) < 0 ||
        strcmp(boot, lock_boot) != 0 ||
        asb_bjank_read(ASB_BJANK_LOCK "/pid", pid_s, sizeof(pid_s)) < 0) return 0;
    char *end = NULL;
    long pid = strtol(pid_s, &end, 10);
    if (!end || *end || pid <= 1 || kill((pid_t)pid, 0) != 0) return 0;
    g_bjank_log_ok = 1;
    return 1;
}

static void asb_bjank_reset_window(void) {
    g_bjank_hash = 0;
    g_bjank_pkg[0] = 0;
    g_bjank_frames = -1;
    g_bjank_janky = -1;
    g_bjank_sys_frames = -1;
    g_bjank_sys_janky = -1;
}

static void asb_bjank_disarm(void) {
    if (g_bjank_armed) {
        g_bjank_armed = 0;
        g_unlock_until_ms = 0;
        g_unlock_lift_now = 0;
        g_unlock_edge = 1;
    }
    asb_bjank_reset_window();
}

static void asb_bjank_eval_window(const char *pkg, long df, long dj, long now_ms) {
    g_bjank_windows++;
    int long_window = df >= ASB_BJANK_MIN_FRAMES && dj >= ASB_BJANK_MIN_JANKY &&
                      dj * 100L >= df * ASB_BJANK_MIN_PCT;
    int short_window = df >= ASB_BJANK_SHORT_FRAMES && df < ASB_BJANK_MIN_FRAMES &&
                       dj >= ASB_BJANK_SHORT_JANKY &&
                       dj * 100L >= df * ASB_BJANK_SHORT_PCT;
    if ((long_window || short_window) &&
        (g_bhold_allow || strcmp(pkg, "com.android.systemui") == 0)) {
        g_bhold_spoil = 1;
        g_unlock_until_ms = now_ms + ASB_BJANK_TTL_MS;
        g_unlock_lift_now = 1;
        g_unlock_edge = 1;
        g_bjank_armed = 1;
        g_unlock_arm_why = "battery jank guard";
        g_bjank_triggers++;
        asb_log("battery_jank_guard[%s]: %s %ld/%ld janky frames (%ld%%), ceilings to %d%% for %lds",
                short_window ? "short" : "long", pkg, dj, df, df > 0 ? dj * 100L / df : 0L,
                asb_unlock_lift_share(PROFILE_BATTERY), ASB_BJANK_TTL_MS / 1000L);
    }
}

static void asb_battery_jank_guard_tick(const asb_fsm_t *fsm, const asb_metrics_t *m) {
    long now = (long)time(NULL);
    long now_ms = asb_clock_ms(CLOCK_BOOTTIME);
    if (g_bjank_armed && now_ms >= g_unlock_until_ms) g_bjank_armed = 0;
    int on = g_asb_cfg.battery_jank_guard && fsm->profile_idx == PROFILE_BATTERY &&
             m->misc.screen_on && !m->misc.camera_active && !fsm->thermal_cap &&
             g_pkg_detect_ok && g_smart_rt.app_hash != 0 &&
             g_smart_rt.app_hint < ASB_APP_GAMING && g_smart_rt.app_pkg_cached[0] &&
             asb_bjank_capture_live(now);
    if (!on) { asb_bjank_disarm(); return; }

    uint64_t h = g_smart_rt.app_hash;
    if (h != g_bjank_hash) {
        asb_bjank_disarm();
        g_bjank_hash = h;
        snprintf(g_bjank_pkg, sizeof(g_bjank_pkg), "%s", g_smart_rt.app_pkg_cached);
    }

    struct stat st;
    if (stat(ASB_GFX_FILE, &st) == 0 && (long)st.st_mtime != g_bjank_gfx_seen &&
        g_bjank_probe_ts > 0 && (long)st.st_mtime >= g_bjank_probe_ts) {
        g_bjank_gfx_seen = (long)st.st_mtime;
        long fr = -1, jk = -1;
        if (asb_gfx_read_pkg(g_bjank_pkg, &fr, &jk) == 0) {
            if (g_bjank_frames >= 0 && fr >= g_bjank_frames && jk >= g_bjank_janky)
                asb_bjank_eval_window(g_bjank_pkg, fr - g_bjank_frames,
                                      jk - g_bjank_janky, now_ms);
            g_bjank_frames = fr;
            g_bjank_janky = jk;
        }
        /* Launcher swipes, notification shade and recents are rendered by SystemUI, not
         * necessarily by the foreground package. The field Battery capture that motivated
         * this guard had 29.5% SystemUI jank while several foreground apps were below 3%.
         * Evaluate SystemUI as an independent window from the SAME on-demand dump: never
         * add two apps' frames together, and never run another probe or worker. */
        if (strcmp(g_bjank_pkg, "com.android.systemui") != 0) {
            fr = -1; jk = -1;
            if (asb_gfx_read_pkg("com.android.systemui", &fr, &jk) == 0) {
                if (g_bjank_sys_frames >= 0 && fr >= g_bjank_sys_frames &&
                    jk >= g_bjank_sys_janky)
                    asb_bjank_eval_window("com.android.systemui",
                                          fr - g_bjank_sys_frames,
                                          jk - g_bjank_sys_janky, now_ms);
                g_bjank_sys_frames = fr;
                g_bjank_sys_janky = jk;
            }
        }
    }

    if (g_bjank_probe_ts == 0 || now - g_bjank_probe_ts >= ASB_BJANK_PROBE_S ||
        now < g_bjank_probe_ts) {
        const char *pk = g_bjank_pkg;
        int ok = pk[0] != 0;
        for (const char *c = pk; *c && ok; c++)
            ok = ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
                  (*c >= '0' && *c <= '9') || *c == '.' || *c == '_');
        g_bjank_probe_ts = now;
        if (!ok) return;
        g_bjank_probes++;
        /* fix271: the probe writes only the packages it is asked for, so SystemUI is named
         * here - without it the SystemUI window above never had a line to read. */
        char _bj_args[160];
        if (strcmp(pk, "com.android.systemui") != 0)
            snprintf(_bj_args, sizeof(_bj_args), "%s com.android.systemui", pk);
        else
            snprintf(_bj_args, sizeof(_bj_args), "%s", pk);
        asb_run_modscript("runtime/asb_gfx_probe.sh", _bj_args);
    }
}


static int g_rec_on_applied = 0;            /* fix184: the records' screen-on lean in force, x1000 */
static int g_smart_cold_guard = 0;          /* fix185: cold pack at low charge - battery rails */
static int g_smart_night_awake_on = 0;      /* the evening values replaced the night ones */
static int g_smart_night_awake_from = 0;    /* the night slot's own alpha before that */
static int g_smart_night_awake_to = 0;      /* the evening slot's alpha it took instead */
static unsigned long g_smart_night_awake_ticks = 0;

static void asb_apply_adaptive_budget_caps(asb_profile_caps_t *caps,
                                           const asb_metrics_t *m,
                                           const asb_fsm_t *fsm) {
    /* The prime is the highest slot that exists, not slot 2.
     *
     * SM8850 has two clusters (policy0/policy6), so slot 2 is empty and this read 0: the
     * first capture after this telemetry landed reported "prime ceiling: 0 kHz (profile
     * 0)". Same selection the FSM already uses for its own prime cap. */
    int _ps = (g_cpu_policy_ids[2] >= 0) ? 2 : ((g_cpu_policy_ids[1] >= 0) ? 1 : 0);
    g_cap_prime_base_khz = caps->cpu_max[_ps];
    snprintf(g_cap_prime_reason, sizeof(g_cap_prime_reason), "%s", "profile");
    int trim = asb_adaptive_budget_trim_pct(m, fsm);
    if (trim > 0 && trim < 100) {
        int keep = 100 - trim;
        for (int i = 0; i < 3; i++) {
            if (caps->cpu_max[i] > 0) caps->cpu_max[i] = caps->cpu_max[i] * keep / 100;
            if (caps->cpu_min[i] > 0 && caps->cpu_max[i] > 0 && caps->cpu_min[i] > caps->cpu_max[i])
                caps->cpu_min[i] = caps->cpu_max[i];
        }
        if (caps->gpu_max_pct > 0) {
            caps->gpu_max_pct = caps->gpu_max_pct * keep / 100;
            if (caps->gpu_max_pct < 10) caps->gpu_max_pct = 10;
            if (caps->gpu_min_pct > caps->gpu_max_pct) caps->gpu_min_pct = caps->gpu_max_pct;
        }
        if (caps->cpu_max[_ps] > 0 && caps->cpu_max[_ps] < g_cap_prime_base_khz)
            snprintf(g_cap_prime_reason, sizeof(g_cap_prime_reason),
                     "thermal_budget:%s", g_budget_reason);
    }
    {
        int _before_env = caps->cpu_max[_ps];
        asb_active_efficiency_apply_caps(caps, m, fsm);
        if (caps->cpu_max[_ps] > 0 && caps->cpu_max[_ps] < _before_env)
            snprintf(g_cap_prime_reason, sizeof(g_cap_prime_reason),
                     "%s", "efficiency_envelope");
    }
    asb_main_capacity_parity(caps, m, fsm, trim);
    g_cap_prime_eff_khz = caps->cpu_max[_ps];
}

static void write_state(const asb_fsm_t *fsm, const asb_metrics_t *m,
                        asb_prediction_t pred)
{
    static const char *profile_names[] = {"battery","balanced","performance","smart"};
    static const char *pred_names[] = {"unknown","idle","light","active"};

    FILE *f = fopen(STATE_FILE ".tmp", "w");
    if (!f) return;
    int rmax0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
    int rmax1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
    fprintf(f,
        "state=%s\nprofile=%s\n"
        "mA=%d\ngpu_pct=%d\ngpu_valid=%d\nload1=%.2f\n"
        "cpu_max=%d,%d,%d\ncpu_max_live=%d,%d\n"
        "thermal=%d\ncap_temp=%d\n"
        "headroom_pct=%d\nheadroom_valid=%d\nperf_cap_p0=%d\nperf_cap_p6=%d\n"
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
        m->gpu.load_valid,
        m->cpu.load1,
        /* cpu_max stays the REQUESTED cap - asb_reconcile.sh reads this field as its target.
         *
         * I briefly published the live sysfs value here instead, to stop the state file lying
         * about unsnapped numbers. That turned the reconcile loop into a no-op that could not
         * see drift, and worse: whatever the vendor had raised the cap to became the value the
         * shell then reasserted. A two-hour capture shows the result - 15 of 16 idle samples
         * owned by "shell", three parties writing, and 65 degC during light use.
         *
         * The live value is published separately as cpu_max_live below, so reporting is honest
         * without the enforcement loop losing its reference. */
        fsm->current_caps.cpu_max[0],
        fsm->current_caps.cpu_max[1],
        fsm->current_caps.cpu_max[2],
        /* What the CPU actually holds, for diagnostics only - kept in its own field so
           nothing that enforces caps can start following it by mistake. */
        sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0),
        sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0),
        fsm->thermal_cap,
        m->therm.cpu_max_c,
        m->therm.headroom_pct,
        m->therm.headroom_valid,
        m->therm.perf_cap_p0,
        m->therm.perf_cap_p6,
        pred_names[pred],
        m->misc.screen_on,
        m->bat.capacity_pct,
        fsm_elapsed_sec(fsm),
        g_msm_boost_active,
        (rmax0 > 0) ? (fsm->current_caps.cpu_max[0] - rmax0) : 0,
        (rmax1 > 0) ? (fsm->current_caps.cpu_max[1] - rmax1) : 0,
        sustained_reason_name(fsm->sustained_reason),
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
    /* requested/applied/failure/backoff counters from readback-aware native writers */
    writer_write_health_dump(f);
    fprintf(f, "shadow_mode=%d\nthermal_budget_enabled=%d\nthermal_budget_trim_pct=%d\n"
               "thermal_budget_base_trim_pct=%d\nthermal_budget_envelope_bonus_pct=%d\n"
               "thermal_budget_stage=%d\nthermal_budget_reason=%s\nthermal_budget_dwell_s=%d\n"
               "active_efficiency_active=%d\nactive_efficiency_tier=%s\n"
               "active_efficiency_reason=%s\nactive_efficiency_gpu_idle_bonus_pct=%d\n"
               "active_efficiency_bg_uclamp_moderate_delta=%d\n"
               "active_efficiency_bg_uclamp_severe_delta=%d\n",
            g_asb_cfg.shadow_mode, g_asb_cfg.thermal_budget_enable,
            g_budget_trim_pct, g_budget_base_trim_pct, g_budget_envelope_bonus_pct,
            g_budget_stage, g_budget_reason, g_asb_cfg.thermal_budget_dwell_s,
            g_active_efficiency.active, g_active_efficiency.tier,
            g_active_efficiency.reason, g_active_efficiency.gpu_idle_bonus_pct,
            g_active_efficiency.bg_uclamp_moderate_delta,
            g_active_efficiency.bg_uclamp_severe_delta);
    /* Break the overhead down by source, not just by total.
     *
     * events / timer_wakeups / cpu_ms answer "how much" and never "from what". A capture
     * showing 4.45 writer operations per FSM record was the clue that led to the state
     * oscillation, and finding it took manual correlation of three separate files. With
     * the sources counted separately the same question is one line of the report: a high
     * transition count means the ladder is chattering, a high write count with few
     * transitions means the reconcile loop is fighting something, and a high vendor count
     * means neither - the phone is simply not ours to drive right now. */
    /* Probe cache effectiveness - stage 1 observability from the lightening plan.
     *
     * Hits are forks that did not happen. Publishing the ratio is what makes the TTL
     * judgeable instead of merely plausible: a hit rate near zero would mean the cache is
     * in the wrong place again, which is exactly the failure it replaced. */
    /* Foreground app class, so consumers can tell a game from a busy GPU.
     *
     * The logkit labelled any sustained GPU streak as a gaming phase - video and maps
     * included - because GPU load was the only signal it had. The governor already knows
     * the answer from the package table; it just never published it. */
    fprintf(f, "app_hint=%d\n", g_smart_rt.app_hint);
    /* How long THIS governor has been running.
     *
     * Every counter above is cumulative since the governor started, and the report divides
     * them by system uptime - which is longer, because the governor starts after boot and
     * restarts on profile changes. A capture showed 29 timer wakeups per hour where the
     * 10-second idle tick alone accounts for 360: the counters were right and the divisor
     * was wrong, making the module look an order of magnitude cheaper than it is.
     *
     * Publishing the real denominator is the difference between a measurement and a
     * flattering number. */
    fprintf(f, "governor_uptime_s=%ld\n", (long)(time(NULL) - g_governor_start_ts));
    fprintf(f, "write_batches=%lu\n", g_stat_write_batches);
    fprintf(f, "noop_ticks=%lu\n", g_stat_noop_ticks);
    fprintf(f, "json_written=%lu\njson_skipped=%lu\n",
            g_stat_json_written, g_stat_json_skipped);
    fprintf(f, "probe_cache_hits=%lu\nprobe_cache_misses=%lu\n",
            g_stat_probe_hits, g_stat_probe_misses);
    /* Foreground answered from the top-app cgroup, no fork (fix124). */
    fprintf(f, "probe_topapp=%lu\nprobe_topapp_empty=%lu\nprobe_topapp_ambiguous=%lu\n",
            g_stat_probe_topapp, g_stat_probe_topapp_empty, g_stat_probe_topapp_ambig);
    fprintf(f, "zygisk_refresh_accepted=%lu\nzygisk_refresh_vetoed=%lu\n",
            g_zygisk_refresh_accepted, g_zygisk_refresh_vetoed);
    fprintf(f, "zygisk_launch_accepted=%lu\nzygisk_launch_vetoed=%lu\n"
               "unlock_cold_lifts=%lu\nunlock_cold_extends=%lu\n",
            g_zygisk_launch_accepted, g_zygisk_launch_vetoed,
            g_unlock_cold_lifts, g_unlock_cold_extends);
    fprintf(f, "governor_transitions=%lu\ngovernor_writes=%lu\n"
               "governor_readbacks=%lu\ngovernor_vendor_overrides=%lu\n",
            g_stat_transitions, g_stat_writes, g_stat_readbacks,
            g_stat_vendor_overrides);
    fprintf(f, "governor_event_wakeups=%lu\ngovernor_timer_wakeups=%lu\n"
               "governor_cpu_ms=%ld\n",
            g_governor_event_wakeups, g_governor_timer_wakeups,
            (long)(clock() * 1000 / CLOCKS_PER_SEC));
    long _active = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec + fsm->ses_time_sustained_sec;
    int _sus_pct = (_active > 0) ? (int)(fsm->ses_time_sustained_sec * 100 / _active) : 0;
    long _bat_tot = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec + fsm->bat_time_moderate_sec;
    int _idle_q = -1;
    if (_bat_tot > 30) {
        _idle_q = (int)(fsm->bat_time_deep_idle_sec * 100 / _bat_tot);
        int _wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
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
                (fsm->ses_intent >= 0 && fsm->ses_intent <= 6)
                    ? intent_names[fsm->ses_intent] : "unknown",
                g_pstats_per[_pidx].hot_fail_count,
                fsm->ses_degrade_at_age,
                g_pstats_per[_pidx].degrade_count);
    }
    fprintf(f, "plan_sensor=%d\nplan_hr=%d\nplan_ac=%d\nplan_deep=%d\nplan_thermal_div=%d\nplan_budget=%d\nplan_prearm=%d\nplan_used=%d\nplan_class=%d\nplan_sensor_budget=%d\nplan_sensor_used=%d\n",
            fsm->plan.sensor_tier, fsm->plan.allow_hr,
            fsm->plan.ac_eligible, fsm->plan.deep_sleep, fsm->plan.thermal_div,
            fsm->plan.ac_budget, fsm->plan.ac_prearm, fsm->plan.ac_used,
            fsm->plan.plan_class, fsm->plan.sensor_budget, fsm->plan.sensor_used);
    {
        long qleft = (g_user_quarantine_active && g_user_quarantine_until > 0)
                     ? (long)(g_user_quarantine_until - time(NULL)) : 0;
        if (qleft < 0) qleft = 0;
        fprintf(f, "quarantine=%d\nuser_id=%d\nquarantine_left=%ld\n",
                fsm->plan.quarantine, g_last_user_id, qleft);
    }
    /*
     * Warm-up flag.
     * Reported exactly that way.
     */
    {
        static int _warm_ticks = 0;
        if (_warm_ticks < 3) _warm_ticks++;
        fprintf(f, "state_warmup=%d\n", (_warm_ticks < 3) ? 1 : 0);
    }
    /* Smart Mode state fields */
    fprintf(f,
            "smart_mode=%d\nsmart_bucket_id=%d\nsmart_daypart=%d\nsmart_is_weekend=%d\n"
            "smart_confidence=%d\nsmart_alpha_battery=%d\nsmart_interactive_bonus=%d\n"
            "smart_sleep_override=%d\nsmart_thermal_veto=%d\nsmart_thermal_veto_reason=%d\n"
            "smart_app_hint=%d\nsmart_fallback_level=%d\n"
            /* Learned per-bucket history, exposed so the effect is observable. Without
             * these two the thermal lean is invisible: alpha moves and nothing says why. */
            "smart_bucket_temp_x10=%d\nsmart_bucket_drain_x10=%d\n"
            "smart_therm_warm_x10=%d\nsmart_therm_cool_x10=%d\n"
            "smart_media_guard_setting=%d\nsmart_media_guard_pkg_known=%d\n"
            "smart_media_guard_active=%d\nsmart_media_guard_age_s=%ld\n"
            "smart_media_guard_reason=%s\n",
            g_smart_rt.enabled,
            g_smart_rt.bucket_id,
            g_smart_rt.daypart,
            g_smart_rt.is_weekend,
            g_smart_rt.conf_x1000,
            g_smart_rt.alpha_battery_x1000,
            g_smart_rt.interactive_bonus_x1000,
            g_smart_rt.night_safe_override ? 1 : 0,
            g_smart_rt.thermal_veto ? 1 : 0,
            g_smart_rt.thermal_veto_reason,
            g_smart_rt.app_hint,
            g_smart_rt.fallback_level,
            g_smart_rt.bucket_temp_x10,
            g_smart_rt.bucket_drain_x10,
            g_smart_rt.therm_warm_x10,
            g_smart_rt.therm_cool_x10,
            g_asb_cfg.smart_media_guard,
            g_smart_media_pkg_known,
            g_smart_media_guard_active,
            g_smart_media_guard_since > 0 ? (long)(time(NULL) - g_smart_media_guard_since) : 0L,
            g_smart_media_guard_reason);
    fprintf(f, "camera_hold=%d\n", g_cam_guard_on ? 1 : 0);
    /* fix186: the Monitor's "Headroom" (the status JSON's headroom_real_pct) for the action
     * screen - the most limited cluster's live ceiling against its hardware maximum. */
    {
        int _hr = -1;
        int _l0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
        int _l1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
        if (g_cpu_slot_hwmax[0] > 0 && _l0 > 0) _hr = (int)((long)_l0 * 100 / g_cpu_slot_hwmax[0]);
        if (g_cpu_slot_hwmax[1] > 0 && _l1 > 0) {
            int _h1 = (int)((long)_l1 * 100 / g_cpu_slot_hwmax[1]);
            if (_hr < 0 || _h1 < _hr) _hr = _h1;
        }
        if (_hr > 100) _hr = 100;
        fprintf(f, "headroom_real_pct=%d\n", _hr);
    }
    /* fix188: what ASB holds in msm_performance/cpu_max_freq - 1 while it has a HEAVY/GAMING
     * registration there, and the per-slot values it last wrote. An OP15 asbdiag a minute
     * after boot read 0:2227200 .. 6:1632000 in that node, the prime held at 35 % with ASB's
     * own ceiling at 1862400, and nothing said whose numbers they were. */
    fprintf(f, "msm_asb_hold=%d\nmsm_asb=%d,%d,%d\n", g_msm_holding ? 1 : 0,
            g_asb_msm_written[0], g_asb_msm_written[1], g_asb_msm_written[2]);
    /* fix150: a night slot with the screen on took the evening's lean (alpha before it). */
    /* fix184: Smart records - the knobs in force and what is being measured. */
    fprintf(f, "rec_enabled=%d\nrec_counter=%d\nrec_on_offset=%d\nrec_off_scale=%d\n"
               "rec_block=%s\nrec_block_arm=%d\nrec_blocks_ok=%lu\nrec_blocks_rejected=%lu\n"
               "microwake_active=%d\nmicrowake_holds=%lu\nmicrowake_learned=%u\n"
               "smooth_lean=%d\nsmooth_testing=%d\nsmooth_probes=%lu\nsmooth_windows=%lu\n"
               "smart_cold_guard=%d\nses_climate=%d\nunplug_age_s=%ld\n",
            g_asb_cfg.smart_records, g_rec_cc_state, g_rec_on_applied, g_rec_off_scale,
            g_rec_blk.active ? g_rec_ctx_names[g_rec_blk.ctx] : "-",
            g_rec_blk.active ? asb_rec_arm_value(g_rec_blk.ctx, g_rec_blk.arm) : 0,
            g_rec_blocks_ok, g_rec_blocks_rejected,
            g_mw_active, g_mw_holds, g_rec.mw.total,
            g_smooth_lean, g_rec_smooth_testing, g_smooth_probes, g_smooth_windows,
            g_smart_cold_guard, g_ses_climate_last, g_unplug_age_s);
    fprintf(f, "smooth_log_status=%s\nsmooth_log_accepted=%lu\nsmooth_log_rejected=%lu\n"
               "smooth_log_suppressed=%lu\nsmooth_log_checks=%lu\nsmooth_log_reads=%lu\n"
               "smooth_log_changes=%lu\nsmooth_log_unchanged=%lu\n"
               "smooth_log_last_epoch=%ld\nsmooth_log_last_jank_x1000=%ld\n"
               "smooth_log_capture=%s\nsmooth_log_seq=%lu\n",
            g_smooth_log_status, g_smooth_log_accepted, g_smooth_log_rejected, g_smooth_log_suppressed,
            g_smooth_log_checks, g_smooth_log_reads, g_smooth_log_changes, g_smooth_log_unchanged,
            g_smooth_log_last_epoch, g_smooth_log_last_jank, g_smooth_log_capture, g_smooth_log_seq);
    /* fix186: the records' situation in force now and where it stands, for the WebUI's
     * Basis tile ("own slot" alone said nothing once the learner had history). */
    {
        const int _k = g_rec_kctx;
        const asb_rec_ctx_t *_rc = (_k >= 0 && _k < ASB_REC_CTX_N) ? &g_rec.ctx[_k] : NULL;
        double _g = _rc ? (1.0 - (double)_rc->gain_total) * 1000.0 : 0.0;
        fprintf(f, "rec_ctx=%s\nrec_ctx_status=%s\nrec_ctx_best=%d\nrec_ctx_test=%d\nrec_ctx_trial=%d\n"
                   "rec_ctx_pairs=%u\nrec_ctx_need=%d\nrec_ctx_max=%d\nrec_ctx_n=%u\nrec_ctx_gain_x10=%d\n",
                _rc ? g_rec_ctx_names[_k] : "-",
                _rc ? asb_rec_status_name(_rc) : "-",
                _rc ? asb_rec_arm_value(_k, _rc->champion) : 0,
                _rc ? asb_rec_arm_value(_k, _rc->challenger) : 0,
                (_rc && g_rec_blk.active && g_rec_blk.ctx == _k && g_rec_blk.slot == 1) ? 1 : 0,
                _rc ? _rc->pairs : 0u,
                (_rc && asb_rec_is_off(_k)) ? ASB_REC_OFF_NMIN : ASB_REC_ON_NMIN,
                (_rc && asb_rec_is_off(_k)) ? ASB_REC_OFF_NMAX : ASB_REC_ON_NMAX,
                _rc ? _rc->trial[0].n : 0u,
                (int)(_g + (_g >= 0 ? 0.5 : -0.5)));
    }
    fprintf(f, "smart_night_awake=%d\nsmart_night_awake_from=%d\nsmart_night_awake_to=%d\n"
               "smart_night_awake_ticks=%lu\n",
            g_smart_night_awake_on, g_smart_night_awake_from, g_smart_night_awake_to,
            g_smart_night_awake_ticks);
    fprintf(f, "smart_lowbat_override=%d\nsmart_thermal_trend=%d\nsmart_trend_slope=%d\n",
            g_smart_rt.low_battery_override ? 1 : 0,
            g_smart_rt.thermal_trend_bump,
            g_smart_trend_slope_mc_min);
    /*
     * Cumulative Smart session total, same number the WebUI shows from learner_state.json
     * (smart_sessions.total).
     */
    /* Published so the report can say "the phone is not sleeping" instead of only
     * showing a drain figure and leaving the user to guess why. */
    fprintf(f, "awake_pct_screenoff=%d\nawake_window_min=%ld\n",
            g_awake_pct, g_awake_win_boot_ms / 60000L);
    fprintf(f, "offdrain_pctph_x100=%d\noffdrain_windows=%d\noffdrain_media_skipped=%d\n",
            g_offdrain_x100, g_offdrain_n, g_offdrain_media_skipped);
    /* fix189: the same measurement per profile, "name:rate:windows" (rate -1 = none yet). */
    fprintf(f, "offdrain_by_profile=");
    for (int _i = 0; _i < ASB_OFFDRAIN_NPROF; _i++)
        fprintf(f, "%s%s:%d:%d", _i ? "," : "", g_offdrain_p_name[_i], g_offdrain_p_x100[_i], g_offdrain_p_n[_i]);
    fprintf(f, "\n");
    fprintf(f, "smart_sessions_total=%d\nsmart_last_confidence=%d\n",
            g_smart_sessions_total, g_smart_last_confidence);
    {
        long live_x10 = 0;
        int _live_stale = 0;
        if (g_smart_drain_on_sec >= 300 && g_smart_drain_drop_x100 > 0) {
            live_x10 = (g_smart_drain_drop_x100 * 360L) / g_smart_drain_on_sec;
        } else if (g_drain_roll_sec >= 300 && g_drain_roll_x100 > 0) {
            /* The rolling figure, when the current session is too young to have one of its
             * own. This is the case almost all the time - sessions restart on every state
             * change - and it is what stops the banner from freezing on a reading that may
             * be hours old. */
            live_x10 = (g_drain_roll_x100 * 360L) / g_drain_roll_sec;
        }
        /* Halve the rolling window every two hours: the number should follow how the phone
         * is behaving now, not average the whole day into a figure that never moves. */
        if (g_drain_roll_sec >= 7200) {
            g_drain_roll_sec  /= 2;
            g_drain_roll_x100 /= 2;
        }
        /* fix94: this used to be an `else` of the halving above, so whenever the rolling
         * window was under two hours the PREVIOUS session's rate replaced the live one - even
         * mid-session with 31 minutes of real data. An OP15 went 53 -> 44 % in an hour while
         * the banner said 3.3 %/h and the WebUI forecast "13h 56m · measured". The old rate
         * is only a fallback for when nothing current exists. */
        if (live_x10 <= 0 && g_smart_drain_last_x10 > 0 &&
                   (time(NULL) - g_smart_drain_last_ts) < ASB_DRAIN_STALE_SEC) {
            /* Nothing measurable in the current session yet - report the previous one
             * rather than nothing. Expires after a few hours: a rate from this morning
             * says little about this evening. */
            live_x10 = g_smart_drain_last_x10;
            _live_stale = 1;
        }
        int hot = (asb_smart_appheat_score(g_smart_rt.app_hash, time(NULL))
                   >= ASB_SMART_APPHEAT_HOT_SCORE);
        int known = 0;
        for (int i = 0; i < ASB_SMART_APPHEAT_N; i++)
            if (g_smart_appheat.entries[i].hash != 0) known++;
        long _pub_win = (g_smart_drain_on_sec >= 300) ? g_smart_drain_on_sec : g_drain_roll_sec;
        /* A carried-over rate has no window of its own: publishing the current one next to
         * it let both screens label an old session's figure "measured over the last N min". */
        if (_live_stale) _pub_win = 0;
        /* P0-4: confidence travels with the measurement.
         *
         * A %/h number is only as good as the window it came from. A short window, a SOC
         * that moved by a single integer step, or a charge transition mid-window all
         * produce a figure that looks authoritative and is not - and the report was
         * presenting "4% in 15 minutes" as a definitive ASB drain claim regardless.
         *
         * high   = long window, real SOC movement, no charge transition
         * medium = usable but short, or derived from a smoothed gauge
         * low    = single-step SOC or very short window; show as estimate
         * none   = no valid window at all
         */
        int _bconf;
        const char *_breason;
        if (m->bat.charging) {
            _bconf = 0; _breason = "charging sample excluded from drain estimate";
        } else if (_pub_win < 300) {
            _bconf = 0; _breason = "window under 5 min";
        } else if (g_smart_drain_drop_x100 <= 100) {
            _bconf = 1; _breason = "SOC moved one integer step or less";
        } else if (_pub_win < 900) {
            _bconf = 2; _breason = "short but usable window";
        } else {
            _bconf = 3; _breason = "settled window with real SOC movement";
        }
        fprintf(f, "smart_drain_window_s=%ld\nsmart_drain_pctph_x10=%ld\n"
                   "smart_app_hot=%d\nsmart_appheat_n=%d\n"
                   "battery_window_confidence=%d\nbattery_window_reason=\"%s\"\n"
                   "battery_current_source=\"%s\"\n",
                _pub_win, live_x10, hot, known,
                _bconf, _breason, g_batt_current_source);
        fprintf(f, "smart_budget_sev=%d\nsmart_budget_pred_h_x10=%d\n"
                   "smart_drain_ewma_x10=%d\n"
                   "smart_quality_last=%d\nsmart_quality_avg=%d\n"
                   "smart_app_drain=%d\n"
                   "smart_battery_lean=%d\n"
                   "anomaly_code=%d\nanomaly_count_1h=%d\n",
                g_smart_rt.budget_severity, g_smart_rt.budget_pred_h_x10,
                g_smart_drain_rate_ewma_x10,
                g_smart_last_quality, g_smart_quality_ewma,
                asb_smart_appheat_drain(g_smart_rt.app_hash, time(NULL)),
                g_smart_battery_lean_pub,
                g_anom_code, g_anom_count_1h);
        fprintf(f, "smart_q_bat=%d\nsmart_q_heat=%d\nsmart_q_stab=%d\n"
                   "smart_q_vendor=%d\nsmart_q_fail=%d\nsmart_budget_src=%d\n",
                g_smart_q_bat, g_smart_q_heat, g_smart_q_stab,
                g_smart_q_vendor, g_smart_q_fail, g_smart_budget_src);
        /* One screen-time forecast for every screen (fix127), from the ACTUAL drain first
         * (fix128).
         *
         * fix127 published the battery budget's forecast - the smoothed drain of recent
         * sessions, or this hour's history before a session was measured - so every screen
         * agreed. But it was not what the phone was doing: an OP15 Monitor read "usual this
         * hour 7.9 %/h" above "2 h 23 m · recent drain 17.1 %/h", and its owner asked the
         * obvious question - how is the battery doing NOW. The measured screen-on drain
         * (the battery level falling over the last ten minutes or more, with a real SOC
         * movement behind it) leads now, as "now"; the budget's rates are the fallback, as
         * "recent" or "slot", and the screens call those an estimate. The budget itself is
         * unchanged. "none" while charging or with nothing to go on. */
        {
            int _fr = 0;
            const char *_fb = "none";
            if (m && !m->bat.charging) {
                if (!_live_stale && live_x10 > 0 && _pub_win >= 600 && _bconf >= 2) {
                    _fr = (int)live_x10;
                    _fb = "now";
                } else if (g_smart_rt.enabled && g_smart_rt.budget_pred_h_x10 > 0 &&
                           g_smart_budget_rate_x10 > 0) {
                    _fr = g_smart_budget_rate_x10;
                    _fb = g_smart_budget_src ? "slot" : "recent";
                }
            }
            fprintf(f, "forecast_rate_x10=%d\nforecast_basis=%s\n", _fr, _fb);
        }
        /* The live control-sensor reading, for consumers outside the governor.
         *
         * Peer counts, rejected sources and confidence are all published; the temperature
         * they describe was not. Anything outside this process that wants to react to heat -
         * the audio gain backoff, a log, a future tweak - had no number to read and would
         * have to pick a thermal zone for itself, which is exactly the guessing this file
         * spent months eliminating. */
        fprintf(f, "cpu_max_c=%d\n", m ? m->therm.cpu_max_c : 0);
        /* Promotions of the control sensor to full confidence after boot (fix129). */
        fprintf(f, "thermal_conf_promotions=%lu\n", g_thermal_conf_promotions);
        fprintf(f, "smart_boot_settle=%d\nstartup_quarantined=%lu\n"
                   "thermal_control_source=\"%s\"\nthermal_control_zone=%d\n"
                   "thermal_source_confidence=%d\nthermal_rejected_type=\"%s\"\n"
                   "thermal_rejected_raw=%d\nthermal_peer_hi=%d\nthermal_peer_lo=%d\n"
                   "thermal_peer_n=%d\nthermal_consensus=\"%s\"\n"
                   /* Same file the diagnostic reads. This was published only into the
                    * status JSON, so the report could never see it - the identical
                    * producer/consumer split that hid the consensus fields before. */
                   "freq_table_n=\"%d,%d,%d\"\n"
                   /* What the writer was ASKED for, next to what the node holds.
                    * The report shows the live tiers; without the request beside
                    * them a tier stuck at stock is indistinguishable from a tier
                    * the FSM deliberately left alone, and that ambiguity has cost
                    * several rounds of guessing already. */
                   "uclamp_want=\"%d,%d\"\n"
                   /* What the LAST banked session actually carried.
                    *
                    * The report shows the bucket average, and a capture had it at 30 C
                    * while the phase ledger averaged 46 C - so the learner concluded "this
                    * bucket runs cool" and raised the ceiling on a phone that was warm.
                    * The average alone cannot say whether the sessions arrive cold or the
                    * averaging is wrong, and guessing between those cost three rounds on
                    * the uclamp problem already. */
                   "ses_last_temp=%d\nses_last_dur=%d\nses_last_reason=\"%s\"\n"
                   /* Engine version for the WebUI badge. The card showed the raw
                    * alpha, which is an internal weight nobody outside this file
                    * can interpret; the schema version is what actually changes
                    * when the learner is reworked. */
                   "smart_engine_ver=%d\n",
                g_smart_boot_settle, g_startup_quarantined,
                g_thermal_cpu_type[0] ? g_thermal_cpu_type : "unknown", g_thermal_cpu_zone,
                g_thermal_source_confidence, g_thermal_rejected_type, g_thermal_rejected_raw,
                g_thermal_peer_hi, g_thermal_peer_lo, g_thermal_peer_n,
                g_thermal_consensus_note,
                writer_freq_table_len(0), writer_freq_table_len(1), writer_freq_table_len(2),
                writer_last_uclamp_top(), writer_last_uclamp_bg(),
                g_ses_last_temp, g_ses_last_dur, g_ses_last_reason,
                ASB_SMART_VER);
        fprintf(f, "cool_gaming=%d\n", g_asb_cfg.cool_gaming);
        fprintf(f, "cool_gaming_level=%d\n", g_smart_cool_gaming_lvl);
        fprintf(f, "game_charging=%d\ngame_bat_temp_peak_dc=%d\n"
                   "game_cpu_max_peak_c=%d\ngame_cool_lvl_peak=%d\n",
                g_game_charging_seen, g_game_bat_temp_peak_dc,
                g_game_cpu_max_peak_c, g_game_cool_lvl_peak);
        {
            /* While grading is suspended (charging or the night/sleep override),
               don't publish a stale accuracy figure — it reads as a failed
               forecast when really the loop is just paused. Emit the no-data
               sentinel so the report card shows nothing instead of 0/100. */
            int _acc_pub = g_budget_acc_score;
            int _err_pub = g_budget_acc_error_pct;
            if (g_smart_rt.night_safe_override) { _acc_pub = -1; _err_pub = -1; }
            fprintf(f, "budget_accuracy_score=%d\nbudget_error_pct=%d\n",
                    _acc_pub, _err_pub);
        }
        fprintf(f, "budget_bias_dir=%d\nbudget_bias_streak=%d\n",
                g_budget_bias_dir, g_budget_bias_streak);
        fprintf(f, "night_samples_accepted=%d\nnight_samples_rejected=%d\n"
                   "night_reject_reason=%d\n",
                g_night_samples_accepted, g_night_samples_rejected,
                g_night_reject_reason);
        fprintf(f, "charging=%d\nsmart_charge_assist=%d\nsmart_charge_cool=%d\n"
                   "smart_charge_class=%d\nsmart_charge_w_x10=%d\n",
                m->bat.charging,
                g_smart_rt.charge_assist, g_smart_rt.charge_cool_guard,
                g_smart_rt.charge_power_class, g_smart_rt.charge_power_w_x10);
        fprintf(f, "night_auto=%d\nnight_auto_ready=%d\nnight_window_active=%d\n"
                   "night_sleep_min=%d\nnight_wake_min=%d\nnight_samples=%d\n",
                g_asb_cfg.night_quiet_auto,
                asb_night_window_ready(),
                asb_night_window_active(time(NULL)),
                g_night_sleep_min, g_night_wake_min, g_night_samples);
        fprintf(f, "write_attempts=%ld\nwrite_skipped_detente=%ld\n"
                   "write_skipped_backoff=%ld\nbudget_spike_bump=%d\n",
                g_write_attempts, g_write_skipped_detente,
                g_write_skipped_backoff, g_drain_spike_bump);

        /* Per-node write breakdown and vendor-contention state.
         *
         * write_attempts says the writer is busy, not with what; and the passive mode -
         * stop reasserting after 20 vendor clamps in the slow window - exists but was
         * only published in JSON. A capture with cap_owner=vendor at 71% cannot be read
         * without knowing whether ASB stepped back deliberately or is still fighting.
         *
         * An audit asks for a 40-60% cut in writes per hour. Cutting blind is how the
         * previous attempt produced a filter that filtered nothing. */
        fprintf(f, "cap_vendor_passive=%d\ncap_vendor_slow_clamps=%d\n",
                g_cap_vendor_passive, g_cap_slow_vendor_clamps);
        /* Which source answered the screen question, and what it said.
         *
         * A capture had the active tick at zero across an hour of screen-ON use: the
         * module ran the entire session on the 10 s idle cadence. "screen_on=?" in the
         * report gave nothing to work with - this names the path that answered. */
        fprintf(f, "screen_src=%d\n", metrics_screen_src());
        /* Android's display state (1 off, 2 on, 3/4 doze, -1 unavailable) and the seconds
         * a lit always-on display was counted as screen-off (fix115). */
        fprintf(f, "display_state=%d\nscreen_aod_s=%ld\n", g_display_state, g_scr_aod_s);
        fprintf(f, "screen_on_detect=\"uevent:%lu,recheck:%lu,tick:%lu,display:%lu\"\n",
                g_scr_on_by_uevent, g_scr_on_by_recheck, g_scr_on_by_tick, g_scr_on_by_display);
        fprintf(f, "screen_off_detect=\"uevent:%lu,display:%lu,tick:%lu\"\n",
                g_scr_off_by_uevent, g_scr_off_by_display, g_scr_off_by_tick);
        fprintf(f, "display_waiter=%d\ndisplay_state_events=%lu\nscreen_on_resume_skipped=%lu\n",
                g_disp_waiter_up, g_disp_prop_events, g_scr_resume_skipped);
        /* Screen-on touch watch (fix117): device found, touches that started after a calm
         * spell, and how many of them lifted light idle on the spot. */
        fprintf(f, "touch_watch=%d\ntouch_starts=%lu\ntouch_lifts=%lu\n",
                g_touch_fd >= 0 ? 1 : 0, g_touch_starts, g_touch_lifts);
        fprintf(f, "screen_on_single_rechecks=%lu\nscreen_on_resume_chains=%lu\nscreen_on_tick_late_max_s=%ld\n",
                g_scr_recheck_single, g_scr_resume_chains, g_scr_tick_late_max_s);
        fprintf(f, "screen_on_key_devices=%d\nscreen_on_key_hints=%lu\n", g_wake_key_n, g_wake_key_hints);
        fprintf(f, "light_idle_pin_escalations=%lu\n", g_li_pin_escalations);
        /* Raw single-sample session peak next to the smoothed one the learner uses (fix110),
         * so a report shows how much of the "peak" was a one-tick spike. */
        fprintf(f, "ses_max_temp_raw=%d\nses_max_temp_smooth=%d\n",
                fsm->ses_max_temp, fsm->ses_max_temp_sm);
        fprintf(f, "mem_stall_now=%d\nmem_stall_entries=%lu\n",
                g_mem_stall_now, g_mem_stall_entries);

        /* Wakeups by source, same shape as the write breakdown below. */
        fprintf(f, "wake_by_src=\"");
        for (int _w = 0, _wf = 1; _w < ASB_WAKE_SRC_COUNT; _w++) {
            if (!g_wake_by_src[_w]) continue;
            fprintf(f, "%s%s:%lu", _wf ? "" : ",", g_wake_src_name[_w], g_wake_by_src[_w]);
            _wf = 0;
        }
        fprintf(f, "\"\n");

        /* Uevents by subsystem: governor_event_wakeups counts the epoll wakes, this
         * names what filled them. */
        fprintf(f, "uevent_events_total=%lu\n", g_uev_events_total);
        fprintf(f, "uevent_parked=%d\nuevent_parks=%lu\nuevent_dropped_while_parked=%lu\n",
                g_uev_parked, g_uev_parks, g_uev_unpark_dropped);
        fprintf(f, "uevent_by_subsys=\"");
        for (int _u = 0, _uf = 1; _u < ASB_UEV_COUNT; _u++) {
            if (!g_uev_by_src[_u]) continue;
            fprintf(f, "%s%s:%lu", _uf ? "" : ",", g_uev_src_name[_u], g_uev_by_src[_u]);
            _uf = 0;
        }
        fprintf(f, "\"\n");

        fprintf(f, "write_by_node=\"");
        for (int _n = 0, _first = 1; _n < ASB_WRITE_NODE_COUNT; _n++) {
            unsigned _c = writer_node_writes((asb_write_node_t)_n);
            if (!_c) continue;
            fprintf(f, "%s%s:%u", _first ? "" : ",",
                    writer_write_node_name((asb_write_node_t)_n), _c);
            _first = 0;
        }
        fprintf(f, "\"\n");
        fprintf(f, "walt_window_owner=%s\nwalt_window_rom=%d\n",
                g_ravg_rom_owned ? "rom" : "asb", g_ravg_rom_seen);
        fprintf(f, "cap_sleep_detente=%d\ncap_detente_skipped=%ld\n"
                   "build_flavor=%s\nbat_cur_unit=%d\n",
                g_cap_detente_active, g_cap_detente_skipped,
                "unified",
                g_batt_cur_unit);
    }
    /* Debug build only: include plaintext pkg if cached */
#if ASB_DEBUG_BUILD
    if (g_asb_cfg.smart_pkg_plaintext || ASB_DEBUG_BUILD) {
        fprintf(f, "smart_pkg=%s\n",
                g_smart_rt.app_pkg_cached[0] ? g_smart_rt.app_pkg_cached : "");
    }
#endif
    fprintf(f, "smart_pkg_hash=%016llx\n",
            (unsigned long long)g_smart_rt.app_hash);
    /* — Foreground package detection observability */
    fprintf(f, "smart_pkg_detect_ok=%d\nsmart_pkg_source=%d\nsmart_pkg_status=%d\n",
            g_pkg_detect_ok, g_pkg_detect_source, g_pkg_detect_status);
    /* — Cap ownership */
    /* Published separately from the short holddown: "we paused for three seconds" and
       "the vendor owns this cap and we have stopped writing" look identical otherwise, and
       only the second one explains an hour of asb 0% in the ownership trace. */
    /* What ASB asked for, what the hardware actually has, and whether we may retry.
     *
     * cap_owner says WHO won; it does not say by how much, so a log cannot distinguish
     * "vendor trimmed us by 5%" from "vendor ignored us completely". The audit asks for
     * the three states separately, and they are the difference between a report that
     * describes a disagreement and one that only notes it happened.
     *
     * Slot 0 and the prime slot: enough to see the shape without three more columns. */
    /* Publish the SNAPPED request, the same value the writer sends.
     *
     * current_caps holds the interpolated ceiling before cpu_snap_freq rounds it to a
     * real OPP step. Reporting that against the snapped effective value guarantees a
     * mismatch on every tick: a field diag reads "prime 1500174 -> 1132800 (hardware is
     * stricter)" where 1500174 is not a frequency this SoC has at all, so the gap is
     * partly our own rounding rather than the vendor.
     *
     * Snapping here makes desired-versus-effective answer the question it is meant to:
     * did our request survive, or did something else overrule it. */
    /* Publish the slot -> policy map this governor actually uses.
     *
     * asbdiag reconstructed it with its own rule - first policy slot0, last policy slot2 -
     * which disagrees with cpu_topology_discover for two clusters: there the second
     * policy is slot1 and slot2 is empty. On a two-cluster phone the report printed
     * "policy6 -> slot2 (prime)" while every rail, cap and desired/effective value used
     * slot1 for the prime - so the one line meant to explain the numbers contradicted
     * them. -1 marks an empty slot. */
    fprintf(f, "slot_policy_ids=%d,%d,%d\n",
            g_cpu_policy_ids[0], g_cpu_policy_ids[1], g_cpu_policy_ids[2]);
    /* fix181: how many quick SUSTAINED re-entries the current dwell is doubled for, and
     * how long re-entry is still blocked after the last exit. */
    {
        long _sre = (fsm->sustained_reentry_until > 0) ? (long)(fsm->sustained_reentry_until - time(NULL)) : 0;
        fprintf(f, "sustained_repeat=%d\nsustained_reentry_left_s=%ld\n", fsm->sus_repeat, _sre > 0 ? _sre : 0L);
    }
    {
        int _d0 = writer_slot_ceiling(0, fsm->current_caps.cpu_max[0], fsm->thermal_cap);
        if (g_parity_main_khz > _d0) _d0 = g_parity_main_khz;   /* fix130: the level kept with the prime */
        fprintf(f, "desired_cpu_max0=%d\ndesired_cpu_maxp=%d\n", _d0,
                writer_slot_ceiling(1, fsm->current_caps.cpu_max[1], fsm->thermal_cap));
    }
    /* Published through cpu_floor_ceiling as well: "desired" must be what the writer really
     * sends. Before, it was the raw FSM wish, so whenever that sat under the race-to-idle
     * guard the report read "hardware above the request" - the guard's own 1747200 against
     * a wish of 1017600 - and that was taken for a vendor holding the prime up. */
    /* Index 1 here, not 2: the effective side reads tick_scaling_max(1), which is the
       second POLICY. Slot 2 is the prime cluster in the rail vocabulary, and mixing the
       two would compare different clusters - I made exactly that mistake once. */
    fprintf(f, "effective_cpu_max0=%d\neffective_cpu_maxp=%d\n",
            tick_scaling_max(0), tick_scaling_max(1));
    /* The prime itself, and what ASB last wrote (fix126).
     *
     * "maxp" above is slot 1: the prime on a 2-cluster SoC, a middle cluster on a 1+3+2+1
     * part (OP12, Ace 5). The full-day capture compared that slot's request with the LAST
     * policy's live ceiling, so on those phones a mid-core number judged the prime.
     *
     * requested_* is the ceiling the writer sent and kept - after the thermal budget and the
     * race-to-idle floor - so a capture can split "lower than the profile rail" into ASB's
     * own trim (live == requested) and somebody else's ceiling (live < requested). desired_*
     * is the rail before the budget and cannot tell those apart. */
    {
        int _pslot = (g_cpu_policy_ids[2] >= 0) ? 2 : 1;
        fprintf(f, "prime_slot=%d\nprime_policy_id=%d\n", _pslot, g_cpu_policy_ids[_pslot]);
        fprintf(f, "desired_cpu_max_prime=%d\neffective_cpu_max_prime=%d\n",
                writer_slot_ceiling(_pslot, fsm->current_caps.cpu_max[_pslot], fsm->thermal_cap),
                tick_scaling_max(_pslot));
        fprintf(f, "requested_cpu_max0=%d\nrequested_cpu_max_prime=%d\n",
                g_fsm_slot_req_khz[0], g_fsm_slot_req_khz[_pslot]);
        /* fix182: who writes the CPU ceilings right now, and - in a manual profile - the
         * values the shell wrote. desired_* above is the FSM's rail, which the writer does
         * not send in battery/balanced; a capture compared live ceilings against it and
         * counted the profile's own cap as a throttle in every sample. 0 = not known. */
        fprintf(f, "cap_writer=%s\nshell_cpu_max0=%d\nshell_cpu_max_prime=%d\n",
                asb_manual_shell_owns_caps(fsm) ? "shell" : "asb",
                asb_shell_cap_khz(fsm, 0), asb_shell_cap_khz(fsm, _pslot));
    }
    fprintf(f, "reassert_eligible=%d\n", asb_cap_writes_should_back_off() ? 0 : 1);
    fprintf(f, "cap_vendor_passive=%d\n", g_cap_vendor_passive);
    /* Screen-off cooldown clamp, so a night capture can show whether it engaged.
     *
     * The clamp only fires on a phone that fell asleep warm, which is exactly the night
     * nobody plans to have - so it cannot be triggered on demand, and without this line
     * the only evidence would be an absence of heat, which proves nothing either way. */
    fprintf(f, "thermal_cooldown=%d\ntherm_keepalive_reads=%lu\ntemp_read_epoch=%ld\n",
            fsm->thermal_cooldown, g_therm_keepalive_reads, (long)g_last_thermal_read_ts);
    fprintf(f, "prime_escape=%d\nprime_escape_mid=%d\nprime_escape_count=%lu\n",
            fsm->prime_escape, fsm->prime_escape_mid, fsm->prime_escape_count);
    fprintf(f, "main_parity_khz=%d\nmain_parity_lifts=%lu\nmain_parity_capacity=\"%d,%d\"\n",
            g_parity_main_khz, g_parity_lifts, g_parity_cap0, g_parity_cap1);
    fprintf(f, "main_parity_near=%d\nmain_parity_over_khz=%d\n", g_parity_near, g_parity_over_khz);
    fprintf(f, "main_parity_cooling=%d\nmain_parity_cool_lifts=%lu\n", g_parity_cooling, g_parity_cool_lifts);
    /* Unlock lift (fix150): in force on the last write, lifts started (wakes and first
     * touches), wakes that did not lift and why the last one did not. */
    fprintf(f, "unlock_lift=%d\nunlock_lifts=%lu\nunlock_lift_skips=%lu\nunlock_lift_skip_why=%s\n",
            g_unlock_applied, g_unlock_lifts, g_unlock_skips, g_unlock_skip_why);
    fprintf(f, "unlock_level_khz=%d\nunlock_levels=%lu\n", g_unlock_level_khz, g_unlock_levels);
    {
        int _bk, _br, _bt;
        asb_bhold_counts(&_bk, &_br, &_bt);
        fprintf(f, "battery_hold=%d\nbattery_hold_kept=%d\nbattery_hold_released=%d\nbattery_hold_testing=%d\n"
                   "battery_hold_probes=%lu\nbattery_hold_windows=%lu\n",
                g_bhold_now, _bk, _br, _bt, g_bhold_probes, g_bhold_windows);
    }
    {
        long _pe_t = g_prime_escape_total_ms;
        if (g_prime_escape_since_ms > 0) _pe_t += asb_clock_ms(CLOCK_BOOTTIME) - g_prime_escape_since_ms;
        fprintf(f, "prime_escape_total_s=%ld\n", _pe_t / 1000L);
        /* Bursts the gates kept shut (fix126): die within 3 C of the mark that would end the
         * burst at once, and spells pinned at a lower ceiling ASB does not hold. */
        fprintf(f, "prime_escape_skip_warm=%lu\nprime_escape_skip_foreign=%lu\n",
                g_esc_skip_warm, g_esc_skip_foreign);
    }
    /* The suspend-aware companion to load1: how much of the last tick the CPU was up. */
    fprintf(f, "awake_tick_pct=%d\n", m->cpu.awake_tick_pct);
    fprintf(f, "current_scale_x100=%d\ncurrent_scale_windows=%d\n", g_curscale_x100, g_curscale_n);
    fprintf(f, "device_bounds_applied=%d\ndevice_bounds_status=%s\ndevice_bounds_reason=%s\n",
            g_device_bounds_applied, g_device_bounds_status, g_device_bounds_reason);
    fprintf(f, "surface_source=%s\n", g_surface_from_skin ? "skin" :
               (g_thermal_surface_zone >= 0 ? "zone" : (g_thermal_board_zone >= 0 ? "board" : "none")));
    fprintf(f, "vendor_ceiling_ticks=%lu\nvendor_ceiling_used_ticks=%lu\nown_ceiling_ticks=%lu\n",
            g_leak_ceiling_ticks, g_leak_used_ticks, g_own_ceiling_ticks);
    fprintf(f, "trend_trim_held_cool=%lu\n", g_trend_held_cool);
    fprintf(f, "comfort_trim_burst_skips=%lu\n", g_comfort_burst_skips);
    fprintf(f, "fg_guard_fixes=%lu\n", g_fg_fix_total);
    fprintf(f, "cap_owner=%s\ncap_owner_since=%ld\ncap_vendor_holddown=%d\n",
            asb_cap_owner_name(g_cap_owner_eff),
            (long)g_cap_owner_since,
            asb_cap_writes_should_back_off());
    /* What lowered the prime ceiling, and from what to what (kHz). Its own fprintf so the
     * field list and the argument list cannot drift apart. */
    fprintf(f, "cap_prime_reason=%s\ncap_prime_base_khz=%d\ncap_prime_eff_khz=%d\n",
            g_cap_prime_reason, g_cap_prime_base_khz, g_cap_prime_eff_khz);
    /* Whether governor.conf was accepted, at boot or at the last reload (fix165): 0, or the
     * loader's error code while the governor runs its last good or built-in values. */
    fprintf(f, "cfg_load_rc=%d\ncfg_load_ts=%ld\n", g_cfg_load_rc, (long)g_cfg_load_ts);
    /* Vendor clamp counters for WebUI Live page */
    fprintf(f, "vendor_clamp_1h=%lu\nvendor_clamp_total=%lu\nvendor_raised_total=%lu\n",
            v44_clamp_1h_now(), g_v44_clamp_total, g_v44_raised_total);
    /* Drop the durability barrier when the screen is off and nothing changed.
     *
     * This file is read by the WebUI and by asbdiag, both on demand and both while the
     * user is awake and looking. Nobody reads it at 3am, and an fsync per tick through the
     * night is a flush to storage to record that nothing happened.
     *
     * The rename still publishes every tick, so a reader always sees current data - only
     * the barrier is skipped, and only screen-off. A crash then loses at most the last
     * few seconds of a file that is rebuilt from live state on the next tick anyway.
     * Screen-on behaviour is unchanged. */
    fflush(f);
    if (m && m->misc.screen_on) fsync(fileno(f));
    fclose(f);
    rename(STATE_FILE ".tmp", STATE_FILE);
}

static int g_total_writes = 0;
static time_t g_last_write_ts = 0;

static char          g_v44_last_clamp_source[32] = "";  /* last cap_source seen (any non-asb) */
static time_t        g_v44_last_clamp_ts = 0;

static void v44_conflict_record(const char *cap_source) {
    if (!cap_source) return;
    /* Track all non-asb / non-shell sources of cap changes. */
    int is_clamp  = (strcmp(cap_source, "vendor_clamp") == 0);
    int is_raised = (strcmp(cap_source, "vendor_raised") == 0);
    int is_thermal = (strcmp(cap_source, "thermal_overlay") == 0);
    if (!is_clamp && !is_raised && !is_thermal) return;
    time_t now = time(NULL);
    v44_clamp_decay(now);
    if (is_clamp)  { g_v44_clamp_total++;  g_v44_clamp_rate += 1.0; }
    if (is_raised) { g_v44_raised_total++; }
    strncpy(g_v44_last_clamp_source, cap_source, sizeof(g_v44_last_clamp_source) - 1);
    g_v44_last_clamp_source[sizeof(g_v44_last_clamp_source) - 1] = '\0';
    g_v44_last_clamp_ts = now;
}

/*
 * V50: the 1h window above only reset lazily when the NEXT vendor event arrived.
 * On a clean night after a noisy evening that next event never came, so a stale count (e.g.
 */
static unsigned long v44_clamp_1h_now(void) {
    v44_clamp_decay(time(NULL));
    g_v44_clamp_1h = (unsigned long)(g_v44_clamp_rate + 0.5);
    return g_v44_clamp_1h;
}
/* A steadier copy of the rate, for the published conflicts file only.
 *
 * That file is rewritten only when its content changes, and the decaying rate changes on
 * almost every tick after a burst - from 285 it loses two or three clamps per poll for
 * the best part of an hour. Two captures in a row then skipped only 53% of publishes
 * against 73% before the rolling count landed: the file was "different" every time
 * because one number in it was sliding.
 *
 * Here the published figure moves only when the rate has changed by 10% (at least 5).
 * Every decision - the thermal veto, the anomaly check - still reads the exact value
 * from v44_clamp_1h_now(); this only stops a display number from defeating the
 * unchanged-content check. */
static unsigned long v44_clamp_1h_pub(void) {
    static unsigned long pub = 0;
    unsigned long now = v44_clamp_1h_now();
    unsigned long diff = (now > pub) ? now - pub : pub - now;
    unsigned long step = pub / 10;
    if (step < 5) step = 5;
    if (diff >= step || (now == 0 && pub != 0)) pub = now;
    return pub;
}

/*
 * — Cap ownership model.
 */
typedef enum {
    ASB_CAP_OWNER_UNKNOWN = 0,
    ASB_CAP_OWNER_ASB     = 1,
    ASB_CAP_OWNER_SHELL   = 2,
    ASB_CAP_OWNER_VENDOR  = 3,
} asb_cap_owner_t;

/*
 * Compute effective owner from observed cap_source.
 */
static int asb_cap_compute_owner(const char *cap_source) {
    time_t now = time(NULL);
    int owner;
    if (!cap_source) owner = ASB_CAP_OWNER_UNKNOWN;
    else if (strcmp(cap_source, "vendor_clamp") == 0 ||
             strcmp(cap_source, "vendor_raised") == 0) {
        owner = ASB_CAP_OWNER_VENDOR;
    }
    /*
     * shell_overridden_up is somebody else raising our cap, not us owning it.
     *
     * Every shell_* source was counted as ASB's own, so the anti-thrash logic below never
     * saw a conflict and never backed off. Field report from a OnePlus 13: cap_verify said
     * DESYNC_shell_overridden_up in 5 samples out of 8 - the profile asked for 1190400 on
     * policy0 and the device sat at 2227200 - while vendor_clamp_1h was 32 and
     * cap_vendor_holddown_active stayed 0. ASB rewrote the cap, something rewrote it back,
     * and the loop ran all day. Six cores fighting over their own ceiling is exactly the
     * heat and drain those users reported, and it is the case the anti-clamp was built for.
     *
     * OnePlus 15 and Ace 6 do not show it because their policy0 is the little cluster
     * alone; on OP13 and Ace 5 policy0 covers cpu0-5, so the same losing write costs six
     * cores instead of two.
     *
     * "up" means our value did not hold. "down" is different - a value below ours is
     * usually a legitimate vendor cooldown, and treating that as a fight would make ASB
     * push back against thermal protection.
     */
    else if (strcmp(cap_source, "shell_overridden_up") == 0) owner = ASB_CAP_OWNER_VENDOR;
    else if (strncmp(cap_source, "shell_", 6) == 0) owner = ASB_CAP_OWNER_SHELL;
    else if (strcmp(cap_source, "asb") == 0 ||
             strncmp(cap_source, "asb_", 4) == 0) {
        owner = ASB_CAP_OWNER_ASB;
    }
    else owner = ASB_CAP_OWNER_UNKNOWN;

    /*
     * Track recent vendor clamp pattern for anti-thrash.
     */
    /* REVERTED: not backing off on vendor_raised made the phone stutter, not cool.
     *
     * The reasoning was that clamping down and raising up are opposite messages and should
     * not share one anti-thrash counter. That still reads as correct. But shipped together
     * with the cap-ownership change it produced a phone that stuttered in audio, animation,
     * camera and lock screen, held the prime below 1.2 GHz a fifth of the time, and ran no
     * cooler. Fighting the vendor for the ceiling is a write war, and the phone loses it.
     *
     * Both are reverted together because they shipped together: with two changes and one
     * bad outcome there is no way to tell which caused it, and guessing again is how this
     * got here. If the ownership question is worth reopening, it goes back one change at a
     * time with a capture between them.
     */
    if (owner == ASB_CAP_OWNER_VENDOR) {
        /* Burst window (60s) */
        if (g_cap_recent_window_start == 0 || (now - g_cap_recent_window_start) > 60) {
            g_cap_recent_window_start = now;
            g_cap_recent_vendor_clamps = 1;
        } else {
            g_cap_recent_vendor_clamps++;
        }
        /* Slow-thrash window (5 min) */
        if (g_cap_slow_window_start == 0 || (now - g_cap_slow_window_start) > 300) {
            g_cap_slow_window_start = now;
            g_cap_slow_vendor_clamps = 1;
        } else {
            g_cap_slow_vendor_clamps++;
        }
        /* Back off from a WRITE WAR, not from the vendor simply being present.
         *
         * The old thresholds - 3 clamps in 60 s, 8 in 300 s - describe a vendor HAL that
         * intervenes occasionally. Every Qualcomm thermal HAL in this fleet re-evaluates far
         * more often than once per 37 seconds, so `slow_trip` was true essentially always and
         * the governor spent its life in a 15-30 second hold. A device diag shows the bill
         * directly: attempts=282 applied=241 backoff_skips=174. Two thirds of the governor's
         * writes were never attempted, which is why cap_owner reads vendor 92% / asb 0% on a
         * phone with Smart active - and why none of the thermal work in this file reached the
         * hardware.
         *
         * A write war is two writers fighting over the SAME tick, not a vendor that also has
         * opinions. The burst window is what detects that, so it keeps a tight threshold and a
         * short hold. The slow window now needs a rate no normal HAL produces, and its hold is
         * cut to the length of a couple of ticks: long enough to break a feedback loop, short
         * enough that the governor is back before the next thermal decision matters.
         *
         * Both counters also decay on a tick where the vendor did NOT clamp, so a quiet minute
         * earns the governor its voice back instead of the count ratcheting up all session.
         */
        int burst_trip = (g_cap_recent_vendor_clamps >= 6);
        int slow_trip  = (g_cap_slow_vendor_clamps  >= 40);
        int persistent = (g_cap_slow_vendor_clamps  >= 90);
        if (persistent) {
            g_cap_vendor_hold_until = now + 6;
        } else if (burst_trip || slow_trip) {
            g_cap_vendor_hold_until = now + 3;
        }
    }
    else {
        /* A tick the vendor did not take: give the governor its voice back gradually.
         *
         * Without this the counters only ever climb until their window rolls over, so one
         * busy minute could hold the governor quiet for the following four. Decaying on
         * quiet ticks means the backoff tracks what is happening now rather than what
         * happened at the start of the window. */
        if (g_cap_recent_vendor_clamps > 0) g_cap_recent_vendor_clamps--;
        if (g_cap_slow_vendor_clamps  > 0) g_cap_slow_vendor_clamps--;
    }

    if (owner != g_cap_owner_eff) {
        g_cap_owner_eff = owner;
        g_cap_owner_since = now;
    }
    return owner;
}

/* Anti-thrash gate: returns 1 if ASB should back off cap writes right now. */
/* Sustained vendor pressure: stop rewriting a ceiling the vendor owns outright.
 *
 * The short holddown above breaks a burst - two or three clamps in a row - and then we go
 * back to writing. That is right when the vendor intervenes occasionally. It is wrong when
 * the vendor simply owns the cap: a field capture recorded 35 vendor clamps in an hour, 14
 * in the last minute, with cap_source on both clusters reading "vendor_clamp" and the CPU
 * at 54 degC against our own 60 degC throttle point. The vendor was throttling earlier
 * than we would, and every tick we wrote a ceiling it immediately took back.
 *
 * That loop costs I/O, OPP switches and the energy of the ramp, and it buys nothing: the
 * value we write never survives. Hysteresis cannot fix it because hysteresis governs how
 * WE change our mind, and here the disagreement is with something else entirely.
 *
 * So: 20 or more clamps in the slow window means the vendor is the owner, not a visitor.
 * Go passive - keep measuring, keep deciding, stop writing - and resume the moment the
 * rate drops back under half that. Nothing thermal is lost: the vendor's ceiling is the
 * stricter of the two in every capture we have, so passive means the phone runs cooler,
 * not hotter.
 */
static int asb_cap_writes_should_back_off(void) {
    time_t now = time(NULL);
    /* Threshold comes from config now - see vendor_passive_clamps.
     *
     * 20 was tuned against one ROM. A capture from a build where the vendor owns 77% of
     * clamp events reaches it constantly, so ASB goes passive and stays there; a quieter
     * ROM may never reach it and keeps fighting a cap it cannot win. The right number is a
     * property of the firmware, which means it belongs in the config, not the binary. */
    /* Let the counter fall when the clamps stop.
     *
     * It is only touched when a clamp happens: the window restarts and it resets to 1, or
     * it increments. With no clamps at all nothing runs, so it freezes at whatever it
     * reached - and the release below, which waits for it to drop under 10, waits
     * forever. Fixing the unreachable else above was only half the problem.
     *
     * An elapsed window with no clamp in it means the contention is over, so the count
     * goes to zero. Same 5-minute window the counting path uses. */
    if (g_cap_slow_window_start > 0 && (now - g_cap_slow_window_start) > 300 &&
        g_cap_slow_vendor_clamps > 0) {
        g_cap_slow_vendor_clamps = 0;
        g_cap_slow_window_start  = 0;
    }
    {
        int _vpc = g_asb_cfg.vendor_passive_clamps > 0 ? g_asb_cfg.vendor_passive_clamps : 20;
        if (g_cap_slow_vendor_clamps >= _vpc) g_cap_vendor_passive = 1;
    }
    /* The release has to be checked whether or not we are passive.
     *
     * It sat in the else branch of "are we passive", which only runs when we are NOT - so
     * the one state that needed clearing could never reach the line that clears it. Once
     * the module stood down it stayed down until the governor restarted: eight snapshots
     * in a row read vendor_passive=1 on a device whose contention had long since dropped
     * to a single slow clamp.
     *
     * The hysteresis is unchanged: enter at 20 slow clamps, leave below 10. Only the
     * reachability of the exit is fixed. */
    if (g_cap_vendor_passive) {
        g_stat_vendor_overrides++;
        if (g_cap_slow_vendor_clamps < 10) g_cap_vendor_passive = 0;
    }
    if (g_cap_vendor_passive) return 1;
    return (g_cap_vendor_hold_until > 0 && now < g_cap_vendor_hold_until) ? 1 : 0;
}

/* Translate owner enum to short string for JSON */
static const char *asb_cap_owner_name(int o) {
    switch (o) {
        case ASB_CAP_OWNER_ASB:    return "asb";
        case ASB_CAP_OWNER_SHELL:  return "shell";
        case ASB_CAP_OWNER_VENDOR: return "vendor";
        default:                   return "unknown";
    }
}

static void write_conflicts_json(void) {
    FILE *f = fopen("/dev/.asb/conflicts.json.tmp", "w");
    if (!f) return;
    fprintf(f,
        "{\n"
        "  \"last_cap_source\": \"%s\",\n"
        "  \"last_cap_source_ts\": %lld,\n"
        "  \"vendor_clamp_total\": %lu,\n"
        "  \"vendor_raised_total\": %lu,\n"
        "  \"vendor_clamp_1h\": %lu,\n"
        "  \"cap_owner\": \"%s\",\n"
        "  \"cap_owner_since\": %ld,\n"
        "  \"cap_vendor_holddown_active\": %d,\n"
        "  \"cap_recent_vendor_clamps_60s\": %d,\n"
        "  \"cap_sleep_detente\": %d,\n"
        "  \"cap_detente_skipped\": %ld\n"
        "}\n",
        g_v44_last_clamp_source[0] ? g_v44_last_clamp_source : "none",
        (long long)g_v44_last_clamp_ts,
        g_v44_clamp_total,
        g_v44_raised_total,
        v44_clamp_1h_pub(),
        asb_cap_owner_name(g_cap_owner_eff),
        (long)g_cap_owner_since,
        asb_cap_writes_should_back_off(),
        g_cap_recent_vendor_clamps,
        g_cap_detente_active, g_cap_detente_skipped);
    /* Skip the fsync and the rename when nothing in this file changed.
     *
     * This runs on every tick that produces a state write, and each run costs an fsync -
     * a durability barrier on /dev, plus a rename. The content is derived from counters
     * that mostly do not move: on a quiet phone the same bytes are written, synced and
     * published over and over.
     *
     * Comparing against the previous content is cheap - it is a few hundred bytes already
     * in memory. The WebUI reads this file on demand and cannot tell the difference
     * between a file that was rewritten identically and one that was left alone.
     *
     * The temp file is removed on the skip path so a stale .tmp cannot accumulate. */
    {
        static char _cj_prev[2048];
        char _cj_now[2048];
        long _cj_len = ftell(f);
        fflush(f);
        rewind(f);
        size_t _cj_rd = 0;
        FILE *_cj_r = fopen("/dev/.asb/conflicts.json.tmp", "r");
        if (_cj_r) {
            _cj_rd = fread(_cj_now, 1, sizeof(_cj_now) - 1, _cj_r);
            fclose(_cj_r);
        }
        _cj_now[_cj_rd] = 0;
        (void)_cj_len;
        if (_cj_rd > 0 && strcmp(_cj_now, _cj_prev) == 0) {
            fclose(f);
            g_stat_json_skipped++;
            unlink("/dev/.asb/conflicts.json.tmp");
            return;
        }
        snprintf(_cj_prev, sizeof(_cj_prev), "%s", _cj_now);
    }
    fsync(fileno(f));
    fclose(f);
    g_stat_json_written++;
    rename("/dev/.asb/conflicts.json.tmp", "/dev/.asb/conflicts.json");
}

static int g_v44_last_bat_trust = -1;          /* -1=unknown, 0=dirty, 1=partial, 2=clean */
static char g_v44_last_bat_outcome[24] = "";   /* "clean", "partial", "dirty", "noise" */

static void write_learner_state_json(const asb_fsm_t *fsm) {
    FILE *f = fopen("/dev/.asb/learner_state.json.tmp", "w");
    if (!f) return;
    const char *tier_name = "unknown";
    if (g_v44_last_bat_trust == 0) tier_name = "dirty";
    else if (g_v44_last_bat_trust == 1) tier_name = "partial";
    else if (g_v44_last_bat_trust == 2) tier_name = "clean";
    else if (g_v44_last_bat_trust == 3) tier_name = "noisy";

    int bat_sessions = g_pstats_per[PROFILE_BATTERY].session_count;
    int balanced_sessions = g_pstats_per[PROFILE_BALANCED].session_count;
    int perf_sessions = g_pstats_per[PROFILE_PERFORMANCE].session_count;
    int night_count = g_pstats_per[PROFILE_BATTERY].night_count;
    int day_count = g_pstats_per[PROFILE_BATTERY].day_count;

    fprintf(f,
        "{\n"
        "  \"trust_tier\": \"%s\",\n"
        "  \"trust_tier_num\": %d,\n"
        "  \"last_outcome\": \"%s\",\n"
        "  \"sessions\": {\n"
        "    \"battery\": %d,\n"
        "    \"balanced\": %d,\n"
        "    \"performance\": %d,\n"
        "    \"night\": %d,\n"
        "    \"day\": %d\n"
        "  },\n"
        "  \"smart_sessions\": {\n"
        "    \"total\": %d,\n"
        "    \"day\": %d,\n"
        "    \"night\": %d,\n"
        "    \"gaming\": %d,\n"
        "    \"bucket_updates\": %d,\n"
        "    \"last_bucket_id\": %d,\n"
        "    \"last_daypart\": %d,\n"
        "    \"last_confidence\": %d,\n"
        "    \"last_update_ts\": %ld,\n"
        "    \"last_quality\": %d,\n"
        "    \"avg_quality\": %d\n"
        "  },\n"
        "  \"self_tuned\": {\n"
        "    \"bat_fast_idle_s\": %d,\n"
        "    \"bat_heavy_load_enter\": %.0f,\n"
        "    \"bat_moderate_load_enter\": %.0f,\n"
        "    \"bat_light_idle_gpu\": %d\n"
        "  },\n"
        "  \"battery_aggregates\": {\n"
        "    \"avg_idle_q\": %.1f,\n"
        "    \"avg_wph\": %.2f,\n"
        "    \"night_avg_iq\": %.1f,\n"
        "    \"day_avg_iq\": %.1f,\n"
        "    \"clean_night_count\": %d\n"
        "  }\n"
        "}\n",
        tier_name,
        g_v44_last_bat_trust,
        g_v44_last_bat_outcome[0] ? g_v44_last_bat_outcome : "unknown",
        bat_sessions, balanced_sessions, perf_sessions, night_count, day_count,
        g_smart_sessions_total, g_smart_sessions_day, g_smart_sessions_night,
        g_smart_sessions_gaming, g_smart_bucket_updates,
        g_smart_last_bucket_id, g_smart_last_daypart, g_smart_last_confidence,
        (long)g_smart_last_update_ts,
        g_smart_last_quality, g_smart_quality_ewma,
        g_asb_cfg.bat_fast_idle_s,
        g_asb_cfg.bat_heavy_load_enter,
        g_asb_cfg.bat_moderate_load_enter,
        g_asb_cfg.bat_light_idle_gpu,
        g_pstats_per[PROFILE_BATTERY].avg_idle_q,
        g_pstats_per[PROFILE_BATTERY].avg_wph,
        g_pstats_per[PROFILE_BATTERY].night_avg_iq,
        g_pstats_per[PROFILE_BATTERY].day_avg_iq,
        g_pstats_per[PROFILE_BATTERY].clean_night_count);
    (void)fsm;
    /* Same skip as conflicts.json, but with a time floor - the learner is different.
     *
     * conflicts.json is pure derived state: identical content means nothing happened, so
     * skipping it is free. This file also carries the learner's own statistics, and a
     * consumer reading it wants to know the model is alive, not just that its numbers
     * have not moved yet. A bucket that legitimately reports the same values for an hour
     * would look frozen if we never republished.
     *
     * So: skip identical content, but publish anyway every 5 minutes regardless. That
     * keeps the fsync off the tick path while leaving a heartbeat, which is what the
     * audit asked for when it said the learner needs a separate gated path.
     */
    {
        static char   _lj_prev[4096];
        static time_t _lj_last_pub = 0;
        time_t _lj_now = time(NULL);
        char   _lj_cur[4096];
        size_t _lj_rd = 0;
        fflush(f);
        FILE *_lj_r = fopen("/dev/.asb/learner_state.json.tmp", "r");
        if (_lj_r) {
            _lj_rd = fread(_lj_cur, 1, sizeof(_lj_cur) - 1, _lj_r);
            fclose(_lj_r);
        }
        _lj_cur[_lj_rd] = 0;
        if (_lj_rd > 0 && strcmp(_lj_cur, _lj_prev) == 0 &&
            (_lj_now - _lj_last_pub) < 300) {
            fclose(f);
            g_stat_json_skipped++;
            unlink("/dev/.asb/learner_state.json.tmp");
            return;
        }
        snprintf(_lj_prev, sizeof(_lj_prev), "%s", _lj_cur);
        _lj_last_pub = _lj_now;
    }
    fsync(fileno(f));
    fclose(f);
    /* Publish it. This rename was lost when the skip block was added: the function wrote
       learner_state.json.tmp, fsynced it and returned, so the real file was never replaced.
       The WebUI kept reading a stale copy from install time - which is why Monitor showed
       "no data" on a phone with 49 sessions recorded and visible in the Smart card. */
    rename("/dev/.asb/learner_state.json.tmp", "/dev/.asb/learner_state.json");
    g_stat_json_written++;
}

static void build_status_json(const asb_fsm_t *fsm, const asb_metrics_t *m,
                               asb_prediction_t pred,
                               char *out, int outlen)
{
    static const char *profile_names[] = {"battery","balanced","performance","smart"};
    static const char *pred_names[] = {"unknown","idle","light","active"};
    int ma_valid = (m->bat.current_ma > 0 && !m->bat.charging);
    int real_max_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
    int real_max_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
    int cap_gap_p0  = (real_max_p0 > 0) ? (fsm->current_caps.cpu_max[0] - real_max_p0) : 0;
    int cap_gap_p1  = (real_max_p1 > 0) ? (fsm->current_caps.cpu_max[1] - real_max_p1) : 0;
    /* cap_source classification — who controls the actual cap right now. */
    int hw_ceil_p0 = sysfs_read_int(cpu_policy_path(0, "cpuinfo_max_freq"), 0);
    int hw_ceil_p1 = sysfs_read_int(cpu_policy_path(1, "cpuinfo_max_freq"), 0);
    int profile_cap_p0 = asb_profile_bounds_for(fsm->profile_idx)->ceil.cpu_max[0];
    int profile_cap_p6 = asb_profile_bounds_for(fsm->profile_idx)->ceil.cpu_max[1];
    int headroom_real_pct = -1;
    if (hw_ceil_p0 > 0 && real_max_p0 > 0) {
        headroom_real_pct = (int)((long)real_max_p0 * 100 / hw_ceil_p0);
    }
    if (hw_ceil_p1 > 0 && real_max_p1 > 0) {
        int _hr1 = (int)((long)real_max_p1 * 100 / hw_ceil_p1);
        if (headroom_real_pct < 0 || _hr1 < headroom_real_pct) headroom_real_pct = _hr1;
    }
    if (headroom_real_pct > 100) headroom_real_pct = 100;
    /*
     * classifier gets runtime_declared from msm_performance read (m->therm.perf_cap_*), not
     * from fsm->current_caps.
     */
    /* fix182: in a manual profile the shell's recorded ceiling is the reference, not the
     * vendor's msm_performance value or a write cache left over from Smart. */
    int shell_cap_p0 = asb_shell_cap_khz(fsm, 0);
    int shell_cap_p1 = asb_shell_cap_khz(fsm, 1);
    const char *cap_src_p0 = (shell_cap_p0 > 0)
        ? cap_source_classify_shell(shell_cap_p0, real_max_p0, hw_ceil_p0)
        : cap_source_classify(profile_cap_p0,
                              m->therm.perf_cap_p0,
                              real_max_p0, hw_ceil_p0,
                              g_wcache.cpu_max[0]);
    const char *cap_src_p6 = (shell_cap_p1 > 0)
        ? cap_source_classify_shell(shell_cap_p1, real_max_p1, hw_ceil_p1)
        : cap_source_classify(profile_cap_p6,
                              m->therm.perf_cap_p6,
                              real_max_p1, hw_ceil_p1,
                              g_wcache.cpu_max[1]);
    /*
     * record conflicts to /dev/.asb/conflicts.json (written below).
     */
    v44_conflict_record(cap_src_p0);
    v44_conflict_record(cap_src_p6);
    /* compute effective cap owner from observed source. The owner with
     * the more-restrictive cap wins; default to p6 since prime cores matter
     * most for perf decisions. */
    asb_cap_compute_owner(cap_src_p6);
    snprintf(out, outlen,
        "{\"state\":\"%s\",\"profile\":\"%s\","
        "\"mA\":%d,\"mA_valid\":%d,\"charging\":%d,"
        "\"capacity\":%d,\"bat_temp_dC\":%d,"
        "\"gpu\":%d,\"load\":%.2f,"
        "\"cpu_max\":[%d,%d,%d],"
        "\"thermal\":%d,\"temp\":%d,\"temp_valid\":%d,\"temp_age_s\":%d,\"temp_read_epoch\":%ld,\"temp_invalid_reason\":\"%s\","
        "\"skin_temp\":%d,\"surface_hotspot\":%d,\"board_temp\":%d,"
        /* Confidence travels with the source. A temperature whose sensor could not be
         * cross-checked, or that came from a peer median after socd was rejected, is
         * not the same claim as one validated against twenty per-core zones - and the
         * report should not present them identically. */
        "\"thermal_cpu_zone\":%d,\"thermal_cpu_type\":\"%s\",\"thermal_src_conf\":%d,"
        /* Rejected candidate travels separately and unformatted. A consumer that
         * wants to show it must choose to, and cannot accidentally print it as C. */
        "\"thermal_rejected_type\":\"%s\",\"thermal_rejected_raw\":%d,"
        /* Consensus v2: what the control value was checked against, and what that
         * check concluded. An empty note means the sources agreed. */
        "\"thermal_peer_hi\":%d,\"thermal_peer_n\":%d,\"thermal_consensus\":\"%s\","
        /* How many OPP steps the writer could enumerate per cluster. Zero means
         * cpu_snap_freq is a no-op and every ceiling is written unsnapped - which
         * looks identical to a vendor override in the failure log and took three
         * rounds to tell apart. Published so it can be read instead of inferred. */
        "\"freq_table_n\":\"%d,%d,%d\","
        "\"thermal_skin_zone\":%d,\"thermal_surface_zone\":%d,"
        "\"soft_clamp\":%d,\"hard_clamp\":%d,"
        "\"headroom_pct\":%d,\"headroom_valid\":%d,\"headroom_invalid_reason\":\"%s\",\"headroom_real_pct\":%d,"
        "\"perf_cap_p0\":%d,\"perf_cap_p6\":%d,"
        "\"cap_source_p0\":\"%s\",\"cap_source_p6\":\"%s\","
        "\"thermal_cpu_fallback_type\":\"%s\","
        "\"predict\":\"%s\",\"screen\":%d,\"bat\":%d,"
        "\"writes\":%d,\"last_write\":%ld,"
        "\"dwell_sec\":%ld,\"boost\":%d,"
        "\"cap_gap_p0\":%d,\"cap_gap_p1\":%d,"
        "\"last_sustained_reason\":\"%s\",\"highload_mode\":\"%s\",\"ses_gaming\":%d,\"ses_sustained\":%d,\"ses_thermal\":%d,\"ses_unreachable\":%d,\"ses_t_heavy\":%ld,\"ses_t_gaming\":%ld,\"ses_t_sustained\":%ld,\"ses_avg_gap_p0\":%d,\"ses_max_gap_p0\":%d,\"ses_max_temp\":%d,\"ses_max_skin_temp\":%d,\"ses_max_surface_temp\":%d,\"ses_max_board_temp\":%d,\"ses_auto_degraded\":%d,\"bat_deep_idle\":%ld,\"bat_light_idle\":%ld,\"bat_wake_cycles\":%d,\"clamp_hold\":%d,\"cap_owner\":\"%s\",\"cap_vendor_holddown_active\":%d,\"cap_recent_vendor_clamps_60s\":%d,\"vendor_clamp_1h\":%lu}",
        asb_state_names[fsm->state],
        profile_names[fsm->profile_idx],
        m->bat.current_ma, ma_valid, m->bat.charging,
        m->bat.capacity_pct, m->bat.temp_dC,
        m->gpu.load_pct,
        m->cpu.load1,
        /* Same as the state file above: report the cap being held, not the one requested. */
        (sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0) > 0)
            ? sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0)
            : fsm->current_caps.cpu_max[0],
        (sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0) > 0)
            ? sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0)
            : fsm->current_caps.cpu_max[1],
        fsm->current_caps.cpu_max[2],
        fsm->thermal_cap,
        m->therm.cpu_max_c,
        m->therm.temp_valid,
        m->therm.temp_age_s,
        /* Absolute time of the last real thermal read.
         *
         * temp_age_s is computed when the metrics are collected; this JSON can be
         * re-published long after that, and a reader then sees a cached night value
         * labelled "age 0, valid". An audit caught exactly that: control temp 28 C,
         * temp_valid=1, temp_age_s=0 in the morning while prime/perf/little read
         * 43/45/46 directly. The governor's own decisions were fine - they use the value
         * at decision time - but nothing downstream could tell the snapshot was stale.
         * With the epoch, any reader computes the true age itself. */
        (long)g_last_thermal_read_ts,
        m->therm.temp_invalid_reason[0] ? m->therm.temp_invalid_reason : "init",
        m->therm.skin_temp_c,
        m->therm.surface_hotspot_c,
        m->therm.board_temp_c,
        g_thermal_cpu_zone,
        g_thermal_cpu_type[0] ? g_thermal_cpu_type : "unknown",
        g_thermal_source_confidence,
        g_thermal_rejected_type,
        g_thermal_rejected_raw,
        g_thermal_peer_hi,
        g_thermal_peer_n,
        g_thermal_consensus_note,
        writer_freq_table_len(0), writer_freq_table_len(1), writer_freq_table_len(2),
        g_thermal_skin_zone,
        g_thermal_surface_zone,
        m->therm.soft_clamp,
        m->therm.hard_clamp,
        m->therm.headroom_pct,
        m->therm.headroom_valid,
        m->therm.headroom_invalid_reason[0] ? m->therm.headroom_invalid_reason : "ok",
        headroom_real_pct,
        m->therm.perf_cap_p0,
        m->therm.perf_cap_p6,
        cap_src_p0, cap_src_p6,
        g_thermal_cpu_fallback_type[0] ? g_thermal_cpu_fallback_type : "none",
        pred_names[pred],
        m->misc.screen_on,
        m->bat.capacity_pct,
        g_total_writes,
        (long)g_last_write_ts,
        fsm_elapsed_sec(fsm),
        g_msm_boost_active,
        cap_gap_p0,
        cap_gap_p1,
        sustained_reason_name(fsm->sustained_reason),
        g_asb_cfg.highload_mode == 1 ? "burst" :
        g_asb_cfg.highload_mode == 2 ? "stable" :
        g_asb_cfg.highload_mode == 3 ? "auto" : "default",
        fsm->ses_gaming_entries, fsm->ses_sustained_entries,
        fsm->ses_thermal_entries, fsm->ses_unreachable_entries,
        fsm->ses_time_heavy_sec, fsm->ses_time_gaming_sec, fsm->ses_time_sustained_sec,
        fsm->ses_gap_samples > 0 ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0,
        fsm->ses_max_gap_p0,
        fsm->ses_max_temp,
        fsm->ses_max_skin_temp,
        fsm->ses_max_surface_temp,
        fsm->ses_max_board_temp,
        fsm->ses_auto_degraded,
        fsm->bat_time_deep_idle_sec,
        fsm->bat_time_light_idle_sec,
        fsm->bat_wake_cycles,
        fsm->clamp_hold,
        asb_cap_owner_name(g_cap_owner_eff),
        (g_cap_vendor_passive || g_cap_vendor_hold_until > time(NULL)) ? 1 : 0,
        g_cap_recent_vendor_clamps,
        v44_clamp_1h_now());
    {
        long _act = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec + fsm->ses_time_sustained_sec;
        int _sp = (_act > 0) ? (int)(fsm->ses_time_sustained_sec * 100 / _act) : 0;
        long _bt = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec + fsm->bat_time_moderate_sec;
        int _iq = -1;
        if (_bt > 30) {
            _iq = (int)(fsm->bat_time_deep_idle_sec * 100 / _bt);
            int _wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
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
            "\"mem_psi_peak\":%d,\"mem_press_ticks\":%d,"
            "\"eff_sus_lvl\":%.2f,\"eff_sus_temp\":%d,\"eff_gr_cd\":%d,\"eff_gr_temp\":%d,"
            "\"eff_bat_fi\":%d,\"eff_bat_hl\":%.1f,\"eff_bat_ml\":%.1f,\"eff_bat_idle_gpu\":%d}",
            _sp, _iq, _ce,
            fsm->mem_psi_peak_x100, fsm->mem_pressure_ticks,
            g_asb_cfg.sustained_level,
            asb_config_profile_sustained_temp_enter(&g_asb_cfg, fsm->profile_idx),
            g_asb_cfg.gaming_retry_cooldown_s, g_asb_cfg.gaming_retry_temp_max,
            g_asb_cfg.bat_fast_idle_s,
            g_asb_cfg.bat_heavy_load_enter,
            g_asb_cfg.bat_moderate_load_enter,
            g_asb_cfg.bat_light_idle_gpu);
        int _pidx = fsm->profile_idx;
        if (_pidx < 0 || _pidx > 2) _pidx = 1;
        snprintf(out + strlen(out) - 1, outlen - (int)strlen(out),
            ",\"intent\":\"%s\",\"hot_fail\":%d,\"deg_age\":%ld,"
            "\"auto_bat\":%d,\"auto_bat_restore\":%d,\"qn_active\":%d,"
            "\"auto_bat_reason\":\"%s\",\"auto_bat_since\":%lld,"
            "\"adv_score\":%d,\"adv_active\":%d,\"cold_skin\":%d,\"cold_surface\":%d,\"cold_board\":%d,"
            "\"vote_skin\":%d,\"vote_surface\":%d,\"vote_board\":%d,\"would_bias_exit\":%d,"
            "\"bias_a\":%d,\"bias_b\":%d}",
            (fsm->ses_intent >= 0 && fsm->ses_intent <= 6)
                ? intent_names[fsm->ses_intent] : "unknown",
            g_pstats_per[_pidx].hot_fail_count,
            fsm->ses_degrade_at_age,
            fsm->auto_battery_active,
            fsm->auto_battery_restore_idx,
            g_quiet_night_active,
            fsm->auto_battery_reason[0] ? fsm->auto_battery_reason : "none",
            (long long)fsm->auto_battery_since,
            fsm->thermal_advisory_score,
            fsm->thermal_advisory_active,
            fsm->cold_baseline_skin,
            fsm->cold_baseline_surface,
            fsm->cold_baseline_board,
            fsm->thermal_vote_skin,
            fsm->thermal_vote_surface,
            fsm->thermal_vote_board,
            fsm->would_bias_exit_gaming,
            fsm->would_bias_mode_a,
            fsm->would_bias_mode_b);
    }
}

static void pstats_load_one(const char *path, asb_persistent_stats_t *ps) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    int _n = fscanf(f, "{\"count\":%d,\"t2s\":%f,\"t2th\":%f,\"temp\":%f,\"gap\":%f,\"eff\":%f",
           &ps->session_count, &ps->avg_time_to_first_sus,
           &ps->avg_time_to_first_thermal, &ps->avg_max_temp,
           &ps->avg_gap_p0, &ps->avg_efficiency);
    (void)_n;
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
    
    if (fscanf(f, ",\"iq\":%f", &ps->avg_idle_q) != 1)
        ps->avg_idle_q = 0;
    if (fscanf(f, ",\"wph\":%f", &ps->avg_wph) != 1)
        ps->avg_wph = 0;
    if (fscanf(f, ",\"cn\":%d", &ps->clean_night_count) != 1)
        ps->clean_night_count = 0;
    if (fscanf(f, ",\"qmin\":%f", &ps->avg_quiet_duration_min) != 1)
        ps->avg_quiet_duration_min = 0;
    /* Battery Memory Split */
    if (fscanf(f, ",\"niq\":%f", &ps->night_avg_iq) != 1)
        ps->night_avg_iq = 0;
    if (fscanf(f, ",\"nwph\":%f", &ps->night_avg_wph) != 1)
        ps->night_avg_wph = 0;
    if (fscanf(f, ",\"nc\":%d", &ps->night_count) != 1)
        ps->night_count = 0;
    if (fscanf(f, ",\"diq\":%f", &ps->day_avg_iq) != 1)
        ps->day_avg_iq = 0;
    if (fscanf(f, ",\"dwph\":%f", &ps->day_avg_wph) != 1)
        ps->day_avg_wph = 0;
    if (fscanf(f, ",\"dc\":%d", &ps->day_count) != 1)
        ps->day_count = 0;
    if (fscanf(f, ",\"tfi\":%ld", &ps->last_tune_ts_fast_idle) != 1)
        ps->last_tune_ts_fast_idle = 0;
    if (fscanf(f, ",\"thl\":%ld", &ps->last_tune_ts_heavy_load) != 1)
        ps->last_tune_ts_heavy_load = 0;
    if (fscanf(f, ",\"tml\":%ld", &ps->last_tune_ts_moderate_load) != 1)
        ps->last_tune_ts_moderate_load = 0;
    if (fscanf(f, ",\"tlg\":%ld", &ps->last_tune_ts_light_gpu) != 1)
        ps->last_tune_ts_light_gpu = 0;
    fclose(f);
    if (ps->session_count > PERSISTENT_STATS_MAX_SESSIONS)
        ps->session_count = PERSISTENT_STATS_MAX_SESSIONS;
}

static void pstats_save_one(const char *path, const asb_persistent_stats_t *ps) {
    char buf[896];
    snprintf(buf, sizeof(buf),
        "{\"count\":%d,\"t2s\":%.1f,\"t2th\":%.1f,\"temp\":%.1f,\"gap\":%.0f,\"eff\":%.1f,"
        "\"deg\":%d,\"hot\":%d,\"deg_age\":%.1f,\"btcd\":%d,\"cstrk\":%d,\"ctype\":%d,\"quar\":%d,"
        "\"iq\":%.1f,\"wph\":%.1f,\"cn\":%d,\"qmin\":%.0f,"
        "\"niq\":%.1f,\"nwph\":%.1f,\"nc\":%d,\"diq\":%.1f,\"dwph\":%.1f,\"dc\":%d,"
        "\"tfi\":%ld,\"thl\":%ld,\"tml\":%ld,\"tlg\":%ld}",
            ps->session_count, ps->avg_time_to_first_sus,
            ps->avg_time_to_first_thermal, ps->avg_max_temp,
            ps->avg_gap_p0, ps->avg_efficiency, ps->degrade_count,
            ps->hot_fail_count, ps->avg_degrade_age,
            ps->bat_tune_cooldown, ps->cause_streak,
            ps->cause_streak_type, ps->quarantine_remaining,
            ps->avg_idle_q, ps->avg_wph,
            ps->clean_night_count, ps->avg_quiet_duration_min,
            ps->night_avg_iq, ps->night_avg_wph, ps->night_count,
            ps->day_avg_iq, ps->day_avg_wph, ps->day_count,
            ps->last_tune_ts_fast_idle, ps->last_tune_ts_heavy_load,
            ps->last_tune_ts_moderate_load, ps->last_tune_ts_light_gpu);
    if (atomic_write_file(path, buf) != 0)
        asb_log("pstats: atomic write failed for %s", path);
}

/* Load from the current path, or once from the pre-move module directory. */
static void pstats_load_migrating(const char *path, asb_persistent_stats_t *ps) {
    if (access(path, F_OK) == 0) { pstats_load_one(path, ps); return; }
    const char *base = strrchr(path, '/');
    if (!base) return;
    char legacy[256];
    snprintf(legacy, sizeof(legacy), "%s%s", PERSISTENT_STATS_DIR_LEGACY, base);
    if (access(legacy, F_OK) == 0) pstats_load_one(legacy, ps);
}

static void persistent_stats_load(void) {
    pstats_load_migrating(PERSISTENT_STATS_FILE, &g_pstats);
    for (int i = 0; i < 3; i++)
        pstats_load_migrating(g_pstats_files[i], &g_pstats_per[i]);
}

#define BAT_TRUST_DIRTY   0
#define BAT_TRUST_PARTIAL 1
#define BAT_TRUST_CLEAN   2
#define BAT_TRUST_NOISY   3
#define BAT_CAUSE_NONE       0
#define BAT_CAUSE_WAKE_NOISE 1
#define BAT_CAUSE_SCREEN_ON  2
#define BAT_CAUSE_NO_SETTLE  3
static int battery_session_trust(const asb_fsm_t *fsm);
static int classify_environment(const asb_fsm_t *fsm);
static int battery_fail_cause(const asb_fsm_t *fsm, int iq);

/* A screen-off is not a session end (fix167).
 *
 * Both screen-off paths called the full save, and the save is not only a write to disk: it
 * folds the session into the per-profile averages and counters - session_count, the max-temp
 * and efficiency EMAs, hot_fail, degrade_count, cause_streak, the battery night/day split.
 * The session itself only ends later (Smart's 20-minute bank, the deep-idle boundary, a
 * profile change), where the same save runs again. So every screen-off inside a session
 * counted that session once more: in the fix163 capture "cause_streak: vendor_clamp x3
 * consecutive" at 06:20 was one session seen at its third screen-off, and a single hot
 * Performance session with two screen-offs reads as two thermal-wall hits - two of those and
 * Performance is switched to stable.
 *
 * What a screen-off does need is the context for whatever comes next - the thermal debt of a
 * Performance session that just ended, the clean-night reward, the environment the next
 * session starts in. That part still runs at every screen-off; the learning runs once, when
 * the session really ends. */
static void persistent_stats_save_ex(const asb_fsm_t *fsm, int learn) {
    /*
     * battery-aware save gate.
     */
    if (fsm->profile_idx == PROFILE_BATTERY) {
        long bat_total = fsm->bat_time_deep_idle_sec +
                         fsm->bat_time_light_idle_sec +
                         fsm->bat_time_moderate_sec;
        long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
        if (bat_total < 120 && dur < 180)
            return;
    } else {
        if (fsm->ses_sustained_entries == 0 && fsm->ses_time_heavy_sec < 30
            && fsm->bat_time_deep_idle_sec < 60)
            return;
    }

    int pidx = fsm->profile_idx;
    if (pidx < 0 || pidx > 2) pidx = 1;

    /* record thermal debt for performance sessions */
    if (pidx == PROFILE_PERFORMANCE) {
        g_last_perf_end_ts = time(NULL);
        g_last_perf_max_temp = fsm->ses_max_temp;
        g_last_perf_was_clamped = (fsm->had_futility && fsm->clamp_hold) ? 1 : 0;
    }
    /* Clean-Night Reward -- remember if last battery session was a good night.
     * V50: smart sessions spend nights battery-like and accumulate the same
     * idle telemetry now, so they can earn (and lose) the reward too. */
    if (pidx == PROFILE_BATTERY || fsm->profile_idx == PROFILE_SMART) {
        long _dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
        long _bt = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec
                   + fsm->bat_time_moderate_sec;
        int _iq = (_bt > 0) ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt) : 0;
        g_last_bat_clean_night = (_dur >= 7200 && _iq >= 40 &&
                                  fsm->bat_wake_bg <= 4 &&
                                  !fsm->ses_auto_degraded) ? 1 : 0;
        if (g_last_bat_clean_night)
            asb_log("pstats: clean_night_reward active for next battery session");
    }
    /* Start-of-session Priming -- save env for next session */
    g_last_session_env = classify_environment(fsm);
    if (!learn) return;

    asb_persistent_stats_t *ps = &g_pstats_per[pidx];

    int skip_per_profile = 0;
    float trust_weight = 1.0f;  /* learning weight: clean=1.0, partial=0.25, noisy=0.10, dirty=0 */
    if (pidx == PROFILE_BATTERY) {
        int trust = battery_session_trust(fsm);
        /* expose trust + outcome to learner_state.json */
        g_v44_last_bat_trust = trust;
        if (trust == BAT_TRUST_DIRTY) {
            strncpy(g_v44_last_bat_outcome, "dirty", sizeof(g_v44_last_bat_outcome) - 1);
            g_v44_last_bat_outcome[sizeof(g_v44_last_bat_outcome) - 1] = '\0';
        } else if (trust == BAT_TRUST_NOISY) {
            strncpy(g_v44_last_bat_outcome, "noisy", sizeof(g_v44_last_bat_outcome) - 1);
            g_v44_last_bat_outcome[sizeof(g_v44_last_bat_outcome) - 1] = '\0';
        } else if (trust == BAT_TRUST_PARTIAL) {
            strncpy(g_v44_last_bat_outcome, "partial", sizeof(g_v44_last_bat_outcome) - 1);
            g_v44_last_bat_outcome[sizeof(g_v44_last_bat_outcome) - 1] = '\0';
        } else if (trust == BAT_TRUST_CLEAN) {
            strncpy(g_v44_last_bat_outcome, "clean", sizeof(g_v44_last_bat_outcome) - 1);
            g_v44_last_bat_outcome[sizeof(g_v44_last_bat_outcome) - 1] = '\0';
        }
        if (trust == BAT_TRUST_DIRTY) {
            skip_per_profile = 1;
            /*
             * bootstrap pstats_battery.json on first meaningful session even if noisy.
             */
            if (access(g_pstats_files[pidx], F_OK) != 0) {
                pstats_save_one(g_pstats_files[pidx], ps);
                asb_log("pstats: battery trust=%d, bootstrapped %s (no learning)",
                        trust, g_pstats_files[pidx]);
            } else {
                /* log specific reason for rejection */
                long _bt = fsm->bat_time_deep_idle_sec +
                           fsm->bat_time_light_idle_sec +
                           fsm->bat_time_moderate_sec;
                int _iq = (_bt > 0) ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt) : 0;
                long _dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
                float _wph = (_dur > 0) ? (float)fsm->bat_wake_bg * 3600.0f / _dur : 0;
                asb_log("pstats: battery trust=%d (iq=%d bg_wph=%.1f wake_bg=%d wake_scr=%d), "
                        "skipping per-profile memory update",
                        trust, _iq, _wph, fsm->bat_wake_bg, fsm->bat_wake_screen);
            }
        } else if (trust == BAT_TRUST_NOISY) {
            trust_weight = 0.10f;
            asb_log("pstats: battery trust=noisy, learning with weight=0.10");
        } else if (trust == BAT_TRUST_PARTIAL) {
            trust_weight = 0.25f;
            asb_log("pstats: battery trust=partial, learning with weight=0.25");
        }
    }
    if (pidx == PROFILE_PERFORMANCE && fsm->ses_intent == INTENT_BENCHMARK) {
        skip_per_profile = 1;
        asb_log("pstats: benchmark session, skipping per-profile memory update");
    }
    /* quarantine -- don't learn from user-switch storm */
    if (fsm->plan.quarantine) {
        skip_per_profile = 1;
        asb_log("pstats: quarantine active, skipping per-profile memory update");
    }
    /* storm shield -- don't learn from noisy battery data */
    if (g_storm_shield_active) {
        skip_per_profile = 1;
        asb_log("pstats: storm shield active, skipping per-profile memory update");
    }

    /* OTA quarantine -- skip learning during environment adjustment
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
        alpha *= trust_weight;  /* partial trust = 25% learning rate */

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

        /* cause_streak -- track consecutive same-cause sessions */
        {
            int cur_cause = 0;
            if (pidx == PROFILE_BATTERY) {
                long bt = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec
                         + fsm->bat_time_moderate_sec;
                int iq = -1;
                if (bt > 60) {
                    iq = (int)(fsm->bat_time_deep_idle_sec * 100 / bt);
                    int wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
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

        
        if (pidx == PROFILE_BATTERY) {
            long _dur_bm = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
            long _bt_bm = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec
                          + fsm->bat_time_moderate_sec;
            int _iq_bm = (_bt_bm > 0) ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt_bm) : 0;
            float _wph_bm = (_dur_bm > 0) ? (float)fsm->bat_wake_bg * 3600.0f / _dur_bm : 0;
            ps->avg_idle_q = ps->avg_idle_q * (1 - alpha) + _iq_bm * alpha;
            ps->avg_wph = ps->avg_wph * (1 - alpha) + _wph_bm * alpha;
            /* Track clean nights separately */
            if (_dur_bm >= 7200 && _iq_bm >= 40 && fsm->bat_wake_bg <= 4) {
                ps->clean_night_count++;
                float qn_min = _dur_bm / 60.0f;
                float cn_a = 1.0f / ps->clean_night_count;
                if (cn_a < 0.15f) cn_a = 0.15f;
                ps->avg_quiet_duration_min =
                    ps->avg_quiet_duration_min * (1 - cn_a) + qn_min * cn_a;
            }
            /* Battery Memory Split -- night vs day */
            int is_night = (_dur_bm >= 7200 && _iq_bm >= 30 && !fsm->ses_auto_degraded);
            if (is_night) {
                ps->night_count++;
                float na = 1.0f / ps->night_count;
                if (na < 0.15f) na = 0.15f;
                ps->night_avg_iq = ps->night_avg_iq * (1 - na) + _iq_bm * na;
                ps->night_avg_wph = ps->night_avg_wph * (1 - na) + _wph_bm * na;
            } else {
                ps->day_count++;
                float da = 1.0f / ps->day_count;
                if (da < 0.15f) da = 0.15f;
                ps->day_avg_iq = ps->day_avg_iq * (1 - da) + _iq_bm * da;
                ps->day_avg_wph = ps->day_avg_wph * (1 - da) + _wph_bm * da;
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

static void persistent_stats_save(const asb_fsm_t *fsm) { persistent_stats_save_ex(fsm, 1); }
static void persistent_stats_screen_off(const asb_fsm_t *fsm) { persistent_stats_save_ex(fsm, 0); }

/* More than half the session spent in the screen-off idle states. */
static int asb_smart_session_idle_dominant(const asb_fsm_t *fsm, long dur) {
    long idle = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec;
    return dur > 0 && idle * 2 >= dur;
}

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
    /* Smart had no branch, so every Smart session - 500 of 500 in an OP15 history, the
     * profile nearly everyone runs - was "low" and its signature "mixed", and the session
     * report had nothing to sort them by. A Smart session is judged by what it mostly was:
     * screen-off time by the battery rules, screen-on time by the duration/headroom rules. */
    if (fsm->profile_idx == PROFILE_SMART) {
        if (asb_smart_session_idle_dominant(fsm, dur)) {
            int trust = battery_session_trust(fsm);
            if (trust == BAT_TRUST_CLEAN && dur >= 300) return "high";
            if (trust != BAT_TRUST_DIRTY && dur >= 120) return "medium";
            return "low";
        }
        if (dur < 120) return "low";
        if (dur >= 300 && hr_n >= 30) return "high";
        if (dur >= 120 && hr_n >= 10) return "medium";
        return "low";
    }
    return "low";
}

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
    if (fsm->profile_idx == PROFILE_SMART) {
        if (fsm->ses_max_temp >= 80 || strcmp(limiter, "thermal") == 0) return "thermal_limited";
        if (fsm->ses_time_to_first_sus > 0 && fsm->ses_time_to_first_sus < 60) return "early_collapse";
        if (idle_quality >= 70 && strcmp(conf, "high") == 0 && fsm->ses_time_heavy_sec == 0)
            return "clean_sleep";
        if (idle_quality >= 0 && idle_quality < 20 && fsm->ses_time_heavy_sec == 0 &&
            fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec > 0 &&
            fsm->bat_wake_screen == 0)
            return "no_settle";
        if (sus_pct >= 60) return "stable_dominant";
        if (fsm->ses_time_heavy_sec > 0 || fsm->ses_time_gaming_sec > 0) return "active_burst";
        return "mixed";
    }
    return "mixed";
}

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
    if (fsm->profile_idx == PROFILE_BATTERY && fsm->bat_wake_bg >= 10) return "wake_spike";
    if (dur < 60) return "too_short";
    return "none";
}

static void session_history_append_ex(const asb_fsm_t *fsm, const char *reason) {
    if (fsm->ses_sustained_entries == 0 && fsm->ses_time_heavy_sec < 10
        && fsm->bat_time_deep_idle_sec < 60)
        return;

    /* skip boundary carry-over sessions
     * dur<=0: impossible real session for any profile -- always skip
     * dur<60: short hot profile switches for non-battery non-benchmark */
    long _dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (_dur <= 0) return;
    if (_dur < 60 && fsm->profile_idx != PROFILE_BATTERY
        && fsm->ses_intent != INTENT_BENCHMARK) {
        asb_log("session_history: skipping short boundary session (%lds, profile=%d)", _dur, fsm->profile_idx);
        return;
    }

    static const char *profile_names[] = {"battery","balanced","performance","smart"};
    static const char *mode_names[] = {"default","burst","stable","auto"};
    int mode_idx = g_asb_cfg.highload_mode;
    if (mode_idx < 0 || mode_idx > 3) mode_idx = 0;
    int avg_gap = (fsm->ses_gap_samples > 0)
                  ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0;
    long total_active = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec
                       + fsm->ses_time_sustained_sec;
    int sus_pct = (total_active > 0)
                  ? (int)(fsm->ses_time_sustained_sec * 100 / total_active) : 0;

    /*
     * session_history rotation — stream-based to avoid 1 MB stack allocation.
     * If file exceeds SESSION_HISTORY_SIZE_CAP_BYTES, force tighter trim by skipping more
     * lines until the resulting file fits.
     */
    int line_count = 0;
    long file_size = 0;
    {
        FILE *rf = fopen(SESSION_HISTORY_FILE, "r");
        if (rf) {
            char buf[SESSION_HISTORY_LINE_MAX];
            while (fgets(buf, sizeof(buf), rf)) {
                file_size += (long)strlen(buf);
                if (buf[0] == '{') line_count++;
            }
            fclose(rf);
        }
    }

    /* Determine how many lines to skip from the start to keep last (MAX-1) */
    int skip = (line_count >= SESSION_HISTORY_MAX) ? line_count - SESSION_HISTORY_MAX + 1 : 0;

    /* Hard size cap: if estimated retained bytes still exceed cap, increase skip */
    if (file_size > SESSION_HISTORY_SIZE_CAP_BYTES && line_count > 0) {
        long avg_line = file_size / (line_count > 0 ? line_count : 1);
        if (avg_line < 1) avg_line = 1;
        long max_lines_for_cap = SESSION_HISTORY_SIZE_CAP_BYTES / avg_line;
        if (max_lines_for_cap > 0 && line_count - skip > (int)max_lines_for_cap) {
            skip = line_count - (int)max_lines_for_cap + 1;
            if (skip < 0) skip = 0;
        }
    }

    char tmp_path[256];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", SESSION_HISTORY_FILE);
    FILE *wf = fopen(tmp_path, "w");
    if (!wf) return;

    /* Pass 2: stream existing lines, skipping first `skip` */
    {
        FILE *rf = fopen(SESSION_HISTORY_FILE, "r");
        if (rf) {
            char buf[SESSION_HISTORY_LINE_MAX];
            int idx = 0;
            while (fgets(buf, sizeof(buf), rf)) {
                if (buf[0] != '{') continue;
                if (idx >= skip) {
                    /* strip trailing newline then re-emit */
                    int len = (int)strlen(buf);
                    if (len > 0 && buf[len-1] == '\n') buf[len-1] = '\0';
                    fputs(buf, wf);
                    fputc('\n', wf);
                }
                idx++;
            }
            fclose(rf);
        }
    }

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M", tm);
    
    long dur = (fsm->ses_start_ts > 0) ? (now - fsm->ses_start_ts) : 0;
    int idle_quality = -1;
    if (fsm->profile_idx == PROFILE_BATTERY ||
        fsm->profile_idx == PROFILE_SMART) {
        long bat_total = fsm->bat_time_deep_idle_sec +
                         fsm->bat_time_light_idle_sec +
                         fsm->bat_time_moderate_sec;
        if (bat_total > 60) {
            idle_quality = (int)(fsm->bat_time_deep_idle_sec * 100 / bat_total);
            int wake_penalty = (fsm->bat_wake_bg > 2)
                               ? (fsm->bat_wake_bg - 2) * 5 : 0;
            idle_quality -= wake_penalty;
            if (idle_quality < 0) idle_quality = 0;
        }
    }
    int cap_eff = -1;
    if (fsm->ses_gaming_entries > 0 && avg_gap > 0) {
        int target = asb_profile_bounds_for(fsm->profile_idx)->ceil.cpu_max[0];
        if (target > 0) {
            cap_eff = (int)((target - avg_gap) * 100 / target);
            if (cap_eff < 0) cap_eff = 0;
            if (cap_eff > 100) cap_eff = 100;
        }
    }
    /* headroom session metrics */
    int hr_avg = (fsm->ses_headroom_samples > 0)
                 ? (int)(fsm->ses_headroom_sum / fsm->ses_headroom_samples) : -1;
    int hr_min = (fsm->ses_headroom_samples > 0) ? fsm->ses_headroom_min : -1;
    int hr_b70 = fsm->ses_headroom_below70;
    int hr_b50 = fsm->ses_headroom_below50;

    /* session-level limiter, reachability, battery reason */
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
        else if (cap_eff >= 0 && cap_eff < 40 && hr_min >= 80
                 && !thermal_hot && fsm->ses_unreachable_entries >= 5)
            limiter = "vendor_clamp";  /* hard clamp: good headroom, low temp, but caps not reached */
        else if (cap_eff >= 0 && cap_eff < 40 && !thermal_hot
                 && fsm->ses_unreachable_entries >= 10 && b50_pct < 10)
            limiter = "vendor_clamp";  /* unreachable-dominant: massive gap, moderate headroom, not thermal */
        else if (cap_eff >= 0 && cap_eff < 40 && !thermal_hot
                 && fsm->clamp_hold && b50_pct < 10)
            limiter = "vendor_clamp";  /* hold-aware -- futility confirmed clamp, unreachable suppressed */
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

    /* session-level classification fields */
    const char *conf = classify_confidence(fsm, dur, fsm->ses_headroom_samples, idle_quality);
    const char *sig  = classify_signature(fsm, sus_pct, limiter, reach, bat_reason, conf, idle_quality);
    const char *anomaly = classify_anomaly(fsm, dur, idle_quality, cap_eff);

    /* cap reach when anomaly shows session was clearly limited */
    if (strcmp(anomaly, "extreme_temp") == 0 && reach > 75) {
        reach = 75;
        if (fsm->ses_time_to_first_sus > 0 && fsm->ses_time_to_first_sus < 90)
            reach = 65;
    }
    int mid_tune_n = fsm->ses_mid_tune_count;
    const char *mid_tune = "none";
    if (mid_tune_n > 0) mid_tune = (mid_tune_n >= 3) ? "heavy" : "light";

    /* battery outcome classification + trust for session history */
    int bat_trust_val = -1;
    const char *bat_outcome = "none";
    if (fsm->profile_idx == PROFILE_BATTERY ||
        fsm->profile_idx == PROFILE_SMART) {
        bat_trust_val = battery_session_trust(fsm);
        long _bt_o = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec
                     + fsm->bat_time_moderate_sec;
        int _iq_o = (_bt_o > 0) ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt_o) : 0;
        /* V56: noise = BACKGROUND wakes; the user's own screen checks are not
         * wake noise (field data: 53% of sessions were rejected as wake_noisy
         * with wake_bg=0 -- every single wake was the user's screen). */
        float _wph_o = (dur > 0) ? (float)fsm->bat_wake_bg * 3600.0f / dur : 0;
        if (bat_trust_val == BAT_TRUST_CLEAN && _iq_o >= 40 && _wph_o < 2.0f
            && dur >= 7200 && !fsm->ses_auto_degraded)
            bat_outcome = "clean_night";
        else if (bat_trust_val == BAT_TRUST_CLEAN && _iq_o >= 20)
            bat_outcome = "clean_day";
        else if (_wph_o > 10.0f)
            bat_outcome = "wake_noisy";
        else if (_iq_o < 20 && dur >= 300)
            bat_outcome = "no_settle";
        else if (fsm->ses_max_temp >= 45)
            bat_outcome = "thermal_warm";
        else if (bat_trust_val == BAT_TRUST_DIRTY)
            bat_outcome = "hostile";
        else
            bat_outcome = "mixed";
    }

    /* performance outcome classification */
    const char *perf_outcome = "none";
    if (fsm->profile_idx == PROFILE_PERFORMANCE) {
        if (fsm->had_futility && fsm->clamp_hold && cap_eff < 40)
            perf_outcome = "vendor_clamped";
        else if (fsm->had_futility && !fsm->clamp_hold)
            perf_outcome = "recovered_clamp";
        else if (fsm->ses_max_temp >= 90 || (fsm->ses_thermal_entries >= 3 && sus_pct >= 30))
            perf_outcome = "thermal_limited";
        else if (fsm->ses_auto_degraded)
            perf_outcome = "degraded";
        else if (fsm->ses_sustained_entries == 0 && fsm->ses_max_temp < 70)
            perf_outcome = "clean";
        else
            perf_outcome = "mixed";
    }

    int would_be_noisy = 0;
    char noisy_dim[96] = "";
    if (fsm->profile_idx == PROFILE_BATTERY) {
        long _bt = fsm->bat_time_deep_idle_sec
                   + fsm->bat_time_light_idle_sec
                   + fsm->bat_time_moderate_sec;
        float _wph = (dur > 0)
                     ? (float)fsm->bat_wake_cycles * 3600.0f / dur : 0.0f;
        if (idle_quality >= 8 && idle_quality <= 19
            && _wph >= 12.0f && _wph <= 25.0f
            && fsm->bat_wake_cycles >= 10 && fsm->bat_wake_cycles <= 50
            && dur >= 1800 && _bt > 600) {
            would_be_noisy = 1;
        }
        snprintf(noisy_dim, sizeof(noisy_dim),
                 "iq=%d wph=%.1f wake=%d bg=%d scr=%d dur=%ld bt=%ld",
                 idle_quality, _wph, fsm->bat_wake_cycles,
                 fsm->bat_wake_bg, fsm->bat_wake_screen, dur, _bt);
    }

    fprintf(wf,
        "{\"v\":16,\"ts\":\"%s\",\"profile\":\"%s\",\"mode\":\"%s\",\"end\":\"%s\","
        "\"gaming\":%d,\"sustained\":%d,\"thermal\":%d,\"unreachable\":%d,"
        "\"t_heavy\":%ld,\"t_gaming\":%ld,\"t_sustained\":%ld,"
        "\"avg_gap\":%d,\"max_temp\":%d,\"skin_max_temp\":%d,\"surface_max_temp\":%d,\"board_max_temp\":%d,\"degraded\":%d,"
        "\"temp_invalid_n\":%d,\"temp_last_reason\":\"%s\","
        "\"t2s\":%ld,\"t2th\":%ld,\"t2g\":%ld,\"eff\":%d,\"recovery\":%d,"
        "\"sus_pct\":%d,"
        "\"bat_deep\":%ld,\"bat_light\":%ld,\"bat_mod\":%ld,"
        "\"bat_wake\":%d,\"bat_ttd\":%ld,"
        "\"wake_screen\":%d,\"wake_bg\":%d,\"radio_ticks\":%d,"
        "\"idle_q\":%d,\"cap_eff\":%d,\"dur\":%ld,"
        "\"intent\":\"%s\",\"deg_age\":%ld,"
        "\"asb\":\"%s\",\"learn_exempt\":%d,"
        "\"hr_avg\":%d,\"hr_min\":%d,\"hr_b70\":%d,\"hr_b50\":%d,\"hr_n\":%d,"
        "\"limiter\":\"%s\",\"reach\":%d,\"bat_reason\":\"%s\","
        "\"conf\":\"%s\",\"sig\":\"%s\",\"mid_tune\":\"%s\",\"mid_n\":%d,\"anomaly\":\"%s\","
        "\"clamp_hold\":%d,\"had_clamp_hold\":%d,\"had_futility\":%d,"
        "\"bat_trust\":%d,\"bat_outcome\":\"%s\",\"perf_outcome\":\"%s\","
        "\"env\":\"%s\","
        "\"mem_psi_peak\":%d,\"mem_press_ticks\":%d,"
        "\"would_be_noisy\":%d,\"noisy_dim\":\"%s\","
        "\"adv_score\":%d,\"adv_active\":%d,\"adv_vote_skin\":%d,\"adv_vote_surface\":%d,\"adv_vote_board\":%d,\"adv_would_bias\":%d,"
        "\"bias_mode_a_count\":%d,\"bias_mode_b_count\":%d,"
        "\"smart_mode\":%d,\"bucket_id\":%d,\"daypart\":%d,\"is_weekend\":%d,"
        "\"bucket_confidence\":%d,\"alpha_battery\":%d,"
        "\"smart_fallback_level\":%d,\"sleep_override_n\":%d,\"thermal_veto_n\":%d,"
        "\"app_hint_top\":%d,\"pkg_hash_top\":\"%016llx\"}\n",
        ts, profile_names[fsm->profile_idx], mode_names[mode_idx], reason,
        fsm->ses_gaming_entries, fsm->ses_sustained_entries,
        fsm->ses_thermal_entries, fsm->ses_unreachable_entries,
        fsm->ses_time_heavy_sec, fsm->ses_time_gaming_sec,
        fsm->ses_time_sustained_sec,
        avg_gap, fsm->ses_max_temp, fsm->ses_max_skin_temp, fsm->ses_max_surface_temp, fsm->ses_max_board_temp, fsm->ses_auto_degraded,
        fsm->ses_temp_invalid_count,
        fsm->ses_last_temp_reason[0] ? fsm->ses_last_temp_reason : "ok",
        fsm->ses_time_to_first_sus, fsm->ses_time_to_first_thermal,
        fsm->ses_time_to_first_gaming,
        fsm->ses_sustained_efficiency, fsm->ses_recovery_count,
        sus_pct,
        fsm->bat_time_deep_idle_sec, fsm->bat_time_light_idle_sec,
        fsm->bat_time_moderate_sec,
        fsm->bat_wake_cycles, fsm->bat_time_to_first_deep,
        fsm->bat_wake_screen, fsm->bat_wake_bg, fsm->bat_radio_active_ticks,
        idle_quality, cap_eff, dur,
        (fsm->ses_intent >= 0 && fsm->ses_intent <= 6)
            ? intent_names[fsm->ses_intent] : "unknown",
        fsm->ses_degrade_at_age,
        ASB_VERSION,
        (fsm->ses_intent == INTENT_BENCHMARK) ? 1 : 0,
        hr_avg, hr_min, hr_b70, hr_b50, fsm->ses_headroom_samples,
        limiter, reach, bat_reason,
        conf, sig, mid_tune, mid_tune_n, anomaly,
        fsm->clamp_hold, fsm->had_clamp_hold, fsm->had_futility,
        bat_trust_val, bat_outcome, perf_outcome,
        (const char *[]){"quiet","noisy","hostile"}[classify_environment(fsm)],
        fsm->mem_psi_peak_x100, fsm->mem_pressure_ticks,
        would_be_noisy, noisy_dim,
        fsm->thermal_advisory_score, fsm->thermal_advisory_active,
        fsm->thermal_vote_skin, fsm->thermal_vote_surface, fsm->thermal_vote_board,
        fsm->would_bias_exit_gaming,
        fsm->would_bias_mode_a_count, fsm->would_bias_mode_b_count,
        /* Smart Mode fields */
        g_smart_rt.enabled,
        g_smart_rt.bucket_id,
        g_smart_rt.daypart,
        g_smart_rt.is_weekend,
        g_smart_rt.conf_x1000,
        g_smart_rt.alpha_battery_x1000,
        g_smart_rt.fallback_level,
        /* sleep_override_n / thermal_veto_n: alpha tracks current state only,
         * not session counters (deferred to dedicated counters) */
        g_smart_rt.night_safe_override ? 1 : 0,
        g_smart_rt.thermal_veto ? 1 : 0,
        g_smart_rt.app_hint_session_top,
        (unsigned long long)g_smart_rt.app_hash_session_top);

    /* Smart Mode: feed session outcome into bucket learning (smart_mode=1 only)
     *
     * fix211: and only while the Smart PROFILE is actually running. The flag says the
     * user chose Smart at some point; it stays 1 in memory across a live switch to
     * Battery/Balanced/Performance (the socket command updates profile_idx, nobody
     * re-reads the flag) - and every session after such a switch banked its drain,
     * measured under the manual profile's own ceilings, into Smart's buckets. A battery
     * profile day taught the learner this bucket is cheap; a performance day, that it is
     * dear. Both are the manual profile's numbers, not Smart's - the learner must never
     * see them. (The per-app records already gate on the profile, see the recorder arm.) */
    if (g_smart_rt.enabled && g_smart_store_loaded && dur > 0 &&
        fsm->profile_idx == PROFILE_SMART) {
        asb_smart_session_input_t sin = {0};
        sin.dur_s = (int)dur;
        /* The smoothed session peak (fix110), not the single hottest sample: a one-tick
         * launch spike must not teach the whole slot to lean toward battery. Falls back to
         * the raw peak only when no valid sample was smoothed. */
        sin.max_temp_c = (fsm->ses_max_temp_sm > 0) ? fsm->ses_max_temp_sm : fsm->ses_max_temp;
        /* A session with no smoothed sample at all lay entirely in the boot window; the
         * startup quarantine below marks it DIRTY, so the raw fallback never teaches. */
        /* Record it as handed over, before anything downstream can average it away. */
        g_ses_last_temp = sin.max_temp_c;
        g_ses_last_dur  = (int)dur;
        snprintf(g_ses_last_reason, sizeof(g_ses_last_reason), "%s", reason ? reason : "?");
        sin.max_skin_c = fsm->ses_max_skin_temp;
        sin.net_kibps = (g_ses_net_samples > 0)
                      ? (int)(g_ses_net_kib_sum / g_ses_net_samples) : 0;
        /* fix185: climate. A pack under 5 C (the gauge's percentage shrinks in the cold and
         * comes back when warm), a cold pack warming or cooling by 3 C (outdoors <-> indoors),
         * a pack ending 3 C below where it started (use only heats it: the surroundings did
         * that, or the charger's warmth leaving), or a session in the first 20 minutes after
         * the charger. Decided from the session's own battery readings. */
        {
            int _cl = 0;
            if (g_ses_bat_t0_dc > -10000) {
                int _rg = g_ses_bat_tmax_dc - g_ses_bat_tmin_dc;
                if (g_ses_bat_tmin_dc < 50) _cl = 1;
                else if (g_ses_bat_tmin_dc < 100 && _rg >= 30) _cl = 2;
                else if (g_ses_bat_t0_dc - g_ses_bat_tmin_dc >= 30) _cl = 3;
            }
            if (!_cl && g_ses_post_unplug) _cl = 4;
            sin.climate = _cl ? 1 : 0;
            g_ses_climate_last = _cl;
            if (_cl)
                asb_log("smart: session drain set aside - %s (battery %d..%d dC, started %d dC)",
                        _cl == 1 ? "cold pack" : _cl == 2 ? "cold pack changing temperature" :
                        _cl == 3 ? "pack cooled by its surroundings" : "right after the charger",
                        g_ses_bat_tmin_dc, g_ses_bat_tmax_dc, g_ses_bat_t0_dc);
            g_ses_bat_t0_dc = -10000; g_ses_bat_tmin_dc = 10000; g_ses_bat_tmax_dc = -10000;
            g_ses_post_unplug = 0;
        }
        g_ses_net_kib_sum = 0;
        g_ses_net_samples = 0;
        sin.trust = (bat_trust_val >= 0) ? bat_trust_val : ASB_TRUST_PARTIAL;
        sin.was_heavy = (fsm->ses_time_heavy_sec > 60 || fsm->ses_time_gaming_sec > 60) ? 1 : 0;
        sin.was_thermal_hit = (fsm->ses_thermal_entries > 0) ? 1 : 0;
        sin.sustained_pct = sus_pct;
        sin.idle_q_x10 = (idle_quality >= 0) ? idle_quality * 10 : 0;
        sin.drain_pctph_x10 = 0;
        sin.drain_on_sec = (int)g_smart_drain_on_sec;
        if (g_smart_drain_on_sec >= ASB_SMART_DRAIN_MIN_ON_SEC) {
            long r = (g_smart_drain_drop_x100 * 360L) / g_smart_drain_on_sec;
            if (r < 0) r = 0;
            if (r > 6000) r = 6000;
            sin.drain_pctph_x10 = (int)r;
        }
        /* The recent screen-on drain (fix186): a ratio of decayed sums, not a mean of
         * per-session ratios.
         *
         * The battery level moves in whole percent, and a 20-minute session at 8 %/h sees a
         * step or two - or none. Sessions with no step were left out ("> 0"), while the
         * ones that caught a step went in at full rate, so the average ran above the real
         * drain: an OP15 Smart capture forecast 12.5 %/h (7 h to empty) against 8-10 %/h
         * measured in every screen-on phase and 8.2 %/h in the drain meter. That rate also
         * sets the battery budget, which trims the phone when the forecast looks short.
         * Summing the level drop and the screen-on time across sessions - older ones
         * fading by a quarter each - counts the quiet sessions too and weights each by its
         * length. A session right after the charger is left out: its level sits at the top. */
        if (sin.drain_on_sec >= ASB_SMART_DRAIN_MIN_ON_SEC && g_ses_climate_last != 4) {
            g_drain_rs_drop_x100 = g_drain_rs_drop_x100 * 3 / 4 + g_smart_drain_drop_x100;
            g_drain_rs_on_s      = g_drain_rs_on_s * 3 / 4 + (long)g_smart_drain_on_sec;
            if (g_drain_rs_drop_x100 > 0 && g_drain_rs_on_s >= ASB_SMART_DRAIN_MIN_ON_SEC) {
                long r = (long)(g_drain_rs_drop_x100 * 360L / g_drain_rs_on_s);
                if (r < 1) r = 1;
                if (r > 6000) r = 6000;
                g_smart_drain_rate_ewma_x10 = (int)r;
            }
        }
        if (sin.drain_pctph_x10 > 0) {
            if (sin.drain_pctph_x10 >= ASB_SMART_APPHEAT_DRAIN_SAMPLE_X10 &&
                g_smart_rt.app_hash_session_top != 0) {
                asb_smart_appheat_drain_bump(g_smart_rt.app_hash_session_top, time(NULL));
            }
        }
        {
            int _qv = (sin.drain_on_sec >= ASB_SMART_DRAIN_MIN_ON_SEC);
            int _vph = -1;
            if (sin.dur_s >= 900 &&
                sin.drain_on_sec >= 600 &&
                g_v44_clamp_total >= g_smart_ses_clamp_start) {
                unsigned long _cd = g_v44_clamp_total - g_smart_ses_clamp_start;
                /* Only judge vendor-war when the absolute clamp count is
                   meaningful; a handful of clamps extrapolated over a short
                   session produces a misleading per-hour rate and false
                   primary_failure=vendor_war verdicts. */
                if (_cd >= 20) {
                    _vph = (int)((_cd * 3600UL) / (unsigned long)sin.dur_s);
                    if (_vph > 9999) _vph = 9999;
                }
            }
            asb_smart_quality_t _qb;
            int _q = asb_smart_session_quality_ex(sin.drain_pctph_x10, _qv,
                                               sin.max_temp_c,
                                               fsm->ses_thermal_entries,
                                               fsm->ses_recovery_count,
                                               _vph,
                                                  g_smart_rt.therm_warm_x10 > 0 ? (g_smart_rt.therm_warm_x10 - ASB_SMART_THERM_WARM_OFFSET_X10) / 10 : 0, &_qb);
            g_smart_last_quality = _q;
            g_smart_q_bat = _qb.q_battery;
            g_smart_q_heat = _qb.q_heat;
            g_smart_q_stab = _qb.q_stability;
            g_smart_q_vendor = _qb.q_vendor;
            g_smart_q_fail = _qb.primary_failure;
            if (g_smart_quality_ewma < 0) g_smart_quality_ewma = _q;
            else g_smart_quality_ewma = (g_smart_quality_ewma * 3 + _q) / 4;
            g_smart_ses_clamp_start = g_v44_clamp_total;
        }
        /* Carry the last usable rate across the session boundary.
         *
         * The window resets at the end of every session, and a session ends whenever the
         * screen goes off - so a phone used in short bursts almost never accumulated the
         * 300 seconds of continuous screen-on the estimate needs, and the banner sat on
         * "measuring..." for hours. Reported after three hours of ordinary use.
         *
         * The measurement itself must stay per-session: mixing a gaming session into a
         * reading one produces a number describing neither. But the LAST completed
         * measurement is still the best answer available until a new one exists, so it is
         * kept and published as such rather than thrown away.
         */
        if (g_smart_drain_on_sec >= 300 && g_smart_drain_drop_x100 > 0) {
            g_smart_drain_last_x10 = (g_smart_drain_drop_x100 * 360L) / g_smart_drain_on_sec;
            g_smart_drain_last_ts  = time(NULL);
        }
        g_smart_drain_on_sec = 0;
        g_smart_drain_drop_x100 = 0;
        /* Estimate screen_on_pct from bat_wake counters (rough approximation) */
        if (fsm->bat_wake_cycles > 0 && dur > 0) {
            sin.screen_on_pct = (int)((fsm->bat_wake_screen * 100L) / fsm->bat_wake_cycles);
        }

        /* P0-3: startup quarantine.
         *
         * The first minutes after boot are package rescan, app restore, sync and whatever
         * the user immediately opened - a burst that looks nothing like how the phone
         * behaves settled. Banked as a normal session it teaches the learner that this
         * bucket is expensive, and that conclusion outlives the boot by weeks.
         *
         * The samples are NOT discarded: the phase ledger and telemetry keep them, because
         * they are real evidence of what the phone did. They are marked DIRTY, which the
         * bucket updater already refuses - one mechanism, not a second policy.
         *
         * Thermal safety is untouched by this. Nothing here gates a temperature read or an
         * emergency clamp; a phone that overheats two minutes after boot is still
         * protected. Only the energy conclusions wait for a settled sample.
         */
        if (g_gov_start_ts > 0 &&
            (long)(time(NULL) - g_gov_start_ts) < ASB_STARTUP_QUARANTINE_S) {
            sin.trust = ASB_TRUST_DIRTY;
            g_startup_quarantined++;
            asb_log("smart: session inside startup window (%lds) - kept as telemetry, "
                    "not banked into learning",
                    (long)(time(NULL) - g_gov_start_ts));
        }

        /* Find current bucket and update */
        int bid = (int)asb_smart_bucket_id(g_smart_rt.daypart, g_smart_rt.is_weekend);
        if (bid >= 0 && bid < ASB_SMART_BUCKETS) {
            asb_smart_bucket_update_from_session_ex(
                &g_smart_store.buckets[bid], &sin, time(NULL),
                asb_smart_therm_median_x10(&g_smart_store) / 10);
            g_smart_sessions_since_save++;
            /* separate Smart-specific accounting */
            g_smart_sessions_total++;
            g_smart_bucket_updates++;
            g_smart_last_bucket_id = bid;
            g_smart_last_daypart = g_smart_rt.daypart;
            g_smart_last_confidence = g_smart_rt.conf_x1000;
            g_smart_last_update_ts = time(NULL);
            /* Day = morn/day/eve (2/3/4); Night = sleep/late (0/5); wake=1 floats */
            if (g_smart_rt.daypart == 0 || g_smart_rt.daypart == 5) {
                g_smart_sessions_night++;
            } else if (g_smart_rt.daypart >= 2 && g_smart_rt.daypart <= 4) {
                g_smart_sessions_day++;
            }
            if (g_smart_rt.app_hint_session_top >= ASB_APP_GAMING) {
                g_smart_sessions_gaming++;
            }
        }

        /* Reset session-top tracking for next session */
        g_smart_rt.app_hint_session_top = 0;
        g_smart_rt.app_hash_session_top = 0;
    }
    /* fix211: the drain carry and reset inside the block above belong to EVERY session,
     * not only Smart's. With the banking gated on the Smart profile, a manual-profile
     * session must still close out the measurement window - otherwise its seconds and
     * percent steps leak into the next Smart session's evidence. When the block above
     * ran, both accumulators are already zero and this is a no-op; when the session was
     * zero-length the old code kept them, and so does this. */
    if (dur > 0 && !(g_smart_rt.enabled && g_smart_store_loaded &&
                     fsm->profile_idx == PROFILE_SMART)) {
        if (g_smart_drain_on_sec >= 300 && g_smart_drain_drop_x100 > 0) {
            g_smart_drain_last_x10 = (g_smart_drain_drop_x100 * 360L) / g_smart_drain_on_sec;
            g_smart_drain_last_ts  = time(NULL);
        }
        g_smart_drain_on_sec = 0;
        g_smart_drain_drop_x100 = 0;
    }
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
    if (fsm->ses_intent == INTENT_IDLE_WARM)
        return BAT_TRUST_PARTIAL;
    int iq = 0;
    if (bat_total > 0) {
        iq = (int)(fsm->bat_time_deep_idle_sec * 100 / bat_total);
        int wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
        iq -= wp;
        if (iq < 0) iq = 0;
    }
    /* V56: wake NOISE = background wakes only; screen wakes are the user. */
    float wph = (dur > 0) ? (float)fsm->bat_wake_bg * 3600.0f / dur : 0;
    if (iq >= 12 && iq < 20 && dur >= 600 &&
        wph < 12.0f && fsm->bat_wake_bg < 24)
        return BAT_TRUST_PARTIAL;
    if (iq >= 8 && iq < 20 && dur >= 1800 && bat_total > 600 &&
        wph >= 12.0f && wph <= 25.0f &&
        fsm->bat_wake_bg >= 10 && fsm->bat_wake_bg <= 50)
        return BAT_TRUST_NOISY;
    if (iq < 20 && dur >= 300)
        return BAT_TRUST_DIRTY;
    if (wph > 10.0f)
        return BAT_TRUST_DIRTY;
    return BAT_TRUST_CLEAN;
}

/*
 * V56: read /proc/pressure/memory 'some avg10' as an integer x100 (e.g.
 * Note asb_smart.h has its own bucketed PSI reader for the alpha-bias path; this one returns
 * the raw scaled value for telemetry, which is why it's separate.
 */
static int asb_read_mem_psi_x100(void) {
    FILE *f = fopen("/proc/pressure/memory", "r");
    if (!f) return -1;
    char line[256];
    int out = -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "some ", 5) != 0) continue;
        char *p = strstr(line, "avg10=");
        if (!p) break;
        p += 6;
        int whole = 0, frac = 0;
        if (sscanf(p, "%d.%d", &whole, &frac) >= 1)
            out = whole * 100 + frac;
        break;
    }
    fclose(f);
    return out;
}

/* 'full avg10' x100: the share of time EVERY runnable task waited on memory (fix108). */
static int asb_read_mem_psi_full_x100(void) {
    FILE *f = fopen("/proc/pressure/memory", "r");
    if (!f) return -1;
    char line[256];
    int out = -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "full ", 5) != 0) continue;
        char *p = strstr(line, "avg10=");
        int whole = 0, frac = 0;
        if (p && sscanf(p + 6, "%d.%d", &whole, &frac) >= 1)
            out = whole * 100 + frac;
        break;
    }
    fclose(f);
    return out;
}

static int classify_environment(const asb_fsm_t *fsm) {
    long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (dur < 60) return ENV_QUIET;
    long bat_total = fsm->bat_time_deep_idle_sec +
                     fsm->bat_time_light_idle_sec +
                     fsm->bat_time_moderate_sec;
    int iq = 0;
    if (bat_total > 0) {
        iq = (int)(fsm->bat_time_deep_idle_sec * 100 / bat_total);
        int wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
        iq -= wp;
        if (iq < 0) iq = 0;
    }
    /* V56: environment hostility is about the RADIO/BACKGROUND environment;
     * the user picking the phone up is not a hostile environment. wph is
     * therefore background-wake rate (screen wakes excluded). */
    float wph = (dur > 0) ? (float)fsm->bat_wake_bg * 3600.0f / dur : 0;
    /* radio-aware -- heavy mobile data activity during screen-off
     * is a sign of hostile radio environment (push services, sync storms) */
    int radio_noisy = 0;
    if (dur > 120) {
        /* Most screen-off time now runs at TIMER_DEEP_S.  Dividing by the shorter idle period
         * after an adaptive cadence change would inflate the active-radio share and falsely
         * classify a quiet night as hostile, which in turn re-enables costly monitoring. */
        long expected_samples = dur / (TIMER_DEEP_S > 0 ? TIMER_DEEP_S : 30);
        if (expected_samples < 1) expected_samples = 1;
        int radio_pct = (int)((long)fsm->bat_radio_active_ticks * 100 / expected_samples);
        if (radio_pct > 30) radio_noisy = 1;  /* >30% of conservative samples had active data */
    }
    /*
     * V56 FIX: the idle-quality (iq) branch below is only meaningful when the session is
     * genuinely idle/screen-off dominant.
     */
    int idle_dominant = (bat_total > 0 &&
                         (fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec)
                             * 2 >= bat_total);

    /* Real radio-storm / excessive-wake signals apply in any session. */
    if (wph > g_asb_cfg.env_wph_hostile || (radio_noisy && iq < 20 && idle_dominant))
        return ENV_HOSTILE;
    /* Idle-quality-based hostility only when the session is idle-dominant. */
    if (idle_dominant && iq < g_asb_cfg.env_iq_hostile)
        return ENV_HOSTILE;
    if (wph > g_asb_cfg.env_wph_noisy || radio_noisy ||
        (idle_dominant && iq < g_asb_cfg.env_iq_quiet))
        return ENV_NOISY;
    return ENV_QUIET;
}

static int battery_fail_cause(const asb_fsm_t *fsm, int iq) {
    long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (dur < 120) return BAT_CAUSE_NONE;
    long bat_total = fsm->bat_time_deep_idle_sec +
                     fsm->bat_time_light_idle_sec +
                     fsm->bat_time_moderate_sec;
    float wph = (dur > 0) ? (float)fsm->bat_wake_bg * 3600 / dur : 0;
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

    /* don't self-tune during quarantine */
    if (fsm->plan.quarantine) {
        asb_log("self_tune: quarantine active, skipping");
        return;
    }
    /* don't self-tune during storm shield (noisy battery data) */
    if (g_storm_shield_active) {
        asb_log("self_tune: storm shield active, skipping");
        return;
    }

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

        /*
         * Never raise the throttle point above what the user configured.
         * Hitting SUSTAINED inside a minute usually means the threshold is too low for this
         * device, and nudging it up is the right reflex - unless a person went into the WebUI
         * and deliberately chose a LOWER one.
         */
        if (fsm->ses_time_to_first_sus > 0 &&
            fsm->ses_time_to_first_sus < 60 &&
            g_asb_cfg.sustained_temp_enter < 68 &&
            g_asb_cfg.sustained_temp_enter < g_asb_cfg.sustained_temp_enter_user) {
            int old = g_asb_cfg.sustained_temp_enter;
            g_asb_cfg.sustained_temp_enter += 2;
            if (g_asb_cfg.sustained_temp_enter > 68)
                g_asb_cfg.sustained_temp_enter = 68;
            if (g_asb_cfg.sustained_temp_enter > g_asb_cfg.sustained_temp_enter_user)
                g_asb_cfg.sustained_temp_enter = g_asb_cfg.sustained_temp_enter_user;
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
        long _now_ts = time(NULL);
        const long TUNE_MIN_GAP_S = 2 * 3600;

        if (trust == BAT_TRUST_DIRTY) {
            asb_log("self_tune: bat session dirty (too short), skipping");
        } else if (trust == BAT_TRUST_PARTIAL) {
            asb_log("self_tune: bat session partial (sleep/insufficient signal), skipping");
        } else if (trust == BAT_TRUST_NOISY) {
            asb_log("self_tune: bat session noisy (mixed-use), defensive tune only");
            /* Fall through to the cause-driven block via shared logic — */
            /* Implementation: jump directly to the bad-iq path below */
            if (iq >= 0 && iq < 40 && bat_total > 300 && cause != BAT_CAUSE_NONE) {
                asb_log("self_tune: noisy + bad iq=%d cause=%s, tuning by cause",
                        iq, cause_names[cause]);
                switch (cause) {
                case BAT_CAUSE_WAKE_NOISE:
                    if (g_asb_cfg.bat_fast_idle_s > BAT_FAST_IDLE_FLOOR &&
                        (_now_ts - bps->last_tune_ts_fast_idle) >= TUNE_MIN_GAP_S) {
                        int old = g_asb_cfg.bat_fast_idle_s;
                        g_asb_cfg.bat_fast_idle_s -= 1;
                        bps->last_tune_ts_fast_idle = _now_ts;
                        asb_log("self_tune: noisy+wake_noise -> bat_fast_idle %d->%d (cadence-gated)",
                                old, g_asb_cfg.bat_fast_idle_s);
                        tuned++;
                    }
                    break;
                default:
                    /* don't adjust on noisy + non-wake-noise causes */
                    break;
                }
            }
        } else if (bps->bat_tune_cooldown > 0) {
            bps->bat_tune_cooldown--;
            asb_log("self_tune: bat cooldown=%d, skipping tune this session", bps->bat_tune_cooldown + 1);
        } else if (iq >= 70 && bat_total > 300) {
            if (g_asb_cfg.bat_fast_idle_s < 8 &&
                (_now_ts - bps->last_tune_ts_fast_idle) >= TUNE_MIN_GAP_S) {
                int old = g_asb_cfg.bat_fast_idle_s;
                g_asb_cfg.bat_fast_idle_s += 1;
                bps->last_tune_ts_fast_idle = _now_ts;
                asb_log("self_tune: bat good iq=%d -> bat_fast_idle %d->%d (relax)",
                        iq, old, g_asb_cfg.bat_fast_idle_s);
                tuned++;
            }
            if (g_asb_cfg.bat_heavy_load_enter > 10.0f &&
                (_now_ts - bps->last_tune_ts_heavy_load) >= TUNE_MIN_GAP_S) {
                float old = g_asb_cfg.bat_heavy_load_enter;
                g_asb_cfg.bat_heavy_load_enter -= 1.0f;
                bps->last_tune_ts_heavy_load = _now_ts;
                asb_log("self_tune: bat good iq=%d -> bat_heavy_load %.1f->%.1f (relax)",
                        iq, old, g_asb_cfg.bat_heavy_load_enter);
                tuned++;
            }
            if (g_asb_cfg.bat_moderate_load_enter > 8.0f &&
                (_now_ts - bps->last_tune_ts_moderate_load) >= TUNE_MIN_GAP_S) {
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
                if (g_asb_cfg.bat_fast_idle_s > BAT_FAST_IDLE_FLOOR &&
                    (_now_ts - bps->last_tune_ts_fast_idle) >= TUNE_MIN_GAP_S) {
                    int old = g_asb_cfg.bat_fast_idle_s;
                    g_asb_cfg.bat_fast_idle_s -= 1;
                    if (g_asb_cfg.bat_fast_idle_s < BAT_FAST_IDLE_FLOOR)
                        g_asb_cfg.bat_fast_idle_s = BAT_FAST_IDLE_FLOOR;
                    bps->last_tune_ts_fast_idle = _now_ts;
                    asb_log("self_tune: wake_noise -> bat_fast_idle %d->%d (cadence-gated)",
                            old, g_asb_cfg.bat_fast_idle_s);
                    tuned++;
                }
                break;
            case BAT_CAUSE_SCREEN_ON:
                if (g_asb_cfg.bat_moderate_load_enter < 15.0f &&
                    (_now_ts - bps->last_tune_ts_moderate_load) >= TUNE_MIN_GAP_S) {
                    float old = g_asb_cfg.bat_moderate_load_enter;
                    g_asb_cfg.bat_moderate_load_enter += 1.0f;
                    bps->last_tune_ts_moderate_load = _now_ts;
                    asb_log("self_tune: screen_on -> bat_moderate_load %.1f->%.1f (cadence-gated)",
                            old, g_asb_cfg.bat_moderate_load_enter);
                    tuned++;
                }
                if (g_asb_cfg.bat_heavy_load_enter < 20.0f &&
                    (_now_ts - bps->last_tune_ts_heavy_load) >= TUNE_MIN_GAP_S) {
                    float old = g_asb_cfg.bat_heavy_load_enter;
                    g_asb_cfg.bat_heavy_load_enter += 1.0f;
                    bps->last_tune_ts_heavy_load = _now_ts;
                    asb_log("self_tune: screen_on -> bat_heavy_load %.1f->%.1f (cadence-gated)",
                            old, g_asb_cfg.bat_heavy_load_enter);
                    tuned++;
                }
                break;
            case BAT_CAUSE_NO_SETTLE:
                if (g_asb_cfg.bat_fast_idle_s > BAT_FAST_IDLE_FLOOR &&
                    (_now_ts - bps->last_tune_ts_fast_idle) >= TUNE_MIN_GAP_S) {
                    int old = g_asb_cfg.bat_fast_idle_s;
                    g_asb_cfg.bat_fast_idle_s -= 1;
                    if (g_asb_cfg.bat_fast_idle_s < BAT_FAST_IDLE_FLOOR)
                        g_asb_cfg.bat_fast_idle_s = BAT_FAST_IDLE_FLOOR;
                    bps->last_tune_ts_fast_idle = _now_ts;
                    asb_log("self_tune: no_settle -> bat_fast_idle %d->%d (cadence-gated)",
                            old, g_asb_cfg.bat_fast_idle_s);
                    tuned++;
                }
                if (g_asb_cfg.bat_moderate_load_enter < 15.0f &&
                    (_now_ts - bps->last_tune_ts_moderate_load) >= TUNE_MIN_GAP_S) {
                    float old = g_asb_cfg.bat_moderate_load_enter;
                    g_asb_cfg.bat_moderate_load_enter += 1.0f;
                    bps->last_tune_ts_moderate_load = _now_ts;
                    asb_log("self_tune: no_settle -> bat_moderate_load %.1f->%.1f (cadence-gated)",
                            old, g_asb_cfg.bat_moderate_load_enter);
                    tuned++;
                }
                break;
            }
            bps->bat_tune_cooldown = 2;
        }

        if (bat_total > 300 && fsm->bat_time_moderate_sec > 0 &&
            (_now_ts - bps->last_tune_ts_light_gpu) >= TUNE_MIN_GAP_S) {
            int mod_pct = (int)(fsm->bat_time_moderate_sec * 100 / bat_total);
            if (mod_pct > 40 && g_asb_cfg.bat_light_idle_gpu > 5) {
                int old = g_asb_cfg.bat_light_idle_gpu;
                g_asb_cfg.bat_light_idle_gpu -= 2;
                if (g_asb_cfg.bat_light_idle_gpu < 5)
                    g_asb_cfg.bat_light_idle_gpu = 5;
                bps->last_tune_ts_light_gpu = _now_ts;
                asb_log("self_tune: bat MODERATE=%d%% -> bat_light_idle_gpu %d->%d (cadence-gated)",
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
    int n = (int)read(fd, buf, sizeof(buf)-1);
    close(fd);
    if (n <= 0) return PROFILE_BALANCED;
    buf[n] = '\0';
    for (int i = 0; buf[i]; i++)
        if (buf[i] == '\n' || buf[i] == '\r') { buf[i] = '\0'; break; }
    if (strcmp(buf, "battery")     == 0) return PROFILE_BATTERY;
    if (strcmp(buf, "performance") == 0) return PROFILE_PERFORMANCE;
    if (strcmp(buf, "smart")       == 0) return PROFILE_SMART;
    return PROFILE_BALANCED;
}

static int make_timerfd_clock(int clk, int secs) {
    int fd = timerfd_create(clk, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0 && clk != CLOCK_MONOTONIC) fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0) return -1;
    struct itimerspec its = {
        .it_interval = { secs, 0 },
        .it_value    = { secs, 0 }
    };
    timerfd_settime(fd, 0, &its, NULL);
    return fd;
}
static int make_timerfd(int secs) { return make_timerfd_clock(CLOCK_MONOTONIC, secs); }

/* Change a periodic timer's interval in place, keeping it periodic.
 *
 * arm_timerfd below is one-shot: it sets it_value and leaves it_interval zero, which is
 * right for the wake-up nudge it was written for and would silently stop the screen-on
 * tick after a single fire. */
static void arm_timerfd_periodic(int fd, int secs) {
    struct itimerspec its = {
        .it_interval = { secs, 0 },
        .it_value    = { secs, 0 }
    };
    timerfd_settime(fd, 0, &its, NULL);
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

/* A real one-shot. arm_timerfd above sets it_interval too, so it is periodic despite the
 * name; a "re-check in one second" armed with it kept firing every second until something
 * re-armed the timer - with the screen still off, after an always-on-display pulse. */
static void arm_timerfd_once_ms(int fd, int ms) {
    struct itimerspec its = {
        .it_interval = { 0, 0 },
        .it_value    = { ms / 1000, (long)(ms % 1000) * 1000000L }
    };
    timerfd_settime(fd, 0, &its, NULL);
}
/* Display-event follow-up: when the last display uevent arrived while the screen read off,
 * and how many quick re-checks have been spent on it. */
static time_t g_disp_evt_ts = 0;
static int    g_disp_retry  = 0;
static time_t g_disp_single_ts = 0;   /* when the last single (budget-time) re-check was armed */

/* 1 when the timer runs periodically, 2 when only a one-shot is pending, 0 when disarmed. */
static int timerfd_state(int fd) {
    struct itimerspec cur;
    if (timerfd_gettime(fd, &cur) != 0) return 0;
    if (cur.it_interval.tv_sec || cur.it_interval.tv_nsec) return 1;
    if (cur.it_value.tv_sec || cur.it_value.tv_nsec) return 2;
    return 0;
}

static void timerfd_drain(int fd) {
    uint64_t exp;
    ssize_t _r = read(fd, &exp, sizeof(exp));
    (void)_r;
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

/* Split recv from parse so the drain loop can also bucket each event by subsystem;
 * the old shape read the buffer inside the parser and threw the source away. */
static int recv_uevent(int fd, char *buf, size_t cap) {
    int n = (int)recv(fd, buf, (size_t)(cap - 1), MSG_DONTWAIT);
    if (n <= 0) return -1;
    buf[n] = '\0';
    return n;
}

/* Returns 1 (explicit on), 0 (explicit off), -2 (a display event with no power marker:
 * "something changed, re-read") or -1 (not a display event).
 *
 * The no-marker case used to return 0, i.e. "off". Thousands of DRM/panel events a day carry
 * no POWER=/BLANK= field - including the one sent when the screen turns on - so the ON branch
 * never ran: the governor log of every capture has "screen OFF (uevent)" lines and not a single
 * "screen ON (uevent)". The decision was always the sysfs read anyway; what the parse decides is
 * whether a quick re-check is worth arming, and "unknown" must allow it. */
static int parse_uevent_screen_buf(char *buf, int n) {
    int is_display = 0, is_power = -2;
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

static asb_uev_src_t uevent_bucket(const char *buf, int n) {
    /* NUL-separated key=value pairs; SUBSYSTEM= is the authoritative source. */
    const char *p = buf, *end = buf + n;
    while (p < end) {
        if (strncmp(p, "SUBSYSTEM=", 10) == 0) {
            const char *s = p + 10;
            if (strncmp(s, "power_supply", 12) == 0) return ASB_UEV_POWER;
            if (strncmp(s, "backlight", 9) == 0)    return ASB_UEV_DISPLAY;
            if (strncmp(s, "drm", 3) == 0)          return ASB_UEV_DISPLAY;
            if (strncmp(s, "net", 3) == 0)          return ASB_UEV_NET;
            if (strncmp(s, "sound", 5) == 0)        return ASB_UEV_SOUND;
            if (strncmp(s, "usb", 3) == 0)          return ASB_UEV_USB;
            if (strncmp(s, "thermal", 7) == 0)      return ASB_UEV_THERMAL;
            if (strncmp(s, "wakeup", 6) == 0)       return ASB_UEV_WAKEUP;
            return ASB_UEV_OTHER;
        }
        p += strlen(p) + 1;
    }
    return ASB_UEV_OTHER;
}

/*
 * Smart Media Guard: a narrow, explicit guard for a known media/feed/browser app that
 * reaches the FSM's game-like CPU+GPU band. A package has to be freshly detected and
 * positively recognised as media; an unknown app, stale package and any known game all
 * fail closed. This keeps the switch from becoming a universal performance cap.
 */
static int asb_smart_media_guard_observe(const asb_metrics_t *m,
                                         const asb_fsm_t *fsm,
                                         time_t now) {
    int was_active = g_smart_media_guard_active;
    const char *why = "disabled";
    int eligible = 0;
    if (!g_asb_cfg.smart_media_guard) {
        why = "disabled";
    } else if (!m || !fsm || fsm->profile_idx != PROFILE_SMART) {
        why = "profile_not_smart";
    } else if (!m->misc.screen_on || m->bat.charging) {
        why = "not_screenon_discharge";
    } else if (fsm->thermal_cap) {
        why = "thermal_cap";
    } else if (fsm->state != ASB_STATE_GAMING) {
        why = "state_not_gaming";
    } else if (!g_pkg_detect_ok || !g_smart_media_pkg_known ||
               g_smart_rt.app_hint >= ASB_APP_GAMING) {
        why = "no_fresh_known_media_pkg";
    } else if (m->gpu.load_pct < g_asb_cfg.gaming_gpu_enter) {
        why = "gpu_below_gaming_entry";
    } else if (m->cpu.load1 < ASB_GAMING_MIN_LOAD1 || m->cpu.load1 >= 12.0f) {
        why = "cpu_outside_media_band";
    } else {
        eligible = 1;
        why = "warming";
    }

    if (!eligible) {
        g_smart_media_guard_since = 0;
        g_smart_media_guard_active = 0;
    } else {
        if (g_smart_media_guard_since == 0) g_smart_media_guard_since = now;
        if ((long)(now - g_smart_media_guard_since) >= 60) {
            g_smart_media_guard_active = 1;
            why = "active";
        } else {
            g_smart_media_guard_active = 0;
        }
    }
    snprintf(g_smart_media_guard_reason, sizeof(g_smart_media_guard_reason), "%s", why);
    return was_active != g_smart_media_guard_active;
}

static void asb_smart_media_guard_apply_caps(asb_profile_caps_t *caps) {
    enum { ASB_SMART_MEDIA_GUARD_GPU_MAX_PCT = 70 };
    if (!caps || !g_smart_media_guard_active) return;
    if (caps->gpu_max_pct > ASB_SMART_MEDIA_GUARD_GPU_MAX_PCT)
        caps->gpu_max_pct = ASB_SMART_MEDIA_GUARD_GPU_MAX_PCT;
    if (caps->gpu_min_pct > caps->gpu_max_pct)
        caps->gpu_min_pct = caps->gpu_max_pct;
}

/*
 * Smart Mode tick — compute effective runtime values and update g_smart_bounds slot if a
 * meaningful change occurred.
 * Returns: 1 if g_smart_bounds was updated this tick (caller should refresh FSM caps
 * immediately so they reflect the new bounds), 0 otherwise.
 */
/* A night slot with the screen on (fix150).
 *
 * The SLEEP (00-06) and LATE (21-24) slots are seeded at alpha 950 and 750 with an interactive
 * bonus of 0 and 20 - "battery-lean at night", for a phone that is asleep. The evening slot
 * starts at 400 with a bonus of 80. Learning moves a slot by a few thousandths per session, so
 * those seeds stay in force for months, and they apply whenever the clock says night - screen
 * on included. Asleep, they buy nothing: screen-off already has the DEEP_IDLE rails and the
 * night override lifts alpha to 900 on its own. Awake, they are what a user describes as "when
 * I stay up late the animations get less smooth" - the same phone seeded 350 points closer to
 * Battery at 23:30 than at 20:30 (750 against 400) and 550 closer after midnight, with a
 * quarter of the evening's touch bonus, or none.
 *
 * So with the screen on, a night slot leans no harder toward economy than this phone's evening
 * slot (the same weekday/weekend half, computed the same way), and gets at least its bonus.
 * Everything after this - the user's bias, low battery, the thermal veto and trend - still
 * applies on top, and screen-off is untouched. smart_night_awake=0 turns it off. */

static void asb_smart_night_awake(int screen_on, int daypart, int is_weekend, time_t now) {
    g_smart_night_awake_on = 0;
    g_smart_night_awake_from = 0;
    g_smart_night_awake_to = 0;
    if (!g_asb_cfg.smart_night_awake || !screen_on) return;
    if (daypart != ASB_DAYPART_SLEEP && daypart != ASB_DAYPART_LATE) return;
    int fb = 0;
    asb_smart_bucket_t *eb = asb_smart_lookup_bucket(&g_smart_store, ASB_DAYPART_EVE,
                                                     is_weekend, now, &fb);
    if (!eb) return;
    asb_smart_runtime_t ev = g_smart_rt;
    asb_smart_compute_effective(eb, asb_smart_confidence_x1000(eb, now), &g_smart_store, &ev);
    if (ev.alpha_battery_x1000 < g_smart_rt.alpha_battery_x1000) {
        g_smart_night_awake_from = g_smart_rt.alpha_battery_x1000;
        g_smart_rt.alpha_battery_x1000 = ev.alpha_battery_x1000;
        g_smart_night_awake_on = 1;
    }
    if (ev.interactive_bonus_x1000 > g_smart_rt.interactive_bonus_x1000) {
        if (!g_smart_night_awake_on) g_smart_night_awake_from = g_smart_rt.alpha_battery_x1000;
        g_smart_rt.interactive_bonus_x1000 = ev.interactive_bonus_x1000;
        g_smart_night_awake_on = 1;
    }
    if (g_smart_night_awake_on) {
        g_smart_night_awake_to = g_smart_rt.alpha_battery_x1000;
        g_smart_night_awake_ticks++;
    }
}

/* Foreground app classification on the manual profiles (fix210).
 *
 * The FSM's GAMING gate asks the package table: pkg_agrees counts app_hint == 0 as "no
 * information, do not block". The classification that fills app_hint lives inside
 * asb_smart_tick, which returns early unless Smart is active - so on BATTERY, BALANCED
 * and PERFORMANCE the hint stayed 0 all day, the fallback was permanently in force, and
 * a busy GPU next to a busy CPU read as GAMING. A field capture shows it plainly:
 * profile BALANCED, FSM=GAMING, GPU 57 %, load 7.1, while the owner scrolled a feed.
 *
 * This mirrors Smart's classification block for the manual profiles: the same detector,
 * the same ten-second cache, the same stale-cache demotion, the same heat inference with
 * the camera and media guards, the same wake-edge re-read (fix186). The no-signal
 * fallback keeps Smart's load heuristic - and like Smart's, it never invents GAMING.
 * With Smart active this function is a no-op: Smart owns the classification. */
static void asb_fg_classify_tick(const asb_metrics_t *m, const asb_fsm_t *fsm) {
    if (!m) return;
    if (g_smart_rt.enabled && g_smart_store_loaded) return;

    time_t now = time(NULL);
    static time_t _last = 0;
    static int _prev_on = -1;
    /* Same wake edge as Smart (fix186): the cached answer was read with the screen off
     * and says "idle" - re-read at once instead of waiting out the cache. */
    if (m->misc.screen_on && _prev_on == 0) _last = 0;
    _prev_on = m->misc.screen_on ? 1 : 0;
    if (_last && now - _last < ASB_SMART_APP_CACHE_S) return;

    if (!m->misc.screen_on) {
        g_smart_rt.app_hint = ASB_APP_IDLE;
        g_smart_rt.app_hash = 0;
        g_smart_rt.app_pkg_cached[0] = 0;
        g_pkg_detect_ok = 0;
        g_pkg_detect_source = 0;
        g_pkg_detect_status = ASB_PKG_MISSING;
    } else {
        char fg_pkg[128] = {0};
        uint64_t fg_hash = 0;
        int fg_hint = ASB_APP_MEDIUM;
        int fg_source = 0;
        int media_known = 0;
        asb_pkg_status_t pst = asb_smart_detect_foreground_pkg(
            fg_pkg, sizeof(fg_pkg), &fg_hash, &fg_hint, &fg_source,
            m->misc.screen_on,
            /* "Interacting" = the run queue is above the learned quiet floor. Same
               signal the calm tick cadence uses, so the two cannot disagree. */
            (g_ui_quiet_floor > 0.0f &&
             m->cpu.load1 >= g_ui_quiet_floor * 1.35f));

        g_pkg_detect_status = pst;
        g_pkg_detect_source = fg_source;

        if (pst == ASB_PKG_OK || pst == ASB_PKG_STALE) {
            /* Real package signal — use it */
            g_smart_rt.app_hash = fg_hash;
            g_smart_rt.app_hint = fg_hint;
            g_pkg_detect_ok = 1;
            {
                size_t _pl = strnlen(fg_pkg, sizeof(g_smart_rt.app_pkg_cached) - 1);
                memcpy(g_smart_rt.app_pkg_cached, fg_pkg, _pl);
                g_smart_rt.app_pkg_cached[_pl] = 0;
            }
            /* Only a current, positively recognised media package may opt into the
             * media guard. A stale cache deliberately does not qualify. */
            media_known = (pst == ASB_PKG_OK &&
                           asb_smart_pkg_is_media_candidate(fg_pkg));
            /* For heavy/gaming hints, double-check with load to avoid
             * stale cache mistakes (e.g. user backgrounded the game) */
            if (fg_hint >= ASB_APP_HEAVY && m->cpu.load1 < 3.0f) {
                g_smart_rt.app_hint = ASB_APP_LIGHT;
            }
            /* Game/heavy app is foreground but the FSM has settled into an idle state
             * with low GPU — the game is paused, in a menu, or loading. */
            else if (fg_hint >= ASB_APP_HEAVY && fsm &&
                     (fsm->state == ASB_STATE_DEEP_IDLE ||
                      fsm->state == ASB_STATE_LIGHT_IDLE) &&
                     m->gpu.load_pct < 15) {
                g_smart_rt.app_hint = fg_hint - 1;
            }
        } else {
            /* No package signal — the load heuristic, and never GAMING from it. */
            g_smart_rt.app_hash = 0;
            g_smart_rt.app_pkg_cached[0] = 0;
            g_pkg_detect_ok = 0;
            if (m->cpu.load1 >= 12.0f) g_smart_rt.app_hint = ASB_APP_HEAVY;
            else if (m->cpu.load1 >= 6.0f) g_smart_rt.app_hint = ASB_APP_MEDIUM;
            else g_smart_rt.app_hint = ASB_APP_LIGHT;
        }
        /* The heat inference, one-to-one with Smart's: an unlisted game looks like a
         * hot die plus a busy GPU. The camera is not a game (fix120), a media app is
         * not either, and the boot grace keeps early boot storms out. */
        if (g_smart_rt.app_hint < ASB_APP_GAMING && fsm && m->misc.screen_on) {
            int fresh_pkg = (pst == ASB_PKG_OK);
            int boot_grace = (g_gov_start_ts > 0 &&
                              (long)(now - g_gov_start_ts) < 180);
            int cam_open = m->misc.camera_active;
            if (fsm->state == ASB_STATE_GAMING && fresh_pkg && !media_known) {
                g_smart_rt.app_hint = ASB_APP_GAMING;
            } else if (!boot_grace && !cam_open &&
                       fsm->state == ASB_STATE_SUSTAINED &&
                       m->therm.cpu_max_c >= 60 && m->gpu.load_pct >= 30 &&
                       fresh_pkg && !media_known) {
                g_smart_rt.app_hint = ASB_APP_GAMING;
            } else if (!boot_grace && !cam_open &&
                       g_asb_cfg.bat_suppress_gaming &&
                       fsm->state == ASB_STATE_HEAVY &&
                       m->therm.cpu_max_c >= 60 && m->gpu.load_pct >= 45 &&
                       m->cpu.load1 >= 3.0f &&
                       fresh_pkg && !media_known) {
                /* A suppressed game is still a game - see the Smart twin of this
                 * branch for the full reasoning. */
                g_smart_rt.app_hint = ASB_APP_GAMING;
            }
        }
    }
    _last = now;
}

/* The user's screen-transition switches on the manual profiles (fix248).
 *
 * smart_dynamic_tune.sh carries three switches the user turns on for themselves - LTE with
 * the screen off (net_screen_off_lte), 5G only when needed (net_lte_light) and Wi-Fi power
 * save with the screen off (wifi_powersave) - next to Smart's own I/O and memory nudges.
 * It was only ever started from the Smart tick, which returns at once on BATTERY, BALANCED
 * and PERFORMANCE, so on those profiles the three switches did nothing. An OP15 on Battery
 * shows it: the LTE log stopped the evening Smart was switched off, and two days, two
 * captures and 1.9 GiB of mobile data later every snapshot still read applies=19,
 * light_watch=0 with both switches on.
 *
 * On a manual profile the tuner now runs at every screen change in its "manual" mode, which
 * does those switches and nothing else - read-ahead, swappiness and the dirty limits stay
 * the profile's. -1 means "run at the next manual tick": Smart owned the screen until now. */
static int g_manual_tune_screen = -1;

static void asb_manual_screen_tune(const asb_metrics_t *m) {
    int on = m->misc.screen_on ? 1 : 0;
    if (on == g_manual_tune_screen) return;
    g_manual_tune_screen = on;
    /* Smart's tuner re-runs at its first tick when Smart comes back: the screen state it
     * last saw is no longer the one the switches were left in. */
    g_smart_last_tune_sig = -1;
    char args[48];
    snprintf(args, sizeof(args), "%d 0 %d manual", g_smart_rt.app_hint, on);
    asb_run_modscript("runtime/smart_dynamic_tune.sh", args);
}

static int asb_smart_tick(const asb_metrics_t *m, const asb_fsm_t *fsm) {
    if (!m) return 0;
    /* Defensive consistency: if FSM is in PROFILE_SMART, ensure runtime flag
     * is on so g_smart_bounds gets refreshed (FSM reads from it). */
    if (fsm && fsm->profile_idx == PROFILE_SMART) {
        g_smart_rt.enabled = 1;
    }
    if (!g_smart_rt.enabled || !g_smart_store_loaded) {
        asb_manual_screen_tune(m);
        return 0;
    }
    g_manual_tune_screen = -1;

    time_t now = time(NULL);

    /* 1. Build context */
    int daypart = asb_smart_daypart_now(now);
    int is_weekend = asb_smart_is_weekend(now);
    int bid = (int)asb_smart_bucket_id(daypart, is_weekend);
    int charging = m->bat.charging;
    int screen_on = m->misc.screen_on;
    int battery_pct = m->bat.capacity_pct;
    int cpu_max_c = m->therm.cpu_max_c;
    int skin_temp_c = m->therm.skin_temp_c;

    /* Daypart transition detection (for smoothing) */
    if (g_smart_rt.prev_daypart >= 0 &&
        g_smart_rt.prev_daypart != daypart &&
        g_smart_rt.smoothing_start_ts == 0) {
        g_smart_rt.smoothing_start_ts = now;
        g_smart_rt.smoothing_active = 1;
    }

    g_smart_rt.daypart = daypart;
    g_smart_rt.is_weekend = is_weekend;
    g_smart_rt.bucket_id = bid;

    /*
     * app detection: cascading foreground package sources.
     */
    /* The app in front is read again the moment the screen comes on (fix186). The last
     * read was made with the screen off and says "idle"; waiting out the ten-second cache
     * left the Monitor's Load tile at "idle" over a MODERATE phone, and Smart's lean on the
     * screen-off value, for the first seconds of every wake. */
    {
        static int _app_prev_on = -1;
        if (screen_on && _app_prev_on == 0) g_smart_rt.app_cache_last_refresh = 0;
        _app_prev_on = screen_on ? 1 : 0;
    }
    if (now - g_smart_rt.app_cache_last_refresh >= ASB_SMART_APP_CACHE_S) {
        if (!screen_on) {
            g_smart_rt.app_hint = ASB_APP_IDLE;
            g_smart_rt.app_hash = 0;
            g_smart_rt.app_pkg_cached[0] = 0;
            g_pkg_detect_ok = 0;
            g_pkg_detect_source = 0;
            g_pkg_detect_status = ASB_PKG_MISSING;
            g_smart_media_pkg_known = 0;
        } else {
            char fg_pkg[128] = {0};
            uint64_t fg_hash = 0;
            int fg_hint = ASB_APP_MEDIUM;
            int fg_source = 0;
            asb_pkg_status_t pst = asb_smart_detect_foreground_pkg(
                fg_pkg, sizeof(fg_pkg), &fg_hash, &fg_hint, &fg_source,
                m->misc.screen_on,
                /* "Interacting" = the run queue is above the learned quiet floor. Same
                   signal the calm tick cadence uses, so the two cannot disagree. */
                (g_ui_quiet_floor > 0.0f &&
                 m->cpu.load1 >= g_ui_quiet_floor * 1.35f));

            g_pkg_detect_status = pst;
            g_pkg_detect_source = fg_source;

            if (pst == ASB_PKG_OK || pst == ASB_PKG_STALE) {
                /* Real package signal — use it */
                g_smart_rt.app_hash = fg_hash;
                g_smart_rt.app_hint = fg_hint;
                g_pkg_detect_ok = 1;
                {   /* fix185: the name, for the smoothness probe */
                    size_t _pl = strnlen(fg_pkg, sizeof(g_smart_rt.app_pkg_cached) - 1);
                    memcpy(g_smart_rt.app_pkg_cached, fg_pkg, _pl);
                    g_smart_rt.app_pkg_cached[_pl] = 0;
                }
                /* Only a current, positively recognised media package may opt into the
                 * media guard. A stale cache deliberately does not qualify. */
                g_smart_media_pkg_known = (pst == ASB_PKG_OK &&
                                            asb_smart_pkg_is_media_candidate(fg_pkg));
                /* For heavy/gaming hints, double-check with load to avoid
                 * stale cache mistakes (e.g. user backgrounded the game) */
                if (fg_hint >= ASB_APP_HEAVY && m->cpu.load1 < 3.0f) {
                    g_smart_rt.app_hint = ASB_APP_LIGHT;
                }
                /*
                 * Game/heavy app is foreground but the FSM has settled into an idle state with
                 * low GPU — the game is paused, in a menu, or loading.
                 */
                else if (fg_hint >= ASB_APP_HEAVY && fsm &&
                         (fsm->state == ASB_STATE_DEEP_IDLE ||
                          fsm->state == ASB_STATE_LIGHT_IDLE) &&
                         m->gpu.load_pct < 15) {
                    g_smart_rt.app_hint = fg_hint - 1;
                }
            } else {
                /* No package signal — fall back to load-based heuristic,
                 * but mark detect_ok=0 so observability shows the gap */
                g_smart_rt.app_hash = 0;
                g_smart_rt.app_pkg_cached[0] = 0;
                g_pkg_detect_ok = 0;
                g_smart_media_pkg_known = 0;
                if (m->cpu.load1 >= 12.0f) g_smart_rt.app_hint = ASB_APP_HEAVY;
                else if (m->cpu.load1 >= 6.0f) g_smart_rt.app_hint = ASB_APP_MEDIUM;
                else g_smart_rt.app_hint = ASB_APP_LIGHT;
            }
            if (g_smart_rt.app_hint < ASB_APP_GAMING &&
                m->misc.screen_on && fsm) {
                int fresh_pkg = (pst == ASB_PKG_OK);
                /*
                 * Boot grace.
                 * The SUSTAINED branch below infers "this must be a game" from heat plus GPU
                 * load, because an unrecognised game looks exactly like that.
                 */
                int boot_grace = (g_gov_start_ts > 0 &&
                                  (long)(now - g_gov_start_ts) < 180);
                /* The camera is not a game (fix120).
                 *
                 * The two heat branches below guess "game" from a hot die plus a busy GPU,
                 * because an unrecognised game looks like that. A camera session looks
                 * exactly the same: the ISP pipeline, HDR merge and preview render push the
                 * GPU past 30-50% and the die to 60 C within seconds. An OP15 capture shows
                 * it - SUSTAINED at 60 C, camera=1 eleven seconds later, and the Smart row
                 * for that minute carries app_hint=4 with the GPU back at 0-6%.
                 *
                 * A game hint is not free. It lifts Smart's proactive ceiling (_game_busy
                 * in the FSM), relaxes the GPU gate for a GAMING entry and opens the GAMING
                 * entry itself (pkg_agrees) - the loosest rails ASB has, for a workload that
                 * already gets its own HEAVY floor and camera QoS. That is heat on the one
                 * thing users hold in their hand while it runs.
                 *
                 * Only the inference is blocked: a package the table names as a game keeps
                 * its hint with the camera open (an AR game), and so does an FSM that is
                 * already in GAMING, because it could only have got there with a hint. */
                int cam_open = m->misc.camera_active;
                if (fsm->state == ASB_STATE_GAMING && fresh_pkg &&
                    !g_smart_media_pkg_known) {
                    g_smart_rt.app_hint = ASB_APP_GAMING;
                } else if (!boot_grace && !cam_open &&
                           fsm->state == ASB_STATE_SUSTAINED &&
                           cpu_max_c >= 60 && m->gpu.load_pct >= 30 &&
                           fresh_pkg && !g_smart_media_pkg_known) {
                    g_smart_rt.app_hint = ASB_APP_GAMING;
                } else if (!boot_grace && !cam_open &&
                           g_asb_cfg.bat_suppress_gaming &&
                           fsm->state == ASB_STATE_HEAVY &&
                           cpu_max_c >= 60 && m->gpu.load_pct >= 45 &&
                           m->cpu.load1 >= 3.0f &&
                           fresh_pkg && !g_smart_media_pkg_known) {
                    /* A suppressed game is still a game.
                     *
                     * bat_suppress_gaming deliberately keeps the FSM in HEAVY on a
                     * battery-leaning profile, so a game never unlocks GAMING clocks. That
                     * part works. What it also does is hide the workload from every
                     * gaming-specific thermal control - cool_gaming, the retry cooldown,
                     * the gap-to-SUSTAINED escape - because all of them key off this hint,
                     * and this hint was only ever set from GAMING or SUSTAINED.
                     *
                     * The result is the worst of both: the phone does not get game
                     * performance, and it does not get game heat management either. A user
                     * reported exactly that - "played briefly, the device turned into a
                     * heater" - with cool_gaming=1 and suppress_gaming_on_battery=1 both
                     * enabled, GPU past the gaming threshold and 95 C on the die.
                     *
                     * The thresholds here are stricter than the GAMING entry, not looser:
                     * hot, GPU busy past the exit threshold, AND real CPU load. That
                     * combination is not a video feed - the case the GPU-only check was
                     * tightened for in V63 - it is sustained rendering work.
                     */
                    g_smart_rt.app_hint = ASB_APP_GAMING;
                }
            }
        }
        g_smart_rt.app_cache_last_refresh = now;
    }
    /* Track session-top app hint + hash (max-of-session). Sync both so the
     * session record at end-of-session shows the actual heaviest app's hash. */
    if (g_smart_rt.app_hint > g_smart_rt.app_hint_session_top) {
        g_smart_rt.app_hint_session_top = g_smart_rt.app_hint;
        g_smart_rt.app_hash_session_top = g_smart_rt.app_hash;
    } else if (g_smart_rt.app_hint == g_smart_rt.app_hint_session_top &&
               g_smart_rt.app_hash != 0 &&
               g_smart_rt.app_hash_session_top == 0) {
        /* Same level but we now have a real hash where we had none — record it */
        g_smart_rt.app_hash_session_top = g_smart_rt.app_hash;
    }

    /* 3. Bucket lookup with fallback hierarchy */
    asb_smart_bucket_t *b = asb_smart_lookup_bucket(
        &g_smart_store, daypart, is_weekend, now, &g_smart_rt.fallback_level);
    if (g_smart_rt.fallback_level == ASB_SMART_FALLBACK_EXACT) {
        g_smart_rt.exact_bucket_hits++;
    } else {
        g_smart_rt.fallback_hits++;
    }

    int conf = asb_smart_confidence_x1000(b, now);
    asb_smart_compute_effective(b, conf, &g_smart_store, &g_smart_rt);
    asb_smart_night_awake(screen_on, daypart, is_weekend, now);

    /*
     * Optional user autonomy dial: smart_battery_bias (governor.conf, x1000, default 0 =
     * unchanged) nudges the effective battery lean upward so Smart leans harder toward economy
     * without touching the learner or the profiles.
     * Bias is clamped to 0..600 and is confidence-scaled; the final alpha is still hard-capped
     * at ASB_SMART_ALPHA_BATTERY_MAX_X1000 (1000), so it can never exceed pure-battery
     * behaviour.
     */
    if (g_asb_cfg.smart_battery_bias > 0) {
        int bbias = g_asb_cfg.smart_battery_bias;
        if (bbias > 600) bbias = 600;

        /* Ease the nudge off while the phone is actually working.
         *
         * This bias is a user preference, not evidence: it is added on top of whatever
         * the learner concluded, in every state. asbdiag already warns that 400 or more
         * "can pin active-use alpha into battery-like behaviour", and a field config sits
         * at the 600 ceiling - so under load Smart rides the battery rail and feels slow,
         * which is what the sluggishness reports described.
         *
         * HEAVY and GAMING are the two states where the user is waiting on the phone, and
         * they are bounded: they end when the work does. The nudge is halved there rather
         * than dropped, so the preference still counts - just not at full weight against
         * someone staring at the screen.
         *
         * SUSTAINED keeps the full bias on purpose: that state means sustained heat, and
         * leaning toward battery is the right answer there. */
        if (fsm && (fsm->state == ASB_STATE_HEAVY || fsm->state == ASB_STATE_GAMING))
            bbias /= 2;
        /* scale by confidence so low-confidence Smart isn't over-biased */
        /* V4: the nudge takes a SHARE of the remaining headroom, it does not add.
         *
         * Adding saturated the value and erased the learner. With a learned alpha of 500
         * and a bias of 600 the sum clamps to the 1000 ceiling - and so does a learned
         * 300, and a learned 800. Every bucket ends up at pure battery, which is what the
         * captures show: alpha sat at 1000, 971, 908 while the learner had spent 177
         * sessions working out that these buckets differ. Smart stopped being adaptive
         * and became Battery with extra steps.
         *
         * Taking a fraction of the distance to the ceiling keeps the preference strong
         * while preserving order and range:
         *
         *   learned 300 + bias 600  ->  300 + 700*0.6 = 720
         *   learned 500 + bias 600  ->  500 + 500*0.6 = 800
         *   learned 900 + bias 600  ->  900 + 100*0.6 = 960
         *
         * A warm bucket still lands higher than a cool one, so the next session's
         * measurement still changes the outcome - which is the whole point of the
         * learner. The ceiling is approached, never reached, so there is always somewhere
         * left for evidence to move. */
        int scaled = (bbias * conf) / 1000;
        int alpha  = (int)g_smart_rt.alpha_battery_x1000;
        int room   = ASB_SMART_ALPHA_BATTERY_MAX_X1000 - alpha;
        if (room < 0) room = 0;
        int biased = alpha + (room * scaled) / 1000;
        if (biased > ASB_SMART_ALPHA_BATTERY_MAX_X1000)
            biased = ASB_SMART_ALPHA_BATTERY_MAX_X1000;
        g_smart_rt.alpha_battery_x1000 = biased;
    }

    /* fix184: the Smart records' lean for this situation, screen on only - the setting being
     * measured in a block, or the best one found. Before the safety layers, so the thermal
     * veto, low battery and the charge guard still lift alpha over it. */
    g_rec_on_applied = 0;
    /* fix185: plus the smoothness lean of the app in front (more headroom, only where a test
     * showed it helps, or the test itself). */
    if (screen_on && (g_rec_on_offset != 0 || g_smooth_lean != 0)) {
        int _off = g_rec_on_offset + g_smooth_lean;
        int _ra = (int)g_smart_rt.alpha_battery_x1000 + _off;
        if (_ra < ASB_SMART_ALPHA_BATTERY_MIN_X1000) _ra = ASB_SMART_ALPHA_BATTERY_MIN_X1000;
        if (_ra > ASB_SMART_ALPHA_BATTERY_MAX_X1000) _ra = ASB_SMART_ALPHA_BATTERY_MAX_X1000;
        g_smart_rt.alpha_battery_x1000 = _ra;
        g_rec_on_applied = _off;
    }
    /* fix185: cold battery, low charge. A Li-ion pack under 5 C has two to three times its
     * usual internal resistance, so a burst on the prime pulls the voltage down hard - and
     * with the pack under 40 % that is how a phone switches itself off in the cold with
     * charge still showing. Lean to the battery rails (lower peaks, the same floor the
     * low-battery layer uses at 20 %) until the pack warms up or goes on a charger. The
     * physics, not a capture: no log so far was taken in the cold. */
    g_smart_cold_guard = 0;
    if (g_asb_cfg.smart_cold_guard && !charging && battery_pct >= 0 && battery_pct < 40 &&
        m->bat.temp_dC > -300 && m->bat.temp_dC < 50) {
        if (g_smart_rt.alpha_battery_x1000 < 800) g_smart_rt.alpha_battery_x1000 = 800;
        g_smart_cold_guard = 1;
    }

    /* 4. Safety overrides — these can lift floors but never reduce safety */
    asb_smart_apply_night_override(daypart,
                                   asb_night_window_active(now),
                                   screen_on, charging,
                                   g_smart_rt.app_hint, battery_pct, &g_smart_rt);

    if (screen_on != g_smart_last_screen_on) {
        if (!screen_on) {
            g_smart_screen_off_since = now;
        } else {
            g_smart_screen_off_since = 0;
        }
        g_smart_last_screen_on = screen_on;
    }
    long screen_off_secs = (g_smart_screen_off_since > 0)
                           ? (long)(now - g_smart_screen_off_since) : 0;
    asb_smart_apply_idle_screen_override(screen_on, charging,
                                          g_smart_rt.app_hint,
                                          screen_off_secs, &g_smart_rt);

    asb_smart_apply_low_battery_override(battery_pct, charging, &g_smart_rt);

    {
        /* V50 charge-aware: classify charger power from |I|x|V| at the pack,
         * then let the layer trade lean direction against pack temperature. */
        int pclass = ASB_CHARGE_CLASS_NONE;
        int pw_x10 = 0;
        if (charging) {
            long w_x10 = ((long)m->bat.current_ma * (m->bat.voltage_uv / 1000L)) / 100000L;
            if (w_x10 < 0) w_x10 = 0;
            if (w_x10 > 2000) w_x10 = 2000;
            pw_x10 = (int)w_x10;
            if (pw_x10 >= ASB_CHARGE_POWER_SUPER_W * 10) pclass = ASB_CHARGE_CLASS_SUPER;
            else if (pw_x10 >= ASB_CHARGE_POWER_FAST_W * 10) pclass = ASB_CHARGE_CLASS_FAST;
            else pclass = ASB_CHARGE_CLASS_SLOW;
        }
        g_smart_rt.charge_power_class = pclass;
        g_smart_rt.charge_power_w_x10 = pw_x10;
        asb_smart_apply_charge_aware(g_asb_cfg.charge_aware_enable,
                                     charging, screen_on,
                                     m->bat.temp_dC, pclass,
                                     g_asb_cfg.charge_assist_alpha_max,
                                     m->therm.cpu_max_c,
                                     g_asb_cfg.charge_temp_warn_dC,
                                     g_asb_cfg.charge_temp_hot_dC,
                                     &g_smart_rt);
    }
    {
        /* Measure first, remember second.
         *
         * The bucket average answers "what this hour of the week usually costs" - a prior
         * built from past sessions, including the gaming and downloading ones. Used as the
         * prediction it was wrong by the width of the question: a capture graded itself
         * score=0/100, error=100%, predicting 10.2 %/h while the battery actually went
         * 78% to 60% over 3.5 h - 4.96 %/h, less than half.
         *
         * That error is not cosmetic. This rate feeds the budget severity, so a
         * pessimistic number trims a phone that had hours of headroom.
         *
         * The live EWMA is what this session is actually doing, so it leads. The bucket
         * stays as the fallback for the first minutes after boot, before any window has
         * closed - which is exactly the case it was written for.
         */
        int _budget_rate = g_smart_drain_rate_ewma_x10;
        g_smart_budget_src = 0;
        if (_budget_rate <= 0 &&
            g_smart_rt.bucket_id < ASB_SMART_BUCKETS &&
            g_smart_rt.conf_x1000 >= 350) {
            int _bew = (int)g_smart_store.buckets[g_smart_rt.bucket_id].avg_drain_pctph_x10;
            if (_bew > 0) {
                _budget_rate = _bew;
                g_smart_budget_src = 1;
            }
        }
        /*
         * Self-correction: when the forecast has consistently missed in the same direction
         * across several windows, nudge the drain rate fed to the budget by a small bounded
         * factor (max +-12%).
         */
        if (g_budget_bias_streak >= ASB_BUDGET_ACC_BIAS_STREAK) {
            int _adj = g_budget_bias_streak - ASB_BUDGET_ACC_BIAS_STREAK + 1;
            if (_adj > 12) _adj = 12;
            _budget_rate += (g_budget_bias_dir * _budget_rate * _adj) / 100;
            if (_budget_rate < 1) _budget_rate = 1;
        }
        g_drain_spike_bump = (g_drain_spike_until > now) ? 1 : 0;
        g_smart_budget_rate_x10 = _budget_rate;
        asb_smart_apply_energy_budget(battery_pct, charging,
                                      _budget_rate, now, &g_smart_rt);
        /*
         * Budget accuracy grading.
         * The anchor is also suspended while the night/sleep override is active: deep-idle
         * drain (often <0.3%/h) is a different regime from the active EWMA the budget predicts
         * with, so grading — and especially the self-correction — must not learn from it, or
         * it would drag the daytime rate down and then under-predict once normal use resumes.
         */
        /* Screen-off is not the regime being predicted either.
         *
         * The budget forecasts from the ACTIVE drain rate, and grading was suspended only at
         * night and on charge - not for an ordinary hour with the screen off. So a window
         * opened at 16.6 %/h while the phone was in use, ran on through an hour in a
         * pocket, and closed against a drop of one or two percent: error 100%, score 0, in
         * every graded window of a capture whose real average was 1.3 %/h. The forecast was
         * fine for what it forecasts; the grade compared it with a different regime.
         *
         * Only the anchor is dropped here. The self-correction streak is still reset only
         * by night and charging, as before - a screen-off pause does not make the daytime
         * evidence collected so far untrustworthy. */
        if (charging || battery_pct < 0 || g_smart_rt.night_safe_override ||
            !m->misc.screen_on) {
            g_budget_acc_anchor_ts = 0;
            g_budget_acc_anchor_pct = -1;
            if (g_smart_rt.night_safe_override || charging) {
                /* Don't let a streak built from a non-representative regime
                   (deep-idle night, or charging windows) persist into a
                   correction — reset it as we enter that regime. The daytime
                   budget must only learn from genuine on-battery discharge. */
                g_budget_bias_streak = 0;
                g_budget_bias_dir = 0;
            }
        } else if (g_budget_acc_anchor_ts == 0 &&
                   g_smart_rt.budget_pred_h_x10 > 0) {
            g_budget_acc_anchor_ts = now;
            g_budget_acc_anchor_pct = battery_pct;
            g_budget_acc_pred_h_x10 = g_smart_rt.budget_pred_h_x10;
        } else if (g_budget_acc_anchor_ts > 0 &&
                   (long)(now - g_budget_acc_anchor_ts) >= ASB_BUDGET_ACC_WINDOW_S &&
                   g_budget_acc_anchor_pct >= 0) {
            long _elapsed = (long)(now - g_budget_acc_anchor_ts);
            int _actual_drop = g_budget_acc_anchor_pct - battery_pct;
            if (_actual_drop > 0 && g_budget_acc_pred_h_x10 > 0) {
                /* predicted drop over the window = elapsed_h / pred_h * anchor_pct.
                 *
                 * fix96: pred_h is hours to EMPTY FROM THE ANCHOR LEVEL (battery_pct /
                 * drain in asb_smart_apply_energy_budget), not hours per 100 %. Scaling by
                 * 100 over-predicted every window by 100/pct - x1.9 at 53 %, x2.3 at 44 % -
                 * so every grade read "over-predicted", error pinned at 100, and the
                 * self-correction streak built in the -1 direction: the drain fed to the
                 * budget was nudged DOWN by up to 12 % on a phone draining 9-12 %/h, the
                 * opposite of the evidence. */
                long _pred_drop_x100 =
                    (_elapsed * (long)g_budget_acc_anchor_pct * 100L) /
                    ((long)g_budget_acc_pred_h_x10 * 360L);
                long _actual_x100 = (long)_actual_drop * 100L;
                long _err = _actual_x100 - _pred_drop_x100;
                if (_err < 0) _err = -_err;
                long _err_pct = (_actual_x100 > 0)
                    ? (_err * 100L) / _actual_x100 : 100;
                if (_err_pct > 100) _err_pct = 100;
                g_budget_acc_error_pct = (int)_err_pct;
                g_budget_acc_score = (int)(100 - _err_pct);
                /* Signed bias: did we under- or over-predict drain? Track a
                   streak of same-direction misses. A correction is applied only
                   when several consecutive windows agree, so a single noisy
                   window never moves anything. */
                int _signed = (_actual_x100 > _pred_drop_x100) ? 1
                            : (_actual_x100 < _pred_drop_x100) ? -1 : 0;
                if (_err_pct >= ASB_BUDGET_ACC_BIAS_MIN_ERR_PCT && _signed != 0) {
                    if (_signed == g_budget_bias_dir) {
                        if (g_budget_bias_streak < 100) g_budget_bias_streak++;
                    } else {
                        g_budget_bias_dir = _signed;
                        g_budget_bias_streak = 1;
                    }
                } else {
                    g_budget_bias_streak = 0;
                    g_budget_bias_dir = 0;
                }
            }
            g_budget_acc_anchor_ts = 0;
            g_budget_acc_anchor_pct = -1;
        }
        if (g_drain_spike_bump && g_smart_rt.budget_severity < 2 &&
            !charging && battery_pct <= ASB_SMART_BUDGET_MAX_PCT) {
            g_smart_rt.budget_severity++;
            if (g_smart_rt.budget_severity == 1 &&
                g_smart_rt.alpha_battery_x1000 < ASB_SMART_BUDGET_WARN_ALPHA_X1000)
                g_smart_rt.alpha_battery_x1000 = ASB_SMART_BUDGET_WARN_ALPHA_X1000;
            else if (g_smart_rt.budget_severity == 2 &&
                     g_smart_rt.alpha_battery_x1000 < ASB_SMART_BUDGET_EMERG_ALPHA_X1000)
                g_smart_rt.alpha_battery_x1000 = ASB_SMART_BUDGET_EMERG_ALPHA_X1000;
        }
    }

    if (battery_pct >= 1 && battery_pct <= 100) {
        if (screen_on && !charging && g_smart_drain_prev_ts > 0 &&
            g_smart_drain_prev_pct >= 1) {
            long ddt = (long)(now - g_smart_drain_prev_ts);
            if (ddt > 0 && ddt <= 30) {
                g_smart_drain_on_sec += ddt;
                g_drain_roll_sec += ddt;
                int ddrop = g_smart_drain_prev_pct - battery_pct;
                if (ddrop > 0 && ddrop <= 5) {
                    g_smart_drain_drop_x100 += (long)ddrop * 100L;
                g_drain_roll_x100 += (long)ddrop * 100L;
                }
            }
        }
        g_smart_drain_prev_ts = now;
        g_smart_drain_prev_pct = battery_pct;
        if (screen_on) {
            g_anom_pkg_total++;
            if (g_pkg_detect_ok) g_anom_pkg_ok++;
        }
    } else {
        g_smart_drain_prev_ts = 0;
        g_smart_drain_prev_pct = -1;
    }

    int vendor_clamp_1h = (int)v44_clamp_1h_now();
    int recovery_active = 0;  /* recovery state; conservatively 0 in alpha */
    asb_smart_apply_thermal_veto(cpu_max_c, skin_temp_c, &g_asb_cfg, vendor_clamp_1h, recovery_active, &g_smart_rt);
    {
        /*
         * Cool-gaming engage level fed to the thermal lean: 0 = none, 1 = game active (engage
         * from 40 C / 2 C/min), 2 = charge-aware: game active AND charging AND the battery is
         * warm, the worst thermal case (render heat stacked on charge heat) — engage even
         * earlier (38 C / 1.5 C/min).
         */
        int _settle_lvl = (g_gov_start_ts > 0 &&
                           (long)(now - g_gov_start_ts) < 1200) ? 1 : 0;
        int _cool_lvl = 0;
        if (g_asb_cfg.cool_gaming && g_smart_rt.app_hint >= ASB_APP_GAMING) {
            _cool_lvl = 1;
            if (m->bat.charging &&
                m->bat.temp_dC >= ASB_SMART_CHARGE_WARM_BAT_DC) {
                _cool_lvl = 2;
            }
        }
        int _engage = _settle_lvl > _cool_lvl ? _settle_lvl : _cool_lvl;
        asb_smart_apply_thermal_trend(cpu_max_c, now, g_smart_rt.app_hash,
                                      _engage, &g_smart_rt);
        g_smart_boot_settle = (_settle_lvl > 0);
        g_smart_cool_gaming_lvl = _cool_lvl;

        /* Gaming-session peak tracking: while a game is the foreground app,
           accumulate running maxima; when it isn't, decay the session so the
           next game starts clean. Lightweight — just a few comparisons. */
        if (g_smart_rt.app_hint >= ASB_APP_GAMING) {
            if (m->bat.temp_dC > g_game_bat_temp_peak_dc)
                g_game_bat_temp_peak_dc = m->bat.temp_dC;
            if (cpu_max_c > g_game_cpu_max_peak_c)
                g_game_cpu_max_peak_c = cpu_max_c;
            if (_cool_lvl > g_game_cool_lvl_peak)
                g_game_cool_lvl_peak = _cool_lvl;
            if (m->bat.charging) g_game_charging_seen = 1;
        } else {
            g_game_bat_temp_peak_dc = 0;
            g_game_cpu_max_peak_c   = 0;
            g_game_cool_lvl_peak    = 0;
            g_game_charging_seen    = 0;
        }
    }

    /* intelligent modifiers — memory pressure, signal-aware net, refresh-rate,
     * gaming relax. Each is a no-op if its signal is unavailable on this device,
     * and all skip when night_override or thermal_veto fired (those keep priority). */
    asb_smart_apply_v48_modifiers(g_smart_rt.app_hint, cpu_max_c, m->misc.screen_on, &g_smart_rt);

    /* camera relax runs last: it is the only modifier allowed to override the
     * soft thermal lean, and it must not be undone by one that runs after it. */
    asb_smart_apply_camera_relax(m->misc.camera_active, &g_smart_rt);

    /* 5. Slot-update gating: should we rebuild g_smart_bounds? */
    /* Run the screen/app tuner on EVERY tick, not only when the slot recomputes.
     *
     * This call used to sit below "if (!do_update) return 0;", and the slot recomputes on
     * bucket, daypart, confidence, thermal, charging and app-tier changes - never on a
     * screen change. So turning the screen off reached the tuner only when the app tier
     * happened to change at the same moment. A field night shows the result: hourly
     * snapshots at 02:39 and 04:27, screen off, still read watermark_scale_factor=60 -
     * and with it none of the tuner's screen-off work ran either: laptop_mode, dirty
     * thresholds, read-ahead and Wi-Fi power save. Foreground uclamp is native-owned.
     *
     * The call itself stays cheap: it only forks when the signature changes. A screen
     * change also bypasses the 30 s debounce - with the screen off the governor's timers
     * are disarmed, so a transition that landed inside the window would otherwise not be
     * retried until morning. */
    {
        int therm_bucket = (cpu_max_c >= 60) ? 2 : (cpu_max_c >= 50 ? 1 : 0);
        int screen_on_v  = m->misc.screen_on ? 1 : 0;
        /* Memory-stall bit (fix108). The tuner decides swappiness from PSI "full" (fix107),
         * but it only ran when app tier, heat band or screen changed - so a stall that
         * started inside an app never reached it. Hysteresis 2.00 on / 1.00 off, screen on
         * only (the screen-off branch has its own PSI rule). One small read per tick. */
        static int _mem_stall = 0;
        if (screen_on_v) {
            int _pf = asb_read_mem_psi_full_x100();
            if (_pf >= 200) {
                if (!_mem_stall) g_mem_stall_entries++;
                _mem_stall = 1;
            }
            else if (_pf >= 0 && _pf < 100) _mem_stall = 0;
        } else {
            _mem_stall = 0;
        }
        g_mem_stall_now = _mem_stall;
        int sig = (g_smart_rt.app_hint << 4) | (therm_bucket << 2) | (_mem_stall << 1) | screen_on_v;
        int screen_changed = (g_smart_last_tune_sig < 0) ||
                                 ((sig & 1) != (g_smart_last_tune_sig & 1));
            if (sig != g_smart_last_tune_sig &&
                (screen_changed || (now - g_smart_last_tune_ts) >= 30)) {
            char sdt_args[48];
            /*
             * Run it THROUGH sh.
             * Exec'ing the path directly therefore failed with EACCES on every device, and
             * because the command is backgrounded into /dev/null with its return value
             * discarded, it failed in complete silence: the Smart dynamic tuner has never
             * actually run. asb_run_modscript keeps the sh indirection, resolves the module
             * directory from /proc/self/exe instead of assuming it, and logs when the
             * script cannot be run at all.
             */
            snprintf(sdt_args, sizeof(sdt_args), "%d %d %d",
                     g_smart_rt.app_hint, therm_bucket, screen_on_v);
            asb_run_modscript("runtime/smart_dynamic_tune.sh", sdt_args);
            g_smart_last_tune_sig = sig;
            g_smart_last_tune_ts  = now;
        }
    }
    int do_update = asb_smart_should_update_slot(&g_smart_rt, now, charging, g_smart_rt.app_hint);
    if (!do_update) return 0;

    /* 6. Blend battery↔balanced into g_smart_bounds */
    const asb_profile_bounds_t *bat = &g_profile_bounds[PROFILE_BATTERY];
    const asb_profile_bounds_t *bal = &g_profile_bounds[PROFILE_BALANCED];
    asb_profile_bounds_t out;
    memset(&out, 0, sizeof(out));

    int alpha = g_smart_rt.alpha_battery_x1000;

    /*
     * daypart smoothing: when we just crossed a daypart boundary and BOTH the previous bucket
     * and the current bucket had decent confidence (≥ low threshold), linearly blend from
     * prev_alpha to current_alpha over ASB_SMART_SMOOTH_S (5 min).
     * Thermal veto and night override break smoothing — they're already applied above and
     * force alpha to safety floor, which we must respect.
     */
    if (g_smart_rt.smoothing_active &&
        !g_smart_rt.night_safe_override &&
        !g_smart_rt.thermal_veto)
    {
        int prev_conf = g_smart_rt.smoothing_from_alpha_x1000 > 0 ? ASB_SMART_CONF_LOW_X1000 : 0;
        int cur_conf  = g_smart_rt.conf_x1000;
        int factor = asb_smart_daypart_smoothing_factor_x100(
            g_smart_rt.smoothing_start_ts, now, prev_conf, cur_conf);
        if (factor < 100) {
            /* Blend: result = from + (to - from) × factor/100 */
            int from = g_smart_rt.smoothing_from_alpha_x1000;
            int to   = alpha;
            alpha = from + ((to - from) * factor) / 100;
        } else {
            /* Smoothing window finished */
            g_smart_rt.smoothing_active = 0;
            g_smart_rt.smoothing_start_ts = 0;
        }
    }
    /* Remember current alpha for the next daypart transition */
    if (g_smart_rt.smoothing_start_ts == 0) {
        g_smart_rt.smoothing_from_alpha_x1000 = (uint16_t)alpha;
    }

    /* CPU max (floor → DEEP_IDLE cap, ceil → GAMING peak) per cluster */
    int bat_vals[3], bal_vals[3], out_vals[3];
    for (int i = 0; i < 3; i++) bat_vals[i] = bat->floor.cpu_max[i];
    for (int i = 0; i < 3; i++) bal_vals[i] = bal->floor.cpu_max[i];
    asb_smart_blend_values_int(bat_vals, bal_vals, 3, alpha, out_vals);
    for (int i = 0; i < 3; i++) out.floor.cpu_max[i] = out_vals[i];

    for (int i = 0; i < 3; i++) bat_vals[i] = bat->ceil.cpu_max[i];
    for (int i = 0; i < 3; i++) bal_vals[i] = bal->ceil.cpu_max[i];
    asb_smart_blend_values_int(bat_vals, bal_vals, 3, alpha, out_vals);
    /* Apply interactive bonus on ceil (peak) — capped at balanced */
    for (int i = 0; i < 3; i++) {
        out.ceil.cpu_max[i] = asb_smart_apply_interactive_bonus(
            out_vals[i], bal->ceil.cpu_max[i], g_smart_rt.interactive_bonus_x1000);
    }

    /* CPU min — no interactive bonus (it's the floor for DEEP_IDLE / GAMING) */
    for (int i = 0; i < 3; i++) bat_vals[i] = bat->floor.cpu_min[i];
    for (int i = 0; i < 3; i++) bal_vals[i] = bal->floor.cpu_min[i];
    asb_smart_blend_values_int(bat_vals, bal_vals, 3, alpha, out_vals);
    for (int i = 0; i < 3; i++) out.floor.cpu_min[i] = out_vals[i];

    for (int i = 0; i < 3; i++) bat_vals[i] = bat->ceil.cpu_min[i];
    for (int i = 0; i < 3; i++) bal_vals[i] = bal->ceil.cpu_min[i];
    asb_smart_blend_values_int(bat_vals, bal_vals, 3, alpha, out_vals);
    for (int i = 0; i < 3; i++) out.ceil.cpu_min[i] = out_vals[i];

    /* GPU pcts */
    int gpu_min_bat[1] = { bat->floor.gpu_min_pct };
    int gpu_min_bal[1] = { bal->floor.gpu_min_pct };
    int gpu_min_out[1];
    asb_smart_blend_values_int(gpu_min_bat, gpu_min_bal, 1, alpha, gpu_min_out);
    out.floor.gpu_min_pct = gpu_min_out[0];

    int gpu_max_bat[1] = { bat->floor.gpu_max_pct };
    int gpu_max_bal[1] = { bal->floor.gpu_max_pct };
    int gpu_max_out[1];
    asb_smart_blend_values_int(gpu_max_bat, gpu_max_bal, 1, alpha, gpu_max_out);
    out.floor.gpu_max_pct = gpu_max_out[0];

    gpu_min_bat[0] = bat->ceil.gpu_min_pct;
    gpu_min_bal[0] = bal->ceil.gpu_min_pct;
    asb_smart_blend_values_int(gpu_min_bat, gpu_min_bal, 1, alpha, gpu_min_out);
    out.ceil.gpu_min_pct = gpu_min_out[0];

    gpu_max_bat[0] = bat->ceil.gpu_max_pct;
    gpu_max_bal[0] = bal->ceil.gpu_max_pct;
    asb_smart_blend_values_int(gpu_max_bat, gpu_max_bal, 1, alpha, gpu_max_out);
    out.ceil.gpu_max_pct = gpu_max_out[0];

    /* Hard invariant: never exceed balanced sustained envelope */
    for (int i = 0; i < 3; i++) {
        if (out.ceil.cpu_max[i] > bal->ceil.cpu_max[i]) out.ceil.cpu_max[i] = bal->ceil.cpu_max[i];
        if (out.ceil.cpu_min[i] > bal->ceil.cpu_min[i]) out.ceil.cpu_min[i] = bal->ceil.cpu_min[i];
    }
    if (out.ceil.gpu_max_pct > bal->ceil.gpu_max_pct) out.ceil.gpu_max_pct = bal->ceil.gpu_max_pct;

    /* Commit to global slot */
    /* Blend the uclamp tiers too - they were left at zero.
     *
     * Every other field of the Smart bounds is blended from the battery and balanced
     * rails, but uclamp_top_max and uclamp_bg_max were never assigned, so the struct
     * carried its zero-initialised value. A device on the Smart profile therefore asked
     * the writer for uclamp 0 on every tick: the state file reads uclamp_want="0,0" with
     * status:applied, and cpu.uclamp.max for top-app sits at 0.00.
     *
     * A zero ceiling tells the scheduler the foreground app may request nothing, which
     * is the same empty-uclamp defect fixed once in the profile rails - and the reason a
     * phone on Smart feels sluggish. Blended the same way as the frequency rails, with
     * the balanced ceiling as the upper bound.
     */
    {
        int ut_bat[1], ut_bal[1], ut_out[1];
        ut_bat[0] = bat->ceil.uclamp_top_max; ut_bal[0] = bal->ceil.uclamp_top_max;
        asb_smart_blend_values_int(ut_bat, ut_bal, 1, alpha, ut_out);
        out.ceil.uclamp_top_max = ut_out[0];
        out.floor.uclamp_top_max = bat->floor.uclamp_top_max;
        ut_bat[0] = bat->ceil.uclamp_bg_max; ut_bal[0] = bal->ceil.uclamp_bg_max;
        asb_smart_blend_values_int(ut_bat, ut_bal, 1, alpha, ut_out);
        out.ceil.uclamp_bg_max = ut_out[0];
        out.floor.uclamp_bg_max = bat->floor.uclamp_bg_max;
        if (out.ceil.uclamp_top_max > bal->ceil.uclamp_top_max)
            out.ceil.uclamp_top_max = bal->ceil.uclamp_top_max;
    }
    /* fix244: the WALT window and packing threshold were never blended either.
     *
     * Same defect as the uclamp tiers above, in the two fields after them: ravg_ticks and
     * idle_enough stayed at the zero memset left, so Smart asked the writer for
     * sched_idle_enough 0 on every tick. Every Smart capture on file reads 0 once the
     * governor runs (OP12, OP13, OP15, Ace 6): no CPU short of a fully idle one counted
     * as idle enough to take work, so screen-off background work woke idle cores the
     * Battery and Balanced rails would have packed onto a busy one - more C-state exits for
     * the profile most people run. The window request was 0 too, which the writer had to
     * reject. Both are blended from the two rails like everything else; on screen the FSM
     * keeps packing at the kernel's own default (fsm_interpolate_caps). */
    {
        int wb[2], wl[2], wo[2];
        wb[0] = bat->floor.idle_enough; wb[1] = bat->floor.ravg_ticks;
        wl[0] = bal->floor.idle_enough; wl[1] = bal->floor.ravg_ticks;
        asb_smart_blend_values_int(wb, wl, 2, alpha, wo);
        out.floor.idle_enough = wo[0];
        out.floor.ravg_ticks  = wo[1];
        wb[0] = bat->ceil.idle_enough; wb[1] = bat->ceil.ravg_ticks;
        wl[0] = bal->ceil.idle_enough; wl[1] = bal->ceil.ravg_ticks;
        asb_smart_blend_values_int(wb, wl, 2, alpha, wo);
        out.ceil.idle_enough = wo[0];
        out.ceil.ravg_ticks  = wo[1];
    }
    g_smart_bounds = out;
    g_smart_bounds_initialized = 1;

    asb_smart_mark_slot_updated(&g_smart_rt, now, charging, g_smart_rt.app_hint);

    /* Dynamic tuner: re-apply readahead/MGLRU/VM/swappiness when the scenario
     * meaningfully changed. Rate-limited to once per 30 seconds and only on
     * a change in hint or thermal bucket or screen-on state. */

    if (g_asb_cfg.smart_debug_log) {
        asb_log("smart_tick: bucket=%d daypart=%d we=%d fb=%d conf=%d alpha=%d "
                "night=%d veto=%d app=%d cpu=%d",
                bid, daypart, is_weekend, g_smart_rt.fallback_level,
                g_smart_rt.conf_x1000, g_smart_rt.alpha_battery_x1000,
                g_smart_rt.night_safe_override, g_smart_rt.thermal_veto,
                g_smart_rt.app_hint, cpu_max_c);
    }
    return 1;
}

/*
 * Smart Mode periodic persistence.
 */
static void asb_smart_persist_check(void) {
    if (!g_smart_rt.enabled || !g_smart_store_loaded) return;
    time_t now = time(NULL);
    /* Save throttled: at most once per 5 minutes */
    /* Save on banked sessions too, not only on the clock.
     *
     * g_smart_sessions_since_save was incremented on every banked session and never read:
     * the only trigger was the 300 s timer. That is usually enough, but it means a session
     * banked shortly before a reboot - or before the governor is restarted by a config
     * change - is lost, and on a phone that is rebooted often the learner can keep losing
     * the same evidence it needs.
     *
     * Two sessions is a cheap threshold: the store is a few KB and the write is atomic.
     */
    if (now - g_smart_last_save_ts >= 300 || g_smart_sessions_since_save >= 2) {
        g_smart_store.last_update_ts = (uint32_t)now;
        int rc = asb_smart_store_save_atomic(&g_smart_store, ASB_SMART_STORE_FILE);
        if (rc == 0) {
            g_smart_last_save_ts = now;
            g_smart_sessions_since_save = 0;
        }
        asb_smart_appheat_save();
    }
    /* Weekly backup */
    if (now - g_smart_last_backup_ts >= ASB_SMART_BACKUP_PERIOD_S) {
        int rc = asb_smart_store_backup(ASB_SMART_STORE_FILE, ASB_SMART_STORE_BAK);
        if (rc == 0) {
            g_smart_last_backup_ts = now;
            asb_log("smart_persist: weekly backup written");
        }
    }
}

static volatile int g_running = 1;
static void sig_handler(int sig) {
    (void)sig;
    g_running = 0;
}

/*
 * Smart Mode init helpers.
 * Returns 1 if Smart Mode enabled, 0 otherwise.
 */
static int asb_smart_init(void) {
    /* Initialise g_smart_bounds to BALANCED defaults so any reads during
     * boot/uninit get a safe envelope */
    memcpy(&g_smart_bounds, &g_profile_bounds[PROFILE_BALANCED], sizeof(g_smart_bounds));
    g_smart_bounds_initialized = 1;

    /* Initialise runtime state */
    memset(&g_smart_rt, 0, sizeof(g_smart_rt));
    g_smart_rt.prev_bucket_id = -1;
    g_smart_rt.prev_daypart = -1;
    g_smart_rt.last_conf_tier = -1;
    g_smart_rt.last_charging = -1;
    g_smart_rt.last_app_hint_tier = -1;
    g_smart_rt.last_night_override = -1;
    g_smart_rt.last_thermal_veto = -1;

    /* Read on/off flag */
    int flag = asb_smart_flag_read();
    if (flag < 0) {
        /*
         * No flag file yet — treat as disabled, but still load the store so a manual profile
         * switch to 'smart' (e.g.
         */
        g_smart_rt.enabled = 0;
        g_asb_cfg.smart_mode_enabled = 0;
        flag = 0;
    } else {
        g_smart_rt.enabled = flag;
        g_asb_cfg.smart_mode_enabled = flag;
    }

    /* Load bucket store (chain: main → bak → seed defaults) regardless of
     * flag — store availability and on/off are separate concerns. */
    asb_smart_load_outcome_t outcome;
    int rc = asb_smart_store_load(&g_smart_store, &outcome);
    asb_smart_appheat_load();
    g_smart_store_loaded = 1;
    /* fix184: the Smart records and the night-wake habit. */
    g_rec_read_cc = asb_rec_cc_file;
    g_rec_read_net = asb_rec_net_bytes;
    g_rec_read_bright_pct = asb_rec_bright_pct;
    {
        int _rl = asb_rec_load();
        asb_rec_summary_write();
        asb_log("records: %s (%s); night wakes learned: %u over %u night(s)",
                _rl == 1 ? "loaded" : _rl == 2 ? "fix184 store: night checks kept, situations re-measured as power"
                         : "fresh start", asb_rec_cc_file() > 0 ? "charge counter readable"
                                                                      : "no charge counter - not measured",
                g_rec.mw.total, g_rec.mw.nights);
    }

    /*
     * The runtime session counters reset on every daemon start, which made the WebUI show "0
     * ses" after a reboot even though the learning itself (the bucket observations) persisted
     * fine.
     */
    {
        unsigned long _obs = 0;
        for (int _b = 0; _b < ASB_SMART_BUCKETS; _b++)
            _obs += g_smart_store.buckets[_b].observations_raw;
        g_smart_sessions_total = (int)_obs;
        g_smart_bucket_updates = (int)_obs;
        /*
         * Also seed the displayed confidence from the best persisted bucket.
         */
        time_t _now_seed = time(NULL);
        int _best_conf = 0;
        for (int _b = 0; _b < ASB_SMART_BUCKETS; _b++) {
            int _c = asb_smart_confidence_x1000(&g_smart_store.buckets[_b], _now_seed);
            if (_c > _best_conf) _best_conf = _c;
        }
        g_smart_last_confidence = _best_conf;
    }

    if (outcome.loaded_from_main) {
        asb_log("smart_init: loaded main store, %d buckets, version %d",
            g_smart_store.bucket_count, g_smart_store.version);
    } else if (outcome.loaded_from_backup) {
        asb_log("smart_init: main store invalid (reason=%d), restored from backup",
            outcome.reset_reason);
    } else if (outcome.seeded) {
        asb_log("smart_init: store unreadable (reason=%d), seeded fresh defaults",
            outcome.reset_reason);
    }
    (void)rc;

    g_smart_last_save_ts = time(NULL);
    g_smart_last_backup_ts = g_smart_last_save_ts;
    return flag;
}

int main(int argc, char **argv) {
    /* fix187: LSPosed's verbose-log switch, for runtime/asb_lsposed.sh - no daemon involved. */
    if (argc >= 3 && strcmp(argv[1], "--lspd") == 0) return asb_lspd_cli(argc - 2, argv + 2);
    if (argc >= 2) {
        /*
         * expanded status JSON with 6 new thermal fields (skin_temp, surface_hotspot,
         * thermal_cpu_zone/type, thermal_skin_zone, thermal_surface_zone,
         * ses_max_surface_temp) pushed worst-case payload to ~1000 bytes.
         */
        char reply[4096] = {0};
        asb_sock_send_cmd(argv[1], reply, sizeof(reply));
        if (reply[0]) puts(reply);
        return 0;
    }

    {
        char pidbuf[16] = {0};
        int pfd = open(PID_FILE, O_RDONLY | O_CLOEXEC);
        if (pfd >= 0) {
            ssize_t _r = read(pfd, pidbuf, sizeof(pidbuf)-1);
            (void)_r;
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
        if (pfd >= 0) {
            ssize_t _w = write(pfd, pidbuf, strlen(pidbuf));
            (void)_w;
            close(pfd);
        }
    }

    g_gov_start_ts = time(NULL);
    g_logf = fopen(LOG_FILE, "a");
    asb_log("=== asb_governor starting (pid %d, flavor=%s) ===", getpid(),
            "unified");

    signal(SIGTERM, sig_handler);
    signal(SIGINT,  sig_handler);
    signal(SIGPIPE, SIG_IGN);

    asb_config_defaults(&g_asb_cfg);
    int initial_cfg_rc = asb_config_load_file(CONFIG_FILE, &g_asb_cfg);
    g_cfg_load_rc = initial_cfg_rc;
    g_cfg_load_ts = time(NULL);
    if (initial_cfg_rc != 0) {
        asb_log("config_reject: startup load failed rc=%d; using built-in safe defaults", initial_cfg_rc);
        asb_config_defaults(&g_asb_cfg);
    } else {
        asb_config_apply_highload_mode(&g_asb_cfg);
    }
    /*
     * Per-device bounds override (Phase 2, opt-in via device_bounds_override=1).
     */
    {
        static asb_profile_bounds_t _bounds_defaults[3];
        memcpy(_bounds_defaults, g_profile_bounds, sizeof(_bounds_defaults));
        int _ovr = asb_load_device_bounds_override(g_asb_cfg.device_bounds_override,
                                                   _bounds_defaults);
        if (_ovr > 0) asb_log("device_bounds: applied %d per-device override(s) from %s",
                              _ovr, ASB_DEVICE_BOUNDS_FILE);
        /* Say so when the switch is on and nothing loaded: the compiled rails are the OP15
         * reference, and running them on another SoC must not look like a synthesised fit
         * (external audit P1). The writer still snaps every value to this device's own
         * frequency table, so nothing invalid reaches sysfs either way. */
        else if (g_asb_cfg.device_bounds_override)
            asb_log_critical("device_bounds: %s/%s for %s - compiled reference rails in force",
                             g_device_bounds_status, g_device_bounds_reason,
                             ASB_DEVICE_BOUNDS_FILE);
        g_device_bounds_applied = _ovr;
    }
    asb_active_efficiency_load();
    asb_night_window_load();
    {
        int stale_warnings = 0;
        if (g_asb_cfg.heavy_load_enter < 10.0f) {
            asb_log("config_audit: heavy_load_enter=%.1f is much lower than the default (20.0). "
                    "If you didn't customize this, your config may be stale. "
                    "To restore defaults: rm /data/adb/modules/AutoSystemBoost/config/governor.conf "
                    "&& reflash module.",
                    g_asb_cfg.heavy_load_enter);
            stale_warnings++;
        }
        if (g_asb_cfg.bat_heavy_load_enter < 10.0f && g_asb_cfg.bat_heavy_load_enter > 0) {
            asb_log("config_audit: bat_heavy_load_enter=%.1f is much lower than the default (20.0). "
                    "Likely stale config.",
                    g_asb_cfg.bat_heavy_load_enter);
            stale_warnings++;
        }
        if (g_asb_cfg.bat_fast_idle_s < 10) {
            asb_log("config_audit: bat_fast_idle_s=%d is much lower than the default (15). "
                    "Likely stale config.",
                    g_asb_cfg.bat_fast_idle_s);
            stale_warnings++;
        }
        if (stale_warnings > 0) {
            FILE *sf = fopen("/dev/.asb/config_stale_detected", "w");
            if (sf) {
                fprintf(sf, "stale_warnings=%d\n", stale_warnings);
                fprintf(sf, "heavy_load_enter=%.1f (default 20.0)\n", g_asb_cfg.heavy_load_enter);
                fprintf(sf, "bat_heavy_load_enter=%.1f (default 20.0)\n", g_asb_cfg.bat_heavy_load_enter);
                fprintf(sf, "bat_fast_idle_s=%d (default 15)\n", g_asb_cfg.bat_fast_idle_s);
                fprintf(sf, "to_reset_to_defaults: rm %s && reflash\n", CONFIG_FILE);
                fclose(sf);
            }
        }
    }

    thermal_discover();
    writer_init_cache();
    persistent_stats_load();
    sweep_stale_session();

    /* Smart Mode init (no-op if smart_mode_enabled file flag not set) */
    asb_smart_init();

    /* OTA quarantine -- detect environment changes */
    {
        #define ENV_FP_FILE PERSISTENT_STATS_DIR "/env_fingerprint"
        #define QUARANTINE_SESSIONS 3
        char cur_fp[256] = {0};
        char kern[128] = {0};
        FILE *kf = fopen("/proc/version", "r");
        if (kf) {
            char *_g = fgets(kern, sizeof(kern), kf);
            (void)_g;
            fclose(kf);
        }
        /* trim newline */
        char *nl = strchr(kern, '\n'); if (nl) *nl = '\0';
        snprintf(cur_fp, sizeof(cur_fp), "%s|%s", ASB_VERSION, kern);

        char old_fp[256] = {0};
        FILE *ef = fopen(ENV_FP_FILE, "r");
        if (ef) {
            char *_g = fgets(old_fp, sizeof(old_fp), ef);
            (void)_g;
            fclose(ef);
        }
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

    /* Seconds since boot on the persistent line (fix144): the log tail in asbdiag listed
     * twelve starts and could not say which were boots and which were restarts. A start
     * long after boot with no "stopped cleanly" before it is a crash that was recovered. */
    asb_log_critical("asb_governor %s started (pid %d, %lds after boot)", ASB_VERSION, getpid(),
                     asb_clock_ms(CLOCK_BOOTTIME) / 1000);
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
    /* The session the "session_start" line announces has to exist (fix167).
     *
     * fsm_init clears the struct, and only fsm_session_reset gives a session its start time
     * and its sentinels (efficiency -1, headroom minimum 100). Nothing called it at startup,
     * so until the first profile change or reset command ses_start_ts stayed 0 - and every
     * session clock reads 0 when the start is 0. Smart's 20-minute bank, the deep-idle
     * session boundary, intent classification, the session history line and the bank on
     * shutdown are all gated on that age. The fix163 capture booted at 01:49 and banked
     * nothing until it ended at 08:49: smart_sessions_total held at 726 and
     * smart_quality_last at -1 for seven hours. The zero headroom minimum also read as a
     * vendor clamp ("cause_streak: vendor_clamp x3 consecutive" with the vendor quiet). */
    fsm_session_reset(&fsm);
    fsm_profile_is_battery = (profile_idx == PROFILE_BATTERY);
    fsm_profile_is_performance = (profile_idx == PROFILE_PERFORMANCE);
    fsm_profile_is_smart   = (profile_idx == PROFILE_SMART);
    fsm_profile_is_balanced = (profile_idx == PROFILE_BALANCED);

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

    /* Stamp the start before the loop: without it the published uptime is the whole
       epoch and every rate comes out as zero. */
    g_governor_start_ts = time(NULL);
    int tfd_active = make_timerfd(TIMER_ACTIVE_S);
    /* The screen-off tick runs on CLOCK_BOOTTIME (plain, not _ALARM): it never wakes the
     * phone, but it counts time spent suspended, so the first resume after the interval
     * has passed delivers a tick at once. On CLOCK_MONOTONIC the interval only advanced
     * while the CPU was awake: after a night in suspend the first tick came up to 45 s of
     * AWAKE time after the screen turned on, and an OP15 capture shows exactly that - a
     * 07:12 wake noticed by the tick, deep-idle rails until then. */
    int tfd_idle   = make_timerfd_clock(CLOCK_BOOTTIME, TIMER_IDLE_S);
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
    {
        int _dpe = asb_disp_waiter_start();
        if (_dpe >= 0) {
            ev.data.fd = _dpe; epoll_ctl(epfd, EPOLL_CTL_ADD, _dpe, &ev);
            asb_log("display waiter: watching Android's display state for wakes");
        }
    }
    if (uefd >= 0) {
        wake_keys_open(epfd);
        asb_log("wake keys: %d input device(s) watched for power/wakeup while the screen is off",
                g_wake_key_n);
    }
    if (touch_open() >= 0)
        asb_log("touch watch: touchscreen found - a touch on a calm screen is answered at once");
    /* Started with the screen on: the active tick owns screen detection until it goes off. */
    if (screen_on) uev_park(epfd, uefd);

    asb_metrics_t metrics;
    memset(&metrics, 0, sizeof(metrics));

    metrics_read_all(&metrics, 1, 1);  /* startup: always read headroom + thermal */
    /* Hand the app classification to the FSM before it decides.
     * The Smart package table already knows which app is a game; without this the FSM
     * only ever saw GPU load, and a game that does not push the GPU past the entry
     * threshold never reached GAMING at all.
     * fix210: classify first on the manual profiles too - otherwise the hint stays 0,
     * the gate's "no package information" fallback counts as agreement, and any busy
     * GPU next to a busy CPU reads as GAMING. */
    asb_fg_classify_tick(&metrics, &fsm);
    metrics.misc.app_hint = g_smart_rt.app_hint;
    fsm_update(&fsm, &metrics);

    /* detect initial user ID */
    g_last_user_id = get_current_user_id();

    session_plan_build(&fsm, metrics.misc.screen_on);
    session_plan_apply_prearm(&fsm);
    {
        static const char *_pc_names[] = {
            "idle_clean","idle_noisy","daily_active","perf_active",
            "perf_clamped","benchmark","quarantine"
        };
        const char *pc = (fsm.plan.plan_class <= 6) ? _pc_names[fsm.plan.plan_class] : "?";
        asb_log("plan: class=%s sensor=%d thermal_div=%d hr=%d ac=%d deep=%d "
                "ac_budget=%d prearm=%d sensor_budget=%d quar=%d user=%d",
                pc, fsm.plan.sensor_tier, fsm.plan.thermal_div,
                fsm.plan.allow_hr, fsm.plan.ac_eligible, fsm.plan.deep_sleep,
                fsm.plan.ac_budget, fsm.plan.ac_prearm, fsm.plan.sensor_budget,
                fsm.plan.quarantine, g_last_user_id);
    }
    /* run smart_tick BEFORE the first writer_apply_caps so the boot
     * write already reflects fresh g_smart_bounds when profile is SMART.
     * Without this, the first write uses BALANCED defaults until the next
     * tick refreshes — visible as a brief envelope flicker at boot. */
    {
        /* Track suspend before anything else this tick: the numbers come from the
         * clocks, not from the metrics, so they are valid even when a probe failed. */
        asb_awake_track(metrics.misc.screen_on);
        asb_offdrain_track(metrics.misc.screen_on, metrics.bat.capacity_pct, metrics.bat.charging, fsm.profile_idx);
        asb_curscale_track(metrics.misc.screen_on, metrics.bat.capacity_pct, metrics.bat.charging, metrics.bat.current_ma);
        int _smart_updated = asb_smart_tick(&metrics, &fsm);
        if (_smart_updated && fsm.profile_idx == PROFILE_SMART) {
            asb_profile_caps_t _new_caps;
            fsm_interpolate_caps(asb_profile_bounds_for(fsm.profile_idx),
                                 fsm.profile_idx, fsm.state,
                         0, 0.0f, &_new_caps);
            if (fsm.thermal_cap && fsm.state != ASB_STATE_SUSTAINED) {
                float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
                for (int i = 0; i < 3; i++)
                    _new_caps.cpu_max[i] = (int)(_new_caps.cpu_max[i] * keep);
            }
            /* The user's ceiling trim, applied to what the governor just computed.
             *
             * The shell path already honoured perf_ceiling_pct when writing the uclamp
             * tiers, but on Smart the CPU caps are recomputed here every tick from the
             * profile bounds - so the full value went straight back and the setting did
             * nothing. Reported as: set to 75, games still hot.
             *
             * Ceilings only, and floors are left alone, matching what the shell does.
             */
            /* Snap the caps here, where they are decided - not only in the writer.
             *
             * The writer already snapped before writing, so the hardware got a real
             * frequency. But current_caps kept the raw ratio value, and the anti-clamp
             * detector compares current_caps against what sysfs reads back. Part of the
             * difference it saw was therefore its own rounding, reported as a vendor
             * clamp: the log shows cpu_max=[3140760,2627631], numbers no device has.
             *
             * Snapping at the decision point makes the request, the write and the
             * comparison all refer to the same number, which is the only way the detector
             * can tell "somebody overrode us" from "we asked for something impossible".
             */
            for (int i = 0; i < 3; i++) {
                if (_new_caps.cpu_max[i] <= 0) continue;
                int _si = -1;
                for (int k = 0; k < g_cpu_all_paths_n && k < 16; k++) {
                    if (g_cpu_all_max_paths[k][0] && g_cpu_max_paths[i][0] &&
                        strcmp(g_cpu_all_max_paths[k], g_cpu_max_paths[i]) == 0) { _si = k; break; }
                }
                if (_si >= 0)
                    _new_caps.cpu_max[i] = (int)cpu_snap_freq(_si, (long)_new_caps.cpu_max[i]);
            }
            if (g_asb_cfg.perf_ceiling_pct > 0 && g_asb_cfg.perf_ceiling_pct < 100) {
                /* Trim the PEAK, not the whole ladder.
                 *
                 * Applied flat, this multiplies the idle and light states too - and those
                 * are already low by design, so there it does harm instead of good. Worse,
                 * because the ladder rises faster than the trim, a low setting inverts it:
                 * at 60% on an OP15 little cluster GAMING lands on 1566720 while HEAVY
                 * lands on 1593630. The phone ends up SLOWER under load than off it, which
                 * is the opposite of every reason someone touches this control.
                 *
                 * A user lowering this expects a calmer phone under load. What they got was
                 * one that crawls at rest: a task needing 100 ms at full clock needs 330 ms
                 * at a third of it, with every core, the display and the radio awake for
                 * the whole stretch. That is race-to-idle, and it is why a capture with
                 * perf_ceiling_pct=70 showed higher drain than none at all.
                 *
                 * Weighted by ladder position: full effect at GAMING, none at DEEP_IDLE.
                 * The setting keeps meaning what the user thinks it means, and the ladder
                 * stays monotonic at every value the slider can produce.
                 */
                float _pc_w = (fsm.state >= 0 && fsm.state < ASB_STATE_COUNT)
                              ? g_state_level[fsm.state] : 1.0f;
                if (_pc_w < 0.0f) _pc_w = 0.0f;
                if (_pc_w > 1.0f) _pc_w = 1.0f;

                /* Scale the weighting to the ladder this profile actually has.
                 *
                 * Raising the slider's minimum was not enough, and could not be: the trim
                 * grows with ladder position at a fixed rate, while how much room the
                 * ladder has depends on the profile. Battery spans 45% between its floor
                 * and ceiling, Performance only 36% - so the same 35% trim eats the whole
                 * ladder on one and not the other, and the state above ends up capped
                 * lower than the state below it.
                 *
                 * Checked across all six profile/cluster pairs at every slider value: five
                 * inversions remained at 65%, all of them on the narrow ladders.
                 *
                 * Limiting the weighted trim to half the ladder's own span keeps the peak
                 * above every rung under it on any profile, and on any SoC - the span is
                 * read from the bounds in force, not assumed.
                 */
                {
                    const asb_profile_bounds_t *_pb = asb_profile_bounds_for(fsm.profile_idx);
                    if (_pb && _pb->ceil.cpu_max[0] > 0 && _pb->floor.cpu_max[0] > 0) {
                        long _span = _pb->ceil.cpu_max[0] - _pb->floor.cpu_max[0];
                        long _room = _span * 50 / (_pb->ceil.cpu_max[0] ? _pb->ceil.cpu_max[0] : 1);
                        /* Explicit casts: the strict-warning budget counts implicit
                         * int-to-float conversions, and these two were the whole overage. */
                        float _pc_gap = (float)(100 - g_asb_cfg.perf_ceiling_pct);
                        if (_room > 0 && _pc_gap > 0.0f && _pc_w * _pc_gap > (float)_room)
                            _pc_w = (float)_room / _pc_gap;
                    }
                }

                int _pc_eff = 100 - (int)((float)(100 - g_asb_cfg.perf_ceiling_pct) * _pc_w);
                if (_pc_eff < g_asb_cfg.perf_ceiling_pct) _pc_eff = g_asb_cfg.perf_ceiling_pct;
                if (_pc_eff > 100) _pc_eff = 100;


                for (int i = 0; i < 3; i++) {
                    if (_new_caps.cpu_max[i] > 0)
                        _new_caps.cpu_max[i] =
                            (int)((long)_new_caps.cpu_max[i] * _pc_eff / 100);
                }
                if (_new_caps.gpu_max_pct > 0)
                    _new_caps.gpu_max_pct =
                        _new_caps.gpu_max_pct * _pc_eff / 100;
                for (int i = 0; i < 3; i++) {
                    /* Never leave a floor above the ceiling we just lowered - that is the
                     * contradiction the writer had to clean up after. */
                    if (_new_caps.cpu_min[i] > 0 && _new_caps.cpu_max[i] > 0 &&
                        _new_caps.cpu_min[i] > _new_caps.cpu_max[i])
                        _new_caps.cpu_min[i] = _new_caps.cpu_max[i];
                }
            }
            fsm.current_caps = _new_caps;
        }
    }
    {
        asb_profile_caps_t _effective_caps = fsm.current_caps;
        asb_apply_adaptive_budget_caps(&_effective_caps, &metrics, &fsm);
        writer_apply_caps(&_effective_caps, 1, fsm.state, fsm.thermal_cap);
    }
    write_state(&fsm, &metrics, cur_pred);
    {
        int bidx = metrics_find_batt_current_path();
        asb_log("diag: battery_current_path=%s (raw=%d uA = %d mA)",
                bidx >= 0 ? g_batt_current_paths[bidx] : "NOT_FOUND",
                metrics.bat.current_ua,
                metrics.bat.current_ma);
        asb_log("diag: screen_on=%d thermal_cpu_zone=%d thermal_skin_zone=%d",
                metrics.misc.screen_on, g_thermal_cpu_zone, g_thermal_skin_zone);
        {
            char _zt_path[128], _zt_cpu[64] = "none", _zt_skin[64] = "none";
            if (g_thermal_cpu_zone >= 0) {
                snprintf(_zt_path, sizeof(_zt_path),
                         "/sys/class/thermal/thermal_zone%d/type", g_thermal_cpu_zone);
                FILE *_f = fopen(_zt_path, "r");
                if (_f) { if (fgets(_zt_cpu, sizeof(_zt_cpu), _f)) { char *n=strchr(_zt_cpu,'\n'); if(n)*n=0; } fclose(_f); }
            }
            if (g_thermal_skin_zone >= 0) {
                snprintf(_zt_path, sizeof(_zt_path),
                         "/sys/class/thermal/thermal_zone%d/type", g_thermal_skin_zone);
                FILE *_f = fopen(_zt_path, "r");
                if (_f) { if (fgets(_zt_skin, sizeof(_zt_skin), _f)) { char *n=strchr(_zt_skin,'\n'); if(n)*n=0; } fclose(_f); }
            }
            asb_log("diag: thermal_cpu=%s (zone%d) thermal_skin=%s (zone%d)",
                    _zt_cpu, g_thermal_cpu_zone, _zt_skin, g_thermal_skin_zone);
            asb_log("diag: thermal_cpu_choice=%s reason=%s",
                    g_thermal_cpu_type[0] ? g_thermal_cpu_type : "unknown",
                    g_thermal_cpu_reason);
        }
        /* dump every thermal zone on startup -- one line per zone -- so
         * next tuning cycle doesn't require pulling thermal_zones from adb. */
        {
            char _zt_path[128], _zt_type[64], _zt_tmp[32];
            int _dumped = 0;
            for (int _z = 0; _z < 128; _z++) {
                snprintf(_zt_path, sizeof(_zt_path),
                         "/sys/class/thermal/thermal_zone%d/type", _z);
                FILE *_ft = fopen(_zt_path, "r");
                if (!_ft) continue;
                _zt_type[0] = '\0';
                if (fgets(_zt_type, sizeof(_zt_type), _ft)) {
                    char *n = strchr(_zt_type, '\n'); if (n) *n = 0;
                }
                fclose(_ft);
                snprintf(_zt_path, sizeof(_zt_path),
                         "/sys/class/thermal/thermal_zone%d/temp", _z);
                FILE *_fv = fopen(_zt_path, "r");
                int _rawv = 0;
                if (_fv) {
                    if (fgets(_zt_tmp, sizeof(_zt_tmp), _fv)) {
                        _rawv = atoi(_zt_tmp);
                    }
                    fclose(_fv);
                }
                int _c = (_rawv > 200) ? (_rawv / 1000) : _rawv;
                asb_log("tz_dump: zone%d|%s|raw=%d|c=%d", _z, _zt_type, _rawv, _c);
                _dumped++;
            }
            asb_log("tz_dump: total=%d zones scanned", _dumped);
        }
        /* one-line thermal summary so users don't have to read 96 tz_dump lines.
         * Format: thermal_summary: cpu=<type>(z<N>,val=<C>,valid=<0|1>) skin=<type>(z<N>,val=<C>) surface=<type>(z<N>,val=<C>) */
        {
            char _ttype[3][64]; int _tval[3] = {0,0,0}; int _zlist[3];
            _zlist[0] = g_thermal_cpu_zone;
            _zlist[1] = g_thermal_skin_zone;
            _zlist[2] = g_thermal_surface_zone;
            for (int _ti = 0; _ti < 3; _ti++) {
                _ttype[_ti][0] = '\0';
                if (_zlist[_ti] < 0) { snprintf(_ttype[_ti], sizeof(_ttype[_ti]), "none"); continue; }
                char _p[128]; FILE *_f;
                snprintf(_p, sizeof(_p), "/sys/class/thermal/thermal_zone%d/type", _zlist[_ti]);
                _f = fopen(_p, "r");
                if (_f) { if (fgets(_ttype[_ti], sizeof(_ttype[_ti]), _f)) { char *n=strchr(_ttype[_ti],'\n'); if(n)*n=0; } fclose(_f); }
                snprintf(_p, sizeof(_p), "/sys/class/thermal/thermal_zone%d/temp", _zlist[_ti]);
                _f = fopen(_p, "r");
                if (_f) { char b[32]; if (fgets(b,sizeof(b),_f)) { int r=atoi(b); _tval[_ti] = (r>200)?(r/1000):r; } fclose(_f); }
            }
            asb_log("thermal_summary: cpu=%s(z%d,val=%dC,valid=%d) skin=%s(z%d,val=%dC) surface=%s(z%d,val=%dC)",
                    _ttype[0], g_thermal_cpu_zone, _tval[0], metrics.therm.temp_valid,
                    _ttype[1], g_thermal_skin_zone, _tval[1],
                    _ttype[2], g_thermal_surface_zone, _tval[2]);
        }
        asb_log("diag: gpu_load=%d%% valid=%d gpu_maxfreq=%ld",
                metrics.gpu.load_pct, metrics.gpu.load_valid, metrics.gpu.max_freq_hz);
        cpu_topology_discover();
        /* Print the policies actually chosen, not a guess at what they must be.
         *
         * These two lines named fixed policy numbers regardless of what discovery found.
         * On a CPH2581 - policies 0, 2, 5 and 7 - the log read "policy0+policy4+policy7"
         * while policy4 does not exist on that device at all. Discovery had in fact picked
         * correctly; only the message was wrong, which is worse than no message: it sent
         * two people looking for a topology bug that was not there.
         *
         * Reading the array costs nothing and cannot drift from reality. */
        {
            /* Build the list from the slots that are actually filled: an unused slot holds
               -1, and printing "policy-1" would trade one confusing message for another. */
            char _topo[64]; int _tp = 0;
            _topo[0] = 0;
            for (int _s = 0; _s < 3; _s++) {
                if (g_cpu_policy_ids[_s] < 0) continue;
                _tp += snprintf(_topo + _tp, sizeof(_topo) - (size_t)_tp,
                                "%spolicy%d", _tp ? "+" : "", g_cpu_policy_ids[_s]);
                if (_tp >= (int)sizeof(_topo)) break;
            }
            asb_log("diag: cpu_topology=%s (%d cluster%s)",
                    _topo[0] ? _topo : "none",
                    g_cpu_policy_count, g_cpu_policy_count == 1 ? "" : "s");
        }
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

        /* probe device capabilities once at startup */
        memset(&g_device_caps, 0, sizeof(g_device_caps));
        g_device_caps.has_msm_perf = msm_perf_check() ? 1 : 0;
        g_device_caps.has_headroom = (access("/sys/kernel/msm_performance/parameters/cpu_max_freq", R_OK) == 0);
        g_device_caps.has_thermal_cpu = (g_thermal_cpu_zone >= 0);
        g_device_caps.has_thermal_skin = (g_thermal_skin_zone >= 0);
        g_device_caps.has_gpu_load = (uint8_t)(metrics.gpu.load_valid ? 1 : 0);
        g_device_caps.has_uclamp = (access("/dev/cpuctl/top-app/cpu.uclamp.max", W_OK) == 0);
        asb_log("caps: msm=%d hr=%d thermal_cpu=%d thermal_skin=%d gpu=%d uclamp=%d",
                g_device_caps.has_msm_perf, g_device_caps.has_headroom,
                g_device_caps.has_thermal_cpu, g_device_caps.has_thermal_skin,
                g_device_caps.has_gpu_load, g_device_caps.has_uclamp);
        asb_log("diag: cfg heavy_gpu=%d heavy_load=%.1f gaming_gpu=%d sustained_gpu=%d sustained_load=%.1f sustained_temp=%d/%d sustained_lvl=%.2f dwell=%d/%d/%d reassert=%d/%d boost_only=%d throttle_temp=%d highload_mode=%s bat_fast_idle=%d bat_suppress=%d",
                g_asb_cfg.heavy_gpu_enter, g_asb_cfg.heavy_load_enter,
                g_asb_cfg.gaming_gpu_enter, g_asb_cfg.sustained_gpu_min,
                g_asb_cfg.sustained_load_min,
                asb_config_profile_sustained_temp_enter(&g_asb_cfg, PROFILE_PERFORMANCE),
                asb_config_profile_sustained_temp_exit(&g_asb_cfg, PROFILE_PERFORMANCE),
                asb_config_profile_sustained_level(&g_asb_cfg, PROFILE_PERFORMANCE),
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
            asb_profile_name(profile_idx),
            g_asb_cfg.highload_mode == 1 ? "burst" :
            g_asb_cfg.highload_mode == 2 ? "stable" :
            g_asb_cfg.highload_mode == 3 ? "auto" : "default",
            metrics.bat.capacity_pct, metrics.therm.cpu_max_c,
                    asb_config_profile_sustained_temp_enter(&g_asb_cfg, profile_idx),
                    asb_config_profile_sustained_temp_exit(&g_asb_cfg, profile_idx),
                    g_asb_cfg.gaming_gpu_enter);

    struct epoll_event events[MAX_EVENTS];

    while (g_running) {
        int nev = epoll_wait(epfd, events, MAX_EVENTS, -1);
        if (nev < 0) {
            if (errno == EINTR) continue;
            break;
        }

        /* One wakeup, however many descriptors were ready.
         *
         * epoll_wait returns the NUMBER of ready descriptors, and adding that counted a
         * single wake with five ready fds as five wakeups. A capture reads 10546 against
         * 1963 timer wakeups, suggesting the event path costs five times the timer - it
         * does not, the two were measured differently.
         *
         * The cost of a wakeup is the wake itself: the process is scheduled, the CPU leaves
         * idle, the tick body runs once. That is what this counter is read as, so that is
         * what it should count. */
        g_governor_event_wakeups++;
        int need_metrics = 0;
        int force_write  = 0;
        int profile_changed = 0;

        static time_t g_last_state_touch = 0;
        static time_t g_last_heartbeat   = 0;
        static time_t g_last_profile_sync = 0;
        {
            time_t _now = time(NULL);
            if (_now - g_last_state_touch >= 60) {
                /*
                 * profile drift safety net.
                 */
                if (_now - g_last_profile_sync >= 60) {
                    int _file_idx = read_profile_idx();
                    if (_file_idx != fsm.profile_idx) {
                        asb_log("profile_drift_detected: fsm=%d file=%d resyncing",
                                fsm.profile_idx, _file_idx);
                        fsm_flush_state_time(&fsm);
                        persistent_stats_save(&fsm);
                        session_history_append_ex(&fsm, "profile_drift_resync");
                        session_end_self_tune(&fsm);
                        fsm_session_reset(&fsm);
                        fsm.plan.ac_used = 0;
                        fsm.profile_idx = _file_idx;
                        fsm_profile_is_battery = (_file_idx == PROFILE_BATTERY);
                        fsm_profile_is_performance = (_file_idx == PROFILE_PERFORMANCE);
                        fsm_profile_is_smart   = (_file_idx == PROFILE_SMART);
                        fsm_profile_is_balanced = (_file_idx == PROFILE_BALANCED);
                        force_write = 1;
                        g_last_reassert = 0;
                        storm_shield_reset();
                        anti_clamp_reset();
                        session_plan_build(&fsm, metrics.misc.screen_on);
                        session_plan_apply_prearm(&fsm);
                        asb_log("session_start profile=%s highload=%s bat=%d%% temp=%d "
                                "sus_enter=%d sus_exit=%d gaming_gpu=%d (drift_resync)",
                                asb_profile_name(_file_idx),
                                g_asb_cfg.highload_mode == 1 ? "burst" :
                                g_asb_cfg.highload_mode == 2 ? "stable" :
                                g_asb_cfg.highload_mode == 3 ? "auto" : "default",
                                metrics.bat.capacity_pct, metrics.therm.cpu_max_c,
                                asb_config_profile_sustained_temp_enter(&g_asb_cfg, fsm.profile_idx),
                                asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm.profile_idx),
                                g_asb_cfg.gaming_gpu_enter);
                    }
                    g_last_profile_sync = _now;
                }
                {
                    /* Suspend tracking belongs in the loop, not only in the pre-loop
                     * init block where it was.
                     *
                     * Called once at startup it can never accumulate a window, so
                     * awake_pct_screenoff sat at -1 forever - the diagnostic said "not
                     * measured yet" on a phone that had been running for a day, and
                     * asb_wakelock_watch.sh, which gates on that figure, never took a
                     * single snapshot. Two features silently inert because their input
                     * was computed in the wrong place.
                     */
                    asb_awake_track(metrics.misc.screen_on);
                    asb_offdrain_track(metrics.misc.screen_on, metrics.bat.capacity_pct, metrics.bat.charging, fsm.profile_idx);
                    asb_curscale_track(metrics.misc.screen_on, metrics.bat.capacity_pct, metrics.bat.charging, metrics.bat.current_ma);
                    int _smart_updated = asb_smart_tick(&metrics, &fsm);
                    if (_smart_updated && fsm.profile_idx == PROFILE_SMART) {
                        asb_profile_caps_t _new_caps;
                        fsm_interpolate_caps(asb_profile_bounds_for(fsm.profile_idx),
                                             fsm.profile_idx, fsm.state,
                         0, 0.0f, &_new_caps);
                        if (fsm.thermal_cap && fsm.state != ASB_STATE_SUSTAINED) {
                            float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
                            for (int i = 0; i < 3; i++)
                                _new_caps.cpu_max[i] = (int)(_new_caps.cpu_max[i] * keep);
                        }
                        int _diff = 0;
                        for (int i = 0; i < 3; i++) {
                            if (_new_caps.cpu_max[i] != fsm.current_caps.cpu_max[i]) { _diff = 1; break; }
                            if (_new_caps.cpu_min[i] != fsm.current_caps.cpu_min[i]) { _diff = 1; break; }
                        }
                        /* Count the ticks that decided nothing, so the ratio is measurable.
                         *
                         * The semantic no-op is already here - _diff guards the whole write path. What was
                         * missing is the number: without it, "the writer filters correctly" is a claim
                         * about the code rather than a fact about the device, and stage 1 of the
                         * lightening plan asks for exactly that fact.
                         *
                         * A high no-op share is the healthy state: it means the ladder settled and the
                         * governor is watching rather than acting. A low one on an idle phone would mean
                         * something upstream keeps producing new caps for no reason. */
                        if (!_diff) g_stat_noop_ticks++;
                        if (_diff) {
                            fsm.current_caps = _new_caps;
                            asb_profile_caps_t _effective_caps = fsm.current_caps;
                            asb_apply_adaptive_budget_caps(&_effective_caps, &metrics, &fsm);
                            /* A heartbeat refresh inside the unlock window keeps the lift (fix150). */
                            if (g_unlock_lift_now && !fsm.thermal_cap && metrics.misc.screen_on)
                                asb_unlock_lift_apply(&_effective_caps);
                            asb_rec_apply_offcaps(&_effective_caps, &fsm, metrics.misc.screen_on);   /* fix184 */
                            int _w = writer_apply_caps(&_effective_caps, 1, fsm.state, fsm.thermal_cap);
                            g_writer_floor_pct = 0;
                            if (_w > 0) { g_total_writes += _w; g_last_write_ts = time(NULL); }
                            if (g_asb_cfg.smart_debug_log) {
                                asb_log("smart_tick(heartbeat): forced caps refresh");
                            }
                        }
                    }
                }
                write_state(&fsm, &metrics, cur_pred);
                /*
                 * also write conflicts.json and learner_state.json for WebUI.
                 */
                write_conflicts_json();
                write_learner_state_json(&fsm);
                g_last_state_touch = _now;
            }
            if (g_last_heartbeat == 0) g_last_heartbeat = _now;
            if (_now - g_last_heartbeat >= 900) {
                /* State names come from the FSM's own table (fix120). This line used to carry
                 * a private copy with GAMING and SUSTAINED swapped - the enum is SUSTAINED=4,
                 * GAMING=5 - so every heartbeat during a thermal hold read "state=GAMING". An
                 * OP15 capture shows it: "heartbeat: state=GAMING ... gpu=5" between
                 * "FSM: SUSTAINED" and "exit_sustained", with no GAMING transition anywhere.
                 * A log that names the wrong state sends the analysis after the wrong fix. */
                static const char *_enames[] = {"quiet","noisy","hostile"};
                fsm_flush_state_time(&fsm);  /* flush before heartbeat so bat_deep/light/mod are current */
                int _hb_env = classify_environment(&fsm);
                asb_log("heartbeat: state=%s profile=%d temp=%d%s headroom=%d%% load=%.1f gpu=%d bat=%d "
                        "ses_heavy=%lds ses_sus=%lds bat_deep=%lds bat_wake=%d env=%s waste=%d sc=%d hc=%d",
                        ((int)fsm.state >= 0 && (int)fsm.state < ASB_STATE_COUNT) ? asb_state_names[fsm.state] : "?",
                        fsm.profile_idx,
                        metrics.therm.cpu_max_c,
                        metrics.therm.temp_valid ? "" : "(stale)",
                        metrics.therm.headroom_pct,
                        metrics.cpu.load1,
                        metrics.gpu.load_pct,
                        metrics.bat.capacity_pct,
                        fsm.ses_time_heavy_sec,
                        fsm.ses_time_sustained_sec,
                        fsm.bat_time_deep_idle_sec,
                        fsm.bat_wake_cycles,
                        _enames[_hb_env],
                        g_action_waste,
                        metrics.therm.soft_clamp,
                        metrics.therm.hard_clamp);
                g_last_heartbeat = _now;
                /*
                 * action waste decay -- env-aware.
                 */
                if (g_action_waste > 0) {
                    int _hb_env_d = classify_environment(&fsm);
                    if (_hb_env_d == ENV_QUIET && !fsm.clamp_hold)
                        g_action_waste = (g_action_waste >= 2) ? g_action_waste - 2 : 0;
                    else if (_hb_env_d == ENV_HOSTILE || fsm.clamp_hold)
                        { /* no decay -- still in trouble */ }
                    else
                        g_action_waste--;
                }
            }
        }

        for (int i = 0; i < nev; i++) {
            int fd = events[i].data.fd;

            if (fd == tfd_active) {
                timerfd_drain(fd);
                g_governor_timer_wakeups++;
                g_wake_by_src[ASB_WAKE_ACTIVE]++;
                need_metrics = 1;

                /* Slow the screen-on cadence while the screen is quiet.
                 *
                 * Two seconds is the right answer for a game or a burst: the ladder can
                 * move that fast and being late shows up as a stutter. It is the wrong
                 * answer for reading, a feed at rest, or music with the display on - the
                 * FSM's decision does not change for tens of seconds there, and 30 samples
                 * a minute buys nothing.
                 *
                 * Measurement says this is where the module's own cost lives: with the
                 * screen on 66% of the time, the overhead line works out at 17 wakeups per
                 * minute, and the 2 s tier is nearly all of it.
                 *
                 * Backing off only from the calm states, and returning to 2 s the moment
                 * anything rises above them. A UI burst re-arms this from the state change
                 * path below, so the first busy tick is already back at full cadence -
                 * the slow tier can delay noticing by a few seconds at most, and only when
                 * nothing has been happening.
                 */
                /* MODERATE with an idle CPU is calm too - and it is where the time goes.
                 *
                 * Gating on LIGHT_IDLE or below sounded conservative, but a field capture
                 * shows what it covers: of 359 screen-on samples, LIGHT_IDLE accounts for
                 * 12. MODERATE alone is 173. The slow cadence was reaching 3% of the time
                 * it was written for, so the saving it promised was almost entirely
                 * theoretical.
                 *
                 * MODERATE spans everything from a resting feed to real scrolling, so the
                 * state alone is not enough - but the run queue tells them apart. Below the
                 * learned quiet floor the CPU is doing compositing and nothing else, which
                 * is exactly the case a 6-second tick was meant for.
                 *
                 * Anything above that, and GAMING, HEAVY, SUSTAINED and the camera, keep
                 * the 2-second tick: those are the states where a late decision is felt. */
                /* Sampled touch watch back in epoll for the next touch (fix117). */
                if (g_touch_rearm && metrics.misc.screen_on) {
                    /* Touches that came while it was out still count as "touching now". */
                    if (touch_watch_set(epfd, 1)) g_touch_last_ts = time(NULL);
                    g_touch_rearm = 0;
                }
                /* Not calm while the unlock lift runs (fix150): the tick that ends it must come
                 * on the 2 s cadence, not 6 s later. */
                int calm = !metrics.misc.camera_active && !g_unlock_lift_now &&
                           !(g_touch_last_ts > 0 && time(NULL) - g_touch_last_ts <= ASB_TOUCH_RECENT_S) &&
                           (fsm.state <= ASB_STATE_LIGHT_IDLE ||
                            (fsm.state == ASB_STATE_MODERATE &&
                             g_ui_quiet_floor > 0.0f &&
                             metrics.cpu.load1 < g_ui_quiet_floor * 1.35f));
                int want_active = calm ? TIMER_ACTIVE_CALM_S : TIMER_ACTIVE_S;
                /* Not while the screen is off.
                 *
                 * The active timer can deliver one expiry that was already queued when a
                 * screen-off uevent arrived. This branch then re-armed the periodic
                 * screen-on cadence, and the end-of-tick check disarmed it again a moment
                 * later - harmless, but it wrote "screen-on interval -> 6s" into the log
                 * one second after "screen OFF", and an audit reasonably read that as the
                 * phone polling at screen-on cadence all night. Skipping the re-arm when
                 * the screen is already off removes the arm/disarm pair and the misleading
                 * line together. */
                if (want_active != g_active_interval && metrics.misc.screen_on) {
                    arm_timerfd_periodic(tfd_active, want_active);
                    g_active_interval = want_active;
                    /* Back to calm after a touch-driven 2 s spell (fix117) is routine - one
                     * per touch session; at the normal level it filled the 50-line log tail
                     * the captures keep (fix119). */
                    if (g_asb_cfg.log_level >= (g_active_by_touch && calm ? 3 : 1))
                        asb_log("adaptive_tick: screen-on interval -> %ds (%s)",
                                want_active, calm ? "calm" : "busy");
                    g_active_by_touch = 0;
                }
            }
            else if (fd == tfd_idle) {
                timerfd_drain(fd);
                g_governor_timer_wakeups++;
                g_wake_by_src[ASB_WAKE_IDLE]++;
                need_metrics = 1;
            }
            else if (fd == tfd_hourly) {
                timerfd_drain(fd);
                g_governor_timer_wakeups++;
                g_wake_by_src[ASB_WAKE_HOURLY]++;
                float avg_drain = -1.0f, avg_screen = 0;
                /* An hour on the charger has screen ticks but no drain sample (fix148): the
                 * screen share is still learned, the drain is left as it was. */
                if (accum.total_ticks > 0) {
                    if (accum.drain_count > 0) avg_drain = accum.drain_sum / accum.drain_count;
                    avg_screen = (float)accum.screen_on_ticks / accum.total_ticks;
                    learner_update(&learn, avg_drain, avg_screen);
                    cur_pred = learner_predict(&learn);
                    learner_adjust_windows(&learn,
                                          &fsm.up_window, &fsm.down_window);
                    if (g_asb_cfg.log_level >= 1) {
                        if (avg_drain >= 0)
                            asb_log("learner updated: drain=%.1fmA screen=%.0f%% "
                                    "predict=%d windows=%d/%d",
                                    avg_drain, avg_screen * 100,
                                    cur_pred, fsm.up_window, fsm.down_window);
                        else
                            asb_log("learner updated: drain=n/a (on the charger) screen=%.0f%% "
                                    "predict=%d windows=%d/%d",
                                    avg_screen * 100,
                                    cur_pred, fsm.up_window, fsm.down_window);
                    }
                    accum.drain_sum       = 0;
                    accum.drain_count     = 0;
                    accum.screen_on_ticks = 0;
                    accum.total_ticks     = 0;
                }
            }
            else if (g_touch_fd >= 0 && fd == g_touch_fd) {
                /* A touch with the screen on (fix117). Sampled: out of epoll until the
                 * next active tick puts it back. */
                int _touched = touch_drain(fd);
                (void)touch_watch_set(epfd, 0);
                g_touch_rearm = 1;
                if (_touched && metrics.misc.screen_on) {
                    time_t _tn = time(NULL);
                    int _fresh = (g_touch_last_ts == 0 || _tn - g_touch_last_ts > ASB_TOUCH_RECENT_S);
                    g_touch_last_ts = _tn;
                    if (_fresh) {
                        g_touch_starts++;
                        g_touch_kick = 1;
                        need_metrics = 1;
                        if (g_active_interval != TIMER_ACTIVE_S) {
                            arm_timerfd_periodic(tfd_active, TIMER_ACTIVE_S);
                            g_active_interval = TIMER_ACTIVE_S;
                            g_active_by_touch = 1;
                            if (g_asb_cfg.log_level >= 3)
                                asb_log("adaptive_tick: screen-on interval -> %ds (touch)", TIMER_ACTIVE_S);
                        }
                    }
                }
            }
            else if (g_disp_prop_evfd >= 0 && fd == g_disp_prop_evfd) {
                /* Android entered or left display ON (fix116). Entering: on now - the
                 * metrics pass trusts a fresh ON for 3 s - and the usual re-check chain as
                 * the backstop. Leaving: look now instead of at the next active tick. */
                uint64_t _dv;
                ssize_t _dr = read(fd, &_dv, sizeof(_dv));
                (void)_dr;
                g_disp_prop_events++;
                if (asb_display_state_read() == 2) {
                    g_disp_prop_on_ts = time(NULL);
                    if (!metrics.misc.screen_on) {
                        g_disp_evt_ts = time(NULL); g_disp_retry = 0;
                        need_metrics = 1;
                    }
                } else {
                    g_disp_prop_on_ts = 0;
                    g_disp_prop_off_ts = time(NULL);
                    if (metrics.misc.screen_on) need_metrics = 1;
                }
            }
            else if (wake_key_is_fd(fd)) {
                /* A wake key while the screen reads off: look now, then the usual short
                 * re-check chain. sysfs decides; the key only says "look". */
                int _wkp = wake_key_drain(fd);
                if (_wkp && !metrics.misc.screen_on &&
                    timerfd_state(tfd_active) != 1) {
                    g_wake_key_hints++;
                    g_disp_evt_ts = time(NULL); g_disp_retry = 0;
                    arm_timerfd_once_ms(tfd_active, 250);
                } else if (_wkp && metrics.misc.screen_on) {
                    /* fix220: the power key with the screen on is the lock press - the
                     * screen-off animation renders before Android publishes the display
                     * state, at whatever ceilings the moment had. Ask the lift to cover
                     * it; the fresh pass decides (a stale "on" after the panel went off
                     * arms nothing - the update refuses with the screen off). */
                    g_lock_key_kick = 1;
                    need_metrics = 1;
                }
            }
            else if (fd == uefd) {
                int final_scr = -1;
                int drained = 0;
                char ubuf[4096];
                int un;
                /* Drain until empty, cap 64 - same contract as before, but every event
                 * is now bucketed by subsystem instead of vanishing between the two
                 * recv calls the old loop made per iteration. */
                while (drained < 64 && (un = recv_uevent(uefd, ubuf, sizeof(ubuf))) > 0) {
                    int cur = parse_uevent_screen_buf(ubuf, un);
                    g_uev_events_total++;
                    g_uev_by_src[cur != -1 ? ASB_UEV_DISPLAY : uevent_bucket(ubuf, un)]++;
                    /* An explicit value wins over "changed"; "changed" still counts. */
                    if (cur >= 0) final_scr = cur;
                    else if (cur == -2 && final_scr == -1) final_scr = -2;
                    drained++;
                }
                if (final_scr != -1) {
                    int was_on = metrics.misc.screen_on;
                    int real_scr = metrics_screen_on();
                    /* The display uevent for screen ON arrives as the panel starts to power
                     * up, often before panel_power_status says so. This used to trust that
                     * first read outright, so an ON was almost never confirmed: a capture's
                     * governor log has "screen OFF (uevent)" entries and not one "screen ON".
                     * The wake was then only noticed on the next timer tick - and with the
                     * screen off only the slow deep-idle timer is armed - so unlock and its
                     * animations ran on sleep rails: one wake stayed in DEEP_IDLE for 10 s
                     * with the screen on.
                     *
                     * Re-read briefly (up to ~0.5 s) when the event says ON and the node does
                     * not yet. If the panel still does not report on - an always-on-display
                     * pulse, a pocket wake - the event is not trusted, but a one-second
                     * re-check is armed instead of waiting for the deep-idle tick. */
                    /* Screen read off, and the event is not an explicit "off": the panel may
                     * be powering up ahead of panel_power_status. Re-check in 0.4 s from a
                     * one-shot timer (the tick path then retries a few times over ~2 s)
                     * instead of waiting for the slow deep-idle tick - and without blocking:
                     * an always-on display sends display events while asleep too, and a
                     * half-second busy wait on each would cost charge. */
                    /* At most one follow-up chain per 30 s: an always-on display refreshing
                     * its clock would otherwise buy up to ~2 s awake every minute. */
                    if (!was_on && real_scr != 1 && final_scr != 0 && timerfd_state(tfd_active) != 1) {
                        if (time(NULL) - g_disp_evt_ts > 30) {
                            g_disp_evt_ts = time(NULL); g_disp_retry = 0;
                            arm_timerfd_once_ms(tfd_active, 400);
                        } else if (timerfd_state(tfd_active) == 0 &&
                                   time(NULL) - g_disp_single_ts >= 10) {
                            /* Inside the 30 s budget, the old code did nothing at all - and
                             * the budget is what an earlier display event (an always-on
                             * display pulse, the screen going off) had just spent. A real
                             * wake landing there was then found only by the 45 s idle tick,
                             * on sleep rails the whole time: the field signature is every
                             * "seen on a tick" line sitting exactly 45 s after the last one.
                             * One single look, 1 s later, is one timer wakeup - not the
                             * ~2 s chain the budget exists to ration. The retry counter is
                             * left spent so this never grows into a chain. */
                            g_disp_retry = 3;
                            g_disp_single_ts = time(NULL);
                            g_scr_recheck_single++;
                            arm_timerfd_once_ms(tfd_active, 1000);
                        }
                    }
                    /* sysfs decides; the event only said "look now". */
                    int confirmed = real_scr;
                    metrics.misc.screen_on = confirmed;

                    if (confirmed != was_on) {
                        if (g_asb_cfg.log_level >= 1) asb_log("screen %s (uevent, drained=%d events)",
                                confirmed ? "ON" : "OFF", drained);
                        if (confirmed) g_scr_on_by_uevent++;
                        else { g_scr_off_since = time(NULL); g_scr_off_by_uevent++; }
                        need_metrics = 1;
                        if (confirmed) {
                            /* Screen just came on: full cadence immediately, and reset
                             * the tracker so the next tick re-evaluates rather than
                             * assuming it is still where it left off. */
                            arm_timerfd_periodic(tfd_active, TIMER_ACTIVE_S);
                            g_active_interval = TIMER_ACTIVE_S;
                            uev_park(epfd, uefd);
                            /* Clear storm shield on screen wake */
                            if (g_storm_shield_active) {
                                storm_shield_reset();
                                asb_log("storm_shield: cleared (screen ON)");
                            }
                            /* check user switch on screen ON */
                            int cur_uid = get_current_user_id();
                            if (cur_uid >= 0 && g_last_user_id >= 0 && cur_uid != g_last_user_id) {
                                asb_log("user_quarantine: user switch %d -> %d, active for %ds",
                                        g_last_user_id, cur_uid, USER_QUARANTINE_SEC);
                                g_last_user_id = cur_uid;
                                g_user_quarantine_active = 1;
                                g_user_quarantine_until = time(NULL) + USER_QUARANTINE_SEC;
                            } else if (cur_uid >= 0) {
                                g_last_user_id = cur_uid;
                            }
                        } else {
                            disarm_timerfd(tfd_active);
                            persistent_stats_screen_off(&fsm);
                            if (fsm_profile_is_battery)
                                fsm.bat_screen_off_count++;
                        }
                        session_plan_build(&fsm, confirmed);
                        session_plan_apply_prearm(&fsm);
                        write_state(&fsm, &metrics, cur_pred);
                    }
                }
            }
            else if (fd == sockfd) {
                char cmd[256] = {0};
                struct sockaddr_un src = {0};
                socklen_t srclen = sizeof(src);
                int n = asb_sock_recv(sockfd, cmd, sizeof(cmd), &src, &srclen);
                if (n <= 0) continue;

                /* "status" is a read-only query, and the logkit sampler and the WebUI
                 * ask it every ~45 s - two or three times per poll. Logging each one
                 * filled the governor log with "cmd: status": a capture's 50-line tail
                 * was nothing else, so the transitions and audits worth reading had
                 * scrolled out before anyone looked. Commands that change something are
                 * still logged; status only at the most verbose level. */
                if ((strcmp(cmd, "status") == 0 || strcmp(cmd, "zygisk-refresh") == 0 ||
                     strcmp(cmd, "zygisk-launch") == 0)
                        ? g_asb_cfg.log_level >= 3 : g_asb_cfg.log_level >= 1)
                    asb_log("cmd: %s", cmd);

                if (strncmp(cmd, "profile:", 8) == 0) {
                    const char *pname = cmd + 8;
                    char _pbuf[16];
                    int _is_auto = 0;
                    {
                        size_t _plen = strlen(pname);
                        if (_plen >= 5 && strcmp(pname + _plen - 5, ":auto") == 0) {
                            _is_auto = 1;
                            if (_plen - 5 < sizeof(_pbuf)) {
                                memcpy(_pbuf, pname, _plen - 5);
                                _pbuf[_plen - 5] = '\0';
                                pname = _pbuf;
                            }
                        }
                    }
                    int new_idx = PROFILE_BALANCED;
                    if (strcmp(pname, "battery")     == 0) new_idx = PROFILE_BATTERY;
                    if (strcmp(pname, "performance") == 0) new_idx = PROFILE_PERFORMANCE;
                    if (strcmp(pname, "smart")       == 0) new_idx = PROFILE_SMART;
                    if (!_is_auto) {
                        FILE *_amf = fopen("/data/adb/asb/auto_switch_marker", "r");
                        if (_amf) {
                            char _am[32];
                            if (fgets(_am, sizeof(_am), _amf)) {
                                size_t _aml = strlen(_am);
                                while (_aml > 0 && (_am[_aml-1] == '\n' || _am[_aml-1] == '\r' || _am[_aml-1] == ' ')) {
                                    _am[--_aml] = '\0';
                                }
                                if (strcmp(_am, pname) == 0) _is_auto = 1;
                            }
                            fclose(_amf);
                            remove("/data/adb/asb/auto_switch_marker");
                        }
                    }
                    if (new_idx != fsm.profile_idx) {
                        fsm_flush_state_time(&fsm);
                        persistent_stats_save(&fsm);
                        session_history_append_ex(&fsm, "profile_change");
                        session_end_self_tune(&fsm);
                        fsm_session_reset(&fsm);
                        fsm.plan.ac_used = 0;  /* budget reset on new session */

                        if (fsm.auto_battery_active && !_is_auto) {
                            asb_log("auto_battery: cleared by user profile change");
                            fsm.auto_battery_active = 0;
                            fsm.auto_battery_restore_idx = -1;
                            
                            strncpy(fsm.auto_battery_reason, "manual_clear", sizeof(fsm.auto_battery_reason) - 1);
                            fsm.auto_battery_reason[sizeof(fsm.auto_battery_reason) - 1] = '\0';
                            fsm.auto_battery_since = time(NULL);
                            fsm_auto_battery_persist(&fsm);
                            remove("/data/adb/asb/auto_battery_origin");
                        }

                        fsm.profile_idx = new_idx;
                        fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                        fsm_profile_is_performance = (new_idx == PROFILE_PERFORMANCE);
                        fsm_profile_is_smart   = (new_idx == PROFILE_SMART);
                        fsm_profile_is_balanced = (new_idx == PROFILE_BALANCED);
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
                        /* fix211: follow the flag apply_profile.sh just wrote. The
                         * in-memory copy was only ever set at init or by a Smart tick,
                         * so after a live Smart -> Battery switch it stayed 1: Smart's
                         * tick kept classifying (harmless, but it is the manual
                         * profiles' own classifier's job now, fix210) and kept its
                         * bookkeeping alive under a manual policy. A user switch writes
                         * the flag before this command arrives; an auto switch keeps it
                         * at 1 by design, and Smart resumes classification. */
                        {
                            int _sf = asb_smart_flag_read();
                            if (_sf >= 0 && _sf != g_smart_rt.enabled) {
                                g_smart_rt.enabled = _sf;
                                asb_log("smart: mode %s after profile switch",
                                        _sf ? "enabled" : "disabled");
                            }
                        }
                        /* The foreground package cache is keyed on time, not on relevance: a profile switch
                           is a certainty that the next decision should be made on fresh data, not on what
                           was true up to 8 seconds ago. */
                        asb_smart_pkg_cache_invalidate();
                        force_write = 1;
                        need_metrics = 1;
                        g_last_reassert = 0;
                        storm_shield_reset();
                        anti_clamp_reset();
                        session_plan_build(&fsm, metrics.misc.screen_on);
                        session_plan_apply_prearm(&fsm);
                        asb_sock_reply(sockfd, &src, srclen, "ok");
                        asb_log_critical("profile changed to %d (session reset)", new_idx);
                    } else {
                        asb_sock_reply(sockfd, &src, srclen, "ok:nochange");
                    }
                }
                else if (strcmp(cmd, "zygisk-refresh") == 0) {
                    /* The observer supplies a lifecycle edge, not a foreground verdict or
                     * a target cap. Screen-off events cost no metrics probe. Every normal
                     * profile, dwell, thermal and vendor decision still applies below. */
                    if (!g_asb_cfg.zygisk_enabled || !g_asb_cfg.zygisk_hints ||
                        access("/data/adb/asb/zygisk_observer/disable", F_OK) == 0) {
                        g_zygisk_refresh_vetoed++;
                        asb_sock_reply(sockfd, &src, srclen, "err:disabled");
                    } else if (!metrics.misc.screen_on) {
                        g_zygisk_refresh_vetoed++;
                        asb_sock_reply(sockfd, &src, srclen, "err:screen_off");
                    } else {
                        asb_smart_pkg_cache_invalidate();
                        need_metrics = 1;
                        g_zygisk_refresh_accepted++;
                        asb_sock_reply(sockfd, &src, srclen, "ok");
                    }
                }
                else if (strcmp(cmd, "zygisk-launch") == 0) {
                    /* fix272: zygote is creating a new top-app process (a cold start). The
                     * observer names no app and no value; this only feeds the unlock lift's
                     * existing launch window and asks for fresh foreground evidence. The
                     * profile, thermal, warm-die and lift-length gates decide the rest. */
                    if (!g_asb_cfg.zygisk_enabled || !g_asb_cfg.zygisk_launch ||
                        access("/data/adb/asb/zygisk_observer/disable", F_OK) == 0) {
                        g_zygisk_launch_vetoed++;
                        asb_sock_reply(sockfd, &src, srclen, "err:disabled");
                    } else if (!metrics.misc.screen_on) {
                        g_zygisk_launch_vetoed++;
                        asb_sock_reply(sockfd, &src, srclen, "err:screen_off");
                    } else {
                        g_unlock_cold_kick = 1;
                        asb_smart_pkg_cache_invalidate();
                        need_metrics = 1;
                        g_zygisk_launch_accepted++;
                        asb_sock_reply(sockfd, &src, srclen, "ok");
                    }
                }
                else if (strcmp(cmd, "status") == 0) {
                    char jbuf[STATUS_JSON_MAX];
                    build_status_json(&fsm, &metrics, cur_pred, jbuf, sizeof(jbuf));
                    asb_sock_reply(sockfd, &src, srclen, jbuf);
                }
                else if (strcmp(cmd, "reset-stats") == 0) {
                    session_reset_and_replan(&fsm, metrics.misc.screen_on);
                    asb_log("session telemetry reset by cmd");
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strcmp(cmd, "reload") == 0) {
                    int new_idx = read_profile_idx();
                    asb_runtime_config_t candidate_cfg;
                    asb_config_defaults(&candidate_cfg);
                    int reload_cfg_rc = asb_config_load_file(CONFIG_FILE, &candidate_cfg);
                    g_cfg_load_rc = reload_cfg_rc;
                    g_cfg_load_ts = time(NULL);
                    if (reload_cfg_rc != 0) {
                        asb_log("config_reject: reload refused rc=%d; keeping last-known-good policy", reload_cfg_rc);
                        asb_sock_reply(sockfd, &src, srclen, "err:invalid_config");
                        continue;
                    }
                    asb_config_apply_highload_mode(&candidate_cfg);
                    g_asb_cfg = candidate_cfg;
                    /* if profile is changing, preserve old session in history
                     * BEFORE resetting. Previously reload silently discarded
                     * running sessions, leaving history with stale attribution. */
                    if (new_idx != fsm.profile_idx) {
                        fsm_flush_state_time(&fsm);
                        persistent_stats_save(&fsm);
                        session_history_append_ex(&fsm, "profile_change");
                        session_end_self_tune(&fsm);
                    }
                    fsm_session_reset(&fsm);
                    fsm.plan.ac_used = 0;
                    storm_shield_reset();
                    anti_clamp_reset();
                    if (new_idx != fsm.profile_idx) {
                        fsm.profile_idx = new_idx;
                        fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                        fsm_profile_is_performance = (new_idx == PROFILE_PERFORMANCE);
                        fsm_profile_is_smart   = (new_idx == PROFILE_SMART);
                        fsm_profile_is_balanced = (new_idx == PROFILE_BALANCED);
                        force_write = 1;
                        need_metrics = 1;
                    }
                    session_plan_build(&fsm, metrics.misc.screen_on);
                    session_plan_apply_prearm(&fsm);
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strncmp(cmd, "start-session:", 14) == 0) {
                    char *rest = cmd + 14;
                    char *colon = strchr(rest, ':');
                    int new_idx = PROFILE_BALANCED;
                    if (strncmp(rest, "battery", 7) == 0)     new_idx = PROFILE_BATTERY;
                    if (strncmp(rest, "performance", 11) == 0) new_idx = PROFILE_PERFORMANCE;
                    if (strncmp(rest, "smart", 5) == 0)       new_idx = PROFILE_SMART;
                    fsm_flush_state_time(&fsm);
                    persistent_stats_save(&fsm);
                    session_history_append_ex(&fsm, "new_session");
                    session_end_self_tune(&fsm);
                    fsm.profile_idx = new_idx;
                    fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                    fsm_profile_is_performance = (new_idx == PROFILE_PERFORMANCE);
                    fsm_profile_is_smart   = (new_idx == PROFILE_SMART);
                    fsm_profile_is_balanced = (new_idx == PROFILE_BALANCED);
                    if (colon && *(colon+1)) {
                        char *mode = colon + 1;
                        if (strcmp(mode, "burst") == 0)  g_asb_cfg.highload_mode = 1;
                        else if (strcmp(mode, "stable") == 0) g_asb_cfg.highload_mode = 2;
                        else if (strcmp(mode, "auto") == 0)   g_asb_cfg.highload_mode = 3;
                        else g_asb_cfg.highload_mode = 0;
                        asb_config_apply_highload_mode(&g_asb_cfg);
                    }
                    session_reset_and_replan(&fsm, metrics.misc.screen_on);
                    force_write = 1;
                    need_metrics = 1;
                    g_last_reassert = 0;
                    asb_log("session_start profile=%s highload=%s (start-session cmd)",
                            asb_profile_name(new_idx),
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
                    session_reset_and_replan(&fsm, metrics.misc.screen_on);
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
            /* sensor scheduler reads from session plan.
             * sensor_budget limits expensive full-mode reads per plan epoch. */
            static int g_sensor_skip = 0;
            int need_hr = fsm.plan.allow_hr;
            int need_thermal = 1;

            /* Read the thermal zones less often when nothing is close to a threshold.
             *
             * Every pass opens eight or more zone files. That is the right price when the
             * die is near the throttle point and a decision might change this tick; at
             * 35 C with a 60 C threshold it buys nothing - the answer cannot change fast
             * enough to matter between one tick and the next.
             *
             * plan.thermal_div already existed for exactly this and was only ever
             * published, never applied. Using it now means the cadence follows the plan the
             * FSM already built rather than a second rule that can drift from it.
             *
             * The skip is bounded by distance, not by state alone: within 12 C of the
             * threshold every tick reads, whatever the plan says. Heat rises faster than
             * a state machine notices, and being late there costs a hot phone.
             */
            if (fsm.plan.thermal_div > 1 && g_last_cpu_max_c > 0) {
                int trip = asb_config_profile_sustained_temp_enter(&g_asb_cfg, 1);
                if (trip > 0 && g_last_cpu_max_c <= trip - 12) {
                    static int g_therm_skip = 0;
                    g_therm_skip++;
                    if (g_therm_skip % fsm.plan.thermal_div != 0)
                        need_thermal = 0;
                }
            }

            /* Quiet Night Baseline -- after sustained quiet DEEP_IDLE,
             * enter ultra-quiet mode: even less reads, longer ticks. */
            /* Which night window applies right now (0 = none): 3 = the learned per-user
             * window, 2 = the static hours. Computed before the eligibility test because
             * it is now part of it. */
            int _qn_window = 0;
            if (g_asb_cfg.night_quiet_enable && fsm.state == ASB_STATE_DEEP_IDLE &&
                !metrics.misc.screen_on) {
                time_t _t = time(NULL);
                if (asb_night_window_ready()) {
                    /* V50: learned per-user window replaces static hours */
                    if (asb_night_window_active(_t)) _qn_window = 3;
                } else {
                    struct tm _tm;
                    if (localtime_r(&_t, &_tm)) {
                        int _h = _tm.tm_hour;
                        int _hs = g_asb_cfg.night_quiet_hour_start;
                        int _he = g_asb_cfg.night_quiet_hour_end;
                        int _in_window = (_hs > _he)
                                         ? (_h >= _hs || _h < _he)   /* crosses midnight */
                                         : (_h >= _hs && _h < _he);  /* same-day window */
                        if (_in_window) _qn_window = 2;
                    }
                }
            }
            /* Eligibility. This used to require a battery-like profile only - and Smart
             * counts as battery-like only while its learned battery weight is >= 0.8. A full
             * OP15 night (23:23-06:36, Smart, weight 0.45-0.79) never entered Quiet Night at
             * all, while two daytime screen-offs did: the mode named for the night ran by
             * day and not at night. What it saves is the governor's OWN footprint (longer
             * ticks, fewer reads) on a sleeping phone, which has nothing to do with how
             * performance-leaning the profile is - so inside the night window, with the
             * switch on, any profile qualifies. Outside it the old rule stands unchanged. */
            if (fsm.state == ASB_STATE_DEEP_IDLE &&
                (asb_profile_battery_like(fsm.profile_idx) || _qn_window) &&
                !metrics.misc.screen_on) {
                g_quiet_night_ticks++;
                g_quiet_noise_ticks = 0;  /* reset hysteresis -- we're quiet again */
                /*
                 * night-window acceleration.
                 */
                int _use_fast = g_last_bat_clean_night;
                if (!_use_fast) _use_fast = _qn_window;
                int threshold = _use_fast
                                ? g_asb_cfg.quiet_fast_ticks   /* 5min with reward or night-window */
                                : g_asb_cfg.quiet_entry_ticks; /* 10min normal */
                if (!g_quiet_night_active && g_quiet_night_ticks >= threshold) {
                    g_quiet_night_active = 1;
                    g_quiet_night_since = time(NULL);
                    asb_log("quiet_night: entered ultra-quiet mode (ticks=%d%s)",
                            g_quiet_night_ticks,
                            (_use_fast == 1) ? " reward=fast" :
                            (_use_fast == 2) ? " night_window=fast" :
                            (_use_fast == 3) ? " learned_window=fast" : "");
                }
            } else {
                /*
                 * Quiet Lock Hysteresis -- don't exit quiet on single noise burst.
                 */
                if (g_quiet_night_active) {
                    g_quiet_noise_ticks++;
                    if (g_quiet_noise_ticks >= g_asb_cfg.quiet_exit_grace || metrics.misc.screen_on) {
                        long qn_dur = g_quiet_night_since > 0
                                      ? (time(NULL) - g_quiet_night_since) : 0;
                        asb_log("quiet_night: exited after %ldmin (noise=%d screen=%d)",
                                qn_dur / 60, g_quiet_noise_ticks, metrics.misc.screen_on);
                        g_quiet_wake_ramp = 3;
                        g_quiet_night_active = 0;
                        g_quiet_night_ticks = 0;
                        g_quiet_noise_ticks = 0;
                    }
                } else {
                    g_quiet_night_active = 0;
                    g_quiet_night_ticks = 0;
                    g_quiet_noise_ticks = 0;
                }
            }

            /* deep idle economy -- in battery DEEP_IDLE with screen off,
             * GPU/headroom/thermal reads are waste. Only battery level matters. */
            int deep_idle_economy = (fsm.state == ASB_STATE_DEEP_IDLE &&
                                     asb_profile_battery_like(fsm.profile_idx) &&
                                     !metrics.misc.screen_on);
            if (deep_idle_economy) {
                need_hr = 0;
                need_thermal = 0;
            }

            /* Quiet Night ultra-economy -- skip even battery current reads
             * on alternating ticks. Device is sleeping, minimal governor footprint. */
            /* Clear first, unconditionally.
             *
             * The reset used to live in the else branch of the test below, so it only ran
             * while Quiet Night was still active. If the mode ended on a skipping tick the
             * flag stayed set for the rest of the session: metrics_read_battery() returned
             * immediately on every subsequent tick and the daemon ran on the current,
             * voltage, temperature and level it had read that morning.
             *
             * Everything downstream trusts those numbers - auto-battery switching, charge
             * awareness, the drain the learner banks, the time-to-empty estimates - so a
             * stuck flag is worse than the economy it was buying. Default is "read", and
             * only an active skipping tick turns it off.
             */
            g_qn_skip_this_tick = 0;
            if (g_quiet_night_active) {
                static int g_qn_skip = 0;
                g_qn_skip++;
                if (g_qn_skip % 2 != 0) {
                    /* Actually skip the tick.
                     *
                     * This set need_metrics = 0 - after the only place that reads it, so
                     * nothing was skipped and the comment described an economy that never
                     * happened. Clang flagged the write as dead; the interesting part is
                     * that the feature was dead with it.
                     *
                     * Counted so the saving is observable rather than asserted: a
                     * footprint claim nobody can check is how this went unnoticed.
                     */
                    /* Skip the expensive reads for this tick.
                     *
                     * Not a goto: the metrics block runs to ~1400 lines and jumping out of
                     * it would hop over cleanup and state updates that later ticks depend
                     * on. The flag is checked at the individual read sites instead, which
                     * keeps the control flow intact and makes the saving auditable per
                     * source rather than all-or-nothing.
                     */
                    g_qn_ticks_skipped++;
                    g_qn_skip_this_tick = 1;
                }
            }

            /*
             * Exit-from-Quiet Brain -- after quiet night ends, ramp up sensor reads gradually
             * instead of full blast.
             */
            if (g_quiet_wake_ramp > 0) {
                if (g_quiet_wake_ramp >= 3) { need_hr = 0; need_thermal = 0; }
                else if (g_quiet_wake_ramp == 2) { need_hr = 0; }
                g_quiet_wake_ramp--;
            }

            /*
             * Burst Probation Window -- detect early ceiling collapse.
             */
            if (fsm.profile_idx == PROFILE_PERFORMANCE && fsm.ses_start_ts > 0) {
                long ses_age = time(NULL) - fsm.ses_start_ts;
                if (ses_age <= 60 && !g_burst_early_collapse) {
                    g_burst_probation = 1;
                    if (fsm.clamp_hold) {
                        int obs_p1_now = tick_scaling_max(1);
                        if (obs_p1_now > 0 && obs_p1_now < 2000000) {
                            g_burst_early_collapse = 1;
                            g_burst_probation = 0;
                            fsm.plan.ac_budget = fsm.plan.ac_budget / 2;
                            if (fsm.plan.ac_budget < 1) fsm.plan.ac_budget = 1;
                            asb_log("burst_probation: early collapse detected "
                                    "(p6_max=%dkHz < 2GHz at %lds), ac_budget halved to %d",
                                    obs_p1_now / 1000, ses_age, fsm.plan.ac_budget);
                        }
                    }
                } else if (ses_age > 60 && g_burst_probation) {
                    g_burst_probation = 0;  /* window expired, no collapse */
                }
            }

            /* ceiling-adaptive economy -- when vendor clamp confirmed >45s,
             * headroom reads are pointless (always clamped) and thermal reads
             * can be reduced (device is stable, not in thermal danger).
             * early_collapse bypasses the timer entirely. */
            int clamp_economy = (fsm.clamp_hold && g_clamp_hold_since > 0 &&
                                 ((time(NULL) - g_clamp_hold_since) > g_asb_cfg.clamp_economy_after_s ||
                                  g_burst_early_collapse) &&
                                 fsm.profile_idx == PROFILE_PERFORMANCE);
            if (clamp_economy) {
                need_hr = 0;
                /* thermal every 3rd tick instead of every tick */
                static int g_clamp_thermal_skip = 0;
                g_clamp_thermal_skip++;
                if (g_clamp_thermal_skip % g_asb_cfg.clamp_thermal_every_n != 0) need_thermal = 0;
                /* Ceiling-Adaptive Reshaping -- track actual ceiling with EMA.
                 * This becomes the reference for gap/eff instead of target. */
                int obs_p0 = tick_scaling_max(0);
                int obs_p1 = tick_scaling_max(1);
                if (obs_p0 > 0) {
                    if (g_virtual_ceiling_p0 == 0) g_virtual_ceiling_p0 = obs_p0;
                    else g_virtual_ceiling_p0 = (g_virtual_ceiling_p0 * g_asb_cfg.virtual_ceiling_alpha + obs_p0) / (g_asb_cfg.virtual_ceiling_alpha + 1);
                }
                if (obs_p1 > 0) {
                    if (g_virtual_ceiling_p1 == 0) g_virtual_ceiling_p1 = obs_p1;
                    else g_virtual_ceiling_p1 = (g_virtual_ceiling_p1 * g_asb_cfg.virtual_ceiling_alpha + obs_p1) / (g_asb_cfg.virtual_ceiling_alpha + 1);
                }
            } else {
                g_virtual_ceiling_p0 = 0;
                g_virtual_ceiling_p1 = 0;
            }

            if (fsm.plan.thermal_div > 1) {
                g_sensor_skip++;
                if (g_sensor_skip % fsm.plan.thermal_div != 0) need_thermal = 0;
            } else {
                g_sensor_skip = 0;
            }
            /* sensor budget -- downgrade to reduced when budget exhausted */
            if (need_hr && fsm.plan.sensor_budget > 0) {
                if (fsm.plan.sensor_used >= fsm.plan.sensor_budget) {
                    need_hr = 0;  /* budget exhausted, skip headroom reads */
                } else {
                    fsm.plan.sensor_used++;
                }
            }
            /* Every skip rule above has had its say; the keepalive overrides them all, so a
             * cooldown can always see the die cool down (fix166, see asb_therm_keepalive_due). */
            if (!need_thermal &&
                asb_therm_keepalive_due(time(NULL), g_last_thermal_read_ts, fsm.thermal_cooldown)) {
                need_thermal = 1;
                g_therm_keepalive_reads++;
            }
            /* Drop last tick's cached ceilings before reading anything new.
             *
             * Placed here rather than at the end of the previous iteration because the loop has
             * several exit paths: invalidating on the way in is the one position that cannot be
             * skipped, and a cache that survives a tick is exactly the bug this must not become. */
            tick_scaling_max_invalidate();
            /* Camera opening or closing changes which package is in front, immediately.
             *
             * The TTL is a default staleness budget; this is a known event that invalidates it.
             * Without this the first tick after the camera launches still classifies the previous
             * app, and the camera guard is exactly the consumer that must not be late.
             *
             * Edge-triggered, so a long camera session costs one invalidation, not one per tick. */
            {
                static int _cam_was = -1;
                if (_cam_was != metrics.misc.camera_active) {
                    if (_cam_was >= 0) asb_smart_pkg_cache_invalidate();
                    _cam_was = metrics.misc.camera_active;
                }
            }
            metrics_read_all(&metrics, need_hr, need_thermal);
            /* A screen-on tick never decides on an old temperature (fix141).
             *
             * Deep-idle economy and the quiet-night wake ramp both skip the zones, and both
             * look at the screen state of the PREVIOUS tick - so the tick that sees the screen
             * come on still skipped. Capture 2830: the last read was at 01:03 (43 C), the
             * capture's own zone reads through the night were 26-35 C, and the 08:02:41
             * screen-on still decided MODERATE with "t=43degC"; the state file published
             * 43/34/37 C all night. One read of the zones when the screen is on and the
             * reading is over a minute old. */
            if (!need_thermal && metrics.misc.screen_on && g_last_thermal_read_ts > 0 &&
                time(NULL) - g_last_thermal_read_ts > 60) {
                metrics_read_thermal(&metrics.therm, need_hr);
                need_thermal = 1;
            }
            /* A skipped tick keeps the last reading, and it used to keep its age too: the
             * state JSON said temp_age_s=0 two hours after the read. The value stays (the
             * decisions above are built for that), the age is the true one (fix166). */
            if (!need_thermal && g_last_thermal_read_ts > 0)
                metrics.therm.temp_age_s = (int)(time(NULL) - g_last_thermal_read_ts);
            /* Remember the last real reading: on a skipped tick the struct still holds it,
             * and the distance check above needs a value it can trust. */
            if (need_thermal && metrics.therm.cpu_max_c > 0)
                g_last_cpu_max_c = metrics.therm.cpu_max_c;
            if (need_thermal && metrics.therm.cpu_max_c > 0 && metrics.therm.temp_valid &&
                !metrics.misc.screen_on) {
                g_unlock_dark_c = metrics.therm.cpu_max_c;
                g_unlock_dark_ts = time(NULL);
            }

            /* Screen-on cadence must not depend on catching the display uevent.
             *
             * The active timer (2 s, or 6 s when calm) used to be armed only in the uevent
             * branch for screen ON, and re-armed only from inside its own handler - so once a
             * wake was missed, nothing armed it again. The tick that finally saw the screen
             * on came from the slow idle timer, and the whole screen session then ran on that
             * 10 s cadence: a capture shows 2097 timer wakeups in five hours where 157 minutes
             * of screen time alone should have produced well over 1500 active ticks. Load
             * bursts were noticed three to five times late.
             *
             * Whichever path read the screen, make the timers agree with it: screen on with no
             * periodic active timer -> arm it; screen off with one still running -> disarm it
             * (a pending one-shot re-check is left alone). */
            {
                int _ts = timerfd_state(tfd_active);
                if (metrics.misc.screen_on && _ts != 1) {
                    arm_timerfd_periodic(tfd_active, TIMER_ACTIVE_S);
                    g_active_interval = TIMER_ACTIVE_S;
                    /* A re-check a display event armed (fired within ~3 s of it) is the
                     * fast path working; anything later is the slow path the counters exist
                     * to expose. "late" is an upper bound: the wake happened somewhere
                     * between the last screen-off and this tick. */
                    if (g_disp_prop_on_ts && time(NULL) - g_disp_prop_on_ts <= 3) {
                        g_scr_on_by_display++;
                        if (g_asb_cfg.log_level >= 1) asb_log("screen ON (Android display state)");
                    } else if ((g_disp_evt_ts && time(NULL) - g_disp_evt_ts <= 3) ||
                        (g_disp_single_ts && time(NULL) - g_disp_single_ts <= 3)) {
                        g_scr_on_by_recheck++;
                        if (g_asb_cfg.log_level >= 1) asb_log("screen ON confirmed by the display re-check");
                    } else {
                        g_scr_on_by_tick++;
                        long _late = g_scr_off_since ? (long)(time(NULL) - g_scr_off_since) : 0;
                        if (_late > g_scr_tick_late_max_s && _late < 86400) g_scr_tick_late_max_s = _late;
                        if (g_asb_cfg.log_level >= 1) asb_log("screen ON seen on a tick - active cadence restored");
                    }
                    uev_park(epfd, uefd);
                    /* Publish the transition now (see the screen-off branch below). */
                    write_state(&fsm, &metrics, cur_pred);
                } else if (!metrics.misc.screen_on && _ts == 1) {
                    disarm_timerfd(tfd_active);
                    g_scr_off_since = time(NULL);
                    /* The tick found the screen off before any uevent did - always the
                     * case while the socket is parked, and before that whenever the event
                     * was missed. Run what the uevent path runs on screen-off, which this
                     * branch used to skip: stats saved, and the screen-off session plan
                     * built and pre-armed, so the sleep rails are not left to chance. */
                    uev_unpark(epfd, uefd);
                    /* Name the path that actually noticed (fix126): the waiter's off edge
                     * lands here too, within the same second. */
                    if (g_disp_prop_off_ts && time(NULL) - g_disp_prop_off_ts <= 3) {
                        g_scr_off_by_display++;
                        if (g_asb_cfg.log_level >= 1) asb_log("screen OFF (Android display state)");
                    } else {
                        g_scr_off_by_tick++;
                        if (g_asb_cfg.log_level >= 1) asb_log("screen OFF (tick)");
                    }
                    g_disp_prop_off_ts = 0;
                    persistent_stats_screen_off(&fsm);
                    if (fsm_profile_is_battery)
                        fsm.bat_screen_off_count++;
                    session_plan_build(&fsm, 0);
                    session_plan_apply_prearm(&fsm);
                    /* The state file is what the shell helpers read for "is the screen off",
                     * and it was only rewritten when caps were applied - which in deep idle,
                     * under the write backoff or the vendor detente, can be many minutes later.
                     * Screen-off LTE then found screen=1 when its 90 s timer fired and quietly
                     * did nothing: an OP15 evening shows applies 7, 7.5 and 37 minutes after
                     * the screen went off instead of 90 s. A transition is always published. */
                    write_state(&fsm, &metrics, cur_pred);
                }
                /* A tick right after a resume, with the screen still reading off: the
                 * resume may BE the wake (power key, fingerprint, lift), with the panel a
                 * few hundred ms behind. Run the same short re-check chain a display event
                 * would. The one-shots hold no wakelock - if the phone goes back to sleep
                 * they simply fire at the next resume - so a maintenance wake costs nothing. */
                {
                    static struct timespec _rb_prev = {0}, _rm_prev = {0};
                    struct timespec _rb, _rm;
                    clock_gettime(CLOCK_BOOTTIME, &_rb);
                    clock_gettime(CLOCK_MONOTONIC, &_rm);
                    long _slept = 0;
                    if (_rb_prev.tv_sec)
                        _slept = (long)((_rb.tv_sec - _rb_prev.tv_sec) - (_rm.tv_sec - _rm_prev.tv_sec));
                    _rb_prev = _rb; _rm_prev = _rm;
                    /* With the waiter live, a resume that Android itself reports as off or doze
                     * is not a wake (fix118): the chain cost up to four extra ticks on every
                     * maintenance wake of the night, and a real wake is delivered by the
                     * waiter the moment the display turns on. */
                    int _dsr = asb_display_state_read();
                    int _not_wake = (g_disp_waiter_up == 2 && (_dsr == 1 || _dsr == 3 || _dsr == 4));
                    if (_slept >= 5 && !metrics.misc.screen_on && timerfd_state(tfd_active) == 0) {
                        if (_not_wake) {
                            g_scr_resume_skipped++;
                        } else {
                            g_disp_evt_ts = time(NULL); g_disp_retry = 0;
                            g_scr_resume_chains++;
                            arm_timerfd_once_ms(tfd_active, 400);
                        }
                    }
                    /* The waiter came up while the screen is off (or went away): move the
                     * uevent socket to match - parked while Android reports wakes, listening
                     * when it does not. */
                    if (!metrics.misc.screen_on && uefd >= 0) {
                        if (g_disp_waiter_up == 2 && !g_uev_parked) {
                            if (epoll_ctl(epfd, EPOLL_CTL_DEL, uefd, NULL) == 0) {
                                g_uev_parked = 1;
                                g_uev_parks++;
                                asb_log("display waiter: live - uevent socket parked, wakes come from Android's display state");
                            }
                        } else if (g_disp_waiter_up != 2 && g_uev_parked) {
                            uev_unpark(epfd, uefd);
                        }
                    }
                }
                if (!metrics.misc.screen_on && timerfd_state(tfd_active) == 0 && g_disp_evt_ts &&
                           time(NULL) - g_disp_evt_ts <= 3 && g_disp_retry < 3) {
                    /* A display event just came in and the panel has not reported on yet:
                     * a few more quick looks (~1.0, 1.6, 2.2 s after it), then give up -
                     * an always-on-display pulse or a pocket wake simply never turns on. */
                    g_disp_retry++;
                    arm_timerfd_once_ms(tfd_active, 600);
                }
            }

            /*
             * low-battery auto-switch.
             */
            if (g_asb_cfg.auto_battery_enable && metrics.bat.capacity_pct > 0) {
                time_t _now_t = time(NULL);
                int _can_act = (fsm.auto_battery_last_action == 0) ||
                               (_now_t - fsm.auto_battery_last_action >= g_asb_cfg.auto_battery_min_gap_s);

                if (!fsm.auto_battery_active &&
                    metrics.bat.capacity_pct <= g_asb_cfg.auto_battery_low_pct &&
                    fsm.profile_idx != PROFILE_BATTERY &&
                    _can_act) {
                    fsm.auto_battery_restore_idx = fsm.profile_idx;
                    fsm.auto_battery_active = 1;
                    fsm.auto_battery_last_action = _now_t;
                    
                    strncpy(fsm.auto_battery_reason, "low_pct", sizeof(fsm.auto_battery_reason) - 1);
                    fsm.auto_battery_reason[sizeof(fsm.auto_battery_reason) - 1] = '\0';
                    fsm.auto_battery_since = time(NULL);
                    fsm_auto_battery_persist(&fsm);
                    /*
                     * Durable record of where we came from, by name and independent of the
                     * in-memory flag.
                     * auto_battery_state stores active and restore_idx together, so the moment
                     * "active" is lost the restore target is lost with it - and then nothing
                     * knows whether this device is in battery because the module put it there
                     * or because the user chose it.
                     */
                    {
                        FILE *_of = fopen("/data/adb/asb/auto_battery_origin", "w");
                        if (_of) {
                            fprintf(_of, "%s\n", asb_profile_name(fsm.auto_battery_restore_idx));
                            fclose(_of);
                        }
                    }
                    asb_log("auto_battery: trigger bat=%d%% (low=%d) saving=%d -> spawning apply_profile.sh battery auto",
                            metrics.bat.capacity_pct,
                            g_asb_cfg.auto_battery_low_pct,
                            fsm.auto_battery_restore_idx);
                    int _rc = system("sh /data/adb/modules/AutoSystemBoost/apply_profile.sh battery auto >/dev/null 2>&1 &");
                    (void)_rc;
                } else if (fsm.auto_battery_active &&
                           metrics.bat.capacity_pct >= g_asb_cfg.auto_battery_high_pct &&
                           _can_act) {
                    int _restore = fsm.auto_battery_restore_idx;
                    /*
                     * Consult the durable record before falling back.
                     * The old code then silently chose BALANCED, which is why a Smart user who
                     * discharged to 15% and charged back to 40% came back to Balanced: nothing
                     * was broken about the trigger or the flag, the restore target had simply
                     * been forgotten and the fallback guessed.
                     */
                    if (_restore < 0 || _restore >= ASB_PROFILE_COUNT) {
                        FILE *_orf = fopen("/data/adb/asb/auto_battery_origin", "r");
                        if (_orf) {
                            char _on[24] = {0};
                            if (fgets(_on, sizeof(_on), _orf)) {
                                size_t _ol = strlen(_on);
                                while (_ol > 0 && (_on[_ol-1] == '\n' || _on[_ol-1] == '\r' ||
                                                   _on[_ol-1] == ' ')) _on[--_ol] = '\0';
                                if      (!strcmp(_on, "balanced"))    _restore = PROFILE_BALANCED;
                                else if (!strcmp(_on, "performance")) _restore = PROFILE_PERFORMANCE;
                                else if (!strcmp(_on, "smart"))       _restore = PROFILE_SMART;
                            }
                            fclose(_orf);
                        }
                    }
                    if (_restore < 0 || _restore >= ASB_PROFILE_COUNT) {
                        if (asb_smart_flag_read() == 1) _restore = PROFILE_SMART;
                        else                            _restore = PROFILE_BALANCED;
                    }
                    const char *_pname = asb_profile_name(_restore);
                    fsm.auto_battery_active = 0;
                    fsm.auto_battery_restore_idx = -1;
                    fsm.auto_battery_last_action = _now_t;
                    
                    strncpy(fsm.auto_battery_reason, "high_pct_restore", sizeof(fsm.auto_battery_reason) - 1);
                    fsm.auto_battery_reason[sizeof(fsm.auto_battery_reason) - 1] = '\0';
                    fsm.auto_battery_since = time(NULL);
                    fsm_auto_battery_persist(&fsm);
                    remove("/data/adb/asb/auto_battery_origin");
                    asb_log("auto_battery: restore bat=%d%% (high=%d) -> spawning apply_profile.sh %s auto",
                            metrics.bat.capacity_pct,
                            g_asb_cfg.auto_battery_high_pct, _pname);
                    char _cmd[160];
                    snprintf(_cmd, sizeof(_cmd),
                             "sh /data/adb/modules/AutoSystemBoost/apply_profile.sh %s auto >/dev/null 2>&1 &",
                             _pname);
                    int _rc = system(_cmd);
                    (void)_rc;
                } else if (!fsm.auto_battery_active &&
                           fsm.profile_idx == PROFILE_BATTERY &&
                           metrics.bat.capacity_pct >= g_asb_cfg.auto_battery_high_pct &&
                           _can_act) {
                    /*
                     * Recovery when the in-memory flag was lost.
                     * That distinction matters: someone who CHOSE battery must not be pulled
                     * out of it, which is why a bare "in battery and charged" test is not
                     * enough on its own.
                     */
                    int _rec_idx = -1;
                    {
                        FILE *_rf = fopen("/data/adb/asb/auto_battery_origin", "r");
                        if (_rf) {
                            char _rn[24] = {0};
                            if (fgets(_rn, sizeof(_rn), _rf)) {
                                size_t _rl = strlen(_rn);
                                while (_rl > 0 && (_rn[_rl-1] == '\n' || _rn[_rl-1] == '\r' ||
                                                   _rn[_rl-1] == ' ')) _rn[--_rl] = '\0';
                                if      (!strcmp(_rn, "balanced"))    _rec_idx = PROFILE_BALANCED;
                                else if (!strcmp(_rn, "performance")) _rec_idx = PROFILE_PERFORMANCE;
                                else if (!strcmp(_rn, "smart"))       _rec_idx = PROFILE_SMART;
                            }
                            fclose(_rf);
                        }
                    }
                    if (_rec_idx < 0 && asb_smart_flag_read() == 1) _rec_idx = PROFILE_SMART;

                    if (_rec_idx >= 0) {
                        const char *_rname = asb_profile_name(_rec_idx);
                        fsm.auto_battery_last_action = _now_t;
                        fsm.auto_battery_restore_idx = -1;
                        strncpy(fsm.auto_battery_reason, "recovery_restore", sizeof(fsm.auto_battery_reason) - 1);
                        fsm.auto_battery_reason[sizeof(fsm.auto_battery_reason) - 1] = '\0';
                        fsm.auto_battery_since = time(NULL);
                        fsm_auto_battery_persist(&fsm);
                        remove("/data/adb/asb/auto_battery_origin");
                        asb_log("auto_battery: recovery restore bat=%d%% (high=%d) -> spawning apply_profile.sh %s auto",
                                metrics.bat.capacity_pct,
                                g_asb_cfg.auto_battery_high_pct, _rname);
                        char _rcmd[160];
                        snprintf(_rcmd, sizeof(_rcmd),
                                 "sh /data/adb/modules/AutoSystemBoost/apply_profile.sh %s auto >/dev/null 2>&1 &",
                                 _rname);
                        int _rc2 = system(_rcmd);
                        (void)_rc2;
                    }
                }
            }

            {
                time_t _an_now = time(NULL);
                if (g_anom_window_start == 0 ||
                    (long)(_an_now - g_anom_window_start) >= 3600) {
                    g_anom_window_start = _an_now;
                    g_anom_count_1h = 0;
                    g_anom_pkg_total = 0;
                    g_anom_pkg_ok = 0;
                }
                int _code = ASB_ANOM_NONE;
                long _live_x10 = 0;
                if (g_smart_drain_on_sec >= ASB_SMART_DRAIN_MIN_ON_SEC &&
                    g_smart_drain_drop_x100 > 0) {
                    _live_x10 = (g_smart_drain_drop_x100 * 360L) / g_smart_drain_on_sec;
                }
                if (_live_x10 >= ASB_ANOM_DRAIN_SPIKE_X10) {
                    _code = ASB_ANOM_DRAIN_SPIKE;
                    g_drain_spike_until = _an_now + ASB_BUDGET_SPIKE_WINDOW_S;
                } else if (v44_clamp_1h_now() >= ASB_ANOM_VENDOR_WAR_CLAMPS_1H) {
                    _code = ASB_ANOM_VENDOR_WAR;
                } else if (fsm.profile_idx == PROFILE_BATTERY &&
                           !metrics.bat.charging &&
                           /*
                            * Absolute 40%, not high_pct + 10.
                            * Tying it to high_pct meant that narrowing that hysteresis from 30
                            * to 21 silently moved the anomaly from 40% to 31%, and would have
                            * flagged anyone who simply picked Battery by hand at a third of a
                            * charge.
                            */
                           metrics.bat.capacity_pct >= 40 &&
                           asb_smart_flag_read() == 1) {
                    _code = ASB_ANOM_STUCK_BATTERY;
                } else if (g_anom_pkg_total >= 50 &&
                           g_anom_pkg_ok * 10 < g_anom_pkg_total) {
                    _code = ASB_ANOM_PKG_MISSING;
                }
                if (_code != ASB_ANOM_NONE && g_anom_code == ASB_ANOM_NONE) {
                    g_anom_count_1h++;
                    asb_log("anomaly: code=%d count_1h=%d", _code, g_anom_count_1h);
                }
                g_anom_code = _code;
            }

            /* log thermal CPU source flips (primary <-> fallback)
             * visible in governor.log for runtime thermal path diagnostics. */
            if (metrics.therm.fallback_just_flipped) {
                asb_log("thermal_cpu_switch: primary=%s fallback=%s -> used_fallback=%d (cpu_max=%dC)",
                        g_thermal_cpu_type,
                        g_thermal_cpu_fallback_type[0] ? g_thermal_cpu_fallback_type : "none",
                        metrics.therm.used_fallback,
                        metrics.therm.cpu_max_c);
            }

            float dummy_drain, dummy_screen;
            if (accum_tick(&accum,
                           metrics.bat.charging ? -1 : metrics.bat.current_ma,
                           metrics.misc.screen_on,
                           &dummy_drain, &dummy_screen)) {
                learner_update(&learn, dummy_drain, dummy_screen);
                cur_pred = learner_predict(&learn);
                learner_adjust_windows(&learn, &fsm.up_window, &fsm.down_window);
            }

            asb_night_window_tick(metrics.misc.screen_on, time(NULL));
            asb_mw_update(metrics.misc.screen_on, fsm.profile_idx == PROFILE_SMART, time(NULL));

            /* radio-aware -- track mobile data activity during battery idle */
            if ((fsm.profile_idx == PROFILE_BATTERY ||
                 fsm.profile_idx == PROFILE_SMART) && !metrics.misc.screen_on) {
                long net_bps = metrics.misc.rmnet_rx_bps + metrics.misc.rmnet_tx_bps;
                /* Same reading, kept for the learner: one running mean per session. */
                g_ses_net_kib_sum += (metrics.misc.rmnet_rx_bps +
                                      metrics.misc.rmnet_tx_bps) / 1024;
                g_ses_net_samples++;
                if (net_bps > 5000)  /* >5KB/s = active data transfer */
                    fsm.bat_radio_active_ticks++;
            }

            /* V56: sample memory pressure (PSI some avg10) every tick so the
             * session record can carry a peak + a pressured-tick count. Pure
             * observation -- gives the module its first memory visibility. */
            {
                int _mp = asb_read_mem_psi_x100();
                if (_mp >= 0) {
                    if (_mp > fsm.mem_psi_peak_x100) fsm.mem_psi_peak_x100 = _mp;
                    if (_mp >= 500) fsm.mem_pressure_ticks++;  /* >=5.0 avg10 */
                }
            }

            /* pass virtual ceiling to FSM for gap reshaping */
            fsm.virtual_ceiling_p0 = g_virtual_ceiling_p0;
            fsm.virtual_ceiling_p1 = g_virtual_ceiling_p1;

            /*
             * thermal_pwrlevel monitoring (KGSL devices where msm_performance is dead).
             * Skip if screen off (vendor thermal not relevant when GPU idle) 3.
             */
            {
                int monitor_skipped = 1;
                static time_t g_last_thermal_pl_read = 0;
                time_t now_for_pl = time(NULL);
                int min_interval_ok = (now_for_pl - g_last_thermal_pl_read >= 2);

                if (g_asb_cfg.thermal_pwrlevel_div_idle > 0 &&
                    metrics.misc.screen_on &&
                    fsm.state != ASB_STATE_DEEP_IDLE &&
                    min_interval_ok)
                {
                    int should_read = 0;
                    if (fsm.state == ASB_STATE_HEAVY ||
                        fsm.state == ASB_STATE_SUSTAINED ||
                        fsm.state == ASB_STATE_GAMING)
                    {
                        should_read = 1;
                    } else {
                        /* LIGHT_IDLE / MODERATE: gate by div counter */
                        static int g_thermal_pl_idle_skip = 0;
                        if (++g_thermal_pl_idle_skip >= g_asb_cfg.thermal_pwrlevel_div_idle) {
                            should_read = 1;
                            g_thermal_pl_idle_skip = 0;
                        }
                    }
                    if (should_read) {
                        int level = gpu_read_thermal_pwrlevel();
                        (void)level; /* used by FSM via gpu_thermal_pwrlevel_last() */
                        g_last_thermal_pl_read = now_for_pl;
                        monitor_skipped = 0;
                    }
                }
                if (monitor_skipped) gpu_thermal_pl_record_skip();

                /*
                 * thread thermal_pwrlevel into thermal struct for FSM use.
                 */
                {
                    int tpl = gpu_thermal_pwrlevel_last();
                    metrics.therm.gpu_thermal_pwrlevel = tpl;
                    metrics.therm.gpu_thermal_pwrlevel_active = 0;
                    if (tpl > 0) {
                        /* Read our current max_pwrlevel write to compare. Cheap
                         * because it's the same path we discovered + write to. */
                        int our_max = -1;
                        if (g_gpu_uses_pwrlevel && g_gpu_max_path[0]) {
                            int fd = open(g_gpu_max_path, O_RDONLY | O_CLOEXEC);
                            if (fd >= 0) {
                                char b[8] = {0};
                                ssize_t _n = read(fd, b, sizeof(b)-1);
                                close(fd);
                                if (_n > 0) our_max = atoi(b);
                            }
                        }
                        if (our_max >= 0 && tpl > our_max) {
                            /* Vendor wants stricter cap than us — soft signal */
                            metrics.therm.gpu_thermal_pwrlevel_active = 1;
                            if (!metrics.therm.soft_clamp) {
                                metrics.therm.soft_clamp = 1;
                                /* Don't escalate to hard_clamp from this signal alone;
                                 * thermal_pwrlevel is a soft hint, not actionable
                                 * confirmation like CPU thermal throttling is. */
                            }
                        }
                    }
                }

                /* Audit logger: flush counters periodically so user can verify
                 * the cost claim ("not eating battery") with real numbers. */
                static time_t g_thermal_pl_last_audit = 0;
                if (g_asb_cfg.thermal_pwrlevel_audit_log_s > 0) {
                    time_t now_s = time(NULL);
                    if (g_thermal_pl_last_audit == 0)
                        g_thermal_pl_last_audit = now_s;
                    if (now_s - g_thermal_pl_last_audit >= g_asb_cfg.thermal_pwrlevel_audit_log_s) {
                        char audit_buf[256];
                        gpu_thermal_pl_audit_path(audit_buf, sizeof(audit_buf));
                        asb_log("thermal_pl_audit: %s elapsed_s=%ld",
                                audit_buf, (long)(now_s - g_thermal_pl_last_audit));
#if ASB_DEBUG_BUILD
                        FILE *af = fopen("/dev/.asb/thermal_pl_audit", "w");
                        if (af) {
                            fprintf(af, "%s\nelapsed_s=%ld\n",
                                    audit_buf, (long)(now_s - g_thermal_pl_last_audit));
                            fclose(af);
                        }
#endif
                        g_thermal_pl_last_audit = now_s;

                        char vo_buf[256];
                        gpu_vendor_override_audit_path(vo_buf, sizeof(vo_buf));
                        asb_log("vendor_override_audit: %s", vo_buf);
#if ASB_DEBUG_BUILD
                        FILE *vf = fopen("/dev/.asb/vendor_override_audit", "w");
                        if (vf) {
                            fprintf(vf, "%s\n", vo_buf);
                            fclose(vf);
                        }
#endif
                    }
                }

                /* vendor override detection — check if vendor
                 * PowerHAL or thermal HAL stomped our pwrlevel writes. Same
                 * cost gating as thermal_pwrlevel monitor (skip DEEP_IDLE,
                 * skip screen-off, 2s minimum interval). */
                if (!monitor_skipped) {
                    gpu_check_vendor_override(fsm.profile_idx,
                                              asb_state_names[fsm.state]);
                }
            }

            writer_camera_guard(metrics.misc.camera_active);

            /*
             * Modem LPM.
             * The policy is about what the device is DOING, not which profile is selected, so
             * it lives here rather than in the Smart tick: an online match wants the data call
             * hot because coming back from an idle radio state is the latency spike that costs
             * the round, and a sleeping phone wants the opposite.
             */
            {
                /*
                 * The Battery profile outranks the load state.
                 * Reported as exactly that mismatch.
                 */
                /* A deeper step for the learned sleep window.
                 *
                 * "save" drops the always-on data call the moment the screen goes off, which is
                 * right for a pocket: the phone may be picked up any second. Overnight it is too
                 * timid. A five-hour sleep capture shows bluetooth 2.69 against cpu 3.96 in
                 * batterystats and roughly a thousand kernel wakeups down the modem path -
                 * rmnet_ipa 180, rmnet_ctl 300, IPA_LAN 318. The CPU slept 97% of the time and the
                 * phone still drew 96 mA, because something kept knocking on the door.
                 *
                 * "night" stretches keepalives much further and lets the radio settle - affordable
                 * at 3am, not at 3pm. It engages only inside a window the learner derived from this
                 * user's own nights, so a shift worker gets theirs rather than someone's idea of
                 * night. */
                /* Smart can deliberately lean into the Battery envelope (bias >= 400),
                 * which means its active session is asking for economy over latency.  Do not
                 * defeat that choice by holding mobile_data_always_on in fast merely because
                 * a feed/media burst reached HEAVY.  Confirmed GAMING stays fast, as does a
                 * camera session or any Smart context that is not explicitly battery-lean.
                 * The user-facing handover opt-in remains independent: normal mode still
                 * honours net_handover_fast inside asb_lpm.sh. */
                int smart_battery_lean =
                    fsm.profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
                    g_asb_cfg.smart_battery_bias >= 400 &&
                    !metrics.misc.camera_active && !metrics.bat.charging &&
                    g_smart_rt.app_hint < ASB_APP_GAMING;
                g_smart_battery_lean_pub = smart_battery_lean;
                const char *lpm_mode =
                    (g_asb_cfg.night_modem_idle && (!metrics.misc.screen_on || g_mw_active) &&
                     asb_night_window_active(time(NULL)))   ? "night" :
                    !metrics.misc.screen_on                 ? "save" :
                    (fsm.profile_idx == PROFILE_BATTERY)    ? "save" :
                    (fsm.state == ASB_STATE_GAMING ||
                     (fsm.state == ASB_STATE_HEAVY && !smart_battery_lean))
                                                        ? "fast" : "normal";
                static const char *g_lpm_last = NULL;
                static time_t g_lpm_last_ts = 0;
                time_t lpm_now = time(NULL);
                /* Compare the strings, not the pointers.
         *
         * lpm_mode is assigned from string literals in a conditional chain, and this test
         * relied on the compiler pooling identical literals so that two "save" results
         * share an address. GCC does pool them here, so it happens to work - but nothing
         * in the language requires it, and the failure mode is silent: with pooling off,
         * every tick looks like a mode change and the LPM script is re-run every fifteen
         * seconds forever; with a future edit that builds the string instead of selecting
         * a literal, a real change stops being noticed at all.
         *
         * A field diag shows LPM sitting at "normal" for 219 ticks against 56 in "save" on
         * a phone that spent the night with its screen off, which is the shape of the
         * second failure. strcmp costs nothing here and cannot depend on the toolchain. */
        if ((g_lpm_last == NULL || strcmp(lpm_mode, g_lpm_last) != 0) &&
            (lpm_now - g_lpm_last_ts) >= 15) {
                    /* Resolved module dir + logged failure: the old hardcoded spawn
                     * discarded its return value, so a missing asb_lpm.sh was invisible. */
                    asb_run_modscript("runtime/asb_lpm.sh", lpm_mode);
                    g_lpm_last    = lpm_mode;
                    g_lpm_last_ts = lpm_now;
                }
            }

            /*
             * Periodic maintenance, on this loop's clock rather than its own process: the
             * config file watch and the night doze window.
             */
            {
                time_t _mnow = time(NULL);
                /* Reload governor.conf when it changes on disk.
                 *
                 * Until now only an explicit "asb reload" re-read the file, so a WebUI save of any
                 * governor-owned key sat inert until the next reboot - and the diag had to print a
                 * warning telling the user to reload by hand. That warning is the symptom; the file
                 * watch is the fix, and it removes a whole class of "the setting did nothing".
                 *
                 * mtime, not inotify: one stat per tick against a file already in page cache costs
                 * nothing, and it cannot leak a watch descriptor across the reload it triggers.
                 * The existing reload path validates and rejects a bad file, so a partial write
                 * mid-save is refused rather than applied. */
                {
                    static time_t _cfg_mtime = 0;
                    struct stat _cst;
                    if (stat(CONFIG_FILE, &_cst) == 0) {
                        if (_cfg_mtime == 0) {
                            _cfg_mtime = _cst.st_mtime;
                        } else if (_cst.st_mtime != _cfg_mtime) {
                            _cfg_mtime = _cst.st_mtime;
                            asb_runtime_config_t _ncfg;
                            asb_config_defaults(&_ncfg);
                            int _rc = asb_config_load_file(CONFIG_FILE, &_ncfg);
                            g_cfg_load_rc = _rc;
                            g_cfg_load_ts = time(NULL);
                            if (_rc == 0) {
                                asb_config_apply_highload_mode(&_ncfg);
                                g_asb_cfg = _ncfg;
                                asb_log("config: reloaded automatically (governor.conf changed on disk)");
                            } else {
                                asb_log("config: auto-reload refused rc=%d; keeping last-known-good", _rc);
                            }
                        }
                    }
                }
                /* No reconcile spawn here any more (fix144). "sh asb_reconcile.sh --once" broke
                 * out of its loop before the first check - the fast branch's --once break sits
                 * ahead of the pass - and, run outside service.sh, it had none of the helpers the
                 * pass calls. Every 2-16 minutes it forked two shells to do nothing. The native
                 * governor owns the CPU policy it would have reconciled; without the governor the
                 * resident reconcile loop service.sh starts after 90 s is unchanged. */
                /* doze=night has to be re-evaluated when the window opens and closes,
                 * and boot is the only time anything ran it. Hourly is plenty: the
                 * window has hour granularity, and the script is a no-op unless the
                 * side of the boundary changed. */
                {
                    static time_t _doze_last = 0;
                    if (_doze_last == 0) _doze_last = _mnow;
                    /* Only while the screen is off - this one runs the other way round.
                     *
                     * asb_doze_apply arms the night window: it pauses AOD, gates the modem wakeup
                     * nodes and adjusts idle timings. None of that means anything while the user is
                     * looking at the screen, and the script itself checks and exits - after the fork,
                     * the shell, the grep and the config read have already happened.
                     *
                     * Checking the screen here costs nothing and removes six spawns an hour of
                     * screen-on time. The night path is unaffected: with the screen off the cadence
                     * is exactly what it was. */
                    if (!metrics.misc.screen_on && (_mnow - _doze_last) >= 600) {
                        _doze_last = _mnow;
                        int _dr = system("grep -q '^doze_level=night' "
                                         "/data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null"
                                         " && sh /data/adb/modules/AutoSystemBoost/runtime/asb_doze_apply.sh"
                                         " >/dev/null 2>&1 &");
                        (void)_dr;
                    }
                }
                /* No watchdog spawn here either (fix144). The governor cannot be its own
                 * liveness check - if it dies, nothing it schedules runs - and the spawned
                 * "asb_watchdog.sh --once" exited on its first line anyway: ASB_GOV_ENABLED is
                 * a shell variable of service.sh, never in this process's environment. The
                 * check now lives in service.sh's housekeeping loop. */
            }

            /* Hand the app classification to the FSM before it decides.
             * The Smart package table already knows which app is a game; without this the FSM
             * only ever saw GPU load, and a game that does not push the GPU past the entry
             * threshold never reached GAMING at all.
             * fix210: classify first on the manual profiles too - otherwise the hint
             * stays 0, the gate's "no package information" fallback counts as agreement,
             * and any busy GPU next to a busy CPU reads as GAMING. */
            asb_fg_classify_tick(&metrics, &fsm);
            metrics.misc.app_hint = g_smart_rt.app_hint;
            /* Tell the writer whether anyone is looking, before it writes anything. */
            fsm_screen_is_on = metrics.misc.screen_on;
            /* Unlock lift (fix150): decided before the touch kick is answered below, because
             * the first touch after a wake re-arms it. Lifting forces the write - the writer
             * otherwise holds a ceiling for 10 s while the state does not move, which is the
             * touch re-arm's case. Ending it only asks for a pass (g_unlock_edge): a live
             * ceiling above the request is always rewritten, and so is a changed uclamp. */
            {
                /* fix212: an app switch is a launch burst. The foreground hash was refreshed
                 * a few lines up (the manual-profile classification) or one tick ago (Smart's
                 * own tick) - either way fresh enough for a 3 s window. Screen-off and "no
                 * package" reset the baseline, so a wake is never mistaken for a switch. */
                static long g_launch_prev_hash = 0;
                int _launch_kick = 0;
                {
                    uint64_t _fh = g_smart_rt.app_hash;
                    if (metrics.misc.screen_on && _fh != 0 && g_launch_prev_hash != 0 &&
                        (uint64_t)g_launch_prev_hash != _fh)
                        _launch_kick = 1;
                    g_launch_prev_hash = (metrics.misc.screen_on && _fh != 0) ? (long)_fh : 0;
                }
                int _ul_was = g_unlock_applied;
                int _touch_active = metrics.misc.screen_on && !metrics.misc.camera_active &&
                                    g_touch_last_ts > 0 &&
                                    time(NULL) - g_touch_last_ts <= ASB_TOUCH_RECENT_S;
                int _ul = asb_unlock_lift_update(metrics.misc.screen_on, g_touch_kick,
                                                 _touch_active, g_lock_key_kick, _launch_kick,
                                                 asb_clock_ms(CLOCK_BOOTTIME), fsm.profile_idx,
                                                 fsm.thermal_cap,
                                                 asb_unlock_gate_die(metrics.therm.cpu_max_c,
                                                                     g_unlock_dark_c,
                                                                     g_unlock_dark_ts,
                                                                     time(NULL)));
                if (_ul != _ul_was) {
                    g_unlock_edge = 1;
                    /* Screen off inside the window: the screen-off write must get through the
                     * deep-idle back-off, and the edge is answered here so it is logged once. */
                    if (_ul || !metrics.misc.screen_on) force_write = 1;
                    if (!metrics.misc.screen_on) g_unlock_applied = 0;
                    if (g_asb_cfg.log_level >= 2) {
                        if (_ul)
                            asb_log("unlock_lift: on (%s, ceilings to %d%% of hw for %d s, die=%dC)",
                                    g_unlock_arm_why,
                                    asb_unlock_lift_share(fsm.profile_idx), g_asb_cfg.unlock_lift_s,
                                    metrics.therm.cpu_max_c);
                        else
                            asb_log("unlock_lift: off (%s)",
                                    metrics.misc.screen_on ? "time up" : "screen off");
                    }
                }
            }
            int changed = fsm_update(&fsm, &metrics);
            g_touch_kick = 0;   /* answered (fix117) */
            g_lock_key_kick = 0;   /* answered (fix220) */
            /* fix184: Smart records - one tick of measuring, the knobs read back below. */
            {
                asb_rec_in_t _ri;
                memset(&_ri, 0, sizeof(_ri));
                _ri.enabled     = g_asb_cfg.smart_records && fsm.profile_idx == PROFILE_SMART &&
                                  g_smart_rt.enabled;
                _ri.explore     = g_asb_cfg.smart_records_explore;
                _ri.screen_on   = metrics.misc.screen_on;
                _ri.charging    = metrics.bat.charging;
                /* Quiet deep idle: DEEP_IDLE with the CPU asleep most of the time. Screen-off
                 * music keeps the CPU awake (100 % in the captures) - it must not run on a
                 * setting being tried, and a block full of it is not about the setting.
                 * Hysteresis (busy at 70 %, quiet again under 50 %) so a sync burst does not
                 * flip the ceilings back and forth. Nor while the cap detente freezes writes:
                 * the setting would be claimed without being on the hardware. */
                {
                    static int _rq_quiet = 1;
                    int _aw = metrics.cpu.awake_tick_pct;
                    if (_aw >= 70) _rq_quiet = 0;
                    else if (_aw >= 0 && _aw < 50) _rq_quiet = 1;
                    _ri.idle_state = (fsm.state == ASB_STATE_DEEP_IDLE && _rq_quiet &&
                                      !g_cap_detente_active);
                }
                _ri.heavy_state = (fsm.state >= ASB_STATE_HEAVY || g_smart_rt.app_hint >= ASB_APP_HEAVY ||
                                   metrics.misc.camera_active);
                _ri.app_medium  = (g_smart_rt.app_hint == ASB_APP_MEDIUM);
                _ri.thermal_cap = fsm.thermal_cap;
                _ri.cooldown    = g_fsm_cooldown_active;
                _ri.veto        = g_smart_rt.thermal_veto;
                _ri.lowbat      = g_smart_rt.low_battery_override;
                _ri.night       = asb_night_window_active(time(NULL)) ||
                                  (!asb_night_window_ready() && g_smart_rt.daypart == ASB_DAYPART_SLEEP);
                _ri.microwake   = g_mw_active;
                _ri.at_ceiling  = metrics.misc.screen_on ? asb_rec_at_ceiling(&metrics) : 0;
                _ri.now_ms      = asb_clock_ms(CLOCK_BOOTTIME);
                _ri.wall        = (long)time(NULL);
                /* fix185: climate and charge - the pack temperature, its voltage (power =
                 * charge x voltage), the charge level and how long ago the charger came off. */
                _ri.bat_temp_dc = metrics.bat.temp_dC;
                _ri.voltage_uv  = metrics.bat.voltage_uv;
                _ri.soc         = metrics.bat.capacity_pct;
                {
                    static int  _rc_prev_chg = -1;
                    static long long _rc_unplug_ms = 0;
                    if (_rc_prev_chg == 1 && !metrics.bat.charging) _rc_unplug_ms = _ri.now_ms;
                    _rc_prev_chg = metrics.bat.charging ? 1 : 0;
                    _ri.unplug_age_s = (_rc_unplug_ms > 0) ? (long)((_ri.now_ms - _rc_unplug_ms) / 1000)
                                                           : 1000000L;
                    g_unplug_age_s = _ri.unplug_age_s;
                    /* The session's battery temperature, for the learner's climate guard. */
                    int _bt = metrics.bat.temp_dC;
                    if (_bt > -300 && _bt < 800) {
                        if (g_ses_bat_t0_dc == -10000) g_ses_bat_t0_dc = _bt;
                        if (_bt < g_ses_bat_tmin_dc) g_ses_bat_tmin_dc = _bt;
                        if (_bt > g_ses_bat_tmax_dc) g_ses_bat_tmax_dc = _bt;
                    }
                    if (metrics.misc.screen_on && !metrics.bat.charging &&
                        _ri.unplug_age_s < ASB_REC_SETTLE_S)
                        g_ses_post_unplug = 1;
                }
                asb_rec_tick(&_ri);
                asb_smooth_probe_tick(&fsm, &metrics);
                asb_bhold_tick(&fsm, &metrics);
                asb_battery_jank_guard_tick(&fsm, &metrics);
                if (g_rec_event) { asb_log("%s", g_rec_event_msg); g_rec_event = 0; }
                if (g_rec_knob_changed) { g_rec_knob_changed = 0; force_write = 1; }
            }

            /* rebuild plan on state band cross (idle<->active<->heavy) */
            if (changed) {
                int new_band = (fsm.state <= ASB_STATE_LIGHT_IDLE) ? 0
                             : (fsm.state < ASB_STATE_HEAVY) ? 1 : 2;
                static int g_last_band = -1;
                if (new_band != g_last_band) {
                    session_plan_build(&fsm, metrics.misc.screen_on);
                    session_plan_apply_prearm(&fsm);
                    g_last_band = new_band;
                }
            }
            /* accumulate headroom telemetry (only real reads) */
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
                            if (fsm.ses_time_sustained_sec > 300 ||
                                fsm.ses_max_temp >= 65) {
                                fsm.ses_intent = INTENT_IDLE_WARM;
                            } else {
                                fsm.ses_intent = INTENT_IDLE;
                            }
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
            /*
             * benchmark false-positive guard -- runs EVERY tick regardless of lock status.
             * Must be OUTSIDE !ses_intent_locked block to actually fire.
             */
            if (fsm.ses_intent == INTENT_BENCHMARK &&
                fsm.ses_intent_locked && fsm.ses_start_ts > 0) {
                long _bfp_age = time(NULL) - fsm.ses_start_ts;
                if (_bfp_age >= 900) {
                    int _bfp_gaming = (fsm.ses_gaming_entries > 0);
                    fsm.ses_intent = _bfp_gaming ? INTENT_LONG_GAME : INTENT_MIXED;
                    asb_log("intent: benchmark downgraded to %s "
                            "(age=%lds > 900s, not a real benchmark)",
                            intent_names[fsm.ses_intent], _bfp_age);
                }
            }
            if (fsm.state == ASB_STATE_DEEP_IDLE) {
                /* use session age, not fsm_elapsed (which resets on heartbeat flush) */
                long ses_age_b = (fsm.ses_start_ts > 0) ? (time(NULL) - fsm.ses_start_ts) : 0;
                if (ses_age_b >= 1800 && fsm.bat_time_deep_idle_sec > 900) {
                    fsm_flush_state_time(&fsm);
                    if (fsm.ses_time_heavy_sec > 0 ||
                        fsm.bat_time_deep_idle_sec > 60) {
                        session_history_append_ex(&fsm, "idle_boundary");
                        session_end_self_tune(&fsm);
                        persistent_stats_save(&fsm);
                        session_reset_and_replan(&fsm, metrics.misc.screen_on);
                        asb_log("session_boundary: 30min DEEP_IDLE, stats saved+reset");
                    }
                }
            }

            /*
             * Smart Mode periodic learning: keep learning even when the user never switches
             * profiles.
             */
            if (fsm.profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
                g_smart_store_loaded) {
                long _ses_age = (fsm.ses_start_ts > 0)
                                ? (time(NULL) - fsm.ses_start_ts) : 0;
                int _bucket_rollover =
                    (g_smart_last_seen_bucket >= 0 &&
                     g_smart_last_seen_bucket != (int)g_smart_rt.bucket_id &&
                     metrics.misc.screen_on);
                /*
                 * Fire a soft session after the session has run long enough, regardless of
                 * whether it was heavy.
                 * Light daily use (browsing, messaging, idle) must advance the learner too —
                 * otherwise a user who never switches profiles would never accumulate
                 * confidence.
                 */
                long _active_s = fsm.ses_time_heavy_sec
                               + fsm.ses_time_gaming_sec
                               + fsm.ses_time_sustained_sec;
                int _meaningful = (_active_s > 60 || fsm.bat_wake_screen > 0);
                int _smart_age_trigger =
                    (_ses_age >= 1200 && _meaningful &&
                     (time(NULL) - g_smart_last_periodic_ts) >= 1200);
                if (_bucket_rollover || _smart_age_trigger) {
                    const char *_reason = _bucket_rollover
                                          ? "smart_bucket_rollover"
                                          : "smart_periodic";
                    fsm_flush_state_time(&fsm);
                    session_history_append_ex(&fsm, _reason);
                    session_end_self_tune(&fsm);
                    persistent_stats_save(&fsm);
                    session_reset_and_replan(&fsm, metrics.misc.screen_on);
                    g_smart_last_periodic_ts = time(NULL);
                    asb_log("smart_learn: %s fired (age=%lds, bucket=%u, heavy=%lds)",
                            _reason, _ses_age,
                            (unsigned)g_smart_rt.bucket_id,
                            fsm.ses_time_heavy_sec);
                }
                g_smart_last_seen_bucket = (int)g_smart_rt.bucket_id;
            }
            /*
             * Smart Mode tick: refresh g_smart_bounds BEFORE writer_apply_caps.
             * Force a write so the change reaches sysfs immediately rather than waiting for
             * the next state transition.
             */
            int smart_updated = asb_smart_tick(&metrics, &fsm);
            int smart_media_guard_changed = asb_smart_media_guard_observe(&metrics, &fsm, time(NULL));
            if (smart_media_guard_changed) force_write = 1;
            asb_smart_persist_check();
            if (smart_updated && fsm.profile_idx == PROFILE_SMART) {
                asb_profile_caps_t _new_caps;
                fsm_interpolate_caps(asb_profile_bounds_for(fsm.profile_idx),
                                     fsm.profile_idx, fsm.state,
                         0, 0.0f, &_new_caps);
                /* Apply same thermal overlay as the normal FSM path */
                if (fsm.thermal_cap && fsm.state != ASB_STATE_SUSTAINED) {
                    float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
                    for (int i = 0; i < 3; i++)
                        _new_caps.cpu_max[i] = (int)(_new_caps.cpu_max[i] * keep);
                }
                /* Detect if caps actually changed to avoid spurious writes */
                int _diff = 0;
                int _thr = fsm.thermal_cap ? 1 : 38400;
                for (int i = 0; i < 3; i++) {
                    if (abs(_new_caps.cpu_max[i] - fsm.current_caps.cpu_max[i]) >= _thr) { _diff = 1; break; }
                    if (abs(_new_caps.cpu_min[i] - fsm.current_caps.cpu_min[i]) >= _thr) { _diff = 1; break; }
                }
                if (!_diff) {
                    int _gthr = fsm.thermal_cap ? 1 : 2;
                    if (abs(_new_caps.gpu_max_pct - fsm.current_caps.gpu_max_pct) >= _gthr ||
                        abs(_new_caps.gpu_min_pct - fsm.current_caps.gpu_min_pct) >= _gthr) {
                        _diff = 1;
                    }
                }
                if (_diff) {
                    fsm.current_caps = _new_caps;
                    force_write = 1;
                    if (g_asb_cfg.smart_debug_log) {
                        asb_log("smart_tick: forced caps refresh (alpha=%d, fb=%d)",
                                g_smart_rt.alpha_battery_x1000,
                                g_smart_rt.fallback_level);
                    }
                }
            }
            {
                int _det = asb_cap_detente_check(
                        metrics.misc.screen_on,
                        fsm.state == ASB_STATE_DEEP_IDLE ||
                            fsm.state == ASB_STATE_LIGHT_IDLE,
                        g_cap_owner_eff == ASB_CAP_OWNER_VENDOR ||
                            g_cap_owner_eff == ASB_CAP_OWNER_SHELL,
                        (long)(time(NULL) - g_cap_owner_since),
                        metrics.therm.cpu_max_c,
                        fsm.thermal_cap);
                static int _det_false_ticks = 0;
                int _hard_exit = (metrics.misc.screen_on || fsm.thermal_cap);
                if (_det) _det_false_ticks = 0;
                if (_det && !g_cap_detente_active) {
                    g_cap_detente_active = 1;
                    g_cap_detente_since = time(NULL);
                    asb_log("cap_detente: enter (foreign-owned deep idle, freezing cap writes)");
                } else if (!_det && g_cap_detente_active) {
                    _det_false_ticks++;
                    if (_hard_exit || _det_false_ticks >= 3) {
                        g_cap_detente_active = 0;
                        _det_false_ticks = 0;
                        asb_log("cap_detente: exit after %lds (%s, skipped %ld writes total)",
                                (long)(time(NULL) - g_cap_detente_since),
                                _hard_exit ? "wake/thermal" : "conditions faded",
                                g_cap_detente_skipped);
                    }
                }
            }
            /* One decision for all three branches below.
             *
             * The detente and backoff guards were written as (changed || force_write),
             * so a re-assert that fires on a timer - with nothing changed and nothing
             * forced - matched neither and fell straight through to the write. That is
             * the write war those guards exist to prevent: on a device where the vendor
             * owns the cap, the module would have gone back to rewriting it every 30 s
             * while passive mode was supposedly holding it back.
             *
             * The periodic pass is for drift the module can legitimately fix, not a way
             * around the module's own restraint. */
            int want_apply = (changed || force_write || g_unlock_edge ||
                              (time(NULL) - g_last_caps_reassert) >= 30);
            g_unlock_edge = 0;

            if (want_apply && g_cap_detente_active) {
                g_cap_detente_skipped++;
                g_write_skipped_detente++;
            } else if (want_apply &&
                       asb_cap_writes_should_back_off() &&
                       !force_write && !metrics.misc.screen_on &&
                       (fsm.state == ASB_STATE_DEEP_IDLE ||
                        fsm.state == ASB_STATE_LIGHT_IDLE) &&
                       !fsm.thermal_cap) {
                g_cap_detente_skipped++;
                g_write_skipped_backoff++;
            } else if (want_apply) {
                g_write_attempts++;
                asb_profile_caps_t _effective_caps = fsm.current_caps;
                asb_apply_adaptive_budget_caps(&_effective_caps, &metrics, &fsm);
                asb_smart_media_guard_apply_caps(&_effective_caps);
                /* fix150: the unlock lift, after every trim - it only ever raises a ceiling,
                 * and only for the seconds after a wake (see asb_unlock_lift_update). */
                if (g_unlock_lift_now && !fsm.thermal_cap && metrics.misc.screen_on) {
                    asb_unlock_lift_apply(&_effective_caps);
                    g_unlock_applied = 1;
                } else {
                    g_unlock_applied = 0;
                }

                /* Floor the top-app ceiling while the screen is on.
                 *
                 * uclamp.max is a CEILING on what a task may ask the scheduler for, not a
                 * frequency the phone holds: raising it costs nothing while the phone is
                 * idle and only stops getting in the way when something actually needs a
                 * burst. A field report of "slideshow" while scrolling a gallery of
                 * videos, and while watching video alongside another app, came with a
                 * capture showing top-app uclamp.max at 38 - below even the Battery
                 * profile's own ceiling of 50. Decode plus UI cannot run on that, and the
                 * media guard does not help because it only caps the GPU.
                 *
                 * 50 is not invented: it is BALANCED_FLOOR_UCLAMP_TOP, the least this
                 * project has ever considered acceptable for the app in front of the
                 * user. Screen-off keeps whatever the learner decided - nobody is
                 * waiting then. */
                if (metrics.misc.screen_on &&
                    _effective_caps.uclamp_top_max > 0 &&
                    _effective_caps.uclamp_top_max < ASB_BALANCED_FLOOR_UCLAMP_TOP)
                    _effective_caps.uclamp_top_max = ASB_BALANCED_FLOOR_UCLAMP_TOP;
                asb_rec_apply_offcaps(&_effective_caps, &fsm, metrics.misc.screen_on);   /* fix184 */
                g_last_caps_reassert = time(NULL);
                int writes = writer_apply_caps(&_effective_caps, force_write, fsm.state, fsm.thermal_cap);
                g_writer_floor_pct = 0;
                if (writes > 0) {
                    g_total_writes += writes;
                    g_last_write_ts = time(NULL);
                }

                write_state(&fsm, &metrics, cur_pred);
                
                write_conflicts_json();
                write_learner_state_json(&fsm);

                /* Log the cooldown edges the FSM flagged.
                 *
                 * The clamp only fires on a night that began warm, so it cannot be triggered on
                 * demand - and thermal_cooldown in the state file only ever says what is true right
                 * now. Without these two lines the night capture carries no record of when the clamp
                 * engaged or how long it held, which is exactly what a validation run needs.
                 *
                 * Outside the state-change block: the clamp usually flips while the FSM stays in
                 * DEEP_IDLE, and an edge seen only on a state change was logged late or not at all. */
                /* "clamping to hw minimum" was not what reached the kernel on the OP15: the
                 * writer's race-to-idle floor (40% of hardware max) lifts the clamp, so the
                 * night ceilings read 1555/1862 MHz in capture 2830 with cooldown engaged.
                 * Say what is asked, and that the floor still applies (fix141). */
                if (fsm.cooldown_edge > 0)
                    asb_log("cooldown: enter die=%dC (screen off: ceilings lowered toward the hw minimum, not below the race-to-idle floor)",
                            fsm.cooldown_die_c);
                else if (fsm.cooldown_edge < 0)
                    asb_log("cooldown: exit die=%dC (screen on or cool enough, profile rails restored)",
                            fsm.cooldown_die_c);
                /* Time spent lifted, so a report can tell a short burst from a ceiling that
                 * stayed up (external audit R-6). Boottime: a lift never spans suspend, but
                 * the clock must not run backwards if one did. */
                if (fsm.prime_escape_edge > 0) g_prime_escape_since_ms = asb_clock_ms(CLOCK_BOOTTIME);
                else if (fsm.prime_escape_edge < 0 && g_prime_escape_since_ms > 0) {
                    long _pe_d = asb_clock_ms(CLOCK_BOOTTIME) - g_prime_escape_since_ms;
                    if (_pe_d > 0) g_prime_escape_total_ms += _pe_d;
                    g_prime_escape_since_ms = 0;
                }
                if (fsm.prime_escape_edge > 0)
                    asb_log("prime_escape: lift (%s, big cores pinned at their ceiling%s, die=%dC)",
                            fsm.state == ASB_STATE_MODERATE ? "MODERATE" : "HEAVY",
                            fsm.prime_escape_mid ? ", mid cluster lifted too" : "",
                            metrics.therm.cpu_max_c);
                else if (fsm.prime_escape_edge < 0)
                    asb_log("prime_escape: release (burst spent or conditions gone, die=%dC)",
                            metrics.therm.cpu_max_c);
                if (fsm.state_changed) {
                    g_stat_transitions++;   /* overhead attribution - see write_state */
                    int ma_v = (metrics.bat.current_ma > 0 && !metrics.bat.charging) ? 1 : 0;
                    int fsm_rmax0 = tick_scaling_max(0);
                    int fsm_rmax1 = tick_scaling_max(1);
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
                                /*
                                 * explicit reason for every enter_sustained instead of
                                 * "unknown".
                                 */
                                const char *_sus_reason =
                                    metrics.therm.throttling       ? "thermal" :
                                    metrics.therm.hard_clamp       ? "hard_clamp" :
                                    fsm.perf_hot_guard_active      ? "perf_hot_guard" :
                                    (fsm.thermal_trend >= 6)       ? "thermal_trend" :
                                    (metrics.therm.cpu_max_c >= g_asb_cfg.sustained_temp_enter)
                                                                   ? "thermal_floor" :
                                                                     "other";
                                asb_log("enter_sustained: %s actual_t=%ddegC (thresh=%d) headroom=%d%% soft=%d hard=%d trend=%d hot_guard=%d",
                                        _sus_reason,
                                        metrics.therm.cpu_max_c,
                                        asb_config_profile_sustained_temp_enter(&g_asb_cfg, fsm.profile_idx),
                                        metrics.therm.headroom_pct,
                                        metrics.therm.soft_clamp,
                                        metrics.therm.hard_clamp,
                                        fsm.thermal_trend,
                                        fsm.perf_hot_guard_active);
                            }
                            if (fsm.ses_time_to_first_thermal == 0 && fsm.ses_start_ts > 0)
                                fsm.ses_time_to_first_thermal = time(NULL) - fsm.ses_start_ts;
                            if (fsm.ses_sustained_entries > 1)
                                fsm.ses_recovery_count++;
                        }
                    }
                    if (fsm.prev_state == ASB_STATE_SUSTAINED) {
                        /* sustained_reason=2 set by FSM time-based escape.
                         * When we see it on exit, surface it in the log so the
                         * new mechanism is visible in post-mortem analysis. */
                        /* Against the exit mark this profile really uses (fix181): judged by
                         * the global entry point, an OP12 logged "temp_dropped t=51degC
                         * (exit_thresh=48)" for an exit the screen going off had made. */
                        const char *reason =
                            (fsm.sustained_reason == 2)                                      ? "time_based_escape" :
                            (!metrics.misc.screen_on)                                        ? "screen_off" :
                            (metrics.therm.cpu_max_c <
                             asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm.profile_idx)) ? "temp_dropped" :
                                                                                               "no_longer_heavy";
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
                        asb_log("exit_sustained: %s t=%ddegC (exit_thresh=%d) -> %s cooldown=%ds efficiency=%d/100 repeat=%d",
                                reason, metrics.therm.cpu_max_c,
                                asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm.profile_idx),
                                asb_state_names[fsm.state],
                                g_asb_cfg.gaming_retry_cooldown_s, _eff, fsm.sus_repeat);
                        /* Reset reason so the *next* enter_sustained classifies cleanly */
                        if (fsm.sustained_reason == 2) fsm.sustained_reason = 0;
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
                 || fsm.state == ASB_STATE_SUSTAINED) && !fsm.thermal_cap &&
                /* Smart is an energy/heat profile. Its calculated caps remain applied by the
                 * normal writer, but it must never enter the anti-clamp reassert path that
                 * tries to lift a foreign vendor ceiling. This avoids wasted writes/backoff
                 * during vendor-held light-use caps and preserves anti-clamp for the explicit
                 * Performance/Balanced paths where the user requested performance. */
                fsm.profile_idx != PROFILE_SMART) {
                /* anti-clamp with cadence ladder
                 * Stages: IDLE -> BURST(2s,3 attempts) -> HOLD(4s) -> BACKOFF(30s)
                 * Detection: gap > 500kHz on either cluster + temp < 95 + headroom >= 60%
                 * Backoff: 5 ineffective attempts -> pause 30s */

                int vendor_clamping = 0;
                /* What this path asks for, per slot (fix191): in a manual profile never under
                 * the profile's own ceiling in HEAVY/GAMING, never over it in SUSTAINED. */
                int rtc[3];
                for (int _rs = 0; _rs < 3; _rs++)
                    rtc[_rs] = writer_reassert_target(_rs, fsm.current_caps.cpu_max[_rs], fsm.state);
                if (fsm.plan.ac_eligible && fsm.plan.ac_used < fsm.plan.ac_budget
                    && !g_ac_futile) {
                    time_t now_ac = time(NULL);
                    if (g_ac_stage == AC_STAGE_BACKOFF && now_ac < g_ac_backoff_until) {
                        /* In backoff -- skip */
                    } else {
                        if (g_ac_stage == AC_STAGE_BACKOFF) {
                            g_ac_stage = AC_STAGE_IDLE;
                            g_ac_fails = 0;
                        }
                        int actual_p0 = tick_scaling_max(0);
                        int actual_p1 = tick_scaling_max(1);
                        int desired_p0 = rtc[0];
                        int desired_p1 = rtc[1];
                        int gap0 = (desired_p0 > 0 && actual_p0 > 0) ? desired_p0 - actual_p0 : 0;
                        int gap1 = (desired_p1 > 0 && actual_p1 > 0) ? desired_p1 - actual_p1 : 0;
                        int max_gap = (gap0 > gap1) ? gap0 : gap1;
                        int headroom_ok = (!metrics.therm.headroom_valid || metrics.therm.headroom_pct >= 60);
                        if (max_gap > 500000 && metrics.therm.cpu_max_c < 95 && headroom_ok) {
                            vendor_clamping = 1;
                            if (g_ac_stage == AC_STAGE_IDLE) {
                                /*
                                 * budget counts anti-clamp WINDOWS, not individual writes.
                                 * budget=6 means 6 windows x ~3 writes = ~18 actual
                                 * dual-writes max, spread across the full session instead of
                                 * burning in 90 seconds.
                                 */
                                fsm.plan.ac_used++;
                                int is_last = (fsm.plan.ac_used >= fsm.plan.ac_budget);

                                g_ac_stage = AC_STAGE_BURST;
                                g_ac_burst_count = 0;
                                g_ac_fails = 0;

                                if (is_last) {
                                    asb_log("anti_clamp: last window %d/%d",
                                            fsm.plan.ac_used, fsm.plan.ac_budget);
                                } else if (fsm.plan.ac_prearm) {
                                    asb_log("anti_clamp: prearm -> BURST window %d/%d (streak=%d)",
                                            fsm.plan.ac_used, fsm.plan.ac_budget,
                                            g_pstats_per[PROFILE_PERFORMANCE].cause_streak);
                                }
                            }
                        } else if (g_ac_stage != AC_STAGE_IDLE) {
                            g_ac_stage = AC_STAGE_IDLE;
                            g_ac_burst_count = 0;
                            g_ac_fails = 0;
                        }
                    }
                }
                /* Cadence ladder */
                int reassert_interval;
                if (g_ac_futile) {
                    /* futility fallback -- vendor clamp won, reduce writes.
                     * Double the reassert interval since fighting is pointless. */
                    reassert_interval = (fsm.state == ASB_STATE_GAMING)
                                        ? g_asb_cfg.reassert_gaming_s * 2
                                        : g_asb_cfg.reassert_heavy_s * 2;
                } else if (g_ac_stage == AC_STAGE_BURST)
                    reassert_interval = 2;
                else if (g_ac_stage == AC_STAGE_HOLD)
                    reassert_interval = 4;
                else
                    reassert_interval = (fsm.state == ASB_STATE_GAMING)
                                        ? g_asb_cfg.reassert_gaming_s
                                        : g_asb_cfg.reassert_heavy_s;
                /* action cost economy -- wasted actions slow everything */
                if (g_action_waste >= g_asb_cfg.action_waste_threshold)
                    reassert_interval = reassert_interval * 2;

                time_t now = time(NULL);
                if (now - g_last_reassert >= reassert_interval) {
                    int pre_p0 = 0, pre_p1 = 0;
                    if (vendor_clamping) {
                        pre_p0 = tick_scaling_max(0);
                        pre_p1 = tick_scaling_max(1);
                    }
                    /* Write msm_performance */
                    int ok = msm_perf_write_caps(rtc[0], rtc[1], rtc[2]);
                    /* Anti-clamp: force scaling_max_freq on both clusters */
                    if (vendor_clamping) {
                        for (int ci = 0; ci < 2; ci++) {
                            if (rtc[ci] > 0 &&
                                sysfs_write_int(cpu_policy_path(ci, "scaling_max_freq"),
                                               rtc[ci]) == 0)
                                writer_mark_slot_held(ci, 2);   /* fix183: handed back after HEAVY in Balanced */
                        }
                        /* Evaluate effectiveness on BOTH clusters */
                        int post_p0 = tick_scaling_max(0);
                        int post_p1 = tick_scaling_max(1);
                        int delta0 = (post_p0 > 0 && pre_p0 > 0) ? post_p0 - pre_p0 : 0;
                        int delta1 = (post_p1 > 0 && pre_p1 > 0) ? post_p1 - pre_p1 : 0;
                        int max_delta = (delta0 > delta1) ? delta0 : delta1;
                        if (max_delta < 100000) {
                            g_ac_fails++;
                            if (g_ac_fails >= 5) {
                                g_ac_stage = AC_STAGE_BACKOFF;
                                g_ac_backoff_until = now + 30;
                                g_ac_fails = 0;
                                g_ac_backoff_count++;
                                asb_log("anti_clamp: backoff 30s (5 ineffective, actual=[%d,%d]) backoffs=%d",
                                        post_p0, post_p1, g_ac_backoff_count);
                                g_action_waste++;
                                /* futility suspend -- if 2+ backoffs this session,
                                 * anti-clamp is clearly losing. Stop wasting writes. */
                                if (g_ac_backoff_count >= 2) {
                                    g_ac_futile = 1;
                                    fsm.clamp_hold = 1;
                                    fsm.had_clamp_hold = 1;
                                    fsm.had_futility = 1;
                                    g_clamp_hold_since = time(NULL);
                                    fsm.plan.plan_class = PLAN_CLASS_PERF_CLAMPED;
                                    asb_log("anti_clamp: futility suspend + clamp_hold "
                                            "(2+ backoffs, vendor wins, gap jitter suppressed)");
                                }
                            }
                        } else {
                            g_ac_fails = 0;
                            /* Action Waste Reward -- successful action reduces waste */
                            if (g_action_waste > 0) {
                                g_action_waste -= 2;
                                if (g_action_waste < 0) g_action_waste = 0;
                            }
                        }
                        /* Burst -> Hold transition after 3 burst attempts */
                        if (g_ac_stage == AC_STAGE_BURST) {
                            g_ac_burst_count++;
                            if (g_ac_burst_count >= 3)
                                g_ac_stage = AC_STAGE_HOLD;
                        }
                    }
                    g_last_reassert = now;
                    g_last_reassert_ok = (ok == 0) ? 1 : 0;
                    if (ok == 0 && g_asb_cfg.log_level >= 1) {
                        if (vendor_clamping) {
                            /* Same fix the reassert branch below already carries, applied
                             * here too.
                             *
                             * This printed fsm.current_caps raw - the ratio arithmetic
                             * before the writer snaps it to a step the cluster actually
                             * has. A field log shows
                             * "anti_clamp[burst]: cpu_max=[3551224,2322753]" two lines
                             * above "reassert: cpu_max=[3513600,2227200]", the same moment
                             * reported with and without snapping. The first pair are
                             * frequencies no device has.
                             *
                             * That is not cosmetic here: this line exists to show a VENDOR
                             * clamp, and the reader compares the two columns to judge how
                             * far apart they are. Part of that gap was our own rounding,
                             * so the log overstated the clamp - and I diagnosed exactly
                             * that wrongly once already from this output.
                             *
                             * Both columns now come from the same place: what was asked
                             * for after snapping, against what the device holds.
                             */
                            int _ac_want0 = rtc[0];
                            int _ac_want1 = rtc[1];
                            for (int _ac_i = 0; _ac_i < 2; _ac_i++) {
                                int _ac_slot = -1;
                                for (int _ac_k = 0; _ac_k < g_cpu_all_paths_n && _ac_k < 16; _ac_k++) {
                                    if (g_cpu_all_max_paths[_ac_k][0] && g_cpu_max_paths[_ac_i][0] &&
                                        strcmp(g_cpu_all_max_paths[_ac_k], g_cpu_max_paths[_ac_i]) == 0) {
                                        _ac_slot = _ac_k; break;
                                    }
                                }
                                if (_ac_slot < 0) continue;
                                if (_ac_i == 0 && _ac_want0 > 0)
                                    _ac_want0 = (int)cpu_snap_freq(_ac_slot, (long)_ac_want0);
                                if (_ac_i == 1 && _ac_want1 > 0)
                                    _ac_want1 = (int)cpu_snap_freq(_ac_slot, (long)_ac_want1);
                            }
                            asb_log("anti_clamp[%s]: %s cpu_max=[%d,%d] actual=[%d,%d] hr=%d%% t=%ddegC",
                                    (g_ac_stage == AC_STAGE_BURST) ? "burst" :
                                    (g_ac_stage == AC_STAGE_HOLD) ? "hold" : "?",
                                    asb_state_names[fsm.state],
                                    _ac_want0, _ac_want1,
                                    tick_scaling_max(0),
                                    tick_scaling_max(1),
                                    metrics.therm.headroom_pct, metrics.therm.cpu_max_c);
                        }
                        else
                            /* Log what the CPU will actually hold, not what was asked for.
                             *
                             * This printed fsm.current_caps - the value before the writer
                             * snaps it to a real frequency step. A whole day of logs read
                             * "cpu_max=[2128230,1925001]", numbers no chip has, and I spent
                             * a diagnosis concluding the caps were being written unsnapped
                             * when in fact only the log was wrong. A log that reports an
                             * intention while claiming to report an action is worse than no
                             * log: it sends the next person looking in the wrong place. */
                            asb_log("reassert: %s cpu_max=[%d,%d] t=%ddegC",
                                    asb_state_names[fsm.state],
                                    tick_scaling_max(0),
                                    tick_scaling_max(1),
                                    metrics.therm.cpu_max_c);
                    }
                }
            } else {
                if (fsm.state < ASB_STATE_HEAVY || fsm.thermal_cap) {
                    g_last_reassert = 0;
                    g_msm_boost_active = 0;
                    /* Light reset: stop reasserting but preserve session futility.
                     * Full anti_clamp_reset() would clear g_ac_futile, letting
                     * the module bang the wall again after a momentary load dip. */
                    g_ac_stage = AC_STAGE_IDLE;
                    g_ac_burst_count = 0;
                    g_ac_fails = 0;
                    g_ac_backoff_until = 0;
                }
            }

            /*
             * shell_overridden_up watchdog Anti-clamp above handles vendor DOWN-clamps (gap >
             * 0).
             */
            /* One native foreground owner: Smart screen transitions, the max guard and
             * Battery's short interaction lift (fix234). Other manual profiles retain their
             * baseline without gaining either Smart's sleep cap or Battery's foreground lift. */
            if (fsm.profile_idx != PROFILE_PERFORMANCE)
                writer_fg_guard(metrics.misc.screen_on, fsm.profile_idx == PROFILE_SMART,
                                fsm.profile_idx == PROFILE_BATTERY && g_unlock_lift_now &&
                                    !fsm.thermal_cap && !g_fsm_cooldown_active,
                                asb_unlock_lift_share(fsm.profile_idx));
            if (fsm.profile_idx != PROFILE_PERFORMANCE &&
                (fsm.state == ASB_STATE_DEEP_IDLE || fsm.state == ASB_STATE_LIGHT_IDLE ||
                 fsm.state == ASB_STATE_MODERATE  || fsm.state == ASB_STATE_HEAVY)) {
                int actual_p0 = tick_scaling_max(0);
                int actual_p1 = tick_scaling_max(1);
                /* Compare against what the writer really sends - snapped and lifted to the
                 * race-to-idle floor - the same figure published as desired_cpu_max*. The raw
                 * FSM wish sits under that floor in idle states, so every idle stretch logged
                 * "leak_observed p0=1440000(want 1269183) p1=1747200(want 1374780)": both
                 * "leaks" were ASB's own floor, and the counter grew on a device where
                 * nothing had raised a cap at all. */
                /* Per-slot tables (fix126): on a 1+3+2+1 part slot 1 is not table index 1. */
                int want_p0 = writer_slot_ceiling(0, fsm.current_caps.cpu_max[0], fsm.thermal_cap);
                int want_p1 = writer_slot_ceiling(1, fsm.current_caps.cpu_max[1], fsm.thermal_cap);
                if (g_parity_main_khz > want_p0) want_p0 = g_parity_main_khz;   /* fix130 */
                int req_p0 = g_write_health[ASB_WRITE_CPU_MAX0].requested;
                int req_p1 = g_write_health[ASB_WRITE_CPU_MAX0 + 1].requested;
                /* fix182: in battery/balanced the writer never sends want_p* - the shell
                 * owns the ceiling - so a live value above the FSM's wish was the profile's
                 * own cap: "vendor_ceiling[LIGHT_IDLE/battery]: p0=1785600(want 1555200) -
                 * clock ABOVE our limit" all day on a phone holding exactly the shell's 50 %.
                 * Compare with what the shell wrote; with no record, there is nothing of
                 * ours to compare with, so nothing is counted. */
                const int shell_mode = asb_manual_shell_owns_caps(&fsm);
                if (shell_mode) {
                    want_p0 = asb_shell_cap_khz(&fsm, 0);
                    want_p1 = asb_shell_cap_khz(&fsm, 1);
                    req_p0 = req_p1 = 0;   /* the governor's write cache is not the owner here */
                }
                int k0 = asb_ceiling_over_kind(actual_p0, want_p0, req_p0);
                int k1 = asb_ceiling_over_kind(actual_p1, want_p1, req_p1);
                int leak0 = (k0 == ASB_CEIL_OVER_VENDOR);
                int leak1 = (k1 == ASB_CEIL_OVER_VENDOR);
                if ((k0 == ASB_CEIL_OVER_OWN || k1 == ASB_CEIL_OVER_OWN) && !leak0 && !leak1) g_own_ceiling_ticks++;

                g_leak_streak_p0 = leak0 ? (g_leak_streak_p0 + 1) : 0;
                g_leak_streak_p1 = leak1 ? (g_leak_streak_p1 + 1) : 0;

                /* Did the raised ceiling actually get used? cur_freq is MHz, want is kHz.
                 *
                 * The old line logged every raise as "leak_observed ... reconcile.sh handles"
                 * - neither true (during sleep detente nothing rewrites the cap, by design)
                 * nor useful: a OnePlus 15 night logged the little cluster at 1.79-1.90 GHz
                 * against a 1.44 GHz wish while its clock sat above 1.44 GHz in 3 of 64
                 * screen-off samples. A ceiling nobody climbs to costs nothing, and fighting
                 * the vendor over it is the write war this module already learned to avoid.
                 * What matters is whether the clock went above OUR limit; that is what is
                 * now counted, published and logged. */
                int used0 = leak0 && metrics.cpu.cur_freq[0] > 0 &&
                            (long)metrics.cpu.cur_freq[0] * 1000L > (long)want_p0 + 100000L;
                int used1 = leak1 && metrics.cpu.cur_freq[1] > 0 &&
                            (long)metrics.cpu.cur_freq[1] * 1000L > (long)want_p1 + 100000L;
                if (leak0 || leak1) g_leak_ceiling_ticks++;
                if (used0 || used1) g_leak_used_ticks++;

                /* Reporter, rate-limited to 1/minute. A ceiling raise the clock never used is
                 * debug detail (log_level 3); a clock actually running above our limit is the
                 * case worth a line at the normal level. */
                if (g_leak_streak_p0 == 2 || g_leak_streak_p1 == 2) {
                    time_t leak_now = time(NULL);
                    int _lvl = (used0 || used1) ? 1 : 3;
                    if (g_asb_cfg.log_level >= _lvl && leak_now - g_last_leak_reassert >= 60) {
                        /* What the writer last did on the leaking node (fix125).
                         *
                         * The OP15 fix124 capture has one of these 4 s after a prime_escape lift
                         * and release in the same second: p1 still at 3129600 - the escape's own
                         * rail - against a wish of 1862400, with nothing in the log to say whether
                         * the lowering write was deferred by a backoff or written and read back
                         * higher. The node's status and remaining backoff answer that next time. */
                        const asb_write_health_t *_wh = &g_write_health[leak1 ? ASB_WRITE_CPU_MAX0 + 1
                                                                               : ASB_WRITE_CPU_MAX0];
                        long _wr = (_wh->retry_at > leak_now) ? (long)(_wh->retry_at - leak_now) : 0L;
                        asb_log("vendor_ceiling[%s/%s]: p0=%d(want %d, cur %d MHz) p1=%d(want %d, cur %d MHz) — %s"
                                " [%s cap] (writer p%d: %s, req %d, holds %lu, backoff %lds)",
                                asb_state_names[fsm.state],
                                asb_profile_name(fsm.profile_idx),
                                actual_p0, want_p0, metrics.cpu.cur_freq[0],
                                actual_p1, want_p1, metrics.cpu.cur_freq[1],
                                (used0 || used1) ? "clock ABOVE our limit" : "raised but unused, not contested",
                                shell_mode ? "shell" : "governor",
                                leak1 ? 1 : 0, _wh->status[0] ? _wh->status : "-",
                                _wh->requested, _wh->floor_holds, _wr);
                        g_last_leak_reassert = leak_now;
                        g_leak_reassert_count++;
                    }
                }
            } else {
                /* Reset streaks when we're in gaming/sustained or on perf profile */
                g_leak_streak_p0 = 0;
                g_leak_streak_p1 = 0;
            }

            /* check quarantine expiry (runs each idle tick = 5-10s) */
            if (g_user_quarantine_active) {
                if (user_quarantine_check(&fsm)) {
                    asb_log("user_quarantine: expired, resuming normal policy");
                    session_plan_build(&fsm, metrics.misc.screen_on);
                    session_plan_apply_prearm(&fsm);
                }
            }

            /*
             * Periodic user ID check while the screen is on - every 2 minutes of wall time
             * (fix124). It counted 6 ticks, i.e. every 12-36 s at the 2-6 s screen-on cadence:
             * a fork and exec of `cmd` plus a binder call into the user manager, blocking this
             * loop, a few hundred times per screen-on hour - for a user switch that happens
             * almost never on a phone (and is also caught at every screen-on edge).
             */
            if (metrics.misc.screen_on && !g_user_quarantine_active) {
                static time_t g_user_poll_ts = 0;
                time_t _upn = time(NULL);
                if (g_user_poll_ts == 0) g_user_poll_ts = _upn;
                if (_upn - g_user_poll_ts >= 120 || _upn < g_user_poll_ts) {
                    g_user_poll_ts = _upn;
                    int cur_uid = get_current_user_id();
                    if (cur_uid >= 0 && g_last_user_id >= 0 && cur_uid != g_last_user_id) {
                        asb_log("user_quarantine: user switch %d -> %d (poll), active for %ds",
                                g_last_user_id, cur_uid, USER_QUARANTINE_SEC);
                        g_last_user_id = cur_uid;
                        g_user_quarantine_active = 1;
                        g_user_quarantine_until = time(NULL) + USER_QUARANTINE_SEC;
                        session_plan_build(&fsm, metrics.misc.screen_on);
                    } else if (cur_uid >= 0) {
                        g_last_user_id = cur_uid;
                    }
                }
            }

            /*
             * storm shield -- activate for noisy battery screen-off.
             */
            if (!g_storm_shield_active && fsm_profile_is_battery
                && !metrics.misc.screen_on
                && fsm.bat_wake_cycles >= 5) {
                long ses_age = fsm_elapsed_sec(&fsm);
                int rearm_ok = 1;
                if (g_shield_exit_wakes > 0) {
                    /* After smart exit: need 3+ NEW wakes AND 2min cooldown */
                    int new_wakes = fsm.bat_wake_cycles - g_shield_exit_wakes;
                    if (new_wakes < 3 || time(NULL) < g_shield_rearm_until)
                        rearm_ok = 0;
                }
                /* daytime-mixed gating */
                int daytime_mixed = (fsm.ses_intent == INTENT_MIXED);
                int daytime_gate_ok = 1;
                if (daytime_mixed) {
                    float wph = (ses_age > 0)
                              ? (float)fsm.bat_wake_cycles * 3600.0f / ses_age
                              : 0.0f;
                    if (wph < 12.0f || fsm.bat_wake_cycles < 8 || ses_age < 480)
                        daytime_gate_ok = 0;
                }
                if (ses_age >= 300 && rearm_ok && daytime_gate_ok) {
                    g_storm_shield_active = 1;
                    g_shield_exit_wakes = 0;  /* clear re-arm state on new activation */
                    g_shield_rearm_until = 0;
                    session_plan_build(&fsm, 0);
                    asb_log("storm_shield: activated (wakes=%d age=%lds intent=%d), ultra-light mode",
                            fsm.bat_wake_cycles, ses_age, fsm.ses_intent);
                }
            }
            /* storm shield smart exit -- if noise calmed down for ~10min,
             * exit shield and resume normal battery behavior */
            if (g_storm_shield_active && fsm_profile_is_battery
                && !metrics.misc.screen_on) {
                if (g_shield_last_wakes < 0)
                    g_shield_last_wakes = fsm.bat_wake_cycles;
                if (fsm.bat_wake_cycles == g_shield_last_wakes) {
                    g_shield_calm_ticks++;
                    if (g_shield_calm_ticks >= 60) {  /* ~10min at 10s deep ticks */
                        int exit_wakes = fsm.bat_wake_cycles;
                        storm_shield_reset();
                        /* re-arm hysteresis -- remember exit point */
                        g_shield_exit_wakes = exit_wakes;
                        g_shield_rearm_until = time(NULL) + 120;  /* 2min cooldown */
                        session_plan_build(&fsm, 0);
                        asb_log("storm_shield: exited (noise calmed for ~10min, wakes=%d, rearm after 2min+3 new wakes)",
                                exit_wakes);
                    }
                } else {
                    g_shield_last_wakes = fsm.bat_wake_cycles;
                    g_shield_calm_ticks = 0;
                }
            }

            /* adaptive tick reads from session plan */

            /*
             * clamp recovery probe -- periodically check if vendor clamp lifted.
             * Dual-cluster: both policy0 AND policy6 must be unclamped.
             */
            if (fsm.clamp_hold && metrics.misc.screen_on) {
                /* Counted in TICKS, not seconds.
                 *
                 * The old comment said "~5min", which is true only at the 6 s calm
                 * cadence; at the 2 s busy tick the same 60 ticks are two minutes. The
                 * behaviour is reasonable either way - probing more often while the phone
                 * is busy is what you want - but the number drifts silently whenever a
                 * TIMER_*_S value changes, and a comment that quietly stops being true is
                 * how the next reader gets misled.
                 *
                 * 60 ticks = 2 min busy / 6 min calm / 10 min screen-off. */
                int probe_interval = 60;  /* ticks, not seconds - see above */
                if (g_clamp_hold_since > 0 &&
                    (time(NULL) - g_clamp_hold_since) >= 600)
                    probe_interval = 120;  /* ticks: 4 min busy / 12 min calm */
                /* action cost economy -- more waste = longer between probes */
                if (g_action_waste >= g_asb_cfg.action_waste_threshold)
                    probe_interval = probe_interval * 2;
                if (++g_clamp_probe_skip >= probe_interval) {
                    g_clamp_probe_skip = 0;
                    int probe_p0 = tick_scaling_max(0);
                    int probe_p1 = tick_scaling_max(1);
                    int gap0 = (probe_p0 > 0 && fsm.current_caps.cpu_max[0] > 0)
                               ? fsm.current_caps.cpu_max[0] - probe_p0 : 0;
                    int gap1 = (probe_p1 > 0 && fsm.current_caps.cpu_max[1] > 0)
                               ? fsm.current_caps.cpu_max[1] - probe_p1 : 0;
                    if (gap0 < 0) gap0 = 0;  /* reject transient overshoot */
                    if (gap1 < 0) gap1 = 0;
                    int max_gap = (gap0 > gap1) ? gap0 : gap1;
                    if (max_gap < 500000) {
                        g_probe_good_hits++;
                        if (g_probe_good_hits >= 2) {
                            fsm.clamp_hold = 0;
                            g_ac_futile = 0;
                            g_ac_backoff_count = 0;
                            g_probe_good_hits = 0;
                            g_clamp_probe_skip = 0;
                            g_clamp_hold_since = 0;
                            /* recovery cautious -- don't immediately go full aggressive */
                            fsm.recovery_cautious_until = time(NULL) + 300;
                            session_plan_build(&fsm, metrics.misc.screen_on);
                            session_plan_apply_prearm(&fsm);
                            asb_log("clamp_probe: vendor clamp lifted (gap=%dkHz/%dkHz, 2+ good, waste=%d), plan rebuilt",
                                    gap0 / 1000, gap1 / 1000, g_action_waste);
                            action_waste_reset();
                        } else {
                            asb_log("clamp_probe: gap ok (gap=%dkHz/%dkHz), need %d more confirm",
                                    gap0 / 1000, gap1 / 1000, 2 - g_probe_good_hits);
                        }
                    } else {
                        g_probe_good_hits = 0;
                        g_action_waste++;
                        if (g_asb_cfg.log_level >= 1)
                            asb_log("clamp_probe: still clamped (gap=%dkHz/%dkHz), hold continues",
                                    gap0 / 1000, gap1 / 1000);
                    }
                }
            }
            {
                static int g_idle_interval = TIMER_IDLE_S;
                int want = fsm.plan.deep_sleep ? TIMER_DEEP_S
                         : fsm.plan.idle_noisy_slow ? TIMER_IDLE_NOISY_S
                         : TIMER_IDLE_S;
                /* Quiet Night Baseline -- even longer ticks in ultra-quiet */
                if (g_quiet_night_active) want = g_asb_cfg.quiet_tick_s;
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
    /* Bank the session in flight before the store is written.
     *
     * Everything measured since the last bank lived in memory only: drain accumulated
     * over the window, max temperature, time in heavy states. A restart threw it away,
     * and a restart is cheap to cause - saving anything in the WebUI reloads the config
     * and brings the governor back up, so an evening of adjusting settings could discard
     * one session after another and the learner would see almost nothing from it.
     *
     * The same 20-minute floor the periodic path uses applies here: shorter than that and
     * the drain figure is noise, which is exactly what should not be learned from.
     *
     * One call, not two (fix167). An unconditional "shutdown" append ran first and banked
     * the session into Smart's bucket, then the 20-minute block banked the same session a
     * second time - and a Smart session under 20 minutes, the noise that floor exists to keep
     * out, went in through the first call anyway. Without Smart the history line is written
     * as before. */
    {
        int _smart_bank = g_smart_store_loaded && g_smart_rt.enabled;
        int _ses_long = fsm.ses_start_ts > 0 && (long)(time(NULL) - fsm.ses_start_ts) >= 1200;
        if (!_smart_bank || _ses_long) {
            session_history_append_ex(&fsm, "shutdown");
            if (_smart_bank) asb_log("smart: session banked on shutdown");
        }
    }
    asb_night_window_save();
    /* Flush what Smart learned before we go.
     *
     * The store is written on a 5-minute timer and nothing wrote it on shutdown, so every
     * restart threw away up to five minutes of learning - and a phone rebooted often
     * enough could stay near zero indefinitely. A user reported exactly that: "does smart
     * mode lose its memory when I restart". Everything else in this block persists on the
     * way out; the learner was the one thing that did not.
     */
    if (g_smart_store_loaded) {
        g_smart_store.last_update_ts = (uint32_t)time(NULL);
        if (asb_smart_store_save_atomic(&g_smart_store, ASB_SMART_STORE_FILE) == 0)
            asb_log("smart store flushed on shutdown");
        asb_smart_appheat_save();
    }
    /* fix184: the records and night wakes, which save at most every 15 minutes otherwise. */
    if (g_rec_loaded && g_rec_dirty && asb_rec_save() == 0) asb_log("smart records flushed on shutdown");
    asb_log("persistent stats saved: sessions=%d degrade=%d", g_pstats.session_count, g_pstats.degrade_count);
    unlink(ASB_SOCK_PATH);
    unlink(PID_FILE);
    asb_log_critical("asb_governor stopped cleanly (pid %d)", getpid());
    if (g_logf) fclose(g_logf);
    return 0;
}
