#!/system/bin/sh
# Bounded owner for the KRILIKD exact-name kernel wakeup blocker.
# No polling, pattern matching, arbitrary paths or default block rules.

ASB_WB_MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
ASB_WB_NODE="${ASB_WAKEUP_BLOCKLIST_NODE:-/sys/kernel/asb_wakeup/blocklist}"
ASB_WB_POLICY="${ASB_WAKEUP_POLICY:-$ASB_WB_MODDIR/config/wakeup_blocklist.conf}"
ASB_WB_EVENTS="${ASB_WAKEUP_EVENTS_NODE:-/sys/kernel/asb_wakeup/blocked_events}"

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

asb_wb_status() {
  _wb_node_state=writable
  if [ ! -e "$ASB_WB_NODE" ]; then _wb_node_state=not_exposed
  elif [ ! -r "$ASB_WB_NODE" ]; then _wb_node_state=not_readable
  elif [ ! -w "$ASB_WB_NODE" ]; then _wb_node_state=not_writable
  fi
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
  printf 'wakeup_blocker|status|blocked_events=%s|node=%s|policy=%s|saved_count=%s|current_count=%s\n' \
    "$_wb_events" "$_wb_node_state" "$_wb_policy_state" "$_wb_saved_count" "$_wb_current_count"
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
  [ "$_wb_node_state" != not_exposed ] || return 2
  return 0
}

case "${1:-status}" in
  apply) asb_wb_apply ;;
  set) shift; asb_wb_set "$@" ;;
  clear) asb_wb_clear ;;
  status) asb_wb_status ;;
  *) printf 'usage: asb_wakeup_blocker.sh apply|set [NAME...]|clear|status\n' >&2; exit 2 ;;
esac
