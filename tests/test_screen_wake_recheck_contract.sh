#!/bin/sh
# Contract: a display event inside the 30 s follow-up budget still buys one quick look.
#
# Field captures (OP15, two days): 22 of 54 screen-ons were noticed only by the idle tick,
# each exactly 45 s after the previous tick, with deep-idle rails and frozen cap writes in
# the meantime - an unlock and camera launch ran on sleep rails. The budget that rations the
# ~2 s follow-up chain had been spent by an earlier display event, and inside it nothing was
# armed at all. Guard the single re-check, its spacing, and the counters that expose it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL screen wake recheck: $*" >&2; fail=1; }
need() { grep -Fq -- "$1" "$G" || f "$2"; }
need 'time(NULL) - g_disp_single_ts >= 10' 'single re-check is not spaced (AOD would buy a wakeup per event)'
need 'arm_timerfd_once_ms(tfd_active, 1000);' 'no single re-check inside the follow-up budget'
need 'g_disp_retry = 3;' 'single re-check can grow into a chain'
need 'screen_on_detect=' 'screen-on detection path not published'
need 'g_scr_on_by_tick++' 'slow-path wakes not counted'
need 'make_timerfd_clock(CLOCK_BOOTTIME, TIMER_IDLE_S)' 'screen-off tick still on CLOCK_MONOTONIC (stalls through suspend)'
need 'g_scr_resume_chains++' 'no re-check chain after a resume'
grep -Fq 'screen_on_detect=' "$ROOT/tools/asb_diag.sh" || f 'asbdiag does not show how wakes were noticed'
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f 'asbdiag copy out of date'
[ "$fail" = 0 ] && echo "PASS screen wake re-check contract"
exit "$fail"
