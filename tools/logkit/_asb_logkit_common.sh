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

# Pick a base dir the USER can actually reach, like asb_diag lands on /sdcard.
lk_resolve_outbase() {
  for _b in /sdcard /storage/emulated/0 /data/local/tmp; do
    [ -d "$_b" ] || continue
    if mkdir -p "$_b/.asb_lk_wtest" 2>/dev/null; then
      rmdir "$_b/.asb_lk_wtest" 2>/dev/null
      echo "$_b"; return 0
    fi
  done
  echo "/data/local/tmp"
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
    _gpid=$(cat /dev/.asb/governor.pid 2>/dev/null)
    [ -z "$_gpid" ] && _gpid=$(pgrep -f "bin/asb" 2>/dev/null | tr '\n' ' ')
    echo "governor_pid:    $_gpid"
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
    echo "--- state (key=value) ---"
    cat /dev/.asb/state 2>/dev/null || echo "  (absent)"
    echo ""
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
    elif command -v dumpsys >/dev/null 2>&1; then
      echo "  (debugfs unavailable, using dumpsys power)"
      dumpsys power 2>/dev/null | sed -n '/^  Wake Locks:/,/^  Suspend Blockers:/p' | head -30
      echo "  ----"
      dumpsys power 2>/dev/null | sed -n '/^  Suspend Blockers:/,/^[A-Z]/p' | head -25
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
  _profile="$(cat "$MODDIR/current_profile" 2>/dev/null || echo balanced)"
  #  Smart Mode: 'smart' profile doesn't have a smart.sh file by design —
  _src_profile="$_profile"
  [ "$_src_profile" = "smart" ] && _src_profile="balanced"
  # Initialize cap variables to avoid 'set -u' issues if source fails
  CPU_CAP_BIG="${CPU_CAP_BIG:-(unset)}"
  CPU_CAP_LITTLE="${CPU_CAP_LITTLE:-(unset)}"
  . "$MODDIR/profiles/${_src_profile}.sh" 2>/dev/null || true

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
    if [ "$_profile" = "smart" ]; then
      echo "# NOTE: profile_cpu_cap_* below is the STATIC profile baseline."
      echo "# On smart, asb_declared_* is synthesized dynamically from alpha/state"
      echo "# and is EXPECTED to differ from the static baseline. Compare observed"
      echo "# policy caps against asb_declared_*, not against profile_cpu_cap_*."
    fi
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
  _gb="$LK_GPU_NOW"
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

# WAKELOCK / WAKE-SOURCE collection

# One full snapshot of kernel wakeup_sources, written as a timestamped block.
lk_wakelock_kernel_snapshot() {
  _tag="${1:-snap}"
  _src=/sys/kernel/debug/wakeup_sources
  [ -r "$_src" ] || { _src=/d/wakeup_sources; [ -r "$_src" ] || return 0; }
  {
    echo "===== wakeup_sources ${_tag} $(date '+%Y-%m-%d %H:%M:%S') ====="
    # header + rows where the source has been active at least once, sorted by
    # the time it actively prevented suspend (most disruptive first).
    awk -v self="$LK_WAKELOCK_NAME" '
      NR==1 { next }
      {
        name=$1;
        if (name==self) next;             # skip our own capture wakelock
        ac=$2+0; as=$6+0; tt=$7+0; pst=$10+0;
        if (ac>0 || as>0 || pst>0)
          printf "%-28s active=%-6d active_since_ms=%-10d total_ms=%-10d prevent_suspend_ms=%-10d\n", name, ac, as, tt, pst
      }
    ' "$_src" 2>/dev/null | sort -t= -k5 -rn | head -40
    echo ""
  } >> "$LK_OUT_DIR/wake_sources.txt"
}

# Delta of the top kernel wakeup sources between two snapshots, so we can see
lk_wakelock_kernel_baseline() {
  _src=/sys/kernel/debug/wakeup_sources
  [ -r "$_src" ] || { _src=/d/wakeup_sources; [ -r "$_src" ] || return 0; }
  awk 'NR>1{print $1"|"$7"|"$10}' "$_src" 2>/dev/null > "$LK_OUT_DIR/.wl_kernel_base"
}
lk_wakelock_kernel_delta() {
  _src=/sys/kernel/debug/wakeup_sources
  [ -r "$_src" ] || { _src=/d/wakeup_sources; [ -r "$_src" ] || return 0; }
  [ -r "$LK_OUT_DIR/.wl_kernel_base" ] || return 0
  awk 'NR>1{print $1"|"$7"|"$10}' "$_src" 2>/dev/null > "$LK_OUT_DIR/.wl_kernel_end"
  {
    echo "===== wakeup_sources DELTA over capture (active time gained) ====="
    echo "# source | d_total_ms | d_prevent_suspend_ms"
    awk -F'|' -v self="$LK_WAKELOCK_NAME" '
      FNR==NR { bt[$1]=$2; bp[$1]=$3; next }
      {
        if ($1==self) next;
        dt=$2-(bt[$1]+0); dp=$3-(bp[$1]+0);
        if (dt>0 || dp>0) printf "%-28s %-12d %-12d\n", $1, dt, dp
      }
    ' "$LK_OUT_DIR/.wl_kernel_base" "$LK_OUT_DIR/.wl_kernel_end" \
      | sort -k3 -rn | head -30
    echo ""
  } >> "$LK_OUT_DIR/wake_sources.txt"
  rm -f "$LK_OUT_DIR/.wl_kernel_base" "$LK_OUT_DIR/.wl_kernel_end" 2>/dev/null
}

# Android-side wakelock + alarm attribution via batterystats/dumpsys. This is
# the per-APP view (the kernel sources above are per-driver) and — crucially —
# it works with NO debugfs access, which is the common case on OP15 where
# /sys/kernel/debug/wakeup_sources isn't readable. Call _reset at the start and
# _dump at the end so the window is just the capture.
lk_wakelock_batterystats_reset() {
  lk_have dumpsys || return 0
  dumpsys batterystats --reset >/dev/null 2>&1 || true
  # record when the window opened so the report can show elapsed
  date +%s > "$LK_OUT_DIR/.bstats_reset_epoch" 2>/dev/null || true
}

# Capture the raw batterystats once to a file, then parse several distinct
# sections out of that single snapshot (cheaper than calling dumpsys repeatedly
# and keeps all views time-consistent).
lk_wakelock_batterystats_dump() {
  lk_have dumpsys || return 0
  _raw="$LK_OUT_DIR/.bstats_raw.txt"
  dumpsys batterystats 2>/dev/null > "$_raw" || return 0
  _self="$LK_WAKELOCK_NAME"
  {
    echo "===== batterystats wakelock/alarm attribution $(date '+%Y-%m-%d %H:%M:%S') ====="
    if [ -r "$LK_OUT_DIR/.bstats_reset_epoch" ]; then
      _re=$(cat "$LK_OUT_DIR/.bstats_reset_epoch" 2>/dev/null)
      _now=$(date +%s)
      echo "# window: $(( (_now - _re) / 60 )) min since reset"
    fi
    echo ""

    # 1) Partial wakelocks held by apps (the "Wake lock <name> realtime" lines).
    #    These carry the total time each app held a partial wakelock during the
    #    window — the single best signal for "what kept the CPU awake".
    echo "# --- partial wakelocks (app-held, by realtime) ---"
    grep -iE "Wake lock|Wakelock" "$_raw" 2>/dev/null \
      | grep -ivE "$_self" \
      | sed 's/^[[:space:]]*//' \
      | grep -iE "realtime|[0-9]+m[0-9]+s|[0-9]+s [0-9]" \
      | head -30
    echo ""

    # 2) Alarms / scheduled wakeups (the *walarm* and "wakeup" lines). High
    #    wakeup counts = an app polling on a timer; a frequent offender for
    #    standby drain.
    echo "# --- alarm wakeups (by count) ---"
    grep -iE "\*walarm\*|Alarm [0-9]|wakeups|: [0-9]+ wakeup" "$_raw" 2>/dev/null \
      | sed 's/^[[:space:]]*//' \
      | head -25
    echo ""

    # 3) Top "Estimated power use" by UID if present (newer OOS includes a
    #    computed mAh breakdown — directly names the heaviest apps).
    echo "# --- estimated power use (mAh, if reported) ---"
    awk '/Estimated power use/{f=1} f{print} /^$/{if(f)c++; if(c>=2)f=0}' "$_raw" 2>/dev/null \
      | grep -iE "uid|mah|screen|cpu|wifi|cell|gps|[0-9]+\.[0-9]+" \
      | grep -iv "$_self" \
      | head -25
    echo ""

    # 4) Job scheduler activity (background jobs that wake the device).
    echo "# --- top jobs (by count/time) ---"
    grep -iE "Job [0-9]|JobScheduler|: [0-9]+ jobs" "$_raw" 2>/dev/null \
      | sed 's/^[[:space:]]*//' \
      | head -15
    echo ""
  } >> "$LK_OUT_DIR/wake_sources.txt"

  # Build a compact, ranked ACTIONABLE report from the same snapshot so the user
  # (and we) don't have to wade through the raw dump.
  lk_wakelock_emit_report "$_raw"
  rm -f "$_raw" 2>/dev/null || true
}

# Parse the raw batterystats into a ranked offenders report. Pure text parsing,
# no jq/python dependency. The goal: name the top wakelock holders and alarm
# sources with numbers, so an ASB prop/standby change can target a real culprit.
lk_wakelock_emit_report() {
  _raw="$1"
  [ -r "$_raw" ] || return 0
  _self="$LK_WAKELOCK_NAME"
  _out="$LK_OUT_DIR/_wakelock_report.txt"
  {
    echo "==================================================================="
    echo " WAKELOCK / WAKEUP REPORT (Android batterystats) — $(date '+%F %T')"
    echo "==================================================================="
    echo ""
    echo "Source: dumpsys batterystats (works without kernel debugfs)."
    echo "This names the apps/components that kept the device awake during the"
    echo "capture window, so ASB standby tuning can target a real offender."
    echo ""

    echo "----- TOP PARTIAL WAKELOCK HOLDERS -----"
    echo "(app/component held a partial wakelock = CPU couldn't fully sleep)"
    # OxygenOS batterystats lists these two ways depending on section/build:
    #   (a) "Wake lock <owner> <name>: <dur> realtime"  (dur present)
    #   (b) "Wake lock <owner/name> realtime"           (no dur on this build)
    # and the history stream uses "+wake_lock=<uid>:\"<name>\"". We rank by
    # whichever signal exists: duration if present, else how many times the
    # wakelock appears (a proxy for how often it was taken). Either way the
    # capture's own wakelock is excluded.
    {
      # form (a): lines with an explicit duration before "realtime"
      grep -iE "Wake lock" "$_raw" 2>/dev/null \
        | grep -ivE "$_self" \
        | awk '
          {
            line=$0;
            if (match(line,/[0-9]+h[0-9]+m[0-9]+s/)||match(line,/[0-9]+m[0-9]+s/)||match(line,/[0-9]+s[0-9]+ms/)) {
              t=substr(line,RSTART,RLENGTH); tmp=t; h=0;m=0;s=0;
              if(match(tmp,/[0-9]+h/))h=substr(tmp,RSTART,RLENGTH-1)+0;
              if(match(tmp,/[0-9]+m/))m=substr(tmp,RSTART,RLENGTH-1)+0;
              if(match(tmp,/[0-9]+s/))s=substr(tmp,RSTART,RLENGTH-1)+0;
              secs=h*3600+m*60+s;
              # owner = strip leading "Wake lock " and trailing ": ... realtime"
              o=line; sub(/^.*Wake lock[[:space:]]*/,"",o); sub(/:.*$/,"",o);
              if(secs>0) printf "DUR|%08d|%s\n", secs, o;
            }
          }'
      # form (b)+history: count occurrences by wakelock name when no duration
      { grep -oiE "Wake lock [^:]+ realtime" "$_raw" 2>/dev/null | sed 's/^Wake lock //;s/ realtime$//';
        grep -oE '\+wake_lock=[0-9a-z]+:"[^"]+"' "$_raw" 2>/dev/null | sed 's/.*"//;s/"$//'; } \
        | grep -ivE "$_self" \
        | sed 's/^[[:space:]]*//' | grep -vE '^$' \
        | sort | uniq -c | sort -rn \
        | awk '$1>0 {n=$1; $1=""; sub(/^ /,""); printf "CNT|%08d|%s\n", n, $0}'
    } | sort -t'|' -k1,1 -k2,2rn | awk -F'|' '
        $1=="DUR" {printf "  %6ds held  %s\n", $2+0, $3; d++; next}
        $1=="CNT" && d<3 {printf "  x%-4d taken  %s\n", $2+0, $3}
      ' | head -18
    echo ""

    echo "----- TOP ALARM / WAKEUP SOURCES -----"
    echo "(scheduled wakeups = something polling on an RTC timer)"
    # Real format on this build: history lines carrying *walarm*:<name>. Count
    # by alarm name. Also surface the kernel wake_reason tokens (what actually
    # pulled the SoC out of suspend).
    grep -oE '\*walarm\*:[^"]+' "$_raw" 2>/dev/null \
      | sort | uniq -c | sort -rn | head -15 \
      | awk '{n=$1; $1=""; sub(/^ /,""); printf "  x%-4d  %s\n", n+0, $0}'
    echo ""
    echo "  -- kernel wake_reason (what resumed the SoC) --"
    grep -oE 'wake_reason=[0-9]*:"[^"]+"' "$_raw" 2>/dev/null \
      | sed 's/wake_reason=[0-9]*://' \
      | sort | uniq -c | sort -rn | head -8 \
      | awk '{n=$1; $1=""; sub(/^ /,""); printf "  x%-4d  %s\n", n+0, $0}'
    echo ""

    echo "----- HOW TO READ -----"
    echo "* A named third-party package high in either list that you don't need"
    echo "  in the background is a candidate for a standby-bucket / wakelock"
    echo "  restriction."
    echo "* AOD (systemui.aod.*) and location (activity-detection, GnssLocation,"
    echo "  NetworkLocationScanner) alarms are common standby drains — they're"
    echo "  user-facing features, so weigh battery vs the feature before cutting."
    echo "* Cross-check timestamps against phase_timeline.txt — wakeups during"
    echo "  'sleep'/'idle' phases are the ones that actually cost standby battery."
  } > "$_out"
}

# Live "what is awake right now" — current partial wakelocks held and the power
# manager's view. Cheap; safe to call each poll. Appends a compact one-liner.
lk_wakelock_live_row() {
  _e=$(date +%s)
  # active kernel sources count (excluding ours)
  _ksrc=/sys/kernel/debug/wakeup_sources
  [ -r "$_ksrc" ] || _ksrc=/d/wakeup_sources
  _kactive=0; _ktop=""
  if [ -r "$_ksrc" ]; then
    _kactive=$(awk -v self="$LK_WAKELOCK_NAME" 'NR>1 && $1!=self && $2>0 {n++} END{print n+0}' "$_ksrc" 2>/dev/null)
    _ktop=$(awk -v self="$LK_WAKELOCK_NAME" 'NR>1 && $1!=self && $6>0 {print $1"("$6")"}' "$_ksrc" 2>/dev/null | head -3 | tr '\n' ',')
  fi
  # app partial wakelocks currently held (power manager)
  _plock=""
  if lk_have dumpsys; then
    _plock=$(dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' \
             | grep -iE "PARTIAL_WAKE_LOCK|FULL_WAKE_LOCK" \
             | grep -iv "$LK_WAKELOCK_NAME" | head -3 \
             | sed 's/^[[:space:]]*//' | tr '\n' ';')
  fi
  echo "${_e}|kactive=${_kactive}|ktop=${_ktop}|plocks=${_plock}" >> "$LK_OUT_DIR/wake_live.txt"
}

# OEM toggle state tracker — records the LIVE value of the OnePlus toggles ASB
lk_oem_toggle_row() {
  _e=$(date +%s)
  lk_have settings || return 0
  _re=$(settings get global ram_expand_size 2>/dev/null)
  _rel=$(settings get global ram_expand_size_list 2>/dev/null)
  _ress=$(settings get global ram_expand_switch_state 2>/dev/null)
  _ab=$(settings get global adaptive_battery_management_enabled 2>/dev/null)
  _lh=$(settings get global sem_low_heat_mode 2>/dev/null)
  echo "${_e}|ram_expand_size=${_re}|ram_expand_size_list=${_rel}|switch_state=${_ress}|adaptive_bat=${_ab}|low_heat=${_lh}" >> "$LK_OUT_DIR/oem_toggles_trace.txt"
}

# One-shot deep dump of EVERY ram/expand-related key across all settings
lk_oem_ram_expand_probe() {
  _tag="${1:-probe}"
  {
    echo "===== RAM-EXPAND KEY PROBE ${_tag} $(date '+%Y-%m-%d %H:%M:%S') ====="
    if lk_have settings; then
      for _ns in global system secure; do
        echo "# --- settings $_ns (ram/expand/vram) ---"
        settings list "$_ns" 2>/dev/null | grep -iE "ram_expand|expand_size|vram|ram_boost|swap|extend.*mem|mem.*extend" \
          | grep -v "^$" | sed 's/^/    /'
      done
    fi
    echo "# --- getprop (ram/expand/vram/swap) ---"
    getprop 2>/dev/null | grep -iE "ram_expand|vram|ram_boost|swapfile|extend.*ram|ram.*extend|oplus.*ram|oplus.*mem" \
      | sed 's/^/    /'
    echo ""
  } >> "$LK_OUT_DIR/oem_ram_expand_probe.txt"
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

# =====  Smart Mode logkit helpers ============================================
# These capture the Smart Mode adaptive layer state per tick + final summary.

lk_check_smart_mode_active() {
  # Verify both: profile == smart AND smart_mode_enabled flag == 1
  _cur=$(cat "$MODDIR/current_profile" 2>/dev/null)
  _flag=$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)
  if [ "$_cur" != "smart" ]; then
    echo "⚠️  Current profile is '$_cur', expected 'smart'."
    echo "    Tap 🤖 Smart in WebUI or run: sh $MODDIR/tools/asb_smart_mode.sh enable"
    return 1
  fi
  if [ "$_flag" != "1" ]; then
    echo "⚠️  smart_mode_enabled file flag is '$_flag', expected '1'."
    echo "    Run: sh $MODDIR/tools/asb_smart_mode.sh enable"
    return 1
  fi
  return 0
}

lk_smart_trace_header() {
  {
    echo "#  Smart Mode trace — one row per poll"
    echo "# Columns:"
    echo "#   epoch  iso_time  bucket_id  daypart  is_weekend  fb_level"
    echo "#   conf_x1000  alpha_battery_x1000  interactive_bonus_x1000"
    echo "#   sleep_override  thermal_veto  app_hint  pkg_hash"
    echo "#   cpu_max_c  bat_pct  bat_temp_dC  screen_on  charging"
    echo "#   fsm_state  fsm_profile_idx  pkg_detect_ok  pkg_source  cap_owner"
    echo "#   draw_mA  gpu_busy_pct  little_cur_MHz  prime_cur_MHz"
    echo "# Daypart: 0=sleep 1=wake 2=morn 3=day 4=eve 5=late"
    echo "# Fallback: 0=exact 1=daypart 2=class 3=global 4=safe_default(cold-start)"
    echo "# App hint: 0=idle 1=light 2=medium 3=heavy 4=gaming"
    echo "# pkg_source: 0=none 1=activity_top 2=resumed 3=window_focus"
    echo "# draw_mA: battery current magnitude (mA); pair with charging col for direction"
    echo "epoch iso bucket dp wkd fb conf alpha inter night veto app pkghash cpuC batpct batT scr chg state pidx pkgok pkgsrc capowner drawmA gpubusy f0MHz fpMHz"
  } > "$LK_OUT_DIR/smart_trace.tsv"
}

# Extract a single key=value from /dev/.asb/state (returns "" if missing)
lk_state_kv() {
  _k="$1"
  grep -m1 "^${_k}=" /dev/.asb/state 2>/dev/null | sed "s/^${_k}=//"
}

lk_capture_smart_trace_row() {
  _e=$(date +%s)
  _d=$(date '+%Y-%m-%dT%H:%M:%S')

  # Smart-specific fields written by C governor each tick
  _bucket=$(lk_state_kv smart_bucket_id)
  _dp=$(lk_state_kv smart_daypart)
  _wkd=$(lk_state_kv smart_is_weekend)
  _fb=$(lk_state_kv smart_fallback_level)
  _conf=$(lk_state_kv smart_confidence)
  _alpha=$(lk_state_kv smart_alpha_battery)
  _inter=$(lk_state_kv smart_interactive_bonus)
  _night=$(lk_state_kv smart_sleep_override)
  _veto=$(lk_state_kv smart_thermal_veto)
  _app=$(lk_state_kv smart_app_hint)
  _pkghash=$(lk_state_kv smart_pkg_hash)
  _pkgok=$(lk_state_kv smart_pkg_detect_ok)
  _pkgsrc=$(lk_state_kv smart_pkg_source)
  _capowner=$(lk_state_kv cap_owner)

  # CPU temp: state file uses 'cap_temp' (degC), not 'cpu_max_c'
  _cpuC=$(lk_state_kv cap_temp)
  _state=$(lk_state_kv state)
  # state file exposes 'profile' as a string name; map to numeric idx so the
  # trace schema stays stable and machine-parseable.
  _pname=$(lk_state_kv profile)
  case "$_pname" in
    battery)     _pidx=0 ;;
    balanced)    _pidx=1 ;;
    performance) _pidx=2 ;;
    smart)       _pidx=3 ;;
    "")          _pidx=- ;;
    *)           _pidx="$_pname" ;;
  esac
  _bpct=$(lk_state_kv capacity)
  [ -z "$_bpct" ] && _bpct=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  _btmp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)

  # Screen state: convert Awake/Asleep/Dozing text to 1/0
  _scr_raw=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | sed 's/.*mWakefulness=//;s/ .*//')
  case "$_scr_raw" in
    Awake) _scr=1 ;;
    Asleep|Dozing) _scr=0 ;;
    *) _scr=- ;;
  esac

  # Charging state from battery status
  _chg_raw=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
  case "$_chg_raw" in
    Charging|Full) _chg=1 ;;
    Discharging|"Not charging") _chg=0 ;;
    *) _chg=- ;;
  esac

  # --- autonomy fields (added so drain correlates with Smart state in one row) ---
  _ima=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  if [ -n "$_ima" ]; then
    _ima_abs=${_ima#-}
    # uA -> mA when the value is clearly in microamps (5+ digits)
    if [ "${#_ima_abs}" -ge 5 ]; then _ima=$(( _ima_abs / 1000 )); else _ima=$_ima_abs; fi
  fi
  # GPU busy % (activity — high GPU busy off-screen is a drain red flag)
  _gbusy=$(cat /sys/class/kgsl/kgsl-3d0/gpubusy 2>/dev/null | awk '{ if ($2>0) printf "%d", $1*100/$2; else print 0 }')
  # Actual current freq of the little (policy0) and prime (top policy) clusters,
  # in MHz — shows whether cores are really idling down under each profile.
  _f0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)
  [ -n "$_f0" ] && _f0=$(( _f0 / 1000 ))
  _ptop=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | sort -t y -k3 -n | tail -1)
  _fp=$(cat "$_ptop/scaling_cur_freq" 2>/dev/null)
  [ -n "$_fp" ] && _fp=$(( _fp / 1000 ))

  # Fallback empty fields to '-' so columns stay aligned
  for v in _bucket _dp _wkd _fb _conf _alpha _inter _night _veto _app _pkghash _cpuC _state _pidx _bpct _btmp _scr _chg _pkgok _pkgsrc _capowner _ima _gbusy _f0 _fp; do
    eval "_val=\$$v"
    [ -z "$_val" ] && eval "$v=-"
  done

  echo "$_e $_d $_bucket $_dp $_wkd $_fb $_conf $_alpha $_inter $_night $_veto $_app $_pkghash $_cpuC $_bpct $_btmp $_scr $_chg $_state $_pidx $_pkgok $_pkgsrc $_capowner $_ima $_gbusy $_f0 $_fp" \
    >> "$LK_OUT_DIR/smart_trace.tsv"
}

# Append session_history.jsonl entries that arrived during this capture window
lk_capture_smart_sessions_window() {
  _src="/data/adb/asb/session_history.jsonl"
  [ -r "$_src" ] || return 0
  _dst="$LK_OUT_DIR/session_history_window.jsonl"
  # Cap work: only consider the last 400 sessions (matches the on-disk trim),
  tail -n 400 "$_src" 2>/dev/null | awk -v start="$LK_START_EPOCH" '
    {
      if (match($0, /"ts":"[0-9T:Z\-]+"/)) {
        t = substr($0, RSTART+6, RLENGTH-7)
        cmd = "date -d \"" t "\" +%s 2>/dev/null"
        epoch = ""
        if ((cmd | getline epoch) <= 0) epoch = ""
        close(cmd)
        if (epoch != "" && epoch+0 >= start+0) print $0
      }
    }
  ' > "$_dst" 2>/dev/null || true
  _n=$(wc -l < "$_dst" 2>/dev/null | tr -d ' ')
  echo "[smart] captured $_n session_history entries in window" >&2
}

# Save the bucket store snapshot at end of capture for diff vs start
lk_snapshot_smart_store() {
  _suffix="$1"
  _bin=/data/adb/asb/buckets.bin
  if [ -r "$_bin" ]; then
    cp "$_bin" "$LK_OUT_DIR/buckets_${_suffix}.bin" 2>/dev/null
    # Also hex-dump for easy inspection
    od -An -v -tx1 "$_bin" 2>/dev/null | head -50 > "$LK_OUT_DIR/buckets_${_suffix}.hex" 2>/dev/null
  fi
}

# End-of-run Smart Mode aggregate summary
lk_kv_state() {
  grep "^$1=" /dev/.asb/state 2>/dev/null | head -1 | cut -d= -f2
}

lk_emit_report_card() {
  _out="$LK_OUT_DIR/_report_card.txt"
  _dur_s=$(( $(date +%s) - LK_START_EPOCH ))
  [ "$_dur_s" -lt 0 ] 2>/dev/null && _dur_s=0
  _dur_h=$(awk -v s="$_dur_s" 'BEGIN { printf "%.2f", s/3600 }')
  _q_last=$(lk_kv_state smart_quality_last)
  _q_avg=$(lk_kv_state smart_quality_avg)
  _q_fail=$(lk_kv_state smart_q_fail)
  _budget_sev=$(lk_kv_state smart_budget_sev)
  _budget_pred=$(lk_kv_state smart_budget_pred_h_x10)
  _budget_src=$(lk_kv_state smart_budget_src)
  _ewma=$(lk_kv_state smart_drain_ewma_x10)
  _anom=$(lk_kv_state anomaly_code)
  _anom_n=$(lk_kv_state anomaly_count_1h)
  _det=$(lk_kv_state cap_detente_skipped)
  _flavor=$(lk_kv_state build_flavor)
  _unit=$(lk_kv_state bat_cur_unit)
  _clamp1h=$(lk_kv_state vendor_clamp_1h 2>/dev/null)
  [ -z "$_clamp1h" ] && _clamp1h=$(grep -o '"vendor_clamp_1h": [0-9]*' /dev/.asb/conflicts.json 2>/dev/null | grep -o '[0-9]*')
  case "$_q_fail" in
    1) _fail_name="battery" ;;
    2) _fail_name="heat" ;;
    3) _fail_name="stability" ;;
    4) _fail_name="vendor_war" ;;
    *) _fail_name="none" ;;
  esac
  {
    echo "===== ASB Report Card ====="
    echo "capture:         ${LK_SCENARIO:-unknown}  duration: ${_dur_h}h  flavor: ${_flavor:-?}"
    echo ""
    echo "session quality: last=${_q_last:--}  avg=${_q_avg:--}  primary_failure=${_fail_name}"
    echo "energy budget:   severity=${_budget_sev:--}  predicted_h_x10=${_budget_pred:--}  src=$([ "$_budget_src" = "1" ] && echo bucket || echo global)  drain_ewma_x10=${_ewma:--}"
    _bacc=$(lk_kv_state budget_accuracy_score)
    _berr=$(lk_kv_state budget_error_pct)
    _bstreak=$(lk_kv_state budget_bias_streak)
    _bdir=$(lk_kv_state budget_bias_dir)
    if [ -n "$_bacc" ] && [ "$_bacc" != "-1" ]; then
      _corr=""
      if [ -n "$_bstreak" ] && [ "$_bstreak" -ge 3 ] 2>/dev/null; then
        _corr="  correcting=$([ "$_bdir" = "1" ] && echo 'rate+' || echo 'rate-')"
      fi
      echo "budget accuracy: score=${_bacc}/100  error=${_berr}%${_corr}"
    elif [ "$_bacc" = "-1" ]; then
      echo "budget accuracy: paused (grading suspended during sleep/charge)"
    fi
    _own=$(lk_kv_state cap_owner)
    _wa=$(lk_kv_state write_attempts)
    _wsd=$(lk_kv_state write_skipped_detente)
    _wsb=$(lk_kv_state write_skipped_backoff)
    echo "vendor war:      clamp_1h=${_clamp1h:--}  detente_skipped_total=${_det:--}  cap_owner=${_own:--}"
    echo "cap writes:      attempts=${_wa:--}  skipped_detente=${_wsd:--}  skipped_backoff=${_wsb:--}"
    echo "anomalies:       code=${_anom:-0}  episodes_1h=${_anom_n:-0}"
    echo "sensors:         bat_cur_unit=${_unit:--} (0=undecided 1=uA 2=mA)"

    # Gaming session peaks (only meaningful right after / during a game)
    _gchg=$(lk_kv_state game_charging)
    _gbt=$(lk_kv_state game_bat_temp_peak_dc)
    _gcpu=$(lk_kv_state game_cpu_max_peak_c)
    _gclvl=$(lk_kv_state game_cool_lvl_peak)
    if [ -n "$_gcpu" ] && [ "$_gcpu" -gt 0 ] 2>/dev/null; then
      _gbt_c=""
      [ -n "$_gbt" ] && [ "$_gbt" -gt 0 ] 2>/dev/null && _gbt_c="$(( _gbt / 10 ))C"
      echo "gaming peaks:    charging=${_gchg:-0}  bat_temp_peak=${_gbt_c:--}  cpu_max_peak=${_gcpu}C  cool_level_peak=${_gclvl:-0}"
    fi

    # Plain-language diagnosis: rank the weakest quality component and suggest
    # one concrete next step. Built from the same subscores the verdict uses.
    _qh=$(lk_kv_state smart_q_heat); _qv=$(lk_kv_state smart_q_vendor)
    _qb=$(lk_kv_state smart_q_bat);  _qs=$(lk_kv_state smart_q_stab)
    _diag_primary=""; _diag_secondary=""; _diag_hint=""
    # collect (name,score) pairs that are valid (>=0), find two lowest
    _lowest=101; _lowest2=101
    for _pair in "heat:$_qh" "vendor:$_qv" "battery:$_qb" "stability:$_qs"; do
      _nm="${_pair%%:*}"; _sc="${_pair##*:}"
      case "$_sc" in ''|*[!0-9-]*) continue ;; esac
      [ "$_sc" -lt 0 ] 2>/dev/null && continue
      if [ "$_sc" -lt "$_lowest" ] 2>/dev/null; then
        _lowest2=$_lowest; _diag_secondary=$_diag_primary
        _lowest=$_sc; _diag_primary=$_nm
      elif [ "$_sc" -lt "$_lowest2" ] 2>/dev/null; then
        _lowest2=$_sc; _diag_secondary=$_nm
      fi
    done
    if [ -n "$_diag_primary" ] && [ "$_lowest" -lt 80 ] 2>/dev/null; then
      case "$_diag_primary" in
        heat)      _diag_hint="run hot games with cool_gaming on; lower screen brightness/refresh" ;;
        vendor)    _diag_hint="vendor thermal-clamps under load — expected when hot; no action if heat is the real cause" ;;
        battery)   _diag_hint="background drain high; check sync/push-heavy apps" ;;
        stability) _diag_hint="caps oscillating; consider easing cool_gaming if it's on" ;;
      esac
      echo ""
      echo "diagnosis:       primary=${_diag_primary}  secondary=${_diag_secondary:-none}"
      echo "improvement:     ${_diag_hint}"
    fi
    echo ""
    echo "score key: quality 0-100 (>=80 good), budget sev 0=ok 1=warn 2=emergency"
  } > "$_out"
  lk_log "report card -> $_out"
}

lk_emit_smart_summary() {
  _trace="$LK_OUT_DIR/smart_trace.tsv"
  _out="$LK_OUT_DIR/_smart_summary.txt"
  [ -r "$_trace" ] || return 0

  {
    echo "=====  Smart Mode capture summary ====="
    echo "scenario:    $LK_SCENARIO"
    echo "duration:    $(( $(date +%s) - LK_START_EPOCH ))s"
    echo "ticks:       $LK_TICK_COUNT"
    echo ""

    # Count rows where smart was actually active (not '-')
    _rows=$(grep -cE '^[0-9]' "$_trace" 2>/dev/null)
    _smart_rows=$(awk '/^[0-9]/ && $3 != "-"' "$_trace" 2>/dev/null | wc -l)
    echo "data rows:           $_rows"
    echo "with smart fields:   $_smart_rows"
    echo ""

    # Bucket distribution (which buckets did we hit during capture?)
    echo "── Bucket distribution ──"
    awk '/^[0-9]/ && $3 != "-" { c[$3]++ } END { for (k in c) printf "  bucket #%s : %d ticks\n", k, c[k] }' \
      "$_trace" 2>/dev/null | sort
    echo ""

    # Daypart distribution
    echo "── Daypart distribution ──"
    awk '/^[0-9]/ && $4 != "-" {
      n[$4]++
    } END {
      for (k in n) {
        name = "?"
        if (k == 0) name = "sleep"; else if (k == 1) name = "wake"
        else if (k == 2) name = "morn"; else if (k == 3) name = "day"
        else if (k == 4) name = "eve"; else if (k == 5) name = "late"
        printf "  daypart %s (%s) : %d ticks\n", k, name, n[k]
      }
    }' "$_trace" 2>/dev/null | sort
    echo ""

    # Fallback distribution (how often did we have a real exact match?)
    echo "── Fallback distribution ──"
    awk '/^[0-9]/ && $6 != "-" {
      n[$6]++
    } END {
      for (k in n) {
        name = "?"
        if (k == 0) name = "exact"; else if (k == 1) name = "daypart_pair"
        else if (k == 2) name = "class"; else if (k == 3) name = "global"
        else if (k == 4) name = "safe_default(cold)"
        printf "  level %s (%s) : %d ticks\n", k, name, n[k]
      }
    }' "$_trace" 2>/dev/null | sort
    echo ""

    # Confidence stats
    echo "── Confidence (x1000) ──"
    awk '/^[0-9]/ && $7 != "-" {
      v=$7+0; sum+=v; n++
      if (n==1 || v<min) min=v
      if (n==1 || v>max) max=v
    } END {
      if (n>0) printf "  ticks=%d  avg=%.0f  min=%d  max=%d  (1000=full conf, 350=low gate, 650=strong gate)\n",
        n, sum/n, min, max
      else print "  (no data)"
    }' "$_trace" 2>/dev/null
    echo ""

    # Alpha distribution (how battery-leaning was the blend?)
    echo "── Alpha_battery (x1000, 0=balanced 1000=battery) ──"
    awk '/^[0-9]/ && $8 != "-" {
      v=$8+0; sum+=v; n++
      if (n==1 || v<min) min=v
      if (n==1 || v>max) max=v
      bin = int(v/100)*100
      b[bin]++
    } END {
      if (n>0) {
        printf "  ticks=%d  avg=%.0f  min=%d  max=%d\n", n, sum/n, min, max
        for (k=0; k<=1000; k+=100) {
          cnt = b[k]+0
          bar = ""
          step = int(n/40); if (step<1) step=1
          for (i=0; i<cnt; i+=step) bar = bar "#"
          printf "  %3d-%3d : %s (%d)\n", k, k+99, bar, cnt
        }
      } else print "  (no alpha data)"
    }' "$_trace" 2>/dev/null
    echo ""

    # Override / veto rates
    echo "── Override / Veto firing rate ──"
    awk '/^[0-9]/ && $10 != "-" { n10++; if ($10+0==1) o++; }
         /^[0-9]/ && $11 != "-" { n11++; if ($11+0==1) v++; }
         END {
           if (n10>0) printf "  night_safe_override: %d/%d ticks (%.1f%%)\n", o+0, n10, (o+0)*100.0/n10
           if (n11>0) printf "  thermal_veto:        %d/%d ticks (%.1f%%)\n", v+0, n11, (v+0)*100.0/n11
         }' "$_trace" 2>/dev/null
    echo ""

    # App hint distribution
    echo "── App hint distribution ──"
    awk '/^[0-9]/ && $12 != "-" {
      n[$12]++
    } END {
      for (k in n) {
        name = "?"
        if (k == 0) name = "idle"; else if (k == 1) name = "light"
        else if (k == 2) name = "medium"; else if (k == 3) name = "heavy"
        else if (k == 4) name = "gaming"
        printf "  hint %s (%s) : %d ticks\n", k, name, n[k]
      }
    }' "$_trace" 2>/dev/null | sort
    echo ""

    # Thermal correlation: avg CPU temp grouped by alpha range
    echo "── Avg CPU temp by alpha range (does battery-lean run cooler?) ──"
    awk '/^[0-9]/ && $8 != "-" && $14 != "-" && $14+0 > 0 {
      a=$8+0; t=$14+0
      band=int(a/200)*200
      tsum[band]+=t; n[band]++
    } END {
      any=0
      for (k=0; k<=1000; k+=200) {
        if (n[k] > 0) {
          printf "  alpha %3d-%3d : %d ticks, avg CPU %.1f°C\n", k, k+199, n[k], tsum[k]/n[k]
          any=1
        }
      }
      if (!any) print "  (no valid CPU temp samples — check cap_temp state field)"
    }' "$_trace" 2>/dev/null

    # Battery drain analysis (the autonomy view). draw_mA is col 24, screen col
    # 17, charging col 18, profile_idx col 20. We only average DISCHARGING ticks.
    echo ""
    echo "── Battery drain (discharging only; draw_mA col) ──"
    echo "   NOTE: this capture holds a partial wakelock to survive Doze, so the"
    echo "   device never enters true deep sleep — screen-OFF mA here is an UPPER"
    echo "   bound, real standby is lower. See wake_sources.txt to attribute it."
    awk '/^[0-9]/ && $24 != "-" && $18 == "0" {
      v=$24+0; n++; sum+=v
      if ($17=="1") { son_n++; son_sum+=v } else if ($17=="0") { soff_n++; soff_sum+=v }
      # by profile idx (col 20): 0=batt 1=bal 2=perf 3=smart
      pn[$20]++; ps[$20]+=v
    } END {
      if (n>0) {
        printf "  overall: ticks=%d  avg=%d mA\n", n, sum/n
        if (son_n>0)  printf "  screen ON : ticks=%d  avg=%d mA\n", son_n, son_sum/son_n
        if (soff_n>0) printf "  screen OFF: ticks=%d  avg=%d mA  (idle/standby drain)\n", soff_n, soff_sum/soff_n
        for (k=0;k<=3;k++) if (pn[k]>0) {
          name=(k==0?"battery":k==1?"balanced":k==2?"performance":"smart")
          printf "  profile %s: ticks=%d  avg=%d mA\n", name, pn[k], ps[k]/pn[k]
        }
      } else print "  (no discharging draw_mA samples)"
    }' "$_trace" 2>/dev/null
    echo ""
    echo "── GPU activity & CPU idle (off-screen high values = drain red flags) ──"
    awk '/^[0-9]/ && $17 == "0" && $18 == "0" {
      if ($25 != "-") { gn++; gsum+=$25 }
      if ($26 != "-") { fn++; fsum+=$26; if (fn==1||$26<fmin) fmin=$26 }
    } END {
      if (gn>0) printf "  off-screen GPU busy avg=%d%% (should be ~0)\n", gsum/gn
      if (fn>0) printf "  off-screen little-cluster freq avg=%d MHz min=%d MHz (low=good)\n", fsum/fn, fmin
      if (gn==0 && fn==0) print "  (no off-screen samples)"
    }' "$_trace" 2>/dev/null

    # Final ASB Smart Mode CLI status snapshot
    echo ""
    echo "── End-of-capture Smart status snapshot ──"
    sh "$MODDIR/tools/asb_smart_mode.sh" status 2>/dev/null | head -30
  } > "$_out"

  cat "$_out"
}

# ===== end Smart Mode helpers ===================================================

LK_AUDIO_PLAY=0
LK_AUDIO_ROUTE="none"
lk_sample_audio() {
  LK_AUDIO_PLAY=0
  LK_AUDIO_ROUTE="none"
  _ad=$(dumpsys audio 2>/dev/null)
  if [ -z "$_ad" ]; then export LK_AUDIO_PLAY LK_AUDIO_ROUTE; return 0; fi
  case "$_ad" in
    *state:started*) LK_AUDIO_PLAY=1 ;;
  esac
  _rl=$(printf '%s\n' "$_ad" | grep -iE '^[[:space:]]*Devices:' | tr 'A-Z' 'a-z')
  [ -z "$_rl" ] && _rl=$(printf '%s\n' "$_ad" | tr 'A-Z' 'a-z')
  case "$_rl" in
    *ble_headset*|*ble_speaker*|*ble_broadcast*|*le_audio*) LK_AUDIO_ROUTE="bt_le" ;;
    *bt_a2dp*|*bluetooth_a2dp*) LK_AUDIO_ROUTE="bt" ;;
    *usb_headset*|*usb_device*) LK_AUDIO_ROUTE="usb" ;;
    *headset*|*headphone*|*wired*) LK_AUDIO_ROUTE="wired" ;;
    *speaker*|*earpiece*) LK_AUDIO_ROUTE="speaker" ;;
  esac
  export LK_AUDIO_PLAY LK_AUDIO_ROUTE
}

lk_snapshot_audio() {
  _tag="$1"
  _af="$LK_OUT_DIR/audio_trace.txt"
  {
    echo "===== AUDIO [$_tag] $(date -u '+%Y-%m-%dT%H:%M:%SZ') play=$LK_AUDIO_PLAY route=$LK_AUDIO_ROUTE ====="
    echo "# codec / offload props"
    for p in persist.bluetooth.a2dp_offload.disabled persist.vendor.bluetooth.a2dp_offload.disabled \
             persist.bluetooth.a2dp.optional_codecs_enabled persist.bluetooth.disableabsvol \
             persist.vendor.bluetooth.3rd.lhdcv5.support persist.bluetooth.aptxadaptive_offload.enabled \
             persist.vendor.audio.a2dp.hal.implementation persist.vendor.audio.ull.enabled; do
      echo "  $p = $(lk_get_prop "$p")"
    done
    echo "# active players"
    dumpsys audio 2>/dev/null | grep -iE 'state:started|usage=|content Type|piid:|AudioPlaybackConfiguration' | head -20
    echo "# routing / devices"
    dumpsys audio 2>/dev/null | grep -iE 'Devices for|Device for|Sink:|Communication device|mConnectedDevices|routed|BLE_|A2DP|SPEAKER|WIRED' | head -20
    echo "# stream volumes"
    dumpsys audio 2>/dev/null | grep -iE 'STREAM_MUSIC|Current:|Muted:|- STREAM_' | head -14
    echo "# bt codec"
    dumpsys bluetooth_manager 2>/dev/null | grep -iE 'codec|sample_?rate|bits_?per|channel|LHDC|LDAC|aptX|SBC|AAC|state: connected' | head -20
    echo "# audioflinger effects/output"
    dumpsys media.audio_flinger 2>/dev/null | grep -iE 'Effect|session|viper|Output thread|sampleRate|format|Latency|Frame' | head -25
    echo "# alsa pcm status"
    for c in /proc/asound/card*/pcm*/sub*/status; do
      [ -r "$c" ] || continue
      echo "  $c:"; sed 's/^/    /' "$c" 2>/dev/null
    done | head -30
    echo ""
  } >> "$_af" 2>/dev/null || true
}

lk_snapshot_kernel() {
  _tag="$1"
  _kf="$LK_OUT_DIR/kernel_params.txt"
  {
    echo "===== KERNEL [$_tag] $(date -u '+%Y-%m-%dT%H:%M:%SZ') ====="
    echo "# identity"
    echo "  uname_r: $(uname -r)"
    echo "  version: $(cat /proc/version 2>/dev/null)"
    echo "  cmdline: $(cat /proc/cmdline 2>/dev/null | cut -c1-400)"
    echo "  ksu: $(lk_have ksud && echo yes || echo no)"
    echo "# cpufreq per policy"
    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$pol" ] || continue
      echo "  $(basename "$pol"): gov=$(cat "$pol/scaling_governor" 2>/dev/null) cur=$(cat "$pol/scaling_cur_freq" 2>/dev/null) min=$(cat "$pol/scaling_min_freq" 2>/dev/null) max=$(cat "$pol/scaling_max_freq" 2>/dev/null) hwmax=$(cat "$pol/cpuinfo_max_freq" 2>/dev/null)"
      echo "    avail_gov: $(cat "$pol/scaling_available_governors" 2>/dev/null)"
      _sg="$pol/schedutil/rate_limit_us"
      [ -r "$_sg" ] && echo "    schedutil.rate_limit_us: $(cat "$_sg" 2>/dev/null)"
      _up="$pol/schedutil/up_rate_limit_us"
      [ -r "$_up" ] && echo "    schedutil.up/down: $(cat "$_up" 2>/dev/null)/$(cat "$pol/schedutil/down_rate_limit_us" 2>/dev/null)"
    done
    echo "# kernel.sched"
    for k in sched_latency_ns sched_min_granularity_ns sched_wakeup_granularity_ns \
             sched_migration_cost_ns sched_util_clamp_min sched_util_clamp_max \
             sched_energy_aware sched_schedstats; do
      _v=$(cat "/proc/sys/kernel/$k" 2>/dev/null); [ -n "$_v" ] && echo "  kernel.$k = $_v"
    done
    echo "# cpu boost / walt (custom-kernel markers)"
    for w in /sys/module/cpu_boost/parameters /proc/sys/walt /sys/walt /sys/devices/system/cpu/walt; do
      [ -d "$w" ] || continue
      echo "  $w:"
      for f in "$w"/*; do [ -f "$f" ] && [ -r "$f" ] && echo "    $(basename "$f")=$(cat "$f" 2>/dev/null | tr '\n' ' ' | cut -c1-90)"; done
    done
    echo "# io scheduler"
    for b in /sys/block/sda /sys/block/mmcblk0 /sys/block/dm-0; do
      [ -r "$b/queue/scheduler" ] && echo "  $(basename "$b"): $(cat "$b/queue/scheduler" 2>/dev/null) read_ahead_kb=$(cat "$b/queue/read_ahead_kb" 2>/dev/null) nr_requests=$(cat "$b/queue/nr_requests" 2>/dev/null)"
    done
    echo "# thermal"
    echo "  zone0.policy: $(cat /sys/class/thermal/thermal_zone0/policy 2>/dev/null)"
    echo "  core_ctl present: $([ -d /sys/devices/system/cpu/cpu0/core_ctl ] && echo yes || echo no)"
    echo "# vm"
    for k in swappiness dirty_ratio dirty_background_ratio vfs_cache_pressure \
             watermark_boost_factor watermark_scale_factor min_free_kbytes page-cluster; do
      _v=$(cat "/proc/sys/vm/$k" 2>/dev/null); [ -n "$_v" ] && echo "  vm.$k = $_v"
    done
    echo "# zram / swap"
    echo "  swaps: $(cat /proc/swaps 2>/dev/null | tail -n +2 | tr '\n' ';')"
    echo ""
  } >> "$_kf" 2>/dev/null || true
}

lk_snapshot_network() {
  _tag="$1"
  _nf="$LK_OUT_DIR/network_trace.txt"
  {
    echo "===== NETWORK [$_tag] $(date -u '+%Y-%m-%dT%H:%M:%SZ') ====="
    echo "# data path"
    echo "  default_route: $(ip route get 1.1.1.1 2>/dev/null | head -1)"
    echo "  up_ifaces: $(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | tr '\n' ' ')"
    echo "# carrier / radio"
    echo "  operator: $(lk_get_prop gsm.operator.alpha) numeric: $(lk_get_prop gsm.operator.numeric) roaming: $(lk_get_prop gsm.operator.isroaming)"
    echo "  voice_type: $(lk_get_prop gsm.network.type) data_type: $(lk_get_prop gsm.data.network.type)"
    dumpsys telephony.registry 2>/dev/null | grep -iE 'mSignalStrength|mDataConnectionState=|mDataNetworkType=|mVoiceNetworkType=|rsrp|rssnr|level=' | head -10
    echo "# wifi link"
    dumpsys wifi 2>/dev/null | grep -iE 'SSID:|Supplicant state|RSSI:|Link speed|Tx Link speed|Rx Link speed|Frequency|score' | head -12
    echo "# tcp params (current, ASB may have tuned)"
    echo "  congestion: $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
    echo "  tcp_rmem: $(cat /proc/sys/net/ipv4/tcp_rmem 2>/dev/null)"
    echo "  tcp_wmem: $(cat /proc/sys/net/ipv4/tcp_wmem 2>/dev/null)"
    echo "  rmem_max: $(cat /proc/sys/net/core/rmem_max 2>/dev/null) wmem_max: $(cat /proc/sys/net/core/wmem_max 2>/dev/null)"
    echo "  netdev_budget: $(cat /proc/sys/net/core/netdev_budget 2>/dev/null) backlog: $(cat /proc/sys/net/core/netdev_max_backlog 2>/dev/null)"
    echo "  mtu_probing: $(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null) default_qdisc: $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
    echo "  tcp_notsent_lowat: $(cat /proc/sys/net/ipv4/tcp_notsent_lowat 2>/dev/null) fastopen: $(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null)"
    echo "# rmnet / wlan counters"
    for r in rmnet_data0 rmnet_data1 rmnet_ipa0 wlan0; do
      _d="/sys/class/net/$r"
      [ -d "$_d" ] && echo "  $r: oper=$(cat "$_d/operstate" 2>/dev/null) mtu=$(cat "$_d/mtu" 2>/dev/null) rx=$(cat "$_d/statistics/rx_bytes" 2>/dev/null) tx=$(cat "$_d/statistics/tx_bytes" 2>/dev/null)"
    done
    echo ""
  } >> "$_nf" 2>/dev/null || true
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
