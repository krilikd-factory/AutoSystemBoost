#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE_DIR="${ASB_CONFIG_STATE:-/data/adb/asb}"
CONF="$MODDIR/config/governor.conf"
SYS="${ASB_VC_SYS:-/sys}"
PROC="${ASB_VC_PROC:-/proc}"
MODS="${ASB_VC_MODULES:-${MODDIR%/*}}"
CPUS="$SYS/devices/system/cpu"
NODE="$SYS/kernel/msm_performance/parameters/cpu_max_freq"
[ -e "$NODE" ] || NODE="$SYS/module/msm_performance/parameters/cpu_max_freq"
GDIS="$PROC/game_opt/disable_cpufreq_limit"
OWN="$STATE_DIR/vendor_cap"
LOG="$STATE_DIR/vendor_cap.log"

_cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'; }
_mode() {
  case "$(_cfg cpu_vendor_unlock)" in
    off) echo off ;;
    always) echo always ;;
    *) echo perf ;;
  esac
}
_profile() { tr -d ' \r\n' < "$MODDIR/current_profile" 2>/dev/null; }
_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$(date '+%F %T' 2>/dev/null || echo now)" "$*" >> "$LOG" 2>/dev/null
  tail -n 40 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true
}
_trim() { tr -s ' \t\r\n' ' ' < "$1" 2>/dev/null | sed 's/^ //; s/ $//'; }
_other_owner() {
  for _o in "$MODS"/oplus-cloud-block "$MODS"/oplus_cloud_block; do
    [ -d "$_o" ] || continue
    [ -e "$_o/disable" ] || [ -e "$_o/remove" ] || { echo "${_o##*/}"; return 0; }
  done
  return 1
}
_want() {
  case "$(_mode)" in
    off) return 1 ;;
    always) [ "$(_profile)" != stock ] ;;
    *) [ "$(_profile)" = performance ] ;;
  esac
}
_lift_value() {
  _lv=""
  for _c in $(_trim "$NODE"); do
    _n="${_c%%:*}"
    case "$_n" in ''|*[!0-9]*) continue ;; esac
    _hw=""
    read -r _hw < "$CPUS/cpu$_n/cpufreq/cpuinfo_max_freq" 2>/dev/null
    case "$_hw" in ''|*[!0-9]*) return 1 ;; esac
    _lv="$_lv${_lv:+ }$_n:$_hw"
  done
  [ -n "$_lv" ] || return 1
  echo "$_lv"
}
_node_lifted() {
  _have="$(_trim "$NODE")"
  for _c in $1; do
    case " $_have " in *" $_c "*) ;; *) return 1 ;; esac
  done
  return 0
}
_mode_of() { stat -c %a "$1" 2>/dev/null || echo 644; }
_own_get() { sed -n "s/^$1=//p" "$OWN" 2>/dev/null | head -n 1; }
_own_put() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  { grep -v "^$1=" "$OWN" 2>/dev/null; echo "$1=$2"; } > "$OWN.tmp" 2>/dev/null && mv -f "$OWN.tmp" "$OWN" 2>/dev/null
}
_valid_orig() {
  [ -n "$1" ] || return 1
  case "$1" in *9999999*|*[!0-9:' ']*) return 1 ;; esac
  return 0
}

_lift_node() {
  [ -e "$NODE" ] || return 2
  [ "$(_own_get node)" = 1 ] && [ "$(_mode_of "$NODE")" = 444 ] && return 0
  _want_v="$(_lift_value)" || return 1
  if [ -z "$(_own_get node)" ]; then
    _cur="$(_trim "$NODE")"
    if _node_lifted "$_want_v"; then
      _own_put node_mode "$(_mode_of "$NODE")"
      _own_put node_orig ""
    else
      _valid_orig "$_cur" || return 1
      _own_put node_mode "$(_mode_of "$NODE")"
      _own_put node_orig "$_cur"
    fi
    _own_put node 1
  fi
  if ! _node_lifted "$_want_v"; then
    chmod 0644 "$NODE" 2>/dev/null
    echo "$_want_v" > "$NODE" 2>/dev/null
    _node_lifted "$_want_v" || { _restore_node; return 1; }
    _log "vendor ceiling lifted: $_want_v"
  fi
  chmod 0444 "$NODE" 2>/dev/null
  return 0
}
_restore_node() {
  [ "$(_own_get node)" = 1 ] || return 0
  _om="$(_own_get node_mode)"
  _ov="$(_own_get node_orig)"
  if [ -e "$NODE" ]; then
    chmod 0644 "$NODE" 2>/dev/null
    if _valid_orig "$_ov"; then
      echo "$_ov" > "$NODE" 2>/dev/null
      _log "vendor ceiling handed back: $_ov"
    fi
    case "$_om" in [0-7][0-7][0-7]) chmod "$_om" "$NODE" 2>/dev/null ;; *) chmod 0644 "$NODE" 2>/dev/null ;; esac
  fi
  _own_put node ""
  _own_put node_orig ""
  _own_put node_mode ""
  return 0
}
_lift_game() {
  [ -e "$GDIS" ] || return 2
  _gv=""
  read -r _gv < "$GDIS" 2>/dev/null
  case "$_gv" in 0|1) ;; *) return 1 ;; esac
  if [ -z "$(_own_get game)" ]; then
    _own_put game_orig "$_gv"
    _own_put game 1
  fi
  [ "$_gv" = 1 ] && return 0
  echo 1 > "$GDIS" 2>/dev/null
  _gv=""
  read -r _gv < "$GDIS" 2>/dev/null
  [ "$_gv" = 1 ] || { _restore_game; return 1; }
  _log "game scene ceiling disabled"
  return 0
}
_restore_game() {
  [ "$(_own_get game)" = 1 ] || return 0
  _go="$(_own_get game_orig)"
  case "$_go" in 0|1) ;; *) _go=0 ;; esac
  if [ -e "$GDIS" ]; then
    echo "$_go" > "$GDIS" 2>/dev/null
    _log "game scene ceiling handed back: $_go"
  fi
  _own_put game ""
  _own_put game_orig ""
  return 0
}
_restore_all() {
  _restore_node
  _restore_game
  rm -f "$OWN" "$OWN.tmp" 2>/dev/null
}

case "${1:-status}" in
  apply|sync)
    if _o="$(_other_owner)"; then
      _restore_all
      echo "result=other_owner"
      echo "owner=$_o"
      exit 0
    fi
    if ! _want; then
      _restore_all
      echo "result=stock"
      exit 0
    fi
    _lift_node; _rn=$?
    _lift_game; _rg=$?
    if [ "$_rn" = 2 ] && [ "$_rg" = 2 ]; then
      rm -f "$OWN" 2>/dev/null
      echo "result=unsupported"
      exit 0
    fi
    if [ "$_rn" = 1 ] || [ "$_rg" = 1 ]; then echo "result=partial"; else echo "result=lifted"; fi
    echo "node=$([ "$_rn" = 0 ] && echo lifted || { [ "$_rn" = 2 ] && echo absent || echo refused; })"
    echo "game_scene=$([ "$_rg" = 0 ] && echo lifted || { [ "$_rg" = 2 ] && echo absent || echo refused; })"
    ;;
  restore|stop)
    _restore_all
    echo "result=restored"
    ;;
  status)
    echo "version=1"
    echo "mode=$(_mode)"
    echo "profile=$(_profile)"
    if _o="$(_other_owner)"; then echo "other_owner=$_o"; fi
    if [ -e "$NODE" ]; then
      echo "node=present"
      echo "node_value=$(_trim "$NODE")"
      echo "node_perm=$(_mode_of "$NODE")"
    else
      echo "node=absent"
    fi
    if [ -e "$GDIS" ]; then _gv=""; read -r _gv < "$GDIS" 2>/dev/null; echo "game_scene_off=$_gv"; else echo "game_scene_off=absent"; fi
    if [ "$(_own_get node)" = 1 ] || [ "$(_own_get game)" = 1 ]; then echo "held=1"; else echo "held=0"; fi
    ;;
  *)
    echo "usage: asb_vendor_cap.sh apply|sync|restore|status" >&2
    exit 2
    ;;
esac
