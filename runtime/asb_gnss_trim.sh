#!/system/bin/sh
# asb_gnss_trim.sh - stop GPS running for apps the user has already left.
#
# A field log from a OnePlus Ace 5 shows where this matters: gnss=55.6 mAh over 44 minutes,
# of which gnss:cached=53.3 mAh over 42 minutes. "cached" is Android's own word for a
# process that is no longer foreground and no longer doing anything the user asked for -
# the app was closed and its location request outlived it. That is 96% of the GPS drain in
# that capture, and it is exactly the class of waste a battery module should catch: nobody
# chose it, nobody benefits from it, and it costs more than most of what the module tunes.
#
# What this is NOT: it does not touch location while an app is in the foreground, and it
# does not revoke permissions. Navigation keeps working, fitness tracking keeps working,
# and an app the user is looking at is never affected.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE=/data/adb/asb/gnss_restricted
[ -f "$CONF" ] || exit 0

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}
_has() { command -v "$1" >/dev/null 2>&1; }

case "$(_cfg gnss_trim)" in
  1|on|true) : ;;
  *)
    # Turned off: release anything we restricted, then stop.
    if [ -f "$STATE" ] && _has appops; then
      while IFS= read -r _p; do
        # Restore the recorded mode, not a blanket allow. Records are pkg|op|mode;
        # a legacy pkg|mode line names COARSE_LOCATION.
        _rp="${_p%%|*}"; _rest="${_p#*|}"
        case "$_rest" in
          *"|"*) _rop="${_rest%%|*}"; _rm="${_rest#*|}" ;;
          *)            _rop="COARSE_LOCATION"; _rm="$_rest" ;;
        esac
        case "$_rop" in COARSE_LOCATION|FINE_LOCATION) : ;; *) _rop="COARSE_LOCATION" ;; esac
        case "$_rm" in allow|ignore|deny|default|foreground) : ;; *) _rm="allow" ;; esac
        [ -n "$_rp" ] && appops set "$_rp" "$_rop" "$_rm" >/dev/null 2>&1
      done < "$STATE"
      rm -f "$STATE" 2>/dev/null
      echo "gnss trim: off - location restored for the apps ASB had limited"
    fi
    exit 0 ;;
esac

_has dumpsys || exit 0
_has pm || exit 0
_has appops || exit 0

# Screen must be off. A cached process can still be serving something the user set up
# moments ago; waiting for the screen to go dark removes that ambiguity entirely.
case "$(dumpsys deviceidle get screen 2>/dev/null)" in
  *true*|*on*) exit 0 ;;
esac

# Give location back to anything that is no longer cached.
#
# The header of this file says the trim lasts "until it is opened again", and that was
# not implemented: the only restore path ran when the tweak itself was switched off. An
# app the user opened after it had been trimmed stayed on COARSE_LOCATION=ignore for as
# long as gnss_trim was on - so a navigation app resumed with no precise location and no
# indication why.
#
# Checked before the trim loop below, so an app promoted and demoted in the same session
# is handled in the right order.
if [ -f "$STATE" ] && _has appops && _has dumpsys; then
  _keep=""
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    # Records are pkg|op|mode now; a legacy pkg|mode line names COARSE_LOCATION.
    _rp="${_line%%|*}"; _rest="${_line#*|}"
    case "$_rest" in
      *"|"*) _rop="${_rest%%|*}"; _rm="${_rest#*|}" ;;
      *)            _rop="COARSE_LOCATION"; _rm="$_rest" ;;
    esac
    case "$_rop" in COARSE_LOCATION|FINE_LOCATION) : ;; *) _rop="COARSE_LOCATION" ;; esac
    case "$_rm" in allow|ignore|deny|default|foreground) : ;; *) _rm="allow" ;; esac
    _st="$(dumpsys activity processes "$_rp" 2>/dev/null \
           | grep -m1 -oE 'cached|foreground|perceptible|visible')"
    if [ -n "$_st" ] && [ "$_st" != "cached" ]; then
      appops set "$_rp" "$_rop" "$_rm" >/dev/null 2>&1 \
        && echo "gnss trim: $_rp ($_rop) is in use again - location restored"
    else
      _keep="${_keep}${_line}
"
    fi
  done < "$STATE"
  printf '%s' "$_keep" > "$STATE" 2>/dev/null
fi

_third="$(pm list packages -3 2>/dev/null | sed 's/^package://')"
[ -n "$_third" ] || exit 0
mkdir -p /data/adb/asb 2>/dev/null

# Apps holding a location request while cached, per Android's own accounting.
for _p in $(dumpsys location 2>/dev/null \
            | sed -n 's/.*package=\([a-zA-Z0-9_.]*\).*/\1/p' | sort -u); do
  case "$_third" in *"$_p"*) : ;; *) continue ;; esac

  # Never touched, for the same reason the doze trim spares them: a navigation app that
  # cannot see where you are is broken, and an emergency or safety app doubly so.
  case "$_p" in
    # The pattern list missed several navigators, including two very common ones.
    #
    # "yandex.navi" does not match ru.yandex.yandexnavi - there is no dot before navi in
    # the real package name - and 2gis is published as ru.dublgis.dgismobile, which
    # contains neither "2gis" nor "maps". A user reported a navigator losing its fix
    # mid-drive and recovering only after a reboot, which is exactly what a revoked
    # COARSE_LOCATION looks like from the passenger seat.
    #
    # Matching on the vendor stem rather than the product name is the safer form here:
    # a false exclusion costs a little battery, a false restriction costs navigation.
    *maps*|*navigation*|*navi*|*waze*|*yandex*|*2gis*|*dgis*|*sygic*|*osmand*|\
    *tomtom*|*here.app*|*seznam.mapy*|*mapy*|*karta*|*gps*|\
    *fitness*|*strava*|*runtastic*|*komoot*|*tracker*|\
    *emergency*|*sos*|*safety*|*find*my*|*findmy*|*antitheft*) continue ;;
  esac

  # Only if the process is actually cached. A foreground or perceptible process is doing
  # something visible, whatever the battery accounting says.
  _proc="$(dumpsys activity processes "$_p" 2>/dev/null | grep -m1 -oE 'cached|foreground|perceptible|visible')"
  [ "$_proc" = "cached" ] || continue

  # Both location ops, in FOREGROUND mode - not COARSE only, and not "ignore".
  #
  # Two defects lived here:
  #
  # 1. Only COARSE_LOCATION was set. An app holding a FINE fix (which is what GNSS
  #    drain actually is - the capture that motivated this file is labelled "gnss")
  #    notes OP_FINE_LOCATION, so the trim never reached the drain it exists for.
  #
  # 2. "ignore" is sticky: the appop survives the process being promoted, and the old
  #    comment's claim that "Android restores it on its own when the process is
  #    promoted" was wrong. The restore loop above only runs from the screen-off hourly
  #    cycle, so a navigation app opened in the morning after an overnight trim had no
  #    location until the next screen-off pass - potentially never during a screen-on
  #    drive. A user reported exactly that: fix lost mid-drive, recovered at reboot.
  #
  # MODE_FOREGROUND is the self-healing form of the same idea: cached processes are
  # denied, promoted processes are allowed, and Android flips it with the process state
  # itself - no restore timing to get wrong. Both ops are recorded per op, so uninstall
  # restores exactly what each app had, for each op.
  #
  # appops get prints a line like "COARSE_LOCATION: allow"; the mode is the last field.
  for _lop in COARSE_LOCATION FINE_LOCATION; do
    _prev="$(appops get "$_p" "$_lop" 2>/dev/null | head -1 | awk '{print $NF}')"
    case "$_prev" in allow|ignore|deny|default|foreground) : ;; *) _prev="allow" ;; esac
    # An app already on foreground or stricter asked for this itself; do not record or
    # rewrite the user's own choice.
    case "$_prev" in ignore|deny|foreground) continue ;; esac
    if appops set "$_p" "$_lop" foreground >/dev/null 2>&1; then
      grep -qE "^${_p}\|${_lop}\|" "$STATE" 2>/dev/null \
        || printf '%s|%s|%s\n' "$_p" "$_lop" "$_prev" >> "$STATE"
      echo "gnss trim: $_p ($_lop) was holding location while cached - foreground-only now"
    fi
  done
done
exit 0
