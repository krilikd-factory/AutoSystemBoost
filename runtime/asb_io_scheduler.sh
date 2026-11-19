#!/system/bin/sh
# Bounded per-block-device I/O scheduler owner. It discovers the kernel's exposed
# scheduler names, saves each device's active original, writes only the fixed
# queue/scheduler node and verifies readback. No arbitrary path/value interface.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="${ASB_CONF:-$MODDIR/config/governor.conf}"
ROOT="${ASB_IO_BLOCK_ROOT:-/sys/block}"
STATE="${ASB_IO_SCHEDULER_STATE:-/data/adb/asb/io_scheduler}"

_ios_clean() { printf '%s' "$1" | tr -d ' \t\r\n'; }
_ios_mode() {
  _iosm_v="$(grep -E '^[[:space:]]*io_scheduler=' "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \t\r\n')"
  case "$_iosm_v" in ''|stock) _iosm_v=stock ;; auto) : ;;
    *) case "$_iosm_v" in *[!a-z0-9_-]*|[!a-z0-9]*) _iosm_v=stock ;; esac
       [ "${#_iosm_v}" -le 32 ] || _iosm_v=stock ;;
  esac
  printf '%s\n' "$_iosm_v"
}
_ios_dev_ok() {
  case "$1" in
    sd[a-z]*|mmcblk[0-9]*|nvme[0-9]*n[0-9]*|dm-[0-9]*)
      case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; esac
      [ "${#1}" -le 40 ] ;;
    *) return 1 ;;
  esac
}
_ios_node() { _ios_dev_ok "$1" || return 1; printf '%s/%s/queue/scheduler\n' "$ROOT" "$1"; }
_ios_active() {
  _iosa_line="$(cat "$1" 2>/dev/null)" || return 1
  _iosa_old_ifs="$IFS"; IFS=' '; set -f
  for _iosa_tok in $_iosa_line; do
    case "$_iosa_tok" in \[*\]) _iosa_tok="${_iosa_tok#\[}"; printf '%s\n' "${_iosa_tok%\]}"; IFS="$_iosa_old_ifs"; set +f; return 0 ;; esac
  done
  IFS="$_iosa_old_ifs"; set +f
  # A few test/old kernels omit brackets when only one scheduler exists.
  set -- $_iosa_line
  [ "$#" = 1 ] && { printf '%s\n' "$1"; return 0; }
  return 1
}
_ios_name_ok() {
  case "$1" in ''|[!a-z0-9]*|*[!a-z0-9_-]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}
_ios_has() {
  _iosh_line="$(cat "$1" 2>/dev/null)" || return 1
  _iosh_old_ifs="$IFS"; IFS=' '; set -f
  for _iosh_tok in $_iosh_line; do
    _iosh_tok="${_iosh_tok#\[}"; _iosh_tok="${_iosh_tok%\]}"
    [ "$_iosh_tok" = "$2" ] && { IFS="$_iosh_old_ifs"; set +f; return 0; }
  done
  IFS="$_iosh_old_ifs"; set +f; return 1
}
_ios_options() {
  _ioso_line="$(cat "$1" 2>/dev/null)" || return 1
  _ioso_old_ifs="$IFS"; IFS=' '; set -f
  for _ioso_tok in $_ioso_line; do
    _ioso_tok="${_ioso_tok#\[}"; _ioso_tok="${_ioso_tok%\]}"
    _ios_name_ok "$_ioso_tok" && printf '%s\n' "$_ioso_tok"
  done
  IFS="$_ioso_old_ifs"; set +f
}
_ios_devices() {
  [ -d "$ROOT" ] || return 0
  for _iosd_dir in "$ROOT"/*; do
    [ -d "$_iosd_dir/queue" ] || continue
    _iosd_name="${_iosd_dir##*/}"
    _ios_dev_ok "$_iosd_name" || continue
    [ -r "$_iosd_dir/queue/scheduler" ] || continue
    # Rotational devices are deliberately outside the phone-oriented policy.
    [ "$(cat "$_iosd_dir/queue/rotational" 2>/dev/null)" = 1 ] && continue
    printf '%s\n' "$_iosd_name"
  done
}
_ios_kid() { printf '%s|%s\n' "$(uname -r 2>/dev/null)" "$(uname -v 2>/dev/null)"; }
_ios_kid_ok() { [ ! -f "$1.kid" ] || [ "$(cat "$1.kid" 2>/dev/null)" = "$(_ios_kid)" ]; }
_ios_kid_write() {
  _iosk_tmp="$1.kid.tmp.$$"
  (umask 077; _ios_kid > "$_iosk_tmp" 2>/dev/null) && mv -f "$_iosk_tmp" "$1.kid" 2>/dev/null
}
_ios_prev() { printf '%s/%s.prev\n' "$STATE" "$1"; }
_ios_capture() {
  _iosc_dev="$1"; _iosc_node="$(_ios_node "$_iosc_dev")" || return 1
  _iosc_prev="$(_ios_prev "$_iosc_dev")"
  if [ -f "$_iosc_prev" ] && ! _ios_kid_ok "$_iosc_prev"; then
    rm -f "$_iosc_prev" "$_iosc_prev.kid" 2>/dev/null || return 1
  fi
  if [ -f "$_iosc_prev" ]; then
    _ios_name_ok "$(cat "$_iosc_prev" 2>/dev/null)" || return 1
    [ -f "$_iosc_prev.kid" ] || _ios_kid_write "$_iosc_prev"
    return 0
  fi
  _iosc_orig="$(_ios_active "$_iosc_node")" || return 1
  _ios_name_ok "$_iosc_orig" || return 1
  mkdir -p "$STATE" 2>/dev/null || return 1
  _iosc_tmp="$_iosc_prev.tmp.$$"
  (umask 077; printf '%s\n' "$_iosc_orig" > "$_iosc_tmp" 2>/dev/null) || { rm -f "$_iosc_tmp" 2>/dev/null; return 1; }
  mv -f "$_iosc_tmp" "$_iosc_prev" 2>/dev/null || { rm -f "$_iosc_tmp" 2>/dev/null; return 1; }
  _ios_kid_write "$_iosc_prev"
}
_ios_live() {
  _iosl_seen=""; _iosl_mixed=0
  for _iosl_dev in $(_ios_devices); do
    _iosl_node="$(_ios_node "$_iosl_dev")"
    _iosl_cur="$(_ios_active "$_iosl_node" 2>/dev/null)"
    _ios_name_ok "$_iosl_cur" || continue
    if [ -z "$_iosl_seen" ]; then _iosl_seen="$_iosl_cur"
    elif [ "$_iosl_seen" != "$_iosl_cur" ]; then _iosl_mixed=1; fi
  done
  [ "$_iosl_mixed" = 1 ] && printf 'mixed\n' || printf '%s\n' "${_iosl_seen:-unknown}"
}
_ios_baseline() {
  _iosb_seen=""; _iosb_mixed=0; _iosb_any=0
  [ -d "$STATE" ] || { printf 'none\n'; return; }
  for _iosb_file in "$STATE"/*.prev; do
    [ -f "$_iosb_file" ] || continue
    _ios_kid_ok "$_iosb_file" || continue
    _iosb_any=1
    _iosb_val="$(cat "$_iosb_file" 2>/dev/null)"
    _ios_name_ok "$_iosb_val" || continue
    if [ -z "$_iosb_seen" ]; then _iosb_seen="$_iosb_val"
    elif [ "$_iosb_seen" != "$_iosb_val" ]; then _iosb_mixed=1; fi
  done
  [ "$_iosb_any" = 0 ] && { printf 'none\n'; return; }
  [ "$_iosb_mixed" = 1 ] && printf 'mixed\n' || printf '%s\n' "${_iosb_seen:-invalid}"
}
_ios_emit() { printf 'io_scheduler|%s|%s|%s|%s\n' "$1" "$(_ios_mode)" "$(_ios_live)" "$(_ios_baseline)"; }
_ios_status() {
  _ioss_any=0; _ioss_write=0; _ioss_union=""
  for _ioss_dev in $(_ios_devices); do
    _ioss_any=1
    _ioss_node="$(_ios_node "$_ioss_dev")"
    [ -w "$_ioss_node" ] && _ioss_write=1
    _ioss_union="$_ioss_union $(_ios_options "$_ioss_node")"
  done
  if [ "$_ioss_any" = 0 ]; then _ios_emit not_exposed
  elif [ "$_ioss_write" = 0 ]; then _ios_emit not_writable
  else _ios_emit writable; fi
  printf '%s\n' "$_ioss_union" | tr ' ' '\n' | sed '/^$/d' | sort -u | awk 'BEGIN{first=1} {if(!first)printf " "; printf "%s",$0; first=0} END{if(!first)printf "\n"}' \
    | sed 's/^/io_scheduler_options|/'
}
_ios_smart_plan() {
  _iossp_hint=2; _iossp_screen=1
  if [ -f "$STATE/smart.plan" ]; then
    _iossp_old_ifs="$IFS"; IFS=' '; set -f
    set -- $(cat "$STATE/smart.plan" 2>/dev/null)
    IFS="$_iossp_old_ifs"; set +f
    if [ "$#" = 2 ]; then
      case "$1" in 0|1|2|3|4) case "$2" in 0|1) _iossp_hint="$1"; _iossp_screen="$2" ;; esac ;; esac
    fi
  fi
  printf '%s %s\n' "$_iossp_hint" "$_iossp_screen"
}
_ios_smart_plan_write() {
  _iossw_tmp="$STATE/smart.plan.tmp.$$"
  (umask 077; printf '%s %s\n' "$1" "$2" > "$_iossw_tmp" 2>/dev/null) || { rm -f "$_iossw_tmp" 2>/dev/null; return 1; }
  mv -f "$_iossw_tmp" "$STATE/smart.plan" 2>/dev/null || { rm -f "$_iossw_tmp" 2>/dev/null; return 1; }
}
_ios_choose() {
  _iosch_node="$1"; _iosch_mode="$2"; _iosch_profile="$3"; _iosch_hint="${4:-2}"; _iosch_screen="${5:-1}"
  if [ "$_iosch_mode" != auto ]; then
    _ios_has "$_iosch_node" "$_iosch_mode" || return 1
    printf '%s\n' "$_iosch_mode"; return 0
  fi
  # Every scheduler is selected only from the queue's runtime exposure. BFQ is deliberately
  # absent from every automatic order: it remains available only as an explicit user choice.
  if [ "$_iosch_profile" = smart ]; then
    if [ "$_iosch_screen" = 0 ]; then
      # With no interactive reader, try the minimal FIFO path first. This is a
      # workload policy, not a claim of measured power savings on every UFS queue.
      _iosch_order='none mq-deadline kyber adios'
    elif [ "$_iosch_hint" = 0 ]; then
      _iosch_order='mq-deadline none kyber adios'
    else
      case "$_iosch_hint" in
        3|4) _iosch_order='adios kyber mq-deadline none' ;;
        *) _iosch_order='kyber mq-deadline adios none' ;;
      esac
    fi
  else
    case "$_iosch_profile" in
      performance) _iosch_order='adios kyber mq-deadline none' ;;
      battery) _iosch_order='none mq-deadline kyber adios' ;;
      *) _iosch_order='mq-deadline kyber adios none' ;;
    esac
  fi
  for _iosch_name in $_iosch_order; do
    if _ios_has "$_iosch_node" "$_iosch_name"; then printf '%s\n' "$_iosch_name"; return 0; fi
  done
  # Auto stays fail-closed if none of the documented policy choices is exposed.
  return 1
}

# Roll back only queues whose live value differs from the bounded pre-attempt snapshot.
# Device and scheduler names cannot contain '|'. Persistent first-ASB baselines are kept:
# a later explicit Stock must still restore the value from before the first successful write.
_ios_attempt_rollback() {
  _iosar_fail=0
  while IFS='|' read -r _iosar_dev _iosar_before; do
    [ -n "$_iosar_dev" ] && [ -n "$_iosar_before" ] || continue
    _iosar_node="$(_ios_node "$_iosar_dev")" || { _iosar_fail=1; continue; }
    _iosar_now="$(_ios_active "$_iosar_node" 2>/dev/null)"
    [ "$_iosar_now" = "$_iosar_before" ] && continue
    printf '%s\n' "$_iosar_before" > "$_iosar_node" 2>/dev/null || { _iosar_fail=1; continue; }
    [ "$(_ios_active "$_iosar_node" 2>/dev/null)" = "$_iosar_before" ] || _iosar_fail=1
  done <<EOF_IO_ATTEMPT
$1
EOF_IO_ATTEMPT
  [ "$_iosar_fail" = 0 ]
}
_ios_apply_failed() {
  _iosaf_reason="$1"
  _ios_attempt_rollback "$2" || _iosaf_reason=rollback_failed
  _ios_emit "$_iosaf_reason"
  return 1
}
_ios_apply() {
  _iosap_hint="${1:-}"; _iosap_screen="${2:-}"
  _iosap_mode="$(_ios_mode)"
  [ "$_iosap_mode" != stock ] || { _ios_restore; return $?; }
  _iosap_devices="$(_ios_devices)"
  [ -n "$_iosap_devices" ] || { _ios_emit not_exposed; return 1; }
  _iosap_profile="${ASB_PROFILE:-$(cat "$MODDIR/current_profile" 2>/dev/null | tr -d ' \t\r\n')}"
  [ -n "$_iosap_profile" ] || _iosap_profile=balanced
  if [ "$_iosap_mode" = auto ] && [ "$_iosap_profile" = smart ] && [ -z "$_iosap_hint" ]; then
    _iosap_plan="$(_ios_smart_plan)"
    _iosap_hint="${_iosap_plan% *}"; _iosap_screen="${_iosap_plan#* }"
  fi
  # Preflight every queue before changing any one of them. An explicit scheduler is
  # never substituted silently and a partially writable set does not report success.
  for _iosap_dev in $_iosap_devices; do
    _iosap_node="$(_ios_node "$_iosap_dev")"
    [ -r "$_iosap_node" ] || { _ios_emit not_readable; return 1; }
    [ -w "$_iosap_node" ] || { _ios_emit not_writable; return 1; }
    _ios_choose "$_iosap_node" "$_iosap_mode" "$_iosap_profile" "$_iosap_hint" "$_iosap_screen" >/dev/null || { _ios_emit not_exposed; return 1; }
  done
  for _iosap_dev in $_iosap_devices; do
    _ios_capture "$_iosap_dev" || { _ios_emit baseline_failed; return 1; }
  done
  # Capture the pre-attempt state of every queue before the first write. Preflight handles
  # unsupported/read-only sets; this snapshot handles a later device-specific write/readback
  # failure without leaving the earlier queues on a partially applied scenario.
  _iosap_attempt=""
  for _iosap_dev in $_iosap_devices; do
    _iosap_node="$(_ios_node "$_iosap_dev")"
    _iosap_before="$(_ios_active "$_iosap_node" 2>/dev/null)"
    _ios_name_ok "$_iosap_before" || { _ios_emit not_readable; return 1; }
    _iosap_attempt="${_iosap_attempt}${_iosap_dev}|${_iosap_before}
"
  done
  for _iosap_dev in $_iosap_devices; do
    _iosap_node="$(_ios_node "$_iosap_dev")"
    _iosap_want="$(_ios_choose "$_iosap_node" "$_iosap_mode" "$_iosap_profile" "$_iosap_hint" "$_iosap_screen")" || {
      _ios_apply_failed not_exposed "$_iosap_attempt"; return 1;
    }
    _iosap_before="$(_ios_active "$_iosap_node" 2>/dev/null)"
    if [ "$_iosap_before" != "$_iosap_want" ]; then
      printf '%s\n' "$_iosap_want" > "$_iosap_node" 2>/dev/null || {
        _ios_apply_failed write_failed "$_iosap_attempt"; return 1;
      }
    fi
    _iosap_now="$(_ios_active "$_iosap_node" 2>/dev/null)"
    [ "$_iosap_now" = "$_iosap_want" ] || {
      _ios_apply_failed readback_mismatch "$_iosap_attempt"; return 1;
    }
  done
  if [ "$_iosap_mode" = auto ] && [ "$_iosap_profile" = smart ]; then
    _ios_smart_plan_write "${_iosap_hint:-2}" "${_iosap_screen:-1}" || :
  fi
  _ios_emit applied
}
_ios_restore() {
  _iosr_any=0; _iosr_done=0
  [ -d "$STATE" ] || { _ios_emit stock_unowned; return 0; }
  for _iosr_prev in "$STATE"/*.prev; do
    [ -f "$_iosr_prev" ] || continue
    _iosr_any=1
    _iosr_dev="${_iosr_prev##*/}"; _iosr_dev="${_iosr_dev%.prev}"
    _iosr_node="$(_ios_node "$_iosr_dev")" || { _ios_emit baseline_invalid; return 1; }
    if ! _ios_kid_ok "$_iosr_prev"; then
      rm -f "$_iosr_prev" "$_iosr_prev.kid" 2>/dev/null || { _ios_emit state_cleanup_failed; return 1; }
      continue
    fi
    _iosr_orig="$(cat "$_iosr_prev" 2>/dev/null)"
    _ios_name_ok "$_iosr_orig" || { _ios_emit baseline_invalid; return 1; }
    [ -e "$_iosr_node" ] || { _ios_emit not_exposed; return 1; }
    [ -w "$_iosr_node" ] || { _ios_emit not_writable; return 1; }
    printf '%s\n' "$_iosr_orig" > "$_iosr_node" 2>/dev/null || { _ios_emit write_failed; return 1; }
    [ "$(_ios_active "$_iosr_node" 2>/dev/null)" = "$_iosr_orig" ] || { _ios_emit readback_mismatch; return 1; }
    rm -f "$_iosr_prev" "$_iosr_prev.kid" 2>/dev/null || { _ios_emit state_cleanup_failed; return 1; }
    _iosr_done=1
  done
  rm -f "$STATE/smart.plan" 2>/dev/null || { _ios_emit state_cleanup_failed; return 1; }
  if [ "$_iosr_done" = 1 ]; then _ios_emit restored; else _ios_emit stock_unowned; fi
}

case "${1:-status}" in
  status) _ios_status ;;
  apply) _ios_apply ;;
  restore) _ios_restore ;;
  smart)
    [ "$#" = 3 ] || { printf 'usage: asb_io_scheduler.sh smart HINT SCREEN\n' >&2; exit 2; }
    case "$2" in 0|1|2|3|4) : ;; *) printf 'error=bad_hint\n' >&2; exit 2 ;; esac
    case "$3" in 0|1) : ;; *) printf 'error=bad_screen\n' >&2; exit 2 ;; esac
    ASB_PROFILE=smart _ios_apply "$2" "$3" ;;
  *) printf 'usage: asb_io_scheduler.sh status|apply|restore|smart HINT SCREEN\n' >&2; exit 2 ;;
esac
