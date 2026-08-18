#!/system/bin/sh
# asb_intent.sh — user-facing intent presets over validated existing knobs.
# No direct config edits: every change is a safe-writer transaction.
set -eu

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
WRITER="$MODDIR/runtime/asb_config_safe.sh"
STATE="${ASB_INTENT_STATE:-/data/adb/asb/current_intent}"

[ -x "$WRITER" ] || { echo "asb_intent: config writer unavailable: $WRITER" >&2; exit 1; }

apply() {
  _intent="$1"
  case "$_intent" in
    daily)
      sh "$WRITER" set-many perf_ceiling_pct 90 smart_battery_bias 0 thermal_budget_enable 1 shadow_mode 0
      ;;
    camera)
      sh "$WRITER" set-many camera_hold_enable 1 perf_ceiling_pct 100 smart_battery_bias 0 thermal_budget_enable 1 shadow_mode 0
      ;;
    game)
      sh "$WRITER" set-many perf_ceiling_pct 100 smart_battery_bias 0 thermal_budget_enable 1 shadow_mode 0
      ;;
    travel)
      sh "$WRITER" set-many perf_ceiling_pct 75 smart_battery_bias 400 thermal_budget_enable 1 shadow_mode 0
      ;;
    charging)
      sh "$WRITER" set-many perf_ceiling_pct 85 smart_battery_bias 0 thermal_budget_enable 1 shadow_mode 0
      ;;
    observe)
      sh "$WRITER" set shadow_mode 1
      ;;
    *)
      echo 'usage: asb_intent.sh [list|status|apply daily|camera|game|travel|charging|observe]' >&2
      exit 2
      ;;
  esac
  mkdir -p "${STATE%/*}" 2>/dev/null || true
  printf '%s\n' "$_intent" > "$STATE.tmp.$$"
  mv -f "$STATE.tmp.$$" "$STATE"
  echo "intent=$_intent applied"
}

case "${1:-list}" in
  list)
    cat <<'EOF'
daily     balanced interactive use; modest ceiling, adaptive budget on
camera    preserve recording deadlines; camera lease plus adaptive budget
game      target performance; adaptive budget protects sustained thermals
travel    battery-first; lower ceiling and confidence-aware battery bias
charging  restrained interactive use while charging
observe   shadow mode; calculate/log decisions without policy writes
EOF
    ;;
  status) cat "$STATE" 2>/dev/null || echo 'daily (default)' ;;
  apply) [ "$#" -eq 2 ] || { echo 'usage: asb_intent.sh apply INTENT' >&2; exit 2; }; apply "$2" ;;
  *) echo 'usage: asb_intent.sh [list|status|apply INTENT]' >&2; exit 2 ;;
esac
