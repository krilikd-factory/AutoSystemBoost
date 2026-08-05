#!/system/bin/sh
# asb_athena_apply.sh - switch off OxygenOS's own background-app killer.
#
# WHAT ATHENA IS
#
# com.oplus.athena is OnePlus/OPPO's resource manager. AthenaService is the component that
# decides which background apps get killed and when. It is why a messenger left in the
# background stops delivering notifications until it is reopened - a complaint that has
# nothing to do with Android's own Doze and cannot be fixed by whitelisting the app.
#
#   athena_service = stock | off
#
#   stock  untouched. Whatever state the phone is in stays.
#   off    only the AthenaService COMPONENT is disabled. The package stays enabled.
#
# WHY THE COMPONENT AND NOT THE PACKAGE
#
# Disabling com.oplus.athena wholesale takes out thermal reporting and several settings
# panels with it, and on some builds Settings force-closes when you open Battery. Turning
# off the one component that does the killing leaves the rest of the package running.
#
# ALWAYS REVERSIBLE
#
# The pre-change state is recorded before the first write and restored when the setting goes
# back to stock or the module is removed. If ASB never disabled it - because the user did,
# or an older build did - there is no record and nothing is re-enabled: undoing somebody
# else's deliberate choice is worse than leaving it alone.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE="/data/adb/asb/athena_prev"
COMP="com.oplus.athena/com.oplus.athena.client.AthenaService"
PKG="com.oplus.athena"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}
_has() { command -v "$1" >/dev/null 2>&1; }

_want="$(_cfg athena_service)"
case "$_want" in off) : ;; *) _want=stock ;; esac

if ! _has pm; then
  echo "athena: pm unavailable, nothing done"
  exit 0
fi

# Not present on non-OPPO builds and on some regions. Saying so beats a silent no-op.
if ! pm list packages 2>/dev/null | grep -q "^package:$PKG$"; then
  echo "athena: $PKG is not on this device - nothing to switch off"
  exit 0
fi

if [ "$_want" = "off" ]; then
  if [ ! -f "$STATE" ]; then
    mkdir -p /data/adb/asb 2>/dev/null
    # Record that ASB is the one making the change, so the restore knows it may undo it.
    printf 'ASB_DISABLED_COMPONENT=1\n' > "$STATE" 2>/dev/null
  fi
  if pm disable "$COMP" >/dev/null 2>&1; then
    echo "athena: AthenaService disabled - background apps stop being killed by it"
    echo "        the rest of the package keeps running (thermal, settings panels)"
  else
    # Some builds guard the component. Say so rather than leaving the card looking applied.
    rm -f "$STATE" 2>/dev/null
    echo "athena: this ROM refused to disable the component - nothing was changed"
  fi
else
  if [ -f "$STATE" ]; then
    pm enable "$COMP" >/dev/null 2>&1
    rm -f "$STATE" 2>/dev/null
    echo "athena: AthenaService re-enabled (back to how it was before ASB touched it)"
  else
    echo "athena: stock (ASB has not changed it)"
  fi
fi
exit 0
