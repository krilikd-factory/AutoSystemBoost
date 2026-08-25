#!/system/bin/sh
# Stock profile boundary.
#
# Stock is an explicit no-intervention power profile: ASB stops its native policy daemon and
# releases only leases it owns as `profile`. It deliberately does NOT guess vendor CPU/GPU/
# scheduler defaults and write invented "stock" values over a live ROM. A reboot restores the
# kernel's own boot-time policy exactly; until then ASB makes no further profile-policy writes.

asb_stock_profile_active() {
  _asp_moddir="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
  [ "$(cat "$_asp_moddir/current_profile" 2>/dev/null)" = "stock" ]
}

asb_stock_release_profile_leases() {
  command -v asb_arbiter_release >/dev/null 2>&1 || return 0
  for _asp_resource in cpu_cap gpu_cap uclamp_max cpuset_fg; do
    asb_arbiter_release "$_asp_resource" profile >/dev/null 2>&1 || true
  done
}

asb_stock_stop_governor() {
  _asp_pid="$(cat /dev/.asb/governor.pid 2>/dev/null)"
  case "$_asp_pid" in ''|*[!0-9]*) : ;; *) kill "$_asp_pid" 2>/dev/null || true ;; esac
  # The native binary is normally invoked as an argument-less process. Keep this defensive
  # fallback in case a stale pid file was lost; it is intentionally restricted to ASB's path.
  pkill -f '/bin/asb$' 2>/dev/null || true
  _asp_wait=0
  while [ "$_asp_wait" -lt 10 ]; do
    pgrep -f '/bin/asb$' >/dev/null 2>&1 || break
    sleep 0.1
    _asp_wait=$((_asp_wait + 1))
  done
  rm -f /dev/.asb/governor.pid /dev/.asb/state 2>/dev/null || true
}

asb_stock_restore_profile_runtime() {
  # This is deliberately separate from asb_baseline_replay: the global baseline contains
  # independent user-selected controls (including manual audio), while Stock must restore
  # only values that a power profile itself changed.
  command -v asb_profile_baseline_restore >/dev/null 2>&1 && \
    asb_profile_baseline_restore || true
}

asb_stock_enter() {
  mkdir -p /data/adb/asb 2>/dev/null || true
  : > /data/adb/asb/stock_profile_active 2>/dev/null || true
  asb_stock_stop_governor
  asb_stock_release_profile_leases
  asb_stock_restore_profile_runtime
  command -v asb_log >/dev/null 2>&1 && \
    asb_log 'stock profile: native governor stopped; profile-owned baseline restored; no ASB power policy remains active'
}

asb_stock_leave() {
  rm -f /data/adb/asb/stock_profile_active 2>/dev/null || true
}

asb_stock_start_governor() {
  _asp_moddir="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
  _asp_bin="$_asp_moddir/bin/asb"
  [ -x "$_asp_bin" ] || return 1
  pgrep -f '/bin/asb$' >/dev/null 2>&1 && return 0
  nice -n 10 "$_asp_bin" >/dev/null 2>&1 &
  _asp_wait=0
  while [ "$_asp_wait" -lt 10 ]; do
    _asp_pid="$(cat /dev/.asb/governor.pid 2>/dev/null)"
    case "$_asp_pid" in ''|*[!0-9]*) : ;; *) kill -0 "$_asp_pid" 2>/dev/null && return 0 ;; esac
    sleep 0.1
    _asp_wait=$((_asp_wait + 1))
  done
  return 1
}
