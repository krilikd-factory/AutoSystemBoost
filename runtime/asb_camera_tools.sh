#!/system/bin/sh

STATE="${ASB_CAMTOOLS_STATE:-/data/adb/asb/camera_tools}"
RUNDIR="${ASB_CAMTOOLS_RUN:-/dev/.asb/camera_tools}"
GADGET_ROOT="${ASB_CAMTOOLS_GADGET_ROOT:-/config/usb_gadget}"
PKGLIST="${ASB_CAMTOOLS_PACKAGES_LIST:-/data/system/packages.list}"
CONF="${ASB_CONF:-${MODDIR:-/data/adb/modules/AutoSystemBoost}/config/governor.conf}"
WC_PKG=com.android.DeviceAsWebcam
WC_PROP=ro.usb.uvc.enabled
COMPILE_TIMEOUT="${ASB_CAMTOOLS_COMPILE_TIMEOUT:-900}"
BOOT_DELAY="${ASB_CAMTOOLS_BOOT_DELAY:-600}"
HIST_KEEP=8
MODE="${1:-status}"
SUB="${2:-}"

_ct_now() { date +%s 2>/dev/null || echo 0; }
_ct_clean() { printf '%s' "$1" | tr '\r\n\t|' '    ' | tr -cd 'A-Za-z0-9 ._:/=,+-' | cut -c1-"${2:-120}"; }

_ct_log() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now)" "$(_ct_clean "$*" 300)" >> "$STATE/log" 2>/dev/null
  _cl="$(wc -l < "$STATE/log" 2>/dev/null | tr -d ' ')"
  case "$_cl" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_cl" -gt 80 ] && tail -n 80 "$STATE/log" > "$STATE/log.tmp" 2>/dev/null && mv -f "$STATE/log.tmp" "$STATE/log" 2>/dev/null
  return 0
}

_ct_has_pkg() {
  if [ -r "$PKGLIST" ]; then
    grep -q "^$1 " "$PKGLIST" 2>/dev/null && return 0
    return 1
  fi
  pm path "$1" 2>/dev/null | grep -q '^package:' && return 0
  return 1
}

_ct_gadget() {
  for _g in "$GADGET_ROOT"/*; do
    [ -f "$_g/UDC" ] || continue
    printf '%s' "$_g"
    return 0
  done
  return 1
}

_ct_kernel_uvc() {
  _kg="$1"
  [ -n "$_kg" ] || { printf 'unknown'; return 0; }
  [ -d "$_kg/functions/uvc.0" ] && { printf 'ok'; return 0; }
  _kc="$RUNDIR/kernel_uvc"
  if [ -f "$_kc" ]; then
    _kv="$(cat "$_kc" 2>/dev/null)"
    case "$_kv" in ok|absent) printf '%s' "$_kv"; return 0 ;; esac
  fi
  mkdir -p "$RUNDIR" 2>/dev/null
  if mkdir "$_kg/functions/uvc.asbprobe" 2>/dev/null; then
    rmdir "$_kg/functions/uvc.asbprobe" 2>/dev/null
    _kv=ok
  else
    _kv=absent
  fi
  printf '%s\n' "$_kv" > "$_kc" 2>/dev/null
  printf '%s' "$_kv"
}

_ct_wc_app() {
  _ct_has_pkg "$WC_PKG" || { printf 'app=0|app_enabled=0'; return 0; }
  if pm list packages -d 2>/dev/null | grep -qx "package:$WC_PKG"; then
    printf 'app=1|app_enabled=0'
  else
    printf 'app=1|app_enabled=1'
  fi
}

_ct_usb_functions() {
  _uf="$(svc usb getFunctions 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9_,')"
  [ -n "$_uf" ] || _uf="$(getprop sys.usb.config 2>/dev/null | tr -cd 'A-Za-z0-9_,')"
  printf '%s' "${_uf:-unknown}"
}

_ct_wc_function() {
  [ -n "$1" ] || { printf 'no_gadget'; return 0; }
  if [ -d "$1/functions/uvc.0" ]; then
    if [ -f "$RUNDIR/uvc_created" ]; then printf 'created'; else printf 'present'; fi
  else
    printf 'missing'
  fi
}

_ct_wc_status() {
  _g="$(_ct_gadget)"
  _we=0; [ -f "$STATE/webcam" ] && _we=1
  _wp="$(getprop "$WC_PROP" 2>/dev/null | tr -cd 'a-z01')"
  _wg='-'; [ -n "$_g" ] && _wg="${_g##*/}"
  _wu="$(cat "$_g/UDC" 2>/dev/null | tr -cd 'A-Za-z0-9._-')"
  _wl='-'
  [ -f "$STATE/webcam.last" ] && _wl="$(tr -cd 'A-Za-z0-9_' < "$STATE/webcam.last" 2>/dev/null)"
  printf 'camtools|webcam|enabled=%s|%s|prop=%s|kernel=%s|function=%s|gadget=%s|udc=%s|usb=%s|last=%s\n' \
    "$_we" "$(_ct_wc_app)" "${_wp:-unset}" "$(_ct_kernel_uvc "$_g")" "$(_ct_wc_function "$_g")" \
    "$_wg" "${_wu:--}" "$(_ct_usb_functions)" "${_wl:--}"
}

_ct_w() { printf '%s\n' "$2" > "$1" 2>/dev/null; }
_ct_ln() { [ -d "${2%/*}" ] || mkdir -p "${2%/*}" 2>/dev/null; ln -s "$1" "$2" 2>/dev/null; }

_ct_wc_prepare() {
  _g="$(_ct_gadget)" || { _ct_log "webcam: no USB gadget under $GADGET_ROOT"; printf 'no_gadget'; return 0; }
  _f="$_g/functions/uvc.0"
  [ -d "$_f" ] && { printf 'present'; return 0; }
  mkdir "$_f" 2>/dev/null || { _ct_log "webcam: the kernel refused the UVC function"; printf 'kernel_refused'; return 0; }
  _ct_w "$_f/function_name" 'Android Webcam'
  _ct_w "$_f/streaming_maxpacket" 3072
  mkdir -p "$_f/control/header/h" 2>/dev/null
  _ct_ln "$_f/control/header/h" "$_f/control/class/fs/h"
  _ct_ln "$_f/control/header/h" "$_f/control/class/ss/h"
  for _fr in 1080p:1920:1080:4147200 720p:1280:720:1843200 480p:640:480:614400; do
    _n="${_fr%%:*}"; _r="${_fr#*:}"; _wd="${_r%%:*}"; _r="${_r#*:}"; _ht="${_r%%:*}"; _bs="${_r#*:}"
    _d="$_f/streaming/mjpeg/m/$_n"
    mkdir -p "$_d" 2>/dev/null || continue
    _ct_w "$_d/wWidth" "$_wd"
    _ct_w "$_d/wHeight" "$_ht"
    _ct_w "$_d/dwMaxVideoFrameBufferSize" "$_bs"
    _ct_w "$_d/dwDefaultFrameInterval" 333333
    _ct_w "$_d/dwFrameInterval" 333333
  done
  mkdir -p "$_f/streaming/header/h" 2>/dev/null
  _ct_ln "$_f/streaming/mjpeg/m" "$_f/streaming/header/h/m"
  _ct_ln "$_f/streaming/header/h" "$_f/streaming/class/fs/h"
  _ct_ln "$_f/streaming/header/h" "$_f/streaming/class/hs/h"
  _ct_ln "$_f/streaming/header/h" "$_f/streaming/class/ss/h"
  if [ -L "$_f/streaming/class/hs/h" ] && [ -L "$_f/streaming/header/h/m" ] && [ -L "$_f/control/class/fs/h" ]; then
    mkdir -p "$RUNDIR" 2>/dev/null; touch "$RUNDIR/uvc_created" 2>/dev/null
    _ct_log "webcam: UVC function created on ${_g##*/} (MJPEG 1080p/720p/480p at 30 fps)"
    printf 'created'
  else
    _ct_log "webcam: UVC function created but its descriptor links are incomplete"
    printf 'incomplete'
  fi
}

_ct_wc_prop() {
  [ -f "$STATE/webcam" ] || return 0
  command -v resetprop >/dev/null 2>&1 || return 0
  [ "$(getprop "$WC_PROP" 2>/dev/null)" = true ] && return 0
  resetprop -n "$WC_PROP" true >/dev/null 2>&1
}

_ct_wc_set() {
  case "$1" in
    on)
      _ct_has_pkg "$WC_PKG" || { printf 'camtools|webcam_set|state=no_app\n'; return 0; }
      mkdir -p "$STATE" 2>/dev/null || { printf 'camtools|webcam_set|state=error\n'; return 0; }
      if [ ! -f "$STATE/webcam.prop0" ]; then
        printf '%s\n' "$(getprop "$WC_PROP" 2>/dev/null | tr -cd 'a-z01')" > "$STATE/webcam.prop0" 2>/dev/null
      fi
      touch "$STATE/webcam" 2>/dev/null
      if pm list packages -d 2>/dev/null | grep -qx "package:$WC_PKG"; then
        pm enable "$WC_PKG" >/dev/null 2>&1 && _ct_log "webcam: enabled the ROM's webcam service app"
        touch "$STATE/webcam.app_enabled_by_asb" 2>/dev/null
      fi
      _ct_wc_prop
      _wr="$(_ct_wc_prepare)"
      _ct_log "webcam: switched on (function $_wr)"
      printf 'camtools|webcam_set|state=on|function=%s|reboot=1\n' "$_wr"
      ;;
    off)
      rm -f "$STATE/webcam" 2>/dev/null
      _p0="$(cat "$STATE/webcam.prop0" 2>/dev/null)"
      if command -v resetprop >/dev/null 2>&1; then
        if [ -n "$_p0" ]; then resetprop -n "$WC_PROP" "$_p0" >/dev/null 2>&1; else resetprop --delete "$WC_PROP" >/dev/null 2>&1; fi
      fi
      if [ -f "$STATE/webcam.app_enabled_by_asb" ]; then
        pm disable-user --user 0 "$WC_PKG" >/dev/null 2>&1
        rm -f "$STATE/webcam.app_enabled_by_asb" 2>/dev/null
      fi
      rm -f "$STATE/webcam.prop0" 2>/dev/null
      _ct_log "webcam: switched off"
      printf 'camtools|webcam_set|state=off|reboot=1\n'
      ;;
    *) printf 'camtools|error|unknown_command\n'; exit 2 ;;
  esac
}

_ct_wc_start() {
  [ -f "$STATE/webcam" ] || { printf 'camtools|webcam_start|state=off\n'; return 0; }
  [ "$(getprop "$WC_PROP" 2>/dev/null)" = true ] || { printf 'camtools|webcam_start|state=needs_reboot\n'; return 0; }
  _wr="$(_ct_wc_prepare)"
  case "$_wr" in created|present) ;; *) printf 'camtools|webcam_start|state=%s\n' "$_wr"; return 0 ;; esac
  _before="$(_ct_usb_functions)"
  case "$_before" in *uvc*) ;; *) printf '%s\n' "$_before" > "$STATE/webcam.before" 2>/dev/null ;; esac
  svc usb setFunctions uvc >/dev/null 2>&1
  _i=0; _now=''
  while [ "$_i" -lt 8 ]; do
    sleep 1
    _now="$(_ct_usb_functions)"
    case "$_now" in *uvc*) break ;; esac
    _i=$((_i + 1))
  done
  case "$_now" in
    *uvc*) _ws=active ;;
    *) _ws=refused ;;
  esac
  printf '%s\n' "$_ws" > "$STATE/webcam.last" 2>/dev/null
  _ct_log "webcam: start $_ws (USB functions before=$_before now=$_now)"
  printf 'camtools|webcam_start|state=%s|usb=%s\n' "$_ws" "${_now:-unknown}"
}

_ct_wc_stop() {
  _b="$(tr -cd 'A-Za-z0-9_,' < "$STATE/webcam.before" 2>/dev/null)"
  case "$_b" in ''|unknown|*uvc*) svc usb setFunctions >/dev/null 2>&1 ;; *) svc usb setFunctions "$_b" >/dev/null 2>&1 ;; esac
  sleep 1
  _now="$(_ct_usb_functions)"
  _ct_log "webcam: stop (USB functions now=$_now)"
  printf 'camtools|webcam_stop|state=done|usb=%s\n' "${_now:-unknown}"
}

_ct_cam_component() {
  _rc="$(cmd package resolve-activity --brief -a android.media.action.STILL_IMAGE_CAMERA 2>/dev/null | tail -n 1 | tr -cd 'A-Za-z0-9_./$')"
  case "$_rc" in
    */*) case "$_rc" in android/*|*ResolverActivity*) _rc='' ;; esac ;;
    *) _rc='' ;;
  esac
  if [ -z "$_rc" ] && _ct_has_pkg com.oplus.camera; then
    _rc="$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.oplus.camera 2>/dev/null | tail -n 1 | tr -cd 'A-Za-z0-9_./$')"
    case "$_rc" in */*) ;; *) _rc='' ;; esac
  fi
  printf '%s' "$_rc"
}

_ct_filter() {
  [ -n "$1" ] || { printf 'unknown'; return 0; }
  _cf="$(pm art dump "$1" 2>/dev/null | sed -n 's/.*\[status=\([a-z-]*\)\].*/\1/p' | head -n 1)"
  [ -n "$_cf" ] || _cf="$(dumpsys package dexopt 2>/dev/null | sed -n "/\[$1\]/,/^  \[/p" | sed -n 's/.*\[status=\([a-z-]*\)\].*/\1/p' | head -n 1)"
  printf '%s' "${_cf:-unknown}"
}

_ct_la_state() { sed -n 's/^state=\([a-z_]*\)$/\1/p' "$STATE/launch.state" 2>/dev/null | head -n 1; }

_ct_la_status() {
  _cc="$(_ct_cam_component)"; _cp="${_cc%%/*}"
  _le=0; [ -f "$STATE/launch" ] && _le=1
  _ls="$(_ct_la_state)"
  if [ "$_ls" = running ] && [ ! -d "$RUNDIR/compile.lock" ]; then _ls=interrupted; fi
  _lt="$(sed -n 's/^time=\([0-9]*\)$/\1/p' "$STATE/launch.state" 2>/dev/null | head -n 1)"
  _hist="$(tail -n "$HIST_KEEP" "$STATE/launch.history" 2>/dev/null | awk '{printf "%s%s:%s:%s", (NR>1?";":""), $1, $2, $3}')"
  printf 'camtools|launch|enabled=%s|pkg=%s|filter=%s|state=%s|state_time=%s|history=%s\n' \
    "$_le" "${_cp:--}" "$(_ct_filter "$_cp")" "${_ls:-idle}" "${_lt:-0}" "${_hist:--}"
}

_ct_la_write_state() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf 'state=%s\ntime=%s\n' "$1" "$(_ct_now)" > "$STATE/launch.state.tmp" 2>/dev/null && mv -f "$STATE/launch.state.tmp" "$STATE/launch.state" 2>/dev/null
}

_ct_la_worker() {
  _wpkg="$1"; _wmode="$2"
  mkdir -p "$RUNDIR" 2>/dev/null
  mkdir "$RUNDIR/compile.lock" 2>/dev/null || exit 0
  trap 'rmdir "$RUNDIR/compile.lock" 2>/dev/null' EXIT
  _ct_la_write_state running
  _t0="$(_ct_now)"
  _to=''
  command -v timeout >/dev/null 2>&1 && _to="timeout $COMPILE_TIMEOUT"
  if [ "$_wmode" = reset ]; then
    _out="$($_to cmd package compile --reset "$_wpkg" 2>&1)"
  else
    _out="$($_to cmd package compile -m speed -f "$_wpkg" 2>&1)"
  fi
  case "$_out" in
    *Success*) _res="${_wmode}_done" ;;
    *) _res="${_wmode}_failed" ;;
  esac
  case "$_res" in
    compile_done) printf '%s\n' "$_wpkg" > "$STATE/launch.pkg" 2>/dev/null ;;
    reset_done) rm -f "$STATE/launch.pkg" 2>/dev/null ;;
  esac
  _ct_la_write_state "$_res"
  _ct_log "launch: $_wmode $_wpkg -> $_res in $(( $(_ct_now) - _t0 ))s, filter now $(_ct_filter "$_wpkg"); output [$(_ct_clean "$(printf '%s' "$_out" | tail -n 1)" 80)]"
}

_ct_la_spawn() {
  _cc="$(_ct_cam_component)"; _cp="${_cc%%/*}"
  [ -n "$_cp" ] || { printf 'camtools|launch_%s|state=no_camera\n' "$1"; return 0; }
  [ -d "$RUNDIR/compile.lock" ] && { printf 'camtools|launch_%s|state=busy\n' "$1"; return 0; }
  _self="${ASB_CAMTOOLS_SELF:-$0}"
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$_self" launch-worker "$_cp" "$1" </dev/null >/dev/null 2>&1 &
  else
    nohup sh "$_self" launch-worker "$_cp" "$1" </dev/null >/dev/null 2>&1 &
  fi
  printf 'camtools|launch_%s|state=started|pkg=%s\n' "$1" "$_cp"
}

_ct_la_set() {
  case "$1" in
    on) mkdir -p "$STATE" 2>/dev/null && touch "$STATE/launch" 2>/dev/null; _ct_log "launch: switched on"; _ct_la_spawn compile ;;
    off) rm -f "$STATE/launch" 2>/dev/null; _ct_log "launch: switched off"; _ct_la_spawn reset ;;
    *) printf 'camtools|error|unknown_command\n'; exit 2 ;;
  esac
}

_ct_la_measure() {
  _cc="$(_ct_cam_component)"
  [ -n "$_cc" ] || { printf 'camtools|measure|state=no_camera\n'; return 0; }
  [ -d "$RUNDIR/compile.lock" ] && { printf 'camtools|measure|state=busy\n'; return 0; }
  _cp="${_cc%%/*}"
  _f="$(_ct_filter "$_cp")"
  _out="$(am start -W -S -n "$_cc" 2>&1)"
  _ms="$(printf '%s\n' "$_out" | sed -n 's/^TotalTime: *\([0-9]*\).*/\1/p' | head -n 1)"
  _st="$(printf '%s\n' "$_out" | sed -n 's/^LaunchState: *\([A-Z]*\).*/\1/p' | head -n 1)"
  case "$_ms" in ''|*[!0-9]*) _ct_log "launch: measure failed [$(_ct_clean "$(printf '%s' "$_out" | tail -n 1)" 80)]"; printf 'camtools|measure|state=failed\n'; return 0 ;; esac
  mkdir -p "$STATE" 2>/dev/null
  printf '%s %s %s %s\n' "$(_ct_now)" "$_ms" "$_f" "${_st:-UNKNOWN}" >> "$STATE/launch.history" 2>/dev/null
  tail -n "$HIST_KEEP" "$STATE/launch.history" > "$STATE/launch.history.tmp" 2>/dev/null && mv -f "$STATE/launch.history.tmp" "$STATE/launch.history" 2>/dev/null
  _ct_log "launch: measured $_cc ${_ms} ms (${_st:-UNKNOWN}, filter $_f)"
  printf 'camtools|measure|state=done|ms=%s|launch=%s|filter=%s\n' "$_ms" "${_st:-UNKNOWN}" "$_f"
}

_ct_preview_mode() {
  _pm="$(awk -F= '$1 ~ "^[[:space:]]*CAMERA_PREVIEW_TNR[[:space:]]*$" {v=$2; sub(/#.*/,"",v); gsub(/[[:space:]]/,"",v); print v; exit}' "$CONF" 2>/dev/null)"
  printf '%s' "${_pm:-stock}"
}
_ct_preview_base() { printf '%s/preview.%s.base' "$STATE" "$(printf '%s' "$1" | tr '.' '_')"; }
_ct_preview_value() { _pv="$(getprop "$1" 2>/dev/null)"; printf '%s' "${_pv:-unset}"; }
_ct_preview_run() {
  _pr_mode="$1"
  case "$_pr_mode" in stock|off|on) ;; *) printf 'camtools|preview|mode=invalid|state=config_invalid\n'; return 0 ;; esac
  _pr_state=stock_unowned
  [ "$_pr_mode" = stock ] || _pr_state=applied
  _pr_failed=0
  for _pr_prop in persist.camera.tnr.preview persist.vendor.camera.tnr.preview; do
    _pr_base="$(_ct_preview_base "$_pr_prop")"
    _pr_cur="$(getprop "$_pr_prop" 2>/dev/null)"
    if [ "$_pr_mode" = stock ]; then
      [ -f "$_pr_base" ] || continue
      _pr_old="$(cat "$_pr_base" 2>/dev/null)"
      command -v resetprop >/dev/null 2>&1 || { _pr_failed=1; continue; }
      if [ "$_pr_old" = __ASB_UNSET__ ]; then
        resetprop --delete "$_pr_prop" >/dev/null 2>&1 || { _pr_failed=1; continue; }
        _pr_now="$(getprop "$_pr_prop" 2>/dev/null)"
        [ -z "$_pr_now" ] || { _pr_failed=1; continue; }
      else
        resetprop -n "$_pr_prop" "$_pr_old" >/dev/null 2>&1 || { _pr_failed=1; continue; }
        _pr_now="$(getprop "$_pr_prop" 2>/dev/null)"
        [ "$_pr_now" = "$_pr_old" ] || { _pr_failed=1; continue; }
      fi
      rm -f "$_pr_base" 2>/dev/null || { _pr_failed=1; continue; }
      _pr_state=restored
    else
      [ "$_pr_mode" = on ] && _pr_want=1 || _pr_want=0
      if [ ! -f "$_pr_base" ]; then
        mkdir -p "$STATE" 2>/dev/null || { _pr_failed=1; continue; }
        if [ -z "$_pr_cur" ]; then printf '__ASB_UNSET__\n' > "$_pr_base.tmp" 2>/dev/null; else printf '%s\n' "$_pr_cur" > "$_pr_base.tmp" 2>/dev/null; fi
        mv -f "$_pr_base.tmp" "$_pr_base" 2>/dev/null || { rm -f "$_pr_base.tmp" 2>/dev/null; _pr_failed=1; continue; }
      fi
      command -v resetprop >/dev/null 2>&1 || { _pr_failed=1; continue; }
      resetprop -n "$_pr_prop" "$_pr_want" >/dev/null 2>&1 || { _pr_failed=1; continue; }
      _pr_now="$(getprop "$_pr_prop" 2>/dev/null)"
      [ "$_pr_now" = "$_pr_want" ] || { _pr_failed=1; continue; }
    fi
  done
  if [ "$_pr_failed" != 0 ]; then
    [ "$_pr_mode" = stock ] && _pr_state=restore_failed || _pr_state=write_failed
  fi
  printf 'camtools|preview|mode=%s|state=%s|camera=%s|vendor=%s\n' \
    "$_pr_mode" "$_pr_state" "$(_ct_preview_value persist.camera.tnr.preview)" "$(_ct_preview_value persist.vendor.camera.tnr.preview)"
}
_ct_preview_status() {
  _ps_mode="$(_ct_preview_mode)"
  case "$_ps_mode" in stock|off|on) _ps_state=ready ;; *) _ps_state=config_invalid ;; esac
  _ps_owned=0
  for _ps_prop in persist.camera.tnr.preview persist.vendor.camera.tnr.preview; do
    [ -f "$(_ct_preview_base "$_ps_prop")" ] && _ps_owned=$((_ps_owned + 1))
  done
  printf 'camtools|preview|mode=%s|state=%s|owned=%s|camera=%s|vendor=%s\n' \
    "$_ps_mode" "$_ps_state" "$_ps_owned" "$(_ct_preview_value persist.camera.tnr.preview)" "$(_ct_preview_value persist.vendor.camera.tnr.preview)"
}

_ct_boot() {
  until [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]; do sleep 5; done
  if [ -f "$STATE/webcam" ]; then
    _wr="$(_ct_wc_prepare)"
    _ct_log "webcam: boot prepare $_wr, $WC_PROP=$(getprop "$WC_PROP" 2>/dev/null)"
  fi
  [ -f "$STATE/launch" ] || return 0
  sleep "$BOOT_DELAY"
  _cc="$(_ct_cam_component)"; _cp="${_cc%%/*}"
  [ -n "$_cp" ] || return 0
  _f="$(_ct_filter "$_cp")"
  case "$_f" in
    speed|everything) return 0 ;;
    unknown) _ct_log "launch: boot check could not read the compile state of $_cp"; return 0 ;;
  esac
  _ct_log "launch: boot check found $_cp at $_f, compiling again"
  _ct_la_worker "$_cp" compile
}

case "$MODE" in
  status)
    _ct_wc_status
    _ct_la_status
    _ct_preview_status
    ;;
  webcam)
    case "$SUB" in
      on|off) _ct_wc_set "$SUB" ;;
      start) _ct_wc_start ;;
      stop) _ct_wc_stop ;;
      prop) _ct_wc_prop ;;
      prepare) printf 'camtools|webcam_prepare|state=%s\n' "$(_ct_wc_prepare)" ;;
      *) printf 'camtools|error|unknown_command\n'; exit 2 ;;
    esac
    ;;
  launch)
    case "$SUB" in
      on|off) _ct_la_set "$SUB" ;;
      measure) _ct_la_measure ;;
      *) printf 'camtools|error|unknown_command\n'; exit 2 ;;
    esac
    ;;
  preview)
    case "$SUB" in
      status) _ct_preview_status ;;
      apply) _ct_preview_run "$(_ct_preview_mode)" ;;
      restore) _ct_preview_run stock ;;
      *) printf 'camtools|error|unknown_command\n'; exit 2 ;;
    esac
    ;;
  launch-worker)
    case "${3:-}" in compile|reset) ;; *) exit 2 ;; esac
    case "$SUB" in ''|*[!A-Za-z0-9_.]*) exit 2 ;; esac
    _ct_la_worker "$SUB" "$3"
    ;;
  flags)
    _fw=0; [ -f "$STATE/webcam" ] && _fw=1
    _fl=0; [ -f "$STATE/launch" ] && _fl=1
    printf 'camtools|flags|webcam=%s|launch=%s\n' "$_fw" "$_fl"
    ;;
  boot) _ct_boot ;;
  log) [ -s "$STATE/log" ] && tail -n 40 "$STATE/log" 2>/dev/null || printf 'camtools|log|empty\n' ;;
  *) printf 'camtools|error|unknown_command\n'; exit 2 ;;
esac
