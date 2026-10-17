#!/bin/sh
# Runtime (fix162, reworked fix163): the Monitor card is symmetric, carries the time to empty
# beside each drain figure, and speaks the UI language.
#
# fix162 moved the "exact" chip off the card border into a title row; the owner found the card
# lopsided that way and the page half empty below the tiles, and asked for the screen-on and
# idle forecasts to sit with the two drain figures they belong to. fix163: a section title over
# the card (as on Home and Settings), two equal battery tiles - drain, then time to empty - and
# the eight Smart readings, the chip's meaning folded into a "Basis" reading; the live grid is
# three rows of three. The REAL page functions run in node.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor card: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui monitor card: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$H" <<'P' || fail "layout"
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
top = s.index('id="liveTopSecLabel"')
sb = s[s.index('id="liveSmartBanner"'):s.index('id="liveStockRomBanner"')]
st = s[s.index('id="liveStockRomBanner"'):s.index('data-i18n="sec_live"')]
assert top < s.index('id="liveSmartBanner"'), "no section title over the card"
for part, name in ((sb, "Smart"), (st, "ROM")):
    assert "smart-banner-head" not in part and "smart-banner-tag" not in part and "tags" not in part, "%s card still carries a title row or chips" % name
strip = sb[sb.index('id="bnDrainStrip"'):sb.index('<div class="smart-banner-row">')]
halves = strip.split('class="smart-drain-half"')[1:]
assert len(halves) == 2, "want two drain tiles, have %d" % len(halves)
for h, val, eta in zip(halves, ("bnDrain", "bnDrainOff"), ("liveEtaOn", "liveEtaOff")):
    assert 'onclick="liveDrainOpen()"' in h, "a drain tile does not open the sheet"
    assert h.index('id="%s"' % val) < h.index('id="%s"' % eta), "%s is not under %s" % (eta, val)
for k in ("lv_bucket", "lv_conf", "lv_alpha", "lv_app", "lv_basis", "lv_slot_heat", "lv_trend", "lv_lpm"):
    assert ('data-i18n="%s"' % k) in sb, "Smart reading %s missing or untranslated" % k
assert 'id="bnSes"' not in sb and 'id="bnBasis"' in sb, "Basis did not take the sessions slot"
g = s[s.index('<div class="live-metrics">'):s.index('<section class="stock-telemetry"')]
rows = g.count('<div class="live-row">')
cells = g.count('<div class="live-cell">')
assert rows == 3 and cells == 9 and "live-cell-wide" not in g, "live grid is %d rows / %d cells, want 3 x 3" % (rows, cells)
assert "fbTag" not in s and "T('lv_fb_' + fb," in s, "the slot source is still a chip"
assert "T('lv_mode_guard'," in s and "T('lv_mode_night'," in s, "night and thermal guard are not shown in Basis"
assert "T('lv_dp_' + dp, dpNames[dp])" in s and "T('lv_app_' + appH," in s, "day part or load class still English"
assert "+ '% bat'" not in s and "T('unit_d', 'd')" in s, "English units left"
assert "_el('liveLearner').textContent = sm.total + ' ' + _ses;" in s, "Learner repeats the confidence instead of the session count"
P
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in lv_card_smart lv_card_rom lv_bucket lv_conf lv_alpha lv_basis lv_we_short lv_wd_short lv_fb_tip lv_eta_meter_tip \
           lv_mode_night lv_mode_guard unit_d lv_dp_0 lv_dp_1 lv_dp_2 lv_dp_3 lv_dp_4 lv_dp_5 \
           lv_app_0 lv_app_1 lv_app_2 lv_app_3 lv_app_4 lv_fb_0 lv_fb_1 lv_fb_2 lv_fb_3 lv_fb_4; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
done
python3 - "$ROOT/webroot/i18n/ru.json" <<'P' || fail "ru strings"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for k, v in (("lv_bucket", "Слот"), ("lv_basis", "Основа"), ("lv_fb_0", "свой слот"), ("lv_app_2", "средняя"), ("lv_dp_0", "сон"), ("lv_card_smart", "Батарея и Smart"), ("lv_card_rom", "Батарея и система")):
    assert d[k] == v, (k, d[k])
P
{
  cat <<'EOF'
const _nodes = {};
function _el(id) { return _nodes[id] || null; }
function T(k, d) { return d; }
let _selectedProfile = 'smart';
const _lvMeter = { at: 0, cur: '', p: {} };
function liveDrainIsOpen() { return false; }
function liveDrainPaint() {}
EOF
  for fn in lvEtaFmt lvEtaPaint lvTopSec lvTopSecSync lvDrainHome lvMeterPaint lvPct; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  sed -n "/^const _lvEta = /p; /^const _lvDrain = /p" "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
function el(id) { const e = { id: id, textContent: '', title: '', style: { display: '' }, parentElement: null }; _nodes[id] = e; return e; }
const on = el('liveEtaOn'), off = el('liveEtaOff'); el('bnDrain'); el('bnDrainOff');
_lvEta.gov = { on: 536, onTip: 'gov on', off: 5000, offTip: 'gov off' };
_lvEta.cap = 88;
lvEtaPaint();
chk(on.textContent === '8h 56m' && off.textContent === '> 72h', 'Smart shows the governor forecast: ' + on.textContent + ' / ' + off.textContent);
_lvEta.chg = true; lvEtaPaint();
chk(on.textContent === '—' && off.textContent === '—', 'no time to empty while charging');
_lvEta.chg = false;
_selectedProfile = 'stock'; lvEtaPaint();
chk(on.textContent === '—' && off.textContent === '—', 'Stock without a measurement borrows nothing from the governor');
_lvMeter.p.stock = { on: 75, off: 50, offN: 1, onMin: 40 };
lvMeterPaint('stock');
chk(on.textContent === '11h 44m' && on.title.indexOf('measured') >= 0, 'Stock: level over its own measured drain: ' + on.textContent);
chk(off.textContent === '> 72h', 'Stock idle past three days shows the ceiling: ' + off.textContent);
_selectedProfile = 'battery'; lvMeterPaint('battery');
chk(on.textContent === '8h 56m' && off.textContent === '> 72h', 'Battery without a measurement falls back to the governor: ' + on.textContent);
_lvMeter.p.battery = { on: 120, off: 0, offN: 0, onMin: 30 };
lvMeterPaint('battery');
chk(on.textContent === '7h 20m' && off.textContent === '> 72h', 'Battery: measured screen-on, governor idle: ' + on.textContent + ' / ' + off.textContent);
const sec = { style: { display: 'none' } };
_nodes.liveTopSecLabel = { textContent: '', parentElement: sec };
const smart = el('liveSmartBanner'), rom = el('liveStockRomBanner');
smart.style.display = 'none'; rom.style.display = 'none';
lvTopSec(true);
chk(sec.style.display === 'none', 'section title hidden while no card is shown');
smart.style.display = ''; lvTopSec(true);
chk(sec.style.display === '' && _nodes.liveTopSecLabel.textContent === 'Battery & Smart', 'Smart card titled');
smart.style.display = 'none'; rom.style.display = ''; lvTopSec(false);
chk(_nodes.liveTopSecLabel.textContent === 'Battery & system', 'ROM card titled');
function card() {
  const c = { kids: [{ k: 'grid' }], style: { display: '' } };
  c.kids.forEach(function (k) { k.parentElement = c; });
  c.firstChild = c.kids[0];
  c.insertBefore = function (n, ref) {
    if (n.parentElement && n.parentElement !== c) { const p = n.parentElement; p.kids = p.kids.filter(function (k) { return k !== n; }); p.firstChild = p.kids[0] || null; }
    c.kids = c.kids.filter(function (k) { return k !== n; });
    const i = ref ? c.kids.indexOf(ref) : c.kids.length; c.kids.splice(i < 0 ? c.kids.length : i, 0, n); n.parentElement = c; c.firstChild = c.kids[0];
  };
  return c;
}
const a = card(), b = card(), strip = { k: 'strip', parentElement: null };
_nodes.bnDrainStrip = strip;
lvDrainHome(a); chk(a.kids[0] === strip, 'drain tiles open the Smart card');
lvDrainHome(b); chk(b.kids[0] === strip && a.kids.indexOf(strip) < 0, 'drain tiles move to the ROM card');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui monitor card: section title, two drain tiles with their time to empty on every profile, Basis instead of chips, three by three live grid, all in the UI language"
