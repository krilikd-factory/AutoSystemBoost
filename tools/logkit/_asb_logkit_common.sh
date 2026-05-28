#!/system/bin/sh

MODID="${MODID:-AutoSystemBoost}"

lk_resolve_moddir() {
  for d in \
    "$MODDIR" \
    "/data/adb/modules/$MODID" \
    "/data/adb/modules_update/$MODID" \
    "/data/adb/ksu/modules/$MODID" \
    "/data/adb/ksu/modules_update/$MODID"; do
    [ -n "$d" ] || continue
    [ -f "$d/module.prop" ] && { echo "$d"; return 0; }
  done
  echo "/data/adb/modules/$MODID"
}

lk_resolve_gov_log() {
  for p in \
    "/dev/.asb/governor.log" \
    "$MODDIR/runtime/governor.log" \
    "$MODDIR/governor.log"; do
    [ -f "$p" ] && { echo "$p"; return 0; }
  done
  echo "/dev/.asb/governor.log"
}

lk_have() { command -v "$1" >/dev/null 2>&1; }

lk_get_prop() { getprop "$1" 2>/dev/null; }

lk_status_json() {
  if [ -x "$MODDIR/bin/asb" ]; then
    "$MODDIR/bin/asb" status 2>/dev/null | head -1
    return 0
  fi
  if lk_have asb; then
    asb status 2>/dev/null | head -1
    return 0
  fi
  if [ -f "$MODDIR/runtime/status.json" ]; then
    cat "$MODDIR/runtime/status.json" 2>/dev/null
    return 0
  fi
  echo "{}"
}

lk_probe_env() {
  {
    echo "===== ENVIRONMENT PROBE $(date -u '+%Y-%m-%dT%H:%M:%SZ') ====="
    echo ""
    echo "# device"
    echo "model:           $(lk_get_prop ro.product.model)"
    echo "device:          $(lk_get_prop ro.product.device)"
    echo "brand:           $(lk_get_prop ro.product.brand)"
    echo "manufacturer:    $(lk_get_prop ro.product.manufacturer)"
    echo "hardware:        $(lk_get_prop ro.hardware)"
    echo "platform:        $(lk_get_prop ro.board.platform)"
    echo "soc_model:       $(lk_get_prop ro.soc.model)"
    echo ""
    echo "# os"
    echo "android_release: $(lk_get_prop ro.build.version.release)"
    echo "android_sdk:     $(lk_get_prop ro.build.version.sdk)"
    echo "fingerprint:     $(lk_get_prop ro.build.fingerprint)"
    echo "oem_build:       $(lk_get_prop ro.build.display.id)"
    echo ""
    echo "# kernel"
    echo "kernel_release:  $(uname -r)"
    echo "kernel_version:  $(uname -v)"
    echo ""
    echo "# root+superuser"
    echo "ksu_present:     $(lk_have ksud && echo yes || echo no)"
    echo "magisk_present:  $(lk_have magisk && echo yes || echo no)"
    echo "selinux:         $(getenforce 2>/dev/null || echo unknown)"
    echo ""
    echo "# asb"
    echo "module_dir:      $MODDIR"
    if [ -f "$MODDIR/module.prop" ]; then
      sed 's/^/  /' "$MODDIR/module.prop"
    else
      echo "  module.prop: MISSING"
    fi
    echo ""
    echo "current_profile: $(cat "$MODDIR/current_profile" 2>/dev/null || echo '(unreadable)')"
    echo "asb_binary:      $(lk_have asb && which asb || echo missing)"
    echo "governor_pid:    $(pgrep -f asb_governor 2>/dev/null | tr '\n' ' ')"
    echo "governor_log:    $LK_GOV_LOG"
    echo ""
    echo "# battery"
    echo "capacity_pct:    $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)"
    echo "status:          $(cat /sys/class/power_supply/battery/status 2>/dev/null)"
    echo "temp_10x:        $(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
  } > "$LK_OUT_DIR/env.txt"
}

lk_dump_build_manifest() {
  if [ -f "$MODDIR/build_manifest.json" ]; then
    cp "$MODDIR/build_manifest.json" "$LK_OUT_DIR/build_manifest.json"
  else
    {
      echo "{"
      echo "  \"asb_version\":       \"$(awk -F= '/^version=/{print $2}' "$MODDIR/module.prop" 2>/dev/null)\","
      echo "  \"build_date\":        \"$(date -u '+%Y-%m-%d %H:%M:%S')\","
      echo "  \"schema_version\":    9,"
      echo "  \"manifest_source\":   \"logkit_synthesized\","
      echo "  \"hashes\": {}"
      echo "}"
    } > "$LK_OUT_DIR/build_manifest.json"
  fi
}

lk_discover_zones() {
  {
    echo "# thermal zone discovery $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for zd in /sys/class/thermal/thermal_zone*; do
      [ -d "$zd" ] || continue
      _id="${zd##*thermal_zone}"
      _t=$(cat "$zd/type" 2>/dev/null)
      _raw=$(cat "$zd/temp" 2>/dev/null)
      echo "zone${_id}|${_t}|raw=${_raw}"
    done
  } > "$LK_OUT_DIR/thermal_zones.txt"
  {
    _socd=$(grep '|socd|'            "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    _prime=$(grep '|cpu-1-1-0|'      "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    _perf=$(grep '|cpu-0-5-0|'       "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    _cpullc=$(grep '|cpullc-0-0|'    "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    _sfront=$(grep '|shell_front|'   "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    _sframe=$(grep '|shell_frame|'   "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    _sback=$(grep '|shell_back|'     "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    _stherm6=$(grep '|sys-therm-6|'  "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    _board=$(grep -E '\|(board_temp|board-temp|board)\|' "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    _bat=$(grep '|battery|'          "$LK_OUT_DIR/thermal_zones.txt" 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d 'zone')
    echo "TZ_SOCD=${_socd:-}"
    echo "TZ_CPU_PRIME=${_prime:-}"
    echo "TZ_CPU_PERF=${_perf:-}"
    echo "TZ_CPULLC=${_cpullc:-}"
    echo "TZ_SHELL_FRONT=${_sfront:-}"
    echo "TZ_SHELL_FRAME=${_sframe:-}"
    echo "TZ_SHELL_BACK=${_sback:-}"
    echo "TZ_SYSTHERM6=${_stherm6:-}"
    echo "TZ_BOARD=${_board:-}"
    echo "TZ_BATTERY=${_bat:-}"
  } > "$LK_OUT_DIR/thermal_zones_aliases.sh"
  . "$LK_OUT_DIR/thermal_zones_aliases.sh"
}

lk_snapshot_state() {
  _tag="$1"
  _target="$LK_OUT_DIR/${_tag}.txt"
  {
    echo "===== SNAPSHOT $_tag $(date) ====="
    echo ""
    echo "===== ASB STATUS ====="
    lk_status_json
    echo ""
    echo ""
    echo "===== ASB RUNTIME DIR ====="
    ls -la "$MODDIR/runtime" 2>/dev/null
    echo ""
    echo "===== CURRENT PROFILE ====="
    cat "$MODDIR/current_profile" 2>/dev/null
    echo ""
    echo "===== PSTATS ====="
    for f in "$MODDIR/runtime/pstats_"*.json; do
      [ -f "$f" ] || continue
      echo "--- $(basename "$f") ---"
      cat "$f"
      echo ""
    done
    echo "===== LAST 5 SESSIONS (session_history.jsonl tail) ====="
    tail -5 "$MODDIR/runtime/session_history.jsonl" 2>/dev/null
    echo ""
    echo "===== CPU SCALING MAX (all policies) ====="
    for pd in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$pd" ] || continue
      _p="${pd##*policy}"
      _rel=$(cat "$pd/related_cpus" 2>/dev/null)
      _smax=$(cat "$pd/scaling_max_freq" 2>/dev/null)
      _smin=$(cat "$pd/scaling_min_freq" 2>/dev/null)
      _cur=$(cat "$pd/scaling_cur_freq" 2>/dev/null)
      echo "policy${_p} cpus=[${_rel}] max=${_smax} min=${_smin} cur=${_cur}"
    done
    echo ""
    echo "===== GPU ====="
    echo "cur_pwrlevel: $(cat /sys/class/kgsl/kgsl-3d0/cur_pwrlevel 2>/dev/null)"
    echo "max_pwrlevel: $(cat /sys/class/kgsl/kgsl-3d0/max_pwrlevel 2>/dev/null)"
    echo "min_pwrlevel: $(cat /sys/class/kgsl/kgsl-3d0/min_pwrlevel 2>/dev/null)"
    echo "gpu_busy:     $(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null)"
    echo "gpuclk:       $(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null)"
    echo ""
    echo "===== BATTERY ====="
    cat /sys/class/power_supply/battery/uevent 2>/dev/null
    echo ""
    echo "===== THERMAL SERVICE DUMP ====="
    dumpsys thermalservice 2>/dev/null | head -200
    echo ""
    echo "===== BG_TRIM STATE ====="
    echo "--- standby buckets (curated apps) ---"
    for _pkg in com.android.systemui com.oneplus.launcher \
                com.whatsapp org.telegram.messenger com.discord \
                com.facebook.katana com.instagram.android com.zhiliaoapp.musically \
                com.netflix.mediaclient com.google.android.gms com.android.vending; do
      _b=$(am get-standby-bucket "$_pkg" 2>/dev/null)
      [ -n "$_b" ] && echo "  $_pkg : $_b"
    done
    echo ""
    echo "--- top-app (current foreground) ---"
    dumpsys activity activities 2>/dev/null | grep -E "topResumedActivity|ResumedActivity" | head -3
    echo ""
    echo "--- memcg v2 state ---"
    if [ -d /sys/fs/cgroup ]; then
      [ -r /sys/fs/cgroup/cgroup.controllers ] && echo "  controllers: $(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)"
      for _grp in /sys/fs/cgroup/uid_*/cgroup.procs; do
        [ -f "$_grp" ] || continue
        _d=$(dirname "$_grp")
        _ml=$(cat "$_d/memory.low" 2>/dev/null)
        _mh=$(cat "$_d/memory.high" 2>/dev/null)
        _mm=$(cat "$_d/memory.max" 2>/dev/null)
        [ "$_ml" = "0" ] && [ "$_mh" = "max" ] && [ "$_mm" = "max" ] && continue
        echo "  $(basename "$_d") : low=$_ml high=$_mh max=$_mm"
      done | head -20
    fi
    echo ""
    echo "--- doze constants (must be empty for stock Doze) ---"
    settings get global device_idle_constants 2>/dev/null
    echo ""
    echo "===== ASB OBSERVABILITY ENDPOINTS ====="
    echo "--- recovery.json ---"
    cat /dev/.asb/recovery.json 2>/dev/null || echo "  (absent — no recovery events)"
    echo ""
    echo "--- learner_state.json ---"
    cat /dev/.asb/learner_state.json 2>/dev/null || echo "  (absent)"
    echo ""
    echo "--- conflicts.json ---"
    cat /dev/.asb/conflicts.json 2>/dev/null || echo "  (absent)"
    echo ""
    echo "--- governor_persist.log tail (last 20, survives reboot) ---"
    tail -20 /data/adb/asb/governor_persist.log 2>/dev/null || echo "  (absent)"
    echo ""
    echo "===== AUDIO HAL STATE ====="
    echo "  vendor.soter init.svc: $(getprop init.svc.vendor.soter 2>/dev/null)"
    echo "  audio.hal.output.suspend.supported: $(getprop audio.hal.output.suspend.supported 2>/dev/null)"
    echo "  vendor.qc2audio.suspend.enabled: $(getprop vendor.qc2audio.suspend.enabled 2>/dev/null)"
    echo "  ro.audio.hifi: $(getprop ro.audio.hifi 2>/dev/null)"
    echo "  persist.audio.uhqa: $(getprop persist.audio.uhqa 2>/dev/null)"
    echo "  persist.vendor.audio.power.save.setting: $(getprop persist.vendor.audio.power.save.setting 2>/dev/null)"
    echo "  af.resampler.quality: $(getprop af.resampler.quality 2>/dev/null)"
    echo "  audio.offload.buffer.size.kb: $(getprop audio.offload.buffer.size.kb 2>/dev/null)"
    echo ""
    echo "===== UX SETTINGS (profile-aware) ====="
    echo "  animator_duration_scale: $(settings get global animator_duration_scale 2>/dev/null)"
    echo "  transition_animation_scale: $(settings get global transition_animation_scale 2>/dev/null)"
    echo "  window_animation_scale: $(settings get global window_animation_scale 2>/dev/null)"
    echo "  long_press_timeout: $(settings get secure long_press_timeout 2>/dev/null)"
    echo "  multi_press_timeout: $(settings get secure multi_press_timeout 2>/dev/null)"
    echo "  adaptive_battery_management_enabled: $(settings get global adaptive_battery_management_enabled 2>/dev/null)"
    echo "  ram_expand_size: $(settings get global ram_expand_size 2>/dev/null)"
    echo "  sem_low_heat_mode: $(settings get global sem_low_heat_mode 2>/dev/null)"
    echo "  google_core_control: $(settings get global google_core_control 2>/dev/null)"
    echo ""
    echo "===== NET STATE ====="
    echo "  tcp_congestion_control: $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
    echo "  default_qdisc: $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
    echo "  tcp_mtu_probing: $(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null)"
    echo "  udp_mem: $(cat /proc/sys/net/ipv4/udp_mem 2>/dev/null)"
    echo "  tcp_rmem: $(cat /proc/sys/net/ipv4/tcp_rmem 2>/dev/null)"
    echo "  tcp_wmem: $(cat /proc/sys/net/ipv4/tcp_wmem 2>/dev/null)"
    echo ""
    echo "===== WAKELOCKS (top 20 by active time) ====="
    if [ -r /sys/kernel/debug/wakeup_sources ]; then
      head -1 /sys/kernel/debug/wakeup_sources
      tail -n +2 /sys/kernel/debug/wakeup_sources | sort -k7 -n -r | head -20
    elif [ -r /d/wakeup_sources ]; then
      head -1 /d/wakeup_sources
      tail -n +2 /d/wakeup_sources | sort -k7 -n -r | head -20
    else
      echo "  (wakeup_sources not accessible)"
    fi
    echo ""
    echo "===== GOVERNOR LOG TAIL (last 50 lines) ====="
    tail -50 "$LK_GOV_LOG" 2>/dev/null
  } > "$_target" 2>&1
}

lk_copy_runtime_artifacts() {
  [ -f "$LK_GOV_LOG" ] && cp "$LK_GOV_LOG" "$LK_OUT_DIR/governor.log"
  for f in \
    "$MODDIR/runtime/session_history.jsonl" \
    "$MODDIR/runtime/last_sessions_v9.jsonl" \
    "$MODDIR/runtime/learn.bin" \
    "$MODDIR/runtime/session_stats.json" \
    "$MODDIR/runtime/pstats_performance.json" \
    "$MODDIR/runtime/pstats_balanced.json" \
    "$MODDIR/runtime/pstats_battery.json" \
    "/dev/.asb/runtime_apply.log" \
    "/dev/.asb/thermal_pl_audit" \
    "/dev/.asb/drift_rate" \
    "/dev/.asb/gpu_path_discovery" \
    "/dev/.asb/config_stale_detected" \
    "/dev/.asb/vendor_overrides" \
    "/dev/.asb/vendor_override_audit" \
    "/dev/.asb/thermal_events" \
    "/dev/.asb/recovery.json" \
    "/dev/.asb/learner_state.json" \
    "/dev/.asb/conflicts.json" \
    "/dev/.asb/recovery_history.log" \
    "/dev/.asb/state" \
    "/data/adb/asb/governor_persist.log" \
    "/data/adb/asb/governor_persist.log.1"; do
    [ -f "$f" ] || continue
    cp "$f" "$LK_OUT_DIR/" 2>/dev/null
  done
  echo "$LK_GOV_LOG" > "$LK_OUT_DIR/_govlog_source.txt"

  if [ -f "$MODDIR/tools/asb_field_report.py" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$MODDIR/tools/asb_field_report.py" \
      --input "$LK_OUT_DIR/session_history.jsonl" \
      --recovery "$LK_OUT_DIR/recovery.json" \
      --text-out "$LK_OUT_DIR/field_report.txt" \
      --quiet 2>/dev/null
  fi
}

lk_verify_caps() {
  . "$MODDIR/profiles/$(cat "$MODDIR/current_profile" 2>/dev/null || echo balanced).sh" 2>/dev/null
  _profile="$(cat "$MODDIR/current_profile" 2>/dev/null || echo balanced)"

  _j=$(lk_status_json)
  _asb_p0_cap=$(echo "$_j" | awk -F'"perf_cap_p0":' '{print $2}' | awk -F, '{print $1}')
  _asb_p6_cap=$(echo "$_j" | awk -F'"perf_cap_p6":' '{print $2}' | awk -F, '{print $1}')
  _gov_src_p0=$(echo "$_j" | awk -F'"cap_source_p0":"' '{print $2}' | awk -F'"' '{print $1}')
  _gov_src_p6=$(echo "$_j" | awk -F'"cap_source_p6":"' '{print $2}' | awk -F'"' '{print $1}')
  _asb_p0_cap="${_asb_p0_cap:-0}"
  _asb_p6_cap="${_asb_p6_cap:-0}"
  _gov_src_p0="${_gov_src_p0:-?}"
  _gov_src_p6="${_gov_src_p6:-?}"

  {
    echo "# cap_verify v3 at $(date -u '+%Y-%m-%dT%H:%M:%SZ')  profile=$_profile"
    echo "# profile_cpu_cap_big:     ${CPU_CAP_BIG:-(none)}"
    echo "# profile_cpu_cap_little:  ${CPU_CAP_LITTLE:-(none)}"
    echo "# asb_declared_p0:         ${_asb_p0_cap}"
    echo "# asb_declared_p6:         ${_asb_p6_cap}"
    echo "# governor_cap_source_p0:  ${_gov_src_p0}"
    echo "# governor_cap_source_p6:  ${_gov_src_p6}"
    for pd in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$pd" ] || continue
      _p="${pd##*policy}"
      _smax=$(cat "$pd/scaling_max_freq" 2>/dev/null)
      _cmax=$(cat "$pd/cpuinfo_max_freq" 2>/dev/null)
      _rel=$(cat "$pd/related_cpus" 2>/dev/null | awk '{print $1}')
      if [ "${_rel:-0}" -ge 6 ] 2>/dev/null; then
        _expect="$CPU_CAP_BIG"
        _label="BIG(prime)"
        _asb_declared="$_asb_p6_cap"
        _gov_src="$_gov_src_p6"
      elif [ "${_rel:-0}" -ge 2 ] 2>/dev/null; then
        _expect=""
        _label="PERF"
        _asb_declared=""
        _gov_src="-"
      else
        _expect="$CPU_CAP_LITTLE"
        _label="LITTLE"
        _asb_declared="$_asb_p0_cap"
        _gov_src="$_gov_src_p0"
      fi

      if [ -z "$_expect" ] || [ -z "$_smax" ]; then
        _status="unset"
        _source="-"
      elif [ -z "$_asb_declared" ] || [ "$_asb_declared" = "0" ]; then
        if [ "$_smax" = "$_expect" ]; then
          _status="ok (shell-applied)"
          _source="shell_applied"
        elif [ "$_smax" -gt "$_expect" ] 2>/dev/null; then
          _status="DESYNC_shell_overridden_up (profile=$_expect actual=$_smax over=+$((_smax - _expect)))"
          _source="shell_overridden_up"
        else
          _status="shell_overridden_down (profile=$_expect actual=$_smax under=$((_expect - _smax)))"
          _source="shell_overridden_down"
        fi
      elif [ "$_smax" = "$_expect" ] && [ "$_asb_declared" = "$_expect" ]; then
        _status="ok"
        _source="asb"
      else
        _diff=$((_smax - _expect))
        if [ "$_asb_declared" != "0" ] && [ "$_smax" = "$_asb_declared" ] && [ "$_asb_declared" != "$_expect" ]; then
          _status="DESYNC_asb_dynamic (profile=$_expect asb_declared=$_asb_declared actual=$_smax diff=$_diff)"
          _source="asb_dynamic"
        elif [ "$_smax" = "$_expect" ] && [ "$_asb_declared" != "$_expect" ]; then
          _status="DESYNC_thermal_overlay (profile=$_expect asb_declared=$_asb_declared actual=$_smax)"
          _source="thermal_overlay"
        elif [ "$_smax" -gt "$_asb_declared" ] 2>/dev/null; then
          _status="DESYNC_vendor_raised (asb_declared=$_asb_declared actual=$_smax over=+$((_smax - _asb_declared)))"
          _source="vendor_raised"
        elif [ "$_smax" -lt "$_asb_declared" ] 2>/dev/null \
             && [ -n "$_cmax" ] && [ "$_smax" -lt "$_cmax" ] 2>/dev/null; then
          _status="DESYNC_vendor_clamp (asb_declared=$_asb_declared actual=$_smax clamp_depth=$((_asb_declared - _smax)))"
          _source="vendor_clamp"
        else
          _status="DESYNC_mismatch (profile=$_expect asb_declared=${_asb_declared:-?} actual=$_smax)"
          _source="mismatch"
        fi
      fi
      echo "policy${_p} (${_label}) cpus[first]=${_rel} actual_max=${_smax} hw_ceiling=${_cmax:-?} profile_expected=${_expect:-unset} asb_declared=${_asb_declared:-?} shell_source=${_source} gov_source=${_gov_src} -> $_status"
    done
  } >> "$LK_OUT_DIR/cap_verify.txt"
}

lk_grep_governor_log_events() {
  [ -f "$LK_OUT_DIR/governor.log" ] || return 0

  _start_off="${LK_GOV_LOG_OFFSET:-0}"
  _total_bytes=$(wc -c < "$LK_OUT_DIR/governor.log" 2>/dev/null | tr -d ' ')
  _total_bytes="${_total_bytes:-0}"

  if [ "$_start_off" -gt 0 ] && [ "$_total_bytes" -gt "$_start_off" ]; then
    tail -c "+$((_start_off + 1))" "$LK_OUT_DIR/governor.log" > "$LK_OUT_DIR/governor.log.session"
    _slice_mode="byte-offset"
  else
    cp "$LK_OUT_DIR/governor.log" "$LK_OUT_DIR/governor.log.session"
    _slice_mode="full-log-fallback"
  fi
  echo "slice_mode=$_slice_mode start_offset=$_start_off total_bytes=$_total_bytes session_bytes=$((_total_bytes - _start_off))" \
    > "$LK_OUT_DIR/_slice_info.txt"

  grep -E "enter_sustained|exit_sustained|time_based_escape"      "$LK_OUT_DIR/governor.log.session" > "$LK_OUT_DIR/events_sustained.txt"     2>/dev/null
  grep -E "thermal_cpu_switch|thermal_cpu_choice|thermal_summary|runtime rebind" "$LK_OUT_DIR/governor.log.session" > "$LK_OUT_DIR/events_thermal_source.txt" 2>/dev/null
  grep -E "self_tune|mid_tune|auto_degrade"     "$LK_OUT_DIR/governor.log.session" > "$LK_OUT_DIR/events_tuning.txt"        2>/dev/null
  grep -E "pstats: battery trust=|bat_trust"    "$LK_OUT_DIR/governor.log.session" > "$LK_OUT_DIR/events_battery_trust.txt" 2>/dev/null
  grep -E "screen_aware_caps|apply_cpufreq_caps|reconcile" "$LK_OUT_DIR/governor.log.session" > "$LK_OUT_DIR/events_cap_apply.txt" 2>/dev/null
  grep -E "intent=|session_end|session_start"   "$LK_OUT_DIR/governor.log.session" > "$LK_OUT_DIR/events_session.txt"       2>/dev/null
  grep -E "headroom_valid=0|stuck_100|headroom_invalid" "$LK_OUT_DIR/governor.log.session" > "$LK_OUT_DIR/events_headroom.txt" 2>/dev/null
}

lk_emit_state_transitions() {
  _src="$LK_OUT_DIR/status_watch.txt"
  _dst="$LK_OUT_DIR/state_transitions.txt"
  [ -f "$_src" ] || return 0
  awk '
    /^===== / { ts=$0; next }
    /^\{/ {
      line=$0
      match(line, /"state":"[^"]*"/); st=substr(line, RSTART+9, RLENGTH-10)
      match(line, /"temp":[0-9-]+/); tp=substr(line, RSTART+7, RLENGTH-7)
      match(line, /"last_sustained_reason":"[^"]*"/); rs=substr(line, RSTART+24, RLENGTH-25)
      match(line, /"thermal_cpu_type":"[^"]*"/); ct=substr(line, RSTART+20, RLENGTH-21)
      match(line, /"headroom_valid":[0-9]+/); hv=substr(line, RSTART+17, RLENGTH-17)
      match(line, /"thermal_cpu_fallback_type":"[^"]*"/); fb=substr(line, RSTART+29, RLENGTH-30)
      if (st != prev_st) {
        printf "%s  %s->%s  temp=%s  reason=%s  cpu_src=%s  fb=%s  hr_valid=%s\n",
               ts, (prev_st==""?"START":prev_st), st, tp, rs, ct, (fb==""?"-":fb), (hv==""?"-":hv)
        prev_st = st
      }
    }
  ' "$_src" > "$_dst"
}

lk_emit_cap_source_summary() {
  _src="$LK_OUT_DIR/status_watch.txt"
  [ -f "$_src" ] || return 0
  awk '
    /"cap_source_p0":"[^"]*"/ {
      match($0, /"cap_source_p0":"[^"]*"/)
      s=substr($0, RSTART+18, RLENGTH-19)
      p0[s]++
      tot0++
    }
    /"cap_source_p6":"[^"]*"/ {
      match($0, /"cap_source_p6":"[^"]*"/)
      s=substr($0, RSTART+18, RLENGTH-19)
      p6[s]++
      tot6++
    }
    END {
      print "===== cap_source summary (tick counts from status_watch) ====="
      printf "policy0 (LITTLE)  total_ticks=%d\n", tot0
      for (k in p0) printf "  %-16s %6d  (%5.1f%%)\n", k, p0[k], tot0>0?100*p0[k]/tot0:0
      printf "policy6 (BIG)     total_ticks=%d\n", tot6
      for (k in p6) printf "  %-16s %6d  (%5.1f%%)\n", k, p6[k], tot6>0?100*p6[k]/tot6:0
    }
  ' "$_src" > "$LK_OUT_DIR/cap_source_summary.txt"
}

lk_emit_drift_summary() {
  local _src="$LK_OUT_DIR/runtime_apply.log"
  [ -f "$_src" ] || return 0
  {
    echo "# drift_summary v1"
    echo "# events_total=$(grep -c 'cap-drift-up' "$_src" 2>/dev/null || echo 0)"
    echo "# perf_hal_drift=$(grep -c 'PERF-HAL DRIFT' "$_src" 2>/dev/null || echo 0)"
    echo "# severe_abs=$(grep -c 'drift(abs): severe' "$_src" 2>/dev/null || echo 0)"
    echo "# severe_cap=$(grep -c 'drift(cap): severe' "$_src" 2>/dev/null || echo 0)"
    echo ""
    echo "# Top minutes by drift density (max 10):"
    grep "cap-drift-up" "$_src" 2>/dev/null \
      | awk -F'T' '{print $2}' | awk -F':' '{print $1":"$2}' \
      | sort | uniq -c | sort -rn | head -10
  } > "$LK_OUT_DIR/drift_summary.txt"
}

lk_finalize() {
  echo "" >&2
  echo "[$(date '+%H:%M:%S')] lk_finalize: closing capture, collecting artifacts..." >&2
  lk_snapshot_state "after"
  lk_verify_caps
  lk_copy_runtime_artifacts
  lk_grep_governor_log_events
  lk_emit_state_transitions
  lk_emit_cap_source_summary
  lk_emit_drift_summary
  {
    echo "===== FILE LIST ====="
    ls -la "$LK_OUT_DIR"
    echo ""
    echo "===== DISCOVERED ZONES ====="
    cat "$LK_OUT_DIR/thermal_zones_aliases.sh" 2>/dev/null
    echo ""
    echo "===== RUN INFO ====="
    echo "scenario: $LK_SCENARIO"
    echo "start:    $LK_START_ISO"
    echo "end:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "duration: $(( $(date +%s) - LK_START_EPOCH ))s (limit: ${LK_MAX_SEC}s)"
    echo "poll_interval_s: $LK_POLL_S"
    echo "snapshot_interval_s: $LK_SNAPSHOT_S"
    echo "ticks_captured: $LK_TICK_COUNT"
  } > "$LK_OUT_DIR/_index.txt"

  _zip_parent="${LK_ZIP_PARENT:-/sdcard}"
  mkdir -p "$_zip_parent" 2>/dev/null
  _zip_path="$_zip_parent/asb_${LK_SCENARIO}_$(date +%Y%m%d_%H%M).zip"
  if lk_have zip; then
    ( cd "$LK_OUT_DIR" && zip -rq "$_zip_path" . )
    echo "[$(date '+%H:%M:%S')] wrote: $_zip_path" >&2
  else
    echo "[$(date '+%H:%M:%S')] 'zip' not found — artifacts left in $LK_OUT_DIR" >&2
  fi
  echo "[$(date '+%H:%M:%S')] done. You can upload $_zip_path for analysis." >&2
}

lk_status_watch_header() {
  echo ""
  echo "===== $(date) ====="
}

lk_perf_trace_header() {
  cat <<'EOF' > "$LK_OUT_DIR/perf_trace.txt"
EOF
}

lk_battery_trace_header() {
  cat <<'EOF' > "$LK_OUT_DIR/battery_trace.txt"
EOF
}

lk_capture_perf_trace_row() {
  _e=$(date +%s)
  _d=$(date '+%Y-%m-%d %H:%M:%S')
  _f() { cat "$1" 2>/dev/null; }
  _tz() { _id="$1"; [ -z "$_id" ] && { echo ""; return; }; _r=$(cat "/sys/class/thermal/thermal_zone${_id}/temp" 2>/dev/null); [ -n "$_r" ] && echo $((_r / 1000)) || echo ""; }
  _socd=$(_tz "$TZ_SOCD")
  _prime=$(_tz "$TZ_CPU_PRIME")
  _perf=$(_tz "$TZ_CPU_PERF")
  _cpullc=$(_tz "$TZ_CPULLC")
  _sf=$(_tz "$TZ_SHELL_FRONT")
  _sfr=$(_tz "$TZ_SHELL_FRAME")
  _sb=$(_tz "$TZ_SHELL_BACK")
  _st6=$(_tz "$TZ_SYSTHERM6")
  _board=$(_tz "$TZ_BOARD")
  _btz=$(_tz "$TZ_BATTERY")
  _p0cur=$(_f /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq)
  _p0max=$(_f /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)
  _p6cur=$(_f /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq)
  _p6max=$(_f /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)
  _gb=$(_f /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage)
  _gclk=$(_f /sys/class/kgsl/kgsl-3d0/gpuclk)
  _gmax=$(_f /sys/class/kgsl/kgsl-3d0/max_gpuclk)
  _gmin=$(_f /sys/class/kgsl/kgsl-3d0/min_gpuclk)
  _ggov=$(_f /sys/class/kgsl/kgsl-3d0/devfreq/governor)
  _bc=$(_f /sys/class/power_supply/battery/current_now)
  _bv=$(_f /sys/class/power_supply/battery/voltage_now)
  read -r _l1 _l5 _l15 _rest < /proc/loadavg
  _j=$(lk_status_json)
  _temp=$(echo "$_j"    | awk -F'"temp":'                     '{print $2}' | awk -F, '{print $1}')
  _tv=$(echo "$_j"      | awk -F'"temp_valid":'               '{print $2}' | awk -F, '{print $1}')
  _ta=$(echo "$_j"      | awk -F'"temp_age_s":'               '{print $2}' | awk -F, '{print $1}')
  _tr=$(echo "$_j"      | awk -F'"temp_invalid_reason":"'     '{print $2}' | awk -F'"' '{print $1}')
  _ct=$(echo "$_j"      | awk -F'"thermal_cpu_type":"'        '{print $2}' | awk -F'"' '{print $1}')
  _cz=$(echo "$_j"      | awk -F'"thermal_cpu_zone":'         '{print $2}' | awk -F, '{print $1}')
  _sz=$(echo "$_j"      | awk -F'"thermal_skin_zone":'        '{print $2}' | awk -F, '{print $1}')
  _surfz=$(echo "$_j"   | awk -F'"thermal_surface_zone":'     '{print $2}' | awk -F, '{print $1}')
  _sk=$(echo "$_j"      | awk -F'"skin_temp":'                '{print $2}' | awk -F, '{print $1}')
  _surf=$(echo "$_j"    | awk -F'"surface_hotspot":'          '{print $2}' | awk -F, '{print $1}')
  _smax=$(echo "$_j"    | awk -F'"ses_max_temp":'             '{print $2}' | awk -F, '{print $1}')
  _ssurfmax=$(echo "$_j"| awk -F'"ses_max_surface_temp":'     '{print $2}' | awk -F, '{print $1}')
  _brd=$(echo "$_j"     | awk -F'"board_temp":'               '{print $2}' | awk -F, '{print $1}')
  _hv=$(echo "$_j"      | awk -F'"headroom_valid":'           '{print $2}' | awk -F, '{print $1}')
  _hir=$(echo "$_j"     | awk -F'"headroom_invalid_reason":"' '{print $2}' | awk -F'"' '{print $1}')
  _fb=$(echo "$_j"      | awk -F'"thermal_cpu_fallback_type":"' '{print $2}' | awk -F'"' '{print $1}')
  echo "${_e}|${_d}|${_socd}|${_prime}|${_perf}|${_cpullc}|${_sf}|${_sfr}|${_sb}|${_st6}|${_board}|${_btz}|${_p0cur}|${_p0max}|${_p6cur}|${_p6max}|${_gb}|${_gclk}|${_gmax}|${_gmin}|${_ggov}|${_bc}|${_bv}|${_l1}|${_l5}|${_l15}|${_temp}|${_tv}|${_ta}|${_tr}|${_ct}|${_cz}|${_sz}|${_surfz}|${_sk}|${_surf}|${_smax}|${_ssurfmax}|${_brd}|${_hv}|${_hir}|${_fb}" >> "$LK_OUT_DIR/perf_trace.txt"
}

lk_capture_battery_trace_row() {
  _e=$(date +%s)
  _d=$(date '+%Y-%m-%d %H:%M:%S')
  _bpct=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  _bma=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  _bv=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
  _btmp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  _wrx=$(cat /sys/class/net/wlan0/statistics/rx_bytes 2>/dev/null)
  _wtx=$(cat /sys/class/net/wlan0/statistics/tx_bytes 2>/dev/null)
  _rrx=$(cat /sys/class/net/rmnet_data0/statistics/rx_bytes 2>/dev/null)
  _rtx=$(cat /sys/class/net/rmnet_data0/statistics/tx_bytes 2>/dev/null)
  read -r _l1 _rest < /proc/loadavg
  _mfree=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  _swfree=$(awk '/^SwapFree:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  _zram_used=$(awk 'BEGIN{u=0} /^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t-f}' /proc/meminfo 2>/dev/null)
  _wakelocks=0
  if [ -r /sys/kernel/debug/wakeup_sources ]; then
    _wakelocks=$(awk 'NR>1 && $7>0 {n++} END{print n+0}' /sys/kernel/debug/wakeup_sources 2>/dev/null)
  fi
  _j=$(lk_status_json)
  _st=$(echo "$_j"    | awk -F'"state":"'                    '{print $2}' | awk -F'"' '{print $1}')
  _pr=$(echo "$_j"    | awk -F'"profile":"'                  '{print $2}' | awk -F'"' '{print $1}')
  _sc=$(echo "$_j"    | awk -F'"screen":'                    '{print $2}' | awk -F, '{print $1}')
  _temp=$(echo "$_j"  | awk -F'"temp":'                      '{print $2}' | awk -F, '{print $1}')
  _sk=$(echo "$_j"    | awk -F'"skin_temp":'                 '{print $2}' | awk -F, '{print $1}')
  _surf=$(echo "$_j"  | awk -F'"surface_hotspot":'           '{print $2}' | awk -F, '{print $1}')
  _brd=$(echo "$_j"   | awk -F'"board_temp":'                '{print $2}' | awk -F, '{print $1}')
  _iq=$(echo "$_j"    | awk -F'"idle_q":'                    '{print $2}' | awk -F, '{print $1}')
  _bd=$(echo "$_j"    | awk -F'"bat_deep_idle":'             '{print $2}' | awk -F, '{print $1}')
  _bl=$(echo "$_j"    | awk -F'"bat_light_idle":'            '{print $2}' | awk -F, '{print $1}')
  _bw=$(echo "$_j"    | awk -F'"bat_wake_cycles":'           '{print $2}' | awk -F, '{print $1}')
  _hp=$(echo "$_j"    | awk -F'"headroom_pct":'              '{print $2}' | awk -F, '{print $1}')
  _hv=$(echo "$_j"    | awk -F'"headroom_valid":'            '{print $2}' | awk -F, '{print $1}')
  _hir=$(echo "$_j"   | awk -F'"headroom_invalid_reason":"'  '{print $2}' | awk -F'"' '{print $1}')
  _ct=$(echo "$_j"    | awk -F'"thermal_cpu_type":"'         '{print $2}' | awk -F'"' '{print $1}')
  _fb=$(echo "$_j"    | awk -F'"thermal_cpu_fallback_type":"' '{print $2}' | awk -F'"' '{print $1}')
  _dw=$(echo "$_j"    | awk -F'"dwell_sec":'                 '{print $2}' | awk -F, '{print $1}')
  echo "${_e}|${_d}|${_st}|${_pr}|${_sc}|${_bpct}|${_bma}|${_bv}|${_btmp}|${_temp}|${_sk}|${_surf}|${_brd}|${_iq}|${_bd}|${_bl}||${_bw}|${_hp}|${_hv}|${_hir}|${_ct}|${_fb}|${_wrx}|${_wtx}|${_rrx}|${_rtx}|${_l1}|${_dw}|${_mfree}|${_swfree}|${_zram_used}|${_wakelocks}" >> "$LK_OUT_DIR/battery_trace.txt"
}

lk_check_profile_matches() {
  _expect="$1"
  _cur=$(cat "$MODDIR/current_profile" 2>/dev/null)
  if [ "$_cur" != "$_expect" ]; then
    echo "⚠️  Current profile is '$_cur', expected '$_expect'."
    echo "    Switch in WebUI or via 'sh $MODDIR/apply_profile.sh $_expect' then rerun."
    return 1
  fi
  return 0
}

lk_init() {
  MODDIR="$(lk_resolve_moddir)"
  LK_GOV_LOG="$(lk_resolve_gov_log)"
  mkdir -p "$LK_OUT_DIR" || { echo "Cannot create $LK_OUT_DIR"; exit 1; }
  LK_START_EPOCH=$(date +%s)
  LK_START_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  LK_TICK_COUNT=0

  if [ -f "$LK_GOV_LOG" ]; then
    LK_GOV_LOG_OFFSET=$(wc -c < "$LK_GOV_LOG" 2>/dev/null | tr -d ' ')
    LK_GOV_LOG_OFFSET="${LK_GOV_LOG_OFFSET:-0}"
  else
    LK_GOV_LOG_OFFSET=0
  fi
  echo "$LK_GOV_LOG_OFFSET" > "$LK_OUT_DIR/_govlog_start_offset.txt"

  echo "[$(date '+%H:%M:%S')] logkit init: moddir=$MODDIR scenario=$LK_SCENARIO out=$LK_OUT_DIR gov_offset=$LK_GOV_LOG_OFFSET"
  lk_probe_env
  lk_dump_build_manifest
  lk_discover_zones
  lk_snapshot_state "before"
}
