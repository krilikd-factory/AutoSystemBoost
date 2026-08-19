#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# The effective policy extension must remain a JSON-producing observer. It is
# intentionally executable on a host with neither Android properties nor ZRAM.
MODDIR="$ROOT" sh "$ROOT/tools/asb_effective_policy.sh" > "$TMP/effective_policy.json"
python3 - "$TMP/effective_policy.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

for section in ("audio", "network", "memory", "asb_overhead"):
    assert section in payload, f"missing {section}"

assert set(("dsp_enabled", "dsp_route_published", "a2dp_offload_requested")) <= set(payload["audio"])
assert set(("congestion_requested", "congestion_result", "qdisc_requested", "qdisc_result")) <= set(payload["network"])
assert set(("psi_some_avg10", "psi_full_avg10", "zram_algorithm", "zram_mm_stat")) <= set(payload["memory"])
PY

# Telemetry is evidence only. No new property, settings, sysctl or ZRAM writer
# may appear in the effective-policy producer or in the added logkit blocks.
! grep -Eq '^[[:space:]]*(setprop|resetprop|sysctl[[:space:]]+-w|settings[[:space:]]+put|swapoff|swapon|mkswap)[[:space:]]' \
  "$ROOT/tools/asb_effective_policy.sh"
! grep -Eq '^[[:space:]]*(setprop|resetprop|sysctl[[:space:]]+-w|settings[[:space:]]+put|swapoff|swapon|mkswap)[[:space:]]' \
  "$ROOT/tools/logkit/_asb_logkit_common.sh"

# The routine captures must disclose requested-versus-live state. A raw property
# alone is not sufficient because it cannot tell a refused kernel write from a
# setting that ASB never requested.
grep -q 'ASB audio / offload provenance' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'ASB network provenance' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'memory PSI (read-only' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'zram\.\$_zf' "$ROOT/tools/logkit/_asb_logkit_common.sh"
# Offload is evidence, not a decoder-location claim. A live AudioFlinger thread
# must be tied to observed BT playback before the report gives it stronger wording.
grep -q 'offload.state = unknown (conflicting AudioFlinger/property evidence)' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'route association unverified' "$ROOT/tools/logkit/_asb_logkit_common.sh"
! grep -q 'what the DSP or the CPU is decoding' "$ROOT/tools/asb_diag.sh"
# Reconnect recorder is full-day opt-in only, read-only, redacts addresses and
# always stops its background logcat pipeline through the finalizer.
grep -q 'ASB_BT_RECONNECT_TRACE:-0' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'lk_bt_reconnect_start' "$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q 'lk_bt_reconnect_stop' "$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q 'lk_bt_redact_addr' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q '<BT_ADDR>' "$ROOT/tools/logkit/_asb_logkit_common.sh"
printf '%s\n' 'BT AA:BB:CC:DD:EE:FF connected' | sh -c '. "$1/tools/logkit/_asb_logkit_common.sh"; lk_bt_redact_addr' sh "$ROOT" \
  | grep -qx 'BT <BT_ADDR> connected'
! grep -Eq '^[[:space:]]*(setprop|resetprop|sysctl[[:space:]]+-w|settings[[:space:]]+put|swapoff|swapon|mkswap)[[:space:]]' \
  "$ROOT/tools/logkit/asb_log_full_day.sh"

# Human and machine diagnostics must expose the same core facts, and the
# installed command must never drift from the source copy.
grep -q 'bt_a2dp_offload: requested=' "$ROOT/tools/asb_diag.sh"
grep -q 'AudioFlinger offload/compress observed during BT playback' "$ROOT/tools/asb_diag.sh"
grep -q 'DSP requested/applied gain' "$ROOT/tools/asb_diag.sh"
grep -q 'memory PSI (read-only)' "$ROOT/tools/asb_diag.sh"
grep -q '"audio"' "$ROOT/tools/asb_effective_policy.sh"
grep -q '"network"' "$ROOT/tools/asb_effective_policy.sh"
grep -q '"memory"' "$ROOT/tools/asb_effective_policy.sh"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag"
grep -q 'provenance snapshots' "$ROOT/docs/log_schemas.md"
grep -q 'bt_reconnect_events.txt' "$ROOT/docs/log_schemas.md"
grep -q 'ASB_BT_RECONNECT_TRACE=1' "$ROOT/docs/log_schemas.md"

printf '%s\n' 'PASS donor telemetry contract'
