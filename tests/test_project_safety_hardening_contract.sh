#!/bin/sh
# Contract: cross-directory hardening must not regress into silent broad boot mutations.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL project safety hardening: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden [$2] in $1" || true; }

UTILS="$ROOT/runtime/asb_utils.sh"
CORE="$ROOT/runtime/profile_core.sh"
POSTFS="$ROOT/post-fs-data.sh"
TWEAKS="$ROOT/runtime/asb_tweaks.sh"
SERVICE="$ROOT/service.sh"
AUDIO="$ROOT/runtime/asb_audio_apply.sh"
GUARD="$ROOT/runtime/asb_overlay_guard.sh"
ATTACH="$ROOT/src/DSP_AIDL/asb_dsp_attach.cpp"
REL="$ROOT/.github/workflows/build-release.yml"
DBG="$ROOT/.github/workflows/build-debug.yml"
ATTWF="$ROOT/.github/workflows/build-dsp-attach.yml"
WEB="$ROOT/webroot/index.html"
for f in "$UTILS" "$CORE" "$POSTFS" "$TWEAKS" "$SERVICE" "$AUDIO" "$GUARD" "$ATTACH" "$REL" "$DBG" "$ATTWF" "$WEB"; do
  [ -f "$f" ] || fail "missing $f"
done
for f in "$UTILS" "$CORE" "$POSTFS" "$TWEAKS" "$SERVICE" "$AUDIO" "$GUARD"; do
  sh -n "$f" || fail "shell syntax $f"
done

# All independent feature readers fail closed for missing/unknown state.
need "$UTILS" '[ -r "$MODDIR/features.conf" ] || return 1'
need "$CORE" '[ -r "$MODDIR/features.conf" ] || return 1'
need "$POSTFS" '[ -r "$MODDIR/features.conf" ] || return 1'
need "$TWEAKS" '[ -r "$_ftf" ] || return 1'
need "$UTILS" 'asb_bt_policy_enabled()'
need "$UTILS" 'asb_audio_boot_policy_enabled()'
need "$POSTFS" 'asb_bt_policy_enabled()'

# Every early/framework automatic Bluetooth policy path is behind the same explicit opt-in.
need "$POSTFS" 'if asb_bt_policy_enabled && command -v asb_device_pack_allows'
need "$SERVICE" 'asb_bt_policy_enabled && apply_bt_runtime'
need "$SERVICE" 'if asb_bt_policy_enabled; then'

# AUDIO=1 exposes manual controls, but no longer triggers broad boot-time HAL policy/deletes.
need "$SERVICE" 'audio runtime: default ROM policy retained'
need "$SERVICE" 'asb_audio_boot_policy_enabled && [ -f "$MODDIR/runtime/asb_audio_apply.sh" ]'
need "$AUDIO" '/data/adb/asb/audio_user_policy_enabled'
need "$AUDIO" 'if [ "$_mode" = "boot" ]; then'
need "$AUDIO" 'boot restore, no audioserver restart'
absent "$SERVICE" 'resetprop -p --delete audio.hal.output.suspend.supported'

# A malformed ODM bind manifest blocks its own overlay instead of falling through to mount.
need "$POSTFS" 'runtime/asb_overlay_guard.sh'
need "$GUARD" 'vendor_overlay_blocked'
need "$GUARD" 'forbidden_target'
need "$GUARD" 'missing_payload'
need "$GUARD" 'invalid_xml_payload'
need "$GUARD" 'invalid_json_payload'

# The attacher carries a source marker and every relevant CI path rejects a stale prebuilt.
need "$ATTACH" 'kAsbAttachBuildId'
need "$ATTACH" 'ASB_ATTACH_SRC_V64_GUARD_20260825'
need "$ATTWF" 'attacher binary does not contain source build marker'
need "$REL" 'ATT is stale for source marker'
need "$DBG" 'ATT is stale for source marker'
for w in "$REL" "$DBG"; do
  need "$w" 'tests/test_bt_safe_policy_contract.sh'
  need "$w" 'tests/test_v65_smart_thermal_cap_contract.sh'
  need "$w" 'tests/test_v65_efficiency_contract.sh'
  need "$w" 'tests/test_project_safety_hardening_contract.sh'
done

# Post-boot connectivity must be bounded and single-owner; Stock read-only telemetry must not
# create a three-second shell wakeup loop while a comparison page is open.
need "$SERVICE" 'wifi_reassert.lock'
need "$SERVICE" 'wait_path /sys/class/net/wlan0 10'
need "$SERVICE" 'while [ "$t" -lt 30 ]'
absent "$SERVICE" '[ $t -lt 120 ]'
need "$WEB" 'STOCK_TELEMETRY_MIN_INTERVAL_MS = 10000'
need "$WEB" 'if (!force && (now - _stockTelemetryLastMs) < STOCK_TELEMETRY_MIN_INTERVAL_MS) return;'

echo 'PASS project safety hardening contract'
