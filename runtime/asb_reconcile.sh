#!/system/bin/sh

  # This file is sourced by service.sh. Stock is an explicit no-intervention profile, so
  # return from the sourced helper instead of keeping a reconcile loop for a stopped governor.
  if [ "$(cat "${MODDIR:-/data/adb/modules/AutoSystemBoost}/current_profile" 2>/dev/null)" = "stock" ]; then
    return 0 2>/dev/null || exit 0
  fi

  _last_profile=""
  _last_screen="-1"
  _reconcile_fast=3
  _last_wifi_check=0
  _drift_streak=0
  _last_eff_batt="-1"
  _lease_remaining=0
  _lease_delays="2 4 14 40"
  _lease_last_reassert_ts=0
  # --once mirrors asb_watchdog.sh: the governor schedules this now, so the resident
  # loop is only needed when the governor is absent.
  ASB_REC_ONCE=0
  case "$1" in --once) ASB_REC_ONCE=1 ;; esac
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
      [ "$ASB_REC_ONCE" = "1" ] && break
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
        # Prime cluster by measurement, not by number: pineapple numbers its clusters
        # 0/2/5/7, so policy6 is absent there and this read returned nothing at all.
        _pd=""; _ph=0
        for _d in /sys/devices/system/cpu/cpufreq/policy*; do
          [ -r "$_d/cpuinfo_max_freq" ] || continue
          _h=$(cat "$_d/cpuinfo_max_freq" 2>/dev/null)
          case "$_h" in ''|*[!0-9]*) continue ;; esac
          [ "$_h" -gt "$_ph" ] && { _ph="$_h"; _pd="$_d"; }
        done
        [ -n "$_pd" ] || _pd=/sys/devices/system/cpu/cpufreq/policy6
        _cur_p6_max=$(cat "$_pd/scaling_max_freq" 2>/dev/null)
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
          [ $_need -eq 0 ] && [ -n "$_cur_ucl" ] && [ "$_cur_ucl" != "$_want_ucl" ] && { _need=1; _reason="uclamp"; _drift_saw="$_cur_ucl"; _drift_want="$_want_ucl"; }
          # foreground as well, not just top-app.
          #
          # Only top-app was checked, so a foreground ceiling put back to "max" by the ROM
          # was never noticed and never restored. A capture on a OnePlus 12 found it sitting
          # at max for 43% of the day - with the camera guard off, so this was not ASB's own
          # doing - during which the profile's foreground limit meant nothing. That covers
          # music playback, navigation and anything else that keeps working off-screen,
          # which is exactly where the cap was supposed to earn its keep.
          _cur_ucl_fg="$(cat /dev/cpuctl/foreground/cpu.uclamp.max 2>/dev/null | tr -d '\r')"
          case "$_cur_ucl_fg" in max) _cur_ucl_fg="100" ;; esac
          _want_ucl_fg="${UCL_FG_MAX:-70}"
          case "$_want_ucl_fg" in max) _want_ucl_fg="100" ;; esac
          [ $_need -eq 0 ] && [ -n "$_cur_ucl_fg" ] && [ "$_cur_ucl_fg" != "$_want_ucl_fg" ] \
            && { _need=1; _reason="uclamp-fg"; _drift_saw="$_cur_ucl_fg"; _drift_want="$_want_ucl_fg"; }
          # And background, which is the cheapest ceiling to lose track of and the most
          # expensive to have lifted: it sits at 35% precisely so work nobody is looking at
          # does not run at full speed. The profile writes all four tiers; only two were
          # being watched, so two could drift back with nothing noticing.
          _cur_ucl_bg="$(cat /dev/cpuctl/background/cpu.uclamp.max 2>/dev/null | tr -d '\r')"
          case "$_cur_ucl_bg" in max) _cur_ucl_bg="100" ;; esac
          _want_ucl_bg="${UCL_BG_MAX:-35}"
          case "$_want_ucl_bg" in max) _want_ucl_bg="100" ;; esac
          [ $_need -eq 0 ] && [ -n "$_cur_ucl_bg" ] && [ "$_cur_ucl_bg" != "$_want_ucl_bg" ] \
            && { _need=1; _reason="uclamp-bg"; _drift_saw="$_cur_ucl_bg"; _drift_want="$_want_ucl_bg"; }
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
      if [ $_need -eq 0 ] && [ "$_now" = "smart" ] && asb_feature_enabled VM && asb_feature_enabled LOG; then
        _cur_eff=0
        _ralpha="$(grep -m1 '^smart_alpha_battery=' /dev/.asb/state 2>/dev/null | sed 's/^smart_alpha_battery=//')"
        case "$_ralpha" in
          ''|*[!0-9]*) : ;;
          *) if [ "$_ralpha" -ge 800 ] 2>/dev/null && ! asb_screen_on; then _cur_eff=1; fi ;;
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
        walt-topapp|walt-edboost|walt-ravg|uclamp|uclamp-fg|uclamp-bg)
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

      # Record the drift with its numbers, not just its name.
      #
      # asb_log keeps a rolling text line, which is enough to know something happened and
      # useless for knowing what. A capture from a real device showed top-app uclamp.max
      # sitting at 0.00 in two diagnostics and 85.00 in six others - the scheduler had been
      # forbidden from asking for performance for the app on screen, which is as expensive
      # as it sounds. Finding that took comparing ten files by hand, because nothing had
      # written down the observed value at the moment it was wrong.
      #
      # The apply ledger already carries exactly this shape for every other writer:
      # requested, observed, result. A drift the module corrected is still a drift, and the
      # next capture should show how often and when instead of requiring an archaeologist.
      case "$_reason" in
        uclamp|uclamp-fg|uclamp-bg)
          if [ -f "$MODDIR/runtime/asb_apply_ledger.sh" ]; then
            # shellcheck source=/dev/null
            . "$MODDIR/runtime/asb_apply_ledger.sh" 2>/dev/null || true
            command -v asb_ledger_note >/dev/null 2>&1 && \
              asb_ledger_note reconcile "$_reason" "${_drift_want:-}" "${_drift_saw:-}" \
                              "${_drift_saw:-}" readback_mismatch \
                              "drift found by reconcile, restoring" ""
          fi ;;
      esac
      _drift_saw=""; _drift_want=""
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
          if asb_feature_enabled NET; then
            if [ "$_last_eff_batt" = "1" ] && [ -r "$MODDIR/profiles/battery.sh" ]; then
              ( . "$MODDIR/profiles/battery.sh"; asb_map_profile_vars; apply_net )
            else
              apply_net
            fi
          fi
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
        [ "$ASB_REC_ONCE" = "1" ] || sleep 120
      fi
    fi
  done
