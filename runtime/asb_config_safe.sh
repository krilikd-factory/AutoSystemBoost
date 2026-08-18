#!/system/bin/sh
# asb_config_safe.sh — the only runtime writer for governor.conf.
#
# It prevents the former split-brain failure where shell code read the first
# duplicate key and the native daemon read the last one. Updates are staged,
# validated and atomically renamed while a tiny mkdir lock serializes WebUI,
# boot and helper writes.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
SHIPPED="$MODDIR/config/governor.conf.shipped"
STATE="${ASB_CONFIG_STATE:-/data/adb/asb}"
LOCK="$STATE/config.lock"

_die() { echo "asb_config_safe: $*" >&2; exit 1; }

_lock() {
  mkdir -p "$STATE" 2>/dev/null || _die "cannot create state directory"
  _i=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    _i=$((_i + 1))
    [ "$_i" -lt 50 ] || _die "config lock timeout"
    sleep 0.1
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT HUP INT TERM
}

_key_allowed() {
  _k="$1"
  case "$_k" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  _schema="$SHIPPED"
  [ -r "$_schema" ] || _schema="$CONF"
  grep -qE "^[[:space:]]*${_k}=" "$_schema" 2>/dev/null
}

_value_safe() {
  # Values are deliberately simple scalar config tokens. Reject quotes,
  # whitespace, shell separators and newlines before any shell command sees it.
  case "$1" in ''|*[!A-Za-z0-9_.+:-]*) return 1 ;; esac
  return 0
}

_no_duplicates() {
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      p=index($0,"="); if (!p) next
      k=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (++seen[k] > 1) { print "duplicate key: " k > "/dev/stderr"; bad=1 }
    }
    END { exit bad ? 1 : 0 }
  ' "$1"
}

_num() {
  _v="$(awk -F= -v k="$1" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" {v=$2; sub(/#.*/,"",v); gsub(/[[:space:]]/,"",v); print v; exit}' "$2")"
  case "$_v" in ''|*[!0-9-]*) return 1 ;; esac
  printf '%s' "$_v"
}

_between() { [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null; }

_validate() {
  _f="$1"
  _no_duplicates "$_f" || return 1
  _enter="$(_num sustained_temp_enter "$_f")" || return 1
  _exit="$(_num sustained_temp_exit "$_f")" || return 1
  _tick="$(_num quiet_tick_s "$_f")" || return 1
  _qs="$(_num night_quiet_hour_start "$_f")" || return 1
  _qe="$(_num night_quiet_hour_end "$_f")" || return 1
  _bl="$(_num auto_battery_low_pct "$_f")" || return 1
  _bh="$(_num auto_battery_high_pct "$_f")" || return 1
  _between "$_enter" 40 70 && _between "$_exit" 30 69 && [ "$_exit" -lt "$_enter" ] || _die "invalid sustained temperature hysteresis"
  _between "$_tick" 5 3600 || _die "quiet_tick_s must be 5..3600"
  _between "$_qs" 0 23 && _between "$_qe" 0 23 || _die "night quiet hours must be 0..23"
  _between "$_bl" 1 99 && _between "$_bh" 2 100 && [ "$_bl" -lt "$_bh" ] || _die "invalid auto battery thresholds"
  return 0
}

_update_one() {
  _src="$1" _dst="$2" _key="$3" _val="$4"
  awk -v k="$_key" -v v="$_val" '
    BEGIN { n=0 }
    {
      p=index($0,"=")
      if (p) {
        left=substr($0,1,p-1); probe=left
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", probe)
        if (probe==k) { print k "=" v; n++; next }
      }
      print
    }
    END { if (n==0) print k "=" v; if (n>1) exit 2 }
  ' "$_src" > "$_dst"
}

[ "$#" -ge 1 ] || _die "usage: $0 set KEY VALUE [snapshot] | validate [FILE]"
case "$1" in
  validate)
    _validate "${2:-$CONF}" && echo "ok"
    ;;
  set)
    [ "$#" -ge 3 ] || _die "set needs KEY and VALUE"
    _key="$2" _val="$3" _snapshot="${4:-}"
    _key_allowed "$_key" || _die "unknown key: $_key"
    _value_safe "$_val" || _die "invalid scalar value"
    [ -f "$CONF" ] || _die "missing governor.conf"
    _lock
    _no_duplicates "$CONF" || _die "refusing to update duplicated config"
    _tmp="$CONF.tmp.$$"
    _update_one "$CONF" "$_tmp" "$_key" "$_val" || { rm -f "$_tmp"; _die "update failed"; }
    _validate "$_tmp" || { rm -f "$_tmp"; exit 1; }
    chmod 0644 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$CONF" || _die "atomic replace failed"
    if [ -n "$_snapshot" ]; then
      _stmp="$_snapshot.tmp.$$"
      if [ -f "$_snapshot" ]; then _update_one "$_snapshot" "$_stmp" "$_key" "$_val"; else printf '%s=%s\n' "$_key" "$_val" > "$_stmp"; fi
      chmod 0644 "$_stmp" 2>/dev/null || true
      mv -f "$_stmp" "$_snapshot" 2>/dev/null || true
    fi
    echo "ok"
    ;;
  *) _die "unknown command: $1" ;;
esac
