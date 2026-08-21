#!/bin/sh
# Contract: release is smaller than debug, not functionally crippled.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REL="$ROOT/.github/workflows/build-release.yml"
DBG="$ROOT/.github/workflows/build-debug.yml"

need() { grep -Fq -- "$2" "$1" || { echo "FAIL package parity: missing [$2] in ${1##*/}" >&2; exit 1; }; }
not_need() { ! grep -Fq -- "$2" "$1" || { echo "FAIL package parity: forbidden [$2] in ${1##*/}" >&2; exit 1; }; }

for wf in "$REL" "$DBG"; do
  [ -f "$wf" ] || { echo "FAIL package parity: missing workflow $wf" >&2; exit 1; }
  need "$wf" 'bin/asb_dsp_attach'
  need "$wf" 'system/bin/asbdiag'
  need "$wf" 'runtime/asb_debug_support.sh'
done

# The helper is physically present in both packages because runtime/ is a module runtime
# dependency; its own installed module.prop check denies every release action.
need "$ROOT/runtime/asb_debug_support.sh" 'debug_only'

# Release must retain every normal on-device capture and support script. They are POSIX shell,
# are used by users to collect support evidence, and must not become debug-only.
for tool in \
  asb_diag.sh asb_kernel_uv_coexist.sh asb_doctor.sh asb_recents_probe.sh \
  asb_effective_policy.sh asb_intent.sh asb_config_backup.sh asb_state_sampler.sh \
  asb_drain_analyzer.sh asb_vendor_thermal_probe.sh asb_audit_state.sh asb_verify_device.sh; do
  need "$REL" "tools/$tool"
done
for tool in \
  _asb_logkit_common.sh asb_audio_ab.sh asb_log_battery_mixed.sh \
  asb_log_battery_sleep.sh asb_log_bgtrim_snapshot.sh asb_log_full_day.sh \
  asb_log_perf.sh asb_log_smart_daily.sh asb_log_smart_gaming.sh asb_log_smart_sleep.sh; do
  need "$REL" "tools/logkit/$tool"
done

# Host/Python analysis remains deliberately outside a flashable release ZIP.
for forbidden in tools/asb_field_report.py tools/asb_field_report.sh tools/asb_compare_sessions.py tools/asb_analyze.py; do
  need "$REL" "\"$forbidden\""
done
not_need "$REL" '"tools/logkit/"'

# The release manifest must describe the support paths that are needed after installation.
need "$REL" '"bin/asb_dsp_attach"'
need "$REL" '"tools/asb_config_backup.sh"'
need "$REL" '"tools/logkit/asb_log_full_day.sh"'

echo 'PASS debug/release functional package parity contract'
