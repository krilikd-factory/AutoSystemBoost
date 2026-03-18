# asb_utils.sh — utility functions, sourced by service.sh

asb_map_profile_vars() {
  _P_RAVG="$RAVG_TICKS"
  _P_IDLE="$WALT_IDLE"
  _P_IDLEC="$WALT_IDLE_CLUST"
  _P_CLUT="$WALT_CLUSTER"
  _P_CLUTC="$WALT_CLUSTER_CLUST"
  _P_COLOC="$WALT_COLOC"
  _P_PIPE="$WALT_PIPE"
  _P_PIPEN="$WALT_PIPE_NONSP"
  _P_PIPES="$WALT_PIPE_SP"
  _P_CPUL="$CPU_MIN_LITTLE"
  _P_CPUB="$CPU_MIN_BIG"
  _P_SWAP="$VM_SWAPPINESS"
  _P_DEXP="$VM_DIRTY_EXPIRE"
  _P_DWB="$VM_DIRTY_WRITEBACK"
  _P_GTMR="$GPU_IDLE_TIMER"
  _P_BHYST="$WALT_BUSY_HYST"
  _P_EDB="$WALT_ED_BOOST"
  _P_TOPW="$WALT_TOPAPP_WEIGHT"
  _P_MINTB="$WALT_BOOST_MIN_UTIL"
  _P_SBOOST="$WALT_SCHED_BOOST"
  _P_UCL_BG="$UCL_BG_MIN"
  _P_UCL_FG="$UCL_FG_MIN"
  _P_UCL_TOP="$UCL_TOP_MIN"
  _P_CPUCAP_L="${CPU_CAP_LITTLE:-}"
  _P_CPUCAP_B="${CPU_CAP_BIG:-}"
  _P_CPU_MAXL="$CPU_MAX_LITTLE"
  _P_CPU_MAXB="$CPU_MAX_BIG"
  case "$WIFI_PM_MODE" in
    off) _P_WLAN_PM=0 ;;
    on) _P_WLAN_PM=1 ;;
    *) _P_WLAN_PM=2 ;;
  esac
  _P_WLAN_TXQLEN="$WIFI_TXQLEN"
  _P_LATENCY_SENSITIVE="$LATENCY_SENSITIVE"
  _P_GPU_MIN_PCT="$GPU_MIN_PCT"
  _P_GPU_MAX_PCT="$GPU_MAX_PCT"
  _P_VFS="$VM_VFS"
  _P_STATINT="$VM_STAT_INTERVAL"
  _P_WMARK="$VM_WMARK"
  _P_MINFREE="$VM_MINFREE"
  _P_QDISC="$NET_QDISC"
  _P_TCP_RMEM="$NET_TCP_RMEM"
  _P_TCP_WMEM="$NET_TCP_WMEM"
  _P_TCP_NOTSENT="$NET_TCP_NOTSENT"
  _P_NET_BACKLOG="$NET_BACKLOG"
  _P_NET_BUDGET="$NET_BUDGET"
  _P_NET_BUDGET_US="$NET_BUDGET_USECS"
  _P_DEV_WEIGHT="$NET_DEV_WEIGHT"
  _P_TCP_FASTOPEN="$NET_TCP_FASTOPEN"
  _P_TCP_KEEPIDLE="$NET_TCP_KEEPIDLE"
  _P_TCP_FIN="$NET_TCP_FIN"
}

asb_load_profile() {
  ASB_PROFILE="$(cat "$MODDIR/current_profile" 2>/dev/null)"
  case "$ASB_PROFILE" in
    performance|battery|balanced) : ;;

    *) ASB_PROFILE=balanced ;;
  esac
  PROFILE="$ASB_PROFILE"
  if [ -r "$MODDIR/profiles/$ASB_PROFILE.sh" ]; then
    . "$MODDIR/profiles/$ASB_PROFILE.sh"
  elif [ -r "$MODDIR/profiles/balanced.sh" ]; then
    PROFILE=balanced
    ASB_PROFILE=balanced
    . "$MODDIR/profiles/balanced.sh"
  fi
  asb_map_profile_vars
}

asb_feature_enabled() {
  _key="$1"
  [ -r "$MODDIR/features.conf" ] || return 0
  _line="$(grep -E "^${_key}=" "$MODDIR/features.conf" 2>/dev/null | tail -n 1)"
  [ -z "$_line" ] && return 0
  [ "${_line#*=}" = "1" ]
}

has() { command -v "$1" >/dev/null 2>&1; }
asb_has_risky_vendor_stack() {
  for _d in /data/adb/modules /data/adb/modules_update /data/adb/ksu/modules /data/adb/ksu/modules_update; do
    [ -d "$_d" ] || continue
    ls "$_d" 2>/dev/null | grep -qiE 'zeromount|overlayfs|susfs' && return 0
  done
  return 1
}
writef() { [ -w "$1" ] || return 1; echo "$2" > "$1" 2>/dev/null; }
readf() { [ -r "$1" ] && cat "$1" 2>/dev/null; }
writef_retry() {
  local _p="$1" _v="$2" _tries="${3:-3}" _delay="${4:-0.25}"
  [ -e "$_p" ] || return 1
  local i=1
  while [ $i -le $_tries ]; do
    [ -w "$_p" ] || return 1
    echo "$_v" > "$_p" 2>/dev/null || true
    [ -r "$_p" ] || return 0
    [ "$(cat "$_p" 2>/dev/null)" = "$_v" ] && return 0
    sleep "$_delay"
    i=$((i+1))
  done
  return 1
}
wait_path() {
  local _p="$1" _t="${2:-8}" i=0
  while [ $i -lt $_t ]; do
    [ -e "$_p" ] && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}
writef_verify() {
  _p="$1"; _v="$2"
  writef "$_p" "$_v" || return 1
  [ -r "$_p" ] || return 0
  _cur="$(cat "$_p" 2>/dev/null)"
  [ "$_cur" = "$_v" ] && return 0
  return 1
}
asb_update_desc() {
  _p="$(cat "$MODDIR/current_profile" 2>/dev/null)"
  case "$_p" in
    performance) _s="description=status: performance 🔥 | active ✅" ;;
    battery) _s="description=status: battery 🔋 | active ✅" ;;
    *) _s="description=status: balanced ⚖️ | active ✅" ;;
  esac
  sed "s/^description=.*/$_s/g" "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null || true
  grep -q "^description=" "$MODDIR/module.prop.tmp" 2>/dev/null && cat "$MODDIR/module.prop.tmp" > "$MODDIR/module.prop"
  rm -f "$MODDIR/module.prop.tmp"
}
sysctlw() {
  k="$1"; v="$2"
  if has sysctl; then
    sysctl -w "$k=$v" >/dev/null 2>&1 && return 0
  fi
  p="/proc/sys/$(echo "$k" | tr . /)"
  [ -w "$p" ] || return 1
  echo "$v" > "$p" 2>/dev/null
}

ASB_GOV="$MODDIR/bin/asb"
ASB_GOV_ENABLED=0

asb_governor_running() {
  [ -f /dev/.asb/governor.pid ] || return 1
  _gpid="$(cat /dev/.asb/governor.pid 2>/dev/null)"
  [ -n "$_gpid" ] && kill -0 "$_gpid" 2>/dev/null
}

asb_governor_start() {
  [ -x "$ASB_GOV" ] || return 1
  asb_governor_running && return 0
  mkdir -p "$MODDIR/config"
  if [ ! -f "$MODDIR/config/governor.conf" ] && [ -f "$MODDIR/config/governor.conf.default" ]; then
    cp "$MODDIR/config/governor.conf.default" "$MODDIR/config/governor.conf"
  fi
  mkdir -p /dev/.asb
  nice -n 10 "$ASB_GOV" >/dev/null 2>&1 &
  sleep 0.3
  asb_governor_running || return 1
  ASB_GOV_ENABLED=1
  asb_log "governor started (pid=$(cat /dev/.asb/governor.pid 2>/dev/null))"
  return 0
}

asb_governor_set_profile() {
  [ "$ASB_GOV_ENABLED" -eq 1 ] || return 0
  asb_governor_running || return 0
  "$ASB_GOV" "profile:$ASB_PROFILE" >/dev/null 2>&1 || true
}

if asb_feature_enabled CPU && [ -x "$ASB_GOV" ]; then
  asb_governor_start && ASB_GOV_ENABLED=1
fi
