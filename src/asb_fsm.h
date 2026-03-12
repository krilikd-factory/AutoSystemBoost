#pragma once
/*
 * asb_fsm.h — Конечный автомат с гистерезисом
 *
 * 5 состояний × 3 профиля (battery/balanced/performance).
 * Каждое состояние задаёт CPU/GPU caps внутри диапазона профиля.
 *
 * ПРИНЦИП ГИСТЕРЕЗИСА:
 *   Переход вверх (IDLE→MODERATE): быстрый, окно 2с
 *   Переход вниз (MODERATE→IDLE):  медленный, окно 10с
 *   Это предотвращает мерцание при кратковременных пиках.
 *
 * ПРИОРИТЕТ СОБЫТИЙ:
 *   1. screen OFF → DEEP_IDLE немедленно (uevent)
 *   2. screen ON  → LIGHT_IDLE немедленно (uevent)
 *   3. thermal throttle → overlay, не меняет FSM state
 *   4. battery drain → FSM transition через окна
 */

#include <time.h>
#include <string.h>
#include "asb_metrics.h"

/* ─── States ───────────────────────────────────────────────── */
typedef enum {
    ASB_STATE_DEEP_IDLE  = 0, /* screen OFF, полный покой          */
    ASB_STATE_LIGHT_IDLE = 1, /* screen ON, ничего не делаем       */
    ASB_STATE_MODERATE   = 2, /* активное использование            */
    ASB_STATE_HEAVY      = 3, /* видео, карты, рендеринг           */
    ASB_STATE_GAMING     = 4, /* игры, нагрузка GPU > 65%         */
    ASB_STATE_COUNT      = 5
} asb_state_t;

static const char *asb_state_names[] = {
    "DEEP_IDLE", "LIGHT_IDLE", "MODERATE", "HEAVY", "GAMING"
};

/* ─── Profile constraints ──────────────────────────────────── */
/* Каждый профиль задаёт диапазон [floor, ceil] для FSM.
 * FSM работает внутри диапазона — не выходит за его пределы.
 * Единицы: кГц для CPU, % от max для GPU.                    */
typedef struct {
    /* CPU caps per policy (0=little, 1=mid/big, 2=prime) */
    int cpu_max[3];   /* максимальная частота policy в кГц */
    int cpu_min[3];   /* минимальная частота policy в кГц  */
    /* GPU */
    int gpu_max_pct;  /* % от max GPU freq                 */
    int gpu_min_pct;  /* % от min GPU freq                 */
    /* WALT */
    int ravg_ticks;
    int idle_enough;
    /* Scheduler */
    int uclamp_top_max; /* 0..100 */
    int uclamp_bg_max;
} asb_profile_caps_t;

/* Границы профилей — FSM НЕ может выйти за них */
typedef struct {
    asb_profile_caps_t floor; /* самый экономный вариант профиля */
    asb_profile_caps_t ceil;  /* самый производительный          */
} asb_profile_bounds_t;

/*
 * Значения для OnePlus 15 / Snapdragon 8 Elite
 * policy0 = little (0-3), policy4 = mid/big (4-6), policy7 = prime (7)
 * Частоты в кГц.
 */
static const asb_profile_bounds_t g_profile_bounds[3] = {
    /* [0] BATTERY */
    {
        .floor = {
            .cpu_max    = {  576000,  768000,  768000 },
            .cpu_min    = {  192000,  384000,  384000 },
            .gpu_max_pct = 15, .gpu_min_pct = 0,
            .ravg_ticks = 8, .idle_enough = 99,
            .uclamp_top_max = 12, .uclamp_bg_max = 5
        },
        .ceil = {
            .cpu_max    = { 1324800, 1132800, 1132800 },
            .cpu_min    = {  384000,  768000,  768000 },
            .gpu_max_pct = 25, .gpu_min_pct = 0,
            .ravg_ticks = 8, .idle_enough = 99,
            .uclamp_top_max = 16, .uclamp_bg_max = 8
        }
    },
    /* [1] BALANCED */
    {
        .floor = {
            .cpu_max    = { 1190400, 1881600, 2265600 },
            .cpu_min    = {  576000,  883200,  883200 },
            .gpu_max_pct = 50, .gpu_min_pct = 0,
            .ravg_ticks = 3, .idle_enough = 45,
            .uclamp_top_max = 60, .uclamp_bg_max = 30
        },
        .ceil = {
            .cpu_max    = { 3302400, 3974400, 4224000 },
            .cpu_min    = {  787200,  883200,  883200 },
            .gpu_max_pct = 90, .gpu_min_pct = 0,
            .ravg_ticks = 3, .idle_enough = 45,
            .uclamp_top_max = 85, .uclamp_bg_max = 40
        }
    },
    /* [2] PERFORMANCE */
    {
        .floor = {
            .cpu_max    = { 2112000, 2438400, 3072000 },
            .cpu_min    = { 1190400, 1881600, 2265600 },
            .gpu_max_pct = 60, .gpu_min_pct = 20,
            .ravg_ticks = 2, .idle_enough = 8,
            .uclamp_top_max = 85, .uclamp_bg_max = 60
        },
        .ceil = {
            .cpu_max    = { 3628800, 4608000, 4800000 },
            .cpu_min    = { 2112000, 2438400, 3072000 },
            .gpu_max_pct = 100, .gpu_min_pct = 30,
            .ravg_ticks = 2, .idle_enough = 8,
            .uclamp_top_max = 100, .uclamp_bg_max = 75
        }
    }
};

/* Индекс профиля */
#define PROFILE_BATTERY     0
#define PROFILE_BALANCED    1
#define PROFILE_PERFORMANCE 2

/* ─── State → caps mapping ─────────────────────────────────── */
/*
 * Для каждого состояния: насколько "высоко" в диапазоне профиля?
 * 0.0 = floor, 1.0 = ceil.
 * Линейная интерполяция между floor и ceil.
 */
static const float g_state_level[ASB_STATE_COUNT] = {
    [ASB_STATE_DEEP_IDLE]  = 0.0f,
    [ASB_STATE_LIGHT_IDLE] = 0.15f,
    [ASB_STATE_MODERATE]   = 0.45f,
    [ASB_STATE_HEAVY]      = 0.75f,
    [ASB_STATE_GAMING]     = 1.0f
};

static inline int lerp_int(int a, int b, float t) {
    return (int)(a + (b - a) * t + 0.5f);
}

static void fsm_interpolate_caps(
    const asb_profile_bounds_t *bounds, asb_state_t state,
    asb_profile_caps_t *out)
{
    float t = g_state_level[state];
    const asb_profile_caps_t *f = &bounds->floor;
    const asb_profile_caps_t *c = &bounds->ceil;

    for (int i = 0; i < 3; i++) {
        out->cpu_max[i] = lerp_int(f->cpu_max[i], c->cpu_max[i], t);
        out->cpu_min[i] = lerp_int(f->cpu_min[i], c->cpu_min[i], t);
    }
    out->gpu_max_pct    = lerp_int(f->gpu_max_pct,    c->gpu_max_pct,    t);
    out->gpu_min_pct    = lerp_int(f->gpu_min_pct,    c->gpu_min_pct,    t);
    out->ravg_ticks     = lerp_int(f->ravg_ticks,     c->ravg_ticks,     t > 0.5f ? 1.0f : 0.0f);
    out->idle_enough    = lerp_int(f->idle_enough,    c->idle_enough,    t);
    out->uclamp_top_max = lerp_int(f->uclamp_top_max, c->uclamp_top_max, t);
    out->uclamp_bg_max  = lerp_int(f->uclamp_bg_max,  c->uclamp_bg_max,  t);
}

/* ─── FSM context ──────────────────────────────────────────── */
typedef struct {
    asb_state_t     state;
    asb_state_t     pending;        /* кандидат на переход  */
    int             profile_idx;    /* 0/1/2                */
    int             thermal_cap;    /* 1 = thermal throttle */

    /* Гистерезис */
    int             pending_ticks;  /* сколько тиков в pending */
    /* Вверх: 2 тика (при 2с/тик = 4с), вниз: 5 тиков = 10с  */
    int             up_window;
    int             down_window;

    struct timespec last_transition;
    asb_profile_caps_t current_caps;

    /* Для лога: что изменилось */
    int             caps_changed;
    int             state_changed;
} asb_fsm_t;

static void fsm_init(asb_fsm_t *fsm, int profile_idx) {
    memset(fsm, 0, sizeof(*fsm));
    fsm->state       = ASB_STATE_LIGHT_IDLE;
    fsm->pending     = ASB_STATE_LIGHT_IDLE;
    fsm->profile_idx = profile_idx;
    fsm->up_window   = 2;
    fsm->down_window = 5;
    clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);
    /* Начальные caps */
    fsm_interpolate_caps(&g_profile_bounds[profile_idx],
                         fsm->state, &fsm->current_caps);
}

/* ─── Transition logic ─────────────────────────────────────── */
/*
 * Определяет желаемое состояние по метрикам.
 * Не учитывает гистерезис — только "что хочет быть".
 */
static asb_state_t fsm_desired(const asb_metrics_t *m) {
    if (!m->misc.screen_on) return ASB_STATE_DEEP_IDLE;

    /* mA доступен (> 0) — используем как основной сигнал нагрузки.
     * mA = 0 означает зарядку или недоступный sysfs-путь —
     * в этом случае опираемся только на GPU load и loadavg.       */
    int ma_valid = (m->bat.current_ma > 0 && !m->bat.charging);

    /* GAMING: GPU сильно занят */
    if (m->gpu.load_pct >= 65) {
        if (!ma_valid || m->bat.current_ma >= 300)
            return ASB_STATE_GAMING;
    }

    /* HEAVY: видео/карты/рендеринг */
    if (m->gpu.load_pct >= 35) {
        if (!ma_valid || m->bat.current_ma >= 150)
            return ASB_STATE_HEAVY;
    }

    /* MODERATE: активное использование CPU */
    if (m->cpu.load1 >= 1.5f)
        return ASB_STATE_MODERATE;
    if (ma_valid && m->bat.current_ma >= 120)
        return ASB_STATE_MODERATE;

    /* LIGHT_IDLE: экран ON, мало работы */
    return ASB_STATE_LIGHT_IDLE;
}

/*
 * Обновляет FSM на основе метрик.
 * Возвращает 1 если caps изменились (нужна запись в sysfs).
 */
static int fsm_update(asb_fsm_t *fsm, const asb_metrics_t *m) {
    fsm->state_changed = 0;
    fsm->caps_changed  = 0;

    /* ── Screen OFF: немедленный переход, без гистерезиса ──── */
    if (!m->misc.screen_on && fsm->state != ASB_STATE_DEEP_IDLE) {
        fsm->state   = ASB_STATE_DEEP_IDLE;
        fsm->pending = ASB_STATE_DEEP_IDLE;
        fsm->pending_ticks = 0;
        fsm->state_changed = 1;
    }
    /* ── Screen ON из DEEP_IDLE: немедленный подъём ─────────── */
    else if (m->misc.screen_on && fsm->state == ASB_STATE_DEEP_IDLE) {
        fsm->state   = ASB_STATE_LIGHT_IDLE;
        fsm->pending = ASB_STATE_LIGHT_IDLE;
        fsm->pending_ticks = 0;
        fsm->state_changed = 1;
    }
    else {
        asb_state_t desired = fsm_desired(m);

        if (desired != fsm->pending) {
            /* Новый кандидат — сбрасываем счётчик */
            fsm->pending       = desired;
            fsm->pending_ticks = 0;
        } else {
            fsm->pending_ticks++;
        }

        int window = (desired > fsm->state)
                     ? fsm->up_window    /* переход вверх: быстро */
                     : fsm->down_window; /* переход вниз: медленно */

        if (fsm->pending_ticks >= window && desired != fsm->state) {
            fsm->state         = desired;
            fsm->pending_ticks = 0;
            fsm->state_changed = 1;
            clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);
        }
    }

    /* ── Thermal overlay ─────────────────────────────────────── */
    int new_thermal = m->therm.throttling;
    if (new_thermal != fsm->thermal_cap) {
        fsm->thermal_cap  = new_thermal;
        fsm->caps_changed = 1; /* нужна перезапись с новыми limits */
    }

    /* ── Пересчёт caps ───────────────────────────────────────── */
    asb_profile_caps_t new_caps;
    fsm_interpolate_caps(&g_profile_bounds[fsm->profile_idx],
                         fsm->state, &new_caps);

    /* Если thermal throttle: принудительно снижаем на 20% */
    if (fsm->thermal_cap) {
        for (int i = 0; i < 3; i++)
            new_caps.cpu_max[i] = (int)(new_caps.cpu_max[i] * 0.80f);
        new_caps.gpu_max_pct = new_caps.gpu_max_pct > 20
                               ? new_caps.gpu_max_pct - 20 : 0;
    }

    /* Проверяем изменение */
    if (fsm->state_changed ||
        memcmp(&new_caps, &fsm->current_caps, sizeof(new_caps)) != 0)
    {
        fsm->current_caps = new_caps;
        fsm->caps_changed = 1;
    }

    return fsm->caps_changed;
}
