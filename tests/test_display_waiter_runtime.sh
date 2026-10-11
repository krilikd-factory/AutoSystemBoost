#!/bin/sh
# Runtime (fix116): wakes are seen the moment Android switches the display on.
#
# OnePlus 15 captures found 6 of 31 and 14 of 35 wakes only on the next 45 s idle tick, the
# OnePlus 13R 19 of 30 - unlock and launch on deep-idle rails. A thread now blocks in
# __system_property_wait on debug.tracing.screen_state and pokes an eventfd only when the
# display enters or leaves ON; always-on-display doze flips never reach the main loop.
# Executable fixture: the REAL waiter cut out of asb_governor.c, a fake property store
# whose __system_property_wait blocks on a condition variable.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; M="$ROOT/src/asb_metrics.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL display waiter: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP display waiter: no C compiler"; exit 0; }

# From the waiter's globals to the end of asb_disp_waiter_start().
_a="$(grep -n "^/\* \.\.\. and by Android's own display state" "$G" | cut -d: -f1)"
_b="$(awk '/^static int asb_disp_waiter_start\(/{f=1} f&&/^}/{print NR; exit}' "$G")"
[ -n "$_a" ] && [ -n "$_b" ] || fail "waiter code not found"
sed -n "${_a},${_b}p" "$G" > "$T/w.c"
awk '/^#ifndef ASB_DISPLAY_STATE_FIXTURE$/{on=1} on{print} on&&/^#endif$/{n++} n==2{exit}' "$M" > "$T/r.c"
grep -q 'pthread_sigmask(SIG_BLOCK' "$T/w.c" || fail "signals are not blocked on the waiter thread"
grep -q 'cur == 2 || prev == 2' "$T/w.c" || fail "waiter signals more than ON transitions"
grep -q 'debug.tracing.screen_state' "$T/r.c" || fail "property reader not found"

cat > "$T/t.c" <<'X'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <poll.h>
#include <pthread.h>
#include <dlfcn.h>
#include <sys/eventfd.h>
#define __ANDROID__ 1
#define PROP_VALUE_MAX 92
typedef struct prop_info { int dummy; } prop_info;
static prop_info g_pi;
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_cv = PTHREAD_COND_INITIALIZER;
static char g_val[8] = "1";
static uint32_t g_serial = 1;
static int g_waits = 0;
int __system_property_get(const char *n, char *v) {
    pthread_mutex_lock(&g_mx); strcpy(v, g_val); pthread_mutex_unlock(&g_mx); return (int)strlen(v); }
static int g_prop_exists = 0;   /* created at the first display transition after boot */
const prop_info *__system_property_find(const char *n) {
    if (strcmp(n, "debug.tracing.screen_state")) return NULL;
    pthread_mutex_lock(&g_mx); int e = g_prop_exists; pthread_mutex_unlock(&g_mx);
    return e ? &g_pi : NULL; }
uint32_t __system_property_serial(const prop_info *pi) {
    pthread_mutex_lock(&g_mx); uint32_t s = g_serial; pthread_mutex_unlock(&g_mx); return s; }
_Bool __system_property_wait(const prop_info *pi, uint32_t old, uint32_t *ns, const struct timespec *to) {
    pthread_mutex_lock(&g_mx);
    g_waits++;
    while (g_serial == old) pthread_cond_wait(&g_cv, &g_mx);
    *ns = g_serial;
    pthread_mutex_unlock(&g_mx);
    return 1;
}
static void setp(const char *v) {
    pthread_mutex_lock(&g_mx); strcpy(g_val, v); g_serial++; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mx);
    usleep(30000);
}
#include "r.c"
#include "w.c"
static int fired(int fd) {
    struct pollfd p = { fd, POLLIN, 0 };
    if (poll(&p, 1, 200) <= 0) return 0;
    uint64_t v; if (read(fd, &v, sizeof(v)) != sizeof(v)) return 0;
    return 1;
}
int main(void) {
    int bad = 0;
    #define CHECK(c, msg) do { if (!(c)) { printf("%s\n", msg); bad = 1; } } while (0)
    int fd = asb_disp_waiter_start();
    CHECK(fd >= 0, "waiter did not start");
    if (fd < 0) return 1;
    usleep(50000);
    CHECK(g_disp_waiter_up == 1, "waiter gave up before the property existed");
    /* the property appears only after the screen stayed on past the old 10-minute limit */
    usleep(2500000);
    CHECK(g_disp_waiter_up == 1, "waiter stopped looking");
    pthread_mutex_lock(&g_mx); g_prop_exists = 1; pthread_mutex_unlock(&g_mx);
    usleep(1300000);
    CHECK(g_disp_waiter_up == 2, "waiter did not pick up a property created late");
    setp("2"); CHECK(fired(fd), "OFF -> ON did not reach the main loop");
    setp("3"); CHECK(fired(fd), "ON -> DOZE did not reach the main loop");
    setp("4"); CHECK(!fired(fd), "DOZE -> DOZE_SUSPEND woke the main loop");
    setp("3"); CHECK(!fired(fd), "DOZE_SUSPEND -> DOZE woke the main loop");
    setp("1"); CHECK(!fired(fd), "DOZE -> OFF woke the main loop");
    setp("2"); CHECK(fired(fd), "second wake missed");
    setp("2"); CHECK(!fired(fd), "a rewrite of the same value woke the main loop");
    setp("1"); CHECK(fired(fd), "ON -> OFF missed");
    /* SIGTERM must land on the main thread: blocked on the waiter */
    sigset_t cur; pthread_sigmask(SIG_BLOCK, NULL, &cur);
    CHECK(!sigismember(&cur, SIGTERM), "the main thread was left with signals blocked");
    return bad;
}
X
"$CC" -std=gnu99 -Wall -Wno-unused-function -DASB_DISP_FIND_RETRY_S=1 -pthread -rdynamic -o "$T/t" "$T/t.c" -I"$T" -ldl 2>"$T/cc.err" \
  || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"

# Main-loop wiring: the eventfd is watched, a fresh ON is trusted for 3 s, wakes are counted.
grep -q 'fd == g_disp_prop_evfd' "$G" || fail "main loop does not watch the waiter"
grep -q 'g_disp_prop_on_ts = time(NULL);' "$G" || fail "ON transition not stamped"
grep -q 'now - g_disp_prop_on_ts <= 3' "$M" || fail "fresh ON not trusted (or trusted without a window)"
grep -q 'display:%lu' "$G" || fail "state file does not count display-state wakes"
grep -q 'display_waiter=%d' "$G" || fail "state file does not say whether the waiter runs"
echo "PASS display-state waiter: instant wake detection, no doze wakeups"
