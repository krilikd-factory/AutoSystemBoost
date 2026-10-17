#!/bin/sh
# Runtime (fix162): the Monitor card's tags live inside the card, and the card speaks the UI
# language.
#
# Owner's screenshot of fix161: the "exact" chip sat on the card's top border, half on the
# gradient and half on the page, and read as a sticker that had slipped. The same screen still
# showed "BUCKET", "CONF", "#1 sleep·we", "medium" and "42% bat" in a Russian UI. Both cards
# (Smart and the ROM card of every other profile) now open with a slim title row holding the
# chips; the drain strip follows it. The REAL page functions run in node.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor card head: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui monitor card head: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$H" <<'P' || fail "layout"
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
for cid, tags, title in (("liveSmartBanner", "bnTagRow", "lv_card_smart"), ("liveStockRomBanner", "bnStockTagRow", "lv_card_rom")):
    i = s.index('id="%s"' % cid)
    b = s[i:s.index('<div class="smart-banner-row">', i)]
    h = b.index('<div class="smart-banner-head">')
    assert h < b.index('data-i18n="%s"' % title) < b.index('id="%s"' % tags), "%s: chips are not in the title row" % cid
css = s[s.index("/* Monitor, compact"):s.index(".live-page .sec {")]
assert "position: absolute" not in css and "top: -8px" not in css, "a tag is still pinned to the card border"
assert ".smart-banner-head { display: flex;" in s, "no title row style"
sb = s[s.index('id="liveSmartBanner"'):s.index('id="liveStockRomBanner"')]
assert '🤖' not in sb and '>Conf<' not in sb, "English-only labels left on the Smart card"
for k in ("lv_bucket", "lv_conf", "lv_alpha", "lv_app"):
    assert ('data-i18n="%s"' % k) in sb, "label %s not translated" % k
assert "fbTag.textContent = T('lv_fb_' + fb," in s, "fallback chip still English"
assert "T('lv_app_' + appH," in s, "load class still English"
assert "T('lv_dp_' + dp, dpNames[dp])" in s, "Home day part still English"
assert "+ '% bat'" not in s, "battery lean still carries an English unit"
assert "T('unit_d', 'd')" in s and "+ 'h '" not in s, "Stock uptime units still English"
P
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in lv_card_smart lv_card_rom lv_bucket lv_conf lv_alpha lv_we_short lv_wd_short lv_fb_tip unit_d \
           lv_dp_0 lv_dp_1 lv_dp_2 lv_dp_3 lv_dp_4 lv_dp_5 lv_app_0 lv_app_1 lv_app_2 lv_app_3 lv_app_4 \
           lv_fb_0 lv_fb_1 lv_fb_2 lv_fb_3 lv_fb_4; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
done
python3 - "$ROOT/webroot/i18n/ru.json" <<'P' || fail "ru strings"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for k, v in (("lv_bucket", "Слот"), ("lv_fb_0", "точный слот"), ("lv_app_2", "средняя"), ("lv_dp_0", "сон"), ("lv_card_smart", "Обучение Smart")):
    assert d[k] == v, (k, d[k])
P
{
  echo "const _nodes = {};"
  echo "function _el(id) { return _nodes[id] || null; }"
  sed -n "/^function lvDrainHome(/,/^}/p" "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
function mk(cls) { return { className: cls, parentElement: null, kids: [], nextSibling: null }; }
function card() {
  const c = mk('smart-banner'); const head = mk('smart-banner-head'); const grid = mk('smart-banner-row');
  c.kids = [head, grid]; head.parentElement = c; grid.parentElement = c;
  c.querySelector = function (q) { return q === '.smart-banner-head' ? this.kids.find(k => k.className === 'smart-banner-head') || null : null; };
  c.insertBefore = function (n, ref) {
    if (n.parentElement) n.parentElement.kids = n.parentElement.kids.filter(k => k !== n);
    const i = ref ? this.kids.indexOf(ref) : 0; this.kids.splice(i < 0 ? this.kids.length : i, 0, n); n.parentElement = this;
    this.kids.forEach((k, j) => { k.nextSibling = this.kids[j + 1] || null; });
  };
  c.kids.forEach((k, j) => { k.nextSibling = c.kids[j + 1] || null; });
  return c;
}
const smart = card(), rom = card(), strip = mk('smart-drain');
_nodes.bnDrainStrip = strip;
lvDrainHome(smart);
chk(smart.kids[0].className === 'smart-banner-head' && smart.kids[1] === strip, 'Smart: strip right under the title row');
lvDrainHome(rom);
chk(rom.kids[0].className === 'smart-banner-head' && rom.kids[1] === strip && smart.kids.indexOf(strip) < 0, 'ROM card: strip moved under its title row');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui monitor card head: chips in a title row inside both cards, drain strip under it, Smart card labels and values in the UI language"
