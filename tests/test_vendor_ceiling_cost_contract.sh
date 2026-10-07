#!/usr/bin/env bash
# A vendor-raised CPU ceiling is reported by what it COST, not merely that it happened.
# The old line said "leak_observed ... reconcile.sh handles" for every raise - untrue during
# sleep detente and useless: on a OnePlus 15 night the clock exceeded ASB's limit in 3 of
# 64 screen-off samples. Raised-but-unused and really-used are counted separately.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; A="$ROOT/action.sh"
fail() { echo "FAIL vendor ceiling cost contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$G" '(long)metrics.cpu.cur_freq[0] * 1000L > (long)want_p0 + 100000L' 'little clock not compared with the limit (MHz vs kHz)'
need "$G" 'if (used0 || used1) g_leak_used_ticks++;' 'really-used ticks not counted'
need "$G" 'vendor_ceiling_ticks=%lu\nvendor_ceiling_used_ticks=%lu' 'counters not published'
need "$G" 'int _lvl = (used0 || used1) ? 1 : 3;' 'unused raises still logged at the normal level'
grep -F 'asb_log(' "$G" | grep -Fq 'reconcile.sh handles' && fail 'misleading "reconcile.sh handles" text is back'
need "$A" '_vcu="$(_st vendor_ceiling_used_ticks)"' 'action does not report the cost'
echo "PASS vendor ceiling cost contract"
