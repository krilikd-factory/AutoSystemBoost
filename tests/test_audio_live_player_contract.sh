#!/bin/sh
# Contract + fixture: "something is playing" means a live AudioPlaybackConfiguration line.
# History lines and idle players must not count (external audit fix44, P2).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; f() { echo "FAIL audio live player: $*" >&2; fail=1; }
RX='AudioPlaybackConfiguration .*state:started'
live='  AudioPlaybackConfiguration piid:79 deviceIds:[2] type:android.media.MediaPlayer u/pid:10652/9876 state:started attr:AudioAttributes: usage=USAGE_MEDIA'
idle='  AudioPlaybackConfiguration piid:80 deviceIds:[] type:AAudio u/pid:10658/1234 state:paused attr:AudioAttributes: usage=USAGE_MEDIA'
hist='  10-07 12:01:02:123 player piid:63 state:started'
hist2='  10-07 12:01:02:123 player piid:63 event:started'
printf '%s\n' "$live" | grep -qE "$RX" || f "live player not recognised"
printf '%s\n%s\n%s\n' "$idle" "$hist" "$hist2" | grep -qE "$RX" && f "idle player or history counted as playing"
for file in runtime/asb_screenoff_class.sh service.sh tools/asb_diag.sh tools/logkit/_asb_logkit_common.sh tools/logkit/asb_audio_ab.sh; do
  grep -q "AudioPlaybackConfiguration .\*state:started" "$ROOT/$file" || f "$file does not use the live-player pattern"
  grep -vE '^[[:space:]]*#' "$ROOT/$file" | grep -qE "player piid\.\*started|grep -q[a-zA-Z]* '?\"?state:started|\*state:started\*" && f "$file still matches history lines"
done
[ "$fail" = 0 ] && echo "PASS audio live player"
exit "$fail"
