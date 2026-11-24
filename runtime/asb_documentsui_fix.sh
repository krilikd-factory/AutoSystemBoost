#!/system/bin/sh
# Manual, reversible DocumentsUI / DSU file-picker repair for user 0.
# No service.sh writer: Android package and component states already persist across boots.
# Only fields changed by ASB are restored, so a pre-disabled package/component stays untouched.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="${ASB_CONF:-$MODDIR/config/governor.conf}"
STATE_DIR="${ASB_DOCUMENTSUI_STATE_DIR:-/data/adb/asb/documentsui_fix}"
BASELINE="$STATE_DIR/baseline.conf"
DOC="com.android.documentsui"
FM="com.coloros.filemanager"
PICK="com.android.documentsui.picker.PickActivity"
FILES="com.android.documentsui.files.FilesActivity"

[ -f "$MODDIR/runtime/asb_package_state.sh" ] && . "$MODDIR/runtime/asb_package_state.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | tail -1 | sed 's/^[^=]*=//; s/#.*//' | tr -d ' \r'
}
_base() { sed -n "s/^$1=//p" "$BASELINE" 2>/dev/null | head -1; }
_dump() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  dumpsys package "$DOC" > "$STATE_DIR/doc.dump" 2>/dev/null || return 1
  if asb_pkg_present "$FM"; then
    dumpsys package "$FM" > "$STATE_DIR/fm.dump" 2>/dev/null || return 1
  else
    rm -f "$STATE_DIR/fm.dump" 2>/dev/null
  fi
}
_save_baseline() {
  _sv_tmp="$BASELINE.tmp.$$"
  {
    echo 'version=1'
    printf 'doc_enabled=%s\ndoc_hidden=%s\npick_enabled=%s\nfiles_enabled=%s\nfm_present=%s\nfm_enabled=%s\n' \
      "$_doc_enabled" "$_doc_hidden" "$_pick" "$_files" "$_fm_present" "$_fm_enabled"
    printf 'doc_enabled_changed=%s\ndoc_hidden_changed=%s\npick_changed=%s\nfiles_changed=%s\nfm_changed=%s\n' \
      "$_doc_enabled_changed" "$_doc_hidden_changed" "$_pick_changed" "$_files_changed" "$_fm_changed"
  } > "$_sv_tmp" 2>/dev/null || { rm -f "$_sv_tmp"; return 1; }
  mv -f "$_sv_tmp" "$BASELINE" 2>/dev/null || { rm -f "$_sv_tmp"; return 1; }
}
_read_baseline() {
  [ -f "$BASELINE" ] || return 1
  _doc_enabled="$(_base doc_enabled)"; _doc_hidden="$(_base doc_hidden)"
  _pick="$(_base pick_enabled)"; _files="$(_base files_enabled)"
  _fm_present="$(_base fm_present)"; _fm_enabled="$(_base fm_enabled)"
  _doc_enabled_changed="$(_base doc_enabled_changed)"; _doc_hidden_changed="$(_base doc_hidden_changed)"
  _pick_changed="$(_base pick_changed)"; _files_changed="$(_base files_changed)"; _fm_changed="$(_base fm_changed)"
  case "$_doc_enabled:$_doc_hidden:$_pick:$_files:$_fm_present:$_fm_enabled" in
    *[!0-9:]*|*::*) return 1 ;;
  esac
  case "$_doc_enabled_changed:$_doc_hidden_changed:$_pick_changed:$_files_changed:$_fm_changed" in
    *[!0-9:]*|*::*) return 1 ;;
  esac
  return 0
}
_restore() {
  [ -f "$BASELINE" ] || { echo 'result=untouched'; return 0; }
  _read_baseline || { echo 'result=restore_failed reason=baseline_invalid'; return 0; }
  _rc=0
  [ "$_doc_enabled_changed" = 1 ] && { asb_pkg_restore_enabled "$_doc_enabled" "$DOC" 0 || _rc=1; }
  [ "$_doc_hidden_changed" = 1 ] && { asb_pkg_restore_hidden "$_doc_hidden" "$DOC" 0 || _rc=1; }
  [ "$_pick_changed" = 1 ] && { asb_pkg_restore_enabled "$_pick" "$DOC/$PICK" 0 || _rc=1; }
  [ "$_files_changed" = 1 ] && { asb_pkg_restore_enabled "$_files" "$DOC/$FILES" 0 || _rc=1; }
  [ "$_fm_present" = 1 ] && [ "$_fm_changed" = 1 ] && {
    asb_pkg_restore_enabled "$_fm_enabled" "$FM" 0 || _rc=1;
  }
  if [ "$_rc" -eq 0 ]; then
    rm -f "$BASELINE" "$STATE_DIR/doc.dump" "$STATE_DIR/fm.dump" 2>/dev/null
    echo 'result=restored'
  else
    # Keep the baseline for a later retry rather than claiming an exact handback.
    echo 'result=restore_failed'
  fi
}
_status() {
  if asb_pkg_present "$DOC"; then echo 'present=1'; else echo 'present=0'; fi
  if asb_pkg_present "$FM"; then echo 'filemanager_present=1'; else echo 'filemanager_present=0'; fi
  echo "setting=$(_cfg documentsui_fix)"
  [ -f "$BASELINE" ] && echo 'asb_changed=1' || echo 'asb_changed=0'
}
_apply() {
  case "$(_cfg documentsui_fix)" in 1|on) : ;; *) _restore; return ;; esac
  [ -f "$BASELINE" ] && { echo 'result=already_applied'; return 0; }
  command -v pm >/dev/null 2>&1 || { echo 'result=pm_unavailable'; return 0; }
  asb_pkg_present "$DOC" || { echo 'result=absent'; return 0; }
  _dump || { echo 'result=state_unknown'; return 0; }

  _doc_enabled="$(asb_pkg_enabled "$STATE_DIR/doc.dump" 2>/dev/null)"
  _doc_hidden="$(asb_pkg_hidden "$STATE_DIR/doc.dump" 2>/dev/null)"
  _pick="$(asb_component_enabled "$STATE_DIR/doc.dump" "$DOC" "$PICK" 2>/dev/null)"
  _files="$(asb_component_enabled "$STATE_DIR/doc.dump" "$DOC" "$FILES" 2>/dev/null)"
  case "$_doc_enabled" in 0|1|2|3|4) : ;; *) echo 'result=state_unknown field=doc_enabled'; return 0 ;; esac
  case "$_doc_hidden" in 0|1) : ;; *) echo 'result=state_unknown field=doc_hidden'; return 0 ;; esac
  case "$_pick" in 0|1|2|3|4) : ;; *) echo 'result=state_unknown field=pick_enabled'; return 0 ;; esac
  case "$_files" in 0|1|2|3|4) : ;; *) echo 'result=state_unknown field=files_enabled'; return 0 ;; esac

  if [ -f "$STATE_DIR/fm.dump" ]; then
    _fm_present=1
    _fm_enabled="$(asb_pkg_enabled "$STATE_DIR/fm.dump" 2>/dev/null)"
    case "$_fm_enabled" in 0|1|2|3|4) : ;; *) echo 'result=state_unknown field=filemanager_enabled'; return 0 ;; esac
  else
    _fm_present=0
    _fm_enabled=0
  fi

  _doc_enabled_changed=0; _doc_hidden_changed=0; _pick_changed=0; _files_changed=0; _fm_changed=0
  [ "$_doc_enabled" = 1 ] || _doc_enabled_changed=1
  [ "$_doc_hidden" = 0 ] || _doc_hidden_changed=1
  [ "$_pick" = 0 ] || _pick_changed=1
  [ "$_files" = 0 ] || _files_changed=1
  if [ "$_fm_present" = 1 ]; then
    case "$_fm_enabled" in 2|3) : ;; *) _fm_changed=1 ;; esac
  fi
  if [ "$_doc_enabled_changed$_doc_hidden_changed$_pick_changed$_files_changed$_fm_changed" = 00000 ]; then
    rm -f "$STATE_DIR/doc.dump" "$STATE_DIR/fm.dump" 2>/dev/null
    echo 'result=already_fixed'
    return 0
  fi
  _save_baseline || { echo 'result=baseline_write_failed'; return 0; }

  _rc=0
  [ "$_doc_enabled_changed" = 1 ] && { pm enable --user 0 "$DOC" >/dev/null 2>&1 || _rc=1; }
  [ "$_doc_hidden_changed" = 1 ] && { pm unhide --user 0 "$DOC" >/dev/null 2>&1 || _rc=1; }
  [ "$_pick_changed" = 1 ] && { pm default-state --user 0 "$DOC/$PICK" >/dev/null 2>&1 || _rc=1; }
  [ "$_files_changed" = 1 ] && { pm default-state --user 0 "$DOC/$FILES" >/dev/null 2>&1 || _rc=1; }
  [ "$_fm_changed" = 1 ] && { pm disable-user --user 0 "$FM" >/dev/null 2>&1 || _rc=1; }

  # Read back every target. A rejected command or a silent PackageManager mismatch triggers
  # rollback of only ASB's fields; it never remains presented as a successful repair.
  _dump || _rc=1
  if [ "$_rc" -eq 0 ]; then
    _now_doc="$(asb_pkg_enabled "$STATE_DIR/doc.dump" 2>/dev/null)"
    _now_hidden="$(asb_pkg_hidden "$STATE_DIR/doc.dump" 2>/dev/null)"
    _now_pick="$(asb_component_enabled "$STATE_DIR/doc.dump" "$DOC" "$PICK" 2>/dev/null)"
    _now_files="$(asb_component_enabled "$STATE_DIR/doc.dump" "$DOC" "$FILES" 2>/dev/null)"
    [ "$_now_doc" = 1 ] && [ "$_now_hidden" = 0 ] && [ "$_now_pick" = 0 ] && [ "$_now_files" = 0 ] || _rc=1
    if [ "$_fm_present" = 1 ]; then
      _now_fm="$(asb_pkg_enabled "$STATE_DIR/fm.dump" 2>/dev/null)"
      case "$_now_fm" in 2|3) : ;; *) _rc=1 ;; esac
    fi
  fi
  if [ "$_rc" -ne 0 ]; then
    _restore >/dev/null 2>&1
    [ -f "$BASELINE" ] && echo 'result=rollback_failed' || echo 'result=write_failed_rolled_back'
    return 0
  fi
  rm -f "$STATE_DIR/doc.dump" "$STATE_DIR/fm.dump" 2>/dev/null
  echo 'result=applied'
}

case "${1:-apply}" in
  apply) _apply ;;
  status) _status ;;
  restore) _restore ;;
  *) echo 'usage: asb_documentsui_fix.sh apply|status|restore' >&2; exit 2 ;;
esac
exit 0
