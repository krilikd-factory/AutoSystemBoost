#!/usr/bin/env sh
# P0 provenance contract: all fixtures stay under mktemp; do not create /data/adb.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
WRITER="$ROOT_DIR/runtime/asb_config_safe.sh"
POLICY="$ROOT_DIR/tools/asb_effective_policy.sh"
STATE_SRC="$ROOT_DIR/src/asb_governor.c"
METRICS_SRC="$ROOT_DIR/src/asb_metrics.h"
SCREENOFF="$ROOT_DIR/runtime/asb_screenoff_class.sh"
LOGKIT="$ROOT_DIR/tools/logkit/_asb_logkit_common.sh"
WEBUI="$ROOT_DIR/webroot/index.html"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_p0_contract.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
need_line() { grep -qx "$2" "$1" || fail "missing '$2' in $1"; }
need_text() { grep -Fq "$2" "$1" || fail "missing text '$2' in $1"; }

# Native producer: consumers must never invent these fields independently.
need_text "$STATE_SRC" 'startup_quarantined=%lu'
need_text "$STATE_SRC" 'thermal_control_source=\"%s\"'
need_text "$STATE_SRC" 'thermal_source_confidence=%d'
need_text "$STATE_SRC" 'thermal_rejected_type=\"%s\"'
need_text "$STATE_SRC" 'thermal_rejected_raw=%d'
need_text "$STATE_SRC" 'if (m->bat.charging)'
need_text "$METRICS_SRC" 'ASB_SOCD_MAX_ABOVE_PEERS_C 25'
need_text "$METRICS_SRC" 'g_thermal_cpu_zone = fallback_zone'
need_text "$METRICS_SRC" 'g_thermal_cpu_fallback_zone = -1'
need_text "$METRICS_SRC" 'strcmp(g_thermal_cpu_type, "socd") == 0'

# The classifier may record its own observation but must not write a system node or setting.
if grep -nE '>[[:space:]]*/sys/|settings[[:space:]]+put|setprop[[:space:]]' "$SCREENOFF" >/dev/null; then
  fail "screen-off classifier contains a system-policy write"
fi

# Thermal slider transaction must keep its linked ceiling coherent when the user
# selects 69–70°C above the previous Smart ceiling. The writer validates the staged
# file as a whole, so WebUI must publish the matching value in the same set-many call.
need_text "$WEBUI" "shQuote('sustained_temp_ceiling') + ' ' + shQuote(val)"

# Transaction writer must use the injected state path, not a hard-coded production location.
need_text "$WRITER" 'ASB_TXN="${ASB_CONFIG_TXN:-$STATE/config_last_txn}"'
if grep -Fq 'ASB_TXN="/data/adb/asb/config_last_txn"' "$WRITER"; then
  fail "writer hard-codes production transaction path"
fi

MOD="$TMP/module"
CFG_STATE="$TMP/config-state"
RUNTIME_STATE="$TMP/runtime.state"
mkdir -p "$MOD/config" "$CFG_STATE"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"

MODDIR="$MOD" ASB_CONFIG_STATE="$CFG_STATE" sh "$WRITER" set sustained_temp_enter 60 >/dev/null
TXN="$CFG_STATE/config_last_txn"
[ -f "$TXN" ] || fail "isolated writer did not create transaction record"
need_line "$TXN" 'result_class=success'
need_line "$TXN" 'reason=applied'
need_line "$TXN" 'key=sustained_temp_enter'
need_line "$TXN" 'reload_accepted=not_requested'
grep -Eq '^pre_epoch=[0-9]+$' "$TXN" || fail "transaction missing numeric pre_epoch"
grep -Eq '^post_epoch=[0-9]+$' "$TXN" || fail "transaction missing numeric post_epoch"

printf '%s\n' \
  'thermal_control_source="cpu-1-1-0"' \
  'thermal_control_zone=7' \
  'thermal_source_confidence=1' \
  'thermal_rejected_type="socd"' \
  'thermal_rejected_raw=92000' \
  'startup_quarantined=4' > "$RUNTIME_STATE"
MODDIR="$MOD" ASB_CONFIG_STATE="$CFG_STATE" ASB_RUNTIME_STATE="$RUNTIME_STATE" \
  sh "$POLICY" > "$TMP/effective_policy.json"
command -v jq >/dev/null 2>&1 || fail "jq is required for effective-policy JSON contract"
jq -e '.thermal_provenance == {"control_source":"cpu-1-1-0","control_zone":7,"confidence":1,"rejected_type":"socd","rejected_raw":92000,"startup_quarantined":4}' "$TMP/effective_policy.json" >/dev/null \
  || fail "thermal provenance JSON object is invalid or incomplete"
jq -e '.config_last_txn.result_class == "success" and .config_last_txn.reason == "applied" and .config_last_txn.reload_accepted == "not_requested"' "$TMP/effective_policy.json" >/dev/null \
  || fail "config transaction JSON object is invalid or incomplete"

# logkit must retain thermal confidence/rejection in its transition trace and snapshots.
need_text "$LOGKIT" '"thermal_src_conf"'
need_text "$LOGKIT" '"thermal_rejected_type"'
need_text "$LOGKIT" 'config_last_txn (writer provenance)'

echo "PASS P0 provenance contract"
