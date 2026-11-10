#pragma once
/*
 * Smart V7 (V66): what using the phone costs, and when it is usually charged.
 *
 *  - Per app: with the screen on and the charger out, the battery's own current times its
 *    voltage is credited, tick by tick, to the app in front. The figure includes the screen
 *    at the brightness that was used and whatever ran in the background at the time: it is
 *    what an hour in that app costs on this phone, not what the app alone draws.
 *  - Per kind of use: a screen-on stretch under 90 s is a glance; a longer one takes the kind
 *    of app it spent most of its time in - light, media and feeds, heavy work or a game.
 *  - The charging habit: when the charger goes in, by half hour, weekdays and weekends apart.
 *    Smart's battery budget compares the hours the battery has left at the current drain with
 *    the hours until the usual charge (asb_smart_apply_energy_budget).
 *
 * Everything fades by 3 % a day, so the figures follow the last weeks of use. Pure logic: the
 * governor feeds one tick, the tests feed their own.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#ifndef ASB_EN_FILE
#define ASB_EN_FILE         "/data/adb/asb/smart_energy.bin"
#endif
#ifndef ASB_EN_SUMMARY
#define ASB_EN_SUMMARY      "/dev/.asb/smart_energy.txt"
#endif
#define ASB_EN_MAGIC        0x4153454eu
#define ASB_EN_VERSION      3     /* 2 (dev5): mW on the real scale; 3 (dev6): the screen-on share counts long gaps */
#define ASB_EN_GAP_MAX_MS   (6LL * 3600 * 1000)
#define ASB_EN_APPS         32
#define ASB_EN_SLOTS        48
#define ASB_EN_GLANCE_S     90
#define ASB_EN_TICK_MAX_MS  30000
#define ASB_EN_DECAY        0.97f
#define ASB_EN_SAVE_EVERY_S 1800
#define ASB_EN_PLUG_MIN_W   3.0f    /* about three charges in that half hour before it counts */
#define ASB_EN_REPLUG_S     600     /* a charger back within 10 minutes is the same charge */

#ifndef ASB_EN_PLUG_ETA_DECLARED
#define ASB_EN_PLUG_ETA_DECLARED
static int g_en_plug_eta_min = -1;   /* minutes until the usual charge, -1 unknown */
static int g_en_mix_rate_x10 = -1;   /* the drain until then, %/h x10, screen on and off mixed */
static int g_en_budget_plug = 0;     /* 1 the usual charge is too far, -1 near enough to relax */
#endif

static int g_en_gauge_x100 = -1;     /* this phone's current reading as x100 of the real drain, -1 not known yet */
static int g_en_gauge_windows = 0;   /* how many drain windows that factor stands on */

enum { EN_GLANCE = 0, EN_LIGHT, EN_MEDIA, EN_HEAVY, EN_GAME, EN_CLASSES };
static const char *const g_en_class_names[EN_CLASSES] = { "glance", "light", "media", "heavy", "game" };

typedef struct {
    uint64_t hash;
    char     pkg[64];
    float    j;          /* energy, joules */
    float    s;          /* measured seconds in front */
    uint32_t last_ts;
    uint32_t pad;
} asb_en_app_t;

typedef struct { float n, s, j; } asb_en_class_t;

typedef struct {
    uint32_t       magic, version, size, day;
    asb_en_app_t   app[ASB_EN_APPS];
    asb_en_class_t cls[EN_CLASSES];
    float          plug[2][ASB_EN_SLOTS];   /* [0] weekdays, [1] weekends */
    uint32_t       plugs, last_plug_ts;
    float          on_s, off_s;             /* off the charger: time with the screen on and off */
} asb_en_store_t;

typedef struct {
    int         screen_on, charging;
    int         ma;            /* battery current, mA, discharge magnitude */
    int         voltage_uv;
    int         hint;          /* the app in front: 0 idle, 1 light, 2 medium, 3 heavy, 4 game */
    uint64_t    app_hash;
    const char *pkg;
    long long   now_ms;        /* CLOCK_BOOTTIME */
    long        wall;
} asb_en_in_t;

static asb_en_store_t g_en;
static int       g_en_loaded = 0, g_en_dirty = 0;
static long      g_en_saved_ts = 0, g_en_eta_ts = 0;
static long long g_en_prev_ms = 0;
static int       g_en_prev_on = -1, g_en_prev_chg = -1;
static long      g_en_unplug_ts = 0;
static long long g_en_ses_t0_ms = 0;
static float     g_en_ses_j = 0.0f, g_en_ses_s = 0.0f, g_en_ses_hint_s[5];
static int       g_en_class_now = -1;          /* the kind of use so far in this stretch */
/* V66 dev8: the stretch that just ended, for the Smart lab's wake-lift test. */
static unsigned  g_en_ses_seq = 0;
static float     g_en_ses_last_dur = 0.0f, g_en_ses_last_j = 0.0f, g_en_ses_last_s = 0.0f;

static void asb_en_init(asb_en_store_t *s) {
    memset(s, 0, sizeof(*s));
    s->magic = ASB_EN_MAGIC; s->version = ASB_EN_VERSION; s->size = sizeof(*s);
}

static int asb_en_local(long wall, int *slot) {
    struct tm tmv;
    time_t t = (time_t)wall;
    if (!localtime_r(&t, &tmv)) { *slot = -1; return 0; }
    *slot = (tmv.tm_hour * 60 + tmv.tm_min) / 30;
    return (tmv.tm_wday == 0 || tmv.tm_wday == 6) ? 1 : 0;
}

static void asb_en_decay_to(long wall) {
    uint32_t day = (uint32_t)(wall / 86400L);
    if (g_en.day == 0) { g_en.day = day; return; }
    if (day <= g_en.day) return;
    uint32_t n = day - g_en.day;
    if (n > 60) n = 60;
    float f = 1.0f;
    for (uint32_t i = 0; i < n; i++) f *= ASB_EN_DECAY;
    for (int i = 0; i < ASB_EN_APPS; i++) { g_en.app[i].j *= f; g_en.app[i].s *= f; }
    for (int i = 0; i < EN_CLASSES; i++) { g_en.cls[i].n *= f; g_en.cls[i].s *= f; g_en.cls[i].j *= f; }
    for (int w = 0; w < 2; w++) for (int i = 0; i < ASB_EN_SLOTS; i++) g_en.plug[w][i] *= f;
    g_en.on_s *= f; g_en.off_s *= f;
    g_en.day = day;
    g_en_dirty = 1;
}

static asb_en_app_t *asb_en_app(uint64_t hash, const char *pkg, long wall) {
    if (!hash || !pkg || !pkg[0]) return NULL;
    int low = 0;
    for (int i = 0; i < ASB_EN_APPS; i++) {
        if (g_en.app[i].hash == hash) return &g_en.app[i];
        if (g_en.app[i].j < g_en.app[low].j) low = i;
    }
    asb_en_app_t *a = &g_en.app[low];
    memset(a, 0, sizeof(*a));
    a->hash = hash;
    snprintf(a->pkg, sizeof(a->pkg), "%s", pkg);
    a->last_ts = (uint32_t)wall;
    return a;
}

static int asb_en_class_of(float dur_s, const float *hint_s) {
    if (dur_s < ASB_EN_GLANCE_S) return EN_GLANCE;
    float light = hint_s[0] + hint_s[1];
    int best = EN_LIGHT; float bw = light;
    if (hint_s[2] > bw) { best = EN_MEDIA; bw = hint_s[2]; }
    if (hint_s[3] > bw) { best = EN_HEAVY; bw = hint_s[3]; }
    if (hint_s[4] > bw) { best = EN_GAME; }
    return best;
}

static void asb_en_session_close(long long now_ms) {
    if (g_en_ses_t0_ms <= 0) return;
    float dur = (float)((double)(now_ms - g_en_ses_t0_ms) / 1000.0);
    g_en_ses_t0_ms = 0;
    g_en_class_now = -1;
    g_en_ses_last_dur = dur; g_en_ses_last_j = g_en_ses_j; g_en_ses_last_s = g_en_ses_s;
    g_en_ses_seq++;
    if (g_en_ses_s < 10.0f) return;   /* mostly on the charger: no figure */
    int c = asb_en_class_of(dur, g_en_ses_hint_s);
    g_en.cls[c].n += 1.0f;
    g_en.cls[c].s += g_en_ses_s;
    g_en.cls[c].j += g_en_ses_j;
    g_en_dirty = 1;
}

/* Minutes until the usual charge: the first half hour ahead, within a day, that holds at least
 * half of the busiest half hour of its kind of day and about three charges. -1 when the habit
 * is not clear yet. 0 inside that half hour. */
static int asb_en_plug_eta(long wall) {
    float wmax[2] = { 0.0f, 0.0f };
    for (int w = 0; w < 2; w++)
        for (int i = 0; i < ASB_EN_SLOTS; i++) if (g_en.plug[w][i] > wmax[w]) wmax[w] = g_en.plug[w][i];
    int slot0;
    asb_en_local(wall, &slot0);
    if (slot0 < 0) return -1;
    long into = wall % 1800L;
    for (int k = 0; k < ASB_EN_SLOTS; k++) {
        int slot;
        int wk = asb_en_local(wall + (long)k * 1800L, &slot);
        if (slot < 0 || wmax[wk] < ASB_EN_PLUG_MIN_W) continue;
        if (g_en.plug[wk][slot] >= wmax[wk] * 0.5f) {
            long m = k == 0 ? 0 : ((long)k * 1800L - into) / 60L;
            return (int)(m < 0 ? 0 : m);
        }
    }
    return -1;
}

/* The drain until the usual charge: the screen-on rate for the share of time the screen is on
 * (off the charger, over the last weeks), the screen-off rate for the rest. Without a
 * screen-off figure, an eighth of the screen-on rate. -1 until a day's worth of time is in. */
static int asb_en_mix_rate(int on_x10, int off_x100) {
    float tot = g_en.on_s + g_en.off_s;
    if (on_x10 <= 0 || tot < 86400.0f * 0.5f) return -1;
    float share = g_en.on_s / tot;
    float off_x10 = off_x100 >= 0 ? (float)off_x100 / 10.0f : (float)on_x10 / 8.0f;
    int r = (int)((float)on_x10 * share + off_x10 * (1.0f - share) + 0.5f);
    return r < 1 ? 1 : r;
}

static void asb_en_summary_write(void);
static int asb_en_save(void);

static void asb_en_tick(const asb_en_in_t *in) {
    if (!g_en_loaded) return;
    asb_en_decay_to(in->wall);
    long long gap_ms = (g_en_prev_ms > 0) ? in->now_ms - g_en_prev_ms : 0;
    long long dt_ms = gap_ms;
    g_en_prev_ms = in->now_ms;
    if (dt_ms <= 0 || dt_ms > ASB_EN_TICK_MAX_MS) dt_ms = 0;
    /* dev6: the share of time with the screen on takes the whole gap since the last tick, in
     * the state the phone was in during it. dev4 counted only gaps of 30 s or less, and with the
     * screen off the governor ticks far less often than that - an OP15 day read 96-97 % screen
     * on for a capture that had it on 60 % of the time, which made the drain until the usual
     * charge look like a day of screen-on use. Suspend counts as screen-off time, as it is. */
    if (gap_ms > 0 && gap_ms <= ASB_EN_GAP_MAX_MS && g_en_prev_chg == 0 && g_en_prev_on >= 0) {
        if (g_en_prev_on == 1) g_en.on_s += (float)gap_ms / 1000.0f;
        else                   g_en.off_s += (float)gap_ms / 1000.0f;
    }

    if (g_en_prev_chg == 0 && in->charging) {
        if (!(g_en_unplug_ts > 0 && in->wall - g_en_unplug_ts < ASB_EN_REPLUG_S)) {
            int slot;
            int wk = asb_en_local(in->wall, &slot);
            if (slot >= 0) {
                g_en.plug[wk][slot] += 1.0f;
                g_en.plugs++;
                g_en.last_plug_ts = (uint32_t)in->wall;
                g_en_dirty = 1;
                g_en_saved_ts = 0;
            }
        }
    }
    if (g_en_prev_chg == 1 && !in->charging) g_en_unplug_ts = in->wall;
    g_en_prev_chg = in->charging ? 1 : 0;

    if (in->screen_on && g_en_prev_on != 1) {
        g_en_ses_t0_ms = in->now_ms;
        g_en_ses_j = 0.0f; g_en_ses_s = 0.0f;
        memset(g_en_ses_hint_s, 0, sizeof(g_en_ses_hint_s));
        dt_ms = 0;
    } else if (!in->screen_on && g_en_prev_on == 1) {
        asb_en_session_close(in->now_ms);
    }
    g_en_prev_on = in->screen_on ? 1 : 0;

    if (in->screen_on && !in->charging && dt_ms > 0 && in->ma > 0 && in->ma < 8000 &&
        in->voltage_uv > 3000000 && in->voltage_uv < 4800000) {
        float dt = (float)dt_ms / 1000.0f;
        float j = (float)in->ma * ((float)in->voltage_uv / 1e6f) * dt / 1000.0f;
        g_en_ses_j += j; g_en_ses_s += dt;
        int h = (in->hint >= 0 && in->hint <= 4) ? in->hint : 0;
        g_en_ses_hint_s[h] += dt;
        asb_en_app_t *a = asb_en_app(in->app_hash, in->pkg, in->wall);
        if (a) { a->j += j; a->s += dt; a->last_ts = (uint32_t)in->wall; }
        g_en_dirty = 1;
    }
    if (in->screen_on && g_en_ses_t0_ms > 0)
        g_en_class_now = asb_en_class_of((float)((double)(in->now_ms - g_en_ses_t0_ms) / 1000.0), g_en_ses_hint_s);

    if (g_en_eta_ts == 0 || in->wall - g_en_eta_ts >= 60 || in->wall < g_en_eta_ts) {
        g_en_eta_ts = in->wall;
        g_en_plug_eta_min = asb_en_plug_eta(in->wall);
    }
    if (g_en_dirty && (g_en_saved_ts == 0 || in->wall - g_en_saved_ts >= ASB_EN_SAVE_EVERY_S || in->wall < g_en_saved_ts)) {
        if (asb_en_save() == 0) { g_en_dirty = 0; g_en_saved_ts = in->wall; }
        asb_en_summary_write();
    }
}

static int asb_en_save(void) {
    char tmp[160];
    snprintf(tmp, sizeof(tmp), "%s.tmp", ASB_EN_FILE);
    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    g_en.magic = ASB_EN_MAGIC; g_en.version = ASB_EN_VERSION; g_en.size = sizeof(g_en);
    size_t w = fwrite(&g_en, 1, sizeof(g_en), f);
    fflush(f);
    int ok = (w == sizeof(g_en));
    fclose(f);
    if (!ok || rename(tmp, ASB_EN_FILE) != 0) { remove(tmp); return -1; }
    return 0;
}

static int asb_en_finite(float v, float hi) { return v >= 0.0f && v <= hi; }

/* 1 loaded, 0 fresh start (none, or not sane). */
static int asb_en_load(void) {
    static asb_en_store_t s;
    int got = 0;
    FILE *f = fopen(ASB_EN_FILE, "rb");
    if (f) {
        memset(&s, 0, sizeof(s));
        size_t n = fread(&s, 1, sizeof(s), f);
        fclose(f);
        if (n == sizeof(s) && s.magic == ASB_EN_MAGIC && (s.version == ASB_EN_VERSION || s.version == 2) &&
            s.size == sizeof(s)) {
            if (s.version == 2) { s.on_s = 0.0f; s.off_s = 0.0f; s.version = ASB_EN_VERSION; }
            got = 1;
            for (int i = 0; i < ASB_EN_APPS && got; i++) {
                s.app[i].pkg[sizeof(s.app[i].pkg) - 1] = 0;
                if (!asb_en_finite(s.app[i].j, 1e9f) || !asb_en_finite(s.app[i].s, 1e9f)) got = 0;
            }
            for (int i = 0; i < EN_CLASSES && got; i++)
                if (!asb_en_finite(s.cls[i].n, 1e7f) || !asb_en_finite(s.cls[i].s, 1e9f) || !asb_en_finite(s.cls[i].j, 1e10f)) got = 0;
            for (int w = 0; w < 2 && got; w++)
                for (int i = 0; i < ASB_EN_SLOTS; i++) if (!asb_en_finite(s.plug[w][i], 1e5f)) { got = 0; break; }
            if (got && (!asb_en_finite(s.on_s, 1e9f) || !asb_en_finite(s.off_s, 1e9f))) got = 0;
        }
    }
    if (got) g_en = s; else asb_en_init(&g_en);
    g_en_loaded = 1;
    return got;
}

static void asb_en_summary_write(void) {
    char tmp[160];
    snprintf(tmp, sizeof(tmp), "%s.tmp", ASB_EN_SUMMARY);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "# Smart V7 energy: screen on, off the charger; battery current x voltage on the real scale; fades 3 %% a day\n");
    fprintf(f, "meter|gauge_x100=%d|windows=%d|confidence=%s|basis=%s\n", g_en_gauge_x100, g_en_gauge_windows,
            g_en_gauge_x100 <= 0 ? "low" : (g_en_gauge_windows >= 30 ? "high" : (g_en_gauge_windows >= 5 ? "medium" : "low")),
            g_en_gauge_x100 > 0 ? "gauge_corrected" : "current_raw");
    float total = 0.0f;
    for (int i = 0; i < ASB_EN_APPS; i++) total += g_en.app[i].j;
    fprintf(f, "# app|pkg|minutes|avg_mW|share_pct\n");
    int used[ASB_EN_APPS] = {0};
    for (int r = 0; r < 12; r++) {
        int best = -1;
        for (int i = 0; i < ASB_EN_APPS; i++)
            if (!used[i] && g_en.app[i].hash && g_en.app[i].s >= 60.0f &&
                (best < 0 || g_en.app[i].j > g_en.app[best].j)) best = i;
        if (best < 0) break;
        used[best] = 1;
        const asb_en_app_t *a = &g_en.app[best];
        fprintf(f, "app|%s|%.0f|%.0f|%.1f\n", a->pkg, a->s / 60.0f, a->j * 1000.0f / a->s,
                total > 0.0f ? a->j * 100.0f / total : 0.0f);
    }
    fprintf(f, "# class|name|sessions|minutes|avg_mW\n");
    for (int i = 0; i < EN_CLASSES; i++) {
        const asb_en_class_t *c = &g_en.cls[i];
        fprintf(f, "class|%s|%.1f|%.0f|%.0f\n", g_en_class_names[i], c->n, c->s / 60.0f,
                c->s > 0.0f ? c->j * 1000.0f / c->s : 0.0f);
    }
    int ws = -1, wsw = -1; float wm = 0.0f, wmw = 0.0f;
    for (int i = 0; i < ASB_EN_SLOTS; i++) {
        if (g_en.plug[0][i] > wm) { wm = g_en.plug[0][i]; ws = i; }
        if (g_en.plug[1][i] > wmw) { wmw = g_en.plug[1][i]; wsw = i; }
    }
    char wd[16] = "-", we[16] = "-";
    if (ws >= 0 && wm >= ASB_EN_PLUG_MIN_W) snprintf(wd, sizeof(wd), "%02d:%02d", ws / 2, (ws % 2) * 30);
    if (wsw >= 0 && wmw >= ASB_EN_PLUG_MIN_W) snprintf(we, sizeof(we), "%02d:%02d", wsw / 2, (wsw % 2) * 30);
    fprintf(f, "plug|charges=%u|weekday=%s|weekend=%s|eta_min=%d|mix_x10=%d|budget=%d|on_pct=%.0f\n", g_en.plugs,
            wd, we, g_en_plug_eta_min, g_en_mix_rate_x10, g_en_budget_plug,
            (g_en.on_s + g_en.off_s) > 0.0f ? g_en.on_s * 100.0f / (g_en.on_s + g_en.off_s) : 0.0f);
    fclose(f);
    rename(tmp, ASB_EN_SUMMARY);
}
