#!/system/bin/sh
if [ ! -f /data/adb/asb/debug ] && [ "$(getprop persist.asb.debug 2>/dev/null)" != "1" ]; then
  exec >/dev/null 2>&1
fi
MODID="AutoSystemBoost"
MODDIR="${0%/*}"
asb_resolve_moddir() {
  for _d in     "$MODDIR"     "/data/adb/modules/$MODID"     "/data/adb/modules_update/$MODID"     "/data/adb/modules/${MODID}_TMP"     "/data/adb/modules_update/${MODID}_TMP"
  do
    [ -n "$_d" ] || continue
    [ -f "$_d/module.prop" ] && { echo "$_d"; return 0; }
  done
  echo "/data/adb/modules/$MODID"
}
MODDIR="$(asb_resolve_moddir)"

mkdir -p /data/adb/asb 2>/dev/null
for _legacy_pair in \
    "asb_active_profile:active_profile" \
    "asb_baseline.txt:baseline.txt" \
    "asb_profile_switches.log:profile_switches.log" \
    "asb_user_config:user_config" \
    "asb_vendor_boot_counter:vendor_boot_counter" \
    "asb_vendor_mounts.log:vendor_mounts.log" \
    "asb_vendor_overlay_active:vendor_overlay_active" \
    "asb_recovery_disabled:recovery_disabled" \
    "asb_recovery_lock:recovery_lock" \
    "asb_debug:debug"; do
  _old="${_legacy_pair%:*}"
  _new="${_legacy_pair#*:}"
  if [ -e "/data/adb/$_old" ] && [ ! -e "/data/adb/asb/$_new" ]; then
    mv "/data/adb/$_old" "/data/adb/asb/$_new" 2>/dev/null || true
  elif [ -e "/data/adb/$_old" ]; then
    rm -f "/data/adb/$_old" 2>/dev/null || true
  fi
done

# ── V56 learning-reset boot sweep ────────────────────────────────────────────
# Must run BEFORE asb_utils.sh is sourced below (sourcing it auto-starts the
# governor), i.e. at a point in a fresh boot where NO governor instance is
# alive. Two jobs:
#  (a) consume the install-time pending marker: install.sh deletes the learned
#      state, but the OLD still-running governor re-saves buckets.bin/pstats
#      from memory within ~5 minutes, resurrecting it before the reboot.
#      Deleting again here — with no daemon alive — makes the reset stick.
#  (b) one-shot repair for devices that upgraded before this fix existed and
#      already got their store resurrected (field data: 286 pre-reset bucket
#      sessions, last_seen older than the reset marker). Learner state only —
#      the append-only session_history.jsonl survived the race cleanly and is
#      genuinely fresh, so it is kept.
if [ -f /data/adb/asb/learning_reset_pending ]; then
  rm -f /data/adb/asb/buckets.bin /data/adb/asb/buckets.bin.bak \
        /data/adb/asb/pstats_balanced.json /data/adb/asb/pstats_battery.json \
        /data/adb/asb/smart_appheat.bin /data/adb/asb/auto_battery_state \
        /data/adb/asb/session_history.jsonl \
        /data/adb/asb/session_history_migrated_v47 2>/dev/null
  rm -f /data/adb/asb/learning_reset_pending 2>/dev/null
  : > /data/adb/asb/v56_resurrect_sweep_done 2>/dev/null
elif [ -f /data/adb/asb/v56_learning_reset_done ] && [ ! -f /data/adb/asb/v56_resurrect_sweep_done ]; then
  rm -f /data/adb/asb/buckets.bin /data/adb/asb/buckets.bin.bak \
        /data/adb/asb/pstats_balanced.json /data/adb/asb/pstats_battery.json \
        /data/adb/asb/smart_appheat.bin /data/adb/asb/auto_battery_state 2>/dev/null
  : > /data/adb/asb/v56_resurrect_sweep_done 2>/dev/null
fi

[ -r "$MODDIR/runtime/asb_utils.sh" ]   && . "$MODDIR/runtime/asb_utils.sh"
[ -r "$MODDIR/runtime/profile_core.sh" ] && . "$MODDIR/runtime/profile_core.sh"
[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"
ASB_STATE_LOG="/dev/.asb_profile_state/runtime_apply.log"
asb_log(){ echo "[$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo now)] $*" >> "$ASB_STATE_LOG" 2>/dev/null || true; }

if [ -r /data/adb/asb/active_profile ]; then
  _saved_profile="$(cat /data/adb/asb/active_profile 2>/dev/null)"
  case "$_saved_profile" in
    battery|balanced|performance|smart)
      _current_profile="$(cat "$MODDIR/current_profile" 2>/dev/null)"
      if [ "$_saved_profile" != "$_current_profile" ]; then
        echo "$_saved_profile" > "$MODDIR/current_profile" 2>/dev/null
        asb_log "profile restored from active_profile: $_current_profile -> $_saved_profile"
      fi
      ;;
  esac
fi

# Smart Mode default-on for fresh installs; preserve previous behaviour for upgrades.
mkdir -p /data/adb/asb 2>/dev/null
if [ ! -f /data/adb/asb/smart_mode_enabled ]; then
  _prior_signs=0
  [ -r /data/adb/asb/active_profile ] && _prior_signs=1
  [ -r /data/adb/asb/user_config ] && _prior_signs=1
  [ -d /data/adb/asb/learn ] && _prior_signs=1
  [ -r /data/adb/asb/pstats_battery.json ] && _prior_signs=1
  [ -r /data/adb/asb/pstats_balanced.json ] && _prior_signs=1
  if [ "$_prior_signs" = "1" ]; then
    echo "0" > /data/adb/asb/smart_mode_enabled 2>/dev/null
    _cur_prof="$(cat "$MODDIR/current_profile" 2>/dev/null)"
    [ -z "$_cur_prof" ] && _cur_prof=balanced
    echo "$_cur_prof" > /data/adb/asb/smart_prev_profile 2>/dev/null
    asb_log "smart_migration: existing user state detected, smart_mode=off, prev_profile=$_cur_prof"
  else
    echo "1" > /data/adb/asb/smart_mode_enabled 2>/dev/null
    echo "balanced" > /data/adb/asb/smart_prev_profile 2>/dev/null
    echo "smart" > "$MODDIR/current_profile" 2>/dev/null
    echo "smart" > /data/adb/asb/active_profile 2>/dev/null
    asb_log "smart_migration: fresh install, smart_mode=on, current_profile=smart"
  fi
fi

asb_load_profile

rm -f /data/adb/asb/v45_cleanup_done /data/adb/asb/v46_athena_cleanup_done /data/adb/asb/session_history_migrated_v47 2>/dev/null

if [ ! -f /data/adb/asb/stale_props_cleaned ]; then
  for _stale_p in \
      persist.sys.oplus.athena.reclaim_enable \
      persist.sys.oplus.athena.force_kill \
      persist.sys.oplus.athena.limit_count \
      persist.sys.oplus.deepthinker.reclaim_hint \
      ro.audio.audiozoom \
      persist.bluetooth.spatial_audio_support; do
    if [ -n "$(getprop "$_stale_p" 2>/dev/null)" ]; then
      resetprop --delete "$_stale_p" >/dev/null 2>&1 || true
    fi
  done
  touch /data/adb/asb/stale_props_cleaned 2>/dev/null
fi

# Reset vm.oom_kill_allocating_task to kernel default (0) at every boot.
if [ -w /proc/sys/vm/oom_kill_allocating_task ]; then
  echo 0 > /proc/sys/vm/oom_kill_allocating_task 2>/dev/null || true
fi

command -v asb_update_desc >/dev/null 2>&1 && asb_update_desc 2>/dev/null

asb_migrate_governor_conf() {
  local _expected_schema=17
  local _conf_dir="$MODDIR/config"
  local _user_conf="$_conf_dir/governor.conf"
  local _shipped_conf="$_conf_dir/governor.conf.shipped"
  local _schema_marker="$_conf_dir/.schema_version"

  [ -f "$_user_conf" ] || return 0

  local _current_schema=0
  if [ -f "$_schema_marker" ]; then
    _current_schema="$(cat "$_schema_marker" 2>/dev/null || echo 0)"
    case "$_current_schema" in
      ''|*[!0-9]*) _current_schema=0 ;;
    esac
  fi

  if [ "$_current_schema" -ge "$_expected_schema" ]; then
    asb_log "config_migrate: schema=$_current_schema already current, skipping"
    return 0
  fi

  asb_log "config_migrate: schema=$_current_schema -> $_expected_schema, additive merge"

  if [ ! -f "$_shipped_conf" ]; then
    asb_log "config_migrate: WARN no governor.conf.shipped found, leaving existing config"
    echo "$_expected_schema" > "$_schema_marker" 2>/dev/null
    chmod 644 "$_schema_marker" 2>/dev/null || true
    return 0
  fi

  local _ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)"
  local _backup="$_user_conf.bak.schema${_current_schema}.${_ts}"
  if ! cp "$_user_conf" "$_backup" 2>/dev/null; then
    asb_log "config_migrate: WARN could not create backup at $_backup, aborting"
    return 1
  fi

  local _added=0 _kept=0
  local _tmp="$_user_conf.merge.$$"
  cp "$_user_conf" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }

  local _line _k
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      ''|\#*) continue ;;
      *=*) _k="${_line%%=*}" ;;
      *) continue ;;
    esac
    if grep -q "^[[:space:]]*${_k}=" "$_tmp" 2>/dev/null; then
      _kept=$((_kept + 1))
    else
      printf '%s\n' "$_line" >> "$_tmp"
      _added=$((_added + 1))
    fi
  done < "$_shipped_conf"

  if mv "$_tmp" "$_user_conf" 2>/dev/null; then
    chmod 644 "$_user_conf" 2>/dev/null || true
    asb_log "config_migrate: kept $_kept user values, added $_added new keys (backup: $_backup)"
  else
    rm -f "$_tmp" 2>/dev/null
    asb_log "config_migrate: WARN merge write failed, original preserved"
    return 1
  fi

  echo "$_expected_schema" > "$_schema_marker" 2>/dev/null
  chmod 644 "$_schema_marker" 2>/dev/null || true

  asb_log "config_migrate: complete, schema=$_expected_schema"
}
asb_migrate_governor_conf

# Refresh device facts at boot (read-only; rewrites /data/adb/asb/device_caps.env
# so it tracks kernel/topology changes between installs). Then re-derive the
# per-device bounds from those facts. Chained so synthesis sees the fresh caps;
# both are read-only and the governor only consumes device_bounds.env when
# device_bounds_override=1. Backgrounded so boot is not delayed.
(
  [ -f "$MODDIR/tools/asb_discover.sh" ] && sh "$MODDIR/tools/asb_discover.sh" >/dev/null 2>&1
  [ -f "$MODDIR/tools/asb_synthesize_bounds.sh" ] && sh "$MODDIR/tools/asb_synthesize_bounds.sh" >/dev/null 2>&1
  # Retire the interactive prime ceilings from any bounds file written by an earlier
  # build. The governor already refuses them, but this file lives in /data/adb/asb and
  # outlives module updates, and the diagnostics print it verbatim - left in place the
  # report would keep showing a prime cap that is not applied any more.
  if [ -f /data/adb/asb/device_bounds.env ] && \
     grep -qE '^(BALANCED|PERFORMANCE)_CPU_MAX_PRIME=' /data/adb/asb/device_bounds.env 2>/dev/null; then
    sed -i '/^BALANCED_CPU_MAX_PRIME=/d; /^PERFORMANCE_CPU_MAX_PRIME=/d' \
      /data/adb/asb/device_bounds.env 2>/dev/null
    asb_log "device_bounds: dropped retired interactive prime ceilings"
  fi
) &

(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done
  asb_feature_enabled SOTER_REPAIR || exit 0
  _soter_state="$(getprop init.svc.vendor.soter 2>/dev/null)"
  if [ -z "$_soter_state" ]; then
    asb_log "soter_repair: vendor.soter not declared on this device, skipping"
    exit 0
  fi
  _attempt=0
  _delays="1 5 30"
  for _d in $_delays; do
    _attempt=$((_attempt + 1))
    _state="$(getprop init.svc.vendor.soter 2>/dev/null)"
    if [ "$_state" = "running" ]; then
      asb_log "soter_repair: vendor.soter running, no action needed"
      break
    fi
    asb_log "soter_repair: attempt $_attempt — state=$_state, restarting"
    stop vendor.soter
    sleep 1
    start vendor.soter
    sleep "$_d"
    _state="$(getprop init.svc.vendor.soter 2>/dev/null)"
    if [ "$_state" = "running" ]; then
      asb_log "soter_repair: succeeded after attempt $_attempt"
      break
    fi
  done
  _final="$(getprop init.svc.vendor.soter 2>/dev/null)"
  [ "$_final" != "running" ] && asb_log "soter_repair: gave up after 3 attempts, final state=$_final"
) &

(
  _t=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_t" -lt 180 ]; do
    sleep 5
    _t=$((_t + 5))
  done
  if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    echo 0 > /data/adb/asb/vendor_boot_counter 2>/dev/null
    # Re-apply the /odm runtime binds. post-fs-data already tries this, but KernelSU mounts
    # its own module overlay on /odm AFTER post-fs-data runs, so that early bind gets
    # shadowed and the framework still reads the stock config (observed: the boot log said
    # action=boot, yet grep asb /odm/etc/audio_effects_config.xml stayed 0 until a manual
    # mount --bind). Binding again here - after the overlay is in place - sticks.
    if [ ! -f /data/adb/asb/vendor_overlay_blocked ] && [ -f /data/adb/asb/odm_bind_manifest.txt ]; then
      _rb_any=0
      while IFS='|' read -r _rb_t _rb_p; do
        case "$_rb_t" in ''|'#'*) continue ;; esac
        [ -f "$_rb_t" ] && [ -f "$_rb_p" ] || continue
        cmp -s "$_rb_t" "$_rb_p" 2>/dev/null && continue
        if command -v nsenter >/dev/null 2>&1 \
           && nsenter -t 1 -m -- mount --bind "$_rb_p" "$_rb_t" 2>/dev/null; then
          _rb_any=1
        elif mount --bind "$_rb_p" "$_rb_t" 2>/dev/null; then
          _rb_any=1
        fi
      done < /data/adb/asb/odm_bind_manifest.txt
      if [ "$_rb_any" = "1" ]; then
        echo "ts=$(date +%s) action=odm_bind_late result=applied" >> /data/adb/asb/vendor_mounts.log 2>/dev/null
        setprop ctl.restart audioserver 2>/dev/null || true
      fi
    fi
    # Launch the attacher daemon from OUR data dir (post-fs-data staged it there and made it
    # executable; the copy inside the module dir stays 0644 because the root manager resets
    # module file permissions after installation). This is what actually makes the DSP
    # audible on OxygenOS: the framework never applies the config's <postprocess> section
    # here - AudioPolicyEffects logs "no output processing needed" even for the stock
    # music_helper - so effects have to be created programmatically, exactly like ViperFX
    # and OPlus' own effect do.
    _att_bin="/data/adb/asb/asb_dsp_attach"
    if [ -f "$MODDIR/bin/asb_dsp_attach" ]; then
      mkdir -p /data/adb/asb 2>/dev/null
      # Refresh unconditionally. Copying only when the file was missing meant a rebuilt
      # daemon shipped in a module update never took effect - the stale binary from the
      # previous install stayed in /data/adb/asb and kept being launched.
      cp -f "$MODDIR/bin/asb_dsp_attach" "$_att_bin" 2>/dev/null
    fi
    if [ -f "$_att_bin" ]; then
      chmod 0755 "$_att_bin" 2>/dev/null
      pkill -f asb_dsp_attach 2>/dev/null
      sleep 1
      if [ -x "$_att_bin" ]; then
        nohup "$_att_bin" >> /data/adb/asb/dsp_attach.log 2>&1 &
        _att_how="direct"
      else
        # Last resort: hand the binary to the dynamic linker. That runs it without needing
        # the exec bit, covering a noexec mount or an SELinux label that forbids exec.
        nohup /system/bin/linker64 "$_att_bin" >> /data/adb/asb/dsp_attach.log 2>&1 &
        _att_how="linker64"
      fi
      echo "ts=$(date +%s) action=dsp_attach_started via=$_att_how" >> /data/adb/asb/vendor_mounts.log 2>/dev/null
      # Publish the vendor-namespace copies of the DSP properties the effect reads. This
      # uses "mirror", not "dsp": at this point in boot the overlay carrying libasbdsp.so
      # is not mounted yet, and the normal path would read that as "library missing" and
      # write enable=0, turning the DSP off on every boot.
      [ -f "$MODDIR/runtime/asb_audio_apply.sh" ] && \
        sh "$MODDIR/runtime/asb_audio_apply.sh" mirror >/dev/null 2>&1
    fi
  fi
) >/dev/null 2>&1 &

asb_device_guard() {
  local _soc
  _soc="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_soc" ] && _soc="$(getprop ro.hardware.chipname 2>/dev/null)"
  case "$_soc" in
    sun|sm8850*|pineapple) ASB_DEVICE_TIER="flagship" ;;
    taro|sm8550*|sm8650*|kalama|crow) ASB_DEVICE_TIER="high" ;;
    *) ASB_DEVICE_TIER="generic" ;;
  esac
  asb_log "device_guard: soc=$_soc tier=$ASB_DEVICE_TIER"
  [ "$ASB_DEVICE_TIER" = "generic" ] && \
    asb_log "device_guard: unknown SoC, conservative limits apply"
}

asb_probe_paths() {
  for _pp in \
    "policy0_max:/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq" \
    "policy6_max:/sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq" \
    "gpu_max:/sys/class/kgsl/kgsl-3d0/max_pwrlevel" \
    "vm_swappiness:/proc/sys/vm/swappiness" \
    "uclamp_topapp:/dev/cpuctl/top-app/cpu.uclamp.max"; do
    _label="${_pp%%:*}"; _path="${_pp#*:}"
    if [ ! -e "$_path" ]; then
      asb_log "probe: $_label MISSING"
    elif [ -w "$_path" ]; then
      asb_log "probe: $_label writable"
    else
      asb_log "probe: $_label read-only"
    fi
  done
}

asb_conflict_scan() {
  local _found=0 _mods="/data/adb/modules"
  for _m in "$_mods"/*/; do
    [ -f "$_m/disable" ] && continue
    [ "$(basename "$_m")" = "$MODID" ] && continue
    [ ! -f "$_m/module.prop" ] && continue
    local _name; _name="$(grep '^name=' "$_m/module.prop" 2>/dev/null | cut -d= -f2)"
    case "$_name" in *thermal*|*kernel*tuner*|*cpu*freq*|*governor*|*performance*tweak*)
      asb_log "conflict: potential overlap with $_name"; _found=$((_found+1)) ;;
    esac
    grep -ql "scaling_max_freq\|cpufreq" "$_m/service.sh" 2>/dev/null && \
      { asb_log "conflict: $_name may write cpufreq"; _found=$((_found+1)); }
  done
  [ $_found -eq 0 ] && asb_log "conflict: none detected"
}

asb_read_msm_perf_cap() {
  _cpu="$1"
  _path="/sys/kernel/msm_performance/parameters/cpu_max_freq"
  [ -r "$_path" ] || return 1
  awk -v cpu="$_cpu" '{
    for (i = 1; i <= NF; i++) {
      split($i, a, ":")
      if (a[1] == cpu) { print a[2]; exit }
    }
  }' "$_path" 2>/dev/null
}
asb_drift_check() {
  local _prof="$1"; [ -z "$_prof" ] && return 0
  sleep 1
  asb_load_profile

  # Caps are per-device PERCENTAGES now, not the absolute CPU_MAX_* in the
  for _dchk in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_dchk" ] || continue
    local _mn _mx
    _mn="$(cat "$_dchk/scaling_min_freq" 2>/dev/null)"
    _mx="$(cat "$_dchk/scaling_max_freq" 2>/dev/null)"
    [ -n "$_mn" ] && [ -n "$_mx" ] && [ "$_mn" -gt "$_mx" ] 2>/dev/null && \
      asb_log "drift(cpu): $(basename "$_dchk") min=${_mn} > max=${_mx}"
  done

  # Cap-drift comparison intentionally omitted: caps are per-device percents (and
  :
  local _gmin_path="/sys/class/kgsl/kgsl-3d0/devfreq/min_freq"
  local _gmax_path="/sys/class/kgsl/kgsl-3d0/devfreq/max_freq"
  if [ -r "$_gmin_path" ] && [ -r "$_gmax_path" ]; then
    local _gmin _gmax
    _gmin="$(cat "$_gmin_path" 2>/dev/null)"
    _gmax="$(cat "$_gmax_path" 2>/dev/null)"
    [ -n "$_gmin" ] && [ -n "$_gmax" ] && [ "$_gmin" -gt "$_gmax" ] 2>/dev/null &&       asb_log "drift(gpu): min_freq=${_gmin} > max_freq=${_gmax}"
  fi
}

asb_device_guard
asb_probe_paths
asb_conflict_scan

# ASB:CPU:BEGIN
KREL="$(uname -r 2>/dev/null)"
IS_WILD=0
echo "$KREL" | grep -qi "wild" && IS_WILD=1
cpu_present="$(cat /sys/devices/system/cpu/present 2>/dev/null | tr -d '\n')"
cpu_max="7"
case "$cpu_present" in
  *-*) cpu_max="${cpu_present##*-}" ;;
  *) cpu_max="$cpu_present" ;;
esac
[ -n "$cpu_max" ] || cpu_max="7"
N=$((cpu_max + 1))
_ref_freq="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)"
_big_start="$N"
if [ -n "$_ref_freq" ]; then
  _i=1
  while [ $_i -le $cpu_max ]; do
    _f="$(cat /sys/devices/system/cpu/cpu${_i}/cpufreq/cpuinfo_max_freq 2>/dev/null)"
    if [ -n "$_f" ] && [ "$_f" != "$_ref_freq" ]; then
      _big_start=$_i
      break
    fi
    _i=$((_i + 1))
  done
fi
[ "$_big_start" -ge "$N" ] && _big_start=$((N / 2))
[ "$_big_start" -lt 2 ] && _big_start=2
little_end=$((_big_start - 1))
LITTLE_POLICY="/sys/devices/system/cpu/cpufreq/policy0"
BIG_POLICY="/sys/devices/system/cpu/cpufreq/policy${_big_start}"
[ -d "$BIG_POLICY" ] || BIG_POLICY="$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | sort -t'y' -k2 -n | tail -1)"
[ -d "$BIG_POLICY" ] || BIG_POLICY="$LITTLE_POLICY"
apply_cpuset_groups() {
  writef_retry /dev/cpuset/background/cpus        "0-${little_end}" 3 0.25 || true
  writef_retry /dev/cpuset/system-background/cpus "0-${little_end}" 3 0.25 || true
  if [ "$ASB_PROFILE" = "battery" ]; then
    writef_retry /dev/cpuset/foreground/cpus      "0-${little_end}" 3 0.25 || true
    writef_retry /dev/cpuset/top-app/cpus         "0-${little_end}" 3 0.25 || true
  else
    writef_retry /dev/cpuset/foreground/cpus      "0-${cpu_max}" 3 0.25 || true
    writef_retry /dev/cpuset/top-app/cpus         "0-${cpu_max}" 3 0.25 || true
  fi
}
apply_cpuset_groups_all() {
  for _cg_root in /dev/cpuset /sys/fs/cgroup; do
    [ -d "$_cg_root" ] || continue
    _bg="0-${little_end}"
    _fg="0-${cpu_max}"
    if [ "$ASB_PROFILE" = "battery" ]; then
      _fg="0-${little_end}"
    fi
    for _grp in background system-background; do
      [ -e "$_cg_root/$_grp/cpus" ] && writef_retry "$_cg_root/$_grp/cpus" "$_bg" 5 0.3 || true
      [ -e "$_cg_root/$_grp/cpuset.cpus" ] && writef_retry "$_cg_root/$_grp/cpuset.cpus" "$_bg" 5 0.3 || true
    done
    for _grp in foreground top-app; do
      [ -e "$_cg_root/$_grp/cpus" ] && writef_retry "$_cg_root/$_grp/cpus" "$_fg" 5 0.3 || true
      [ -e "$_cg_root/$_grp/cpuset.cpus" ] && writef_retry "$_cg_root/$_grp/cpuset.cpus" "$_fg" 5 0.3 || true
    done
  done
}
apply_uclamp() {
  writef_retry /dev/cpuctl/top-app/uclamp.latency_sensitive $_P_LATENCY_SENSITIVE 5 0.3 || true
  writef_retry /dev/cpuctl/background/cpu.uclamp.min        $_P_UCL_BG  5 0.3 || true
  writef_retry /dev/cpuctl/system-background/cpu.uclamp.min $_P_UCL_BG  5 0.3 || true
  writef_retry /dev/cpuctl/foreground/cpu.uclamp.min        $_P_UCL_FG 5 0.3 || true
  writef_retry /dev/cpuctl/top-app/cpu.uclamp.min           $_P_UCL_TOP 5 0.3 || true
  _ucl_bg_max="${UCL_BG_MAX:-40}"
  _ucl_fg_max="${UCL_FG_MAX:-70}"
  _ucl_top_max="${UCL_TOP_MAX:-85}"
  writef_retry /dev/cpuctl/background/cpu.uclamp.max        $_ucl_bg_max 5 0.3 || true
  writef_retry /dev/cpuctl/system-background/cpu.uclamp.max $_ucl_bg_max 5 0.3 || true
  writef_retry /dev/cpuctl/foreground/cpu.uclamp.max        $_ucl_fg_max 5 0.3 || true
  writef_retry /dev/cpuctl/top-app/cpu.uclamp.max           $_ucl_top_max 5 0.3 || true
  writef_retry /dev/cpuctl/background/uclamp.min        $_P_UCL_BG  5 0.3 || true
  writef_retry /dev/cpuctl/system-background/uclamp.min $_P_UCL_BG  5 0.3 || true
  writef_retry /dev/cpuctl/foreground/uclamp.min        $_P_UCL_FG 5 0.3 || true
  writef_retry /dev/cpuctl/top-app/uclamp.min           $_P_UCL_TOP 5 0.3 || true
  for _cg_root in /sys/fs/cgroup /dev/cgroup; do
    [ -d "$_cg_root" ] || continue
    for _tier in background system-background foreground top-app; do
      _uval=$_P_UCL_BG
      [ "$_tier" = "foreground" ] && _uval=$_P_UCL_FG
      [ "$_tier" = "top-app" ]    && _uval=$_P_UCL_TOP
      _node="$_cg_root/$_tier/cpu.uclamp.min"
      [ -f "$_node" ] && writef_retry "$_node" "$_uval" 5 0.3 || true
      _mnode="$_cg_root/$_tier/cpu.uclamp.max"
      _mval=$_ucl_bg_max
      [ "$_tier" = "foreground" ] && _mval=$_ucl_fg_max
      [ "$_tier" = "top-app" ] && _mval=$_ucl_top_max
      [ -f "$_mnode" ] && writef_retry "$_mnode" "$_mval" 5 0.3 || true
    done
    _lat="$_cg_root/top-app/cpu.uclamp.latency_sensitive"
    [ -f "$_lat" ] && writef_retry "$_lat" $_P_LATENCY_SENSITIVE 5 0.3 || true
  done
}
wait_path /dev/cpuset/background/cpus 8 || true
wait_path /dev/cpuctl/top-app 8 || true
asb_feature_enabled CPU && apply_uclamp
if asb_feature_enabled CPU; then
  apply_cpuset_groups
  apply_cpuset_groups_all
fi
apply_cpugov_hints() {
  _rate="${SCHED_RATE:-3000}"
  _up_rate="${SCHED_UP_RATE:-1200}"
  _down_rate="${SCHED_DOWN_RATE:-4000}"
  _hispeed="${SCHED_HISPEED_LOAD:-88}"
  for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol" ] || continue
    [ -w "$_pol/schedutil/rate_limit_us" ] && writef_retry "$_pol/schedutil/rate_limit_us" "$_rate" 3 0.2 || true
    [ -w "$_pol/schedutil/up_rate_limit_us" ] && writef_retry "$_pol/schedutil/up_rate_limit_us" "$_up_rate" 3 0.2 || true
    [ -w "$_pol/schedutil/down_rate_limit_us" ] && writef_retry "$_pol/schedutil/down_rate_limit_us" "$_down_rate" 3 0.2 || true
    [ -w "$_pol/schedutil/hispeed_load" ] && writef_retry "$_pol/schedutil/hispeed_load" "$_hispeed" 3 0.2 || true
    [ -w "$_pol/schedutil/hispeed_freq" ] && [ -n "$SCHED_HISPEED_FREQ" ] && writef_retry "$_pol/schedutil/hispeed_freq" "$SCHED_HISPEED_FREQ" 3 0.2 || true
  done
}
asb_feature_enabled CPU && apply_cpugov_hints
# ASB:CPU:END
if has pm; then
  if command -v asb_pm_disable >/dev/null 2>&1; then
    asb_pm_disable com.android.traceur
  else
    asb_pm_disable com.android.traceur
  fi
fi
# ASB:VM:BEGIN
apply_vm() {
  sysctlw vm.swappiness $_P_SWAP
  if [ -e /proc/sys/vm/dirty_bytes ] && [ -e /proc/sys/vm/dirty_background_bytes ]; then
    sysctlw vm.dirty_ratio 0
    sysctlw vm.dirty_background_ratio 0
    case "$ASB_PROFILE" in
      performance)
        sysctlw vm.dirty_bytes 33554432
        sysctlw vm.dirty_background_bytes 8388608 ;;
      battery)
        sysctlw vm.dirty_bytes 134217728
        sysctlw vm.dirty_background_bytes 33554432 ;;
      *)
        sysctlw vm.dirty_bytes 67108864
        sysctlw vm.dirty_background_bytes 16777216 ;;
    esac
  else
    case "$ASB_PROFILE" in
      performance) sysctlw vm.dirty_ratio 5; sysctlw vm.dirty_background_ratio 2 ;;
      battery) sysctlw vm.dirty_ratio 40; sysctlw vm.dirty_background_ratio 10 ;;
      *) sysctlw vm.dirty_ratio 20; sysctlw vm.dirty_background_ratio 5 ;;
    esac
  fi
  sysctlw vm.dirty_expire_centisecs $_P_DEXP
  sysctlw vm.dirty_writeback_centisecs $_P_DWB
  sysctlw vm.vfs_cache_pressure $_P_VFS

  if [ -e /proc/sys/vm/compaction_proactiveness ]; then
    case "$ASB_PROFILE" in
      performance) sysctlw vm.compaction_proactiveness 0 ;;
      battery)     sysctlw vm.compaction_proactiveness 20 ;;
      *)           sysctlw vm.compaction_proactiveness 10 ;;
    esac
  fi

  [ -w /sys/kernel/mm/lru_gen/enabled ] && echo 7 > /sys/kernel/mm/lru_gen/enabled 2>/dev/null

  [ -e /proc/sys/vm/stat_interval ] && sysctlw vm.stat_interval $_P_STATINT
  case "$ASB_PROFILE" in
    performance) writef_retry /proc/sys/vm/page-cluster 0 1 0 || true ;;
    battery) writef_retry /proc/sys/vm/page-cluster 3 1 0 || true ;;
    *) writef_retry /proc/sys/vm/page-cluster 1 1 0 || true ;;
  esac
  sysctlw vm.watermark_scale_factor $_P_WMARK
  sysctlw vm.min_free_kbytes $_P_MINFREE
  # Do not set vm.oom_kill_allocating_task=1 (see boot-time reset above): it
  if [ "$ASB_PROFILE" = "battery" ]; then
    [ -e /proc/sys/vm/drop_caches ] || true
    [ -e /proc/sys/vm/laptop_mode ] && sysctlw vm.laptop_mode 1 || true
    [ -e /proc/sys/vm/block_dump ] && writef_retry /proc/sys/vm/block_dump 0 1 0 || true
  else
    [ -e /proc/sys/vm/laptop_mode ] && sysctlw vm.laptop_mode 0 || true
  fi
}
asb_feature_enabled VM && apply_vm
# ASB:VM:END
sysctl_try() {
  k="$1"; shift
  p="/proc/sys/$(echo "$k" | tr . /)"
  avail=""
  if [ "$k" = "net.ipv4.tcp_congestion_control" ] && [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
    avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
  fi
  for v in "$@"; do
    if [ -n "$avail" ]; then
      echo "$avail" | grep -qw "$v" || continue
    fi
    if has sysctl; then
      sysctl -w "${k}=${v}" >/dev/null 2>&1 && return 0
    fi
    [ -e "$p" ] || return 0
    echo "$v" > "$p" 2>/dev/null && return 0
  done
  return 0
}
# ASB:NET:BEGIN
apply_net() {
  sysctl_try net.core.default_qdisc fq_codel fq pfifo_fast
  if [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
    _cc_avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    if echo "$_cc_avail" | grep -qw bbr; then
      sysctlw net.ipv4.tcp_congestion_control bbr
      [ -e /proc/sys/net/ipv6/tcp_congestion_control ] && sysctlw net.ipv6.tcp_congestion_control bbr
    elif echo "$_cc_avail" | grep -qw cubic; then
      sysctlw net.ipv4.tcp_congestion_control cubic
      [ -e /proc/sys/net/ipv6/tcp_congestion_control ] && sysctlw net.ipv6.tcp_congestion_control cubic
    else
      :
    fi
  else
    sysctl_try net.ipv4.tcp_congestion_control bbr cubic reno
    [ -e /proc/sys/net/ipv6/tcp_congestion_control ] && sysctl_try net.ipv6.tcp_congestion_control bbr cubic reno
  fi
  case "$ASB_PROFILE" in
    performance) _pca=160; _pss=240 ;;
    battery)     _pca=80;  _pss=110 ;;
    *)           _pca=110; _pss=170 ;;
  esac
  sysctlw net.ipv4.tcp_pacing_ca_ratio $_pca
  sysctlw net.ipv4.tcp_pacing_ss_ratio $_pss
  [ -e /proc/sys/net/ipv6/tcp_ecn ] && sysctlw net.ipv6.tcp_ecn 0
  [ -e /proc/sys/net/ipv6/tcp_rmem ] && sysctlw net.ipv6.tcp_rmem "$_P_TCP_RMEM"
  [ -e /proc/sys/net/ipv6/tcp_wmem ] && sysctlw net.ipv6.tcp_wmem "$_P_TCP_WMEM"
  sysctlw net.ipv4.tcp_moderate_rcvbuf 1
  sysctlw net.ipv4.tcp_rmem "$_P_TCP_RMEM"
  sysctlw net.ipv4.tcp_wmem "$_P_TCP_WMEM"
  sysctlw net.core.rmem_max "$NET_RMEM_MAX"
  sysctlw net.core.wmem_max "$NET_WMEM_MAX"
  sysctlw net.core.optmem_max "$NET_OPTMEM_MAX"
  sysctlw net.ipv4.tcp_fastopen $_P_TCP_FASTOPEN
  sysctlw net.ipv4.tcp_sack 1
  sysctlw net.ipv4.tcp_dsack 1
  sysctlw net.ipv4.tcp_window_scaling 1
  sysctlw net.ipv4.tcp_timestamps 1
  sysctlw net.ipv4.tcp_ecn 0
  sysctlw net.ipv4.tcp_early_retrans 3
  [ -e /proc/sys/net/ipv4/tcp_notsent_lowat ] && sysctlw net.ipv4.tcp_notsent_lowat $_P_TCP_NOTSENT
  sysctlw net.ipv4.udp_rmem_min 65536
  sysctlw net.ipv4.udp_wmem_min 65536
  [ -e /proc/sys/net/ipv6/udp_rmem_min ] && sysctlw net.ipv6.udp_rmem_min 65536
  [ -e /proc/sys/net/ipv6/udp_wmem_min ] && sysctlw net.ipv6.udp_wmem_min 65536
  sysctlw net.ipv4.tcp_mtu_probing "$_P_TCP_MTU_PROBING"
  sysctlw net.ipv4.tcp_slow_start_after_idle 0
  sysctlw net.ipv4.tcp_recovery 1
  sysctlw net.ipv4.tcp_retrans_collapse 0
  sysctlw net.ipv4.tcp_max_orphans 8192
  sysctlw net.ipv4.tcp_rfc1337 1
  [ -n "$_P_UDP_MEM" ] && [ -e /proc/sys/net/ipv4/udp_mem ] && sysctlw net.ipv4.udp_mem "$_P_UDP_MEM"
  [ -n "$_P_HAPPY_EYEBALLS" ] && asb_settings_put system cloud_dns_happy_eyeballs_priority_enabled "$_P_HAPPY_EYEBALLS"
  sysctlw net.ipv4.tcp_keepalive_time   $_P_TCP_KEEPIDLE
  sysctlw net.ipv4.tcp_keepalive_intvl  75
  sysctlw net.ipv4.tcp_keepalive_probes 9
  sysctlw net.ipv4.tcp_fin_timeout          $_P_TCP_FIN
  sysctlw net.ipv4.tcp_no_metrics_save 1
  sysctlw net.core.somaxconn 512
  sysctlw net.ipv4.tcp_max_syn_backlog 2048
  sysctlw net.core.netdev_max_backlog $_P_NET_BACKLOG
  sysctlw net.core.netdev_budget $_P_NET_BUDGET
  sysctlw net.core.netdev_budget_usecs $_P_NET_BUDGET_US
  sysctlw net.core.dev_weight $_P_DEV_WEIGHT
  sysctlw net.core.bpf_jit_enable 1
  sysctlw net.core.bpf_jit_harden 0
  sysctlw net.core.bpf_jit_kallsyms 1
  [ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established ] && \
  sysctlw net.netfilter.nf_conntrack_tcp_timeout_established 600
  [ -e /proc/sys/net/netfilter/nf_conntrack_buckets ] && \
  sysctlw net.netfilter.nf_conntrack_buckets 16384
  [ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait ] && \
  sysctlw net.netfilter.nf_conntrack_tcp_timeout_time_wait 30
  [ -e /proc/sys/net/netfilter/nf_conntrack_max ] && \
  sysctlw net.netfilter.nf_conntrack_max 65536
  [ -e /proc/sys/net/core/tstamp_allow_data ] && \
  sysctlw net.core.tstamp_allow_data 1
  sysctlw net.ipv4.ip_no_pmtu_disc 0
  sysctlw net.ipv4.tcp_syncookies 1
  sysctlw net.ipv4.tcp_rfc1337 1
  sysctlw net.ipv4.conf.all.rp_filter 0
  sysctlw net.ipv4.conf.default.rp_filter 0
  sysctlw net.ipv4.ip_nonlocal_bind 1
  [ -e /proc/sys/net/ipv6/ip_nonlocal_bind ] && sysctlw net.ipv6.ip_nonlocal_bind 1
  sysctlw net.ipv4.conf.all.accept_redirects 0
  sysctlw net.ipv4.conf.all.send_redirects 0
  sysctlw net.ipv4.conf.all.secure_redirects 0
  sysctlw net.ipv4.icmp_echo_ignore_broadcasts 1
  sysctlw net.ipv4.icmp_ignore_bogus_error_responses 1
  [ -e /proc/sys/net/ipv6/conf/all/accept_redirects ] && \
    sysctlw net.ipv6.conf.all.accept_redirects 0
  [ -e /proc/sys/net/ipv6/conf/all/accept_ra ] && \
    sysctlw net.ipv6.conf.all.accept_ra 2
  [ -e /proc/sys/net/ipv6/conf/all/accept_ra_mtu ] && \
    sysctlw net.ipv6.conf.all.accept_ra_mtu 1
  [ -e /proc/sys/net/ipv6/conf/default/accept_ra_mtu ] && \
    sysctlw net.ipv6.conf.default.accept_ra_mtu 1
  [ -e /proc/sys/net/ipv6/conf/all/use_tempaddr ] && \
    sysctlw net.ipv6.conf.all.use_tempaddr 2
  [ -e /proc/sys/net/ipv6/conf/default/use_tempaddr ] && \
    sysctlw net.ipv6.conf.default.use_tempaddr 2
  [ -e /proc/sys/net/ipv6/icmp/echo_ignore_anycast ] && \
    sysctlw net.ipv6.icmp.echo_ignore_anycast 1
  [ -e /proc/sys/net/ipv6/icmp/echo_ignore_multicast ] && \
    sysctlw net.ipv6.icmp.echo_ignore_multicast 1
  [ -e /proc/sys/net/ipv6/conf/all/proxy_ndp ] && \
    sysctlw net.ipv6.conf.all.proxy_ndp 1
  sysctlw net.ipv4.conf.all.accept_source_route 0
  [ -e /proc/sys/net/ipv6/conf/all/accept_source_route ] && \
    sysctlw net.ipv6.conf.all.accept_source_route 0
  sysctlw net.ipv4.neigh.default.gc_thresh1 128
  sysctlw net.ipv4.neigh.default.gc_thresh2 512
  sysctlw net.ipv4.neigh.default.gc_thresh3 1024
  [ -e /proc/sys/net/ipv6/neigh/default/gc_thresh1 ] && \
    sysctlw net.ipv6.neigh.default.gc_thresh1 128
  [ -e /proc/sys/net/ipv6/neigh/default/gc_thresh2 ] && \
    sysctlw net.ipv6.neigh.default.gc_thresh2 512
  [ -e /proc/sys/net/ipv6/neigh/default/gc_thresh3 ] && \
    sysctlw net.ipv6.neigh.default.gc_thresh3 1024
}
asb_feature_enabled NET && apply_net
# ASB:NET:END
apply_wifi_settings() {
  has settings || return 0
  asb_settings_put global nearby_scanning_enabled 0
  asb_settings_put global wifi_scan_throttle_enabled 1
  asb_settings_put global wifi_suspend_optimizations_enabled 1
  asb_settings_put global wifi_verbose_logging_enabled 0
}
asb_feature_enabled WIFI && apply_wifi_settings
asb_wifi_cc_heal() {
  # One-time heal: older versions ran `force-country-code enabled IT`, which
  if [ -f /data/adb/asb/wifi_cc_forced ]; then
    has cmd && cmd -w wifi force-country-code disabled >/dev/null 2>&1 || true
    rm -f /data/adb/asb/wifi_cc_forced 2>/dev/null || true
  fi
}
asb_wifi_cc_heal

apply_wifi_country() {
  # Country from SIM then operator; only a confident 2-letter ISO code. We set
  _cc=""
  for _p in gsm.sim.operator.iso-country gsm.operator.iso-country; do
    _v="$(getprop "$_p" 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
    case "$_v" in [A-Z][A-Z]) _cc="$_v"; break ;; esac
  done
  [ -n "$WIFI_COUNTRY" ] && _cc="$WIFI_COUNTRY"   # explicit user override
  [ -n "$_cc" ] || return 0                        # none -> leave it to the modem

  has settings && {
    asb_settings_put global wifi_country_code "$_cc"
  }
}
asb_feature_enabled WIFI && apply_wifi_country
apply_wlan0_txqlen() {
  [ -e /sys/class/net/wlan0/tx_queue_len ] || return 0
  _want="${_P_WLAN_TXQLEN:-768}"
  _txq="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
  [ "$_txq" = "$_want" ] && return 0
  echo $_want > /sys/class/net/wlan0/tx_queue_len 2>/dev/null || true
  ip link set wlan0 txqueuelen $_want >/dev/null 2>&1 || true
}
asb_feature_enabled WIFI && apply_wlan0_txqlen
netif_oper_upish() {
  _if="$1"
  [ -n "$_if" ] || return 1
  [ -r "/sys/class/net/$_if/operstate" ] || return 0
  _st="$(cat "/sys/class/net/$_if/operstate" 2>/dev/null)"
  case "$_st" in
    up|dormant|unknown) return 0 ;;
  esac
  return 1
}
netif_carrier_upish() {
  _if="$1"
  [ -n "$_if" ] || return 0
  [ -r "/sys/class/net/$_if/carrier" ] || return 0
  [ "$(cat "/sys/class/net/$_if/carrier" 2>/dev/null)" = "1" ]
}
netif_qdisc_kind() {
  _if="$1"
  has tc || return 1
  [ -n "$_if" ] || return 1
  tc qdisc show dev "$_if" 2>/dev/null | awk 'NR==1{print $2}'
}
apply_netif_qdisc() {
  _if="$1"
  has tc || return 0
  [ -n "$_if" ] || return 0
  ip link show "$_if" >/dev/null 2>&1 || return 0
  netif_oper_upish "$_if" || return 0
  netif_carrier_upish "$_if" || return 0
  _qk="$(netif_qdisc_kind "$_if")"
  case "$_qk" in
    fq_codel|fq) return 0 ;;
    mq)
      tc qdisc show dev "$_if" 2>/dev/null | while read -r line; do
        _parent="$(echo "$line" | grep -oE 'parent [0-9a-f]+:[0-9a-f]+' | awk '{print $2}')"
        [ -n "$_parent" ] || continue
        tc qdisc replace dev "$_if" parent "$_parent" fq_codel >/dev/null 2>&1 || true
      done
      return 0
      ;;
  esac
  tc qdisc replace dev "$_if" root fq_codel >/dev/null 2>&1 || \
    tc qdisc replace dev "$_if" root fq >/dev/null 2>&1 || true
}
apply_wlan0_qdisc() {
  if has tc && ip link show wlan0 >/dev/null 2>&1; then
    if [ "$ASB_PROFILE" = "performance" ]; then
      tc qdisc replace dev wlan0 root $_P_QDISC >/dev/null 2>&1 || apply_netif_qdisc wlan0
    else
      tc qdisc replace dev wlan0 root $_P_QDISC >/dev/null 2>&1 || apply_netif_qdisc wlan0
    fi
  fi
}
apply_mobile_qdisc() {
  for _dev in /sys/class/net/*; do
    [ -e "$_dev" ] || continue
    _if="${_dev##*/}"
    case "$_if" in
      rmnet*|ccmni*)
        if has tc; then
          tc qdisc replace dev "$_if" root "$_P_QDISC" >/dev/null 2>&1 || apply_netif_qdisc "$_if"
        else
          apply_netif_qdisc "$_if"
        fi ;;

    esac
  done
}
asb_feature_enabled WIFI && apply_wlan0_qdisc
asb_feature_enabled NET && apply_mobile_qdisc
# ASB:WIFI:BEGIN
apply_wifi_pm() {
  wait_path /sys/class/net/wlan0 10 || return 0
  _wt=0
  while [ $_wt -lt 15 ]; do
    _wst="$(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
    case "$_wst" in up|dormant|unknown) break ;; esac
    sleep 1
    _wt=$((_wt+1))
  done
  case "$_P_WLAN_PM" in
    0)
      iw dev wlan0 set power_save off >/dev/null 2>&1 || true
      sleep 0.5
      iw dev wlan0 set power_save off >/dev/null 2>&1 || true
      writef_retry /sys/module/wlan/parameters/wlan_pm 0 4 0.5 || true
      asb_persist_safe persist.vendor.wlan.scan_throttle 0
      asb_persist_safe persist.vendor.wlan.powersave 0
      [ -e /sys/module/wlan/parameters/wlan_pm ] && writef_retry /sys/module/wlan/parameters/wlan_pm 0 6 0.5 || true
      ;;
    1)
      iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      sleep 0.5
      iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      writef_retry /sys/module/wlan/parameters/wlan_pm 1 4 0.5 || true
      asb_persist_safe persist.vendor.wlan.scan_throttle 1
      asb_persist_safe persist.vendor.wlan.powersave 1
      [ -e /sys/module/wlan/parameters/wlan_pm ] && writef_retry /sys/module/wlan/parameters/wlan_pm 1 6 0.5 || true
      ;;
    *)
      iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      writef_retry /sys/module/wlan/parameters/wlan_pm 1 3 0.25 || true
      asb_persist_safe persist.vendor.wlan.scan_throttle 1
      ;;
  esac
}
asb_feature_enabled WIFI && apply_wifi_pm
apply_wifi_dtim() {
  asb_has_risky_vendor_stack && return 0
  case "$ASB_PROFILE" in
    battery) iw dev wlan0 set listen-interval 10 >/dev/null 2>&1 || true ;;
    performance) iw dev wlan0 set listen-interval 2 >/dev/null 2>&1 || true ;;
    *) iw dev wlan0 set listen-interval 4 >/dev/null 2>&1 || true ;;
  esac
  writef_retry /sys/module/wlan/parameters/enable_connected_scan_result 0 3 0.25 || true
}
asb_feature_enabled WIFI && apply_wifi_dtim
apply_net_steering() {
  for q in /sys/class/net/wlan0/queues/rx-* /sys/class/net/rmnet*/queues/rx-*; do
    [ -d "$q" ] || continue
    [ -w "$q/rps_cpus" ] && echo fc > "$q/rps_cpus" 2>/dev/null || true
  done
  for q in /sys/class/net/wlan0/queues/tx-* /sys/class/net/rmnet*/queues/tx-*; do
    [ -d "$q" ] || continue
    [ -w "$q/xps_cpus" ] && echo fc > "$q/xps_cpus" 2>/dev/null || true
  done
}
asb_feature_enabled NET && apply_net_steering

# ASB:WIFI:END
(
  _skip_wlan_wait=0
  if has settings; then
    _wifi_on="$(settings get global wifi_on 2>/dev/null)"
    case "$_wifi_on" in
      0|disabled|false) _skip_wlan_wait=1 ;;
    esac
  fi
  t=0
  while [ $_skip_wlan_wait -eq 0 ] && [ $t -lt 120 ]; do
    [ -r /sys/class/net/wlan0/operstate ] || { sleep 2; t=$((t+2)); continue; }
    st="$(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
    case "$st" in
      up|dormant) break ;;
    esac
    sleep 2
    t=$((t+2))
  done
  for delay in 0 15; do
    [ $delay -gt 0 ] && sleep $delay
    asb_feature_enabled WIFI && apply_wlan0_txqlen
    asb_feature_enabled WIFI && apply_wlan0_qdisc
    q="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
    [ "$q" = "${_P_WLAN_TXQLEN:-1024}" ] && break
  done
) >/dev/null 2>&1 &
# ASB:GPS:BEGIN
apply_gps_hygiene() {
  has settings || return 0
  asb_settings_put global assisted_gps_enabled 1
  asb_settings_put global gps_xtra_server "https://xtra3.gpsonextra.net/xtra3grc.bin"
  asb_settings_put global gps_xtra_server_1 "https://xtra2.gpsonextra.net/xtra2.bin"
  asb_settings_put global gps_xtra_server_2 "https://xtra1.gpsonextra.net/xtra.bin"
  asb_settings_put global ntp_server time.google.com
  asb_settings_put global ntp_server_2 ntp1.inrim.it
  asb_settings_put global ntp_server_3 0.it.pool.ntp.org
  asb_settings_put global ntp_server_4 1.it.pool.ntp.org
}
asb_feature_enabled GPS && apply_gps_hygiene
# ASB:GPS:END
# ASB:AUDIO:BEGIN
apply_audio_runtime() {
  if [ "${AUDIO_EQ_COMPAT:-0}" = "1" ]; then
    setprop ro.audio.bt.connect.disable.mute true 2>/dev/null || true
    asb_persist_safe persist.audio.uhqa 0
    asb_persist_safe persist.vendor.audio.uhqa false
    setprop af.resampler.quality 0 2>/dev/null || true
    return
  fi
  asb_persist_safe persist.audio.hifi.int_codec true
  asb_persist_safe persist.vendor.audio.hifi.int_codec true
  setprop ro.audio.bt.connect.disable.mute true 2>/dev/null || true
  asb_persist_safe persist.vendor.audio.aec_ref.enable false
  setprop vendor.audio.feature.aec_ref.enable false 2>/dev/null || true

  if [ "${AUDIO_AGGRESSIVE:-0}" = "1" ]; then
    setprop ro.audio.hifi true 2>/dev/null || true
    setprop ro.vendor.audio.hifi true 2>/dev/null || true
    asb_persist_safe persist.audio.hifi true
    asb_persist_safe persist.vendor.audio.hifi true
    asb_persist_safe persist.audio.uhqa 1
    asb_persist_safe persist.vendor.audio.uhqa true
    asb_persist_safe persist.vendor.audio.power.save.setting 1
    setprop af.resampler.quality 255 2>/dev/null || true
    setprop audio.offload.min.duration.secs 20 2>/dev/null || true
    setprop vendor.audio.offload.min.duration.secs 20 2>/dev/null || true
    setprop audio.offload.buffer.size.kb 256 2>/dev/null || true
    setprop vendor.audio.offload.buffer.size.kb 256 2>/dev/null || true
  fi
}
asb_feature_enabled AUDIO && apply_audio_runtime
# ASB:AUDIO:END
resetprop -p --delete audio.hal.output.suspend.supported >/dev/null 2>&1 || true
resetprop -p --delete vendor.qc2audio.suspend.enabled    >/dev/null 2>&1 || true
resetprop --delete audio.hal.output.suspend.supported >/dev/null 2>&1 || true
resetprop --delete vendor.qc2audio.suspend.enabled    >/dev/null 2>&1 || true
# ASB:BG_TRIM:BEGIN

_BG_TRIM_NEVER="
com.android.systemui
com.android.launcher3
net.oneplus.launcher
com.oneplus.launcher
com.android.inputmethod.latin
com.google.android.inputmethod.latin
com.touchtype.swiftkey
com.android.dialer
com.google.android.dialer
com.oneplus.camera
com.oplus.camera
com.android.camera2
com.google.android.apps.maps
com.waze
"

_BG_TRIM_MESSENGER="
com.whatsapp
org.telegram.messenger
org.thunderdog.challegram
com.viber.voip
com.facebook.orca
com.facebook.mlite
com.discord
com.signal.android
org.thoughtcrime.securesms
com.skype.raider
com.tencent.mm
com.microsoft.teams
"

_BG_TRIM_RECENT_WORKSET="
com.adobe.lrmobile
com.adobe.photoshopmix
com.android.gallery3d
com.coloros.gallery3d
com.oneplus.gallery
com.google.android.apps.photos
com.spotify.music
com.aspiro.tidal
com.deezer.android.app
com.google.android.youtube.music
"

_BG_TRIM_HEAVY="
com.facebook.katana
com.instagram.android
com.snapchat.android
com.zhiliaoapp.musically
com.ss.android.ugc.trill
com.netflix.mediaclient
com.amazon.mShop.android.shopping
com.aliexpress.buyer
com.heytap.htms
com.heytap.pictorial
com.heytap.market
"

_BG_TRIM_DISABLE="
com.oplus.midas
com.oplus.olc
com.oplus.crashbox
com.oplus.logkit
"

asb_bg_trim_is_top() {
  local _pkg="$1"
  local _top
  _top=$(dumpsys activity activities 2>/dev/null \
    | grep -m1 'topResumedActivity\|mResumedActivity' \
    | grep -oE '[a-z][a-z0-9_.]+/[a-zA-Z0-9_.$]+' \
    | head -1 | cut -d/ -f1)
  [ "$_top" = "$_pkg" ]
}

asb_bg_trim_screen_off() {
  local _state
  _state=$(dumpsys power 2>/dev/null \
    | grep -m1 'mWakefulness=' | cut -d= -f2)
  case "$_state" in
    Asleep|Dozing) return 0 ;;
    *) return 1 ;;
  esac
}

asb_bg_trim_pkg() {
  local _pkg="$1" _level="$2"
  asb_bg_trim_is_top "$_pkg" && return 0
  local _pids
  _pids=$(pidof "$_pkg" 2>/dev/null)
  _pids="$_pids $(ps -A -o PID,NAME 2>/dev/null | awk -v p="$_pkg" \
    '$2==p || index($2, p":")==1 {print $1}' | tr '\n' ' ')"
  _pids=$(echo "$_pids" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
  [ -z "$_pids" ] && return 0
  local _pid
  for _pid in $_pids; do
    [ "$_pid" -gt 100 ] 2>/dev/null && \
      am send-trim-memory --user 0 "$_pid" "$_level" >/dev/null 2>&1
  done
}

asb_bg_trim_apply_buckets() {
  local _p
  for _p in $_BG_TRIM_MESSENGER; do
    am set-standby-bucket "$_p" active >/dev/null 2>&1 || true
  done
  for _p in $_BG_TRIM_RECENT_WORKSET; do
    am set-standby-bucket "$_p" working_set >/dev/null 2>&1 || true
  done
  for _p in $_BG_TRIM_HEAVY; do
    am set-standby-bucket "$_p" rare >/dev/null 2>&1 || true
  done
}

asb_bg_trim_apply_memcg() {
  [ -d /sys/fs/cgroup ] || return 0
  [ -e /sys/fs/cgroup/cgroup.controllers ] || return 0

  local _pkg _uid _path
  for _pkg in $_BG_TRIM_NEVER $_BG_TRIM_MESSENGER; do
    _uid=$(dumpsys package "$_pkg" 2>/dev/null \
      | grep -m1 'userId=' | cut -d= -f2 | tr -d ' ')
    case "$_uid" in ''|*[!0-9]*) continue ;; esac
    _path=/sys/fs/cgroup/uid_${_uid}
    [ -d "$_path" ] || continue
    [ -w "$_path/memory.low" ] && echo 67108864 > "$_path/memory.low" 2>/dev/null
  done

  for _pkg in $_BG_TRIM_HEAVY; do
    _uid=$(dumpsys package "$_pkg" 2>/dev/null \
      | grep -m1 'userId=' | cut -d= -f2 | tr -d ' ')
    case "$_uid" in ''|*[!0-9]*) continue ;; esac
    _path=/sys/fs/cgroup/uid_${_uid}
    [ -d "$_path" ] || continue
    [ -w "$_path/memory.high" ] && echo 268435456 > "$_path/memory.high" 2>/dev/null
  done
}

asb_bg_trim_oplus_tune() {
  :
}

asb_bg_trim_gms_wakelock_throttle() {
  has cmd || return 0
  cmd appops set com.google.android.gms RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || true
  cmd appops set com.google.android.gms WAKE_LOCK allow             >/dev/null 2>&1 || true
  cmd appops set com.google.android.googlequicksearchbox RUN_IN_BACKGROUND ignore >/dev/null 2>&1 || true
  cmd appops set com.google.android.gms PSEUDO_LOCATION_REPORTING ignore >/dev/null 2>&1 || true
  am set-standby-bucket com.google.android.gms working_set >/dev/null 2>&1 || true
  am set-standby-bucket com.google.android.googlequicksearchbox rare >/dev/null 2>&1 || true
  if command -v asb_settings_put >/dev/null 2>&1; then
    asb_settings_put global location_background_throttle_interval_ms 1800000
    asb_settings_put global location_background_throttle_proximity_alert_interval_ms 1800000
    # Full-day OP15 logs showed GMS activity-recognition (the
    # ALARM_WAKEUP_ACTIVITY_DETECTION alarm) as a top idle wakeup source —
    # second only to AOD. Lengthen its sampling interval so it polls far less
    # often in the background. This only relaxes how often activity is sampled,
    # it does NOT disable location; foreground requests are unaffected.
    asb_settings_put global activity_recognition_mode 0
    asb_settings_put global gms_activity_recognition_interval_ms 1800000
  fi
}

asb_bg_trim_reclaim_once() {
  local _p
  for _p in $_BG_TRIM_HEAVY; do
    asb_bg_trim_pkg "$_p" 40
  done
  if asb_bg_trim_screen_off; then
    for _p in $_BG_TRIM_RECENT_WORKSET; do
      asb_bg_trim_pkg "$_p" 20
    done
  fi
}

apply_bg_trim_runtime() {
  local _bg_level="${BG_TRIM_LEVEL:-safe}"

  local _p
  for _p in $_BG_TRIM_DISABLE; do
    if command -v asb_pm_disable >/dev/null 2>&1; then
      asb_pm_disable "$_p"
    else
      pm disable-user --user 0 "$_p" >/dev/null 2>&1 || true
    fi
  done

  stop vendor.oplus.hardware.cammidasservice-V1-service >/dev/null 2>&1 || true
  stop vendor.oplus.hardware.olc2-V3-service           >/dev/null 2>&1 || true

  # Stop debug/crash-dump/telemetry daemons that run in the background but serve
  # no purpose on a user's daily driver. These only collect logs/ramdumps for
  # developers; stopping them frees a little CPU/RAM and removes some wakeups.
  # All are safe to stop (they re-spawn on next boot if a stop didn't take, and
  # none are required for normal operation). Kept conservative — no system_server
  # or connectivity daemons here.
  for _svc in minidump minidump32 minidump64 qseelogd wlanramdumpcollector \
              mqsasd bootstat poweroff_charger_log mtdoopslog ostatsd \
              charge_logger cnss_diag tcpdump; do
    stop "$_svc" >/dev/null 2>&1 || true
  done

  if command -v asb_settings_put >/dev/null 2>&1; then
    asb_settings_put global wifi_scan_always_enabled 0
    asb_settings_put global wifi_wakeup_enabled 0
  else
    asb_settings_put global wifi_scan_always_enabled 0
    asb_settings_put global wifi_wakeup_enabled 0
  fi

  asb_bg_trim_oplus_tune

  asb_bg_trim_gms_wakelock_throttle

  asb_bg_trim_apply_buckets

  asb_bg_trim_apply_memcg

  asb_log "bg_trim: level=$_bg_level"

  if [ "$_bg_level" = "aggressive" ]; then
    ( sleep 30; asb_bg_trim_reclaim_once ) >/dev/null 2>&1 &

    (
      while : ; do
        sleep 21600
        asb_bg_trim_apply_buckets >/dev/null 2>&1
        if asb_bg_trim_screen_off; then
          asb_bg_trim_reclaim_once >/dev/null 2>&1
        fi
      done
    ) >/dev/null 2>&1 &
  fi
}

asb_feature_enabled BG_TRIM && apply_bg_trim_runtime

# ASB:BG_TRIM:END
apply_bt_runtime() {
  asb_persist_safe persist.bluetooth.a2dp_offload.disabled false
  asb_persist_safe persist.vendor.bluetooth.a2dp_offload.disabled false
  asb_persist_safe persist.bluetooth.a2dp.optional_codecs_enabled 1
  asb_persist_safe persist.vendor.bt.enable.swb true
  asb_persist_safe persist.vendor.qcom.bluetooth.aac_vbr_ctl.enabled true
  # LE Audio is deliberately NOT forced on here, to stay consistent with
  # system.prop (which had the LE Audio / profile / class_of_device forces removed
  # to fix classic-BLE watch pairing — Amazfit / T-Rex Ultra 2 via Zepp). In
  # practice the system.prop change alone fixes pairing, because the offending
  # keys are read early at BT-stack init; this late setprop ran after the stack
  # was already up. It is dropped anyway so the module never re-forces LE Audio
  # from any layer. A2DP codec quality for headphones is unaffected.
}
asb_feature_enabled BT && apply_bt_runtime
apply_camera_props_static() {
  # Camera prop layer. IMPORTANT REVERSAL: the known-good debug module that has
  _cp_plat="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_cp_plat" ] && _cp_plat="$(getprop ro.hardware.chipname 2>/dev/null)"
  has resetprop || return 0
  resetprop -n persist.camera.tnr.preview 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.tnr.video 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.tnr_cds 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.mfnr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.tnr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.tnr.preview 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.tnr.video 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.tnr_cds 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.mfnr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.hdr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.snapshot.disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.preview.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.dual_camera_sat 1 >/dev/null 2>&1 || true
  resetprop -n ro.vendor.audio.camera.bt.record.support true >/dev/null 2>&1 || true
  resetprop -n ro.vendor.audio.camera.loopback.support true >/dev/null 2>&1 || true
  resetprop -n ro.vendor.audio.camera.videorecord.gain true >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.hdr.enable 1 >/dev/null 2>&1 || true
  resetprop -n ro.camera.disableHeicUltraHDR false >/dev/null 2>&1 || true
  resetprop -n persist.camera.dcrf.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.isp.ltm_disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.jpeg.dumpqtable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.jpeg_burst 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.llnoise 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.ltmforseemore 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.max_prev.enable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.maxgain.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.llnoise 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.maxgain.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.ltmforseemore 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.picturesize.limit.enable false >/dev/null 2>&1 || true
  resetprop -n persist.camera.tn.disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.video.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.sys.camera.cameraservice.micompactmemory.enable true >/dev/null 2>&1 || true
  resetprop -n persist.sys.camera.ubwc.enabled 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.dual_camera_sat 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.eis.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.picturesize.limit.enable false >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.preview.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.snapshot.disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.video.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n ro.camera.disableJpegR false >/dev/null 2>&1 || true
  resetprop -n ro.camera.enableCompositeAPI0JpegR true >/dev/null 2>&1 || true
  resetprop -n ro.vendor.camera.use_srgb_gamma true >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.hfr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.video.hdr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.global.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.mct.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.sensor.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.iface.logs 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.isp.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.af.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.aec.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.awb.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.asd.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.afd.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.q3a.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.is.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.haf.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.pproc.debug.mask 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.cpp.debug.mask 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.c2d.debug.mask 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.imglib.logs 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.mmstill.logs 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.debug.enable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.kpi.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.cpp.duplicate_strip_dump 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.cpp.zoom.opt 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.eis.disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.fdvideo 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.opt_mode.video 2 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.smyuv.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.raw.zsl.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.zsl.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.multiframe.nr.enable 1 >/dev/null 2>&1 || true
  resetprop -n ro.camerax.extensions.enabled true >/dev/null 2>&1 || true
  resetprop -n vendor.camera.algo.jpeghwdecode 1 >/dev/null 2>&1 || true
  resetprop -n vendor.camera.algo.jpeghwencode 1 >/dev/null 2>&1 || true
  resetprop -n vendor.camera.picturesize.limit.enable false >/dev/null 2>&1 || true
  asb_log "camera props: applied static set (81 props)"
}
asb_feature_enabled CAMERA && apply_camera_props_static

apply_camera_runtime() {
  # Base camera props — safe on every device. The proven-working OP12 build set
  asb_persist_safe persist.camera.tnr.preview 1
  asb_persist_safe persist.camera.tnr.video 1
  asb_persist_safe persist.vendor.camera.hdr.enable 1
  asb_persist_safe persist.vendor.camera.eis.enable 1
  # OP15 (canoe) ONLY: video HDR, 4K60 EIS, Hasselblad/Explorer are OnePlus 15
  _cam_soc="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_cam_soc" ] && _cam_soc="$(getprop ro.hardware.chipname 2>/dev/null)"
  case "$_cam_soc" in
    canoe|sm8850*)
      asb_persist_safe persist.vendor.camera.video.hdr.enable 1
      asb_persist_safe persist.vendor.camera.video.4k60.eis.enable 1
      if has resetprop; then
        resetprop -n ro.vendor.oplus.camera.isSupportExplorer 1 >/dev/null 2>&1 || true
        resetprop -n ro.vendor.oplus.camera.isHasselbladCamera 1 >/dev/null 2>&1 || true
      fi
      ;;
  esac
}
asb_feature_enabled CAMERA && apply_camera_runtime
tune_io_queues() {
  for _b in /sys/block/sd* /sys/block/mmcblk* /sys/block/dm-*; do
    [ -d "$_b/queue" ] || continue
    [ -r "$_b/queue/rotational" ] && [ "$(cat "$_b/queue/rotational" 2>/dev/null)" = "1" ] && continue
    writef "$_b/queue/iostats" 0
    writef "$_b/queue/add_random" 0
    writef "$_b/queue/rq_affinity" 2
    case "$ASB_PROFILE" in
      performance)
        writef "$_b/queue/read_ahead_kb" 512
        [ -w "$_b/queue/nr_requests" ] && writef "$_b/queue/nr_requests" 256 || true ;;
      battery)
        writef "$_b/queue/read_ahead_kb" 64
        [ -w "$_b/queue/nr_requests" ] && writef "$_b/queue/nr_requests" 64 || true ;;
      *)
        writef "$_b/queue/read_ahead_kb" 128
        [ -w "$_b/queue/nr_requests" ] && writef "$_b/queue/nr_requests" 128 || true ;;
    esac
  done
}
# ASB:KERNEL:BEGIN
apply_kernel() {
  sysctlw kernel.perf_cpu_time_max_percent 25
  sysctlw kernel.sched_schedstats 0
  sysctlw kernel.timer_migration 0
  sysctlw kernel.panic 0
  sysctlw kernel.panic_on_oops 0
  sysctlw vm.panic_on_oom 0
  [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
  writef_retry /proc/sys/kernel/printk_devkmsg off 1 0 || true
  writef_retry /proc/sys/kernel/printk "3 4 1 7" 1 0 || true
  [ -e /proc/sys/kernel/printk_ratelimit ] && \
    sysctlw kernel.printk_ratelimit 1
  [ -e /proc/sys/kernel/printk_ratelimit_burst ] && \
    sysctlw kernel.printk_ratelimit_burst 5
  [ -e /proc/sys/vm/oom_dump_tasks ] && sysctlw vm.oom_dump_tasks 0
  [ -e /proc/sys/debug/exception-trace ] && \
    writef_retry /proc/sys/debug/exception-trace 0 1 0 || true
  [ -e /proc/sys/walt/sched_boost ] && \
    writef_retry /proc/sys/walt/sched_boost 0 1 0 || true
  [ -e /proc/sys/walt/sched_idle_enough ] && \
    writef_retry /proc/sys/walt/sched_idle_enough $_P_IDLE 1 0 || true
  [ -e /proc/sys/walt/sched_idle_enough_clust ] && \
    writef_retry /proc/sys/walt/sched_idle_enough_clust "$_P_IDLEC" 1 0 || true
  # NOTE: per-cluster scaling_min_freq is now set inside apply_cpufreq_caps
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct $_P_CLUT 1 0 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct_clust ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct_clust "$_P_CLUTC" 1 0 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_colocation ] && writef_retry /proc/sys/walt/sched_min_task_util_for_colocation $_P_COLOC 1 0 || true
  [ -e /proc/sys/walt/sched_busy_hyst_ns ] && writef_retry /proc/sys/walt/sched_busy_hyst_ns $_P_BHYST 1 0 || true
  [ -e /proc/sys/walt/sched_boost ] && writef_retry /proc/sys/walt/sched_boost $_P_SBOOST 1 0 || true
  [ -e /proc/sys/walt/sched_ravg_window_nr_ticks ] && writef_retry /proc/sys/walt/sched_ravg_window_nr_ticks $_P_RAVG 3 0.5 || true
  [ -e /proc/sys/walt/sched_pipeline_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_util_thres $_P_PIPE 1 0 || true
  [ -e /proc/sys/walt/sched_pipeline_non_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_non_special_task_util_thres $_P_PIPEN 1 0 || true
  [ -e /proc/sys/walt/sched_pipeline_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_special_task_util_thres $_P_PIPES 1 0 || true
  [ -e /proc/sys/walt/sched_ed_boost ] && writef_retry /proc/sys/walt/sched_ed_boost $_P_EDB 1 0 || true
  [ -e /proc/sys/walt/sched_topapp_weight_pct ] && writef_retry /proc/sys/walt/sched_topapp_weight_pct $_P_TOPW 1 0 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_boost ] && writef_retry /proc/sys/walt/sched_min_task_util_for_boost $_P_MINTB 1 0 || true
  case "$ASB_PROFILE" in
    battery)
      [ -e /proc/sys/kernel/sched_energy_aware ] && sysctlw kernel.sched_energy_aware 1 || true
      [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 2 || true
      [ -e /proc/sys/kernel/hrtimer_migration ] && writef_retry /proc/sys/kernel/hrtimer_migration 0 1 0 || true
      [ -e /proc/sys/kernel/timer_migration ] && sysctlw kernel.timer_migration 0 || true
      [ -e /proc/sys/walt/sched_conservative_pl ] && writef_retry /proc/sys/walt/sched_conservative_pl 1 1 0 || true
      [ -e /proc/sys/walt/sched_suppress_region2_cpus ] && writef_retry /proc/sys/walt/sched_suppress_region2_cpus 1 1 0 || true
      writef /sys/module/lpm_levels/parameters/sleep_disabled 0 || true
      [ -e /sys/module/lpm_levels/parameters/lpm_prediction ] &&         writef /sys/module/lpm_levels/parameters/lpm_prediction 1 || true
      [ -e /sys/module/printk/parameters/console_suspend ] && writef /sys/module/printk/parameters/console_suspend Y || true
      [ -e /proc/sys/kernel/printk_devkmsg ] && writef /proc/sys/kernel/printk_devkmsg ratelimit || true
      [ -e /proc/sys/vm/laptop_mode ] && writef /proc/sys/vm/laptop_mode 5 || true
      [ -e /sys/module/wakelock/parameters/debug ] && writef /sys/module/wakelock/parameters/debug 0 || true
      ;;
    performance)
      [ -e /proc/sys/kernel/sched_energy_aware ] && sysctlw kernel.sched_energy_aware 0 || true
      [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 8 || true
      [ -e /proc/sys/walt/sched_conservative_pl ] && writef_retry /proc/sys/walt/sched_conservative_pl 0 1 0 || true
      [ -e /proc/sys/walt/sched_suppress_region2_cpus ] && writef_retry /proc/sys/walt/sched_suppress_region2_cpus 0 1 0 || true
      ;;
    *)
      [ -e /proc/sys/kernel/sched_energy_aware ] && sysctlw kernel.sched_energy_aware 1 || true
      [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4 || true
      ;;
  esac
  tune_io_queues
}
asb_feature_enabled KERNEL && apply_kernel
apply_dsp_compute_boost() {
  [ -e /sys/module/cdsp_loader/parameters/cdsp_load_state ] && \
    writef /sys/module/cdsp_loader/parameters/cdsp_load_state 1 || true
  [ -e /sys/module/adsprpc/parameters/perf_v2 ] && \
    writef /sys/module/adsprpc/parameters/perf_v2 1 || true
  for d in /sys/devices/platform/soc/*remoteproc-cdsp/power \
           /sys/devices/platform/soc/*remoteproc-adsp/power \
           /sys/devices/platform/soc/*cdsp*/power \
           /sys/devices/platform/soc/*adsp*/power; do
    [ -d "$d" ] || continue
    [ -w "$d/control" ] && writef "$d/control" on 2>/dev/null || true
    if [ -w "$d/autosuspend_delay_ms" ]; then
      writef "$d/autosuspend_delay_ms" 2000 2>/dev/null
    fi
  done
}
asb_feature_enabled KERNEL && apply_dsp_compute_boost

# ASB:KERNEL:END
asb_freq_pick_pct() {
  _dir="$1"; _pct="$2"
  [ -d "$_dir" ] || return 1
  _max="$(cat "$_dir/cpuinfo_max_freq" 2>/dev/null)"
  [ -n "$_max" ] || return 1
  _target=$(( _max * _pct / 100 ))
  _avail="$_dir/scaling_available_frequencies"
  if [ -r "$_avail" ]; then
    _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | awk -v t="$_target" '$1<=t{v=$1} END{print v}')"
    [ -n "$_pick" ] || _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | head -1)"
  else
    _pick="$_target"
  fi
  [ -n "$_pick" ] && echo "$_pick"
}
asb_gpu_pick_pct() {
  _base="/sys/class/kgsl/kgsl-3d0/devfreq"
  [ -d "$_base" ] || return 1
  _max="$(cat "$_base/max_freq" 2>/dev/null)"
  [ -n "$_max" ] || return 1
  _target=$(( _max * $1 / 100 ))
  _avail="$_base/available_frequencies"
  if [ -r "$_avail" ]; then
    _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | awk -v t="$_target" '$1<=t{v=$1} END{print v}')"
    [ -n "$_pick" ] || _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | head -1)"
  else
    _pick="$_target"
  fi
  [ -n "$_pick" ] && echo "$_pick"
}
apply_gpu_caps() {
  _gbase="/sys/class/kgsl/kgsl-3d0/devfreq"
  # Primary path: devfreq frequency capping (OP13 Adreno 830 and any GPU that
  # populates devfreq/max_freq + available_frequencies).
  if [ -d "$_gbase" ] && [ -n "$(cat "$_gbase/max_freq" 2>/dev/null)" ] && [ -s "$_gbase/available_frequencies" ]; then
    _gmax="$(asb_gpu_pick_pct ${_P_GPU_MAX_PCT:-100})"
    [ -n "$_gmax" ] && writef_retry "$_gbase/max_freq" "$_gmax" 3 0.25 || true
    if [ "${_P_GPU_MIN_PCT:-0}" -gt 0 ] 2>/dev/null; then
      _gmin="$(asb_gpu_pick_pct ${_P_GPU_MIN_PCT})"
    else
      _gmin="$(cat "$_gbase/available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort -n | head -1)"
      [ -n "$_gmin" ] || _gmin="$(cat "$_gbase/min_freq" 2>/dev/null)"
    fi
    [ -n "$_gmin" ] && writef_retry "$_gbase/min_freq" "$_gmin" 3 0.25 || true
    return 0
  fi
  # Fallback: pwrlevel capping. OP15 Adreno 840 leaves devfreq freq nodes empty
  _pmax_node="/sys/class/kgsl/kgsl-3d0/max_pwrlevel"
  _nlvl="$(cat /sys/class/kgsl/kgsl-3d0/num_pwrlevels 2>/dev/null)"
  if [ -w "$_pmax_node" ] && [ -n "$_nlvl" ] && [ "$_nlvl" -gt 1 ] 2>/dev/null; then
    _floor_file="/data/adb/asb/gpu_pwrlevel_floor"
    if [ ! -f "$_floor_file" ]; then
      mkdir -p /data/adb/asb 2>/dev/null
      cat "$_pmax_node" 2>/dev/null > "$_floor_file" 2>/dev/null || true
    fi
    _vfloor="$(cat "$_floor_file" 2>/dev/null)"
    case "$_vfloor" in ''|*[!0-9]*) _vfloor=0 ;; esac
    _pct="${_P_GPU_MAX_PCT:-100}"
    [ "$_pct" -gt 100 ] 2>/dev/null && _pct=100
    [ "$_pct" -lt 1 ] 2>/dev/null && _pct=1
    _last=$(( _nlvl - 1 ))
    _lvl=$(( (100 - _pct) * _last / 100 ))
    # Clamp into [vendor_floor .. slowest]: never faster than the vendor cap.
    [ "$_lvl" -lt "$_vfloor" ] 2>/dev/null && _lvl="$_vfloor"
    [ "$_lvl" -gt "$_last" ] 2>/dev/null && _lvl="$_last"
    writef_retry "$_pmax_node" "$_lvl" 3 0.25 || true
  fi
}
apply_cpufreq_caps() {
  # Topology-aware capping. 2-cluster SoCs (OP15 canoe, OP13 sun) map cleanly to
  _pol_list="$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | sort -t'y' -k2 -n)"
  _pol_count="$(echo "$_pol_list" | grep -c .)"
  _top_pol="$(echo "$_pol_list" | tail -1)"
  _top_rel=0
  if [ -n "$_top_pol" ]; then
    _top_rel="$(cat "$_top_pol/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_top_rel" in ''|*[!0-9]*) _top_rel=0 ;; esac
  fi
  for _pol_dir in $_pol_list; do
    [ -d "$_pol_dir" ] || continue
    _smax="$_pol_dir/scaling_max_freq"
    [ -w "$_smax" ] || continue
    _rel="$(cat "$_pol_dir/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_rel" in ''|*[!0-9]*) _rel=0 ;; esac
    _is_mid=0
    if [ "$_pol_count" -ge 3 ] && [ "$_rel" -gt "$little_end" ] && [ "$_rel" -lt "$_top_rel" ]; then
      _is_mid=1
    fi
    # _P_CPUCAP_* are PERCENTS of this cluster's cpuinfo_max_freq (empty = no cap).
    if [ "$_rel" -le "$little_end" ]; then
      _pct="$_P_CPUCAP_L"
    else
      _pct="$_P_CPUCAP_B"
    fi
    if [ "$_is_mid" = "1" ] && [ -n "$_P_CPUCAP_L" ] && [ -n "$_P_CPUCAP_B" ]; then
      # MID cluster (the OP12 policy2 workhorse): cap halfway between the LITTLE
      _hi="$_P_CPUCAP_L"; [ "$_P_CPUCAP_B" -gt "$_hi" ] 2>/dev/null && _hi="$_P_CPUCAP_B"
      _pct="$(( _hi + (100 - _hi) / 2 ))"
    fi
    if [ -z "$_pct" ]; then
      # no cap for this tier — restore the cluster's full hardware ceiling.
      _want="$(cat "$_pol_dir/cpuinfo_max_freq" 2>/dev/null)"
    elif [ "$_pct" -ge 100 ] 2>/dev/null; then
      _want="$(cat "$_pol_dir/cpuinfo_max_freq" 2>/dev/null)"
    else
      _want="$(asb_freq_pick_pct "$_pol_dir" "$_pct")"
    fi
    if [ -n "$_want" ] && writef_retry "$_smax" "$_want" 3 0.25; then :; fi
    # Per-cluster min-freq floor (single owner, 4-cluster aware). little cluster
    _smin="$_pol_dir/scaling_min_freq"
    if [ -w "$_smin" ]; then
      if [ "$_rel" -le "$little_end" ]; then _minw="$CPU_MIN_LITTLE"; else _minw="$CPU_MIN_BIG"; fi
      if [ -n "$_minw" ]; then
        _minpick="$(asb_pick_nearest_freq "$_pol_dir" "$_minw" 2>/dev/null)"
        [ -z "$_minpick" ] && _minpick="$_minw"
        _curmax_now="$(cat "$_smax" 2>/dev/null)"
        if [ -n "$_curmax_now" ] && [ -n "$_minpick" ] && [ "$_minpick" -gt "$_curmax_now" ] 2>/dev/null; then
          _minpick="$_curmax_now"
        fi
        [ -n "$_minpick" ] && writef_retry "$_smin" "$_minpick" 3 0.25 || true
      fi
    fi
  done
}
# apply_cpufreq_caps must run ONLY via apply_screen_aware_caps, which first sets

asb_screen_on() {
  for _dp in /sys/kernel/oplus_display/panel_power_status               /sys/kernel/oplus_display/disp_on_notify; do
    [ -r "$_dp" ] || continue
    _dpv="$(cat "$_dp" 2>/dev/null)"
    case "$_dpv" in 1|on|ON) return 0 ;; 0|off|OFF) return 1 ;; esac
  done
  for _df in /sys/class/drm/card0-DSI-1/status /sys/class/drm/card0-DSI-2/status; do
    [ -r "$_df" ] || continue
    [ "$(cat "$_df" 2>/dev/null)" = "connected" ] && return 0
    return 1
  done
  for _bl in /sys/class/backlight/panel0-backlight/brightness               /sys/class/leds/lcd-backlight/brightness; do
    [ -r "$_bl" ] || continue
    _blv="$(cat "$_bl" 2>/dev/null)"
    [ "${_blv:-0}" -gt 0 ] 2>/dev/null && return 0
    return 1
  done
  dumpsys power 2>/dev/null | grep -q "mHoldingDisplaySuspendBlocker=true"
}
apply_screen_aware_caps() {
  asb_feature_enabled CPU || return 0
  asb_load_profile
  _son=0
  asb_screen_on && _son=1
  # Caps are PERCENT of each cluster's own cpuinfo_max_freq (apply_cpufreq_caps
  _soc="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_soc" ] && _soc="$(getprop ro.hardware.chipname 2>/dev/null)"
  case "$_soc" in
    canoe|sm8850*) _dev="op15" ;;
    sun|sm8750*)   _dev="op13" ;;
    pineapple|sm8650*) _dev="op12" ;;
    *)             _dev="generic" ;;
  esac

  _P_CPUCAP_L=""; _P_CPUCAP_B=""
  CPU_CAP_LITTLE=""; CPU_CAP_BIG=""
  case "$ASB_PROFILE" in
    performance)
      # never cap performance: full hardware range on every cluster, every SoC.
      _P_CPUCAP_L=""; _P_CPUCAP_B=""
      ;;
    balanced)
      if [ "$_son" -eq 1 ]; then
        # screen-on balanced: light touch; balance comes from WALT/uclamp. OP15
        case "$_dev" in
          op15) _P_CPUCAP_L=""; _P_CPUCAP_B="" ;;
          op13) _P_CPUCAP_L=72; _P_CPUCAP_B=58 ;;
          op12) _P_CPUCAP_L=78; _P_CPUCAP_B=58 ;;   # MID lifts to ~79%
          *)    _P_CPUCAP_L=72; _P_CPUCAP_B=55 ;;
        esac
      else
        _P_CPUCAP_L=55; _P_CPUCAP_B=45             # screen-off: cheap background
      fi
      ;;
    battery)
      if [ "$_son" -eq 1 ]; then
        # screen-on battery: MUST stay usable. Prime is capped for savings but
        case "$_dev" in
          op15) _P_CPUCAP_L=50; _P_CPUCAP_B=38 ;;
          op13) _P_CPUCAP_L=58; _P_CPUCAP_B=48 ;;   # raised: UI stayed janky at 50/44
          op12) _P_CPUCAP_L=60; _P_CPUCAP_B=45 ;;   # MID lifts to ~72%
          *)    _P_CPUCAP_L=52; _P_CPUCAP_B=40 ;;
        esac
      else
        _P_CPUCAP_L=35; _P_CPUCAP_B=25             # screen-off: aggressive
      fi
      ;;
    *)
      return 0
      ;;
  esac
  apply_cpufreq_caps
  asb_log "screen_aware_caps: dev=$_dev profile=$ASB_PROFILE screen_on=$_son cap_l=${_P_CPUCAP_L:-(none)} cap_b=${_P_CPUCAP_B:-(none)}"
}
asb_feature_enabled CPU && apply_gpu_caps
apply_walt_live() {
  asb_feature_enabled CPU || return 0
  [ -d /proc/sys/walt ] || return 0
  [ -e /proc/sys/walt/sched_ravg_window_nr_ticks ] && writef_retry /proc/sys/walt/sched_ravg_window_nr_ticks "$RAVG_TICKS" 10 0.25 || true
  [ -e /proc/sys/walt/sched_idle_enough ] && writef_retry /proc/sys/walt/sched_idle_enough "$WALT_IDLE" 10 0.25 || true
  [ -e /proc/sys/walt/sched_idle_enough_clust ] && writef_retry /proc/sys/walt/sched_idle_enough_clust "$WALT_IDLE_CLUST" 10 0.25 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct "$WALT_CLUSTER" 10 0.25 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct_clust ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct_clust "$WALT_CLUSTER_CLUST" 10 0.25 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_colocation ] && writef_retry /proc/sys/walt/sched_min_task_util_for_colocation "$WALT_COLOC" 10 0.25 || true
  [ -e /proc/sys/walt/sched_pipeline_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_util_thres "$WALT_PIPE" 10 0.25 || true
  [ -e /proc/sys/walt/sched_pipeline_non_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_non_special_task_util_thres "$WALT_PIPE_NONSP" 10 0.25 || true
  [ -e /proc/sys/walt/sched_pipeline_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_special_task_util_thres "$WALT_PIPE_SP" 10 0.25 || true
  [ -e /proc/sys/walt/sched_busy_hyst_ns ] && writef_retry /proc/sys/walt/sched_busy_hyst_ns "$WALT_BUSY_HYST" 10 0.25 || true
  [ -e /proc/sys/walt/sched_ed_boost ] && writef_retry /proc/sys/walt/sched_ed_boost "$WALT_ED_BOOST" 10 0.25 || true
  [ -e /proc/sys/walt/sched_topapp_weight_pct ] && writef_retry /proc/sys/walt/sched_topapp_weight_pct "$WALT_TOPAPP_WEIGHT" 10 0.25 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_boost ] && writef_retry /proc/sys/walt/sched_min_task_util_for_boost "$WALT_BOOST_MIN_UTIL" 10 0.25 || true
  [ -e /proc/sys/walt/sched_boost ] && writef_retry /proc/sys/walt/sched_boost "$WALT_SCHED_BOOST" 10 0.25 || true
}
apply_idle() {
  writef /sys/module/lpm_levels/parameters/sleep_disabled 0
  [ -w /sys/class/kgsl/kgsl-3d0/idle_timer ] &&     echo $_P_GTMR > /sys/class/kgsl/kgsl-3d0/idle_timer 2>/dev/null || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_rail_on 0 3 0.25 || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_clk_on  0 3 0.25 || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_bus_on  0 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/force_no_nap ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/force_no_nap "${GPU_FORCE_NO_NAP:-0}" 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/bus_split ] && [ -n "$GPU_BUS_SPLIT" ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/bus_split "$GPU_BUS_SPLIT" 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/throttling ] && [ -n "$GPU_THROTTLING" ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/throttling "$GPU_THROTTLING" 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel ] && [ -n "$GPU_THERMAL_PWRLEVEL" ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel "$GPU_THERMAL_PWRLEVEL" 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/pwrscale/policy/governor ] &&     echo msm-adreno-tz > /sys/class/kgsl/kgsl-3d0/pwrscale/policy/governor 2>/dev/null || true
}
asb_feature_enabled CPU && apply_idle

# ASB:CPU:BEGIN
apply_runtime_profile_now() {
  asb_load_profile
  PROFILE="$ASB_PROFILE"
  asb_log "apply_runtime_profile_now profile=$ASB_PROFILE"
  asb_feature_enabled CPU && asb_apply_profile_once
  if asb_feature_enabled CPU; then
    apply_walt_live
    apply_uclamp
    apply_cpuset_groups
    apply_cpuset_groups_all
    apply_idle
    apply_screen_aware_caps
    apply_gpu_caps
    # (min-freq now handled inside apply_cpufreq_caps; stray LITTLE/BIG writes removed)
    apply_cpugov_hints
  fi
  asb_feature_enabled VM && apply_vm
  asb_feature_enabled NET && apply_net
  asb_feature_enabled WIFI && apply_wlan0_txqlen
  asb_feature_enabled WIFI && apply_wlan0_qdisc
  asb_feature_enabled WIFI && apply_wifi_pm
  asb_feature_enabled WIFI && apply_wifi_dtim

  asb_feature_enabled VM && apply_doze
  (
    sleep 10
    asb_load_profile
    asb_feature_enabled CPU && apply_walt_live
    asb_feature_enabled CPU && apply_uclamp
    asb_feature_enabled CPU && apply_screen_aware_caps
    asb_feature_enabled CPU && apply_gpu_caps
    asb_feature_enabled WIFI && apply_wifi_pm
    asb_feature_enabled WIFI && apply_wifi_dtim

  ) >/dev/null 2>&1 &
}
# ASB:CPU:END
apply_bt_settings() {
  if has settings; then
    asb_settings_put global bluetooth_btsnoop_default_mode 0
    asb_settings_put secure bluetooth_btsnoop_default_mode 0
    asb_settings_put global bluetooth_btsnoop_log_mode disabled
    settings delete global bluetooth_disabled_profiles >/dev/null 2>&1 || true
  fi
}
asb_feature_enabled BT && apply_bt_settings
apply_bt_codec_policy() {
  if has settings; then
    asb_settings_put global bluetooth_a2dp_optional_codecs_enabled 1
    asb_settings_put global bluetooth_a2dp_codec_priority_lhdc 1200
    asb_settings_put global bluetooth_a2dp_codec_priority_ldac 1100
    asb_settings_put global bluetooth_a2dp_codec_priority_aac 1000
    asb_settings_put global bluetooth_a2dp_ldac_quality_index 0
    asb_settings_put global bluetooth_a2dp_codec_ldac_quality_index 0
    asb_settings_put global bluetooth_a2dp_codec_ldac_playback_quality 990
  fi
  if has resetprop; then
    resetprop -n persist.vendor.qcom.bluetooth.aac_frm_ctl.enabled true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.qcom.bluetooth.aac_vbr_ctl.enabled true >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
  fi
}
asb_feature_enabled BT && apply_bt_codec_policy
apply_bt_volume_behavior() {
  # Respect the user's bt_absvol_mode (auto|on|off) from governor.conf — the
  _bt_mode="$(grep -E '^[[:space:]]*bt_absvol_mode=' "$MODDIR/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  [ -n "$_bt_mode" ] || _bt_mode="auto"
  # AUTO = truly hands-off: do NOT touch absolute-volume at all, so the stock
  if [ "$_bt_mode" = "auto" ]; then
    asb_log "bt absvol: mode=auto -> leaving stock absolute-volume untouched"
    return 0
  fi
  case "$_bt_mode" in
    on)  _bt_dav=1; _bt_prop="true"  ;;   # disable absolute volume
    off) _bt_dav=0; _bt_prop="false" ;;
    *)   _bt_dav=0; _bt_prop="false" ;;
  esac
  if has settings; then
    asb_settings_put global bluetooth_disable_absolute_volume "$_bt_dav"
    asb_settings_put secure bluetooth_disable_absolute_volume "$_bt_dav"
  fi
  if has resetprop; then
    resetprop -n persist.bluetooth.disableabsvol "$_bt_prop" >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.disableabsvol "$_bt_prop" >/dev/null 2>&1 || true
    resetprop -p --delete persist.asb.force_disableabsvol >/dev/null 2>&1 || true
    resetprop -p --delete persist.asb.force_enableabsvol >/dev/null 2>&1 || true
  fi
}
asb_feature_enabled BT && apply_bt_volume_behavior
apply_bt_audio_hygiene() {
  if has resetprop; then
    resetprop -p --delete persist.vendor.bt.a2dp.lhdc.bitrate >/dev/null 2>&1 || true
    resetprop -p --delete persist.bluetooth.a2dp.lhdc.bitrate >/dev/null 2>&1 || true
  fi
  if has resetprop; then
    resetprop -n persist.bluetooth.a2dp.lhdc.samplerate 96000 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.samplerate 96000 >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.bitdepth 24 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.bitdepth 24 >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.qcom.bluetooth.enable.lpa true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.btstack.enable.lpa true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bt.enable.lpa true >/dev/null 2>&1 || true
    # LE Audio (lc3_offload / leaudio.enable / leaudio.enabled) intentionally not
    # forced — see apply_bt_runtime note: it breaks classic-BLE watch pairing.
  fi
}
asb_feature_enabled BT && apply_bt_audio_hygiene
if has resetprop; then
    for _k in media.resolution.limit.16bit media.resolution.limit.24bit media.resolution.limit.32bit \
             audio.resolution.limit.16bit audio.resolution.limit.24bit audio.resolution.limit.32bit; do
      resetprop -p --delete "$_k" >/dev/null 2>&1 || true
    done
  fi
apply_logd_props() {
  asb_persist_safe persist.logd.size 32K
  asb_persist_safe persist.logd.size.radio 32K
  asb_persist_safe persist.logd.size.system 32K
  asb_persist_safe persist.logd.size.crash 32K
  asb_persist_safe persist.logd.size.kernel 32K
  asb_persist_safe persist.logd.size.security 32K
  asb_persist_safe persist.logd.statistics false
  asb_persist_safe persist.logd.logpersistd stop
}
asb_feature_enabled LOG && apply_logd_props

# Runtime GMS/analytics tracking suppression via the settings DB. Props can't
apply_tracking_block() {
  _trk_log="/data/adb/asb/tracking_restore.log"
  : > "$_trk_log" 2>/dev/null
  _sp() {
    # _sp <key> <value> — save the old value, then set the new one.
    _old="$(settings get global "$1" 2>/dev/null)"
    echo "$1|$_old" >> "$_trk_log" 2>/dev/null
    settings put global "$1" "$2" >/dev/null 2>&1
  }
  _sp clearcut_enabled 0
  _sp clearcut_events 0
  _sp clearcut_gcm 0
  _sp gmscorestat_enabled 0
  _sp ga_collection_enabled 0
  _sp analytics_enabled 0
  _sp uploading_enabled 0
  _sp usage_stats_enabled 0
  _sp usagestats_collection_enabled 0
  _sp network_watchlist_enabled 0
  _sp limit_ad_tracking 1
  _sp tron_enabled 0
  _sp play_store_panel_logging_enabled 0
  _sp phenotype_flags "disable_log_upload=1,disable_log_for_missing_debug_id=1"
  _sp binder_calls_stats "sampling_interval=600000000,detailed_tracking=disable,enabled=false,upload_data=false"
}
asb_feature_enabled LOG && apply_tracking_block

apply_camera_experimental() {
  # The proven-working OP12 build ran this on pineapple too (it set MFNR/EIS/SAT/
  _orig="$MODDIR/config/camera_orig.conf"

  if [ ! -f "$_orig" ]; then
    mkdir -p "$MODDIR/config"
    echo "# ASB camera original values" > "$_orig"
    for _prop in \
      persist.vendor.camera.mfnr.enable \
      persist.vendor.camera.eis.enable \
      persist.vendor.camera.sat.fallback.dist \
      persist.vendor.camera.main.hfr \
      persist.vendor.camera.fast.af; do
      _v="$(getprop "$_prop" 2>/dev/null)"
      echo "${_prop}=${_v}" >> "$_orig"
    done
    asb_log "camera: saved originals to camera_orig.conf"
  fi

  has resetprop || return 0
  resetprop -n persist.vendor.camera.mfnr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.eis.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.sat.fallback.dist 2.0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.main.hfr 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.fast.af 1 >/dev/null 2>&1 || true
  asb_log "camera experimental: applied (MFNR+EIS+SAT+HFR+FastAF)"
}
asb_feature_enabled CAMERA && apply_camera_experimental

apply_audio_boost() {
  _as_pid="$(pidof audioserver 2>/dev/null | head -1)"
  [ -z "$_as_pid" ] && return 0
  has chrt || return 0
  renice -10 "$_as_pid" >/dev/null 2>&1 || true
  chrt -r -p 52 "$_as_pid" >/dev/null 2>&1 || true
  asb_log "audio boost: audioserver pid=$_as_pid renice=-10 chrt=RR/52"
}
asb_feature_enabled BT && ( sleep 15 && apply_audio_boost ) >/dev/null 2>&1 &

asb_check_perfhal_drift() {
  # DISABLED: caps are now a percent of each cluster's own max (see
  return 0
}
asb_check_perfhal_drift_legacy_unused() {
  asb_load_profile
  [ -z "$CPU_CAP_BIG" ] && return 0
  _want="$CPU_CAP_BIG"
  _drift_pol=""
  for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol" ] || continue
    _rel="$(cat "$_pol/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_rel" in ''|*[!0-9]*) continue ;; esac
    [ "$_rel" -gt "$little_end" ] 2>/dev/null && { _drift_pol="$_pol"; break; }
  done
  [ -z "$_drift_pol" ] && return 0
  _cur="$(cat "$_drift_pol/scaling_max_freq" 2>/dev/null)"
  [ -z "$_cur" ] && return 0
  if [ "$_cur" != "$_want" ]; then
    asb_log "PERF-HAL DRIFT: $(basename $_drift_pol) max=${_cur} (expected ${_want}) — likely overridden by PowerHAL/thermal"
  fi
}

svc_state() { getprop "init.svc.$1" 2>/dev/null; }
svc_exists() { [ -n "$(svc_state "$1")" ]; }
svc_running() { [ "$(svc_state "$1")" = "running" ]; }
svc_busy() {
  st="$(svc_state "$1")"
  [ "$st" = "stopping" ] || [ "$st" = "restarting" ]
}
svc_stop() {
  s="$1"
  svc_exists "$s" || return 0
  svc_running "$s" || return 0
  svc_busy "$s" && return 0
  sleep 0.5
  svc_running "$s" && stop "$s" 2>/dev/null || true
  return 0
}
svc_stop_guarded() {
  s="$1"
  for i in 1 2 3; do
    svc_stop "$s"
    svc_running "$s" || return 0
    sleep 2
  done
  return 0
}
for s in \
  qseelogd wlanramdumpcollector mqsasd mtdoopslog debuggerd \
  minidump minidump32 minidump64 bootstat poweroff_charger_log \
  ostatsd charge_logger iorapd cnss_diag diag_mdlog diag_mdlog_start \
  mmi-diag qcom-diag tftp_server tcpdump modem_svc logcat-debug \
  midasd batterysecret \
  mdnsd \
  oplus_sensor_fb vendor.oplus.sensor.fb \
  oplus_crash_report \
  oplusdebuglogauto \
  vendor.oplus.logkit oplus_logctl \
  oplus_gaia oplus_theia theia_screen_monitor \
  qcom_diag_relay vendor.qti.diag \
  oplusd mlipay \
; do
  svc_stop_guarded "$s"
done
apply_zram() {
  [ -e /sys/block/zram0 ] || return 0
  CPU_CORES=$(nproc 2>/dev/null || echo 8)
  ZRAM_SIZE_MB=8192
  _cur_disksize=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
  _want_bytes=$((ZRAM_SIZE_MB * 1024 * 1024))
  if [ "$_cur_disksize" = "$_want_bytes" ] && \
     grep -q "/dev/block/zram0" /proc/swaps 2>/dev/null; then
    return 0
  fi
  swapoff /dev/block/zram0 >/dev/null 2>&1
  _t=0
  while grep -q "/dev/block/zram0" /proc/swaps 2>/dev/null && [ "$_t" -lt 5 ]; do
    sleep 1; swapoff /dev/block/zram0 >/dev/null 2>&1; _t=$((_t + 1))
  done
  echo 1 > /sys/block/zram0/reset 2>/dev/null || return 0
  sleep 2
  echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || \
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  echo "$CPU_CORES" > /sys/block/zram0/max_comp_streams 2>/dev/null || true
  [ -f /sys/block/zram0/use_dedup ] && echo 1 > /sys/block/zram0/use_dedup 2>/dev/null || true
  echo "${ZRAM_SIZE_MB}M" > /sys/block/zram0/disksize 2>/dev/null || return 0
  echo 0 > /sys/block/zram0/queue/iostats 2>/dev/null || true
  echo 0 > /sys/block/zram0/queue/add_random 2>/dev/null || true
  mkswap /dev/block/zram0 >/dev/null 2>&1 && \
    swapon /dev/block/zram0 >/dev/null 2>&1 || true
}
apply_walt_boost() {
  for _pol in 0 4 7; do
    _wp="/sys/devices/system/cpu/cpufreq/policy${_pol}/walt"
    [ -d "$_wp" ] || continue
    writef_retry "$_wp/input_boost_freq" 0  3 0.25 || true
    writef_retry "$_wp/input_boost_ms"   25 3 0.25 || true
  done
  [ -w /proc/sys/kernel/sched_boost ] && \
    writef_retry /proc/sys/kernel/sched_boost 0 3 0.25 || true
  writef_retry /proc/sys/kernel/sched_energy_aware 1 3 0.25 || true
}
( sleep 5; asb_load_profile; apply_walt_boost; apply_walt_live ) >/dev/null 2>&1 &
asb_feature_enabled VM && apply_zram
apply_doze() {
  has settings || return 0
  case "$ASB_PROFILE" in
    battery)
      _DIC="light_after_inactive_to=15000,light_pre_idle_to=2000,light_max_idle_to=86400000,light_idle_to=5000,light_idle_factor=3.0,light_idle_maintenance_min_budget=1000,light_idle_maintenance_max_budget=5000,inactive_to=30000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=3000,idle_pending_to=1500,max_idle_pending_to=3000,idle_pending_factor=3.0,idle_to=900000,max_idle_to=43200000,idle_factor=3.0,min_time_to_alarm=30000,max_temp_app_whitelist_duration=20000,mms_temp_app_whitelist_duration=10000,sms_temp_app_whitelist_duration=8000" ;;
    performance)
      _DIC="light_after_inactive_to=60000,light_pre_idle_to=10000,light_max_idle_to=86400000,light_idle_to=15000,light_idle_factor=2.0,light_idle_maintenance_min_budget=2000,light_idle_maintenance_max_budget=15000,inactive_to=300000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=20000,idle_pending_to=10000,max_idle_pending_to=15000,idle_pending_factor=2.0,idle_to=3600000,max_idle_to=10800000,idle_factor=2.0,min_time_to_alarm=60000,max_temp_app_whitelist_duration=60000,mms_temp_app_whitelist_duration=30000,sms_temp_app_whitelist_duration=20000" ;;
    *)
      _DIC="light_after_inactive_to=30000,light_pre_idle_to=5000,light_max_idle_to=86400000,light_idle_to=10000,light_idle_factor=2.0,light_idle_maintenance_min_budget=2000,light_idle_maintenance_max_budget=15000,inactive_to=180000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=10000,idle_pending_to=5000,max_idle_pending_to=10000,idle_pending_factor=2.0,idle_to=3600000,max_idle_to=21600000,idle_factor=2.0,min_time_to_alarm=60000,max_temp_app_whitelist_duration=60000,mms_temp_app_whitelist_duration=30000,sms_temp_app_whitelist_duration=20000" ;;
  esac
  asb_settings_put global device_idle_constants "$_DIC"
}
asb_feature_enabled VM && apply_doze
# network_stats_poll_interval: how often the framework polls per-app network
apply_network_stats_poll() {
  has settings || return 0
  asb_feature_enabled LOG || return 0
  _eff_batt=0
  if [ "$ASB_PROFILE" = "battery" ]; then
    _eff_batt=1
  elif [ "$ASB_PROFILE" = "smart" ]; then
    _alpha="$(grep -m1 '^smart_alpha_battery=' /dev/.asb/state 2>/dev/null | sed 's/^smart_alpha_battery=//')"
    case "$_alpha" in
      ''|*[!0-9]*) : ;;                                  # no/!num reading -> leave default
      *) [ "$_alpha" -ge 800 ] 2>/dev/null && _eff_batt=1 ;;
    esac
  fi
  if [ "$_eff_batt" = "1" ]; then
    asb_settings_put global network_stats_poll_interval 7200000
  else
    asb_settings_put global network_stats_poll_interval 1800000
  fi
}
asb_feature_enabled VM && apply_network_stats_poll
apply_extra_settings() {
  has settings || return 0
  asb_settings_put global audio_safe_volume_state 0
  settings delete global netstats_enabled >/dev/null 2>&1 || true
  settings delete global app_usage_enabled >/dev/null 2>&1 || true
  settings delete global package_usage_stats_enabled >/dev/null 2>&1 || true
  asb_settings_put global bluetooth_voip_support 1
  asb_settings_put global dropbox_max_files 5
  asb_settings_put global network_recommendations_enabled 0
  asb_settings_put global activity_starts_logging_enabled 0
  asb_settings_put global settings_enable_monitor_phantom_procs false
  asb_settings_put global send_action_app_error 0
  asb_settings_put global enhanced_connectivity_enabled 0
  asb_settings_put global adaptive_connectivity_enabled 0
  # Connectivity (captive-portal) check: point it at Cloudflare's generate_204
  # endpoint with a gstatic fallback. The stock Google-only endpoint can be slow
  # to answer (or blocked in some regions), which shows up as a laggy "no
  # internet" state on a working connection or delayed connectivity after wake.
  # Cloudflare's 204 is fast and globally anycast; the fallback keeps detection
  # working if it's ever unreachable. Device-agnostic, no battery cost.
  asb_settings_put global captive_portal_mode 1
  asb_settings_put global captive_portal_detection_enabled 1
  asb_settings_put global captive_portal_use_https 1
  asb_settings_put global captive_portal_http_url "http://cp.cloudflare.com/generate_204"
  asb_settings_put global captive_portal_https_url "https://cp.cloudflare.com/generate_204"
  asb_settings_put global captive_portal_fallback_url "http://connectivitycheck.gstatic.com/generate_204"
  asb_settings_put global captive_portal_other_fallback_url "https://www.google.com/generate_204"
}
apply_extra_settings
asb_load_profile
[ "$(type -t asb_apply_ux 2>/dev/null)" = "function" ] && asb_apply_ux >/dev/null 2>&1
(
  sleep 30
  _fg="$(getprop persist.sys.power.fuel.gauge 2>/dev/null)"
  [ "$_fg" != "0" ] && asb_persist_safe persist.sys.power.fuel.gauge 0
) >/dev/null 2>&1 &
(
  [ -r "$MODDIR/runtime/asb_reconcile.sh" ] && . "$MODDIR/runtime/asb_reconcile.sh"
) >/dev/null 2>&1 &
(
  sleep 60
  asb_load_profile
  if asb_feature_enabled KERNEL; then
    sysctlw kernel.sched_schedstats 0
    sysctlw kernel.timer_migration 0
    [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
  fi
  if asb_feature_enabled CPU; then
    if [ "$ASB_GOV_ENABLED" != "1" ] || ! asb_governor_running; then
      apply_walt_live
    fi
  fi
  asb_log "light reinforce 60s profile=$ASB_PROFILE"
  has settings && asb_settings_put global network_recommendations_enabled 0
  # If the user opted to manage OEM toggles, OxygenOS often re-enables RAM
  if [ -r "$MODDIR/config/governor.conf" ]; then
    _oem="$(grep -E '^[[:space:]]*UX_MANAGE_OEM_TOGGLES=' "$MODDIR/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
    if [ "$_oem" = "1" ] || [ "$_oem" = "on" ]; then
      _rex="$(grep -E '^[[:space:]]*UX_RAM_EXPAND=' "$MODDIR/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
      case "$_rex" in ''|*[!0-9]*) _rex=0 ;; esac
      if has settings; then
        # Match profile_core: confirmed off = 0/0 on OP13. Just the two real keys.
        if [ "$_rex" = "0" ]; then
          asb_settings_put global ram_expand_size 0
          asb_settings_put global ram_expand_size_list 0
        else
          asb_settings_put global ram_expand_size "$_rex"
        fi
      fi
    fi
  fi
  sleep 240
  asb_load_profile
  if asb_feature_enabled KERNEL; then
    sysctlw kernel.sched_schedstats 0
    sysctlw kernel.timer_migration 0
    [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
  fi
  asb_log "full reinforce 5m profile=$ASB_PROFILE"
  if [ "$ASB_GOV_ENABLED" != "1" ] || ! asb_governor_running; then
    asb_feature_enabled CPU && apply_walt_live
    asb_feature_enabled CPU && apply_uclamp
    asb_feature_enabled CPU && apply_screen_aware_caps
    asb_feature_enabled CPU && apply_gpu_caps
  fi
  asb_feature_enabled VM && apply_vm
  asb_feature_enabled VM && apply_doze
) >/dev/null 2>&1 &
(
  [ -r "$MODDIR/runtime/asb_watchdog.sh" ] && . "$MODDIR/runtime/asb_watchdog.sh"
) >/dev/null 2>&1 &

exit 0
