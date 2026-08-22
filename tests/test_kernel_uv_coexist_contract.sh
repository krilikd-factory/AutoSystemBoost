#!/bin/sh
# Contract: external kernel/UV coexistence detection is evidence-only and never owns voltage policy.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TOOL="$ROOT/tools/asb_kernel_uv_coexist.sh"
DIAG="$ROOT/tools/asb_diag.sh"
BIN_DIAG="$ROOT/system/bin/asbdiag"
DEBUG_WF="$ROOT/.github/workflows/build-debug.yml"
REL_WF="$ROOT/.github/workflows/build-release.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL kernel-uv coexistence: $*" >&2; exit 1; }
get() { grep -E "^$1=" "$1" 2>/dev/null; }
value() { grep -E "^$1=" "$2" 2>/dev/null | tail -1 | sed 's/^[^=]*=//'; }
run_probe() {
  ASB_SYSROOT="$TMP/sys" ASB_MODULES_ROOT="$TMP/modules" ASB_PROP_FILE="$TMP/props" \
    sh "$TOOL" > "$TMP/out"
}

[ -x "$TOOL" ] || fail "probe must be executable"
sh -n "$TOOL" || fail "probe syntax"
mkdir -p "$TMP/sys" "$TMP/modules"
: > "$TMP/props"
run_probe
[ "$(value status "$TMP/out")" = "not_observable" ] || fail "clean device must be not_observable"
[ "$(value asb_voltage_owner "$TMP/out")" = "external_or_vendor" ] || fail "ASB ownership wording"
# `opp` is generic operating-point metadata and appears in unrelated Bluetooth properties;
# it must never by itself produce an external voltage-policy verdict.
printf '%s\n' '[bluetooth.profile.opp.enabled]: [true]' > "$TMP/props"
run_probe
[ "$(value status "$TMP/out")" = "not_observable" ] || fail "Bluetooth OPP property is not UV evidence"
printf '%s\n' '[persist.kernel.cpu_voltage_offset]: [1]' > "$TMP/props"
run_probe
[ "$(value status "$TMP/out")" = "external_uv_hint" ] || fail "explicit voltage property should remain a hint"
: > "$TMP/props"
[ "$(value asb_action "$TMP/out")" = "diagnostics_only" ] || fail "diagnostics-only action"

mkdir -p "$TMP/modules/MyUV"
cat > "$TMP/modules/MyUV/module.prop" <<'EOF'
id=example_undervolt_kernel
name=Example Undervolt Kernel Controller
EOF
run_probe
[ "$(value status "$TMP/out")" = "external_uv_hint" ] || fail "external module should be a hint"
[ "$(value confidence "$TMP/out")" = "name_or_property_hint" ] || fail "module hint confidence"

rm -rf "$TMP/modules/MyUV"
mkdir -p "$TMP/sys/devices/system/cpu/cpufreq/policy0"
: > "$TMP/sys/devices/system/cpu/cpufreq/policy0/opp_voltage"
run_probe
[ "$(value status "$TMP/out")" = "voltage_surface_observed" ] || fail "readable voltage surface must be observed"
[ "$(value confidence "$TMP/out")" = "observed_surface" ] || fail "surface confidence"

# The executable body must not contain mutation commands. Comments are not policy paths.
if sed '/^[[:space:]]*#/d' "$TOOL" | grep -Eqi '(^|[;[:space:]])(setprop|mount|umount|chmod|chown|insmod|rmmod|dd)[[:space:]]|>[[:space:]]*/(sys|proc|data)'; then
  fail "probe contains a mutation primitive"
fi

grep -Fq 'frequency_temperature_or_kernel_name_alone_do_not_prove_undervolt' "$TOOL" || fail "uncertainty warning missing"
grep -Fq 'ASB does not own, write, validate, disable or revert external voltage policy' "$TOOL" || fail "non-ownership warning missing"
grep -Fq 'EXTERNAL KERNEL / UV COEXISTENCE' "$DIAG" || fail "asbdiag integration missing"
grep -Fq 'asb_kernel_uv_coexist.sh' "$DIAG" || fail "asbdiag helper invocation missing"
cmp -s "$DIAG" "$BIN_DIAG" || fail "asbdiag copies differ"

# Debug package identity changes only in staged package. It intentionally preserves base code.
grep -Fq 'ASB_VER="${BASE_VER}-debug${DEBUG_SEQ}"' "$DEBUG_WF" || fail "V64-debug1 naming contract missing"
grep -Fq 'DEBUG_CODE="$BASE_CODE"' "$DEBUG_WF" || fail "debug versionCode preservation missing"
grep -Fq 'sed -i "s/^version=.*/version=${ASB_VER}/" "$PKG_DBG/module.prop"' "$DEBUG_WF" || fail "staged version-only patch missing"
grep -Fq 'grep -qx "versionCode=${BASE_CODE}" "$PKG_DBG/module.prop"' "$DEBUG_WF" || fail "staged versionCode check missing"
! grep -Fq 'DEBUG_CODE=$((BASE_CODE + DEBUG_SEQ))' "$DEBUG_WF" || fail "legacy debug code ladder remains"

grep -Fq 'tools/asb_kernel_uv_coexist.sh' "$REL_WF" || fail "release package does not carry probe"
grep -Fq 'tools/asb_kernel_uv_coexist.sh' "$DEBUG_WF" || fail "debug package does not carry probe"

echo "PASS kernel/UV coexistence and V64-debug identity contract"
