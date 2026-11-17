#!/system/bin/sh
MODDIR="${0%/*}/.."
D="${ASB_BFIX_STATE_DIR:-/data/adb/asb}"
SYS="${ASB_BFIX_SYSDIR:-/data/system}"
PEND="$D/battery_fix.pending"
LAST="$D/battery_fix.last"
PROG="$D/battery_fix.compile"
STOPF="$D/battery_fix.stop"
mkdir -p "$D" 2>/dev/null

_plugged() {
  [ -n "${ASB_BFIX_FAKE_PLUGGED:-}" ] && { [ "$ASB_BFIX_FAKE_PLUGGED" = 1 ]; return; }
  dumpsys battery 2>/dev/null | grep -Eq '(AC|USB|Wireless) powered: true'
}
_level() {
  if [ -n "${ASB_BFIX_FAKE_LEVEL:-}" ]; then printf '%s\n' "$ASB_BFIX_FAKE_LEVEL"; return; fi
  dumpsys battery 2>/dev/null | sed -n 's/^  level: \([0-9][0-9]*\).*/\1/p' | head -1
}
_eligible() {
  _plugged || { echo 'eligible=0 reason=not_charging'; return 1; }
  _l="$(_level)"
  [ "$_l" = 100 ] || { echo "eligible=0 reason=not_full level=${_l:-unknown}"; return 1; }
  echo 'eligible=1 reason=full_on_charge level=100'
}

case "${1:-status}" in
  eligible) _eligible ;;
  run)
    _eligible >/dev/null || { echo 'result=refused'; exit 1; }
    (umask 077; printf '%s' '' > "$PEND") || { echo 'result=state_error'; exit 1; }
    rm -f "$PROG" "$STOPF" 2>/dev/null
    echo 'result=armed reset_on=reboot compile=not_required'
    ;;
  boot)
    [ -f "$PEND" ] || exit 0
    (umask 077; printf '%s' '' > "$LAST") || { echo 'result=state_error'; exit 1; }
    for b in batterystats.bin batterystats-checkin.bin batterystats-daily.xml; do
      if [ -f "$SYS/$b" ]; then rm -f "$SYS/$b" && echo "$b" >> "$LAST"; fi
    done
    rm -f "$PEND"
    echo 'result=reset_done'
    ;;
  cancel)
    rm -f "$PEND" "$STOPF" "$PROG" 2>/dev/null
    echo 'result=cancelled'
    ;;
  status|*)
    if [ -f "$PEND" ]; then _r=pending; elif [ -f "$LAST" ]; then _r=done; else _r=none; fi
    if [ -f "$PEND" ]; then _eligible; else :; fi
    echo "reset=$_r compile=not_required"
    [ -f "$LAST" ] && echo "last_reset=$(cat "$LAST" | tr '\n' ' ')"
    ;;
esac
exit 0
