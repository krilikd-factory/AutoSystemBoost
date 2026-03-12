/*
 * asb_governor.c — ASB Adaptive Runtime Governor
 *
 * Архитектура event loop:
 *
 *   epoll ждёт событий (блокирует без CPU):
 *     ├── timerfd_active  (2с)  — метрики когда экран ON
 *     ├── timerfd_idle    (5с)  — метрики когда экран OFF
 *     ├── ueventfd        — screen ON/OFF немедленно
 *     ├── timerfd_hourly  (1ч)  — обновление learner
 *     └── sockfd          — команды от action.sh
 *
 * В DEEP_IDLE: только timerfd_idle (5с) + ueventfd активны.
 * Таймер активных метрик приостановлен → CPU не будится зря.
 *
 * Потребление в DEEP_IDLE:
 *   - 0% CPU (epoll заблокирован)
 *   - ~50KB RSS (весь код + данные)
 *   - Просыпается только от uevent экрана или раз в 5с для
 *     проверки battery/thermal
 *
 * Компиляция в Termux:
 *   clang -O2 -o asb_governor asb_governor.c -lm
 *   (или через Makefile)
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <math.h>
#include <stdint.h>

#include "asb_metrics.h"
#include "asb_fsm.h"
#include "asb_learner.h"
#include "asb_writer.h"
#include "asb_socket.h"

/* ─── Config ────────────────────────────────────────────────── */
#define TIMER_ACTIVE_S  2   /* интервал метрик, экран ON  */
#define TIMER_IDLE_S    5   /* интервал метрик, экран OFF */
#define TIMER_HOURLY_S  3600

#define STATE_FILE      "/dev/.asb/state"
#define LOG_FILE        "/dev/.asb/governor.log"
#define PID_FILE        "/dev/.asb/governor.pid"
#define PROFILE_FILE    "/data/adb/modules/AutoSystemBoost/current_profile"

#define MAX_EVENTS      8

/* ─── Logging ───────────────────────────────────────────────── */
static FILE *g_logf = NULL;

static void asb_log(const char *fmt, ...) __attribute__((format(printf,1,2)));
static void asb_log(const char *fmt, ...) {
    if (!g_logf) return;
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

/* ─── State dump ────────────────────────────────────────────── */
static void write_state(const asb_fsm_t *fsm, const asb_metrics_t *m,
                        asb_prediction_t pred)
{
    static const char *profile_names[] = {"battery","balanced","performance"};
    static const char *pred_names[] = {"unknown","idle","light","active"};

    FILE *f = fopen(STATE_FILE, "w");
    if (!f) return;
    fprintf(f,
        "state=%s\nprofile=%s\n"
        "mA=%d\ngpu_pct=%d\nload1=%.2f\n"
        "cpu_max=%d,%d,%d\n"
        "thermal=%d\ncap_temp=%d\n"
        "predict=%s\n"
        "screen=%d\ncapacity=%d\n",
        asb_state_names[fsm->state],
        profile_names[fsm->profile_idx],
        m->bat.current_ma,
        m->gpu.load_pct,
        m->cpu.load1,
        fsm->current_caps.cpu_max[0],
        fsm->current_caps.cpu_max[1],
        fsm->current_caps.cpu_max[2],
        fsm->thermal_cap,
        m->therm.cpu_max_c,
        pred_names[pred],
        m->misc.screen_on,
        m->bat.capacity_pct);
    fclose(f);
}

/* ─── JSON status ───────────────────────────────────────────── */
static void build_status_json(const asb_fsm_t *fsm, const asb_metrics_t *m,
                               asb_prediction_t pred,
                               char *out, int outlen)
{
    static const char *profile_names[] = {"battery","balanced","performance"};
    static const char *pred_names[] = {"unknown","idle","light","active"};
    snprintf(out, outlen,
        "{\"state\":\"%s\",\"profile\":\"%s\","
        "\"mA\":%d,\"gpu\":%d,\"load\":%.2f,"
        "\"cpu_max\":[%d,%d,%d],"
        "\"thermal\":%d,\"temp\":%d,"
        "\"predict\":\"%s\",\"screen\":%d,\"bat\":%d}",
        asb_state_names[fsm->state],
        profile_names[fsm->profile_idx],
        m->bat.current_ma,
        m->gpu.load_pct,
        m->cpu.load1,
        fsm->current_caps.cpu_max[0],
        fsm->current_caps.cpu_max[1],
        fsm->current_caps.cpu_max[2],
        fsm->thermal_cap,
        m->therm.cpu_max_c,
        pred_names[pred],
        m->misc.screen_on,
        m->bat.capacity_pct);
}

/* ─── Profile reader ────────────────────────────────────────── */
static int read_profile_idx(void) {
    char buf[32] = {0};
    int fd = open(PROFILE_FILE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return PROFILE_BALANCED;
    int n = read(fd, buf, sizeof(buf)-1);
    close(fd);
    if (n <= 0) return PROFILE_BALANCED;
    buf[n] = '\0';
    /* trim newline */
    for (int i = 0; buf[i]; i++)
        if (buf[i] == '\n' || buf[i] == '\r') { buf[i] = '\0'; break; }
    if (strcmp(buf, "battery")     == 0) return PROFILE_BATTERY;
    if (strcmp(buf, "performance") == 0) return PROFILE_PERFORMANCE;
    return PROFILE_BALANCED;
}

/* ─── timerfd helpers ───────────────────────────────────────── */
static int make_timerfd(int secs) {
    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0) return -1;
    struct itimerspec its = {
        .it_interval = { secs, 0 },
        .it_value    = { secs, 0 }
    };
    timerfd_settime(fd, 0, &its, NULL);
    return fd;
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

static void timerfd_drain(int fd) {
    uint64_t exp;
    read(fd, &exp, sizeof(exp)); /* очищаем счётчик */
}

/* ─── Uevent screen monitor ─────────────────────────────────── */
/*
 * Слушаем kernel uevent socket.
 * Фильтруем события display/backlight.
 * При получении screen-event немедленно обновляем таймеры.
 *
 * Формат uevent: "ACTION@/path\0key=val\0key=val\0..."
 * Нас интересует SUBSYSTEM=backlight или SUBSYSTEM=drm
 */
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
    /* Увеличиваем буфер чтобы не терять события */
    int buf = 256 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof(buf));
    return fd;
}

/*
 * Читаем uevent буфер, ищем screen-related событие.
 * Возвращает:
 *   1  — экран включился
 *   0  — экран выключился
 *  -1  — не screen-событие (игнорировать)
 */
static int parse_uevent_screen(int fd) {
    char buf[4096];
    int n = recv(fd, buf, sizeof(buf)-1, MSG_DONTWAIT);
    if (n <= 0) return -1;
    buf[n] = '\0';

    int is_display = 0, is_power = 0;
    char *p = buf;
    /* uevent: нуль-разделённые строки */
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

/* ─── Signal handling ───────────────────────────────────────── */
static volatile int g_running = 1;
static void sig_handler(int sig) {
    (void)sig;
    g_running = 0;
}

/* ─── Main ──────────────────────────────────────────────────── */
int main(int argc, char **argv) {
    /* Быстрый режим: "status" или "profile:X" — просто отправить команду */
    if (argc >= 2) {
        char reply[512] = {0};
        asb_sock_send_cmd(argv[1], reply, sizeof(reply));
        if (reply[0]) puts(reply);
        return 0;
    }

    /* Daemon: проверяем не запущен ли уже */
    {
        char pidbuf[16] = {0};
        int pfd = open(PID_FILE, O_RDONLY | O_CLOEXEC);
        if (pfd >= 0) {
            read(pfd, pidbuf, sizeof(pidbuf)-1);
            close(pfd);
            pid_t old = (pid_t)atoi(pidbuf);
            if (old > 1 && kill(old, 0) == 0) {
                fprintf(stderr, "asb_governor already running (pid %d)\n", old);
                return 1;
            }
        }
    }

    /* Создаём рабочую директорию */
    mkdir("/dev/.asb", 0700);

    /* PID file */
    {
        char pidbuf[16];
        snprintf(pidbuf, sizeof(pidbuf), "%d\n", getpid());
        int pfd = open(PID_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (pfd >= 0) { write(pfd, pidbuf, strlen(pidbuf)); close(pfd); }
    }

    /* Логирование */
    g_logf = fopen(LOG_FILE, "a");
    asb_log("=== asb_governor starting (pid %d) ===", getpid());

    /* Сигналы */
    signal(SIGTERM, sig_handler);
    signal(SIGINT,  sig_handler);
    signal(SIGPIPE, SIG_IGN);

    /* Инициализация подсистем */
    thermal_discover();
    writer_init_cache();

    int profile_idx = read_profile_idx();
    asb_log("initial profile: %d", profile_idx);

    asb_fsm_t fsm;
    fsm_init(&fsm, profile_idx);

    asb_learn_db_t learn;
    learner_init(&learn);

    asb_accum_t accum;
    accum_init(&accum);

    asb_prediction_t cur_pred = learner_predict(&learn);
    learner_adjust_windows(&learn, &fsm.up_window, &fsm.down_window);
    asb_log("learner predict: %d, windows up=%d down=%d",
            cur_pred, fsm.up_window, fsm.down_window);

    /* epoll */
    int epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0) { perror("epoll_create1"); return 1; }

    /* timerfd: активный режим */
    int tfd_active = make_timerfd(TIMER_ACTIVE_S);
    /* timerfd: idle режим */
    int tfd_idle   = make_timerfd(TIMER_IDLE_S);
    /* timerfd: hourly learner */
    int tfd_hourly = make_timerfd(TIMER_HOURLY_S);
    /* uevent socket */
    int uefd       = make_uevent_fd();
    /* control socket */
    int sockfd     = asb_sock_create();

    if (tfd_active < 0 || tfd_idle < 0 || tfd_hourly < 0) {
        asb_log("failed to create timerfds");
        return 1;
    }

    /* В начале: активный таймер вооружён, idle вооружён.
     * При переходе в DEEP_IDLE: разоружаем active, вооружаем idle.  */
    int screen_on = metrics_screen_on();
    if (!screen_on) {
        disarm_timerfd(tfd_active);
    }

    /* Добавляем все fd в epoll */
    struct epoll_event ev = {0};
    ev.events = EPOLLIN;

    ev.data.fd = tfd_active; epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_active, &ev);
    ev.data.fd = tfd_idle;   epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_idle,   &ev);
    ev.data.fd = tfd_hourly; epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_hourly, &ev);
    if (uefd  >= 0) { ev.data.fd = uefd;   epoll_ctl(epfd, EPOLL_CTL_ADD, uefd,   &ev); }
    if (sockfd >= 0) { ev.data.fd = sockfd; epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev); }

    asb_metrics_t metrics;
    memset(&metrics, 0, sizeof(metrics));

    /* Начальное применение caps */
    metrics_read_all(&metrics);
    fsm_update(&fsm, &metrics);
    writer_apply_caps(&fsm.current_caps, 1); /* force=1 */
    write_state(&fsm, &metrics, cur_pred);
    asb_log("initial state: %s mA=%d gpu=%d%% load=%.2f",
            asb_state_names[fsm.state],
            metrics.bat.current_ma,
            metrics.gpu.load_pct,
            metrics.cpu.load1);

    /* ─── Event loop ─────────────────────────────────────────── */
    struct epoll_event events[MAX_EVENTS];

    while (g_running) {
        /* epoll_wait: блокируем до события.
         * timeout=-1: бесконечно. CPU = 0% пока нет событий. */
        int nev = epoll_wait(epfd, events, MAX_EVENTS, -1);
        if (nev < 0) {
            if (errno == EINTR) continue;
            break;
        }

        int need_metrics = 0;
        int force_write  = 0;
        int profile_changed = 0;

        for (int i = 0; i < nev; i++) {
            int fd = events[i].data.fd;

            /* ── Активный таймер (2с) ─────────────────────────── */
            if (fd == tfd_active) {
                timerfd_drain(fd);
                need_metrics = 1;
            }
            /* ── Idle таймер (5с) ────────────────────────────── */
            else if (fd == tfd_idle) {
                timerfd_drain(fd);
                need_metrics = 1;
            }
            /* ── Hourly learner ──────────────────────────────── */
            else if (fd == tfd_hourly) {
                timerfd_drain(fd);
                float avg_drain = 0, avg_screen = 0;
                /* accum_tick не вызываем здесь — он вызывается в need_metrics */
                /* Принудительный flush накопленного */
                if (accum.drain_count > 0) {
                    avg_drain  = accum.drain_sum / accum.drain_count;
                    avg_screen = accum.total_ticks > 0
                                 ? (float)accum.screen_on_ticks / accum.total_ticks
                                 : 0.0f;
                    learner_update(&learn, avg_drain, avg_screen);
                    cur_pred = learner_predict(&learn);
                    learner_adjust_windows(&learn,
                                          &fsm.up_window, &fsm.down_window);
                    asb_log("learner updated: drain=%.1fmA screen=%.0f%% "
                            "predict=%d windows=%d/%d",
                            avg_drain, avg_screen * 100,
                            cur_pred, fsm.up_window, fsm.down_window);
                    /* Сброс аккумулятора */
                    accum.drain_sum       = 0;
                    accum.drain_count     = 0;
                    accum.screen_on_ticks = 0;
                    accum.total_ticks     = 0;
                }
            }
            /* ── Uevent (screen events) ──────────────────────── */
            else if (fd == uefd) {
                int scr = parse_uevent_screen(fd);
                if (scr >= 0) {
                    int was_on = metrics.misc.screen_on;
                    metrics.misc.screen_on = scr;

                    if (scr != was_on) {
                        asb_log("screen %s (uevent)", scr ? "ON" : "OFF");
                        /* Немедленная реакция: пересчитываем FSM */
                        need_metrics = 1;
                        /* Переключаем таймеры */
                        if (scr) {
                            /* Экран ON: вооружаем быстрый таймер */
                            arm_timerfd(tfd_active, TIMER_ACTIVE_S);
                        } else {
                            /* Экран OFF: разоружаем быстрый таймер */
                            disarm_timerfd(tfd_active);
                        }
                    }
                    /* Дренируем остальные события в очереди */
                    while (parse_uevent_screen(uefd) >= 0) {}
                }
            }
            /* ── Control socket ──────────────────────────────── */
            else if (fd == sockfd) {
                char cmd[256] = {0};
                struct sockaddr_un src = {0};
                socklen_t srclen = sizeof(src);
                int n = asb_sock_recv(sockfd, cmd, sizeof(cmd), &src, &srclen);
                if (n <= 0) continue;

                asb_log("cmd: %s", cmd);

                if (strncmp(cmd, "profile:", 8) == 0) {
                    const char *pname = cmd + 8;
                    int new_idx = PROFILE_BALANCED;
                    if (strcmp(pname, "battery")     == 0) new_idx = PROFILE_BATTERY;
                    if (strcmp(pname, "performance") == 0) new_idx = PROFILE_PERFORMANCE;
                    if (new_idx != fsm.profile_idx) {
                        fsm.profile_idx = new_idx;
                        profile_changed = 1;
                        force_write = 1;
                        need_metrics = 1;
                        asb_sock_reply(sockfd, &src, srclen, "ok");
                        asb_log("profile changed to %d", new_idx);
                    } else {
                        asb_sock_reply(sockfd, &src, srclen, "ok:nochange");
                    }
                }
                else if (strcmp(cmd, "status") == 0) {
                    char jbuf[512];
                    build_status_json(&fsm, &metrics, cur_pred, jbuf, sizeof(jbuf));
                    asb_sock_reply(sockfd, &src, srclen, jbuf);
                }
                else if (strcmp(cmd, "reload") == 0) {
                    int new_idx = read_profile_idx();
                    if (new_idx != fsm.profile_idx) {
                        fsm.profile_idx = new_idx;
                        force_write = 1;
                        need_metrics = 1;
                    }
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strcmp(cmd, "quit") == 0) {
                    asb_sock_reply(sockfd, &src, srclen, "bye");
                    g_running = 0;
                }
                (void)profile_changed;
            }
        } /* for events */

        /* ── Читаем метрики и обновляем FSM ─────────────────── */
        if (need_metrics) {
            metrics_read_all(&metrics);

            /* Аккумулятор для learner */
            float dummy_drain, dummy_screen;
            if (accum_tick(&accum,
                           metrics.bat.current_ma,
                           metrics.misc.screen_on,
                           &dummy_drain, &dummy_screen)) {
                /* Час сменился внутри accum_tick */
                learner_update(&learn, dummy_drain, dummy_screen);
                cur_pred = learner_predict(&learn);
                learner_adjust_windows(&learn, &fsm.up_window, &fsm.down_window);
            }

            int changed = fsm_update(&fsm, &metrics);

            if (changed || force_write) {
                int writes = writer_apply_caps(&fsm.current_caps, force_write);
                write_state(&fsm, &metrics, cur_pred);

                if (fsm.state_changed) {
                    asb_log("FSM: %s mA=%d gpu=%d%% load=%.2f "
                            "t=%d°C writes=%d",
                            asb_state_names[fsm.state],
                            metrics.bat.current_ma,
                            metrics.gpu.load_pct,
                            metrics.cpu.load1,
                            metrics.therm.cpu_max_c,
                            writes);
                }
            }
        }
    } /* while running */

    /* ── Cleanup ─────────────────────────────────────────────── */
    asb_log("governor stopping");
    close(tfd_active);
    close(tfd_idle);
    close(tfd_hourly);
    if (uefd  >= 0) close(uefd);
    if (sockfd >= 0) close(sockfd);
    close(epfd);
    unlink(ASB_SOCK_PATH);
    unlink(PID_FILE);
    if (g_logf) fclose(g_logf);
    return 0;
}
