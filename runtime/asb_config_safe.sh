#!/system/bin/sh
# asb_config_safe.sh — the only runtime writer for governor.conf.
#
# The writer serializes WebUI, boot and helper changes with a mkdir lock. Every
# update is staged, validated as a complete config and atomically renamed. Do
# not edit governor.conf with sed/echo from runtime code: use set, set-many or
# import so the daemon and shell never observe a split-brain policy.

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
  # The active config is authoritative after installation. The shipped file is
  # only a bootstrap fallback; preferring it caused newly introduced keys to be
  # rejected when a source checkout had an older shipped baseline.
  _schema="$CONF"
  [ -r "$_schema" ] || _schema="$SHIPPED"
  grep -qE "^[[:space:]]*${_k}=" "$_schema" 2>/dev/null
}

_value_safe() {
  # Scalar tokens only. Reject whitespace, quotes, shell separators and newlines
  # before a value is handed to awk or any shell command.
  case "$1" in ''|*[!A-Za-z0-9_.+:-]*) return 1 ;; esac
  return 0
}

_no_duplicates() {
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      p=index($0,"="); if (!p) next
      k=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      # Same prefix every other refusal uses: the WebUI filters stderr on it to find the
      # reason, so a message without it is invisible - and a stale config with a duplicate
      # key is exactly the case where the user most needs to be told what is wrong.
      if (++seen[k] > 1) { print "asb_config_safe: duplicate key in config: " k > "/dev/stderr"; bad=1 }
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
_float_between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v + 0 >= lo && v + 0 <= hi) }'; }
_bool() { case "$1" in 0|1) return 0 ;; *) return 1 ;; esac; }

_require_float() {
  _rf="$(awk -F= -v k="$1" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" {v=$2; sub(/#.*/,"",v); gsub(/[[:space:]]/,"",v); print v; exit}' "$2")"
  case "$_rf" in ''|*[!0-9.+-]*) _die "missing or non-decimal $1" ;; esac
  awk -v v="$_rf" 'BEGIN { exit !(v ~ /^[-+]?[0-9]+([.][0-9]+)?$/) }' || _die "invalid decimal $1"
  printf '%s' "$_rf"
}

_require_num() {
  _rn="$(_num "$1" "$2")" || _die "missing or non-numeric $1"
  printf '%s' "$_rn"
}

_validate() {
  _f="$1"
  _no_duplicates "$_f" || return 1

  _enter="$(_require_num sustained_temp_enter "$_f")"
  _exit="$(_require_num sustained_temp_exit "$_f")"
  _ceiling="$(_require_num sustained_temp_ceiling "$_f")"
  _override="$(_require_num sustained_temp_user_override "$_f")"
  _tick="$(_require_num quiet_tick_s "$_f")"
  _qs="$(_require_num night_quiet_hour_start "$_f")"
  _qe="$(_require_num night_quiet_hour_end "$_f")"
  _bl="$(_require_num auto_battery_low_pct "$_f")"
  _bh="$(_require_num auto_battery_high_pct "$_f")"

  _overlay="$(_require_num thermal_overlay_pct "$_f")"
  _skin_gate="$(_require_num thermal_skin_gate "$_f")"
  _skin="$(_require_num thermal_skin_c "$_f")"
  _junction="$(_require_num thermal_junction_hard_c "$_f")"
  _budget_enable="$(_require_num thermal_budget_enable "$_f")"
  _budget_light_hr="$(_require_num thermal_budget_light_headroom_pct "$_f")"
  _budget_moderate_hr="$(_require_num thermal_budget_moderate_headroom_pct "$_f")"
  _budget_severe_hr="$(_require_num thermal_budget_severe_headroom_pct "$_f")"
  _budget_light_trim="$(_require_num thermal_budget_light_trim_pct "$_f")"
  _budget_moderate_trim="$(_require_num thermal_budget_moderate_trim_pct "$_f")"
  _budget_severe_trim="$(_require_num thermal_budget_severe_trim_pct "$_f")"
  _budget_dwell="$(_require_num thermal_budget_dwell_s "$_f")"
  _shadow="$(_require_num shadow_mode "$_f")"
  _game_cap="$(_require_num gaming_cpu_max_ceiling_khz "$_f")"
  _cam_enable="$(_require_num camera_hold_enable "$_f")"
  _cam_busy="$(_require_num camera_busy_pct "$_f")"
  _cam_grace="$(_require_num camera_hold_grace_s "$_f")"
  _cam_max="$(_require_num camera_hold_max_s "$_f")"
  _perf_ceiling="$(_require_num perf_ceiling_pct "$_f")"
  _conf_low="$(_require_num smart_conf_low "$_f")"
  _conf_high="$(_require_num smart_conf_high "$_f")"
  _eff_obs="$(_require_num smart_eff_obs_full "$_f")"
  _heavy_load="$(_require_float heavy_load_enter "$_f")"
  _game_confirm="$(_require_num gaming_confirm_ticks "$_f")"
  _gpu_idle_trim="$(_require_num gpu_idle_trim_pct "$_f")"
  _gpu_video_max="$(_require_num gpu_video_max_pct "$_f")"
  _thermal_throttle="$(_require_num thermal_throttle_temp "$_f")"
  _bounds_override="$(_require_num device_bounds_override "$_f")"

  if ! _between "$_enter" 40 70 || ! _between "$_exit" 30 69 || [ "$_exit" -ge "$_enter" ]; then _die "invalid sustained temperature hysteresis"; fi
  _between "$_ceiling" "$_enter" 70 || _die "sustained_temp_ceiling must be enter..70"
  _bool "$_override" || _die "sustained_temp_user_override must be 0 or 1"
  _between "$_tick" 5 3600 || _die "quiet_tick_s must be 5..3600"
  if ! _between "$_qs" 0 23 || ! _between "$_qe" 0 23; then _die "night quiet hours must be 0..23"; fi
  if ! _between "$_bl" 1 99 || ! _between "$_bh" 2 100 || [ "$_bl" -ge "$_bh" ]; then _die "invalid auto battery thresholds"; fi

  # Thermal values are safety-critical. In particular, overlay >= 100 produces
  # a non-positive multiplier and can make a CPU cap silently skip its write.
  _between "$_overlay" 0 80 || _die "thermal_overlay_pct must be 0..80"
  _bool "$_skin_gate" || _die "thermal_skin_gate must be 0 or 1"
  _between "$_skin" 30 65 || _die "thermal_skin_c must be 30..65"
  _between "$_junction" 70 110 || _die "thermal_junction_hard_c must be 70..110"
  _bool "$_budget_enable" || _die "thermal_budget_enable must be 0 or 1"
  _between "$_budget_light_hr" 30 95 || _die "thermal_budget_light_headroom_pct must be 30..95"
  _between "$_budget_moderate_hr" 20 94 || _die "thermal_budget_moderate_headroom_pct must be 20..94"
  _between "$_budget_severe_hr" 10 93 || _die "thermal_budget_severe_headroom_pct must be 10..93"
  if ! [ "$_budget_severe_hr" -lt "$_budget_moderate_hr" ] || ! [ "$_budget_moderate_hr" -lt "$_budget_light_hr" ]; then
    _die "thermal budget headroom thresholds must descend"
  fi
  _between "$_budget_light_trim" 0 30 || _die "thermal_budget_light_trim_pct must be 0..30"
  _between "$_budget_moderate_trim" "$_budget_light_trim" 45 || _die "thermal_budget_moderate_trim_pct must be light_trim..45"
  _between "$_budget_severe_trim" "$_budget_moderate_trim" 60 || _die "thermal_budget_severe_trim_pct must be moderate_trim..60"
  _between "$_budget_dwell" 5 600 || _die "thermal_budget_dwell_s must be 5..600"
  _bool "$_shadow" || _die "shadow_mode must be 0 or 1"
  _between "$_game_cap" 0 5000000 || _die "gaming_cpu_max_ceiling_khz must be 0..5000000"
  _bool "$_cam_enable" || _die "camera_hold_enable must be 0 or 1"
  _between "$_cam_busy" 1 100 || _die "camera_busy_pct must be 1..100"
  _between "$_cam_grace" 0 600 || _die "camera_hold_grace_s must be 0..600"
  _between "$_cam_max" 0 7200 || _die "camera_hold_max_s must be 0..7200"
  _between "$_perf_ceiling" 60 100 || _die "perf_ceiling_pct must be 60..100"
  if ! _between "$_conf_low" 0 999 || ! _between "$_conf_high" 1 1000 || [ "$_conf_low" -ge "$_conf_high" ]; then _die "invalid Smart confidence bounds"; fi
  _between "$_eff_obs" 1 10000 || _die "smart_eff_obs_full must be 1..10000"
  _float_between "$_heavy_load" 0.1 1000 || _die "heavy_load_enter must be 0.1..1000"
  _between "$_game_confirm" 1 120 || _die "gaming_confirm_ticks must be 1..120"
  _between "$_gpu_idle_trim" 0 90 || _die "gpu_idle_trim_pct must be 0..90"
  _between "$_gpu_video_max" 0 100 || _die "gpu_video_max_pct must be 0..100"
  _between "$_thermal_throttle" 30 110 || _die "thermal_throttle_temp must be 30..110"
  _bool "$_bounds_override" || _die "device_bounds_override must be 0 or 1"
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

_check_pairs() {
  [ "$#" -gt 0 ] || _die "at least one KEY VALUE pair is required"
  [ $(( $# % 2 )) -eq 0 ] || _die "KEY VALUE pairs are incomplete"
  _seen=""
  while [ "$#" -gt 0 ]; do
    _key_allowed "$1" || _die "unknown key: $1"
    _value_safe "$2" || _die "invalid scalar value for $1"
    case " $_seen " in *" $1 "*) _die "duplicate transaction key: $1" ;; esac
    _seen="$_seen $1"
    shift 2
  done
}

_apply_pairs_locked() {
  _snapshot="$1"
  shift
  _check_pairs "$@"
  _no_duplicates "$CONF" || _die "refusing to update duplicated config"
  _tmp="$CONF.tmp.$$"
  cp "$CONF" "$_tmp" || _die "cannot stage config"
  _changed=""
  while [ "$#" -gt 0 ]; do
    _next="$_tmp.next.$$"
    _update_one "$_tmp" "$_next" "$1" "$2" || { rm -f "$_tmp" "$_next"; _die "update failed"; }
    mv -f "$_next" "$_tmp" || { rm -f "$_tmp"; _die "cannot stage update"; }
    _changed="$_changed $1"
    shift 2
  done
  _validate "$_tmp" || { rm -f "$_tmp"; exit 1; }

  _stmp=""
  if [ -n "$_snapshot" ]; then
    _stmp="$_snapshot.tmp.$$"
    if [ -f "$_snapshot" ]; then cp "$_snapshot" "$_stmp"; else : > "$_stmp"; fi
    for _key in $_changed; do
      _val="$(_num "$_key" "$_tmp" 2>/dev/null || true)"
      # Non-numeric scalar tokens (enums) are copied directly from the staged file.
      [ -n "$_val" ] || _val="$(awk -F= -v k="$_key" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" {v=$2; sub(/#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/, "",v); print v; exit}' "$_tmp")"
      _next="$_stmp.next.$$"
      _update_one "$_stmp" "$_next" "$_key" "$_val" || { rm -f "$_tmp" "$_stmp" "$_next"; _die "snapshot update failed"; }
      mv -f "$_next" "$_stmp" || { rm -f "$_tmp" "$_stmp"; _die "cannot stage snapshot"; }
    done
  fi

  chmod 0644 "$_tmp" 2>/dev/null || true
  mv -f "$_tmp" "$CONF" || _die "atomic config replace failed"
  if [ -n "$_stmp" ]; then
    chmod 0644 "$_stmp" 2>/dev/null || true
    mv -f "$_stmp" "$_snapshot" || _die "atomic snapshot replace failed"
  fi
  echo "ok"
}

_set_many() {
  _snapshot=""
  if [ "${1:-}" = "--snapshot" ]; then
    [ "$#" -ge 4 ] || _die "set-many --snapshot needs a path and KEY VALUE pairs"
    _snapshot="$2"
    shift 2
  fi
  [ -f "$CONF" ] || _die "missing governor.conf"
  _lock
  _apply_pairs_locked "$_snapshot" "$@"
}

_import_backup() {
  _input="${1:-}"
  _snapshot="${2:-}"
  shift 2 || true
  if [ -z "$_input" ] || [ -z "$_snapshot" ]; then _die "import needs INPUT SNAPSHOT and allowed keys"; fi
  [ -r "$_input" ] || _die "backup is not readable"
  [ "$#" -gt 0 ] || _die "import needs allowed keys"

  mkdir -p "$STATE" 2>/dev/null || _die "cannot create state directory"
  _allowed=" $* "
  _pairs="$STATE/import_pairs.$$"
  : > "$_pairs" || _die "cannot stage import"
  _seen=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="$(printf '%s' "$_line" | tr -d '\r')"
    case "$_line" in ''|'#'*) continue ;; esac
    case "$_line" in *=*) ;; *) rm -f "$_pairs"; _die "invalid backup line" ;; esac
    _key="${_line%%=*}"; _val="${_line#*=}"
    case "$_allowed" in *" $_key "*) ;; *) continue ;; esac
    _key_allowed "$_key" || { rm -f "$_pairs"; _die "unknown key in backup: $_key"; }
    _value_safe "$_val" || { rm -f "$_pairs"; _die "invalid value for $_key"; }
    case " $_seen " in *" $_key "*) rm -f "$_pairs"; _die "duplicate key in backup: $_key" ;; esac
    _seen="$_seen $_key"
    printf '%s\n%s\n' "$_key" "$_val" >> "$_pairs"
  done < "$_input"

  _n="$(wc -l < "$_pairs" 2>/dev/null | tr -d ' ')"
  [ "$_n" -gt 0 ] 2>/dev/null || { rm -f "$_pairs"; _die "backup contains no allowed settings"; }
  [ $(( _n % 2 )) -eq 0 ] || { rm -f "$_pairs"; _die "invalid import staging"; }

  # Values were validated against a no-whitespace scalar grammar above; turning
  # the staged alternating lines into positional arguments is therefore safe.
  # shellcheck disable=SC2046
  set -- $(cat "$_pairs")
  rm -f "$_pairs"
  _set_many --snapshot "$_snapshot" "$@"
}

[ "$#" -ge 1 ] || _die "usage: $0 validate [FILE] | set KEY VALUE [snapshot] | set-many [--snapshot PATH] KEY VALUE ... | import INPUT SNAPSHOT ALLOWED_KEY ..."
case "$1" in
  validate)
    _validate "${2:-$CONF}" && echo "ok"
    ;;
  set)
    [ "$#" -ge 3 ] || _die "set needs KEY and VALUE"
    _key="$2" _val="$3" _snapshot="${4:-}"
    if [ -n "$_snapshot" ]; then _set_many --snapshot "$_snapshot" "$_key" "$_val"; else _set_many "$_key" "$_val"; fi
    ;;
  set-many)
    shift
    _set_many "$@"
    ;;
  import)
    shift
    _import_backup "$@"
    ;;
  *) _die "unknown command: $1" ;;
esac
