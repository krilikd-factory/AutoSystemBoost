#!/bin/sh
# Runtime (fix127): one screen-time forecast, the same on every screen.
#
# OP15, V65 fix126: Monitor "Forecast (screen) 5 h 44 m · average" under "Average drain
# 12.9 %/h", while the action sheet printed "5.7 h at an average drain of 9.4 %/h" next to
# "this hour usually 12.9 %/h" - three rates, two called "average". The governor now
# publishes its forecast rate and basis; the REAL action.sh block and the REAL WebUI block
# are cut out and fed the same state: same minutes, same rate, the rate's own name.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
A="$ROOT/action.sh"; W="$ROOT/webroot/index.html"; G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL forecast one source: $*" >&2; exit 1; }

grep -q 'fprintf(f, "forecast_rate_x10=%d\\nforecast_basis=%s\\n", _fr, _fb);' "$G" || fail "governor does not publish the forecast"
grep -q 'g_smart_budget_rate_x10 = _budget_rate;' "$G" || fail "published rate is not the one the budget divided by"

awk '/^_frx=\$\(grep -m1 "\^forecast_rate_x10="/{f=1} f{print} /^# Idle half: the governor/{if(f) exit}' "$A" \
  | sed "s#/dev/.asb/state#\$STATE#g" > "$T/a.sh"
[ -s "$T/a.sh" ] || fail "action forecast block not found"
for v in T_ETA_MEASURED T_ETA_AVG T_ETA_SLOT T_ETA_HEUR T_ETA_SCREEN; do
  grep -m1 "^$v=" "$ROOT/runtime/i18n/action_ru.sh" >> "$T/ru.sh" || fail "$v missing in ru"
done
echo 'U_PCTH="%/ч"' >> "$T/ru.sh"

run_action() {   # $1 state file -> "minutes|note"
  STATE="$1" sh -c '
    . "$1"; _s() { _sfmt="$1"; shift; printf "$_sfmt" "$@"; }
    PROFILE=smart; _lvl=55; _cap_uah=7300000
    . "$2"
    echo "$(( _ton_h * 60 + _ton_m ))|$_eta_note|$(_s "$T_ETA_SCREEN" "$_ton_h" "$_ton_m")"
  ' x "$T/ru.sh" "$T/a.sh"
}

_s="$(grep -n '    let on_ma, eta_note;' "$W" | head -1 | cut -d: -f1)"
_e="$(grep -n '      : ((remain_mah > 0 && on_ma > 0) ? Math.floor(remain_mah \* 60 / on_ma) : 0);' "$W" | head -1 | cut -d: -f1)"
[ -n "$_s" ] && [ -n "$_e" ] || fail "WebUI forecast block not found"
sed -n "${_s},${_e}p" "$W" > "$T/w.js"
cat > "$T/run.js" <<'X'
const fs = require('fs');
const ru = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const kv = {};
for (const l of fs.readFileSync(process.argv[3], 'utf8').split('\n')) { const i = l.indexOf('='); if (i > 0) kv[l.slice(0, i)] = l.slice(i + 1); }
const T = (k, d) => (k in ru ? ru[k] : d);
const st = null, bcap = 55, cap_full_mah = 7300, profile = 'smart';
let __out = '';
eval(fs.readFileSync(process.argv[4], 'utf8') + "\n__out = ton_min + '|' + eta_note;");
console.log(__out);
X
run_web() { node "$T/run.js" "$ROOT/webroot/i18n/ru.json" "$1" "$T/w.js"; }

# 1. The actual drain (fix128): 15.4 %/h measured over the last minutes, at 55 %.
printf 'forecast_rate_x10=154\nforecast_basis=now\nsmart_drain_pctph_x10=154\nsmart_drain_window_s=698\nsmart_drain_ewma_x10=162\nsmart_bucket_drain_x10=93\nsmart_confidence=1000\n' > "$T/s0"
a="$(run_action "$T/s0")"; w="$(run_web "$T/s0")"
[ "${a%%|*}" = 214 ] || fail "action minutes $a, want 214 (55 % / 15.4 %/h)"
[ "${w%%|*}" = 214 ] || fail "WebUI minutes $w, want 214"
printf '%s' "$a" | grep -q '(по факту 15.4%/ч)' || fail "action note for the actual drain: $a"
printf '%s' "$a" | grep -q '|~3 ч 34 мин$' || fail "Smart card time differs from the header: $a"
[ "${w#*|}" = ' · по факту' ] || fail "WebUI note must be short - '· по факту': $w"
# 2. An estimate from recent sessions: 9.4 %/h.
printf 'forecast_rate_x10=94\nforecast_basis=recent\nsmart_drain_pctph_x10=103\nsmart_drain_window_s=300\nsmart_drain_ewma_x10=94\nsmart_bucket_drain_x10=129\nsmart_confidence=1000\n' > "$T/s1"
a="$(run_action "$T/s1")"; w="$(run_web "$T/s1")"
[ "${a%%|*}" = 351 ] && [ "${w%%|*}" = 351 ] || fail "estimate minutes: action $a, WebUI $w (want 351)"
printf '%s' "$a" | grep -q '(оценка по прошлым сессиям 9.4%/ч)' || fail "action estimate note: $a"
[ "${w#*|}" = ' · оценка' ] || fail "WebUI estimate note must be short: $w"
# 3. Slot basis right after boot.
printf 'forecast_rate_x10=129\nforecast_basis=slot\nsmart_drain_window_s=0\n' > "$T/s2"
a="$(run_action "$T/s2")"; w="$(run_web "$T/s2")"
[ "${a%%|*}" = "${w%%|*}" ] || fail "slot forecast differs: action $a, WebUI $w"
printf '%s' "$a" | grep -q '(оценка по этому часу 12.9%/ч)' || fail "slot note wrong: $a"
[ "${w#*|}" = ' · оценка' ] || fail "WebUI slot note wrong: $w"
# 4. An older governor without forecast keys: both fall back to the same live rate.
printf 'smart_drain_pctph_x10=103\nsmart_drain_window_s=1200\n' > "$T/s3"
a="$(run_action "$T/s3")"; w="$(run_web "$T/s3")"
[ "${a%%|*}" = 320 ] && [ "${w%%|*}" = 320 ] || fail "fallback differs: action $a, WebUI $w (want 320)"
printf '%s' "$a" | grep -q '(по факту 10.3%/ч)' || fail "live note wrong: $a"
# 5. The Monitor tile shows the actual drain, in one word.
grep -q '"lv_avgdrain": "Расход"' "$ROOT/webroot/i18n/ru.json" || fail "drain tile not the actual drain"
grep -q "if (_fbs === 'now') _act = _frt;" "$W" || fail "tile does not show the actual rate"
# fix131: until a window is measured the tile shows the same estimate the action screen
# prints (marked "~"), not "measuring" - nearly always the case in short screen-on use.
grep -Fq "} else if (_frt > 0 && (_fbs === 'recent' || _fbs === 'slot') && !_chg) {" "$W" || fail "tile hides the estimate the action screen shows"
grep -Fq "_bdEl.textContent = '~' + (_frt / 10).toFixed(1)" "$W" || fail "estimate not marked as one"
grep -q '_fb = "now";' "$G" || fail "governor forecast does not lead with the actual drain"

echo "PASS forecast one source: actual drain first, same minutes on every screen, short labels"
