#!/bin/sh
# fix86: wake keys (power / KEY_WAKEUP) arm the screen-on re-check while the screen is off.
# OP15: a third of wakes had no display uevent and were found only by the 45 s idle tick.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL wake key hint: $*" >&2; exit 1; }
grep -Fq 'int ok = caps && !is_abs &&' "$G" || fail "touchscreens (EV_ABS) must not be admitted for power/wakeup alone"
# fix101: a touch panel is admitted only for its off-screen gesture keys (double-tap wake).
grep -Fq '(asb_bit_test(keyb, KEY_WAKEUP) || asb_bit_test(keyb, KEY_F4))' "$G" || fail "touch gesture keys not admitted"
grep -Fq 'else if (wake_key_is_fd(fd)) {' "$G" || fail "key fds not handled in the event loop"
grep -Fq 'wake_keys_park(epfd, 1);' "$G" || fail "keys not parked with the uevent socket while the screen is on"
grep -Fq 'wake_keys_park(epfd, 0);' "$G" || fail "keys not unparked at screen-off"
grep -q 'O_RDONLY | O_NONBLOCK | O_CLOEXEC' "$G" || fail "input devices must be opened read-only, non-blocking"
grep -q 'EVIOCGRAB' "$G" && fail "input devices must never be grabbed"
# fix87: every screen transition publishes the state file (shell helpers read screen= there)
[ "$(grep -c 'write_state(&fsm, &metrics, cur_pred);' "$G")" -ge 6 ] || fail "screen transitions do not publish the state file"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS wake key hint (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  printf '#include <stdio.h>\n#include <string.h>\n#include <unistd.h>\n#include <fcntl.h>\n#include <linux/input.h>\n'
  printf '#define ASB_WAKE_KEY_MAX 6\nstatic int g_wake_key_fd[ASB_WAKE_KEY_MAX], g_wake_key_touch[ASB_WAKE_KEY_MAX], g_wake_key_n = 0;\n'
  sed -n '/^static int wake_key_drain(int fd) {/,/^}$/p' "$G"
  cat <<'X'
static int feed_t(int code, int value, int type, int touch) {
    int p[2]; if (pipe(p)) return -1;
    fcntl(p[0], F_SETFL, O_NONBLOCK);
    g_wake_key_n = 1; g_wake_key_fd[0] = p[0]; g_wake_key_touch[0] = touch;
    struct input_event e[2]; memset(e, 0, sizeof(e));
    e[0].type = type; e[0].code = code; e[0].value = value;
    e[1].type = EV_SYN;
    if (write(p[1], e, sizeof(e)) != (ssize_t)sizeof(e)) return -1;
    close(p[1]);
    int r = wake_key_drain(p[0]); close(p[0]); return r;
}
static int feed(int code, int value, int type) { return feed_t(code, value, type, 0); }
int main(void) {
    int bad = 0;
    if (feed(KEY_POWER, 1, EV_KEY) != 1) { puts("power press"); bad = 1; }
    if (feed(KEY_WAKEUP, 1, EV_KEY) != 1) { puts("wakeup press"); bad = 1; }
    if (feed(KEY_POWER, 0, EV_KEY) != 0) { puts("release must not count"); bad = 1; }
    if (feed(KEY_VOLUMEUP, 1, EV_KEY) != 0) { puts("volume must not count"); bad = 1; }
    if (feed_t(KEY_F4, 1, EV_KEY, 1) != 1) { puts("touch gesture F4 must count"); bad = 1; }
    if (feed_t(KEY_F4, 1, EV_KEY, 0) != 0) { puts("F4 on a plain key device must not count"); bad = 1; }
    if (feed_t(BTN_TOUCH, 1, EV_KEY, 1) != 0) { puts("a touch press must not count"); bad = 1; }
    return bad;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -o "$T/t" "$T/t.c" || fail "fixture did not compile"
"$T/t" || fail "drain classification wrong"
echo "PASS wake keys arm the screen-on re-check"
