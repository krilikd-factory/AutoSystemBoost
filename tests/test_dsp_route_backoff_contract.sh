#!/bin/sh
# Contract: the DSP route watcher does not dump the audio service on a fixed 5 s clock.
#
# With a dsp_outputs filter set it ran `dumpsys audio` every 5 s of screen-on time - about
# 720 framework dumps an hour, nearly all returning the same route. It now backs off to
# 30 s (15 s while playing) and is pulled forward by the kernel's PCM state, which costs
# a file read instead of a binder walk.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/service.sh"
fail=0; f() { echo "FAIL dsp route backoff: $*" >&2; fail=1; }
blk="$(sed -n '/_prev_route=""/,/persist.asb.dsp.route "\$_now"/p' "$S")"
[ -n "$blk" ] || { echo "FAIL dsp route backoff: watcher block not found" >&2; exit 1; }
printf '%s\n' "$blk" | grep -q 'grep -l RUNNING /proc/asound/card\*/pcm\*p/sub\*/status' || f "no PCM-state pull-forward"
printf '%s\n' "$blk" | grep -q '\[ "$_since" -lt "${_iv:-5}" \]' || f "dump not gated by the interval"
printf '%s\n' "$blk" | grep -q '_ivmax=30; \[ "$_play_now" = 1 \] && _ivmax=15' || f "back-off ceilings changed"
# The dump must come after the gate, never straight after a fixed sleep.
printf '%s\n' "$blk" | awk '/sleep 5$/ { s = NR } /_adump="\$\(dumpsys audio/ { if (s && NR - s < 3) bad = 1 } END { exit bad }' \
  || f "dumpsys audio directly after a fixed sleep"
[ "$fail" = 0 ] && echo "PASS dsp route backoff contract"
exit "$fail"
