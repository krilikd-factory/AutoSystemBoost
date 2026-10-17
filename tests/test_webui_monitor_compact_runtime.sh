#!/bin/sh
# Runtime (fix161): the Monitor fits with room to spare, its heat tile no longer scares, every
# profile shows both drains, and the Settings restarts are one row of small tiles.
#
# Owner's screenshot: the last row of Monitor tiles touched the tab bar after the screen-on /
# screen-off pair went into the Smart card, and "usual peak 51.8 C" read as a hot phone - it is
# the hottest core at its busiest moment, and this phone's own norm is 41-49 C. Asked too: the
# drain pair on every profile (Stock included) and lighter restart buttons. The REAL page
# functions run in node; the markup is checked for the new layout.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor compact: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui monitor compact: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$H" <<'P' || fail "layout"
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
b = s[s.index('id="liveSmartBanner"'):s.index('id="liveStockRomBanner"')]
assert b.index('id="bnDrainStrip"') < b.index('id="bnBucket"'), "drain pair is not the first row of the Smart card"
assert 'data-i18n="lv_slot_heat"' in b and 'lv_slot_temp' not in b, "the usual-peak tile is still a bare temperature"
st = s[s.index('id="liveStockRomBanner"'):s.index('<div class="live-metrics">')]
assert 'id="bnStockDrain"' in st, "stock card lost its battery current"
g = s[s.index('<div class="live-metrics">'):s.index('<section class="stock-telemetry"')]
for i in ("liveCpu", "liveSkin", "liveSurface", "liveState", "liveGpu", "liveHeadroom", "liveCapSrc", "liveClamp", "liveLearner"):
    assert ('id="%s"' % i) in g, "metric %s lost" % i
for i in ("liveEtaOn", "liveEtaOff"):
    assert ('id="%s"' % i) in b, "time to empty %s is not beside the drain figures" % i
r = s[s.index('<div id="cfgRebootWrap" class="cfg-reboot-row">'):]
r = r[:r.index('</div>')]
assert r.count('class="cfg-reboot-tile') == 3, "restarts are not three tiles"
assert "#cfgRebootWrap.cfg-reboot-row { display: grid; grid-template-columns: repeat(3, 1fr);" in s, "restart tiles not in one row"
assert re.search(r"if \(stockBanner\) \{ lvDrainHome\(stockBanner\);[^}]*lvMeterPaint\(_selectedProfile\); \}", s), "other profiles do not get the drain pair"
P
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in lv_slot_heat lv_heat_cool lv_heat_norm lv_heat_warm lv_heat_tip lv_drain_on_meter lv_drain_cmp cfg_reboot_tile cfg_soft_tile cfg_sysui_tile; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
  grep -q '"lv_heat_tip": "[^"]*%s[^"]*%s' "$ROOT/webroot/i18n/$l.json" || fail "$l.json lv_heat_tip needs two places"
done
{
  echo "var T = function (k, d) { return d; };"
  for fn in lvSlotHeat lvMeterParse; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
let h = lvSlotHeat(518, 414, 494);
chk(h.text === 'above normal' && h.warm === true, 'slot above the norm: ' + JSON.stringify(h));
chk(h.tip.indexOf('51.8') >= 0 && h.tip.indexOf('41') >= 0 && h.tip.indexOf('49') >= 0, 'number kept in the tooltip: ' + h.tip);
h = lvSlotHeat(487, 414, 494); chk(h.text === 'normal' && !h.warm, 'slot inside the norm: ' + h.text);
h = lvSlotHeat(400, 414, 494); chk(h.text === 'below normal' && !h.warm, 'slot under the norm: ' + h.text);
h = lvSlotHeat(0, 414, 494); chk(h.text === '—', 'nothing learned shows a dash');
h = lvSlotHeat(530, 0, 0); chk(h.text === 'normal' && !h.warm, 'no norm known: never "above"');
const m = lvMeterParse('smart 1170 300 7230 100 1\nbattery 300 100 0 0 0\nstock 2400 500 7200 100 1\njunk\ncurrent stock\n');
chk(m.cur === 'stock', 'current profile');
chk(m.p.smart.on === 92 && m.p.smart.off === 50, 'smart rates: ' + JSON.stringify(m.p.smart));
chk(m.p.battery.on === 0, 'under 10 min of screen time is not a rate');
chk(m.p.stock.on === 75 && m.p.stock.offN === 1, 'stock rates: ' + JSON.stringify(m.p.stock));
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui monitor compact: drain pair first in the card on every profile, heat against the phone's own norm, restarts as one row of tiles"
