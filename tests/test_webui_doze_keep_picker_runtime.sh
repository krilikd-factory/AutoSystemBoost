#!/bin/sh
# Runtime (fix152): the WebUI picker for apps the Doze trim must leave alone.
#
# Testers asked to choose these apps in the WebUI, easily, with a search. The REAL page
# functions run in node on the REAL applier's `list` output (fake pm / deviceidle):
#   - every user app is offered, not only the ones Android still exempts, and an app ASB
#     already trimmed is there to tick, marked as trimmed;
#   - names come from the root manager when it gives them, and the search finds an app by
#     its name or by its package;
#   - ticked apps come first, then what ASB trimmed, then the exempt ones, then the rest;
#   - the saved file holds exactly the ticked packages, one per line, and nothing else.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui doze keep picker: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui doze keep picker: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q "eb.onclick = (e) => { e.stopPropagation(); uiSound('option'); dozeOpenEditor(); };" "$H" || fail "the card button does not open the picker"
grep -q "run('sh ' + shQuote(MD + '/runtime/asb_doze_apply.sh') + ' list 2>/dev/null')" "$H" || fail "the picker does not read the applier's list"
grep -q "try { await run('sh ' + shQuote(MD + '/runtime/asb_doze_apply.sh') + ' >/dev/null 2>&1'); } catch (e) {}" "$H" || fail "closing the picker does not apply"
grep -q 'id="dozeKeepSearch" type="search"' "$H" || fail "no search field"
for l in en ru uk; do
  for k in doze_keep_title doze_keep_search doze_keep_copy doze_tag_trimmed doze_chip_trimmed doze_keep_saved; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
done
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:%s\n' com.example.zeta org.telegram.messenger com.example.vpn com.example.game com.azure.authenticator com.whatsapp com.example.alpha
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = deviceidle ] && [ "$2" = whitelist ] && [ -z "${3:-}" ] || exit 0
printf '%s\n' 'system-excidle,com.android.phone,1001' 'user,com.example.vpn,10100' 'user,com.azure.authenticator,10101'
S
chmod +x "$T/bin/"*
printf 'doze_level=night\ndoze_trim_whitelist=1\n' > "$T/mod/config/governor.conf"
printf '%s\n' com.example.game > "$T/st/doze_whitelist_removed"
printf '%s\n' com.example.zeta > "$T/st/doze_whitelist_keep"
PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_DOZE_STATE_DIR="$T/st" sh "$ROOT/runtime/asb_doze_apply.sh" list > "$T/list" 2>/dev/null
{
  echo "const DOZE_KEEP_PATH = process.env.KEEP;"
  sed -n '/^const DOZE_MESSENGERS = \[/,/^\];/p' "$H"
  sed -n '/^const _dozeKeep = {/,/};$/p' "$H"
  grep '^function dozePkgOk(p) { return /^\[A-Za-z0-9_.\]+\$/.test(p); }$' "$H"
  for fn in shQuote dozeIsMessenger dozeKeepParse dozeKeepLabels dozeKeepRank dozeKeepMatch dozeKeepWrite; do
    sed -n "/^function $fn(/,/^}/p" "$H"
  done
  cat <<'EOF'
const fs = require('fs'); const cp = require('child_process');
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const d = dozeKeepParse(fs.readFileSync(process.env.LIST, 'utf8'));
chk(d.trim === true, 'night doze with trim on not read as working');
chk(d.apps.length === 7, 'not every user app offered: ' + d.apps.length);
chk(!d.E['com.android.phone'] && !d.apps.some(a => a.pkg === 'com.android.phone'), 'a system entry offered');
chk(d.R['com.example.game'] === 1, 'the app ASB trimmed is not marked');
chk(d.apps.some(a => a.pkg === 'com.example.game'), 'the app ASB trimmed is not offered');
chk(d.apps.find(a => a.pkg === 'com.azure.authenticator').prot === true, 'rule protection lost');
global.ksu = { getPackagesInfo: function (j) {
  const want = JSON.parse(j);
  const names = { 'org.telegram.messenger': 'Telegram', 'com.whatsapp': 'WhatsApp', 'com.example.alpha': 'Альфа Банк', 'com.example.zeta': 'com.example.zeta' };
  return JSON.stringify(want.map(p => ({ packageName: p, appLabel: names[p] || '' })));
} };
const labels = dozeKeepLabels(d.apps.map(a => a.pkg));
chk(labels['org.telegram.messenger'] === 'Telegram', 'name from the root manager not used');
chk(!('com.example.zeta' in labels), 'a label equal to the package treated as a name');
delete global.ksu;
chk(Object.keys(dozeKeepLabels(['com.whatsapp'])).length === 0, 'no root-manager API must give no names, not an error');
global.ksu = { getPackagesInfo: function () { throw new Error('x'); } };
chk(Object.keys(dozeKeepLabels(['com.whatsapp'])).length === 0, 'a failing API must give no names');
delete global.ksu;
const apps = d.apps.map(function (a) {
  const name = labels[a.pkg] || '';
  return { pkg: a.pkg, name: name, prot: a.prot, e: !!d.E[a.pkg], r: !!d.R[a.pkg], g: !!d.G[a.pkg],
    msg: dozeIsMessenger(a.pkg), kept0: !!d.K[a.pkg], q: (name + ' ' + a.pkg).toLowerCase() };
});
apps.sort(function (x, y) { const a = dozeKeepRank(x), b = dozeKeepRank(y); return a !== b ? a - b : (x.name || x.pkg).toLowerCase().localeCompare((y.name || y.pkg).toLowerCase()); });
const order = apps.map(a => a.pkg).join(' ');
chk(order === 'com.example.zeta com.example.game com.example.vpn org.telegram.messenger com.whatsapp com.example.alpha com.azure.authenticator', 'order: ' + order);
_dozeKeep.apps = apps; _dozeKeep.keep = { 'com.example.zeta': 1 };
function hits(q, f) { _dozeKeep.q = q.toLowerCase(); _dozeKeep.filter = f || 'all'; return apps.filter(dozeKeepMatch).map(a => a.pkg).join(' '); }
chk(hits('tele') === 'org.telegram.messenger', 'search by name: ' + hits('tele'));
chk(hits('WHATS') === 'com.whatsapp', 'search is case-sensitive');
chk(hits('альфа') === 'com.example.alpha', 'search by a Cyrillic name: ' + hits('альфа'));
chk(hits('messenger') === 'org.telegram.messenger', 'search by package: ' + hits('messenger'));
chk(hits('', 'trimmed') === 'com.example.game', 'trimmed filter: ' + hits('', 'trimmed'));
chk(hits('', 'kept') === 'com.example.zeta', 'ticked filter: ' + hits('', 'kept'));
chk(hits('zzz') === '', 'a search with no match still shows apps');
let cmd = '';
global.run = function (c) { cmd = c; return Promise.resolve({ errno: cp.spawnSync('sh', ['-c', c]).status }); };
_dozeKeep.keep = { 'org.telegram.messenger': 1, 'com.whatsapp': 1, "x';touch /tmp/asb_pwn;'": 1 };
dozeKeepWrite().then(function () {
  chk(fs.readFileSync(process.env.KEEP, 'utf8') === 'com.whatsapp\norg.telegram.messenger\n', 'file: ' + JSON.stringify(fs.readFileSync(process.env.KEEP, 'utf8')));
  chk(!fs.existsSync('/tmp/asb_pwn') && cmd.indexOf('pwn') < 0, 'an invalid name reached the shell');
  chk(_dozeKeep.failed === false, 'a good write reported as failed');
  _dozeKeep.keep = {};
  return dozeKeepWrite();
}).then(function () {
  chk(fs.readFileSync(process.env.KEEP, 'utf8') === '', 'unticking everything left names in the file');
  process.exit(bad ? 1 : 0);
});
EOF
} > "$T/t.js"
LIST="$T/list" KEEP="$T/keep" node "$T/t.js" || fail "see above"
echo "PASS webui doze keep picker: all user apps, trimmed ones marked, search by name or package, exact keep file"
