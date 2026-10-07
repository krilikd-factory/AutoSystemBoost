#pragma once

#include <stdio.h>
#include <string.h>
#include <time.h>
#include <math.h>

#define LEARN_SLOTS     168
#define LEARN_ALPHA     0.15f
/* Outside the module directory: a module update replaces that directory wholesale, so the
 * learner lost its 168 hour-of-week slots on every update and - needing 3 samples per slot,
 * i.e. three weeks - in practice never produced a prediction at all. The old path is still
 * read once, so whatever survived there is carried over. */
#define LEARN_FILE        "/data/adb/asb/learn.bin"
#define LEARN_FILE_LEGACY "/data/adb/modules/AutoSystemBoost/runtime/learn.bin"
/* Prediction thresholds, as a share of ticks with the screen on in that hour of the week.
 *
 * They used to be milliamps: < 30 mA idle, < 70 mA light. No hour of a real day averages
 * that - the samples are taken while the governor is awake, so even a sleeping hour reads
 * hundreds of mA (an OP15 night hour: 502 mA), and the OP15 gauge reads about half the true
 * current besides. Every slot would have become ACTIVE. Screen share is what the windows are
 * really about (will someone be using the phone this hour?) and no gauge distorts it. */
#define LEARN_IDLE_SCREEN   0.15f
#define LEARN_LIGHT_SCREEN  0.45f

typedef struct {
    float drain_ma_ema;
    float screen_on_ema;
    uint32_t samples;
    float _pad;
} asb_slot_t;

typedef struct {
    uint32_t    magic;
    uint32_t    version;
    asb_slot_t  slots[LEARN_SLOTS];
    uint32_t    crc32;
} asb_learn_db_t;

#define LEARN_MAGIC 0xA5B1EA5B

static uint32_t crc32_simple(const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    uint32_t crc = 0xFFFFFFFF;
    while (len--) {
        crc ^= *p++;
        for (int i = 0; i < 8; i++)
            crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
    return crc ^ 0xFFFFFFFF;
}

static inline int learner_slot(void) {
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    return tm->tm_wday * 24 + tm->tm_hour;
}

static int learner_load_from(asb_learn_db_t *db, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    size_t n = fread(db, 1, sizeof(*db), f);
    fclose(f);
    if (n != sizeof(*db)) return 0;
    if (db->magic != LEARN_MAGIC || db->version != 1) return 0;
    uint32_t crc = crc32_simple(db->slots, sizeof(db->slots));
    return (crc == db->crc32) ? 1 : 0;
}

static int learner_load(asb_learn_db_t *db) {
    if (learner_load_from(db, LEARN_FILE)) return 1;
    return learner_load_from(db, LEARN_FILE_LEGACY);
}

static void learner_save(asb_learn_db_t *db) {
    db->crc32 = crc32_simple(db->slots, sizeof(db->slots));

    /* Write to a temporary file, then rename over the target.
     *
     * Opening the real file with "wb" truncates it immediately: from that moment until
     * fclose returns, learn.bin is empty or half-written. A reboot, a crash or a module
     * update in that window leaves nothing to load, and the learner starts from scratch -
     * days of accumulated buckets gone for a few milliseconds of exposure.
     *
     * rename() on the same filesystem is atomic: a reader sees either the old file or the
     * new one, never a partial. asb_smart.h already saves its store this way; this makes
     * the learner match.
     */
    char tmp[288];
    snprintf(tmp, sizeof(tmp), "%s.tmp", LEARN_FILE);

    FILE *f = fopen(tmp, "wb");
    if (!f) return;
    size_t wrote = fwrite(db, 1, sizeof(*db), f);
    fflush(f);
    int fd = fileno(f);
    if (fd >= 0) fsync(fd);
    fclose(f);

    /* Only replace the good copy if the new one is complete. A short write means the
     * filesystem is full or failing - keeping the previous file is strictly better than
     * replacing it with a truncated one. */
    if (wrote == sizeof(*db)) {
        if (rename(tmp, LEARN_FILE) != 0) unlink(tmp);
    } else {
        unlink(tmp);
    }
}

static void learner_init(asb_learn_db_t *db) {
    if (learner_load(db)) return;
    memset(db, 0, sizeof(*db));
    db->magic   = LEARN_MAGIC;
    db->version = 1;
    for (int i = 0; i < LEARN_SLOTS; i++) {
        db->slots[i].drain_ma_ema   = 60.0f;
        db->slots[i].screen_on_ema  = 0.3f;
        db->slots[i].samples        = 0;
    }
}

static void learner_update(asb_learn_db_t *db,
                           float drain_ma_avg, float screen_on_frac)
{
    int slot = learner_slot();
    asb_slot_t *s = &db->slots[slot];

    if (s->samples == 0) {
        s->drain_ma_ema  = drain_ma_avg;
        s->screen_on_ema = screen_on_frac;
    } else {
        float alpha = LEARN_ALPHA;
        if (s->samples > 20) alpha = 0.08f;
        s->drain_ma_ema  = alpha * drain_ma_avg  + (1 - alpha) * s->drain_ma_ema;
        s->screen_on_ema = alpha * screen_on_frac + (1 - alpha) * s->screen_on_ema;
    }
    if (s->samples < 0xFFFFFFFF) s->samples++;
    learner_save(db);
}

typedef enum {
    LEARN_PREDICT_UNKNOWN  = 0,
    LEARN_PREDICT_IDLE     = 1,
    LEARN_PREDICT_LIGHT    = 2,
    LEARN_PREDICT_ACTIVE   = 3
} asb_prediction_t;

static asb_prediction_t learner_predict(const asb_learn_db_t *db) {
    int slot = learner_slot();
    const asb_slot_t *s = &db->slots[slot];

    if (s->samples < 3) return LEARN_PREDICT_UNKNOWN;

    if (s->screen_on_ema < LEARN_IDLE_SCREEN)  return LEARN_PREDICT_IDLE;
    if (s->screen_on_ema < LEARN_LIGHT_SCREEN) return LEARN_PREDICT_LIGHT;
    return LEARN_PREDICT_ACTIVE;
}

static void learner_adjust_windows(const asb_learn_db_t *db,
                                   int *up_window, int *down_window)
{
    asb_prediction_t p = learner_predict(db);
    switch (p) {
        /* No prediction ever makes ramping UP slower than the default 2 ticks. The IDLE
         * row used to wait 5: an hour you rarely use the phone is exactly the hour a sudden
         * unlock should not stutter in. What a quiet hour may do is settle down sooner. */
        case LEARN_PREDICT_IDLE:
            *up_window   = 2;
            *down_window = 3;
            break;
        case LEARN_PREDICT_LIGHT:
            *up_window   = 2;
            *down_window = 5;
            break;
        case LEARN_PREDICT_ACTIVE:
            *up_window   = 1;
            *down_window = 6;
            break;
        default:
            *up_window   = 2;
            *down_window = 5;
            break;
    }
}

typedef struct {
    float   drain_sum;
    int     drain_count;
    int     screen_on_ticks;
    int     total_ticks;
    int     last_hour;
} asb_accum_t;

static void accum_init(asb_accum_t *a) {
    memset(a, 0, sizeof(*a));
    time_t t = time(NULL);
    a->last_hour = localtime(&t)->tm_hour;
}

static int accum_tick(asb_accum_t *a, int drain_ma, int screen_on,
                      float *out_drain, float *out_screen)
{
    a->drain_sum     += (float)drain_ma;
    a->drain_count++;
    if (screen_on) a->screen_on_ticks++;
    a->total_ticks++;

    time_t t = time(NULL);
    int hour = localtime(&t)->tm_hour;
    if (hour != a->last_hour) {
        if (a->drain_count > 0) {
            *out_drain  = a->drain_sum / a->drain_count;
            *out_screen = (a->total_ticks > 0)
                          ? (float)a->screen_on_ticks / a->total_ticks
                          : 0.0f;
        } else {
            *out_drain  = 0.0f;
            *out_screen = 0.0f;
        }
        a->drain_sum        = 0;
        a->drain_count      = 0;
        a->screen_on_ticks  = 0;
        a->total_ticks      = 0;
        a->last_hour        = hour;
        return 1;
    }
    return 0;
}
