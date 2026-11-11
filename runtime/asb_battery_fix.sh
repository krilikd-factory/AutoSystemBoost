#!/system/bin/sh
# Infirmary: Battery Fix.
#
# Two separate, honest operations, both one-shot and both opt-in from the WebUI:
#
#   1. A battery-stats reset. Android keeps a running record of per-app battery use and a
#      learned "estimated capacity" in three files under /data/system (batterystats.bin,
#      batterystats-checkin.bin, batterystats-daily.xml). Deleting them makes the OS start
#      that record again from a known full charge. It does NOT change the physical battery
#      and does NOT add capacity or runtime: it only clears a skewed usage history and the
#      learned estimate so the percentage curve and the per-app breakdown relearn. Because
#      the files are read by system_server early in boot, the delete is done at post-fs-data
#      on the NEXT boot, not live - so the tweak arms a one-shot flag and asks for a reboot.
#      It is only offered at 100% on charge, which is the only correct moment to reset the
#      learning from.
#
#   2. An ART refresh. Re-compiles installed apps to the speed-profile filter and runs the
#      background dexopt job. This can make launches and hot paths smoother; the cost is a
#      longer first boot afterwards and more storage. Unlike a wipe-and-recompile it does
#      NOT delete dalvik-cache/.odex/.art (that forces a full cold recompile and risks a
#      very long or failed first boot) - recompiling in place is the safe, effective part.
#
# Nothing here is applied at boot on its own, nothing self-removes the module, and a pending
# reset can be cancelled before the reboot.
set -u

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE_DIR="${ASB_BFIX_STATE_DIR:-/data/adb/asb}"
PENDING="$STATE_DIR/battery_fix.pending"
LASTLOG="$STATE_DIR/battery_fix.last"
# /data/system in production; relocatable for host fixtures.
SYSDIR="${ASB_BFIX_SYSDIR:-/data/system}"
BSTATS="batterystats.bin batterystats-checkin.bin batterystats-daily.xml"

_now() { date +%s 2>/dev/null || echo 0; }

# --- battery state ---------------------------------------------------------------------
# Level and whether a charger is attached, from sysfs first and dumpsys as a fallback.
_bf_level() {
  _l=""
  [ -r /sys/class/power_supply/battery/capacity ] && _l="$(cat /sys/class/power_supply/battery/capacity 2>/dev/null | tr -dc '0-9')"
  if [ -z "$_l" ] && command -v dumpsys >/dev/null 2>&1; then
    _l="$(dumpsys battery 2>/dev/null | sed -n 's/^[[:space:]]*level:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
  fi
  printf '%s' "${ASB_BFIX_FAKE_LEVEL:-$_l}"
}
_bf_plugged() {
  if [ -n "${ASB_BFIX_FAKE_PLUGGED:-}" ]; then
    [ "$ASB_BFIX_FAKE_PLUGGED" = 1 ]; return
  fi
  _st=""
  [ -r /sys/class/power_supply/battery/status ] && _st="$(cat /sys/class/power_supply/battery/status 2>/dev/null)"
  case "$_st" in
    Charging|Full) return 0 ;;
    Discharging|"Not charging") return 1 ;;
  esac
  if command -v dumpsys >/dev/null 2>&1; then
    # Any of AC/USB/Wireless powered = true means a charger is attached.
    dumpsys battery 2>/dev/null | grep -Eq '(AC|USB|Wireless) powered:[[:space:]]*true' && return 0
  fi
  return 1
}
# eligible=1 only at a full battery on a charger - the only correct point to reset from.
_bf_eligible() {
  _lv="$(_bf_level)"
  case "$_lv" in ''|*[!0-9]*) echo 'eligible=0 reason=unknown_level'; return 1 ;; esac
  if ! _bf_plugged; then echo "eligible=0 reason=not_charging level=$_lv"; return 1; fi
  if [ "$_lv" -lt 100 ] 2>/dev/null; then echo "eligible=0 reason=not_full level=$_lv"; return 1; fi
  echo "eligible=1 level=$_lv"
  return 0
}

# --- ART refresh (best effort, backgrounded) -------------------------------------------
_bf_dexopt() {
  [ "${ASB_BFIX_NO_DEXOPT:-0}" = 1 ] && return 0
  command -v cmd >/dev/null 2>&1 || return 0
  (
    exec </dev/null >/dev/null 2>&1
    cmd package compile -m speed-profile -f -a
    cmd package bg-dexopt-job
  ) &
  return 0
}

case "${1:-status}" in
  eligible)
    _bf_eligible
    ;;
  run)
    if ! _bf_eligible >/dev/null 2>&1; then
      _e="$(_bf_eligible)"
      echo "result=refused ${_e#eligible=0 }"
      exit 1
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null
    _ts="$(_now)"
    # Arm the one-shot stats reset for the next boot. The level/charge at arm time is
    # recorded for the status line; the delete itself happens in `boot`.
    printf 'armed_at=%s\nlevel=%s\n' "$_ts" "$(_bf_level)" > "$PENDING" 2>/dev/null
    _bf_dexopt
    echo "result=armed reset_on=reboot dexopt=$([ "${ASB_BFIX_NO_DEXOPT:-0}" = 1 ] && echo skipped || echo started)"
    ;;
  boot)
    # Runs at post-fs-data on the next boot, before system_server reads the stats files.
    [ -f "$PENDING" ] || exit 0
    _removed=""; _missing=""
    for _b in $BSTATS; do
      if [ -e "$SYSDIR/$_b" ]; then
        rm -f "$SYSDIR/$_b" 2>/dev/null && _removed="$_removed $_b" || _missing="$_missing $_b"
      else
        _missing="$_missing $_b"
      fi
    done
    printf 'done_at=%s\nremoved=%s\nmissing=%s\n' "$(_now)" "${_removed# }" "${_missing# }" > "$LASTLOG" 2>/dev/null
    rm -f "$PENDING" 2>/dev/null
    ;;
  cancel)
    if [ -f "$PENDING" ]; then rm -f "$PENDING" 2>/dev/null; echo 'result=cancelled'; else echo 'result=none'; fi
    ;;
  status)
    _e="$(_bf_eligible)"
    if [ -f "$PENDING" ]; then _p=pending; else _p=none; fi
    _last=""
    [ -f "$LASTLOG" ] && _last="$(sed -n 's/^removed=//p' "$LASTLOG" 2>/dev/null | head -1)"
    printf '%s reset=%s last_removed=%s\n' "$_e" "$_p" "${_last:--}"
    ;;
  *)
    echo 'usage: eligible|run|boot|cancel|status' >&2
    exit 2
    ;;
esac
