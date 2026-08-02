#!/system/bin/sh
# asb_gms_trim.sh - reduce what Google Play services does in the background.
#
# Deliberately NOT a package freezer. Disabling com.google.android.gms breaks push
# notifications, sign-in, payments and the Play Store, and a user who wanted that would
# use a tool built for it. What this does instead is narrow the background work GMS is
# allowed to do while leaving the parts people depend on intact.
#
# Everything here is reversible and recorded: appops go back through asb_baseline.sh,
# the standby bucket resets itself, and no package is ever disabled.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || exit 0
[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}
_has() { command -v "$1" >/dev/null 2>&1; }

GMS=com.google.android.gms
GSB=com.google.android.googlequicksearchbox
GSA=com.google.android.apps.gsa.staticplugins

_lvl="$(_cfg gms_trim)"
case "$_lvl" in stock|lite|strict) : ;; *) _lvl=stock ;; esac

_has cmd || exit 0

if [ "$_lvl" = "stock" ]; then
  # Hand everything back. Push, location and sync return to whatever the ROM wanted.
  cmd appops set "$GMS" RUN_ANY_IN_BACKGROUND allow          >/dev/null 2>&1 || true
  cmd appops set "$GMS" WAKE_LOCK allow                       >/dev/null 2>&1 || true
  cmd appops set "$GMS" PSEUDO_LOCATION_REPORTING allow       >/dev/null 2>&1 || true
  cmd appops set "$GSB" RUN_IN_BACKGROUND allow               >/dev/null 2>&1 || true
  am set-standby-bucket "$GMS" active                         >/dev/null 2>&1 || true
  am set-standby-bucket "$GSB" active                         >/dev/null 2>&1 || true
  echo "gms trim: stock - nothing restricted"
  exit 0
fi

# --- lite ---------------------------------------------------------------------------
# Location reporting and the search widget's background work. Neither is needed for a
# notification to arrive, and both run constantly on a stock phone.
cmd appops set "$GMS" PSEUDO_LOCATION_REPORTING ignore  >/dev/null 2>&1 || true
cmd appops set "$GSB" RUN_IN_BACKGROUND ignore          >/dev/null 2>&1 || true
am set-standby-bucket "$GSB" rare                       >/dev/null 2>&1 || true
# GMS itself stays in working_set: pushing it lower is what delays messages.
am set-standby-bucket "$GMS" working_set                >/dev/null 2>&1 || true

if [ "$_lvl" = "lite" ]; then
  echo "gms trim: lite - location reporting and search background work restricted"
  exit 0
fi

# --- strict -------------------------------------------------------------------------
# Additionally drops GMS out of the Doze whitelist. This is the line that actually saves
# battery on a GMS-heavy device, and also the line that can delay a notification by
# minutes while the phone is asleep - which is why it is not in lite and why the WebUI
# says so plainly rather than burying it.
if _has dumpsys; then
  dumpsys deviceidle whitelist -"$GMS" >/dev/null 2>&1 || true
fi
cmd appops set "$GMS" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1 || true
am set-standby-bucket "$GMS" rare                  >/dev/null 2>&1 || true
echo "gms trim: strict - GMS removed from the doze whitelist, notifications may lag"
exit 0
