#!/usr/bin/env bash
# Thermal trend must not read a sleep gap or the unlock burst as a fast climb.
#
# The trend sums per-tick deltas, and ticks are 2-6 s on screen but 45 s or a whole
# suspend apart off screen. A OnePlus 15 day showed the first tick after unlock (40 -> 50 C)
# firing thermal_trend_fast - a 34% trim at the moment of interaction, "cool" 30 s later.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL thermal trend gap contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$F" 'clock_gettime(CLOCK_BOOTTIME, &_tts)' 'gap not measured on a suspend-aware clock'
need "$F" 'if (_tr_gap > 6) delta = (int)((long)delta * 6L / _tr_gap);' 'long-gap deltas are not scaled down'
need "$F" 'int _tr_wake = (m->misc.screen_on && _tr_prev_screen == 0);' 'screen-on edge not detected'
need "$F" 'fsm->warm_anchor_c = m->therm.cpu_max_c;' 'warm anchor not re-seeded on wake'
# Short ticks keep their tuning: the scale may only shrink a delta.
grep -Fq 'delta * 6L / _tr_gap' "$F" && ! grep -Eq 'delta \* _tr_gap' "$F" || fail 'deltas can be scaled up'
# The slow-climb rule itself is unchanged.
need "$F" 'if (m->therm.cpu_max_c >= 50 && _rise >= 6 && fsm->thermal_trend < 6)' 'slow-climb rule changed'
echo "PASS thermal trend gap contract"
