#!/usr/bin/env sh
# Contract: the V65 efficiency pass must keep expensive boot operations opt-in and
# must not reintroduce high-frequency screen-off polling.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE="$ROOT/service.sh"
GOV="$ROOT/src/asb_governor.c"
fail() { echo "FAIL V65 efficiency contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
line_of() { grep -nF "$2" "$1" | head -1 | cut -d: -f1; }

# A full zram reset performs swapoff/writeback.  It must never run solely because
# the VM feature is enabled on a device that already owns a usable zram policy.
need "$SERVICE" 'allow_zram_rebuild'
zram_guard="$(line_of "$SERVICE" 'allow_zram_rebuild')"
zram_swapoff="$(line_of "$SERVICE" 'swapoff /dev/block/zram0')"
[ -n "$zram_guard" ] && [ -n "$zram_swapoff" ] && [ "$zram_guard" -lt "$zram_swapoff" ] \
  || fail 'zram rebuild is not guarded before swapoff'

# Destructive background trimming and init service stops can induce package/service
# restarts.  They must have explicit local opt-in gates.
need "$SERVICE" 'allow_disruptive_bg_trim'
need "$SERVICE" 'allow_service_stops'

# The observer must not run package-manager/dumpsys/appops work while the screen is
# on, and the screen-off interval must be at least an hour between expensive passes.
need "$SERVICE" 'sleep 1800'
need "$SERVICE" '_screenoff_pass=$((_screenoff_pass + 1))'
need "$SERVICE" '[ $((_screenoff_pass % 2)) -eq 0 ] || continue'

# DSP route correction is a fallback poll; normal setting changes still signal the
# attacher immediately.  A 60-second cadence prevents permanent 20-second IPC churn.
need "$SERVICE" 'sleep 60'
need "$SERVICE" 'pkill -USR1 -f asb_dsp_attach'

# The deferred core worker must avoid the broad profile fan-out and use only its
# narrow CPU setup path, preventing duplicate CPU/GPU/VM/network/Wi-Fi/UX writes.
core_start="$(line_of "$SERVICE" 'asb_apply_deferred_core_boot() {')"
core_end="$(line_of "$SERVICE" 'apply_doze() {')"
[ -n "$core_start" ] && [ -n "$core_end" ] || fail 'could not locate deferred core worker'
if sed -n "${core_start},${core_end}p" "$SERVICE" | grep -Eq '^[[:space:]]*asb_apply_profile_once([[:space:]]|$)'; then
  fail 'deferred core worker still uses broad profile fan-out'
fi
need "$SERVICE" 'asb_feature_enabled CPU && asb_cpu_cluster_init'
# On devices with the native Smart governor, boot must return after native ownership is
# confirmed; the legacy multi-write shell convergence is available only as an explicit opt-in.
need "$SERVICE" 'allow_boot_shell_policy'
need "$SERVICE" 'post_boot_core_policy_native_only'
boot_guard="$(line_of "$SERVICE" 'allow_boot_shell_policy')"
boot_load="$(sed -n "${core_start},${core_end}p" "$SERVICE" | grep -nE '^[[:space:]]*asb_load_profile([[:space:]]|$)' | head -1 | cut -d: -f1)"
[ -n "$boot_guard" ] && [ -n "$boot_load" ] || fail 'boot shell-policy guard missing'

# Native screen-off cadence must remain materially slower than the active loop.
need "$GOV" '#define TIMER_IDLE_S   10'
need "$GOV" '#define TIMER_DEEP_S   30'
need "$GOV" 'expected_samples = dur / (TIMER_DEEP_S'

echo 'PASS V65 efficiency contract'
