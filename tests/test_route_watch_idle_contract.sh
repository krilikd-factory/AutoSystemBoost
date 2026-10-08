#!/bin/sh
# Contract: the DSP route watcher does not dump the audio service while nothing plays
# (kernel PCM state unchanged and empty) on kernels that expose PCM state; a stream opening
# still forces a dump at once, and kernels without PCM files keep the timed back-off.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/service.sh"
fail=0; f() { echo "FAIL route watch idle: $*" >&2; fail=1; }
blk="$(sed -n '/^# Keep persist.asb.dsp.route honest while the phone is running./,/^) >\/dev\/null 2>&1 &$/p' "$S")"
printf '%s\n' "$blk" | grep -q 'elif \[ -z "$_sig" \] && \[ -n "${_pcm_known:-}" \] && \[ -n "$_prev_route" \]; then' \
  || f "idle skip missing"
printf '%s\n' "$blk" | grep -q '_pcm_known=1' || f "PCM-state availability not detected"
# Order: a changed signature must be handled before the idle skip.
_a="$(printf '%s\n' "$blk" | grep -n 'if \[ "$_sig" != "${_prev_sig:-}" \]; then' | cut -d: -f1)"
_b="$(printf '%s\n' "$blk" | grep -n 'elif \[ -z "$_sig" \]' | cut -d: -f1)"
[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" -lt "$_b" ] || f "playback start no longer forces a dump first"
printf '%s\n' "$blk" | grep -q '\*bt_sco\*|\*BLUETOOTH_SCO\*) _now="call"' || f "SCO route lost"
[ "$fail" = 0 ] && echo "PASS route watch idle contract"
exit "$fail"
