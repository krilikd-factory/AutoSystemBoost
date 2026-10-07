#!/usr/bin/env bash
# Measured screen-off drain replaces the idle guess in every forecast.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; A="$ROOT/action.sh"; W="$ROOT/webroot/index.html"; D="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL offdrain contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$G" 'if (charging) { g_offdrain_start_ms = 0; g_offdrain_on_ms = 0; return; }' 'charging window not discarded'
need "$G" 'if (dur >= 3600000L && dpct >= 2) {' 'short or rounding-only windows can count'
need "$G" 'now - g_offdrain_on_ms >= 120000L' 'a glance at the clock splits the night'
need "$G" 'long now = asb_clock_ms(CLOCK_BOOTTIME);' 'window not timed on a suspend-aware clock'
need "$G" 'offdrain_pctph_x100=%d\noffdrain_windows=%d' 'not published'
[ "$(grep -c 'asb_offdrain_track(metrics.misc.screen_on' "$G")" -ge 2 ] || fail 'not called on both tick paths'
need "$A" "grep -m1 '^offdrain_pctph_x100=' /dev/.asb/state" 'action ignores the measured idle drain'
need "$W" 'kv.offdrain_pctph_x100' 'WebUI ignores the measured idle drain'
need "$D" "^offdrain_pctph_x100=" 'diag does not report it'
echo "PASS offdrain contract"
