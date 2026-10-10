#!/bin/sh
# V64 P0 regression contract: actual Trial transaction + thermal producer/consumer safety.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_v64_p0_contract.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- Thermal consensus/state/asbdiag contract --------------------------------------------
MET="$ROOT/src/asb_metrics.h"
GOV="$ROOT/src/asb_governor.c"
DIAG="$ROOT/tools/asb_diag.sh"
BIN_DIAG="$ROOT/system/bin/asbdiag"

cmp -s "$DIAG" "$BIN_DIAG" || fail "asbdiag copies differ"
grep -Fq 'thermal_control_source=' "$GOV" || fail "state misses thermal_control_source"
grep -Fq 'thermal_source_confidence=' "$GOV" || fail "state misses thermal_source_confidence"
grep -Fq 'thermal_peer_hi=' "$GOV" || fail "state misses thermal_peer_hi"
grep -Fq 'thermal_peer_lo=' "$GOV" || fail "state misses thermal_peer_lo"
grep -Fq 'thermal_peer_n=' "$GOV" || fail "state misses thermal_peer_n"
grep -Fq 'thermal_consensus=' "$GOV" || fail "state misses thermal_consensus"
grep -Fq "^thermal_control_source=" "$DIAG" || fail "diag reads stale thermal_cpu_type key"
grep -Fq "^thermal_source_confidence=" "$DIAG" || fail "diag reads stale thermal_src_conf key"
grep -Fq "^thermal_peer_hi=" "$DIAG" || fail "diag misses peer high"
grep -Fq "^thermal_peer_lo=" "$DIAG" || fail "diag misses peer low"
! grep -Fq 't->cpu_max_c = hi' "$MET" || fail "non-CPU peer still replaces CPU control"
# Board read must precede consensus; peer telemetry must reset for a no-peer tick.
board_line=$(grep -n 'Board must be read before consensus' "$MET" | head -1 | cut -d: -f1)
cons_line=$(grep -n 'Thermal consensus v2:' "$MET" | head -1 | cut -d: -f1)
[ -n "$board_line" ] && [ -n "$cons_line" ] && [ "$board_line" -lt "$cons_line" ] || fail "board read order is stale"
grep -Fq 'g_thermal_peer_n  = 0;' "$MET" || fail "peer count is not reset"
grep -Fq "g_thermal_consensus_note[0] = '\\0';" "$MET" || fail "consensus note is not reset"
pass "thermal state/diagnostic and non-CPU control contract"

# --- Trial transaction contract ------------------------------------------------------------
MOD="$TMP/mod"
STATE="$TMP/state"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE"
cp "$ROOT/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
cp "$ROOT/runtime/asb_trial.sh" "$MOD/runtime/asb_trial.sh"
cp "$ROOT/runtime/asb_apply_ledger.sh" "$MOD/runtime/asb_apply_ledger.sh"
chmod 0755 "$MOD/runtime/asb_config_safe.sh" "$MOD/runtime/asb_trial.sh"
TRIAL="sh $MOD/runtime/asb_trial.sh"
get_conf() { awk -F= -v k="$1" '$1 ~ /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*$/ {x=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); if(x==k){v=$2; sub(/#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/, "",v); print v; exit}}' "$MOD/config/governor.conf"; }

old_doze=$(get_conf doze_level)
case "$old_doze" in moderate) new_doze=stock ;; *) new_doze=moderate ;; esac
ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL start doze_level "$new_doze" 1 >/dev/null || fail "trial start rejected valid setting"
[ "$(get_conf doze_level)" = "$new_doze" ] || fail "trial start did not apply config"
[ -f "$STATE/trial/doze_level.trial" ] || fail "trial record absent after apply"
ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL confirm doze_level >/dev/null || fail "trial confirm failed"
[ -f "$STATE/trial/doze_level.kept" ] || fail "kept record absent after confirm"
[ "$(get_conf doze_level)" = "$new_doze" ] || fail "confirm changed accepted value"

old_gnss=$(get_conf gnss_trim)
case "$old_gnss" in 0) new_gnss=1 ;; *) new_gnss=0 ;; esac
ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL start gnss_trim "$new_gnss" 1 >/dev/null || fail "second trial start failed"
[ "$(get_conf gnss_trim)" = "$new_gnss" ] || fail "second trial did not apply"
ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL revert gnss_trim >/dev/null || fail "trial revert failed"
[ "$(get_conf gnss_trim)" = "$old_gnss" ] || fail "trial revert did not restore exact previous value"
[ ! -f "$STATE/trial/gnss_trim.trial" ] || fail "trial record removed only after failed/unfinished revert"

# Malformed/path-like keys are rejected before any state path is created.
if ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL start '../escaped' 1 1 >/dev/null 2>&1; then
  fail "path-like trial key accepted"
fi
[ ! -e "$STATE/escaped.trial" ] && [ ! -e "$STATE/escaped.before" ] || fail "path-like trial key escaped trial directory"
# Allowlisted key with invalid config scalar must not become an active trial.
if ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL start doze_level invalid 1 >/dev/null 2>&1; then
  fail "invalid config value accepted by trial"
fi
[ ! -f "$STATE/trial/doze_level.trial" ] || fail "failed start created active trial"
pass "Trial allowlist, apply/read-back, confirm, revert and path protection contract"

echo "ALL V64 P0 CONTRACTS PASSED"
