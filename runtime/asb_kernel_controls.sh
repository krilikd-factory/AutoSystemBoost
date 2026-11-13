#!/system/bin/sh

ASB_KC_MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
ASB_KC_CONF="${ASB_CONF:-$ASB_KC_MODDIR/config/governor.conf}"
ASB_KC_STATE="${ASB_KERNEL_STATE_DIR:-/data/adb/asb/kernel_controls}"

asb_kc_node() {
  case "$1" in
    mglru_mode) printf '%s\n' "${ASB_MGLRU_ENABLED_NODE:-/sys/kernel/mm/lru_gen/enabled}" ;;
    kernel_timer_migration) printf '%s\n' "${ASB_TIMER_MIGRATION_NODE:-/proc/sys/kernel/timer_migration}" ;;
    kernel_sched_nr_migrate) printf '%s\n' "${ASB_SCHED_NR_MIGRATE_NODE:-/sys/kernel/debug/sched/nr_migrate}" ;;
    kernel_sched_stats) printf '%s\n' "${ASB_SCHED_STATS_NODE:-/proc/sys/kernel/sched_schedstats}" ;;
    kernel_sched_autogroup) printf '%s\n' "${ASB_SCHED_AUTOGROUP_NODE:-/proc/sys/kernel/sched_autogroup_enabled}" ;;
    kernel_sched_child_runs_first) printf '%s\n' "${ASB_SCHED_CHILD_RUNS_FIRST_NODE:-/proc/sys/kernel/sched_child_runs_first}" ;;
    *) return 1 ;;
  esac
}

asb_kc_clean() { printf '%s' "$1" | tr -d ' \t\r\n'; }

asb_kc_mode() {
  _akm_v="$(grep -E "^[[:space:]]*$1=" "$ASB_KC_CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \t\r\n')"
  case "$1:$_akm_v" in
    mglru_mode:stock|mglru_mode:off|mglru_mode:on|mglru_mode:smart) ;;
    mglru_mode:*) _akm_v=smart ;;
    kernel_timer_migration:stock|kernel_timer_migration:off|kernel_timer_migration:on) ;;
    kernel_timer_migration:*) _akm_v=off ;;
    kernel_sched_nr_migrate:stock|kernel_sched_nr_migrate:1|kernel_sched_nr_migrate:2|kernel_sched_nr_migrate:4|kernel_sched_nr_migrate:8|kernel_sched_nr_migrate:16) ;;
    kernel_sched_nr_migrate:*) _akm_v=4 ;;
    kernel_sched_stats:stock|kernel_sched_stats:off) ;;
    kernel_sched_stats:*) _akm_v=stock ;;
    kernel_sched_autogroup:stock|kernel_sched_autogroup:off|kernel_sched_autogroup:on) ;;
    kernel_sched_autogroup:*) _akm_v=stock ;;
    kernel_sched_child_runs_first:stock|kernel_sched_child_runs_first:off|kernel_sched_child_runs_first:on) ;;
    kernel_sched_child_runs_first:*) _akm_v=stock ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$_akm_v"
}

asb_kc_valid_value() {
  _akv_key="$1" _akv_v="$2"
  case "$_akv_key" in
    kernel_timer_migration|kernel_sched_stats|kernel_sched_autogroup|kernel_sched_child_runs_first) case "$_akv_v" in 0|1) return 0 ;; *) return 1 ;; esac ;;
    kernel_sched_nr_migrate)
      case "$_akv_v" in ''|*[!0-9]*) return 1 ;; esac
      [ "${#_akv_v}" -le 9 ]
      ;;
    mglru_mode)
      case "$_akv_v" in
        ''|*[!0-9A-Za-z]*) return 1 ;;
        0[xX]*)
          _akv_h="${_akv_v#??}"
          case "$_akv_h" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
          [ "${#_akv_h}" -le 8 ]
          ;;
        *[!0-9]*) return 1 ;;
        *) [ "${#_akv_v}" -le 9 ] ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

asb_kc_number() {
  _akn_v="$1"
  case "$_akn_v" in
    0[xX]*) printf '%d\n' "$_akn_v" 2>/dev/null ;;
    ''|*[!0-9]*) return 1 ;;
    *) printf '%d\n' "$_akn_v" 2>/dev/null ;;
  esac
}

asb_kc_same() {
  _aks_a="$(asb_kc_number "$1")" || return 1
  _aks_b="$(asb_kc_number "$2")" || return 1
  [ "$_aks_a" = "$_aks_b" ]
}

asb_kc_prev() {
  if [ "$1" = kernel_sched_stats ] && [ -z "${ASB_KERNEL_STATE_DIR+x}" ]; then
    printf '%s\n' "${ASB_SCHED_STATS_PREV:-/data/adb/asb/kernel_sched_stats.prev}"
  else
    printf '%s/%s.prev\n' "$ASB_KC_STATE" "$1"
  fi
}

asb_kc_emit() {
  printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-unknown}" "${5:-none}"
}

asb_kc_capture() {
  _akc_key="$1" _akc_node="$2" _akc_prev="$3"
  if [ -f "$_akc_prev" ]; then
    _akc_saved="$(asb_kc_clean "$(cat "$_akc_prev" 2>/dev/null)")"
    asb_kc_valid_value "$_akc_key" "$_akc_saved" || return 1
    return 0
  fi
  _akc_orig="$(asb_kc_clean "$(cat "$_akc_node" 2>/dev/null)")"
  asb_kc_valid_value "$_akc_key" "$_akc_orig" || return 1
  mkdir -p "${_akc_prev%/*}" 2>/dev/null || return 1
  _akc_tmp="$_akc_prev.tmp.$$"
  (umask 077; printf '%s\n' "$_akc_orig" > "$_akc_tmp" 2>/dev/null) || { rm -f "$_akc_tmp" 2>/dev/null; return 1; }
  mv -f "$_akc_tmp" "$_akc_prev" 2>/dev/null || { rm -f "$_akc_tmp" 2>/dev/null; return 1; }
}

asb_kc_restore() {
  _akr_key="$1"
  _akr_node="$(asb_kc_node "$_akr_key")" || return 1
  _akr_prev="$(asb_kc_prev "$_akr_key")"
  [ -f "$_akr_prev" ] || { asb_kc_emit "$_akr_key" stock_unowned stock "" none; return 0; }
  _akr_orig="$(asb_kc_clean "$(cat "$_akr_prev" 2>/dev/null)")"
  asb_kc_valid_value "$_akr_key" "$_akr_orig" || { asb_kc_emit "$_akr_key" baseline_invalid stock "" invalid; return 1; }
  [ -e "$_akr_node" ] || { asb_kc_emit "$_akr_key" not_exposed stock "" "$_akr_orig"; return 1; }
  [ -w "$_akr_node" ] || { asb_kc_emit "$_akr_key" not_writable stock "" "$_akr_orig"; return 1; }
  printf '%s\n' "$_akr_orig" > "$_akr_node" 2>/dev/null || { asb_kc_emit "$_akr_key" write_failed stock "" "$_akr_orig"; return 1; }
  _akr_live="$(asb_kc_clean "$(cat "$_akr_node" 2>/dev/null)")"
  if asb_kc_same "$_akr_orig" "$_akr_live"; then
    rm -f "$_akr_prev" 2>/dev/null || { asb_kc_emit "$_akr_key" state_cleanup_failed stock "$_akr_live" "$_akr_orig"; return 1; }
    asb_kc_emit "$_akr_key" restored stock "$_akr_live" none
    return 0
  fi
  asb_kc_emit "$_akr_key" readback_mismatch stock "$_akr_live" "$_akr_orig"
  return 1
}

asb_kc_apply() {
  _aka_key="$1" _aka_smart="${2:-}"
  _aka_node="$(asb_kc_node "$_aka_key")" || return 1
  _aka_mode="$(asb_kc_mode "$_aka_key")" || return 1
  [ "$_aka_mode" != stock ] || { asb_kc_restore "$_aka_key"; return $?; }
  _aka_prev="$(asb_kc_prev "$_aka_key")"
  _aka_saved=none
  [ -f "$_aka_prev" ] && _aka_saved="$(asb_kc_clean "$(cat "$_aka_prev" 2>/dev/null)")"
  [ -e "$_aka_node" ] || { asb_kc_emit "$_aka_key" not_exposed "$_aka_mode" "" "$_aka_saved"; return 1; }
  [ -r "$_aka_node" ] || { asb_kc_emit "$_aka_key" not_readable "$_aka_mode" "" "$_aka_saved"; return 1; }
  [ -w "$_aka_node" ] || { asb_kc_emit "$_aka_key" not_writable "$_aka_mode" "" "$_aka_saved"; return 1; }
  case "$_aka_key:$_aka_mode" in
    mglru_mode:off) _aka_want=0 ;;
    mglru_mode:on) _aka_want=7 ;;
    mglru_mode:smart)
      case "$_aka_smart" in 5|7) _aka_want="$_aka_smart" ;; *) _aka_want=7 ;; esac
      ;;
    kernel_timer_migration:off) _aka_want=0 ;;
    kernel_timer_migration:on) _aka_want=1 ;;
    kernel_sched_stats:off|kernel_sched_child_runs_first:off) _aka_want=0 ;;
    kernel_sched_autogroup:off|kernel_sched_child_runs_first:off) _aka_want=0 ;;
    kernel_sched_autogroup:on|kernel_sched_child_runs_first:on) _aka_want=1 ;;
    kernel_sched_nr_migrate:1|kernel_sched_nr_migrate:2|kernel_sched_nr_migrate:4|kernel_sched_nr_migrate:8|kernel_sched_nr_migrate:16)
      _aka_want="$_aka_mode" ;;
    *) asb_kc_emit "$_aka_key" invalid_request "$_aka_mode" "" "$_aka_saved"; return 1 ;;
  esac
  asb_kc_capture "$_aka_key" "$_aka_node" "$_aka_prev" || { asb_kc_emit "$_aka_key" baseline_failed "$_aka_mode" "" "$_aka_saved"; return 1; }
  _aka_saved="$(asb_kc_clean "$(cat "$_aka_prev" 2>/dev/null)")"
  _aka_before="$(asb_kc_clean "$(cat "$_aka_node" 2>/dev/null)")"
  if ! asb_kc_same "$_aka_want" "$_aka_before"; then
    printf '%s\n' "$_aka_want" > "$_aka_node" 2>/dev/null || { asb_kc_emit "$_aka_key" write_failed "$_aka_mode" "$_aka_before" "$_aka_saved"; return 1; }
  fi
  _aka_live="$(asb_kc_clean "$(cat "$_aka_node" 2>/dev/null)")"
  if asb_kc_same "$_aka_want" "$_aka_live"; then
    asb_kc_emit "$_aka_key" applied "$_aka_mode" "$_aka_live" "$_aka_saved"
    return 0
  fi
  asb_kc_emit "$_aka_key" readback_mismatch "$_aka_mode" "$_aka_live" "$_aka_saved"
  return 1
}

asb_kc_status() {
  _akst_key="$1"
  _akst_node="$(asb_kc_node "$_akst_key")" || return 1
  _akst_mode="$(asb_kc_mode "$_akst_key")" || return 1
  _akst_prev="$(asb_kc_prev "$_akst_key")"
  _akst_base=none
  [ -f "$_akst_prev" ] && _akst_base="$(asb_kc_clean "$(cat "$_akst_prev" 2>/dev/null)")"
  [ -e "$_akst_node" ] || { asb_kc_emit "$_akst_key" not_exposed "$_akst_mode" "" "$_akst_base"; return 0; }
  _akst_live="$(asb_kc_clean "$(cat "$_akst_node" 2>/dev/null)")"
  if [ -r "$_akst_node" ] && [ -w "$_akst_node" ]; then
    asb_kc_emit "$_akst_key" writable "$_akst_mode" "$_akst_live" "$_akst_base"
  elif [ -r "$_akst_node" ]; then
    asb_kc_emit "$_akst_key" not_writable "$_akst_mode" "$_akst_live" "$_akst_base"
  else
    asb_kc_emit "$_akst_key" not_readable "$_akst_mode" "" "$_akst_base"
  fi
}

asb_kc_each() {
  _ake_action="$1" _ake_rc=0
  for _ake_key in mglru_mode kernel_timer_migration kernel_sched_nr_migrate kernel_sched_stats kernel_sched_autogroup kernel_sched_child_runs_first; do
    "asb_kc_$_ake_action" "$_ake_key" || _ake_rc=1
  done
  return "$_ake_rc"
}

case "${0##*/}" in
  asb_kernel_controls.sh)
    _akc_cmd="${1:-status}" _akc_one="${2:-}"
    case "$_akc_cmd" in
      apply) if [ -z "$_akc_one" ]; then asb_kc_each apply; else asb_kc_apply "$_akc_one" "${3:-}"; fi ;;
      restore) if [ -z "$_akc_one" ]; then asb_kc_each restore; else asb_kc_restore "$_akc_one"; fi ;;
      status) if [ -z "$_akc_one" ]; then asb_kc_each status; else asb_kc_status "$_akc_one"; fi ;;
      *) printf 'usage: asb_kernel_controls.sh apply|restore|status [registered_key]\n' >&2; exit 2 ;;
    esac
    ;;
esac
