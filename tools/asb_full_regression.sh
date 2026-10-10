#!/usr/bin/env bash
# Canonical host-side regression entry point for source archives and GitHub Actions.
# Run from any directory: bash tools/asb_full_regression.sh
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

run() { printf '\n== %s ==\n' "$1"; shift; "$@"; }
if [ -n "${CC:-}" ] && command -v "$CC" >/dev/null 2>&1; then
  HOST_CC="$CC"            # an explicit choice (CI passes clang) wins
elif command -v gcc >/dev/null 2>&1; then
  HOST_CC=gcc
elif command -v clang >/dev/null 2>&1; then
  HOST_CC=clang
else
  echo 'ERROR: gcc or clang is required for host C fixtures' >&2
  exit 1
fi
# Test scripts run in parallel (fix97).
#
# Run one after another the suite took ~2 minutes, and three runtime tests that wait on real
# timers (Wi-Fi fallback ~34 s, debug support ~18 s, LTPO video ~13 s) were 60 % of it. The
# scripts are independent - each works in its own mktemp directory - so they are queued here
# and run N at a time at the end. Output is buffered per test and printed in queue order, so
# the log reads exactly as before; a failure still names the test and fails the run.
# ASB_REGRESSION_JOBS=1 restores strictly sequential execution.
_Q_TITLE=(); _Q_CMD=()
queue() { _Q_TITLE+=("$1"); shift; _Q_CMD+=("$(printf '%q ' "$@")"); }
run_optional() {
  local title="$1" file="$2" shell="$3"
  [ -f "$file" ] || { printf 'ERROR: required regression file missing: %s\n' "$file" >&2; exit 1; }
  queue "$title" "$shell" "$file"
}
run_queue() {
  local jobs="${ASB_REGRESSION_JOBS:-}"
  if [ -z "$jobs" ]; then
    jobs="$(nproc 2>/dev/null || echo 2)"
    [ "$jobs" -lt 4 ] && jobs=4
    [ "$jobs" -gt 12 ] && jobs=12
  fi
  local out; out="$(mktemp -d)"
  local i n=${#_Q_CMD[@]} running=0
  for ((i = 0; i < n; i++)); do
    ( set +e; eval "${_Q_CMD[$i]}" >"$out/$i.log" 2>&1; echo $? >"$out/$i.rc" ) &
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then wait -n 2>/dev/null || true; running=$((running - 1)); fi
  done
  wait
  local failed=0 rc
  for ((i = 0; i < n; i++)); do
    printf '\n== %s ==\n' "${_Q_TITLE[$i]}"
    cat "$out/$i.log" 2>/dev/null
    rc="$(cat "$out/$i.rc" 2>/dev/null || echo 99)"
    if [ "$rc" != 0 ]; then
      printf 'FAILED: %s (exit %s)\n' "${_Q_TITLE[$i]}" "$rc" >&2
      failed=$((failed + 1))
    fi
  done
  rm -rf "$out"
  [ "$failed" -eq 0 ] || { printf '\n%d regression test(s) failed\n' "$failed" >&2; exit 1; }
}

run 'schema sync' bash tools/asb_schema_sync.sh check
run 'lint' env MODDIR="$ROOT" bash tools/asb_lint.sh
# The compiler selected above, not a hard-coded clang: a host with gcc only failed the whole
# regression here although every check passes (external audit, fix44).
run 'native warning budget' env CC="$HOST_CC" bash tools/asb_native_warning_budget.sh
run 'DSP syntax' bash tools/dsp_stubs/asb_dsp_syntax_check.sh

run_optional 'smart learner session 2' tests/test_smart_session2.sh bash
run_optional 'smart learner session 3' tests/test_smart_session3.sh bash
# Guards for the defects fixed in V64 - blend direction and overflow, config clamps,
# threshold ordering. Each cost a round of field logs to find; this catches a
# reintroduction at build time instead.
run_optional 'V64 regression contract' tests/test_v64_regression_contract.sh bash
run_optional 'DSP reference' tests/test_dsp_reference_contract.sh bash
run_optional 'device safety' tests/test_device_safety_contract.sh sh
run_optional 'donor telemetry boundary' tests/test_donor_telemetry_contract.sh sh
run_optional 'Quiet Night source' tests/test_quiet_night_skip.py python3
run 'Quiet Night behaviour build' "$HOST_CC" -O2 -o /tmp/asb_quiet_night tests/test_quiet_night_behaviour.c
run 'Quiet Night behaviour' /tmp/asb_quiet_night
run 'native config safety build' "$HOST_CC" -O2 -Wall -Wextra -Werror -o /tmp/asb_config_safety tests/test_config_safety.c
run 'native config safety' /tmp/asb_config_safety
run_optional 'config writer' tests/test_config_writer.sh bash
run 'native thermal fixture' env HOST_CC="$HOST_CC" bash -c '"$HOST_CC" -D_GNU_SOURCE -std=c11 -O2 -Wno-unused-function -I src tests/test_thermal_socd_validation.c -lm -o /tmp/asb_thermal && /tmp/asb_thermal'

run_optional 'P0 provenance' tests/test_p0_provenance_contract.sh sh
run_optional 'V64 P0' tests/test_v64_p0_contract.sh sh
run_optional 'V64 WebUI Trial/Ledger' tests/test_v64_webui_trial_ledger_contract.py python3
run_optional 'quick restart' tests/test_quick_restart_contract.sh bash
for test_file in \
  tests/test_config_lock_contract.sh \
  tests/test_config_ownership_registry.sh \
  tests/test_camera_grade_contract.sh \
  tests/test_cpu_min_opp_contract.sh \
  tests/test_named_config_profiles.sh \
  tests/test_smart_reset_complete_contract.sh \
  tests/test_v64_hardening_contract.sh \
  tests/test_reversible_settings_contract.sh \
  tests/test_v65_efficiency_contract.sh \
  tests/test_v65_smart_thermal_cap_contract.sh \
  tests/test_bt_safe_policy_contract.sh \
  tests/test_project_safety_hardening_contract.sh \
  tests/test_wakelock_watch_safety_contract.sh \
  tests/test_active_efficiency_contract.sh \
  tests/test_kernel_uv_coexist_contract.sh \
  tests/test_bt_lifecycle_recorder_contract.sh \
  tests/test_logkit_capture_quality_contract.sh \
  tests/test_profile_uv_webui_package_contract.sh \
  tests/test_workflow_executable_modes_contract.sh \
  tests/test_workflow_required_files_shell.sh \
  tests/test_release_package_tool_contract.sh \
  tests/test_package_functional_parity_contract.sh \
  tests/test_network_handover_contract.sh \
  tests/test_uninstall_dsp_prop_cleanup_contract.sh \
  tests/test_writer_ceiling_below_min_contract.sh \
  tests/test_wifi_scan_rungs_contract.sh \
  tests/test_gnss_foreground_contract.sh \
  tests/test_uclamp_gmin_drift_contract.sh \
  tests/test_cpu_gpu_portability_contract.sh \
  tests/test_arbiter.sh \
  tests/test_intent_backup.sh \
  tests/test_service_thermal_vm_contract.sh; do
  run_optional "$(basename "$test_file" .sh)" "$test_file" sh
done
run_optional 'debug support' tests/test_debug_support_contract.sh bash
run_optional 'active Wi-Fi fallback runtime' tests/test_active_wifi_fallback_runtime.sh bash
run_optional 'force-LTPO contract' tests/test_ltpo_contract.sh bash
run_optional 'multimedia-telemetry contract' tests/test_mmfeed_contract.sh bash
run_optional 'net congestion verdict contract' tests/test_net_verdict_contract.sh bash
run_optional 'LPM wakeup gate contract' tests/test_lpm_gate_contract.sh bash
run_optional 'uevent accounting contract' tests/test_uevent_accounting_contract.sh bash
run_optional 'update/fallback/theme contract' tests/test_update_handover_theme_contract.sh bash
run_optional 'snapshot-only update migration' tests/test_update_snapshot_only_migration.sh bash
run_optional 'Stock profile' tests/test_stock_profile_contract.sh sh
run_optional 'V62-to-V64 migration' tests/test_v62_to_v64_migration.sh bash
# Every remaining contract, so a new test is a CI gate the day it is added. The explicit
# list above kept its order and shells; a test missing from it used to run only by hand -
# fifteen field-fix contracts were outside CI that way (external audit, fix44).
_listed="$(grep -oE 'tests/test_[A-Za-z0-9_]+\.sh' "$0" | sort -u)"
for test_file in tests/test_*.sh; do
  printf '%s\n' "$_listed" | grep -qxF "$test_file" && continue
  queue "$(basename "$test_file" .sh)" bash "$test_file"
done
run_queue
run 'effective policy JSON' bash -c 'MODDIR="$1" sh tools/asb_effective_policy.sh | python3 -m json.tool >/dev/null' _ "$ROOT"
cmp -s tools/asb_diag.sh system/bin/asbdiag || { echo 'ERROR: asbdiag copies differ' >&2; exit 1; }
printf '\nALL ASB HOST REGRESSIONS PASSED\n'
