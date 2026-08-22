#!/system/bin/sh
# asb_trial.sh - put a risky, user-selected setting on probation instead of on trust.
#
# A trial is a real config transaction, not a note beside one:
#   1. validate a narrow allowlist and scalar value through asb_config_safe.sh;
#   2. capture the previous effective config value and a before snapshot;
#   3. apply and read the config back before publishing an active trial record;
#   4. keep the record until explicit confirmation or a verified rollback succeeds.
#
# Device-side writers can apply on their ordinary cadence. Trial never pretends their
# eventual runtime effect is already proven; it records config acceptance separately and
# only rolls back automatically on evidence (rejected writer ledger entry or expiry).

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE="${ASB_CONFIG_STATE:-/data/adb/asb}"
CONF="$MODDIR/config/governor.conf"
WRITER="$MODDIR/runtime/asb_config_safe.sh"
TRIAL="$STATE/trial"
LEDGER="$STATE/apply_ledger"

_has() { command -v "$1" >/dev/null 2>&1; }
_now() { date +%s 2>/dev/null || echo 0; }

# Keep the trial surface deliberately narrow. These are optional, reversible controls whose
# cost is visible to the user; profiles and thermal caps remain normal explicit config edits.
_trial_key_allowed() {
  case "${1:-}" in
    doze_level|doze_trim_whitelist|wakelock_action|gnss_trim|night_modem_idle|\
    gms_trim|gms_freeze|UX_MANAGE_OEM_TOGGLES|wifi_country|audio_remove_volume_limit|\
    smart_media_guard)
      return 0 ;;
    *) return 1 ;;
  esac
}

_valid_key() {
  case "${1:-}" in ''|*[!A-Za-z0-9_]*) return 1 ;; *) _trial_key_allowed "$1" ;; esac
}

# asb_config_safe validates transaction shape and safety invariants. Trial additionally
# constrains each risky control to its real runtime enum so a syntactically-safe typo cannot
# become a deceptive active trial that the downstream writer silently treats as stock/off.
_valid_value() {
  _vv_k="$1" _vv_v="$2"
  case "$_vv_k" in
    doze_level) case "$_vv_v" in stock|moderate|aggressive|night) return 0 ;; esac ;;
    gms_trim) case "$_vv_v" in stock|lite|strict) return 0 ;; esac ;;
    gms_freeze) case "$_vv_v" in off|safe|more) return 0 ;; esac ;;
    wifi_country) case "$_vv_v" in auto|CR|US|DE|JP) return 0 ;; esac ;;
    doze_trim_whitelist|wakelock_action|gnss_trim|night_modem_idle|gms_trim|\
    UX_MANAGE_OEM_TOGGLES|audio_remove_volume_limit|smart_media_guard)
      case "$_vv_v" in 0|1) return 0 ;; esac ;;
  esac
  return 1
}

# Exact parser: keys are never interpolated into grep regexes.
_conf_value() {
  [ -r "$CONF" ] || return 1
  awk -F= -v k="$1" '
    $1 ~ /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*$/ {
      left=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", left)
      if (left == k) { v=$2; sub(/#.*/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit }
    }
  ' "$CONF"
}

_clean_line() { printf '%s' "${1:-}" | tr '\n\r|' '___' | cut -c1-160; }

_load_ledger() {
  command -v asb_ledger_note >/dev/null 2>&1 && return 0
  for _lp in "$MODDIR/runtime/asb_apply_ledger.sh" "$(dirname "$0")/asb_apply_ledger.sh"; do
    [ -f "$_lp" ] && . "$_lp" && break
  done
  command -v asb_ledger_note >/dev/null 2>&1
}

_ledger() {
  _load_ledger || return 0
  asb_ledger_note trial "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

_snapshot() {
  _sn_f="$1"
  {
    echo "ts=$(_now)"
    echo "awake_pct=$(grep -m1 '^awake_pct_screenoff=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
    echo "awake_window_min=$(grep -m1 '^awake_window_min=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
    echo "drain_x10=$(grep -m1 '^smart_drain_pctph_x10=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
    echo "drain_conf=$(grep -m1 '^battery_window_confidence=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
    echo "screenoff_class=$(grep -m1 '^class=' /dev/.asb/screenoff_class 2>/dev/null | cut -d= -f2)"
    if _has dumpsys; then
      echo "doze_state=$(dumpsys deviceidle get deep 2>/dev/null | tr -d '\r\n')"
      echo "doze_whitelist_n=$(dumpsys deviceidle whitelist 2>/dev/null | grep -c .)"
    fi
    [ -s "$STATE/wakelock_top" ] && \
      echo "top_wakelock=$(head -1 "$STATE/wakelock_top" 2>/dev/null | cut -d'|' -f1)"
  } > "$_sn_f" 2>/dev/null
}

_record_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }
_record_error() {
  _rf="$1" _why="$2"
  printf 'last_error=%s\nlast_error_at=%s\n' "$(_clean_line "$_why")" "$(_now)" >> "$_rf" 2>/dev/null
}

_apply_config() {
  _ac_k="$1" _ac_v="$2" _ac_out="$3"
  [ -x "$WRITER" ] || return 1
  ASB_CONFIG_TXN="$STATE/config_last_txn" sh "$WRITER" set "$_ac_k" "$_ac_v" > "$_ac_out" 2>&1 || return 1
  [ "$(_conf_value "$_ac_k")" = "$_ac_v" ]
}

# asb_trial start <key> <value> [hours]
_start() {
  _k="${1:-}" _v="${2:-}" _h="${3:-12}"
  _valid_key "$_k" || { echo "trial: unsupported or unsafe key: $_k" >&2; return 1; }
  _valid_value "$_k" "$_v" || { echo "trial: unsupported value for $_k: $_v" >&2; return 1; }
  case "$_h" in ''|*[!0-9]*) echo "trial: hours must be an integer" >&2; return 1 ;; esac
  [ "$_h" -ge 1 ] 2>/dev/null && [ "$_h" -le 72 ] 2>/dev/null || {
    echo "trial: hours must be 1..72" >&2; return 1;
  }
  [ -f "$CONF" ] && [ -x "$WRITER" ] || { echo "trial: config writer unavailable" >&2; return 1; }
  mkdir -p "$TRIAL" 2>/dev/null || return 1
  _tf="$TRIAL/$_k.trial"
  [ ! -e "$_tf" ] || { echo "trial: $_k already has an active trial" >&2; return 1; }

  _prev="$(_conf_value "$_k")"
  [ -n "$_prev" ] || { echo "trial: key is not present in active config: $_k" >&2; return 1; }
  _started="$(_now)"
  _expires=$(( _started + _h * 3600 ))
  _pending="$TRIAL/.$_k.pending.$$"
  _snapshot "$TRIAL/$_k.before"
  {
    echo "key=$_k"
    echo "trial_value=$_v"
    echo "previous_value=$_prev"
    echo "started=$_started"
    echo "expires=$_expires"
    echo "ledger_mark=$(wc -l < "$LEDGER" 2>/dev/null || echo 0)"
  } > "$_pending" 2>/dev/null || return 1

  _out="$TRIAL/.$_k.apply.$$"
  if ! _apply_config "$_k" "$_v" "$_out"; then
    _why="config apply/read-back failed: $(tail -n 1 "$_out" 2>/dev/null)"
    _record_error "$_pending" "$_why"
    _ledger "$_k" "$_v" "$_prev" "$(_conf_value "$_k")" not_writable "$(_clean_line "$_why")" "$_expires"
    rm -f "$_out" "$TRIAL/$_k.before" 2>/dev/null
    mv -f "$_pending" "$TRIAL/$_k.start_failed" 2>/dev/null
    echo "trial: $_k was not started; active config did not accept the requested value" >&2
    return 1
  fi
  rm -f "$_out" 2>/dev/null
  mv -f "$_pending" "$_tf" || return 1
  _ledger "$_k" "$_v" "$_prev" "$_v" applied "trial config accepted; runtime evidence pending" "$_expires"
  echo "trial: $_k = $_v for ${_h}h; config accepted, confirm or it reverts"
  return 0
}

_revert_record() {
  _tf="$1" _why="$2"
  _k="$(_record_get "$_tf" key)"
  _prev="$(_record_get "$_tf" previous_value)"
  _valid_key "$_k" || { _record_error "$_tf" "unsafe record key"; return 1; }
  [ -n "$_prev" ] || { _record_error "$_tf" "missing previous value"; return 1; }
  _snapshot "$TRIAL/$_k.after"
  _out="$TRIAL/.$_k.revert.$$"
  if ! _apply_config "$_k" "$_prev" "$_out"; then
    _err="rollback failed: $(tail -n 1 "$_out" 2>/dev/null)"
    _record_error "$_tf" "$_err"
    _ledger "$_k" "$_prev" "$(_conf_value "$_k")" "$(_conf_value "$_k")" deferred "$(_clean_line "$_err")" ""
    rm -f "$_out" 2>/dev/null
    echo "trial: rollback for $_k failed; active record retained for retry" >&2
    return 1
  fi
  rm -f "$_out" 2>/dev/null
  _ledger "$_k" "$_prev" "$(_record_get "$_tf" trial_value)" "$_prev" applied "reverted: $(_clean_line "$_why")" ""
  rm -f "$_tf" 2>/dev/null
  echo "trial: $_k reverted to $_prev - $_why"
  return 0
}

_check() {
  [ -d "$TRIAL" ] || return 0
  for _tf in "$TRIAL"/*.trial; do
    [ -f "$_tf" ] || continue
    _k="$(_record_get "$_tf" key)"
    _exp="$(_record_get "$_tf" expires)"
    _mark="$(_record_get "$_tf" ledger_mark)"
    _valid_key "$_k" || { _record_error "$_tf" "unsafe active record key"; continue; }
    case "$_exp" in ''|*[!0-9]*) _record_error "$_tf" "invalid expiry"; continue ;; esac

    # If a real writer reported rejection for this exact config key after the trial began,
    # roll back. Missing ledger evidence is not treated as failure.
    if [ -s "$LEDGER" ] && [ -n "$_mark" ]; then
      _bad="$(tail -n +"$((_mark + 1))" "$LEDGER" 2>/dev/null | \
        awk -F'|' -v k="$_k" '$3==k && ($7=="not_writable" || $7=="readback_mismatch" || $7=="unsupported"){n++} END{print n+0}')"
      if [ "${_bad:-0}" -gt 0 ] 2>/dev/null; then
        _revert_record "$_tf" "writer rejected ${_bad} time(s)" || true
        continue
      fi
    fi
    if [ "$(_now)" -ge "$_exp" ] 2>/dev/null; then
      _revert_record "$_tf" "trial expired without confirmation" || true
    fi
  done
}

_confirm() {
  _k="${1:-}"
  _valid_key "$_k" || { echo "trial: unsupported or unsafe key: $_k" >&2; return 1; }
  _tf="$TRIAL/$_k.trial"
  [ -f "$_tf" ] || { echo "trial: no active trial for $_k" >&2; return 1; }
  _want="$(_record_get "$_tf" trial_value)"
  if [ "$(_conf_value "$_k")" != "$_want" ]; then
    _record_error "$_tf" "cannot keep: active config no longer matches trial value"
    echo "trial: cannot keep $_k; active config changed" >&2
    return 1
  fi
  _snapshot "$TRIAL/$_k.after"
  mv -f "$_tf" "$TRIAL/$_k.kept" || return 1
  _ledger "$_k" "$_want" "$(_record_get "$TRIAL/$_k.kept" previous_value)" "$_want" applied "trial confirmed by user" ""
  echo "trial: $_k confirmed - keeping it"
}

_revert() {
  _k="${1:-}"
  _valid_key "$_k" || { echo "trial: unsupported or unsafe key: $_k" >&2; return 1; }
  _tf="$TRIAL/$_k.trial"
  [ -f "$_tf" ] || { echo "trial: no active trial for $_k" >&2; return 1; }
  _revert_record "$_tf" "user requested"
}

case "${1:-check}" in
  start)   shift; _start "$@" ;;
  check)   _check ;;
  confirm) shift; _confirm "${1:-}" ;;
  revert)  shift; _revert "${1:-}" ;;
  *) echo "usage: asb_trial {start KEY VALUE [HOURS]|check|confirm KEY|revert KEY}" >&2; exit 1 ;;
esac
