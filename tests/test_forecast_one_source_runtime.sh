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

# 1. The governor's forecast: recent drain 9.4 %/h at 55 %.
printf 'forecast_rate_x10=94\nforecast_basis=recent\nsmart_drain_pctph_x10=103\nsmart_drain_window_s=5908\nsmart_drain_ewma_x10=94\nsmart_bucket_drain_x10=129\nsmart_confidence=1000\n' > "$T/s1"
a="$(run_action "$T/s1")"; w="$(run_web "$T/s1")"
[ "${a%%|*}" = 351 ] || fail "action minutes $a, want 351 (55 % / 9.4 %/h)"
[ "${w%%|*}" = 351 ] || fail "WebUI minutes $w, want 351"
printf '%s' "$a" | grep -q '(недавний расход 9.4%/ч)' || fail "action note does not name the rate: $a"
printf '%s' "$a" | grep -q '|~5 ч 51 мин$' || fail "Smart card time differs from the header: $a"
printf '%s' "$w" | grep -q 'недавний расход 9.4%/ч' || fail "WebUI note does not name the rate: $w"
# 2. Slot basis right after boot.
printf 'forecast_rate_x10=129\nforecast_basis=slot\nsmart_drain_window_s=0\n' > "$T/s2"
a="$(run_action "$T/s2")"; w="$(run_web "$T/s2")"
[ "${a%%|*}" = "${w%%|*}" ] || fail "slot forecast differs: action $a, WebUI $w"
printf '%s' "$a" | grep -q '(обычно в этот час 12.9%/ч)' || fail "slot note wrong: $a"
printf '%s' "$w" | grep -q 'обычно в этот час 12.9%/ч' || fail "WebUI slot note wrong: $w"
# 3. No governor forecast (another profile): both fall back to the same live rate.
printf 'forecast_rate_x10=0\nforecast_basis=none\nsmart_drain_pctph_x10=103\nsmart_drain_window_s=1200\n' > "$T/s3"
a="$(run_action "$T/s3")"; w="$(run_web "$T/s3")"
[ "${a%%|*}" = 320 ] && [ "${w%%|*}" = 320 ] || fail "fallback differs: action $a, WebUI $w (want 320)"
printf '%s' "$a" | grep -q '(расход сейчас 10.3%/ч)' || fail "live note wrong: $a"
# 4. The Monitor tile is "usual this hour", not "average drain".
grep -q '"lv_avgdrain": "Обычно в этот час"' "$ROOT/webroot/i18n/ru.json" || fail "slot tile still called average"
grep -q '"eta_average": "недавний расход"' "$ROOT/webroot/i18n/ru.json" || fail "forecast basis still called average"

echo "PASS forecast one source: action and WebUI print the same minutes from the governor's rate, each rate named"
