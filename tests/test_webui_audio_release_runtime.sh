#!/bin/sh
# Runtime (fix130): the WebUI lets go of the audio output between sounds.
#
# The UI sounds shared one AudioContext that, once created, stayed running for the life of
# the page - an open output stream rendering silence while someone read the Monitor. An
# OP15 capture found AudioMix held for the root manager's WebView. The REAL sound block is
# cut out of index.html and run on a fake AudioContext and a fake clock: suspended 1.5 s
# after the last note, not before; a long sound (the saucer) holds it; a hidden page lets go
# at once; the next tap resumes.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/webroot/index.html"
fail() { echo "FAIL webui audio release: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui audio release: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_s="$(grep -n '^let _uiAudioCtx = null;$' "$W" | head -1 | cut -d: -f1)"
_e="$(grep -n '^  } catch (e) { /\* no WebAudio: stay silent \*/ }' "$W" | head -1 | cut -d: -f1)"
[ -n "$_s" ] && [ -n "$_e" ] || fail "sound block not found"
{ sed -n "${_s},${_e}p" "$W"; echo "}"; } > "$T/s.js"
grep -q 'uiAudioRelease(ctx, now + DUR + 1)' "$W" || fail "the saucer does not hold the context"
sed -n '/^const UI_SONIC = {/,/^};/p' "$W" > "$T/u.js"
[ -s "$T/u.js" ] || fail "UI_SONIC not found"
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
const listeners = {};
global.document = { hidden: false, addEventListener: (k, f) => { listeners[k] = f; } };
let suspends = 0, resumes = 0;
class FakeCtx {
  constructor() { this.state = 'running'; this.destination = {}; }
  get currentTime() { return now; }
  suspend() { this.state = 'suspended'; suspends++; }
  resume() { this.state = 'running'; resumes++; }
  createOscillator() { return { frequency: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {}, start() {}, stop() {} }; }
  createGain() { return { gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {} }; }
}
global.window = { AudioContext: FakeCtx };
eval(fs.readFileSync(process.argv[2], 'utf8') + fs.readFileSync(process.argv[3], 'utf8') +
  `
  const out = [];
  uiSound('nav');
  advance(1.0); out.push('t1=' + suspends);
  advance(1.0); out.push('t2=' + suspends);
  uiSound('success'); out.push('resumed=' + resumes);
  uiAudioRelease(_uiAudioCtx, now + 11);
  uiSound('nav');
  advance(5); out.push('t3=' + suspends);
  advance(8); out.push('t4=' + suspends);
  uiSound('nav'); document.hidden = true; listeners.visibilitychange(); out.push('hidden=' + _uiAudioCtx.state);
  console.log(out.join(' '));
`);
X
r="$(node "$T/run.js" "$T/u.js" "$T/s.js")"
[ "$r" = "t1=0 t2=1 resumed=1 t3=1 t4=2 hidden=suspended" ] || fail "release timing wrong: $r"
echo "PASS webui audio release: suspended 1.5 s after the last sound, held for long sounds, released when hidden"
