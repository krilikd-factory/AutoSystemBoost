#!/usr/bin/env bash
# Foreground uclamp had no owner while the governor ran (reconcile skips per-cgroup checks
# then, the writer manages only top/bg/sybg), so a ROM "max" stayed for whole screen-on
# sessions. The guard's limits are what keep it from fighting vendor launch boosts.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"; G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL fg uclamp guard contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$W" 'static void writer_fg_guard(int screen_on)' 'guard missing'
need "$W" 'if (!screen_on || g_cam_guard_on) { g_fg_max_since = 0; return; }' 'acts with screen off or during camera guard'
need "$W" 'if (cur < 100) { g_fg_last_good = cur; g_fg_max_since = 0; return; }' 'corrects values other than max'
need "$W" 'if (now - g_fg_max_since < 60) return;' 'no 60 s persistence before acting'
need "$W" 'g_fg_backoff_until = now + 600' 'no stand-down when something keeps reasserting'
need "$G" 'writer_fg_guard(metrics.misc.screen_on);' 'guard not called from the governor loop'
need "$G" 'fg_guard_fixes=%lu' 'corrections not published'
echo "PASS fg uclamp guard contract"
