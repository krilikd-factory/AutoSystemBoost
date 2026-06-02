#ifndef ASB_SMART_H
#define ASB_SMART_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <ctype.h>

#include "asb_smart_defs.h"

typedef struct {
    uint32_t bucket_id;
    uint32_t observations_raw;
    uint32_t last_seen_ts;

    uint16_t eff_obs_x100;
    uint16_t conf_x1000;

    uint16_t alpha_battery_x1000;
    int16_t  interactive_bonus_x1000;
    int16_t  idle_bias_x1000;
    uint16_t sleep_bias_x1000;
    uint16_t net_conservative_x1000;

    uint16_t avg_idle_q_x10;
    uint16_t avg_wph_x10;
    uint16_t avg_drain_mahph_x10;
    uint16_t avg_max_temp_x10;
} asb_smart_bucket_t;

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t bucket_count;
    uint32_t last_update_ts;
    uint32_t reserved;
    asb_smart_bucket_t buckets[ASB_SMART_BUCKETS];
} asb_smart_store_t;

typedef struct {
    int enabled;
    int fresh_install_default;

    int bucket_id;
    int prev_bucket_id;
    int is_weekend;
    int daypart;
    int prev_daypart;
    int fallback_level;

    int app_hint;
    uint64_t app_hash;
    uint64_t app_hash_session_top;
    int app_hint_session_top;
    time_t app_cache_last_refresh;
    char app_pkg_cached[64];

    int night_safe_override;
    int thermal_veto;

    int conf_x1000;
    int alpha_battery_x1000;
    int interactive_bonus_x1000;
    int idle_bias_x1000;
    int sleep_bias_x1000;
    int net_conservative_x1000;

    time_t last_slot_update_ts;
    int last_conf_tier;
    int last_charging;
    int last_app_hint_tier;
    int last_night_override;
    int last_thermal_veto;

    time_t smoothing_start_ts;
    int smoothing_active;
    uint16_t smoothing_from_alpha_x1000;
    uint16_t smoothing_to_alpha_x1000;
    int exact_bucket_hits;
    int fallback_hits;
} asb_smart_runtime_t;

static inline int asb_clamp_int(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static inline uint16_t asb_clamp_u16(int v, int lo, int hi) {
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return (uint16_t)v;
}

static inline int16_t asb_clamp_i16(int v, int lo, int hi) {
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return (int16_t)v;
}

static int asb_smart_daypart_now(time_t now) {
    struct tm tmv;
    struct tm *tmp;
#if defined(_GNU_SOURCE) || defined(_POSIX_C_SOURCE)
    tmp = localtime_r(&now, &tmv);
#else
    tmp = localtime(&now);
    if (tmp) tmv = *tmp;
#endif
    if (!tmp) return ASB_DAYPART_DAY;
    int h = tmv.tm_hour;
    if (h <  ASB_SMART_DAYPART_WAKE_START) return ASB_DAYPART_SLEEP;
    if (h <  ASB_SMART_DAYPART_MORN_START) return ASB_DAYPART_WAKE;
    if (h <  ASB_SMART_DAYPART_DAY_START)  return ASB_DAYPART_MORN;
    if (h <  ASB_SMART_DAYPART_EVE_START)  return ASB_DAYPART_DAY;
    if (h <  ASB_SMART_DAYPART_LATE_START) return ASB_DAYPART_EVE;
    return ASB_DAYPART_LATE;
}

static int asb_smart_is_weekend(time_t now) {
    struct tm tmv;
    struct tm *tmp;
#if defined(_GNU_SOURCE) || defined(_POSIX_C_SOURCE)
    tmp = localtime_r(&now, &tmv);
#else
    tmp = localtime(&now);
    if (tmp) tmv = *tmp;
#endif
    if (!tmp) return 0;
    return (tmv.tm_wday == 0 || tmv.tm_wday == 6) ? 1 : 0;
}

static uint32_t asb_smart_bucket_id(int daypart, int is_weekend) {
    if (daypart < 0 || daypart >= ASB_SMART_DAYPARTS) daypart = ASB_DAYPART_DAY;
    if (is_weekend != 0 && is_weekend != 1) is_weekend = 0;
    return (uint32_t)(daypart * 2 + is_weekend);
}

__attribute__((unused))
static uint64_t asb_smart_pkg_hash64(const char *pkg) {
    if (!pkg || !*pkg) return 0ull;
    /* FNV-1a 64-bit */
    uint64_t h = 0xcbf29ce484222325ull;
    while (*pkg) {
        h ^= (uint64_t)(unsigned char)(*pkg++);
        h *= 0x100000001b3ull;
    }
    return h;
}

__attribute__((unused))
static int asb_smart_app_hint_from_pkg(const char *pkg) {
    if (!pkg || !*pkg) return ASB_APP_IDLE;
    /* Heuristic mapping. User can override via /data/adb/asb/app_categories.conf
     * in future revisions. V48 alpha: built-in table only. */
    struct map_entry { const char *prefix; int hint; };
    static const struct map_entry T[] = {
        { "com.activision.callofduty", ASB_APP_GAMING },
        { "com.tencent.ig",            ASB_APP_GAMING },
        { "com.pubg.imobile",          ASB_APP_GAMING },
        { "com.pubg.krmobile",         ASB_APP_GAMING },
        { "com.miHoYo.GenshinImpact",  ASB_APP_GAMING },
        { "com.miHoYo.hkrpg",          ASB_APP_GAMING },
        { "com.dts.freefireth",        ASB_APP_GAMING },
        { "com.garena.game",           ASB_APP_GAMING },
        { "com.gameloft.android",      ASB_APP_GAMING },
        { "com.supercell.clashroyale", ASB_APP_GAMING },
        { "com.king.candycrushsaga",   ASB_APP_HEAVY  },
        { "com.adobe.lrmobile",        ASB_APP_HEAVY  },
        { "com.adobe.psmobile",        ASB_APP_HEAVY  },
        { "com.google.android.apps.maps", ASB_APP_HEAVY },
        { "com.google.earth",          ASB_APP_HEAVY  },
        { "com.google.android.youtube",ASB_APP_MEDIUM },
        { "com.netflix.mediaclient",   ASB_APP_MEDIUM },
        { "com.spotify.music",         ASB_APP_MEDIUM },
        { "com.amazon.avod",           ASB_APP_MEDIUM },
        { "com.android.chrome",        ASB_APP_MEDIUM },
        { "com.brave.browser",         ASB_APP_MEDIUM },
        { "com.opera.browser",         ASB_APP_MEDIUM },
        { "org.mozilla.firefox",       ASB_APP_MEDIUM },
        { "com.google.android.gm",     ASB_APP_LIGHT  },
        { "org.telegram.messenger",    ASB_APP_LIGHT  },
        { "com.whatsapp",              ASB_APP_LIGHT  },
        { "com.discord",               ASB_APP_LIGHT  },
        { "com.facebook.katana",       ASB_APP_LIGHT  },
        { "com.instagram.android",     ASB_APP_LIGHT  },
        { "com.twitter.android",       ASB_APP_LIGHT  },
        { "com.viber.voip",            ASB_APP_LIGHT  },
        { "com.google.android.apps.messaging", ASB_APP_LIGHT },
        { NULL, 0 }
    };
    for (int i = 0; T[i].prefix; i++) {
        size_t pl = strlen(T[i].prefix);
        if (strncmp(pkg, T[i].prefix, pl) == 0) return T[i].hint;
    }
    return ASB_APP_MEDIUM;
}

static void asb_smart_store_seed_defaults(asb_smart_store_t *st) {
    if (!st) return;
    memset(st, 0, sizeof(*st));
    st->magic = ASB_SMART_MAGIC;
    st->version = ASB_SMART_VER;
    st->bucket_count = ASB_SMART_BUCKETS;
    st->last_update_ts = (uint32_t)time(NULL);
    for (int dp = 0; dp < ASB_SMART_DAYPARTS; dp++) {
        for (int we = 0; we < 2; we++) {
            uint32_t bid = (uint32_t)(dp * 2 + we);
            asb_smart_bucket_t *b = &st->buckets[bid];
            b->bucket_id = bid;
            b->observations_raw = 0;
            b->last_seen_ts = 0;
            b->eff_obs_x100 = 0;
            b->conf_x1000 = 0;
            uint16_t alpha_seed;
            int16_t inter_seed;
            uint16_t sleep_seed;
            uint16_t net_seed;
            switch (dp) {
                case ASB_DAYPART_SLEEP:
                    alpha_seed = 950; inter_seed = 0;   sleep_seed = 900; net_seed = 800; break;
                case ASB_DAYPART_LATE:
                    alpha_seed = 750; inter_seed = 20;  sleep_seed = 500; net_seed = 500; break;
                case ASB_DAYPART_WAKE:
                    alpha_seed = 500; inter_seed = 60;  sleep_seed = 100; net_seed = 200; break;
                case ASB_DAYPART_MORN:
                case ASB_DAYPART_DAY:
                    alpha_seed = 300; inter_seed = 100; sleep_seed = 0;   net_seed = 100; break;
                case ASB_DAYPART_EVE:
                    alpha_seed = 400; inter_seed = 80;  sleep_seed = 50;  net_seed = 200; break;
                default:
                    alpha_seed = 500; inter_seed = 50;  sleep_seed = 100; net_seed = 300; break;
            }
            b->alpha_battery_x1000  = alpha_seed;
            b->interactive_bonus_x1000 = inter_seed;
            b->idle_bias_x1000         = 0;
            b->sleep_bias_x1000        = sleep_seed;
            b->net_conservative_x1000  = net_seed;
            b->avg_idle_q_x10 = 0;
            b->avg_wph_x10 = 0;
            b->avg_drain_mahph_x10 = 0;
            b->avg_max_temp_x10 = 0;
        }
    }
}

static int asb_smart_store_validate(const asb_smart_store_t *st) {
    if (!st) return -1;
    if (st->magic != ASB_SMART_MAGIC) return -2;
    if (st->version != ASB_SMART_VER) return -3;
    if (st->bucket_count != ASB_SMART_BUCKETS) return -4;
    for (int i = 0; i < ASB_SMART_BUCKETS; i++) {
        if (st->buckets[i].bucket_id != (uint32_t)i) return -5;
        if (st->buckets[i].alpha_battery_x1000 > ASB_SMART_ALPHA_BATTERY_MAX_X1000) return -6;
        if (st->buckets[i].interactive_bonus_x1000 > ASB_SMART_INTERACTIVE_MAX_X1000) return -7;
        if (st->buckets[i].interactive_bonus_x1000 < ASB_SMART_INTERACTIVE_MIN_X1000) return -8;
        if (st->buckets[i].idle_bias_x1000 > ASB_SMART_IDLE_BIAS_MAX_X1000) return -9;
        if (st->buckets[i].idle_bias_x1000 < ASB_SMART_IDLE_BIAS_MIN_X1000) return -10;
        if (st->buckets[i].sleep_bias_x1000 > ASB_SMART_SLEEP_BIAS_MAX_X1000) return -11;
        if (st->buckets[i].net_conservative_x1000 > ASB_SMART_NET_CONSERV_MAX_X1000) return -12;
    }
    return 0;
}

static int asb_smart_store_load_from(const char *path, asb_smart_store_t *out) {
    if (!path || !out) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return -2;
    size_t n = fread(out, 1, sizeof(*out), f);
    fclose(f);
    if (n != sizeof(*out)) return -3;
    return asb_smart_store_validate(out);
}

static int asb_smart_store_save_atomic(const asb_smart_store_t *st, const char *path) {
    if (!st || !path) return -1;
    if (asb_smart_store_validate(st) != 0) return -2;
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return -3;
    size_t n = fwrite(st, 1, sizeof(*st), f);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    if (n != sizeof(*st)) {
        unlink(tmp);
        return -4;
    }
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        return -5;
    }
    return 0;
}

static int asb_smart_store_backup(const char *src, const char *bak) {
    if (!src || !bak) return -1;
    FILE *fi = fopen(src, "rb");
    if (!fi) return -2;
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", bak);
    FILE *fo = fopen(tmp, "wb");
    if (!fo) { fclose(fi); return -3; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), fi)) > 0) {
        if (fwrite(buf, 1, n, fo) != n) {
            fclose(fi); fclose(fo); unlink(tmp);
            return -4;
        }
    }
    fflush(fo);
    fsync(fileno(fo));
    fclose(fo);
    fclose(fi);
    if (rename(tmp, bak) != 0) {
        unlink(tmp);
        return -5;
    }
    return 0;
}

typedef struct {
    int reset_reason;
    int loaded_from_main;
    int loaded_from_backup;
    int seeded;
} asb_smart_load_outcome_t;

static int asb_smart_store_load(asb_smart_store_t *st, asb_smart_load_outcome_t *out) {
    if (!st) return -1;
    asb_smart_load_outcome_t local = {0,0,0,0};
    int rc = asb_smart_store_load_from(ASB_SMART_STORE_FILE, st);
    if (rc == 0) {
        local.loaded_from_main = 1;
        if (out) *out = local;
        return 0;
    }
    local.reset_reason = rc;
    int rc2 = asb_smart_store_load_from(ASB_SMART_STORE_BAK, st);
    if (rc2 == 0) {
        local.loaded_from_backup = 1;
        if (out) *out = local;
        asb_smart_store_save_atomic(st, ASB_SMART_STORE_FILE);
        return 0;
    }
    asb_smart_store_seed_defaults(st);
    local.seeded = 1;
    if (out) *out = local;
    asb_smart_store_save_atomic(st, ASB_SMART_STORE_FILE);
    return 1;
}

static int asb_smart_flag_read(void) {
    FILE *f = fopen(ASB_SMART_FLAG_FILE, "r");
    if (!f) return -1;
    int v = -1;
    int got = fscanf(f, "%d", &v);
    fclose(f);
    if (got != 1) return -1;
    return (v != 0) ? 1 : 0;
}

__attribute__((unused))
static int asb_smart_flag_write(int enabled) {
    FILE *f = fopen(ASB_SMART_FLAG_FILE, "w");
    if (!f) return -1;
    fprintf(f, "%d\n", enabled ? 1 : 0);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    return 0;
}

__attribute__((unused))
static int asb_smart_prev_profile_read(char *out, size_t outsz) {
    if (!out || outsz < 2) return -1;
    FILE *f = fopen(ASB_SMART_PREV_PROF, "r");
    if (!f) return -1;
    if (!fgets(out, (int)outsz, f)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    size_t L = strlen(out);
    while (L > 0 && (out[L-1] == '\n' || out[L-1] == '\r' || out[L-1] == ' ')) {
        out[--L] = '\0';
    }
    return (L > 0) ? 0 : -1;
}

__attribute__((unused))
static int asb_smart_prev_profile_write(const char *prof) {
    if (!prof || !*prof) return -1;
    FILE *f = fopen(ASB_SMART_PREV_PROF, "w");
    if (!f) return -1;
    fprintf(f, "%s\n", prof);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    return 0;
}

__attribute__((unused))
static int asb_smart_app_hash_to_hex(uint64_t h, char *out, size_t outsz) {
    if (!out || outsz < 17) return -1;
    snprintf(out, outsz, "%016llx", (unsigned long long)h);
    return 0;
}

/* ============================================================
 * Part 2: Math, blend, overrides, learning (Session 3)
 * ============================================================ */

/* Map duration in seconds to weight × 100.
 * <10min=0.25, 10-30min=0.50, 30-90min=1.00, >90min=1.25 */
static uint16_t asb_smart_duration_weight_x100(int dur_s) {
    if (dur_s < 0) dur_s = 0;
    if (dur_s <  ASB_SMART_DUR_W_SHORT_MAX_S) return ASB_SMART_DUR_W_SHORT_X100;
    if (dur_s <  ASB_SMART_DUR_W_MED_MAX_S)   return ASB_SMART_DUR_W_MED_X100;
    if (dur_s <  ASB_SMART_DUR_W_LONG_MAX_S)  return ASB_SMART_DUR_W_LONG_X100;
    return ASB_SMART_DUR_W_VLONG_X100;
}

/* Map trust tier (0=DIRTY .. 3=NOISY, V47 enum) to weight × 100.
 * CLEAN=1.00, PARTIAL=0.40, NOISY=0.15, DIRTY=0.00 */
static uint16_t asb_smart_trust_weight_x100(int trust) {
    switch (trust) {
        case ASB_TRUST_CLEAN:   return ASB_SMART_TRUST_W_CLEAN_X100;
        case ASB_TRUST_PARTIAL: return ASB_SMART_TRUST_W_PARTIAL_X100;
        case ASB_TRUST_NOISY:   return ASB_SMART_TRUST_W_NOISY_X100;
        case ASB_TRUST_DIRTY:   return ASB_SMART_TRUST_W_DIRTY_X100;
        default:                return ASB_SMART_TRUST_W_PARTIAL_X100;
    }
}

/* eff_obs increment for one session = (dur_weight × trust_weight) / 100
 * (since both are _x100, product is _x10000, we want _x100 result) */
static uint16_t asb_smart_eff_obs_add_x100(int dur_s, int trust) {
    uint32_t dw = asb_smart_duration_weight_x100(dur_s);
    uint32_t tw = asb_smart_trust_weight_x100(trust);
    uint32_t prod = (dw * tw) / 100;
    if (prod > 0xffffu) prod = 0xffffu;
    return (uint16_t)prod;
}

/* Decay factor × 100 based on time since last_seen.
 * <7 days: 1.00 (100), 7-37 days linear to 0.30 (30), >37 days: 0 */
static int asb_smart_decay_x100(uint32_t last_seen_ts, time_t now) {
    if (last_seen_ts == 0) return 100;
    if ((uint32_t)now <= last_seen_ts) return 100;
    int days = (int)((uint32_t)now - last_seen_ts) / (24 * 3600);
    if (days <  ASB_SMART_DECAY_FRESH_DAYS) return 100;
    if (days >= ASB_SMART_DECAY_STALE_DAYS) return 0;
    /* Linear from 100 at FRESH_DAYS down to FLOOR (30) at STALE_DAYS */
    int span = ASB_SMART_DECAY_STALE_DAYS - ASB_SMART_DECAY_FRESH_DAYS;  /* 30 */
    int into = days - ASB_SMART_DECAY_FRESH_DAYS;                         /* 0..30 */
    int from_full = 100 - ASB_SMART_DECAY_FLOOR_X100;                     /* 70 */
    int dec = (from_full * into) / span;
    return 100 - dec;
}

/* Confidence × 1000 from current eff_obs and time decay.
 * conf = min(1.0, eff_obs / EFF_OBS_FULL) × decay */
static uint16_t asb_smart_confidence_x1000(const asb_smart_bucket_t *b, time_t now) {
    if (!b || b->eff_obs_x100 == 0) return 0;
    /* Ratio = eff_obs_x100 / EFF_OBS_FULL_x100. Both in same scale. */
    uint32_t ratio_x1000 = ((uint32_t)b->eff_obs_x100 * 1000u) / ASB_SMART_EFF_OBS_FULL_X100;
    if (ratio_x1000 > 1000u) ratio_x1000 = 1000u;
    int decay = asb_smart_decay_x100(b->last_seen_ts, now);
    uint32_t conf = (ratio_x1000 * (uint32_t)decay) / 100u;
    if (conf > ASB_SMART_CONF_MAX_X1000) conf = ASB_SMART_CONF_MAX_X1000;
    return (uint16_t)conf;
}

/* Confidence tier from conf_x1000: 0=ignore, 1=mild, 2=strong */
static int asb_smart_confidence_tier(int conf_x1000) {
    if (conf_x1000 < ASB_SMART_CONF_LOW_X1000)  return 0;
    if (conf_x1000 < ASB_SMART_CONF_HIGH_X1000) return 1;
    return 2;
}

/* Daypart class: SLEEP/LATE → "night", WAKE/MORN/DAY → "day", EVE → "evening" */
static int asb_smart_daypart_class(int daypart) {
    switch (daypart) {
        case ASB_DAYPART_SLEEP:
        case ASB_DAYPART_LATE:
            return 0; /* night */
        case ASB_DAYPART_WAKE:
        case ASB_DAYPART_MORN:
        case ASB_DAYPART_DAY:
            return 1; /* day */
        case ASB_DAYPART_EVE:
            return 2; /* evening */
        default:
            return 1;
    }
}

/* Lookup bucket with hierarchical fallback.
 * Returns bucket pointer + sets *fallback_level (0=exact, 4=safe default).
 * Safe default bucket is a static synthesized fallback (never NULL).
 *
 * Hierarchy:
 *   0 EXACT: (daypart, is_weekend)
 *   1 DAYPART_ONLY: best of (daypart, weekday) or (daypart, weekend) by confidence
 *   2 CLASS: best of class-peer dayparts (e.g., SLEEP/LATE for night)
 *   3 GLOBAL: best bucket overall by confidence
 *   4 SAFE: synthesized conservative defaults
 */
static asb_smart_bucket_t* asb_smart_lookup_bucket(
        asb_smart_store_t *st,
        int daypart, int is_weekend,
        time_t now,
        int *fallback_level)
{
    static asb_smart_bucket_t safe_default;
    static int safe_default_initialized = 0;
    if (!safe_default_initialized) {
        memset(&safe_default, 0, sizeof(safe_default));
        safe_default.alpha_battery_x1000      = 500;  /* mid */
        safe_default.interactive_bonus_x1000  = 0;
        safe_default.idle_bias_x1000          = 0;
        safe_default.sleep_bias_x1000         = 100;
        safe_default.net_conservative_x1000   = 300;
        safe_default.conf_x1000               = 0;
        safe_default_initialized = 1;
    }

    if (!st || !fallback_level) {
        if (fallback_level) *fallback_level = ASB_SMART_FALLBACK_SAFE;
        return &safe_default;
    }

    if (daypart < 0 || daypart >= ASB_SMART_DAYPARTS) daypart = ASB_DAYPART_DAY;
    if (is_weekend != 0 && is_weekend != 1) is_weekend = 0;

    /* Level 0: EXACT */
    int exact_bid = (int)asb_smart_bucket_id(daypart, is_weekend);
    asb_smart_bucket_t *bx = &st->buckets[exact_bid];
    int conf_x = asb_smart_confidence_x1000(bx, now);
    if (conf_x >= ASB_SMART_CONF_LOW_X1000) {
        *fallback_level = ASB_SMART_FALLBACK_EXACT;
        bx->conf_x1000 = (uint16_t)conf_x;
        return bx;
    }

    /* Level 1: DAYPART_ONLY — pick higher-confidence variant within same daypart */
    int alt_bid = (int)asb_smart_bucket_id(daypart, is_weekend ^ 1);
    asb_smart_bucket_t *ba = &st->buckets[alt_bid];
    int conf_a = asb_smart_confidence_x1000(ba, now);
    if (conf_a >= ASB_SMART_CONF_LOW_X1000 && conf_a > conf_x) {
        *fallback_level = ASB_SMART_FALLBACK_DAYPART_ONLY;
        ba->conf_x1000 = (uint16_t)conf_a;
        return ba;
    }
    /* If exact has any nonzero conf below low threshold but better than alt, still try it weakly */
    if (conf_x > 0 && conf_x >= conf_a) {
        *fallback_level = ASB_SMART_FALLBACK_EXACT;
        bx->conf_x1000 = (uint16_t)conf_x;
        return bx;
    }

    /* Level 2: CLASS — best confidence within daypart class */
    int my_class = asb_smart_daypart_class(daypart);
    asb_smart_bucket_t *best_class = NULL;
    int best_class_conf = -1;
    for (int dp = 0; dp < ASB_SMART_DAYPARTS; dp++) {
        if (asb_smart_daypart_class(dp) != my_class) continue;
        for (int we = 0; we < 2; we++) {
            int bid = (int)asb_smart_bucket_id(dp, we);
            asb_smart_bucket_t *b = &st->buckets[bid];
            int c = asb_smart_confidence_x1000(b, now);
            if (c > best_class_conf) {
                best_class_conf = c;
                best_class = b;
            }
        }
    }
    if (best_class && best_class_conf >= ASB_SMART_CONF_LOW_X1000) {
        *fallback_level = ASB_SMART_FALLBACK_CLASS;
        best_class->conf_x1000 = (uint16_t)best_class_conf;
        return best_class;
    }

    /* Level 3: GLOBAL — best bucket anywhere */
    asb_smart_bucket_t *best_global = NULL;
    int best_global_conf = -1;
    for (int i = 0; i < ASB_SMART_BUCKETS; i++) {
        asb_smart_bucket_t *b = &st->buckets[i];
        int c = asb_smart_confidence_x1000(b, now);
        if (c > best_global_conf) {
            best_global_conf = c;
            best_global = b;
        }
    }
    if (best_global && best_global_conf >= ASB_SMART_CONF_LOW_X1000) {
        *fallback_level = ASB_SMART_FALLBACK_GLOBAL;
        best_global->conf_x1000 = (uint16_t)best_global_conf;
        return best_global;
    }

    /* Level 4: SAFE — synthesized conservative defaults */
    *fallback_level = ASB_SMART_FALLBACK_SAFE;
    return &safe_default;
}

/* Compute effective runtime smart params from a chosen bucket + confidence.
 * Applies confidence gating per V48_LOCKED rules. */
static void asb_smart_compute_effective(
        const asb_smart_bucket_t *b,
        int conf_x1000,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    if (!b) {
        rt->conf_x1000 = 0;
        rt->alpha_battery_x1000 = 500;
        rt->interactive_bonus_x1000 = 0;
        rt->idle_bias_x1000 = 0;
        rt->sleep_bias_x1000 = 100;
        rt->net_conservative_x1000 = 300;
        return;
    }
    rt->conf_x1000 = conf_x1000;

    /* effective scale: 0 if conf<low, smooth ramp up to ~0.4 at high, 1.0 at full */
    int eff_scale_x1000;
    if (conf_x1000 < ASB_SMART_CONF_LOW_X1000) {
        eff_scale_x1000 = 0;
    } else if (conf_x1000 < ASB_SMART_CONF_HIGH_X1000) {
        /* Linear: low→0, high→400 (max 40% influence in mild tier) */
        int span = ASB_SMART_CONF_HIGH_X1000 - ASB_SMART_CONF_LOW_X1000;
        int into = conf_x1000 - ASB_SMART_CONF_LOW_X1000;
        eff_scale_x1000 = (400 * into) / span;
    } else {
        /* Strong tier: linear from 400 at high→1000 at full conf */
        int span = ASB_SMART_CONF_MAX_X1000 - ASB_SMART_CONF_HIGH_X1000;
        int into = conf_x1000 - ASB_SMART_CONF_HIGH_X1000;
        eff_scale_x1000 = 400 + ((1000 - 400) * into) / span;
        if (eff_scale_x1000 > 1000) eff_scale_x1000 = 1000;
    }

    /* Blend bucket value with neutral baseline using eff_scale.
     * Neutral baseline for alpha_battery: 500 (mid between battery and balanced).
     * Effective = neutral + (bucket - neutral) × eff_scale */
    int alpha = 500 + ((b->alpha_battery_x1000 - 500) * eff_scale_x1000) / 1000;
    rt->alpha_battery_x1000 = asb_clamp_int(alpha,
        ASB_SMART_ALPHA_BATTERY_MIN_X1000, ASB_SMART_ALPHA_BATTERY_MAX_X1000);

    /* For bias values neutral is 0 */
    int inter = (b->interactive_bonus_x1000 * eff_scale_x1000) / 1000;
    rt->interactive_bonus_x1000 = asb_clamp_int(inter,
        ASB_SMART_INTERACTIVE_MIN_X1000, ASB_SMART_INTERACTIVE_MAX_X1000);

    int idle = (b->idle_bias_x1000 * eff_scale_x1000) / 1000;
    rt->idle_bias_x1000 = asb_clamp_int(idle,
        ASB_SMART_IDLE_BIAS_MIN_X1000, ASB_SMART_IDLE_BIAS_MAX_X1000);

    int sleep = (b->sleep_bias_x1000 * eff_scale_x1000) / 1000;
    rt->sleep_bias_x1000 = asb_clamp_int(sleep,
        ASB_SMART_SLEEP_BIAS_MIN_X1000, ASB_SMART_SLEEP_BIAS_MAX_X1000);

    int net = (b->net_conservative_x1000 * eff_scale_x1000) / 1000;
    rt->net_conservative_x1000 = asb_clamp_int(net,
        ASB_SMART_NET_CONSERV_MIN_X1000, ASB_SMART_NET_CONSERV_MAX_X1000);
}

/* Night-safe override: if late/sleep daypart + screen off + not charging +
 * no heavy foreground + low battery → force aggressive battery-lean state. */
static void asb_smart_apply_night_override(
        int daypart,
        int screen_on,
        int charging,
        int app_hint,
        int battery_pct,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    rt->night_safe_override = 0;

    int is_night_part = (daypart == ASB_DAYPART_SLEEP || daypart == ASB_DAYPART_LATE);
    int idle_screen = (screen_on == 0);
    int not_charging = (charging == 0);
    int no_heavy = (app_hint < ASB_APP_HEAVY);
    int low_or_normal_bat = (battery_pct <= ASB_SMART_NIGHT_BAT_PCT_MAX);

    if (is_night_part && idle_screen && not_charging && no_heavy && low_or_normal_bat) {
        rt->night_safe_override = 1;
        if (rt->alpha_battery_x1000 < 900) rt->alpha_battery_x1000 = 900;
        if (rt->sleep_bias_x1000 < 800)    rt->sleep_bias_x1000 = 800;
        if (rt->net_conservative_x1000 < 700) rt->net_conservative_x1000 = 700;
        rt->interactive_bonus_x1000 = 0;
    }
}

/* Thermal veto: if device already hot or vendor heavily clamping, force
 * battery-lean alpha and downscale interactive ambitions. */
static void asb_smart_apply_thermal_veto(
        int cpu_max_c,
        int vendor_clamp_1h,
        int recovery_active,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    rt->thermal_veto = 0;

    int veto = 0;
    if (cpu_max_c >= ASB_SMART_VETO_CPU_TEMP_C) veto = 1;
    if (vendor_clamp_1h >= ASB_SMART_VETO_VENDOR_CLAMP_1H) veto = 1;
    if (recovery_active) veto = 1;

    if (veto) {
        rt->thermal_veto = 1;
        /* Effective confidence × 0.3 */
        rt->conf_x1000 = (rt->conf_x1000 * ASB_SMART_VETO_CONF_SCALE_X100) / 100;
        /* Force alpha_battery ≥ 700 */
        if (rt->alpha_battery_x1000 < ASB_SMART_VETO_FORCE_ALPHA_X1000) {
            rt->alpha_battery_x1000 = ASB_SMART_VETO_FORCE_ALPHA_X1000;
        }
        /* Trim interactive bonus */
        rt->interactive_bonus_x1000 /= 2;
    }
}

/* Blend two profile bounds structures using alpha_battery_x1000.
 * alpha=0 → all balanced, alpha=1000 → all battery.
 * Output is clamped to never exceed balanced sustained envelope.
 *
 * This is a generic int-based blend; the actual asb_profile_bounds_t struct
 * lives in asb_fsm.h. We expose a simple field-by-field blender via two
 * arrays of values supplied by the caller. The caller (Session 4 integration)
 * unpacks the profile bounds struct into arrays, calls blend, and packs back. */
static void asb_smart_blend_values_int(
        const int *battery_vals,
        const int *balanced_vals,
        int n,
        int alpha_battery_x1000,
        int *out_vals)
{
    if (!battery_vals || !balanced_vals || !out_vals || n <= 0) return;
    int a = asb_clamp_int(alpha_battery_x1000, 0, 1000);
    int inv = 1000 - a;
    for (int i = 0; i < n; i++) {
        int b_val = battery_vals[i];
        int x_val = balanced_vals[i];
        /* If both zero, output zero. If one is zero and other not, use non-zero. */
        if (b_val == 0 && x_val == 0) {
            out_vals[i] = 0;
            continue;
        }
        int blended = (b_val * a + x_val * inv) / 1000;
        /* Hard cap: never exceed balanced value */
        if (blended > x_val) blended = x_val;
        /* Hard floor: never go below battery value */
        if (blended < b_val) blended = b_val;
        out_vals[i] = blended;
    }
}

/* Apply interactive_bonus to a CPU cap value. Bonus is relative (×1000),
 * applied as small upward modifier, but never exceeds balanced ceiling. */
static int asb_smart_apply_interactive_bonus(
        int blended_val, int balanced_ceiling, int interactive_bonus_x1000)
{
    if (interactive_bonus_x1000 <= 0) return blended_val;
    int bonus = (blended_val * interactive_bonus_x1000) / 1000;
    int boosted = blended_val + bonus;
    if (boosted > balanced_ceiling) boosted = balanced_ceiling;
    return boosted;
}

/* Update bucket bias values from one session outcome.
 * Called on session finalize. Adjusts alpha_battery, interactive_bonus,
 * sleep_bias, net_conservative based on whether session was hot/drainy/clean.
 * Learning rate intentionally slow (ASB_SMART_LEARN_RATE_X1000 = 50 = 5%). */
typedef struct {
    int dur_s;
    int max_temp_c;
    int max_skin_c;
    int drain_mah_per_hour;
    int trust;            /* ASB_TRUST_* */
    int was_heavy;        /* 0/1 had heavy/gaming time */
    int was_thermal_hit;  /* 0/1 reached thermal_throttle */
    int sustained_pct;    /* 0-100 fraction of time in SUSTAINED */
    int idle_q_x10;       /* idle quality if applicable */
    int screen_on_pct;    /* 0-100 */
} asb_smart_session_input_t;

static void asb_smart_bucket_update_from_session(
        asb_smart_bucket_t *b,
        const asb_smart_session_input_t *s,
        time_t now)
{
    if (!b || !s) return;

    /* Reject DIRTY sessions entirely — don't pollute learning */
    if (s->trust == ASB_TRUST_DIRTY) return;

    int eff_add = (int)asb_smart_eff_obs_add_x100(s->dur_s, s->trust);
    if (eff_add <= 0) return;

    /* Accumulate eff_obs with cap at 2× full (40.0 × 100 = 4000) to allow
     * old buckets to still drift on new data without saturating instantly */
    int new_eff = (int)b->eff_obs_x100 + eff_add;
    if (new_eff > 4000) new_eff = 4000;
    b->eff_obs_x100 = (uint16_t)new_eff;
    b->observations_raw++;
    b->last_seen_ts = (uint32_t)now;

    int lr = ASB_SMART_LEARN_RATE_X1000;  /* 5% per session */

    /* Direction signals:
     *   was_hot     → bias toward battery (+alpha)
     *   was_drainy  → bias toward battery (+alpha)
     *   was_clean_cool → allow slight balanced (-alpha) and interactive (+bonus)
     *   was_thermal_hit → strong push to battery + suppress interactive
     */
    int dt_alpha = 0;
    int dt_inter = 0;
    int dt_sleep = 0;
    int dt_net   = 0;

    int hot = (s->max_temp_c >= 70);
    int very_hot = (s->max_temp_c >= 80);
    int drainy = (s->drain_mah_per_hour > 600);
    int sustained_heavy = (s->sustained_pct >= 30);
    int clean_cool = (s->max_temp_c < 55 && s->trust == ASB_TRUST_CLEAN);

    if (very_hot)  dt_alpha += 80;
    else if (hot)  dt_alpha += 40;
    if (drainy)    dt_alpha += 30;
    if (sustained_heavy) dt_alpha += 20;
    if (s->was_thermal_hit) {
        dt_alpha += 100;
        dt_inter -= 50;
    }
    if (clean_cool) {
        dt_alpha -= 60;
        dt_inter += 25;
    }

    /* Sleep/idle quality */
    if (s->screen_on_pct < 5 && s->dur_s > 1800) {
        /* Long screen-off session with clean idle */
        if (s->trust == ASB_TRUST_CLEAN && s->idle_q_x10 >= 50) {
            dt_sleep += 30;
            dt_net   += 20;
        } else if (s->trust == ASB_TRUST_NOISY) {
            /* Wake-noisy night session - reduce confidence in sleep behaviour */
            dt_sleep -= 20;
        }
    }

    /* Scale all deltas by learning rate */
    dt_alpha = (dt_alpha * lr) / 1000;
    dt_inter = (dt_inter * lr) / 1000;
    dt_sleep = (dt_sleep * lr) / 1000;
    dt_net   = (dt_net   * lr) / 1000;

    /* Apply with clamps */
    int new_alpha = (int)b->alpha_battery_x1000 + dt_alpha;
    b->alpha_battery_x1000 = asb_clamp_u16(new_alpha,
        ASB_SMART_ALPHA_BATTERY_MIN_X1000, ASB_SMART_ALPHA_BATTERY_MAX_X1000);

    int new_inter = (int)b->interactive_bonus_x1000 + dt_inter;
    b->interactive_bonus_x1000 = asb_clamp_i16(new_inter,
        ASB_SMART_INTERACTIVE_MIN_X1000, ASB_SMART_INTERACTIVE_MAX_X1000);

    int new_sleep = (int)b->sleep_bias_x1000 + dt_sleep;
    b->sleep_bias_x1000 = asb_clamp_u16(new_sleep,
        ASB_SMART_SLEEP_BIAS_MIN_X1000, ASB_SMART_SLEEP_BIAS_MAX_X1000);

    int new_net = (int)b->net_conservative_x1000 + dt_net;
    b->net_conservative_x1000 = asb_clamp_u16(new_net,
        ASB_SMART_NET_CONSERV_MIN_X1000, ASB_SMART_NET_CONSERV_MAX_X1000);

    /* Update running averages with EMA (alpha = 0.2 = 1/5) */
    if (b->avg_max_temp_x10 == 0) b->avg_max_temp_x10 = (uint16_t)(s->max_temp_c * 10);
    else b->avg_max_temp_x10 = (uint16_t)((b->avg_max_temp_x10 * 4 + s->max_temp_c * 10) / 5);

    if (b->avg_drain_mahph_x10 == 0) b->avg_drain_mahph_x10 = (uint16_t)(s->drain_mah_per_hour * 10);
    else b->avg_drain_mahph_x10 = (uint16_t)((b->avg_drain_mahph_x10 * 4 + s->drain_mah_per_hour * 10) / 5);

    if (s->idle_q_x10 > 0) {
        if (b->avg_idle_q_x10 == 0) b->avg_idle_q_x10 = (uint16_t)s->idle_q_x10;
        else b->avg_idle_q_x10 = (uint16_t)((b->avg_idle_q_x10 * 4 + s->idle_q_x10) / 5);
    }

    /* Refresh cached confidence */
    b->conf_x1000 = asb_smart_confidence_x1000(b, now);
}

/* Slot-update gating: returns 1 if PROFILE_SMART bounds should be recomputed
 * this tick, 0 if cached values are still valid.
 * Called from governor.c tick path. */
static int asb_smart_should_update_slot(
        const asb_smart_runtime_t *rt,
        time_t now,
        int charging,
        int app_hint)
{
    if (!rt) return 1;
    if (rt->last_slot_update_ts == 0) return 1;

    /* Bucket / fallback / daypart changed */
    if (rt->bucket_id != rt->prev_bucket_id) return 1;
    if (rt->daypart  != rt->prev_daypart)  return 1;

    /* Confidence tier crossed a boundary */
    int cur_tier = asb_smart_confidence_tier(rt->conf_x1000);
    if (cur_tier != rt->last_conf_tier) return 1;

    /* Night override or thermal veto state changed */
    if (rt->night_safe_override != rt->last_night_override) return 1;
    if (rt->thermal_veto != rt->last_thermal_veto) return 1;

    /* Charging state changed */
    if (charging != rt->last_charging) return 1;

    /* App hint tier changed (group app hints into 3 tiers for fewer churn:
     * 0=idle/light, 1=medium, 2=heavy/gaming) */
    int cur_app_tier = (app_hint <= ASB_APP_LIGHT) ? 0 :
                       (app_hint == ASB_APP_MEDIUM) ? 1 : 2;
    if (cur_app_tier != rt->last_app_hint_tier) return 1;

    /* Otherwise, no update needed */
    return 0;
}

/* Mark slot updated; remember current gating state */
static void asb_smart_mark_slot_updated(
        asb_smart_runtime_t *rt,
        time_t now,
        int charging,
        int app_hint)
{
    if (!rt) return;
    rt->last_slot_update_ts = now;
    rt->last_conf_tier = asb_smart_confidence_tier(rt->conf_x1000);
    rt->last_charging = charging;
    rt->last_app_hint_tier = (app_hint <= ASB_APP_LIGHT) ? 0 :
                             (app_hint == ASB_APP_MEDIUM) ? 1 : 2;
    rt->last_night_override = rt->night_safe_override;
    rt->last_thermal_veto = rt->thermal_veto;
    rt->prev_bucket_id = rt->bucket_id;
    rt->prev_daypart   = rt->daypart;
}

/* Daypart transition smoothing helper.
 * Returns blend factor × 100 (0..100) representing transition progress.
 * Smoothing active only if both prev_conf and cur_conf >= LOW threshold.
 * Otherwise returns 100 (full new bucket, hard switch).
 * Thermal veto and night override caller-side break smoothing. */
static int asb_smart_daypart_smoothing_factor_x100(
        time_t smoothing_start,
        time_t now,
        int prev_conf_x1000,
        int cur_conf_x1000)
{
    if (smoothing_start == 0) return 100;
    if (prev_conf_x1000 < ASB_SMART_CONF_LOW_X1000) return 100;
    if (cur_conf_x1000  < ASB_SMART_CONF_LOW_X1000) return 100;
    int elapsed = (int)(now - smoothing_start);
    if (elapsed >= ASB_SMART_SMOOTH_S) return 100;
    if (elapsed <  0) return 0;
    return (elapsed * 100) / ASB_SMART_SMOOTH_S;
}

#endif
