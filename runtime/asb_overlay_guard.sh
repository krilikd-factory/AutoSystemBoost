#!/system/bin/sh
# Validate generated ODM bind payload before magic-mount/runtime bind consumers can use it.
# This is deliberately fail-closed: an invalid generated overlay is less safe than stock ROM.

MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
for _d in "$MODDIR" "/data/adb/modules/$MODID" "/data/adb/modules_update/$MODID"; do
  [ -f "$_d/module.prop" ] && { MODDIR="$_d"; break; }
done
STATE_DIR="/data/adb/asb"
MAN="$STATE_DIR/odm_bind_manifest.txt"
STATE="$STATE_DIR/overlay_guard.state"
BLOCK="$STATE_DIR/vendor_overlay_blocked"

_write_state() {
  _tmp="$STATE.tmp.$$"
  {
    printf 'status=%s\n' "$1"
    printf 'reason=%s\n' "${2:-}"
    printf 'checked=%s\n' "${3:-0}"
    printf 'timestamp=%s\n' "$(date +%s 2>/dev/null || echo 0)"
  } > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$STATE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
}

_fail() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  : > "$BLOCK" 2>/dev/null || true
  _write_state blocked "$1" "${2:-0}"
  exit 1
}

[ -f "$BLOCK" ] && { _write_state blocked existing_block 0; exit 1; }
[ -f "$MAN" ] || { _write_state absent no_bind_manifest 0; exit 0; }

_checked=0
while IFS='|' read -r _target _payload _extra; do
  case "$_target$_payload$_extra" in ''|'#'*) continue ;; esac
  [ -n "$_target" ] && [ -n "$_payload" ] && [ -z "$_extra" ] || _fail malformed_manifest "$_checked"
  case "$_target" in
    /odm/etc/*|/vendor/odm/etc/*|/vendor/etc/*) ;;
    *) _fail forbidden_target "$_checked" ;;
  esac
  case "$_payload" in "$STATE_DIR/odm_patched/"*) ;; *) _fail forbidden_payload "$_checked" ;; esac
  [ -f "$_payload" ] && [ -s "$_payload" ] || _fail missing_payload "$_checked"
  [ -e "$_target" ] || _fail missing_target "$_checked"
  case "$_target" in
    *.xml)
      grep -q '<' "$_payload" 2>/dev/null || _fail invalid_xml_payload "$_checked"
      ;;
    *.json|*/video_beauty_default_config)
      _open="$(tr -cd '{' < "$_payload" 2>/dev/null | wc -c)"
      _close="$(tr -cd '}' < "$_payload" 2>/dev/null | wc -c)"
      [ "$_open" = "$_close" ] && [ "${_open:-0}" -gt 0 ] 2>/dev/null || _fail invalid_json_payload "$_checked"
      ;;
  esac
  _checked=$((_checked + 1))
done < "$MAN"

[ "$_checked" -gt 0 ] || _fail empty_manifest 0
_write_state ready validated "$_checked"
exit 0
