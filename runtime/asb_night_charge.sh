#!/system/bin/sh
# Optional night charge ceiling, using only standard kernel power-supply controls.
# No vendor/SoC path is guessed. Every write is read back, and only a value still
# owned by ASB is restored. The scheduler lives in the existing service loop.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
PSY="${ASB_NC_PSY:-/sys/class/power_supply/battery}"
STATE="${ASB_NC_STATE:-/data/adb/asb}"
LEDGER="$STATE/night_charge.ledger"
STATUS="$STATE/night_charge.status"
LOCK="$STATE/night_charge.lock"
BOOTID_FILE="${ASB_NC_BOOTID:-/proc/sys/kernel/random/boot_id}"
TARGET=80
START_MIN=1320
END_MIN=360
NC_START=22:00
NC_END=06:00
NC_KIND=none
NC_NODE=""
NC_ENABLED=0
NC_CAPACITY=unknown
NC_CHARGING=unknown
NC_BATTERY_STATUS=unknown
NC_BOOT=unknown
L_KIND=""; L_ORIG=""; L_APPLIED=""; L_OWNED=""; L_BOOT=""
L_FOUND=0

_nc_cfg_key() {
  # Read the small config synchronously in the shell. A pipeline here used to turn a
  # transient fork/read failure into an empty value, silently restoring 22:00-06:00.
  # Preserve the old grammar: first exact key, optional leading whitespace, and spaces/CR
  # removed from its value. No background process or retry loop is introduced.
  [ -r "$CONF" ] || return 0
  _ck_key="$1"; _ck_cr="$(printf '\r')"
  while IFS= read -r _ck_line || [ -n "$_ck_line" ]; do
    case "$_ck_line" in *=*) ;; *) continue ;; esac
    _ck_name="${_ck_line%%=*}"
    while :; do
      case "$_ck_name" in [[:space:]]*) _ck_name="${_ck_name#?}" ;; *) break ;; esac
    done
    [ "$_ck_name" = "$_ck_key" ] || continue
    _ck_value="${_ck_line#*=}"; _ck_out=""
    while [ -n "$_ck_value" ]; do
      _ck_rest="${_ck_value#?}"
      _ck_char="${_ck_value%"$_ck_rest"}"
      _ck_value="$_ck_rest"
      case "$_ck_char" in ' '|"$_ck_cr") ;; *) _ck_out="$_ck_out$_ck_char" ;; esac
    done
    printf '%s\n' "$_ck_out"
    return 0
  done < "$CONF"
}
_nc_cfg() { _nc_cfg_key night_charge_enable; }
_nc_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
_nc_hm_min() {
  case "$1" in [0-1][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) return 1 ;; esac
  _h="${1%%:*}"; _m="${1##*:}"
  printf '%s\n' "$((1$_h * 60 + 1$_m - 6100))"
}
_nc_load_window() {
  _s="$(_nc_cfg_key night_charge_start)"; _e="$(_nc_cfg_key night_charge_end)"
  [ -n "$_s" ] || _s=22:00
  [ -n "$_e" ] || _e=06:00
  _sm="$(_nc_hm_min "$_s")" || return 1
  _em="$(_nc_hm_min "$_e")" || return 1
  # Equal endpoints are rejected rather than silently becoming a 24-hour hold.
  [ "$_sm" != "$_em" ] || return 1
  START_MIN="$_sm"; END_MIN="$_em"; NC_START="$_s"; NC_END="$_e"
  return 0
}
_nc_read() { cat "$1" 2>/dev/null | head -1 | tr -d ' \r\n'; }
_nc_boot() {
  _b="$(_nc_read "$BOOTID_FILE")"
  case "$_b" in ''|*[!A-Za-z0-9-]*) NC_BOOT=unknown ;; *) NC_BOOT="$_b" ;; esac
}
_nc_probe_battery() {
  NC_CAPACITY="$(_nc_read "$PSY/capacity")"
  _nc_num "$NC_CAPACITY" || NC_CAPACITY=unknown
  _s="$(_nc_read "$PSY/status")"
  case "$_s" in Charging|Full|Discharging|"Not charging") NC_BATTERY_STATUS="$_s" ;; *) NC_BATTERY_STATUS=unknown ;; esac
  case "$_s" in Charging|Full) NC_CHARGING=1 ;; Discharging|'Not charging') NC_CHARGING=0 ;; *) NC_CHARGING=unknown ;; esac
}
_nc_discover() {
  NC_KIND=none; NC_NODE=""
  _lim="$PSY/charge_control_limit"
  _max="$(_nc_read "$PSY/charge_control_limit_max")"
  _cur="$(_nc_read "$_lim")"
  if [ -f "$_lim" ] && [ -w "$_lim" ] && _nc_num "$_max" && _nc_num "$_cur" \
     && [ "$_max" -ge "$TARGET" ] 2>/dev/null; then
    NC_KIND=limit; NC_NODE="$_lim"; return 0
  fi
  _sw="$PSY/charging_enabled"
  _cur="$(_nc_read "$_sw")"
  if [ -f "$_sw" ] && [ -w "$_sw" ]; then
    case "$_cur" in 0|1) NC_KIND=switch; NC_NODE="$_sw"; return 0 ;; esac
  fi
  return 1
}
_nc_node_for() {
  case "$1" in
    limit) printf '%s\n' "$PSY/charge_control_limit" ;;
    switch) printf '%s\n' "$PSY/charging_enabled" ;;
    *) return 1 ;;
  esac
}
_nc_ledger_load() {
  L_KIND=""; L_ORIG=""; L_APPLIED=""; L_OWNED=""; L_BOOT=""; L_FOUND=0
  [ -f "$LEDGER" ] || return 1
  while IFS='=' read -r _k _v; do
    case "$_k" in
      kind) L_KIND="$_v" ;; original) L_ORIG="$_v" ;; applied) L_APPLIED="$_v" ;;
      owned) L_OWNED="$_v" ;; boot) L_BOOT="$_v" ;;
    esac
  done < "$LEDGER"
  case "$L_KIND" in limit|switch) ;; *) return 1 ;; esac
  _nc_num "$L_ORIG" && _nc_num "$L_APPLIED" || return 1
  case "$L_OWNED" in 0|1) ;; *) return 1 ;; esac
  L_FOUND=1
  return 0
}
_nc_ledger_save() {
  mkdir -p "$STATE" 2>/dev/null || return 1
  [ ! -d "$LEDGER" ] || return 1
  _tmp="$LEDGER.tmp.$$"
  {
    echo 'version=1'
    echo "kind=$1"
    echo "original=$2"
    echo "applied=$3"
    echo "owned=$4"
    echo "boot=$NC_BOOT"
  } > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$LEDGER" 2>/dev/null
}
_nc_mark_external() { _nc_ledger_save "$L_KIND" "$L_ORIG" "$L_APPLIED" 0; }
_nc_status() {
  _state="$1"
  _out="version=1
enabled=$NC_ENABLED
state=$_state
result=$_state
interface=$NC_KIND
capacity=$NC_CAPACITY
charging=$NC_CHARGING
target=$TARGET
window=$NC_START-$NC_END"
  _old="$(cat "$STATUS" 2>/dev/null)"
  if [ "$_old" != "$_out" ]; then
    mkdir -p "$STATE" 2>/dev/null || true
    _tmp="$STATUS.tmp.$$"
    printf '%s\n' "$_out" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$STATUS" 2>/dev/null
  fi
  printf '%s\n' "$_out"
}
_nc_window() {
  if [ -n "${ASB_NC_NOW_MIN:-}" ]; then
    _now="$ASB_NC_NOW_MIN"
  else
    _hm="$(date +'%H %M' 2>/dev/null)"
    _h="${_hm%% *}"; _m="${_hm##* }"
    case "$_h$_m" in ''|*[!0-9]*) return 1 ;; esac
    _now=$((1$_h * 60 + 1$_m - 6100))
  fi
  _nc_num "$_now" && [ "$_now" -le 1439 ] 2>/dev/null || return 1
  if [ "$START_MIN" -lt "$END_MIN" ]; then
    [ "$_now" -ge "$START_MIN" ] && [ "$_now" -lt "$END_MIN" ]
  else
    [ "$_now" -ge "$START_MIN" ] || [ "$_now" -lt "$END_MIN" ]
  fi
}
_nc_stale_boot() {
  _nc_ledger_load || return 1
  [ "$L_BOOT" != unknown ] && [ "$NC_BOOT" != unknown ] && [ "$L_BOOT" != "$NC_BOOT" ]
}
# Release only a node that still reads the exact value ASB wrote.
_nc_release() {
  _nc_ledger_load || { echo none; return 0; }
  _node="$(_nc_node_for "$L_KIND")" || { echo invalid; return 0; }
  [ "$L_OWNED" = 1 ] || { rm -f "$LEDGER" 2>/dev/null; echo external; return 0; }
  [ -n "$_node" ] && [ -f "$_node" ] && [ -w "$_node" ] || { echo failed; return 0; }
  _cur="$(_nc_read "$_node")"
  if [ "$_cur" != "$L_APPLIED" ]; then
    _nc_mark_external
    echo external
    return 0
  fi
  printf '%s\n' "$L_ORIG" > "$_node" 2>/dev/null || { echo failed; return 0; }
  _back="$(_nc_read "$_node")"
  [ "$_back" = "$L_ORIG" ] || { echo failed; return 0; }
  rm -f "$LEDGER" 2>/dev/null
  echo restored
}
_nc_apply_new() {
  _kind="$1"; _node="$2"; _want="$3"
  _orig="$(_nc_read "$_node")"
  _nc_num "$_orig" || { _nc_status unknown; return 0; }
  if [ "$_orig" != "$_want" ]; then
    printf '%s\n' "$_want" > "$_node" 2>/dev/null || { _nc_status write_failed; return 0; }
    _back="$(_nc_read "$_node")"
    if [ "$_back" != "$_want" ]; then
      printf '%s\n' "$_orig" > "$_node" 2>/dev/null || true
      _nc_status write_failed
      return 0
    fi
  fi
  if ! _nc_ledger_save "$_kind" "$_orig" "$_want" 1; then
    [ "$_orig" = "$_want" ] || printf '%s\n' "$_orig" > "$_node" 2>/dev/null || true
    _nc_status write_failed
    return 0
  fi
  _nc_status holding
}
_nc_reconcile() {
  NC_ENABLED=0
  [ "$(_nc_cfg)" = 1 ] && NC_ENABLED=1
  _window_ok=1; _nc_load_window || _window_ok=0
  _nc_probe_battery
  _nc_boot
  _nc_discover || true
  if _nc_stale_boot; then
    # sysfs is boot-scoped; never carry ownership into a new boot.
    rm -f "$LEDGER" 2>/dev/null
  fi
  if [ "$NC_ENABLED" != 1 ]; then
    _r="$(_nc_release)"
    case "$_r" in failed|invalid) _nc_status restore_failed ;; *) _nc_status off ;; esac
    return 0
  fi
  if [ "$_window_ok" != 1 ]; then
    # A malformed/equal window must never strand ASB's previous hold.
    _r="$(_nc_release)"
    case "$_r" in failed|invalid) _nc_status restore_failed ;; *) _nc_status invalid_window ;; esac
    return 0
  fi
  if ! _nc_window; then
    _r="$(_nc_release)"
    case "$_r" in failed|invalid) _nc_status restore_failed ;; *) _nc_status released ;; esac
    return 0
  fi
  if [ "$NC_KIND" = none ]; then
    if _nc_ledger_load && [ "$L_OWNED" = 1 ]; then _nc_status restore_failed; else _nc_status not_exposed; fi
    return 0
  fi
  if _nc_ledger_load; then
    [ "$L_KIND" = "$NC_KIND" ] || { _nc_status external_change; return 0; }
    [ "$L_OWNED" = 1 ] || { _nc_status external_change; return 0; }
    _cur="$(_nc_read "$NC_NODE")"
    if [ "$_cur" != "$L_APPLIED" ]; then
      _nc_mark_external
      _nc_status external_change
      return 0
    fi
    # Discharging is an explicit unplug indication. "Not charging" is not: it is
    # also the normal result of our own limit/switch and must not cause a release/
    # apply oscillation on the next maintenance tick.
    if [ "$NC_BATTERY_STATUS" = Discharging ] || \
       { [ "$NC_KIND" = switch ] && [ "$NC_CAPACITY" != unknown ] \
         && [ "$NC_CAPACITY" -lt "$TARGET" ] 2>/dev/null; }; then
      _r="$(_nc_release)"
      case "$_r" in restored|external|none) _nc_status waiting ;; *) _nc_status restore_failed ;; esac
    else
      _nc_status holding
    fi
    return 0
  fi
  if [ "$NC_CHARGING" != 1 ]; then
    _r="$(_nc_release)"
    case "$_r" in failed|invalid) _nc_status restore_failed ;; *) _nc_status waiting ;; esac
    return 0
  fi
  if [ "$NC_KIND" = limit ]; then
    _nc_apply_new limit "$NC_NODE" "$TARGET"
    return 0
  fi
  if [ "$NC_CAPACITY" = unknown ]; then _nc_status unknown; return 0; fi
  if [ "$NC_CAPACITY" -lt "$TARGET" ] 2>/dev/null; then _nc_status waiting; return 0; fi
  _nc_apply_new switch "$NC_NODE" 0
}
_nc_status_only() {
  NC_ENABLED=0
  [ "$(_nc_cfg)" = 1 ] && NC_ENABLED=1
  _window_ok=1; _nc_load_window || _window_ok=0
  _nc_probe_battery
  _nc_discover || true
  _st=unknown
  if [ -f "$STATUS" ]; then
    _st="$(grep -E '^state=' "$STATUS" 2>/dev/null | head -1 | sed 's/.*=//')"
    _if="$(grep -E '^interface=' "$STATUS" 2>/dev/null | head -1 | sed 's/.*=//')"
    case "$_st" in ''|*[!a-z_]*) _st=unknown ;; esac
    case "$_if" in limit|switch) NC_KIND="$_if" ;; esac
  elif [ "$NC_ENABLED" = 1 ] && [ "$NC_KIND" = none ]; then
    _st=not_exposed
  fi
  if [ "$NC_ENABLED" = 1 ]; then
    [ "$_st" = off ] && _st=unknown
    # An invalid interval must not hide an earlier failed restore: the kernel node
    # may still be owned by ASB even though no new hold can be reconciled.
    if [ "$_st" != restore_failed ] && [ "$_window_ok" != 1 ]; then
      _st=invalid_window
    fi
  else
    # A failed handback remains visible after the toggle is off; hiding it behind
    # a calm "off" badge would leave the user unaware of a still-owned node.
    case "$_st" in restore_failed) : ;; *) _st=off ;; esac
  fi
  printf '%s\n' "version=1" "enabled=$NC_ENABLED" "state=$_st" "result=$_st" \
    "interface=$NC_KIND" "capacity=$NC_CAPACITY" "charging=$NC_CHARGING" \
    "target=$TARGET" "window=$NC_START-$NC_END"
}
case "${1:-apply}" in
  status) _nc_status_only ;;
  apply|tick|restore)
    mkdir -p "$STATE" 2>/dev/null || true
    if ! mkdir "$LOCK" 2>/dev/null; then
      NC_ENABLED=0; [ "$(_nc_cfg)" = 1 ] && NC_ENABLED=1
      _nc_load_window || true
      _nc_probe_battery; _nc_discover || true; _nc_status unknown
      exit 0
    fi
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT HUP INT TERM
    if [ "$1" = restore ]; then
      NC_ENABLED=0; _nc_load_window || true; _nc_probe_battery; _nc_boot; _nc_discover || true
      if _nc_stale_boot; then rm -f "$LEDGER" 2>/dev/null; fi
      _r="$(_nc_release)"
      case "$_r" in failed|invalid) _nc_status restore_failed ;; *) _nc_status off ;; esac
    else
      _nc_reconcile
    fi
    ;;
  *) echo 'usage: asb_night_charge.sh apply|tick|status|restore' >&2; exit 2 ;;
esac
