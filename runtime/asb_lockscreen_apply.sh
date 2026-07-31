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

# Settings on some devices cannot be reached through the `settings` command at all - a
# OnePlus 15R returned "Failure calling service settings" for every call while still
# exiting 0, so writes looked successful and reads returned the error text as a value.
# This helper falls back to the content provider and verifies what it wrote.
[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}

# Verdict for the WebUI. Everything below prints a reason, and every caller sends that to
# /dev/null - so a refusal was invisible and the card looked like it had worked. A OnePlus
# 15R owner reported "it does not work" with no way to find out why, which was fair.
RESULT="/data/adb/asb/lockscreen_result"
_verdict() {
  mkdir -p /data/adb/asb 2>/dev/null
  printf 'lockscreen_skip_delayed=%s\n' "$1" > "$RESULT" 2>/dev/null
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
[ "$_has_lock" = "0" ] && [ -n "$(asb_set_get secure lockscreen.password_type | grep -vE '^0$')" ] && _has_lock=1

# Third signal: the credential files themselves.
#
# Needed because the first two can be unavailable at once - a OnePlus 15R has no
# locksettings binary, and lockscreen.password_type is legacy and often unset on modern
# Android even when a PIN is set. With only those two the script refuses with "no secure
# lock" on a phone that plainly has one - a wrong answer dressed up as a safety check.
# Gatekeeper writes these files when a credential is enrolled, and root can see them.
if [ "$_has_lock" = "0" ]; then
  for _gk in /data/system/gatekeeper.password.key \
             /data/system/gatekeeper.pattern.key \
             /data/system/locksettings.db; do
    [ -s "$_gk" ] || continue
    case "$_gk" in
      *locksettings.db)
        # This db exists on every device; only a credential row means a lock is set.
        grep -aqE 'lockscreen.password_type|sp-handle' "$_gk" 2>/dev/null && _has_lock=1
        ;;
      *) _has_lock=1 ;;
    esac
    [ "$_has_lock" = "1" ] && break
  done
fi

# The grace period itself. Zero means "lock immediately", and skipping the lockscreen then
# would mean skipping a lock the user asked to be instant - the exact thing to refuse.
_grace="$(asb_set_get secure lock_screen_lock_after_timeout)"
case "$_grace" in ''|null|*[!0-9]*) _grace=0 ;; esac

if [ "$_want" = "on" ] && command -v asb_set_ok >/dev/null 2>&1 && ! asb_set_ok; then
  echo "lockscreen: Settings cannot be reached on this device at all - neither the"
  echo "            settings command nor the content provider answered. This is not"
  echo "            specific to this tweak; every setting-based feature is affected."
  _verdict noservice
  exit 0
fi

if [ "$_want" = "on" ]; then
  if [ "$_has_lock" = "0" ]; then
    echo "lockscreen: no secure lock set - nothing to skip, leaving everything alone"
    _verdict nolock
    exit 0
  fi
  if [ "$_grace" -le 0 ] 2>/dev/null; then
    echo "lockscreen: 'Lock after screen timeout' is immediate - refusing to skip an instant lock"
    echo "            set a delay in Settings > Security first, then enable this again"
    _verdict nograce
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
    printf 'PREV_LS_DISABLED=%s\n' "$(asb_set_get secure lockscreen.disabled)" \
      > "$STATE" 2>/dev/null
  fi
  asb_set_put secure lockscreen.disabled 1
  # Read it back. Some ROMs accept the write and drop the value, or guard the key entirely -
  # and a setting that reports success without checking is how "it does not work" reports
  # start. Say which of the two happened.
  # Stored is not the same as effective.
  #
  # lockscreen.disabled is a legacy Settings.Secure key. On modern Android the keyguard asks
  # LockPatternUtils, which decides from the enrolled credential and ignores this key
  # entirely once a PIN or pattern is set - so the value stores perfectly and changes
  # nothing. A OnePlus 15R on Android 15 reported exactly that: written, read back, still
  # swiping. Storing it and calling that success is the wrong answer.
  #
  # There is no supported setting that dismisses the keyguard while a trust agent holds
  # trust. Extend Unlock (Отложенная блокировка) grants trust, and AOSP responds by making
  # the lockscreen swipe-only rather than skipping it - that is the design, not a bug. Doing
  # better needs a framework hook, which is outside what a property-and-settings module can
  # honestly claim to do.
  _ls_sdk="$(getprop ro.build.version.sdk 2>/dev/null)"
  case "$_ls_sdk" in ''|*[!0-9]*) _ls_sdk=0 ;; esac
  if [ "$(asb_set_get secure lockscreen.disabled)" = "1" ] && [ "$_ls_sdk" -lt 30 ] 2>/dev/null; then
    _verdict ok
    echo "lockscreen: swipe skipped while the ${_grace}ms grace period is active"
    echo "            the lock still engages on its own when that expires"
  elif [ "$_ls_sdk" -ge 30 ] 2>/dev/null; then
    # Put it straight back: leaving a stored value that does nothing is worse than not
    # writing it, because the next reader cannot tell it is inert.
    asb_set_del secure lockscreen.disabled
    _verdict unsupported
    echo "lockscreen: not possible on Android $_ls_sdk"
    echo "            the keyguard ignores this setting once a PIN is enrolled, and no"
    echo "            supported setting dismisses it while Extend Unlock holds trust -"
    echo "            trust makes the lockscreen swipe-only by design, not skipped"
  else
    _verdict rejected
    echo "lockscreen: this ROM refused the setting - the value did not stick"
    echo "            nothing was changed; your lock behaves exactly as before"
  fi
else
  if [ -f "$STATE" ]; then
    _prev="$(grep -E '^PREV_LS_DISABLED=' "$STATE" 2>/dev/null | head -1 | sed 's/.*=//')"
    case "$_prev" in
      ''|null) asb_set_del secure lockscreen.disabled ;;
      *)       asb_set_put secure lockscreen.disabled "$_prev" ;;
    esac
    rm -f "$STATE" 2>/dev/null
    _verdict off
    echo "lockscreen: restored to the value the device had before"
  else
    _verdict off
    echo "lockscreen: off (nothing had been changed)"
  fi
fi
exit 0
