#!/usr/bin/env bash
# Screen-off "real work" must mean the CPU was actually awake, not just a high loadavg.
#
# loadavg on these kernels counts uninterruptible waiters and is frozen across suspend: a
# OnePlus 15 night read load1 40-112 while suspended 96% of the time, held LIGHT_IDLE for
# hours, cut the deep-idle share the environment classifier reads (env=noisy all night)
# and kept the screen-off prime gate shut. The gate is the monotonic/boottime ratio per
# tick, which no idle waiter can fake and which reads the same on every SoC.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"; F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL screen-off awake gate: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$M" 'int     awake_tick_pct;' 'cpu metrics lack the awake share'
need "$M" 'clock_gettime(CLOCK_MONOTONIC, &_ts)' 'awake share not measured from CLOCK_MONOTONIC'
need "$M" 'clock_gettime(CLOCK_BOOTTIME, &_ts)' 'awake share not measured against CLOCK_BOOTTIME'
need "$M" 'if (_db >= 1000)' 'sub-second gaps are not ignored'
need "$F" 'int _awake_ok = (m->cpu.awake_tick_pct < 0 || m->cpu.awake_tick_pct >= 50);' 'busy rule not gated on awake share'
need "$F" 'if (m->cpu.load1 >= 8.0f && _awake_ok) {' 'busy streak still counts a sleeping CPU'
need "$F" '(m->cpu.awake_tick_pct >= 0 && m->cpu.awake_tick_pct < 50)) &&' 'screen-off prime gate ignores suspend'
need "$G" 'awake_tick_pct=%d' 'awake share not published'
# Three-tick streak and the load threshold itself are unchanged: the screen-off BT playback
# case this rule was built for (load1 13-19, CPU awake 99.8%) must still promote.
need "$F" 'int _off_busy = (_off_busy_streak >= 3);' 'streak requirement changed'
echo "PASS screen-off awake gate contract"
