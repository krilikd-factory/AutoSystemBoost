#pragma once
/*
 * asb_learner.h — Обучение паттернам использования
 *
 * Алгоритм: Exponential Moving Average по часам суток × 7 дней недели.
 * 24 часа × 7 дней = 168 слотов.
 * Каждый слот хранит: средний drain (мА), среднее время screen-on.
 *
 * Файл learn.bin: 168 × 8 байт = 1344 байта. Хранится в tmpfs.
 *
 * EMA коэффициент α = 0.15:
 *   - Новые данные влияют постепенно
 *   - "Память" ≈ 1/α = ~7 измерений = ~7 дней
 *   - После 7 дней паттерн стабилизируется
 *
 * Использование:
 *   learner_update() — вызывается каждый час
 *   learner_predict_idle() — возвращает 1 если текущий час
 *                           исторически "спокойный" (<30мА средний drain)
 */

#include <stdio.h>
#include <string.h>
#include <time.h>
#include <math.h>

#define LEARN_SLOTS     168   /* 24 × 7 */
#define LEARN_ALPHA     0.15f /* EMA коэффициент */
#define LEARN_FILE      "/dev/.asb/learn.bin"
#define LEARN_IDLE_MA   30    /* порог "тихого" часа, мА */
#define LEARN_LIGHT_MA  70    /* порог "лёгкого" часа, мА */

typedef struct {
    float drain_ma_ema;    /* экспоненциальное среднее drain, мА */
    float screen_on_ema;   /* доля времени с включённым экраном 0..1 */
    uint32_t samples;      /* сколько измерений накоплено */
    float _pad;
} asb_slot_t;              /* 16 байт × 168 = 2688 байт */

typedef struct {
    uint32_t    magic;     /* 0xA5B1EA5B */
    uint32_t    version;   /* 1 */
    asb_slot_t  slots[LEARN_SLOTS];
    uint32_t    crc32;
} asb_learn_db_t;

#define LEARN_MAGIC 0xA5B1EA5B

/* ─── CRC32 ─────────────────────────────────────────────────── */
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

/* ─── Slot index ────────────────────────────────────────────── */
static inline int learner_slot(void) {
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    return tm->tm_wday * 24 + tm->tm_hour; /* 0..167 */
}

/* ─── Persistence ───────────────────────────────────────────── */
static int learner_load(asb_learn_db_t *db) {
    FILE *f = fopen(LEARN_FILE, "rb");
    if (!f) return 0;
    size_t n = fread(db, 1, sizeof(*db), f);
    fclose(f);
    if (n != sizeof(*db)) return 0;
    if (db->magic != LEARN_MAGIC || db->version != 1) return 0;
    uint32_t crc = crc32_simple(db->slots, sizeof(db->slots));
    return (crc == db->crc32) ? 1 : 0;
}

static void learner_save(asb_learn_db_t *db) {
    db->crc32 = crc32_simple(db->slots, sizeof(db->slots));
    FILE *f = fopen(LEARN_FILE, "wb");
    if (!f) return;
    fwrite(db, 1, sizeof(*db), f);
    fflush(f);
    fclose(f);
}

static void learner_init(asb_learn_db_t *db) {
    if (learner_load(db)) return;
    /* Первый запуск: инициализируем нейтральными значениями */
    memset(db, 0, sizeof(*db));
    db->magic   = LEARN_MAGIC;
    db->version = 1;
    /* По умолчанию: средний drain 60мА (до накопления данных
     * не делаем агрессивных предсказаний)                    */
    for (int i = 0; i < LEARN_SLOTS; i++) {
        db->slots[i].drain_ma_ema   = 60.0f;
        db->slots[i].screen_on_ema  = 0.3f;
        db->slots[i].samples        = 0;
    }
}

/* ─── Update ────────────────────────────────────────────────── */
/*
 * Вызывается каждый час с накопленными за час данными.
 * drain_ma_avg — среднее потребление за прошедший час (мА)
 * screen_on_frac — доля времени с включённым экраном (0..1)
 */
static void learner_update(asb_learn_db_t *db,
                           float drain_ma_avg, float screen_on_frac)
{
    int slot = learner_slot();
    asb_slot_t *s = &db->slots[slot];

    if (s->samples == 0) {
        /* Первое измерение: прямое присваивание */
        s->drain_ma_ema  = drain_ma_avg;
        s->screen_on_ema = screen_on_frac;
    } else {
        float alpha = LEARN_ALPHA;
        /* После 20+ измерений доверяем модели больше */
        if (s->samples > 20) alpha = 0.08f;
        s->drain_ma_ema  = alpha * drain_ma_avg  + (1 - alpha) * s->drain_ma_ema;
        s->screen_on_ema = alpha * screen_on_frac + (1 - alpha) * s->screen_on_ema;
    }
    if (s->samples < 0xFFFFFFFF) s->samples++;
    learner_save(db);
}

/* ─── Predict ───────────────────────────────────────────────── */
/*
 * Возвращает предсказание для текущего часа.
 * Используется для подстройки порогов FSM.
 */
typedef enum {
    LEARN_PREDICT_UNKNOWN  = 0, /* мало данных, не трогаем пороги */
    LEARN_PREDICT_IDLE     = 1, /* обычно спим/не используем       */
    LEARN_PREDICT_LIGHT    = 2, /* лёгкое использование            */
    LEARN_PREDICT_ACTIVE   = 3  /* активное использование          */
} asb_prediction_t;

static asb_prediction_t learner_predict(const asb_learn_db_t *db) {
    int slot = learner_slot();
    const asb_slot_t *s = &db->slots[slot];

    /* Нужно минимум 3 измерения для доверия */
    if (s->samples < 3) return LEARN_PREDICT_UNKNOWN;

    if (s->drain_ma_ema < LEARN_IDLE_MA)  return LEARN_PREDICT_IDLE;
    if (s->drain_ma_ema < LEARN_LIGHT_MA) return LEARN_PREDICT_LIGHT;
    return LEARN_PREDICT_ACTIVE;
}

/*
 * Возвращает скорректированные пороги для FSM на основе предсказания.
 * В "тихие" часы FSM медленнее переходит вверх.
 */
static void learner_adjust_windows(const asb_learn_db_t *db,
                                   int *up_window, int *down_window)
{
    asb_prediction_t p = learner_predict(db);
    switch (p) {
        case LEARN_PREDICT_IDLE:
            *up_window   = 5;  /* вверх: 10с (тихий час, не торопимся) */
            *down_window = 3;  /* вниз:  6с  (быстро засыпаем)         */
            break;
        case LEARN_PREDICT_LIGHT:
            *up_window   = 3;
            *down_window = 5;
            break;
        case LEARN_PREDICT_ACTIVE:
            *up_window   = 1;  /* вверх: 2с  (активный час, реагируем быстро) */
            *down_window = 8;
            break;
        default:
            *up_window   = 2;  /* defaults */
            *down_window = 5;
            break;
    }
}

/* ─── Hourly accumulator ────────────────────────────────────── */
/* Накапливаем данные внутри часа для усреднения */
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

/*
 * Вызывается каждый тик (2с в active, 5с в idle).
 * Возвращает 1 если час сменился (нужно вызвать learner_update).
 */
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
        /* Час сменился — возвращаем накопленное */
        if (a->drain_count > 0) {
            *out_drain  = a->drain_sum / a->drain_count;
            *out_screen = (a->total_ticks > 0)
                          ? (float)a->screen_on_ticks / a->total_ticks
                          : 0.0f;
        } else {
            *out_drain  = 0.0f;
            *out_screen = 0.0f;
        }
        /* Сброс */
        a->drain_sum        = 0;
        a->drain_count      = 0;
        a->screen_on_ticks  = 0;
        a->total_ticks      = 0;
        a->last_hour        = hour;
        return 1;
    }
    return 0;
}
