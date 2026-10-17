#!/bin/sh
# Runtime (fix158): the picker's labels say what will happen, and the night window is named.
#
# Asked: what is the difference between "exempt" and "exempt via ASB", between Ticked and
# Trimmed, and does Trimmed work. The labels were fixed when the list opened, so ticking an
# app ASB had trimmed still read "trimmed by ASB" until the window was closed and opened
# again, and Deep Sleep on night by day showed an empty Trimmed with no reason. The REAL page
# functions run in node:
#   - the applier's window/night lines are read;
#   - each label follows the tick: trimmed -> returns on Done, ASB's exemption -> removed on
#     Done, a new tick -> exempt on Done, an exempt app just unticked -> trimmed on Done (only
#     while the trim is live), and back to the plain label when the tick is undone;
#   - protected apps keep their own label whatever the tick;
#   - every new string exists in every language, and the legend names every label.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui doze keep tags: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui doze keep tags: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q '<details class="doze-keep-legend" id="dozeKeepLegend">' "$H" || fail "no legend in the picker"
grep -q "_dozeKeep.live = d.trim && d.window !== false;" "$H" || fail "the live state ignores the night window"
grep -q "} else if (d.window === false) {" "$H" || fail "no note for the closed night window"
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in doze_tag_back doze_tag_drop doze_tag_willtrim doze_tag_give doze_keep_day doze_keep_legend_title doze_keep_legend; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
  grep -q '"doze_keep_day": "[^"]*%s' "$ROOT/webroot/i18n/$l.json" || fail "$l.json doze_keep_day has no place for the window"
done
python3 - "$ROOT/webroot/i18n" <<'P' || fail "a legend does not name every label"
import json, sys
for l in ("en", "ru", "uk", "de", "es", "fr", "it", "pt", "tr", "id", "ar", "hy", "zh"):
    d = json.load(open("%s/%s.json" % (sys.argv[1], l), encoding="utf-8"))
    leg = d["doze_keep_legend"].lower()
    for k in ("doze_tag_exempt", "doze_tag_granted", "doze_tag_trimmed", "doze_tag_always", "doze_chip_kept", "doze_chip_trimmed"):
        if d[k].lower() not in leg:
            print(l, k, d[k]); sys.exit(1)
P
{
  echo "function T(k, d) { return k; }"
  sed -n '/^const _dozeKeep = {/,/};$/p' "$H"
  for fn in dozeKeepParse dozeKeepTag; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const out = ['trim=1', 'level=night', 'window=0', 'night=23:15-06:40', 'A com.a -', 'A com.b -', 'A com.c -',
  'A com.d -', 'A com.auth p', 'E com.b', 'E com.d', 'E com.auth', 'R com.a', 'G com.b', 'K com.b', 'K com.d'].join('\n');
const d = dozeKeepParse(out);
chk(d.trim === true && d.window === false && d.night === '23:15-06:40', 'window lines: ' + JSON.stringify([d.trim, d.window, d.night]));
chk(dozeKeepParse('trim=1\nlevel=aggressive').window === null, 'no window line must read as no window');
chk(dozeKeepParse('window=1').window === true, 'open window');
function app(p) { return { pkg: p, prot: p === 'com.auth', e: !!d.E[p], r: !!d.R[p], g: !!d.G[p], kept0: !!d.K[p] }; }
const A = app('com.a'), B = app('com.b'), C = app('com.c'), D = app('com.d'), P = app('com.auth');
function tag(a) { const t = dozeKeepTag(a); return t ? t[0] : '-'; }
_dozeKeep.trim = true; _dozeKeep.live = true; _dozeKeep.keep = { 'com.b': 1, 'com.d': 1 };
chk(tag(A) === 'trimmed', 'trimmed app: ' + tag(A));
chk(tag(B) === 'granted', 'ASB grant: ' + tag(B));
chk(tag(C) === '-', 'plain app: ' + tag(C));
chk(tag(D) === 'exempt', 'kept exempt app: ' + tag(D));
chk(tag(P) === 'always', 'protected app: ' + tag(P));
_dozeKeep.keep = { 'com.a': 1, 'com.c': 1, 'com.auth': 1 };
chk(tag(A) === 'back', 'ticking a trimmed app: ' + tag(A));
chk(tag(B) === 'drop', 'unticking an ASB grant: ' + tag(B));
chk(tag(C) === 'give', 'ticking an app with no exemption: ' + tag(C));
chk(tag(D) === 'drop' && dozeKeepTag(D)[1] === 'doze_tag_willtrim', 'unticking an exempt app while the trim is live: ' + tag(D));
chk(tag(P) === 'always', 'protected app ticked: ' + tag(P));
_dozeKeep.live = false;
chk(tag(D) === 'exempt', 'unticking an exempt app by day must not promise a trim: ' + tag(D));
chk(tag(C) === 'give', 'by day a tick still gets an exemption: ' + tag(C));
_dozeKeep.trim = false;
chk(tag(C) === '-' && tag(A) === 'trimmed' && tag(B) === 'granted', 'trim off: no promise of a change');
process.exit(bad ? 1 : 0);
EOF
} > "$T/t.js"
node "$T/t.js" || fail "see above"
echo "PASS webui doze keep tags: labels follow the tick, the night window is named, every language explains every label"
