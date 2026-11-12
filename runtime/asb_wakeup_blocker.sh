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
  [ ! -s "$ASB_WB_NODE" ] || {
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
    if grep -Fqx "$_wb_name" "$_wb_tmp" 2>/dev/null; then
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

asb_wb_status() {
  [ -e "$ASB_WB_NODE" ] || { printf 'wakeup_blocker|not_exposed||\n'; return 2; }
  _wb_rules=''
  [ -r "$ASB_WB_NODE" ] && _wb_rules="$(cat "$ASB_WB_NODE" 2>/dev/null)"
  _wb_events='unknown'
  [ -r "$ASB_WB_EVENTS" ] && _wb_events="$(cat "$ASB_WB_EVENTS" 2>/dev/null)"
  printf 'wakeup_blocker|status|blocked_events=%s|\n%s\n' "${_wb_events:-unknown}" "$_wb_rules"
}

case "${1:-status}" in
  apply) asb_wb_apply ;;
  clear) asb_wb_clear ;;
  status) asb_wb_status ;;
  *) printf 'usage: asb_wakeup_blocker.sh apply|clear|status\n' >&2; exit 2 ;;
esac
