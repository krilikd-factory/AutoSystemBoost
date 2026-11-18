#!/system/bin/sh
# asb_display_ui_apply.sh - bounded ColorOS interface/display Settings controls.
#
# Every non-stock write goes through the Settings/content fallback and the exact pre-ASB
# baseline. A stored config value is not proof that Android accepted it: every write and
# restore is read back. `stock` means "restore only what ASB owns"; with no baseline row it
# leaves the current ROM/user value alone.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -r "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"
[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"

ASB_DISPLAY_UI_KEYS='ui_recents_memory ui_recents_corner_radius ui_smooth_corners ui_nav_handle_autohide feel_pointer_speed feel_gesture_mistouch feel_game_memc feel_dc_dimming'

_cfg() {
  awk -F= -v k="$1" '
    $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
      v=$2; sub(/#.*/, "", v); gsub(/[[:space:]\r]/, "", v); print v; exit
    }' "$CONF" 2>/dev/null
}

_known_key() {
  case " $ASB_DISPLAY_UI_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

_valid() {
  case "$1" in
    ui_recents_corner_radius) case "$2" in stock|0|8|12|16|20|24|28|32) return 0 ;; esac ;;
    feel_pointer_speed) case "$2" in stock|-[0-7]|[0-7]) return 0 ;; esac ;;
    *) case "$2" in stock|on|off) return 0 ;; esac ;;
  esac
  return 1
}

# Print the closed setting set for one ASB key as namespace|Settings-key|value rows.
# Recents radius has a master and a dp value in ColorOS; they are restored as one owned unit.
_targets() {
  _t_key="$1" _t_val="$2"
  case "$_t_key" in
    ui_recents_memory)
      _t_v=0; [ "$_t_val" = on ] && _t_v=1
      printf 'secure|display_memory_information_recent_task|%s\n' "$_t_v" ;;
    ui_recents_corner_radius)
      printf 'global|oost_recent_task_radius|1\nglobal|oost_recent_task_radius_dp|%s\n' "$_t_val" ;;
    ui_smooth_corners)
      _t_v=0; [ "$_t_val" = on ] && _t_v=1
      printf 'global|smooth_corner_enabled|%s\n' "$_t_v" ;;
    ui_nav_handle_autohide)
      _t_v=0; [ "$_t_val" = on ] && _t_v=1
      printf 'global|oost_navigation_handle_auto_hide|%s\n' "$_t_v" ;;
    feel_pointer_speed)
      printf 'system|pointer_speed|%s\n' "$_t_val" ;;
    feel_gesture_mistouch)
      _t_v=0; [ "$_t_val" = on ] && _t_v=1
      printf 'secure|gesture_mistouch_prevention_enable|%s\n' "$_t_v" ;;
    feel_game_memc)
      _t_v=0; [ "$_t_val" = on ] && _t_v=1
      printf 'secure|display_memc_game_enable|%s\n' "$_t_v" ;;
    feel_dc_dimming)
      _t_v=0; [ "$_t_val" = on ] && _t_v=1
      printf 'secure|display_dc_settings_switch|%s\n' "$_t_v" ;;
    *) return 1 ;;
  esac
}

_target_names() {
  case "$1" in
    ui_recents_memory) printf 'secure|display_memory_information_recent_task\n' ;;
    ui_recents_corner_radius) printf 'global|oost_recent_task_radius\nglobal|oost_recent_task_radius_dp\n' ;;
    ui_smooth_corners) printf 'global|smooth_corner_enabled\n' ;;
    ui_nav_handle_autohide) printf 'global|oost_navigation_handle_auto_hide\n' ;;
    feel_pointer_speed) printf 'system|pointer_speed\n' ;;
    feel_gesture_mistouch) printf 'secure|gesture_mistouch_prevention_enable\n' ;;
    feel_game_memc) printf 'secure|display_memc_game_enable\n' ;;
    feel_dc_dimming) printf 'secure|display_dc_settings_switch\n' ;;
    *) return 1 ;;
  esac
}

_baseline_has() {
  [ -f "$ASB_BASELINE" ] && awk -F'|' -v ns="$1" -v key="$2" '
    $1=="settings" && $2==ns && $3==key { found=1; exit }
    END { exit !found }
  ' "$ASB_BASELINE" 2>/dev/null
}

_baseline_value() {
  awk -F'|' -v ns="$1" -v key="$2" '
    $1=="settings" && $2==ns && $3==key { print $4; exit }
  ' "$ASB_BASELINE" 2>/dev/null
}

# $1 namespace, $2 Settings key. Returns 2 when ASB never owned it.
_restore_one() {
  _r_ns="$1" _r_key="$2"
  _baseline_has "$_r_ns" "$_r_key" || return 2
  _r_want="$(_baseline_value "$_r_ns" "$_r_key")"
  asb_baseline_restore_setting "$_r_ns" "$_r_key" >/dev/null 2>&1 || return 1
  _r_now="$(asb_set_get "$_r_ns" "$_r_key" 2>/dev/null)"
  [ "$_r_now" = "$_r_want" ]
}

_restore_key() {
  _rk_key="$1" _rk_fail=0 _rk_owned=0
  _rk_results="$(_target_names "$_rk_key" | while IFS='|' read -r _rk_ns _rk_name; do
    [ -n "$_rk_ns" ] && [ -n "$_rk_name" ] || continue
    _restore_one "$_rk_ns" "$_rk_name"
    case "$?" in 0) printf '0\n' ;; 2) printf '2\n' ;; *) printf '1\n' ;; esac
  done)"
  for _rk_rc in $_rk_results; do
    case "$_rk_rc" in
      0) _rk_owned=1 ;;
      1) _rk_owned=1; _rk_fail=1 ;;
    esac
  done
  [ "$_rk_fail" = 0 ] || return 1
  [ "$_rk_owned" = 1 ] || return 2
  return 0
}

_apply_key() {
  _a_key="$1" _a_mode="${2:-apply}"
  _known_key "$_a_key" || { printf '%s|invalid|unknown_key\n' "$_a_key"; return 1; }
  _a_val="$(_cfg "$_a_key")"
  [ -n "$_a_val" ] || _a_val=stock
  _valid "$_a_key" "$_a_val" || { printf '%s|invalid|bounded_value_required\n' "$_a_key"; return 1; }

  if [ "$_a_mode" = boot ] && [ "$_a_val" = stock ]; then
    return 0
  fi
  if [ "$_a_val" = stock ]; then
    _restore_key "$_a_key"
    case "$?" in
      0) printf '%s|restored|exact_baseline\n' "$_a_key"; return 0 ;;
      2) printf '%s|stock_unowned|no_baseline\n' "$_a_key"; return 0 ;;
      *) printf '%s|restore_failed|readback_mismatch\n' "$_a_key"; return 1 ;;
    esac
  fi

  command -v asb_settings_put >/dev/null 2>&1 && command -v asb_set_get >/dev/null 2>&1 || {
    printf '%s|write_failed|settings_helper_missing\n' "$_a_key"; return 1;
  }
  asb_set_ok >/dev/null 2>&1 || { printf '%s|write_failed|settings_unavailable\n' "$_a_key"; return 1; }

  # Separate from the persistent pre-ASB baseline: a failed later edit must return to the
  # value seen immediately before THIS attempt, not jump back to the first-ever ROM value.
  _a_before="$(_target_names "$_a_key" | while IFS='|' read -r _a_ns _a_name; do
    [ -n "$_a_ns" ] && [ -n "$_a_name" ] || continue
    printf '%s|%s|%s\n' "$_a_ns" "$_a_name" "$(asb_set_get "$_a_ns" "$_a_name" 2>/dev/null)"
  done)"
  _a_fail=0
  while IFS='|' read -r _a_ns _a_name _a_want; do
    [ -n "$_a_ns" ] && [ -n "$_a_name" ] || continue
    asb_settings_put "$_a_ns" "$_a_name" "$_a_want" >/dev/null 2>&1 || _a_fail=1
    _a_now="$(asb_set_get "$_a_ns" "$_a_name" 2>/dev/null)"
    [ "$_a_now" = "$_a_want" ] || _a_fail=1
  done <<EOF_TARGETS
$(_targets "$_a_key" "$_a_val")
EOF_TARGETS

  if [ "$_a_fail" != 0 ]; then
    # Best-effort rollback to the exact values captured before this attempt. In particular,
    # never leave the Recents radius master enabled with an unverified dp value. The persistent
    # baseline remains untouched for the user's later explicit return to Stock.
    _a_rollback_fail=0
    while IFS='|' read -r _a_ns _a_name _a_old; do
      [ -n "$_a_ns" ] && [ -n "$_a_name" ] || continue
      if [ -z "$_a_old" ]; then settings delete "$_a_ns" "$_a_name" >/dev/null 2>&1 || true
      else settings put "$_a_ns" "$_a_name" "$_a_old" >/dev/null 2>&1 || true; fi
      [ "$(asb_set_get "$_a_ns" "$_a_name" 2>/dev/null)" = "$_a_old" ] || _a_rollback_fail=1
    done <<EOF_BEFORE
$_a_before
EOF_BEFORE
    if [ "$_a_rollback_fail" = 0 ]; then printf '%s|write_failed|readback_mismatch\n' "$_a_key"
    else printf '%s|write_failed|rollback_failed\n' "$_a_key"; fi
    return 1
  fi
  printf '%s|applied|%s\n' "$_a_key" "$_a_val"
  return 0
}

# Read-only field evidence. Values outside the bounded numeric/name vocabulary are not
# copied into a machine-readable report. An unset Settings key is an observation, not proof
# that the ROM lacks a renderer or that the key is unsupported.
_diag_value() {
  [ -n "$1" ] || { printf '<unset>\n'; return; }
  case "$1" in *[!A-Za-z0-9_.-]*) printf 'unknown\n'; return ;; esac
  [ "${#1}" -le 48 ] || { printf 'unknown\n'; return; }
  printf '%s\n' "$1"
}
_diag_home() {
  _diag_home_component=unknown _diag_home_version=unknown
  _dh_raw="$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -n 1)"
  case "$_dh_raw" in
    ''|*/*/*) _dh_raw="" ;;
    */*) : ;;
    *) _dh_raw="" ;;
  esac
  case "$_dh_raw" in ''|*[!A-Za-z0-9._/$%-]*) _dh_raw="" ;; esac
  [ "${#_dh_raw}" -le 180 ] || _dh_raw=""
  [ -n "$_dh_raw" ] || return 0
  _diag_home_component="$_dh_raw"
  _dh_pkg="${_dh_raw%%/*}"
  _dh_ver="$(dumpsys package "$_dh_pkg" 2>/dev/null | sed -n 's/^[[:space:]]*versionName=//p' | head -n 1)"
  case "$_dh_ver" in ''|*[!A-Za-z0-9_.-]*) return 0 ;; esac
  [ "${#_dh_ver}" -le 48 ] || return 0
  _diag_home_version="$_dh_ver"
}
_diagnose_key() {
  _dk_key="$1" _dk_transport="$2"
  _dk_val="$(_cfg "$_dk_key")"; [ -n "$_dk_val" ] || _dk_val=stock
  _dk_valid=1; _valid "$_dk_key" "$_dk_val" || _dk_valid=0
  _dk_match=1 _dk_owned=0 _dk_unowned=0 _dk_rows=""
  _dk_targets=""
  [ "$_dk_valid" = 1 ] && [ "$_dk_val" != stock ] && _dk_targets="$(_targets "$_dk_key" "$_dk_val")"
  while IFS='|' read -r _dk_ns _dk_name; do
    [ -n "$_dk_ns" ] && [ -n "$_dk_name" ] || continue
    _dk_base_state=unowned _dk_base="" _dk_expected=-
    if _baseline_has "$_dk_ns" "$_dk_name"; then
      _dk_base_state=owned _dk_owned=1 _dk_base="$(_baseline_value "$_dk_ns" "$_dk_name")"
    else
      _dk_unowned=1
    fi
    _dk_live_raw=unknown
    if [ "$_dk_transport" = available ]; then _dk_live_raw="$(asb_set_get "$_dk_ns" "$_dk_name" 2>/dev/null)"; fi
    if [ "$_dk_valid" = 1 ] && [ "$_dk_val" != stock ]; then
      _dk_expected="$(printf '%s\n' "$_dk_targets" | awk -F'|' -v ns="$_dk_ns" -v key="$_dk_name" '$1==ns && $2==key {print $3; exit}')"
      [ "$_dk_live_raw" = "$_dk_expected" ] || _dk_match=0
    elif [ "$_dk_val" = stock ] && [ "$_dk_base_state" = owned ]; then
      [ "$_dk_live_raw" = "$_dk_base" ] || _dk_match=0
    fi
    _dk_base_print="$_dk_base"
    [ "$_dk_base_state" = owned ] && [ -z "$_dk_base_print" ] && _dk_base_print='<empty>'
    _dk_rows="${_dk_rows}display_ui_target|key=${_dk_key}|namespace=${_dk_ns}|name=${_dk_name}|expected=${_dk_expected}|live=$(_diag_value "$_dk_live_raw")|baseline=$(_diag_value "$_dk_base_print")|baseline_state=${_dk_base_state}
"
  done <<EOF_DIAG_TARGETS
$(_target_names "$_dk_key")
EOF_DIAG_TARGETS
  _dk_baseline=unowned
  [ "$_dk_owned" = 1 ] && _dk_baseline=owned
  [ "$_dk_owned" = 1 ] && [ "$_dk_unowned" = 1 ] && _dk_baseline=partial
  if [ "$_dk_transport" != available ]; then _dk_verdict=settings_unavailable
  elif [ "$_dk_valid" = 0 ]; then _dk_verdict=invalid_config
  elif [ "$_dk_val" = stock ]; then
    if [ "$_dk_owned" = 0 ]; then _dk_verdict=stock_unowned_observed
    elif [ "$_dk_match" = 1 ]; then _dk_verdict=stock_baseline_matches
    else _dk_verdict=stock_readback_mismatch; fi
  elif [ "$_dk_match" = 1 ]; then _dk_verdict=write_verified_visual_unverified
  else _dk_verdict=readback_mismatch_visual_unverified; fi
  printf 'display_ui_key|key=%s|configured=%s|verdict=%s|baseline=%s|visual=unverified\n' \
    "$_dk_key" "$_dk_val" "$_dk_verdict" "$_dk_baseline"
  printf '%s' "$_dk_rows"
}

_command="${1:-apply}"
case "$_command" in
  apply)
    if [ "$#" -gt 1 ]; then
      _apply_key "$2" apply
      exit $?
    fi
    _all_fail=0
    for _k in $ASB_DISPLAY_UI_KEYS; do _apply_key "$_k" apply || _all_fail=1; done
    [ "$_all_fail" = 0 ]
    ;;
  boot)
    _all_fail=0
    for _k in $ASB_DISPLAY_UI_KEYS; do _apply_key "$_k" boot || _all_fail=1; done
    [ "$_all_fail" = 0 ]
    ;;
  status)
    for _k in $ASB_DISPLAY_UI_KEYS; do
      _v="$(_cfg "$_k")"; [ -n "$_v" ] || _v=stock
      _target_names "$_k" | while IFS='|' read -r _ns _name; do
        [ -n "$_ns" ] && [ -n "$_name" ] || continue
        printf '%s|status|%s:%s=%s\n' "$_k" "$_ns" "$_name" "$(asb_set_get "$_ns" "$_name" 2>/dev/null)"
      done
    done
    ;;
  diagnose)
    [ "$#" -le 2 ] || { printf 'usage: asb_display_ui_apply.sh diagnose [key]\n' >&2; exit 2; }
    if [ "$#" = 2 ]; then _known_key "$2" || { printf 'error=unknown_key\n' >&2; exit 2; }; fi
    _diag_transport=unavailable
    asb_set_ok >/dev/null 2>&1 && _diag_transport=available
    _diag_home
    printf 'display_ui_diagnostics|schema=1|settings_transport=%s|home=%s|home_version=%s\n' \
      "$_diag_transport" "$_diag_home_component" "$_diag_home_version"
    for _k in $ASB_DISPLAY_UI_KEYS; do
      [ "$#" != 2 ] || [ "$_k" = "$2" ] || continue
      _diagnose_key "$_k" "$_diag_transport"
    done
    printf 'display_ui_visual|unverified|settings_readback_is_not_launcher_or_systemui_rendering_evidence\n'
    ;;
  *) printf 'usage: asb_display_ui_apply.sh apply [key] | boot | status | diagnose [key]\n' >&2; exit 2 ;;
esac
