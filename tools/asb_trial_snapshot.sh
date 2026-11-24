#!/system/bin/sh
# One read-only sample for a controlled field trial. Missing nodes have no row.
sample() {
    [ -r "$2" ] || return 0
    value=$(cat "$2" 2>/dev/null) || return 0
    [ -n "$value" ] && printf '%s\t%s\n' "$1" "$value"
    return 0
}
sys=${ASB_TRIAL_SYS:-/sys}
proc=${ASB_TRIAL_PROC:-/proc}
state=${ASB_TRIAL_STATE:-/dev/.asb/state}
printf 'epoch_s\t%s\n' "$(date +%s)"
sample boot_id "$proc/sys/kernel/random/boot_id"
sample uptime "$proc/uptime"
sample kernel_release "$proc/sys/kernel/osrelease"
if command -v getprop >/dev/null 2>&1; then
    printf 'model\t%s\nrom_fingerprint\t%s\n' "$(getprop ro.product.model)" "$(getprop ro.build.fingerprint)"
fi
for policy in "$sys"/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    for node in affected_cpus scaling_governor scaling_min_freq scaling_max_freq scaling_available_frequencies schedutil/up_rate_limit_us schedutil/down_rate_limit_us; do
        sample "${policy##*/}/$node" "$policy/$node"
    done
done
for node in up_rate_limit_us down_rate_limit_us; do
    sample "shared_schedutil/$node" "$sys/devices/system/cpu/cpufreq/schedutil/$node"
done
for node in status charge_counter current_now temp capacity cycle_count; do
    sample "battery/$node" "$sys/class/power_supply/battery/$node"
done
for node in min_freq max_freq available_frequencies; do
    sample "gpu/$node" "$sys/class/kgsl/kgsl-3d0/devfreq/$node"
done
for path in /dev/cpuctl/top-app/cpu.uclamp.* /sys/fs/cgroup/top-app/cpu.uclamp.*; do
    sample "$path" "$path"
done
for device in "$sys"/block/*/queue/scheduler; do
    sample "${device#"$sys"/}" "$device"
done
for pressure in cpu memory io; do
    if [ -r "$proc/pressure/$pressure" ]; then
        awk -v group="$pressure" '{print "psi/" group "/" $1 "\t" substr($0, index($0, " ")+1)}' "$proc/pressure/$pressure"
    fi
done
if [ -r "$state" ]; then
    awk -F= '/^(governor_uptime_s|governor_cpu_ms|governor_writes|governor_write_attempts|governor_timer_wakeups|governor_event_wakeups|governor_already_set)=[0-9]+$/ {print $1 "\t" $2}' "$state"
fi
