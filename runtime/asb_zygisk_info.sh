#!/system/bin/sh
# Read-only observer diagnostics. Requires _emit, _read, MODDIR, PROC and DATA from the collector.
# Missing state is not proof that Zygisk or an application facility is unsupported.

_asb_zygisk_info() {
  _zi_dir="${ASB_ZYGISK_DIR:-$DATA/asb/zygisk_observer}"
  _zi_run="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"
  _zi_policy="${ASB_ZYGISK_POLICY:-$MODDIR/zygisk/policy}"
  _zi_conf="$MODDIR/config/governor.conf"
  _zi_enabled="$(sed -n 's/^[[:space:]]*zygisk_enabled=//p' "$_zi_conf" 2>/dev/null | head -n 1 | tr -d ' \r')"
  _zi_mode="$(sed -n 's/^[[:space:]]*zygisk_mode=//p' "$_zi_conf" 2>/dev/null | head -n 1 | tr -d ' \r')"
  _zi_hints_enabled="$(sed -n 's/^[[:space:]]*zygisk_hints=//p' "$_zi_conf" 2>/dev/null | head -n 1 | tr -d ' \r')"
  case "$_zi_enabled" in 0|1) : ;; *) _zi_enabled=0 ;; esac
  case "$_zi_mode" in observer) : ;; *) _zi_mode=observer ;; esac
  case "$_zi_hints_enabled" in 0|1) : ;; *) _zi_hints_enabled=0 ;; esac
  _zi_launch_on="$(sed -n 's/^[[:space:]]*zygisk_launch=//p' "$_zi_conf" 2>/dev/null | head -n 1 | tr -d ' \r')"
  _zi_ledger_on="$(sed -n 's/^[[:space:]]*zygisk_ledger=//p' "$_zi_conf" 2>/dev/null | head -n 1 | tr -d ' \r')"
  case "$_zi_launch_on" in 0|1) : ;; *) _zi_launch_on=0 ;; esac
  case "$_zi_ledger_on" in 0|1) : ;; *) _zi_ledger_on=0 ;; esac
  _zi_policy_gen=0
  if [ -s "$_zi_policy" ]; then
    _zi_policy_gen="$(sed -n 's/^gen=//p' "$_zi_policy" 2>/dev/null | head -n 1)"
    case "$_zi_policy_gen" in ''|*[!0-9]*) _zi_policy_gen=0 ;; esac
  fi
  _zi_safe=off; [ -e "$_zi_dir/disable" ] && _zi_safe=on
  _zi_packages=0; _zi_package_list=''
  if [ -x "$MODDIR/runtime/asb_zygisk.sh" ] || [ -f "$MODDIR/runtime/asb_zygisk.sh" ]; then
    _zi_package_list="$(ASB_ZYGISK_MODDIR="$MODDIR" ASB_ZYGISK_DIR="$_zi_dir" sh "$MODDIR/runtime/asb_zygisk.sh" list 2>/dev/null | awk 'NF { a=a (a ? "," : "") $0 } END { print a }' 2>/dev/null)"
    _zi_packages="$(printf '%s\n' "$_zi_package_list" | awk 'BEGIN{n=0} {if(length($0))n=split($0,a,",")} END{print n}')"
  fi
  case "$_zi_packages" in ''|*[!0-9]*) _zi_packages=0 ;; esac

  _zi_events=0; _zi_dropped=0; _zi_rate=0; _zi_duplicate=0; _zi_invalid=0; _zi_capacity=0
  _zi_cpu=0; _zi_wake=0; _zi_loaded=0; _zi_memory=0; _zi_seen_pids=' '; _zi_state=0; _zi_updated=0
  _zi_hints=0; _zi_accepted=0; _zi_vetoed=0; _zi_unavailable=0; _zi_throttled=0
  _zi_spawn=0; _zi_l_events=0; _zi_l_ok=0; _zi_l_veto=0; _zi_l_none=0; _zi_l_thr=0
  _zi_ledger_n=0; _zi_absent=0; _zi_seen_gen=0; _zi_ledger_rows=''
  for _zi_file in "$_zi_run/state.arm64-v8a.tsv" "$_zi_run/state.armeabi-v7a.tsv"; do
    [ -r "$_zi_file" ] || continue
    _zi_state=1
    while IFS="$(printf '\t')" read -r _zi_type _zi_a _zi_b _zi_c _zi_d _zi_extra; do
      case "$_zi_type" in
        Z)
          case "$_zi_a" in
            events_total|events_dropped_total|events_dropped_rate_limit|events_dropped_duplicate|events_dropped_invalid|events_dropped_capacity|ipc_cpu_ms|ipc_wakeups|policy_hints|hints_accepted|hints_vetoed|hints_unavailable|hints_throttled|updated_monotonic_ms|spawn_events|launch_events|launch_accepted|launch_vetoed|launch_unavailable|launch_throttled|ledger_events|events_policy_absent|policy_generation_seen)
              case "$_zi_b" in ''|*[!0-9]*) continue ;; esac
              [ "${#_zi_b}" -le 18 ] || continue
              case "$_zi_a" in
                events_total) _zi_events=$((_zi_events + _zi_b)) ;;
                events_dropped_total) _zi_dropped=$((_zi_dropped + _zi_b)) ;;
                events_dropped_rate_limit) _zi_rate=$((_zi_rate + _zi_b)) ;;
                events_dropped_duplicate) _zi_duplicate=$((_zi_duplicate + _zi_b)) ;;
                events_dropped_invalid) _zi_invalid=$((_zi_invalid + _zi_b)) ;;
                events_dropped_capacity) _zi_capacity=$((_zi_capacity + _zi_b)) ;;
                ipc_cpu_ms) _zi_cpu=$((_zi_cpu + _zi_b)) ;;
                ipc_wakeups) _zi_wake=$((_zi_wake + _zi_b)) ;;
                policy_hints) _zi_hints=$((_zi_hints + _zi_b)) ;;
                hints_accepted) _zi_accepted=$((_zi_accepted + _zi_b)) ;;
                hints_vetoed) _zi_vetoed=$((_zi_vetoed + _zi_b)) ;;
                hints_unavailable) _zi_unavailable=$((_zi_unavailable + _zi_b)) ;;
                hints_throttled) _zi_throttled=$((_zi_throttled + _zi_b)) ;;
                updated_monotonic_ms) [ "$_zi_b" -gt "$_zi_updated" ] && _zi_updated="$_zi_b" ;;
                spawn_events) _zi_spawn=$((_zi_spawn + _zi_b)) ;;
                launch_events) _zi_l_events=$((_zi_l_events + _zi_b)) ;;
                launch_accepted) _zi_l_ok=$((_zi_l_ok + _zi_b)) ;;
                launch_vetoed) _zi_l_veto=$((_zi_l_veto + _zi_b)) ;;
                launch_unavailable) _zi_l_none=$((_zi_l_none + _zi_b)) ;;
                launch_throttled) _zi_l_thr=$((_zi_l_thr + _zi_b)) ;;
                ledger_events) _zi_ledger_n=$((_zi_ledger_n + _zi_b)) ;;
                events_policy_absent) _zi_absent=$((_zi_absent + _zi_b)) ;;
                policy_generation_seen) [ "$_zi_b" -gt "$_zi_seen_gen" ] && _zi_seen_gen="$_zi_b" ;;
              esac ;;
          esac ;;
        L)
          case "$_zi_a" in ''|*[!A-Za-z0-9_.]*|*..*) continue ;; esac
          case "$_zi_b:$_zi_c:$_zi_d" in *[!0-9:]*|:*|*::*) continue ;; esac
          [ "${#_zi_b}" -le 12 ] && [ "${#_zi_c}" -le 12 ] || continue
          _zi_ledger_rows="$_zi_ledger_rows$_zi_a $_zi_b $_zi_c
"
          ;;
        P)
          [ "$_zi_loaded" -lt 64 ] || continue
          case "$_zi_a:$_zi_b:$_zi_d" in *[!0-9:]*) continue ;; esac
          case "$_zi_c" in ''|*[!A-Za-z0-9_.]*|*:*|*..*) continue ;; esac
          case "$_zi_seen_pids" in *" $_zi_a "*) continue ;; esac
          _zi_actual_ticks="$(awk '{s=$0;sub(/^.*\) /,"",s);split(s,a," ");print a[20]}' "$PROC/$_zi_a/stat" 2>/dev/null || true)"
          [ -n "$_zi_actual_ticks" ] && [ "$_zi_actual_ticks" = "$_zi_b" ] || continue
          _zi_seen_pids="$_zi_seen_pids$_zi_a "
          _zi_loaded=$((_zi_loaded + 1))
          _zi_rss="$(sed -n 's/^VmRSS:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$PROC/$_zi_a/status" 2>/dev/null | head -n 1)"
          case "$_zi_rss" in ''|*[!0-9]*) _zi_rss="$_zi_d" ;; esac
          case "$_zi_rss" in ''|*[!0-9]*) _zi_rss=0 ;; esac
          _zi_memory=$((_zi_memory + _zi_rss))
          ;;
      esac
    done < "$_zi_file"
  done

  _zi_uptime_ms="$(awk '{printf "%.0f",$1*1000}' "$PROC/uptime" 2>/dev/null)"
  _zi_age='unknown'; _zi_freshness='no event state'
  case "$_zi_uptime_ms" in ''|*[!0-9]*) : ;; *)
    if [ "$_zi_updated" -gt 0 ]; then
      _zi_age=$((_zi_uptime_ms - _zi_updated)); [ "$_zi_age" -lt 0 ] && _zi_age=0
      if [ "$_zi_age" -le 300000 ] || [ "$_zi_loaded" -gt 0 ]; then _zi_freshness=current; else _zi_freshness=stale_over_5_minutes; fi
    fi ;;
  esac
  _zi_ledger_top='none'
  if [ -n "$_zi_ledger_rows" ]; then
    _zi_ledger_top="$(printf '%s' "$_zi_ledger_rows" | awk 'NF == 3 { off[$1] += $2; on[$1] += $3 }
      END { for (p in off) if (off[p] > 0) printf "%d %d %s\n", off[p], on[p], p }' | sort -rn | head -n 5 \
      | awk '{ s = s (s ? ", " : "") $3 " " $1 "/" $2 } END { print (s ? s : "none") }')"
  fi
  if [ "$_zi_enabled" = 0 ]; then _zi_broker='disabled for new processes'
  elif [ "$_zi_safe" = on ]; then _zi_broker='safe mode'
  elif [ "$_zi_packages" = 0 ] && [ "$_zi_launch_on" = 0 ] && [ "$_zi_ledger_on" = 0 ]; then _zi_broker='nothing selected: allowlist empty, cold-start lift and ledger off'
  elif [ "$_zi_state" = 1 ]; then _zi_broker='event state available'
  else _zi_broker='no events or companion not started'; fi

  # One machine-readable verdict for Actions, asbdiag, log capture and WebUI.
  # Configuration and staged ABI files are deliberately absent from the positive tests.
  _zi_link=unknown
  if [ "$_zi_enabled" = 0 ]; then _zi_link=off
  elif [ "$_zi_safe" = on ]; then _zi_link=safe
  elif [ "$_zi_freshness" = stale_over_5_minutes ]; then _zi_link=stale
  elif [ "$_zi_freshness" = current ] && [ "$_zi_loaded" -gt 0 ]; then _zi_link=connected
  elif [ "$_zi_freshness" = current ] && { [ "$_zi_events" -gt 0 ] || [ "$_zi_spawn" -gt 0 ] || [ "$_zi_seen_gen" -gt 0 ]; }; then _zi_link=confirmed
  elif [ "$_zi_packages" = 0 ] && [ "$_zi_launch_on" = 0 ] && [ "$_zi_ledger_on" = 0 ]; then _zi_link=idle
  elif [ "$_zi_freshness" = current ] || [ "$_zi_freshness" = 'no event state' ]; then _zi_link=waiting
  fi

  _zi_abis='not installed'
  if [ -f "$MODDIR/zygisk/arm64-v8a.so" ] || [ -f "$MODDIR/zygisk/armeabi-v7a.so" ]; then
    _zi_abis=''
    [ -f "$MODDIR/zygisk/arm64-v8a.so" ] && _zi_abis=arm64-v8a
    if [ -f "$MODDIR/zygisk/armeabi-v7a.so" ]; then _zi_abis="${_zi_abis:+$_zi_abis,}armeabi-v7a"; fi
  fi

  _emit zygisk_observer enabled "$_zi_enabled"
  _emit zygisk_observer mode observer
  _emit zygisk_observer lifecycle_hints "$_zi_hints_enabled"
  _emit zygisk_observer launch_hints "$_zi_launch_on"
  _emit zygisk_observer spawn_ledger "$_zi_ledger_on"
  _emit zygisk_observer policy_generation "$_zi_policy_gen"
  _emit zygisk_observer policy_seen_generation "$_zi_seen_gen"
  _emit zygisk_observer safe_mode "$_zi_safe"
  _emit zygisk_observer framework_status 'not runtime-discoverable from process events alone'
  _emit zygisk_observer installed_abis "$_zi_abis"
  _emit zygisk_observer enabled_packages "$_zi_packages"
  _emit zygisk_observer enabled_package_list "${_zi_package_list:-none}"
  _emit zygisk_observer loaded_processes "$_zi_loaded"
  _emit zygisk_observer broker_status "$_zi_broker"
  _emit zygisk_observer link_state "$_zi_link"
  _emit zygisk_observer state_freshness "$_zi_freshness"
  _emit zygisk_observer state_age_ms "$_zi_age"
  _emit zygisk_observer events_total "$_zi_events"
  _emit zygisk_observer events_dropped_total "$_zi_dropped"
  _emit zygisk_observer events_dropped_rate_limit "$_zi_rate"
  _emit zygisk_observer events_dropped_duplicate "$_zi_duplicate"
  _emit zygisk_observer events_dropped_invalid "$_zi_invalid"
  _emit zygisk_observer events_dropped_capacity "$_zi_capacity"
  _emit zygisk_observer ipc_cpu_ms "$_zi_cpu"
  _emit zygisk_observer ipc_wakeups "$_zi_wake"
  _emit zygisk_observer memory_kb "$_zi_memory"
  _emit zygisk_observer memory_basis 'sum of current VmRSS for validated live PIDs; includes app memory, not pure overhead'
  _emit zygisk_observer ipc_basis 'companion receive/validation/state-write/hint-round-trip CPU and IPC wakeups; not whole-app CPU'
  _emit zygisk_observer crash_count unknown
  _emit zygisk_observer anr_count unknown
  _emit zygisk_observer crash_anr_evidence 'not exposed; no attribution inferred'
  _emit zygisk_observer policy_hints "$_zi_hints"
  _emit zygisk_observer hints_accepted "$_zi_accepted"
  _emit zygisk_observer hints_vetoed "$_zi_vetoed"
  _emit zygisk_observer hints_unavailable "$_zi_unavailable"
  _emit zygisk_observer hints_throttled "$_zi_throttled"
  _emit zygisk_observer spawn_events "$_zi_spawn"
  _emit zygisk_observer launch_events "$_zi_l_events"
  _emit zygisk_observer launch_accepted "$_zi_l_ok"
  _emit zygisk_observer launch_vetoed "$_zi_l_veto"
  _emit zygisk_observer launch_unavailable "$_zi_l_none"
  _emit zygisk_observer launch_throttled "$_zi_l_thr"
  _emit zygisk_observer ledger_events "$_zi_ledger_n"
  _emit zygisk_observer ledger_top_screen_off "$_zi_ledger_top"
  _emit zygisk_observer hints_status 'accepted means governor acknowledged fresh-evidence evaluation; never proof of a cap change or energy saving'
  _emit zygisk_observer hint_bounds 'screen on; at least 2 s between requests; at most 8 per minute per companion; no package or cap sent'
  _emit zygisk_observer lifecycle_coverage 'process start and peer-disconnect exit only; neither proves foreground visibility'
  _emit zygisk_observer foreground_events 'not exposed without global hooks; is_top_app is not tracking'
  _emit zygisk_observer media_camera_audio_navigation 'not exposed in observer-only stage'
  _emit zygisk_observer overhead_confidence "$([ "$_zi_state" = 1 ] && echo 'measured event counters; snapshot only' || echo 'unknown: no event state')"
  _emit zygisk_observer data_minimization 'package name, PID/start ticks, process RSS and bounded counters; the ledger keeps package names and start counts for this boot in tmpfs only'
}
