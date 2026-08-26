#!/bin/sh
# Contract: full-day telemetry improvements must remain observer-only and phase-stable.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOGKIT="$ROOT/tools/logkit/asb_log_full_day.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

need() { grep -Fq -- "$2" "$1" >/dev/null || { echo "FAIL logkit capture-quality: missing [$2]" >&2; exit 1; }; }

[ -f "$LOGKIT" ] || { echo "FAIL logkit capture-quality: missing full-day logkit" >&2; exit 1; }
sh -n "$LOGKIT"

# Extract the standalone debounce function: this avoids sourcing a device-only recorder.
sed -n '/^lk_stabilize_charging_phase() {/,/^}/p' "$LOGKIT" > "$TMP/debounce.sh"
[ -s "$TMP/debounce.sh" ] || { echo "FAIL logkit capture-quality: cannot extract debounce helper" >&2; exit 1; }
. "$TMP/debounce.sh"

LK_CHG_PHASE_STABLE=""
LK_CHG_IDLE_CANDIDATE_SINCE=0
LK_CHG_IDLE_DEBOUNCE_S=45
LK_CHG_IDLE_COALESCED=0
lk_stabilize_charging_phase charging_active 100
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: first active sample" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 115
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: short idle must stay active" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 145
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: debounce must remain bounded" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 160
[ "$LK_CHG_PHASE_OUT" = charging_idle ] || { echo "FAIL logkit capture-quality: sustained idle must commit" >&2; exit 1; }
lk_stabilize_charging_phase charging_active 161
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: visible screen use must be immediate" >&2; exit 1; }
[ "$LK_CHG_IDLE_COALESCED" -ge 2 ] || { echo "FAIL logkit capture-quality: coalesced counter" >&2; exit 1; }

need "$LOGKIT" 'LK_SCREENOFF_LONGEST_S=0'
need "$LOGKIT" '----- CAPTURE VALIDITY -----'
need "$LOGKIT" 'night verdict: unavailable'
need "$LOGKIT" '----- CAP OWNERSHIP VERDICT -----'
need "$LOGKIT" 'Native vendor holddown/detente'
need "$LOGKIT" 'throttle samples logged: $_tc (poll observations, not independent clamp incidents)'
need "$LOGKIT" 'continuous clamp periods (new period after >180s gap or owner change):'
need "$LOGKIT" 'owner=%-8s duration=%4d min samples=%d'
need "$LOGKIT" '----- CHARGING-IDLE AWAKE VERDICT -----'
need "$LOGKIT" 'ASB does not alter charge current or kill apps automatically.'
need "$LOGKIT" 'lk_charge_idle_observe "$_phase"'

# New verdict code must remain read-only: no global runtime-policy writes are allowed here.
if grep -nE 'setprop|settings[[:space:]]+put|sysctl[[:space:]]+-w|swapoff|svc[[:space:]]+power|reboot' "$LOGKIT" >/dev/null 2>&1; then
  echo "FAIL logkit capture-quality: full-day telemetry gained a policy write" >&2
  exit 1
fi

echo 'PASS logkit capture-quality telemetry contract'
