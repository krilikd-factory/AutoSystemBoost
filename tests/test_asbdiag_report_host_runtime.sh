#!/bin/sh
# Runtime (fix151): asbdiag says which janky frames are its own output scrolling.
#
# A CPH2691 report run from Termux: "com.termux 663 of 676 frames (20.72/s)" and "steady:
# com.termux missed 663 of the 676 frames ... while you only waited for this report". An
# outside audit read that as "over 90% UI lag in Termux, up to 20 a second" and proposed CPU
# boosts and big-core whitelists for it. Termux was drawing the report. The REAL functions
# run on a fake /proc and cpuset: the app in front at the start is found from the top-app
# group (uid >= 10000, oom_score_adj 0), and its line says it is the report's own window.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL asbdiag report host: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^# asb_gfx_pkg_begin$/,/^# asb_gfx_pkg_end$/p' "$D" > "$T/f.sh"
grep -q '^asb_report_host() {' "$T/f.sh" || fail "no host lookup in the testable block"
mkdir -p "$T/cpuset/top-app"
mk() {   # pid uid oom cmdline
  mkdir -p "$T/proc/$1"
  printf 'Name:\tx\nUid:\t%s\t%s\t%s\t%s\n' "$2" "$2" "$2" "$2" > "$T/proc/$1/status"
  echo "$3" > "$T/proc/$1/oom_score_adj"
  printf '%s\000' "$4" > "$T/proc/$1/cmdline"
}
mk 100 1000 0 system_server
mk 200 10123 200 com.google.android.inputmethod.latin
mk 300 10234 0 /data/data/com.termux/files/usr/bin/bash
mk 400 10234 0 com.termux
printf '100\n200\n300\n400\n' > "$T/cpuset/top-app/cgroup.procs"
h="$(ASB_PROC_ROOT="$T/proc" ASB_CPUSET_ROOT="$T/cpuset" sh -c '. "$1"; asb_report_host' x "$T/f.sh")"
[ "$h" = com.termux ] || fail "host: '$h', want com.termux"
printf 'com.termux 1000 10\ncom.android.systemui 2000 20\n' > "$T/a"
printf 'com.termux 1676 673\ncom.android.systemui 3144 44\n' > "$T/b"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(cat "$2")" "$(cat "$3")" 32 com.termux' x "$T/f.sh" "$T/a" "$T/b")"
printf '%s\n' "$d" | grep -q 'com.termux 663 of 676 frames (20.72/s, the window this report is printed in)' || fail "per-app line: $d"
printf '%s\n' "$d" | grep -q '^host: com.termux missed 663 of the 676 frames it drew - the report scrolling in it, not a lag$' || fail "host line: $d"
printf '%s\n' "$d" | grep -q '^steady:' && fail "the report's own window called a steady redraw: $d"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(cat "$2")" "$(cat "$3")" 32 com.rifsxd.ksunext' x "$T/f.sh" "$T/a" "$T/b")"
printf '%s\n' "$d" | grep -q '^steady: com.termux missed 663' || fail "another app in front still gets the steady verdict: $d"
grep -q 'asb_gfx_run_delta "$_gfx_run0" "$_gfx_run1" "$(( $(date +%s) - ${_gfx_run0_t:-0} ))" "$_gfx_host"' "$D" || fail "7c does not pass the host"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS asbdiag report host: the window the report prints into is named, not read as lag"
