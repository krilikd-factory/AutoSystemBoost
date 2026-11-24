#!/system/bin/sh
# Bounded owner for the KRILIKD exact-name kernel wakeup blocker.
# No polling, pattern matching, arbitrary paths or default block rules.

ASB_WB_MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
ASB_WB_NODE="${ASB_WAKEUP_BLOCKLIST_NODE:-/sys/kernel/asb_wakeup/blocklist}"
ASB_WB_POLICY="${ASB_WAKEUP_POLICY:-$ASB_WB_MODDIR/config/wakeup_blocklist.conf}"
ASB_WB_SLEEP_POLICY="${ASB_WAKEUP_SLEEP_POLICY:-$ASB_WB_MODDIR/config/wakeup_blocklist_sleep.conf}"
ASB_WB_EVENTS="${ASB_WAKEUP_EVENTS_NODE:-/sys/kernel/asb_wakeup/blocked_events}"
ASB_WB_ABI="${ASB_WAKEUP_ABI_NODE:-/sys/kernel/asb_wakeup/abi_version}"
ASB_WB_STATS="${ASB_WAKEUP_STATS_NODE:-/sys/kernel/asb_wakeup/rule_stats}"
ASB_WB_CLASS="${ASB_WAKEUP_CLASS:-/sys/class/wakeup}"
ASB_WB_OBSERVE="${ASB_WAKEUP_OBSERVE_DIR:-/data/adb/asb/wakeup_observer}"
ASB_WB_MODE_STATE="${ASB_WAKEUP_MODE_STATE:-/dev/.asb/wakeup_blocker_mode}"

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
  rm -f "$ASB_WB_MODE_STATE" 2>/dev/null || true
  printf 'wakeup_blocker|cleared|empty|\n'
}

# Screen off is a bounded UI/window state, not a claim about CPU suspend or deep sleep.
# Unknown/unreadable state deliberately selects only the always list.
asb_wb_screen() {
  if [ -n "${ASB_WAKEUP_SCREEN_STATE:-}" ]; then
    case "$ASB_WAKEUP_SCREEN_STATE" in on|off) printf '%s\n' "$ASB_WAKEUP_SCREEN_STATE"; return 0 ;; esac
  fi
  if [ -r /dev/.asb/state ]; then
    case "$(sed -n 's/^screen=//p' /dev/.asb/state 2>/dev/null | head -1)" in
      1) printf 'on\n'; return 0 ;;
      0) printf 'off\n'; return 0 ;;
    esac
  fi
  case "$(dumpsys deviceidle get screen 2>/dev/null | head -1)" in
    true) printf 'on\n'; return 0 ;;
    false|Asleep) printf 'off\n'; return 0 ;;
  esac
  printf 'unknown\n'
}

asb_wb_policy_append() {
  [ -r "$1" ] || return 0
  while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
    [ -n "$_wb_name" ] || continue
    asb_wb_valid_name "$_wb_name" || return 1
    grep -Fqx -e "$_wb_name" "$2" 2>/dev/null && continue
    _wb_count=$((_wb_count + 1))
    [ "$_wb_count" -le 16 ] || return 2
    printf '%s\n' "$_wb_name" >> "$2" || return 3
  done < "$1"
  return 0
}

asb_wb_apply() {
  _wb_req="${1:-auto}"
  case "$_wb_req" in auto|on|off) ;; *) printf 'wakeup_blocker|bad_mode||\n'; return 2 ;; esac
  [ -e "$ASB_WB_NODE" ] || { printf 'wakeup_blocker|not_exposed||\n'; return 2; }
  [ -r "$ASB_WB_NODE" ] && [ -w "$ASB_WB_NODE" ] || {
    printf 'wakeup_blocker|not_writable||\n'; return 1;
  }
  [ -r "$ASB_WB_POLICY" ] || { printf 'wakeup_blocker|policy_missing||\n'; return 1; }
  _wb_screen="$(asb_wb_screen)"
  [ "$_wb_req" = auto ] && _wb_req="$_wb_screen"
  [ "$_wb_req" = off ] && [ "$_wb_screen" != off ] && [ -z "${ASB_WAKEUP_FORCE_MODE:-}" ] && _wb_req=on
  _wb_tmp="${ASB_WB_POLICY}.checked.$$"
  (umask 077; printf '%s' '' > "$_wb_tmp") || { printf 'wakeup_blocker|policy_error||\n'; return 1; }
  _wb_count=0
  asb_wb_policy_append "$ASB_WB_POLICY" "$_wb_tmp"
  _wb_rc=$?
  if [ "$_wb_rc" -eq 0 ] && [ "$_wb_req" = off ]; then
    asb_wb_policy_append "$ASB_WB_SLEEP_POLICY" "$_wb_tmp"
    _wb_rc=$?
  fi
  case "$_wb_rc" in
    0) : ;;
    2) rm -f "$_wb_tmp"; printf 'wakeup_blocker|too_many_rules||\n'; return 1 ;;
    1) rm -f "$_wb_tmp"; printf 'wakeup_blocker|invalid_name||\n'; return 1 ;;
    *) rm -f "$_wb_tmp"; printf 'wakeup_blocker|policy_error||\n'; return 1 ;;
  esac
  _wb_sig="$(cksum "$ASB_WB_POLICY" "$ASB_WB_SLEEP_POLICY" 2>/dev/null)"
  _wb_saved_sig=''; [ -r "$ASB_WB_MODE_STATE" ] && _wb_saved_sig="$(cat "$ASB_WB_MODE_STATE" 2>/dev/null)"
  if cmp -s "$_wb_tmp" "$ASB_WB_NODE"; then
    rm -f "$_wb_tmp"; printf 'wakeup_blocker|applied|%s|%s\n' "$_wb_count" "$_wb_req"; return 0
  fi

  # ASB is the sole live policy owner. A partial write or readback mismatch clears the list.
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
    _wb_state_dir="${ASB_WB_MODE_STATE%/*}"; [ "$_wb_state_dir" != "$ASB_WB_MODE_STATE" ] || _wb_state_dir='.'
    mkdir -p "$_wb_state_dir" 2>/dev/null || true
    if (umask 077; printf '%s|%s\n' "$_wb_req" "$_wb_sig" 2>/dev/null > "$ASB_WB_MODE_STATE.new.$$") && \
      mv -f "$ASB_WB_MODE_STATE.new.$$" "$ASB_WB_MODE_STATE" 2>/dev/null; then :; else
      rm -f "$ASB_WB_MODE_STATE.new.$$"
    fi
    printf 'wakeup_blocker|applied|%s|%s\n' "$_wb_count" "$_wb_req"
    return 0
  fi
  printf 'clear\n' > "$ASB_WB_NODE" 2>/dev/null || true
  rm -f "$_wb_tmp" "$ASB_WB_MODE_STATE"
  printf 'wakeup_blocker|readback_mismatch||\n'
  return 1
}

asb_wb_set_locked() {
  _wb_always_new="${ASB_WB_POLICY}.new.$$"
  _wb_sleep_new="${ASB_WB_SLEEP_POLICY}.new.$$"
  _wb_dir="${ASB_WB_POLICY%/*}"; [ "$_wb_dir" != "$ASB_WB_POLICY" ] || _wb_dir='.'
  mkdir -p "$_wb_dir" 2>/dev/null || { printf 'wakeup_blocker|policy_error||\n'; return 1; }
  (umask 077; printf '%s' '' > "$_wb_always_new"; printf '%s' '' > "$_wb_sleep_new") || {
    rm -f "$_wb_always_new" "$_wb_sleep_new"; printf 'wakeup_blocker|policy_error||\n'; return 1;
  }
  _wb_kind=always; _wb_total=0
  while [ "$#" -gt 0 ]; do
    case "$1" in --always) _wb_kind=always; shift; continue ;; --sleep) _wb_kind=sleep; shift; continue ;; esac
    asb_wb_valid_name "$1" || {
      rm -f "$_wb_always_new" "$_wb_sleep_new"; printf 'wakeup_blocker|invalid_name||\n'; return 1;
    }
    _wb_total=$((_wb_total + 1)); [ "$_wb_total" -le 32 ] || {
      rm -f "$_wb_always_new" "$_wb_sleep_new"; printf 'wakeup_blocker|too_many_rules||\n'; return 1;
    }
    if [ "$_wb_kind" = always ]; then _wb_dest="$_wb_always_new"; else _wb_dest="$_wb_sleep_new"; fi
    grep -Fqx -e "$1" "$_wb_dest" 2>/dev/null || printf '%s\n' "$1" >> "$_wb_dest"
    shift
  done
  # The union must fit the kernel even when every sleep-only name is active.
  _wb_union="${ASB_WB_POLICY}.union.$$"
  (umask 077; printf '%s' '' > "$_wb_union") || {
    rm -f "$_wb_always_new" "$_wb_sleep_new" "$_wb_union"
    printf 'wakeup_blocker|policy_error||\n'; return 1;
  }
  cat "$_wb_always_new" "$_wb_sleep_new" 2>/dev/null | while IFS= read -r _wb_name; do
    [ -n "$_wb_name" ] && ! grep -Fqx -e "$_wb_name" "$_wb_union" 2>/dev/null && printf '%s\n' "$_wb_name" >> "$_wb_union"
  done
  _wb_n="$(grep -c . "$_wb_union" 2>/dev/null)"; rm -f "$_wb_union"
  [ "${_wb_n:-0}" -le 16 ] || { rm -f "$_wb_always_new" "$_wb_sleep_new"; printf 'wakeup_blocker|too_many_rules||\n'; return 1; }
  mv -f "$_wb_always_new" "$ASB_WB_POLICY" && mv -f "$_wb_sleep_new" "$ASB_WB_SLEEP_POLICY" || {
    rm -f "$_wb_always_new" "$_wb_sleep_new"; printf 'wakeup_blocker|policy_error||\n'; return 1;
  }
  rm -f "$ASB_WB_MODE_STATE" 2>/dev/null || true
  asb_wb_apply auto
}

asb_wb_set() {
  # Serialize policy replacement and kernel application. A live owner returns busy;
  # a stale PID from an interrupted save is recovered without hiding real errors.
  _wb_lock="${ASB_WB_POLICY}.lock"
  if ! mkdir "$_wb_lock" 2>/dev/null; then
    _wb_owner="$(cat "$_wb_lock/pid" 2>/dev/null)"
    case "$_wb_owner" in ''|*[!0-9]*) _wb_owner=0 ;; esac
    if [ "$_wb_owner" -gt 1 ] && kill -0 "$_wb_owner" 2>/dev/null; then
      printf 'wakeup_blocker|busy||\n'
      return 75
    fi
    rm -f "$_wb_lock/pid" 2>/dev/null || true
    rmdir "$_wb_lock" 2>/dev/null || true
    mkdir "$_wb_lock" 2>/dev/null || {
      printf 'wakeup_blocker|busy||\n'
      return 75
    }
  fi
  printf '%s\n' "$$" > "$_wb_lock/pid" 2>/dev/null || {
    rmdir "$_wb_lock" 2>/dev/null || true
    printf 'wakeup_blocker|policy_error||\n'
    return 1
  }
  asb_wb_set_locked "$@"
  _wb_rc=$?
  rm -f "$_wb_lock/pid" 2>/dev/null || true
  rmdir "$_wb_lock" 2>/dev/null || true
  return "$_wb_rc"
}

asb_wb_mono_ms() {
  awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime 2>/dev/null
}

asb_wb_snapshot() {
  _wb_snap_out="$1"
  _wb_snap_tmp="${_wb_snap_out}.new.$$"
  (umask 077; printf '%s' '' > "$_wb_snap_tmp") || return 1
  set -- "$ASB_WB_CLASS"/wakeup*
  [ -d "$1" ] || { rm -f "$_wb_snap_tmp"; return 1; }
  for _wb_snap_dir in "$@"; do
    printf '%s\n' "$_wb_snap_dir/name" "$_wb_snap_dir/active_count" "$_wb_snap_dir/event_count" "$_wb_snap_dir/total_time_ms"
  done | xargs grep -H '' 2>/dev/null | awk '
    {
      i = index($0, ":"); if (i < 2) next
      p = substr($0, 1, i - 1); v = substr($0, i + 1)
      n = split(p, a, "/"); if (n < 2) next
      id = a[n - 1]; f = a[n]
      if (id !~ /^wakeup[0-9]+$/) next
      if (f == "name") {
        if (length(v) < 1 || length(v) > 63 || v !~ /^[!-~]+$/ || v ~ /[\/\\]/) next
        nm[id] = v
      } else if (v ~ /^[0-9]+$/) {
        if (f == "active_count") ac[id] = v
        else if (f == "event_count") ev[id] = v
        else if (f == "total_time_ms") tt[id] = v
      }
    }
    END {
      c = 0
      for (id in nm) if ((id in ac) && (id in ev) && (id in tt)) { printf "%s\t%s\t%s\t%s\t%s\n", id, nm[id], ac[id], ev[id], tt[id]; c++ }
      exit c ? 0 : 1
    }' > "$_wb_snap_tmp" || { rm -f "$_wb_snap_tmp"; return 1; }
  mv -f "$_wb_snap_tmp" "$_wb_snap_out"
}

asb_wb_observe_start() {
  [ -d "$ASB_WB_CLASS" ] || return 0
  mkdir -p "$ASB_WB_OBSERVE" 2>/dev/null || return 1
  chmod 700 "$ASB_WB_OBSERVE" 2>/dev/null || true
  asb_wb_snapshot "$ASB_WB_OBSERVE/baseline.tsv.new" || return 1
  _wb_obs_now="$(asb_wb_mono_ms)"
  case "$_wb_obs_now" in ''|*[!0-9]*) return 1 ;; esac
  (umask 077; printf 'format=2\nstart_mono_ms=%s\nstart_epoch=%s\n' "$_wb_obs_now" "$(date +%s)" > "$ASB_WB_OBSERVE/meta.new.$$") || return 1
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
  if [ "$_wb_obs_state" = idle ] && ! grep -qx 'format=2' "$ASB_WB_OBSERVE/meta" 2>/dev/null; then
    asb_wb_observe_clear
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
    NR == FNR { bn[$1]=$2; a[$1]=$3; e[$1]=$4; t[$1]=$5; next }
    {
      shared[$2]++
      fresh = !($1 in bn) || bn[$1] != $2
      if (fresh) { da=$3; de=$4; dt=$5; reset=0 }
      else {
        da=$3-a[$1]; de=$4-e[$1]; dt=$5-t[$1]; reset=0
        if (da<0 || de<0 || dt<0) { da=$3; de=$4; dt=$5; reset=1 }
      }
      if (da>0 || de>0 || dt>0 || reset) {
        if (!($2 in sa)) order[++no]=$2
        sa[$2]+=da; se[$2]+=de; st[$2]+=dt
        if (reset) sr[$2]=1
        if (fresh) sn[$2]=1
      }
    }
    END {
      for (k=1; k<=no; k++) { nme=order[k]
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", nme, sa[nme], se[nme], st[nme], (nme in sr) ? 1 : 0, shared[nme], (nme in sn) ? 1 : 0
      }
    }
  ' "$ASB_WB_OBSERVE/baseline.tsv" "$ASB_WB_OBSERVE/current.tsv.new" > "$_wb_obs_delta" || {
    rm -f "$ASB_WB_OBSERVE/current.tsv.new" "$_wb_obs_delta"; return 1;
  }
  _wb_obs_count=0; _wb_obs_resets=0
  while IFS='	' read -r _wb_obs_name _wb_obs_active _wb_obs_events _wb_obs_time _wb_obs_reset _wb_obs_shared _wb_obs_new; do
    [ -n "$_wb_obs_name" ] || continue
    printf 'wakeup_source|%s|events=%s|active=%s|time_ms=%s|reset=%s|shared=%s|new=%s\n' \
      "$_wb_obs_name" "$_wb_obs_events" "$_wb_obs_active" "$_wb_obs_time" "$_wb_obs_reset" "$_wb_obs_shared" "$_wb_obs_new"
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
  _wb_sleep_state=empty
  _wb_sleep_count=0
  if [ ! -e "$ASB_WB_SLEEP_POLICY" ]; then _wb_sleep_state=missing
  elif [ ! -r "$ASB_WB_SLEEP_POLICY" ]; then _wb_sleep_state=not_readable
  elif [ -s "$ASB_WB_SLEEP_POLICY" ]; then _wb_sleep_state=ready
  fi
  if [ "$_wb_sleep_state" = ready ]; then
    while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
      [ -n "$_wb_name" ] || continue
      _wb_sleep_count=$((_wb_sleep_count + 1))
    done < "$ASB_WB_SLEEP_POLICY"
  fi
  _wb_status_screen="$(asb_wb_screen)"
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
  printf 'wakeup_blocker|status|blocked_events=%s|node=%s|policy=%s|sleep_policy=%s|saved_count=%s|sleep_count=%s|current_count=%s|screen=%s|abi=%s|rule_stats=%s\n' \
    "$_wb_events" "$_wb_node_state" "$_wb_policy_state" "$_wb_sleep_state" "$_wb_saved_count" "$_wb_sleep_count" "$_wb_current_count" "$_wb_status_screen" "$_wb_abi" "$_wb_stats"
  if [ "$_wb_policy_state" = ready ]; then
    while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
      [ -n "$_wb_name" ] || continue
      printf 'wakeup_rule|saved|%s\n' "$_wb_name"
      printf 'wakeup_rule|saved_always|%s\n' "$_wb_name"
    done < "$ASB_WB_POLICY"
  fi
  if [ "$_wb_sleep_state" = ready ]; then
    while IFS= read -r _wb_name || [ -n "$_wb_name" ]; do
      [ -n "$_wb_name" ] || continue
      printf 'wakeup_rule|saved_sleep|%s\n' "$_wb_name"
    done < "$ASB_WB_SLEEP_POLICY"
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
      printf 'wakeup_rule|blocked|%s|%s\n' "$_wb_name" "$_wb_count"
    done < "$ASB_WB_STATS"
  fi
  asb_wb_observe_status
  [ "$_wb_node_state" != not_exposed ] || return 2
  return 0
}

case "${1:-status}" in
  apply) shift; asb_wb_apply "${1:-auto}" ;;
  set) shift; asb_wb_set "$@" ;;
  clear) asb_wb_clear ;;
  status) asb_wb_status ;;
  observe_start) asb_wb_observe_start && asb_wb_status ;;
  observe_clear) asb_wb_observe_clear; asb_wb_status ;;
  *) printf 'usage: asb_wakeup_blocker.sh apply [auto|on|off]|set [--always NAME...] [--sleep NAME...]|clear|status|observe_start|observe_clear\n' >&2; exit 2 ;;
esac
