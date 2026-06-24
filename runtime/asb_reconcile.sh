#!/system/bin/sh

  _last_profile=""
  _last_screen="-1"
  _reconcile_fast=3
  _last_wifi_check=0
  _drift_streak=0
  _last_eff_batt="-1"
  _lease_remaining=0
  _lease_delays="2 4 14 40"
  _lease_last_reassert_ts=0
  while true; do
    if [ "$_lease_remaining" -gt 0 ]; then
      _d=$(echo "$_lease_delays" | awk -v i="$_lease_remaining" '{print $(NF - i + 1)}')
      [ -z "$_d" ] || [ "$_d" = "0" ] && _d=2
      sleep "$_d"
      _lease_remaining=$((_lease_remaining - 1))
    elif [ "$ASB_GOV_ENABLED" = "1" ] && asb_governor_running; then
      _rec_scr=0
      for _rsp in /sys/kernel/oplus_display/panel_power_status                   /sys/class/backlight/panel0-backlight/brightness; do
        [ -r "$_rsp" ] || continue
        _rspv="$(cat "$_rsp" 2>/dev/null)"
        case "$_rspv" in 0|"") ;; *) _rec_scr=1 ;; esac
        break
      done
      [ "$_rec_scr" -eq 1 ] && sleep 120 || {
        _rec_prof="$(cat "$MODDIR/current_profile" 2>/dev/null)"
        if [ "$_rec_prof" = "battery" ]; then
          sleep 600
        else
          sleep 180
        fi
      }
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
      battery|balanced|performance|smart) : ;;
      *) _now="balanced" ;;
    esac
    if [ -f /dev/.asb/safe_mode ]; then
      _last_profile="$_now"
      continue
    fi
    if [ -f /dev/.asb/recovery.lock ]; then
      continue
    fi
    # Anti-thrash: if vendor is repeatedly clamping, the C governor sets
    # cap_vendor_holddown=1 in state. Back off here too so we stop fighting.
    _vhd=0
    if [ -r /dev/.asb/state ]; then
      _vhd="$(awk -F= '/^cap_vendor_holddown=/{print $2; exit}' /dev/.asb/state 2>/dev/null)"
      [ -z "$_vhd" ] && _vhd=0
    fi
    if [ "$_vhd" = "1" ]; then
      # vendor owns caps right now — don't apply profile to avoid thrash
      continue
    fi
    asb_load_profile
    _need=0
    _reason=""
    if [ "$_now" != "$_last_profile" ]; then
      _need=1
      _reason="profile-change"
      _lease_remaining=4
    else
      _cur_screen=0
      asb_screen_on && _cur_screen=1
      if [ "$_cur_screen" != "$_last_screen" ]; then
        _need=1
        _reason="screen-state"
        _last_screen="$_cur_screen"
        _lease_remaining=4
      fi
      if [ $_need -eq 0 ] && asb_feature_enabled CPU; then
        _cur_p0_max=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)
        _cur_p6_max=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null)
        _fsm_caps=$(grep "^cpu_max=" /dev/.asb/state 2>/dev/null | head -1 | cut -d= -f2)
        _want_p0_max=$(echo "$_fsm_caps" | cut -d, -f1)
        _want_p6_max=$(echo "$_fsm_caps" | cut -d, -f2)
        case "$_want_p0_max" in ''|*[!0-9]*) _want_p0_max="${CPU_CAP_LITTLE:-0}" ;; esac
        case "$_want_p6_max" in ''|*[!0-9]*) _want_p6_max="${CPU_CAP_BIG:-0}" ;; esac

        _drift_state="/dev/.asb/drift_rate"
        _now_ts=$(date +%s 2>/dev/null || echo 0)
        _window_start=0
        _p0_count=0
        _p6_count=0
        if [ -f "$_drift_state" ]; then
          _ds=$(cat "$_drift_state" 2>/dev/null)
          _window_start=$(echo "$_ds" | sed -n '1p')
          _p0_count=$(echo "$_ds" | sed -n '2p')
          _p6_count=$(echo "$_ds" | sed -n '3p')
          case "$_window_start" in ''|*[!0-9]*) _window_start=0 ;; esac
          case "$_p0_count" in ''|*[!0-9]*) _p0_count=0 ;; esac
          case "$_p6_count" in ''|*[!0-9]*) _p6_count=0 ;; esac
        fi
        if [ $((_now_ts - _window_start)) -ge 60 ]; then
          _window_start=$_now_ts
          _p0_count=0
          _p6_count=0
        fi

        case "$_now" in
          battery|balanced)
            # CAP-DRIFT CHECK DISABLED. Caps are now a percent of each cluster's
            # own max and are owned/re-applied by service.sh apply_screen_aware_caps
            # on every screen-state and profile change (idempotently). The old
            # check here compared policy0/policy6 against the absolute
            # CPU_CAP_LITTLE/BIG, which (a) no longer matches the live % cap so it
            # fired false "cap-drift" re-applies, and (b) only looked at a 2-cluster
            # layout, missing OP12's policy2/5/7. Screen-state transitions above
            # already retrigger a correct, topology-aware re-apply, so PowerHAL/
            # thermal clawback is corrected without this stale comparison.
            :
            ;;
        esac

        printf '%s\n%s\n%s\n' "$_window_start" "$_p0_count" "$_p6_count" > "$_drift_state" 2>/dev/null
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
      # Smart effective-battery transition: network_stats_poll follows whether the
      # current state is battery-equivalent. In the battery profile this is fixed
      # and handled by profile-change, but in Smart the alpha lean drifts without a
      # profile switch — so watch for it crossing the >=800 (battery-lean) boundary
      # and re-apply only on the transition, not every tick (avoids write churn).
      if [ $_need -eq 0 ] && [ "$_now" = "smart" ] && asb_feature_enabled VM && asb_feature_enabled LOG; then
        _cur_eff=0
        _ralpha="$(grep -m1 '^smart_alpha_battery=' /dev/.asb/state 2>/dev/null | sed 's/^smart_alpha_battery=//')"
        case "$_ralpha" in
          ''|*[!0-9]*) : ;;
          *) [ "$_ralpha" -ge 800 ] 2>/dev/null && _cur_eff=1 ;;
        esac
        if [ "$_cur_eff" != "$_last_eff_batt" ]; then
          _last_eff_batt="$_cur_eff"
          _need=1
          _reason="smart-eff-batt"
        fi
      fi
    fi
    if [ $_need -eq 1 ]; then
      case "$_reason" in
        walt-topapp|walt-edboost|walt-ravg|uclamp)
          _drift_streak=$((_drift_streak + 1)) ;;
        cap-drift-up-p0|cap-drift-up-p6)
          : ;;
        profile-change|screen-state)
          _drift_streak=0 ;;
        *)
          : ;; # wifi-pm etc don't affect drift streak
      esac
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
          asb_feature_enabled VM   && apply_network_stats_poll
        elif [ "$_reason" = "wifi-pm" ]; then
          asb_feature_enabled WIFI && apply_wifi_pm
          asb_feature_enabled WIFI && apply_wifi_dtim
        elif [ "$_reason" = "smart-eff-batt" ]; then
          asb_feature_enabled VM && apply_network_stats_poll
        elif [ "$_reason" = "cap-drift-up-p0" ] || [ "$_reason" = "cap-drift-up-p6" ]; then
          asb_feature_enabled CPU && apply_screen_aware_caps
        fi
      else
        if [ "$_reason" = "screen-state" ]; then
          asb_feature_enabled CPU && apply_screen_aware_caps
        elif [ "$_reason" = "cap-drift-up-p0" ] || [ "$_reason" = "cap-drift-up-p6" ]; then
          asb_feature_enabled CPU && apply_screen_aware_caps
        else
          apply_runtime_profile_now
          [ "$_reason" = "profile-change" ] && sleep 2 && asb_load_profile && apply_runtime_profile_now
        fi
      fi
      asb_feature_enabled LOG && asb_check_perfhal_drift
      _last_profile="$_now"
      if [ "$_drift_streak" -ge 3 ]; then
        asb_log "reconcile: drift_streak=$_drift_streak, economy sleep 120s"
        sleep 120
      fi
    fi
  done
