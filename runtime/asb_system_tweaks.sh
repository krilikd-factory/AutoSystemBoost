#!/system/bin/sh
# asb_system_tweaks.sh - small system-behaviour settings that belong to the user.
#
# Both of these were already being set unconditionally somewhere in service.sh. Turning
# them into settings is not new capability - it is admitting that the module had an
# opinion the user never agreed to, and letting them disagree.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || exit 0
[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}
_put() {
  # asb_settings_put records the original before the first write, which is what makes
  # "stock" recoverable at all. Fall back to a plain write if the baseline helper is not
  # loaded, rather than silently doing nothing.
  if command -v asb_settings_put >/dev/null 2>&1; then
    asb_settings_put "$1" "$2" "$3"
  else
    settings put "$1" "$2" "$3" >/dev/null 2>&1 || true
  fi
}

_changed=""

# --- phantom process monitor ---------------------------------------------------------
case "$(_cfg phantom_procs)" in
  relaxed)
    _put global settings_enable_monitor_phantom_procs false
    _changed="${_changed}phantom=relaxed "
    ;;
  strict)
    _put global settings_enable_monitor_phantom_procs true
    _changed="${_changed}phantom=strict "
    ;;
  *) : ;;   # stock: leave whatever is there
esac

# --- lock screen shortcuts -----------------------------------------------------------
# Two keys because OEMs disagree on which one is authoritative, and writing the one that
# does nothing is cheaper than probing which is which.
case "$(_cfg lockscreen_shortcuts)" in
  clean)
    _put secure lockscreen_left_button_enabled 0
    _put secure lockscreen_right_button_enabled 0
    _changed="${_changed}lockscreen=clean "
    ;;
  *) : ;;
esac

[ -n "$_changed" ] && echo "system tweaks: $_changed"
exit 0
