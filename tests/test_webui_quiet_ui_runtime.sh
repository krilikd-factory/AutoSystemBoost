#!/bin/sh
# Runtime (fix145): the WebUI keeps still and quiet where it should.
#
# 1. Interface sounds: a switch, and no cue while another app plays. A CPH2691 user heard his
#    Bluetooth music dip in loudness and bass for about a second on opening the Audio
#    category - the length of the WebView stream each cue opens. The REAL sound block runs
#    on a fake AudioContext, a fake clock and a fake run(): dumpsys says another player has
#    started -> no cue; switched off -> no cue; the look is never taken while this page's
#    own stream could be the player counted.
# 2. Settings entrance: "the six category cards twitch every time I open Settings". The hub
#    was painted, slid in, and painted again with the loaded values - with the entrance
#    animation both times. Pinned: the entrance runs on a change of screen only, the slide-in
#    paint does not run it, and a same-screen repaint during an entrance waits for it.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/webroot/index.html"
fail() { echo "FAIL webui quiet ui: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui quiet ui: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_s="$(grep -n '^let _uiAudioCtx = null;$' "$W" | head -1 | cut -d: -f1)"
_e="$(grep -n '^  } catch (e) { /\* no WebAudio: stay silent \*/ }' "$W" | head -1 | cut -d: -f1)"
[ -n "$_s" ] && [ -n "$_e" ] || fail "sound block not found"
{ sed -n "${_s},${_e}p" "$W"; echo "}"; } > "$T/s.js"
sed -n '/^const UI_SONIC = {/,/^};/p' "$W" > "$T/u.js"
cat > "$T/run.js" <<'X'
const fs = require('fs');
let now = 0; const timers = [];
global.setTimeout = (fn, ms) => { const t = { at: now + ms / 1000, fn, live: true }; timers.push(t); return t; };
global.clearTimeout = (t) => { if (t) t.live = false; };
function advance(s) {
  const end = now + s;
  for (;;) {
    const due = timers.filter(t => t.live && t.at <= end).sort((a, b) => a.at - b.at)[0];
    if (!due) break;
    now = due.at; due.live = false; due.fn();
  }
  now = end;
}
global.performance = { now: () => now * 1000 };
const store = {};
global.localStorage = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } };
global.document = { hidden: false, addEventListener: () => {} };
let oscs = 0;
class FakeCtx {
  constructor() { this.state = 'running'; this.destination = {}; }
  get currentTime() { return now; }
  suspend() { this.state = 'suspended'; }
  resume() { this.state = 'running'; }
  createOscillator() { oscs++; return { frequency: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {}, start() {}, stop() {} }; }
  createGain() { return { gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {} }; }
}
global.window = { AudioContext: FakeCtx };
let playing = '0', looks = [];
global.run = (cmd) => { looks.push(cmd); return Promise.resolve({ stdout: playing + '\n' }); };
global._el = () => null; global.T = (k, d) => d; global.toast = () => {};
eval(fs.readFileSync(process.argv[2], 'utf8') + fs.readFileSync(process.argv[3], 'utf8') + `
(async () => {
  const flush = () => new Promise(r => setImmediate(r));
  const out = [];
  advance(2); await flush();                                    // the look taken at page open completes
  advance(18);
  uiSound('nav'); await flush();
  out.push('first=' + oscs + '/' + looks.length);           // looked at open (nothing playing) and again at the cue 15 s+ later
  advance(30);                                                  // own context suspended, cue long ago
  playing = '1';
  uiSound('nav'); await flush();
  const afterLook = oscs;
  out.push('lookedWhilePlaying=' + looks.length);
  uiSound('nav');
  out.push('mutedWhilePlaying=' + (oscs === afterLook));
  advance(20); playing = '0';
  uiSound('nav'); await flush();
  uiSound('nav');
  out.push('backAfterStop=' + (oscs > afterLook));
  // Never look while this page's own stream is the likely player.
  const n = looks.length; _uiOtherAudioAt = -1e9; uiSound('nav');
  out.push('noLookRightAfterOwnCue=' + (looks.length === n));
  // Switched off: nothing plays, the choice is stored.
  advance(30); _uiOtherAudio = false; const o = oscs;
  uiSoundToggle(); uiSound('nav');
  out.push('off=' + (oscs === o) + '/' + store.asb_ui_sound);
  uiSoundToggle();
  out.push('on=' + (oscs > o) + '/' + store.asb_ui_sound);
  out.push('cmd=' + /dumpsys audio .*state:started .*USAGE_\\(MEDIA\\|GAME/.test(looks[0]) );
  console.log(out.join(' '));
})();
`);
X
r="$(node "$T/run.js" "$T/u.js" "$T/s.js")"
printf '%s\n' "$r" | grep -q 'first=4/2' || fail "first cue: $r"
printf '%s\n' "$r" | grep -q 'lookedWhilePlaying=3' || fail "no second look after 15 s: $r"
printf '%s\n' "$r" | grep -q 'mutedWhilePlaying=true' || fail "a cue played over another app's audio: $r"
printf '%s\n' "$r" | grep -q 'backAfterStop=true' || fail "cues did not come back once playback stopped: $r"
printf '%s\n' "$r" | grep -q 'noLookRightAfterOwnCue=true' || fail "looked while its own stream could be counted: $r"
printf '%s\n' "$r" | grep -q 'off=true/0' || fail "switch off did not silence or was not stored: $r"
printf '%s\n' "$r" | grep -q 'on=true/1' || fail "switch on: $r"
grep -q 'id="cfgSoundBtn" onclick="uiSoundToggle()"' "$W" || fail "no sound switch in the settings tools row"
for f in "$ROOT"/webroot/i18n/*.json; do
  for k in ui_sound_aria ui_sound_on ui_sound_off; do grep -q "\"$k\":" "$f" || fail "$k missing in ${f##*/}"; done
done

# 2. Entrance motion only on a change of screen.
grep -q "if (_screen !== _cfgShownScreen) {" "$W" || fail "entrance not tied to a change of screen"
grep -q "^  _cfgShownScreen = 'hub';" "$W" || fail "the slide-in paint runs the entrance as well"
grep -q "(_cfgGroup || 'hub') === _cfgShownScreen && performance.now() < _cfgEnterUntil" "$W" \
  || fail "a repaint during the entrance restarts it"
_n="$(grep -c "list.classList.add('cfg-stagger');" "$W")"
[ "$_n" = 1 ] || fail "cfg-stagger added in $_n places (want exactly the screen-change one)"
echo "PASS webui quiet ui: cues switchable and quiet over other audio, entrance only on a change of screen"
