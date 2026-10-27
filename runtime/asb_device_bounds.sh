# shellcheck shell=sh
# Validate and import synthesized per-device bounds without executing the file.
# The native governor performs the same identity/topology checks independently.

asb_device_bounds_current_topology() {
  ASB_BOUNDS_CURRENT_COUNT=0
  ASB_BOUNDS_CURRENT_SIGNATURE=""
  local _sys _dir _id _hw _policies _count _item
  local _little_id _little_hw _big_id _big_hw _mid_id _mid_hw
  _sys="${ASB_CPU_SYSFS:-/sys/devices/system/cpu}"
  _policies=""
  _count=0
  for _dir in "$_sys"/cpufreq/policy*; do
    [ -d "$_dir" ] || continue
    _id="${_dir##*policy}"
    _hw="$(cat "$_dir/cpuinfo_max_freq" 2>/dev/null | tr -d ' \r\n')"
    case "$_id:$_hw" in
      *[!0-9:]*|:*|*:) continue ;;
    esac
    _count=$((_count + 1))
    _policies="${_policies}${_policies:+ }${_id}:${_hw}"
  done
  ASB_BOUNDS_CURRENT_COUNT="$_count"
  case "$_count" in 2|3|4) ;; *) return 1 ;; esac

  _little_id=""; _little_hw=0; _big_id=""; _big_hw=0
  for _item in $_policies; do
    _id="${_item%%:*}"; _hw="${_item#*:}"
    if [ -z "$_little_id" ] || [ "$_hw" -lt "$_little_hw" ] || \
       { [ "$_hw" -eq "$_little_hw" ] && [ "$_id" -lt "$_little_id" ]; }; then
      _little_id="$_id"; _little_hw="$_hw"
    fi
    if [ -z "$_big_id" ] || [ "$_hw" -gt "$_big_hw" ] || \
       { [ "$_hw" -eq "$_big_hw" ] && [ "$_id" -gt "$_big_id" ]; }; then
      _big_id="$_id"; _big_hw="$_hw"
    fi
  done
  _mid_id="none"; _mid_hw=0
  if [ "$_count" -ge 3 ]; then
    for _item in $_policies; do
      _id="${_item%%:*}"; _hw="${_item#*:}"
      [ "$_id" = "$_little_id" ] && continue
      [ "$_id" = "$_big_id" ] && continue
      if [ "$_mid_id" = "none" ] || [ "$_hw" -gt "$_mid_hw" ] || \
         { [ "$_hw" -eq "$_mid_hw" ] && [ "$_id" -lt "$_mid_id" ]; }; then
        _mid_id="$_id"; _mid_hw="$_hw"
      fi
    done
    [ "$_mid_id" != "none" ] || return 1
  fi
  ASB_BOUNDS_CURRENT_SIGNATURE="${_little_id}:${_little_hw}>${_mid_id}:${_mid_hw}>${_big_id}:${_big_hw}"
  return 0
}

asb_device_bounds_validate() {
  local _file _schema _conf _source _fp _current_fp _count _sig
  _file="$1"
  ASB_BOUNDS_VALID=0
  ASB_BOUNDS_STATUS=skipped
  ASB_BOUNDS_REASON=missing
  [ -r "$_file" ] || return 1
  _schema="$(grep -E '^schema=' "$_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  [ "$_schema" = "2" ] || { ASB_BOUNDS_REASON=schema; return 1; }
  _conf="$(grep -E '^confidence=' "$_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  [ "$_conf" = "high" ] || { ASB_BOUNDS_REASON=confidence; return 1; }
  _source="$(grep -E '^source=' "$_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  [ "$_source" = "measured" ] || { ASB_BOUNDS_REASON=source; return 1; }

  ASB_BOUNDS_STATUS=stale
  ASB_BOUNDS_REASON=fingerprint
  _fp="$(grep -E '^fingerprint=' "$_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  _current_fp="$(getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"
  [ -n "$_fp" ] && [ -n "$_current_fp" ] && [ "$_fp" = "$_current_fp" ] || return 1

  ASB_BOUNDS_REASON=policy_count
  _count="$(grep -E '^policy_count=' "$_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r')"
  case "$_count" in 2|3|4) ;; *) return 1 ;; esac
  asb_device_bounds_current_topology || { ASB_BOUNDS_STATUS=skipped; ASB_BOUNDS_REASON=topology; return 1; }
  [ "$_count" = "$ASB_BOUNDS_CURRENT_COUNT" ] || return 1

  ASB_BOUNDS_REASON=cluster_signature
  _sig="$(grep -E '^cluster_signature=' "$_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r')"
  [ -n "$_sig" ] && [ "$_sig" = "$ASB_BOUNDS_CURRENT_SIGNATURE" ] || return 1

  ASB_BOUNDS_VALID=1
  ASB_BOUNDS_STATUS=valid
  ASB_BOUNDS_REASON=ok
  return 0
}

asb_device_bounds_import() {
  local _file _bk _bv _n
  _file="$1"
  asb_device_bounds_validate "$_file" || return 1
  _n=0
  while IFS='=' read -r _bk _bv; do
    case "$_bv" in ''|*[!0-9]*) continue ;; esac
    case "$_bk" in
      BATTERY_CPU_MAX_LITTLE) BATTERY_CPU_MAX_LITTLE="$_bv"; export BATTERY_CPU_MAX_LITTLE ;;
      BATTERY_CPU_MAX_BIG) BATTERY_CPU_MAX_BIG="$_bv"; export BATTERY_CPU_MAX_BIG ;;
      BATTERY_CPU_MAX_MID) BATTERY_CPU_MAX_MID="$_bv"; export BATTERY_CPU_MAX_MID ;;
      BATTERY_CPU_MAX_PRIME) BATTERY_CPU_MAX_PRIME="$_bv"; export BATTERY_CPU_MAX_PRIME ;;
      BATTERY_CPU_CAP_LITTLE) BATTERY_CPU_CAP_LITTLE="$_bv"; export BATTERY_CPU_CAP_LITTLE ;;
      BATTERY_CPU_CAP_BIG) BATTERY_CPU_CAP_BIG="$_bv"; export BATTERY_CPU_CAP_BIG ;;
      BATTERY_CPU_MIN_LITTLE) BATTERY_CPU_MIN_LITTLE="$_bv"; export BATTERY_CPU_MIN_LITTLE ;;
      BATTERY_CPU_MIN_BIG) BATTERY_CPU_MIN_BIG="$_bv"; export BATTERY_CPU_MIN_BIG ;;
      BATTERY_GPU_MAX_PCT) BATTERY_GPU_MAX_PCT="$_bv"; export BATTERY_GPU_MAX_PCT ;;
      BALANCED_CPU_MAX_LITTLE) BALANCED_CPU_MAX_LITTLE="$_bv"; export BALANCED_CPU_MAX_LITTLE ;;
      BALANCED_CPU_MAX_BIG) BALANCED_CPU_MAX_BIG="$_bv"; export BALANCED_CPU_MAX_BIG ;;
      BALANCED_CPU_MAX_MID) BALANCED_CPU_MAX_MID="$_bv"; export BALANCED_CPU_MAX_MID ;;
      BALANCED_CPU_CAP_LITTLE) BALANCED_CPU_CAP_LITTLE="$_bv"; export BALANCED_CPU_CAP_LITTLE ;;
      BALANCED_CPU_CAP_BIG) BALANCED_CPU_CAP_BIG="$_bv"; export BALANCED_CPU_CAP_BIG ;;
      BALANCED_CPU_MIN_LITTLE) BALANCED_CPU_MIN_LITTLE="$_bv"; export BALANCED_CPU_MIN_LITTLE ;;
      BALANCED_CPU_MIN_BIG) BALANCED_CPU_MIN_BIG="$_bv"; export BALANCED_CPU_MIN_BIG ;;
      BALANCED_GPU_MAX_PCT) BALANCED_GPU_MAX_PCT="$_bv"; export BALANCED_GPU_MAX_PCT ;;
      PERFORMANCE_CPU_MAX_LITTLE) PERFORMANCE_CPU_MAX_LITTLE="$_bv"; export PERFORMANCE_CPU_MAX_LITTLE ;;
      PERFORMANCE_CPU_MAX_BIG) PERFORMANCE_CPU_MAX_BIG="$_bv"; export PERFORMANCE_CPU_MAX_BIG ;;
      PERFORMANCE_CPU_MAX_MID) PERFORMANCE_CPU_MAX_MID="$_bv"; export PERFORMANCE_CPU_MAX_MID ;;
      PERFORMANCE_CPU_CAP_LITTLE) PERFORMANCE_CPU_CAP_LITTLE="$_bv"; export PERFORMANCE_CPU_CAP_LITTLE ;;
      PERFORMANCE_CPU_CAP_BIG) PERFORMANCE_CPU_CAP_BIG="$_bv"; export PERFORMANCE_CPU_CAP_BIG ;;
      PERFORMANCE_CPU_MIN_LITTLE) PERFORMANCE_CPU_MIN_LITTLE="$_bv"; export PERFORMANCE_CPU_MIN_LITTLE ;;
      PERFORMANCE_CPU_MIN_BIG) PERFORMANCE_CPU_MIN_BIG="$_bv"; export PERFORMANCE_CPU_MIN_BIG ;;
      PERFORMANCE_GPU_MAX_PCT) PERFORMANCE_GPU_MAX_PCT="$_bv"; export PERFORMANCE_GPU_MAX_PCT ;;
      *) continue ;;
    esac
    _n=$((_n + 1))
  done < "$_file"
  if [ "$_n" -gt 0 ]; then
    ASB_BOUNDS_STATUS=applied
    ASB_BOUNDS_REASON=ok
    return 0
  fi
  ASB_BOUNDS_STATUS=skipped
  ASB_BOUNDS_REASON=no_values
  return 1
}
