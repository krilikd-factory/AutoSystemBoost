#!/bin/sh
# Runtime (fix117): a touch on a calm screen is answered at once.
#
# The governor learnt about interaction only from load and GPU sampled every 2-6 s, and
# light idle needed two agreeing ticks - so a scroll starting from a calm screen ran on
# light-idle ceilings for up to ~12 s. The touchscreen node is now watched while the screen
# is on, SAMPLED (out of epoll after each touch until the next active tick), and a fresh
# touch lifts LIGHT_IDLE to MODERATE on the spot; a touch within 3 s floors at MODERATE.
# Executable fixture: the REAL touch_drain()/touch_watch_set() cut out of asb_governor.c,
# driven through a pipe and a real epoll set.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; F="$ROOT/src/asb_fsm.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL touch watch: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP touch watch: no C compiler"; exit 0; }

_a="$(grep -n '^static int           g_touch_fd = -1;' "$G" | cut -d: -f1)"
_b="$(awk '/^static int touch_watch_set\(/{f=1} f&&/^}/{print NR; exit}' "$G")"
[ -n "$_a" ] && [ -n "$_b" ] || fail "touch watch code not found"
sed -n "${_a},${_b}p" "$G" | sed '/^static int touch_open(void) {$/,/^}$/d' > "$T/w.c"
grep -q 'touch_drain' "$T/w.c" || fail "touch_drain not extracted"

cat > "$T/t.c" <<'X'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/epoll.h>
#include <linux/input.h>
#include "w.c"
static void ev(int wfd, int type, int code, int value) {
    struct input_event e; memset(&e, 0, sizeof(e));
    e.type = (unsigned short)type; e.code = (unsigned short)code; e.value = value;
    if (write(wfd, &e, sizeof(e)) != sizeof(e)) perror("write");
}
static int ready(int ep, int fd) {
    struct epoll_event e[4];
    int n = epoll_wait(ep, e, 4, 50);
    for (int i = 0; i < n; i++) if (e[i].data.fd == fd) return 1;
    return 0;
}
int main(void) {
    int bad = 0;
    #define CHECK(c, msg) do { if (!(c)) { printf("%s\n", msg); bad = 1; } } while (0)
    int p[2]; if (pipe2(p, O_NONBLOCK)) return 1;
    int ep = epoll_create1(0);
    g_touch_fd = p[0];
    /* screen on: watched */
    touch_watch_set(ep, 1);
    CHECK(g_touch_in_epoll == 1, "screen-on did not watch the panel");
    ev(p[1], EV_ABS, ABS_MT_TRACKING_ID, 7); ev(p[1], EV_ABS, ABS_MT_POSITION_X, 300); ev(p[1], EV_SYN, SYN_REPORT, 0);
    CHECK(ready(ep, p[0]), "a touch did not wake the loop");
    CHECK(touch_drain(p[0]) == 1, "a touch was not recognised");
    /* sampled out: no wakeups while out */
    touch_watch_set(ep, 0);
    ev(p[1], EV_ABS, ABS_MT_POSITION_Y, 500); ev(p[1], EV_SYN, SYN_REPORT, 0);
    CHECK(!ready(ep, p[0]), "sampled-out watch still woke the loop");
    /* re-armed on the tick: what came meanwhile counts, then quiet */
    CHECK(touch_watch_set(ep, 1) == 1, "touches queued while out were lost");
    CHECK(!ready(ep, p[0]), "re-arm did not drain the queue");
    /* a key that is not BTN_TOUCH (e.g. a gesture key) is not a touch */
    ev(p[1], EV_KEY, KEY_F4, 1); ev(p[1], EV_SYN, SYN_REPORT, 0);
    CHECK(ready(ep, p[0]), "event not delivered");
    CHECK(touch_drain(p[0]) == 0, "a gesture key was read as a touch");
    ev(p[1], EV_KEY, BTN_TOUCH, 1); ev(p[1], EV_SYN, SYN_REPORT, 0);
    CHECK(touch_drain(p[0]) == 1, "BTN_TOUCH down not a touch");
    /* screen off: unwatched, no re-arm pending */
    g_touch_rearm = 1;
    touch_watch_set(ep, 0);
    CHECK(g_touch_in_epoll == 0 && g_touch_rearm == 0, "screen-off left the watch or a re-arm pending");
    /* no device: harmless */
    g_touch_fd = -1;
    CHECK(touch_watch_set(ep, 1) == 0 && g_touch_in_epoll == 0, "no device still armed something");
    return bad;
}
X
"$CC" -std=gnu99 -Wall -Wno-unused-function -o "$T/t" "$T/t.c" -I"$T" 2>"$T/cc.err" || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"

# The FSM side: the touch floor sits before the light-idle return, battery and camera
# excluded; the first touch lifts LIGHT_IDLE at once; the kick is cleared after each update.
awk '/A finger on the glass is interaction/{t=NR} /The light-idle ceiling is binding/{p=NR} END{exit !(t && p && t < p)}' "$F" \
  || fail "touch floor is not ahead of the light-idle decision"
grep -q 'g_touch_last_ts > 0 && time(NULL) - g_touch_last_ts <= ASB_TOUCH_RECENT_S)' "$F" || fail "touch floor has no time window"
grep -q 'm->misc.screen_on && g_touch_kick && fsm->state == ASB_STATE_LIGHT_IDLE &&' "$F" || fail "first touch does not lift light idle"
grep -q '!fsm_profile_is_battery && !m->misc.camera_active) {' "$F" || fail "battery/camera not excluded from the touch lift"
grep -q 'g_touch_kick = 0;   /\* answered (fix117) \*/' "$G" || fail "touch kick never cleared"
grep -q 'touch_watch=%d' "$G" || fail "state file does not report the touch watch"
grep -q '(void)touch_watch_set(epfd, 0);   /\* screen off' "$G" || fail "screen-off does not stop the touch watch"
echo "PASS touch watch: sampled, instant on a calm screen, off with the screen"
