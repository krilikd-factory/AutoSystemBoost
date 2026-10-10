#!/bin/sh
# Uevent parking: with the screen on, the uevent socket is out of epoll (a field OP15 had
# 29298 display uevents in ~7 h, each an epoll wake + panel sysfs read); the tick that sees
# the screen go off puts it back, drops what queued, and runs the screen-off work the
# uevent path runs (stats save, screen-off session plan + prearm).
# Executable fixture: the REAL park/unpark functions against epoll and a datagram socket.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/asb_governor.c"
fail() { echo "FAIL uevent parking: $*" >&2; exit 1; }

grep -q 'uev_park(epfd, uefd);' "$SRC" || fail "screen-on paths do not park"
grep -q 'if (screen_on) uev_park(epfd, uefd);' "$SRC" || fail "startup with the screen on does not park"
_off="$(sed -n '/} else if (!metrics.misc.screen_on && _ts == 1) {/,/^                }/p' "$SRC")"
printf '%s\n' "$_off" | grep -q 'uev_unpark(epfd, uefd);' || fail "tick screen-off does not unpark"
printf '%s\n' "$_off" | grep -q 'session_plan_build(&fsm, 0);' || fail "tick screen-off skips the screen-off session plan"
printf '%s\n' "$_off" | grep -q 'session_plan_apply_prearm(&fsm);' || fail "tick screen-off skips the prearm"
printf '%s\n' "$_off" | grep -q 'persistent_stats_save(&fsm);' || fail "tick screen-off skips the stats save"
grep -q 'uevent_dropped_while_parked=' "$SRC" || fail "parking not published"
grep -q 'uevent_dropped_while_parked' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show parking"

CC_BIN=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC_BIN="$c"; break; }; done
if [ -z "$CC_BIN" ]; then echo "PASS uevent parking contract (no C compiler: source pins only)"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  printf '#include <stdio.h>\n#include <string.h>\n#include <errno.h>\n#include <unistd.h>\n#include <fcntl.h>\n#include <sys/ioctl.h>\n#include <linux/input.h>\n#include <sys/epoll.h>\n#include <sys/socket.h>\n'
  sed -n '/^static int           g_uev_parked = 0;$/,/^static void uev_unpark(int epfd, int uefd) {$/p' "$SRC" | sed '$d'
  sed -n '/^static void uev_unpark(int epfd, int uefd) {$/,/^}$/p' "$SRC"
  cat <<'EOF'
int main(void) {
    int sv[2], ep = epoll_create1(0), bad = 0;
    struct epoll_event ev = {0}, out[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) != 0 || ep < 0) return 2;
    ev.events = EPOLLIN; ev.data.fd = sv[0];
    epoll_ctl(ep, EPOLL_CTL_ADD, sv[0], &ev);
    uev_park(ep, sv[0]);
    if (!g_uev_parked || g_uev_parks != 1) { puts("not parked"); bad++; }
    uev_park(ep, sv[0]);
    if (g_uev_parks != 1) { puts("parked twice"); bad++; }
    for (int i = 0; i < 3; i++) send(sv[1], "x", 1, 0);
    if (epoll_wait(ep, out, 2, 0) != 0) { puts("parked socket still wakes epoll"); bad++; }
    uev_unpark(ep, sv[0]);
    if (g_uev_parked) { puts("not unparked"); bad++; }
    if (g_uev_unpark_dropped != 3) { printf("dropped %lu, want 3\n", g_uev_unpark_dropped); bad++; }
    if (epoll_wait(ep, out, 2, 0) != 0) { puts("stale events left after unpark"); bad++; }
    send(sv[1], "y", 1, 0);
    if (epoll_wait(ep, out, 2, 0) != 1) { puts("unparked socket does not wake epoll"); bad++; }
    return bad;
}
EOF
} > "$TMP/t.c"
"$CC_BIN" -O2 -Wall -Werror -Wno-unused-function -Wno-unused-variable -o "$TMP/t" "$TMP/t.c" 2> "$TMP/err" || { cat "$TMP/err"; fail "fixture did not compile"; }
"$TMP/t" || fail "park/unpark fixture failed"
echo "PASS uevent parking contract"
