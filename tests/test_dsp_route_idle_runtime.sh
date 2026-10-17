#!/usr/bin/env bash
# Runtime (fix137): with nothing playing, the DSP route watcher takes ONE look at the route a
# minute into the idle stretch, so a route published while the headphones were on does not
# outlive them.
#
# OP15 capture 2830: route_published=bt from 22:46 to 08:00 while the audio service had gone
# back to the speaker (play=0 route=speaker in every hourly audio snapshot), and with
# dsp_outputs=bt the attach daemon held the effect all night ("effect_live found=1").
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SVC="$ROOT/service.sh"
fail() { echo "FAIL dsp route idle: $*" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sed -n '/^  _idle_at=""; _idle_looked=""; _force=""$/,/^  while true; do$/p' "$SVC" | sed '$d' > "$TMP/idle.sh"
grep -q '_idle_due()' "$TMP/idle.sh" || fail "idle helpers not found in service.sh"
# shellcheck disable=SC1090
. "$TMP/idle.sh"
_pcm_known=1

SECONDS=1000
_idle_track ""                         # playback just stopped
_idle_due && fail "looked before a minute had passed"
SECONDS=1059; _idle_due && fail "looked at 59 s"
SECONDS=1061; _idle_due || fail "no look a minute into the idle stretch"
SECONDS=1200; _idle_track ""; _idle_due && fail "looked twice in one idle stretch"
_idle_track "/proc/asound/card0/pcm0p/sub0/status"   # a stream plays again
SECONDS=2000; _idle_track ""; SECONDS=2061
_idle_due || fail "a new idle stretch did not get its own look"
# Where the kernel does not expose PCM state, idle cannot be told from playing: never look.
_pcm_known=""; _idle_track "x"; SECONDS=3000; _idle_track ""; SECONDS=3100
_idle_due && fail "looked without PCM state (idle and playing look the same there)"

# Wiring: both the screen-off and the screen-on path use it, and a forced pass dumps.
grep -q '_idle_due && _force=1 || continue' "$SVC" || fail "screen-off path never looks"
grep -q '      _idle_due || continue' "$SVC" || fail "screen-on path never looks"
grep -q 'elif \[ -n "\$_force" \]; then' "$SVC" || fail "a forced look does not reach the dump"
[ "$(grep -c '_idle_track "\$_sig' "$SVC")" -ge 2 ] || fail "idle stretch not tracked on both paths"
echo "PASS dsp route idle: one route look a minute into every idle stretch, none without PCM state"
