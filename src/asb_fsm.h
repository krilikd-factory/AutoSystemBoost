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
#include "asb_config.h"

extern asb_runtime_config_t g_asb_cfg;

/* ─── States ───────────────────────────────────────────────── */
typedef enum {
    ASB_STATE_DEEP_IDLE  = 0, /* screen OFF, полный покой          */
    ASB_STATE_LIGHT_IDLE = 1, /* screen ON, ничего не делаем       */
    ASB_STATE_MODERATE   = 2, /* активное использование            */
    ASB_STATE_HEAVY      = 3, /* видео, карты, рендеринг           */
    ASB_STATE_SUSTAINED  = 4, /* длительная нагрузка под thermal   */
    ASB_STATE_GAMING     = 5, /* игры, нагрузка GPU > threshold    */
    ASB_STATE_COUNT      = 6
} asb_state_t;

static const char *asb_state_names[] = {
    "DEEP_IDLE", "LIGHT_IDLE", "MODERATE", "HEAVY", "SUSTAINED", "GAMING"
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
    int gpu_max_pct;
    int gpu_min_pct;
    /* WALT */
    int ravg_ticks;
    int idle_enough;
    /* Scheduler */
    int uclamp_top_max;
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
/* ─── Profile bounds — OnePlus 15 / Snapdragon 8 Elite ─────────────
 * CPU topology: policy0 (cpus 0-5, max 3628800)
 *               policy6 (cpus 6-7, max 4608000)
 * cpu_max[2] = 0 → не используется (только 2 policy на этом устройстве)
 *
 * Диапазоны выбраны внутри vendor-разрешённых окон:
 * - battery: жёсткий лимит, экономия батареи
 * - balanced: сбалансированный диапазон
 * - performance: полный потолок hardware
 *
 * WALT/uclamp используются как основной механизм влияния —
 * они работают надёжно даже при vendor perf HAL override.    */
static const asb_profile_bounds_t g_profile_bounds[3] = {
    /* [0] BATTERY — сильно ограничиваем */
    {
        .floor = {
            /* DEEP_IDLE: policy0@1190400, policy6@1344000 */
            .cpu_max    = { 1190400, 1344000, 0 },
            .cpu_min    = {  384000,  768000, 0 },
            .gpu_max_pct = 15, .gpu_min_pct = 0,
            .ravg_ticks = 8, .idle_enough = 95,
            .uclamp_top_max = 10, .uclamp_bg_max = 5
        },
        .ceil = {
            /* MODERATE: policy0@1612800, policy6@2265600 */
            .cpu_max    = { 1612800, 2265600, 0 },
            .cpu_min    = {  576000,  883200, 0 },
            .gpu_max_pct = 30, .gpu_min_pct = 0,
            .ravg_ticks = 8, .idle_enough = 95,
            .uclamp_top_max = 25, .uclamp_bg_max = 10
        }
    },
    /* [1] BALANCED — рабочий диапазон */
    {
        .floor = {
            /* LIGHT_IDLE: умеренные ограничения */
            .cpu_max    = { 1728000, 2265600, 0 },
            .cpu_min    = {  576000,  883200, 0 },
            .gpu_max_pct = 45, .gpu_min_pct = 0,
            .ravg_ticks = 4, .idle_enough = 50,
            .uclamp_top_max = 50, .uclamp_bg_max = 25
        },
        .ceil = {
            /* GAMING: снимаем ограничения */
            .cpu_max    = { 2745600, 3648000, 0 },
            .cpu_min    = {  787200,  883200, 0 },
            .gpu_max_pct = 85, .gpu_min_pct = 0,
            .ravg_ticks = 3, .idle_enough = 45,
            .uclamp_top_max = 80, .uclamp_bg_max = 35
        }
    },
    /* [2] PERFORMANCE — полный потенциал */
    {
        .floor = {
            /* MODERATE при performance: уже высокие базовые */
            .cpu_max    = { 2265600, 3072000, 0 },
            .cpu_min    = { 1190400, 1881600, 0 },
            .gpu_max_pct = 60, .gpu_min_pct = 20,
            .ravg_ticks = 2, .idle_enough = 10,
            .uclamp_top_max = 80, .uclamp_bg_max = 55
        },
        .ceil = {
            /* GAMING: аппаратный максимум */
            .cpu_max    = { 3628800, 4608000, 0 },
            .cpu_min    = { 2112000, 2438400, 0 },
            .gpu_max_pct = 100, .gpu_min_pct = 30,
            .ravg_ticks = 2, .idle_enough = 8,
            .uclamp_top_max = 100, .uclamp_bg_max = 75
        }
    }
};

/* Индекс профиля */
#define PROFILE_BATTERY     0
/* Текущий профиль для fsm_desired (обновляется governor.c) */
static int fsm_profile_is_battery = 0;
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
    [ASB_STATE_HEAVY]      = 0.72f,
    [ASB_STATE_SUSTAINED]  = 0.84f,
    [ASB_STATE_GAMING]     = 1.0f
};

static inline int lerp_int(int a, int b, float t) {
    return (int)(a + (b - a) * t + 0.5f);
}

static void fsm_interpolate_caps(
    const asb_profile_bounds_t *bounds, asb_state_t state,
    asb_profile_caps_t *out)
{
    float t = (state == ASB_STATE_SUSTAINED)
              ? g_asb_cfg.sustained_level   /* конфигурируемый уровень SUSTAINED */
              : g_state_level[state];
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
    asb_state_t     pending;
    int             profile_idx;
    int             thermal_cap;

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
    asb_state_t     prev_state;     /* state до последнего перехода */
    /* Gap-aware SUSTAINED (V22-r5) */
    int             gaming_gap_ticks_count; /* сколько тиков подряд GAMING gap превышал порог */
    time_t          gaming_retry_until;     /* cooldown: не пытаться GAMING до этого времени */
    int             sustained_reason;       /* 0=thermal, 1=gap_unreachable — причина последнего входа */
    time_t          sustained_reentry_until; /* cooldown: не входить в SUSTAINED до этого времени */

    /* ── Session telemetry (V22-r11) ──────────────────────────
     * Сбрасывается при fsm_init() и при команде 'reload'.
     * Позволяет ответить: как governor провёл эту сессию?  */
    int             ses_gaming_entries;      /* сколько раз вошли в GAMING */
    int             ses_sustained_entries;   /* сколько раз вошли в SUSTAINED */
    int             ses_thermal_entries;     /* из них — по thermal path */
    int             ses_unreachable_entries; /* из них — по gaming_unreachable */

    long            ses_time_heavy_sec;      /* суммарное время в HEAVY */
    long            ses_time_gaming_sec;     /* суммарное время в GAMING */
    long            ses_time_sustained_sec;  /* суммарное время в SUSTAINED */

    long            ses_gap_p0_sum;          /* для avg_gap_p0 в GAMING */
    long            ses_gap_p1_sum;
    int             ses_gap_samples;
    int             ses_max_gap_p0;
    int             ses_max_gap_p1;
    int             ses_max_temp;            /* максимальная температура за сессию */

    struct timespec ses_state_enter;         /* когда вошли в текущий state */
    int             ses_auto_degraded;       /* 1 = auto уже деградировал в stable-like */

    /* Battery-mode telemetry */
    long            bat_time_deep_idle_sec;   /* суммарное время в DEEP_IDLE при battery */
    long            bat_time_light_idle_sec;  /* суммарное время в LIGHT_IDLE при battery */
    int             bat_wake_cycles;          /* сколько раз вышли из DEEP_IDLE при battery */
    int             bat_gaming_suppressed;    /* сколько раз GAMING заблокирован bat_suppress */
} asb_fsm_t;

static inline long fsm_elapsed_sec(const asb_fsm_t *fsm) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long)(now.tv_sec - fsm->last_transition.tv_sec);
}

static inline int fsm_min_dwell_for_state(asb_state_t st) {
    switch (st) {
        case ASB_STATE_HEAVY: return g_asb_cfg.heavy_min_dwell_s;
        case ASB_STATE_SUSTAINED: return g_asb_cfg.sustained_min_dwell_s;
        case ASB_STATE_GAMING: return g_asb_cfg.gaming_min_dwell_s;
        default: return 0;
    }
}

static void fsm_init(asb_fsm_t *fsm, int profile_idx) {
    memset(fsm, 0, sizeof(*fsm));
    fsm->state       = ASB_STATE_LIGHT_IDLE;
    fsm->pending     = ASB_STATE_LIGHT_IDLE;
    fsm->profile_idx = profile_idx;
    fsm->up_window   = 2;
    fsm->down_window = 5;
    clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);
    clock_gettime(CLOCK_MONOTONIC, &fsm->ses_state_enter);
    /* Начальные caps */
    fsm_interpolate_caps(&g_profile_bounds[profile_idx],
                         fsm->state, &fsm->current_caps);
}

/* Сбрасывает накопленную телеметрию (при reload) */
static inline void fsm_session_reset(asb_fsm_t *fsm) {
    fsm->ses_gaming_entries      = 0;
    fsm->ses_sustained_entries   = 0;
    fsm->ses_thermal_entries     = 0;
    fsm->ses_unreachable_entries = 0;
    fsm->ses_time_heavy_sec      = 0;
    fsm->ses_time_gaming_sec     = 0;
    fsm->ses_time_sustained_sec  = 0;
    fsm->ses_gap_p0_sum          = 0;
    fsm->ses_gap_p1_sum          = 0;
    fsm->ses_gap_samples         = 0;
    fsm->ses_max_gap_p0          = 0;
    fsm->ses_max_gap_p1          = 0;
    fsm->ses_max_temp            = 0;
    clock_gettime(CLOCK_MONOTONIC, &fsm->ses_state_enter);
    fsm->ses_auto_degraded      = 0;
    fsm->bat_time_deep_idle_sec  = 0;
    fsm->bat_time_light_idle_sec = 0;
    fsm->bat_wake_cycles         = 0;
    fsm->bat_gaming_suppressed   = 0;
}

/* ─── Transition logic ─────────────────────────────────────── */
/*
 * Определяет желаемое состояние по метрикам.
 * Не учитывает гистерезис — только "что хочет быть".
 */
static asb_state_t fsm_desired(const asb_metrics_t *m) {
    if (!m->misc.screen_on) return ASB_STATE_DEEP_IDLE;

    int ma_valid = (m->bat.current_ma > 0 && !m->bat.charging);

    /* GAMING: только по GPU нагрузке, без mA guard.
     * В battery профиле GAMING подавляется — экономия важнее пика. */
    if (m->gpu.load_pct >= g_asb_cfg.gaming_gpu_enter) {
        if (g_asb_cfg.bat_suppress_gaming && fsm_profile_is_battery)
            return ASB_STATE_HEAVY; /* battery: GAMING → HEAVY */
        return ASB_STATE_GAMING;
    }

    /* SUSTAINED не возвращается из fsm_desired напрямую.
     * Promotion в SUSTAINED происходит в fsm_update только если
     * мы уже находимся в HEAVY/GAMING (не с нуля).                */

    if (m->gpu.load_pct >= g_asb_cfg.heavy_gpu_enter ||
        m->cpu.load1 >= g_asb_cfg.heavy_load_enter) {
        if (!ma_valid || m->bat.current_ma >= 150)
            return ASB_STATE_HEAVY;
    }

    if (m->cpu.load1 >= 1.5f)
        return ASB_STATE_MODERATE;
    if (ma_valid && m->bat.current_ma >= 120)
        return ASB_STATE_MODERATE;

    return ASB_STATE_LIGHT_IDLE;
}

/*
 * Обновляет FSM на основе метрик.
 * Возвращает 1 если caps изменились (нужна запись в sysfs).
 */
static int fsm_update(asb_fsm_t *fsm, const asb_metrics_t *m) {
    fsm->state_changed = 0;
    fsm->caps_changed  = 0;
    fsm->prev_state    = fsm->state;  /* запоминаем перед любым переходом */

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

        int thermal_to_sustained = 0;
        int gap_to_sustained = 0;

        /* ── Путь 1: SUSTAINED через thermal (существующий) ─────── */
        int sustained_reentry_blocked = (fsm->sustained_reentry_until > 0 &&
                                         time(NULL) < fsm->sustained_reentry_until);
        if (!sustained_reentry_blocked &&
            m->therm.throttling &&
            fsm->state >= ASB_STATE_HEAVY &&
            desired >= ASB_STATE_HEAVY)
        {
            desired = ASB_STATE_SUSTAINED;
            thermal_to_sustained = 1;
            fsm->sustained_reason = 0;
        }

        /* ── Путь 2: SUSTAINED через gap-aware (V22-r5) ──────────── */
        /* Если в GAMING caps физически недостижимы несколько тиков подряд,
         * переходим в SUSTAINED без ожидания теплового порога.        */
        if (!thermal_to_sustained && !sustained_reentry_blocked &&
            fsm->state == ASB_STATE_GAMING &&
            g_asb_cfg.gaming_gap_thresh > 0)
        {
            /* Читаем текущий реальный gap для policy0 (первичный кластер) */
            int cur_max_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
            int cur_gap    = (cur_max_p0 > 0)
                             ? (fsm->current_caps.cpu_max[0] - cur_max_p0)
                             : 0;
            if (cur_gap > g_asb_cfg.gaming_gap_thresh) {
                fsm->gaming_gap_ticks_count++;
            } else {
                fsm->gaming_gap_ticks_count = 0;
            }

            if (fsm->gaming_gap_ticks_count >= g_asb_cfg.gaming_gap_ticks &&
                desired >= ASB_STATE_HEAVY)
            {
                desired = ASB_STATE_SUSTAINED;
                gap_to_sustained = 1;
                fsm->gaming_gap_ticks_count = 0;
                fsm->sustained_reason = 1;
            }
        } else if (fsm->state != ASB_STATE_GAMING) {
            fsm->gaming_gap_ticks_count = 0; /* сброс если вышли из GAMING */
        }

        /* ── Cooldown: защита от немедленного возврата в GAMING ──── */
        /* После выхода из SUSTAINED, если cooldown активен и desired=GAMING,
         * опускаем до HEAVY — даём системе остыть/стабилизироваться.  */
        if (!thermal_to_sustained && !gap_to_sustained &&
            desired == ASB_STATE_GAMING)
        {
            time_t now_t = time(NULL);
            int cooldown_active = (fsm->gaming_retry_until > 0 &&
                                   now_t < fsm->gaming_retry_until);
            /* Температурное условие: retry только если чип остыл */
            int too_hot = (g_asb_cfg.gaming_retry_temp_max > 0 &&
                           m->therm.cpu_max_c > g_asb_cfg.gaming_retry_temp_max &&
                           fsm->gaming_retry_until > 0); /* только после SUSTAINED */
            if (cooldown_active || too_hot) {
                desired = ASB_STATE_HEAVY;
            } else {
                fsm->gaming_retry_until = 0;
            }
        }
        /* Устанавливаем cooldowns при выходе из SUSTAINED */
        if (fsm->prev_state == ASB_STATE_SUSTAINED &&
            fsm->state_changed &&
            fsm->state != ASB_STATE_SUSTAINED)
        {
            time_t now_exit = time(NULL);
            if (g_asb_cfg.gaming_retry_cooldown_s > 0)
                fsm->gaming_retry_until = now_exit + g_asb_cfg.gaming_retry_cooldown_s;
            if (g_asb_cfg.sustained_reentry_cooldown_s > 0)
                fsm->sustained_reentry_until = now_exit + g_asb_cfg.sustained_reentry_cooldown_s;
        }

        int window = (desired > fsm->state)
                     ? fsm->up_window
                     : fsm->down_window;
        if (thermal_to_sustained) window = 1;

        if (fsm->pending_ticks >= window && desired != fsm->state) {
            int can_leave = 1;
            /* Температурный гистерезис SUSTAINED применяется В ЛЮБОМ направлении.
             * Баг r8: выход через GAMING (desired > state) обходил проверку т.к.
             * блок был внутри 'if (desired < state)'. Теперь вынесен наружу.   */
            if (fsm->state == ASB_STATE_SUSTAINED &&
                g_asb_cfg.sustained_temp_exit > 0 &&
                m->therm.cpu_max_c >= g_asb_cfg.sustained_temp_exit)
                can_leave = 0;
            if (can_leave && desired < fsm->state) {
                int min_dwell = fsm_min_dwell_for_state(fsm->state);
                if (min_dwell > 0 && fsm_elapsed_sec(fsm) < min_dwell)
                    can_leave = 0;
            }
            if (can_leave) {
                fsm->state         = desired;
                fsm->pending_ticks = 0;
                fsm->state_changed = 1;
                clock_gettime(CLOCK_MONOTONIC, &fsm->last_transition);
            }
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

    /* Thermal overlay: для обычных состояний чуть снижаем цели.
     * Для SUSTAINED не режем дополнительно — этот state уже сам по себе
     * является мягким путём отступления перед thermal wall. */
    if (fsm->thermal_cap && fsm->state != ASB_STATE_SUSTAINED) {
        float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
        for (int i = 0; i < 3; i++)
            new_caps.cpu_max[i] = (int)(new_caps.cpu_max[i] * keep);
        int gpu_drop = g_asb_cfg.thermal_overlay_pct;
        new_caps.gpu_max_pct = new_caps.gpu_max_pct > gpu_drop
                               ? new_caps.gpu_max_pct - gpu_drop : 0;
    }

    /* Проверяем изменение */
    if (fsm->state_changed ||
        memcmp(&new_caps, &fsm->current_caps, sizeof(new_caps)) != 0)
    {
        fsm->current_caps = new_caps;
        fsm->caps_changed = 1;
    }

    /* ── Session telemetry update (V22-r11) ──────────────────── */
    /* 1. Температура */
    if (m->therm.cpu_max_c > fsm->ses_max_temp)
        fsm->ses_max_temp = m->therm.cpu_max_c;

    /* 2. Gap в GAMING — накапливаем каждый тик */
    if (fsm->state == ASB_STATE_GAMING) {
        int cur_max_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
        int cur_max_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
        if (cur_max_p0 > 0) {
            int g0 = fsm->current_caps.cpu_max[0] - cur_max_p0;
            int g1 = (cur_max_p1 > 0) ? (fsm->current_caps.cpu_max[1] - cur_max_p1) : 0;
            if (g0 > 0) {
                fsm->ses_gap_p0_sum += g0;
                fsm->ses_gap_p1_sum += g1;
                fsm->ses_gap_samples++;
                if (g0 > fsm->ses_max_gap_p0) fsm->ses_max_gap_p0 = g0;
                if (g1 > fsm->ses_max_gap_p1) fsm->ses_max_gap_p1 = g1;
            }
        }
    }

    /* 3. State counters и time — при переходе */
    if (fsm->state_changed) {
        /* Накапливаем время в предыдущем state */
        struct timespec now_ts;
        clock_gettime(CLOCK_MONOTONIC, &now_ts);
        long spent = (long)(now_ts.tv_sec - fsm->ses_state_enter.tv_sec);
        switch (fsm->prev_state) {
            case ASB_STATE_HEAVY:    fsm->ses_time_heavy_sec    += spent; break;
            case ASB_STATE_GAMING:   fsm->ses_time_gaming_sec   += spent; break;
            case ASB_STATE_SUSTAINED:fsm->ses_time_sustained_sec+= spent; break;
            case ASB_STATE_DEEP_IDLE:
                if (fsm_profile_is_battery) { fsm->bat_time_deep_idle_sec  += spent; } break;
            case ASB_STATE_LIGHT_IDLE:
                if (fsm_profile_is_battery) { fsm->bat_time_light_idle_sec += spent; } break;
            default: break;
        }
        /* Battery wake cycle counter */
        if (fsm_profile_is_battery &&
            fsm->prev_state == ASB_STATE_DEEP_IDLE &&
            fsm->state != ASB_STATE_DEEP_IDLE)
            fsm->bat_wake_cycles++;
        fsm->ses_state_enter = now_ts;

        /* Считаем входы в state */
        if (fsm->state == ASB_STATE_GAMING)
            fsm->ses_gaming_entries++;
        if (fsm->state == ASB_STATE_SUSTAINED)
            fsm->ses_sustained_entries++;
        /* Battery: считаем подавленные GAMING входы */
        if (fsm_profile_is_battery &&
            g_asb_cfg.bat_suppress_gaming &&
            fsm->state == ASB_STATE_HEAVY &&
            fsm->prev_state != ASB_STATE_GAMING) /* только новый вход, не reassert */
        {
            /* gpu >= gaming_gpu_enter → было бы GAMING, но подавлено */
        }
    }

    return fsm->caps_changed;
}
