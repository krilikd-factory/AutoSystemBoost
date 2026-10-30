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
EXT_MODULES_ROOT="${ASB_LTPO_MODULES_ROOT:-/data/adb/modules}"

# OnePlus15-165HZ-LTPO owns touch-driven mode switching through
# oplus_customize_screen_refresh_rate and its own refresh_rate_config.xml bind. ASB's
# force-LTPO bind/range is a different mechanism, but enabling both still produces two
# display policies. Detect the installed, enabled module and yield only ASB's force owner;
# never kill its daemon, edit its files, or disable the independent ltpo_video feature.
_ltpo_external_owner() {
  _e="$EXT_MODULES_ROOT/OnePlus15-165HZ-LTPO"
  [ -d "$_e" ] && [ ! -f "$_e/disable" ] && [ ! -f "$_e/remove" ] || return 1
  [ -f "$_e/vrrd.sh" ] || return 1
  grep -q '^id=OnePlus15-165HZ-LTPO[[:space:]]*$' "$_e/module.prop" 2>/dev/null
}

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
. "$MODDIR/runtime/asb_ltpo_lock.sh"
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
  asb_ltpo_lock || { _log 'action=ltpo_range result=deferred reason=video_lock'; return 1; }
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
      asb_ltpo_set_orig "$VIDEO_LOWERED" "$_max.0"
    else
      _ltpo_put peak_refresh_rate "$_max.0" && _log "action=ltpo_range peak=${_peak:-unset}->$_max"
    fi
  fi
  _mn="$(printf '%s' "$_min" | awk '{ print int($1 + 0.5) }')"
  if [ "${_mn:-0}" -gt 0 ] 2>/dev/null; then
    _ltpo_del min_refresh_rate && _log "action=ltpo_range min=$_min->none"
  fi
  asb_ltpo_unlock
  return 0
}

_ltpo_range_restore() {
  [ -f "$RANGE_ORIG" ] || return 0
  asb_ltpo_lock || return 1
  _op="$(sed -n 's/^peak=//p' "$RANGE_ORIG" | head -1)"
  _om="$(sed -n 's/^min=//p' "$RANGE_ORIG" | head -1)"
  if [ -f "$VIDEO_LOWERED" ]; then
    # The video watcher will put back what it recorded; make that the user's original.
    asb_ltpo_set_orig "$VIDEO_LOWERED" "$_op" || { asb_ltpo_unlock; return 1; }
  else
    case "$_op" in
      __unset|'') _ltpo_del peak_refresh_rate ;;
      *) _ltpo_put peak_refresh_rate "$_op" || { asb_ltpo_unlock; return 0; } ;;   # keep the record for a retry
    esac
  fi
  case "$_om" in
    __unset|'') : ;;
    *) _ltpo_put min_refresh_rate "$_om" || { asb_ltpo_unlock; return 0; } ;;
  esac
  rm -f "$RANGE_ORIG" 2>/dev/null
  _log "action=ltpo_range result=restored peak=$_op min=$_om"
  asb_ltpo_unlock
}

# Explicit ASB ownership: pause only the verified external writer process, never edit or
# disable the other module. Its bind/config stay untouched. If ASB is later switched off,
# resume the external service only when we actually paused it.
EXT_PAUSED="$STATE_DIR/ltpo_external.paused"
TOUCH_PID="$STATE_DIR/ltpo_touch.pid"
TOUCH_STOP="$STATE_DIR/ltpo_touch.stop"

_ltpo_external_pause() {
  _ltpo_external_owner || return 0
  _ep="$(cat "$EXT_MODULES_ROOT/OnePlus15-165HZ-LTPO/.vrrd.pid" 2>/dev/null | tr -dc '0-9')"
  [ -n "$_ep" ] || return 0
  [ -r "/proc/$_ep/cmdline" ] || return 0
  _ec="$(tr '\000' ' ' < "/proc/$_ep/cmdline" 2>/dev/null)"
  case "$_ec" in
    *OnePlus15-165HZ-LTPO/vrrd.sh*|*OnePlus15-165HZ-LTPO*/vrrd.sh*)
      if kill -TERM "$_ep" 2>/dev/null; then
        true > "$EXT_PAUSED" 2>/dev/null
        _log "action=ltpo_external result=paused pid=$_ep"
      fi
      ;;
  esac
}
_ltpo_external_resume() {
  [ -f "$EXT_PAUSED" ] || return 0
  _e="$EXT_MODULES_ROOT/OnePlus15-165HZ-LTPO"
  if _ltpo_external_owner && [ -f "$_e/service.sh" ]; then
    nohup sh "$_e/service.sh" >/dev/null 2>&1 </dev/null &
    _log 'action=ltpo_external result=resume_requested'
  fi
  rm -f "$EXT_PAUSED" 2>/dev/null
}
_ltpo_touch_live() {
  [ -f "$TOUCH_PID" ] || return 1
  _tp="$(cat "$TOUCH_PID" 2>/dev/null | tr -dc '0-9')"
  [ -n "$_tp" ] && [ -r "/proc/$_tp/cmdline" ] || return 1
  _tc="$(tr '\000' ' ' < "/proc/$_tp/cmdline" 2>/dev/null)"
  case "$_tc" in *asb_ltpo_touch.sh*) kill -0 "$_tp" 2>/dev/null ;; *) return 1 ;; esac
}
_ltpo_touch_start() {
  [ -f "$MODDIR/runtime/asb_ltpo_touch.sh" ] || return 1
  _ltpo_touch_live && return 0
  rm -f "$TOUCH_PID" "$TOUCH_STOP" 2>/dev/null
  nohup env MODDIR="$MODDIR" ASB_LTPO_STATE_DIR="$STATE_DIR" \
    ${ASB_LTPO_DISPLAY_DUMP:+ASB_LTPO_DISPLAY_DUMP="$ASB_LTPO_DISPLAY_DUMP"} \
    sh "$MODDIR/runtime/asb_ltpo_touch.sh" >/dev/null 2>&1 </dev/null &
  _ts=$!
  # Bounded startup barrier, not a worker: the watcher publishes its PID only after it
  # has found both a touchscreen and a valid panel mode. Never hand over from the
  # external module to a process that has already exited.
  _tn=0
  while [ "$_tn" -lt 10 ]; do
    _ltpo_touch_live && return 0
    kill -0 "$_ts" 2>/dev/null || break
    sleep 0.1
    _tn=$((_tn + 1))
  done
  _ltpo_touch_live
}
_ltpo_touch_stop() {
  true > "$TOUCH_STOP" 2>/dev/null
  if _ltpo_touch_live; then
    _tp="$(cat "$TOUCH_PID" 2>/dev/null | tr -dc '0-9')"
    kill -TERM "$_tp" 2>/dev/null || true
  fi
  rm -f "$TOUCH_PID" 2>/dev/null
}

case "${1:-apply}" in
  apply)
    if [ "$(_cfg ltpo_force)" = "1" ]; then
      # Explicit ASB enable has priority only after its independent touch controller is
      # actually live. A missing input node/getevent/panel mode must not strand the user
      # with both touch writers stopped.
      if [ ! -f "$BLOCK" ] && _ltpo_guard; then
        _ltpo_bind_all && _log 'action=ltpo_bind result=applied owner=asb'
      elif [ -f "$ACTIVE" ]; then
        _ltpo_unbind_all && _log 'action=ltpo_bind result=removed reason=guard'
      fi
      if _ltpo_framework_up; then
        _ltpo_range_open
        if _ltpo_touch_start; then
          _ltpo_external_pause
        else
          _ltpo_external_resume
          _log 'action=ltpo_touch result=unavailable external=fallback'
        fi
      fi
    else
      _ltpo_touch_stop
      if [ -f "$ACTIVE" ]; then
        _ltpo_unbind_all && _log 'action=ltpo_bind result=removed'
      fi
      _ltpo_framework_up && _ltpo_range_restore
      _ltpo_external_resume
    fi
    ;;
  remove)
    _ltpo_touch_stop
    _ltpo_unbind_all && _log 'action=ltpo_bind result=removed reason=uninstall'
    _ltpo_framework_up && _ltpo_range_restore
    _ltpo_external_resume
    ;;
  range)
    # Diagnostics: what the range half did. The floor key is deleted on purpose once the
    # range is open, so an empty min is the OPEN range, not missing data.
    _pk="$(_ltpo_get peak_refresh_rate)"
    _mn="$(_ltpo_get min_refresh_rate)"
    _rec="$( { [ -f "$RANGE_ORIG" ] && tr '\n' ' ' < "$RANGE_ORIG"; } | sed 's/ *$//' )"
    [ -n "$_rec" ] || _rec="none"
    printf 'max_mode=%s peak=%s min=%s original: %s\n' "$(_ltpo_max_mode)" \
      "${_pk:-unset}" "${_mn:-none (floor open)}" "$_rec"
    ;;
  status)
    if [ "$(_cfg ltpo_force)" != "1" ]; then
      if _ltpo_external_owner; then echo 'ltpo_external_owner'; else echo 'ltpo_off'; fi
    elif [ -f "$ACTIVE" ] && _ltpo_touch_live; then
      echo 'ltpo_active_touch'
    elif [ ! -f "$MAN" ]; then
      echo 'ltpo_patch_absent'
    elif [ -f "$ACTIVE" ]; then
      echo 'ltpo_active'
    else
      echo 'ltpo_pending_boot'
    fi
    ;;
esac
exit 0
