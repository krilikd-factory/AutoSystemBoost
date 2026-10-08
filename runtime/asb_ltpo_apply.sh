#!/system/bin/sh
# Force-LTPO runtime bind owner.
#
# install.sh (asb_prepare_ltpo_patch) clones THIS device's oplus_vrr_config.json, flips
# the idle frame-drop switches the OEM shipped off, and registers the pair in
# ltpo_bind_manifest.txt. This script is the only consumer: it binds the patched table
# over the stock one when ltpo_force=1, and removes its own binds when the toggle is
# off, the feature is uninstalled, or the bootloop fuse is set.
#
# The stock file is never modified - a bind mount only shadows it, so stock is always
# one umount (or one reboot) away.
#
# The display stack reads this config when it starts, so a live bind changes what the
# NEXT boot (or display service restart) sees, not the running one. The WebUI says so.

MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
for _d in "$MODDIR" "/data/adb/modules/$MODID" "/data/adb/modules_update/$MODID"; do
  [ -f "$_d/module.prop" ] && { MODDIR="$_d"; break; }
done

# Injectable for host-side fixtures, same pattern as the Wi-Fi fallback watcher.
STATE_DIR="${ASB_LTPO_STATE_DIR:-/data/adb/asb}"
MAN="$STATE_DIR/ltpo_bind_manifest.txt"
ACTIVE="$STATE_DIR/ltpo_bind.active"
BLOCK="$STATE_DIR/vendor_overlay_blocked"
MOUNTS_LOG="$STATE_DIR/vendor_mounts.log"
CONF="$MODDIR/config/governor.conf"

_cfg() {
  [ -f "$CONF" ] || return 0
  _v="$(grep -E "^$1=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' \r')"
  printf '%s' "$_v"
}

_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  echo "ts=$(date +%s 2>/dev/null || echo 0) $*" >> "$MOUNTS_LOG" 2>/dev/null
}

# Where the patched table may be bound. Only the real partition paths are allowed in
# production; ASB_LTPO_LIVE_ROOT exists for host fixtures, which relocate the live tree,
# and is never set on a device - so on a device this list is the whole story.
_ltpo_target_allowed() {
  case "$1" in
    /my_product/etc/oplus_vrr_config.json|/odm/etc/oplus_vrr_config.json|\
    /vendor/etc/oplus_vrr_config.json|/system_ext/etc/oplus_vrr_config.json|\
    /product/etc/oplus_vrr_config.json) return 0 ;;
  esac
  [ -n "${ASB_LTPO_LIVE_ROOT:-}" ] || return 1
  case "$1" in
    "${ASB_LTPO_LIVE_ROOT%/}"/*/etc/oplus_vrr_config.json|"${ASB_LTPO_LIVE_ROOT%/}"/etc/oplus_vrr_config.json) return 0 ;;
  esac
  return 1
}

# Fail-closed manifest validation, mirroring asb_overlay_guard.sh: a malformed or
# out-of-bounds entry must never become a mount in front of the display service.
_ltpo_guard() {
  [ -f "$MAN" ] || return 1
  _g_n=0
  while IFS='|' read -r _g_t _g_p _g_x; do
    case "$_g_t$_g_p$_g_x" in ''|'#'*) continue ;; esac
    [ -n "$_g_t" ] && [ -n "$_g_p" ] && [ -z "$_g_x" ] || return 1
    _ltpo_target_allowed "$_g_t" || return 1
    case "$_g_p" in "$STATE_DIR/ltpo_patched/"*) ;; *) return 1 ;; esac
    [ -s "$_g_p" ] || return 1
    [ -e "$_g_t" ] || return 1
    _g_open="$(tr -cd '{' < "$_g_p" 2>/dev/null | wc -c)"
    _g_close="$(tr -cd '}' < "$_g_p" 2>/dev/null | wc -c)"
    [ "${_g_open:-0}" = "${_g_close:-1}" ] && [ "${_g_open:-0}" -gt 0 ] 2>/dev/null || return 1
    _g_n=$((_g_n + 1))
  done < "$MAN"
  [ "$_g_n" -gt 0 ]
}

_is_bound() {
  # A bind-mounted file appears as its own mountpoint; the stock file on the partition
  # does not. This is what "we own a bind here" means. The mounts table is injectable
  # for host fixtures, the same portability pattern as the Wi-Fi fallback's PROC_ROOT.
  grep -q " $1 " "${ASB_LTPO_PROC_MOUNTS:-/proc/mounts}" 2>/dev/null
}

_bind_one() {
  _b_t="$1"; _b_p="$2"
  _is_bound "$_b_t" && { cmp -s "$_b_t" "$_b_p" 2>/dev/null && return 0; }
  if command -v nsenter >/dev/null 2>&1 \
     && nsenter -t 1 -m -- mount --bind "$_b_p" "$_b_t" 2>/dev/null; then
    return 0
  fi
  mount --bind "$_b_p" "$_b_t" 2>/dev/null
}

_unbind_one() {
  _u_t="$1"
  _is_bound "$_u_t" || return 0
  if command -v nsenter >/dev/null 2>&1 \
     && nsenter -t 1 -m -- umount "$_u_t" 2>/dev/null; then
    return 0
  fi
  umount "$_u_t" 2>/dev/null
}

_ltpo_bind_all() {
  _a_any=0
  while IFS='|' read -r _a_t _a_p; do
    case "$_a_t" in ''|'#'*) continue ;; esac
    if _bind_one "$_a_t" "$_a_p"; then
      _a_any=1
      true > "$ACTIVE" 2>/dev/null
    fi
  done < "$MAN"
  [ "$_a_any" = "1" ]
}

_ltpo_unbind_all() {
  _r_any=0
  [ -f "$MAN" ] || { rm -f "$ACTIVE" 2>/dev/null; return 1; }
  while IFS='|' read -r _r_t _r_p; do
    case "$_r_t" in ''|'#'*) continue ;; esac
    _unbind_one "$_r_t" && _r_any=1
  done < "$MAN"
  rm -f "$ACTIVE" 2>/dev/null
  [ "$_r_any" = "1" ]
}

# --- Refresh range: the Android half of "1 Hz up to the panel maximum" -----------------
#
# The patched table governs the BOTTOM of the range: the panel's own idle frame-drop
# (ADFR) that takes a still screen down to its lowest rates. Android does not see those
# rates at all - on the OnePlus 15 it lists 60/90/120/144/165 and nothing below - so no
# setting can ask for 1 Hz; the table is the only lever, and it is what the bind changes.
#
# The TOP of the range is Android's: peak_refresh_rate, plus min_refresh_rate as a floor.
# A ROM update, a power-save mode or an older tweak can leave the peak below what the
# panel can do, or a floor that keeps the panel from idling down at all. ltpo_force=1 now
# also makes sure the range is open at both ends: no floor, peak = the highest mode this
# panel reports. Recorded first and restored exactly when the toggle goes off or ASB is
# removed. Applied at boot and when toggled, never in a loop: a later choice in Settings
# is the user's and is not fought over.
[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"
RANGE_ORIG="$STATE_DIR/ltpo_range.orig"
VIDEO_LOWERED="$STATE_DIR/ltpo_video.lowered"

_ltpo_max_mode() {
  if [ -n "${ASB_LTPO_DISPLAY_DUMP:-}" ]; then cat "$ASB_LTPO_DISPLAY_DUMP" 2>/dev/null
  else dumpsys display 2>/dev/null; fi \
    | sed -n 's/.*DisplayMode{id=[0-9]*,.*peakRefreshRate=\([0-9.]*\).*/\1/p' \
    | awk '{ v = int($1 + 0.5); if (v > m) m = v } END { if (m >= 30 && m <= 480) print m }'
}
_ltpo_get() { command -v asb_set_get >/dev/null 2>&1 && asb_set_get system "$1" || settings get system "$1" 2>/dev/null | sed 's/^null$//'; }
_ltpo_put() { command -v asb_set_put >/dev/null 2>&1 && asb_set_put system "$1" "$2" || settings put system "$1" "$2" >/dev/null 2>&1; }
_ltpo_del() { command -v asb_set_del >/dev/null 2>&1 && asb_set_del system "$1" || settings delete system "$1" >/dev/null 2>&1; }

_ltpo_framework_up() {
  [ -n "${ASB_LTPO_DISPLAY_DUMP:-}" ] && return 0
  [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]
}

_ltpo_range_open() {
  _max="$(_ltpo_max_mode)"
  [ -n "$_max" ] || { _log 'action=ltpo_range result=skipped reason=no_modes'; return 0; }
  _peak="$(_ltpo_get peak_refresh_rate)"
  _min="$(_ltpo_get min_refresh_rate)"
  # A video lowering in progress (or left by a reboot mid-video) is not the user's peak.
  if [ -f "$VIDEO_LOWERED" ]; then
    _vo="$(sed -n 's/^orig=//p' "$VIDEO_LOWERED" 2>/dev/null | head -1)"
    [ -n "$_vo" ] && _peak="$_vo"
  fi
  if [ ! -f "$RANGE_ORIG" ]; then
    printf 'peak=%s\nmin=%s\n' "${_peak:-__unset}" "${_min:-__unset}" > "$RANGE_ORIG" 2>/dev/null
  fi
  _pk="$(printf '%s' "$_peak" | awk '{ print int($1 + 0.5) }')"
  if [ "${_pk:-0}" -lt "$_max" ] 2>/dev/null; then
    if [ -f "$VIDEO_LOWERED" ]; then
      # Not while a video holds it low: hand the open value to the video record, which
      # writes it back the moment the video lets go.
      _tmp="$(sed "s/^orig=.*/orig=$_max.0/" "$VIDEO_LOWERED" 2>/dev/null)" && printf '%s\n' "$_tmp" > "$VIDEO_LOWERED"
    else
      _ltpo_put peak_refresh_rate "$_max.0" && _log "action=ltpo_range peak=${_peak:-unset}->$_max"
    fi
  fi
  _mn="$(printf '%s' "$_min" | awk '{ print int($1 + 0.5) }')"
  if [ "${_mn:-0}" -gt 0 ] 2>/dev/null; then
    _ltpo_del min_refresh_rate && _log "action=ltpo_range min=$_min->none"
  fi
  return 0
}

_ltpo_range_restore() {
  [ -f "$RANGE_ORIG" ] || return 0
  _op="$(sed -n 's/^peak=//p' "$RANGE_ORIG" | head -1)"
  _om="$(sed -n 's/^min=//p' "$RANGE_ORIG" | head -1)"
  if [ -f "$VIDEO_LOWERED" ]; then
    # The video watcher will put back what it recorded; make that the user's original.
    _tmp="$(sed "s/^orig=.*/orig=${_op}/" "$VIDEO_LOWERED" 2>/dev/null)" && printf '%s\n' "$_tmp" > "$VIDEO_LOWERED"
  else
    case "$_op" in
      __unset|'') _ltpo_del peak_refresh_rate ;;
      *) _ltpo_put peak_refresh_rate "$_op" || return 0 ;;   # keep the record for a retry
    esac
  fi
  case "$_om" in __unset|'') : ;; *) _ltpo_put min_refresh_rate "$_om" || return 0 ;; esac
  rm -f "$RANGE_ORIG" 2>/dev/null
  _log "action=ltpo_range result=restored peak=$_op min=$_om"
}

case "${1:-apply}" in
  apply)
    if [ "$(_cfg ltpo_force)" = "1" ] && [ ! -f "$BLOCK" ] && _ltpo_guard; then
      if _ltpo_bind_all; then
        _log 'action=ltpo_bind result=applied'
      fi
    else
      # Toggle off (or fuse set): a bind of ours must not survive the choice that
      # removed it. Stock content is what the file shows again from this umount on.
      if [ -f "$ACTIVE" ]; then
        _ltpo_unbind_all && _log 'action=ltpo_bind result=removed'
      fi
    fi
    # The range does not need the patch: a device without a VRR table still benefits from
    # an open Android range, and the fuse guards mounts, not a setting. Only once the
    # framework is up - post-fs-data runs this too, before Settings exists.
    if _ltpo_framework_up; then
      if [ "$(_cfg ltpo_force)" = "1" ]; then
        _ltpo_range_open
      else
        _ltpo_range_restore
      fi
    fi
    ;;
  remove)
    # Uninstall path: drop whatever we own regardless of the toggle state.
    _ltpo_unbind_all && _log 'action=ltpo_bind result=removed reason=uninstall'
    _ltpo_framework_up && _ltpo_range_restore
    ;;
  range)
    # Diagnostics: what the range half did.
    printf 'max_mode=%s peak=%s min=%s recorded=%s\n' "$(_ltpo_max_mode)" \
      "$(_ltpo_get peak_refresh_rate)" "$(_ltpo_get min_refresh_rate)" \
      "$( [ -f "$RANGE_ORIG" ] && tr '\n' ' ' < "$RANGE_ORIG" || echo no)"
    ;;
  status)
    if [ ! -f "$MAN" ]; then
      echo 'ltpo_patch_absent'
    elif [ "$(_cfg ltpo_force)" != "1" ]; then
      echo 'ltpo_off'
    elif [ -f "$ACTIVE" ]; then
      echo 'ltpo_active'
    else
      echo 'ltpo_pending_boot'
    fi
    ;;
esac
exit 0
