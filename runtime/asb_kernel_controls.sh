#!/system/bin/sh

ASB_KC_MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
ASB_KC_CONF="${ASB_CONF:-$ASB_KC_MODDIR/config/governor.conf}"
ASB_KC_STATE="${ASB_KERNEL_STATE_DIR:-/data/adb/asb/kernel_controls}"
ASB_KC_DBG_MP=""

asb_kc_node() {
  case "$1" in
    kernel_mglru_min_ttl) printf '%s\n' "${ASB_MGLRU_MIN_TTL_NODE:-/sys/kernel/mm/lru_gen/min_ttl_ms}" ;;
    mglru_mode) printf '%s\n' "${ASB_MGLRU_ENABLED_NODE:-/sys/kernel/mm/lru_gen/enabled}" ;;
    kernel_timer_migration) printf '%s\n' "${ASB_TIMER_MIGRATION_NODE:-/proc/sys/kernel/timer_migration}" ;;
    kernel_sched_nr_migrate) printf '%s\n' "${ASB_SCHED_NR_MIGRATE_NODE:-/sys/kernel/debug/sched/nr_migrate}" ;;
    kernel_sched_stats) printf '%s\n' "${ASB_SCHED_STATS_NODE:-/proc/sys/kernel/sched_schedstats}" ;;
    kernel_sched_autogroup) printf '%s\n' "${ASB_SCHED_AUTOGROUP_NODE:-/proc/sys/kernel/sched_autogroup_enabled}" ;;
    kernel_sched_child_runs_first) printf '%s\n' "${ASB_SCHED_CHILD_RUNS_FIRST_NODE:-/proc/sys/kernel/sched_child_runs_first}" ;;
    kernel_hrtimer_migration) printf '%s\n' "${ASB_HRTIMER_MIGRATION_NODE:-/proc/sys/kernel/hrtimer_migration}" ;;
    kernel_lpm_prediction)
      if [ -n "${ASB_LPM_PREDICTION_NODE:-}" ]; then
        printf '%s\n' "$ASB_LPM_PREDICTION_NODE"
      elif [ -e "${ASB_LPM_LEVELS_NODE:-/sys/module/lpm_levels/parameters/lpm_prediction}" ]; then
        printf '%s\n' "${ASB_LPM_LEVELS_NODE:-/sys/module/lpm_levels/parameters/lpm_prediction}"
      else
        printf '%s\n' "${ASB_QCOM_LPM_PREDICTION_NODE:-/sys/devices/system/cpu/qcom_lpm/parameters/prediction_disabled}"
      fi
      ;;
    kernel_usb_autosuspend) printf '%s\n' "${ASB_USB_AUTOSUSPEND_NODE:-/sys/module/usbcore/parameters/autosuspend}" ;;
    kernel_rt_boost) printf '%s\n' "${ASB_RT_BOOST_NODE:-/proc/sys/kernel/sched_util_clamp_min_rt_default}" ;;
    *) return 1 ;;
  esac
}

asb_kc_dbg_up() {
  [ "$1" = kernel_sched_nr_migrate ] || return 0
  [ -z "${ASB_SCHED_NR_MIGRATE_NODE:-}" ] || return 0
  [ -e "${ASB_KC_DEBUGFS_DEFAULT:-/sys/kernel/debug/sched/nr_migrate}" ] && return 0
  grep -qw debugfs "${ASB_KC_FILESYSTEMS:-/proc/filesystems}" 2>/dev/null || return 0
  _akd_mp="${ASB_KC_DEBUGFS_MP:-/dev/.asb_kc_debugfs}"
  mkdir -p "$_akd_mp" 2>/dev/null || return 0
  if mount -t debugfs debugfs "$_akd_mp" 2>/dev/null; then
    ASB_KC_DBG_MP="$_akd_mp"
    ASB_SCHED_NR_MIGRATE_NODE="$_akd_mp/sched/nr_migrate"
  else
    rmdir "$_akd_mp" 2>/dev/null
  fi
  return 0
}

asb_kc_dbg_down() {
  [ -n "$ASB_KC_DBG_MP" ] || return 0
  umount "$ASB_KC_DBG_MP" 2>/dev/null || umount -l "$ASB_KC_DBG_MP" 2>/dev/null
  rmdir "$ASB_KC_DBG_MP" 2>/dev/null
  ASB_KC_DBG_MP=""
  ASB_SCHED_NR_MIGRATE_NODE=""
  return 0
}

asb_kc_run() {
  _akrn_a="$1"; shift
  asb_kc_dbg_up "$1"
  "asb_kc_$_akrn_a" "$@"
  _akrn_rc=$?
  asb_kc_dbg_down
  return "$_akrn_rc"
}

asb_kc_clean() { printf '%s' "$1" | tr -d ' \t\r\n'; }

asb_kc_mode() {
  _akm_v="$(grep -E "^[[:space:]]*$1=" "$ASB_KC_CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \t\r\n')"
  case "$1:$_akm_v" in
    kernel_mglru_min_ttl:stock|kernel_mglru_min_ttl:1000|kernel_mglru_min_ttl:2000) ;;
    kernel_mglru_min_ttl:5000) _akm_v=2000 ;;
    kernel_mglru_min_ttl:*) _akm_v=stock ;;
    mglru_mode:stock|mglru_mode:off|mglru_mode:on|mglru_mode:smart) ;;
    mglru_mode:*) _akm_v=smart ;;
    kernel_timer_migration:stock|kernel_timer_migration:auto|kernel_timer_migration:off|kernel_timer_migration:on) ;;
    kernel_timer_migration:*) _akm_v=off ;;
    kernel_sched_nr_migrate:stock|kernel_sched_nr_migrate:auto|kernel_sched_nr_migrate:1|kernel_sched_nr_migrate:2|kernel_sched_nr_migrate:4|kernel_sched_nr_migrate:8|kernel_sched_nr_migrate:16) ;;
    kernel_sched_nr_migrate:*) _akm_v=4 ;;
    kernel_sched_stats:stock|kernel_sched_stats:off) ;;
    kernel_sched_stats:*) _akm_v=stock ;;
    kernel_sched_autogroup:stock|kernel_sched_autogroup:off|kernel_sched_autogroup:on) ;;
    kernel_sched_autogroup:*) _akm_v=stock ;;
    kernel_sched_child_runs_first:stock|kernel_sched_child_runs_first:off|kernel_sched_child_runs_first:on) ;;
    kernel_sched_child_runs_first:*) _akm_v=stock ;;
    kernel_hrtimer_migration:stock|kernel_hrtimer_migration:auto|kernel_hrtimer_migration:off|kernel_hrtimer_migration:on) ;;
    kernel_hrtimer_migration:*) _akm_v=auto ;;
    kernel_lpm_prediction:stock|kernel_lpm_prediction:auto|kernel_lpm_prediction:off|kernel_lpm_prediction:on) ;;
    kernel_lpm_prediction:*) _akm_v=auto ;;
    kernel_usb_autosuspend:stock|kernel_usb_autosuspend:off|kernel_usb_autosuspend:on) ;;
    kernel_usb_autosuspend:*) _akm_v=stock ;;
    kernel_rt_boost:stock|kernel_rt_boost:auto|kernel_rt_boost:0|kernel_rt_boost:128|kernel_rt_boost:256|kernel_rt_boost:512) ;;
    kernel_rt_boost:*) _akm_v=stock ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$_akm_v"
}

asb_kc_valid_value() {
  _akv_key="$1" _akv_v="$2"
  case "$_akv_key" in
    kernel_timer_migration|kernel_sched_stats|kernel_sched_autogroup|kernel_sched_child_runs_first|kernel_hrtimer_migration|kernel_lpm_prediction) case "$_akv_v" in 0|1) return 0 ;; *) return 1 ;; esac ;;
    kernel_usb_autosuspend)
      case "$_akv_v" in
        -1) return 0 ;;
        ''|*[!0-9]*) return 1 ;;
        *) [ "${#_akv_v}" -le 9 ] ;;
      esac
      ;;
    kernel_sched_nr_migrate|kernel_mglru_min_ttl)
      case "$_akv_v" in ''|*[!0-9]*) return 1 ;; esac
      [ "${#_akv_v}" -le 9 ]
      ;;
    kernel_rt_boost)
      case "$_akv_v" in ''|*[!0-9]*) return 1 ;; esac
      [ "${#_akv_v}" -le 4 ] && [ "$_akv_v" -le 1024 ]
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
    -1) printf '%s\n' -1 ;;
    ''|*[!0-9]*) return 1 ;;
    *) printf '%d\n' "$_akn_v" 2>/dev/null ;;
  esac
}

asb_kc_same() {
  _aks_a="$(asb_kc_number "$1")" || return 1
  _aks_b="$(asb_kc_number "$2")" || return 1
  [ "$_aks_a" = "$_aks_b" ]
}

asb_kc_accepts() {
  asb_kc_same "$2" "$3" && return 0
  [ "$1" = mglru_mode ] || return 1
  _akx_w="$(asb_kc_number "$2")" || return 1
  _akx_l="$(asb_kc_number "$3")" || return 1
  [ $((_akx_l & ~_akx_w)) -eq 0 ] && [ $((_akx_l & 1)) -eq $((_akx_w & 1)) ]
}

asb_kc_prev() {
  if [ "$1" = kernel_sched_stats ] && [ -z "${ASB_KERNEL_STATE_DIR+x}" ]; then
    printf '%s\n' "${ASB_SCHED_STATS_PREV:-/data/adb/asb/kernel_sched_stats.prev}"
  else
    printf '%s/%s.prev\n' "$ASB_KC_STATE" "$1"
  fi
}

asb_kc_kid() {
  [ -n "${_akk_id:-}" ] || _akk_id="${ASB_KC_KERNEL_ID:-$(uname -r 2>/dev/null)|$(uname -v 2>/dev/null)}"
  printf '%s\n' "$_akk_id"
}

asb_kc_kid_ok() {
  [ -f "$1.kid" ] || return 0
  [ "$(cat "$1.kid" 2>/dev/null)" = "$(asb_kc_kid)" ]
}

asb_kc_kid_write() {
  _akw_tmp="$1.kid.tmp.$$"
  (umask 077; asb_kc_kid > "$_akw_tmp" 2>/dev/null) && mv -f "$_akw_tmp" "$1.kid" 2>/dev/null && return 0
  rm -f "$_akw_tmp" 2>/dev/null
  return 0
}

asb_kc_lpm_inverted() {
  case "$(asb_kc_node kernel_lpm_prediction)" in
    */prediction_disabled) return 0 ;;
  esac
  return 1
}

asb_kc_flip() {
  case "$1" in
    0) printf '1\n' ;;
    1) printf '0\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

asb_kc_emit() {
  _akp_l="${4:-unknown}" _akp_b="${5:-none}"
  if [ "$1" = kernel_lpm_prediction ] && asb_kc_lpm_inverted; then
    _akp_l="$(asb_kc_flip "$_akp_l")"
    _akp_b="$(asb_kc_flip "$_akp_b")"
  fi
  printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$_akp_l" "$_akp_b"
}

asb_kc_rt_ready() {
  if [ -n "${ASB_KC_RT_READY:-}" ]; then
    [ "$ASB_KC_RT_READY" = 1 ]
    return $?
  fi
  command -v getprop >/dev/null 2>&1 || return 0
  [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || return 1
  for _akq_s in kernel-post-boot vendor.post_boot qcom-post-boot post_boot; do
    [ "$(getprop "init.svc.$_akq_s" 2>/dev/null)" = running ] && return 1
  done
  _akq_up="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
  case "$_akq_up" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_akq_up" -ge 60 ]
}

asb_kc_hrtimer_covered() {
  _ahc_mode="$1" _ahc_base="$2"
  _ahc_node="${ASB_TIMER_MIGRATION_NODE:-/proc/sys/kernel/timer_migration}"
  if [ -e "$_ahc_node" ]; then
    _ahc_live="$(asb_kc_clean "$(cat "$_ahc_node" 2>/dev/null)")"
    asb_kc_emit kernel_hrtimer_migration covered_by_timer_migration "$_ahc_mode" "$_ahc_live" "$_ahc_base"
  else
    asb_kc_emit kernel_hrtimer_migration not_exposed "$_ahc_mode" "" "$_ahc_base"
    return 1
  fi
  return 0
}

asb_kc_capture() {
  _akc_key="$1" _akc_node="$2" _akc_prev="$3"
  if [ -f "$_akc_prev" ] && ! asb_kc_kid_ok "$_akc_prev"; then
    rm -f "$_akc_prev" "$_akc_prev.kid" 2>/dev/null || return 1
  fi
  if [ -f "$_akc_prev" ]; then
    _akc_saved="$(asb_kc_clean "$(cat "$_akc_prev" 2>/dev/null)")"
    asb_kc_valid_value "$_akc_key" "$_akc_saved" || return 1
    [ -f "$_akc_prev.kid" ] || asb_kc_kid_write "$_akc_prev"
    return 0
  fi
  _akc_orig="$(asb_kc_clean "$(cat "$_akc_node" 2>/dev/null)")"
  asb_kc_valid_value "$_akc_key" "$_akc_orig" || return 1
  mkdir -p "${_akc_prev%/*}" 2>/dev/null || return 1
  _akc_tmp="$_akc_prev.tmp.$$"
  (umask 077; printf '%s\n' "$_akc_orig" > "$_akc_tmp" 2>/dev/null) || { rm -f "$_akc_tmp" 2>/dev/null; return 1; }
  mv -f "$_akc_tmp" "$_akc_prev" 2>/dev/null || { rm -f "$_akc_tmp" 2>/dev/null; return 1; }
  asb_kc_kid_write "$_akc_prev"
}

asb_kc_restore() {
  _akr_key="$1" _akr_mode="${2:-stock}"
  _akr_node="$(asb_kc_node "$_akr_key")" || return 1
  if [ "$_akr_key" = kernel_hrtimer_migration ] && [ ! -e "$_akr_node" ]; then
    asb_kc_hrtimer_covered "$_akr_mode" none
    return $?
  fi
  _akr_prev="$(asb_kc_prev "$_akr_key")"
  [ -f "$_akr_prev" ] || { asb_kc_emit "$_akr_key" stock_unowned "$_akr_mode" "" none; return 0; }
  if ! asb_kc_kid_ok "$_akr_prev"; then
    rm -f "$_akr_prev" "$_akr_prev.kid" 2>/dev/null
    asb_kc_emit "$_akr_key" stock_unowned "$_akr_mode" "" none
    return 0
  fi
  _akr_orig="$(asb_kc_clean "$(cat "$_akr_prev" 2>/dev/null)")"
  asb_kc_valid_value "$_akr_key" "$_akr_orig" || { asb_kc_emit "$_akr_key" baseline_invalid "$_akr_mode" "" invalid; return 1; }
  [ -e "$_akr_node" ] || { asb_kc_emit "$_akr_key" not_exposed "$_akr_mode" "" "$_akr_orig"; return 1; }
  [ -w "$_akr_node" ] || { asb_kc_emit "$_akr_key" not_writable "$_akr_mode" "" "$_akr_orig"; return 1; }
  printf '%s\n' "$_akr_orig" > "$_akr_node" 2>/dev/null || { asb_kc_emit "$_akr_key" write_failed "$_akr_mode" "" "$_akr_orig"; return 1; }
  _akr_live="$(asb_kc_clean "$(cat "$_akr_node" 2>/dev/null)")"
  if asb_kc_same "$_akr_orig" "$_akr_live"; then
    rm -f "$_akr_prev" "$_akr_prev.kid" 2>/dev/null || { asb_kc_emit "$_akr_key" state_cleanup_failed "$_akr_mode" "$_akr_live" "$_akr_orig"; return 1; }
    asb_kc_emit "$_akr_key" restored "$_akr_mode" "$_akr_live" none
    return 0
  fi
  asb_kc_emit "$_akr_key" readback_mismatch "$_akr_mode" "$_akr_live" "$_akr_orig"
  return 1
}

asb_kc_apply() {
  _aka_key="$1" _aka_smart="${2:-}" _aka_profile="${3:-${ASB_PROFILE:-}}"
  _aka_node="$(asb_kc_node "$_aka_key")" || return 1
  _aka_mode="$(asb_kc_mode "$_aka_key")" || return 1
  if [ "$_aka_key" = kernel_hrtimer_migration ] && [ ! -e "$_aka_node" ]; then
    asb_kc_hrtimer_covered "$_aka_mode" none
    return $?
  fi
  [ "$_aka_mode" != stock ] || { asb_kc_restore "$_aka_key"; return $?; }
  if [ -z "$_aka_profile" ]; then
    _aka_profile="$(cat "$ASB_KC_MODDIR/current_profile" 2>/dev/null | tr -d ' \t\r\n')"
  fi
  case "$_aka_key:$_aka_mode:$_aka_profile" in
    *:auto:stock) asb_kc_restore "$_aka_key" auto; return $? ;;
    kernel_lpm_prediction:auto:battery|kernel_timer_migration:auto:performance|kernel_hrtimer_migration:auto:performance) ;;
    kernel_rt_boost:auto:battery|kernel_rt_boost:auto:performance|kernel_sched_nr_migrate:auto:*) ;;
    *:auto:*) asb_kc_restore "$_aka_key" auto; return $? ;;
  esac
  _aka_prev="$(asb_kc_prev "$_aka_key")"
  _aka_saved=none
  [ -f "$_aka_prev" ] && asb_kc_kid_ok "$_aka_prev" && _aka_saved="$(asb_kc_clean "$(cat "$_aka_prev" 2>/dev/null)")"
  [ -e "$_aka_node" ] || { asb_kc_emit "$_aka_key" not_exposed "$_aka_mode" "" "$_aka_saved"; return 1; }
  [ -r "$_aka_node" ] || { asb_kc_emit "$_aka_key" not_readable "$_aka_mode" "" "$_aka_saved"; return 1; }
  [ -w "$_aka_node" ] || { asb_kc_emit "$_aka_key" not_writable "$_aka_mode" "" "$_aka_saved"; return 1; }
  case "$_aka_key:$_aka_mode" in
    mglru_mode:off) _aka_want=0 ;;
    mglru_mode:on) _aka_want=7 ;;
    mglru_mode:smart)
      case "$_aka_smart" in 5|7) _aka_want="$_aka_smart" ;; *) _aka_want=7 ;; esac
      ;;
    kernel_mglru_min_ttl:1000|kernel_mglru_min_ttl:2000) _aka_want="$_aka_mode" ;;
    kernel_timer_migration:off|kernel_timer_migration:auto|kernel_hrtimer_migration:off|kernel_hrtimer_migration:auto|kernel_lpm_prediction:off) _aka_want=0 ;;
    kernel_timer_migration:on|kernel_hrtimer_migration:on|kernel_lpm_prediction:on|kernel_lpm_prediction:auto) _aka_want=1 ;;
    kernel_usb_autosuspend:off) _aka_want=-1 ;;
    kernel_usb_autosuspend:on) _aka_want=2 ;;
    kernel_sched_stats:off|kernel_sched_child_runs_first:off) _aka_want=0 ;;
    kernel_sched_autogroup:off|kernel_sched_child_runs_first:off) _aka_want=0 ;;
    kernel_sched_autogroup:on|kernel_sched_child_runs_first:on) _aka_want=1 ;;
    kernel_sched_nr_migrate:1|kernel_sched_nr_migrate:2|kernel_sched_nr_migrate:4|kernel_sched_nr_migrate:8|kernel_sched_nr_migrate:16)
      _aka_want="$_aka_mode" ;;
    kernel_sched_nr_migrate:auto)
      case "$_aka_profile" in battery) _aka_want=2 ;; performance) _aka_want=8 ;; *) _aka_want=4 ;; esac
      ;;
    kernel_rt_boost:auto)
      case "$_aka_profile" in battery) _aka_want=0 ;; *) _aka_want=256 ;; esac
      ;;
    kernel_rt_boost:0|kernel_rt_boost:128|kernel_rt_boost:256|kernel_rt_boost:512) _aka_want="$_aka_mode" ;;
    *) asb_kc_emit "$_aka_key" invalid_request "$_aka_mode" "" "$_aka_saved"; return 1 ;;
  esac
  if [ "$_aka_key" = kernel_lpm_prediction ] && asb_kc_lpm_inverted; then
    _aka_want="$(asb_kc_flip "$_aka_want")"
  fi
  if [ "$_aka_key" = kernel_rt_boost ] && [ "$_aka_saved" = none ] && ! asb_kc_rt_ready; then
    asb_kc_emit "$_aka_key" deferred "$_aka_mode" "$(asb_kc_clean "$(cat "$_aka_node" 2>/dev/null)")" none
    return 0
  fi
  asb_kc_capture "$_aka_key" "$_aka_node" "$_aka_prev" || { asb_kc_emit "$_aka_key" baseline_failed "$_aka_mode" "" "$_aka_saved"; return 1; }
  _aka_saved="$(asb_kc_clean "$(cat "$_aka_prev" 2>/dev/null)")"
  _aka_before="$(asb_kc_clean "$(cat "$_aka_node" 2>/dev/null)")"
  if ! asb_kc_same "$_aka_want" "$_aka_before"; then
    printf '%s\n' "$_aka_want" > "$_aka_node" 2>/dev/null || { asb_kc_emit "$_aka_key" write_failed "$_aka_mode" "$_aka_before" "$_aka_saved"; return 1; }
  fi
  _aka_live="$(asb_kc_clean "$(cat "$_aka_node" 2>/dev/null)")"
  if asb_kc_accepts "$_aka_key" "$_aka_want" "$_aka_live"; then
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
  [ -f "$_akst_prev" ] && asb_kc_kid_ok "$_akst_prev" && _akst_base="$(asb_kc_clean "$(cat "$_akst_prev" 2>/dev/null)")"
  if [ ! -e "$_akst_node" ]; then
    if [ "$_akst_key" = kernel_hrtimer_migration ]; then
      asb_kc_hrtimer_covered "$_akst_mode" "$_akst_base"
    else
      asb_kc_emit "$_akst_key" not_exposed "$_akst_mode" "" "$_akst_base"
    fi
    return 0
  fi
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
  for _ake_key in mglru_mode kernel_mglru_min_ttl kernel_timer_migration kernel_sched_nr_migrate kernel_sched_stats kernel_sched_autogroup kernel_sched_child_runs_first kernel_hrtimer_migration kernel_lpm_prediction kernel_usb_autosuspend kernel_rt_boost; do
    asb_kc_run "$_ake_action" "$_ake_key" || _ake_rc=1
  done
  return "$_ake_rc"
}

asb_kc_follow() {
  _akf_profile="$1" _akf_rc=0
  case "$_akf_profile" in ''|stock) return 0 ;; esac
  _akf_keys="kernel_timer_migration kernel_sched_nr_migrate kernel_hrtimer_migration kernel_lpm_prediction kernel_rt_boost kernel_mglru_min_ttl kernel_sched_stats kernel_sched_autogroup kernel_sched_child_runs_first kernel_usb_autosuspend"
  case "$(asb_kc_mode mglru_mode):$_akf_profile" in
    smart:smart) ;;
    *) _akf_keys="mglru_mode $_akf_keys" ;;
  esac
  for _akf_key in $_akf_keys; do
    asb_kc_run apply "$_akf_key" "" "$_akf_profile" || _akf_rc=1
  done
  return "$_akf_rc"
}

case "${0##*/}" in
  asb_kernel_controls.sh)
    _akc_cmd="${1:-status}" _akc_one="${2:-}"
    case "$_akc_cmd" in
      apply) if [ -z "$_akc_one" ]; then asb_kc_each apply; else asb_kc_run apply "$_akc_one" "${3:-}" "${4:-}"; fi ;;
      restore) if [ -z "$_akc_one" ]; then asb_kc_each restore; else asb_kc_run restore "$_akc_one"; fi ;;
      status) if [ -z "$_akc_one" ]; then asb_kc_each status; else asb_kc_run status "$_akc_one"; fi ;;
      follow) asb_kc_follow "$_akc_one" ;;
      *) printf 'usage: asb_kernel_controls.sh apply|restore|status [registered_key] | follow <profile>\n' >&2; exit 2 ;;
    esac
    ;;
esac
