#!/system/bin/sh
# asb_state_sampler.sh — high-rate state sampler for V40
#
# Captures every 1 second:
#   - GPU pwrlevel (max, min, current freq, busy %)
#   - CPU max freq per cluster (sysfs vs FSM desired)
#   - Thermal zone readings (skin, surface, CPU, GPU)
#   - FSM state, profile, current_caps from /dev/.asb/state
#   - Vendor override count (from V40 instrumentation)
#
# Use: run during a window where you experience stutter or want to characterize
# behavior. Output goes to /sdcard/asb_state_samples_<timestamp>.tsv as TSV.
#
# Default duration: 60 seconds. Override via first arg.
#
# Cost is ~5-10ms CPU per sample = harmless for diagnostic purposes.

DURATION="${1:-60}"
case "$DURATION" in
    ''|*[!0-9]*) echo "usage: $0 [duration_seconds]" >&2; exit 1 ;;
esac

OUT="/sdcard/asb_state_samples_$(date +%Y%m%d-%H%M%S).tsv"
echo "[asb_state_sampler] sampling for ${DURATION}s -> $OUT" >&2

# Header
{
    printf 'ts\tprofile\tstate\t'
    printf 'fsm_p0_max\tfsm_p6_max\tactual_p0_max\tactual_p6_max\t'
    printf 'gpu_max_pwrlevel\tgpu_min_pwrlevel\tgpu_curr_freq\tgpu_busy\t'
    printf 'gpu_thermal_pwrlevel\tcpu_temp\tskin_temp\tsurface_hotspot\t'
    printf 'load1\tbat_current_ma\tbat_pct\t'
    printf 'vendor_max_overrides\tvendor_min_overrides\n'
} > "$OUT"

# Find sysfs paths once
GPU_BASE="/sys/class/kgsl/kgsl-3d0"
P0_MAX="/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
P6_MAX="/sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq"

read_int() { cat "$1" 2>/dev/null || echo 0; }
read_str() { cat "$1" 2>/dev/null || echo ""; }

# Read /dev/.asb/state once-per-tick to extract FSM caps
get_fsm_caps() {
    local _line=$(grep "^cpu_max=" /dev/.asb/state 2>/dev/null | head -1)
    echo "${_line#cpu_max=}"
}
get_state_field() {
    grep "^${1}=" /dev/.asb/state 2>/dev/null | head -1 | cut -d= -f2
}
get_status_field() {
    # JSON-like status fields
    grep -oE "\"${1}\":[\"']?[^,\"']+" /dev/.asb/status 2>/dev/null \
        | head -1 | cut -d: -f2 | tr -d '"' | tr -d "'"
}

# Vendor override audit
get_vendor_audit() {
    cat /dev/.asb/vendor_override_audit 2>/dev/null \
        | grep -oE '"max_overrides":[0-9]+|"min_overrides":[0-9]+' \
        | head -2
}

# Loop
END=$(($(date +%s) + DURATION))
COUNT=0
while [ "$(date +%s)" -lt "$END" ]; do
    TS=$(date +%s)
    # FSM state from /dev/.asb/state
    PROFILE=$(get_state_field profile)
    STATE=$(get_state_field state)
    FSM_CAPS=$(get_fsm_caps)
    FSM_P0=$(echo "$FSM_CAPS" | cut -d, -f1)
    FSM_P6=$(echo "$FSM_CAPS" | cut -d, -f2)
    [ -z "$FSM_P0" ] && FSM_P0=0
    [ -z "$FSM_P6" ] && FSM_P6=0

    # Actual sysfs
    ACT_P0=$(read_int "$P0_MAX")
    ACT_P6=$(read_int "$P6_MAX")

    # GPU
    GPU_MAX=$(read_int "$GPU_BASE/max_pwrlevel")
    GPU_MIN=$(read_int "$GPU_BASE/min_pwrlevel")
    GPU_FREQ=$(read_int "$GPU_BASE/gpuclk")
    GPU_BUSY=$(read_str "$GPU_BASE/gpu_busy_percentage" | grep -oE '[0-9]+' | head -1)
    [ -z "$GPU_BUSY" ] && GPU_BUSY=$(read_str "$GPU_BASE/gpubusy" | head -1)
    GPU_TPL=$(read_int "$GPU_BASE/thermal_pwrlevel")

    # Thermal — read from /dev/.asb/state which has thermal already classified
    CPU_TEMP=$(get_state_field cap_temp)
    SKIN=$(get_state_field skin_temp)
    SURFACE=$(get_state_field surface_hotspot)
    [ -z "$CPU_TEMP" ] && CPU_TEMP=0
    [ -z "$SKIN" ] && SKIN=0
    [ -z "$SURFACE" ] && SURFACE=0

    # Load + battery
    LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    BAT_MA=$(read_int /sys/class/power_supply/battery/current_now)
    BAT_PCT=$(read_int /sys/class/power_supply/battery/capacity)

    # Vendor overrides
    VO=$(cat /dev/.asb/vendor_override_audit 2>/dev/null)
    VO_MAX=$(echo "$VO" | grep -oE '"max_overrides":[0-9]+' | grep -oE '[0-9]+')
    VO_MIN=$(echo "$VO" | grep -oE '"min_overrides":[0-9]+' | grep -oE '[0-9]+')
    [ -z "$VO_MAX" ] && VO_MAX=0
    [ -z "$VO_MIN" ] && VO_MIN=0

    # Output row
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$TS" "$PROFILE" "$STATE" \
        "$FSM_P0" "$FSM_P6" "$ACT_P0" "$ACT_P6" \
        "$GPU_MAX" "$GPU_MIN" "$GPU_FREQ" "$GPU_BUSY" \
        "$GPU_TPL" "$CPU_TEMP" "$SKIN" "$SURFACE" \
        "$LOAD1" "$BAT_MA" "$BAT_PCT" \
        "$VO_MAX" "$VO_MIN" >> "$OUT"

    COUNT=$((COUNT + 1))
    sleep 1
done

echo "[asb_state_sampler] captured $COUNT samples to $OUT" >&2
echo "$OUT"
