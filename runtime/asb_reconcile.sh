#!/system/bin/sh
# asb_reconcile.sh — runtime profile reconcile loop
# Sourced inside a background subshell from service.sh

  _last_profile=""
  _last_screen="-1"
  _reconcile_fast=3
  _last_wifi_check=0
  _drift_streak=0
  while true; do
    if [ "$ASB_GOV_ENABLED" = "1" ] && asb_governor_running; then
      _rec_scr=0
      for _rsp in /sys/kernel/oplus_display/panel_power_status                   /sys/class/backlight/panel0-backlight/brightness; do
        [ -r "$_rsp" ] || continue
        _rspv="$(cat "$_rsp" 2>/dev/null)"
        case "$_rspv" in 0|"") ;; *) _rec_scr=1 ;; esac
        break
      done
      [ "$_rec_scr" -eq 1 ] && sleep 120 || sleep 180
    elif [ "$_reconcile_fast" -gt 0 ]; then
      sleep 45
      _reconcile_fast=$((_reconcile_fast - 1))
    else
      _scr_idle=0
      for _dpp in /sys/kernel/oplus_display/panel_power_status                   /sys/class/backlight/panel0-backlight/brightness; do
        [ -r "$_dpp" ] || continue
        _dppv="$(cat "$_dpp" 2>/dev/null)"
        case "$_dppv" in
          0|"") _scr_idle=1 ;;
        esac
        break
      done
      [ "$_scr_idle" -eq 1 ] && sleep 90 || sleep 45
    fi
    _now="$(cat "$MODDIR/current_profile" 2>/dev/null)"
    case "$_now" in
      battery|balanced|performance) : ;;
      *) _now="balanced" ;;
    esac
    asb_load_profile
    _need=0
    _reason=""
    if [ "$_now" != "$_last_profile" ]; then
      _need=1
      _reason="profile-change"
    else
      _cur_screen=0
      asb_screen_on && _cur_screen=1
      if [ "$_cur_screen" != "$_last_screen" ]; then
        _need=1
        _reason="screen-state"
        _last_screen="$_cur_screen"
      fi
      if [ $_need -eq 0 ] && asb_feature_enabled CPU; then
        if [ "$ASB_GOV_ENABLED" != "1" ] || ! asb_governor_running; then
          _cur_topw="$(cat /proc/sys/walt/sched_topapp_weight_pct 2>/dev/null)"
          [ -n "$_cur_topw" ] && [ "$_cur_topw" != "$WALT_TOPAPP_WEIGHT" ] && { _need=1; _reason="walt-topapp"; }
          _cur_edb="$(cat /proc/sys/walt/sched_ed_boost 2>/dev/null)"
          [ $_need -eq 0 ] && [ -n "$_cur_edb" ] && [ "$_cur_edb" != "$WALT_ED_BOOST" ] && { _need=1; _reason="walt-edboost"; }
          _cur_ravg="$(cat /proc/sys/walt/sched_ravg_window_nr_ticks 2>/dev/null)"
          [ $_need -eq 0 ] && [ -n "$_cur_ravg" ] && [ "$_cur_ravg" != "$RAVG_TICKS" ] && { _need=1; _reason="walt-ravg"; }
          _cur_ucl="$(cat /dev/cpuctl/top-app/cpu.uclamp.max 2>/dev/null | tr -d '\r')"
          case "$_cur_ucl" in max) _cur_ucl="100" ;; esac
          _want_ucl="${UCL_TOP_MAX:-85}"
          case "$_want_ucl" in max) _want_ucl="100" ;; esac
          [ $_need -eq 0 ] && [ -n "$_cur_ucl" ] && [ "$_cur_ucl" != "$_want_ucl" ] && { _need=1; _reason="uclamp"; }
        fi
      fi
      if [ $_need -eq 0 ] && asb_feature_enabled WIFI; then
        _ts_now="$(date +%s 2>/dev/null || echo 0)"
        _wifi_delta=$((_ts_now - _last_wifi_check))
        if [ "$_wifi_delta" -ge 300 ] 2>/dev/null; then
          _last_wifi_check="$_ts_now"
          _want_pm="$WIFI_PM_MODE"
          _cur_pm=""
          has iw && _cur_pm="$(iw dev wlan0 get power_save 2>/dev/null | awk -F': ' '/Power save/ {print tolower($2)}')"
          case "$_want_pm" in
            on)  [ -n "$_cur_pm" ] && [ "$_cur_pm" != "on"  ] && { _need=1; _reason="wifi-pm"; } ;;
            off) [ -n "$_cur_pm" ] && [ "$_cur_pm" != "off" ] && { _need=1; _reason="wifi-pm"; } ;;
          esac
        fi
      fi
    fi
    if [ $_need -eq 1 ]; then
      if [ "$_reason" = "profile-change" ] || [ "$_reason" = "screen-state" ]; then
        _drift_streak=0
      else
        _drift_streak=$((_drift_streak + 1))
      fi
      _reconcile_fast=3
      asb_update_desc
      asb_log "runtime reconcile reason=$_reason profile=$_now"
      if [ "$ASB_GOV_ENABLED" = "1" ] && asb_governor_running; then
        if [ "$_reason" = "profile-change" ]; then
          asb_governor_set_profile
          asb_feature_enabled VM   && apply_vm
          asb_feature_enabled NET  && apply_net
          asb_feature_enabled WIFI && apply_wlan0_txqlen
          asb_feature_enabled WIFI && apply_wifi_pm
          asb_feature_enabled VM   && apply_doze
        elif [ "$_reason" = "wifi-pm" ]; then
          asb_feature_enabled WIFI && apply_wifi_pm
          asb_feature_enabled WIFI && apply_wifi_dtim
        fi
      else
        if [ "$_reason" = "screen-state" ]; then
          asb_feature_enabled CPU && apply_screen_aware_caps
        else
          apply_runtime_profile_now
          [ "$_reason" = "profile-change" ] && sleep 2 && asb_load_profile && apply_runtime_profile_now
        fi
      fi
      asb_feature_enabled LOG && asb_check_perfhal_drift
      _last_profile="$_now"
      # V33: drift economy — if PowerHAL keeps overriding, back off
      if [ "$_drift_streak" -ge 3 ]; then
        asb_log "reconcile: drift_streak=$_drift_streak, economy sleep 120s"
        sleep 120
      fi
    fi
  done
