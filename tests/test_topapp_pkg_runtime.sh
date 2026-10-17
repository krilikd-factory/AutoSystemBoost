#!/bin/sh
# Runtime (fix124): the foreground package comes from the top-app cgroup, not from
# `dumpsys activity top` - which makes the app dump its view hierarchy on its UI thread
# every time it is asked (a field OP15: 129 times in 64 minutes of screen-on).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
S="$ROOT/src/asb_smart.h"
fail() { echo "FAIL topapp pkg: $*" >&2; exit 1; }

# No live call to `dumpsys activity top` anywhere in the native code.
awk '/^#if 0$/{skip=1} /^#endif$/{skip=0; next} !skip' "$S" | grep -q 'popen(".*dumpsys activity top' \
  && fail "dumpsys activity top is still called"
grep -q 'popen(".*dumpsys activity top\|system(".*dumpsys activity top' "$ROOT/src/asb_governor.c" && fail "governor calls dumpsys activity top"
grep -q 'int _topapp = asb_smart_pkg_via_topapp(pkg, sizeof(pkg));' "$S" || fail "top-app cgroup not asked first"
grep -q 'probe_topapp=%lu' "$ROOT/src/asb_governor.c" || fail "top-app answers not published"

CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS topapp pkg (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
proc() {   # pid uid adj cmdline
  mkdir -p "$T/proc/$1"
  printf 'Name:\tx\nUmask:\t0077\nState:\tS\nTgid:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$1" "$2" "$2" "$2" "$2" > "$T/proc/$1/status"
  echo "$3" > "$T/proc/$1/oom_score_adj"
  printf '%s\0' "$4" > "$T/proc/$1/cmdline"
}
proc 1000  1000  -900 system_server                       # system threads in top-app
proc 2001  10234 0    com.instagram.android
proc 2002  10234 0    com.instagram.android:videoplayer
proc 2003  99123 0    com.google.android.webview:sandboxed_process0
proc 2004  10150 100  com.google.android.inputmethod.latin
proc 2005  10300 0    com.netflix.mediaclient
proc 3001  1010234 0  com.whatsapp                        # work profile (user 10)
{
  cat <<X
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#define ASB_PROC_ROOT "$T/proc"
#define ASB_TOPAPP_PROCS_A "$T/cpuset.procs"
#define ASB_TOPAPP_PROCS_B "$T/cpuctl.procs"
static inline void asb_copy_str(char *dst, const char *src, size_t n) {
    if (!dst || n == 0) return;
    if (!src) { dst[0] = 0; return; }
    size_t i = 0;
    for (; i + 1 < n && src[i]; i++) dst[i] = src[i];
    dst[i] = 0;
}
X
  awk '/^#ifndef ASB_PROC_ROOT/{on=1} on&&/^static int asb_smart_pkg_via_topapp/{f=1} on{print} f&&/^}$/{exit}' "$S"
  cat <<'X'
int main(int argc, char **argv) {
    (void)argc;
    char pkg[128];
    int r = asb_smart_pkg_via_topapp(pkg, sizeof(pkg));
    printf("%s|%s|%lu\n", r ? "1" : "0", r ? pkg : "-", g_stat_probe_topapp);
    return 0;
    (void)argv;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -Wno-unused-function -o "$T/t" "$T/t.c" || fail "fixture did not compile"
run() { "$T/t"; }

# Instagram in front, its second process, a system_server thread, an isolated renderer and a
# visible keyboard in the cgroup: Instagram.
printf '1000\n2001\n2002\n2003\n2004\n' > "$T/cpuset.procs"
[ "$(run | cut -d'|' -f1-2)" = "1|com.instagram.android" ] || fail "front app not found: $(run)"
# Split screen - two packages at adj 0: not answered here (the dumpsys chain decides).
printf '2001\n2005\n' > "$T/cpuset.procs"
[ "$(run | cut -d'|' -f1)" = 0 ] || fail "split screen answered with a guess: $(run)"
# cpuset unreadable: the cpuctl group answers.
rm -f "$T/cpuset.procs"; printf '1000\n2005\n' > "$T/cpuctl.procs"
[ "$(run | cut -d'|' -f1-2)" = "1|com.netflix.mediaclient" ] || fail "cpuctl fallback failed: $(run)"
# A work-profile app (uid 10xxxxx) counts.
printf '3001\n' > "$T/cpuctl.procs"
[ "$(run | cut -d'|' -f1-2)" = "1|com.whatsapp" ] || fail "secondary-user app rejected: $(run)"
# Only system processes in front (keyguard on some ROMs): nothing.
printf '1000\n' > "$T/cpuctl.procs"
[ "$(run | cut -d'|' -f1)" = 0 ] || fail "system process taken for the front app: $(run)"
# A vanished pid is skipped.
printf '4242\n2005\n' > "$T/cpuctl.procs"
[ "$(run | cut -d'|' -f1-2)" = "1|com.netflix.mediaclient" ] || fail "a vanished pid broke the lookup: $(run)"
echo "PASS foreground app from the top-app cgroup (no dumpsys activity top)"
