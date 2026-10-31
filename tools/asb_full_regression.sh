#!/usr/bin/env bash
# Canonical host-side regression entry point for source archives and GitHub Actions.
# Run from any directory: bash tools/asb_full_regression.sh
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

# Make the validation contract visible before any test output. SOURCE_ONLY skips only the
# byte-for-byte DSP reference staging check; release/strict runs never set the optional flag.
if [ "${ASB_DSP_REFERENCE_OPTIONAL:-0}" = "1" ]; then
  printf 'MODE=SOURCE_ONLY\nreference prebuilts: optional\n'
elif [ -n "$(find src/DSP_AIDL/prebuilt -type f -print -quit 2>/dev/null)" ]; then
  printf 'MODE=RELEASE_STRICT\nreference prebuilts: strict\n'
else
  printf 'MODE=RELEASE_STRICT\nreference prebuilts: absent\n'
fi

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

# The host tests live in six suites (tests/asb_*.sh, fix164/fix267); each test is a function
# that runs in its own subshell, so every test is still queued on its own and runs in parallel.
export HOST_CC
for suite in tests/asb_*.sh; do
  area="$(basename "$suite" .sh)"; area="${area#asb_}"
  for name in $(bash "$suite" --list); do
    queue "$area: $name" bash "$suite" "$name"
  done
done
[ "${#_Q_CMD[@]}" -gt 0 ] || { echo 'ERROR: no host tests found in tests/asb_*.sh' >&2; exit 1; }
run_queue
run 'effective policy JSON' bash -c 'MODDIR="$1" sh tools/asb_effective_policy.sh | python3 -m json.tool >/dev/null' _ "$ROOT"
cmp -s tools/asb_diag.sh system/bin/asbdiag || { echo 'ERROR: asbdiag copies differ' >&2; exit 1; }
printf '\nALL ASB HOST REGRESSIONS PASSED\n'
