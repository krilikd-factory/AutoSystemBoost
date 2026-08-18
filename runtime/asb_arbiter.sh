#!/system/bin/sh
# asb_arbiter.sh — single owner/lease contract for runtime knobs.
#
# Native governor, camera guard and shell profiles may all influence the same
# hardware policy. Shell writers source this file and call can_write/note; tools
# may use the command interface to inspect or claim a lease. This is deliberately
# stateful but not resident: no polling loop is introduced.

ASB_ARBITER_DIR="${ASB_ARBITER_DIR:-/dev/.asb/arbiter}"
ASB_ARBITER_EVENTS="${ASB_ARBITER_EVENTS:-/data/adb/asb/arbiter_events.jsonl}"
ASB_ARBITER_LOCK="${ASB_ARBITER_LOCK:-$ASB_ARBITER_DIR/.lock}"
ASB_CAMERA_GUARD="${ASB_CAMERA_GUARD:-/dev/.asb/camera_guard}"

asb_arbiter_now() { date +%s 2>/dev/null || echo 0; }
asb_arbiter_die() { echo "asb_arbiter: $*" >&2; return 1; }

asb_arbiter_safe_token() {
  case "$1" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
  return 0
}

asb_arbiter_priority() {
  case "$1" in
    baseline) echo 10 ;;
    smart) echo 20 ;;
    profile) echo 30 ;;
    user_cap) echo 40 ;;
    camera) echo 60 ;;
    safety) echo 80 ;;
    platform_thermal) echo 100 ;;
    *) return 1 ;;
  esac
}

asb_arbiter_lock() {
  mkdir -p "$ASB_ARBITER_DIR" 2>/dev/null || return 1
  _arb_i=0
  while ! mkdir "$ASB_ARBITER_LOCK" 2>/dev/null; do
    _arb_i=$((_arb_i + 1))
    [ "$_arb_i" -lt 30 ] || return 1
    sleep 0.1
  done
  trap 'rmdir "$ASB_ARBITER_LOCK" 2>/dev/null' EXIT HUP INT TERM
}

asb_arbiter_unlock() {
  rmdir "$ASB_ARBITER_LOCK" 2>/dev/null || true
  trap - EXIT HUP INT TERM
}

asb_arbiter_lease_path() {
  asb_arbiter_safe_token "$1" || return 1
  printf '%s/%s.lease' "$ASB_ARBITER_DIR" "$1"
}

asb_arbiter_read_field() {
  _arb_path="$1" _arb_key="$2"
  [ -r "$_arb_path" ] || return 1
  awk -F= -v k="$_arb_key" '$1==k {print substr($0, length(k)+2); exit}' "$_arb_path" 2>/dev/null
}

asb_arbiter_camera_active() { [ -f "$ASB_CAMERA_GUARD" ]; }

asb_arbiter_camera_owns() {
  case "$1" in cpuset_fg|cpuset_top|uclamp_max|uclamp_fg_max|uclamp_top_max|uclamp_bg_max|vm_swappiness) return 0 ;; esac
  return 1
}

asb_arbiter_log_event() {
  # Events are low-frequency state transitions, not per-tick writes. Keep the
  # file bounded so diagnostics never become a storage or wakeup problem.
  _arb_action="$1" _arb_resource="$2" _arb_owner="$3" _arb_priority="$4"
  _arb_reason="$5" _arb_requested="$6" _arb_applied="$7" _arb_result="$8"
  mkdir -p "${ASB_ARBITER_EVENTS%/*}" 2>/dev/null || return 0
  _arb_ts="$(asb_arbiter_now)"
  if [ -f "$ASB_ARBITER_EVENTS" ]; then
    _arb_n="$(wc -l < "$ASB_ARBITER_EVENTS" 2>/dev/null | tr -d ' ')"
    if [ "${_arb_n:-0}" -gt 512 ] 2>/dev/null; then
      tail -n 256 "$ASB_ARBITER_EVENTS" > "$ASB_ARBITER_EVENTS.tmp.$$" 2>/dev/null && mv -f "$ASB_ARBITER_EVENTS.tmp.$$" "$ASB_ARBITER_EVENTS"
    fi
  fi
  printf '{"ts":%s,"action":"%s","resource":"%s","owner":"%s","priority":%s,"reason":"%s","requested":"%s","applied":"%s","result":"%s"}\n' \
    "$_arb_ts" "$_arb_action" "$_arb_resource" "$_arb_owner" "$_arb_priority" \
    "$_arb_reason" "$_arb_requested" "$_arb_applied" "$_arb_result" >> "$ASB_ARBITER_EVENTS" 2>/dev/null || true
}

asb_arbiter_claim() {
  _arb_resource="$1" _arb_owner="$2" _arb_priority="$3" _arb_ttl="$4" _arb_reason="$5"
  asb_arbiter_safe_token "$_arb_resource" && asb_arbiter_safe_token "$_arb_owner" && asb_arbiter_safe_token "$_arb_reason" || return 1
  case "$_arb_priority" in ''|*[!0-9]*) return 1 ;; esac
  case "$_arb_ttl" in ''|*[!0-9]*) return 1 ;; esac
  _arb_now="$(asb_arbiter_now)"
  _arb_expires=$((_arb_now + _arb_ttl))
  asb_arbiter_lock || return 1
  _arb_path="$(asb_arbiter_lease_path "$_arb_resource")" || { asb_arbiter_unlock; return 1; }
  _arb_old_owner="$(asb_arbiter_read_field "$_arb_path" owner || true)"
  _arb_old_prio="$(asb_arbiter_read_field "$_arb_path" priority || true)"
  _arb_old_expires="$(asb_arbiter_read_field "$_arb_path" expires || true)"
  case "$_arb_old_prio" in ''|*[!0-9]*) _arb_old_prio=0 ;; esac
  case "$_arb_old_expires" in ''|*[!0-9]*) _arb_old_expires=0 ;; esac
  if [ "$_arb_old_expires" -gt "$_arb_now" ] 2>/dev/null && [ "$_arb_old_owner" != "$_arb_owner" ] && [ "$_arb_old_prio" -gt "$_arb_priority" ] 2>/dev/null; then
    asb_arbiter_unlock
    asb_arbiter_log_event denied "$_arb_resource" "$_arb_owner" "$_arb_priority" "$_arb_reason" - - lower_priority
    return 1
  fi
  _arb_tmp="$_arb_path.tmp.$$"
  printf 'resource=%s\nowner=%s\npriority=%s\nexpires=%s\nreason=%s\nupdated=%s\ndesired=-\napplied=-\nlast_result=claimed\nlast_error=none\nlast_update=%s\n' \
    "$_arb_resource" "$_arb_owner" "$_arb_priority" "$_arb_expires" "$_arb_reason" "$_arb_now" "$_arb_now" > "$_arb_tmp" || { rm -f "$_arb_tmp"; asb_arbiter_unlock; return 1; }
  mv -f "$_arb_tmp" "$_arb_path" || { asb_arbiter_unlock; return 1; }
  asb_arbiter_unlock
  asb_arbiter_log_event claim "$_arb_resource" "$_arb_owner" "$_arb_priority" "$_arb_reason" - - accepted
  return 0
}

asb_arbiter_release() {
  _arb_resource="$1" _arb_owner="$2"
  asb_arbiter_safe_token "$_arb_resource" && asb_arbiter_safe_token "$_arb_owner" || return 1
  asb_arbiter_lock || return 1
  _arb_path="$(asb_arbiter_lease_path "$_arb_resource")" || { asb_arbiter_unlock; return 1; }
  _arb_current="$(asb_arbiter_read_field "$_arb_path" owner || true)"
  if [ -n "$_arb_current" ] && [ "$_arb_current" != "$_arb_owner" ]; then asb_arbiter_unlock; return 1; fi
  rm -f "$_arb_path"
  asb_arbiter_unlock
  asb_arbiter_log_event release "$_arb_resource" "$_arb_owner" 0 release - - accepted
}

asb_arbiter_can_write() {
  _arb_resource="$1" _arb_owner="$2"
  asb_arbiter_safe_token "$_arb_resource" && asb_arbiter_safe_token "$_arb_owner" || return 1
  _arb_prio="$(asb_arbiter_priority "$_arb_owner" 2>/dev/null || echo 0)"
  [ "$_arb_prio" -gt 0 ] 2>/dev/null || return 1
  if asb_arbiter_camera_active && asb_arbiter_camera_owns "$_arb_resource" && [ "$_arb_owner" != "camera" ]; then
    asb_arbiter_log_event denied "$_arb_resource" "$_arb_owner" "$_arb_prio" camera_lease - - camera_active
    return 1
  fi
  _arb_path="$(asb_arbiter_lease_path "$_arb_resource")" || return 1
  _arb_now="$(asb_arbiter_now)"
  _arb_owner_now="$(asb_arbiter_read_field "$_arb_path" owner || true)"
  _arb_prio_now="$(asb_arbiter_read_field "$_arb_path" priority || true)"
  _arb_expires="$(asb_arbiter_read_field "$_arb_path" expires || true)"
  case "$_arb_prio_now" in ''|*[!0-9]*) _arb_prio_now=0 ;; esac
  case "$_arb_expires" in ''|*[!0-9]*) _arb_expires=0 ;; esac
  if [ "$_arb_expires" -gt "$_arb_now" ] 2>/dev/null && [ "$_arb_owner_now" != "$_arb_owner" ] && [ "$_arb_prio_now" -gt "$_arb_prio" ] 2>/dev/null; then
    asb_arbiter_log_event denied "$_arb_resource" "$_arb_owner" "$_arb_prio" higher_lease - - owner="$_arb_owner_now"
    return 1
  fi
  return 0
}

asb_arbiter_note() {
  _arb_resource="$1" _arb_owner="$2" _arb_reason="$3" _arb_requested="$4" _arb_applied="$5" _arb_result="$6"
  _arb_prio="$(asb_arbiter_priority "$_arb_owner" 2>/dev/null || echo 0)"
  asb_arbiter_safe_token "$_arb_resource" && asb_arbiter_safe_token "$_arb_owner" && asb_arbiter_safe_token "$_arb_reason" && asb_arbiter_safe_token "$_arb_result" || return 1
  _arb_now="$(asb_arbiter_now)"
  asb_arbiter_lock || return 1
  _arb_path="$(asb_arbiter_lease_path "$_arb_resource")" || { asb_arbiter_unlock; return 1; }
  _arb_current="$(asb_arbiter_read_field "$_arb_path" owner || true)"
  # Never let a stale/lower writer rewrite the applied state of another owner.
  if [ -n "$_arb_current" ] && [ "$_arb_current" != "$_arb_owner" ]; then
    asb_arbiter_unlock
    asb_arbiter_log_event denied "$_arb_resource" "$_arb_owner" "$_arb_prio" "$_arb_reason" "$_arb_requested" "$_arb_applied" foreign_owner
    return 1
  fi
  _arb_tmp="$_arb_path.tmp.$$"
  {
    [ -r "$_arb_path" ] && grep -Ev '^(desired|applied|last_result|last_error|last_update)=' "$_arb_path" || true
    printf 'desired=%s\napplied=%s\nlast_result=%s\nlast_error=%s\nlast_update=%s\n' \
      "${_arb_requested:--}" "${_arb_applied:--}" "$_arb_result" \
      "$([ "$_arb_result" = "applied" ] && echo none || echo "$_arb_result")" "$_arb_now"
  } > "$_arb_tmp" || { rm -f "$_arb_tmp"; asb_arbiter_unlock; return 1; }
  mv -f "$_arb_tmp" "$_arb_path" || { asb_arbiter_unlock; return 1; }
  asb_arbiter_unlock
  asb_arbiter_log_event write "$_arb_resource" "$_arb_owner" "$_arb_prio" "$_arb_reason" "$_arb_requested" "$_arb_applied" "$_arb_result"
}

asb_arbiter_status() {
  mkdir -p "$ASB_ARBITER_DIR" 2>/dev/null || return 1
  for _arb_path in "$ASB_ARBITER_DIR"/*.lease; do
    [ -r "$_arb_path" ] || continue
    printf '[%s]\n' "${_arb_path##*/}"
    cat "$_arb_path"
  done
}

# Command mode. When sourced, $0 points to the caller and this block is skipped.
case "${0##*/}" in
  asb_arbiter.sh)
    case "${1:-status}" in
      status) asb_arbiter_status ;;
      claim) shift; asb_arbiter_claim "$@" ;;
      release) shift; asb_arbiter_release "$@" ;;
      can-write) shift; asb_arbiter_can_write "$@" ;;
      *) asb_arbiter_die 'usage: status | claim RESOURCE OWNER PRIORITY TTL REASON | release RESOURCE OWNER | can-write RESOURCE OWNER' ;;
    esac
    ;;
esac
