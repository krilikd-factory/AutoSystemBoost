#!/usr/bin/env bash
# Full host-side regression for a source archive. Run from any working directory:
#   bash ./run_v64_active_efficiency_regression.sh
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT"
run() { echo "== $1 =="; shift; "$@"; }
run 'schema sync' bash tools/asb_schema_sync.sh check
run 'lint' env MODDIR="$ROOT" bash tools/asb_lint.sh
run 'native warning budget' env CC=clang bash tools/asb_native_warning_budget.sh
run 'config safety' bash tests/test_config_writer.sh
run 'camera grade capability' sh tests/test_camera_grade_contract.sh
run 'CPU deep-idle minimum OPP' sh tests/test_cpu_min_opp_contract.sh
run 'config lock lease' sh tests/test_config_lock_contract.sh
run 'named config profiles' sh tests/test_named_config_profiles.sh
run 'P0 provenance' sh tests/test_p0_provenance_contract.sh
run 'V64 P0' sh tests/test_v64_p0_contract.sh
run 'V64 WebUI Trial/Ledger' python3 tests/test_v64_webui_trial_ledger_contract.py
run 'V64 hardening integration' sh tests/test_v64_hardening_contract.sh
run 'active-efficiency capability envelope' sh tests/test_active_efficiency_contract.sh
run 'kernel/UV coexistence and debug identity' sh tests/test_kernel_uv_coexist_contract.sh
run 'Bluetooth lifecycle recorder' sh tests/test_bt_lifecycle_recorder_contract.sh
run 'profile helper packaging and UV WebUI' sh tests/test_profile_uv_webui_package_contract.sh
run 'workflow executable-mode normalization' sh tests/test_workflow_executable_modes_contract.sh
run 'workflow required-files shell' sh tests/test_workflow_required_files_shell.sh
run 'V62-to-V64 migration' bash tests/test_v62_to_v64_migration.sh
run 'release package tool contract' sh tests/test_release_package_tool_contract.sh
run 'device safety' sh tests/test_device_safety_contract.sh
run 'DSP reference' bash tests/test_dsp_reference_contract.sh
run 'native thermal fixture' bash -c 'clang -D_GNU_SOURCE -std=c11 -O2 -Wno-unused-function -I src tests/test_thermal_socd_validation.c -lm -o /tmp/asb_thermal_v64 && /tmp/asb_thermal_v64'
run 'effective policy JSON' bash -c 'MODDIR="$1" sh tools/asb_effective_policy.sh | python3 -m json.tool >/dev/null' _ "$ROOT"
python3 - <<'PY'
import yaml
for f in ['.github/workflows/build-release.yml', '.github/workflows/build-debug.yml']:
    with open(f, encoding='utf-8') as h:
        doc = yaml.safe_load(h)
    assert doc.get('jobs'), f
    print('PASS YAML', f)
PY
cmp -s tools/asb_diag.sh system/bin/asbdiag
echo 'ALL V64 ACTIVE-EFFICIENCY HOST REGRESSIONS PASSED'
