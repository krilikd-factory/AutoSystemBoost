#!/bin/sh
# Runtime (fix118): with Android's display state watched, the uevent socket stays parked.
#
# An OP15 night delivered 250-500 kernel uevents an hour to the governor (AOD pulses,
# battery, thermal, "other"), each one a wakeup to discard it. Once the display-state
# waiter is live it reports every wake, so the socket is parked with the screen off as well;
# the wake keys keep listening as the backstop and still leave epoll while the screen is
# on (the touch panel's node would wake the loop on every frame). Without the waiter the
# old behaviour is exact. Executable fixture: the REAL uev_park()/uev_unpark() and wake-key
# parking cut out of asb_governor.c, against a real epoll set.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL uevent park: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP uevent park: no C compiler"; exit 0; }
_a="$(grep -n '^static int           g_uev_parked = 0;' "$G" | cut -d: -f1)"
_b="$(awk '/^static void uev_unpark\(/{f=1} f&&/^}/{print NR; exit}' "$G")"
[ -n "$_a" ] && [ -n "$_b" ] || fail "park code not found"
sed -n "${_a},${_b}p" "$G" | sed -e '/^static void wake_keys_open(int epfd) {$/,/^}$/d' -e '/^static int touch_open(void) {$/,/^}$/d' > "$T/p.c"

cat > "$T/t.c" <<'X'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <linux/input.h>
static volatile int g_disp_waiter_up = 0;
#include "p.c"
static int in_epoll(int ep, int fd) {
    struct epoll_event e; memset(&e, 0, sizeof(e)); e.events = EPOLLIN; e.data.fd = fd;
    if (epoll_ctl(ep, EPOLL_CTL_MOD, fd, &e) == 0) return 1;
    return errno != ENOENT ? -1 : 0;
}
int main(void) {
    int bad = 0;
    #define CHECK(c, msg) do { if (!(c)) { printf("%s\n", msg); bad = 1; } } while (0)
    int ep = epoll_create1(0);
    int u[2], k[2]; if (pipe2(u, O_NONBLOCK) || pipe2(k, O_NONBLOCK)) return 1;
    int ue = u[0];
    struct epoll_event e; memset(&e, 0, sizeof(e)); e.events = EPOLLIN;
    e.data.fd = ue; epoll_ctl(ep, EPOLL_CTL_ADD, ue, &e);
    g_wake_key_fd[0] = k[0]; g_wake_key_touch[0] = 1; g_wake_key_n = 1;
    e.data.fd = k[0]; epoll_ctl(ep, EPOLL_CTL_ADD, k[0], &e);

    /* no waiter: screen on parks both, screen off unparks both (old behaviour) */
    uev_park(ep, ue);
    CHECK(g_uev_parked == 1 && in_epoll(ep, ue) == 0 && in_epoll(ep, k[0]) == 0, "screen on did not park socket+keys");
    uev_unpark(ep, ue);
    CHECK(g_uev_parked == 0 && in_epoll(ep, ue) == 1 && in_epoll(ep, k[0]) == 1, "screen off did not unpark socket+keys");

    /* waiter live: screen on parks both; screen off brings back the keys only */
    g_disp_waiter_up = 2;
    uev_park(ep, ue);
    CHECK(g_uev_parked == 1 && in_epoll(ep, ue) == 0 && in_epoll(ep, k[0]) == 0, "screen on (waiter) did not park");
    uev_unpark(ep, ue);
    CHECK(g_uev_parked == 1 && in_epoll(ep, ue) == 0, "screen off unparked the uevent socket although the waiter is live");
    CHECK(in_epoll(ep, k[0]) == 1, "screen off (waiter) left the wake keys out");
    uev_park(ep, ue);
    CHECK(in_epoll(ep, k[0]) == 0, "screen on (waiter) left the touch panel's wake-key node in epoll");
    uev_unpark(ep, ue);
    /* waiter gone: the next screen-off path gives the socket back */
    g_disp_waiter_up = -1;
    uev_unpark(ep, ue);
    CHECK(g_uev_parked == 0 && in_epoll(ep, ue) == 1, "socket not given back after the waiter went away");
    return bad;
}
X
"$CC" -std=gnu99 -Wall -Wno-unused-function -o "$T/t" "$T/t.c" -I"$T" 2>"$T/cc.err" || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"
echo "PASS uevent park: socket parked while Android reports wakes, keys as backstop"
