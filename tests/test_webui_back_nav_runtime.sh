#!/bin/sh
# Runtime (fix159): the back gesture steps back inside the WebUI and leaves it only from Home;
# the Monitor's Smart card shows the drain with the screen on and off and opens a sheet with
# what each figure is based on.
#
# Asked for: from a category, a popup or any page but Home, back should go back inside the
# WebUI (as other modules do); only back on Home leaves. A root manager's WebView goes back
# through the page's history before it closes, so the page keeps one history entry per open
# level. The REAL navigation code runs in node against a history that behaves like a WebView's
# (pushState, go(-n) answered by an asynchronous popstate, nothing left = the manager closes the
# page), and the REAL drain sheet painter is run with the Smart card's figures.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui back nav: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui back nav: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
[ "$(grep -c "addEventListener('popstate'" "$H")" = 1 ] || fail "more than one popstate handler - two would both act on one back"
grep -q 'if (typeof navSyncSoon === .function.) navSyncSoon();' "$H" || fail "category changes do not resync the history"
for id in bnDrainStrip bnDrainOff bnSlotTemp bnDrain; do grep -q "id=\"$id\"" "$H" || fail "Smart card lacks #$id"; done
grep -q 'onclick="liveDrainOpen()"' "$H" || fail "the drain strip does not open the sheet"
for l in en ru uk de es fr it pt tr id ar hy zh; do
  J="$ROOT/webroot/i18n/$l.json"
  for k in lv_slot_heat lv_heat_cool lv_heat_norm lv_heat_warm lv_heat_tip lv_drain_on_meter lv_drain_cmp lv_scr_on lv_scr_off lv_drain_title lv_drain_on_now lv_drain_on_recent lv_drain_on_slot lv_drain_on_wait lv_drain_off_measured lv_drain_off_wait lv_drain_left lv_drain_note; do
    grep -q "\"$k\"" "$J" || fail "$l.json lacks $k"
  done
  for k in lv_drain_on_now lv_drain_off_measured lv_drain_left; do
    grep -q "\"$k\": \"[^\"]*%s" "$J" || fail "$l.json $k has no place for its number"
  done
done
{
  sed -n '/^const NAV_OVERLAYS = \[/,/^})();$/p' "$H"
  cat <<'EOF'
;
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
async function tick() { for (let i = 0; i < 6; i++) await new Promise(function (r) { setImmediate(r); }); }
async function back() { if (!hist.canGoBack()) { exited++; return; } hist.go(-1); await tick(); }
(async function () {
  chk(_nav.depth === 0 && hist.idx === 0, 'start: ' + _nav.depth + '/' + hist.idx);
  _liveOpen = true; navSync();
  chk(hist.idx === 1, 'Monitor opened: one history entry, have ' + hist.idx);
  _el('liveDrainSheet').hidden = false; navSync();
  chk(hist.idx === 2, 'drain sheet opened: two entries, have ' + hist.idx);
  await back();
  chk(_el('liveDrainSheet').hidden === true && _liveOpen === true, 'back closed the sheet and kept Monitor');
  await back();
  chk(_liveOpen === false && hist.idx === 0 && exited === 0, 'back from Monitor went Home, not out: live=' + _liveOpen + ' idx=' + hist.idx);
  await back();
  chk(exited === 1, 'back on Home leaves the WebUI');

  exited = 0;
  _cfgOpen = true; navSync(); _cfgGroup = 'battery'; navSync(); _el('dozeKeepModal').hidden = false; navSync();
  chk(hist.idx === 3, 'Settings > Battery > picker: three entries, have ' + hist.idx);
  await back();
  chk(_el('dozeKeepModal').hidden && _cfgGroup === 'battery' && _cfgOpen, 'back closed the picker only');
  await back();
  chk(_cfgGroup === null && _cfgOpen, 'back left the category for the Settings hub');
  await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'back from the hub went Home');

  _cfgOpen = true; _cfgGroup = 'audio'; navSync();
  chk(hist.idx === 2, 'category opened: two entries, have ' + hist.idx);
  _cfgGroup = null; navSync(); await tick();
  chk(hist.idx === 1 && _cfgOpen && !_nav.pending, 'category closed by a tap: history stepped back once without acting, idx=' + hist.idx);
  await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'next back went Home after a tap-close');

  _liveOpen = true; navSync(); _liveOpen = false; _cfgOpen = true; navSync(); await tick();
  chk(hist.idx === 1, 'switching tabs Monitor -> Settings keeps one entry, have ' + hist.idx);
  _el('logMenu').hidden = false; _el('cfgFm').hidden = false; navSync();
  chk(hist.idx === 3, 'two overlays over Settings: three entries, have ' + hist.idx);
  await back();
  chk(_el('logMenu').hidden && !_el('cfgFm').hidden, 'back closes one overlay at a time');
  await back(); await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'everything closed, Home reached, nothing left the WebUI');
  await back();
  chk(exited === 1, 'and only now does back leave');

  _lvDrain.on = 'recent'; _lvDrain.off = 'measured'; _lvDrain.offN = 3; _lvDrain.winS = 0;
  _el('bnDrain').textContent = '~8.5%/h'; _el('bnDrainOff').textContent = '0.52%/h';
  _el('liveEtaOn').textContent = '8h 56m'; _el('liveEtaOff').textContent = '> 72h';
  liveDrainPaint();
  const blocks = _el('liveDrainBody').children;
  chk(blocks.length === 3, 'sheet: two figures and a note, have ' + blocks.length);
  const txt = function (b) { return b.children[1].children.map(function (c) { return c.className + '=' + c.textContent; }).join(' | '); };
  const on = txt(blocks[0]), off = txt(blocks[1]);
  chk(/live-drain-val=~8\.5%\/h/.test(on) && /lv_drain_on_recent/.test(on) && /to 0%: 8h 56m/.test(on), 'screen-on block: ' + on);
  chk(/live-drain-val=0\.52%\/h/.test(off) && /stretch\(es\)/.test(off) && / 3 /.test(off) && /to 0%: > 72h/.test(off), 'screen-off block: ' + off);
  _lvDrain.on = 'charging'; _lvDrain.off = 'wait'; liveDrainPaint();
  const on2 = txt(_el('liveDrainBody').children[0]), off2 = txt(_el('liveDrainBody').children[1]);
  chk(!/to 0%/.test(on2), 'no time-to-empty while charging: ' + on2);
  chk(/lv_drain_off_wait/.test(off2), 'screen-off waits for an hour of screen off: ' + off2);
  if (bad) process.exit(1);
  console.log('ok');
})();
EOF
} > "$T/body.js"
cat > "$T/run.js" <<'EOF'
const fs = require('fs');
const els = {};
function mk(tag) {
  const e = { tagName: tag, id: '', hidden: true, className: '', innerHTML: '', children: [], attrs: {}, _t: '',
    setAttribute: function (k, v) { this.attrs[k] = v; }, addEventListener: function () {},
    appendChild: function (c) { this.children.push(c); if (c.id) els[c.id] = c; return c; } };
  Object.defineProperty(e, 'textContent', { get: function () { return this._t; }, set: function (v) { this._t = String(v); this.children = []; } });
  return e;
}
['logMenu', 'liveDrainSheet', 'cfgFm', 'dozeKeepModal', 'cfgResetModal', 'cfgProfileModal', 'bnDrain', 'bnDrainOff', 'liveEtaOn', 'liveEtaOff',
 'liveDrainBody', 'liveDrainTitle', 'liveDrainDone'].forEach(function (id) { const e = mk('div'); e.id = id; els[id] = e; });
['bnDrain', 'bnDrainOff', 'liveEtaOn', 'liveEtaOff', 'liveDrainBody', 'liveDrainTitle', 'liveDrainDone'].forEach(function (id) { els[id].hidden = false; });
const listeners = {};
const hist = { stack: [{ state: null }], idx: 0,
  pushState: function (s) { this.stack = this.stack.slice(0, this.idx + 1); this.stack.push({ state: s }); this.idx++; },
  canGoBack: function () { return this.idx > 0; },
  go: function (n) { const self = this; setImmediate(function () { self.idx = Math.max(0, self.idx + n); (listeners.popstate || []).forEach(function (f) { f({ state: self.stack[self.idx].state }); }); }); } };
global.hist = hist; global.exited = 0;
global.window = { history: hist, addEventListener: function (t, f) { (listeners[t] = listeners[t] || []).push(f); } };
global.history = hist;
global.document = { body: mk('body'), createElement: mk, addEventListener: function () {} };
global.MutationObserver = function () { this.observe = function () {}; };
global._el = function (id) { return els[id] || null; };
global.T = function (k, d) { return d; };
global.techIcon = function (k) { return '<svg data-k="' + k + '"></svg>'; };
global.uiSound = function () {};
global._liveOpen = false; global._cfgOpen = false; global._cfgGroup = null;
global.closeLivePage = function () { _liveOpen = false; };
global.closeConfigPage = function () { _cfgOpen = false; _cfgGroup = null; };
global.cfgBack = function () { _cfgGroup = null; };
global.asbCloseLogMenu = function () { els.logMenu.hidden = true; };
global.cfgFmClose = function () { els.cfgFm.hidden = true; };
global.dozeKeepClose = function () { els.dozeKeepModal.hidden = true; };
global.cfgResetDialogClose = function () { els.cfgResetModal.hidden = true; };
global.cfgProfileClose = function () { els.cfgProfileModal.hidden = true; };
const src = fs.readFileSync(process.argv[2], 'utf8')
  .replace('const _nav =', 'var _nav =').replace('const _lvDrain =', 'var _lvDrain =')
  .replace(/T\('lv_drain_on_recent', '[^']*'\)/, "'lv_drain_on_recent'").replace(/T\('lv_drain_off_wait', '[^']*'\)/, "'lv_drain_off_wait'");
(0, eval)(src);
EOF
out="$(node "$T/run.js" "$T/body.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui back nav: back closes the top popup, then the category, then the page; only Home lets the WebUI close; the drain sheet shows both figures with their basis"
