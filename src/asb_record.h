#pragma once
/*
 * Smart records (fix184) - Smart measures what each situation costs, keeps the best setting
 * it has found for it, and keeps trying to beat it until it cannot.
 *
 * Until now Smart learned by direction only: a hot or drainy session pushed a bucket's lean
 * toward economy, a clean cool one pulled it back, a few thousandths at a time. Nothing ever
 * asked whether the new setting was actually cheaper than the old one, and the drain it
 * learned from was the battery percentage - 1 % steps, read over 20-minute sessions, where a
 * whole session's drain is often a single step.
 *
 * This layer measures instead of guessing:
 *
 *  - The meter is the fuel gauge's charge counter (power_supply/battery/charge_counter,
 *    1 mAh steps on every OnePlus in the captures - OP15 CPH2745/2747/2769, OP13, OP12
 *    CPH2691). Over a block it gives the real average current, suspend included, and it does
 *    not depend on the governor being awake to sample.
 *  - A block is a stretch of one situation: screen off at night or by day (40 min), or screen
 *    on with light apps or with ordinary ones (feeds, video, anything the package table does
 *    not call light or heavy), dim or bright (10 min). Blocks that are not about
 *    the setting are thrown away: charging, the screen-off radio busy (>= 15 KiB/s), the
 *    thermal veto, low battery, a thermal cap, the screen-off cooldown, heavy work and games.
 *  - Each situation has a champion setting and, while it explores, one challenger next to it.
 *    Blocks alternate between the two, so both see the same nights and the same days, and
 *    the challenger replaces the champion only when it is at least 3 % cheaper and the
 *    difference clears the block-to-block noise (Welch t >= 1.7). Screen on it must also not
 *    make the cores sit at their ceiling more often (+8 points at most) - cheaper by being
 *    slower is not a win. A challenger that is clearly worse is dropped early.
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
 * Night wakes are learned here too: the short check-ins of a night (on for a few minutes,
 * then back to sleep). Their time of night, length and number per night are remembered, and
 * a screen-on that looks like one keeps the night radio mode instead of switching the modem
 * to day mode and back.
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
#define ASB_REC_VERSION     1

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
#define ASB_REC_OFF_NMIN        6
#define ASB_REC_OFF_NMAX        16
#define ASB_REC_ON_NMIN         8
#define ASB_REC_ON_NMAX         20
#define ASB_REC_GAIN_MIN_X1000  30      /* 3 % cheaper at least */
#define ASB_REC_T2_X100         289     /* t >= 1.7, compared squared (no libm) */
#define ASB_REC_PRESS_SLACK     0.08    /* screen on: at most +8 points of time at the ceiling */
#define ASB_REC_PRESS_ABORT     0.15
#define ASB_REC_EARLY_WORSE     1.15    /* >= 15 % dearer after 3 blocks each: dropped */
#define ASB_REC_RECHECK_S       (21L * 24 * 3600)
#define ASB_REC_NET_KIBPS_MAX   15      /* screen off: above this the radio, not the CPU, sets the drain */
#define ASB_REC_BRIGHT_PCT      30
#define ASB_REC_SAVE_EVERY_S    900

typedef struct {
    uint32_t n;
    uint32_t pad;
    double   mean;     /* average current over a block, mA */
    double   m2;       /* Welford sum of squares */
    double   press;    /* mean share of screen-on ticks with a cluster at its ceiling, 0..1 */
} asb_rec_stat_t;

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
    float    record_ma;      /* the champion's mean when it last won or held */
    uint32_t record_n;
    float    record_press;
    float    baseline_ma;    /* today's setting (x1 / 0) as first measured */
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

typedef struct {
    uint32_t magic, version, size, pad;
    asb_rec_ctx_t   ctx[ASB_REC_CTX_N];
    asb_microwake_t mw;
} asb_rec_store_t;

typedef struct {
    int       active, ctx, slot, arm;
    long long t0_ms;
    long      cc0_uah;
    long long net0;
    int       ticks_on, ticks_press;
    int       ticks, ticks_busy;   /* screen off: ticks that were not quiet deep idle */
} asb_rec_block_t;

/* One tick of input. */
typedef struct {
    int       enabled;     /* Smart running and smart_records=1 */
    int       explore;     /* smart_records_explore=1 */
    int       screen_on, charging, heavy_state, app_medium;
    int       idle_state;  /* screen off: DEEP_IDLE and the CPU mostly asleep (not music, not a sync) */
    int       thermal_cap, cooldown, veto, lowbat, night, microwake;
    int       at_ceiling;  /* screen on: a cluster sat at its ceiling this tick */
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
static int    g_rec_event = 0;           /* last decision: 1 promoted, 2 held, 3 plateau */
static char   g_rec_event_msg[160];

static int asb_rec_is_off(int ctx) { return ctx == ASB_REC_OFF_NIGHT || ctx == ASB_REC_OFF_DAY; }
static int asb_rec_arm_value(int ctx, int arm) {
    if (arm < 0 || arm >= ASB_REC_ARMS) arm = ASB_REC_ARM_DEFAULT;
    return asb_rec_is_off(ctx) ? g_rec_off_scale_x1000[arm] : g_rec_on_offset_x1000[arm];
}
static void asb_rec_arm_label(int ctx, int arm, char *out, size_t n) {
    int v = asb_rec_arm_value(ctx, arm);
    if (asb_rec_is_off(ctx)) snprintf(out, n, "x%d.%03d", v / 1000, v % 1000);
    else                     snprintf(out, n, "%+d", v);
}

static void asb_rec_ctx_init(asb_rec_ctx_t *c, int ctx) {
    memset(c, 0, sizeof(*c));
    c->champion = c->challenger = ASB_REC_ARM_DEFAULT;
    /* First guess: screen off, lower ceilings; screen on, a little more economy. */
    c->dir = asb_rec_is_off(ctx) ? -1 : +1;
    c->prev_champion = 255;
}

static void asb_rec_store_init(asb_rec_store_t *s) {
    memset(s, 0, sizeof(*s));
    s->magic = ASB_REC_MAGIC; s->version = ASB_REC_VERSION; s->size = sizeof(*s);
    for (int i = 0; i < ASB_REC_CTX_N; i++) asb_rec_ctx_init(&s->ctx[i], i);
    s->mw.dur_ewma_s = 0;
}

static void asb_rec_stat_add(asb_rec_stat_t *st, double x, double press) {
    st->n++;
    double d = x - st->mean;
    st->mean += d / st->n;
    st->m2 += d * (x - st->mean);
    st->press += (press - st->press) / st->n;
}
static double asb_rec_var(const asb_rec_stat_t *st) {
    return (st->n > 1) ? st->m2 / (double)(st->n - 1) : 0.0;
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
            memset(c->trial, 0, sizeof(c->trial));
            c->alt = 0;
            return;
        }
        /* That side is exhausted: the end of the range, or the setting the champion has
         * already beaten. It counts as a lost challenge. */
        c->fails++;
        c->dir = (int8_t)-c->dir;
    }
    c->converged = 1; c->converged_ts = (uint32_t)now;
}

/* After each accepted block. 0 nothing yet, 1 challenger won, 2 champion held, 3 plateau. */
static int asb_rec_decide(asb_rec_ctx_t *c, int ctx, long now) {
    asb_rec_stat_t *a = &c->trial[0], *b = &c->trial[1];
    const int off  = asb_rec_is_off(ctx);
    const unsigned nmin = off ? ASB_REC_OFF_NMIN : ASB_REC_ON_NMIN;
    const unsigned nmax = off ? ASB_REC_OFF_NMAX : ASB_REC_ON_NMAX;
    if (c->challenger == c->champion) {
        /* Not exploring: the champion's running mean is the record. */
        if (a->n >= nmin) { c->record_ma = (float)a->mean; c->record_n = a->n; c->record_press = (float)a->press; }
        if (c->champion == ASB_REC_ARM_DEFAULT && c->baseline_n == 0 && a->n >= nmin) {
            c->baseline_ma = (float)a->mean; c->baseline_n = a->n;
        }
        return 0;
    }
    int verdict = 0;   /* 1 promote, 2 hold */
    if (a->n >= 3 && b->n >= 3 && b->mean >= a->mean * ASB_REC_EARLY_WORSE) verdict = 2;
    if (!off && a->n >= 4 && b->n >= 4 && b->press > a->press + ASB_REC_PRESS_ABORT) verdict = 2;
    if (!verdict && a->n >= nmin && b->n >= nmin) {
        double diff = a->mean - b->mean;
        double se2  = asb_rec_var(a) / a->n + asb_rec_var(b) / b->n;
        int sig     = (diff * diff * 100.0 >= (double)ASB_REC_T2_X100 * se2);
        int cheaper = (diff > 0 && diff * 1000.0 >= (double)ASB_REC_GAIN_MIN_X1000 * a->mean && sig);
        int comfy   = off || (b->press <= a->press + ASB_REC_PRESS_SLACK);
        if (cheaper && comfy) verdict = 1;
        else if ((a->n >= nmax && b->n >= nmax) || (diff < 0 && sig) || !comfy) verdict = 2;
    }
    if (c->champion == ASB_REC_ARM_DEFAULT && c->baseline_n == 0 && a->n >= nmin) {
        c->baseline_ma = (float)a->mean; c->baseline_n = a->n;
    }
    if (!verdict) return 0;
    c->trials++;
    if (verdict == 1) {
        c->prev_champion = c->champion;
        c->champion = c->challenger;
        c->record_ma = (float)b->mean; c->record_n = b->n; c->record_press = (float)b->press;
        c->wins++; c->fails = 0;
    } else {
        c->record_ma = (float)a->mean; c->record_n = a->n; c->record_press = (float)a->press;
        c->fails++;
        c->dir = (int8_t)-c->dir;
    }
    c->challenger = c->champion;
    memset(c->trial, 0, sizeof(c->trial));
    c->alt = 0;
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
    if (!in->screen_on) {
        /* Busy stretches (music, a sync) stay inside the block - both settings see them - and
         * are counted; a block that was mostly busy is set aside at the end. */
        if (!ignore_conditions && in->cooldown) return -1;
        return in->night ? ASB_REC_OFF_NIGHT : ASB_REC_OFF_DAY;
    }
    if (in->microwake || in->heavy_state) return -1;
    if (!ignore_conditions && (in->veto || in->lowbat)) return -1;
    int bright = (g_rec_bright_band == 1);
    if (g_rec_bright_band < 0) return -1;
    if (in->app_medium) return bright ? ASB_REC_ON_MEDIUM_BRIGHT : ASB_REC_ON_MEDIUM_DIM;
    return bright ? ASB_REC_ON_LIGHT_BRIGHT : ASB_REC_ON_LIGHT_DIM;
}

static void asb_rec_summary_write(void);

static void asb_rec_block_finish(const asb_rec_in_t *in) {
    asb_rec_block_t *k = &g_rec_blk;
    if (!k->active) return;
    k->active = 0;
    int ctx = k->ctx;
    long dur_s = (long)((in->now_ms - k->t0_ms) / 1000);
    int off = asb_rec_is_off(ctx);
    if (dur_s < (off ? ASB_REC_OFF_MIN_S : ASB_REC_ON_MIN_S)) return;   /* too short to mean anything */
    long cc1 = g_rec_read_cc ? g_rec_read_cc() : -1;
    if (k->cc0_uah <= 0 || cc1 <= 0) { g_rec_cc_state = -1; g_rec_blocks_rejected++; return; }
    if (cc1 > k->cc0_uah) { g_rec_blocks_rejected++; return; }          /* charge came in */
    if (cc1 == k->cc0_uah) {
        if (dur_s >= 600) g_rec_cc_state = -2;                          /* the gauge did not move */
        g_rec_blocks_rejected++;
        return;
    }
    g_rec_cc_state = 1;
    double ma = ((double)(k->cc0_uah - cc1) / 1000.0) / ((double)dur_s / 3600.0);
    if (ma < 1.0 || ma > 6000.0) { g_rec_blocks_rejected++; return; }
    if (off && k->ticks >= 4 && k->ticks_busy * 4 > k->ticks) { g_rec_blocks_rejected++; return; }
    if (off && k->net0 >= 0 && g_rec_read_net) {
        long long n1 = g_rec_read_net();
        if (n1 >= k->net0 && (n1 - k->net0) / 1024 / dur_s >= ASB_REC_NET_KIBPS_MAX) {
            g_rec_blocks_rejected++;
            return;
        }
    }
    double press = (k->ticks_on > 0) ? (double)k->ticks_press / k->ticks_on : 0.0;
    asb_rec_ctx_t *c = &g_rec.ctx[ctx];
    /* A block measured under a challenge that has since ended belongs to nobody. */
    int slot = k->slot;
    if (slot == 1 && c->challenger == c->champion) { g_rec_blocks_rejected++; return; }
    if ((slot == 0 && k->arm != c->champion) || (slot == 1 && k->arm != c->challenger)) {
        g_rec_blocks_rejected++; return;
    }
    asb_rec_stat_add(&c->trial[slot], ma, press);
    c->blocks++; c->last_ts = (uint32_t)in->wall;
    if (c->challenger != c->champion) c->alt ^= 1;
    g_rec_blocks_ok++;
    g_rec_dirty = 1;
    char arm_s[16]; asb_rec_arm_label(ctx, k->arm, arm_s, sizeof(arm_s));
    int prev = c->champion;
    int ev = asb_rec_decide(c, ctx, in->wall);
    if (ev) {
        char ch_s[16], pv_s[16];
        asb_rec_arm_label(ctx, c->champion, ch_s, sizeof(ch_s));
        asb_rec_arm_label(ctx, prev, pv_s, sizeof(pv_s));
        g_rec_event = ev;
        if (ev == 1)
            snprintf(g_rec_event_msg, sizeof(g_rec_event_msg),
                     "records: %s new best %s at %.1f mA (was %s) after %u trial(s)",
                     g_rec_ctx_names[ctx], ch_s, c->record_ma, pv_s, c->trials);
        else if (ev == 2)
            snprintf(g_rec_event_msg, sizeof(g_rec_event_msg),
                     "records: %s %s holds at %.1f mA - the neighbour was not cheaper",
                     g_rec_ctx_names[ctx], ch_s, c->record_ma);
        else
            snprintf(g_rec_event_msg, sizeof(g_rec_event_msg),
                     "records: %s plateau - %s is the best found (%.1f mA, %u win(s)); re-check in 21 days",
                     g_rec_ctx_names[ctx], ch_s, c->record_ma, c->wins);
        g_rec_saved_ts = 0;   /* save now */
    }
    (void)arm_s;
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
}

static int asb_rec_save(void);

/* Persist what changed - blocks, decisions, night wakes - at most every 15 minutes, at once
 * after a decision. */
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
            g_rec_blk.ticks++;
            if (in->screen_on) {
                g_rec_blk.ticks_on++;
                if (in->at_ceiling) g_rec_blk.ticks_press++;
            } else if (!in->idle_state) {
                g_rec_blk.ticks_busy++;
            }
        }
    }
    if (!g_rec_blk.active && ctx >= 0) asb_rec_block_start(in, ctx);

    /* The knobs: the block's setting while one runs, the champion otherwise. Outside a
     * measurable situation (charging, veto, ...) the champion still applies - that is the
     * point of having learned it - but never under heavy work, a game or a night check. */
    int kctx = g_rec_blk.active ? g_rec_blk.ctx : asb_rec_ctx_of(in, 1);
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
/* Returns 1 loaded, 0 fresh start. */
static int asb_rec_load(void) {
    asb_rec_store_t s;
    int got = 0;
    FILE *f = fopen(ASB_REC_FILE, "rb");
    if (f) {
        if (fread(&s, 1, sizeof(s), f) == sizeof(s) && s.magic == ASB_REC_MAGIC &&
            s.version == ASB_REC_VERSION && s.size == sizeof(s)) got = 1;
        fclose(f);
    }
    if (got) {
        for (int i = 0; i < ASB_REC_CTX_N; i++) {
            asb_rec_ctx_t *c = &s.ctx[i];
            if (c->champion >= ASB_REC_ARMS || c->challenger >= ASB_REC_ARMS ||
                (c->dir != 1 && c->dir != -1) || c->alt > 1) asb_rec_ctx_init(c, i);
        }
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
    fprintf(f, "# Smart records (fix184): average current per situation, from the charge counter\n");
    fprintf(f, "counter=%s blocks_ok=%lu blocks_rejected=%lu\n", cc, g_rec_blocks_ok, g_rec_blocks_rejected);
    fprintf(f, "# ctx|status|best|record_mA|record_n|baseline_mA|vs_baseline_pct|testing|best_n,best_mA|test_n,test_mA|trials|wins|blocks\n");
    for (int i = 0; i < ASB_REC_CTX_N; i++) {
        const asb_rec_ctx_t *c = &g_rec.ctx[i];
        char best[16], test[16];
        asb_rec_arm_label(i, c->champion, best, sizeof(best));
        if (c->challenger != c->champion) asb_rec_arm_label(i, c->challenger, test, sizeof(test));
        else snprintf(test, sizeof(test), "-");
        const char *st = c->converged ? "plateau"
                       : (c->challenger != c->champion) ? "testing"
                       : (c->record_n > 0) ? "holding" : "measuring";
        int vs = 0;
        if (c->baseline_n > 0 && c->baseline_ma > 0 && c->record_n > 0)
            vs = (int)((c->record_ma - c->baseline_ma) * 100.0f / c->baseline_ma);
        fprintf(f, "%s|%s|%s|%.1f|%u|%.1f|%d|%s|%u,%.1f|%u,%.1f|%u|%u|%u\n",
                g_rec_ctx_names[i], st, best, c->record_ma, c->record_n, c->baseline_ma, vs, test,
                c->trial[0].n, c->trial[0].mean, c->trial[1].n, c->trial[1].mean,
                c->trials, c->wins, c->blocks);
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
    if (g_rec_event_msg[0]) fprintf(f, "last=%s\n", g_rec_event_msg);
    fclose(f);
    rename(tmp, ASB_REC_SUMMARY);
}
