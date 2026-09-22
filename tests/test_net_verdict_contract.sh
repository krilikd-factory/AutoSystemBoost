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

echo 'net verdict contract: OK'
