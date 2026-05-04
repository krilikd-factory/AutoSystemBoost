#!/system/bin/sh

  _last_profile=""
  _last_screen="-1"
  _reconcile_fast=3
  _last_wifi_check=0
  _drift_streak=0
  # V39: lease-based reassert after profile change / screen state change.
  # Observed V39 battery log showed scaling_max_freq drifted to 1228/1382 MHz
  # (profile wants 614/922 MHz) because reconcile slept 600s in battery mode.
  # Anything touching scaling_max_freq (vendor perf_boost on screen wake, user-space
  # thermal daemon, etc.) had 10 minutes to drift before reconcile noticed.
  # Fix: after profile change or screen toggle, open a short reassert window
  # sampling at t=2s, 6s, 20s, 60s before returning to the long idle sleep.
  # Keeps cap ownership but doesn't turn into a write-war with vendor HAL.
  _lease_remaining=0           # ticks left in current lease window
  _lease_delays="2 4 14 40"    # additive delays — sum ≈ 60s probation
  _lease_last_reassert_ts=0
  while true; do
    # Determine sleep duration this iteration.
    if [ "$_lease_remaining" -gt 0 ]; then
      # Inside lease window — use one of the staged delays.
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
          sleep 600  # 10min — quiet battery night, minimal reconcile
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
      battery|balanced|performance) : ;;
      *) _now="balanced" ;;
    esac
    asb_load_profile
    _need=0
    _reason=""
    if [ "$_now" != "$_last_profile" ]; then
      _need=1
      _reason="profile-change"
      # V39: open lease window — poll rapidly for 60s to re-assert caps
      # against anything that tries to drift them.
      _lease_remaining=4
    else
      _cur_screen=0
      asb_screen_on && _cur_screen=1
      if [ "$_cur_screen" != "$_last_screen" ]; then
        _need=1
        _reason="screen-state"
        _last_screen="$_cur_screen"
        # V39: screen transitions are when vendor perf_boost most often
        # raises scaling_max_freq. Open lease window to catch the drift.
        _lease_remaining=4
      fi
      # V39: direction-aware cap drift check — only fight vendor if it
      # is raising us ABOVE profile. If actual is below profile, that's
      # legitimate vendor thermal cooldown, let it be.
      if [ $_need -eq 0 ] && asb_feature_enabled CPU; then
        _cur_p0_max=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)
        _cur_p6_max=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null)
        _want_p0_max="${CPU_CAP_LITTLE:-0}"
        _want_p6_max="${CPU_CAP_BIG:-0}"
        # Only battery/balanced enforce this strict direction check —
        # performance is intentionally permissive to let vendor boost.
        case "$_now" in
          battery|balanced)
            if [ -n "$_cur_p0_max" ] && [ "$_want_p0_max" -gt 0 ] 2>/dev/null \
               && [ "$_cur_p0_max" -gt "$_want_p0_max" ] 2>/dev/null; then
              _diff_p0=$((_cur_p0_max - _want_p0_max))
              # Allow 50MHz tolerance (vendor freq table alignment)
              if [ "$_diff_p0" -gt 50000 ]; then
                _need=1; _reason="cap-drift-up-p0"
                _lease_remaining=4
              fi
            fi
            if [ $_need -eq 0 ] && [ -n "$_cur_p6_max" ] && [ "$_want_p6_max" -gt 0 ] 2>/dev/null \
               && [ "$_cur_p6_max" -gt "$_want_p6_max" ] 2>/dev/null; then
              _diff_p6=$((_cur_p6_max - _want_p6_max))
              if [ "$_diff_p6" -gt 50000 ]; then
                _need=1; _reason="cap-drift-up-p6"
                _lease_remaining=4
              fi
            fi
            ;;
        esac
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
      case "$_reason" in
        walt-topapp|walt-edboost|walt-ravg|uclamp)
          _drift_streak=$((_drift_streak + 1)) ;;
        cap-drift-up-p0|cap-drift-up-p6)
          # V39: cap drift isn't a slow WALT drift — it's vendor writing
          # above profile. Don't count toward drift_streak economy sleep
          # (which would back off at exactly the wrong time).
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
        elif [ "$_reason" = "wifi-pm" ]; then
          asb_feature_enabled WIFI && apply_wifi_pm
          asb_feature_enabled WIFI && apply_wifi_dtim
        elif [ "$_reason" = "cap-drift-up-p0" ] || [ "$_reason" = "cap-drift-up-p6" ]; then
          # V39: vendor raised caps above profile. Reassert via shell
          # even when governor is active, because battery profile doesn't
          # use msm_performance (allow_hr=0) so governor alone can't fix this.
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
