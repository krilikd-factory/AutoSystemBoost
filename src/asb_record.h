#pragma once
/*
 * Smart records (fix184, Smart V5 in fix185) - Smart measures what each situation costs,
 * keeps the best setting it has found for it, and keeps trying to beat it until it cannot.
 *
 * Until fix184 Smart learned by direction only: a hot or drainy session pushed a bucket's
 * lean toward economy, a clean cool one pulled it back, and nothing ever asked whether the
 * new setting was actually cheaper. This layer measures instead of guessing:
 *
 *  - The meter is the fuel gauge's charge counter (power_supply/battery/charge_counter,
 *    1 mAh steps on every OnePlus in the captures - OP15 CPH2745/2747/2769, OP13, OP12
 *    CPH2691). Over a block it gives the real charge drawn, suspend included. fix185 turns
 *    it into POWER: charge x the battery voltage averaged over the block. The same work
 *    draws more current from a battery at 20 % (3.6 V) than at 90 % (4.3 V); in milliamps a
 *    setting measured late in the day looked dearer than one measured in the morning.
 *  - A block is a stretch of one situation: screen off at night or by day (40 min), or screen
 *    on with light apps or with ordinary ones (feeds, video, anything the package table does
 *    not call light or heavy), dim or bright (10 min). Thrown away, with the reason counted:
 *    charging and the first 20 minutes after it (a warm pack, a relaxing voltage), a battery
 *    under 10 %, the screen-off radio busy (>= 15 KiB/s), screen-off music or a sync keeping
 *    the CPU awake, heavy work, games, the camera, the thermal veto, low battery, a thermal
 *    cap, the cooldown - and a change of climate: the pack warming or cooling by 3 C with the
 *    screen off (in from the cold, out into it), or cooling by 3 C in use.
 *  - Each situation has a champion setting and, while it explores, one challenger next to it.
 *    Blocks alternate between the two, and fix185 compares them in PAIRS: each challenger
 *    block against the champion block next to it, only if the two were within four hours,
 *    2.5 C of battery temperature and 25 points of charge of each other. Weather, a warm
 *    home, a cold street, the charge level and battery ageing then change both sides of a
 *    pair alike, and a better result that came from the room is not credited to the setting.
 *    The challenger takes over when the pairs say it is at least 3 % cheaper and the result
 *    clears their spread (t >= 2.5, fix186). Screen on it must also not make the cores sit at their
 *    ceiling more often (+8 points at most) - cheaper by being slower is not a win. A
 *    challenger that is clearly dearer is dropped after three pairs.
 *  - A win keeps going in the same direction; a loss turns round. When neither neighbour of
 *    the champion beats it, the situation has reached its plateau and exploring stops. It is
 *    re-checked after 21 days, because apps, the battery and the ROM change.
 *
 * The settings are deliberately few and bounded:
 *    screen off  - the deep-idle CPU ceilings x0.75, x0.875, x1 (as today), x1.25, x1.5 (never
 *                  while the CPU is kept awake - music, a sync - those keep x1)
 *    screen on   - Smart's economy lean -0.2, -0.1, 0 (as today), +0.1, +0.2
 * so the worst a bad guess can do is one step away from today's behaviour, for a block.
 *
 * Also here: the night-wake habit (short check-ins of a night - time, length, how many) and
 * the smoothness check (fix185, see asb_smooth_*): real HWUI jank per app from Android's own
 * frame statistics, and more headroom for an app only after an A/B test showed it helps.
 *
 * Pure logic: the governor feeds a tick, reads the knobs back and logs the events. The
 * meter, network and brightness readers are swappable for the tests.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#ifndef ASB_REC_FILE
#define ASB_REC_FILE        "/data/adb/asb/smart_records.bin"
#endif
#ifndef ASB_REC_SUMMARY
#define ASB_REC_SUMMARY     "/dev/.asb/smart_records.txt"
#endif
#ifndef ASB_REC_CC_PATH
#define ASB_REC_CC_PATH     "/sys/class/power_supply/battery/charge_counter"
#endif
#define ASB_REC_MAGIC       0x41535243u
#define ASB_REC_VERSION     2

enum {
    ASB_REC_OFF_NIGHT = 0,
    ASB_REC_OFF_DAY,
    ASB_REC_ON_LIGHT_DIM,
    ASB_REC_ON_LIGHT_BRIGHT,
    ASB_REC_ON_MEDIUM_DIM,
    ASB_REC_ON_MEDIUM_BRIGHT,
    ASB_REC_CTX_N
};
static const char *const g_rec_ctx_names[ASB_REC_CTX_N] = {
    "off_night", "off_day", "on_light_dim", "on_light_bright", "on_medium_dim", "on_medium_bright"
};
#define ASB_REC_ARMS        5
#define ASB_REC_ARM_DEFAULT 2
static const int g_rec_off_scale_x1000[ASB_REC_ARMS] = { 750, 875, 1000, 1250, 1500 };
static const int g_rec_on_offset_x1000[ASB_REC_ARMS] = { -200, -100, 0, 100, 200 };

#define ASB_REC_OFF_BLOCK_S     2400
#define ASB_REC_OFF_MIN_S       1200
#define ASB_REC_ON_BLOCK_S      600
#define ASB_REC_ON_MIN_S        180
#define ASB_REC_OFF_NMIN        6       /* pairs */
#define ASB_REC_OFF_NMAX        16
#define ASB_REC_ON_NMIN         8
#define ASB_REC_ON_NMAX         20
#define ASB_REC_GAIN_MIN        0.03    /* 3 % cheaper at least */
/* t >= 2.5, compared squared (no libm). fix185 used 1.7 - but the verdict is looked at after
 * every pair from the 6th/8th to the 16th/20th, and each look is another chance for a setting
 * that is no better to clear the bar by luck: simulated, that handed it a "win" about one
 * time in seven (one in twelve screen off). At 2.5 it is about one in twenty, while a real
 * 8 % saving still wins nine times in ten at the block-to-block spread of screen-off blocks
 * and of steady screen-on use. Screen-on use is not always steady: an OP15 capture's first
 * screen-on pair differed by 36 % between neighbouring blocks - such a situation then simply
 * does not reach a verdict, which is the honest outcome. */
#define ASB_REC_T2              6.25
#define ASB_REC_PRESS_SLACK     0.08    /* screen on: at most +8 points of time at the ceiling */
#define ASB_REC_PRESS_ABORT     0.15
#define ASB_REC_EARLY_WORSE     0.15    /* >= 15 % dearer over 3 pairs: dropped */
#define ASB_REC_RECHECK_S       (21L * 24 * 3600)
#define ASB_REC_NET_KIBPS_MAX   15      /* screen off: above this the radio, not the CPU, sets the drain */
#define ASB_REC_BRIGHT_PCT      30
#define ASB_REC_SAVE_EVERY_S    900
#define ASB_REC_SETTLE_S        1200    /* after the charger: pack warm, voltage still relaxing */
#define ASB_REC_SOC_MIN         10
#define ASB_REC_CLIMATE_DC      30      /* 3.0 C of battery temperature across one block */
#define ASB_REC_PAIR_DT_S       (4L * 3600)
#define ASB_REC_PAIR_TEMP_DC    25
#define ASB_REC_PAIR_SOC        25

/* Why a block was set aside (counted, shown in asbdiag and the full-day report). */
enum { REJ_METER = 0, REJ_CHARGE, REJ_RADIO, REJ_BUSY, REJ_CLIMATE, REJ_OTHER, REJ_N };
static const char *const g_rec_rej_names[REJ_N] = {
    "meter", "charge", "radio", "busy", "climate", "other"
};

typedef struct {
    uint32_t n;
    uint32_t pad;
    double   mean;     /* block power, mW (unpaired - for display) */
    double   mean_ma;  /* the same blocks in mA, for display */
    double   press;    /* mean share of screen-on ticks with a cluster at its ceiling, 0..1 */
} asb_rec_stat_t;

typedef struct {
    uint32_t ts;       /* when the block ended, 0 = none / already paired */
    int16_t  temp_dc;  /* mean battery temperature */
    uint8_t  soc;
    uint8_t  pad;
    float    mw;
    float    press;
} asb_rec_last_t;

typedef struct {
    uint8_t  champion;
    uint8_t  challenger;     /* == champion when no trial runs */
    uint8_t  converged;      /* 1 = plateau: neither neighbour beat the champion */
    uint8_t  alt;            /* which of the two the next block measures */
    int8_t   dir;            /* next neighbour to try: -1 / +1 */
    uint8_t  fails;          /* lost challenges from this champion */
    uint8_t  prev_champion;  /* the one it beat (255 = none), never re-tried as a challenger */
    uint8_t  pad;
    uint32_t trials, wins, converged_ts, last_ts, blocks;
    asb_rec_stat_t trial[2]; /* [0] champion, [1] challenger, this trial only */
    asb_rec_last_t last[2];  /* the latest unpaired block of each, for pairing */
    uint32_t pairs;          /* paired comparisons in this trial */
    float    last_gain;      /* the last win, side by side: 0.08 = 8 % cheaper */
    double   pr_mean, pr_m2; /* relative difference (challenger - champion) / champion */
    double   pr_press;       /* challenger minus champion, ceiling share */
    float    record_mw;      /* the champion's block mean when it last won or held */
    float    record_ma;
    uint32_t record_n;
    float    record_press;
    float    gain_total;     /* product of paired gains since today's setting: 0.92 = 8 % cheaper */
    float    baseline_mw;    /* today's setting as first measured (unpaired, information only) */
    uint32_t baseline_n;
} asb_rec_ctx_t;

#define ASB_MW_SLOTS 48     /* half hours */
typedef struct {
    float    slot_w[ASB_MW_SLOTS];  /* decayed count of night checks starting in each half hour */
    float    dur_ewma_s;            /* how long one usually lasts */
    float    per_night_ewma;        /* how many a night */
    uint32_t total;
    uint32_t last_ts;
    uint16_t tonight;
    uint16_t nights;
} asb_microwake_t;

/* Smoothness (fix185): per app, Android's own janky-frame share, and whether more headroom
 * fixes it. 0 watching, 1 testing, 2 helps (the lean is kept), 3 does not help. */
#define ASB_SMOOTH_APPS 24
typedef struct {
    uint64_t hash;
    uint32_t last_ts, decided_ts;
    uint8_t  state, arm, pad[2];
    uint32_t base_frames, base_janky;    /* watched under the normal lean */
    uint32_t t_frames[2], t_janky[2];    /* test: [0] normal, [1] more headroom */
    uint16_t t_windows[2];
    float    gain;                       /* relative jank reduction when decided */
} asb_smooth_app_t;

typedef struct {
    uint32_t magic, version, size, pad;
    asb_rec_ctx_t    ctx[ASB_REC_CTX_N];
    asb_microwake_t  mw;
    asb_smooth_app_t sm[ASB_SMOOTH_APPS];
} asb_rec_store_t;

typedef struct {
    int       active, ctx, slot, arm;
    long long t0_ms;
    long      cc0_uah;
    long long net0;
    int       ticks_on, ticks_press;
    int       ticks, ticks_busy;   /* screen off: ticks that were not quiet deep idle */
    int       t0_dc, tmin_dc, tmax_dc;
    long long v_sum_uv;
    long long t_sum_dc;
    int       vt_n;
    int       soc0;
} asb_rec_block_t;

/* One tick of input. */
typedef struct {
    int       enabled;     /* Smart running and smart_records=1 */
    int       explore;     /* smart_records_explore=1 */
    int       screen_on, charging, heavy_state, app_medium;
    int       idle_state;  /* screen off: DEEP_IDLE and the CPU mostly asleep (not music, not a sync) */
    int       thermal_cap, cooldown, veto, lowbat, night, microwake;
    int       at_ceiling;  /* screen on: a cluster sat at its ceiling this tick */
    int       bat_temp_dc; /* battery temperature, tenths of a degree */
    int       voltage_uv;
    int       soc;         /* battery percent */
    long      unplug_age_s;/* seconds since the charger came off; large when long ago */
    long long now_ms;      /* CLOCK_BOOTTIME */
    long      wall;        /* time(NULL) */
} asb_rec_in_t;

static long      (*g_rec_read_cc)(void);
static long long (*g_rec_read_net)(void);
static int       (*g_rec_read_bright_pct)(void);

static asb_rec_store_t g_rec;
static asb_rec_block_t g_rec_blk;
static int    g_rec_loaded = 0, g_rec_dirty = 0;
static long   g_rec_saved_ts = 0;
static int    g_rec_on_offset = 0;       /* x1000, Smart's lean while the screen is on */
static int    g_rec_off_scale = 1000;    /* x1000, screen-off idle ceilings */
static int    g_rec_knob_changed = 0;
static int    g_rec_cc_state = 0;        /* 0 not tried, 1 ok, -1 unavailable, -2 not moving */
static long   g_rec_cc_retry_ts = 0;
static int    g_rec_bright_band = -1;    /* 0 dim, 1 bright, -1 unknown */
static long   g_rec_bright_ts = 0;
static unsigned long g_rec_blocks_ok = 0, g_rec_blocks_rejected = 0;
static unsigned long g_rec_rej[REJ_N];
static int    g_rec_event = 0;           /* last decision: 1 promoted, 2 held, 3 plateau */
static char   g_rec_event_msg[200];
static int    g_rec_smooth_testing = 0;  /* the app in front is in a smoothness test */
static int    g_rec_kctx = -1;           /* fix186: the situation in force now (-1 none), for the WebUI */

static int asb_rec_is_off(int ctx) { return ctx == ASB_REC_OFF_NIGHT || ctx == ASB_REC_OFF_DAY; }
static const char *asb_rec_status_name(const asb_rec_ctx_t *c) {
    return c->converged ? "plateau"
         : (c->challenger != c->champion) ? "testing"
         : (c->record_n > 0) ? "holding" : "measuring";
}
static int asb_rec_arm_value(int ctx, int arm) {
    if (arm < 0 || arm >= ASB_REC_ARMS) arm = ASB_REC_ARM_DEFAULT;
    return asb_rec_is_off(ctx) ? g_rec_off_scale_x1000[arm] : g_rec_on_offset_x1000[arm];
}
static void asb_rec_arm_label(int ctx, int arm, char *out, size_t n) {
    int v = asb_rec_arm_value(ctx, arm);
    if (asb_rec_is_off(ctx)) snprintf(out, n, "x%d.%03d", v / 1000, v % 1000);
    else                     snprintf(out, n, "%+d", v);
}

static void asb_rec_trial_reset(asb_rec_ctx_t *c) {
    memset(c->trial, 0, sizeof(c->trial));
    memset(c->last, 0, sizeof(c->last));
    c->pairs = 0; c->pr_mean = 0; c->pr_m2 = 0; c->pr_press = 0;
    c->alt = 0;
}

static void asb_rec_ctx_init(asb_rec_ctx_t *c, int ctx) {
    memset(c, 0, sizeof(*c));
    c->champion = c->challenger = ASB_REC_ARM_DEFAULT;
    /* First guess: screen off, lower ceilings; screen on, a little more economy. */
    c->dir = asb_rec_is_off(ctx) ? -1 : +1;
    c->prev_champion = 255;
    c->gain_total = 1.0f;
}

static void asb_rec_store_init(asb_rec_store_t *s) {
    memset(s, 0, sizeof(*s));
    s->magic = ASB_REC_MAGIC; s->version = ASB_REC_VERSION; s->size = sizeof(*s);
    for (int i = 0; i < ASB_REC_CTX_N; i++) asb_rec_ctx_init(&s->ctx[i], i);
}

static void asb_rec_stat_add(asb_rec_stat_t *st, double mw, double ma, double press) {
    st->n++;
    st->mean    += (mw - st->mean) / st->n;
    st->mean_ma += (ma - st->mean_ma) / st->n;
    st->press   += (press - st->press) / st->n;
}

/* Start the next challenge from the current champion, if there is one to start. */
static void asb_rec_setup_trial(asb_rec_ctx_t *c, int explore, long now) {
    if (c->challenger != c->champion || !explore) return;
    if (c->converged) {
        if (now - (long)c->converged_ts < ASB_REC_RECHECK_S) return;
        /* Re-check: apps, battery and ROM have had three weeks to change. */
        c->converged = 0; c->fails = 0; c->prev_champion = 255;
    }
    while (c->fails < 2) {
        int next = (int)c->champion + c->dir;
        if (next >= 0 && next < ASB_REC_ARMS &&
            !(next == c->prev_champion && c->fails >= 1)) {
            c->challenger = (uint8_t)next;
            asb_rec_trial_reset(c);
            return;
        }
        /* That side is exhausted: the end of the range, or the setting the champion has
         * already beaten. It counts as a lost challenge. */
        c->fails++;
        c->dir = (int8_t)-c->dir;
    }
    c->converged = 1; c->converged_ts = (uint32_t)now;
}

/* Pair the block just added to `slot` with the latest unpaired block of the other side. */
static void asb_rec_pair(asb_rec_ctx_t *c, int slot, const asb_rec_last_t *me) {
    asb_rec_last_t *o = &c->last[1 - slot];
    c->last[slot] = *me;
    if (o->ts == 0) return;
    long dt = (long)me->ts - (long)o->ts;
    int  dT = me->temp_dc - o->temp_dc;
    int  dS = (int)me->soc - (int)o->soc;
    if (dt < 0) dt = -dt;
    if (dT < 0) dT = -dT;
    if (dS < 0) dS = -dS;
    if (dt > ASB_REC_PAIR_DT_S || dT > ASB_REC_PAIR_TEMP_DC || dS > ASB_REC_PAIR_SOC) return;
    const asb_rec_last_t *a = (slot == 0) ? me : o;   /* champion */
    const asb_rec_last_t *b = (slot == 1) ? me : o;   /* challenger */
    if (a->mw <= 0) return;
    double r = ((double)b->mw - (double)a->mw) / (double)a->mw;
    c->pairs++;
    double d = r - c->pr_mean;
    c->pr_mean += d / c->pairs;
    c->pr_m2 += d * (r - c->pr_mean);
    c->pr_press += (((double)b->press - (double)a->press) - c->pr_press) / c->pairs;
    c->last[0].ts = 0; c->last[1].ts = 0;   /* each block in one pair only */
}

/* After each accepted block. 0 nothing yet, 1 challenger won, 2 champion held, 3 plateau. */
static int asb_rec_decide(asb_rec_ctx_t *c, int ctx, long now) {
    asb_rec_stat_t *a = &c->trial[0], *b = &c->trial[1];
    const int off  = asb_rec_is_off(ctx);
    const unsigned nmin = off ? ASB_REC_OFF_NMIN : ASB_REC_ON_NMIN;
    const unsigned nmax = off ? ASB_REC_OFF_NMAX : ASB_REC_ON_NMAX;
    if (c->champion == ASB_REC_ARM_DEFAULT && c->baseline_n == 0 && a->n >= nmin) {
        c->baseline_mw = (float)a->mean; c->baseline_n = a->n;
    }
    if (c->challenger == c->champion) {
        /* Not exploring: the champion's running mean is the record. */
        if (a->n >= nmin) {
            c->record_mw = (float)a->mean; c->record_ma = (float)a->mean_ma;
            c->record_n = a->n; c->record_press = (float)a->press;
        }
        return 0;
    }
    int verdict = 0;   /* 1 promote, 2 hold */
    if (c->pairs >= 3 && c->pr_mean >= ASB_REC_EARLY_WORSE) verdict = 2;
    if (!off && c->pairs >= 4 && c->pr_press > ASB_REC_PRESS_ABORT) verdict = 2;
    if (!verdict && c->pairs >= nmin) {
        double var  = (c->pairs > 1) ? c->pr_m2 / (double)(c->pairs - 1) : 0.0;
        double se2  = var / (double)c->pairs;
        double m    = c->pr_mean;
        int sig     = (m * m >= ASB_REC_T2 * se2);
        int cheaper = (m <= -ASB_REC_GAIN_MIN && sig);
        int comfy   = off || (c->pr_press <= ASB_REC_PRESS_SLACK);
        if (cheaper && comfy) verdict = 1;
        else if (c->pairs >= nmax || (m > 0 && sig) || !comfy) verdict = 2;
    }
    if (!verdict) return 0;
    c->trials++;
    if (verdict == 1) {
        c->prev_champion = c->champion;
        c->champion = c->challenger;
        c->record_mw = (float)b->mean; c->record_ma = (float)b->mean_ma;
        c->record_n = b->n; c->record_press = (float)b->press;
        c->last_gain = (float)(-c->pr_mean);
        c->gain_total *= (float)(1.0 + c->pr_mean);
        c->wins++; c->fails = 0;
    } else {
        c->record_mw = (float)a->mean; c->record_ma = (float)a->mean_ma;
        c->record_n = a->n; c->record_press = (float)a->press;
        c->fails++;
        c->dir = (int8_t)-c->dir;
    }
    c->challenger = c->champion;
    asb_rec_trial_reset(c);
    if (verdict == 2 && c->fails >= 2) {
        c->converged = 1; c->converged_ts = (uint32_t)now;
        return 3;
    }
    return verdict;
}

/* ---- meters ------------------------------------------------------------------------- */
static long asb_rec_cc_file(void) {
    FILE *f = fopen(ASB_REC_CC_PATH, "r");
    if (!f) return -1;
    long v = -1;
    if (fscanf(f, "%ld", &v) != 1) v = -1;
    fclose(f);
    return (v > 0) ? v : -1;
}

/* The situation this tick belongs to, or -1 when it is not one the records measure. */
static int asb_rec_ctx_of(const asb_rec_in_t *in, int ignore_conditions) {
    if (!ignore_conditions && (in->charging || in->thermal_cap)) return -1;
    if (!ignore_conditions && (in->unplug_age_s < ASB_REC_SETTLE_S || in->soc < ASB_REC_SOC_MIN)) return -1;
    if (!in->screen_on) {
        /* Busy stretches (music, a sync) stay inside the block - both settings see them - and
         * are counted; a block that was mostly busy is set aside at the end. */
        if (!ignore_conditions && in->cooldown) return -1;
        return in->night ? ASB_REC_OFF_NIGHT : ASB_REC_OFF_DAY;
    }
    if (in->microwake || in->heavy_state) return -1;
    if (!ignore_conditions && (in->veto || in->lowbat || g_rec_smooth_testing)) return -1;
    int bright = (g_rec_bright_band == 1);
    if (g_rec_bright_band < 0) return -1;
    if (in->app_medium) return bright ? ASB_REC_ON_MEDIUM_BRIGHT : ASB_REC_ON_MEDIUM_DIM;
    return bright ? ASB_REC_ON_LIGHT_BRIGHT : ASB_REC_ON_LIGHT_DIM;
}

static void asb_rec_summary_write(void);
static void asb_rec_reject(int why) { g_rec_blocks_rejected++; if (why >= 0 && why < REJ_N) g_rec_rej[why]++; }

static void asb_rec_block_finish(const asb_rec_in_t *in) {
    asb_rec_block_t *k = &g_rec_blk;
    if (!k->active) return;
    k->active = 0;
    int ctx = k->ctx;
    long dur_s = (long)((in->now_ms - k->t0_ms) / 1000);
    int off = asb_rec_is_off(ctx);
    if (dur_s < (off ? ASB_REC_OFF_MIN_S : ASB_REC_ON_MIN_S)) return;   /* too short to mean anything */
    long cc1 = g_rec_read_cc ? g_rec_read_cc() : -1;
    if (k->cc0_uah <= 0 || cc1 <= 0) { g_rec_cc_state = -1; asb_rec_reject(REJ_METER); return; }
    if (cc1 > k->cc0_uah) { asb_rec_reject(REJ_CHARGE); return; }     /* charge came in */
    if (cc1 == k->cc0_uah) {
        if (dur_s >= 600) g_rec_cc_state = -2;                          /* the gauge did not move */
        asb_rec_reject(REJ_METER);
        return;
    }
    g_rec_cc_state = 1;
    double ma = ((double)(k->cc0_uah - cc1) / 1000.0) / ((double)dur_s / 3600.0);
    if (ma < 1.0 || ma > 6000.0) { asb_rec_reject(REJ_OTHER); return; }
    if (off && k->ticks >= 4 && k->ticks_busy * 4 > k->ticks) { asb_rec_reject(REJ_BUSY); return; }
    /* Climate: the pack moved by 3 C with the screen off (the phone came in from the cold or
     * went out into it), or cooled by 3 C while in use - the room changed, not the setting. */
    int t1 = in->bat_temp_dc;
    if (t1 < k->tmin_dc) k->tmin_dc = t1;
    if (t1 > k->tmax_dc) k->tmax_dc = t1;
    int climate = off ? (k->tmax_dc - k->tmin_dc >= ASB_REC_CLIMATE_DC)
                      : (k->tmax_dc - t1 >= ASB_REC_CLIMATE_DC || k->t0_dc - k->tmin_dc >= ASB_REC_CLIMATE_DC);
    if (climate) { asb_rec_reject(REJ_CLIMATE); return; }
    if (off && k->net0 >= 0 && g_rec_read_net) {
        long long n1 = g_rec_read_net();
        if (n1 >= k->net0 && (n1 - k->net0) / 1024 / dur_s >= ASB_REC_NET_KIBPS_MAX) {
            asb_rec_reject(REJ_RADIO);
            return;
        }
    }
    double v = (k->vt_n > 0) ? (double)k->v_sum_uv / k->vt_n / 1e6 : 0.0;
    if (v < 3.0 || v > 4.7) v = 3.85;                                   /* no sane reading: nominal */
    double mw = ma * v;
    int tmean = (k->vt_n > 0) ? (int)(k->t_sum_dc / k->vt_n) : t1;
    double press = (k->ticks_on > 0) ? (double)k->ticks_press / k->ticks_on : 0.0;
    asb_rec_ctx_t *c = &g_rec.ctx[ctx];
    /* A block measured under a challenge that has since ended belongs to nobody. */
    int slot = k->slot;
    if (slot == 1 && c->challenger == c->champion) { asb_rec_reject(REJ_OTHER); return; }
    if ((slot == 0 && k->arm != c->champion) || (slot == 1 && k->arm != c->challenger)) {
        asb_rec_reject(REJ_OTHER); return;
    }
    asb_rec_stat_add(&c->trial[slot], mw, ma, press);
    if (c->challenger != c->champion) {
        asb_rec_last_t me;
        memset(&me, 0, sizeof(me));
        me.ts = (uint32_t)in->wall; me.temp_dc = (int16_t)tmean;
        me.soc = (uint8_t)((k->soc0 + in->soc) / 2); me.mw = (float)mw; me.press = (float)press;
        asb_rec_pair(c, slot, &me);
        c->alt ^= 1;
    }
    c->blocks++; c->last_ts = (uint32_t)in->wall;
    g_rec_blocks_ok++;
    g_rec_dirty = 1;
    int prev = c->champion;
    int ev = asb_rec_decide(c, ctx, in->wall);
    if (ev) {
        char ch_s[16], pv_s[16];
        asb_rec_arm_label(ctx, c->champion, ch_s, sizeof(ch_s));
        asb_rec_arm_label(ctx, prev, pv_s, sizeof(pv_s));
        g_rec_event = ev;
        if (ev == 1)
            snprintf(g_rec_event_msg, sizeof(g_rec_event_msg),
                     "records: %s new best %s at %.0f mW (was %s; %.1f %% cheaper side by side, %.1f %% below today's setting)",
                     g_rec_ctx_names[ctx], ch_s, c->record_mw, pv_s,
                     c->last_gain * 100.0, (1.0 - c->gain_total) * 100.0);
        else if (ev == 2)
            snprintf(g_rec_event_msg, sizeof(g_rec_event_msg),
                     "records: %s %s holds at %.0f mW - the neighbour was not cheaper side by side",
                     g_rec_ctx_names[ctx], ch_s, c->record_mw);
        else
            snprintf(g_rec_event_msg, sizeof(g_rec_event_msg),
                     "records: %s plateau - %s is the best found (%.0f mW, %u win(s), %.1f %% below today's setting); re-check in 21 days",
                     g_rec_ctx_names[ctx], ch_s, c->record_mw, c->wins, (1.0 - c->gain_total) * 100.0);
        g_rec_saved_ts = 0;   /* save now */
    }
}

static void asb_rec_block_start(const asb_rec_in_t *in, int ctx) {
    asb_rec_block_t *k = &g_rec_blk;
    if (g_rec_cc_state == -1 && in->wall - g_rec_cc_retry_ts < 600) return;
    long cc0 = g_rec_read_cc ? g_rec_read_cc() : -1;
    if (cc0 <= 0) { g_rec_cc_state = -1; g_rec_cc_retry_ts = in->wall; return; }
    asb_rec_ctx_t *c = &g_rec.ctx[ctx];
    asb_rec_setup_trial(c, in->explore, in->wall);
    memset(k, 0, sizeof(*k));
    k->active = 1;
    k->ctx = ctx;
    k->slot = (c->challenger != c->champion) ? c->alt : 0;
    k->arm = k->slot ? c->challenger : c->champion;
    k->t0_ms = in->now_ms;
    k->cc0_uah = cc0;
    k->net0 = (asb_rec_is_off(ctx) && g_rec_read_net) ? g_rec_read_net() : -1;
    k->t0_dc = k->tmin_dc = k->tmax_dc = in->bat_temp_dc;
    k->soc0 = in->soc;
}

static int asb_rec_save(void);

/* Persist what changed - blocks, decisions, night wakes, smoothness - at most every 15
 * minutes, at once after a decision. */
static void asb_rec_maybe_save(long wall) {
    if (!g_rec_loaded || !g_rec_dirty) return;
    if (g_rec_saved_ts != 0 && wall - g_rec_saved_ts < ASB_REC_SAVE_EVERY_S) return;
    if (asb_rec_save() == 0) { g_rec_dirty = 0; g_rec_saved_ts = wall; }
    asb_rec_summary_write();
}

/* Once per governor tick. */
static void asb_rec_tick(const asb_rec_in_t *in) {
    int old_scale = g_rec_off_scale;
    g_rec_on_offset = 0;
    g_rec_off_scale = 1000;
    if (!in->enabled || !g_rec_loaded) {
        g_rec_blk.active = 0;
        g_rec_kctx = -1;
        g_rec_knob_changed |= (old_scale != g_rec_off_scale);
        asb_rec_maybe_save(in->wall);   /* night wakes are learned in every profile */
        return;
    }
    /* Brightness band, read at most every 30 s while the screen is on. */
    if (!in->screen_on) {
        g_rec_bright_band = -1; g_rec_bright_ts = 0;
    } else if (g_rec_bright_band < 0 || in->wall - g_rec_bright_ts >= 30) {
        int b = g_rec_read_bright_pct ? g_rec_read_bright_pct() : -1;
        g_rec_bright_ts = in->wall;
        g_rec_bright_band = (b < 0) ? -1 : (b >= ASB_REC_BRIGHT_PCT ? 1 : 0);
    }
    int ctx = asb_rec_ctx_of(in, 0);
    if (g_rec_blk.active) {
        long dur_s = (long)((in->now_ms - g_rec_blk.t0_ms) / 1000);
        long max_s = asb_rec_is_off(g_rec_blk.ctx) ? ASB_REC_OFF_BLOCK_S : ASB_REC_ON_BLOCK_S;
        if (ctx != g_rec_blk.ctx || dur_s >= max_s) asb_rec_block_finish(in);
        else {
            asb_rec_block_t *k = &g_rec_blk;
            k->ticks++;
            if (in->bat_temp_dc < k->tmin_dc) k->tmin_dc = in->bat_temp_dc;
            if (in->bat_temp_dc > k->tmax_dc) k->tmax_dc = in->bat_temp_dc;
            if (in->voltage_uv > 0) { k->v_sum_uv += in->voltage_uv; k->t_sum_dc += in->bat_temp_dc; k->vt_n++; }
            if (in->screen_on) {
                k->ticks_on++;
                if (in->at_ceiling) k->ticks_press++;
            } else if (!in->idle_state) {
                k->ticks_busy++;
            }
        }
    }
    if (!g_rec_blk.active && ctx >= 0) asb_rec_block_start(in, ctx);

    /* The knobs: the block's setting while one runs, the champion otherwise. Outside a
     * measurable situation (charging, veto, ...) the champion still applies - that is the
     * point of having learned it - but never under heavy work, a game or a night check. */
    int kctx = g_rec_blk.active ? g_rec_blk.ctx : asb_rec_ctx_of(in, 1);
    g_rec_kctx = kctx;
    if (kctx >= 0) {
        int arm = g_rec_blk.active ? g_rec_blk.arm : g_rec.ctx[kctx].champion;
        if (asb_rec_is_off(kctx)) {
            /* Only on quiet deep idle: music and syncs keep the ceilings they always had. */
            if (!in->thermal_cap && !in->cooldown && in->idle_state)
                g_rec_off_scale = asb_rec_arm_value(kctx, arm);
        } else {
            g_rec_on_offset = asb_rec_arm_value(kctx, arm);
        }
    }
    g_rec_knob_changed |= (old_scale != g_rec_off_scale);
    asb_rec_maybe_save(in->wall);
}

/* ---- night wakes ---------------------------------------------------------------------- */
static int asb_mw_slot(long wall) {
    struct tm tmv;
    time_t t = (time_t)wall;
    if (!localtime_r(&t, &tmv)) return -1;
    return (tmv.tm_hour * 60 + tmv.tm_min) / 30;
}
/* A short check ended inside a night: started at start_wall, lasted dur_s. */
static void asb_mw_note(long start_wall, long dur_s) {
    int s = asb_mw_slot(start_wall);
    if (s < 0 || dur_s <= 0) return;
    asb_microwake_t *w = &g_rec.mw;
    w->slot_w[s] += 1.0f;
    w->dur_ewma_s = (w->total == 0) ? (float)dur_s : w->dur_ewma_s * 0.75f + (float)dur_s * 0.25f;
    w->total++;
    w->tonight++;
    w->last_ts = (uint32_t)(start_wall + dur_s);
    g_rec_dirty = 1;
}
/* A night ended (the learned wake held). Old habits fade by 3 % a night. */
static void asb_mw_night_end(void) {
    asb_microwake_t *w = &g_rec.mw;
    w->per_night_ewma = (w->nights == 0) ? (float)w->tonight
                                         : w->per_night_ewma * 0.8f + (float)w->tonight * 0.2f;
    if (w->nights < 65535) w->nights++;
    w->tonight = 0;
    for (int i = 0; i < ASB_MW_SLOTS; i++) w->slot_w[i] *= 0.97f;
    g_rec_dirty = 1;
}
/* Does a screen-on now look like one of this user's night checks? */
static int asb_mw_predict(long wall, int night_active, long dark_s) {
    const asb_microwake_t *w = &g_rec.mw;
    if (!night_active || dark_s < 3600 || w->total < 3) return 0;
    int s = asb_mw_slot(wall);
    if (s < 0) return 0;
    float near = w->slot_w[s] + w->slot_w[(s + 1) % ASB_MW_SLOTS] +
                 w->slot_w[(s + ASB_MW_SLOTS - 1) % ASB_MW_SLOTS];
    return (near >= 1.0f || w->per_night_ewma >= 0.5f);
}
/* How long a check is treated as one: twice the usual length, 3 to 10 minutes. */
static long asb_mw_hold_s(void) {
    long h = (long)(g_rec.mw.dur_ewma_s * 2.0f);
    if (h < 180) h = 180;
    if (h > 600) h = 600;
    return h;
}

/* ---- smoothness (fix185) ----------------------------------------------------------------
 *
 * Every Smart capture in the field says the same thing about the obvious signal: frames are
 * NOT jankier when the cores sit at their ceiling. Across fifteen captures the janky share
 * is highest in intervals that spent under 20 % of their time at the ceiling (OP15 25131:
 * 8.4 % against 3.4 % and 3.1 %), so "the cores are pinned, give more" would spend battery
 * on jank the clocks do not cause - a streaming chat app, SystemUI redrawing, an app's own
 * frame pacing.
 *
 * So the evidence is the frames themselves: Android's GraphicsStatsService already counts
 * every HWUI app's frames and janky frames, in a buffer the app shares with system_server -
 * reading it does not call into the app (dumpsys gfxinfo would, on the app's own thread).
 * The governor reads it every three minutes of screen-on time at most, for the app in front.
 *
 * An app that misses its deadline on 8 % or more of 3000+ frames under the normal lean is
 * TESTED, not trusted: three-minute windows alternate the normal lean and 0.15 more
 * headroom. Only if the headroom cuts its janky share by a quarter and at least 1.5 points
 * does it keep the headroom whenever it is in front; otherwise it is marked as not helped
 * by clocks and left alone. Both verdicts are re-checked after 21 days. 24 apps are
 * remembered; the least recently seen makes room.
 */
#define ASB_SMOOTH_TRIGGER_FRAMES  3000
#define ASB_SMOOTH_TRIGGER_JANK    0.08
#define ASB_SMOOTH_MIN_WINDOWS     3
#define ASB_SMOOTH_MAX_WINDOWS     6
#define ASB_SMOOTH_MIN_FRAMES      4000
#define ASB_SMOOTH_GAIN_REL        0.25
#define ASB_SMOOTH_GAIN_ABS        0.015
#define ASB_SMOOTH_LEAN_X1000      (-150)
static int    g_smooth_event = 0;
static char   g_smooth_event_msg[200];

static asb_smooth_app_t *asb_smooth_find(uint64_t hash, long now, int create) {
    if (!hash) return NULL;
    asb_smooth_app_t *lru = NULL;
    for (int i = 0; i < ASB_SMOOTH_APPS; i++) {
        asb_smooth_app_t *a = &g_rec.sm[i];
        if (a->hash == hash) return a;
        if (!lru || (lru->hash != 0 && (a->hash == 0 || a->last_ts < lru->last_ts))) lru = a;
    }
    if (!create || !lru) return NULL;
    memset(lru, 0, sizeof(*lru));
    lru->hash = hash; lru->last_ts = (uint32_t)now;
    return lru;
}

/* The lean for the app in front (x1000, negative = more headroom), and whether it is in a
 * test - the records then leave that time out. */
static int asb_smooth_offset_for(uint64_t hash, long now) {
    g_rec_smooth_testing = 0;
    asb_smooth_app_t *a = asb_smooth_find(hash, now, 0);
    if (!a) return 0;
    if (a->state == 1) { g_rec_smooth_testing = 1; return a->arm ? ASB_SMOOTH_LEAN_X1000 : 0; }
    if (a->state == 2) return ASB_SMOOTH_LEAN_X1000;
    return 0;
}

/* One measured window for the app in front: df frames, dj janky, drawn under arm `arm`
 * (0 normal, 1 headroom) - the arm that was in force for the whole window. Returns 1 when
 * the app's state changed (the governor logs g_smooth_event_msg). */
static int asb_smooth_window(uint64_t hash, const char *pkg, long df, long dj, int arm, long now) {
    if (!hash || df <= 0 || dj < 0 || dj > df) return 0;
    asb_smooth_app_t *a = asb_smooth_find(hash, now, 1);
    if (!a) return 0;
    a->last_ts = (uint32_t)now;
    g_rec_dirty = 1;
    if ((a->state == 2 || a->state == 3) && now - (long)a->decided_ts >= ASB_REC_RECHECK_S) {
        a->state = 0; a->base_frames = a->base_janky = 0;   /* re-check */
    }
    switch (a->state) {
    case 0:
        if (arm != 0) return 0;
        a->base_frames += (uint32_t)df; a->base_janky += (uint32_t)dj;
        if (a->base_frames >= ASB_SMOOTH_TRIGGER_FRAMES &&
            (double)a->base_janky >= ASB_SMOOTH_TRIGGER_JANK * (double)a->base_frames) {
            a->state = 1; a->arm = 1;
            memset(a->t_frames, 0, sizeof(a->t_frames)); memset(a->t_janky, 0, sizeof(a->t_janky));
            memset(a->t_windows, 0, sizeof(a->t_windows));
            snprintf(g_smooth_event_msg, sizeof(g_smooth_event_msg),
                     "smooth: %s misses frames (%.1f %% of %u) - testing more headroom",
                     pkg ? pkg : "?", 100.0 * a->base_janky / a->base_frames, a->base_frames);
            g_smooth_event = 1;
            return 1;
        }
        if (a->base_frames > 200000) { a->base_frames /= 2; a->base_janky /= 2; }
        return 0;
    case 1: {
        if (arm != (int)a->arm) return 0;   /* the window ran under the other arm: not ours */
        a->t_frames[arm] += (uint32_t)df; a->t_janky[arm] += (uint32_t)dj; a->t_windows[arm]++;
        a->arm ^= 1;
        if (a->t_windows[0] < ASB_SMOOTH_MIN_WINDOWS || a->t_windows[1] < ASB_SMOOTH_MIN_WINDOWS ||
            a->t_frames[0] < ASB_SMOOTH_MIN_FRAMES || a->t_frames[1] < ASB_SMOOTH_MIN_FRAMES) return 0;
        double j0 = (double)a->t_janky[0] / a->t_frames[0];
        double j1 = (double)a->t_janky[1] / a->t_frames[1];
        if (j1 <= j0 * (1.0 - ASB_SMOOTH_GAIN_REL) && j0 - j1 >= ASB_SMOOTH_GAIN_ABS) {
            a->state = 2; a->decided_ts = (uint32_t)now; a->gain = (float)(1.0 - j1 / j0);
            snprintf(g_smooth_event_msg, sizeof(g_smooth_event_msg),
                     "smooth: %s - more headroom helps (janky %.1f %% -> %.1f %%), kept for it",
                     pkg ? pkg : "?", 100.0 * j0, 100.0 * j1);
        } else if (a->t_windows[0] >= ASB_SMOOTH_MAX_WINDOWS && a->t_windows[1] >= ASB_SMOOTH_MAX_WINDOWS) {
            a->state = 3; a->decided_ts = (uint32_t)now; a->gain = (float)((j0 > 0) ? 1.0 - j1 / j0 : 0.0);
            snprintf(g_smooth_event_msg, sizeof(g_smooth_event_msg),
                     "smooth: %s - headroom does not help (janky %.1f %% vs %.1f %%): its jank is not the clocks, left as it was",
                     pkg ? pkg : "?", 100.0 * j0, 100.0 * j1);
        } else {
            return 0;
        }
        g_smooth_event = 1;
        return 1;
    }
    default:
        return 0;
    }
}

/* ---- persistence ----------------------------------------------------------------------- */
static int asb_rec_save(void) {
    char tmp[160];
    snprintf(tmp, sizeof(tmp), "%s.tmp", ASB_REC_FILE);
    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    g_rec.magic = ASB_REC_MAGIC; g_rec.version = ASB_REC_VERSION; g_rec.size = sizeof(g_rec);
    size_t w = fwrite(&g_rec, 1, sizeof(g_rec), f);
    fflush(f);
    int ok = (w == sizeof(g_rec));
    fclose(f);
    if (!ok || rename(tmp, ASB_REC_FILE) != 0) { remove(tmp); return -1; }
    return 0;
}
/* fix184's layout (version 1), only to carry the night-check habit across: it is learned
 * the same way in both. Its situations measured milliamps one block at a time, which the
 * paired comparison cannot use, so those start over. */
typedef struct { uint32_t n, pad; double mean, m2, press; } asb_rec_stat_v1_t;
typedef struct {
    uint8_t  b[8];
    uint32_t u[5];
    asb_rec_stat_v1_t trial[2];
    float    record_ma;
    uint32_t record_n;
    float    record_press, baseline_ma;
    uint32_t baseline_n;
} asb_rec_ctx_v1_t;
typedef struct {
    uint32_t magic, version, size, pad;
    asb_rec_ctx_v1_t ctx[ASB_REC_CTX_N];
    asb_microwake_t  mw;
} asb_rec_store_v1_t;

static int asb_rec_mw_sane(const asb_microwake_t *w) {
    if (!(w->dur_ewma_s >= 0.0f && w->dur_ewma_s <= 7200.0f)) return 0;
    if (!(w->per_night_ewma >= 0.0f && w->per_night_ewma <= 100.0f)) return 0;
    for (int i = 0; i < ASB_MW_SLOTS; i++)
        if (!(w->slot_w[i] >= 0.0f && w->slot_w[i] <= 100000.0f)) return 0;
    return 1;
}

/* Returns 1 loaded, 2 carried over from fix184 (night checks only), 0 fresh start. */
static int asb_rec_load(void) {
    static union { asb_rec_store_t v2; asb_rec_store_v1_t v1; } u;
    static asb_rec_store_t s;
    int got = 0;
    FILE *f = fopen(ASB_REC_FILE, "rb");
    if (f) {
        memset(&u, 0, sizeof(u));
        size_t n = fread(&u, 1, sizeof(u), f);
        if (n == sizeof(u.v2) && u.v2.magic == ASB_REC_MAGIC &&
            u.v2.version == ASB_REC_VERSION && u.v2.size == sizeof(u.v2)) {
            s = u.v2; got = 1;
        } else if (n == sizeof(u.v1) && u.v1.magic == ASB_REC_MAGIC && u.v1.version == 1 &&
                   u.v1.size == sizeof(u.v1) && asb_rec_mw_sane(&u.v1.mw)) {
            got = 2;
        }
        fclose(f);
    }
    if (got == 2) {
        asb_microwake_t mw = u.v1.mw;
        asb_rec_store_init(&g_rec);
        g_rec.mw = mw;
        g_rec_loaded = 1;
        g_rec_dirty = 1;   /* written back in the new layout */
        return 2;
    }
    if (got) {
        for (int i = 0; i < ASB_REC_CTX_N; i++) {
            asb_rec_ctx_t *c = &s.ctx[i];
            if (c->champion >= ASB_REC_ARMS || c->challenger >= ASB_REC_ARMS ||
                (c->dir != 1 && c->dir != -1) || c->alt > 1 ||
                !(c->gain_total > 0.1f && c->gain_total < 10.0f)) asb_rec_ctx_init(c, i);
        }
        for (int i = 0; i < ASB_SMOOTH_APPS; i++)
            if (s.sm[i].state > 3 || s.sm[i].arm > 1) memset(&s.sm[i], 0, sizeof(s.sm[i]));
        g_rec = s;
    } else {
        asb_rec_store_init(&g_rec);
    }
    g_rec_loaded = 1;
    return got;
}

static void asb_rec_summary_write(void) {
    char tmp[160];
    snprintf(tmp, sizeof(tmp), "%s.tmp", ASB_REC_SUMMARY);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    const char *cc = g_rec_cc_state == 1 ? "ok" : g_rec_cc_state == -1 ? "unavailable"
                   : g_rec_cc_state == -2 ? "not_moving" : "waiting";
    fprintf(f, "# Smart records (Smart V5): power per situation, charge counter x battery voltage\n");
    fprintf(f, "counter=%s blocks_ok=%lu blocks_rejected=%lu\n", cc, g_rec_blocks_ok, g_rec_blocks_rejected);
    fprintf(f, "rejected");
    for (int r = 0; r < REJ_N; r++) fprintf(f, "|%s=%lu", g_rec_rej_names[r], g_rec_rej[r]);
    fprintf(f, "\n");
    fprintf(f, "# ctx|status|best|record_mW|record_mA|record_n|gain_pct|testing|pairs|pair_diff_pct|trials|wins|blocks|first_mW\n");
    for (int i = 0; i < ASB_REC_CTX_N; i++) {
        const asb_rec_ctx_t *c = &g_rec.ctx[i];
        char best[16], test[16];
        asb_rec_arm_label(i, c->champion, best, sizeof(best));
        if (c->challenger != c->champion) asb_rec_arm_label(i, c->challenger, test, sizeof(test));
        else snprintf(test, sizeof(test), "-");
        const char *st = asb_rec_status_name(c);
        fprintf(f, "%s|%s|%s|%.0f|%.1f|%u|%.1f|%s|%u|%.1f|%u|%u|%u|%.0f\n",
                g_rec_ctx_names[i], st, best, c->record_mw, c->record_ma, c->record_n,
                (1.0 - c->gain_total) * 100.0, test, c->pairs, c->pr_mean * 100.0,
                c->trials, c->wins, c->blocks, c->baseline_mw);
    }
    const asb_microwake_t *w = &g_rec.mw;
    int top = -1; float topw = 0;
    for (int s = 0; s < ASB_MW_SLOTS; s++) if (w->slot_w[s] > topw) { topw = w->slot_w[s]; top = s; }
    if (top >= 0)
        fprintf(f, "microwake|learned=%u|nights=%u|per_night=%.1f|typical_s=%.0f|usual=%02d:%02d-%02d:%02d\n",
                w->total, w->nights, w->per_night_ewma, w->dur_ewma_s,
                top / 2, (top % 2) * 30, ((top + 1) % 48) / 2, ((top + 1) % 2) * 30);
    else
        fprintf(f, "microwake|learned=%u|nights=%u|per_night=%.1f|typical_s=%.0f|usual=-\n",
                w->total, w->nights, w->per_night_ewma, w->dur_ewma_s);
    int sw = 0, st1 = 0, sh = 0, sn = 0;
    for (int i = 0; i < ASB_SMOOTH_APPS; i++) {
        if (!g_rec.sm[i].hash) continue;
        switch (g_rec.sm[i].state) { case 1: st1++; break; case 2: sh++; break; case 3: sn++; break; default: sw++; }
    }
    fprintf(f, "smooth|watching=%d|testing=%d|helped=%d|not_helped=%d\n", sw, st1, sh, sn);
    if (g_rec_event_msg[0]) fprintf(f, "last=%s\n", g_rec_event_msg);
    if (g_smooth_event_msg[0]) fprintf(f, "last_smooth=%s\n", g_smooth_event_msg);
    fclose(f);
    rename(tmp, ASB_REC_SUMMARY);
}
