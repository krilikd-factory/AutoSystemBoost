#!/bin/sh
# fix88: findings from an OP15 /data/adb/asb snapshot.
#  - gpu_pwrlevel_floor was a one-time snapshot of max_pwrlevel (9 of 18, ASB's own earlier
#    write) that clamped every profile apply; the live thermal level is the vendor limit.
#  - capabilities.env said dsp_soundfx=0 with the effect audible: the probe runs before the
#    overlay is mounted, so the module's staged copy has to count.
#  - every Smart session was conf=low / sig=mixed (500 of 500).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL asb state-dir fixes: $*" >&2; exit 1; }
grep -Fq 'rm -f /data/adb/asb/gpu_pwrlevel_floor' "$ROOT/service.sh" || fail "stale GPU floor snapshot not removed"
grep -Fq '_vfloor="$(cat /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel 2>/dev/null)"' "$ROOT/service.sh" || fail "GPU floor not taken from the live thermal level"
grep -q 'cat "\$_floor_file"' "$ROOT/service.sh" && fail "service.sh still reads the snapshot"
grep -Fq '"$MODDIR/system/vendor/lib64/soundfx"' "$ROOT/runtime/asb_capabilities.sh" || fail "capability probe ignores the staged DSP library"
G="$ROOT/src/asb_governor.c"
grep -Fq 'static int asb_smart_session_idle_dominant(' "$G" || fail "Smart session idle/active split missing"
awk '/^static const char \*classify_confidence\(/,/^}$/' "$G" | grep -q 'PROFILE_SMART' || fail "Smart has no confidence branch"
awk '/^static const char \*classify_signature\(/,/^}$/' "$G" | grep -q 'PROFILE_SMART' || fail "Smart has no signature branch"
grep -Fq "asb_settings_put global dropbox_max_files 50" "$ROOT/service.sh" || fail "dropbox still capped so low that crash evidence is lost"
echo "PASS /data/adb/asb findings: GPU floor, DSP capability, Smart session labels"
