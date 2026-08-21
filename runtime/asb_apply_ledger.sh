#!/system/bin/sh
# asb_apply_ledger.sh - record what each writer actually achieved, not what it attempted.
#
# V64 P0-1. Every writer in ASB ends its work with `|| true`: settings put, setprop, pm
# disable, sysfs write. That was deliberate - one rejected key must not abort a profile
# apply - but it means a write refused by the kernel, silently ignored by the ROM, or
# reverted a second later is indistinguishable from one that took effect. The WebUI then
# shows "on" for something the device never accepted.
#
# The ledger closes that gap with a read-back: ask for the value, read it again, and
# record which of a fixed set of outcomes happened. The classes are the vocabulary the
# rest of V64 reasons in - "unsupported" and "readback_mismatch" mean different things to
# a user and to a diagnostic, and neither is "failed".
#
#   applied            requested, read back, matches
#   already_set        device already had it; no write needed
#   unsupported        the key or node does not exist on this device
#   not_writable       exists but the write was refused (SELinux, ro, permission)
#   readback_mismatch  written without error, reads back as something else
#   lease_denied       another owner holds this knob (reserved for the lease arbiter)
#   safety_veto        refused by a guard, not by the device
#   deferred           cannot act yet; will be retried
#
# The file is a rolling record, not an archive: recent entries answer "why does this look
# wrong right now", which is the question anyone actually asks.

ASB_LEDGER="${ASB_LEDGER:-${ASB_CONFIG_STATE:-/data/adb/asb}/apply_ledger}"
ASB_LEDGER_MAX="${ASB_LEDGER_MAX:-400}"

# asb_ledger_note <domain> <key> <requested> <previous> <readback> <result> [reason] [ttl]
#
# Values are recorded as given. Callers must not pass secrets or package lists - this file
# is meant to be pasteable into a bug report without review.
asb_ledger_note() {
  _lg_dir="$(dirname "$ASB_LEDGER")"
  [ -d "$_lg_dir" ] || mkdir -p "$_lg_dir" 2>/dev/null || return 0
  # Pipe is the field separator, so it cannot survive inside a field.
  _lg_clean() { printf '%s' "$1" | tr '|\n\r' '_  ' | cut -c1-120; }
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$(date +%s 2>/dev/null || echo 0)" \
    "$(_lg_clean "${1:-?}")" "$(_lg_clean "${2:-?}")" \
    "$(_lg_clean "${3:-}")"  "$(_lg_clean "${4:-}")" \
    "$(_lg_clean "${5:-}")"  "$(_lg_clean "${6:-unknown}")" \
    "$(_lg_clean "${7:-}")"  "$(_lg_clean "${8:-}")" \
    >> "$ASB_LEDGER" 2>/dev/null

  # Trim in place, occasionally. Counting lines on every write would cost more than the
  # write itself on a profile apply that touches sixty keys.
  case "$(date +%S 2>/dev/null || echo 0)" in
    0*|3*) _lg_n="$(wc -l < "$ASB_LEDGER" 2>/dev/null || echo 0)"
           case "$_lg_n" in ''|*[!0-9]*) _lg_n=0 ;; esac
           if [ "$_lg_n" -gt "$ASB_LEDGER_MAX" ] 2>/dev/null; then
             tail -n "$ASB_LEDGER_MAX" "$ASB_LEDGER" > "$ASB_LEDGER.tmp" 2>/dev/null \
               && mv -f "$ASB_LEDGER.tmp" "$ASB_LEDGER" 2>/dev/null
           fi ;;
  esac
  return 0
}

# asb_ledger_settings <namespace> <key> <value> [reason]
#
# Write a settings key and record what the device did with it. Returns 0 whenever the
# device ended up in the requested state - including "it was already there" - so callers
# can branch on success without treating a no-op as a failure.
asb_ledger_settings() {
  _ls_ns="$1" _ls_k="$2" _ls_v="$3" _ls_why="${4:-}"
  [ -n "$_ls_ns" ] && [ -n "$_ls_k" ] || return 1
  command -v settings >/dev/null 2>&1 || {
    asb_ledger_note settings "$_ls_k" "$_ls_v" "" "" unsupported "settings binary absent" ""
    return 1
  }

  _ls_prev="$(settings get "$_ls_ns" "$_ls_k" 2>/dev/null)"
  [ "$_ls_prev" = "null" ] && _ls_prev=""

  if [ "$_ls_prev" = "$_ls_v" ]; then
    asb_ledger_note settings "$_ls_k" "$_ls_v" "$_ls_prev" "$_ls_prev" already_set "$_ls_why" ""
    return 0
  fi

  _ls_err="$(settings put "$_ls_ns" "$_ls_k" "$_ls_v" 2>&1)"
  _ls_rc=$?
  _ls_now="$(settings get "$_ls_ns" "$_ls_k" 2>/dev/null)"
  [ "$_ls_now" = "null" ] && _ls_now=""

  if [ "$_ls_now" = "$_ls_v" ]; then
    asb_ledger_note settings "$_ls_k" "$_ls_v" "$_ls_prev" "$_ls_now" applied "$_ls_why" ""
    return 0
  fi
  # Distinguish "refused" from "accepted then ignored": the first is a permission or
  # policy problem the user might fix, the second is the ROM overriding us and no amount
  # of retrying will help.
  if [ "$_ls_rc" != "0" ]; then
    case "$_ls_err" in
      *ermission*|*SecurityException*|*denied*)
        asb_ledger_note settings "$_ls_k" "$_ls_v" "$_ls_prev" "$_ls_now" not_writable "permission refused" "" ;;
      *)
        asb_ledger_note settings "$_ls_k" "$_ls_v" "$_ls_prev" "$_ls_now" not_writable "write rejected" "" ;;
    esac
  else
    asb_ledger_note settings "$_ls_k" "$_ls_v" "$_ls_prev" "$_ls_now" readback_mismatch \
      "accepted but device reports a different value" ""
  fi
  return 1
}

# asb_ledger_sysfs <path> <value> [reason]
asb_ledger_sysfs() {
  _lf_p="$1" _lf_v="$2" _lf_why="${3:-}"
  [ -n "$_lf_p" ] || return 1
  _lf_name="${_lf_p##*/}"
  if [ ! -e "$_lf_p" ]; then
    asb_ledger_note sysfs "$_lf_name" "$_lf_v" "" "" unsupported "node absent on this device" ""
    return 1
  fi
  if [ ! -w "$_lf_p" ]; then
    asb_ledger_note sysfs "$_lf_name" "$_lf_v" "$(cat "$_lf_p" 2>/dev/null)" "" not_writable "read-only" ""
    return 1
  fi
  _lf_prev="$(cat "$_lf_p" 2>/dev/null | tr -d '\r\n')"
  if [ "$_lf_prev" = "$_lf_v" ]; then
    asb_ledger_note sysfs "$_lf_name" "$_lf_v" "$_lf_prev" "$_lf_prev" already_set "$_lf_why" ""
    return 0
  fi
  # Capture the shell's own verdict too. `-w` is true for root on a 0444 file, and a
  # kernel node can refuse a write with EACCES or EINVAL while still being writable by
  # mode - so the redirect's exit status is the only thing that distinguishes "refused"
  # from "accepted and adjusted". Without it a read-only node was being reported as
  # readback_mismatch, which sends the reader looking for a rounding bug that is not there.
  if echo "$_lf_v" > "$_lf_p" 2>/dev/null; then
    _lf_wrote=1
  else
    _lf_wrote=0
  fi
  _lf_now="$(cat "$_lf_p" 2>/dev/null | tr -d '\r\n')"
  if [ "$_lf_now" = "$_lf_v" ]; then
    asb_ledger_note sysfs "$_lf_name" "$_lf_v" "$_lf_prev" "$_lf_now" applied "$_lf_why" ""
    return 0
  fi
  if [ "$_lf_wrote" = "0" ]; then
    asb_ledger_note sysfs "$_lf_name" "$_lf_v" "$_lf_prev" "$_lf_now" not_writable \
      "write refused by the kernel" ""
    return 1
  fi
  # A kernel that rounds to the nearest supported step is not misbehaving - it is telling
  # us the request was not expressible. Worth its own note, because chasing it as a bug
  # wastes the time of whoever reads this file.
  asb_ledger_note sysfs "$_lf_name" "$_lf_v" "$_lf_prev" "$_lf_now" readback_mismatch \
    "kernel adjusted the value" ""
  return 1
}

# asb_ledger_skip <domain> <key> <result> <reason>
#
# For decisions taken without touching the device: a guard refused, a lease was held,
# nothing to do yet. A skip that leaves no trace is why "it says on but does nothing"
# takes an afternoon to diagnose.
asb_ledger_skip() {
  asb_ledger_note "${1:-?}" "${2:-?}" "" "" "" "${3:-safety_veto}" "${4:-}" ""
  return 0
}
