#!/usr/bin/env bash
# Congestion-verdict honesty contract: on a kernel without per-route congctl, a link kind
# whose request is satisfied by the GLOBAL knob must report ok, a kind asking for a
# different algorithm must report unsupported - and the verdict mapper must file both
# under the right WebUI key. Field case: OP15 day log showed net_congestion_mobile
# "not_applied" forever while mobile traffic genuinely ran the globally-applied bbr.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_net_apply.sh"
fail() { echo "FAIL net verdict contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'runtime/asb_net_apply.sh missing'
sh -n "$SRC"

# --- source pins: the emission sites and the mapper lines exist ---
grep -qF 'cc[$_k2]=$_cc(global)' "$SRC" || fail 'global-cover per-kind ok token missing'
grep -qF 'cc[$_k2]=$_k2want-unsupported' "$SRC" || fail 'per-kind unsupported token missing'
grep -qF 'cc[$_akind:$_act]=$_want(global-fallback)' "$SRC" || fail 'fallback token must name the kind'
grep -qF 'cc\[mobile*-unsupported*)' "$SRC" || fail 'mapper: mobile unsupported line missing'
grep -qF 'cc\[wifi*-unsupported*)' "$SRC" || fail 'mapper: wifi unsupported line missing'
# The old anonymous "active" token must not come back: the mapper cannot key on it.
if grep -qF 'cc[active:' "$SRC"; then
  fail 'anonymous cc[active:...] token is back - the badge cannot map it'
fi

# --- ordering pin: specific unsupported/unavailable lines precede the generic ok line,
# or every token would be swallowed by the wildcard first ---
for kind in wifi mobile; do
  u="$(grep -nF "cc\[${kind}*-unsupported*)" "$SRC" | head -1 | cut -d: -f1)"
  g="$(grep -nF "cc\[${kind}*)" "$SRC" | head -1 | cut -d: -f1)"
  [ -n "$u" ] || fail "mapper: $kind unsupported line missing"
  [ -n "$g" ] || fail "mapper: $kind generic line missing"
  [ "$u" -lt "$g" ] || fail "mapper: $kind unsupported line must precede the generic ok line"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- executable pin 1: the REAL emission loop, with only _cfg stubbed ---
sed -n '/# Per-link verdicts when the kernel cannot do per-route congctl/,/^          fi$/p' "$SRC" > "$TMP/emit.sh"
[ -s "$TMP/emit.sh" ] || fail 'emission block not found'
grep -qF 'cc[$_k2]=' "$TMP/emit.sh" || fail 'emission block extracted incomplete'

emit() { # $1 = applied global cc; $2 = cfg net_congestion_wifi; $3 = cfg net_congestion_mobile
  W="$2"; M="$3"
  ( _cc="$1"; _congctl_ok=0; _out="congestion=$1"
    _cfg() { case "$1" in
               net_congestion_wifi)   printf '%s' "$W" ;;
               net_congestion_mobile) printf '%s' "$M" ;;
             esac; }
    . "$TMP/emit.sh"
    printf '%s\n' "$_out" )
}

[ "$(emit bbr bbr bbr)" = 'congestion=bbr cc[wifi]=bbr(global) cc[mobile]=bbr(global)' ] \
  || fail 'matching per-link requests not credited to the global knob'
[ "$(emit bbr auto cubic)" = 'congestion=bbr cc[mobile]=cubic-unsupported' ] \
  || fail 'distinct per-link request not flagged unsupported (and auto must stay silent)'
[ "$(emit bbr '' '')" = 'congestion=bbr' ] \
  || fail 'unset per-link keys must not emit tokens'

# --- executable pin 2: the REAL verdict mapper against synthetic result lines ---
sed -n '/^  for _tok in \$_out; do$/,/^  done$/p' "$SRC" > "$TMP/map.sh"
[ -s "$TMP/map.sh" ] || fail 'verdict mapper block not found'
grep -q 'net_congestion_mobile' "$TMP/map.sh" || fail 'verdict mapper extracted incomplete'

map_verdicts() { ( _out="$1"; . "$TMP/map.sh" ); }

v="$(map_verdicts 'congestion=bbr cc[mobile]=bbr(global)')"
echo "$v" | grep -qx 'net_congestion=ok' || fail 'global congestion not ok'
echo "$v" | grep -qx 'net_congestion_mobile=ok' || fail 'global-covered mobile not ok'

v="$(map_verdicts 'congestion=bbr cc[mobile]=cubic-unsupported')"
echo "$v" | grep -qx 'net_congestion_mobile=unsupported' || fail 'unsupported mobile not mapped'

v="$(map_verdicts 'cc[mobile:rmnet_data3]=bbr(global-fallback)')"
echo "$v" | grep -qx 'net_congestion_mobile=ok' || fail 'fallback-served mobile not ok'

v="$(map_verdicts 'cc[wifi:wlan0]=bbr(global)')"
echo "$v" | grep -qx 'net_congestion_wifi=ok' || fail 'global-covered wifi not ok'

v="$(map_verdicts 'cc[wifi]=cubic-unavailable')"
echo "$v" | grep -qx 'net_congestion_wifi=unavailable' || fail 'unavailable wifi regressed'

v="$(map_verdicts 'qdisc[mobile:rmnet_data3]=fq_codel-noqueue-unsupported')"
echo "$v" | grep -qx 'net_qdisc_mobile=unsupported' || fail 'noqueue mobile not unsupported'

# Regression: the pre-V65-40 vocabulary must keep its meaning.
v="$(map_verdicts 'qdisc[mobile:rmnet_data3]=fq_codel-not-applied')"
echo "$v" | grep -qx 'net_qdisc_mobile=failed' || fail 'not-applied mobile regressed'
v="$(map_verdicts 'congestion=FAILED')"
echo "$v" | grep -qx 'net_congestion=failed' || fail 'global FAILED regressed'
v="$(map_verdicts 'qdisc=fq_codel-unavailable')"
echo "$v" | grep -qx 'net_qdisc=unavailable' || fail 'qdisc unavailable not mapped'

# --- tc binary resolution pins (CPH2745 field log: boot PATH gave a limited applet
# that rejected the qdisc grammar while /system/bin/tc worked) ---
grep -qF '_ASB_TC="${ASB_TC:-}"' "$SRC" || fail 'tc not injectable for fixtures'
grep -qF 'for _tcc in /system/bin/tc "$(command -v tc 2>/dev/null)"; do' "$SRC" \
  || fail 'tc resolution must prefer /system/bin/tc over PATH'
grep -qF '"$_ASB_TC" qdisc replace' "$SRC" || fail 'qdisc writes not using the resolved tc'
grep -qF '"$_ASB_TC" qdisc show' "$SRC" || fail 'qdisc reads not using the resolved tc'
grep -qF 'if [ -n "$_ASB_TC" ]; then' "$SRC" || fail 'qdisc section not gated on the resolved tc'
grep -qF 'qdisc=$_qd-unavailable' "$SRC" || fail 'missing-tc verdict missing'
grep -qF 'tc_binary_limited' "$SRC" || fail 'limited-tc classifier missing'
grep -qF 'qdisc=*-unavailable)' "$SRC" || fail 'mapper: qdisc unavailable line missing'
if grep -v '^[[:space:]]*#' "$SRC" | grep -qE '(^|[^"A-Za-z_])tc qdisc (replace|show)'; then
  fail 'a bare tc call survived - every qdisc call must use the resolved binary'
fi
# profile_core.sh has the same boot-context exposure and must resolve the same way.
PC="$ROOT/runtime/profile_core.sh"
grep -qF '_asb_tc="${ASB_TC:-}"' "$PC" || fail 'profile_core tc not injectable'
grep -qF '"$_asb_tc" qdisc replace' "$PC" || fail 'profile_core not using the resolved tc'

# Executable: the REAL tc selection block honours the fixture injector.
n="$(grep -nF '_ASB_TC="${ASB_TC:-}"' "$SRC" | head -1 | cut -d: -f1)"
[ -n "$n" ] || fail 'cannot locate tc selection block'
sed -n "${n},$((n + 6))p" "$SRC" > "$TMP/tcsel.sh"
grep -q '^fi$' "$TMP/tcsel.sh" || fail 'tc selection block extracted incomplete'
[ "$(ASB_TC=/bin/echo sh -c '. "$1"; printf %s "$_ASB_TC"' _ "$TMP/tcsel.sh")" = '/bin/echo' ] \
  || fail 'tc selection ignores the ASB_TC injector'

# --- verdict dedupe pins: one line per key, worst wins ---
grep -qF '# One line per key.' "$SRC" || fail 'verdict dedupe block missing'
sed -n '/# One line per key\./,/|| rm -f "\$_res_new\.d"/p' "$SRC" > "$TMP/dedupe.sh"
grep -q 'awk' "$TMP/dedupe.sh" || fail 'dedupe block extracted incomplete'
cat > "$TMP/res_in" <<'EOF'
net_congestion=ok
net_qdisc_mobile=failed
net_qdisc_mobile=ok
net_qdisc_mobile=failed
net_qdisc=ok
net_handover_active=off
EOF
( _res_new="$TMP/res_in"; . "$TMP/dedupe.sh"; cat "$TMP/res_in" ) > "$TMP/res_out"
cat > "$TMP/res_want" <<'EOF'
net_congestion=ok
net_qdisc_mobile=failed
net_qdisc=ok
net_handover_active=off
EOF
cmp -s "$TMP/res_want" "$TMP/res_out" || fail 'dedupe must keep one line per key, worst first-seen order'

# --- diag pins: a qdisc FAIL must SHOW the raw tc line, not point at a file the
# report does not contain; and the congestion N/A label must name the right mechanism ---
DIAG="$ROOT/system/bin/asbdiag"
grep -qF '_qraw="$(grep -m1 "want=${_nw} "' "$DIAG" || fail 'diag does not capture the raw qdisc failure line'
grep -qF 'qdisc_failures.log: $_qraw' "$DIAG" || fail 'diag does not print the raw qdisc failure line'
grep -qF 'net_congestion_*)' "$DIAG" || fail 'diag N/A branch does not split congestion from qdisc'
grep -qF 'no per-route congctl on this kernel' "$DIAG" || fail 'congestion N/A wording missing'
grep -qF 'tc_binary_limited)' "$DIAG" || fail 'diag limited-tc branch missing'
grep -qF 'no working tc binary found' "$DIAG" || fail 'diag qdisc-unavailable wording missing'
grep -qF 'tc binary:' "$DIAG" || fail 'diag tc identity line missing'
cmp -s "$DIAG" "$ROOT/tools/asb_diag.sh" || fail 'asbdiag and tools/asb_diag.sh diverged'

# Executable fixture: the REAL _qraw/_qw extraction against a synthetic failure log.
n="$(grep -n '_qraw=' "$DIAG" | head -1 | cut -d: -f1)"
[ -n "$n" ] || fail 'cannot locate _qraw extraction in diag'
sed -n "${n},$((n + 1))p" "$DIAG" | sed "s|/data/adb/asb|$TMP/asb|g" > "$TMP/raw.sh"
grep -q '_qraw=' "$TMP/raw.sh" && grep -q '_qw=' "$TMP/raw.sh" || fail 'raw extraction block incomplete'
mkdir -p "$TMP/asb"
cat > "$TMP/asb/qdisc_failures.log" <<'EOF'
2026-09-22 11:02:26 if=rmnet_ipa0 want=fq_codel why=tc_error err=RTNETLINK answers: Invalid argument
2026-09-22 11:02:27 if=wlan0 want=fq_codel why=root_qdisc_owned err=RTNETLINK answers: Device or resource busy
EOF
( _nw=fq_codel; . "$TMP/raw.sh"; printf '%s\n%s\n' "$_qraw" "$_qw" ) > "$TMP/raw.out"
head -1 "$TMP/raw.out" | grep -q 'if=rmnet_ipa0 .*why=tc_error' || fail 'raw line not captured verbatim'
[ "$(sed -n 2p "$TMP/raw.out")" = 'tc_error' ] || fail 'why not derived from the raw line'

echo 'net verdict contract: OK'
