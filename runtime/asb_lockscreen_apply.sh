#!/system/bin/sh
# asb_lockscreen_apply.sh - wake straight to the launcher while Android already considers
# the device unlocked.
#
# THE REQUEST
#
# Android's "Lock after screen timeout" keeps the device unlocked for a grace period after the
# screen goes off.
#
# WHY THIS IS DONE THE CAREFUL WAY
#
# The obvious implementation - `locksettings set-disabled true`, or clearing
# lockscreen.disabled - removes the lock outright.
# This script never changes WHETHER the device locks or WHEN; Android's own timeout stays the
# single authority.
#
#   lockscreen_skip_delayed = off | on
#
# Usage: asb_lockscreen_apply.sh

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE="/data/adb/asb/lockscreen_prev"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}

_want="$(_cfg lockscreen_skip_delayed)"
case "$_want" in on) : ;; *) _want=off ;; esac

# --- the two facts that decide whether this is even meaningful -------------------------
#
# lockscreen.password_type / a set credential: with no secure lock there is no swipe to
# skip and nothing to protect, so the setting is a no-op rather than a silent behaviour
# change on someone who deliberately runs without a lock.
_has_lock=0
if command -v locksettings >/dev/null 2>&1; then
  case "$(locksettings get-disabled 2>/dev/null)" in
    false) _has_lock=1 ;;
  esac
fi
[ "$_has_lock" = "0" ] && [ -n "$(settings get secure lockscreen.password_type 2>/dev/null | grep -vE '^(null|0)$')" ] && _has_lock=1

# The grace period itself. Zero means "lock immediately", and skipping the lockscreen then
# would mean skipping a lock the user asked to be instant - the exact thing to refuse.
_grace="$(settings get secure lock_screen_lock_after_timeout 2>/dev/null)"
case "$_grace" in ''|null|*[!0-9]*) _grace=0 ;; esac

if [ "$_want" = "on" ]; then
  if [ "$_has_lock" = "0" ]; then
    echo "lockscreen: no secure lock set - nothing to skip, leaving everything alone"
    exit 0
  fi
  if [ "$_grace" -le 0 ] 2>/dev/null; then
    echo "lockscreen: 'Lock after screen timeout' is immediate - refusing to skip an instant lock"
    echo "            set a delay in Settings > Security first, then enable this again"
    exit 0
  fi
fi

# --- apply ------------------------------------------------------------------------------
#
# lockscreen.disabled is the flag OxygenOS's keyguard consults for the "show the swipe"
# decision. Crucially it does NOT clear the credential, and the framework re-locks on the
# timeout regardless - so the grace window remains exactly as long as Android says.
#
# The previous value is stored before the first change so that turning the setting off, or
# uninstalling, puts back what the device had rather than a guess.
if [ "$_want" = "on" ]; then
  if [ ! -f "$STATE" ]; then
    mkdir -p /data/adb/asb 2>/dev/null
    printf 'PREV_LS_DISABLED=%s\n' "$(settings get secure lockscreen.disabled 2>/dev/null)" \
      > "$STATE" 2>/dev/null
  fi
  settings put secure lockscreen.disabled 1 >/dev/null 2>&1
  echo "lockscreen: swipe skipped while the ${_grace}ms grace period is active"
  echo "            the lock still engages on its own when that expires"
else
  if [ -f "$STATE" ]; then
    _prev="$(grep -E '^PREV_LS_DISABLED=' "$STATE" 2>/dev/null | head -1 | sed 's/.*=//')"
    case "$_prev" in
      ''|null) settings delete secure lockscreen.disabled >/dev/null 2>&1 ;;
      *)       settings put secure lockscreen.disabled "$_prev" >/dev/null 2>&1 ;;
    esac
    rm -f "$STATE" 2>/dev/null
    echo "lockscreen: restored to the value the device had before"
  else
    echo "lockscreen: off (nothing had been changed)"
  fi
fi
exit 0
