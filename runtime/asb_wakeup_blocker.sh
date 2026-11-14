#!/system/bin/sh
# Bounded owner for the KRILIKD exact-name kernel wakeup blocker.
# No polling, pattern matching, arbitrary paths or default block rules.

ASB_WB_MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
ASB_WB_NODE="${ASB_WAKEUP_BLOCKLIST_NODE:-/sys/kernel/asb_wakeup/blocklist}"
ASB_WB_POLICY="${ASB_WAKEUP_POLICY:-$ASB_WB_MODDIR/config/wakeup_blocklist.conf}"
ASB_WB_EVENTS="${ASB_WAKEUP_EVENTS_NODE:-/sys/kernel/asb_wakeup/blocked_events}"
ASB_WB_ABI="${ASB_WAKEUP_ABI_NODE:-/sys/kernel/asb_wakeup/abi_version}"
ASB_WB_STATS="${ASB_WAKEUP_STATS_NODE:-/sys/kernel/asb_wakeup/rule_stats}"
ASB_WB_CLASS="${ASB_WAKEUP_CLASS:-/sys/class/wakeup}"
ASB_WB_OBSERVE="${ASB_WAKEUP_OBSERVE_DIR:-/data/adb/asb/wakeup_observer}"

asb_wb_valid_name() {
  [ -n "$1" ] && [ "${#1}" -le 63 ] || return 1
  case "$1" in
    *[!\ -~]*|*[[:space:]]*|*/*|*\\*) return 1 ;;
  esac
  return 0
}

asb_wb_clear() {
  [ -e "$ASB_WB_NODE" ] || { printf 'wakeup_blocker|not_exposed||\n'; return 2; }
  [ -w "$ASB_WB_NODE" ] || { printf 'wakeup_blocker|not_writable||\n'; return 1; }
  printf 'clear\n' > "$ASB_WB_NODE" 2>/dev/null || {
    printf 'wakeup_blocker|write_failed||\n'; return 1;
  }
  _wb_left="$(cat "$ASB_WB_NODE" 2>/dev/null)" && [ -z "$_wb_left" ] || {
    printf 'wakeup_blocker|readback_mismatch||\n'; return 1;
  }
  printf 'wakeup_blocker|cleared|empty|\n'
}

asb_wb_apply() {
  [ -e "$ASB_WB_NODE" ] || { printf 'wakeup_blocker|not_exposed||\n'; return 2; }
  [ -r "$ASB_WB_NODE" ] && [ -w "$ASB_WB_NODE" ] || {
    printf 'wakeup_blocker|not_writable||\n'; return 1;
  }
  [ -r "$ASB_WB_POLICY" ] || { printf 'wakeup_blocker|policy_missing||\n'; return 1; }

  _wb_tmp="${ASB_WB_POLICY}.checked.$$"
  (umask 077; printf '%s' '' > "$_wb_tmp") || { printf 'wakeup_blocker|policy_error||\n'; return 1; }
  _wb_count=0
  while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
    [ -n "$_wb_name" ] || continue
    asb_wb_valid_name "$_wb_name" || {
      rm -f "$_wb_tmp"; printf 'wakeup_blocker|invalid_name||\n'; return 1;
    }
    if grep -Fqx -e "$_wb_name" "$_wb_tmp" 2>/dev/null; then
      continue
    fi
    _wb_count=$((_wb_count + 1))
    [ "$_wb_count" -le 16 ] || {
      rm -f "$_wb_tmp"; printf 'wakeup_blocker|too_many_rules||\n'; return 1;
    }
    printf '%s\n' "$_wb_name" >> "$_wb_tmp" || {
      rm -f "$_wb_tmp"; printf 'wakeup_blocker|policy_error||\n'; return 1;
    }
  done < "$ASB_WB_POLICY"

  if [ "$_wb_count" -eq 0 ] && _wb_live="$(cat "$ASB_WB_NODE" 2>/dev/null)" && [ -z "$_wb_live" ]; then
    rm -f "$_wb_tmp"
    printf 'wakeup_blocker|applied|0|\n'
    return 0
  fi

  # ASB is the sole policy owner. A failed partial apply always falls back to empty.
  printf 'clear\n' > "$ASB_WB_NODE" 2>/dev/null || {
    rm -f "$_wb_tmp"; printf 'wakeup_blocker|write_failed||\n'; return 1;
  }
  while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
    [ -n "$_wb_name" ] || continue
    printf 'add %s\n' "$_wb_name" > "$ASB_WB_NODE" 2>/dev/null || {
      printf 'clear\n' > "$ASB_WB_NODE" 2>/dev/null || true
      rm -f "$_wb_tmp"; printf 'wakeup_blocker|write_failed||\n'; return 1;
    }
  done < "$_wb_tmp"

  if cmp -s "$_wb_tmp" "$ASB_WB_NODE"; then
    rm -f "$_wb_tmp"
    printf 'wakeup_blocker|applied|%s|\n' "$_wb_count"
    return 0
  fi
  printf 'clear\n' > "$ASB_WB_NODE" 2>/dev/null || true
  rm -f "$_wb_tmp"
  printf 'wakeup_blocker|readback_mismatch||\n'
  return 1
}

asb_wb_set() {
  # The WebUI passes names as arguments, never as a shell command or a path. Validate and
  # deduplicate the complete replacement before atomically publishing it. The kernel apply
  # below remains authoritative: a saved policy is never reported as a running rule set.
  [ "$#" -le 16 ] || { printf 'wakeup_blocker|too_many_rules||\n'; return 1; }
  _wb_dir="${ASB_WB_POLICY%/*}"
  [ "$_wb_dir" != "$ASB_WB_POLICY" ] || _wb_dir='.'
  mkdir -p "$_wb_dir" 2>/dev/null || { printf 'wakeup_blocker|policy_error||\n'; return 1; }
  _wb_new="${ASB_WB_POLICY}.new.$$"
  (umask 077; printf '%s' '' > "$_wb_new") || { printf 'wakeup_blocker|policy_error||\n'; return 1; }
  for _wb_name in "$@"; do
    asb_wb_valid_name "$_wb_name" || {
      rm -f "$_wb_new"; printf 'wakeup_blocker|invalid_name||\n'; return 1;
    }
    grep -Fqx -e "$_wb_name" "$_wb_new" 2>/dev/null && continue
    printf '%s\n' "$_wb_name" >> "$_wb_new" || {
      rm -f "$_wb_new"; printf 'wakeup_blocker|policy_error||\n'; return 1;
    }
  done
  mv -f "$_wb_new" "$ASB_WB_POLICY" 2>/dev/null || {
    rm -f "$_wb_new"; printf 'wakeup_blocker|policy_error||\n'; return 1;
  }
  asb_wb_apply
}


# On-demand observation of the standard kernel wakeup-source counters. A start snapshot
# and a later read define one explicit window; there is no timer, delay or background job.
# The counters are cumulative, so only a start/end delta is shown as window activity.
asb_wb_mono_ms() {
  awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime 2>/dev/null
}

asb_wb_snapshot() {
  _wb_snap_out="$1"
  _wb_snap_tmp="${_wb_snap_out}.new.$$"
  (umask 077; printf '%s' '' > "$_wb_snap_tmp") || return 1
  _wb_snap_found=0
  for _wb_snap_dir in "$ASB_WB_CLASS"/wakeup*; do
    [ -d "$_wb_snap_dir" ] || continue
    [ -r "$_wb_snap_dir/name" ] || continue
    _wb_snap_name="$(cat "$_wb_snap_dir/name" 2>/dev/null)"
    asb_wb_valid_name "$_wb_snap_name" || continue
    _wb_snap_active="$(cat "$_wb_snap_dir/active_count" 2>/dev/null)"
    _wb_snap_events="$(cat "$_wb_snap_dir/event_count" 2>/dev/null)"
    _wb_snap_time="$(cat "$_wb_snap_dir/total_time_ms" 2>/dev/null)"
    case "$_wb_snap_active" in ''|*[!0-9]*) continue ;; esac
    case "$_wb_snap_events" in ''|*[!0-9]*) continue ;; esac
    case "$_wb_snap_time" in ''|*[!0-9]*) continue ;; esac
    printf '%s\t%s\t%s\t%s\n' "$_wb_snap_name" "$_wb_snap_active" "$_wb_snap_events" "$_wb_snap_time" >> "$_wb_snap_tmp" || {
      rm -f "$_wb_snap_tmp"; return 1;
    }
    _wb_snap_found=1
  done
  [ "$_wb_snap_found" = 1 ] || { rm -f "$_wb_snap_tmp"; return 1; }
  mv -f "$_wb_snap_tmp" "$_wb_snap_out"
}

asb_wb_observe_start() {
  [ -d "$ASB_WB_CLASS" ] || return 0
  mkdir -p "$ASB_WB_OBSERVE" 2>/dev/null || return 1
  chmod 700 "$ASB_WB_OBSERVE" 2>/dev/null || true
  asb_wb_snapshot "$ASB_WB_OBSERVE/baseline.tsv.new" || return 1
  _wb_obs_now="$(asb_wb_mono_ms)"
  case "$_wb_obs_now" in ''|*[!0-9]*) return 1 ;; esac
  (umask 077; printf 'start_mono_ms=%s\nstart_epoch=%s\n' "$_wb_obs_now" "$(date +%s)" > "$ASB_WB_OBSERVE/meta.new.$$") || return 1
  mv -f "$ASB_WB_OBSERVE/baseline.tsv.new" "$ASB_WB_OBSERVE/baseline.tsv" || return 1
  mv -f "$ASB_WB_OBSERVE/meta.new.$$" "$ASB_WB_OBSERVE/meta" || return 1
  rm -f "$ASB_WB_OBSERVE/delta.tsv" 2>/dev/null || true
  return 0
}

asb_wb_observe_clear() {
  rm -f "$ASB_WB_OBSERVE/baseline.tsv" "$ASB_WB_OBSERVE/meta" "$ASB_WB_OBSERVE/delta.tsv" 2>/dev/null || true
}

asb_wb_observe_status() {
  _wb_obs_state=idle
  [ -d "$ASB_WB_CLASS" ] || _wb_obs_state=not_exposed
  if [ "$_wb_obs_state" = idle ] && [ ! -r "$ASB_WB_OBSERVE/baseline.tsv" ]; then
    printf 'wakeup_observe|status|state=idle|elapsed_ms=0|started=0|sources=0|resets=0\n'
    return 0
  fi
  if [ "$_wb_obs_state" = not_exposed ]; then
    printf 'wakeup_observe|status|state=not_exposed|elapsed_ms=0|started=0|sources=0|resets=0\n'
    return 0
  fi
  _wb_obs_start=0; _wb_obs_epoch=0
  if [ -r "$ASB_WB_OBSERVE/meta" ]; then
    _wb_obs_start="$(sed -n 's/^start_mono_ms=//p' "$ASB_WB_OBSERVE/meta" 2>/dev/null | head -1)"
    _wb_obs_epoch="$(sed -n 's/^start_epoch=//p' "$ASB_WB_OBSERVE/meta" 2>/dev/null | head -1)"
  fi
  case "$_wb_obs_start:$_wb_obs_epoch" in *[!0-9:]*) _wb_obs_start=0; _wb_obs_epoch=0 ;; esac
  _wb_obs_now="$(asb_wb_mono_ms)"
  case "$_wb_obs_now" in ''|*[!0-9]*) _wb_obs_now="$_wb_obs_start" ;; esac
  _wb_obs_elapsed=$((_wb_obs_now - _wb_obs_start)); [ "$_wb_obs_elapsed" -ge 0 ] || _wb_obs_elapsed=0
  _wb_obs_delta="$ASB_WB_OBSERVE/delta.tsv.new.$$"
  if ! asb_wb_snapshot "$ASB_WB_OBSERVE/current.tsv.new"; then
    printf 'wakeup_observe|status|state=not_readable|elapsed_ms=%s|started=%s|sources=0|resets=0\n' "$_wb_obs_elapsed" "$_wb_obs_epoch"
    return 0
  fi
  awk -F '\t' '
    NR == FNR { a[$1]=$2; e[$1]=$3; t[$1]=$4; next }
    {
      da=$2-a[$1]; de=$3-e[$1]; dt=$4-t[$1]; reset=0
      if ($2<a[$1] || $3<e[$1] || $4<t[$1]) { da=$2; de=$3; dt=$4; reset=1 }
      if (da>0 || de>0 || dt>0 || reset) printf "%s\t%d\t%d\t%d\t%d\n", $1,da,de,dt,reset
    }
  ' "$ASB_WB_OBSERVE/baseline.tsv" "$ASB_WB_OBSERVE/current.tsv.new" > "$_wb_obs_delta" || {
    rm -f "$ASB_WB_OBSERVE/current.tsv.new" "$_wb_obs_delta"; return 1;
  }
  _wb_obs_count=0; _wb_obs_resets=0
  while IFS='	' read -r _wb_obs_name _wb_obs_active _wb_obs_events _wb_obs_time _wb_obs_reset; do
    [ -n "$_wb_obs_name" ] || continue
    printf 'wakeup_source|%s|events=%s|active=%s|time_ms=%s|reset=%s\n' \
      "$_wb_obs_name" "$_wb_obs_events" "$_wb_obs_active" "$_wb_obs_time" "$_wb_obs_reset"
    _wb_obs_count=$((_wb_obs_count + 1)); [ "$_wb_obs_reset" != 1 ] || _wb_obs_resets=$((_wb_obs_resets + 1))
  done < "$_wb_obs_delta"
  rm -f "$ASB_WB_OBSERVE/current.tsv.new" "$_wb_obs_delta"
  printf 'wakeup_observe|status|state=measuring|elapsed_ms=%s|started=%s|sources=%s|resets=%s\n' \
    "$_wb_obs_elapsed" "$_wb_obs_epoch" "$_wb_obs_count" "$_wb_obs_resets"
}

asb_wb_status() {
  _wb_node_state=writable
  if [ ! -e "$ASB_WB_NODE" ]; then _wb_node_state=not_exposed
  elif [ ! -r "$ASB_WB_NODE" ]; then _wb_node_state=not_readable
  elif [ ! -w "$ASB_WB_NODE" ]; then _wb_node_state=not_writable
  fi
  _wb_abi=legacy; _wb_stats=not_exposed
  if [ -r "$ASB_WB_ABI" ]; then
    _wb_abi="$(cat "$ASB_WB_ABI" 2>/dev/null | tr -d ' \t\r\n')"
    case "$_wb_abi" in ''|*[!0-9]*) _wb_abi=unknown ;; esac
  fi
  [ -r "$ASB_WB_STATS" ] && _wb_stats=ready
  _wb_events=unknown
  if [ -r "$ASB_WB_EVENTS" ]; then
    _wb_events="$(cat "$ASB_WB_EVENTS" 2>/dev/null | tr -d ' \t\r\n')"
    case "$_wb_events" in ''|*[!0-9]*) _wb_events=unknown ;; esac
  fi
  _wb_policy_state=empty
  _wb_saved_count=0
  if [ ! -e "$ASB_WB_POLICY" ]; then _wb_policy_state=missing
  elif [ ! -r "$ASB_WB_POLICY" ]; then _wb_policy_state=not_readable
  elif [ -s "$ASB_WB_POLICY" ]; then _wb_policy_state=ready
  fi
  if [ "$_wb_policy_state" = ready ]; then
    while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
      [ -n "$_wb_name" ] || continue
      _wb_saved_count=$((_wb_saved_count + 1))
    done < "$ASB_WB_POLICY"
  fi
  _wb_current_count=0
  _wb_rules=''
  if [ "$_wb_node_state" = writable ] || [ "$_wb_node_state" = not_writable ]; then
    _wb_rules="$(cat "$ASB_WB_NODE" 2>/dev/null)"
    while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
      [ -n "$_wb_name" ] || continue
      _wb_current_count=$((_wb_current_count + 1))
    done <<ASB_WB_RULES
$_wb_rules
ASB_WB_RULES
  fi
  printf 'wakeup_blocker|status|blocked_events=%s|node=%s|policy=%s|saved_count=%s|current_count=%s|abi=%s|rule_stats=%s\n' \
    "$_wb_events" "$_wb_node_state" "$_wb_policy_state" "$_wb_saved_count" "$_wb_current_count" "$_wb_abi" "$_wb_stats"
  if [ "$_wb_policy_state" = ready ]; then
    while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
      [ -n "$_wb_name" ] || continue
      printf 'wakeup_rule|saved|%s\n' "$_wb_name"
    done < "$ASB_WB_POLICY"
  fi
  if [ "$_wb_node_state" = writable ] || [ "$_wb_node_state" = not_writable ]; then
    while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
      [ -n "$_wb_name" ] || continue
      printf 'wakeup_rule|current|%s\n' "$_wb_name"
    done <<ASB_WB_RULES
$_wb_rules
ASB_WB_RULES
  fi
  if [ "$_wb_stats" = ready ]; then
    while IFS='	' read -r _wb_name _wb_count || [ -n "$_wb_name" ]; do
      asb_wb_valid_name "$_wb_name" || continue
      case "$_wb_count" in ''|*[!0-9]*) continue ;; esac
      printf 'wakeup_rule|blocked|%s|%s
' "$_wb_name" "$_wb_count"
    done < "$ASB_WB_STATS"
  fi
  asb_wb_observe_status
  [ "$_wb_node_state" != not_exposed ] || return 2
  return 0
}

case "${1:-status}" in
  apply) asb_wb_apply ;;
  set) shift; asb_wb_set "$@" ;;
  clear) asb_wb_clear ;;
  status) asb_wb_status ;;
  observe_start) asb_wb_observe_start && asb_wb_status ;;
  observe_clear) asb_wb_observe_clear; asb_wb_status ;;
  *) printf 'usage: asb_wakeup_blocker.sh apply|set [NAME...]|clear|status|observe_start|observe_clear\n' >&2; exit 2 ;;
esac
