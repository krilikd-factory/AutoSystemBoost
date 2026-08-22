#!/bin/sh
# Contract: active-use efficiency must be capability-gated, monotonic and reversible.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GEN="$ROOT/runtime/asb_active_efficiency_envelope.sh"
SRC="$ROOT/src/asb_governor.c"
SERVICE="$ROOT/service.sh"
DIAG="$ROOT/tools/asb_diag.sh"
BIN_DIAG="$ROOT/system/bin/asbdiag"
EFFECTIVE="$ROOT/tools/asb_effective_policy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL active-efficiency: $*" >&2; exit 1; }
get() { grep -E "^$1=" "$2" 2>/dev/null | tail -1 | sed 's/^[^=]*=//'; }
mkcaps() {
  cat > "$TMP/device_caps.env" <<EOF
soc_platform=$1
cpu_policy_count=$2
gpu_backend=$3
thermal_zone_count=$4
EOF
}
run_case() {
  _soc="$1" _pol="$2" _gpu="$3" _zones="$4"
  mkcaps "$_soc" "$_pol" "$_gpu" "$_zones"
  ASB_CONFIG_STATE="$TMP" sh "$GEN" >/dev/null 2>&1 || fail "generator execution ($_soc)"
}
assert_monotonic() {
  _light="$(get budget_light_bonus_pct "$TMP/active_efficiency.env")"
  _moderate="$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")"
  _severe="$(get budget_severe_bonus_pct "$TMP/active_efficiency.env")"
  [ "$_moderate" -ge "$_light" ] 2>/dev/null || fail "nonmonotonic light/moderate envelope"
  [ "$_severe" -ge "$_moderate" ] 2>/dev/null || fail "nonmonotonic moderate/severe envelope"
}

[ -x "$GEN" ] || fail "generator is not executable"
sh -n "$GEN" || fail "generator syntax"

run_case sm8750 2 devfreq 24
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "SM8750 should be active"
[ "$(get tier "$TMP/active_efficiency.env")" = "sm8750" ] || fail "SM8750 tier"
[ "$(get budget_light_bonus_pct "$TMP/active_efficiency.env")" = "1" ] || fail "SM8750 light bonus"
[ "$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")" = "2" ] || fail "SM8750 moderate bonus"
[ "$(get budget_severe_bonus_pct "$TMP/active_efficiency.env")" = "2" ] || fail "SM8750 severe bonus"
assert_monotonic

run_case sm8850 2 pwrlevel 98
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "SM8850 should be active"
[ "$(get tier "$TMP/active_efficiency.env")" = "sm8850" ] || fail "SM8850 tier"
[ "$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")" = "2" ] || fail "SM8850 moderate bonus"
[ "$(get budget_severe_bonus_pct "$TMP/active_efficiency.env")" = "2" ] || fail "SM8850 severe bonus"
assert_monotonic

run_case sm8650 3 pwrlevel 22
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "SM8650 should be active"
[ "$(get tier "$TMP/active_efficiency.env")" = "sm8650" ] || fail "SM8650 tier"
[ "$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")" = "3" ] || fail "SM8650 moderate bonus"
[ "$(get bg_uclamp_moderate_delta "$TMP/active_efficiency.env")" = "64" ] || fail "SM8650 bg moderate delta"
[ "$(get bg_uclamp_severe_delta "$TMP/active_efficiency.env")" = "128" ] || fail "SM8650 bg severe delta"
[ "$(get budget_severe_bonus_pct "$TMP/active_efficiency.env")" = "3" ] || fail "SM8650 severe bonus"
assert_monotonic

run_case sm8550 3 devfreq 20
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "SM8550 should be active"
[ "$(get tier "$TMP/active_efficiency.env")" = "sm8550" ] || fail "SM8550 tier"
[ "$(get gpu_idle_trim_bonus_pct "$TMP/active_efficiency.env")" = "1" ] || fail "SM8550 gpu bonus"
assert_monotonic

# A complete but unnamed platform gets only the universal capability baseline: it is
# percentage/uclamp-only and strictly smaller than family-specific tiers.
run_case sm9999 3 devfreq 20
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "complete unknown SoC should use capability baseline"
[ "$(get tier "$TMP/active_efficiency.env")" = "capability" ] || fail "capability baseline tier"
[ "$(get reason "$TMP/active_efficiency.env")" = "capability_baseline" ] || fail "capability baseline reason"
[ "$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")" = "1" ] || fail "capability baseline moderate bonus"
[ "$(get bg_uclamp_moderate_delta "$TMP/active_efficiency.env")" = "32" ] || fail "capability baseline bg delta"
assert_monotonic

run_case sm8650 1 devfreq 20
[ "$(get status "$TMP/active_efficiency.env")" = "generic" ] || fail "insufficient CPU topology must be no-op"
[ "$(get reason "$TMP/active_efficiency.env")" = "missing_cpu_gpu_or_thermal_capability" ] || fail "missing capability reason"

# No raw frequency/voltage writes belong in the derived policy generator.
if sed '/^[[:space:]]*#/d' "$GEN" | grep -Eqi 'undervolt|voltage|scaling_max_freq|khz'; then
  fail "generator must remain percentage/uclamp-only"
fi

# Native loader is strict; policy stays inside established thermal/GPU exclusions.
grep -Fq 'ACTIVE_EFFICIENCY_FILE' "$SRC" || fail "native manifest path missing"
grep -Fq 'asb_active_efficiency_load();' "$SRC" || fail "native loader not called"
grep -Fq 'strcmp(g_active_efficiency.tier, "sm8850")' "$SRC" || fail "native SM8850 tier allowlist missing"
grep -Fq 'strcmp(g_active_efficiency.tier, "capability")' "$SRC" || fail "native capability tier allowlist missing"
grep -Fq 'manifest_nonmonotonic' "$SRC" || fail "native monotonic guard missing"
grep -Fq 'fsm->profile_idx != PROFILE_PERFORMANCE' "$SRC" || fail "GPU performance exclusion missing"
grep -Fq 'fsm->state == ASB_STATE_SUSTAINED' "$SRC" || fail "platform thermal exclusion missing"
grep -Fq 'if (target < 128) target = 128;' "$SRC" || fail "background uclamp floor missing"
grep -Fq '!g_asb_cfg.thermal_budget_enable || !g_active_efficiency.active' "$SRC" || fail "thermal budget user opt-out gate missing"
# Screen-on comfort may only add the already-configured light trim with evidence. It must
# fail closed outside Battery/battery-lean Smart and never touch gaming, camera, charging or sleep.
grep -Fq '"screenon_comfort"' "$SRC" || fail "screen-on comfort reason missing"
grep -Fq 'm->misc.screen_on && !m->misc.camera_active' "$SRC" || fail "screen-on/camera exclusion missing"
grep -Fq 'fsm->state != ASB_STATE_GAMING' "$SRC" || fail "gaming exclusion missing"
grep -Fq 'if (g_asb_cfg.thermal_budget_enable && !fsm->thermal_cap &&' "$SRC" || fail "comfort path must remain thermal-cap gated"
grep -Fq 'fsm->state != ASB_STATE_SUSTAINED) {' "$SRC" || fail "SUSTAINED game-safety exclusion missing"
grep -Fq 'm->bat.current_ma >= 450' "$SRC" || fail "current evidence gate missing"
grep -Fq 'fsm->profile_idx == PROFILE_BATTERY' "$SRC" || fail "Battery profile gate missing"
grep -Fq 'g_asb_cfg.smart_battery_bias >= 400' "$SRC" || fail "battery-lean Smart gate missing"
# Media recovery may use the existing light trim only after fresh, positively recognised media
# context. Every QoS/liveness exclusion is independent and must remain explicit.
grep -Fq '"media_recovery"' "$SRC" || fail "media recovery reason missing"
grep -Fq 'fsm->state == ASB_STATE_SUSTAINED' "$SRC" || fail "media recovery sustained gate missing"
grep -Fq 'fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled' "$SRC" || fail "media recovery Smart gate missing"
grep -Fq 'g_pkg_detect_ok && g_smart_media_pkg_known' "$SRC" || fail "media recovery fresh-media gate missing"
grep -Fq 'g_smart_rt.app_hint < ASB_APP_GAMING' "$SRC" || fail "media recovery game exclusion missing"
grep -Fq '!m->misc.camera_active && !m->bat.charging' "$SRC" || fail "media recovery camera/charging exclusion missing"
grep -Fq 'm->bat.current_ma >= 450' "$SRC" || fail "media recovery current evidence gate missing"
grep -Fq 'active_efficiency_active=%d' "$SRC" || fail "state telemetry missing"

# The derived manifest must exist before asb_utils.sh starts the governor.
_pre="$(grep -n 'asb_active_efficiency_envelope.sh' "$SERVICE" | head -1 | cut -d: -f1)"
_utils="$(grep -n 'runtime/asb_utils.sh' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_pre" ] && [ -n "$_utils" ] && [ "$_pre" -lt "$_utils" ] || fail "manifest is not prepared before governor start"

grep -Fq 'active-use envelope' "$DIAG" || fail "diagnostic envelope section missing"
grep -Fq 'active-use runtime' "$DIAG" || fail "diagnostic runtime telemetry missing"
grep -Fq '"active_efficiency"' "$EFFECTIVE" || fail "effective-policy JSON telemetry missing"
grep -Fq 'thermal_budget_envelope_bonus_pct' "$EFFECTIVE" || fail "effective-policy staged budget telemetry missing"
cmp -s "$DIAG" "$BIN_DIAG" || fail "asbdiag copies differ"

echo "PASS active-efficiency capability contract"
