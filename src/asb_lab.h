#pragma once
/*
 * Smart lab (V66 dev8) - more settings that Smart tries for itself, one at a time, and keeps
 * only when the phone measured them cheaper.
 *
 * The Smart records (asb_record.h) learn two things: the screen-off CPU ceilings and the
 * screen-on lean of six situations. Everything else that decides the drain was still a fixed
 * rule: whether light traffic goes to LTE, how far a wake lifts the clocks, the memory bus,
 * and the lean of the few apps that take most of the screen-on time (one OnePlus 15 day:
 * two feed apps 69 % of it). The lab runs the same kind of experiment for each of those:
 *
 *  - radio        5G only when needed (LTE on light traffic) against 5G allowed, on mobile
 *                 data with the screen on - the modem's draw is not readable, the battery's is;
 *  - wake_lift    the unlock lift at the configured share against 15 points less, over
 *                 glances (screen-on stretches of 90 s or less), with SystemUI's frames;
 *  - membus_on    the CPU-side memory-bus votes uncapped, at 75 % or at 55 % of the bus
 *                 maximum, only while the screen is calm (no touch for 10 s, no lift, no burst,
 *                 nothing heavy, no camera);
 *  - membus_off   the same votes uncapped, at 50 % or at the lowest step, on quiet deep idle;
 *  - app1..app3   the three apps that cost the most with the screen on, each with its own
 *                 lean: the situation's best, 0.1 toward economy, 0.1 toward headroom.
 *
 * How a setting wins - the records' rules, so the two agree:
 *  - blocks alternate the best setting so far and one challenger; each challenger block is
 *    compared with the champion block next to it, within 4 hours (12 for glances), 2.5 C of
 *    battery temperature and 25 points of charge, the same screen brightness band, and for
 *    the radio a mobile traffic volume within a factor of two;
 *  - it takes over when the pairs say it is at least 3 % cheaper with t >= 2.5 AND it does
 *    not make the cores sit at their ceiling more often (+8 points), the frames jankier (+1
 *    point where they are counted) or the battery warm faster (+1.5 C an hour); a challenger
 *    15 % dearer after three pairs is dropped; no verdict after 16 pairs (12 screen off) is a
 *    loss - the champion stays;
 *  - one screen-on experiment runs at a time, and none while the records are still trying a
 *    setting for the same situation: two experiments at once would each blur the other. An app
 *    the lab learns is left out of the records' situations altogether.
 *
 * Dynamics, not a snapshot. A verdict is not the end: the champion keeps being measured in
 * the blocks no experiment needs. If its cost rises 15 % above what it cost when it won, four
 * blocks running (an app update, a ROM update, a new network), the knob is tested again at
 * once instead of waiting for the 21-day re-check; if it falls, the reference follows it down.
 *
 * Pure logic with swappable readers (charge counter, frame counters, the bus nodes) for the
 * tests. The governor feeds one tick, the glances and the top apps, and reads the knobs back.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>

#ifndef ASB_LAB_FILE
#define ASB_LAB_FILE        "/data/adb/asb/smart_lab.bin"
#endif
#ifndef ASB_LAB_SUMMARY
#define ASB_LAB_SUMMARY     "/dev/.asb/smart_lab.txt"
#endif
#ifndef ASB_LAB_RADIO_FILE
#define ASB_LAB_RADIO_FILE  "/dev/.asb/lab_radio"
#endif
#ifndef ASB_MEM_ROOT
#define ASB_MEM_ROOT        "/sys/devices/system/cpu/bus_dcvs"
#endif
#ifndef ASB_MEM_DEVFREQ
#define ASB_MEM_DEVFREQ     "/sys/class/devfreq"
#endif
#define ASB_LAB_MAGIC       0x4153424cu
#define ASB_LAB_VERSION     2

enum { LAB_RADIO = 0, LAB_LIFT, LAB_MEM_ON, LAB_MEM_OFF, LAB_APP0, LAB_APP1, LAB_APP2, LAB_N };
static const char *const g_lab_names[LAB_N] = {
    "radio", "wake_lift", "membus_on", "membus_off", "app1", "app2", "app3"
};
#define LAB_APPS 3

#define ASB_LAB_ON_BLOCK_S      600
#define ASB_LAB_ON_MIN_S        180
#define ASB_LAB_RADIO_MIN_S     240
#define ASB_LAB_APP_BLOCK_S     300
#define ASB_LAB_APP_MIN_S       120
#define ASB_LAB_OFF_BLOCK_S     2400
#define ASB_LAB_OFF_MIN_S       1200
#define ASB_LAB_GLANCE_S        90
#define ASB_LAB_LIFT_GLANCES    6
#define ASB_LAB_LIFT_MIN_GL     3
#define ASB_LAB_LIFT_MAX_S      (4L * 3600)
#define ASB_LAB_LIFT_DROP_S     (24L * 3600)
#define ASB_LAB_GAIN_MIN        0.03
#define ASB_LAB_T2              6.25
#define ASB_LAB_DEARER          0.15
#define ASB_LAB_PRESS_SLACK     0.08
#define ASB_LAB_JANK_SLACK      0.01
#define ASB_LAB_HEAT_SLACK      15.0     /* tenths of a degree per hour */
#define ASB_LAB_JANK_STOP       0.02     /* early stop: the challenger is clearly worse to use */
#define ASB_LAB_PRESS_STOP      0.15
#define ASB_LAB_HEAT_STOP       30.0
#define ASB_LAB_PAIR_DT_S       (4L * 3600)
#define ASB_LAB_PAIR_DT_LIFT_S  (12L * 3600)
#define ASB_LAB_PAIR_TEMP_DC    25
#define ASB_LAB_PAIR_SOC        25
#define ASB_LAB_CLIMATE_DC      30
#define ASB_LAB_RECHECK_S       (21L * 24 * 3600)
#define ASB_LAB_DRIFT           0.15f
#define ASB_LAB_DRIFT_N         4
#define ASB_LAB_SAVE_EVERY_S    900
#define ASB_LAB_APP_STALE_S     (14L * 24 * 3600)
#define ASB_LAB_JANK_WAIT_S     120
#define ASB_LAB_JANK_MIN_FRAMES 200
#define ASB_LAB_SETTLE_S        1200
#define ASB_LAB_TICK_MAX_MS     30000LL

typedef struct {
    uint32_t ts;            /* when the block ended; 0 = none or already paired */
    int16_t  temp_dc;
    uint8_t  soc;
    int8_t   band;          /* brightness band, -1 not used */
    float    mw;
    float    press;         /* share of ticks with a cluster at its ceiling */
    float    jank;          /* janky share of the counted frames, -1 not counted */
    float    heat;          /* battery warming, tenths of a degree per hour */
    float    traffic;       /* mobile KiB/s, -1 not used */
} asb_lab_last_t;

typedef struct {
    uint64_t key;           /* app slots: the app's hash */
    char     pkg[48];       /* app slots: the package, for its frame counters */
    uint8_t  champion, challenger, converged, alt;
    uint8_t  tried, fails, pad0, pad1;
    uint32_t trials, wins, pairs, blocks, conv_ts, last_ts, reopen, jank_pairs;
    double   pr_mean, pr_m2, pr_press, pr_jank, pr_heat;
    asb_lab_last_t last[2];
    float    gain, ref_mw, ewma_mw, champ_sum, chal_sum;
    uint32_t champ_n, chal_n;
    uint16_t drift_n, pad2;
} asb_lab_knob_t;

typedef struct {
    uint32_t magic, version, size, pad;
    asb_lab_knob_t k[LAB_N];
    uint32_t wins_total, reopen_total;
} asb_lab_store_t;

typedef struct {
    int       active, knob, slot, arm, need_jank;
    long long t0_ms, last_ms;
    long      wall0;
    double    j, s;
    long      cc0;
    long long v_sum;
    int       v_n;
    int       t0_dc, tlast_dc, tmin_dc, tmax_dc, soc0, band;
    int       ticks, ticks_press, ticks_busy;
    long long net0;
    long      fr0, jk0, fr_req;
    char      pkg[48];
    int       glances;
} asb_lab_blk_t;

typedef struct {
    int       enabled;          /* Smart running and smart_lab=1 */
    int       explore;          /* smart_records_explore=1: challengers are tried */
    int       screen_on, charging, soc, bat_temp_dc, voltage_uv;
    int       ma;               /* battery discharge, mA on the real scale, 0 unknown */
    int       at_ceiling;
    int       calm;             /* screen on and nothing asks for the bus (see the knob) */
    int       idle_quiet;       /* screen off: quiet deep idle */
    int       idle_busy;        /* screen off: this tick was not quiet */
    int       on_mobile;        /* mobile data is the route */
    long long mobile_bytes;     /* cumulative mobile rx+tx, -1 unknown */
    int       radio_ok;         /* the light-traffic watcher is on and can act */
    int       mem_ok;           /* lab memory-bus control allowed (smart_lab_mem=1) */
    int       rec_on_busy;      /* the records try a setting for this screen-on situation now */
    int       rec_off_busy;     /* ... for this screen-off situation */
    int       bright_band;
    int       thermal_cap, cooldown, veto, lowbat, heavy, smooth_testing;
    long      unplug_age_s;
    uint64_t  app_hash;
    const char *app_pkg;
    int       app_base_x1000;   /* the situation's best lean, for the app slots */
    int       lift_cfg_pct;
    long long now_ms;
    long      wall;
} asb_lab_in_t;

/* Outputs, read by the governor after each tick. */
static int   g_lab_radio_arm    = 0;   /* 1 = 5G allowed (the light watcher keeps away) */
static int   g_lab_lift_pct     = 0;   /* 0 = the configured share */
static int   g_lab_mem_on_pct   = 0;   /* 0 none, else % of the bus maximum */
static int   g_lab_mem_off_pct  = 0;   /* 0 none, -1 the lowest step, else % */
static int   g_lab_app_offset   = 0;   /* x1000, the lean of the lab app in front */
static int   g_lab_app_front    = 0;   /* 1 = a lab app is in front: the records step aside */
static int   g_lab_event        = 0;
static char  g_lab_event_msg[200];

static asb_lab_store_t g_lab;
static int   g_lab_loaded = 0, g_lab_dirty = 0;
static long  g_lab_saved_ts = 0;
static asb_lab_blk_t g_lab_on, g_lab_off, g_lab_lift;
static int   g_lab_prev_on = -1;
static unsigned long g_lab_blocks_kept = 0, g_lab_blocks_short = 0, g_lab_blocks_rejected = 0;
static int   g_lab_radio_written = -1;

static long  (*g_lab_read_cc)(void) = NULL;
static long long (*g_lab_read_net)(void) = NULL;
#define ASB_LAB_NET_KIBPS_MAX 15     /* screen off: the records' rule - above it the radio, not the bus, sets the drain */
static unsigned long g_lab_blocks_radio = 0;
static unsigned long g_lab_early_stops = 0;
static void  (*g_lab_gfx_ask)(const char *pkg) = NULL;
static int   (*g_lab_gfx_read)(const char *pkg, long since, long *frames, long *janky) = NULL;

/* A block that waits for its closing frame count. */
static asb_lab_last_t g_lab_pend;
static int   g_lab_pend_k = -1, g_lab_pend_slot = 0, g_lab_pend_arm = 0;
static long  g_lab_pend_ts = 0, g_lab_pend_fr0 = -1, g_lab_pend_jk0 = -1;
static char  g_lab_pend_pkg[48];

static const int g_lab_mem_on_arm[3]  = { 0, 75, 55 };
static const int g_lab_mem_off_arm[3] = { 0, 50, -1 };
static const int g_lab_app_arm[3]     = { 0, 100, -100 };

static int asb_lab_narms(int k) { return (k == LAB_RADIO || k == LAB_LIFT) ? 2 : 3; }
static int asb_lab_is_app(int k) { return k >= LAB_APP0 && k < LAB_APP0 + LAB_APPS; }

static int asb_lab_lift_value(int arm, int cfg) {
    if (cfg < 50) cfg = 50;
    if (cfg > 100) cfg = 100;
    if (arm == 0) return cfg;
    int v = cfg - 15;
    return v < 50 ? 50 : v;
}

static const char *asb_lab_arm_name(int k, int arm) {
    static char buf[24];
    switch (k) {
    case LAB_RADIO: return arm ? "5G allowed" : "LTE on light traffic";
    case LAB_LIFT:  return arm ? "lift -15" : "lift as set";
    case LAB_MEM_ON:
        if (!arm) return "bus free";
        snprintf(buf, sizeof(buf), "bus %d%%", g_lab_mem_on_arm[arm]);
        return buf;
    case LAB_MEM_OFF:
        if (!arm) return "bus free";
        if (g_lab_mem_off_arm[arm] < 0) return "bus lowest";
        snprintf(buf, sizeof(buf), "bus %d%%", g_lab_mem_off_arm[arm]);
        return buf;
    default:
        return arm == 1 ? "lean +0.1" : (arm == 2 ? "lean -0.1" : "lean as situation");
    }
}

/* The next setting to try from this champion, or -1: none left (a plateau). The bus caps
 * go one step further only after the softer step won; the app lean tries economy first,
 * then headroom. */
static int asb_lab_next(const asb_lab_knob_t *kn, int k) {
    int c = kn->champion, t = kn->tried;
    if (k == LAB_MEM_ON || k == LAB_MEM_OFF) {
        if (c < 2 && !(t & (1 << (c + 1)))) return c + 1;
        return -1;
    }
    if (asb_lab_is_app(k)) {
        if (c != 0) return -1;
        if (!(t & 2)) return 1;
        if (!(t & 4)) return 2;
        return -1;
    }
    int o = 1 - c;
    return (t & (1 << o)) ? -1 : o;
}

static void asb_lab_trial_reset(asb_lab_knob_t *kn) {
    kn->pairs = 0; kn->jank_pairs = 0;
    kn->pr_mean = kn->pr_m2 = kn->pr_press = kn->pr_jank = kn->pr_heat = 0.0;
    memset(kn->last, 0, sizeof(kn->last));
    kn->alt = 1;
    kn->champ_sum = 0.0f; kn->champ_n = 0;
    kn->chal_sum = 0.0f; kn->chal_n = 0;
}

static void asb_lab_converge(asb_lab_knob_t *kn, long wall) {
    kn->converged = 1;
    kn->challenger = kn->champion;
    kn->conv_ts = (uint32_t)wall;
    if (kn->champ_n > 0) kn->ref_mw = kn->champ_sum / (float)kn->champ_n;
    else if (kn->ewma_mw > 0.0f) kn->ref_mw = kn->ewma_mw;
    kn->drift_n = 0;
    g_lab_dirty = 1;
}

static void asb_lab_reopen(asb_lab_knob_t *kn) {
    kn->converged = 0;
    kn->tried = (uint8_t)(1u << kn->champion);
    kn->challenger = kn->champion;
    kn->fails = 0;
    kn->drift_n = 0;
    g_lab_dirty = 1;
}

/* At the start of every block: begin a trial if there is something left to try. */
static void asb_lab_setup(int k, int explore, long wall) {
    asb_lab_knob_t *kn = &g_lab.k[k];
    if (kn->converged) {
        if (wall - (long)kn->conv_ts < ASB_LAB_RECHECK_S) return;
        asb_lab_reopen(kn);
    }
    if (!explore) { kn->challenger = kn->champion; return; }
    if (kn->challenger != kn->champion) return;
    int nx = asb_lab_next(kn, k);
    if (nx < 0) { asb_lab_converge(kn, wall); return; }
    kn->challenger = (uint8_t)nx;
    kn->trials++;
    asb_lab_trial_reset(kn);
    g_lab_dirty = 1;
}

/* A verdict changes what the knob runs: a block of it still under way was set up for the
 * trial that just ended, and it is dropped so the new best setting applies at once. */
static void asb_lab_drop_blocks(int k) {
    asb_lab_blk_t *bs[3] = { &g_lab_on, &g_lab_off, &g_lab_lift };
    for (int i = 0; i < 3; i++) if (bs[i]->active && bs[i]->knob == k) { bs[i]->active = 0; g_lab_blocks_short++; }
}

static void asb_lab_lose(int k, const char *why, long wall) {
    asb_lab_knob_t *kn = &g_lab.k[k];
    char a[24];
    snprintf(a, sizeof(a), "%s", asb_lab_arm_name(k, kn->challenger));
    snprintf(g_lab_event_msg, sizeof(g_lab_event_msg), "lab: %s - %s not better (%s) after %u pair(s), kept %s",
             g_lab_names[k], a, why, kn->pairs, asb_lab_arm_name(k, kn->champion));
    g_lab_event = 1;
    kn->tried = (uint8_t)(kn->tried | (1u << kn->challenger));
    kn->fails++;
    kn->challenger = kn->champion;
    if (asb_lab_next(kn, k) < 0) asb_lab_converge(kn, wall);
    asb_lab_drop_blocks(k);
    g_lab_dirty = 1;
    g_lab_saved_ts = 0;
}

static void asb_lab_win(int k, long wall) {
    asb_lab_knob_t *kn = &g_lab.k[k];
    int old = kn->champion;
    char a[24];
    snprintf(a, sizeof(a), "%s", asb_lab_arm_name(k, kn->challenger));
    kn->gain = (float)(-kn->pr_mean);
    snprintf(g_lab_event_msg, sizeof(g_lab_event_msg), "lab: %s - %s beat %s by %.1f %% over %u pair(s)",
             g_lab_names[k], a, asb_lab_arm_name(k, old), -kn->pr_mean * 100.0, kn->pairs);
    g_lab_event = 1;
    kn->wins++;
    g_lab.wins_total++;
    kn->champion = kn->challenger;
    kn->tried = (uint8_t)(kn->tried | (1u << kn->champion));
    kn->ewma_mw = kn->chal_n ? kn->chal_sum / (float)kn->chal_n : 0.0f;
    kn->champ_sum = kn->chal_sum; kn->champ_n = kn->chal_n;
    kn->chal_sum = 0.0f; kn->chal_n = 0;
    if (asb_lab_next(kn, k) < 0) asb_lab_converge(kn, wall);
    asb_lab_drop_blocks(k);
    g_lab_dirty = 1;
    g_lab_saved_ts = 0;
}

static void asb_lab_verdict(int k, long wall) {
    asb_lab_knob_t *kn = &g_lab.k[k];
    unsigned n = kn->pairs;
    double mean = kn->pr_mean;
    int off = (k == LAB_MEM_OFF);
    unsigned nmin = off ? 5u : 6u, nmax = off ? 12u : 16u;
    if (k == LAB_LIFT) { nmin = 5u; nmax = 14u; }
    if (n >= 3 && mean >= ASB_LAB_DEARER) { asb_lab_lose(k, "dearer", wall); return; }
    /* A challenger that is plainly worse to use is not run to the full count: these stops
     * cost at most two or three blocks of it, the guards below would cost up to nmax. */
    if (kn->jank_pairs >= 2 && kn->pr_jank / (double)kn->jank_pairs >= ASB_LAB_JANK_STOP) {
        g_lab_early_stops++; asb_lab_lose(k, "more janky frames", wall); return;
    }
    if (n >= 3 && kn->pr_press / (double)n >= ASB_LAB_PRESS_STOP) {
        g_lab_early_stops++; asb_lab_lose(k, "cores at their ceiling more often", wall); return;
    }
    if (n >= 3 && !off && k != LAB_LIFT && kn->pr_heat / (double)n >= ASB_LAB_HEAT_STOP) {
        g_lab_early_stops++; asb_lab_lose(k, "warms faster", wall); return;
    }
    if (n < nmin) return;
    double var = (n > 1) ? kn->pr_m2 / (double)(n - 1) : 0.0;
    double t2 = (var > 0.0) ? mean * mean * (double)n / var : (mean != 0.0 ? 1e9 : 0.0);
    int press_ok = (kn->pr_press / (double)n) <= ASB_LAB_PRESS_SLACK;
    int jank_ok  = kn->jank_pairs == 0 || (kn->pr_jank / (double)kn->jank_pairs) <= ASB_LAB_JANK_SLACK;
    int heat_ok  = off || k == LAB_LIFT || (kn->pr_heat / (double)n) <= ASB_LAB_HEAT_SLACK;
    if (mean <= -ASB_LAB_GAIN_MIN && t2 >= ASB_LAB_T2) {
        if (press_ok && jank_ok && heat_ok) asb_lab_win(k, wall);
        else asb_lab_lose(k, !press_ok ? "cores at their ceiling more often" :
                             (!jank_ok ? "more janky frames" : "warms faster"), wall);
        return;
    }
    if (n >= nmax) asb_lab_lose(k, "no clear saving", wall);
}

/* The champion keeps being measured after a verdict: a cost that climbs away from it tests
 * the knob again at once. */
static void asb_lab_dynamics(int k, float mw) {
    asb_lab_knob_t *kn = &g_lab.k[k];
    if (mw <= 0.0f) return;
    kn->ewma_mw = (kn->ewma_mw > 0.0f) ? 0.7f * kn->ewma_mw + 0.3f * mw : mw;
    if (!kn->converged) { kn->champ_sum += mw; kn->champ_n++; return; }
    if (kn->ref_mw <= 0.0f) { kn->ref_mw = kn->ewma_mw; return; }
    if (mw > kn->ref_mw * (1.0f + ASB_LAB_DRIFT)) {
        if (++kn->drift_n >= ASB_LAB_DRIFT_N) {
            snprintf(g_lab_event_msg, sizeof(g_lab_event_msg),
                     "lab: %s - the best setting costs %.0f %% more than when it won, testing again",
                     g_lab_names[k], (double)((kn->ewma_mw / kn->ref_mw - 1.0f) * 100.0f));
            g_lab_event = 1;
            kn->reopen++;
            g_lab.reopen_total++;
            asb_lab_reopen(kn);
            g_lab_saved_ts = 0;
        }
    } else {
        kn->drift_n = 0;
        if (kn->ewma_mw < kn->ref_mw * 0.85f) kn->ref_mw = kn->ewma_mw;
    }
}

static int asb_lab_pairable(int k, const asb_lab_last_t *a, const asb_lab_last_t *b) {
    long dt = (long)a->ts - (long)b->ts;
    if (dt < 0) dt = -dt;
    if (dt > (k == LAB_LIFT ? ASB_LAB_PAIR_DT_LIFT_S : ASB_LAB_PAIR_DT_S)) return 0;
    int dtemp = a->temp_dc - b->temp_dc;
    if (dtemp < 0) dtemp = -dtemp;
    if (dtemp > ASB_LAB_PAIR_TEMP_DC) return 0;
    int dsoc = (int)a->soc - (int)b->soc;
    if (dsoc < 0) dsoc = -dsoc;
    if (dsoc > ASB_LAB_PAIR_SOC) return 0;
    if (a->band != b->band) return 0;
    if (a->traffic >= 0.0f && b->traffic >= 0.0f) {
        float lo = a->traffic < b->traffic ? a->traffic : b->traffic;
        float hi = a->traffic < b->traffic ? b->traffic : a->traffic;
        if (hi > 2.0f && hi > lo * 2.0f) return 0;
    }
    return 1;
}

static void asb_lab_sample(int k, int slot, int arm, const asb_lab_last_t *s, long wall) {
    asb_lab_knob_t *kn = &g_lab.k[k];
    if (arm != (slot ? kn->challenger : kn->champion)) { g_lab_blocks_short++; return; }
    kn->blocks++;
    kn->last_ts = (uint32_t)wall;
    g_lab_blocks_kept++;
    g_lab_dirty = 1;
    if (slot == 0) asb_lab_dynamics(k, s->mw);
    else if (s->mw > 0.0f) { kn->chal_sum += s->mw; kn->chal_n++; }
    if (kn->challenger == kn->champion) return;
    kn->last[slot] = *s;
    kn->alt = (uint8_t)(1 - slot);
    asb_lab_last_t *o = &kn->last[1 - slot];
    if (!o->ts) return;
    if (!asb_lab_pairable(k, s, o)) {
        if ((long)s->ts - (long)o->ts > (k == LAB_LIFT ? ASB_LAB_PAIR_DT_LIFT_S : ASB_LAB_PAIR_DT_S)) o->ts = 0;
        return;
    }
    const asb_lab_last_t *a = slot ? o : s;
    const asb_lab_last_t *b = slot ? s : o;
    if (a->mw <= 0.0f) return;
    double d = ((double)b->mw - (double)a->mw) / (double)a->mw;
    kn->pairs++;
    double delta = d - kn->pr_mean;
    kn->pr_mean += delta / (double)kn->pairs;
    kn->pr_m2 += delta * (d - kn->pr_mean);
    kn->pr_press += (double)(b->press - a->press);
    kn->pr_heat += (double)(b->heat - a->heat);
    if (a->jank >= 0.0f && b->jank >= 0.0f) { kn->pr_jank += (double)(b->jank - a->jank); kn->jank_pairs++; }
    kn->last[0].ts = kn->last[1].ts = 0;
    asb_lab_verdict(k, wall);
}

/* ---- frames: one reading at the start of a block, one at its end ----------------------- */
static void asb_lab_pend_flush(float jank) {
    if (g_lab_pend_k < 0) return;
    g_lab_pend.jank = jank;
    int k = g_lab_pend_k;
    g_lab_pend_k = -1;
    asb_lab_sample(k, g_lab_pend_slot, g_lab_pend_arm, &g_lab_pend, (long)g_lab_pend.ts);
}

static void asb_lab_frames_poll(long wall) {
    long fr = -1, jk = -1;
    if (g_lab_pend_k >= 0) {
        if (g_lab_gfx_read && g_lab_gfx_read(g_lab_pend_pkg, g_lab_pend_ts, &fr, &jk) == 0) {
            float jank = -1.0f;
            if (g_lab_pend_fr0 >= 0 && fr - g_lab_pend_fr0 >= ASB_LAB_JANK_MIN_FRAMES && jk >= g_lab_pend_jk0)
                jank = (float)((double)(jk - g_lab_pend_jk0) / (double)(fr - g_lab_pend_fr0));
            asb_lab_blk_t *nb[2] = { &g_lab_on, &g_lab_lift };
            for (int i = 0; i < 2; i++)
                if (nb[i]->active && nb[i]->need_jank && nb[i]->fr0 < 0 && !strcmp(nb[i]->pkg, g_lab_pend_pkg)) {
                    nb[i]->fr0 = fr; nb[i]->jk0 = jk;
                }
            asb_lab_pend_flush(jank);
        } else if (wall - g_lab_pend_ts >= ASB_LAB_JANK_WAIT_S || wall < g_lab_pend_ts) {
            asb_lab_pend_flush(-1.0f);
        }
    }
    asb_lab_blk_t *bs[2] = { &g_lab_on, &g_lab_lift };
    for (int i = 0; i < 2; i++) {
        asb_lab_blk_t *b = bs[i];
        if (!b->active || !b->need_jank || b->fr0 >= 0 || !g_lab_gfx_read) continue;
        if (g_lab_gfx_read(b->pkg, b->fr_req, &fr, &jk) == 0) { b->fr0 = fr; b->jk0 = jk; }
    }
}

/* ---- blocks ---------------------------------------------------------------------------- */
static void asb_lab_blk_begin(asb_lab_blk_t *b, int k, const asb_lab_in_t *in, const char *pkg) {
    asb_lab_setup(k, in->explore, in->wall);
    asb_lab_knob_t *kn = &g_lab.k[k];
    memset(b, 0, sizeof(*b));
    b->active = 1;
    b->knob = k;
    b->slot = (kn->challenger != kn->champion) ? kn->alt : 0;
    b->arm = b->slot ? kn->challenger : kn->champion;
    b->t0_ms = b->last_ms = in->now_ms;
    b->wall0 = in->wall;
    b->t0_dc = b->tlast_dc = b->tmin_dc = b->tmax_dc = in->bat_temp_dc;
    b->soc0 = in->soc;
    b->band = (k == LAB_RADIO || k == LAB_MEM_ON || asb_lab_is_app(k)) ? in->bright_band : -1;
    b->net0 = (k == LAB_RADIO) ? in->mobile_bytes : ((k == LAB_MEM_OFF && g_lab_read_net) ? g_lab_read_net() : -1);
    b->cc0 = (k == LAB_MEM_OFF && g_lab_read_cc) ? g_lab_read_cc() : -1;
    b->fr0 = b->jk0 = -1;
    if (pkg && *pkg) {
        snprintf(b->pkg, sizeof(b->pkg), "%s", pkg);
        b->need_jank = 1;
        b->fr_req = in->wall;
        if (g_lab_gfx_ask) g_lab_gfx_ask(b->pkg);
    }
}

static void asb_lab_blk_track(asb_lab_blk_t *b, const asb_lab_in_t *in) {
    long long dt = in->now_ms - b->last_ms;
    b->last_ms = in->now_ms;
    b->ticks++;
    if (in->bat_temp_dc < b->tmin_dc) b->tmin_dc = in->bat_temp_dc;
    if (in->bat_temp_dc > b->tmax_dc) b->tmax_dc = in->bat_temp_dc;
    b->tlast_dc = in->bat_temp_dc;
    if (in->voltage_uv > 3000000 && in->voltage_uv < 4800000) { b->v_sum += in->voltage_uv; b->v_n++; }
    if (b->knob == LAB_MEM_OFF) { if (in->idle_busy) b->ticks_busy++; return; }
    if (in->at_ceiling) b->ticks_press++;
    if (dt > 0 && dt <= ASB_LAB_TICK_MAX_MS && in->ma > 0 && in->ma < 8000 &&
        in->voltage_uv > 3000000 && in->voltage_uv < 4800000) {
        double sec = (double)dt / 1000.0;
        b->j += (double)in->ma * ((double)in->voltage_uv / 1e6) * sec / 1000.0;
        b->s += sec;
    }
}

static void asb_lab_blk_end(asb_lab_blk_t *b, const asb_lab_in_t *in) {
    if (!b->active) return;
    b->active = 0;
    int k = b->knob;
    long dur = (long)((in->now_ms - b->t0_ms) / 1000);
    long min_s = (k == LAB_MEM_OFF) ? ASB_LAB_OFF_MIN_S :
                 (asb_lab_is_app(k) ? ASB_LAB_APP_MIN_S : (k == LAB_RADIO ? ASB_LAB_RADIO_MIN_S : ASB_LAB_ON_MIN_S));
    if (dur < min_s) { g_lab_blocks_short++; return; }
    asb_lab_last_t s;
    memset(&s, 0, sizeof(s));
    s.ts = (uint32_t)in->wall;
    s.temp_dc = (int16_t)b->t0_dc;
    s.soc = (uint8_t)(b->soc0 < 0 ? 0 : (b->soc0 > 100 ? 100 : b->soc0));
    s.band = (int8_t)b->band;
    s.jank = -1.0f;
    s.traffic = -1.0f;
    if (b->tmax_dc - b->tmin_dc > ASB_LAB_CLIMATE_DC) { g_lab_blocks_rejected++; return; }
    if (k == LAB_MEM_OFF) {
        long cc1 = g_lab_read_cc ? g_lab_read_cc() : -1;
        if (b->cc0 <= 0 || cc1 <= 0 || cc1 >= b->cc0 || b->v_n == 0) { g_lab_blocks_rejected++; return; }
        if (b->ticks >= 4 && b->ticks_busy * 4 > b->ticks) { g_lab_blocks_rejected++; return; }
        if (b->net0 >= 0 && g_lab_read_net) {
            long long n1 = g_lab_read_net();
            if (n1 >= b->net0 && (n1 - b->net0) / 1024 / dur >= ASB_LAB_NET_KIBPS_MAX) {
                g_lab_blocks_rejected++;
                g_lab_blocks_radio++;
                return;
            }
        }
        double ma = ((double)(b->cc0 - cc1) / 1000.0) / ((double)dur / 3600.0);
        double v = ((double)b->v_sum / (double)b->v_n) / 1e6;
        s.mw = (float)(ma * v);
    } else {
        if (b->s < 0.7 * (double)dur || b->s <= 0.0) { g_lab_blocks_rejected++; return; }
        s.mw = (float)(b->j / b->s * 1000.0);
        s.press = b->ticks > 0 ? (float)b->ticks_press / (float)b->ticks : 0.0f;
        s.heat = (float)((double)(b->tlast_dc - b->t0_dc) * 3600.0 / (double)dur);
        if (k == LAB_RADIO && b->net0 >= 0 && in->mobile_bytes >= b->net0)
            s.traffic = (float)((double)(in->mobile_bytes - b->net0) / 1024.0 / (double)dur);
    }
    if (s.mw <= 1.0f || s.mw > 30000.0f) { g_lab_blocks_rejected++; return; }
    if (b->need_jank && b->fr0 >= 0) {
        asb_lab_pend_flush(-1.0f);
        g_lab_pend = s;
        g_lab_pend_k = k;
        g_lab_pend_slot = b->slot;
        g_lab_pend_arm = b->arm;
        g_lab_pend_ts = in->wall;
        g_lab_pend_fr0 = b->fr0;
        g_lab_pend_jk0 = b->jk0;
        memcpy(g_lab_pend_pkg, b->pkg, sizeof(g_lab_pend_pkg)); g_lab_pend_pkg[sizeof(g_lab_pend_pkg) - 1] = 0;
        if (g_lab_gfx_ask) g_lab_gfx_ask(b->pkg);
        return;
    }
    asb_lab_sample(k, b->slot, b->arm, &s, in->wall);
}

/* The wake lift: a block is a run of glances, all woken under one setting. */
static void asb_lab_glance(int screen_on_ses_s, float ses_j, float ses_s, const asb_lab_in_t *in) {
    asb_lab_blk_t *b = &g_lab_lift;
    if (!b->active || screen_on_ses_s > ASB_LAB_GLANCE_S || ses_s < 5.0f || ses_j <= 0.0f) return;
    b->j += (double)ses_j;
    b->s += (double)ses_s;
    b->glances++;
    if (in->bat_temp_dc > b->tmax_dc) b->tmax_dc = in->bat_temp_dc;
    if (in->bat_temp_dc < b->tmin_dc) b->tmin_dc = in->bat_temp_dc;
}

static void asb_lab_lift_close(const asb_lab_in_t *in) {
    asb_lab_blk_t *b = &g_lab_lift;
    if (!b->active) return;
    long age = in->wall - b->wall0;
    int done = b->glances >= ASB_LAB_LIFT_GLANCES ||
               (b->glances >= ASB_LAB_LIFT_MIN_GL && age >= ASB_LAB_LIFT_MAX_S);
    if (!done) {
        if (age >= ASB_LAB_LIFT_DROP_S || age < 0) { b->active = 0; g_lab_blocks_short++; }
        return;
    }
    b->active = 0;
    if (b->s <= 0.0) { g_lab_blocks_rejected++; return; }
    asb_lab_last_t s;
    memset(&s, 0, sizeof(s));
    s.ts = (uint32_t)in->wall;
    s.temp_dc = (int16_t)b->t0_dc;
    s.soc = (uint8_t)(b->soc0 < 0 ? 0 : (b->soc0 > 100 ? 100 : b->soc0));
    s.band = -1;
    s.jank = -1.0f;
    s.traffic = -1.0f;
    s.mw = (float)(b->j / b->s * 1000.0);
    if (s.mw <= 1.0f || s.mw > 30000.0f) { g_lab_blocks_rejected++; return; }
    if (b->need_jank && b->fr0 >= 0) {
        asb_lab_pend_flush(-1.0f);
        g_lab_pend = s;
        g_lab_pend_k = LAB_LIFT;
        g_lab_pend_slot = b->slot;
        g_lab_pend_arm = b->arm;
        g_lab_pend_ts = in->wall;
        g_lab_pend_fr0 = b->fr0;
        g_lab_pend_jk0 = b->jk0;
        memcpy(g_lab_pend_pkg, b->pkg, sizeof(g_lab_pend_pkg)); g_lab_pend_pkg[sizeof(g_lab_pend_pkg) - 1] = 0;
        if (g_lab_gfx_ask) g_lab_gfx_ask(b->pkg);
        return;
    }
    asb_lab_sample(LAB_LIFT, b->slot, b->arm, &s, in->wall);
}

/* ---- the three apps --------------------------------------------------------------------- */
typedef struct { uint64_t hash; const char *pkg; float j; } asb_lab_app_cand_t;

static int asb_lab_app_slot(uint64_t hash) {
    if (!hash) return -1;
    for (int i = 0; i < LAB_APPS; i++) if (g_lab.k[LAB_APP0 + i].key == hash) return i;
    return -1;
}

/* The three apps that cost the most, from the energy table (ordered, dearest first). A slot
 * keeps its app while the app stays in the top three, or for 14 days after it left. */
static void asb_lab_pick_apps(const asb_lab_app_cand_t *c, int n, long wall) {
    if (n > LAB_APPS) n = LAB_APPS;
    for (int i = 0; i < n; i++) {
        if (!c[i].hash || !c[i].pkg || !*c[i].pkg) continue;
        int s = asb_lab_app_slot(c[i].hash);
        if (s >= 0) { g_lab.k[LAB_APP0 + s].last_ts = (uint32_t)wall; continue; }
        int pick = -1;
        for (int j = 0; j < LAB_APPS && pick < 0; j++) if (!g_lab.k[LAB_APP0 + j].key) pick = j;
        for (int j = 0; j < LAB_APPS && pick < 0; j++) {
            asb_lab_knob_t *kn = &g_lab.k[LAB_APP0 + j];
            int still = 0;
            for (int q = 0; q < n; q++) if (c[q].hash == kn->key) still = 1;
            if (!still && wall - (long)kn->last_ts >= ASB_LAB_APP_STALE_S) pick = j;
        }
        if (pick < 0) continue;
        if (g_lab_on.active && g_lab_on.knob == LAB_APP0 + pick) g_lab_on.active = 0;
        asb_lab_knob_t *kn = &g_lab.k[LAB_APP0 + pick];
        memset(kn, 0, sizeof(*kn));
        kn->key = c[i].hash;
        snprintf(kn->pkg, sizeof(kn->pkg), "%s", c[i].pkg);
        kn->tried = 1;
        kn->last_ts = (uint32_t)wall;
        g_lab_dirty = 1;
    }
}

/* ---- the memory bus --------------------------------------------------------------------
 * The CPU's votes on the memory bus: on Qualcomm parts, each voter directory under
 * bus_dcvs/DDR and bus_dcvs/LLCC that has a writable max_freq (memory-latency and bandwidth
 * monitors); elsewhere a devfreq device named for DDR. The display, GPU, video and modem vote
 * through their own interconnect paths, which are never touched - a cap here slows only what
 * the CPU asks of the bus. A value is written only under the voter's own original, read back,
 * and given back when the cap ends. A voter whose value someone else changed, or that refused
 * three writes, is left alone until the next boot. */
#define ASB_MEM_MAX_V 16
typedef struct {
    char path[200];
    long orig, written;
    int  dom, fails, yielded, owned;
} asb_mem_voter_t;
typedef struct {
    char name[16];
    long hw_max, hw_min;
    long avail[40];
    int  navail;
} asb_mem_dom_t;
static asb_mem_voter_t g_mem_v[ASB_MEM_MAX_V];
static asb_mem_dom_t   g_mem_dom[4];
static int  g_mem_nv = 0, g_mem_ndom = 0, g_mem_probe = 0;
static const char *g_mem_kind = "-";
static int  g_mem_cap_now = 0;
static unsigned long g_mem_writes = 0, g_mem_restores = 0, g_mem_yields = 0, g_mem_fails = 0;

static long asb_mem_read(const char *p) {
    FILE *f = fopen(p, "re");
    if (!f) return -1;
    char buf[64] = {0};
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    char *e = NULL;
    long v = strtol(buf, &e, 10);
    return (e == buf) ? -1 : v;
}
static int asb_mem_write(const char *p, long v) {
    FILE *f = fopen(p, "we");
    if (!f) return -1;
    int rc = fprintf(f, "%ld\n", v) > 0 ? 0 : -1;
    if (fclose(f) != 0) rc = -1;
    return rc;
}
static void asb_mem_dom_freqs(asb_mem_dom_t *d, const char *avail) {
    FILE *f = fopen(avail, "re");
    d->navail = 0;
    if (!f) return;
    char buf[1024] = {0};
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    char *p = buf;
    while (*p && d->navail < 40) {
        while (*p == ' ' || *p == '\n' || *p == '\t') p++;
        if (!*p) break;
        char *e = NULL;
        long v = strtol(p, &e, 10);
        if (e == p) break;
        if (v > 0) d->avail[d->navail++] = v;
        p = e;
    }
    for (int i = 1; i < d->navail; i++)
        for (int j = i; j > 0 && d->avail[j - 1] > d->avail[j]; j--) {
            long t = d->avail[j]; d->avail[j] = d->avail[j - 1]; d->avail[j - 1] = t;
        }
    if (d->navail > 0) {
        if (d->hw_min <= 0) d->hw_min = d->avail[0];
        if (d->hw_max <= 0) d->hw_max = d->avail[d->navail - 1];
    }
}
static void asb_mem_add_voter(const char *path, int dom) {
    if (g_mem_nv >= ASB_MEM_MAX_V) return;
    if (access(path, R_OK | W_OK) != 0) return;
    long v = asb_mem_read(path);
    if (v <= 0) return;
    asb_mem_voter_t *m = &g_mem_v[g_mem_nv++];
    memset(m, 0, sizeof(*m));
    snprintf(m->path, sizeof(m->path), "%s", path);
    m->orig = -1; m->written = -1; m->dom = dom;
}
static void asb_mem_probe_run(void) {
    g_mem_probe = -1;
    g_mem_nv = 0; g_mem_ndom = 0;
    static const char *const doms[2] = { "DDR", "LLCC" };
    char p[256];
    for (int di = 0; di < 2; di++) {
        snprintf(p, sizeof(p), "%s/%s", ASB_MEM_ROOT, doms[di]);
        DIR *d = opendir(p);
        if (!d) continue;
        asb_mem_dom_t *dm = &g_mem_dom[g_mem_ndom];
        memset(dm, 0, sizeof(*dm));
        snprintf(dm->name, sizeof(dm->name), "%s", doms[di]);
        snprintf(p, sizeof(p), "%s/%s/hw_max_freq", ASB_MEM_ROOT, doms[di]); dm->hw_max = asb_mem_read(p);
        snprintf(p, sizeof(p), "%s/%s/hw_min_freq", ASB_MEM_ROOT, doms[di]); dm->hw_min = asb_mem_read(p);
        snprintf(p, sizeof(p), "%s/%s/available_frequencies", ASB_MEM_ROOT, doms[di]);
        asb_mem_dom_freqs(dm, p);
        int before = g_mem_nv;
        struct dirent *de;
        while ((de = readdir(d)) != NULL) {
            if (de->d_name[0] == '.') continue;
            char vp[256];
            if (snprintf(vp, sizeof(vp), "%s/%s/%s/max_freq", ASB_MEM_ROOT, doms[di], de->d_name) >= (int)sizeof(vp)) continue;
            asb_mem_add_voter(vp, g_mem_ndom);
        }
        closedir(d);
        if (g_mem_nv > before && dm->hw_max > 0 && dm->hw_min > 0 && dm->hw_max > dm->hw_min) { g_mem_ndom++; g_mem_kind = "bus_dcvs"; }
        else g_mem_nv = before;
    }
    if (g_mem_nv == 0) {
        DIR *d = opendir(ASB_MEM_DEVFREQ);
        if (d) {
            struct dirent *de;
            while ((de = readdir(d)) != NULL && g_mem_ndom < 4) {
                if (de->d_name[0] == '.' || strstr(de->d_name, "bw") || strstr(de->d_name, "gpu")) continue;
                if (!strstr(de->d_name, "ddr") && !strstr(de->d_name, "dvfsrc")) continue;
                asb_mem_dom_t *dm = &g_mem_dom[g_mem_ndom];
                memset(dm, 0, sizeof(*dm));
                snprintf(dm->name, sizeof(dm->name), "%.15s", de->d_name);
                if (snprintf(p, sizeof(p), "%s/%s/available_frequencies", ASB_MEM_DEVFREQ, de->d_name) >= (int)sizeof(p)) continue;
                asb_mem_dom_freqs(dm, p);
                char vp[256];
                if (snprintf(vp, sizeof(vp), "%s/%s/max_freq", ASB_MEM_DEVFREQ, de->d_name) >= (int)sizeof(vp)) continue;
                int before = g_mem_nv;
                asb_mem_add_voter(vp, g_mem_ndom);
                if (g_mem_nv > before && dm->navail >= 2) { g_mem_ndom++; g_mem_kind = "devfreq"; }
                else g_mem_nv = before;
            }
            closedir(d);
        }
    }
    if (g_mem_nv > 0) g_mem_probe = 1;
}

/* The step a cap of pct (or -1: the lowest step) asks for: the lowest listed step at or above
 * that share of the maximum, never under the domain's own minimum. */
static long asb_mem_target(const asb_mem_dom_t *d, int pct) {
    if (pct < 0) return d->hw_min;
    long want = d->hw_max * pct / 100;
    for (int i = 0; i < d->navail; i++) if (d->avail[i] >= want) return d->avail[i] < d->hw_min ? d->hw_min : d->avail[i];
    return d->hw_max;
}

static void asb_mem_give_back(void) {
    for (int i = 0; i < g_mem_nv; i++) {
        asb_mem_voter_t *m = &g_mem_v[i];
        if (!m->owned) continue;
        long cur = asb_mem_read(m->path);
        if (cur != m->written) { m->owned = 0; m->yielded = 1; g_mem_yields++; continue; }
        if (asb_mem_write(m->path, m->orig) == 0 && asb_mem_read(m->path) == m->orig) {
            m->owned = 0; g_mem_restores++;
        } else if (++m->fails >= 3) { m->owned = 0; m->yielded = 1; g_mem_yields++; g_mem_fails++; }
    }
}

/* pct: 0 none, -1 the lowest step, else % of the bus maximum. A cap in force is checked
 * against its readback every 30 s: a value someone else wrote is theirs from then on. */
static void asb_mem_apply(int pct, long now) {
    static long checked = 0;
    if (!pct && !g_mem_cap_now) return;
    if (g_mem_probe == 0) asb_mem_probe_run();
    if (g_mem_probe != 1) return;
    if (pct == g_mem_cap_now) {
        if (checked && now >= checked && now - checked < 30) return;
        checked = now;
        for (int i = 0; i < g_mem_nv; i++) {
            asb_mem_voter_t *m = &g_mem_v[i];
            if (m->owned && asb_mem_read(m->path) != m->written) { m->owned = 0; m->yielded = 1; g_mem_yields++; }
        }
        return;
    }
    checked = now;
    if (!pct) { asb_mem_give_back(); g_mem_cap_now = 0; return; }
    for (int i = 0; i < g_mem_nv; i++) {
        asb_mem_voter_t *m = &g_mem_v[i];
        if (m->yielded) continue;
        const asb_mem_dom_t *d = &g_mem_dom[m->dom];
        long cur = asb_mem_read(m->path);
        if (cur <= 0) continue;
        if (m->owned && cur != m->written) { m->owned = 0; m->yielded = 1; g_mem_yields++; continue; }
        if (!m->owned) m->orig = cur;
        long t = asb_mem_target(d, pct);
        if (t >= m->orig) {
            if (m->owned && asb_mem_write(m->path, m->orig) == 0) { m->owned = 0; g_mem_restores++; }
            continue;
        }
        if (asb_mem_write(m->path, t) == 0 && asb_mem_read(m->path) == t) {
            m->written = t; m->owned = 1; g_mem_writes++;
        } else {
            g_mem_fails++;
            if (m->owned && asb_mem_read(m->path) != m->written) { m->owned = 0; }
            if (++m->fails >= 3) { m->yielded = 1; g_mem_yields++; if (m->owned) { asb_mem_write(m->path, m->orig); m->owned = 0; } }
        }
    }
    g_mem_cap_now = pct;
}

static int asb_mem_active_voters(void) {
    int n = 0;
    for (int i = 0; i < g_mem_nv; i++) if (!g_mem_v[i].yielded) n++;
    return n;
}

/* ---- persistence --------------------------------------------------------------------- */
static void asb_lab_init(void) {
    memset(&g_lab, 0, sizeof(g_lab));
    g_lab.magic = ASB_LAB_MAGIC; g_lab.version = ASB_LAB_VERSION; g_lab.size = (uint32_t)sizeof(g_lab);
    for (int k = 0; k < LAB_N; k++) g_lab.k[k].tried = 1;
}
static int asb_lab_load(void) {
    asb_lab_init();
    g_lab_loaded = 1;
    FILE *f = fopen(ASB_LAB_FILE, "rb");
    if (!f) return 1;
    asb_lab_store_t tmp;
    size_t n = fread(&tmp, 1, sizeof(tmp), f);
    fclose(f);
    if (n != sizeof(tmp) || tmp.magic != ASB_LAB_MAGIC || tmp.size != sizeof(tmp) ||
        (tmp.version != ASB_LAB_VERSION && tmp.version != 1))
        return 2;
    for (int k = 0; k < LAB_N; k++) {
        asb_lab_knob_t *kn = &tmp.k[k];
        int na = asb_lab_narms(k);
        if (kn->champion >= na || kn->challenger >= na) return 2;
        kn->pkg[sizeof(kn->pkg) - 1] = 0;
    }
    /* Version 1 counted screen-off bus blocks during which the radio was busy: that knob alone
     * starts again, the other knobs keep what they learned. */
    int migrated = (tmp.version == 1);
    if (migrated) {
        tmp.k[LAB_MEM_OFF] = g_lab.k[LAB_MEM_OFF];
        tmp.version = ASB_LAB_VERSION;
        g_lab_dirty = 1;
    }
    g_lab = tmp;
    return migrated ? 3 : 0;
}
static int asb_lab_save(void) {
    char tmpn[256];
    snprintf(tmpn, sizeof(tmpn), "%s.tmp", ASB_LAB_FILE);
    FILE *f = fopen(tmpn, "wb");
    if (!f) return -1;
    size_t n = fwrite(&g_lab, 1, sizeof(g_lab), f);
    if (fclose(f) != 0 || n != sizeof(g_lab)) { unlink(tmpn); return -1; }
    if (rename(tmpn, ASB_LAB_FILE) != 0) { unlink(tmpn); return -1; }
    return 0;
}

static const char *asb_lab_state_name(int k, const asb_lab_in_t *in) {
    const asb_lab_knob_t *kn = &g_lab.k[k];
    if (asb_lab_is_app(k) && !kn->key) return "free";
    if (k == LAB_RADIO && in && !in->radio_ok) return "off";
    if ((k == LAB_MEM_ON || k == LAB_MEM_OFF) && (g_mem_probe == -1 || (in && !in->mem_ok))) return "off";
    if (kn->converged) return "best";
    if (kn->challenger != kn->champion) return "testing";
    return "watching";
}

static void asb_lab_summary_write(const asb_lab_in_t *in) {
    char tmpn[256];
    snprintf(tmpn, sizeof(tmpn), "%s.tmp", ASB_LAB_SUMMARY);
    FILE *f = fopen(tmpn, "w");
    if (!f) return;
    fprintf(f, "# Smart lab: one setting at a time, side by side with the best so far\n");
    fprintf(f, "# knob|name|state|best|trying|pairs|diff_pct_x10|press_x1000|jank_x10000|heat_dch|gain_pct_x10|wins|trials|reopen|blocks|now_mw|ref_mw|pkg\n");
    for (int k = 0; k < LAB_N; k++) {
        const asb_lab_knob_t *kn = &g_lab.k[k];
        unsigned n = kn->pairs;
        fprintf(f, "knob|%s|%s|%s|%s|%u|%d|%d|%d|%d|%d|%u|%u|%u|%u|%.0f|%.0f|%s\n",
                g_lab_names[k], asb_lab_state_name(k, in),
                asb_lab_arm_name(k, kn->champion),
                kn->challenger != kn->champion ? asb_lab_arm_name(k, kn->challenger) : "-",
                n, n ? (int)(kn->pr_mean * 1000.0) : 0,
                n ? (int)(kn->pr_press / (double)n * 1000.0) : 0,
                kn->jank_pairs ? (int)(kn->pr_jank / (double)kn->jank_pairs * 10000.0) : 0,
                n ? (int)(kn->pr_heat / (double)n) : 0,
                (int)(kn->gain * 1000.0f), kn->wins, kn->trials, kn->reopen, kn->blocks,
                (double)kn->ewma_mw, (double)kn->ref_mw, kn->pkg[0] ? kn->pkg : "-");
    }
    fprintf(f, "mem|%s|voters=%d|active=%d|doms=%d|cap_now=%d|writes=%lu|restores=%lu|yields=%lu|fails=%lu\n",
            g_mem_probe == 1 ? g_mem_kind : (g_mem_probe == 0 ? "unprobed" : "none"), g_mem_nv,
            asb_mem_active_voters(), g_mem_ndom, g_mem_cap_now, g_mem_writes, g_mem_restores, g_mem_yields, g_mem_fails);
    fprintf(f, "now|radio_arm=%d|lift_pct=%d|mem_on=%d|mem_off=%d|app_front=%d|on_block=%s|off_block=%s|glances=%d|kept=%lu|short=%lu|rejected=%lu|wins=%u|reopened=%u|radio_set_aside=%lu|early_stops=%lu\n",
            g_lab_radio_arm, g_lab_lift_pct, g_lab_mem_on_pct, g_lab_mem_off_pct, g_lab_app_front,
            g_lab_on.active ? g_lab_names[g_lab_on.knob] : "-", g_lab_off.active ? g_lab_names[g_lab_off.knob] : "-",
            g_lab_lift.active ? g_lab_lift.glances : 0, g_lab_blocks_kept, g_lab_blocks_short,
            g_lab_blocks_rejected, g_lab.wins_total, g_lab.reopen_total, g_lab_blocks_radio, g_lab_early_stops);
    fclose(f);
    rename(tmpn, ASB_LAB_SUMMARY);
}

static void asb_lab_radio_publish(void) {
    if (g_lab_radio_written == g_lab_radio_arm) return;
    if (g_lab_radio_arm) {
        FILE *f = fopen(ASB_LAB_RADIO_FILE, "w");
        if (!f) return;
        fputs("nr\n", f);
        fclose(f);
    } else {
        unlink(ASB_LAB_RADIO_FILE);
    }
    g_lab_radio_written = g_lab_radio_arm;
}

static int asb_lab_value(int k, int arm, const asb_lab_in_t *in) {
    switch (k) {
    case LAB_RADIO:   return arm;
    case LAB_LIFT:    return asb_lab_lift_value(arm, in->lift_cfg_pct);
    case LAB_MEM_ON:  return g_lab_mem_on_arm[arm];
    case LAB_MEM_OFF: return g_lab_mem_off_arm[arm];
    default:          return g_lab_app_arm[arm];
    }
}
static int asb_lab_arm_in_force(int k) {
    if (g_lab_on.active && g_lab_on.knob == k) return g_lab_on.arm;
    if (g_lab_off.active && g_lab_off.knob == k) return g_lab_off.arm;
    if (k == LAB_LIFT && g_lab_lift.active) return g_lab_lift.arm;
    return g_lab.k[k].champion;
}

static int asb_lab_on_eligible(int k, const asb_lab_in_t *in, int app_slot) {
    int ok = in->screen_on && !in->charging && !in->thermal_cap && !in->veto && !in->lowbat &&
             !in->heavy && !in->cooldown && in->soc >= 10 && in->unplug_age_s >= ASB_LAB_SETTLE_S;
    if (!ok) return 0;
    if (asb_lab_is_app(k)) return app_slot == k - LAB_APP0 && !in->smooth_testing;
    if (app_slot >= 0 || in->rec_on_busy) return 0;
    if (k == LAB_RADIO) return in->radio_ok && in->on_mobile;
    if (k == LAB_MEM_ON) return in->mem_ok && g_mem_probe == 1 && asb_mem_active_voters() > 0;
    return 0;
}

static void asb_lab_reset_outputs(void) {
    g_lab_radio_arm = 0; g_lab_lift_pct = 0; g_lab_mem_on_pct = 0; g_lab_mem_off_pct = 0;
    g_lab_app_offset = 0; g_lab_app_front = 0;
}

/* Once per governor tick. */
static void asb_lab_tick(const asb_lab_in_t *in) {
    if (!g_lab_loaded) return;
    if (!in->enabled) {
        g_lab_on.active = g_lab_off.active = g_lab_lift.active = 0;
        asb_lab_reset_outputs();
        asb_lab_radio_publish();
        g_lab_prev_on = -1;
        return;
    }
    asb_lab_frames_poll(in->wall);
    int app_slot = in->screen_on ? asb_lab_app_slot(in->app_hash) : -1;
    if (app_slot >= 0 && (!in->app_pkg || strcmp(in->app_pkg, g_lab.k[LAB_APP0 + app_slot].pkg) != 0)) app_slot = -1;

    if (g_lab_on.active) {
        long dur = (long)((in->now_ms - g_lab_on.t0_ms) / 1000);
        long max_s = asb_lab_is_app(g_lab_on.knob) ? ASB_LAB_APP_BLOCK_S : ASB_LAB_ON_BLOCK_S;
        if (!asb_lab_on_eligible(g_lab_on.knob, in, app_slot) || dur >= max_s) asb_lab_blk_end(&g_lab_on, in);
        else asb_lab_blk_track(&g_lab_on, in);
    }
    if (!g_lab_on.active) {
        int want = -1;
        if (app_slot >= 0 && asb_lab_on_eligible(LAB_APP0 + app_slot, in, app_slot)) want = LAB_APP0 + app_slot;
        else {
            int cands[2], nc = 0;
            if (asb_lab_on_eligible(LAB_RADIO, in, app_slot)) cands[nc++] = LAB_RADIO;
            if (asb_lab_on_eligible(LAB_MEM_ON, in, app_slot)) cands[nc++] = LAB_MEM_ON;
            for (int i = 0; i < nc && want < 0; i++) if (!g_lab.k[cands[i]].converged) want = cands[i];
            for (int i = 0; i < nc; i++)
                if (want < 0 || (g_lab.k[want].converged && g_lab.k[cands[i]].last_ts < g_lab.k[want].last_ts)) want = cands[i];
        }
        if (want >= 0) asb_lab_blk_begin(&g_lab_on, want, in, asb_lab_is_app(want) ? g_lab.k[want].pkg : NULL);
    }

    int off_ok = !in->screen_on && !in->charging && in->mem_ok && g_mem_probe == 1 && !in->rec_off_busy &&
                 !in->cooldown && !in->thermal_cap && in->soc >= 10 && in->unplug_age_s >= ASB_LAB_SETTLE_S &&
                 asb_mem_active_voters() > 0;
    if (g_lab_off.active) {
        long dur = (long)((in->now_ms - g_lab_off.t0_ms) / 1000);
        if (!off_ok || dur >= ASB_LAB_OFF_BLOCK_S) asb_lab_blk_end(&g_lab_off, in);
        else asb_lab_blk_track(&g_lab_off, in);
    }
    if (!g_lab_off.active && off_ok) asb_lab_blk_begin(&g_lab_off, LAB_MEM_OFF, in, NULL);

    if (g_lab_prev_on == 1 && !in->screen_on) asb_lab_lift_close(in);
    if (!g_lab_lift.active && !in->screen_on && !in->charging)
        asb_lab_blk_begin(&g_lab_lift, LAB_LIFT, in, "com.android.systemui");
    g_lab_prev_on = in->screen_on ? 1 : 0;

    g_lab_radio_arm = in->radio_ok ? asb_lab_arm_in_force(LAB_RADIO) : 0;
    g_lab_lift_pct = asb_lab_value(LAB_LIFT, asb_lab_arm_in_force(LAB_LIFT), in);
    g_lab_mem_on_pct = in->mem_ok ? asb_lab_value(LAB_MEM_ON, asb_lab_arm_in_force(LAB_MEM_ON), in) : 0;
    g_lab_mem_off_pct = in->mem_ok ? asb_lab_value(LAB_MEM_OFF, asb_lab_arm_in_force(LAB_MEM_OFF), in) : 0;
    g_lab_app_front = (app_slot >= 0);
    g_lab_app_offset = g_lab_app_front ?
        in->app_base_x1000 + asb_lab_value(LAB_APP0 + app_slot, asb_lab_arm_in_force(LAB_APP0 + app_slot), in) : 0;
    asb_lab_radio_publish();

    if (g_lab_dirty && (g_lab_saved_ts == 0 || in->wall - g_lab_saved_ts >= ASB_LAB_SAVE_EVERY_S || in->wall < g_lab_saved_ts)) {
        if (asb_lab_save() == 0) { g_lab_dirty = 0; g_lab_saved_ts = in->wall; }
        asb_lab_summary_write(in);
    }
}
