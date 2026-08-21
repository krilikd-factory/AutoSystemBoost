#!/usr/bin/env bash
# Canonical host-side regression entry point for source archives and GitHub Actions.
# Run from any directory: bash tools/asb_full_regression.sh
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

run() { printf '\n== %s ==\n' "$1"; shift; "$@"; }
if command -v gcc >/dev/null 2>&1; then
  HOST_CC=gcc
elif command -v clang >/dev/null 2>&1; then
  HOST_CC=clang
else
  echo 'ERROR: gcc or clang is required for host C fixtures' >&2
  exit 1
fi
run_optional() {
  local title="$1" file="$2" shell="$3"
  [ -f "$file" ] || { printf 'ERROR: required regression file missing: %s\n' "$file" >&2; exit 1; }
  run "$title" "$shell" "$file"
}

run 'schema sync' bash tools/asb_schema_sync.sh check
run 'lint' env MODDIR="$ROOT" bash tools/asb_lint.sh
run 'native warning budget' env CC=clang bash tools/asb_native_warning_budget.sh
run 'DSP syntax' bash tools/dsp_stubs/asb_dsp_syntax_check.sh

run_optional 'smart learner session 2' tests/test_smart_session2.sh bash
run_optional 'smart learner session 3' tests/test_smart_session3.sh bash
run_optional 'DSP reference' tests/test_dsp_reference_contract.sh bash
run_optional 'device safety' tests/test_device_safety_contract.sh sh
run_optional 'donor telemetry boundary' tests/test_donor_telemetry_contract.sh sh
run_optional 'Quiet Night source' tests/test_quiet_night_skip.py python3
run 'Quiet Night behaviour build' "$HOST_CC" -O2 -o /tmp/asb_quiet_night tests/test_quiet_night_behaviour.c
run 'Quiet Night behaviour' /tmp/asb_quiet_night
run 'native config safety build' "$HOST_CC" -O2 -Wall -Wextra -Werror -o /tmp/asb_config_safety tests/test_config_safety.c
run 'native config safety' /tmp/asb_config_safety
run_optional 'config writer' tests/test_config_writer.sh bash
run 'native thermal fixture' bash -c 'clang -D_GNU_SOURCE -std=c11 -O2 -Wno-unused-function -I src tests/test_thermal_socd_validation.c -lm -o /tmp/asb_thermal && /tmp/asb_thermal'

run_optional 'P0 provenance' tests/test_p0_provenance_contract.sh sh
run_optional 'V64 P0' tests/test_v64_p0_contract.sh sh
run_optional 'V64 WebUI Trial/Ledger' tests/test_v64_webui_trial_ledger_contract.py python3
for test_file in \
  tests/test_config_lock_contract.sh \
  tests/test_camera_grade_contract.sh \
  tests/test_cpu_min_opp_contract.sh \
  tests/test_named_config_profiles.sh \
  tests/test_v64_hardening_contract.sh \
  tests/test_active_efficiency_contract.sh \
  tests/test_kernel_uv_coexist_contract.sh \
  tests/test_bt_lifecycle_recorder_contract.sh \
  tests/test_profile_uv_webui_package_contract.sh \
  tests/test_workflow_executable_modes_contract.sh \
  tests/test_workflow_required_files_shell.sh \
  tests/test_release_package_tool_contract.sh \
  tests/test_arbiter.sh \
  tests/test_intent_backup.sh \
  tests/test_service_thermal_vm_contract.sh; do
  run_optional "$(basename "$test_file" .sh)" "$test_file" sh
done
run_optional 'V62-to-V64 migration' tests/test_v62_to_v64_migration.sh bash
run 'effective policy JSON' bash -c 'MODDIR="$1" sh tools/asb_effective_policy.sh | python3 -m json.tool >/dev/null' _ "$ROOT"
cmp -s tools/asb_diag.sh system/bin/asbdiag || { echo 'ERROR: asbdiag copies differ' >&2; exit 1; }
printf '\nALL ASB HOST REGRESSIONS PASSED\n'
