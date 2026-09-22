#!/usr/bin/env bash
# Modem-wakeup-gate observability contract: the night gate must gate exactly the radio
# wake sources a fixture exposes, record+restore them all, and ALWAYS leave a result
# file behind - including the "ran but matched zero nodes" case, which on a CPH2745 is
# the difference between "tweak is working, kernel hides the nodes" and "tweak never ran".
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_lpm.sh"
DIAG="$ROOT/system/bin/asbdiag"
fail() { echo "FAIL lpm gate contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'runtime/asb_lpm.sh missing'
sh -n "$SRC"

# --- source pins ---
grep -qF 'ASB_LPM_SYSCLASS:-/sys/class' "$SRC" || fail 'sysfs root not injectable for fixtures'
grep -qF '/data/adb/asb/lpm_gate_result' "$SRC" || fail 'gate result file missing'
grep -qF '_g_ws=$((_g_ws + 1))' "$SRC" || fail 'wakeup-class counter missing'
grep -qF '_g_if=$((_g_if + 1))' "$SRC" || fail 'interface counter missing'
grep -qF '"$_SYSCLASS"/wakeup/wakeup*' "$SRC" || fail 'wakeup glob not using the injected root'
grep -qF '"$_SYSCLASS"/net/rmnet*' "$SRC" || fail 'rmnet glob not using the injected root'
grep -qF '"$_SYSCLASS"/net/wlan*' "$SRC" || fail 'wlan glob not using the injected root'
# The restore path must honour the same injected root, or fixtures test a different file.
grep -qF '"$_SYSCLASS/net/$_n/device/power/wakeup"' "$SRC" || fail 'restore path not using the injected root'

# --- diag pins: the result must be visible where a user looks ---
grep -qF 'lpm_gate_result' "$DIAG" || fail 'asbdiag never reads the gate result'
grep -qF 'last modem wakeup gate:' "$DIAG" || fail 'asbdiag gate NOTE missing'
grep -qF 'ran and found nothing to gate' "$DIAG" || fail 'asbdiag zero-match NOTE missing'
cmp -s "$DIAG" "$ROOT/tools/asb_diag.sh" || fail 'asbdiag and tools/asb_diag.sh diverged'

# --- executable fixture: the REAL gate/restore functions against a synthetic sysfs ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the variable block plus both functions (two top-level closing braces).
awk '/^_ASB_WAKEUP_STATE=\/data\/adb\/asb\/lpm_wakeup_prev$/{f=1} f{print} f&&/^}$/{c++; if(c==2) exit}' "$SRC" \
  | sed "s|/data/adb/asb|$TMP/asb|g" > "$TMP/lpm.sh"
[ -s "$TMP/lpm.sh" ] || fail 'function block not found'
grep -q '_lpm_wakeup_gate()' "$TMP/lpm.sh" || fail 'gate function not extracted'
grep -q '_lpm_wakeup_restore()' "$TMP/lpm.sh" || fail 'restore function not extracted'

SYS="$TMP/sys/class"
mkdir -p "$SYS/wakeup/wakeup0/device/power" "$SYS/wakeup/wakeup1/device/power" \
         "$SYS/net/rmnet_data3/device/power" "$SYS/net/wlan0/device/power" \
         "$SYS/net/lo/device/power" "$TMP/asb"
printf 'IPA_CLIENT_APPS_WAN_LOW_LAT_CONS\n' > "$SYS/wakeup/wakeup0/name"
printf 'enabled\n' > "$SYS/wakeup/wakeup0/device/power/wakeup"
printf 'pm8xxx_rtc_alarm\n' > "$SYS/wakeup/wakeup1/name"
printf 'enabled\n' > "$SYS/wakeup/wakeup1/device/power/wakeup"
printf 'enabled\n' > "$SYS/net/rmnet_data3/device/power/wakeup"
printf 'enabled\n' > "$SYS/net/wlan0/device/power/wakeup"
printf 'enabled\n' > "$SYS/net/lo/device/power/wakeup"

export ASB_LPM_SYSCLASS="$SYS"
. "$TMP/lpm.sh"

# Gate: only the radio sources flip, everything is recorded, the result file appears.
_lpm_wakeup_gate disabled
[ "$(cat "$SYS/wakeup/wakeup0/device/power/wakeup")" = 'disabled' ] || fail 'IPA wakeup source not gated'
[ "$(cat "$SYS/wakeup/wakeup1/device/power/wakeup")" = 'enabled' ] || fail 'non-radio wakeup source was touched'
[ "$(cat "$SYS/net/rmnet_data3/device/power/wakeup")" = 'disabled' ] || fail 'rmnet interface not gated'
[ "$(cat "$SYS/net/wlan0/device/power/wakeup")" = 'disabled' ] || fail 'wlan interface not gated'
[ "$(cat "$SYS/net/lo/device/power/wakeup")" = 'enabled' ] || fail 'lo was touched'

ST="$TMP/asb/lpm_wakeup_prev"
[ -f "$ST" ] || fail 'wakeup state file not written'
[ "$(wc -l < "$ST" | tr -d ' ')" = '3' ] || fail 'state file must hold all 3 gated nodes'
grep -q '^rmnet_data3=enabled$' "$ST" || fail 'rmnet baseline not recorded'
grep -q '^wlan0=enabled$' "$ST" || fail 'wlan baseline not recorded'
grep -q '^/.*wakeup0.*/power/wakeup=enabled$' "$ST" || fail 'IPA device baseline not recorded as a path'

GR="$TMP/asb/lpm_gate_result"
[ -f "$GR" ] || fail 'gate result file not written'
grep -q 'action=disabled' "$GR" || fail 'result action wrong'
grep -q 'wakeup_nodes=1' "$GR" || fail 'result must count 1 wakeup-class node'
grep -q 'net_ifaces=2' "$GR" || fail 'result must count 2 interfaces'

# A second pass must not overwrite the real baselines with self-written values.
_lpm_wakeup_gate disabled
grep -q '^rmnet_data3=enabled$' "$ST" || fail 'second pass clobbered the rmnet baseline'
[ "$(wc -l < "$ST" | tr -d ' ')" = '3' ] || fail 'second pass duplicated state entries'

# Restore: everything back, state file gone.
_lpm_wakeup_restore
[ "$(cat "$SYS/wakeup/wakeup0/device/power/wakeup")" = 'enabled' ] || fail 'IPA wakeup source not restored'
[ "$(cat "$SYS/net/rmnet_data3/device/power/wakeup")" = 'enabled' ] || fail 'rmnet not restored'
[ "$(cat "$SYS/net/wlan0/device/power/wakeup")" = 'enabled' ] || fail 'wlan not restored'
[ ! -f "$ST" ] || fail 'state file not removed after restore'

# The CPH2745 case: a kernel that exposes NOTHING gateable. The gate must still leave a
# result file saying so - this is the whole point of the change.
SYS2="$TMP/sys2/class"
mkdir -p "$SYS2/net" "$SYS2/wakeup"
ASB_LPM_SYSCLASS="$SYS2"
export ASB_LPM_SYSCLASS
. "$TMP/lpm.sh"
_lpm_wakeup_gate disabled
[ -f "$GR" ] || fail 'zero-match pass left no result file'
grep -q 'wakeup_nodes=0' "$GR" || fail 'zero-match pass must report wakeup_nodes=0'
grep -q 'net_ifaces=0' "$GR" || fail 'zero-match pass must report net_ifaces=0'
[ ! -f "$ST" ] || fail 'zero-match pass must not invent a state file'

echo 'lpm gate contract: OK'
