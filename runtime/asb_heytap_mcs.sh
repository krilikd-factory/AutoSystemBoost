#!/system/bin/sh
# Opt-in HeyTap MCS / OPPO push transport switch (no .replace overlay).
# stock: restore only a package state ASB itself changed.
# off:   disable com.heytap.mcs now. No ART job is requested. Disabling MCS can delay or
#        stop HeyTap push messages; package-state readback and exact restore remain mandatory.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="${ASB_CONF:-$MODDIR/config/governor.conf}"
STATE_DIR="${ASB_HEYTAP_STATE_DIR:-/data/adb/asb/heytap_mcs}"
BASELINE="$STATE_DIR/baseline.conf"
PKG="com.heytap.mcs"

[ -f "$MODDIR/runtime/asb_package_state.sh" ] && . "$MODDIR/runtime/asb_package_state.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | tail -1 | sed 's/^[^=]*=//; s/#.*//' | tr -d ' \r'
}
_save_baseline() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  _sb_tmp="$BASELINE.tmp.$$"
  printf 'version=1\nprevious_enabled=%s\n' "$1" > "$_sb_tmp" 2>/dev/null || {
    rm -f "$_sb_tmp"; return 1;
  }
  mv -f "$_sb_tmp" "$BASELINE" 2>/dev/null || { rm -f "$_sb_tmp"; return 1; }
}
_previous() { sed -n 's/^previous_enabled=//p' "$BASELINE" 2>/dev/null | head -1; }
_dump() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  dumpsys package "$PKG" > "$STATE_DIR/package.dump" 2>/dev/null
}
_current() {
  _dump || return 1
  asb_pkg_enabled "$STATE_DIR/package.dump"
}
_restore() {
  [ -f "$BASELINE" ] || { echo 'result=untouched'; return 0; }
  _prev="$(_previous)"
  case "$_prev" in 0|1|2|3|4) : ;; *) echo 'result=restore_failed reason=baseline_invalid'; return 0 ;; esac
  if asb_pkg_restore_enabled "$_prev" "$PKG" 0; then
    rm -f "$BASELINE" "$STATE_DIR/package.dump" 2>/dev/null
    echo "result=restored previous_enabled=$_prev"
  else
    # Keep the original state so a later restore can retry.
    echo 'result=restore_failed'
  fi
}
_status() {
  if asb_pkg_present "$PKG"; then echo 'present=1'; else echo 'present=0'; fi
  echo "setting=$(_cfg heytap_mcs)"
  [ -f "$BASELINE" ] && echo "asb_changed=1 previous_enabled=$(_previous)" || echo 'asb_changed=0'
  if [ -f "$STATE_DIR/package.dump" ] || _dump; then
    _st="$(asb_pkg_enabled "$STATE_DIR/package.dump" 2>/dev/null)"
    echo "enabled_state=${_st:-unknown}"
  else
    echo 'enabled_state=unknown'
  fi
  rm -f "$STATE_DIR/package.dump" 2>/dev/null
  echo 'art=not_required'
}
_apply() {
  case "$(_cfg heytap_mcs)" in off) : ;; *) _restore; return ;; esac

  command -v pm >/dev/null 2>&1 || { echo 'result=pm_unavailable'; return 0; }
  if ! asb_pkg_present "$PKG"; then
    echo 'result=absent'
    return 0
  fi
  _dump || { echo 'result=state_unknown'; return 0; }
  _before="$(asb_pkg_enabled "$STATE_DIR/package.dump" 2>/dev/null)"
  case "$_before" in 0|1|2|3|4) : ;; *) echo 'result=state_unknown'; return 0 ;; esac

  _result=already_disabled
  case "$_before" in
    2|3) : ;;
    *)
      [ -f "$BASELINE" ] || _save_baseline "$_before" || {
        echo 'result=baseline_write_failed'; return 0;
      }
      if ! pm disable --user 0 "$PKG" >/dev/null 2>&1; then
        _restore >/dev/null 2>&1
        echo 'result=write_failed'
        return 0
      fi
      _result=disabled
      ;;
  esac
  am force-stop "$PKG" >/dev/null 2>&1 || true

  _after="$(_current 2>/dev/null)"
  case "$_after" in
    2|3) : ;;
    *) _restore >/dev/null 2>&1; echo 'result=readback_mismatch'; return 0 ;;
  esac
  rm -f "$STATE_DIR/package.dump" 2>/dev/null
  echo "result=$_result art=not_required"
}

case "${1:-apply}" in
  apply) _apply ;;
  status) _status ;;
  restore) _restore ;;
  *) echo 'usage: asb_heytap_mcs.sh apply|status|restore' >&2; exit 2 ;;
esac
exit 0
