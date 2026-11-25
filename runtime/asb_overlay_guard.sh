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
    [ -n "${4:-}" ] && printf 'target=%s\n' "$4"
    printf 'timestamp=%s\n' "$(date +%s 2>/dev/null || echo 0)"
  } > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$STATE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
}

_fail() {
  [ "${1:-}" = "" ] && exit 1
  [ "${ASB_OVERLAY_RECHECK:-0}" = 1 ] && exit 1
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  true > "$BLOCK" 2>/dev/null || true
  _write_state blocked "$1" "${2:-0}" "${_target:-}"
  exit 1
}

# Only recover the specific all-NUL generated camera payload failure. A bootloop fuse
# removes the manifest, so never infer permission to retry when it is missing. Keep the
# global block until *every* manifest entry passes the existing guard again.
if [ "${1:-}" = recover ] && [ -f "$BLOCK" ] && [ -f "$MAN" ] && \
   grep -qx 'status=blocked' "$STATE" 2>/dev/null && \
   grep -qx 'reason=invalid_json_payload' "$STATE" 2>/dev/null; then
  _repaired=0; _unsafe=0
  while IFS='|' read -r _rt _rp _extra; do
    case "$_rt" in
      /odm/etc/camera/conf_tuning_params.json|/odm/etc/camera/config/video_beauty_default_config) ;;
      *) continue ;;
    esac
    case "$_rp" in "$STATE_DIR/odm_patched/odm/etc/camera/"*) ;; *) _unsafe=1; break ;; esac
    [ -z "$_extra" ] && [ -s "$_rp" ] || { _unsafe=1; break; }
    # Only repair the proven all-zero corruption, not other malformed files.
    _nonzero="$(tr -d '\000' < "$_rp" 2>/dev/null | wc -c)"
    [ "${_nonzero:-1}" -eq 0 ] 2>/dev/null || continue
    _rel="${_rt#/odm/etc/camera/}"; _rs=""
    for _candidate in "$MODDIR/odm/etc/camera/$_rel" "$MODDIR/system/odm/etc/camera/$_rel" "$MODDIR/system/vendor/odm/etc/camera/$_rel"; do
      [ -s "$_candidate" ] && { _rs="$_candidate"; break; }
    done
    [ -n "$_rs" ] || { _unsafe=1; break; }
    _n="$(wc -c < "$_rs")"; _nn="$(tr -d '\000' < "$_rs" | wc -c)"
    _open="$(tr -cd '{' < "$_rs" | wc -c)"; _close="$(tr -cd '}' < "$_rs" | wc -c)"
    [ "$_n" -eq "$_nn" ] && [ "$_open" -gt 0 ] && [ "$_open" -eq "$_close" ] || { _unsafe=1; break; }
    _stage="$_rp.recover.$$"
    cp -f "$_rs" "$_stage" 2>/dev/null && cmp -s "$_rs" "$_stage" || { rm -f "$_stage"; _unsafe=1; break; }
    chmod --reference="$_rp" "$_stage" 2>/dev/null || chmod 0644 "$_stage" 2>/dev/null || true
    _ctx="$(ls -Zd "$_rp" 2>/dev/null | awk '{print $1}')"
    case "$_ctx" in u:object_r:*) chcon "$_ctx" "$_stage" 2>/dev/null || true ;; esac
    mv -f "$_stage" "$_rp" 2>/dev/null || { rm -f "$_stage"; _unsafe=1; break; }
    _repaired=$((_repaired + 1))
  done < "$MAN"
  if [ "$_unsafe" = 0 ] && [ "$_repaired" -gt 0 ] && ASB_OVERLAY_RECHECK=1 sh "$0" verify; then
    rm -f "$BLOCK" || exit 1
    _write_state ready recovered_zero_camera_payloads "$_repaired"
  fi
  [ -f "$BLOCK" ] && exit 1
  exit 0
fi
[ "${ASB_OVERLAY_RECHECK:-0}" = 1 ] || { [ -f "$BLOCK" ] && { [ -s "$STATE" ] || _write_state blocked existing_block 0; exit 1; }; }

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
[ "${ASB_OVERLAY_RECHECK:-0}" = 1 ] || _write_state ready validated "$_checked"
exit 0
