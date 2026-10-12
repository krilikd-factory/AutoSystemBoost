#!/bin/sh
# Runtime (fix135): asbdiag, the action screen and captures say what AudioFlinger is doing
# with ASB's effect - processing, idle, gone, or SUSPENDED because an app enabled an effect of
# its own on the same output (global effects yield to per-app ones). "Registered" alone could
# not tell a flat-sounding phone's four causes apart.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL dsp live state: $*" >&2; exit 1; }
. "$ROOT_DIR/runtime/asb_dsp_live.sh"
T="$(printf '\t')"

# Android 14-16 layout: the effect on a deep-buffer mixer, processing.
cat > "$TMP/active.txt" <<EOF
Output thread 0xb400007412b95080, name AudioOut_D, tid 14652, type 0 (MIXER):
  1 Effect Chains
${T}Effect ID 41:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00000   003   y          n       y       n
${T}${T}Descriptor:
${T}${T}- UUID: 7a8044a0-1a14-11e3-a184-0002a5d5c51b
Output thread 0xb4000073e985e540, name AudioOut_1D, tid 14691, type 0 (MIXER):
  1 Effect Chains
${T}Effect ID 59:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00000   003   y          n       y       n
${T}${T}Descriptor:
${T}${T}- UUID: a5b10001-7e55-4c60-9f21-415342445350
${T}${T}- TYPE: fe3199be-aed0-413f-87bb-11260eb63cf1
${T}${T}- name: ASB Loudness
EOF
out="$(asb_dsp_live_state "$TMP/active.txt")"
[ "$out" = "found=1 thread=AudioOut_1D type=MIXER session=0 state=ACTIVE enabled=y suspended=n others_enabled=0" ] \
  || fail "active: $out"
[ "$(asb_dsp_live_explain "$out")" = processing ] || fail "active explained as: $(asb_dsp_live_explain "$out")"

# Suspended: an app's own effect enabled on session 113 of the same output. An enabled
# per-app effect on ANOTHER output does not count.
cat > "$TMP/susp.txt" <<EOF
Output thread 0xa, name AudioOut_D, tid 1, type 0 (MIXER):
${T}Effect ID 7:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00097   003   y          n       y       n
${T}${T}- UUID: 0bed4300-ddd6-11db-8f34-0002a5d5c51b
Output thread 0xb, name AudioOut_1D, tid 2, type 1 (DIRECT):
${T}Effect ID 60:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00113   003   y          n       y       n
${T}${T}- UUID: ce772f20-847d-11df-bb17-0002a5d5c51b
${T}Effect ID 59:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00000   000   y          n       y       y
${T}${T}- UUID: a5b10001-7e55-4c60-9f21-415342445350
EOF
out="$(asb_dsp_live_state "$TMP/susp.txt")"
[ "$out" = "found=1 thread=AudioOut_1D type=DIRECT session=0 state=IDLE enabled=y suspended=y others_enabled=1" ] \
  || fail "suspended: $out"
asb_dsp_live_explain "$out" | grep -q '^SUSPENDED by AudioFlinger' || fail "suspension not named"

# Older header without Internal/Suspended: parsed by name, unknown columns say "?".
cat > "$TMP/old.txt" <<EOF
Output thread 0xc, name AudioOut_15, tid 3, type 0 (MIXER):
${T}Effect ID 12:
${T}${T}Session Status State Engine:
${T}${T}00000   000    003   0xb400007
${T}${T}- UUID: a5b10001-7e55-4c60-9f21-415342445350
EOF
out="$(asb_dsp_live_state "$TMP/old.txt")"
[ "$out" = "found=1 thread=AudioOut_15 type=MIXER session=0 state=ACTIVE enabled=? suspended=? others_enabled=0" ] \
  || fail "older layout: $out"

# Released by the attach daemon (or never attached).
grep -v 'a5b10001' "$TMP/active.txt" > "$TMP/none.txt"
[ "$(asb_dsp_live_state "$TMP/none.txt")" = found=0 ] || fail "absent instance reported"
asb_dsp_live_explain found=0 | grep -q '^no live instance' || fail "absent instance not explained"

# Wired into asbdiag (both copies), the action screen and the capture.
for f in "$ROOT_DIR/tools/asb_diag.sh" "$ROOT_DIR/system/bin/asbdiag"; do
  grep -q 'asb_dsp_live_state' "$f" || fail "${f##*/} does not show the live effect"
done
grep -q 'T_A_SUSP' "$ROOT_DIR/action.sh" || fail "action screen silent about a suspended effect"
grep -q 'asb.dsp.effect_live' "$ROOT_DIR/tools/logkit/_asb_logkit_common.sh" || fail "captures do not record the live effect"
grep -q 'asb.dsp.heat' "$ROOT_DIR/tools/logkit/_asb_logkit_common.sh" || fail "captures do not record the heat decision"
for f in "$ROOT_DIR"/runtime/i18n/action_*.sh; do
  grep -q '^T_A_HEAT=' "$f" && grep -q '^T_A_SUSP=' "$f" || fail "heat/suspend lines missing in ${f##*/}"
done
echo "PASS dsp live state: processing / idle / released / suspended told apart, in every report"
