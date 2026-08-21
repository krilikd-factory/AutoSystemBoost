#!/system/bin/sh
# asb_policy_preview.sh - answer "what would this actually do here" before writing it.
#
# V64 P0-4. On a multi-device module the most expensive failure is not a bad value, it is
# a setting that does nothing on this particular phone while the UI happily shows it as
# on. The user then guesses from an absent effect, and every guess costs a support thread.
#
# The preview resolves a requested change against THIS device and reports what would
# happen: which writer takes it, what the resolved value becomes after per-device bounds,
# whether the capability exists at all, what still overrides it, and what restart is
# needed. It writes nothing.
#
# Usage: asb_policy_preview.sh <key> <value>

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE="${ASB_CONFIG_STATE:-/data/adb/asb}"

_k="$1"; _v="$2"
[ -n "$_k" ] || { echo "usage: asb_policy_preview.sh KEY VALUE" >&2; exit 1; }

_cur="$(grep -E "^[[:space:]]*$_k=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
_bounds="$STATE/device_bounds.env"

echo "requested: $_k = $_v"
[ -n "$_cur" ] && echo "current:   $_cur"

# --- capability ------------------------------------------------------------------------
#
# Checked against the device, not against a table of model names. A node that is absent
# here is absent whatever the phone calls itself.
_cap="applicable on this device"
_owner=""
_resolved=""
_override=""
_restart="none"

case "$_k" in
  perf_ceiling_pct)
    _owner="user_cap lease, applied over the profile envelope"
    case "$_v" in ''|*[!0-9]*) echo "result:    rejected - not a number"; exit 1 ;; esac
    if [ "$_v" -lt 60 ] || [ "$_v" -gt 100 ]; then
      echo "resolved:  clamped to 60..100"
    fi
    _p0max="$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null)"
    if [ -n "$_p0max" ]; then
      # Show the arithmetic on this device's real ceiling, not on a reference number:
      # "85%" means nothing until you know 85% of what.
      _ex=$(( _p0max * ${_v:-100} / 100 ))
      _resolved="profile envelope x ${_v}% - little cluster ceiling would top out near $(( _ex / 1000 )) MHz"
    fi
    _override="platform thermal safety still overrides; floors unchanged"
    _restart="applies on the next governor tick"
    ;;
  doze_level|doze_trim_whitelist)
    command -v dumpsys >/dev/null 2>&1 || _cap="not applicable - dumpsys unavailable"
    _owner="asb_doze_apply.sh"
    _override="Android defers network, jobs, sync and ordinary alarms in Doze by design"
    _resolved="affects the learned sleep window only"
    _restart="takes effect at the next screen-off cycle"
    ;;
  gnss_trim)
    command -v appops >/dev/null 2>&1 || _cap="not applicable - appops unavailable on this ROM"
    _owner="asb_gnss_trim.sh"
    _resolved="coarse accuracy for cached, user-installed apps while the screen is off"
    _override="never touches maps, fitness, emergency or foreground apps"
    ;;
  wakelock_action)
    [ -r /sys/kernel/debug/wakeup_sources ] || _cap="degraded - debugfs unreadable, falls back to batterystats"
    _owner="asb_wakelock_watch.sh"
    _resolved="restricted standby bucket after 45+ min screen-off"
    _override="kernel and system sources are never touched"
    ;;
  sustained_temp_enter)
    _owner="governor thermal policy"
    _tf="$STATE/thermal_floor"
    if [ -r "$_tf" ]; then
      _fl="$(cat "$_tf" 2>/dev/null)"
      # This is the one that surprises people: they set 60 and the module uses 61.
      [ -n "$_fl" ] && [ "${_v:-0}" -lt "${_fl:-0}" ] 2>/dev/null && \
        _resolved="would be raised to ${_fl}C - this device idles too warm for ${_v}C"
    fi
    [ -z "$_resolved" ] && _resolved="used as requested"
    _override="vendor thermal HAL still applies its own limits"
    ;;
  *)
    _owner="config value, read by whichever writer owns it"
    _resolved="no device-specific resolution for this key"
    ;;
esac

echo "capability: $_cap"
[ -n "$_owner" ]    && echo "owner:     $_owner"
[ -n "$_resolved" ] && echo "resolved:  $_resolved"
[ -n "$_override" ] && echo "overrides: $_override"
echo "restart:   $_restart"

# --- evidence from this device -----------------------------------------------------------
#
# If the ledger has seen this key before, its history is worth more than any prediction.
_led="$STATE/apply_ledger"
if [ -s "$_led" ]; then
  _last="$(awk -F'|' -v k="$_k" '$3==k {r=$7; w=$8} END{if(r) print r "|" w}' "$_led" 2>/dev/null)"
  if [ -n "$_last" ]; then
    echo "last time: $(echo "$_last" | cut -d'|' -f1)$(echo "$_last" | cut -d'|' -f2 | sed 's/^/ - /')"
  fi
fi
exit 0
