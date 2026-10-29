#!/usr/bin/env bash
# ASB host tests: Install, config, updates, packaging, CI and the field-fix contracts.
#
# Each test is a function t_<name> whose body runs in its own subshell, exactly as the
# standalone script it used to be; the C fixtures it builds are the functions _c_<name>.
#   bash tests/asb_system.sh                 run every test in this file
#   bash tests/asb_system.sh NAME [NAME...]  run the named tests
#   bash tests/asb_system.sh --list          list the tests
#   bash tests/asb_system.sh --source NAME   print an embedded C fixture
# tools/asb_full_regression.sh runs every test of every tests/asb_*.sh in parallel.

_c_config_safety() {
  cat <<'ASB_C_EOF'
#include <stdio.h>
#include <string.h>
#include "asb_config.h"

static int load_text(const char *path, const char *text, asb_runtime_config_t *cfg) {
    FILE *f = fopen(path, "w");
    if (!f) return -99;
    fputs(text, f);
    fclose(f);
    asb_config_defaults(cfg);
    return asb_config_load_file(path, cfg);
}

int main(void) {
    /* asb_config.h declares this static app-heat flag for the production
     * governor. This standalone parser test does not otherwise consume it;
     * mark it used so GCC -Wall -Wextra -Werror in CI checks the test logic,
     * rather than rejecting an unrelated header-local symbol. */
    (void)g_asb_appheat_hot;

    const char *path = "/tmp/asb_config_safety_test.conf";
    asb_runtime_config_t cfg;

    const char *valid =
        "sustained_temp_enter=65\n"
        "sustained_temp_exit=55\n"
        "quiet_tick_s=30\n"
        "quiet_entry_ticks=60\n"
        "quiet_exit_grace=3\n"
        "night_quiet_hour_start=23\n"
        "night_quiet_hour_end=6\n"
        "heavy_min_dwell_s=8\n"
        "sustained_min_dwell_s=24\n"
        "gaming_min_dwell_s=25\n"
        "reassert_heavy_s=12\n"
        "reassert_gaming_s=6\n"
        "perf_hot_guard_ticks=0\n"
        "camera_hold_max_s=180\n"
        "auto_battery_low_pct=20\n"
        "auto_battery_high_pct=30\n"
        "auto_battery_min_gap_s=300\n";

    if (load_text(path, valid, &cfg) != 0) return 1;
    if (load_text(path, "sustained_temp_enter=65\nsustained_temp_enter=64\n", &cfg) != -3) return 2;
    if (load_text(path, "quiet_tick_s=0\n", &cfg) == 0) return 3;
    if (load_text(path, "sustained_temp_enter=40\nsustained_temp_exit=75\n", &cfg) == 0) return 4;
    if (load_text(path, "night_quiet_hour_start=99\n", &cfg) == 0) return 5;
    /* The writer has matching shell validation, but the native parser remains
     * the final trust boundary for manual edits and malformed imports. */
    if (load_text(path, "thermal_overlay_pct=999\n", &cfg) == 0) return 6;
    if (load_text(path, "thermal_junction_hard_c=0\n", &cfg) == 0) return 7;
    if (load_text(path, "thermal_skin_c=66\n", &cfg) == 0) return 8;
    if (load_text(path, "camera_busy_pct=0\n", &cfg) == 0) return 9;
    if (load_text(path, "smart_conf_low=700\nsmart_conf_high=650\n", &cfg) == 0) return 10;
    if (load_text(path, "thermal_budget_light_headroom_pct=40\nthermal_budget_moderate_headroom_pct=50\n", &cfg) == 0) return 11;
    if (load_text(path, "thermal_budget_severe_trim_pct=99\n", &cfg) == 0) return 12;
    if (load_text(path, "thermal_budget_dwell_s=0\n", &cfg) == 0) return 13;
    if (load_text(path, "shadow_mode=2\n", &cfg) == 0) return 14;

    /* ASB-01: ceiling and enter must be independent of persisted key order. */
    if (load_text(path, "sustained_temp_ceiling=68\nsustained_temp_enter=65\n", &cfg) != 0 ||
        cfg.sustained_temp_enter != 65 || cfg.sustained_temp_enter_user != 68) return 15;
    if (load_text(path, "sustained_temp_enter=65\nsustained_temp_ceiling=68\n", &cfg) != 0 ||
        cfg.sustained_temp_enter != 65 || cfg.sustained_temp_enter_user != 68) return 16;
    /* A stale/lower ceiling is normalized up to the active safety threshold. */
    if (load_text(path, "sustained_temp_ceiling=62\nsustained_temp_enter=65\n", &cfg) != 0 ||
        cfg.sustained_temp_enter_user != 65) return 17;

    /* ASB-04: manual config/import data reaches native code; malformed values
     * must not silently become zero or a non-finite FSM threshold. */
    if (load_text(path, "heavy_load_enter=nan\n", &cfg) == 0) return 18;
    if (load_text(path, "heavy_load_enter=inf\n", &cfg) == 0) return 19;
    if (load_text(path, "gpu_idle_trim_pct=-100\n", &cfg) == 0) return 20;
    if (load_text(path, "gpu_video_max_pct=999\n", &cfg) == 0) return 21;
    if (load_text(path, "gaming_confirm_ticks=0\n", &cfg) == 0) return 22;
    if (load_text(path, "thermal_throttle_temp=0\n", &cfg) == 0) return 23;
    if (load_text(path, "device_bounds_override=999\n", &cfg) == 0) return 24;

    asb_config_defaults(&cfg);
    cfg.sustained_level = 0.62f;
    cfg.sustained_level_user_set = 1;
    asb_config_apply_burst_override(&cfg);
    if (cfg.sustained_level != 0.62f) return 25;
    asb_config_apply_stable_override(&cfg);
    if (cfg.sustained_level != 0.62f) return 26;

    remove(path);
    puts("PASS config safety");
    return 0;
}
ASB_C_EOF
}

t_arbiter() (
# arbiter — lease priority and camera ownership regression.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_arbiter.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

export ASB_ARBITER_DIR="$TMP/leases"
export ASB_ARBITER_EVENTS="$TMP/events.jsonl"
export ASB_ARBITER_LOCK="$TMP/leases/.lock"
export ASB_CAMERA_GUARD="$TMP/camera_guard"
# Sourced: command-mode dispatcher is intentionally not invoked.
# shellcheck disable=SC1091
. "$ROOT_DIR/runtime/asb_arbiter.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

asb_arbiter_claim cpu_cap profile 30 60 profile_apply || fail 'profile cpu_cap claim'
asb_arbiter_can_write cpu_cap profile || fail 'same owner may write'
if asb_arbiter_can_write cpu_cap smart; then fail 'lower Smart owner bypassed profile lease'; fi
asb_arbiter_can_write cpu_cap safety || fail 'safety owner could not preempt profile'
asb_arbiter_claim cpu_cap safety 80 60 thermal_guard || fail 'safety preemption failed'
if asb_arbiter_can_write cpu_cap profile; then fail 'profile bypassed safety lease'; fi

# A zero-TTL lease is immediately expired and must not block a later normal claim.
asb_arbiter_claim temporary user_cap 40 0 one_shot || fail 'zero ttl claim failed'
asb_arbiter_can_write temporary smart || fail 'expired lease blocked Smart owner'

: > "$ASB_CAMERA_GUARD"
if asb_arbiter_can_write cpuset_fg profile; then fail 'profile bypassed camera cpuset lease'; fi
if asb_arbiter_can_write uclamp_max profile; then fail 'profile bypassed camera uclamp lease'; fi
asb_arbiter_can_write cpuset_fg camera || fail 'camera could not own cpuset'
asb_arbiter_can_write uclamp_max camera || fail 'camera could not own uclamp'
rm -f "$ASB_CAMERA_GUARD"
asb_arbiter_can_write cpuset_fg profile || fail 'profile remained blocked after camera release'

asb_arbiter_claim cpuset_fg profile 30 60 profile_apply || fail 'cpuset profile claim'
asb_arbiter_note cpuset_fg profile profile_apply 0-7 0-7 applied || fail 'lease applied note'
LEASE="$ASB_ARBITER_DIR/cpuset_fg.lease"
grep -qx 'desired=0-7' "$LEASE" || fail 'desired state missing'
grep -qx 'applied=0-7' "$LEASE" || fail 'applied state missing'
grep -qx 'last_error=none' "$LEASE" || fail 'last error state missing'
grep -q '"action":"claim"' "$ASB_ARBITER_EVENTS" || fail 'claim telemetry missing'
grep -q '"resource":"cpuset_fg"' "$ASB_ARBITER_EVENTS" || fail 'write telemetry missing'

echo 'PASS arbiter'
)

t_camera_boot_regrade_runtime() (
# Runtime: the boot pass (asb_apply_dynamic_tweaks) grades the module-root camera copy
# (odm/etc/camera/... - the file the bind payload follows) from a STOCK baseline with the
# current settings; a graded baseline is dropped instead of being graded again; the install
# pass reads the running module's settings, not the staging dir's shipped config.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL camera boot regrade: $*" >&2; fail=1; }
MD="$T/modules/AutoSystemBoost"
mkdir -p "$MD/config" "$MD/runtime" "$MD/odm/etc/camera" "$T/base" "$T/bin"
cp "$ROOT/runtime/asb_camera_grade.sh" "$MD/runtime/"
echo CAMERA=1 > "$MD/features.conf"
printf 'CAMERA_LEVEL=10\nCAMERA_GRAIN=3\nCAMERA_CONTRAST=3\nCAMERA_PORTRAIT=0\nCAMERA_LOWLIGHT=0\n' > "$MD/config/governor.conf"
printf '#!/bin/sh\necho canoe\n' > "$T/bin/getprop"; chmod +x "$T/bin/getprop"
export PATH="$T/bin:$PATH"
STOCK='{
  "EnhanceNetParamsSet": 1,
  "Main1x_Rgb2YuvParams": [0.299, 0.587, 0.114, -0.168736, -0.331264, 0.5, 0.5, -0.418688, -0.081312],
  "BlendWeight": [0.35, 0.5, 0.7],
  "SatuColorScale": 1.0
}'
CT="$MD/odm/etc/camera/conf_tuning_params.json"
printf '%s\n' "$STOCK" > "$CT"

run() {
  ( set +u; . "$ROOT/runtime/asb_tweaks.sh"; ASB_TWEAK_BASE_DIR="$T/base"
    asb_log() { :; }
    MODDIR="$MD"; export MODDIR; asb_apply_dynamic_tweaks "$1" ) >"$T/run.log" 2>&1
}
bw() { grep -m1 -o '"BlendWeight"[^]]*]' "$1" | sed 's/.*\[//;s/\]//'; }

# Base naming: module-root and system/ copies, installed or staged, share one name.
( . "$ROOT/runtime/asb_tweaks.sh"; ASB_TWEAK_BASE_DIR=/b
  a="$(asb_tw_base_path /data/adb/modules/AutoSystemBoost/odm/etc/camera/x.json)"
  b="$(asb_tw_base_path /data/adb/modules_update/AutoSystemBoost/odm/etc/camera/x.json)"
  c="$(asb_tw_base_path /data/adb/modules/AutoSystemBoost/system/odm/etc/camera/x.json)"
  d="$(asb_tw_base_path /data/adb/modules/AutoSystemBoost/system/vendor/odm/etc/camera/x.json)"
  [ "$a" = /b/odm_etc_camera_x.json.asbbase ] && [ "$a" = "$b" ] && [ "$a" = "$c" ] \
    && [ "$d" = /b/vendor_odm_etc_camera_x.json.asbbase ] ) || f "baseline names differ between copies"

# 1. Fresh: stock module copy -> baseline captured, copy graded.
run "$MD"
[ "$(bw "$CT")" = "1, 1, 1" ] || f "module-root copy not graded at boot (BlendWeight $(bw "$CT"))"
[ "$(bw "$T/base/odm_etc_camera_conf_tuning_params.json.asbbase")" = "0.35, 0.5, 0.7" ] || f "stock baseline not captured"

# 2. Re-run: idempotent (graded from the stock base, not from the graded copy).
cp "$CT" "$T/first"
run "$MD"
cmp -s "$CT" "$T/first" || f "second boot changed the table again (compounding)"

# 3. A graded baseline (left by older installs) is dropped, never graded from.
cp "$T/first" "$T/base/odm_etc_camera_conf_tuning_params.json.asbbase"
run "$MD"
[ -f "$T/base/odm_etc_camera_conf_tuning_params.json.asbbase" ] \
  && ! grep -q -- '-0.1687' "$T/base/odm_etc_camera_conf_tuning_params.json.asbbase" \
  && f "graded baseline kept"
grep -q -- '-0.42184' "$CT" && ! grep -q -- '-1.05' "$CT" || f "table graded from a graded baseline: $(grep -o '"Main1x_Rgb2YuvParams"[^]]*]' "$CT")"

# 4. Settings change (stock level) -> back to stock from the baseline.
printf '%s\n' "$STOCK" > "$CT"; rm -f "$T/base/"*
run "$MD"
sed -i 's/CAMERA_LEVEL=10/CAMERA_LEVEL=0/' "$MD/config/governor.conf"
run "$MD"
[ "$(bw "$CT")" = "0.35, 0.5, 0.7" ] || f "level 0 did not restore stock (BlendWeight $(bw "$CT"))"

# 5. No forced baseline save at install (that is what stored the graded file as "stock").
sed -n '/^asb_save_dynamic_baselines()/,/^}/p' "$ROOT/runtime/asb_tweaks.sh" \
  | grep -q 'conf_tuning_params.json' || f "baseline saver no longer covers the camera"
sed -n '/^asb_save_dynamic_baselines()/,/^}/p' "$ROOT/runtime/asb_tweaks.sh" \
  | grep -q 'asb_tw_save_base "$_cam" force' && f "camera baseline still force-saved after grading"
grep -q '_cam_conf=/data/adb/modules/AutoSystemBoost/config/governor.conf' "$ROOT/runtime/asb_tweaks.sh" \
  || f "install pass grades from the staging dir's shipped config"

# 6. fix127: the installer runs the baseline saver (audio section) BEFORE it clones the camera
# files, so the fresh staging dir has no camera copy yet. The orphan prune deleted the stock
# camera baseline there, the clone then fell back to the live file - the previous install's
# graded overlay - and every second install printed "camera colour graded from a previous
# build, install again" (OP15 install logs alternate exactly so). A stock camera baseline
# survives the prune; a graded one and a real orphan do not.
ST="$T/stage/AutoSystemBoost"; mkdir -p "$ST" "$T/b6"
printf '%s\n' "$STOCK" > "$T/b6/odm_etc_camera_conf_tuning_params.json.asbbase"
printf '%s\n' "$STOCK" > "$T/b6/vendor_odm_etc_camera_conf_tuning_params.json.asbbase"
printf '%s\n' "$STOCK" | sed 's/-0.168736/-0.1/' > "$T/b6/system_odm_bad_conf_tuning_params.json.asbbase"
echo old > "$T/b6/vendor_etc_audio_mixer_paths_gone.xml.asbbase"
( set +u; . "$ROOT/runtime/asb_tweaks.sh"; ASB_TWEAK_BASE_DIR="$T/b6"; asb_save_dynamic_baselines "$ST" ) >/dev/null 2>&1
[ -f "$T/b6/odm_etc_camera_conf_tuning_params.json.asbbase" ] || f "stock camera baseline pruned before the clone"
[ -f "$T/b6/vendor_odm_etc_camera_conf_tuning_params.json.asbbase" ] || f "stock vendor camera baseline pruned"
[ -f "$T/b6/system_odm_bad_conf_tuning_params.json.asbbase" ] && f "graded camera baseline kept by the prune"
[ -f "$T/b6/vendor_etc_audio_mixer_paths_gone.xml.asbbase" ] && f "real orphan kept"
# ...and since a baseline now lives across installs, it carries the ROM build it came from: a
# stock table from before an OTA is not this ROM's stock and must not be graded into the new one.
printf '%s\n' "$STOCK" > "$T/b6/odm_etc_camera_conf_tuning_params.json.asbbase"
echo "OnePlus/old:15/AP3A.240617.008/release-keys" > "$T/b6/odm_etc_camera_conf_tuning_params.json.asbbase.rom"
( set +u; . "$ROOT/runtime/asb_tweaks.sh"; ASB_TWEAK_BASE_DIR="$T/b6"; asb_save_dynamic_baselines "$ST" ) >/dev/null 2>&1
[ -f "$T/b6/odm_etc_camera_conf_tuning_params.json.asbbase" ] && f "baseline from another ROM build kept"
[ -f "$T/b6/odm_etc_camera_conf_tuning_params.json.asbbase.rom" ] && f "stale ROM stamp left behind"
mkdir -p "$T/s7/AutoSystemBoost/odm/etc/camera"; printf '%s\n' "$STOCK" > "$T/s7/AutoSystemBoost/odm/etc/camera/conf_tuning_params.json"
( set +u; . "$ROOT/runtime/asb_tweaks.sh"; ASB_TWEAK_BASE_DIR="$T/b6"
  asb_tw_save_base "$T/s7/AutoSystemBoost/odm/etc/camera/conf_tuning_params.json" force ) >/dev/null 2>&1
[ "$(cat "$T/b6/odm_etc_camera_conf_tuning_params.json.asbbase.rom" 2>/dev/null)" = canoe ] || f "camera baseline saved without its ROM stamp"
( set +u; . "$ROOT/runtime/asb_tweaks.sh"; ASB_TWEAK_BASE_DIR="$T/b6"; asb_save_dynamic_baselines "$ST" ) >/dev/null 2>&1
[ -f "$T/b6/odm_etc_camera_conf_tuning_params.json.asbbase" ] || f "stamped stock baseline of this ROM pruned"
grep -q 'if command -v asb_tw_base_rom_ok >/dev/null 2>&1 && ! asb_tw_base_rom_ok "$_ct_bp"; then' "$ROOT/common/install.sh" \
  || f "installer clones from a baseline of another ROM build"

[ "$fail" = 0 ] && echo "PASS camera boot regrade runtime"
exit "$fail"
)

t_camera_grade_contract() (
# Contract: camera controls must reach the real grader, be visibly stronger at level 10,
# and never claim an independent slider applied when CAMERA_LEVEL remains stock.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GRADE="$ROOT/runtime/asb_camera_grade.sh"
TWEAKS="$ROOT/runtime/asb_tweaks.sh"
WRITER="$ROOT/runtime/asb_config_safe.sh"
UI="$ROOT/webroot/index.html"
ACTION="$ROOT/action.sh"
INSTALL="$ROOT/common/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
STATE="$TMP/state"
SRC="$TMP/conf_tuning_params.json"
OUT="$TMP/graded.json"

fail() { echo "FAIL camera-grade: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing $2"; }
run_writer() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" sh "$WRITER" "$@"; }

mkdir -p "$MOD/config"
cp "$ROOT/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"

sh -n "$GRADE" || fail "grader shell syntax"
sh -n "$TWEAKS" || fail "dynamic overlay shell syntax"
sh -n "$WRITER" || fail "writer shell syntax"

# The visible upper bounds must be exactly the runtime/writer bounds, not optimistic sliders.
need "$UI" "{ key:'CAMERA_LEVEL', type:'range', def:'0', min:0, max:10"
need "$UI" "{ key:'CAMERA_CONTRAST', type:'range', def:'3', min:0, max:10"
need "$UI" "{ key:'CAMERA_GRAIN', type:'range', def:'3', min:0, max:10"
need "$UI" "{ key:'CAMERA_LOWLIGHT', type:'range', def:'0', min:0, max:10"
need "$UI" "CAMERA_AGGRESSIVE:'camera_aggressive'"
need "$UI" "CAMERA_AGGRESSIVE_INJECT:'camera_inject'"
need "$GRADE" '[ "$_lvl" -gt 10 ] 2>/dev/null && _lvl=10'
need "$GRADE" '[ "$_grain" -gt 10 ] 2>/dev/null && _grain=10'
need "$GRADE" '[ "$_contrast" -gt 10 ] 2>/dev/null && _contrast=10'
need "$GRADE" '[ "$_lowlight" -gt 10 ] 2>/dev/null && _lowlight=10'
need "$TWEAKS" '[ "$_lv" -gt 10 ] 2>/dev/null && _lv=10'
need "$TWEAKS" 'asb_tw_camera_grade_needed()'
need "$TWEAKS" '_cam_grade_needed=0'
need "$TWEAKS" 'asb_tw_vb_add_apps()'
need "$INSTALL" 'final camera payload verified'
need "$ACTION" '/odm/etc/camera/config/video_beauty_default_config'
need "$ACTION" '/vendor/odm/etc/camera/config/video_beauty_default_config'

cat > "$SRC" <<'EOF'
{
  "EnhanceNetParamsSet": 1,
  "Main1x_Rgb2YuvParams": [1, 1, 1, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
  "EnhanceNetPortraitParams": {
    "PersonBlendWeight": [0, 0, 0],
    "SkinBlendWeight": [0, 0, 0],
    "FaceBlendWeight": [0, 0, 0]
  },
  "NormalParams": {
    "BnScale": [1],
    "QbcScale": [1]
  },
  "MacroParams": {
    "BnScale": [1],
    "QbcScale": [1]
  },
  "addNoiseWeightMain1X": 1,
  "addNoiseWeightUltraWidePortrait": 0.5,
  "addNoiseWeightFront": [0.25, 0.5],
  "low20XcontrastScale": 1,
  "SatuColorScale": 1
}
EOF

# Level 10 must be more than the old level-8 endpoint and affect all declared axes.
sed -i \
  -e 's/^CAMERA_LEVEL=.*/CAMERA_LEVEL=10/' \
  -e 's/^CAMERA_GRAIN=.*/CAMERA_GRAIN=10/' \
  -e 's/^CAMERA_CONTRAST=.*/CAMERA_CONTRAST=10/' \
  -e 's/^CAMERA_PORTRAIT=.*/CAMERA_PORTRAIT=6/' \
  -e 's/^CAMERA_LOWLIGHT=.*/CAMERA_LOWLIGHT=10/' "$MOD/config/governor.conf"
MODDIR="$MOD" ASB_GRADE_DIR="$TMP/grade_marks" sh "$GRADE" "$SRC" "$OUT" >/dev/null || fail "level-10 grade failed"
need "$OUT" '"Main1x_Rgb2YuvParams": [1, 1, 1, 0.25, 0.5, 0.75, 1, 1.25, 1.5]'
need "$OUT" '"PersonBlendWeight": [0.85, 0.92, 1]'
need "$OUT" '"NormalParams": {'
need "$OUT" '"BnScale": [3.5]'
need "$OUT" '"MacroParams": {'
need "$OUT" '"BnScale": [3.2]'
need "$OUT" '"addNoiseWeightMain1X": 16'
need "$OUT" '"addNoiseWeightUltraWidePortrait": 8'
need "$OUT" '"addNoiseWeightFront": [4, 8]'
need "$OUT" '"low20XcontrastScale": 1.7'
GRADE_STATS="$(find "$TMP/grade_marks" -type f -name '*.stats' | head -1)"
[ -n "$GRADE_STATS" ] || fail 'camera apply coverage report missing'
need "$GRADE_STATS" 'grain_keys=3'
need "$GRADE_STATS" 'grain_pct=1600'
need "$GRADE_STATS" 'contrast_rules=2'
need "$GRADE_STATS" 'contrast_pct=170'

# Independent settings must grade even with Camera Grade at stock. This is the exact former
# silent-no-op regression: contrast 10 had been accepted and displayed but copied unchanged.
sed -i \
  -e 's/^CAMERA_LEVEL=.*/CAMERA_LEVEL=0/' \
  -e 's/^CAMERA_GRAIN=.*/CAMERA_GRAIN=3/' \
  -e 's/^CAMERA_CONTRAST=.*/CAMERA_CONTRAST=10/' \
  -e 's/^CAMERA_PORTRAIT=.*/CAMERA_PORTRAIT=0/' \
  -e 's/^CAMERA_LOWLIGHT=.*/CAMERA_LOWLIGHT=0/' "$MOD/config/governor.conf"
MODDIR="$MOD" ASB_GRADE_DIR="$TMP/grade_marks" sh "$GRADE" "$SRC" "$OUT" >/dev/null || fail "independent contrast grade failed"
need "$OUT" '"low20XcontrastScale": 1.7'
need "$OUT" '"Main1x_Rgb2YuvParams": [1, 1, 1, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6]'
need "$GRADE_STATS" 'grain_keys=0'
need "$GRADE_STATS" 'contrast_rules=2'
need "$ROOT/tools/asb_diag.sh" 'camera grade coverage:'
need "$UI" 'cfgCameraNotExposed(it.key, cur)'
need "$UI" 'ASB_GRADE.grain_keys === 0'
need "$UI" '/^grain_keys=(\d+)$/'
need "$UI" "cfg_not_exposed"

# Retouch injection must survive the final staging pass and remain idempotent. A stock-like
# fixture starts with four package entries; the helper must append the known app set once, not
# duplicate it on every install/update.
VB="$TMP/video_beauty_default_config"
cat > "$VB" <<'EOF_VB'
{
  "appConfigList": [
    { "appName":"Discord", "packageName":"com.discord", "videoBeautyParam": { "isOpen": 0 } },
    { "appName":"Teams", "packageName":"com.microsoft.teams", "videoBeautyParam": { "isOpen": 0 } },
    { "appName":"WeChat", "packageName":"com.tencent.mm", "videoBeautyParam": { "isOpen": 0 } },
    { "appName":"WhatsApp", "packageName":"com.whatsapp", "videoBeautyParam": { "isOpen": 0 } }
  ]
}
EOF_VB
. "$TWEAKS"
asb_tw_vb_add_apps "$VB"
_vb_first="$(grep -c '"packageName"' "$VB" 2>/dev/null)"
[ "${_vb_first:-0}" -ge 7 ] 2>/dev/null || fail "retouch injection count=$_vb_first"
grep -Fq '"packageName":"org.telegram.messenger"' "$VB" || fail 'Telegram retouch entry missing'
asb_tw_vb_add_apps "$VB"
_vb_second="$(grep -c '"packageName"' "$VB" 2>/dev/null)"
[ "$_vb_second" = "$_vb_first" ] || fail 'retouch injection duplicated entries'

# Writer accepts the declared maximum and rejects anything the grader would clamp away.
run_writer set CAMERA_LEVEL 10 >/dev/null
run_writer set CAMERA_GRAIN 10 >/dev/null
run_writer set CAMERA_CONTRAST 10 >/dev/null
run_writer set CAMERA_LOWLIGHT 10 >/dev/null
if run_writer set CAMERA_LEVEL 11 >/dev/null 2>&1; then fail "CAMERA_LEVEL=11 accepted"; fi
if run_writer set CAMERA_GRAIN 11 >/dev/null 2>&1; then fail "CAMERA_GRAIN=11 accepted"; fi
if run_writer set CAMERA_CONTRAST 11 >/dev/null 2>&1; then fail "CAMERA_CONTRAST=11 accepted"; fi
if run_writer set CAMERA_LOWLIGHT 11 >/dev/null 2>&1; then fail "CAMERA_LOWLIGHT=11 accepted"; fi

echo 'PASS camera grade capability contract'
)

t_config_bundle_runtime() (
# Runtime (fix125): a configuration saved to a folder is ONE file, NAME.asb - settings, their
# checksum and the whole Smart learning payload - and opens back through the same checks.
# Anything else inside the archive (extra names, traversal, two profiles, a link) is refused;
# older three-part copies still open.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT_DIR/tools/asb_config_backup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL config bundle: $*" >&2; exit 1; }
MOD="$TMP/module"; STATE="$TMP/state"; SMART="$TMP/smart"; OUT="$TMP/storage/Backups"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE" "$SMART" "$OUT"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
run() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_SMART_STATE="$SMART" ASB_SMART_RESTORE_SKIP_DAEMON=1 sh "$HELPER" "$@"; }
KEYS='gnss_trim night_modem_idle doze_level wifi_country'
printf 'bucket-learning-fixture\n' > "$SMART/buckets.bin"
printf 'bucket-fallback-fixture\n' > "$SMART/buckets.bin.bak"
printf 'appheat-learning-fixture\n' > "$SMART/smart_appheat.bin"
printf 'sleep_min=1380\nwake_min=420\nsamples=12\n' > "$SMART/night_window.conf"
printf '1\n' > "$SMART/smart_mode_enabled"
i=0; : > "$SMART/session_history.jsonl"
while [ $i -lt 400 ]; do printf '{"v":9,"profile":"smart","dur":360,"bat_ttd":75,"n":%d}\n' $i >> "$SMART/session_history.jsonl"; i=$((i+1)); done
printf '{"count":4,"t2s":20}\n' > "$MOD/runtime/pstats_battery.json"

run create daily $KEYS >/dev/null

# 1. Save to a folder: exactly one file.
# An older three-part copy of the same name sits there and is superseded.
printf '# ASB_PROFILE_SCHEMA=1\ngnss_trim=1\n' > "$OUT/daily.conf"; printf 'x\n' > "$OUT/daily.conf.sha256"; mkdir -p "$OUT/daily.smart"
# ...while a user's own unrelated file of another name is left alone.
printf 'mine\n' > "$OUT/notes.conf"
out="$(run export-path daily "$OUT")"
printf '%s\n' "$out" | grep -qx "exported=$OUT/daily.asb" || fail "export did not report the .asb file: $out"
printf '%s\n' "$out" | grep -qx 'smart_learning=saved' || fail "Smart learning not in the file: $out"
[ "$(ls -A "$OUT" | grep -c '^daily')" = 1 ] || fail "more than one entry for one configuration: $(ls -A "$OUT")"
[ -f "$OUT/notes.conf" ] || fail "a user file was removed"
[ "$(head -c 2 "$OUT/daily.asb" | od -An -tx1 | tr -d ' \n')" = 1f8b ] || fail "not compressed"
tar -tzf "$OUT/daily.asb" | grep -qx 'daily.smart/session_history.jsonl' || fail "session history missing inside"

# 2. Opens back - the name comes from inside, whatever the file is called now.
run delete daily >/dev/null
cp "$OUT/daily.asb" "$OUT/renamed copy.asb"
imp="$(run import-path "$OUT/renamed copy.asb")"
printf '%s\n' "$imp" | grep -qx 'imported=daily' || fail "import did not restore the name: $imp"
printf '%s\n' "$imp" | grep -qx 'smart_learning=saved' || fail "Smart learning not imported: $imp"
run list | grep -q '^daily|.*|ok|saved$' || fail "imported profile not listed with Smart learning"
rm -f "$SMART/buckets.bin"
run restore daily $KEYS | grep -qx 'smart_learning=restored' || fail "restore from an imported file failed"
[ -s "$SMART/buckets.bin" ] || fail "learning not restored from the file"

# 3. Refused: tampered content, an extra entry, traversal, two profiles, a link.
mk() {   # $1 = name of a staging dir already filled; $2 = output
  ( cd "$TMP/$1" && tar -czf "$2" * ) 2>/dev/null
}
rm -rf "$TMP/x" && mkdir -p "$TMP/x" && tar -xzf "$OUT/daily.asb" -C "$TMP/x"
printf 'tamper' >> "$TMP/x/daily.conf"; mk x "$TMP/bad1.asb"
if run import-path "$TMP/bad1.asb" >/dev/null 2>&1; then fail "tampered settings accepted"; fi
rm -rf "$TMP/x" && mkdir -p "$TMP/x" && tar -xzf "$OUT/daily.asb" -C "$TMP/x"
printf 'evil\n' > "$TMP/x/payload.sh"; mk x "$TMP/bad2.asb"
if run import-path "$TMP/bad2.asb" >/dev/null 2>&1; then fail "an extra file inside accepted"; fi
rm -rf "$TMP/x" && mkdir -p "$TMP/x" && tar -xzf "$OUT/daily.asb" -C "$TMP/x"
cp "$TMP/x/daily.conf" "$TMP/x/other.conf"; mk x "$TMP/bad3.asb"
if run import-path "$TMP/bad3.asb" >/dev/null 2>&1; then fail "two profiles in one file accepted"; fi
rm -rf "$TMP/x" && mkdir -p "$TMP/x" && tar -xzf "$OUT/daily.asb" -C "$TMP/x"
ln -s /etc/passwd "$TMP/x/daily.smart/buckets.bin.bak" 2>/dev/null || true
rm -f "$TMP/x/daily.smart/buckets.bin.bak"; ln -s /etc/passwd "$TMP/x/daily.smart/buckets.bin.bak"; mk x "$TMP/bad4.asb"
if run import-path "$TMP/bad4.asb" >/dev/null 2>&1; then fail "a link inside accepted"; fi
( cd "$TMP" && tar -czf "$TMP/bad5.asb" --transform 's|^x/|../|' x/ASB_BUNDLE ) 2>/dev/null || true
if [ -s "$TMP/bad5.asb" ] && run import-path "$TMP/bad5.asb" >/dev/null 2>&1; then fail "a traversal entry accepted"; fi
printf 'not an archive' > "$TMP/bad6.asb"
if run import-path "$TMP/bad6.asb" >/dev/null 2>&1; then fail "garbage accepted"; fi
[ -z "$(ls -A "$STATE/config_profiles" | grep '^\.unpack')" ] || fail "an unpack folder was left behind"

# 4. Older three-part copies still open.
run delete daily >/dev/null 2>&1 || true
run create legacy $KEYS >/dev/null
run export legacy downloads >/dev/null 2>&1 || true
LEG="$STATE/config_profiles"
mkdir -p "$TMP/old" && cp "$LEG/legacy.conf" "$LEG/legacy.conf.sha256" "$TMP/old/" && cp -R "$LEG/legacy.smart" "$TMP/old/"
run delete legacy >/dev/null
run import-path "$TMP/old/legacy.conf" | grep -qx 'imported=legacy' || fail "an older .conf copy no longer opens"

# 5. The WebUI browser lists .asb files and shows the file the helper wrote.
UI="$ROOT_DIR/webroot/index.html"
grep -q 'const conf = !dir && /\\.(asb|conf)$/i.test(name);' "$UI" || fail "file browser does not list .asb"
grep -q "const outFile = exm ? exm\[2\].replace" "$UI" || fail "save toast does not name the written file"

echo "PASS config bundle: one .asb file per saved configuration, verified import, old copies still open"
)

t_config_legacy_import_runtime() (
# Runtime (fix134): older multi-file backups open, new saves stay one .asb file, and the save
# dialog chooses whether Smart learning goes in.
#
# The multi-file copies (NAME.conf + NAME.conf.sha256 + NAME.smart) open as before when they
# are intact. What a messenger or a second download delivers often is not: the checksum and the
# learning folder stay behind and the file is "name (1).conf". Those were refused outright.
# Now they are read line by line - known keys, plain values, the current validator - and a
# value this module rejects is left out by name instead of sinking the whole backup.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT_DIR/tools/asb_config_backup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL config legacy import: $*" >&2; exit 1; }
MOD="$TMP/module"; STATE="$TMP/state"; SMART="$TMP/smart"; OLD="$TMP/storage/Telegram"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE" "$SMART" "$OLD"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
run() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_SMART_STATE="$SMART" ASB_SMART_RESTORE_SKIP_DAEMON=1 sh "$HELPER" "$@"; }
KEYS='gnss_trim night_modem_idle doze_level wifi_country quiet_tick_s'
printf 'bucket-learning-fixture\n' > "$SMART/buckets.bin"
printf '1\n' > "$SMART/smart_mode_enabled"

# 0. Is there learning to offer?
run smart-available | grep -qx 'smart_learning=available' || fail "learning on the phone not reported"

# 1. Save without learning: settings only, and the .asb carries no learning folder.
out="$(run create shareable --no-smart $KEYS)"
printf '%s\n' "$out" | grep -qx 'smart_learning=skipped_by_choice' || fail "--no-smart ignored: $out"
[ ! -d "$STATE/config_profiles/shareable.smart" ] || fail "learning saved although left out"
mkdir -p "$TMP/out"
run export-path shareable "$TMP/out" | grep -qx "exported=$TMP/out/shareable.asb" || fail "not one .asb file"
if tar -tzf "$TMP/out/shareable.asb" | grep -q 'shareable.smart'; then fail "learning inside a settings-only file"; fi
# ...and replacing a profile that had learning drops the old learning.
run create both $KEYS >/dev/null
[ -d "$STATE/config_profiles/both.smart" ] || fail "learning not saved by default"
run replace both --no-smart $KEYS >/dev/null
[ ! -d "$STATE/config_profiles/both.smart" ] || fail "replaced profile kept the old learning"

# 2. An intact multi-file copy opens on the strict path, learning included.
run create daily $KEYS >/dev/null
cp "$STATE/config_profiles/daily.conf" "$STATE/config_profiles/daily.conf.sha256" "$OLD/"
cp -R "$STATE/config_profiles/daily.smart" "$OLD/"
run delete daily >/dev/null
out="$(run import-path "$OLD/daily.conf")"
printf '%s\n' "$out" | grep -qx 'imported=daily' || fail "intact copy: $out"
printf '%s\n' "$out" | grep -qx 'smart_learning=saved' || fail "intact copy lost its learning: $out"
printf '%s\n' "$out" | grep -q 'format=older' && fail "intact copy took the line-by-line path"

# 3. The same copy after a messenger: no checksum, no learning folder, renamed.
cp "$OLD/daily.conf" "$OLD/daily (1).conf"
out="$(run import-path "$OLD/daily (1).conf")"
printf '%s\n' "$out" | grep -qx 'imported=daily-1' || fail "renamed copy without checksum refused: $out"
printf '%s\n' "$out" | grep -qx 'format=older_checked_line_by_line' || fail "line-by-line path not reported"
run list | grep -q '^daily-1|.*|ok|empty$' || fail "imported copy not stored with a fresh checksum"
run restore daily-1 $KEYS | grep -qx 'restored=daily-1' || fail "imported copy does not restore"

# 4. A pre-V64 whole-config backup with an inline comment, a value the current module rejects
#    and a key that no longer exists: the rest opens, the bad one is named.
{ echo '# ASB_BACKUP_SCHEMA=2'; echo '# created_at=1'
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MOD/config/governor.conf" \
    | sed 's/^quiet_tick_s=.*/quiet_tick_s=1/; s/^gnss_trim=.*/gnss_trim=1   # mine/'
  echo 'net_handover_fast=1'; printf 'doze_level=two words\r\n'; } > "$OLD/asb_settings_backup.conf"
out="$(run import-path "$OLD/asb_settings_backup.conf")"
printf '%s\n' "$out" | grep -qx 'imported=asb_settings_backup' || fail "whole-config backup refused: $out"
printf '%s\n' "$out" | grep -qx 'skipped_keys=quiet_tick_s' || fail "rejected value not named: $out"
P="$STATE/config_profiles/asb_settings_backup.conf"
grep -qx 'gnss_trim=1' "$P" || fail "inline comment not stripped"
grep -q '^net_handover_fast=' "$P" && fail "a key this module no longer has was kept"
grep -q '^doze_level=two' "$P" && fail "a value with a space inside was kept"
grep -q '^quiet_tick_s=' "$P" && fail "the rejected value was kept"
run restore asb_settings_backup $KEYS >/dev/null || fail "whole-config backup does not restore"
grep -qx 'gnss_trim=1' "$MOD/config/governor.conf" || fail "restored value not applied"

# 5. Not ours: refused.
printf 'foo=1\nbar=2\n' > "$OLD/random.conf"
if run import-path "$OLD/random.conf" >/dev/null 2>&1; then fail "a foreign .conf accepted"; fi

# 6. WebUI: the choice, the flag and the notice, in every language.
UI="$ROOT_DIR/webroot/index.html"
grep -q "' smart-available'" "$UI" || fail "save dialog does not ask whether learning exists"
grep -q "' --no-smart'" "$UI" || fail "save does not pass the choice"
grep -q 'format=older_checked_line_by_line' "$UI" || fail "older-copy import not announced"
for f in "$ROOT_DIR"/webroot/i18n/*.json; do
  for k in cfg_profile_smart_include cfg_profile_smart_include_on cfg_profile_smart_include_off cfg_profile_imported_older cfg_profile_imported_skipped; do
    grep -q "\"$k\"" "$f" || fail "$k missing in ${f##*/}"
  done
done
echo "PASS config legacy import: old copies open (intact or not), saves stay one .asb, Smart learning optional"
)

t_config_lock_contract() (
# Config writer lease contract: no blind lock deletion, no orphan timeout without evidence.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WRITER="$ROOT_DIR/runtime/asb_config_safe.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
STATE="$TMP/state"
mkdir -p "$MOD/config" "$STATE"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"

run_writer() {
  MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" sh "$WRITER" "$@"
}
need() { grep -Fqx "$2" "$1" >/dev/null || { echo "FAIL: missing [$2] in $1" >&2; exit 1; }; }

# A dead owner whose lease is older than the conservative stale threshold may be reclaimed.
mkdir "$STATE/config.lock"
printf '%s\n' '999999' > "$STATE/config.lock/pid"
touch -d '90 seconds ago' "$STATE/config.lock"
run_writer set gnss_trim 0 >/dev/null
need "$MOD/config/governor.conf" 'gnss_trim=0'
need "$STATE/config_last_txn" 'result_class=success'
grep -q '^lock_recovered=stale_owner=999999,owner_state=pid_present,age=' "$STATE/config_last_txn" || {
  echo 'FAIL: stale PID reclaim provenance absent' >&2; exit 1;
}
[ ! -d "$STATE/config.lock" ] || { echo 'FAIL: successful writer left lock behind' >&2; exit 1; }

# A V63/interrupted legacy lock can have no pid at all. It is safe to reclaim only after the
# exact same conservative age threshold: fresh metadata-less acquisition is still protected.
mkdir "$STATE/config.lock"
touch -d '90 seconds ago' "$STATE/config.lock"
run_writer set gnss_trim 1 >/dev/null
need "$MOD/config/governor.conf" 'gnss_trim=1'
grep -q '^lock_recovered=stale_owner=missing,owner_state=missing_metadata,age=' "$STATE/config_last_txn" || {
  echo 'FAIL: stale pid-less reclaim provenance absent' >&2; exit 1;
}
[ ! -d "$STATE/config.lock" ] || { echo 'FAIL: pid-less stale reclaim left lock behind' >&2; exit 1; }

# Malformed historical pid metadata also has no trustworthy owner identity, but may only be
# reclaimed after the stale threshold.
mkdir "$STATE/config.lock"
printf '%s\n' 'not-a-pid' > "$STATE/config.lock/pid"
touch -d '90 seconds ago' "$STATE/config.lock"
run_writer set gnss_trim 0 >/dev/null
grep -q '^lock_recovered=stale_owner=missing,owner_state=invalid_metadata,age=' "$STATE/config_last_txn" || {
  echo 'FAIL: invalid pid reclaim provenance absent' >&2; exit 1;
}
[ ! -d "$STATE/config.lock" ] || { echo 'FAIL: invalid-pid stale reclaim left lock behind' >&2; exit 1; }

# Fresh pid-less metadata can be in the post-mkdir acquisition window and must not be stolen.
mkdir "$STATE/config.lock"
if MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_CONFIG_LOCK_WAIT_TICKS=2 \
  sh "$WRITER" set gnss_trim 1 >/dev/null 2>&1; then
  echo 'FAIL: writer stole fresh pid-less lock' >&2; exit 1
fi
need "$STATE/config_last_txn" 'result_class=lock_live'
need "$STATE/config_last_txn" 'lock_owner=missing'
need "$STATE/config_last_txn" 'lock_owner_state=missing_metadata'
rm -f "$STATE/config.lock/pid" "$STATE/config.lock/started"
rmdir "$STATE/config.lock"

# A live owner must never be stolen, even if directory mtime is old. Shorten only test wait.
mkdir "$STATE/config.lock"
printf '%s\n' "$$" > "$STATE/config.lock/pid"
touch -d '90 seconds ago' "$STATE/config.lock"
if MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_CONFIG_LOCK_WAIT_TICKS=2 \
  sh "$WRITER" set gnss_trim 1 >/dev/null 2>&1; then
  echo 'FAIL: writer stole live lock' >&2; exit 1
fi
need "$STATE/config_last_txn" 'result_class=lock_live'
need "$STATE/config_last_txn" "lock_owner=$$"
need "$STATE/config_last_txn" 'lock_owner_state=pid_present'
grep -q '^lock_age=' "$STATE/config_last_txn" || { echo 'FAIL: live lock age absent' >&2; exit 1; }
need "$STATE/config_last_txn" 'lock_path=config.lock'
POLICY_JSON="$TMP/effective_policy.json"
MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" sh "$ROOT_DIR/tools/asb_effective_policy.sh" > "$POLICY_JSON" 2>/dev/null
python3 - "$POLICY_JSON" "$$" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    txn = json.load(fh)['config_last_txn']
assert txn['lock_owner'] == sys.argv[2], txn
assert txn['lock_owner_state'] == 'pid_present', txn
assert isinstance(txn['lock_age'], int) and txn['lock_age'] >= 0, txn
PY
rm -f "$STATE/config.lock/pid" "$STATE/config.lock/started"
rmdir "$STATE/config.lock"

echo 'PASS config lock lease contract'
)

t_config_ownership_registry() (
# Contract: every governor.conf key has one explicit ownership class, and public keys match WebUI.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONF="$ROOT/config/governor.conf"
REG="$ROOT/config/key_ownership.tsv"
LINT="$ROOT/tools/asb_lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL config ownership registry: $*" >&2; exit 1; }

[ -f "$CONF" ] || fail 'governor.conf missing'
[ -f "$REG" ] || fail 'key_ownership.tsv missing'
[ -f "$LINT" ] || fail 'asb_lint.sh missing'
sh -n "$LINT"

awk -F= '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/{k=$1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k); print k}' "$CONF" | sort > "$TMP/conf"
awk -F'|' '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
  NF != 3 {print "malformed row " NR > "/dev/stderr"; bad=1; next}
  $1 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ {print "invalid key " $1 > "/dev/stderr"; bad=1}
  $2 !~ /^(user|advanced|internal)$/ {print "invalid class " $1 "=" $2 > "/dev/stderr"; bad=1}
  $3 !~ /^[a-z_][a-z0-9_]*$/ {print "invalid intent " $1 "=" $3 > "/dev/stderr"; bad=1}
  {print $1}
  END {exit bad}
' "$REG" | sort > "$TMP/registry" || fail 'registry row format/class vocabulary'
[ "$(wc -l < "$TMP/conf")" = "207" ] || fail "expected 207 config keys, got $(wc -l < "$TMP/conf")"
[ "$(wc -l < "$TMP/registry")" = "207" ] || fail "expected 207 registry keys, got $(wc -l < "$TMP/registry")"
[ "$(uniq -d "$TMP/registry" | wc -l)" = "0" ] || fail "duplicate registry keys: $(uniq -d "$TMP/registry" | tr '\n' ' ')"
diff -u "$TMP/conf" "$TMP/registry" >/dev/null || fail 'registry key set differs from governor.conf'

sed -n '/const CFG_ITEMS = \[/,/^\];/p' "$ROOT/webroot/index.html" \
  | grep -oE "key:'[A-Za-z_][A-Za-z0-9_]*'" | sed "s/key:'//;s/'//" | sort -u > "$TMP/cards"
[ "$(wc -l < "$TMP/cards")" = "80" ] || fail "expected 80 WebUI cards, got $(wc -l < "$TMP/cards")"
_card_bad="$(while IFS= read -r key; do
  cls="$(awk -F'|' -v k="$key" '$1==k {print $2; exit}' "$REG")"
  case "$cls" in user|advanced) : ;; *) printf '%s ' "$key" ;; esac
done < "$TMP/cards")"
[ -z "$_card_bad" ] || fail "card(s) internal or unregistered: $_card_bad"
_public="$(awk -F'|' '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} ($2=="user" || $2=="advanced") {print $1}' "$REG" | sort)"
_public_stale="$(printf '%s\n' "$_public" | while IFS= read -r key; do grep -Fqx "$key" "$TMP/cards" || printf '%s ' "$key"; done)"
[ -z "$_public_stale" ] || fail "public registry key(s) without WebUI card: $_public_stale"

for cls in user advanced internal; do
  n="$(awk -F'|' -v c="$cls" '$2==c {n++} END{print n+0}' "$REG")"
  [ "$n" -gt 0 ] || fail "ownership class $cls is unused"
done

grep -Fq 'Config Key Ownership' "$LINT" || fail 'lint does not enforce ownership registry'
grep -Fq 'config ownership key-set drift' "$LINT" || fail 'lint lacks key-set drift failure'
grep -Fq 'WebUI/ownership drift' "$LINT" || fail 'lint lacks WebUI ownership boundary failure'

# Every WebUI card must survive an update.
#
# common/install.sh carries user values across a reinstall using a hand-written
# _user_keys list. Two cards were added without being put on it, so their values were
# silently dropped on every update - indistinguishable, from the user's side, from a
# tweak that does not save. Nothing checked this, so nothing caught it.
_uk="$(awk '/_user_keys="/{f=1} f{printf "%s ", $0} f&&/"[[:space:]]*$/{exit}' "$ROOT/common/install.sh" | sed 's/.*_user_keys="//;s/".*//;s/\\\\//g')"
_missing=""
for _c in $(grep -oE "\{ key:'[A-Za-z_][A-Za-z_0-9]*'" "$ROOT/webroot/index.html" \
            | sed "s/.*key:'//;s/'//" | sort -u); do
  case " $_uk " in *" $_c "*) : ;; *) _missing="$_missing $_c" ;; esac
done
[ -z "$_missing" ] || fail "cards missing from install.sh _user_keys:$_missing"
# fix240: the snapshot that outlives the module had its own, shorter copy of the list - five
# cards added later (Keep Apps In Memory, Bluetooth link stability, Leave Bad Wi-Fi, Wi-Fi power
# save, LSPosed log) were not in it, so a reinstall after removal reset them.
_sk="$(awk '/^  _keys="audio_profile/{f=1} f{printf "%s ", $0} f&&/"[[:space:]]*$/{exit}' "$ROOT/common/install.sh" | sed 's/.*_keys="//;s/".*//;s/\\\\//g')"
[ -n "$_sk" ] || fail "snapshot key list not found"
_missing=""
for _c in $(grep -oE "\{ key:'[A-Za-z_][A-Za-z_0-9]*'" "$ROOT/webroot/index.html" \
            | sed "s/.*key:'//;s/'//" | sort -u); do
  case " $_sk " in *" $_c "*) : ;; *) _missing="$_missing $_c" ;; esac
done
[ -z "$_missing" ] || fail "cards missing from the install.sh settings snapshot:$_missing"

echo 'PASS config ownership registry contract (207 keys; 30 user, 50 advanced, 127 internal)'
)

t_config_restore_outcome_runtime() (
# Runtime (fix142): applying a saved configuration reports what it did - how many settings the
# file carries and how many it changed - and the WebUI turns save/apply into an outcome panel
# in the window instead of a two-second toast and a dialog left as it was.
#
# A user: "it is not clear whether the backup was saved or applied - the window does not
# close until I close it myself". Saving to a folder left the dialog unchanged; opening a
# file only selected it (a toast said "press Apply") and the user read it as applied.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT_DIR/tools/asb_config_backup.sh"
W="$ROOT_DIR/webroot/index.html"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL config restore outcome: $*" >&2; exit 1; }
MOD="$TMP/module"; STATE="$TMP/state"; SMART="$TMP/smart"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE" "$SMART"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
run() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_SMART_STATE="$SMART" ASB_SMART_RESTORE_SKIP_DAEMON=1 TMPDIR="$TMP" sh "$HELPER" "$@"; }
KEYS='gnss_trim night_modem_idle doze_level wifi_country'
run create daily $KEYS >/dev/null
# Change two of the four settings, then apply the saved copy: 4 in the file, 2 changed back.
sed -i -e 's/^gnss_trim=.*/gnss_trim=9/' -e 's/^doze_level=.*/doze_level=9/' "$MOD/config/governor.conf"
grep -q '^gnss_trim=9' "$MOD/config/governor.conf" || fail "fixture edit did not take"
out="$(run restore daily $KEYS)" || fail "restore failed: $out"
printf '%s\n' "$out" | grep -qx 'restored=daily' || fail "no restored= line: $out"
printf '%s\n' "$out" | grep -qx 'keys=4' || fail "settings in the file not reported: $out"
printf '%s\n' "$out" | grep -qx 'changed=2' || fail "changed count wrong: $out"
out="$(run restore daily $KEYS)"
printf '%s\n' "$out" | grep -qx 'changed=0' || fail "a second apply reports changes: $out"
[ -z "$(ls "$TMP" | grep asb_restore_before)" ] || fail "temporary copy left behind"

# WebUI wiring (the flow itself was driven in Chromium for this change).
grep -q 'function cfgProfileShowResult(res)' "$W" || fail "no outcome panel"
grep -q "if (_cfgProfile.result) { cfgProfilePaintResult(body); return; }" "$W" || fail "outcome not painted in the window"
grep -q "cfg_res_saved_file_title" "$W" || fail "saving to a folder still leaves the dialog unchanged"
grep -q "const settingsDone = /(^|\\\\n)restored=/.test(detail);" "$W" || fail "a Smart-only failure still reads as nothing restored"
grep -q "cfg_res_opened_banner" "$W" || fail "an opened file is not marked as not applied"
grep -q "if (_cfgProfile.resultLeft <= 0) { cfgProfileResultStop(); cfgProfileClose(); return; }" "$W" || fail "a clean success does not close itself"
for f in "$ROOT_DIR"/webroot/i18n/*.json; do
  grep -q '"cfg_res_opened_banner"' "$f" && grep -q '"cfg_res_applied_title"' "$f" || fail "outcome strings missing in ${f##*/}"
done
echo "PASS config restore outcome: keys/changed reported; save and apply answer in the window"
)

t_config_safety() (
# Config parser clamps and rejects out-of-range values (src/asb_config.h), built with -Werror.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CCX="${HOST_CC:-${CC:-}}"
[ -n "$CCX" ] || for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && { CCX="$c"; break; }; done
[ -n "$CCX" ] || { echo "FAIL config_safety: no host C compiler" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_c_config_safety > "$T/t.c"
"$CCX" -O2 -Wall -Wextra -Werror -I "$ROOT/src" "$T/t.c" -o "$T/t"
"$T/t"
)

t_config_writer() (
# config_writer — regression tests for the only runtime writer.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
WRITER="$ROOT_DIR/runtime/asb_config_safe.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_cfg_writer.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
STATE="$TMP/state"
SNAP="$TMP/governor.conf.snapshot"
BACKUP="$TMP/backup.conf"

fail() { echo "FAIL: $*" >&2; exit 1; }
need_line() { grep -qx "$2" "$1" || fail "missing '$2' in $1"; }

mkdir -p "$MOD/config"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf.shipped"

# Source checkout must not ship a stale writer whitelist.
current_keys="$TMP/current.keys"
shipped_keys="$TMP/shipped.keys"
sed -n -E 's/^[[:space:]]*([A-Za-z0-9_]+)=.*/\1/p' "$ROOT_DIR/config/governor.conf" | sort -u > "$current_keys"
sed -n -E 's/^[[:space:]]*([A-Za-z0-9_]+)=.*/\1/p' "$ROOT_DIR/config/governor.conf.shipped" | sort -u > "$shipped_keys"
diff -u "$current_keys" "$shipped_keys" >/dev/null || fail "governor.conf.shipped key set is stale"

run_writer() {
  MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" sh "$WRITER" "$@"
}

# Upgrade compatibility: a retained active config can predate current schema keys.
# They remain closed to the shipped schema, but must be appendable by WebUI rather
# than reported as "unknown key" and left visually disabled.
sed -i '/^gnss_trim=/d; /^night_modem_idle=/d' "$MOD/config/governor.conf"
run_writer set gnss_trim 1 >/dev/null
run_writer set night_modem_idle 1 >/dev/null
need_line "$MOD/config/governor.conf" "gnss_trim=1"
need_line "$MOD/config/governor.conf" "night_modem_idle=1"
if run_writer set ace5_unknown_toggle 1 >/dev/null 2>&1; then
  fail "unknown key was accepted through shipped-schema fallback"
fi

# Ace 5 legacy recovery: older WebUI could leave enter above its former Smart
# ceiling. An unrelated setting must recover only that stale pair atomically,
# record why it did so, and then preserve the normal refusal for an explicit
# invalid thermal edit.
sed -i 's/^sustained_temp_enter=.*/sustained_temp_enter=70/' "$MOD/config/governor.conf"
run_writer set gnss_trim 1 >/dev/null
need_line "$MOD/config/governor.conf" "sustained_temp_enter=70"
need_line "$MOD/config/governor.conf" "sustained_temp_ceiling=70"
need_line "$STATE/config_last_txn" "recovery=legacy_thermal_ceiling"
if run_writer set sustained_temp_ceiling 68 >/dev/null 2>&1; then
  fail "explicit invalid thermal ceiling was accepted"
fi
need_line "$MOD/config/governor.conf" "sustained_temp_ceiling=70"

# F-02: a thermal overlay above 100 used to become a negative multiplier and
# make the writer silently skip the safety cap. Both values must be rejected.
if run_writer set thermal_overlay_pct 999 >/dev/null 2>&1; then
  fail "unsafe thermal_overlay_pct was accepted"
fi
if run_writer set thermal_junction_hard_c 0 >/dev/null 2>&1; then
  fail "unsafe thermal_junction_hard_c was accepted"
fi
need_line "$MOD/config/governor.conf" "thermal_overlay_pct=18"
need_line "$MOD/config/governor.conf" "thermal_junction_hard_c=95"

# ASB-04: the transaction boundary must reject malformed or out-of-range values
# before they reach a persisted config, not only rely on WebUI slider constraints.
for _pair in \
  'heavy_load_enter nan' \
  'gpu_idle_trim_pct -100' \
  'gpu_video_max_pct 999' \
  'smart_media_guard 2' \
  'gaming_confirm_ticks 0' \
  'thermal_throttle_temp 0' \
  'device_bounds_override 999'; do
  set -- $_pair
  if run_writer set "$1" "$2" >/dev/null 2>&1; then
    fail "unsafe $1=$2 was accepted"
  fi
done
need_line "$MOD/config/governor.conf" "heavy_load_enter=20.0"
need_line "$MOD/config/governor.conf" "gpu_idle_trim_pct=12"
need_line "$MOD/config/governor.conf" "gaming_confirm_ticks=6"
need_line "$MOD/config/governor.conf" "smart_media_guard=0"
run_writer set smart_media_guard 1 >/dev/null
need_line "$MOD/config/governor.conf" "smart_media_guard=1"
run_writer set net_mtu_probing on >/dev/null
need_line "$MOD/config/governor.conf" "net_mtu_probing=on"
if run_writer set net_mtu_probing always >/dev/null 2>&1; then
  fail "net_mtu_probing=always was accepted"
fi
need_line "$MOD/config/governor.conf" "net_mtu_probing=on"

# A linked slider update must commit both keys and its snapshot under one lock.
run_writer set-many --snapshot "$SNAP" \
  sustained_temp_enter 60 sustained_temp_mode manual >/dev/null
need_line "$MOD/config/governor.conf" "sustained_temp_enter=60"
need_line "$MOD/config/governor.conf" "sustained_temp_mode=manual"
need_line "$SNAP" "sustained_temp_enter=60"
need_line "$SNAP" "sustained_temp_mode=manual"

# Ace 5 regression: moving the WebUI thermal slider above the previous smart
# ceiling must stage the linked ceiling in the same transaction. In particular,
# 70 is a valid inclusive upper bound, not a writer failure.
run_writer set-many --snapshot "$SNAP" \
  sustained_temp_enter 70 sustained_temp_ceiling 70 sustained_temp_mode manual >/dev/null
need_line "$MOD/config/governor.conf" "sustained_temp_enter=70"
need_line "$MOD/config/governor.conf" "sustained_temp_ceiling=70"
need_line "$MOD/config/governor.conf" "sustained_temp_mode=manual"
need_line "$SNAP" "sustained_temp_enter=70"
need_line "$SNAP" "sustained_temp_ceiling=70"
need_line "$SNAP" "sustained_temp_mode=manual"

# F-03: malformed imports must leave the active configuration untouched.
printf 'sustained_temp_enter=999\n' > "$BACKUP"
if run_writer import "$BACKUP" "$SNAP" sustained_temp_enter sustained_temp_mode >/dev/null 2>&1; then
  fail "invalid import was accepted"
fi
need_line "$MOD/config/governor.conf" "sustained_temp_enter=70"

# A valid import is applied as one validated transaction and updates the snapshot.
printf 'sustained_temp_enter=62\nsustained_temp_mode=manual\n' > "$BACKUP"
run_writer import "$BACKUP" "$SNAP" sustained_temp_enter sustained_temp_mode >/dev/null
need_line "$MOD/config/governor.conf" "sustained_temp_enter=62"
need_line "$MOD/config/governor.conf" "sustained_temp_mode=manual"
need_line "$SNAP" "sustained_temp_enter=62"
need_line "$SNAP" "sustained_temp_mode=manual"

echo "PASS config writer"
)

t_contract_bundle() (
# Source-pin contracts bundled into one script (fix98).
#
# Each section is one former tests/test_<name>.sh, verbatim, run in its own subshell so
# its variables, traps and early "exit 0" skips stay local. They were ~40 separate files
# of 10-200 ms each; the runtime tests that wait on real timers stay separate so the
# parallel regression runner can overlap them. Add a new source-pin contract as a new
# section here rather than a new file.

# ==== action_helper_order_contract ====================================================================
(
# Contract: action.sh never calls a helper before the line that defines it.
# A fix44 block called _st above its definition and the report printed "_st: not found".
set -u
A="$(cd "$(dirname "$0")/.." && pwd)/action.sh"
fail=0
for h in _st _cfg _feat _s _f _join; do
  d="$(grep -n "^$h() *{" "$A" | head -1 | cut -d: -f1)"
  [ -n "$d" ] || continue
  u="$(grep -nE "(\\\$\\(|^[[:space:]]*|[;&|] *)$h " "$A" | grep -v "^$d:" | head -1 | cut -d: -f1)"
  [ -n "$u" ] && [ "$u" -lt "$d" ] && { echo "FAIL action helper order: $h used on line $u, defined on line $d" >&2; fail=1; }
done
[ "$fail" = 0 ] && echo "PASS action helper order"
exit "$fail"

) || { echo "FAIL in bundled contract: action_helper_order_contract" >&2; exit 1; }

# ==== action_i18n_contract ====================================================================
(
# Contract: action.sh report translations.
#
# Every runtime/i18n/action_<lang>.sh must cover every T_* key action.sh defines, with
# the same printf placeholders in the same number - a missing %s shifts every value after
# it, and a bare % makes printf eat the rest of the line. No translation may contain a
# backslash, a backtick or "$(" - the files are sourced, not parsed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="$ROOT/action.sh"
DIR="$ROOT/runtime/i18n"
fail=0
f() { echo "FAIL: $*" >&2; fail=1; }

# One awk pass per language: placeholder COUNTS (%s, %%, any other %), not order -
# Turkish writes the percent sign before the number ("%%%s").
_awk='
function sig(v,  r, n1, n2, n3) {
  r = v; n2 = gsub(/%%/, "", r); n1 = gsub(/%s/, "", r); n3 = gsub(/%/, "", r)
  return "s=" n1 " pct=" n2 " bare=" n3
}
function val(line,  v) { v = line; sub(/^[A-Z0-9_]+="/, "", v); sub(/"[[:space:]]*$/, "", v); return v }
FNR == NR { if ($0 ~ /^T_[A-Z0-9_]+="/) { k = $0; sub(/=.*/, "", k); if (!(k in en)) { en[k] = val($0); order[++n] = k } } next }
$0 ~ /^T_[A-Z0-9_]+="/ { k = $0; sub(/=.*/, "", k); tr[k] = val($0) }
END {
  if (n == 0) { print "no T_* defaults in action.sh"; exit }
  for (i = 1; i <= n; i++) { k = order[i]
    if (!(k in tr)) { print lang ": missing " k; continue }
    if (sig(tr[k]) != sig(en[k])) print lang ": " k " placeholders " sig(tr[k]) " != en " sig(en[k])
  }
  for (k in tr) if (!(k in en)) print lang ": unknown key " k
}'

for lang in ru uk de es pt tr id fr hy it ar zh; do
  file="$DIR/action_${lang}.sh"
  [ -f "$file" ] || { f "missing $file"; continue; }
  sh -n "$file" 2>/dev/null || f "$lang: syntax error"
  if grep -nE '\\|`|\$\(' "$file" | grep -v '^[0-9]*:#' >/dev/null; then f "$lang: shell-unsafe character"; fi
  _out="$(awk -v lang="$lang" "$_awk" "$ACTION" "$file")"
  [ -z "$_out" ] || { echo "$_out" | while IFS= read -r l; do echo "FAIL: $l" >&2; done; fail=1; }
  # Indonesian has no learning-block strings in action.sh itself; its file must carry them.
  if [ "$lang" = id ]; then
    for k in M_CONF_LOW M_SLOT M_DP0 M_WEEKDAY M_W_HOT; do
      grep -qE "(^|[; ])$k=" "$file" || f "id: missing $k"
    done
  fi
done

grep -q 'runtime/i18n/action_${_asb_lang}.sh' "$ACTION" || f "action.sh does not load the translation file"

[ "$fail" = 0 ] && echo "PASS: action i18n contract"
exit "$fail"

) || { echo "FAIL in bundled contract: action_i18n_contract" >&2; exit 1; }

# ==== asb_state_dir_fixes_contract ====================================================================
(
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

) || { echo "FAIL in bundled contract: asb_state_dir_fixes_contract" >&2; exit 1; }

# ==== audio_live_player_contract ====================================================================
(
# Contract + fixture: "something is playing" means a live AudioPlaybackConfiguration line.
# History lines and idle players must not count (external audit fix44, P2).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; f() { echo "FAIL audio live player: $*" >&2; fail=1; }
RX='AudioPlaybackConfiguration .*state:started'
live='  AudioPlaybackConfiguration piid:79 deviceIds:[2] type:android.media.MediaPlayer u/pid:10652/9876 state:started attr:AudioAttributes: usage=USAGE_MEDIA'
idle='  AudioPlaybackConfiguration piid:80 deviceIds:[] type:AAudio u/pid:10658/1234 state:paused attr:AudioAttributes: usage=USAGE_MEDIA'
hist='  10-07 12:01:02:123 player piid:63 state:started'
hist2='  10-07 12:01:02:123 player piid:63 event:started'
printf '%s\n' "$live" | grep -qE "$RX" || f "live player not recognised"
printf '%s\n%s\n%s\n' "$idle" "$hist" "$hist2" | grep -qE "$RX" && f "idle player or history counted as playing"
for file in runtime/asb_screenoff_class.sh service.sh tools/asb_diag.sh tools/logkit/_asb_logkit_common.sh tools/logkit/asb_audio_ab.sh; do
  grep -q "AudioPlaybackConfiguration .\*state:started" "$ROOT/$file" || f "$file does not use the live-player pattern"
  grep -vE '^[[:space:]]*#' "$ROOT/$file" | grep -qE "player piid\.\*started|grep -q[a-zA-Z]* '?\"?state:started|\*state:started\*" && f "$file still matches history lines"
done
[ "$fail" = 0 ] && echo "PASS audio live player"
exit "$fail"

) || { echo "FAIL in bundled contract: audio_live_player_contract" >&2; exit 1; }

# ==== bg_bucket_restore_contract ====================================================================
(
# Contract + runtime: standby buckets forced by background trimming are recorded and
# handed back, and uninstall does it too.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/service.sh"; U="$ROOT/uninstall.sh"
fail=0; f() { echo "FAIL bg buckets: $*" >&2; fail=1; }
blk="$(sed -n '/^asb_bg_trim_apply_buckets() {/,/^}/p' "$S")"
printf '%s\n' "$blk" | grep -q 'am set-standby-bucket' && f "apply_buckets forces a bucket without recording it"
grep -q '/data/adb/asb/bg_buckets_orig' "$U" || f "uninstall does not restore recorded buckets"
# Uninstall's fallback list must be the heavy list, or an old install keeps apps in rare.
heavy="$(sed -n '/^_BG_TRIM_HEAVY="/,/^"/p' "$S" | grep -E '^[a-z]' | sort | tr '\n' ' ')"
unl="$(sed -n '/for _bp in com.facebook.katana/,/; do/p' "$U" | tr -s ' \\\n' '\n' | sed 's/;$//' | grep -E '^com\.' | sort | tr '\n' ' ')"
[ "$heavy" = "$unl" ] || f "uninstall fallback list differs from _BG_TRIM_HEAVY: [$heavy] vs [$unl]"

# Runtime: extract the two helpers and drive them with a stub am.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/am" <<'A'
#!/bin/sh
case "$1" in
  get-standby-bucket) case "$2" in com.inst|com.daily) echo 10 ;; com.gone) echo "Error: no package" ;; *) echo 30 ;; esac ;;
  set-standby-bucket) echo "$2 $3" >> "$AMLOG" ;;
esac
A
chmod +x "$T/bin/am"
{ sed -n '/^ASB_BG_BUCKETS_ORIG=/p' "$S"; sed -n '/^asb_bg_bucket_set() {/,/^}/p;/^asb_bg_bucket_restore() {/,/^}/p;/^asb_bg_bucket_demote_idle() {/,/^}/p' "$S"; } \
  | sed "s#/data/adb/asb#$T/d#g" > "$T/h.sh"
cat >> "$T/h.sh" <<'E'
asb_bg_bucket_set com.inst rare
asb_bg_bucket_set com.inst rare
asb_bg_bucket_set com.gone rare
asb_bg_bucket_set com.msg active
asb_bg_bucket_demote_idle com.daily rare
asb_bg_bucket_demote_idle com.weekly rare
asb_bg_bucket_restore
E
AMLOG="$T/am.log" PATH="$T/bin:$PATH" bash "$T/h.sh"
grep -qx 'com.inst 10' "$T/am.log" || f "original bucket not restored"
grep -qx 'com.msg 30' "$T/am.log" || f "second app not restored"
grep -q 'com.gone' "$T/am.log" && f "uninstalled package touched"
[ "$(grep -c '^com.inst rare$' "$T/am.log")" = 2 ] || f "set not applied"
[ -f "$T/d/bg_buckets_orig" ] && f "record not cleared after restore"
grep -q '^com.daily ' "$T/am.log" && f "an app in daily use was demoted"
grep -qx 'com.weekly rare' "$T/am.log" || f "an app out of daily use was not demoted"
# Heavy apps go through the idle-only rule; aggressive without opt-in gets the periodic pass.
printf '%s\n' "$blk" | grep -q 'asb_bg_bucket_demote_idle "$_p" rare' || f "heavy apps bypass the idle-only rule"
sed -n '/allow_disruptive_bg_trim \]; then/,/return 0/p' "$S" | grep -q 'asb_bg_trim_periodic' || f "smart aggressive has no periodic pass"
[ "$fail" = 0 ] && echo "PASS bg bucket restore"
exit "$fail"

) || { echo "FAIL in bundled contract: bg_bucket_restore_contract" >&2; exit 1; }

# ==== camera_bind_requeue_contract ====================================================================
(
# Contract: every staged camera payload is queued for the boot-time bind - no comparison with
# the live file at install time (fix54 skipped on equality; fix64 drops the comparison: what
# the live path shows mid-install says nothing about what it shows after the reboot).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/common/install.sh"
fail=0; f() { echo "FAIL camera bind requeue: $*" >&2; fail=1; }
body="$(sed -n '/^asb_generate_odm_camera_binds()/,/^}/p' "$I")"
printf '%s\n' "$body" | grep -q 'cmp -s' && f 'a live-file comparison can skip the camera bind again'
printf '%s\n' "$body" | grep -Fq 'echo "${_obc_live}|${_obc_dst}" >> "$_obc_man"' || f 'camera payload no longer queued'
grep -Fq 'camera bind: ' "$ROOT/tools/asb_diag.sh" || f 'asbdiag does not show camera bind evidence'
grep -Fq 'nsenter -t 1 -m -- umount "$_ct_live"' "$I" || f 'installer does not take down its own camera bind before declaring the live tone table dirty'
# fix112: the skipped install ships no tone file and the install wipes odm_patched and the
# bind manifest, so after its reboot one more install finds stock - no disable step needed.
grep -q 'ASB_L_CAM_LIVE_DIRTY2=".*after the reboot just install ASB once more' "$ROOT/common/englishtext.sh" || f 'dirty-camera advice does not say "install once more after the reboot"'
# fix146: the wipe moved to asb_reset_odm_binds (before the audio stage); payloads and the
# manifest still go, only the partition's stock snapshots are kept.
_rb="$(sed -n '/^asb_reset_odm_binds() {/,/^}/p' "$I")"
printf '%s\n' "$_rb" | grep -Fq "find \"\$_rb_root\" -type f ! -name '*.stock' ! -name '.base_fp' -delete" \
  && printf '%s\n' "$_rb" | grep -Fq 'rm -f "${ASB_ODM_MAN:-/data/adb/asb/odm_bind_manifest.txt}"' \
  || f 'install no longer wipes the old odm payloads and the manifest (the advice depends on it)'
[ "$fail" = 0 ] && echo "PASS camera bind requeue contract"
exit "$fail"

) || { echo "FAIL in bundled contract: camera_bind_requeue_contract" >&2; exit 1; }

# ==== cap_source_own_write_contract ====================================================================
(
# fix74: the ceiling ASB wrote to scaling_max_freq is classified as ASB's, not as a vendor
# clamp. The classifier compared the live ceiling with the msm_performance cap, which the
# writer only touches in HEAVY/GAMING - so every Smart cap in LIGHT/MODERATE read as
# "vendor_clamp" (field OP15, 35 C: vendor_clamp_1h=424, holddown active on its own writes).
# Executable fixture: the REAL cap_source_classify() cut out of asb_governor.c.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL cap source own-write: $*" >&2; exit 1; }

grep -q 'real_max_p0, hw_ceil_p0,' "$G" || fail "status builder call changed shape"
grep -q 'g_wcache.cpu_max\[0\]);' "$G" || fail "little cluster classified without ASB's written cap"
grep -q 'g_wcache.cpu_max\[1\]);' "$G" || fail "prime cluster classified without ASB's written cap"

awk '/^static inline const char \*cap_source_classify\(/{on=1} on{print} on&&/^}/{exit}' "$G" > "$T/fn.c"
[ -s "$T/fn.c" ] || fail "cap_source_classify not found"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
#include "fn.c"
static int bad;
static void eq(const char *got, const char *want, const char *what) {
    if (strcmp(got, want)) { printf("%s: got %s want %s\n", what, got, want); bad = 1; }
}
int main(void) {
    // OP15 LIGHT_IDLE: profile ceiling 3628800, msm cap at hw max, ASB wrote 1440000
    eq(cap_source_classify(3628800, 3628800, 1440000, 3628800, 1440000), "asb_dynamic", "own smart cap");
    eq(cap_source_classify(1440000, 3628800, 1440000, 3628800, 1440000), "asb", "own cap = profile");
    // something below what ASB wrote is still a clamp
    eq(cap_source_classify(3628800, 3628800, 1209600, 3628800, 1440000), "vendor_clamp", "real clamp");
    // somebody rewrote the node above ours
    eq(cap_source_classify(3628800, 1440000, 2000000, 3628800, 1440000), "vendor_raised", "raised");
    // no msm_performance node: ASB's own write is not a shell override
    eq(cap_source_classify(3628800, 0, 1440000, 3628800, 1440000), "asb_dynamic", "no msm, own cap");
    eq(cap_source_classify(3628800, 0, 3628800, 3628800, 0), "shell_applied", "nothing written yet");
    return bad;
}
X
cc -std=gnu11 -Wall -Werror -I"$T" "$T/t.c" -o "$T/t" || fail "fixture does not compile"
"$T/t" || fail "classification wrong"
echo "PASS cap source recognises ASB's own writes"

) || { echo "FAIL in bundled contract: cap_source_own_write_contract" >&2; exit 1; }

# ==== cfg_conflicts_contract ====================================================================
(
# WebUI tweak conflicts: choosing one side of a real contradiction switches the other side
# off in the same atomic write, so two cards can never both read "on" for a pair the
# runtime resolves behind the user's back. Dependencies are explained, never auto-enabled.
# Executable fixture: the REAL rule tables and resolver functions under node.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL cfg conflicts: $*" >&2; exit 1; }

grep -q "const _fix = cfgConflictResolve(key, val, cfgCurVal);" "$H" || fail "cfgSet does not resolve conflicts"
grep -q "' set-many --snapshot ' + shQuote(snap) + ' ' +" "$H" || fail "no atomic set-many write"
grep -Fq "_fix.map(function(c) { return ' ' + shQuote(c.key) + ' ' + shQuote(c.val); }).join('')" "$H" || fail "counterparts not in the same write"
grep -Fq "_fix.forEach(function(c) { _cfgVals[c.key] = c.val; });" "$H" || fail "UI state not updated for the switched-off card"
grep -Fq "(AUDIO_DSP_KEYS.indexOf(key) >= 0 && !_fix.length) ? ' dsp' : ''" "$H" || fail "a resolved audio_profile change would take the DSP-only path"
# The pair is real: the runtime resolves it the same way.
grep -q 'eq_compat wins and the DSP is turned off outright' "$ROOT/runtime/asb_audio_apply.sh" || fail "eq_compat/DSP precedence gone from runtime - re-check the rule"
grep -q '_radio_policy_enabled' "$ROOT/runtime/asb_lpm.sh" || fail "night_modem_idle dependency no longer real"
for f in "$ROOT"/webroot/i18n/*.json; do
  for k in t_cfg_conflict_off t_cfg_needs t_cfg_idle; do
    grep -q "\"$k\"" "$f" || fail "$(basename "$f") lacks $k"
  done
done

command -v node >/dev/null 2>&1 || { echo "PASS cfg conflicts contract (no node: source pins only)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  sed -n '/^const CFG_ITEMS = \[/,/^\];/p' "$H"
  sed -n '/^const CFG_CONFLICTS = \[/,/^\];/p' "$H"
  sed -n '/^const CFG_REQUIRES = \[/,/^\];/p' "$H"
  for fn in cfgConflictResolve cfgRequireNotes cfgDefOf; do
    sed -n "/^function $fn(/,/^}/p" "$H"
  done
  cat <<'EOF'
let bad = 0;
const keys = CFG_ITEMS.map(function(x) { return x.key; });
function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
CFG_CONFLICTS.forEach(function(r) {
  [r.a, r.b].forEach(function(s) {
    chk(keys.indexOf(s.key) >= 0, 'conflict key ' + s.key + ' is not a setting');
    chk(!s.on(s.off), 'off value of ' + s.key + ' still counts as on');
  });
});
CFG_REQUIRES.forEach(function(r) {
  chk(keys.indexOf(r.key) >= 0 && keys.indexOf(r.needs) >= 0, 'requires keys unknown: ' + r.key);
});
function cur(map) { return function(k) { return (k in map) ? map[k] : cfgDefOf(k); }; }
let x = cfgConflictResolve('dsp_loudness', '6', cur({ audio_profile:'eq_compat' }));
chk(x.length === 1 && x[0].key === 'audio_profile' && x[0].val === 'stock', 'DSP on did not switch EQ profile off: ' + JSON.stringify(x));
x = cfgConflictResolve('audio_profile', 'eq_compat', cur({ dsp_loudness:'12' }));
chk(x.length === 1 && x[0].key === 'dsp_loudness' && x[0].val === '0', 'EQ profile did not switch DSP off: ' + JSON.stringify(x));
chk(cfgConflictResolve('audio_profile', 'hifi', cur({ dsp_loudness:'12' })).length === 0, 'hifi is not a conflict');
chk(cfgConflictResolve('dsp_loudness', '0', cur({ audio_profile:'eq_compat' })).length === 0, 'DSP off is not a conflict');
chk(cfgConflictResolve('dsp_loudness', '6', cur({ audio_profile:'stock' })).length === 0, 'no conflict with stock');
chk(cfgConflictResolve('disable_blur', '1', cur({})).length === 0, 'unrelated key touched');
let n = cfgRequireNotes('night_modem_idle', '1', cur({ radio_policy_enable:'0' }));
chk(n.length === 1 && n[0].kind === 'needs' && n[0].other === 'radio_policy_enable', 'missing master not noted');
chk(cfgRequireNotes('night_modem_idle', '1', cur({ radio_policy_enable:'1' })).length === 0, 'note with master on');
n = cfgRequireNotes('dsp_loudness', '0', cur({ dsp_bass:'5' }));
chk(n.length === 1 && n[0].kind === 'idle' && n[0].key === 'dsp_bass', 'bass left idle not noted');
chk(cfgRequireNotes('heavy_prime_escape', '0', cur({})).length === 0, 'default burst/rest noted as idle');
chk(cfgRequireNotes('doze_trim_whitelist', '1', cur({ doze_level:'night' })).length === 0, 'night doze satisfies trim');
process.exit(bad);
EOF
} > "$TMP/t.js"
node "$TMP/t.js" || fail "resolver fixture failed"
echo "PASS cfg conflicts contract"

) || { echo "FAIL in bundled contract: cfg_conflicts_contract" >&2; exit 1; }

# ==== current_scale_contract ====================================================================
(
# Contract + simulation: the governor measures the battery-current gauge scale.
# A gauge that reports half the real current (OnePlus 15) must come out near 0.5; screen-off
# time and charging must not contaminate the window.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL current scale: $*" >&2; fail=1; }
grep -q 'current_scale_x100=%d' "$G" || f "scale not published"
[ "$(grep -c 'asb_curscale_track(metrics.misc.screen_on' "$G")" -ge 2 ] || f "not called on both tick paths"
command -v gcc >/dev/null 2>&1 || { [ "$fail" = 0 ] && echo "PASS current scale (contract only, no gcc)"; exit "$fail"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$G" "$T" <<'PY' || { echo "FAIL current scale: extraction" >&2; exit 1; }
import sys
s=open(sys.argv[1]).read(); t=sys.argv[2]
a=s.index('#define ASB_CURSCALE_FILE'); b=s.index('/* Called once per tick. screen_on resets the window')
code=s[a:b].replace('"/data/adb/asb/current_scale_x100"','"%s/cs"' % t)
main=r'''
int main(int argc,char**argv){ double gauge=atof(argv[1]); int pct; int t;
 for(t=0;t<5*3600;t+=5){ g_now=t*1000L;
   double used=700.0*t/3600.0; pct=85-(int)(used*100/7300);
   int scr=(t/600)%3!=2;
   int chg=(t>=3*3600 && t<3*3600+600);    /* a charger plugged in briefly */
   asb_curscale_track(scr,pct,chg,(int)(700.0*gauge)); }
 printf("%d %d\n",g_curscale_x100,g_curscale_n); return 0;}
'''
open(t+'/t.c','w').write('#include <stdio.h>\n#include <stdlib.h>\n#include <time.h>\nstatic long g_now=0;\nstatic long asb_clock_ms(int c){(void)c;return g_now;}\nstatic long sysfs_read_long(const char*p,long d){(void)p;(void)d;return 7300000;}\n'+code+main)
PY
gcc -Wall -Werror -o "$T/t" "$T/t.c" || { echo "FAIL current scale: compile" >&2; exit 1; }
set -- $("$T/t" 0.5); [ "$1" -ge 42 ] && [ "$1" -le 58 ] && [ "$2" -ge 2 ] || f "half-reading gauge measured as $1 ($2 windows)"
rm -f "$T/cs"
set -- $("$T/t" 1.0); [ "$1" -ge 88 ] && [ "$1" -le 112 ] || f "true gauge measured as $1"
[ "$fail" = 0 ] && echo "PASS current scale"
exit "$fail"

) || { echo "FAIL in bundled contract: current_scale_contract" >&2; exit 1; }

# ==== dsp_core_cpu_contract ====================================================================
(
# fix78: the compressor gain (log10f + powf) is evaluated every ASB_COMP_EVERY frames and
# skipped below the knee instead of 48000 times a second; the limiter stays per frame.
# Host measurement at +12 dB on a 60 s music-like signal: 101 -> 45 ms CPU, output
# difference -55 dB relative, peak still under the ceiling. Runtime: same signal through the
# real core, every output sample within the ceiling.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/src/DSP_AIDL/asb_dsp_core.h"
fail() { echo "FAIL dsp core cpu: $*" >&2; exit 1; }
grep -q '#define ASB_COMP_EVERY   16' "$H" || fail "no decimation constant"
grep -q 'if (env <= c->knee_lo_lin) return 1.0f;' "$H" || fail "no below-knee shortcut"
[ "$(grep -c 'float cg = asb_core_comp_step(c, peak);' "$H")" = 2 ] || fail "a process path still evaluates the gain per frame"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <stdlib.h>
#include "asb_dsp_core.h"
#define N 96000
static float in[N*2], out[N*2];
int main(void){
  srand(3);
  for(int i=0;i<N;i++){ float e=0.3f+0.7f*fabsf(sinf(i*0.0003f)); float x=e*(0.6f*sinf(i*0.05f)+0.3f*((rand()/(float)RAND_MAX)-0.5f)); in[2*i]=x; in[2*i+1]=-x; }
  asb_core_t c={0}; asb_core_reset(&c);
  asb_core_configure_ex(&c,1,2500,-15,1,60,-2400,2,48000,1,0,300);
  for(int o=0;o<N;o+=480) asb_core_process_f32(&c,in+2*o,out+2*o,480,0);
  for(int i=0;i<N*2;i++) if (fabsf(out[i]) > c.ceiling + 1e-6f) { printf("over ceiling at %d: %f\n", i, out[i]); return 1; }
  return 0;
}
X
cc -O2 -I"$ROOT/src/DSP_AIDL" "$T/t.c" -lm -o "$T/t" && "$T/t" || fail "limiter ceiling broken"
echo "PASS DSP core evaluates the compressor gain per block"

) || { echo "FAIL in bundled contract: dsp_core_cpu_contract" >&2; exit 1; }

# ==== dsp_route_backoff_contract ====================================================================
(
# Contract: the DSP route watcher does not dump the audio service on a fixed 5 s clock.
#
# With a dsp_outputs filter set it ran `dumpsys audio` every 5 s of screen-on time - about
# 720 framework dumps an hour, nearly all returning the same route. It now backs off to
# 30 s (15 s while playing) and is pulled forward by the kernel's PCM state, which costs
# a file read instead of a binder walk.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/service.sh"
fail=0; f() { echo "FAIL dsp route backoff: $*" >&2; fail=1; }
blk="$(sed -n '/_prev_route=""/,/persist.asb.dsp.route "\$_now"/p' "$S")"
[ -n "$blk" ] || { echo "FAIL dsp route backoff: watcher block not found" >&2; exit 1; }
printf '%s\n' "$blk" | grep -q '_sig="$_aa_sig"' || f "no playback-state pull-forward"
grep -q 'grep -l RUNNING "$_aa_snd"/card\*/pcm\*p/sub\*/status' "$ROOT/runtime/asb_audio_activity.sh" || f "PCM state no longer read where the kernel has it"
grep -q 'AudioOut_\*) _aa_outs=' "$ROOT/runtime/asb_audio_activity.sh" || f "no playback signal on kernels without PCM state"
printf '%s\n' "$blk" | grep -q '\[ "$_since" -lt "${_iv:-5}" \]' || f "dump not gated by the interval"
printf '%s\n' "$blk" | grep -q '_ivmax=30; \[ "$_play_now" = 1 \] && _ivmax=15' || f "back-off ceilings changed"
# The dump must come after the gate, never straight after a fixed sleep.
printf '%s\n' "$blk" | awk '/sleep 5$/ { s = NR } /_adump="\$\(dumpsys audio/ { if (s && NR - s < 3) bad = 1 } END { exit bad }' \
  || f "dumpsys audio directly after a fixed sleep"
[ "$fail" = 0 ] && echo "PASS dsp route backoff contract"
exit "$fail"

) || { echo "FAIL in bundled contract: dsp_route_backoff_contract" >&2; exit 1; }

# ==== dsp_route_release_contract ====================================================================
(
# fix77: off the selected outputs the attach daemon RELEASES the effect instead of keeping
# it attached at gain 0. An enabled effect on the global mix is non-offloadable for the
# audio policy even as a pass-through, so the stream stayed off the offload path and the
# CPU awake (dsp_outputs=speaker/bt is set on field phones). The daemon is a prebuilt, so
# the freshness gate must refuse an older binary.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/src/DSP_AIDL/asb_dsp_attach.cpp"
fail() { echo "FAIL dsp route release: $*" >&2; exit 1; }
grep -q 'int route_ok = route_allows_dsp();' "$A" || fail "daemon does not check the route before attaching"
grep -q 'if (want_on && !route_ok) {' "$A" || fail "no release branch"
grep -q 'logline("released (route not selected)");' "$A" || fail "release not logged (freshness marker)"
# the release branch must come before the attach code, or it never runs while attached
_rel="$(grep -n 'if (want_on && !route_ok) {' "$A" | cut -d: -f1)"
_att="$(grep -n 'next->set(&kAsbTypeUuid' "$A" | cut -d: -f1)"
[ "$_rel" -lt "$_att" ] || fail "release branch after the attach path"
grep -q '"released (route not selected)"[^;]*; do' "$ROOT/src/build_ndk_release.sh" || fail "freshness gate misses the release marker"
grep -q 'persist.asb.dsp.voice' "$A" || fail "voice edits do not trigger a push"
grep -q 'DSP released on purpose' "$ROOT/tools/asb_diag.sh" || fail "asbdiag reports the intended release as a failure"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
# fix79: with the screen off the route watcher still reacts to a PCM change (one pass)
grep -q '_sig_off="$_aa_sig"' "$ROOT/service.sh" || fail "screen-off route change is never noticed"
# Gated on a PCM change - plus, from fix137, one route look a minute into an idle stretch.
grep -q 'if \[ "$_sig_off" = "${_prev_sig:-}" \]; then' "$ROOT/service.sh" || fail "screen-off pass is not gated on a PCM change"
grep -q '_idle_due && _force=1 || continue' "$ROOT/service.sh" || fail "screen-off pass is not gated on a PCM change"
echo "PASS DSP released off the selected outputs"

) || { echo "FAIL in bundled contract: dsp_route_release_contract" >&2; exit 1; }

# ==== fg_uclamp_guard_contract ====================================================================
(
# One native owner handles Smart's screen transitions, Battery's short foreground lift,
# the pre-existing max correction and camera exclusion. The executable fixture drives the REAL
# production functions against a synthetic cgroup/state directory; manual profiles must not
# inherit Smart's sleep cap, and Smart/Balanced must not inherit Battery's foreground lift.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"; G="$ROOT/src/asb_governor.c"; D="$ROOT/runtime/smart_dynamic_tune.sh"
fail() { echo "FAIL fg uclamp guard contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$W" 'static void writer_fg_guard(int screen_on, int smart_screen_policy,' 'native owner missing'
need "$W" 'if (g_cam_guard_on) { g_fg_max_since = 0; return; }' 'camera guard is not exclusive'
need "$W" 'if (!smart_screen_policy || cur <= 35) return;' 'manual profile inherited Smart sleep cap'
need "$W" 'if (now - g_fg_max_since < 60) return;' 'no 60 s persistence before acting'
need "$W" 'g_fg_backoff_until = now + 600' 'no stand-down when something keeps reasserting'
need "$G" 'writer_fg_guard(metrics.misc.screen_on, fsm.profile_idx == PROFILE_SMART,' 'Smart policy not scoped in governor loop'
need "$G" 'fsm.profile_idx == PROFILE_BATTERY && g_unlock_lift_now &&' 'Battery foreground lift not scoped in governor loop'
need "$G" 'fg_guard_fixes=%lu' 'corrections not published'
grep -Fq '/dev/cpuctl/foreground/cpu.uclamp.max' "$D" && fail 'shell tuner still writes foreground uclamp'
grep -Fq '_ucfg_fallback' "$D" && fail 'shell fallback writer remains'

CC=""; for c in ${HOST_CC:-} gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
if [ -z "$CC" ]; then echo 'PASS fg uclamp guard contract (source pins only)'; exit 0; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT HUP INT TERM
sed -n '/^static int    g_fg_last_good = -1;$/,/^static void writer_fg_guard(int screen_on, int smart_screen_policy,$/p' "$W" > "$T/fg.c"
# The range above ends at the function opening; append its complete body through the next brace.
awk '/^static void writer_fg_guard\(int screen_on, int smart_screen_policy,$/{on=1; next} on{print; if ($0 == "}") exit}' "$W" >> "$T/fg.c"
grep -q 'writer_fg_fallback' "$T/fg.c" || fail 'native fixture extraction failed'
cat > "$T/t.c" <<X
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#define UCLAMP_FG_MAX "$T/fg"
#define UCFG_LAST_GOOD "$T/last"
#define UCFG_RESTORE "$T/restore"
static int g_cam_guard_on = 0;
static char g_profile[24] = "smart";
static void writer_read_current_profile(char *out, size_t n) { snprintf(out, n, "%s", g_profile); }
static int sysfs_read_int(const char *path, int def) {
    FILE *f = fopen(path, "r"); int v = def;
    if (f) { if (fscanf(f, "%d", &v) != 1) v = def; fclose(f); }
    return v;
}
static int uclamp_read_pct(const char *path, int def) {
    char b[32] = {0}; FILE *f = fopen(path, "r");
    if (!f) return def;
    if (!fgets(b, sizeof(b), f)) { fclose(f); return def; }
    fclose(f);
    return !strncmp(b, "max", 3) ? 100 : (int)strtol(b, NULL, 10);
}
static int sysfs_write_int(const char *path, int value) {
    FILE *f = fopen(path, "w"); if (!f) return -1;
    int rc = fprintf(f, "%d.00\n", value) > 0 ? 0 : -1; fclose(f); return rc;
}
#include "fg.c"
static int fails = 0;
static void put_raw(const char *s) { FILE *f = fopen(UCLAMP_FG_MAX, "w"); fputs(s, f); fclose(f); }
static void put_state(const char *path, int v) { FILE *f = fopen(path, "w"); if (f) { fprintf(f, "%d\n", v); fclose(f); } }
static void reset_fg(const char *raw, const char *profile) {
    put_raw(raw); snprintf(g_profile, sizeof(g_profile), "%s", profile);
    unlink(UCFG_LAST_GOOD); unlink(UCFG_RESTORE); g_cam_guard_on = 0;
    g_fg_last_good = -1; g_fg_max_since = 0; g_fg_fix_n = 0; g_fg_fix_window = 0;
    g_fg_backoff_until = 0; g_fg_fix_total = 0;
    g_fg_lift_on = 0; g_fg_lift_saved = -1;
}
static void check(int cond, const char *what) { if (!cond) { printf("  FAIL %s\n", what); fails++; } }
int main(void) {
    reset_fg("70.00\n", "smart"); writer_fg_guard(0, 1, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 35, "Smart screen-off did not lower to 35");
    check(sysfs_read_int(UCFG_RESTORE, -1) == 70, "ordinary wake value not saved");
    check(sysfs_read_int(UCFG_LAST_GOOD, -1) == 70, "last-good not saved");
    writer_fg_guard(0, 1, 0, 80);
    check(sysfs_read_int(UCFG_RESTORE, -1) == 70, "second sleep tick overwrote restore");
    writer_fg_guard(1, 1, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 70 && access(UCFG_RESTORE, F_OK) != 0, "wake did not restore exactly once");

    reset_fg("max\n", "smart"); put_state(UCFG_LAST_GOOD, 70); writer_fg_guard(0, 1, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 35 && sysfs_read_int(UCFG_RESTORE, -1) == 70, "max was not replaced by last-good");

    reset_fg("max\n", "balanced"); writer_fg_guard(0, 1, 0, 80);
    check(sysfs_read_int(UCFG_RESTORE, -1) == 70, "balanced fallback changed");
    reset_fg("max\n", "performance"); writer_fg_guard(0, 1, 0, 80);
    check(sysfs_read_int(UCFG_RESTORE, -1) == 88, "performance fallback changed");
    reset_fg("max\n", "smart"); writer_fg_guard(0, 1, 0, 80);
    check(sysfs_read_int(UCFG_RESTORE, -1) == 55, "smart fallback changed");
    reset_fg("max\n", "battery"); writer_fg_guard(0, 1, 0, 80);
    check(sysfs_read_int(UCFG_RESTORE, -1) == 55, "battery fallback changed");

    reset_fg("35.00\n", "smart"); put_state(UCFG_LAST_GOOD, 70); put_state(UCFG_RESTORE, 100); writer_fg_guard(1, 1, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 70 && access(UCFG_RESTORE, F_OK) != 0, "legacy restore=100 survived wake");

    reset_fg("70.00\n", "balanced"); writer_fg_guard(0, 0, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 70 && access(UCFG_RESTORE, F_OK) != 0, "manual Balanced gained Smart sleep policy");

    reset_fg("max\n", "smart"); g_cam_guard_on = 1; writer_fg_guard(0, 1, 0, 80); writer_fg_guard(1, 1, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 100 && access(UCFG_RESTORE, F_OK) != 0, "camera guard was overwritten");

    reset_fg("max\n", "balanced"); put_state(UCFG_LAST_GOOD, 70);
    writer_fg_guard(1, 0, 0, 80); check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 100, "short max boost cut short");
    g_fg_max_since = time(NULL) - 61; writer_fg_guard(1, 0, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 70 && g_fg_fix_total == 1, "persistent max not corrected");

    /* fix234: only an armed Battery interaction borrows foreground uclamp. The exact shell
     * baseline returns at expiry/screen-off; higher vendor values are never lowered. */
    reset_fg("50.00\n", "battery"); writer_fg_guard(1, 0, 1, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 80 && g_fg_lift_on && g_fg_lift_saved == 50,
          "Battery interaction did not lift foreground from its saved baseline");
    writer_fg_guard(1, 0, 1, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 80 && g_fg_last_good == 50,
          "active Battery lift polluted the ordinary last-good value");
    writer_fg_guard(1, 0, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 50 && !g_fg_lift_on && g_fg_lift_saved == -1,
          "Battery foreground lift did not hand back exactly 50");

    reset_fg("70.00\n", "battery"); writer_fg_guard(1, 0, 1, 80);
    writer_fg_guard(0, 0, 1, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 70 && !g_fg_lift_on,
          "screen-off did not end the Battery foreground lift or gained Smart sleep policy");

    reset_fg("90.00\n", "battery"); writer_fg_guard(1, 0, 1, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 90 && !g_fg_lift_on,
          "Battery foreground lift lowered a higher vendor ceiling");

    reset_fg("50.00\n", "battery"); writer_fg_guard(1, 0, 1, 100);
    g_fg_max_since = time(NULL) - 61; writer_fg_guard(1, 0, 1, 100);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 100 && g_fg_fix_total == 0,
          "persistent-max correction fought an active Battery lift");
    writer_fg_guard(1, 0, 0, 100);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 50, "100%% Battery lift did not restore");

    reset_fg("50.00\n", "battery"); writer_fg_guard(1, 0, 1, 80);
    g_cam_guard_on = 1; put_raw("max\n"); writer_fg_guard(1, 0, 1, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 100, "Battery lift overwrote the camera guard");
    g_cam_guard_on = 0; writer_fg_guard(1, 0, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 50 && !g_fg_lift_on,
          "post-camera Battery handback did not restore the saved value");

    reset_fg("50.00\n", "battery"); writer_fg_guard(1, 0, 1, 80);
    snprintf(g_profile, sizeof(g_profile), "%s", "smart"); writer_fg_guard(1, 1, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 80 && !g_fg_lift_on,
          "profile switch restored stale Battery foreground value over Smart");

    reset_fg("50.00\n", "smart"); writer_fg_guard(1, 1, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 50, "Smart gained Battery foreground lift");
    reset_fg("50.00\n", "balanced"); writer_fg_guard(1, 0, 0, 80);
    check(uclamp_read_pct(UCLAMP_FG_MAX, -1) == 50, "Balanced gained Battery foreground lift");

    if (fails) return 1;
    puts("PASS fg uclamp native runtime: sleep/wake, Battery lift handback, max fallback, profile scope, camera exclusion");
    return 0;
}
X
"$CC" -std=gnu99 -Wall -Wextra -Werror -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail 'native fixture does not compile'; }
"$T/t" || fail 'native runtime behaviour mismatch'
echo "PASS fg uclamp guard contract"

) || { echo "FAIL in bundled contract: fg_uclamp_guard_contract" >&2; exit 1; }

# ==== gpu_pwrlevel_order_contract ====================================================================
(
# fix74: a GPU ceiling lowered past the live floor is put back once the floor follows.
#
# KGSL clamps max_pwrlevel to min_pwrlevel at write time (higher index = lower clock), so
# "write ceiling 17, then floor 17" against a floor of 8 ends as max=8 min=17. The override
# check then blamed the vendor and held every GPU write for 15 s - OP15 field capture:
# max_overrides=323 backoffs=492, written 17 / observed 8 with the floor at 17.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { printf '%s\n' "FAIL gpu pwrlevel order: $*" >&2; exit 1; }
need() { grep -Fq "$1" "$W" || fail "missing [$1]"; }

need 'int _gmax_pl_this_tick = -1;'
need 'g_wcache.last_max_pwrlevel_written = pl; _gmax_pl_this_tick = pl;'
need 'if (_gmax_pl_this_tick >= 0 && g_gpu_uses_pwrlevel && g_gpu_max_path[0]) {'
# only when the pair is consistent: a vendor floor above our ceiling is not fought
need 'if (_gmin_now < 0 || _gmin_now >= _gmax_pl_this_tick)'

# the re-check runs AFTER the floor write, or it would see the old floor
_floor="$(grep -Fn 'g_wcache.last_min_pwrlevel_written = pl;' "$W" | head -1 | cut -d: -f1)"
_fix="$(grep -Fn 'if (_gmax_pl_this_tick >= 0 && g_gpu_uses_pwrlevel' "$W" | head -1 | cut -d: -f1)"
[ -n "$_floor" ] && [ -n "$_fix" ] || fail "anchors not found"
[ "$_fix" -gt "$_floor" ] || fail "ceiling re-check precedes the floor write"

# Model of the KGSL rule the fix relies on (kgsl_pwrctrl max/min_pwrlevel_store):
# max cannot exceed min as an index, min cannot go below max.
python3 - <<'PY'
class K:
    def __init__(s, mx, mn): s.max, s.min = mx, mn
    def wmax(s, l): s.max = min(l, s.min)
    def wmin(s, l): s.min = max(l, s.max)
k = K(0, 8)            # vendor floor at 8
k.wmax(17); k.wmin(17) # the old order
assert (k.max, k.min) == (8, 17), (k.max, k.min)
if k.max != 17 and k.min >= 17: k.wmax(17)   # the fix
assert (k.max, k.min) == (17, 17), (k.max, k.min)
k = K(0, 8); k.wmax(17)                        # floor NOT ours to move (no min write)
if k.max != 17 and k.min >= 17: k.wmax(17)
assert k.max == 8                              # left alone
PY
printf '%s\n' 'PASS gpu pwrlevel order contract'

) || { echo "FAIL in bundled contract: gpu_pwrlevel_order_contract" >&2; exit 1; }

# ==== heavy_prime_escape_contract ====================================================================
(
# HEAVY prime escape: a bounded, Smart-only lift of a pinned prime ceiling. Every limit is
# the point of the feature, so each one is pinned here.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"; C="$ROOT/src/asb_config.h"
fail() { echo "FAIL heavy prime escape contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$F" 'fsm->profile_idx == PROFILE_SMART' 'not limited to Smart'
need "$F" '(fsm->state == ASB_STATE_HEAVY || fsm->state == ASB_STATE_MODERATE) &&' 'not limited to HEAVY/MODERATE'
need "$F" '                  m->misc.screen_on &&' 'not limited to screen on'
need "$F" '!fsm->thermal_cap && !m->bat.charging && !m->misc.camera_active' 'thermal/charging/camera gates missing'
need "$F" 'm->misc.app_hint < ASB_APP_GAMING' 'games are not excluded'
need "$F" 'asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm->profile_idx) &&' 'die temperature gate missing'
need "$F" 'g_asb_cfg.thermal_skin_c - 8' 'skin pre-lean gate missing'
# Burst and rest are WebUI settings now; the contract is that both stay bounded.
need "$F" 'if (_now - _esc_since >= _esc_burst)' 'burst is not time-limited'
need "$F" '_esc_rest_until = _now + _esc_rest;' 'no rest period after a burst'
need "$F" 'if (_esc_burst > 60) _esc_burst = 60;' 'burst not capped at 60 s'
need "$F" 'if (_esc_rest < 10) _esc_rest = 10;' 'rest not floored at 10 s'
need "$ROOT/src/asb_config.h" 'c->prime_escape_burst_s         = 20;' 'burst default is not 20 s'
need "$ROOT/src/asb_config.h" 'c->prime_escape_rest_s          = 40;' 'rest default is not 40 s'
need "$F" 'int _need = (fsm->state == ASB_STATE_MODERATE ? 3 : 2);' 'escape does not require the prime to stay pinned (3 ticks in MODERATE)'
need "$F" 'if (_esc_streak >= _need) {' 'pinned streak no longer gates the burst'
need "$F" 'g_profile_bounds[PROFILE_BALANCED]' 'ceiling is not bounded by Balanced'
need "$F" 'g_state_level[_lvl_state]' 'bound is not the Balanced rail of the current state'
need "$F" 'int _lvl_state = (fsm->state == ASB_STATE_MODERATE) ? ASB_STATE_MODERATE' 'MODERATE burst may reach the HEAVY rail'
# The escape must sit before the caps are committed and before the thermal budget runs
# (the budget lives in the governor and is applied to the committed caps afterwards).
_e="$(grep -n 'HEAVY prime escape (Smart only)' "$F" | head -1 | cut -d: -f1)"
_c="$(grep -n 'memcmp(&new_caps, &fsm->current_caps' "$F" | head -1 | cut -d: -f1)"
[ -n "$_e" ] && [ -n "$_c" ] && [ "$_e" -lt "$_c" ] || fail "escape applied after the caps are committed"
need "$C" 'c->heavy_prime_escape           = 1;' 'default not on'
need "$C" '"heavy_prime_escape"' 'config key not parsed'
grep -q '^heavy_prime_escape=1$' "$ROOT/config/governor.conf.shipped" || fail 'shipped config lacks the key'
need "$G" 'prime_escape=%d' 'state file does not publish the escape'
need "$G" 'prime_escape: lift' 'lift edge not logged'
# Multi-cluster: on 3+ cluster SoCs the middle slot is part of the burst (trigger and lift),
# and two-cluster devices must not grow a slot - the mid index exists only when slot 2 does.
need "$F" 'int _ms = (g_cpu_policy_ids[2] >= 0 && g_cpu_policy_ids[1] >= 0) ? 1 : -1;' 'mid slot not derived from topology'
need "$F" 'int _pinned = (_pinned_prime && !asb_esc_ceiling_foreign(m, _ps)) ||' 'prime cannot trigger the burst'
need "$F" '(_pinned_mid && !asb_esc_ceiling_foreign(m, _ms));' 'mid cluster cannot trigger the burst'
need "$F" 'int _slots[2] = { _ps, _ms };' 'burst does not lift the mid cluster'
need "$F" 'if (_hw > 0 && _lim > _hw) _lim = _hw;' 'lift not bounded by hardware max'
need "$G" 'prime_escape_mid=%d' 'mid lift not published'
echo "PASS heavy prime escape contract"

) || { echo "FAIL in bundled contract: heavy_prime_escape_contract" >&2; exit 1; }

# ==== learner_prediction_contract ====================================================================
(
# Contract + runtime: the hour-of-week learner predicts from screen share, never slows a
# ramp-up below the FSM default, and keeps its data outside the module directory.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/src/asb_learner.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL learner prediction: $*" >&2; fail=1; }
grep -Fq '#define LEARN_FILE        "/data/adb/asb/learn.bin"' "$L" || f 'learn.bin still inside the module directory (lost on every update)'
grep -Fq 'learner_load_from(db, LEARN_FILE_LEGACY)' "$L" || f 'legacy learn.bin not carried over'
grep -Fq 'drain_ma_ema < ' "$L" && f 'prediction still uses milliamps (awake-only samples, gauge-scaled)'
grep -Fq '/data/adb/asb/learn.bin' "$ROOT/service.sh" || f 'learning reset does not clear learn.bin'
grep -Fq '#define PERSISTENT_STATS_DIR        "/data/adb/asb"' "$ROOT/src/asb_governor.c" || f 'pstats/env fingerprint still inside the module directory'
grep -Fq 'pstats_load_migrating(PERSISTENT_STATS_FILE' "$ROOT/src/asb_governor.c" || f 'legacy pstats not carried over'
CC="${CC:-}"; [ -n "$CC" ] || CC="$(command -v gcc || command -v clang || true)"
if [ -n "$CC" ]; then
  cat > "$T/t.c" <<'C'
#include <stdint.h>
#include <unistd.h>
#include "asb_learner.h"
#include <stdio.h>
int main(void) {
  asb_learn_db_t db; memset(&db, 0, sizeof db);
  int slot = learner_slot(), up, down, bad = 0;
  float shares[] = { 0.05f, 0.30f, 0.80f };
  int want[] = { LEARN_PREDICT_IDLE, LEARN_PREDICT_LIGHT, LEARN_PREDICT_ACTIVE };
  for (int i = 0; i < 3; i++) {
    db.slots[slot].samples = 5; db.slots[slot].screen_on_ema = shares[i];
    db.slots[slot].drain_ma_ema = 500.0f;   /* a real awake-sampled hour */
    if ((int)learner_predict(&db) != want[i]) { printf("share %.2f predicted %d\n", shares[i], learner_predict(&db)); bad = 1; }
    learner_adjust_windows(&db, &up, &down);
    if (up > 2) { printf("share %.2f slows ramp-up to %d ticks\n", shares[i], up); bad = 1; }
  }
  return bad;
}
C
  if "$CC" -I"$ROOT/src" -o "$T/t" "$T/t.c" -lm 2>"$T/err"; then
    "$T/t" || f 'runtime prediction check failed'
  else
    f "learner header does not compile standalone: $(head -3 "$T/err")"
  fi
fi
[ "$fail" = 0 ] && echo "PASS learner prediction contract"
exit "$fail"

) || { echo "FAIL in bundled contract: learner_prediction_contract" >&2; exit 1; }

# ==== mksh_32bit_arith_contract ====================================================================
(
# Contract: byte counters and other values past 2^31 are not summed or compared with
# shell arithmetic in device scripts.
#
# Android's /system/bin/sh is mksh, whose arithmetic is 32-bit signed (a built mksh R59:
# $((2147483647+1)) = -2147483648, and [ 3000000000 -gt 2000000000 ] is false). Host
# shells are 64-bit, so host tests never saw it. Field effects: the screen-off class lost
# "network" after 2 GiB received since boot, the opt-in zram rebuild compared against a
# wrapped 8 GiB and ran every boot. These go through awk now.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; f() { echo "FAIL mksh 32-bit: $*" >&2; fail=1; }
grep -nE '\$\(\([^)]*(rx_bytes|tx_bytes)' "$ROOT"/runtime/*.sh "$ROOT"/action.sh "$ROOT"/tools/logkit/*.sh && f 'byte counter in $(( ))'
grep -Fq '_rx1=$(( _rx1 +' "$ROOT/runtime/asb_screenoff_class.sh" && f 'screen-off class sums rx bytes in shell arithmetic'
grep -Fq '_mrx=$(( _mrx + _a ))' "$ROOT/tools/logkit/_asb_logkit_common.sh" && f 'logkit sums mobile bytes in shell arithmetic'
grep -Fq '$((ZRAM_SIZE_MB * 1024 * 1024))' "$ROOT/service.sh" && f 'zram bytes computed in shell arithmetic'
grep -Fq '_wf_rate * 125000 * 60' "$ROOT/runtime/asb_net_routes.sh" && f 'BDP product overflows 32 bits above ~286 Mbit/s'
grep -Fq '_ma * 100 / _mt' "$ROOT/runtime/smart_dynamic_tune.sh" && f 'memory share overflows on 24 GB phones'
if command -v mksh >/dev/null 2>&1; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/net/rmnet_data0/statistics"
  echo 3000000000 > "$T/net/rmnet_data0/statistics/rx_bytes"
  _s="$(cat "$T"/net/rmnet_data*/statistics/rx_bytes | awk '{ s += $1 } END { printf "%.0f", s + 0 }')"
  [ "$_s" = 3000000000 ] || f "awk sum under mksh gave $_s"
fi
[ "$fail" = 0 ] && echo "PASS mksh 32-bit arithmetic contract"
exit "$fail"

) || { echo "FAIL in bundled contract: mksh_32bit_arith_contract" >&2; exit 1; }

# ==== mksh_background_detach_contract ====================================================================
(
# Contract: runtime helpers detach background bodies with an exec inside the subshell,
# never with a redirect on the closing ")".
#
# Under mksh (Android's /system/bin/sh) "( ...; x=$(cmd); ... ) >/dev/null 2>&1 &" does not
# release the caller's stdout: a caller capturing the output - the WebUI's exec bridge -
# waits for the whole background body. Measured: the async asbdiag start returned only
# after the export finished (1066 ms for a 1 s fake export, 19 ms under dash). The
# working form is "( exec </dev/null >/dev/null 2>&1; ... ) &".
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bad="$(grep -nE '^[[:space:]]*\)[[:space:]]*(</dev/null[[:space:]]*)?>[[:space:]]*/dev/null[[:space:]]+2>&1[[:space:]]*(</dev/null[[:space:]]*)?&[[:space:]]*$' \
        "$ROOT"/runtime/*.sh "$ROOT"/uninstall.sh 2>/dev/null)"
if [ -n "$bad" ]; then
  echo "FAIL mksh background detach: redirect on a closing ) - use exec inside the subshell:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
if command -v mksh >/dev/null 2>&1; then
  _a="$(date +%s%N 2>/dev/null || echo 0)"
  _x="$(mksh -c '( exec </dev/null >/dev/null 2>&1; y="$(echo z)"; sleep 1 ) & echo p')"
  _b="$(date +%s%N 2>/dev/null || echo 0)"
  [ "$_a" != 0 ] && [ $(( (_b - _a) / 1000000 )) -lt 500 ] || { echo "FAIL mksh background detach: the exec form still blocks on this mksh" >&2; exit 1; }
fi
echo "PASS mksh background-detach contract"

) || { echo "FAIL in bundled contract: mksh_background_detach_contract" >&2; exit 1; }

# ==== mksh_pipe_pattern_contract ====================================================================
(
# Contract: no unescaped | inside a ${var#pat} / ${var%pat} pattern.
#
# Android's /system/bin/sh is mksh, and mksh reads a bare | in those patterns as an
# alternation: "${l%%|*}" on "0|916479" yields "" and "${l#*|}" yields the whole string.
# Every host shell (dash, bash, BusyBox ash) does the expected split, so host tests passed
# while the device failed: the screen-off LTE restore dropped every record as "bad" and
# never gave 5G back, and the GNSS, phantom-process and Wi-Fi fallback restores parsed
# their records the same way. Write \| (works in every shell) or split with IFS/read.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bad="$(cd "$ROOT" && grep -rnoE '\$\{[A-Za-z_][A-Za-z0-9_]*(%%?|##?)[^}]*\}' \
        --include=*.sh common runtime tools system/bin service.sh post-fs-data.sh uninstall.sh action.sh customize.sh 2>/dev/null \
      | grep -E '[^\\]\|' | grep -vE '"[^"]*\|[^"]*"' )"
if [ -n "$bad" ]; then
  echo "FAIL mksh pipe patterns: unescaped | in a parameter pattern:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
echo "PASS mksh pipe-pattern contract"

) || { echo "FAIL in bundled contract: mksh_pipe_pattern_contract" >&2; exit 1; }

# ==== module_overlap_contract ====================================================================
(
# Contract + fixture: asbdiag names other enabled modules that set properties ASB manages,
# with the differing values (AIST v2.1 shares 141 keys with ASB, 16 at other values).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
fail=0; f() { echo "FAIL module overlap: $*" >&2; fail=1; }
grep -q 'SEC "0a0. MODULE OVERLAP' "$D" || f "section missing"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || f "system/bin/asbdiag out of sync"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '# c\nk.same=1\nk.diff=true\nk.only=1\n' > "$T/asb"
printf 'k.same=1\nk.diff=false\nk.other=1\n# k.diff=x\n' > "$T/other"
awk_prog="$(sed -n "/_ov_rows=\"\$(awk -F= '/,/' \"\$_ov_asb\" \"\$_ov_m\/system.prop\" 2>\/dev\/null)\"/p" "$D" | sed "1s/.*awk -F= '//; \$s/' \"\\\$_ov_asb\".*//")"
[ -n "$awk_prog" ] || f "could not extract the overlap program"
out="$(awk -F= "$awk_prog" "$T/asb" "$T/other")"
printf '%s\n' "$out" | grep -qx 'k.diff|true|false' || f "differing key not reported: $out"
printf '%s\n' "$out" | grep -qx '#|2|1' || f "summary wrong: $out"
printf '%s\n' "$out" | grep -q 'k.same|' && f "equal key reported as different"
[ "$fail" = 0 ] && echo "PASS module overlap contract"
exit "$fail"

) || { echo "FAIL in bundled contract: module_overlap_contract" >&2; exit 1; }

# ==== offdrain_contract ====================================================================
(
# Measured screen-off drain replaces the idle guess in every forecast.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; A="$ROOT/action.sh"; W="$ROOT/webroot/index.html"; D="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL offdrain contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$G" 'if (charging) { g_offdrain_start_ms = 0; g_offdrain_on_ms = 0; g_offdrain_media = 0; return; }' 'charging window not discarded'
need "$G" 'if (dur >= 3600000L && dpct >= 2) {' 'short or rounding-only windows can count'
need "$G" 'now - g_offdrain_on_ms >= 120000L' 'a glance at the clock splits the night'
need "$G" 'long now = asb_clock_ms(CLOCK_BOOTTIME);' 'window not timed on a suspend-aware clock'
need "$G" 'offdrain_pctph_x100=%d\noffdrain_windows=%d' 'not published'
[ "$(grep -c 'asb_offdrain_track(metrics.misc.screen_on' "$G")" -ge 2 ] || fail 'not called on both tick paths'
need "$A" "grep -m1 '^offdrain_pctph_x100=' /dev/.asb/state" 'action ignores the measured idle drain'
need "$W" 'kv.offdrain_pctph_x100' 'WebUI ignores the measured idle drain'
need "$D" "^offdrain_pctph_x100=" 'diag does not report it'
echo "PASS offdrain contract"

) || { echo "FAIL in bundled contract: offdrain_contract" >&2; exit 1; }

# ==== quiet_night_any_profile_contract ====================================================================
(
# Contract: Quiet Night is eligible inside the night window on any profile.
#
# A full OP15 night on Smart (battery weight 0.45-0.79, under the 0.8 "battery-like" bar)
# never entered Quiet Night, while two daytime screen-offs did. The mode trims the
# governor's own footprint on a sleeping phone; the profile's performance lean is not a
# reason to keep polling all night. Outside the window the battery-like rule still applies.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL quiet night eligibility: $*" >&2; fail=1; }
grep -Fq '(asb_profile_battery_like(fsm.profile_idx) || _qn_window) &&' "$G" || f 'night window does not make any profile eligible'
grep -Fq 'if (g_asb_cfg.night_quiet_enable && fsm.state == ASB_STATE_DEEP_IDLE &&' "$G" || f 'window is not gated by night_quiet_enable'
grep -Fq 'if (!_use_fast) _use_fast = _qn_window;' "$G" || f 'night window no longer speeds up entry'
[ "$fail" = 0 ] && echo "PASS quiet night any-profile contract"
exit "$fail"

) || { echo "FAIL in bundled contract: quiet_night_any_profile_contract" >&2; exit 1; }

# ==== route_table_all_contract ====================================================================
(
# Contract: route readers use every table, and the route watcher cannot feed itself.
#
# Android keeps each network's default route in its own table ("... table rmnet_data2"),
# never in main. Reading `ip route show` found no route on any phone: initcwnd/initrwnd
# were never applied, per-route congctl was "not supported" without the kernel being
# asked, and the report waited for a link forever.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; f() { echo "FAIL route tables: $*" >&2; fail=1; }
for file in runtime/asb_net_routes.sh runtime/asb_net_apply.sh action.sh tools/asb_diag.sh; do
  sh -n "$ROOT/$file" || f "$file syntax"
  # Any `ip [-6] route show` that is not followed by a table selector reads main only.
  if grep -nE 'ip( -6)? route show( |$)' "$ROOT/$file" | grep -v '^[0-9]*:[[:space:]]*#' \
       | grep -vE 'route show table' >/dev/null; then
    f "$file reads the main table only: $(grep -nE 'ip( -6)? route show( |$)' "$ROOT/$file" | grep -vE 'route show table|^[0-9]*:[[:space:]]*#' | head -1)"
  fi
done
R="$ROOT/runtime/asb_net_routes.sh"
grep -q 'route show table all' "$R" || f "net_routes does not read table all"
# Our own route change is a route event: the watcher must compare a fingerprint that
# strips the tokens it writes, or it re-applies forever.
grep -q '_route_fp()' "$R" || f "no route fingerprint"
grep -q '\[ "$_nfp" = "$_fp" \] && continue' "$R" || f "monitor loop does not skip unchanged routes"
for tok in initcwnd initrwnd congctl; do
  sed -n '/^_route_fp()/,/^}/p' "$R" | grep -q "s/ $tok " || f "fingerprint keeps $tok"
done
# A re-created route lost its congctl too; the watcher restores it through the routes mode.
grep -q 'asb_net_apply.sh" routes' "$R" || f "watcher does not re-apply per-route congctl"
grep -q '\[ "$ASB_NET_MODE" = routes \] && exit 0' "$ROOT/runtime/asb_net_apply.sh" || f "net_apply has no routes mode"
grep -q 'route get 1.1.1.1' "$ROOT/runtime/asb_net_apply.sh" || f "active link not taken from the kernel's own route choice"
# Per-link congestion alone must still run the boot apply and keep the watcher alive.
grep -q 'net_congestion_wifi net_congestion_mobile net_qdisc_wifi net_qdisc_mobile; do' "$ROOT/service.sh" \
  || f "boot apply ignores per-link network keys"
[ "$(grep -c "_rw_mode=cc_only\|_asb_rt=cc_only" "$ROOT/service.sh")" -ge 2 ] || f "watcher not started for per-link congctl alone"
grep -q 'in auto|conservative|aggressive) _apply' "$R" || f "watcher replays route windows while they are off"
# iproute2, not BusyBox: the root manager's applet has no monitor/initcwnd/congctl.
for file in runtime/asb_net_routes.sh runtime/asb_net_apply.sh; do
  grep -q 'for _ipb in /system/bin/ip' "$ROOT/$file" || f "$file does not prefer /system/bin/ip"
  if grep -vE '^[[:space:]]*#' "$ROOT/$file" | grep -qE '(^|[;|&(]|then|else|do)[[:space:]]*ip (route|-6|monitor)'; then
    f "$file still calls a bare ip"
  fi
done
[ "$fail" = 0 ] && echo "PASS route table contract"
exit "$fail"

) || { echo "FAIL in bundled contract: route_table_all_contract" >&2; exit 1; }

# ==== route_watch_idle_contract ====================================================================
(
# Contract: the DSP route watcher does not dump the audio service while nothing plays
# (kernel PCM state unchanged and empty) on kernels that expose PCM state; a stream opening
# still forces a dump at once, and kernels without PCM files keep the timed back-off.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/service.sh"
fail=0; f() { echo "FAIL route watch idle: $*" >&2; fail=1; }
blk="$(sed -n '/^# Keep persist.asb.dsp.route honest while the phone is running./,/^) >\/dev\/null 2>&1 &$/p' "$S")"
printf '%s\n' "$blk" | grep -q 'elif \[ -z "$_sig" \] && \[ -n "${_pcm_known:-}" \] && \[ -n "$_prev_route" \]; then' \
  || f "idle skip missing"
printf '%s\n' "$blk" | grep -q '_pcm_known=1' || f "PCM-state availability not detected"
# Order: a changed signature must be handled before the idle skip.
_a="$(printf '%s\n' "$blk" | grep -n 'if \[ "$_sig" != "${_prev_sig:-}" \]; then' | cut -d: -f1)"
_b="$(printf '%s\n' "$blk" | grep -n 'elif \[ -z "$_sig" \]' | cut -d: -f1)"
[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" -lt "$_b" ] || f "playback start no longer forces a dump first"
printf '%s\n' "$blk" | grep -q '\*bt_sco\*|\*BLUETOOTH_SCO\*) _now="call"' || f "SCO route lost"
[ "$fail" = 0 ] && echo "PASS route watch idle contract"
exit "$fail"

) || { echo "FAIL in bundled contract: route_watch_idle_contract" >&2; exit 1; }

# ==== screen_wake_recheck_contract ====================================================================
(
# Contract: a display event inside the 30 s follow-up budget still buys one quick look.
#
# Field captures (OP15, two days): 22 of 54 screen-ons were noticed only by the idle tick,
# each exactly 45 s after the previous tick, with deep-idle rails and frozen cap writes in
# the meantime - an unlock and camera launch ran on sleep rails. The budget that rations the
# ~2 s follow-up chain had been spent by an earlier display event, and inside it nothing was
# armed at all. Guard the single re-check, its spacing, and the counters that expose it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL screen wake recheck: $*" >&2; fail=1; }
need() { grep -Fq -- "$1" "$G" || f "$2"; }
need 'time(NULL) - g_disp_single_ts >= 10' 'single re-check is not spaced (AOD would buy a wakeup per event)'
need 'arm_timerfd_once_ms(tfd_active, 1000);' 'no single re-check inside the follow-up budget'
need 'g_disp_retry = 3;' 'single re-check can grow into a chain'
need 'screen_on_detect=' 'screen-on detection path not published'
need 'g_scr_on_by_tick++' 'slow-path wakes not counted'
need 'make_timerfd_clock(CLOCK_BOOTTIME, TIMER_IDLE_S)' 'screen-off tick still on CLOCK_MONOTONIC (stalls through suspend)'
need 'g_scr_resume_chains++' 'no re-check chain after a resume'
grep -Fq 'screen_on_detect=' "$ROOT/tools/asb_diag.sh" || f 'asbdiag does not show how wakes were noticed'
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f 'asbdiag copy out of date'
[ "$fail" = 0 ] && echo "PASS screen wake re-check contract"
exit "$fail"

) || { echo "FAIL in bundled contract: screen_wake_recheck_contract" >&2; exit 1; }

# ==== screenoff_awake_gate_contract ====================================================================
(
# Screen-off "real work" must mean the CPU was actually awake, not just a high loadavg.
#
# loadavg on these kernels counts uninterruptible waiters and is frozen across suspend: a
# OnePlus 15 night read load1 40-112 while suspended 96% of the time, held LIGHT_IDLE for
# hours, cut the deep-idle share the environment classifier reads (env=noisy all night)
# and kept the screen-off prime gate shut. The gate is the monotonic/boottime ratio per
# tick, which no idle waiter can fake and which reads the same on every SoC.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"; F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL screen-off awake gate: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$M" 'int     awake_tick_pct;' 'cpu metrics lack the awake share'
need "$M" 'clock_gettime(CLOCK_MONOTONIC, &_ts)' 'awake share not measured from CLOCK_MONOTONIC'
need "$M" 'clock_gettime(CLOCK_BOOTTIME, &_ts)' 'awake share not measured against CLOCK_BOOTTIME'
need "$M" 'if (_db >= 1000)' 'sub-second gaps are not ignored'
need "$F" 'int _awake_ok = (m->cpu.awake_tick_pct < 0 || m->cpu.awake_tick_pct >= 50);' 'busy rule not gated on awake share'
need "$F" 'if (m->cpu.load1 >= 8.0f && _awake_ok) {' 'busy streak still counts a sleeping CPU'
need "$F" '(m->cpu.awake_tick_pct >= 0 && m->cpu.awake_tick_pct < 50)) &&' 'screen-off prime gate ignores suspend'
need "$G" 'awake_tick_pct=%d' 'awake share not published'
# Three-tick streak and the load threshold itself are unchanged: the screen-off BT playback
# case this rule was built for (load1 13-19, CPU awake 99.8%) must still promote.
need "$F" 'int _off_busy = (_off_busy_streak >= 3);' 'streak requirement changed'
echo "PASS screen-off awake gate contract"

) || { echo "FAIL in bundled contract: screenoff_awake_gate_contract" >&2; exit 1; }

# ==== settings_wrapper_coverage_contract ====================================================================
(
# Contract: every standalone script that calls `settings` loads the fallback wrapper.
#
# On some OnePlus builds `settings` answers "cmd: Failure calling service settings: Failed
# transaction" and exits 0. The wrapper falls back to the content provider and never
# returns that text as a value; a script started with `sh` does not inherit it from
# service.sh. action.sh took the error string as the locale and printed in English.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for f in "$ROOT"/runtime/*.sh "$ROOT/action.sh" "$ROOT/service.sh" "$ROOT"/tools/logkit/_asb_logkit_common.sh; do
  case "${f##*/}" in
    asb_settings.sh|asb_apply_ledger.sh) continue ;;   # the wrapper itself / a sourced library
  esac
  # awk, not grep|grep -q: the second grep exits on its first match and the first one dies
  # writing to the closed pipe - three "grep: write error: Broken pipe" lines of CI noise
  # per run (fix216). awk reads the file once and answers with its exit code.
  awk '!/^[[:space:]]*#/ && /(^|[^_a-zA-Z.])settings (get|put|delete) / { f=1 } END { exit(1-f) }' "$f" || continue
  grep -q 'asb_settings.sh' "$f" || { echo "FAIL settings wrapper: ${f#$ROOT/} calls settings without the wrapper" >&2; fail=1; }
done
grep -q "case \"\$_asb_loc\" in \*\[Ff\]ailure\*" "$ROOT/action.sh" || { echo "FAIL settings wrapper: action.sh may take an error string as the locale" >&2; fail=1; }
[ "$fail" = 0 ] && echo "PASS settings wrapper coverage"
exit "$fail"

) || { echo "FAIL in bundled contract: settings_wrapper_coverage_contract" >&2; exit 1; }

# ==== smart_prime_floor_contract ====================================================================
(
# fix80: Smart writes (and repairs) the lowest-OPP floor on every slot, including the prime
# slot whose profile floor is 0. Field OP12: policy7 min=672000 against 480000, the only
# cluster Smart never touched ("smart minimum: WARN"). Non-Smart profiles keep skipping a
# slot without a floor, and HEAVY/GAMING keep their profile floors.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { echo "FAIL smart prime floor: $*" >&2; exit 1; }
grep -Fq 'int _smart_floor = (fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED);' "$W" || fail "primary path"
grep -Fq 'if (want_min <= 0 && !_smart_floor) continue;' "$W" || fail "primary path still skips a zero floor in Smart"
grep -Fq 'if (want_min <= 0 && !(fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED)) continue;' "$W" || fail "extra clusters"
[ "$(grep -Fc 'if (want_min <= 0) continue;' "$W")" -ge 2 ] || fail "no guard against writing 0 when the OPP table is missing"
echo "PASS Smart floors every slot at its lowest OPP"

) || { echo "FAIL in bundled contract: smart_prime_floor_contract" >&2; exit 1; }

# ==== smart_prime_slot_cap_contract ====================================================================
(
# Smart caps the separate prime core of a 3/4-cluster part (slot 2), which nothing held
# before (field OP12 diag in Smart: "prime ceiling: none from ASB", policy7 at 2496000 of
# 3302400). Executable fixture: the REAL helper, plus source pins for where it is applied
# and for the HEAVY prime escape being able to lift it.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL smart prime slot cap: $*" >&2; exit 1; }

grep -q 'int _pc = asb_smart_prime_slot_cap_khz((int)state, g_cpu_slot_hwmax\[2\],' "$F" || fail "helper not applied in fsm_interpolate_caps"
grep -q 'if (_pc > 0 && (out->cpu_max\[2\] <= 0 || out->cpu_max\[2\] > _pc))' "$F" || fail "an unmanaged (0) prime is not capped"
grep -q 'if (_lim <= 0) _lim = _hw;' "$F" || fail "HEAVY prime escape cannot lift a prime Balanced leaves unmanaged"

CC_BIN=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC_BIN="$c"; break; }; done
[ -n "$CC_BIN" ] || { echo "PASS smart prime slot cap contract (no C compiler: source pins only)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  echo '#include <stdio.h>'
  echo 'enum { ASB_STATE_DEEP_IDLE = 0, ASB_STATE_LIGHT_IDLE, ASB_STATE_MODERATE, ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, ASB_STATE_GAMING };'
  sed -n '/^static int asb_smart_prime_slot_cap_khz(/,/^}$/p' "$F"
  cat <<'EOF'
static int bad = 0;
#define EQ(a, b, m) do { if ((a) != (b)) { printf("FAIL %s: got %d want %d\n", m, (a), (b)); bad++; } } while (0)
int main(void) {
    const int hw = 3302400;   /* OP12 prime */
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 0, 1), hw * 62 / 100, "moderate 62%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_HEAVY, hw, 4, 0, 1), hw * 62 / 100, "heavy 62%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_SUSTAINED, hw, 4, 0, 1), hw * 50 / 100, "sustained 50%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_LIGHT_IDLE, hw, 4, 0, 1), hw * 55 / 100, "light idle screen on 55%");
    /* fix181: never 0 (unmanaged) on a 3/4-cluster part - the writer skipped such a slot and
     * the prime kept MODERATE's 62% through the screen-off night (CPH2691 capture 8952) and
     * through GAMING. Screen off is a defined 55% that the screen-off cap and the cooldown
     * lower further; GAMING and a busy game get the whole prime back. */
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_LIGHT_IDLE, hw, 4, 0, 0), hw * 55 / 100, "light idle screen off 55%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_DEEP_IDLE, hw, 4, 0, 0), hw * 55 / 100, "deep idle 55%, lowered further by the screen-off cap");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_GAMING, hw, 4, 0, 1), hw, "gaming: the whole prime back");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 1, 1), hw, "a busy game: the whole prime back");
    if (asb_smart_prime_slot_cap_khz(ASB_STATE_DEEP_IDLE, hw, 4, 0, 0) >= asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 0, 1)) { puts("FAIL screen-off prime not below MODERATE"); bad++; }
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, 4608000, 2, 0, 1), 0, "2-cluster part: slot 1 is the prime, not this");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, 0, 4, 0, 1), 0, "unknown hw max");
    /* Still the fastest core: above the middle cores' MODERATE share (58%). */
    if (!(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 0, 1) > hw * 58 / 100)) { puts("FAIL prime below middle share"); bad++; }
    return bad;
}
EOF
} > "$TMP/t.c"
"$CC_BIN" -O2 -Wall -Werror -o "$TMP/t" "$TMP/t.c" 2> "$TMP/e" || { cat "$TMP/e"; fail "fixture did not compile"; }
"$TMP/t" || fail "helper returned wrong caps"
echo "PASS smart prime slot cap contract"

) || { echo "FAIL in bundled contract: smart_prime_slot_cap_contract" >&2; exit 1; }

# ==== smart_wake_reblend_contract ====================================================================
(
# fix84-85: three Smart field defects.
#  1. CPH2769: after two hours screen-off the Smart blend kept the screen-off lean (pure
#     Battery rails) through the next screen-on session - the slot gate never looked at alpha.
#  2. PLQ110: GAMING <-> SUSTAINED every ~30 s at 49-52 C - exit was one degree under entry
#     and the trend path re-entered five degrees under it.
#  3. CPH2769 / OP15: the thermal-trend trim (18-32%) fired at 48-49 C on phones whose
#     learned normal is 45-54 C. In Smart the trend counts from the learned warm mark.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
S="$ROOT/src/asb_smart.h"; F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL smart wake re-blend: $*" >&2; exit 1; }
grep -Fq 'if (abs(rt->alpha_battery_x1000 - rt->last_alpha_x1000) >= 50) return 1;' "$S" || fail "alpha change does not re-blend"
grep -Fq 'if (abs(rt->interactive_bonus_x1000 - rt->last_bonus_x1000) >= 50) return 1;' "$S" || fail "bonus change does not re-blend"
grep -Fq 'rt->last_alpha_x1000 = rt->alpha_battery_x1000;' "$S" || fail "alpha not recorded at blend time"
grep -Fq 'm->therm.cpu_max_c <= sustained_temp_enter - ASB_GAME_SUS_HYST_C)' "$F" || fail "game exit lacks hysteresis"
grep -Fq '!_trend_game_exempt &&' "$F" || fail "trend path still pulls a busy game into SUSTAINED early"
G="$ROOT/src/asb_governor.c"
grep -Fq 'g_smart_rt.therm_warm_x10 / 10 > _trend_mark)' "$G" || fail "trend trim ignores the learned warm mark"
grep -Fq 'int _trend_warm = (!m->therm.temp_valid) || m->therm.cpu_max_c >= _trend_mark;' "$G" || fail "trend gate"
echo "PASS Smart re-blends on wake, and games have SUSTAINED hysteresis"

) || { echo "FAIL in bundled contract: smart_wake_reblend_contract" >&2; exit 1; }

# ==== special_builtin_redirect_contract ====================================================================
(
# Contract: no ": > file" in device scripts. ":" is a special builtin, and a failed
# redirect on one aborts the script under mksh and POSIX shells (asbdiag stopped at line 34
# when /sdcard was missing). "true > file" fails only the command.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bad="$(cd "$ROOT" && grep -nE '(^|[;&|{(]|[[:space:]]):[[:space:]]*>>?[[:space:]]*["$/]' \
        runtime/*.sh tools/*.sh tools/logkit/*.sh common/*.sh action.sh service.sh post-fs-data.sh uninstall.sh apply_profile.sh customize.sh system/bin/asbdiag 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
if [ -n "$bad" ]; then printf 'FAIL special-builtin redirect:\n%s\n' "$bad" >&2; exit 1; fi
echo "PASS special-builtin redirect contract"

) || { echo "FAIL in bundled contract: special_builtin_redirect_contract" >&2; exit 1; }

# ==== surface_fallback_contract ====================================================================
(
# Contract: a phone without sys-therm/board zones still has a surface temperature.
#
# OnePlus 12 (SM8650) exposes only shell_* body sensors. surface_hotspot stayed 0 there,
# so every surface-driven heat trim was silently off on that model.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"; G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL surface fallback: $*" >&2; fail=1; }
grep -q 'g_thermal_surface_zone < 0 && g_thermal_board_zone < 0' "$M" || f "no fallback when both zones are missing"
grep -q 't->surface_hotspot_c = t->skin_temp_c;' "$M" || f "fallback does not use the shell sensor"
grep -q '!g_surface_from_skin &&' "$M" || f "borrowed surface counted twice in consensus"
grep -q 'surface_source=%s' "$G" || f "surface provenance not published"
grep -q 'surface_source' "$ROOT/tools/asb_diag.sh" || f "diag does not report the surface source"
grep -q 'policy6}/scaling_cur_freq' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "logkit phase prime read is not policy-agnostic"
grep -q 'LK_PRIME_POL:-' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "logkit phase prime read ignores LK_PRIME_POL"
[ "$fail" = 0 ] && echo "PASS surface fallback contract"
exit "$fail"

) || { echo "FAIL in bundled contract: surface_fallback_contract" >&2; exit 1; }

# ==== thermal_trend_gap_contract ====================================================================
(
# Thermal trend must not read a sleep gap or the unlock burst as a fast climb.
#
# The trend sums per-tick deltas, and ticks are 2-6 s on screen but 45 s or a whole
# suspend apart off screen. A OnePlus 15 day showed the first tick after unlock (40 -> 50 C)
# firing thermal_trend_fast - a 34% trim at the moment of interaction, "cool" 30 s later.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL thermal trend gap contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$F" 'clock_gettime(CLOCK_BOOTTIME, &_tts)' 'gap not measured on a suspend-aware clock'
need "$F" 'if (_tr_gap > 6) delta = (int)((long)delta * 6L / _tr_gap);' 'long-gap deltas are not scaled down'
need "$F" 'int _tr_wake = (m->misc.screen_on && _tr_prev_screen == 0);' 'screen-on edge not detected'
need "$F" 'fsm->warm_anchor_c = m->therm.cpu_max_c;' 'warm anchor not re-seeded on wake'
# Short ticks keep their tuning: the scale may only shrink a delta.
grep -Fq 'delta * 6L / _tr_gap' "$F" && ! grep -Eq 'delta \* _tr_gap' "$F" || fail 'deltas can be scaled up'
# The slow-climb rule itself is unchanged.
need "$F" 'if (m->therm.cpu_max_c >= 50 && _rise >= 6 && fsm->thermal_trend < 6)' 'slow-climb rule changed'
echo "PASS thermal trend gap contract"

) || { echo "FAIL in bundled contract: thermal_trend_gap_contract" >&2; exit 1; }

# ==== uevent_parking_contract ====================================================================
(
# Uevent parking: with the screen on, the uevent socket is out of epoll (a field OP15 had
# 29298 display uevents in ~7 h, each an epoll wake + panel sysfs read); the tick that sees
# the screen go off puts it back, drops what queued, and runs the screen-off work the
# uevent path runs (stats context, screen-off session plan + prearm).
# Executable fixture: the REAL park/unpark functions against epoll and a datagram socket.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/asb_governor.c"
fail() { echo "FAIL uevent parking: $*" >&2; exit 1; }

grep -q 'uev_park(epfd, uefd);' "$SRC" || fail "screen-on paths do not park"
grep -q 'if (screen_on) uev_park(epfd, uefd);' "$SRC" || fail "startup with the screen on does not park"
_off="$(sed -n '/} else if (!metrics.misc.screen_on && _ts == 1) {/,/^                }/p' "$SRC")"
printf '%s\n' "$_off" | grep -q 'uev_unpark(epfd, uefd);' || fail "tick screen-off does not unpark"
printf '%s\n' "$_off" | grep -q 'session_plan_build(&fsm, 0);' || fail "tick screen-off skips the screen-off session plan"
printf '%s\n' "$_off" | grep -q 'session_plan_apply_prearm(&fsm);' || fail "tick screen-off skips the prearm"
printf '%s\n' "$_off" | grep -q 'persistent_stats_screen_off(&fsm);' || fail "tick screen-off skips the screen-off stats context"
grep -q 'uevent_dropped_while_parked=' "$SRC" || fail "parking not published"
grep -q 'uevent_dropped_while_parked' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show parking"

CC_BIN=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC_BIN="$c"; break; }; done
if [ -z "$CC_BIN" ]; then echo "PASS uevent parking contract (no C compiler: source pins only)"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  printf '#include <stdio.h>\n#include <string.h>\n#include <errno.h>\n#include <unistd.h>\n#include <fcntl.h>\n#include <sys/ioctl.h>\n#include <linux/input.h>\n#include <sys/epoll.h>\n#include <sys/socket.h>\n'
  # The display-state waiter flag (fix118) lives above the cut; 0 = not running, old behaviour.
  printf 'static volatile int g_disp_waiter_up = 0;\n'
  sed -n '/^static int           g_uev_parked = 0;$/,/^static void uev_unpark(int epfd, int uefd) {$/p' "$SRC" | sed '$d'
  sed -n '/^static void uev_unpark(int epfd, int uefd) {$/,/^}$/p' "$SRC"
  cat <<'EOF'
int main(void) {
    int sv[2], ep = epoll_create1(0), bad = 0;
    struct epoll_event ev = {0}, out[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) != 0 || ep < 0) return 2;
    ev.events = EPOLLIN; ev.data.fd = sv[0];
    epoll_ctl(ep, EPOLL_CTL_ADD, sv[0], &ev);
    uev_park(ep, sv[0]);
    if (!g_uev_parked || g_uev_parks != 1) { puts("not parked"); bad++; }
    uev_park(ep, sv[0]);
    if (g_uev_parks != 1) { puts("parked twice"); bad++; }
    for (int i = 0; i < 3; i++) send(sv[1], "x", 1, 0);
    if (epoll_wait(ep, out, 2, 0) != 0) { puts("parked socket still wakes epoll"); bad++; }
    uev_unpark(ep, sv[0]);
    if (g_uev_parked) { puts("not unparked"); bad++; }
    if (g_uev_unpark_dropped != 3) { printf("dropped %lu, want 3\n", g_uev_unpark_dropped); bad++; }
    if (epoll_wait(ep, out, 2, 0) != 0) { puts("stale events left after unpark"); bad++; }
    send(sv[1], "y", 1, 0);
    if (epoll_wait(ep, out, 2, 0) != 1) { puts("unparked socket does not wake epoll"); bad++; }
    return bad;
}
EOF
} > "$TMP/t.c"
"$CC_BIN" -O2 -Wall -Werror -Wno-unused-function -Wno-unused-variable -o "$TMP/t" "$TMP/t.c" 2> "$TMP/err" || { cat "$TMP/err"; fail "fixture did not compile"; }
"$TMP/t" || fail "park/unpark fixture failed"
echo "PASS uevent parking contract"

) || { echo "FAIL in bundled contract: uevent_parking_contract" >&2; exit 1; }

# ==== undefined_shell_functions_contract ====================================================================
(
# Contract: every _helper called at command position in a device script is defined in that
# script (or, for the logkit, in its common library). smart_dynamic_tune.sh called an
# undefined _cfg, so wifi_powersave silently never applied.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "SKIP undefined-function contract (no python3)"; exit 0; }
python3 - "$ROOT" <<'PY'
import re,glob,os,sys
root=sys.argv[1]; os.chdir(root)
files=glob.glob('runtime/*.sh')+['action.sh','service.sh','post-fs-data.sh','apply_profile.sh','uninstall.sh','tools/asb_diag.sh']+glob.glob('tools/logkit/*.sh')
dre=re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)',re.M)
alld={f:set(dre.findall(open(f).read())) for f in files}
bad=[]
for f in files:
    d=alld[f]
    if 'logkit' in f: d=d|alld.get('tools/logkit/_asb_logkit_common.sh',set())
    for i,line in enumerate(open(f).read().split('\n'),1):
        t=line.strip()
        if t.startswith('#'): continue
        t=re.sub(r'\$\(\([^)]*\)\)','',t)
        for m in re.finditer(r'(?:^|;\s*|&&\s*|\|\|\s*|\|\s*|\$\(\s*|\b(?:then|do|else)\s+)(_[a-z][a-z0-9_]*)(?=\s|$|\)|;)',t):
            if re.match(r'\s*=', t[m.end():]): continue
            if m.group(1) not in d: bad.append('%s:%d %s'%(f,i,m.group(1)))
if bad:
    print('FAIL undefined shell functions:\n  '+'\n  '.join(bad), file=sys.stderr); sys.exit(1)
print('PASS undefined-function contract')
PY

) || { echo "FAIL in bundled contract: undefined_shell_functions_contract" >&2; exit 1; }

# ==== vendor_ceiling_cost_contract ====================================================================
(
# A vendor-raised CPU ceiling is reported by what it COST, not merely that it happened.
# The old line said "leak_observed ... reconcile.sh handles" for every raise - untrue during
# sleep detente and useless: on a OnePlus 15 night the clock exceeded ASB's limit in 3 of
# 64 screen-off samples. Raised-but-unused and really-used are counted separately.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; A="$ROOT/action.sh"
fail() { echo "FAIL vendor ceiling cost contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$G" '(long)metrics.cpu.cur_freq[0] * 1000L > (long)want_p0 + 100000L' 'little clock not compared with the limit (MHz vs kHz)'
need "$G" 'if (used0 || used1) g_leak_used_ticks++;' 'really-used ticks not counted'
need "$G" 'vendor_ceiling_ticks=%lu\nvendor_ceiling_used_ticks=%lu' 'counters not published'
need "$G" 'int _lvl = (used0 || used1) ? 1 : 3;' 'unused raises still logged at the normal level'
grep -F 'asb_log(' "$G" | grep -Fq 'reconcile.sh handles' && fail 'misleading "reconcile.sh handles" text is back'
need "$A" '_vcu="$(_st vendor_ceiling_used_ticks)"' 'action does not report the cost'
echo "PASS vendor ceiling cost contract"

) || { echo "FAIL in bundled contract: vendor_ceiling_cost_contract" >&2; exit 1; }

# ==== webui_apply_truth_contract ====================================================================
(
# Contract: keys the WebUI sends to "governor reload" are keys the governor reads.
# BG_TRIM_LEVEL, UX_MANAGE_* and sustained_temp_mode were in that list; the binary parses
# none of them, so the toast said "applied" and nothing changed until a reboot.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail=0; f() { echo "FAIL webui apply truth: $*" >&2; fail=1; }
keys="$(sed -n "/var GOV_KEYS = \[/,/\];/p" "$H" | grep -oE "'[A-Za-z_]+'" | tr -d "'")"
for k in $keys; do
  # Keys handled by their own branch before the generic reload are fine.
  case "$k" in BG_TRIM_LEVEL|UX_MANAGE_OEM_TOGGLES|UX_MANAGE_TIMEOUTS|sustained_temp_mode)
    grep -q "key === '$k'" "$H" || f "$k has no dedicated apply branch"; continue ;;
  esac
  grep -q "\"$k\"" "$ROOT/src/asb_config.h" "$ROOT/src/asb_governor.c" || f "$k is reload-applied but the governor never parses it"
done
grep -q "shQuote('sustained_temp_user_override') + ' ' + shQuote('1')" "$H" || f "slider move does not publish the override flag"
grep -q 'off) asb_bg_bucket_restore >/dev/null 2>&1; break ;;' "$ROOT/service.sh" || f "six-hour bucket loop ignores BG_TRIM_LEVEL=off"
[ "$fail" = 0 ] && echo "PASS webui apply truth"
exit "$fail"

) || { echo "FAIL in bundled contract: webui_apply_truth_contract" >&2; exit 1; }

# ==== webui_hidden_poll_contract ====================================================================
(
# Contract: the WebUI does not poll the governor while it is not visible.
# The manager keeps the WebView alive in the background; its timers kept spawning root
# shells every 3 s (Live page) or 30 s (home) while the user was in another app.
set -u
H="$(cd "$(dirname "$0")/.." && pwd)/webroot/index.html"
fail=0
sed -n '/^async function pollLive(visible) {/,/^  try {/p' "$H" | grep -q 'if (document.hidden) return;' \
  || { echo "FAIL webui: pollLive runs while hidden" >&2; fail=1; }
grep -q "if (!document.hidden) pollLive(_liveOpen);" "$H" \
  || { echo "FAIL webui: no catch-up poll when the page is shown again" >&2; fail=1; }
[ "$fail" = 0 ] && echo "PASS webui hidden poll"
exit "$fail"

) || { echo "FAIL in bundled contract: webui_hidden_poll_contract" >&2; exit 1; }

# ==== writer_sybg_screen_flip_contract ====================================================================
(
# system-background follows the screen (floor 50 while on), so a screen change is a new
# target, not drift. If flips went through the drift path they would count toward the
# 5-rewrite backoff - never cleared for uclamp nodes - and every few screen cycles leave
# the node stuck at the background ceiling right after screen-on.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { echo "FAIL sybg screen-flip contract: $*"; exit 1; }
grep -q 'static int s_sybg_screen = -1;' "$W" || fail "no per-screen memory for the sybg target"
grep -q 'if (_sybg_flip) _ucl_sybg_drift = 0;' "$W" || fail "a screen flip still counts as drift"
grep -q 'force || _ucl_bg_drift || _ucl_sybg_drift || _sybg_flip ||' "$W" || fail "a screen flip does not force the write"
grep -q 's_sybg_screen = fsm_screen_is_on ? 1 : 0;' "$W" || fail "screen state not recorded after the write"
# The floor itself must be applied identically on all three writers of the node.
[ "$(grep -c 'fsm_screen_is_on && _sybg_' "$W")" -ge 4 ] || fail "screen-on floor missing on a sybg writer"
echo "PASS sybg screen-flip contract"

) || { echo "FAIL in bundled contract: writer_sybg_screen_flip_contract" >&2; exit 1; }

echo "PASS: contract bundle (39 contracts)"
)

t_device_safety_contract() (
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Device-pack producer must make absence explicit without authorizing broad
# properties by device model/fingerprint guesswork.
mkdir -p "$TMP/bin" "$TMP/state"
cat > "$TMP/bin/getprop" <<'EOF'
#!/usr/bin/env sh
[ "${1:-}" = "ro.build.fingerprint" ] && printf '%s\n' 'test/vendor/device:16/TEST/1:user/release-keys'
EOF
chmod 0755 "$TMP/bin/getprop"
PATH="$TMP/bin:$PATH" ASB_CONFIG_STATE="$TMP/state" MODDIR="$ROOT" \
  sh "$ROOT/runtime/asb_device_pack_manifest.sh"
grep -qx 'status=blocked' "$TMP/state/device_pack.state"
grep -qx 'reason=no_certified_domain_manifest' "$TMP/state/device_pack.state"
test ! -e "$TMP/state/device_pack_verified"

# A stale validated manifest must be invalidated rather than authorizing another OTA.
cat > "$TMP/state/device_pack_verified" <<'EOF'
fingerprint=other/vendor/device:16/OLD/1:user/release-keys
tier=validated
domain=properties
EOF
PATH="$TMP/bin:$PATH" ASB_CONFIG_STATE="$TMP/state" MODDIR="$ROOT" \
  sh "$ROOT/runtime/asb_device_pack_manifest.sh"
test ! -e "$TMP/state/device_pack_verified"

# Profile switches are transactional: each request obtains an epoch and workers
# serialise through a module lock while observing supersession between passes.
grep -q '^profile_next_epoch()' "$ROOT/apply_profile.sh"
grep -q '^profile_worker_lock()' "$ROOT/apply_profile.sh"
grep -q 'worker superseded' "$ROOT/apply_profile.sh"
grep -q 'WORKER_EPOCH="${4:-}"' "$ROOT/apply_profile.sh"

# Device evidence showed an invalid WALT sentinel and external CPU policy
# disagreement. Both must be classified and bounded, not retried aggressively.
grep -q 'unsupported_readback' "$ROOT/src/asb_writer.h"
grep -q 'external_policy_holddown' "$ROOT/src/asb_writer.h"
grep -q 'vendor_stricter_ceiling' "$ROOT/src/asb_writer.h"
grep -q 'writer_node_is_cpu_max' "$ROOT/src/asb_writer.h"
grep -q 'live_max > cmax\[i\]' "$ROOT/src/asb_writer.h"
grep -q 'consecutive_failures' "$ROOT/src/asb_writer.h"
grep -q 'retry_at = now + 86400' "$ROOT/src/asb_writer.h"
# OP15/ColorOS evidence: the kernel's INT_MIN WALT sentinel is unsupported hardware surface,
# not a rejected write. Preserve it as UNSUPPORTED evidence and never mix it into FAIL counts.
[ "$(grep -c 'writer_write_unsupported_event(node, path, requested, observed, h->retry_at);' "$ROOT/src/asb_writer.h")" -eq 2 ]
grep -q 'writer_write_event("UNSUPPORTED"' "$ROOT/src/asb_writer.h"
grep -q "sed -n '/^FAIL /s/.*node=" "$ROOT/tools/asb_diag.sh"
grep -q "grep '\^FAIL ' /dev/.asb/write_errors" "$ROOT/tools/asb_diag.sh"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag"
# The vendor-disagreement holddown must exist and be short enough to act within one
# thermal episode.
#
# This asserted the literal string "now + 900". That pinned a number, not a behaviour, and
# the number turned out to be the bug: at fifteen minutes the governor was silent for most
# of its life - a field diag read attempts=34 applied=23 backoff_skips=25, with cap_owner
# vendor 92% / asb 0%. Asserting the constant meant the suite defended the defect.
#
# What matters is that the holddown is present (so no tick-by-tick write war) and bounded
# (so the governor still gets to act). 300 s is the ceiling: longer than most thermal
# episodes, which is what made 900 useless.
grep -qE 'retry_at = now \+ (9|[1-9][0-9]|[12][0-9][0-9]|300);' "$ROOT/src/asb_writer.h"
grep -q 'external_policy_holddown' "$ROOT/src/asb_writer.h"
! grep -q 'asb_settings_put global google_core_control 0' "$ROOT/runtime/profile_core.sh"

# Diagnostics must expose the safely blocked property state and the DSP clamp.
grep -q 'device-pack state' "$ROOT/tools/asb_diag.sh"
grep -q 'managed properties' "$ROOT/tools/asb_diag.sh"
grep -q 'DSP gain applied' "$ROOT/tools/asb_diag.sh"
grep -q '\[ -r "\$MODDIR/runtime/asb_device_pack_manifest.sh" \]' "$ROOT/post-fs-data.sh"
grep -q 'sh "\$MODDIR/runtime/asb_device_pack_manifest.sh"' "$ROOT/post-fs-data.sh"
grep -q '\[ -r "\$MODDIR/runtime/asb_capabilities.sh" \]' "$ROOT/post-fs-data.sh"
grep -q '\[ -r "\$MODDIR/runtime/asb_apply_managed_props.sh" \]' "$ROOT/service.sh"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag"
printf '%s\n' 'PASS device safety contract'
)

t_donor_telemetry_contract() (
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# The effective policy extension must remain a JSON-producing observer. It is
# intentionally executable on a host with neither Android properties nor ZRAM.
MODDIR="$ROOT" sh "$ROOT/tools/asb_effective_policy.sh" > "$TMP/effective_policy.json"
python3 - "$TMP/effective_policy.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

for section in ("audio", "network", "memory", "asb_overhead"):
    assert section in payload, f"missing {section}"

assert set(("dsp_enabled", "dsp_route_published", "a2dp_offload_requested")) <= set(payload["audio"])
assert set(("congestion_requested", "congestion_result", "qdisc_requested", "qdisc_result")) <= set(payload["network"])
assert set(("psi_some_avg10", "psi_full_avg10", "zram_algorithm", "zram_mm_stat")) <= set(payload["memory"])
PY

# Telemetry is evidence only. No new property, settings, sysctl or ZRAM writer
# may appear in the effective-policy producer or in the added logkit blocks.
! grep -Eq '^[[:space:]]*(setprop|resetprop|sysctl[[:space:]]+-w|settings[[:space:]]+put|swapoff|swapon|mkswap)[[:space:]]' \
  "$ROOT/tools/asb_effective_policy.sh"
! grep -Eq '^[[:space:]]*(setprop|resetprop|sysctl[[:space:]]+-w|settings[[:space:]]+put|swapoff|swapon|mkswap)[[:space:]]' \
  "$ROOT/tools/logkit/_asb_logkit_common.sh"

# The routine captures must disclose requested-versus-live state. A raw property
# alone is not sufficient because it cannot tell a refused kernel write from a
# setting that ASB never requested.
grep -q 'ASB audio / offload provenance' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'ASB network provenance' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'memory PSI (read-only' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'zram\.\$_zf' "$ROOT/tools/logkit/_asb_logkit_common.sh"

# Human and machine diagnostics must expose the same core facts, and the
# installed command must never drift from the source copy.
grep -q 'bt_a2dp_offload: requested=' "$ROOT/tools/asb_diag.sh"
grep -q 'DSP requested/applied gain' "$ROOT/tools/asb_diag.sh"
grep -q 'memory PSI (read-only)' "$ROOT/tools/asb_diag.sh"
grep -q '"audio"' "$ROOT/tools/asb_effective_policy.sh"
grep -q '"network"' "$ROOT/tools/asb_effective_policy.sh"
grep -q '"memory"' "$ROOT/tools/asb_effective_policy.sh"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag"
[ -f "$ROOT/docs/log_schemas.md" ] && grep -q 'provenance snapshots' "$ROOT/docs/log_schemas.md"

# A selected throttle point equal to the live CPU maximum is the policy transition edge,
# not evidence that the diagnostic itself failed. Only a strictly hotter live sensor may
# emit the red verdict. A vendor camera file with comments is similarly not proof that ASB
# wrote malformed JSON unless one of ASB's staged payloads is itself commented.
grep -Fq '[ "$_tp_set" -lt "$_tp_now" ]' "$ROOT/tools/asb_diag.sh"
grep -Fq 'boundary observed, not a failure' "$ROOT/tools/asb_diag.sh"
if grep -Fq '[ "$_tp_set" -le "$_tp_now" ]' "$ROOT/tools/asb_diag.sh"; then
  printf '%s\n' 'FAIL asbdiag equality is still a red throttle diagnostic' >&2
  exit 1
fi
grep -q '^camera_json_comment_verdict() {' "$ROOT/tools/asb_diag.sh"
grep -Fq 'ASB-managed camera payload has // comments' "$ROOT/tools/asb_diag.sh"
grep -Fq 'vendor JSON-with-comments:' "$ROOT/tools/asb_diag.sh"
grep -Fq 'ASB did not assert a JSON policy for this live vendor camera domain' "$ROOT/tools/asb_diag.sh"
# Execute the branch in isolation: equality must not call V (the failure printer), while
# a live temperature strictly over the configured point must still do so.
sed -n '/^case "$_tp_set" in/,/^esac$/p' "$ROOT/tools/asb_diag.sh" > "$TMP/throttle_boundary.sh"
[ -s "$TMP/throttle_boundary.sh" ] || { printf '%s\n' 'FAIL asbdiag throttle boundary branch not extracted' >&2; exit 1; }
P(){ printf 'P:%s\n' "$1"; }
NOTE(){ printf 'NOTE:%s\n' "$1"; }
V(){ printf 'V:%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }
# The strictly-over branch is mode-aware: a point ASB derived itself (auto/smart) that the
# live sensor has already passed is the red verdict, while the same temperatures under a
# MANUAL point are the user's own informed choice and rate a WARN, never a FAIL.
cfg(){ [ "$1" = "sustained_temp_mode" ] && printf '%s\n' "${_tp_mode:-auto}"; }
_tp_set=60 _tp_now=60 _tp_n=1 _tp_mode=auto
_boundary_out="$(. "$TMP/throttle_boundary.sh")"
printf '%s\n' "$_boundary_out" | grep -Fq 'boundary observed, not a failure' || { printf '%s\n' 'FAIL asbdiag equality boundary message missing' >&2; exit 1; }
if printf '%s\n' "$_boundary_out" | grep -q '^V:'; then
  printf '%s\n' 'FAIL asbdiag equality invoked red verdict' >&2
  exit 1
fi
_tp_set=60 _tp_now=61 _tp_n=1 _tp_mode=auto
_over_out="$(. "$TMP/throttle_boundary.sh")"
printf '%s\n' "$_over_out" | grep -Fq 'V:  throttle point below live CPU sensor' || { printf '%s\n' 'FAIL asbdiag strictly-over-threshold sensor lost verdict' >&2; exit 1; }
_tp_set=60 _tp_now=61 _tp_n=1 _tp_mode=manual
_manual_out="$(. "$TMP/throttle_boundary.sh")"
if printf '%s\n' "$_manual_out" | grep -q '^V:'; then
  printf '%s\n' 'FAIL asbdiag manual throttle point emitted red verdict' >&2
  exit 1
fi
printf '%s\n' "$_manual_out" | grep -Fq 'P:  [WARN] throttle point below live CPU sensor (manual' || { printf '%s\n' 'FAIL asbdiag manual throttle point lost WARN' >&2; exit 1; }
# Exercise camera provenance without Android paths. A commented live vendor file is INFO
# when ASB carries no malformed payload; a commented ASB payload remains a V failure.
sed -n '/^camera_json_comment_verdict() {/,/^}/p' "$ROOT/tools/asb_diag.sh" > "$TMP/camera_json_verdict.sh"
[ -s "$TMP/camera_json_verdict.sh" ] || { printf '%s\n' 'FAIL asbdiag camera JSON helper not extracted' >&2; exit 1; }
MODDIR="$TMP/module"
LIVE="$TMP/live_camera/video_beauty_default_config"
mkdir -p "$(dirname "$LIVE")" "$MODDIR/system/odm$(dirname "$LIVE")"
printf '// vendor comment\n{}\n' > "$LIVE"
. "$TMP/camera_json_verdict.sh"
_vendor_out="$(camera_json_comment_verdict "$LIVE")"
printf '%s\n' "$_vendor_out" | grep -Fq 'vendor JSON-with-comments:' || { printf '%s\n' 'FAIL asbdiag vendor comment was not informational' >&2; exit 1; }
if printf '%s\n' "$_vendor_out" | grep -q '^V:'; then
  printf '%s\n' 'FAIL asbdiag vendor comment emitted a malformed-ASB verdict' >&2
  exit 1
fi
printf '// broken staged payload\n{}\n' > "$MODDIR/system/odm$LIVE"
_managed_out="$(camera_json_comment_verdict "$LIVE")"
printf '%s\n' "$_managed_out" | grep -Fq 'V:  ASB-managed camera payload has // comments' || { printf '%s\n' 'FAIL asbdiag malformed ASB camera payload lost verdict' >&2; exit 1; }

# Conservative offload semantics must stay conservative.
#
# A review found this contract had lost its offload assertions at the same time the code
# lost the behaviour - so the suite went green on a regression it was written to catch. A
# test deleted alongside its feature proves nothing, which makes these three lines the
# actual protection rather than the code comment above them.
#
# Assert on the SHAPE of the verdict, not on wording: it must be able to say "unknown", and
# it must not conclude offload from an AudioFlinger thread alone.
grep -q 'offload state:' "$ROOT/tools/asb_diag.sh"
grep -q '_ev_verdict="unknown"' "$ROOT/tools/asb_diag.sh"
grep -q '_ev_route' "$ROOT/tools/asb_diag.sh"
grep -q '_ev_play' "$ROOT/tools/asb_diag.sh"
# The bare form - verdict set from the thread with no corroboration - is the regression.
if grep -qE '^\s*\[ -n "\$_ev_af" \] && _ev_verdict=' "$ROOT/tools/asb_diag.sh"; then
  printf '%s\n' 'FAIL offload verdict taken from AudioFlinger thread alone' >&2
  exit 1
fi
# Every capture must carry the same field, or an A/B experiment has nothing to compare -
# and it must apply the SAME rule as the manual report.
#
# Tightening asbdiag while leaving logkit on the old one-signal logic is exactly what
# happened once: the hand-run report became honest while every full-day archive kept
# claiming offload from an uncorroborated thread. These assertions exist so the two copies
# cannot drift apart again without the suite saying so.
grep -q 'offload.state' "$ROOT/tools/logkit/_asb_logkit_common.sh"
# Assert the corroborating signals by their real names.
#
# My first version of this test looked for _lk_route and _lk_play - variables from my own
# implementation. The deployed build reaches the same conclusion through LK_AUDIO_ROUTE and
# LK_AUDIO_PLAY, and is stricter still: it also reports "conflicting" when a thread exists
# while a property says offload is blocked. Testing for my variable names would have failed
# the better implementation, which is a good reminder that a contract should describe
# behaviour, not the author who wrote it first.
grep -q 'LK_AUDIO_ROUTE' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'LK_AUDIO_PLAY' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'conflicting AudioFlinger' "$ROOT/tools/logkit/_asb_logkit_common.sh"
# The bare form - verdict from the thread with nothing corroborating it - is the regression.
if grep -qE 'offload.state = offload thread present"' "$ROOT/tools/logkit/_asb_logkit_common.sh"; then
  printf '%s\n' 'FAIL logkit offload verdict taken from AudioFlinger thread alone' >&2
  exit 1
fi

# The reconnect recorder must survive merges.
#
# It was present in the deployed 507 build and absent from the source for three rounds -
# nobody noticed until an audit compared the two. These assertions cover the functions, the
# default full-day enablement, and every call site, so a future merge that drops it fails here
# instead of in a user's log six hours into a capture.
grep -q 'ASB_BT_RECONNECT_TRACE' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -Fq ': "${ASB_BT_RECONNECT_TRACE:=1}"' "$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q 'lk_bt_reconnect_start' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'lk_bt_reconnect_snapshot' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'lk_bt_reconnect_stop' "$ROOT/tools/logkit/_asb_logkit_common.sh"
_bt_calls="$(grep -c 'lk_bt_reconnect_' "$ROOT/tools/logkit/asb_log_full_day.sh")"
if [ "$_bt_calls" -lt 6 ]; then
  printf '%s\n' "FAIL reconnect recorder call sites: found $_bt_calls, expected 6" >&2
  exit 1
fi
[ -f "$ROOT/docs/log_schemas.md" ] && grep -q 'Bluetooth lifecycle recorder' "$ROOT/docs/log_schemas.md"
[ -f "$ROOT/docs/log_schemas.md" ] && grep -q 'bt_lifecycle_events.tsv' "$ROOT/docs/log_schemas.md"
[ -f "$ROOT/docs/log_schemas.md" ] && grep -q 'bt_lifecycle_context.tsv' "$ROOT/docs/log_schemas.md"

# phase_ledger.tsv: the printf format and the documented column list must agree.
#
# Readers index this file positionally, so adding a field without updating the schema does
# not break anything visibly - it just makes every documented column after the insertion
# point describe the wrong number. That is the failure this check exists to make loud.
# phase_ledger.tsv: the printf format and the documented column list must agree.
#
# Readers index this file positionally, so adding a field without updating the schema
# is silent - every documented column after the insertion point then describes the
# wrong number.
#
# Every grep here is guarded with || true. The script runs under set -e, and a grep
# that finds nothing exits 1 - which killed the whole contract in CI while passing
# locally, because the local tree happened to match. A check that aborts the suite on
# a miss is worse than no check: it hides every test after it.
_pl_line="$(grep -n '"\$LK_CUR_PHASE" "\$LK_PH_START"' \
            "$ROOT/tools/logkit/asb_log_full_day.sh" 2>/dev/null | head -1 | cut -d: -f1 || true)"
case "$_pl_line" in ''|*[!0-9]*) _pl_line="" ;; esac
if [ -n "$_pl_line" ] && [ -f "$ROOT/docs/log_schemas.md" ]; then
  _pl_cols="$(sed -n "$(( _pl_line - 1 ))p" "$ROOT/tools/logkit/asb_log_full_day.sh" \
              | grep -o '%s' | wc -l || true)"
  _pl_doc="$(sed -n '/^1  phase/,/^```/p' "$ROOT/docs/log_schemas.md" \
             | grep -cE '^[0-9]+ ' || true)"
  case "$_pl_cols" in ''|*[!0-9]*) _pl_cols=0 ;; esac
  case "$_pl_doc"  in ''|*[!0-9]*) _pl_doc=0  ;; esac
  if [ "$_pl_cols" -gt 0 ] && [ "$_pl_doc" -gt 0 ] && [ "$_pl_cols" -ne "$_pl_doc" ]; then
    printf '%s\n' "FAIL phase_ledger columns: code emits $_pl_cols, docs describe $_pl_doc" >&2
    exit 1
  fi
fi

printf '%s\n' 'PASS donor telemetry contract'
)

t_field_fixes_contract() (
# Field-fix contracts (fix90 onward), one section per fix. Kept in one file so that each
# small fix no longer adds a script of its own - new ones go in as a new section.

# ---- fix90 ----------------------------------------------------------------
asb_has_test() {
  _ht="${1#test_}"; _ht="${_ht%.*}"
  grep -Eq "^(t|_c)_${_ht}\(\) [({]" "$ROOT"/tests/asb_*.sh
}
(
# fix90: (1) never disable the kernel's reboot-on-panic / panic-on-oops - a wedged phone
# (OP12: black launcher, alarm missed, reboot fixed it) is worse than any saving;
# (2) LIGHT_IDLE escalates when the main cores sit at the light-idle ceiling (OP15: 52% of
# screen-on LIGHT_IDLE samples pinned at 1440 MHz).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL fix90: $*" >&2; exit 1; }
grep -rnE 'sysctlw kernel\.panic(_on_oops)? |/proc/sys/kernel/panic(_on_oops)?' \
  "$ROOT/service.sh" "$ROOT/post-fs-data.sh" "$ROOT/runtime" "$ROOT/profiles" 2>/dev/null \
  | grep -v '^\s*#' | grep -v ':[0-9]*: *#' && fail "a script still writes kernel.panic / panic_on_oops"
F="$ROOT/src/asb_fsm.h"
grep -Fq '#define ASB_LI_PIN_HOLD_S 40' "$F" || fail "pin hold constant"
grep -Fq 'if (_cm > 0 && _cc > 0 && _cc * 100 >= _cm * 98) _sl = _c;' "$F" || fail "pinned test"
grep -Fq 'if (m->misc.screen_on && !fsm_profile_is_battery && !m->misc.camera_active) {' "$F" || fail "escalation must be screen-on, not Battery, not camera"
grep -Fq 'light_idle_pin_escalations=' "$ROOT/src/asb_governor.c" || fail "escalations not published"
grep -q 'resetprop -n tombstoned.max_tombstone_count 0' "$ROOT/post-fs-data.sh" && fail "native crash records still thrown away"
grep -Eq 'for _svc in .*(minidump|mtdoopslog|bootstat)' "$ROOT/service.sh" && fail "bg_trim still stops the crash recorders"
grep -Fq 'kernel panic policy' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show the panic policy"
for _k in persist.sys.crash_dumps persist.sys.pstore_dumps persist.sys.mdlog_dumpback \
          persist.sys.oom_crash_on_watchdog persist.sys.stability.nativehang.enable \
          persist.sys.stability.nativehangII.enable persist.sys.stability.qcom_hang_task.enable \
          persist.sys.stability.scout.enable persist.sys.stability.enable_res_leak_abort; do
  grep -q "^$_k=" "$ROOT/runtime/asb_managed.props" && fail "managed props still set $_k"
done
echo "PASS fix90: panic reboot left to the vendor, pinned light idle escalates"
) || exit 1

# ---- fix94 ----------------------------------------------------------------
(
# fix94: tombstones kept by the platform; carried-over drain rate never replaces a live one;
# the ASB board-temperature cell is not labelled as the die.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
grep -qE '^tombstoned\.max_tombstone_count=' "$ROOT/runtime/asb_managed.props" && fail "managed props still zero tombstones"
grep -qE '^ro\.tombstoned\.crash\.dump=' "$ROOT/runtime/asb_managed.props" && fail "managed props still disable tombstone dumps"
G="$ROOT/src/asb_governor.c"
grep -q 'if (live_x10 <= 0 && g_smart_drain_last_x10 > 0' "$G" || fail "stale drain rate can override the live one"
grep -q 'if (_live_stale) _pub_win = 0;' "$G" || fail "carried-over rate published with a live window"
grep -q "T('lv_board', 'Board')" "$ROOT/webroot/index.html" || fail "board cell still labelled as die"
for f in "$ROOT"/webroot/i18n/*.json; do
  grep -q '"lv_board"' "$f" || fail "lv_board missing in $f"
  grep -q '"lv_board_tip"' "$f" || fail "lv_board_tip missing in $f"
done
echo "PASS: fix94 contract"
) || exit 1

# ---- fix95 ----------------------------------------------------------------
(
# fix95: the 40% ceiling guard snaps UP to a real OPP; asbdiag reads screen state from the
# governor when the panel node is absent and flags post-boot heat in the throttle warning.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
W="$ROOT/src/asb_writer.h"
awk '/^static int cpu_floor_ceiling/,/^}/' "$W" > /tmp/_asb_fc.$$ 
grep -q 'if (v >= guard && (up == 0 || v < up)) up = v;' /tmp/_asb_fc.$$ || { rm -f /tmp/_asb_fc.$$; fail "guard still rounds down below 40%"; }
rm -f /tmp/_asb_fc.$$
# Runtime: build the guard against the OP15 prime table and check the result.
T="${TMPDIR:-/tmp}/asb_fix95.$$"; mkdir -p "$T"
cat > "$T/t.c" <<'C'
#include <stdio.h>
static long g_cpu_freq_tables[16][32]; static int g_cpu_freq_table_len[16];
static void cpu_read_freq_tables(void) {}
static long cpu_snap_freq(int p, long w) { long b=0; for (int i=0;i<g_cpu_freq_table_len[p];i++){long v=g_cpu_freq_tables[p][i]; if(v<=w&&v>b)b=v;} return b?b:w; }
#define ASB_MIN_CEILING_PCT_OF_HW 40
static int g_writer_floor_pct = 0;   /* fix184: the records' one-write floor */
C
awk '/^static int cpu_floor_ceiling/,/^}/' "$W" >> "$T/t.c"
cat >> "$T/t.c" <<'C'
int main(void){
  long t[]={1497600,1747200,1900800,2380800,4608000};
  for(int i=0;i<5;i++) g_cpu_freq_tables[1][i]=t[i]; g_cpu_freq_table_len[1]=5;
  int a=cpu_floor_ceiling(1,1497600,0), b=cpu_floor_ceiling(1,1497600,1), c=cpu_floor_ceiling(1,2380800,0);
  if(a!=1900800||b!=1497600||c!=2380800){printf("got %d %d %d\n",a,b,c);return 1;}
  g_writer_floor_pct = 25;   /* the records trying x0.75: 25 % for that write only */
  if(cpu_floor_ceiling(1,1497600,0)!=1497600){puts("lowered floor ignored");return 1;}
  g_writer_floor_pct = 60;   /* never above the 40 % guard */
  if(cpu_floor_ceiling(1,1497600,0)!=1900800){puts("floor override raised the guard");return 1;}
  return 0; }
C
gcc -O0 -o "$T/t" "$T/t.c" 2>"$T/err" || { cat "$T/err"; rm -rf "$T"; fail "guard harness does not build"; }
"$T/t" || { rm -rf "$T"; fail "guard result wrong"; }
rm -rf "$T"
D="$ROOT/tools/asb_diag.sh"
grep -q "grep -m1 '^screen=\[01\]\$' /dev/.asb/state" "$D" || fail "diag plan line has no governor screen fallback"
grep -q 'post-boot dexopt/indexing heat' "$D" || fail "throttle warning does not flag post-boot heat"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix95 contract"
) || exit 1

# ---- fix96 ----------------------------------------------------------------
(
# fix96: budget grading scales by the anchor level; screen forecast falls back to the slot's
# learned drain before a fixed mA; diag block order; zero-second dwell hidden.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q '(_elapsed \* (long)g_budget_acc_anchor_pct \* 100L)' "$G" || fail "budget grade not scaled by anchor level"
grep -q '(_elapsed \* 100L \* 100L)' "$G" && fail "old per-100% budget grade still present"
# Arithmetic: 44 % anchor, 3.3 h to empty -> 13.3 %/h -> 30 min predicts ~6.7 %.
_p=$(( 1800 * 44 * 100 / (33 * 360) ))
[ "$_p" -ge 660 ] && [ "$_p" -le 670 ] || fail "budget grade arithmetic: $_p"
A="$ROOT/action.sh"

grep -q 'smart_bucket_drain_x10=" /dev/.asb/state' "$A" || fail "action ETA lacks slot fallback"
grep -q '_eta_kind=slot' "$A" || fail "action ETA slot kind missing"
grep -q "kv.smart_bucket_drain_x10 || '0'" "$ROOT/webroot/index.html" || fail "WebUI ETA lacks slot fallback"
for l in ar de en es fr hy id it pt ru tr uk zh; do
  { [ "$l" = en ] || grep -q "^T_ETA_SLOT=" "$ROOT/runtime/i18n/action_$l.sh"; } || fail "T_ETA_SLOT missing: $l"
  grep -q '"eta_slot"' "$ROOT/webroot/i18n/$l.json" || fail "eta_slot missing: $l"
done
grep -q '^T_ETA_SLOT=' "$A" || fail "T_ETA_SLOT default missing"
D="$ROOT/tools/asb_diag.sh"
_l=$(grep -n 'P "  LMKD / vmpressure props:"' "$D" | cut -d: -f1)
_r=$(grep -n 'for _p in ro.lmk.use_psi' "$D" | cut -d: -f1)
_o=$(grep -n 'P "  OEM toggles' "$D" | cut -d: -f1)
[ "$_l" -lt "$_r" ] && [ "$_r" -lt "$_o" ] || fail "LMKD props not under their header"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag differs"
grep -q '\[ "$_g_dwell" -lt 5 \] && _g_dwell=""' "$A" || fail "zero-second dwell still printed"
echo "PASS: fix96 contract"
) || exit 1
# ---- fix97 ----------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix97: $*"; exit 1; }
[ -e "$ROOT/webroot/switch.mp3" ] && fail "switch.mp3 is back"
grep -q 'switch\.mp3"' "$ROOT/webroot/index.html" && fail "WebUI still loads switch.mp3"
grep -q 'clickAudio' "$ROOT/webroot/index.html" && fail "clickAudio fallback still referenced"
grep -q '^run_queue$' "$ROOT/tools/asb_full_regression.sh" || fail "regression no longer runs the queue"
grep -q 'ASB_REGRESSION_JOBS' "$ROOT/tools/asb_full_regression.sh" || fail "parallel runner missing"
echo "PASS: fix97 contract"
) || exit 1
# ---- fix99 ----------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix99: $*"; exit 1; }
A="$ROOT/action.sh"
F="${TMPDIR:-/tmp}/asb_npl.$$"
sed -n '/^_npl() {/,/^}/p' "$A" > "$F"
[ -s "$F" ] || fail "_npl helper missing"
_got="$(sh -c '. "$1"; M_X=many; M_X_1=one; M_X_2=few; M_E=items
  for n in 1 2 5 11 12 21 24 111 579; do printf "%s " "$(_npl $n M_X)"; done; _npl 3 M_E' _ "$F")"
rm -f "$F"
[ "$_got" = "one few many many many one few many many items" ] || fail "plural forms wrong: $_got"
grep -q '^    M_SES_LEARNED_1="сессия изучена"' "$A" || fail "ru singular form missing"
grep -q '$(_npl "$_l_sess" M_SES_LEARNED)' "$A" || fail "sessions line not pluralised"
grep -q 'в %s проверках' "$ROOT/runtime/i18n/action_ru.sh" && fail "ru vendor-ceiling line still declines a bare count"
echo "PASS: fix99 contract"
) || exit 1
# ---- fix100 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix100: $*"; exit 1; }
W="$ROOT/runtime/asb_wakelock_watch.sh"
grep -q 'had WAKE_LOCK reset by the system - limit re-applied' "$W" || fail "lapsed fitness limit not re-asserted"
grep -q 'had WIFI_MULTICAST reset by the system - denial re-applied' "$W" || fail "lapsed multicast denial not re-asserted"
grep -q 'limit lapsed - the system reset this app-op' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not flag a lapsed limit"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix100 contract"
) || exit 1
# ---- fix101 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix101: $*"; exit 1; }
S="$ROOT/src/asb_smart.h"
grep -q 'static void asb_smart_apply_memory_pressure(asb_smart_runtime_t \*rt, int screen_on) {' "$S" || fail "memory lean has no screen gate"
grep -q '    if (screen_on) return;' "$S" || fail "memory lean still applies with the screen on"
grep -q 'm->misc.screen_on, &g_smart_rt);' "$ROOT/src/asb_governor.c" || fail "modifiers not told the screen state"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS: fix101 contract (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  printf '#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n'
  sed -n '/^static int asb_smart_refresh_rate_hz(void) {/,/^}$/p' "$S" \
    | sed -e 's#"/sys/class/drm/sde-crtc-0/measured_fps"#getenv("FPS_FILE")#' -e 's#static const char \*paths#const char *paths#'
  cat <<'X'
int main(void) { printf("%d\n", asb_smart_refresh_rate_hz()); return 0; }
X
} > "$T/t.c"
"$CC" -O2 -o "$T/t" "$T/t.c" 2>"$T/e" || { cat "$T/e"; fail "refresh fixture did not compile"; }
chk() { printf '%s\n' "$1" > "$T/fps"; r="$(FPS_FILE="$T/fps" "$T/t")"; [ "$r" = "$2" ] || fail "measured_fps '$1' -> $r, want $2"; }
chk 'fps: 59.9 duration:500000 frame_count:30' 59
chk 'fps: 120.0 duration:500000 frame_count:60' 120
chk 'fps: 1.0 duration:500000 frame_count:1' 0
chk '90' 90
echo "PASS: fix101 contract"
) || exit 1
# ---- fix102 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix102: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"
grep -q 'g_cam_pids\[g_cam_npid++\] = pid;' "$M" || fail "camera scan still stops at the first match"
grep -q 'cam_read_jiffies_all() : cam_read_jiffies(g_cam_pid)' "$M" || fail "camera load not summed"
grep -q 'wall - g_cam_scan_ts >= 300 && wall >= g_cam_hold_until' "$M" || fail "camera set never refreshed"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS: fix102 contract (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  printf '#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <unistd.h>\n#include <fcntl.h>\n#include <sys/types.h>\n'
  printf '#define ASB_CAM_PID_MAX 8\nstatic pid_t g_cam_pids[ASB_CAM_PID_MAX]; static int g_cam_npid = 0;\n'
  sed -n '/^static unsigned long long cam_read_jiffies(pid_t pid) {/,/^}$/p' "$M"
  sed -n '/^static unsigned long long cam_read_jiffies_all(void) {/,/^}$/p' "$M"
  cat <<'X'
int main(void) {
    volatile unsigned long x = 0; for (unsigned long i = 0; i < 300000000UL; i++) x += i;
    unsigned long long self = cam_read_jiffies(getpid());
    g_cam_pids[0] = 999999; g_cam_pids[1] = getpid(); g_cam_npid = 2;
    unsigned long long all = cam_read_jiffies_all();
    if (all < self) { printf("sum %llu < self %llu\n", all, self); return 1; }
    g_cam_pids[1] = 999998;
    if (cam_read_jiffies_all() != 0ULL) { puts("all dead must read 0"); return 1; }
    return 0;
}
X
} > "$T/t.c"
"$CC" -O0 -o "$T/t" "$T/t.c" 2>"$T/e" || { cat "$T/e"; fail "camera fixture did not compile"; }
"$T/t" || fail "camera load sum wrong"
echo "PASS: fix102 contract"
) || exit 1
# ---- fix103 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix103: $*"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^asb_cpu_cluster_init() {/,/^}$/p' "$ROOT/runtime/profile_core.sh" > "$T/f.sh"
[ -s "$T/f.sh" ] || fail "asb_cpu_cluster_init not found"
mk() { # name present "pol:cpus:max" ...
  d="$T/$1"; mkdir -p "$d/cpufreq"; echo "$2" > "$d/present"; shift 2
  for x in "$@"; do p="${x%%:*}"; r="${x#*:}"; c="${r%%:*}"; m="${r##*:}"
    mkdir -p "$d/cpufreq/policy$p"; echo "$c" > "$d/cpufreq/policy$p/related_cpus"; echo "$m" > "$d/cpufreq/policy$p/cpuinfo_max_freq"; done; }
mk op12 0-7 "0:0 1:2265600" "2:2 3 4:3148800" "5:5 6:2956800" "7:7:3302400"
mk op15 0-7 "0:0 1 2 3 4 5:3628800" "6:6 7:4608000"
mk sm8550 0-7 "0:0 1 2:2016000" "3:3 4 5 6:2803200" "7:7:3187200"
got() { sh -c '. "$1"; PROFILE="$3"; ASB_CPU_SYSFS="$2" asb_cpu_cluster_init; echo "$FG_CPUS|$BG_CPUS"' _ "$T/f.sh" "$T/$1" "$2"; }
[ "$(got op12 battery)" = "0-7|0-1" ] || fail "OP12 battery foreground must include every core: $(got op12 battery)"
[ "$(got op15 battery)" = "0-7|0-5" ] || fail "OP15 battery foreground must include the prime pair: $(got op15 battery)"
[ "$(got sm8550 battery)" = "0-7|0-2" ] || fail "SM8550 battery foreground must include every core: $(got sm8550 battery)"
[ "$(got op12 balanced)" = "0-7|0-1" ] || fail "OP12 balanced: $(got op12 balanced)"
[ "$(got op15 smart)" = "0-7|0-5" ] || fail "OP15 Smart placement changed: $(got op15 smart)"
[ "$(got sm8550 smart)" = "0-7|0-2" ] || fail "SM8550 Smart placement changed: $(got sm8550 smart)"
echo "PASS: fix103/fix233 foreground cpuset contract"
) || exit 1
# ---- fix104 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix104: $*"; exit 1; }
S="$ROOT/service.sh"
grep -q 'writef_retry /dev/cpuset/top-app/cpus         "0-${cpu_max}"' "$S" || fail "service.sh top-app cannot reach every core"
grep -q 'writef_retry /dev/cpuset/foreground/cpus      "0-${cpu_max}"' "$S" || fail "service.sh foreground cannot reach every core"
grep -q '_fg="0-${cpu_max}"' "$S" || fail "service.sh cgroup pass does not use every foreground core"
! grep -q 'bat_fg_end' "$S" || fail "a stale Battery-only foreground cpuset restriction remains"
# The background policy is deliberately unchanged: visible apps get all cores, background does not.
grep -q 'writef_retry /dev/cpuset/background/cpus        "0-${little_end}"' "$S" || fail "background economy cpuset changed"
echo "PASS: fix104/fix233 service cpuset contract"
) || exit 1
# ---- fix107 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix107: $*"; exit 1; }
D="$ROOT/runtime/smart_dynamic_tune.sh"
grep -q "s/^full .*avg10=" "$D" || fail "screen-on swappiness ignores memory stalls"
grep -q 'if \[ "$_psf_i" -ge 2 \] 2>/dev/null && \[ "$_swp" -lt $((_base + 20)) \]; then' "$D" || fail "stall gate changed"
sh -n "$D" || fail "smart_dynamic_tune.sh syntax"
grep -q 'fsm.state == ASB_STATE_MODERATE ? "MODERATE" : "HEAVY"' "$ROOT/src/asb_governor.c" || fail "lift log does not name the state"
echo "PASS: fix107 contract"
) || exit 1
# ---- fix108 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix108: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q '(_mem_stall << 1) | screen_on_v;' "$G" || fail "tuner signature has no memory-stall bit"
grep -q 'if (_pf >= 200) {' "$G" || fail "stall entry threshold changed"
grep -q 'else if (_pf >= 0 && _pf < 100) _mem_stall = 0;' "$G" || fail "stall exit hysteresis missing"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS: fix108 contract (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{ printf '#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n'
  sed -n '/^static int asb_read_mem_psi_full_x100(void) {/,/^}$/p' "$G" | sed 's#"/proc/pressure/memory"#getenv("PSI")#'
  printf 'int main(void){printf("%%d\\n", asb_read_mem_psi_full_x100());return 0;}\n'; } > "$T/t.c"
"$CC" -O2 -o "$T/t" "$T/t.c" 2>"$T/e" || { cat "$T/e"; fail "PSI fixture did not compile"; }
printf 'some avg10=7.39 avg60=8.41 avg300=2.74 total=9449753\nfull avg10=4.78 avg60=4.16 avg300=1.26 total=4448849\n' > "$T/p"
[ "$(PSI="$T/p" "$T/t")" = 478 ] || fail "full avg10 parsed as $(PSI="$T/p" "$T/t")"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' > "$T/p"
[ "$(PSI="$T/p" "$T/t")" = -1 ] || fail "missing full line must read -1"
echo "PASS: fix108 contract"
) || exit 1
# ---- fix109 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix109: $*"; exit 1; }
F="$ROOT/src/asb_fsm.h"
grep -Fq 'int _cand[2] = { _multi ? 1 : 0, _multi ? 2 : -1 };' "$F" || fail "light-idle pin still watches only slot 0 on 3/4-cluster parts"
grep -Fq '_li_pin_slot = _sl;' "$F" || fail "pinned slot not remembered for the hold"
grep -Fq '_li_pin_cap = 0; _li_pin_slot = -1; }' "$F" || fail "pinned slot not cleared when the hold ends"
echo "PASS: fix109 contract"
) || exit 1
# ---- fix110 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix110: $*"; exit 1; }
F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"
grep -Fq '? _t10 : fsm->ses_temp_ema_x10 + (_t10 - fsm->ses_temp_ema_x10) / 4;' "$F" || fail "session temperature EMA missing"
grep -Fq 'fsm->ses_max_temp_sm         = 0;' "$F" || fail "smoothed peak not reset per session"
grep -Fq 'sin.max_temp_c = (fsm->ses_max_temp_sm > 0) ? fsm->ses_max_temp_sm : fsm->ses_max_temp;' "$G" || fail "learner still taught the raw single-sample peak"
grep -Fq 'ses_max_temp_raw=%d\nses_max_temp_smooth=%d\n' "$G" || fail "raw/smooth peaks not published"
# Safety thresholds keep the RAW peak.
grep -Fq 'if (fsm->ses_max_temp >= 90) cur_cause = 5;' "$G" || fail "safety classification moved off the raw peak"
# EMA arithmetic: a one-tick 94 C spike over a 45 C session must not reach 70 C.
e=450; pk=0; for t in 45 45 94 45 45 45; do e=$(( e + (t*10 - e) / 4 )); s=$(( (e+5)/10 )); [ $s -gt $pk ] && pk=$s; done
[ "$pk" -lt 70 ] || fail "one-tick 94 C spike reached $pk C"
e=450; pk=0; for t in 72 72 72 72 72 72 72 72 72 72 72 72; do e=$(( e + (t*10 - e) / 4 )); s=$(( (e+5)/10 )); [ $s -gt $pk ] && pk=$s; done
[ "$pk" -ge 70 ] || fail "sustained 72 C (12 ticks) reached only $pk C"
echo "PASS: fix110 contract"
) || exit 1
# ---- fix111 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix111: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; D="$ROOT/tools/asb_diag.sh"
grep -Fq 'if (!_mem_stall) g_mem_stall_entries++;' "$G" || fail "stall entries not counted on the rising edge"
grep -Fq 'mem_stall_now=%d\nmem_stall_entries=%lu\n' "$G" || fail "stall counters not published"
grep -Fq 'screen-on memory stalls since governor start' "$D" || fail "asbdiag does not show memory stalls"
grep -Fq 'current session peak: raw ${_spr}C, smoothed ${_sps}C' "$D" || fail "asbdiag does not show raw vs smoothed peak"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix111 contract"
) || exit 1
# ---- fix112 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix112: $*"; exit 1; }
D="$ROOT/tools/asb_diag.sh"
grep -Fq '(tombstones kept: ${_tbk:-platform default})' "$D" || fail "unset tombstone prop still prints blank"
grep -Fq "see 'last boot reason' below" "$D" || fail "blank boot reason in the timeline"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
for f in "$ROOT"/common/*text.sh; do
  grep -q '^ASB_L_CAM_LIVE_DIRTY2=' "$f" || fail "$(basename "$f") lacks the camera advice"
  grep -qiE '^ASB_L_CAM_LIVE_DIRTY2=.*(disable ASB|отключите ASB|вимкніть ASB)' "$f" && fail "$(basename "$f") still asks to disable ASB first"
done
echo "PASS: fix112 contract"
) || exit 1
# ---- fix113 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix113: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; F="$ROOT/src/asb_fsm.h"; A="$ROOT/action.sh"
grep -Fq 'int _sm_boot = ((long)(_sm_now - _sm_t0) < 300);' "$F" || fail "boot window still feeds the smoothed peak"
grep -Fq 'if (!_sm_boot && m->therm.temp_valid' "$F" || fail "boot gate not applied"
grep -q '^T_A_VOICE=' "$A" || fail "no English voice-tone line"
for l in ar de es fr hy id it pt ru tr uk zh; do
  grep -q '^T_A_VOICE=' "$ROOT/runtime/i18n/action_$l.sh" || fail "T_A_VOICE missing: $l"
done
# Runtime: level 4 prints +2.0 / -2.4, level 0 and DSP off print nothing.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^_a_voice=/,/^esac$/p' "$A" > "$T/v.sh"
run() { sh -c '_f() { _sfmt="$1"; shift; printf "$_sfmt\n" "$@"; }; _cfg(){ echo "$V"; }; T_A_VOICE="v %s +%s -%s"; _a_dsp="$D"; . "$1"' _ "$T/v.sh"; }
[ "$(V=4 D=5 run | sed 's/^ *//')" = "v 4 +2.0 -2.4" ] || fail "level 4 rendered as '$(V=4 D=5 run)'"
[ -z "$(V=0 D=5 run)" ] || fail "level 0 printed a line"
[ -z "$(V=4 D=off run)" ] || fail "voice line printed with the DSP off"
echo "PASS: fix113 contract"
) || exit 1
# ---- fix114 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix114: $*"; exit 1; }
L="$ROOT/runtime/asb_lte_screenoff.sh"
# fix131: the drop mark moved to 2 Mbit/s and a sustained-demand mark (3 Mbit/s) was added -
# see test_lte_bulk_runtime.sh.
grep -q '^LIGHT_LOW_KBPS="${ASB_LTE_LIGHT_LOW_KBPS:-2000}"' "$L" || fail "light low mark not 2 Mbit/s"
grep -q '^LIGHT_BUSY_KBPS="${ASB_LTE_LIGHT_BUSY_KBPS:-3000}"' "$L" || fail "no sustained-demand mark"
grep -q '^LIGHT_HIGH_KBPS="${ASB_LTE_LIGHT_HIGH_KBPS:-12000}"' "$L" || fail "light high mark not 12 Mbit/s"
grep -q '^  screen_on) do_screen_on ;;' "$L" || fail "no screen_on entry"
grep -Fq 'asb_lte_screenoff.sh screen_on' "$ROOT/runtime/smart_dynamic_tune.sh" || fail "tuner still restores on every screen-on tick"
grep -Fq 'asb_lte_screenoff.sh restore' "$ROOT/runtime/smart_dynamic_tune.sh" && fail "tuner would undo a light LTE choice"
for c in config/governor.conf config/governor.conf.shipped; do
  grep -q '^net_lte_light=0$' "$ROOT/$c" || fail "$c: net_lte_light not off by default"
done
grep -q '^net_lte_light|' "$ROOT/config/key_ownership.tsv" || fail "key ownership missing"
[ "$(grep -c "net_screen_off_lte net_lte_light" "$ROOT/common/install.sh")" -ge 2 ] || fail "installer does not keep the toggle"
grep -Fq "key:'net_lte_light'" "$ROOT/webroot/index.html" || fail "no WebUI item"
grep -Fq "if (key === 'net_lte_light')" "$ROOT/webroot/index.html" || fail "WebUI toggle not live"
for j in "$ROOT"/webroot/i18n/*.json; do
  grep -q '"net_lte_light"' "$j" || fail "$(basename "$j") lacks net_lte_light"
done
for l in ar de es fr hy id it pt ru tr uk zh; do
  for k in T_N_LTE_LIGHT_LTE T_N_LTE_LIGHT_5G; do
    grep -q "^$k=" "$ROOT/runtime/i18n/action_$l.sh" || fail "$k missing: $l"
  done
done
grep -Fq 'fprintf(f, "screen_on=%d' "$ROOT/src/asb_governor.c" && fail "redundant screen_on= key is back (state has screen=)"
grep -Fq "5G only when needed: LTE chosen" "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report the light mode"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix114 contract"
) || exit 1
# ---- fix115 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix115: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"
grep -q '#include <sys/system_properties.h>' "$M" || fail "property API not included on Android"
grep -q '^#if defined(__ANDROID__)$' "$M" || fail "property include not guarded for host builds"
# the doze veto runs before every panel node
awk '/^static int metrics_screen_on\(/{f=1} f&&/asb_display_state_read\(\)/{print "prop"; exit} f&&/PATH_SCREEN_STATUS/{print "node"; exit}' "$M" | grep -qx prop \
  || fail "a panel node is read before Android's display state"
grep -q 'display_state|' "$ROOT/tools/logkit/_asb_logkit_common.sh" || grep -q '|wake|disp_state"' "$ROOT/tools/logkit/_asb_logkit_common.sh" \
  || fail "logkit display trace lacks wake/disp_state"
grep -q 'always-on display: %d of %d' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "full-day report does not count lit screen-off samples"
grep -q 'always-on display counted as screen-off' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report AOD time"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix115 contract"
) || exit 1
# ---- fix116 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix116: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q '^#include <sys/eventfd.h>$' "$G" || fail "eventfd header missing"
grep -q 'dlsym(RTLD_DEFAULT, "__system_property_wait")' "$G" || fail "waiter not resolved at run time (API 24 target)"
grep -q 'asb_disp_waiter_start();' "$G" || fail "waiter never started"
grep -q '^LDFLAGS=(-lm -ldl)' "$ROOT/src/build_ndk_release.sh" || fail "NDK build does not link libdl"
grep -q '^LDFLAGS="-lm -ldl"$' "$ROOT/src/build_termux.sh" || fail "Termux build does not link libdl"
grep -q 'display-state waiter:' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report the waiter"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix116 contract"
) || exit 1
# ---- fix117 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix117: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q 'asb_bit_test(absb, ABS_MT_POSITION_X) && asb_bit_test(absb, ABS_MT_TRACKING_ID)' "$G" || fail "touch panel not identified by multitouch axes"
grep -q 'INPUT_PROP_DIRECT' "$G" || fail "touchpads/digitisers not excluded"
grep -q 'EVIOCGRAB' "$G" && fail "the touch node must never be grabbed"
grep -q 'touch watch:' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report the touch watch"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix117 contract"
) || exit 1
# ---- fix118 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix118: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q 'for (int i = 0; i < 20 && !pi; i++)' "$G" && fail "the waiter still gives up after ten minutes"
grep -q 'if (!pi) sleep(ASB_DISP_FIND_RETRY_S);' "$G" || fail "waiter does not keep looking for the property"
grep -q 'if (g_disp_waiter_up == 2 && g_uev_parked) { wake_keys_park(epfd, 0); return; }' "$G" || fail "screen-off still unparks the uevent socket with the waiter live"
grep -q 'if (g_disp_waiter_up == 2 && g_uev_parked) { wake_keys_park(epfd, 1); return; }' "$G" || fail "screen-on leaves the wake keys (touch panel) in epoll"
grep -q 'int _not_wake = (g_disp_waiter_up == 2 && (_dsr == 1 || _dsr == 3 || _dsr == 4));' "$G" || fail "resume chain not skipped when Android says off/doze"
grep -q '} else if (g_disp_waiter_up != 2 && g_uev_parked) {' "$G" || fail "uevent socket not given back when the waiter is gone"
grep -q 'screen_on_resume_skipped=%lu' "$G" || fail "skipped resume chains not published"
grep -q 'resume re-check(s) skipped' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report skipped resume chains"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix118 contract"
) || exit 1
# ---- fix119 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix119: $*"; exit 1; }
L="$ROOT/runtime/asb_lte_screenoff.sh"
grep -q 'case "$_dev" in rmnet\*|ccmni\*|v4-rmnet\*|v4-ccmni\*) return 0 ;; esac' "$L" || fail "CLAT route not read as mobile"
grep -q '"$_IPB" route show table all' "$L" || fail "VPN check still reads only the main table"
grep -q 'v4-rmnet\*|v4-ccmni\*) echo mobile' "$ROOT/runtime/asb_net_apply.sh" || fail "net apply does not class CLAT as mobile"
grep -q 'rmnet\*|ccmni\*|wwan\*|v4-rmnet\*|v4-ccmni\*)' "$ROOT/runtime/asb_net_routes.sh" || fail "route windows do not class CLAT as mobile"
grep -q '^T_N_LTE_LIGHT_HINT=' "$ROOT/action.sh" || fail "no English hint"
for l in ar de es fr hy id it pt ru tr uk zh; do
  grep -q '^T_N_LTE_LIGHT_HINT=' "$ROOT/runtime/i18n/action_$l.sh" || fail "T_N_LTE_LIGHT_HINT missing: $l"
done
grep -q 'g_asb_cfg.log_level >= (g_active_by_touch && calm ? 3 : 1)' "$ROOT/src/asb_governor.c" || fail "touch cadence still floods the log"
echo "PASS: fix119 contract"
) || exit 1
# ---- fix120 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix120: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
F="$ROOT/src/asb_fsm.h"
grep -q 'int cam_open = m->misc.camera_active;' "$G" || fail "camera flag not read by the app-hint inference"
# Four branches, all guarded: the two Smart inferences and, since fix210, their mirror in
# asb_fg_classify_tick on the manual profiles - each heat branch must keep !cam_open.
[ "$(grep -c '} else if (!boot_grace && !cam_open &&' "$G")" = 4 ] || fail "a heat branch still infers a game with the camera open"
grep -q 'static const char \*_snames\[\]' "$G" && fail "heartbeat still carries its own state-name table"
grep -q 'asb_state_names\[fsm.state\] : "?",' "$G" || fail "heartbeat does not use the FSM state names"
# The name table must follow the enum, entry for entry.
_enum="$(sed -n '/^typedef enum {/,/} asb_state_t;/p' "$F" | grep -oE 'ASB_STATE_[A-Z_]+ *= *[0-9]+' | grep -v COUNT | sort -t= -k2 -n | sed -E 's/ASB_STATE_([A-Z_]+).*/\1/' | tr '\n' ' ')"
_names="$(sed -n '/^static const char \*asb_state_names\[\] = {/,/};/p' "$F" | grep -oE '"[A-Z_]+"' | tr -d '"' | tr '\n' ' ')"
[ -n "$_enum" ] || fail "state enum not found"
[ "$_enum" = "$_names" ] || fail "asb_state_names ($_names) does not follow the enum ($_enum)"
echo "PASS: fix120 contract"
) || exit 1
# ---- fix121 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix121: $*"; exit 1; }
L="$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q '^lk_capture_jank_row() {' "$L" || fail "no jank row capture"
grep -q 'lk_dumpsys graphicsstats' "$L" || fail "jank trace does not read graphicsstats"
grep -q '/^Janky frames:/ ' "$L" || fail "legacy janky count could be summed instead of the current one"
grep -q 'lk_capture_jank_row "$_phase" "${_dscr:-0}"' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "full-day capture does not record UI smoothness"
grep -q 'UI smoothness today' "$ROOT/tools/asb_diag.sh" || fail "asbdiag has no UI smoothness line"
grep -q 'jank_trace.tsv' "$ROOT/docs/log_schemas.md" || fail "jank_trace.tsv schema not documented"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
grep -q 'int _cma = asb_comfort_ma(m);' "$ROOT/src/asb_governor.c" || fail "comfort trims still read one current sample"
echo "PASS: fix121 contract"
) || exit 1
# ---- fix122 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix122: $*"; exit 1; }
L="$ROOT/runtime/asb_lte_screenoff.sh"
# fix131 restructured the loop (the timer keeps watching after the switch); the mobile-data
# gate is the same comparison.
grep -q '\[ $(( _dk \* DELAY )) -ge $(( OFF_MIN_KIB \* _dt )) \]; }; then' "$L" || fail "screen-off LTE does not wait for mobile data"
grep -q '_screen_off_strict || return 0' "$L" || fail "no re-check right before the switch"
grep -q 'the screen came on during the switch' "$L" || fail "an interrupted switch is not given back"
grep -q '/ccmni\*; do' "$L" || fail "ccmni links not counted by the scripts"
grep -q 'ccmni\*/statistics/rx_bytes' "$ROOT/runtime/asb_screenoff_class.sh" || fail "screen-off classifier ignores ccmni"
grep -q 'strncmp(nm, "ccmni", 5)' "$ROOT/src/asb_metrics.h" || fail "governor does not count ccmni"
grep -q '"rmnet_ipa0"' "$ROOT/src/asb_metrics.h" && fail "governor still adds the ipa0 transport"
grep -q 'quiet_windows=' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report quiet windows"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix122 contract"
) || exit 1
# ---- fix123 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix123: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"
grep -q 'strstr(type, "cpu_big") || strstr(type, "cpu-big")' "$M" || fail "MediaTek big-core thermal zones not recognised"
grep -q 'strcmp(type, "soc_max") == 0 || strcmp(type, "mtktscpu") == 0' "$M" || fail "MediaTek SoC aggregate not recognised"
grep -q '"/sys/kernel/ged/hal/gpu_utilization",' "$M" || fail "no MediaTek GPU load source"
grep -q 'case_mediatek_lvts_names();' "$ROOT/tests/asb_smart.sh" || fail "no MTK thermal fixture"
echo "PASS: fix123 contract"
) || exit 1
# ---- fix124 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix124: $*"; exit 1; }
S="$ROOT/src/asb_smart.h"
grep -q 'if (asb_smart_pkg_via_activity_top(pkg' "$S" && fail "dumpsys activity top still in the probe chain"
grep -q 'int _topapp = asb_smart_pkg_via_topapp(pkg, sizeof(pkg));' "$S" || fail "top-app cgroup not asked"
grep -q '"/dev/cpuset/top-app/cgroup.procs"' "$S" || fail "top-app cpuset not read"
grep -q 'if (_upn - g_user_poll_ts >= 120' "$ROOT/src/asb_governor.c" || fail "user poll still every few ticks"
grep -q 'from the top-app cgroup' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report top-app answers"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix124 contract"
) || exit 1
# ---- fix125 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix125: $*"; exit 1; }
UI="$ROOT/webroot/index.html"
B="$ROOT/tools/asb_config_backup.sh"
_cell="$(awk '/^\.live-cell \{/{on=1} on{print} on&&/^}/{exit}' "$UI")"
printf '%s\n' "$_cell" | grep -Eq '^ *min-height: 54px;' || fail "forecast cells do not grow with their text"
printf '%s\n' "$_cell" | grep -Eq '^ *height: 54px;' && fail "fixed 54px cell height is back"
grep -q '_bundle_write()' "$B" || fail "no single-file export"
grep -q '_bundle_import()' "$B" || fail "no single-file import"
grep -q 'import-path FILE.asb|FILE.conf' "$B" || fail "usage does not name .asb"
grep -q 'const conf = !dir && /\\.(asb|conf)$/i.test(name);' "$UI" || fail "file browser does not list .asb"
A="$ROOT/runtime/asb_audio_apply.sh"
[ "$(grep -c '\[ "$(getprop "$1" 2>/dev/null)" = "$2" \] && return 0' "$A")" -ge 2 ] || fail "persist mirrors still rewritten when unchanged"
S="$ROOT/src/asb_smart.h"
grep -q 'if (screen_on_now && g_stat_probe_topapp > 0 && _ttl < 60) _ttl = 60;' "$S" || fail "dumpsys fallback not held back where the cgroup works"
grep -q 'probe_topapp_empty=%lu' "$ROOT/src/asb_governor.c" || fail "fallback reasons not published"
grep -q '(writer p%d: %s, req %d, holds %lu, backoff %lds)' "$ROOT/src/asb_governor.c" || fail "vendor_ceiling line lacks the writer status"
K="$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q '^lk_cap_share()' "$K" || fail "no time-at-ceiling from time_in_state"
grep -q '^lk_topapp_pkg()' "$K" || fail "no app column in the jank trace"
grep -q 'dstart = int(top / day) \* day' "$ROOT/tools/asb_diag.sh" || fail "asbdiag frames-today still keys on one start time"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix125 contract"
) || exit 1
# ---- fix126 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix126: $*"; exit 1; }
F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"; W="$ROOT/src/asb_writer.h"
grep -q '#define ASB_ESC_ENTRY_MARGIN_C 3' "$F" || fail "no entry margin under the exit mark"
grep -q 'if (m->therm.cpu_max_c > _exit_c - ASB_ESC_ENTRY_MARGIN_C) {' "$F" || fail "burst opens right under its own exit mark"
grep -q 'int _pinned = (_pinned_prime && !asb_esc_ceiling_foreign(m, _ps)) ||' "$F" || fail "burst opens under a foreign ceiling"
grep -q 'g_fsm_slot_req_khz\[i\] = cmax\[i\];' "$W" || fail "writer does not record its kept request"
grep -q 'prime_escape_skip_warm=%lu\\nprime_escape_skip_foreign=%lu' "$G" || fail "escape refusals not published"
grep -q 'static int writer_slot_path_idx(int slot)' "$W" || fail "no slot -> policy table mapping"
grep -q 'writer_slot_ceiling(0, fsm.current_caps.cpu_max\[0\], fsm.thermal_cap);' "$G" || fail "vendor_ceiling still snaps with table index = slot"
grep -q 'desired_cpu_max_prime=%d\\neffective_cpu_max_prime=%d' "$G" || fail "prime figures not published"
grep -q 'screen_off_detect=\\"uevent:%lu,display:%lu,tick:%lu\\"' "$G" || fail "screen-off sources not counted"
grep -q 'asb_log("screen OFF (Android display state)")' "$G" || fail "waiter screen-off still logged as a tick"
D="$ROOT/tools/asb_diag.sh"
grep -q 'lifted to the race-to-idle floor (40% of hardware max)' "$D" || fail "asbdiag prime ceiling ignores the floor"
grep -q "_s0n: ASB's own thermal-budget trim" "$D" || fail "asbdiag blames the vendor for ASB's own trim"
grep -q 'screen-off noticed by:' "$D" || fail "asbdiag does not show screen-off sources"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
grep -q '|main_by=${_mb}|prime_by=${_pb}|writer=${_cw:-asb}"' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "throttle rows carry no cause"
echo "PASS: fix126 contract"
) || exit 1
# ---- fix127 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix127: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; A="$ROOT/action.sh"; W="$ROOT/webroot/index.html"
grep -q 'fprintf(f, "forecast_rate_x10=%d\\nforecast_basis=%s\\n", _fr, _fb);' "$G" || fail "governor publishes no forecast"
grep -q '_frx=$(grep -m1 "^forecast_rate_x10=" /dev/.asb/state' "$A" || fail "action does not read the governor forecast"
grep -Fq "const _fPick = lvSlotToMeter(parseInt(kv.forecast_rate_x10 || '0', 10), String(kv.forecast_basis || ''));" "$W" || fail "WebUI does not read the governor forecast"
grep -q '_ton_min=$(( _lvl \* 600 / _eta_rate ))' "$A" || fail "action minutes not percent over rate"
grep -q 'Math.floor(bcap \* 600 / ewma_x10)' "$W" || fail "WebUI minutes not percent over rate"
grep -q 'echo "       ${M_PREDICT}: $(_s "$T_ETA_SCREEN" "$_ton_h" "$_ton_m") ${_eta_note}"' "$A" || fail "Smart card prints its own forecast"
for l in ar de es fr hy id it pt ru tr uk zh; do
  grep -q '^T_ETA_SCREEN=' "$ROOT/runtime/i18n/action_$l.sh" || fail "T_ETA_SCREEN missing: $l"
  grep -q '^T_ETA_AVG=".*%s' "$ROOT/runtime/i18n/action_$l.sh" || fail "forecast note without its rate: $l"
done
for l in ar de en es fr hy id it pt ru tr uk zh; do
  grep -q '"lv_avgdrain_tip"' "$ROOT/webroot/i18n/$l.json" || fail "slot tile tooltip missing: $l"
  grep -q '"unit_pcth"' "$ROOT/webroot/i18n/$l.json" || fail "unit missing: $l"
done
grep -q 'high-input-latency events %d' "$ROOT/tools/asb_diag.sh" || fail "asbdiag latency still a share"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
grep -q 'per cluster: the prime sat under a ceiling ASB did not write' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "verdict ignores the per-cluster cause"
Y="$ROOT/.github/workflows/build-release.yml"
TW="$ROOT/.github/workflows/build-test.yml"
! grep -q 'prerelease:\|PRERELEASE_INPUT\|rc\[1-9\]' "$Y" || fail "obsolete rc/prerelease channel remains"
grep -q 'test_sequence:' "$TW" || fail "test workflow has no positive testN input"
grep -q 'ASB_VER="${BASE_VER}-test${TEST_SEQ}"' "$TW" || fail "testN does not name the build"
[ ! -e "$ROOT/.github/workflows/build-debug.yml" ] || fail "separate debug channel remains"
grep -q '\*conf_tuning_params.json.asbbase) asb_tw_cam_stock "$_bf" && asb_tw_base_rom_ok "$_bf" && continue ;;' "$ROOT/runtime/asb_tweaks.sh" \
  || fail "orphan prune deletes the stock camera baseline before the installer clones"
grep -q '\*conf_tuning_params.json.asbbase) asb_tw_base_rom_stamp "$_bp" ;;' "$ROOT/runtime/asb_tweaks.sh" || fail "camera baseline saved without a ROM stamp"
echo "PASS: fix127 contract"
) || exit 1
# ---- fix128 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix128: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; P="$ROOT/runtime/profile_core.sh"
grep -q 'if (!_live_stale && live_x10 > 0 && _pub_win >= 600 && _bconf >= 2) {' "$G" || fail "forecast does not lead with the actual drain"
grep -q '"lv_avgdrain": "Расход"' "$ROOT/webroot/i18n/ru.json" || fail "Monitor tile is not the actual drain"
grep -q '"eta_measured": "по факту"' "$ROOT/webroot/i18n/ru.json" || fail "actual forecast label not short"
grep -q '^T_ETA_MEASURED="(по факту %s)"' "$ROOT/runtime/i18n/action_ru.sh" || fail "action actual label"
grep -q 'rm -f "$_ux_base" 2>/dev/null' "$P" || fail "UX baseline restored on every run"
grep -q '\[ "$_cur_anim" = "$_mine" \] && _restore=1' "$P" || fail "restore ignores what the user set afterwards"
grep -q 'true > "$_ux_legacy"' "$P" || fail "legacy 0.8/0.9 cleanup not one-shot"
grep -q 'asb_anim_apply.sh" --if-changed' "$P" || fail "explicit Animation Speed loses to the profile"
grep -q 'animation scales: yours - ASB does not change them' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not name the owner"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix128 contract"
) || exit 1
# ---- fix129 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix129: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"; L="$ROOT/runtime/asb_apply_ledger.sh"
grep -q '^static void thermal_conf_recheck(time_t now) {' "$M" || fail "no runtime confidence re-check"
grep -q '        thermal_conf_recheck(now);' "$M" || fail "re-check not called from the thermal read"
grep -q 'case_disputed_fallback_promoted_at_runtime();' "$ROOT/tests/asb_smart.sh" || fail "no fixture for the promotion"
grep -q 'thermal_conf_promotions=%lu' "$ROOT/src/asb_governor.c" || fail "promotions not published"
grep -q 'rejected before on this ROM build - not retried' "$L" || fail "refused settings retried every pass"
grep -q '_lg_cr="$(printf' "$L" || fail "ledger note still forks per field"
grep -q "printf '%s|%.120s|%.120s" "$L" || fail "ledger field cap lost"
grep -q 'grep -Fq "setting|$_pb_ns:$_pb_key|" "$ASB_PROFILE_BASELINE" 2>/dev/null && return 0' "$ROOT/runtime/asb_baseline.sh" || fail "baseline capture reads Android for recorded keys"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix129 contract"
) || exit 1
# ---- fix130 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix130: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; D="$ROOT/tools/asb_diag.sh"
grep -q '^static void asb_main_capacity_parity(asb_profile_caps_t \*caps, const asb_metrics_t \*m,$' "$G" || fail "no main/prime parity"
grep -q 'if (g_parity_main_khz > want_p0) want_p0 = g_parity_main_khz;' "$G" || fail "the raised main ceiling would be logged as a leak"
grep -q 'if (g_parity_main_khz > _d0) _d0 = g_parity_main_khz;' "$G" || fail "desired_cpu_max0 does not include the raise"
grep -q '^static int writer_slot_step_at_least(int slot, long khz) {' "$ROOT/src/asb_writer.h" || fail "no step-at-or-above helper"
grep -q 'capacity at the ceilings: main' "$D" || fail "asbdiag does not show which cluster looks bigger"
grep -q 'main kept level with the prime' "$D" || fail "asbdiag does not report the raise"
grep -q 'uiAudioRelease(ctx, endAt);' "$ROOT/webroot/index.html" || fail "UI sounds keep the audio output open"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix130 contract"
) || exit 1
# ---- fix132 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix132: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; D="$ROOT/tools/asb_diag.sh"; I="$ROOT/common/install.sh"
grep -q '^#define ASB_PARITY_NEAR_PCT 90' "$G" || fail "no near-parity share"
grep -q 'lift = (int)top; near = 1;' "$G" || fail "level step over the limit still refuses everything"
grep -q 'main_parity_near=%d' "$G" || fail "state does not say the raise is the nearest step"
grep -q 'not raised - level needs $_mpo kHz, over 60% of the main maximum' "$D" || fail "asbdiag still says not needed when the limit refused it"
grep -q 'nearly level (within 10%)' "$D" || fail "asbdiag calls a near-level main ceiling the smaller cluster"
grep -q 'within 10%% of the prime' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "full-day report has no near-level bucket"
grep -q 'ASB_D_BT_STOCK:-BT absolute volume: stock' "$I" || fail "stock BT install prints an empty heading"
for f in "$ROOT"/common/*text.sh; do grep -q '^ASB_D_BT_STOCK=' "$f" || fail "ASB_D_BT_STOCK missing in ${f##*/}"; done
grep -q 'LK_BT_LAST_KIND' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "BT lifecycle recorder still writes a row per duplicate line"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix132 contract"
) || exit 1
# ---- fix133 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix133: $*"; exit 1; }
W="$ROOT/src/asb_writer.h"; D="$ROOT/tools/asb_diag.sh"; L="$ROOT/tools/logkit"
grep -q 'if (!_vendor_hold || requested == h->requested) {' "$W" || fail "a vendor hold still swallows a changed request"
grep -q 'writer_hold_bypass=%lu' "$W" || fail "hold bypasses not published"
grep -q 'sent through a vendor hold' "$D" || fail "asbdiag does not count hold bypasses"
grep -q 'by screen state        : screen on' "$L/asb_log_full_day.sh" || fail "timer wakeups not split by screen state"
grep -q "_ph() { awk" "$L/asb_log_full_day.sh" || fail "cost rates still divide by whole hours"
grep -q '^lk_sysui_verdict() {' "$L/_asb_logkit_common.sh" || fail "SystemUI restart has no verdict"
grep -q 'ASB_DSP_REFERENCE_OPTIONAL' "$ROOT/tests/asb_features.sh" || fail "DSP reference has no explicit source-only switch"
grep -q 'ASB_DSP_REFERENCE_OPTIONAL' "$ROOT/.github/workflows/build-release.yml" && fail "release build must never skip the DSP reference"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix133 contract"
) || exit 1
# ---- fix134 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix134: $*"; exit 1; }
F="$ROOT/runtime/asb_wifi_fallback.sh"; N="$ROOT/runtime/asb_net_apply.sh"; B="$ROOT/tools/asb_config_backup.sh"
grep -q '^_enabled() { case "$(_cfg net_wifi_leave)" in weak|unusable|aggressive) return 0 ;; esac; return 1; }' "$F" || fail "leave watch still limited to one rung"
grep -q '^_uses_validation() { case "$(_cfg net_wifi_leave)" in unusable|aggressive)' "$F" || fail "weak rung reads validation"
grep -q '^_release_window() {' "$F" || fail "no escalating release window"
grep -q '_sn="${_sl%%\\|\*}"' "$F" || fail "release-window streak split not mksh-safe"
grep -q '^IDLE_INTERVAL_S=30' "$F" || fail "screen-off watch interval lost"
grep -q '_abw_prev=/data/adb/asb/avoid_bad_wifi.prev' "$N" || fail "avoid_bad_wifi written without keeping the device value"
grep -q 'case "$_nwl" in weak|unusable|aggressive) _wf=1' "$N" || fail "wifi_fallback status ignores weak/unusable"
grep -q 'avoid_bad_wifi.prev ] && _asb_net_any=1' "$ROOT/service.sh" || fail "boot apply skips a pending avoid_bad_wifi restore"
grep -q 'settings put global network_avoid_bad_wifi "$_abw_old"' "$ROOT/uninstall.sh" || fail "uninstall leaves avoid_bad_wifi=1"
grep -q 'Wi-Fi leave watch (' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show the leave watch"
grep -q 'if \[ "${1:-}" = "--no-smart" \]; then _with_smart=0; shift; fi' "$B" || fail "save cannot leave the learning out"
grep -q '^smart_available() {' "$B" || fail "no smart-available probe"
grep -q '^_legacy_import() {' "$B" || fail "older multi-file copies have no line-by-line import"
grep -q "' --no-smart'" "$ROOT/webroot/index.html" || fail "save dialog does not pass the choice"
asb_has_test test_wifi_leave_rungs_runtime.sh || fail "leave-rungs runtime test missing"
asb_has_test test_config_legacy_import_runtime.sh || fail "legacy import runtime test missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix134 contract"
) || exit 1
# ---- fix135 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix135: $*"; exit 1; }
A="$ROOT/runtime/asb_audio_apply.sh"; H="$ROOT/runtime/asb_dsp_thermal.sh"
[ -f "$H" ] || fail "no shared heat rule for the DSP gain"
grep -q 'cpu_max_c=' "$A" && fail "the DSP gain still follows the CPU's hottest core"
grep -q '^ASB_DSP_TH_BAT="${ASB_DSP_TH_BAT:-/sys/class/power_supply/battery/temp}"' "$H" || fail "heat rule not on the battery temperature"
grep -q 'case "$_tc_r" in bt|wired|call) echo "$_tc_g"; return 0 ;; esac' "$H" || fail "Bluetooth/wired reduced for heat"
grep -q '1) if \[ "$_ts_t" -ge 450 \]; then echo 2; elif \[ "$_ts_t" -lt 400 \]; then echo 0; else echo 1; fi ;;' "$H" || fail "no hysteresis"
grep -q 'asb_dsp_thermal_tick' "$ROOT/service.sh" || fail "no minute re-check"
grep -q 'if \[ "${_mwake:-0}" = 1 \]; then' "$A" || fail "mirror does not wake the attach daemon on a gain change"
[ -f "$ROOT/runtime/asb_dsp_live.sh" ] || fail "no live effect probe"
grep -q 'asb_dsp_live_state' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show the live effect"
asb_has_test test_dsp_heat_backoff_runtime.sh || fail "heat back-off runtime test missing"
asb_has_test test_dsp_live_state_runtime.sh || fail "live state runtime test missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix135 contract"
) || exit 1
# ---- fix136 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix136: $*"; exit 1; }
W="$ROOT/runtime/asb_wakelock_watch.sh"; N="$ROOT/runtime/asb_net_apply.sh"; V="$ROOT/runtime/asb_ltpo_video.sh"
grep -q 'org.thoughtcrime.securesms|im.molly' "$W" || fail "Signal not protected by its real package id"
grep -q '^_wl_doze_exempt() {' "$W" || fail "apps exempt from battery optimisation can be restricted"
grep -q '^_wl_release_protected() {' "$W" || fail "a wrong earlier restriction is never released"
grep -q 'case "$_pall" in \*" congctl "\*) _congctl_ok=1; return 0 ;; esac' "$N" || fail "per-route congctl not decided on evidence"
grep -q 'cc\[\$_pk\]=\$_pw-pending' "$N" || fail "stale unsupported congestion verdict kept"
grep -q 'REARM_QUIET_S="${ASB_LTPO_REARM_QUIET_S:-10}"' "$V" || fail "no longer quiet after a touch restore"
grep -q 'ok_asb_dynamic (actual = ASB' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "a matching dynamic cap still reported as DESYNC"
grep -q 'T_N_SUF_WAIT' "$ROOT/action.sh" || fail "action screen silent about a per-link choice waiting for its link"
for t in test_wakelock_messenger_guard_runtime.sh test_net_congctl_probe_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix136 contract"
) || exit 1
# ---- fix137 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix137: $*"; exit 1; }
W="$ROOT/runtime/asb_wakelock_watch.sh"
grep -q 'elif \[ "\$_act" = 1 \] && \[ "\$_s" -lt 600 \] 2>/dev/null && \[ "\$_h" != 1 \]; then' "$W" || fail "a two-minute holder can still be restricted"
grep -q '^_wl_used_today() {' "$W" || fail "an app used today can be restricted"
grep -q '^_wl_rules_migrate() {' "$W" || fail "old-rule restrictions never handed back"
grep -q '_idle_due && _force=1 || continue' "$ROOT/service.sh" || fail "idle DSP route never refreshed"
grep -q 'in the interval the screen changed state' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "screen-change traffic still silently dropped"
grep -q "no ASB record of changing it" "$ROOT/tools/asb_diag.sh" || fail "avoid-bad-Wi-Fi owner not named"
for t in test_dsp_route_idle_runtime.sh test_logkit_traffic_edge_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix137 contract"
) || exit 1
# ---- fix138 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix138: $*"; exit 1; }
N="$ROOT/runtime/asb_net_apply.sh"
grep -q '_out="\$_out qdisc\[\$_pk\]=\$_pw-pending"' "$N" || fail "a per-link qdisc with no link still has no verdict"
grep -qF 'qdisc\[wifi*-pending*)' "$N" || fail "mapper has no pending for the Wi-Fi qdisc"
w="$(grep -nF 'qdisc\[wifi*-pending*)' "$N" | cut -d: -f1)"; g="$(grep -nF 'qdisc\[wifi*)' "$N" | head -1 | cut -d: -f1)"
[ "$w" -lt "$g" ] || fail "qdisc pending line after the generic ok line"
grep -q "case \"\$_pv\" in ''|\*=unsupported)" "$N" || fail "congestion kind without a verdict not filed as pending"
grep -q '_lgf="/dev/.asb/lru_gen_took_\$_lg"' "$ROOT/runtime/smart_dynamic_tune.sh" || fail "MGLRU node rewritten on every tuner run"
grep -q 'a bit missing here is one this kernel does not keep' "$ROOT/tools/asb_diag.sh" || fail "MGLRU bits not explained"
grep -q 'In detail: only an app that held the CPU for 10+ minutes' "$ROOT/webroot/index.html" || fail "wakelock card does not describe the fix137 rule"
for f in "$ROOT"/webroot/i18n/*.json; do
  case "${f##*/}" in en.json) continue ;; esac
  grep -q '10' "$f" || fail "${f##*/} lacks the wakelock rule text"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix138 contract"
) || exit 1
# ---- fix139 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix139: $*"; exit 1; }
E="$ROOT/src/DSP_AIDL/asb_effect_aidl.cpp"
grep -q 'void queueCommon(const Parameter::Common& common)' "$E" || fail "AIDL effect has no way to take a new stream format"
grep -q 'mContext->queueCommon(param.get<Parameter::common>())' "$E" || fail "setParameter does not hand a new Parameter::common to the context"
grep -q 'if (mCommonPending.load(std::memory_order_acquire)) applyPendingCommonLocked();' "$E" || fail "process() never applies a queued format"
grep -q 'std::unique_lock<std::mutex> core(mCoreLock, std::try_to_lock);' "$E" || fail "process() waits on a settings push (or does not guard the core)"
grep -q 'applyTunables(mPushedGainMb);' "$E" || fail "a format change drops the gain pushed over binder"
grep -q 'mPushedGainMb = gainMb;' "$E" || fail "pushed gain not remembered"
# The freshness gate must not demand the new literal: an older library keeps working.
grep -q 'ASB reconfigure' "$ROOT/src/build_ndk_release.sh" && fail "release gate demands the fix139 literal"
grep -q 'rate=%s session=' "$ROOT/runtime/asb_dsp_live.sh" || fail "live state does not show the output rate"
grep -q '(Input|Record) thread' "$ROOT/runtime/asb_dsp_live.sh" || fail "capture threads counted against the output"
grep -q "ASB reconfigure" "$ROOT/tools/asb_diag.sh" || fail "asbdiag silent about a pre-fix139 library on a non-48 kHz output"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix139 contract"
) || exit 1
# ---- fix140 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix140: $*"; exit 1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q '> "\$LK_OUT_DIR/.wl_uid_delta"' "$C" || fail "per-uid batterystats deltas not kept"
grep -q "not one app's total moved in" "$C" || fail "a stalled batterystats still reads as 'no app held a wakelock'"
grep -q '^lk_capture_on_battery()' "$C" || fail "stall check not limited to a capture on battery"
grep -q 'batterystats disagrees with these samples:' "$C" || fail "live holders not checked against batterystats"
grep -q 'within %s (%s), by ASB state and touch' "$C" && grep -q 'wn += within(top, "most frames")' "$C" || fail "jank by state not shown inside one app"
F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -n 'echo "' "$F" | grep -q '`' && fail "a backtick inside a double-quoted echo runs a command"
grep -q "'hfp_audio_disconnect' is an HFP/SCO audio-link detach" "$F" || fail "Bluetooth evidence line still empty"
grep -q 'Look again for up to 3 s before naming anything' "$ROOT/tools/asb_diag.sh" || fail "asbdiag grades a momentary boost as a vendor floor"
grep -q 'vendor floor - \$_drv/\$_gov clamps the minimum, not a write failure' "$ROOT/tools/asb_diag.sh" && fail "unproven vendor-floor claim still printed"
for t in test_logkit_bstats_stall_runtime.sh test_jank_app_state_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix140 contract"
) || exit 1
# ---- fix141 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix141: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"; G="$ROOT/src/asb_governor.c"
grep -q 'No camera guard while the screen is off (fix141)' "$M" || fail "camera guard still runs with the screen off"
awk '/static int metrics_camera_active/ { f = 1 } f && /if \(!g_cam_scr_prev\) \{/ { ok = 1; exit } END { exit !ok }' "$M" || fail "screen-off check not in the camera probe"
grep -q '^static int metrics_pcm_playing(void)' "$M" || fail "no PCM playback probe"
grep -q 'if (!g_offdrain_media && metrics_pcm_playing() == 1) g_offdrain_media = 1;' "$G" || fail "screen-off drain does not notice playback"
grep -q 'g_offdrain_media_skipped++;' "$G" || fail "a window with music still counts as idle"
grep -q 'if (got >= 3 && fmt == ASB_OFFDRAIN_FMT' "$G" || fail "a pre-fix141 idle figure (music mixed in) is still trusted"
grep -q 'offdrain_media_skipped=%d' "$G" || fail "skipped windows not published"
grep -q 'if (!need_thermal && metrics.misc.screen_on && g_last_thermal_read_ts > 0 &&' "$G" || fail "a screen-on tick can still decide on an hours-old temperature"
grep -q 'not below the race-to-idle floor' "$G" || fail "cooldown log still claims the hardware minimum"
grep -q '^asb_cgroup_detach()' "$ROOT/runtime/asb_cgroup.sh" || fail "no cgroup detach helper"
for f in asb_ltpo_video.sh asb_wifi_fallback.sh asb_lte_screenoff.sh; do
  grep -q 'asb_cgroup_detach \$\$' "$ROOT/runtime/$f" || fail "$f watcher stays in the WebUI's app cgroups"
done
grep -q "uid_\[0-9\]+|/apps|/top-app|/foreground|frozen" "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "recorder still calls top-app not_needed"
grep -q '"runtime/asb_cgroup.sh"' "$ROOT/.github/workflows/build-release.yml" || fail "release build does not require asb_cgroup.sh"
grep -q '^_asb_tombstones() {' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not name crashed processes"
grep -q '^lk_emit_native_crashes() {' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "captures do not name crashed processes"
grep -q '^lk_direct_temps() {' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "stale governor temperatures still in the phase table"
grep -q 'com.radolyn.ayugram' "$ROOT/runtime/asb_wakelock_watch.sh" || fail "Telegram forks not protected"
for t in test_camera_pcm_native_runtime.sh test_cgroup_detach_runtime.sh test_native_crash_names_runtime.sh test_logkit_stale_temp_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
asb_has_test test_camera_pcm_native.c || fail "native fixture source missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix141 contract"
) || exit 1
# ---- fix142 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix142: $*"; exit 1; }
W="$ROOT/webroot/index.html"; C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q 'function cfgProfileShowResult(res)' "$W" || fail "save/apply outcome not shown in the window"
grep -q 'cfg_res_opened_banner' "$W" || fail "an opened file is not marked as not applied"
grep -q 'const settingsDone = ' "$W" || fail "a Smart-only failure after the settings were written reads as nothing applied"
grep -q 'echo "changed=' "$ROOT/tools/asb_config_backup.sh" || fail "restore does not report what it changed"
grep -q '} > "$_out.part" && mv -f "$_out.part" "$_out"' "$F" || fail "full-day report still rewritten in place"
grep -q 'phase_summary.txt.part' "$F" || fail "phase summary still rewritten in place"
grep -q 'oa = age; if (offst > 0 && e - offst < oa) oa = e - offst' "$C" || fail "live holds compared with batterystats including screen-on time"
grep -q '^lk_screen_off_min() {' "$C" || fail "stall claim without screen-off time"
grep -q 'first frame outside libc' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not name the crashing code"
grep -q 'first frame outside libc' "$C" || fail "captures do not name the crashing code"
grep -q "AIDL library: fix139 build" "$ROOT/tools/asb_diag.sh" || fail "asbdiag cannot tell which DSP library is installed"
grep -q '^T_S_MC_PAST=' "$ROOT/action.sh" || fail "multicast with Wi-Fi off still reads as a present cost"
for f in "$ROOT"/runtime/i18n/action_*.sh; do grep -q '^T_S_MC_PAST=' "$f" || fail "T_S_MC_PAST missing in ${f##*/}"; done
asb_has_test test_config_restore_outcome_runtime.sh || fail "outcome test missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix142 contract"
) || exit 1
# ---- fix143 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix143: $*"; exit 1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q '^lk_gfx_pkg_delta() {' "$C" || fail "jank trace does not record which app drew the janky frames"
grep -q '|fg_pkg|jank_pkgs|wake"' "$C" || fail "jank trace header lacks column 17"
grep -q 'steady floor: %.2f janky frames a second' "$C" || fail "report does not tell a steady floor from lag"
grep -q 'printf "%-16s %9s %9s %8s %8s\\n", "ASB state", "intervals", "frames", "janky", "janky/s"' "$C" || fail "state table without janky/s"
grep -q '^asb_gfx_run_delta() {' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not measure frames per app while it runs"
grep -q 'wake_lock=\[^:" \]\*:"\\\*walarm' "$C" || fail "alarm list still counts releases and summary lines"
grep -q 'alarmtimer -16: a wake-up alarm was due within 2 s' "$C" || fail "alarmtimer refusals still called driver faults"
grep -q '^lk_wh_app_parse() {' "$C" || fail "phase holders still batterystats running totals"
grep -q '^lk_wh_kernel_snap() {' "$C" || fail "kernel holders not measured per phase"
grep -q 'LK_PH_SNAPSHOT=1' "$F" || fail "interim report snapshot still writes holder blocks"
grep -q 'asb_wakelock_watch.sh" fitness' "$ROOT/service.sh" || fail "fitness limit not put back after boot"
grep -q '^if \[ "\${1:-}" = fitness \]; then' "$ROOT/runtime/asb_wakelock_watch.sh" || fail "watcher has no fitness-only pass"
for t in test_jank_floor_runtime.sh test_phase_wakeholders_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix143 contract"
) || exit 1
# ---- fix144 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix144: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q 'runtime/asb_reconcile.sh"' "$G" && fail "governor still spawns the no-op reconcile --once"
grep -q 'runtime/asb_watchdog.sh"' "$G" && fail "governor still spawns the no-op watchdog --once"
grep -q '^asb_gov_liveness() {' "$ROOT/service.sh" || fail "no governor liveness check"
grep -q '^    asb_gov_liveness$' "$ROOT/service.sh" || fail "liveness check not on the housekeeping tick"
grep -q 'stopped cleanly (pid %d)' "$G" || fail "a clean stop leaves no trace"
grep -q '^asb_gov_starts() {' "$ROOT/tools/asb_diag.sh" || fail "asbdiag cannot tell crashes from boots"
grep -q 'not set at boot with the native governor' "$ROOT/tools/asb_diag.sh" || fail "asbdiag still names a gmin target nothing applies"
asb_has_test test_gov_liveness_runtime.sh || fail "liveness test missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix144 contract"
) || exit 1
# ---- fix145 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix145: $*"; exit 1; }
W="$ROOT/webroot/index.html"; D="$ROOT/tools/asb_diag.sh"
grep -q 'id="cfgSoundBtn" onclick="uiSoundToggle()"' "$W" || fail "no switch for the interface sounds"
grep -q '^function uiOtherAudioRefresh() {' "$W" || fail "cues still play over another app's audio"
grep -q "if (_screen !== _cfgShownScreen) {" "$W" || fail "settings entrance runs on every repaint (cards twitch)"
grep -q '^_vlim="$(dumpsys audio' "$D" || fail "asbdiag does not show Android's volume limits"
grep -q 'disabled|on) V "BT absolute volume disabled' "$D" || fail "asbdiag ignores bt_absvol_mode=disabled"
grep -q 'dsp_load_check.txt' "$D" || fail "asbdiag does not print the boot DSP load check"
grep -q '_dlc=/data/adb/asb/dsp_load_check.txt' "$ROOT/service.sh" || fail "no DSP load check a minute after boot"
grep -q '# volume limits (safe media volume, sound dose, absolute volume)' "$ROOT/tools/logkit/_asb_logkit_common.sh" \
  || fail "full-day audio snapshot without the volume limits"
asb_has_test test_webui_quiet_ui_runtime.sh || fail "quiet-ui test missing"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix145 contract"
) || exit 1
# ---- fix146 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix146: $*"; exit 1; }
I="$ROOT/common/install.sh"; C="$ROOT/tools/logkit/_asb_logkit_common.sh"; D="$ROOT/tools/asb_diag.sh"
grep -q '^asb_reset_odm_binds() {' "$I" || fail "no odm bind reset ahead of the audio stage"
grep -q '^asb_odm_bound_by_asb() {' "$I" || fail "the generator cannot tell its own bind from stock"
sed -n '/^asb_generate_odm_binds() {/,/^}/p' "$I" | grep -q 'rm -rf "$_ob_root"' && fail "the generator wipes the DSP registration's bind again"
grep -q '^lk_cluster_roles() {' "$C" || fail "jank trace still guesses main/prime from policy numbers"
grep -q 'wn += within(topj, "most janky frames")' "$C" || fail "no table for the app with the most janky frames"
grep -q 'the little cluster (%s) runs no UI' "$C" || fail "report does not name the clusters on a 4-cluster part"
grep -q '_tier="little"; \[ "$_npol" -eq 2 \] && _tier="main"' "$D" || fail "asbdiag calls the six main cores little"
grep -q 'no ASB entry and no runtime bind queued - it is read before /vendor/etc' "$D" || fail "asbdiag does not explain a stock /odm effects config"
for t in test_cluster_roles_runtime.sh test_odm_bind_reinstall_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix146 contract"
) || exit 1
# ---- fix148 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix148: $*"; exit 1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q '^lk_power_state() {' "$C" || fail "no power state that knows a paused charge"
grep -q 'case "$(lk_power_state "$_cs")" in' "$F" || fail "a battery-protection hold is filed as sleep again"
grep -q 'longest stretch off the charger was' "$F" || fail "night verdict counts the charger"
grep -q 'kernel holder on the charger:' "$F" || fail "charging-idle verdict names no kernel holder"
grep -q "else if (st\[0\] == 'D')                 b->charging = 0;" "$ROOT/src/asb_metrics.h" || fail "governor reads Not charging as on battery"
asb_has_test test_charge_hold_runtime.sh || fail "charge hold test missing"
echo "PASS: fix148 contract"
) || exit 1
# ---- fix149 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix149: $*"; exit 1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q '^lk_bt_dump_filter() {' "$C" || fail "BT evidence still crowded out by Android 16 flag lines"
[ "$(grep -c 'lk_dumpsys bluetooth_manager 2>/dev/null | lk_bt_dump_filter' "$C")" = 2 ] || fail "a BT dump left unfiltered"
grep -q 'fwmark 0x0/0xffff iif lo .*lookup ' "$ROOT/runtime/asb_wifi_fallback.sh" || fail "leave-bad-Wi-Fi blind under a VPN"
grep -q 'fwmark 0x0/0xffff iif lo .*lookup ' "$ROOT/runtime/asb_lte_screenoff.sh" || fail "LTE check guesses the network under a VPN"
grep -q 'measured screen-off mobile traffic %.1f MiB, Wi-Fi %.1f MiB' "$F" || fail "screen-off traffic counts mobile only"
grep -q '_label="LITTLE"; \[ "$_cv_np" -eq 2 \] && _label="MAIN"' "$C" || fail "cap_verify calls the six main cores LITTLE"
grep -q 'metrics.bat.charging ? -1 : metrics.bat.current_ma' "$ROOT/src/asb_governor.c" || fail "hourly learner takes charging current as drain"
grep -q "tr '\\\\n' ',' | sed 's/,\$//') fps video" "$ROOT/runtime/asb_ltpo_video.sh" || fail "LTPO log line breaks on two rates"
for t in test_wifi_default_vpn_runtime.sh test_learner_charging_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
echo "PASS: fix149 contract"
) || exit 1
# ---- fix150 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix150: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; C="$ROOT/tools/logkit/_asb_logkit_common.sh"; D="$ROOT/tools/asb_diag.sh"
# fix223 deliberately adds touch_active for Battery's already-armed continuous-touch hold.
grep -q '^static int asb_unlock_lift_update(int screen_on, int touch_kick, int touch_active,$' "$G" || fail "no unlock lift"
grep -q '^static void asb_smart_night_awake(int screen_on, int daypart, int is_weekend, time_t now) {$' "$G" || fail "no night-awake lean"
grep -q '^unlock_lift_s=3$' "$ROOT/config/governor.conf" && grep -q '^smart_night_awake=1$' "$ROOT/config/governor.conf" || fail "not shipped on"
cmp -s "$ROOT/config/governor.conf" "$ROOT/config/governor.conf.shipped" || fail "shipped governor.conf differs"
grep -q 'NF >= 18 && $18 == "wake" {' "$C" || fail "wake rows mixed into the ordinary jank figures"
grep -q '"wake" >> "$LK_OUT_DIR/jank_trace.tsv"' "$C" || fail "the wake itself is still in no row"
grep -q '_s0n="little"; \[ "$_s1n" = "prime" \] && _s0n="main"' "$D" || fail "asbdiag cap line calls the main cores little"
grep -q 'waiting_for_wifi_default_route) _f "       $T_N_FB_WAIT" ;;' "$ROOT/action.sh" || fail "action screen prints the watcher's raw token"
for t in test_unlock_lift_runtime.sh test_smart_night_awake_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix150 contract"
) || exit 1
# ---- fix151 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix151: $*"; exit 1; }
D="$ROOT/tools/asb_diag.sh"
_ln_nv="$(grep -n '^\[ -n "\$NVBASE" \] || NVBASE=/data/adb$' "$ROOT/customize.sh" | cut -d: -f1)"
_ln_fn="$(grep -n '^\. \$TMPDIR/functions.sh$' "$ROOT/customize.sh" | cut -d: -f1)"
[ -n "$_ln_nv" ] && [ -n "$_ln_fn" ] && [ "$_ln_nv" -lt "$_ln_fn" ] || fail "NVBASE not defaulted before the template reads it"
grep -q '  resetprop -n audio.safemedia.bypass true >/dev/null 2>&1 || true' "$ROOT/post-fs-data.sh" || fail "limiter switch does not set the bypass before Android starts"
grep -q 'audio.safemedia.bypass = ${_smb:-<unset>}' "$D" || fail "asbdiag does not show the bypass"
grep -q '_no_now="$(ls -d /sys/class/net/\*/queues/rx-\* 2>/dev/null | wc -l):$(cat /sys/class/net/wlan\*/tx_queue_len' "$ROOT/service.sh" || fail "a Wi-Fi queue reset by the driver is not noticed"
grep -q 'the queue did not take (send this diag)' "$D" || fail "asbdiag does not judge the Wi-Fi queue"
grep -q '^CONFIRM_INTERVAL_S=3$' "$ROOT/runtime/asb_wifi_fallback.sh" || fail "no fast confirmation"
for t in test_net_txqueue_runtime.sh test_wifi_leave_fast_confirm_runtime.sh test_asbdiag_report_host_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix151 contract"
) || exit 1
# ---- fix152 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix152: $*"; exit 1; }
D="$ROOT/tools/asb_diag.sh"
Z="$ROOT/runtime/asb_doze_apply.sh"
H="$ROOT/webroot/index.html"
grep -q '^if \[ "${1:-}" = list \]; then$' "$Z" || fail "the applier has no list for the picker"
_ln_l="$(grep -n '^if \[ "${1:-}" = list \]; then$' "$Z" | cut -d: -f1)"
_ln_c="$(grep -n '^case "$_lvl" in$' "$Z" | head -1 | cut -d: -f1)"
[ -n "$_ln_l" ] && [ -n "$_ln_c" ] && [ "$_ln_l" -lt "$_ln_c" ] || fail "list runs after the night block that pauses AOD"
grep -q '_ga_file="${_DZ_DIR}/doze_whitelist_added"' "$Z" || fail "no record of the exemptions ASB grants"
grep -q 'done < /data/adb/asb/doze_whitelist_added' "$ROOT/uninstall.sh" || fail "uninstall leaves ASB's grants behind"
grep -q 'doze_whitelist_removed" "$D/doze_whitelist_keep" 2>/dev/null' "$ROOT/runtime/asb_wakelock_watch.sh" || fail "wakelock watcher forgets apps the trim removed"
grep -q '^async function dozeOpenEditor() {$' "$H" || fail "no picker"
grep -q 'id="dozeKeepSearch" type="search"' "$H" || fail "the picker has no search"
grep -q 'made exempt by ASB: $(_dzn added)' "$D" || fail "asbdiag does not show the trim's records"
for t in test_doze_keep_list_runtime.sh test_webui_doze_keep_picker_runtime.sh test_wakelock_trimmed_exempt_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix152 contract"
) || exit 1
# ---- fix153 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix153: $*"; exit 1; }
D="$ROOT/tools/asb_diag.sh"
grep -q ' s of CPU per hour"$' "$D" || fail "asbdiag does not put ASB's CPU per hour"
grep -q '^    lk_emit_wifi_leave_summary$' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "the capture does not report Wi-Fi leaving"
grep -q '^  lk_wifi_leave_collect$' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "the capture does not keep the watcher's events"
[ -s "$ROOT/docs/field_baseline/fix150.json" ] || fail "no fix150 baseline to compare against"
[ -f "$ROOT/tools/asb_capture_compare.py" ] || fail "no comparison tool"
for t in test_logkit_wifi_leave_runtime.sh test_capture_compare_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix153 contract"
) || exit 1
# ---- fix154 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix154: $*"; exit 1; }
H="$ROOT/webroot/index.html"
grep -q '^  --page-fade-in: 0.26s;$' "$H" || fail "no fade timing"
grep -q 'translateX(-50%) translateX(120%)' "$H" && fail "pages still slide in from the right"
grep -q '^  audio_remove_volume_limit:APPLY_REBOOT,$' "$H" || fail "the limiter card still claims to apply at once"
grep -q "resetprop -n audio.safemedia.bypass true'" "$H" || fail "the limiter switch does not set the bypass"
grep -q '^LIGHT_HOLD_MAX_S="${ASB_LTE_LIGHT_HOLD_MAX_S:-2400}"$' "$ROOT/runtime/asb_lte_screenoff.sh" || fail "no growing 5G hold"
grep -q 'T_A_LIMIT_ON=' "$ROOT/action.sh" || fail "action screen does not show the limiter"
grep -q 'ASB_DOZE_KEEP:-/data/adb/asb/doze_whitelist_keep' "$ROOT/service.sh" || fail "background trim ignores the keep list"
for t in test_lte_light_flap_runtime.sh test_keep_list_guards_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
echo "PASS: fix154 contract"
) || exit 1
# ---- fix155 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix155: $*"; exit 1; }
H="$ROOT/webroot/index.html"
grep -q "opts:\['off','all','speaker','wired','bt','speaker+wired','speaker+bt','wired+bt'\], name:'DSP Outputs'" "$H" || fail "DSP Outputs has no off"
grep -q '^_dsp_out_off=0$' "$ROOT/runtime/asb_audio_apply.sh" || fail "the applier does not know DSP Outputs = off"
grep -q '_dspp inactive_reason "outputs_off"' "$ROOT/runtime/asb_audio_apply.sh" || fail "DSP Outputs = off does not record why the DSP is off"
grep -q "{ key:'audio_resampler', type:'seg', def:'stock', stock:'stock', opts:\['stock','high','max'\]" "$H" || fail "no resampler card"
grep -q "{ key:'media_vol_steps', type:'range', def:'stock', stock:'stock'" "$H" || fail "no volume steps card"
grep -q '^  audio_resampler:APPLY_REBOOT,$' "$H" || fail "the resampler card does not ask for a reboot"
grep -q '^  media_vol_steps:APPLY_REBOOT,$' "$H" || fail "the volume steps card does not ask for a reboot"
for k in audio_resampler media_vol_steps; do
  grep -q "^$k=stock$" "$ROOT/config/governor.conf" || fail "$k not shipped as stock"
  grep -q "^$k|advanced|webui_sensitive$" "$ROOT/config/key_ownership.tsv" || fail "$k has no owner"
  [ "$(grep -c " $k " "$ROOT/common/install.sh")" -ge 2 ] || fail "$k is not carried over on update"
done
grep -q 'resetprop -n ro.config.media_vol_steps "$_mv_st"' "$ROOT/post-fs-data.sh" || fail "volume steps are not set before Android starts"
grep -q 'resetprop -n ro.audio.resampler.psd.stopband "$_rs_sb"' "$ROOT/post-fs-data.sh" || fail "the resampler is not set before Android starts"
grep -q 'cyr = re.compile' "$ROOT/tools/asb_lint.sh" || fail "lint does not catch Cyrillic in other languages"
for t in test_dsp_outputs_off_runtime.sh test_audio_prop_tweaks_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix155 contract"
) || exit 1
# ---- fix156 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix156: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q 'fsm->state >= ASB_STATE_LIGHT_IDLE && fsm->state <= ASB_STATE_SUSTAINED &&' "$G" || fail "parity still limited to light idle and moderate"
grep -q 'g_cpu_policy_ids\[2\] < 0 && m->misc.screen_on && !fsm->thermal_cap &&$' "$G" || fail "parity gate changed beyond the trim"
grep -q 'trim <= 0' "$G" && fail "a thermal budget trim still turns parity off"
grep -q 'main_parity_cooling=%d' "$G" || fail "state does not say the raise is held while cooling"
grep -q 'main_parity_cool_lifts' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report cooling raises"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
grep -q 'warm (surface 40 C and above), %d samples:' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "the capture report has no warm split"
grep -q '"warm_below_pct"' "$ROOT/tools/asb_capture_compare.py" || fail "the comparison does not read the warm split"
grep -q '"warm_below_pct"' "$ROOT/docs/field_baseline/fix150.json" || fail "the fix150 baseline has no warm figures"
for t in test_main_capacity_parity_runtime.sh test_capture_compare_warm_runtime.sh test_logkit_cluster_wakelock_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
echo "PASS: fix156 contract"
) || exit 1
# ---- fix158 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix158: $*"; exit 1; }
Z="$ROOT/runtime/asb_doze_apply.sh"
grep -q '^_doze_night_window() {$' "$Z" || fail "the night window is not one shared function"
grep -q '^_doze_off_restore() {$' "$Z" || fail "the day path still withdraws the ticked apps' exemptions"
grep -q '^asb_doze_keep_grants() {$' "$Z" || fail "no grant routine of its own"
grep -q 'echo "window=$_in_night"' "$Z" || fail "list does not say whether the sleep window is open"
grep -q 'asb_doze_restore_whitelist' "$Z" || fail "trim off no longer restores everything"
H="$ROOT/webroot/index.html"
grep -q 'id="dozeKeepLegend"' "$H" || fail "the picker does not explain its labels"
grep -q "doze_tag_back" "$H" || fail "a ticked trimmed app does not say it comes back"
for t in test_doze_night_keep_runtime.sh test_webui_doze_keep_tags_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
echo "PASS: fix158 contract"
) || exit 1
# ---- fix159 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix159: $*"; exit 1; }
S="$ROOT/service.sh"; H="$ROOT/webroot/index.html"; A="$ROOT/runtime/asb_audio_activity.sh"
[ -f "$A" ] || fail "no audio activity reader"
grep -q '. "$MODDIR/runtime/asb_audio_activity.sh"' "$S" || fail "the route watcher does not load the activity reader"
grep -q 'if \[ "$_so" -lt 12 \]; then _wake=1; _iv=5; continue; fi' "$S" || fail "screen on is not noticed inside the screen-off nap"
grep -q '\[ "$(getprop persist.asb.dsp.route 2>/dev/null)" = "$_now" \] && continue' "$S" || fail "an overwritten route is never republished"
grep -q 'route lag: music is on' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show a lagging DSP route"
grep -q 'SEC "11. YOUR SETTINGS vs WHAT IS LIVE' "$ROOT/tools/asb_diag.sh" || fail "asbdiag has no settings-vs-live summary"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
grep -q 'governor.boot.conf' "$ROOT/post-fs-data.sh" || fail "the config this boot used is not kept"
[ "$(grep -c "addEventListener('popstate'" "$H")" = 1 ] || fail "back is handled twice"
grep -q '^const NAV_OVERLAYS = \[' "$H" || fail "no in-page back navigation"
grep -q 'id="bnDrainStrip"' "$H" || fail "Smart card has no screen-on/off drain"
grep -q 'html\[data-asb-theme="light"\] .live-cell-value { color:var(--text) !important; }' "$H" || fail "Monitor values are green in the light theme"
grep -q '## status bar redraw settings' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "captures do not record the status-bar redraw settings"
for t in test_dsp_route_wake_runtime.sh test_asbdiag_settings_summary_runtime.sh test_webui_back_nav_runtime.sh test_logkit_sysui_redraw_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
echo "PASS: fix159 contract"
) || exit 1
# ---- fix160 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix160: $*"; exit 1; }
H="$ROOT/webroot/index.html"; G="$ROOT/src/asb_governor.c"
grep -q 'asb_core_set_width' "$ROOT/src/DSP_AIDL/asb_dsp_core.h" || fail "no stereo width stage in the DSP core"
grep -q "{ key:'dsp_width', type:'range'" "$H" || fail "no Stereo Width card"
grep -q '^dsp_width=0$' "$ROOT/config/governor.conf.shipped" || fail "dsp_width not shipped off"
grep -q '^dsp_width|advanced|' "$ROOT/config/key_ownership.tsv" || fail "dsp_width not registered"
grep -q '_dspp width "$_wdx"' "$ROOT/runtime/asb_audio_apply.sh" || fail "width not published"
grep -q "{ key:'media_vol_steps', type:'range', def:'stock', stock:'stock', stockAt:15, min:15, max:100, step:5" "$H" || fail "media volume steps is not a slider"
grep -q 'if \[ "$_mv_st" -ge 16 \] && \[ "$_mv_st" -le 100 \]' "$ROOT/post-fs-data.sh" || fail "slider values are not applied"
grep -q 'asb_trend_body_cool' "$G" || fail "trend trims still fire on a cool body"
grep -q 'ASB_CEIL_OVER_OWN' "$G" || fail "ASB's own lifts still read as vendor raises"
for l in ar de es fr hy id it pt ru tr uk zh; do grep -q '^T_A_WIDTH=' "$ROOT/runtime/i18n/action_$l.sh" || fail "action_$l lacks T_A_WIDTH"; done
for t in test_dsp_stereo_width_runtime.sh test_smart_trend_cool_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
echo "PASS: fix160 contract"
) || exit 1
# ---- fix161 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix161: $*"; exit 1; }
H="$ROOT/webroot/index.html"
[ -f "$ROOT/runtime/asb_drain_meter.sh" ] || fail "no profile-independent drain meter"
grep -q 'runtime/asb_drain_meter.sh" run' "$ROOT/service.sh" || fail "the meter is not started"
[ -f "$ROOT/tools/asb_tree_check.sh" ] || fail "no tree check"
[ -s "$ROOT/tools/asb_tree.sha256" ] || fail "no delivered-tree manifest"
grep -q 'data-i18n="lv_slot_heat"' "$H" || fail "the usual-peak tile is still a bare temperature"
grep -q 'class="cfg-reboot-row"' "$H" || fail "restarts are still three full-width bars"
grep -q '^	    ui_print "      + ${ASB_SEC_AUDIO:-AUDIO}: ${ASB_I_HP_LIMIT' "$ROOT/common/install.sh" || fail "the headphone limiter is still a warning"
grep -q 'берегите слух' "$ROOT/common/russiantext.sh" && fail "the hearing warning text is still there"
for t in test_drain_meter_runtime.sh test_tree_check_runtime.sh test_webui_monitor_compact_runtime.sh; do asb_has_test "$t" || fail "$t missing"; done
echo "PASS: fix161 contract"
) || exit 1
# ---- fix162 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix162: $*"; exit 1; }
H="$ROOT/webroot/index.html"
grep -q 'top: -8px' "$H" && fail "a chip is still pinned to the card border"
grep -q '🤖 Bucket' "$H" && fail "the Smart card still has untranslated labels"
grep -q "batteryStatus !== 'discharging' &&" "$H" || fail "Stock can still read an explicit Discharging as charging"
asb_has_test test_webui_monitor_card_head_runtime.sh || fail "test_webui_monitor_card_head_runtime.sh missing"
echo "PASS: fix162 contract"
) || exit 1
# ---- fix163 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix163: $*"; exit 1; }
H="$ROOT/webroot/index.html"
grep -q 'id="liveTopSecLabel"' "$H" || fail "the Monitor has no section title over its card"
grep -q 'class="smart-banner-head"' "$H" && fail "the card still carries a title row"
grep -q '<span id="liveEtaOn">' "$H" || fail "time to empty is not under the drain figure"
grep -q 'id="bnBasis"' "$H" || fail "the Smart card does not say what it leans on"
grep -q "function lvEtaPaint()" "$H" || fail "no single owner for the time to empty"
asb_has_test test_webui_monitor_card_head_runtime.sh || fail "test_webui_monitor_card_head_runtime.sh missing"
echo "PASS: fix163 contract"
) || exit 1
# ---- fix164 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix164: $*"; exit 1; }
[ "$(find "$ROOT/tests" -type f -name 'asb_*.sh' | wc -l)" -eq 4 ] || fail "the host tests are not the four suites"
asb_has_test test_suite_runner_runtime.sh || fail "suite runner test missing"
grep -q 'extra: ' "$ROOT/tools/asb_tree_check.sh" || fail "the tree check does not name leftover files"
echo "PASS: fix164 contract"
) || exit 1
# ---- fix165 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix165: $*"; exit 1; }
H="$ROOT/webroot/index.html"
grep -q '^#define ASB_CFG_MAX_KEYS 512$' "$ROOT/src/asb_config.h" || fail "the config reader still stops at 192 keys"
asb_has_test test_config_shipped_load_runtime.sh || fail "no host test loads the shipped governor.conf"
grep -q "governor accepted governor.conf" "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not check that the governor took the config"
grep -q 'T_CFG_REFUSED' "$ROOT/action.sh" || fail "the action screen does not say when the config was refused"
grep -q 'Charging|Full) return 0 ;;' "$ROOT/runtime/asb_drain_meter.sh" || fail "the drain meter still reads an Unknown status as charging"
grep -q 'T_CPR_FLOOR' "$ROOT/action.sh" || fail "the action screen still prints the prime wish instead of the written ceiling"
grep -q '^\.page:not(\.live-page) > \.header { margin-bottom: 22px; }$' "$H" || fail "Home's section title sits lower than Monitor's and Settings'"
grep -q '^\.live-page \.live-top-sec, \.config-page \.header + \.sec { margin-bottom: 12px !important; }$' "$H" || fail "title-to-content gap differs between pages"
[ "$(grep -c '^\.live-page \.sec {' "$H")" = 2 ] || fail "a duplicate Monitor section rule is back"
echo "PASS: fix165 contract"
) || exit 1
# ---- fix166 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix166: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q '^static int asb_therm_keepalive_due(time_t now, time_t last_read, int cooldown) {$' "$G" || fail "deep idle can still go hours without a temperature"
asb_has_test test_thermal_keepalive_runtime.sh || fail "thermal keepalive test missing"
grep -q '^static void asb_night_wake_confirm(void) {$' "$G" || fail "the night window still learns single screen-offs"
asb_has_test test_night_window_chain_runtime.sh || fail "night window chain test missing"
grep -q 'asb_unlock_gate_die(metrics.therm.cpu_max_c,' "$G" || fail "the unlock lift still judges warm on the wake burst alone"
grep -q 'temperature reading   : ' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show how old the temperature is"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag is stale"
echo "PASS: fix166 contract"
) || exit 1
# ---- fix167 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix167: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
asb_has_test test_session_lifecycle_runtime.sh || fail "session lifecycle test missing"
grep -q '^static void persistent_stats_screen_off(const asb_fsm_t \*fsm) { persistent_stats_save_ex(fsm, 0); }$' "$G" || fail "screen-off still runs the full stats save"
[ "$(grep -c 'persistent_stats_screen_off(&fsm);' "$G")" = 2 ] || fail "both screen-off paths must keep only the context"
[ "$(grep -c 'lk_night_chain ' "$ROOT/tools/logkit/asb_log_full_day.sh")" -ge 2 ] || fail "the night row and the night verdict must both chain the phases"
echo "PASS: fix167 contract"
) || exit 1
# ---- fix168 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix168: $*"; exit 1; }
H="$ROOT/webroot/index.html"
grep -Fq "const notTemp = /trip|bcl|lvl|limit|ibat|vbat|socd/i;" "$H" || fail "Stock can read a 95 C trip point as the CPU temperature"
asb_has_test test_webui_stock_monitor_runtime.sh || fail "Stock monitor test missing"
asb_has_test test_webui_live_info_runtime.sh || fail "live tile explanation test missing"
asb_has_test test_webui_fill_pages_runtime.sh || fail "page fill test missing"
asb_has_test test_profile_net_reassert_runtime.sh || fail "network re-assert test missing"
asb_has_test test_webui_device_font_runtime.sh || fail "device font test missing"
grep -q 'runtime/asb_net_apply.sh' "$ROOT/runtime/asb_stock_policy.sh" || fail "Stock leaves the user's queue discipline at the restored baseline"
echo "PASS: fix168 contract"
) || exit 1
# ---- fix169 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix169: $*"; exit 1; }
asb_has_test test_comfort_burst_hold_runtime.sh || fail "comfort burst hold test missing"
asb_has_test test_asbdiag_stock_governor_runtime.sh || fail "asbdiag governor lookup test missing"
asb_has_test test_action_stock_header_runtime.sh || fail "action Stock header test missing"
asb_has_test test_eta_slot_meter_runtime.sh || fail "slot-to-meter forecast test missing"
asb_has_test test_webui_option_labels_runtime.sh || fail "option label test missing"
grep -q "awk -F= 'tolower(\$1) ~ /network_speed" "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "status-bar settings are matched on their values again"
grep -q "pgrep -f '/bin/asb\$'" "$ROOT/tools/asb_verify_device.sh" || fail "verify_device looks for a process name the governor does not have"
echo "PASS: fix169 contract"
) || exit 1
# ---- fix177 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix177: $*"; exit 1; }
for t in test_stock_switch_fast_runtime.sh test_wakelock_netpath_fgs_runtime.sh test_wakelock_fitness_status_runtime.sh \
         test_logkit_stock_battery_row_runtime.sh test_webui_live_info_runtime.sh test_webui_stock_monitor_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
[ -f "$ROOT/runtime/asb_rom_telemetry.sh" ] || fail "no builtin-read ROM snapshot for the Stock Monitor"
grep -q '^asb_stock_enter_fast() {' "$ROOT/runtime/asb_stock_policy.sh" || fail "Stock still restores every setting inside the WebUI call"
grep -q '^run_stock_finish() {' "$ROOT/apply_profile.sh" || fail "no background settings pass for Stock"
grep -q 'fitness-status' "$ROOT/runtime/asb_wakelock_watch.sh" || fail "the watcher does not answer the fitness badge"
grep -q 'function lviFill(t) {' "$ROOT/webroot/index.html" || fail "sheet texts still carry their own value lists"
grep -q 'asb_tree_check' "$ROOT/.github/workflows/build-test.yml" && fail "CI still annotates the tree differences"
echo "PASS: fix177 contract"
) || exit 1
# ---- fix178 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix178: $*"; exit 1; }
for t in test_drain_meter_runtime.sh test_asbdiag_wake_paths_runtime.sh test_bt_lifecycle_recorder_contract.sh \
         test_native_crash_names_runtime.sh test_asbdiag_report_host_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
grep -q 'DM_GLANCE_S=' "$ROOT/runtime/asb_drain_meter.sh" || fail "a glance at the clock ends the screen-off window again"
grep -q '\[ "\$dm_prev_scr" = 0 \] || _aa_prev=""' "$ROOT/runtime/asb_drain_meter.sh" || fail "the audio probe carries the screen-on activity into screen-off"
grep -q '^lk_bt_history_drops() {' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "the Bluetooth service history is not read back"
grep -q '<name>' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "AVRCP device names are not redacted"
grep -q 'BluetoothRemoteDevices:V' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "the ACL disconnect reason tag is not recorded"
grep -q '^lk_wifi_link() {' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "the network trace has no Wi-Fi link reader"
grep -q 'cmd wifi status' "$ROOT/tools/asb_diag.sh" || fail "asbdiag reads the Wi-Fi link from the first SSID in the dump again"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix178 contract"
) || exit 1
# ---- fix179 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix179: $*"; exit 1; }
for t in test_current_corroboration_runtime.sh test_logkit_screenoff_sleep_runtime.sh test_debug_support_contract.sh; do
  asb_has_test "$t" || fail "$t missing"
done
grep -q '^static float asb_current_corroboration_bar(float mod_thr, float quiet_floor) {' "$ROOT/src/asb_fsm.h" || fail "the current shortcut to MODERATE ignores the phone's idle load"
grep -q "grep 'AudioMix')" "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "AudioMix attribution credits every held lock again"
grep -q 'if(r>=600){' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "seconds of screen-off time are read as a night again"
echo "PASS: fix179 contract"
) || exit 1
# ---- fix180 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix180: $*"; exit 1; }
for t in test_logkit_energy_model_runtime.sh test_logkit_multicast_by_app_runtime.sh test_asbdiag_write_ratio_runtime.sh \
         test_asbdiag_wake_paths_runtime.sh test_logkit_capture_quality_contract.sh; do
  asb_has_test "$t" || fail "$t missing"
done
grep -q '^lk_energy_model_write() {' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "the capture does not record the CPU energy model"
grep -q 'Wi-Fi multicast by app' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "multicast holders are not named in the capture"
grep -q 'P "    writes per transition: $_wpt (8+ with little vendor contention' "$ROOT/tools/asb_diag.sh" && fail "asbdiag calls a high write ratio chattering again"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix180 contract"
) || exit 1
# ---- fix181 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix181: $*"; exit 1; }
for t in test_sustained_repeat_runtime.sh test_logkit_audiomix_summary_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
grep -q '^static void fsm_sustained_edges(asb_fsm_t \*fsm, time_t now) {' "$ROOT/src/asb_fsm.h" || fail "SUSTAINED edges are not recorded after the transitions"
grep -q 'case ASB_STATE_GAMING:     pct = 100; break;' "$ROOT/src/asb_fsm.h" || fail "GAMING keeps the last Smart prime cap on a 3/4-cluster part"
grep -q 'case ASB_STATE_DEEP_IDLE:' "$ROOT/src/asb_fsm.h" || fail "the screen-off prime is unmanaged again"
grep -q 'An unmanaged slot (0) is given back' "$ROOT/src/asb_writer.h" || fail "the writer keeps an old cap on an unmanaged slot"
grep -q 'sustained_repeat=%d' "$ROOT/src/asb_governor.c" || fail "sustained_repeat is not published"
echo "PASS: fix181 contract"
) || exit 1
# ---- fix182 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix182: $*"; exit 1; }
for t in test_shell_cap_owner_runtime.sh test_shell_caps_publish_runtime.sh test_logkit_shell_cap_reference_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
grep -q '^asb_shell_caps_publish() {' "$ROOT/service.sh" || fail "service.sh does not record the manual-profile caps"
grep -q '^static inline const char \*cap_source_classify_shell(' "$ROOT/src/asb_governor.c" || fail "no classification against the shell's own ceiling"
grep -q 'shell_mode ? "shell" : "governor"' "$ROOT/src/asb_governor.c" || fail "the ceiling watch does not say whose cap it compared with"
grep -q '_lc_foreign="$_lc_vendor"' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "the ownership verdict counts the shell as foreign"
grep -q 'cap profile/effective' "$ROOT/tools/asb_diag.sh" || fail "asbdiag compares manual caps with the governor rail"
grep -q 'cap_writer' "$ROOT/docs/log_schemas.md" || fail "cap_writer undocumented"
awk '/int manual_cap_skip = /{on=1} on && /msm_perf_release\(\);/{rel=NR} on && /goto skip_cpu_caps;/{print (rel ? "ok" : "no"); exit}' "$ROOT/src/asb_writer.h" | grep -qx ok || fail "a manual profile keeps ASB's msm_performance registration after HEAVY/SUSTAINED"
grep -q 'if (state != ASB_STATE_HEAVY && state != ASB_STATE_GAMING && state != ASB_STATE_SUSTAINED)' "$ROOT/src/asb_writer.h" || fail "the msm release does not wait for the anti-clamp states to end"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix182 contract"
) || exit 1
# ---- fix183 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix183: $*"; exit 1; }
for t in test_shell_cap_owner_runtime.sh test_shell_caps_publish_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
grep -q '^asb_shell_caps_precompute() {' "$ROOT/service.sh" || fail "the manual rungs are not precomputed"
grep -q '^asb_manual_cap_pct() {' "$ROOT/service.sh" || fail "the per-device percentages are not shared by the precompute"
grep -q 'asb_shell_caps_precompute "$_dev"' "$ROOT/service.sh" || fail "apply_screen_aware_caps does not refresh the records"
grep -q '^static int writer_manual_handback(int profile_idx, asb_state_t state) {' "$ROOT/src/asb_writer.h" || fail "no hand-back of governor-written manual ceilings"
grep -q 'static int s_writer_prof_seen = -1;' "$ROOT/src/asb_writer.h" || fail "a switch into a manual profile does not put its ceilings in"
grep -q 'g_fsm_cooldown_active = _cool_active;' "$ROOT/src/asb_fsm.h" || fail "the cooldown is not visible to the writer"
grep -q 'battery|balanced) asb_feature_enabled CPU && apply_screen_aware_caps ;;' "$ROOT/runtime/asb_reconcile.sh" || fail "the fallback reconcile loop ignores a switch into a manual profile"
grep -q '/dev/.asb/shell_cpu_caps.battery' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "the capture does not carry the precomputed records"
grep -q 'manual-profile cap records' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not list the records"
grep -q 'shell_cpu_caps.battery' "$ROOT/docs/log_schemas.md" || fail "the records are undocumented"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix183 contract"
) || exit 1
# ---- fix184 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix184: $*"; exit 1; }
asb_has_test test_smart_records_runtime.sh || fail "test_smart_records_runtime.sh missing"
[ -f "$ROOT/src/asb_record.h" ] || fail "asb_record.h missing"
grep -q '#define ASB_REC_CC_PATH     "/sys/class/power_supply/battery/charge_counter"' "$ROOT/src/asb_record.h" || fail "the records do not measure with the charge counter"
grep -q 'asb_rec_save() == 0) asb_log("smart records flushed on shutdown");' "$ROOT/src/asb_governor.c" || fail "records not flushed on shutdown"
grep -q '_ri.idle_state = (fsm.state == ASB_STATE_DEEP_IDLE && _rq_quiet &&' "$ROOT/src/asb_governor.c" || fail "screen-off quiet flag has no hysteresis / ignores the detente"
grep -q 'smart_records.bin' "$ROOT/runtime/asb_smart_reset.sh" || fail "the Smart reset keeps the records"
grep -q '^lk_emit_smart_records() {' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "no SMART RECORDS section in the full-day report"
grep -q 'Smart records        :' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show the records"
grep -q 'smart_records.txt' "$ROOT/docs/log_schemas.md" || fail "records undocumented"
for k in smart_records smart_records_explore smart_microwake; do
  grep -q "^$k=1$" "$ROOT/config/governor.conf" || fail "$k not shipped on"
  grep -q "^$k|internal|" "$ROOT/config/key_ownership.tsv" || fail "$k not registered"
  grep -q "\"$k\"" "$ROOT/src/asb_config.h" || fail "$k not parsed"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix184 contract"
) || exit 1
# ---- fix185 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix185: $*"; exit 1; }
asb_has_test test_smart_records_runtime.sh || fail "test_smart_records_runtime.sh missing"
asb_has_test test_smart_smoothness_runtime.sh || fail "test_smart_smoothness_runtime.sh missing"
grep -q '#define ASB_SMART_VER         5' "$ROOT/src/asb_smart_defs.h" || fail "Smart engine is not V5"
grep -q 'if (st->version >= ASB_SMART_VER_KEEP) {' "$ROOT/src/asb_smart.h" || fail "a V4 store would lose what it learned"
grep -q '#define ASB_REC_VERSION     2' "$ROOT/src/asb_record.h" || fail "records store version"
grep -q 'static void asb_rec_pair(asb_rec_ctx_t \*c, int slot, const asb_rec_last_t \*me) {' "$ROOT/src/asb_record.h" || fail "no side-by-side pairing"
grep -q 'double mw = ma \* v;' "$ROOT/src/asb_record.h" || fail "records not measured as power"
grep -q 'if (climate) { asb_rec_reject(REJ_CLIMATE); return; }' "$ROOT/src/asb_record.h" || fail "no climate rejection"
grep -q 'in->unplug_age_s < ASB_REC_SETTLE_S' "$ROOT/src/asb_record.h" || fail "no settle time after the charger"
grep -q 's->drain_pctph_x10 >= 0 && !s->climate);' "$ROOT/src/asb_smart.h" || fail "the bucket learner still takes drain the climate explains"
grep -q 'sin.climate = _cl ? 1 : 0;' "$ROOT/src/asb_governor.c" || fail "the session climate flag is never set"
grep -q 'if (g_asb_cfg.smart_cold_guard && !charging && battery_pct >= 0 && battery_pct < 40 &&' "$ROOT/src/asb_governor.c" || fail "no cold guard"
[ -f "$ROOT/runtime/asb_gfx_probe.sh" ] || fail "no frame-statistics probe"
grep -q 'dumpsys graphicsstats' "$ROOT/runtime/asb_gfx_probe.sh" || fail "the probe does not read graphicsstats"
grep -v '^[[:space:]]*#' "$ROOT/runtime/asb_gfx_probe.sh" | grep -q 'gfxinfo' && fail "the probe must not call into the app (gfxinfo)"
grep -q 'snprintf(disp, sizeof(disp), "app %016llx", (unsigned long long)h);' "$ROOT/src/asb_governor.c" || fail "the smoothness log names apps in plaintext in release builds"
for k in smart_smooth smart_cold_guard; do
  grep -q "^$k=1$" "$ROOT/config/governor.conf" || fail "$k not shipped on"
  grep -q "^$k=1$" "$ROOT/config/governor.conf.shipped" || fail "$k not in the shipped config"
  grep -q "^$k|internal|" "$ROOT/config/key_ownership.tsv" || fail "$k not registered"
  grep -q "\"$k\"" "$ROOT/src/asb_config.h" || fail "$k not parsed"
done
grep -q "smart_cold'" "$ROOT/webroot/index.html" || fail "the WebUI does not show the cold guard"
grep -q '"smart_cold":' "$ROOT/webroot/i18n/ru.json" || fail "cold guard untranslated"
grep -q 'smoothness           :' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show the smoothness check"
grep -q "grep '^smooth|'" "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "the full-day report does not show the smoothness check"
grep -q 'asb_gfx_probe.sh' "$ROOT/docs/log_schemas.md" || fail "probe undocumented"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix185 contract"
) || exit 1
# ---- fix186 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix186: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; W="$ROOT/src/asb_writer.h"; A="$ROOT/action.sh"
asb_has_test test_msm_final_ceiling_runtime.sh || fail "test_msm_final_ceiling_runtime.sh missing"
asb_has_test test_webui_smart_basis_runtime.sh || fail "test_webui_smart_basis_runtime.sh missing"
grep -q 'msm_perf_write_caps(msm_c0, msm_c1, msm_c2);' "$W" || fail "msm_performance still gets the raw ceiling"
grep -q 'g_drain_rs_drop_x100 = g_drain_rs_drop_x100 \* 3 / 4 + g_smart_drain_drop_x100;' "$G" || fail "recent drain is not a ratio of sums"
grep -q 'if (sin.drain_pctph_x10 > 0) {' "$G" && ! grep -q 'g_smart_drain_rate_ewma_x10 = (int)r;' "$G" && fail "recent drain still averages only sessions with a step"
grep -q 'if (screen_on && _app_prev_on == 0) g_smart_rt.app_cache_last_refresh = 0;' "$G" || fail "the app in front is not re-read on wake"
awk '/^static void asb_smooth_probe_tick/,/^}/' "$G" | grep -q 'g_smooth_probe_ts = 0;' && fail "the smoothness probe still runs out of turn"
grep -q '"headroom_real_pct=%d\\n"' "$G" || fail "headroom_real_pct not in the state"
grep -q '_g_head="$(_st headroom_real_pct)"' "$A" || fail "action shows a different headroom than the Monitor"
grep -q '\[ "$_l_dwin" -lt 600 \]' "$A" || fail "action prints an unproven drain-now figure"
grep -q '#define ASB_REC_T2              6.25' "$ROOT/src/asb_record.h" || fail "records verdict threshold"
grep -q 'rec_ctx=%s' "$G" || fail "records situation not published"
grep -q 'const _b = lvBasisPaint(kv, fb, dp, we, conf, night, veto);' "$ROOT/webroot/index.html" || fail "Basis tile"
for l in ar de es fr hy id it pt ru tr uk zh; do
  grep -q '^T_HEADROOM=".*thermal\|^T_HEADROOM="тепловой' "$ROOT/runtime/i18n/action_$l.sh" && fail "$l: headroom still called thermal"
done
grep -q 'asb_msm' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "the capture blames the vendor for ASB's msm registration"
grep -q 'asb_msm' "$ROOT/docs/log_schemas.md" || fail "asb_msm undocumented"
echo "PASS: fix186 contract"
) || exit 1
# ---- fix187 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix187: $*"; exit 1; }
H="$ROOT/webroot/index.html"; L="$ROOT/runtime/asb_lsposed.sh"
asb_has_test test_lsposed_verbose_runtime.sh || fail "test_lsposed_verbose_runtime.sh missing"
asb_has_test test_webui_home_offdrain_runtime.sh || fail "test_webui_home_offdrain_runtime.sh missing"
asb_has_test test_webui_navbar_profiles.sh || fail "test_webui_navbar_profiles.sh missing"
asb_has_test test_webui_lsposed_badge_runtime.sh || fail "test_webui_lsposed_badge_runtime.sh missing"
[ -f "$ROOT/src/asb_lspd.h" ] && [ -f "$L" ] || fail "LSPosed switch missing"
grep -q '#include "asb_lspd.h"' "$ROOT/src/asb_governor.c" || fail "the binary does not carry the LSPosed helper"
grep -q 'dlopen(libs\[i\], RTLD_NOW)' "$ROOT/src/asb_lspd.h" || fail "libsqlite is not opened at run time"
grep -q '^lsposed_verbose=keep$' "$ROOT/config/governor.conf" || fail "the switch must ship as keep"
grep -q '^lsposed_verbose|advanced|' "$ROOT/config/key_ownership.tsv" || fail "lsposed_verbose not registered"
grep -qE 'asb_lsposed\.sh"?[[:space:]]+(apply|restore|open)\b' "$ROOT/service.sh" "$ROOT/post-fs-data.sh" 2>/dev/null && fail "the LSPosed switch must never run at boot"
grep -q 'asb_lsposed' "$ROOT/post-fs-data.sh" 2>/dev/null && fail "the LSPosed sweep must not run in post-fs-data"
grep -q 'asb_lsposed.sh" restore' "$ROOT/uninstall.sh" || fail "uninstall leaves LSPosed changed"
grep -q 'asb_lsposed.sh' "$ROOT/docs/log_schemas.md" || fail "asb_lsposed.sh status undocumented"
grep -q '0f. LSPOSED LOGGING' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report LSPosed"
grep -q 'const off = homeOffFigure(prof);' "$H" || fail "home card does not use the shared screen-off rule"
grep -q '"nav_home": "Профили"' "$ROOT/webroot/i18n/ru.json" || fail "the first tab is not Profiles"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix187 contract"
) || exit 1
# ---- fix188 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix188: $*"; exit 1; }
asb_has_test test_asbdiag_msm_owner_runtime.sh || fail "test_asbdiag_msm_owner_runtime.sh missing"
asb_has_test test_boot_override_noop_runtime.sh || fail "test_boot_override_noop_runtime.sh missing"
grep -q '"msm_asb_hold=%d' "$ROOT/src/asb_governor.c" || fail "msm_performance ownership not published"
grep -q 'msm_asb_hold' "$ROOT/docs/log_schemas.md" || fail "msm_asb_hold undocumented"
grep -q 'if \[ "$_tm_cur" != "$_tm_ovr" \]' "$ROOT/service.sh" || fail "the boot pass rewrites an unchanged override flag"
grep -q '\[ "$(cat "$PREV" 2>/dev/null)" = off \] && rm -f "$PREV"' "$ROOT/runtime/asb_lsposed.sh" || fail "an already-off LSPosed log is still recorded as ASB's change"
grep -q 'shared browser code apps load for web pages, not a hook' "$ROOT/tools/asb_diag.sh" || fail "WebView crashes still blamed on a hook module"
grep -q 'smoothed: not formed yet' "$ROOT/tools/asb_diag.sh" || fail "a peak not formed yet reads as 0 C"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix188 contract"
) || exit 1
# ---- fix189 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix189: $*"; exit 1; }
for t in test_offdrain_by_profile_runtime.sh test_webui_monitor_manual_tiles_runtime.sh \
         test_asbdiag_lsposed_modlog_runtime.sh test_webui_home_offdrain_runtime.sh \
         test_shell_cap_owner_runtime.sh test_shell_caps_publish_runtime.sh test_drain_meter_runtime.sh; do
  asb_has_test "$t" || fail "$t missing"
done
grep -q 'g_shell_live.khz\[pol\] > 0)' "$ROOT/src/asb_writer.h" || fail "an empty shell record still hides the precomputed rung"
grep -q 'elif \[ -w "$_smax" \] && \[ "$(cat "$_smax" 2>/dev/null)" -le "$_want" \] 2>/dev/null; then _wok=1' "$ROOT/service.sh" || fail "a request held lower by a clamp is not recorded"
grep -q '"offdrain_by_profile="' "$ROOT/src/asb_governor.c" || fail "no per-profile screen-off figure"
grep -q 'function lvOffFigure(profile)' "$ROOT/webroot/index.html" || fail "no shared screen-off rule"
grep -q "if (_lvGovOff.x > 0) return" "$ROOT/webroot/index.html" && fail "a card borrows the phone-wide figure"
grep -q 'drain_meter.rej' "$ROOT/runtime/asb_drain_meter.sh" || fail "meter rejections not kept"
grep -q 'drain_meter.rej' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show meter rejections"
grep -q 'true > "$_f" 2>/dev/null && _freed=' "$ROOT/runtime/asb_lsposed.sh" || fail "LSPosed's current verbose logs are deleted, not emptied"
grep -q 'echo "modules_kib=' "$ROOT/runtime/asb_lsposed.sh" || fail "the modules log is not reported apart"
grep -q 'offdrain_by_profile' "$ROOT/docs/log_schemas.md" || fail "offdrain_by_profile undocumented"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix189 contract"
) || exit 1
# ---- fix190 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix190: $*"; exit 1; }
asb_has_test test_webui_monitor_binding_tiles_contract.sh || fail "test_webui_monitor_binding_tiles_contract.sh missing"
grep -q "if (kv.charging === '1') {" "$ROOT/webroot/index.html" || fail "the Basis tile says 'own slot' on the charger"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['lv_sessions_short']=='сес.'" "$ROOT/webroot/i18n/ru.json" || fail "session abbreviation"
echo "PASS: fix190 contract"
) || exit 1
# ---- fix191 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix191: $*"; exit 1; }
asb_has_test test_reassert_manual_ceiling_runtime.sh || fail "test_reassert_manual_ceiling_runtime.sh missing"
grep -q '^static int writer_reassert_target(int slot, int rail, asb_state_t state) {' "$ROOT/src/asb_writer.h" || fail "no reassert target"
grep -q 'ASB applies NO cap in performance' "$ROOT/tools/asb_diag.sh" && fail "asbdiag still says Performance has no ASB cap"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix191 contract"
) || exit 1
# ---- fix192 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix192: $*"; exit 1; }
asb_has_test test_webui_header_capsules.sh || fail "test_webui_header_capsules.sh missing"
grep -q -- '--cap-wash: linear-gradient(135deg, rgba(0,240,180,0.04), rgba(0,212,255,0.025));' "$ROOT/webroot/index.html" || fail "no shared capsule material"
[ "$(grep -c 'class="hdr-cap hdr-info"' "$ROOT/webroot/index.html")" -eq 5 ] || fail "not every page has the chip/version capsule"
grep -q '^function asbHeaderFit(force) {' "$ROOT/webroot/index.html" || fail "the island is never fitted"
echo "PASS: fix192 contract"
) || exit 1
# ---- fix196 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix196: $*"; exit 1; }
# The LTPO diagnostic read as corruption on two field devices.
grep -q 'min=%s original: %s' "$ROOT/runtime/asb_ltpo_apply.sh" || fail "ltpo range diagnostic still glues the recorded originals onto an empty min"
grep -q "printf 'max_mode=%s peak=%s min=%s recorded=%s" "$ROOT/runtime/asb_ltpo_apply.sh" && fail "the old glued recorded= format is back"
# The action sheet shows the same idle figure as the profile's card.
asb_has_test test_action_idle_per_profile_runtime.sh || fail "action idle per-profile test missing"
grep -q 'awk -F: -v p="$PROFILE"' "$ROOT/action.sh" || fail "action.sh does not pick the active profile's idle figure"
# The prime-ceiling label named the rail's ask "requested" - the writer's request is the
# floor-lifted value; all 12 locales carry the corrected wording with its %s intact.
for _l in "$ROOT"/runtime/i18n/action_*.sh; do
  grep -q '^T_CPR_FLOOR=' "$_l" || fail "${_l##*/} lacks T_CPR_FLOOR"
  [ "$(sed -n 's/^T_CPR_FLOOR=//p' "$_l" | grep -c '%s')" -eq 1 ] || fail "${_l##*/} T_CPR_FLOOR lost its %s"
done
grep -q 'T_CPR_FLOOR="эффективный минимум' "$ROOT/runtime/i18n/action_ru.sh" && fail "the misleading ru wording is back"
# OP12's uag/qcom-cpufreq-hw boosts the minimum on touches exactly like walt - a NOTE, not a WARN.
grep -q '\*scmi\*|\*walt\*|\*uag\*|\*qcom-cpufreq-hw\*)' "$ROOT/tools/asb_diag.sh" || fail "asbdiag still warns on a uag platform floor boost"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix196 contract"
) || exit 1
# ---- fix199 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix199: $*"; exit 1; }
# The build must not depend on CHANGELOG.md. The owner keeps the changelog by hand in his
# own repo; a stale or missing one must never fail a build. It did: the fix198 contract
# pinned "the changelog names fix198" and the CI run of a tree whose changelog lagged the
# code failed on exactly that, and lint warned "no section heading" on the same tree. Both
# are gone; nothing in the gates may read the changelog again. (The tree-check fixture's
# made-up temp file of the same name is a fixture, not a gate.)
_clpat='CHANGE''LOG'
grep -q "$_clpat" "$ROOT/tools/asb_lint.sh" && fail "lint still reads the changelog"
for _s in asb_smart asb_features asb_ui; do
  grep -q "$_clpat" "$ROOT/tests/$_s.sh" && fail "tests/$_s.sh still reads the changelog"
done
_clreal='$ROOT/CHANGE''LOG.md'
grep -qF "$_clreal" "$ROOT/tests/asb_system.sh" && fail "this suite still reads the real changelog"
grep -q "$_clpat" "$ROOT/tools/asb_full_regression.sh" && fail "the regression still reads the changelog"
# The changelog stays in the delivered tree and in the tree manifest - it is the owner's
# release notes, just never a build gate.
grep -q '  CHANGELOG.md$' "$ROOT/tools/asb_tree.sha256" || fail "the changelog fell out of the tree manifest"
echo "PASS: fix199 contract"
) || exit 1
# ---- fix210 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
T="$ROOT/tests/asb_smart.sh"
fail() { echo "FAIL fix210: $*"; exit 1; }
# Owner's report: FSM said GAMING on Balanced while he was scrolling a feed (GPU 57 %,
# load 7.1), the Monitor's thermal trend kept showing "...", the Monitor's drain tiles
# looked at odds with the log report's, and the wake section said "holders not recorded"
# while the capture plainly knew what woke the phone.
# 1) GAMING on the manual profiles: the foreground-package classification ran only inside
#    asb_smart_tick, so on Battery/Balanced/Performance the hint stayed 0 and the FSM
#    gate's "no package information" fallback (app_hint == 0 counts as agreement) fired
#    permanently - any busy GPU plus a busy CPU read as a game. asb_fg_classify_tick now
#    mirrors Smart's classification on the manual profiles (same detector, same media and
#    camera guards, same heat inference, same wake-edge re-read, plus a no-signal load
#    heuristic that never invents GAMING) and runs before BOTH app_hint publishes.
grep -q '^static void asb_fg_classify_tick' "$G" || fail "no manual-profile classification"
[ "$(grep -c 'asb_fg_classify_tick(&metrics, &fsm);' "$G")" -eq 2 ] || fail "must run before both app_hint publishes (startup and the main loop)"
grep -q 'if (g_smart_rt.enabled && g_smart_store_loaded) return;' "$G" || fail "Smart must keep owning the classification"
grep -q 't_fg_classify_manual_gaming_runtime' "$T" || fail "the manual-profile classification runtime test is gone"
# 2) Thermal trend: the verdict needs three samples over a 30 s span, and a recreated
#    WebView threw them away - on a real phone that is every visit. The samples and the
#    last verdict now persist in localStorage and survive a page reload (fresh to 115 s,
#    so the oldest restored sample still counts at the next 10 s read).
grep -qF "asb_stock_trend" "$H" || fail "the thermal trend lost its persistence"
# fix214: the reset-on-Stock must KEEP the trend, not drop it - the samples come from the
# ROM's own thermal zones and are profile-agnostic. Dropping them on every switch to Stock
# (and a profile switch is exactly when the Monitor gets opened) is what made the tile sit
# at "..." for half a minute after nearly every visit.
! grep -qF "localStorage.removeItem('asb_stock_trend')" "$H" || fail "the monitor reset drops the persisted trend again (fix214 keeps it)"
grep -qF 'x.t <= 115000' "$H" || fail "restored samples outlive the verdict span"
grep -qF 'd.l.t <= 600000' "$H" || fail "the last verdict is not restored beyond the sample window (fix214)"
# 3) Wake section: flat held-time counters hid the causes the capture already knew. The
#    digest now surfaces them - the top partial-wakelock holders by occurrence (wlt), the
#    top alarm/wakeup sources (wla), and the idle radio traffic (sradio) - and the sheet
#    renders them and names the loudest one in the awake tip instead of shrugging.
grep -qF 'printf "wlt\ttag=%s\tn=%d\n"' "$D" || fail "the digest lost the holder line"
grep -qF 'printf "wla\ttag=%s\tn=%d\n"' "$D" || fail "the digest lost the alarm line"
grep -qF 'printf "sradio\tmib=%.1f\n"' "$D" || fail "the digest lost the idle-radio line"
grep -qF "tag === 'wlt'" "$H" || fail "the report parser dropped the holder line"
grep -qF "tag === 'wla'" "$H" || fail "the report parser dropped the alarm line"
grep -qF 'lr_wlt_head' "$H" || fail "the holder rows are not rendered"
grep -qF 'lr_wla_head' "$H" || fail "the alarm rows are not rendered"
grep -qF 'lr_sradio' "$H" || fail "the idle-radio row is not rendered"
grep -qF 'lr_tip_awake_alarm' "$H" || fail "the awake tip never names the alarm"
grep -qF 'lr_tip_awake_hold' "$H" || fail "the awake tip never names the holder"
# 4) The drain tiles vs the report: not a bug - four different windows (the tiles count
#    only calm stretches of an hour or more, the report covers the whole capture), and the
#    sheet now says so right under the screen rows so the two pages stop looking at odds.
grep -qF 'lr_scr_note' "$H" || fail "the screen-rows reconciliation note is gone"
for _l in "$ROOT"/webroot/i18n/*.json; do
  for _k in lr_wlt_head lr_wla_head lr_times lr_sradio lr_tip_awake_alarm lr_tip_awake_hold lr_scr_note; do
    grep -q "\"$_k\"" "$_l" || fail "${_l##*/} lacks $_k"
  done
done
echo "PASS: fix210 contract"
) || exit 1
# ---- fix211 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
H="$ROOT/webroot/index.html"
U="$ROOT/tests/asb_ui.sh"
fail() { echo "FAIL fix211: $*"; exit 1; }
# Owner's suspicion, confirmed on three captures: "the Battery profile influences Smart".
# It did. Two leaks, both closed.
# 1) Session banking ran under a stale Smart flag. apply_profile.sh clears
#    smart_mode_enabled on a manual switch, but a live socket switch never re-read the
#    flag, and the banking gate checked the flag only - so a Battery/Balanced session
#    after a Smart session was banked into the Smart buckets the per-app records already
#    refused (they gate on fsm.profile_idx == PROFILE_SMART). The banking gate now checks
#    the profile too, and the profile-change handler re-syncs the in-memory flag.
grep -qF 'fsm->profile_idx == PROFILE_SMART' "$G" || fail "Smart session banking is not gated on the Smart profile"
grep -qF '_sf != g_smart_rt.enabled' "$G" || fail "a live profile switch never re-syncs the smart_mode_enabled flag"
# 2) The drain carry/reset lived INSIDE the banked block; gating the block on the profile
#    would have leaked the accumulators into the next Smart session. The unconditional
#    fallback after the block keeps every non-Smart session's drain accounting local.
grep -qF 'fix211: the drain carry and reset inside the block above' "$G" || fail "the non-Smart drain carry/reset fallback is gone"
# 3) The asbcost tip read ms/h against an absolute 2500 - on a busy day (3627 ms/h at
#    3.0 ms per wake, the normal per-wake price on every capture we have) it told the
#    owner to mail the developer. The tip now judges the per-wake price: cheap at or
#    under 8 ms a wake, high only above that, with the absolute figure kept for a
#    capture that has no wake count.
grep -qF '_msPerWake' "$H" || fail "the asbcost tip does not judge the per-wake price"
grep -qF 'a busy day at 3 ms a tick reads cheap' "$U" || fail "the per-wake cost tip is not exercised"
# 4) Noise gates from the same captures: a 5.2 %/h screen-off figure off 11 minutes and
#    an AOD verdict off 1 of 4 checks read red. The screen-off warn now needs 30+
#    minutes of off data, the AOD verdict needs 20+ checks before it can go red.
grep -qF '(+scr.off_min || 0) >= 30' "$H" || fail "the screen-off drain warns on sub-30-minute data"
grep -qF '(+aod.of || 0) >= 20' "$H" || fail "the AOD verdict can go red on a handful of checks"
echo "PASS: fix211 contract"
) || exit 1
# ---- fix212 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
W="$ROOT/src/asb_writer.h"
T="$ROOT/tests/asb_smart.sh"
fail() { echo "FAIL fix212: $*"; exit 1; }
# Owner's report: "подлагивания при открытии и сворачивании приложений и при разблокировке" on
# the Battery profile. The field evidence was already in the captures: an OP15 Battery day
# (17155) janked 32 % of SystemUI frames against 3.5-4.4 % on the Smart captures (18069,
# 30827). Root cause: the fix150 unlock lift was Smart-only, so on Battery/Balanced a wake or
# an app switch ran on the shell's static screen-on caps (OP15: 50/38 %) with WALT boost off.
# The lift now runs on every capped profile (Performance is never capped and skips), a
# foreground-app switch arms the same short window (once per 5 s, never extending a running
# lift), and the writer lets the borrowed ceilings through while it runs - marking the paths
# held (fix183) and handing the shell's values back when the window ends. The profiles' static
# values are UNTOUCHED: Battery stays Battery, the lift is a short ceiling-only burst.
grep -qF 'static int asb_unlock_lift_profile_ok(int profile_idx)' "$G" || fail "no profile gate"
grep -qF 'return profile_idx != PROFILE_PERFORMANCE;' "$G" || fail "the gate is not 'everyone but Performance'"
grep -qF '#define ASB_LAUNCH_LIFT_GAP_MS 5000L' "$G" || fail "no launch rate limit"
# fix220 merged the app switch into one arm with the tap and the lock press - the reason
# string must still name it.
grep -qF 'g_unlock_arm_why = touch_kick ? "touch" : (lock_kick ? "lock key" : "app switch");' "$G" || fail "no app-switch arm"
grep -qF 'g_unlock_arm_why = "screen on";' "$G" || fail "the wake arm lost its reason"
grep -qF 'static long g_launch_prev_hash = 0;' "$G" || fail "no foreground-hash baseline in the tick"
grep -qF 'uint64_t _fh = g_smart_rt.app_hash;' "$G" || fail "the launch kick does not read the foreground hash"
grep -qF '!g_fsm_cooldown_active && !g_unlock_lift_now;' "$G" || fail "the shell-ownership rule does not yield during the lift"
grep -qF 'const int manual_lift     = manual_profile && g_unlock_lift_now && !thermal_cap &&' "$W" || fail "the writer still clamps the borrowed ceilings"
grep -qF 'int manual_cap_skip = manual_profile && !manual_override && !manual_lift;' "$W" || fail "manual_cap_skip does not yield to the lift"
# The pinned fix183 line must survive verbatim next to the new flag.
grep -qF 'const int manual_override = manual_profile && (thermal_cap || g_fsm_cooldown_active);' "$W" || fail "the thermal/cooldown override line changed"
grep -qF 't_unlock_lift_runtime' "$T" || fail "the runtime test is not registered"
grep -qF 'Battery did not lift' "$T" || fail "Battery/Balanced lifts are not exercised"
grep -qF 'an app switch did not lift' "$T" || fail "the launch lift is not exercised"
grep -qF 'a switch during a running lift re-armed' "$T" || fail "the no-extend rule is not exercised"
grep -qF 'lift: the governor owns the ceilings' "$T" || fail "the ownership exclusion is not exercised"
echo "PASS: fix212 contract"
) || exit 1
# ---- fix213 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MP="$ROOT/module.prop"
UJ="$ROOT/update.json"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
DG="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL fix213: $*" >&2; exit 1; }
# Audit K1/K2 (fix215): the exact update.json<->module.prop identity check lives in the
# RELEASE pipeline now (.github/workflows/build-release.yml, step "Validate OTA manifest"),
# where it gates PUBLISHING. It must never gate BUILDING: this block ran in the always-run
# host suite, so any checkout whose metadata had not been bumped yet - a fork, a debug run,
# the owner's own repo between releases - failed CI on a metadata file, which is exactly
# "module.prop/update.json must not influence the build". What stays pinned here is only
# structural: (1) update.json exists and stays out of both flashable zips, (2) the release
# workflow still carries the manifest gate, so it cannot silently disappear.
[ -f "$UJ" ] || fail 'update.json missing at repo root'
grep -qF -- "--exclude 'update.json'" "$ROOT/.github/workflows/build-test.yml" || fail "the test build stopped excluding update.json"
grep -qF -- "--exclude 'update.json'" "$ROOT/.github/workflows/build-release.yml" || fail "the release build stopped excluding update.json"
grep -qF 'Validate OTA manifest (update.json)' "$ROOT/.github/workflows/build-release.yml" || fail "the release workflow lost the update.json manifest gate"
grep -qF '\"versionCode\": ${BASE_CODE}' "$ROOT/.github/workflows/build-release.yml" || fail "the release gate must compare versionCode against module.prop"
grep -qF '/releases/download/${MAJ}/' "$ROOT/.github/workflows/build-release.yml" || fail "the release gate must validate the zipUrl release dir"
# Audit K3: a profile's GPU intent is GPU_MAX_PCT alone. thermal_pwrlevel belongs to the
# vendor thermal engine - the governor reads it back as a vendor cap, so the profile's
# static level (battery 7, balanced/performance 2) looked like one and double-capped the
# GPU. Profiles carry the key no more; the shell releases a stale static level once per
# boot (the engine re-asserts it when it actually needs to cool the GPU).
for _p in "$ROOT"/profiles/*.sh; do
  grep -q 'GPU_THERMAL_PWRLEVEL' "$_p" && fail "profile still pins thermal_pwrlevel: $_p"
done
grep -c 'gpu_tpl_released' "$ROOT/runtime/profile_core.sh" | grep -q '^[0-9]' || fail "profile_core lost the stale-level release"
grep -qF 'gpu_tpl_released' "$ROOT/runtime/profile_core.sh" || fail "profile_core does not release a stale thermal_pwrlevel"
grep -qF 'gpu_tpl_released' "$ROOT/service.sh" || fail "service.sh does not release a stale thermal_pwrlevel"
grep -qF 'writef_retry "$_tpl" 0 2 0.06' "$ROOT/runtime/profile_core.sh" || fail "the release must write 0 (no cap), not another level"
grep -qF 'vendor thermal cap, read-only for us' "$ROOT/src/asb_writer.h" || fail "the writer lost the vendor-cap reading of the node"
# Audit K4: asbdiag probes the meter itself, not only the recorder's summary - a phone
# without a usable charge_counter used to stay silently blind (Smart V5 learns nothing).
grep -qF '/sys/class/power_supply/battery/charge_counter' "$DG" || fail "asbdiag does not probe the charge counter directly"
grep -qF 'smart meter' "$DG" || fail "asbdiag lost the smart meter line"
cmp -s "$DG" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
# Audit K8: the LSPosed answer names the serialization layout it parsed, so a future
# schema change shows up instead of failing silently.
grep -qF 'ASB_LSPD_FORMAT' "$ROOT/src/asb_lspd.h" || fail "the LSPosed answer does not name the schema"
grep -qF 'format=' "$ROOT/runtime/asb_lsposed.sh" || fail "the LSPosed status does not pass the schema through"
# Audit 8.1/8.2/8.3/8.8: the log report grew the device context, the capture history the
# trend reads from, the heat durations and the night habits. The runtime coverage (a
# fixture capture through the real digest, the parser and the tips in node, all 13
# locales) lives in t_webui_log_report_runtime - pin that it is registered and pins the
# new sections.
grep -qF "printf 'meta2" "$D" || fail "the digest emits no device context"
grep -qF 'printf "heat' "$D" || fail "the digest emits no heat detail"
grep -qF "printf 'mwake" "$D" || fail "the digest emits no night habits"
grep -qF 'report_history.tsv' "$D" || fail "the digest keeps no capture history"
grep -qF 'sustained_temp_mode' "$D" || fail "the advice snapshot lost the thermal switch"
grep -qF 'meta2' "$ROOT/tests/asb_ui.sh" || fail "the runtime test does not pin the device context"
grep -qF 'lr_tip_heat_warm' "$ROOT/tests/asb_ui.sh" || fail "the runtime test does not pin the heat advice"
grep -qF 'report_history.tsv' "$ROOT/tests/asb_ui.sh" || fail "the runtime test does not exercise the history"
grep -qF 'lr_sec_trend' "$ROOT/tests/asb_ui.sh" || fail "the runtime test does not pin the trend locale keys"
grep -qF 't_webui_log_report_runtime' "$ROOT/tests/asb_ui.sh" || fail "the report runtime test is not registered"
echo "PASS: fix213 contract"
) || exit 1
# ---- fix214 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
H="$ROOT/webroot/index.html"
TEL="$ROOT/runtime/asb_rom_telemetry.sh"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
fail() { echo "FAIL fix214: $*" >&2; exit 1; }
# Field report (fix212 build, OP15-class device): the FSM sat at HEAVY with two light apps
# open. Three causes, all pinned here.
# 1) bat_suppress_gaming landed on HEAVY INSTANTLY - one tick with the GPU past the gaming
#    gate (an app launch, a scroll fling) held HEAVY's looser rails for a whole ~48 s tick.
#    The suppression must keep Battery out of GAMING but reach HEAVY through the same
#    two-tick, CPU-backed gate as every other GPU-led escalation.
! grep -qE '^[[:space:]]+if \(g_asb_cfg\.bat_suppress_gaming && fsm_profile_is_battery\)$' "$F" || fail "bat_suppress_gaming is an instant HEAVY again"
grep -qF 'int suppress_gaming = (g_asb_cfg.bat_suppress_gaming && fsm_profile_is_battery);' "$F" || fail "the suppression flag is gone"
grep -qF 'if (!suppress_gaming &&' "$F" || fail "a suppressed game can still reach GAMING"
# 2) The "CPU participates" bars were fixed per-core constants (0.15/0.25 -> load1 1.2/2.0
#    on eight cores) calibrated on a phone idling near zero. OP15-class devices idle at
#    load1 6-9, so the bars were always true and every GPU flicker qualified. The gate is
#    the device's own learned quiet floor with the burst margin; the constants are the
#    pre-learning fallback.
grep -qF 'static int asb_cpu_participates(const asb_metrics_t *m, float per_core_fallback)' "$F" || fail "the floor-relative participation gate is gone"
[ "$(grep -c 'asb_cpu_participates(m,' "$F")" -ge 3 ] || fail "not every GPU-led gate uses the participation check"
grep -qF 'qf * (1.0f + (float)ASB_UI_BURST_MARGIN_PCT / 100.0f)' "$F" || fail "the participation gate does not use the quiet floor"
# 3) The Monitor answered the confusion with a share that made it worse: the load average
#    counts tasks waiting on storage, so "9.4 . 118%" showed an overload that was not
#    there. The tile now shows the real CPU-busy share between two /proc/stat readings;
#    the loadavg share moved to the tooltip.
grep -qF 'cpustat=' "$TEL" || fail "the ROM telemetry does not publish /proc/stat"
grep -qF '_stockCpuStatPrev' "$H" || fail "the WebUI does not derive the busy share"
grep -qF 'stock_load_busy' "$H" || fail "the busy share has no caption"
grep -qF "String(kv.cpustat || '')" "$H" || fail "the busy share does not read the telemetry line"
# The thermal trend survives a profile switch to Stock (ROM data, profile-agnostic) and
# the last verdict is restored for ten minutes, so the tile stops sitting at "..." after
# every Monitor visit.
! grep -qF "localStorage.removeItem('asb_stock_trend')" "$H" || fail "the Stock switch wipes the trend again"
grep -qF '_stockCpuStatPrev = null;' "$H" || fail "the busy-share state is declared nowhere"
# A running capture's elapsed time comes from the ledger and the clock, not from the
# interim report rewritten every fifteen minutes - the status line disagreed with the
# live sections below it by up to a quarter of an hour.
grep -qF '_el_live=' "$D" || fail "the digest lost the live elapsed time"
grep -qF 'recording · {min} min of {h} h' "$H" || fail "the report status line is gone"
echo "PASS: fix214 contract"
) || exit 1
# ---- fix216 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
TEL="$ROOT/runtime/asb_rom_telemetry.sh"
fail() { echo "FAIL fix216: $*" >&2; exit 1; }
# The CI debug build failed on a FLAKE, not on code: the device-font discovery filtered
# FULL PATHS with the family/exclusion tokens, and mktemp named the test's fixture dir
# "tmp.5wIeilzKrt" - the "kr" in the random suffix matched the Korean-face exclusion and
# emptied the whole list. On device the same shape silently drops a user font living in a
# directory named "kr"/"mono"/.... The patterns are anchored to the file name now; the
# runtime reproduction (a dir carrying the tokens) lives in tests/asb_ui.sh.
grep -qF 'grep -iE \"/[^/]*(syssans|oplussans|oneplussans|opsans)[^/]*$\"' "$H" || fail "the family match is not anchored to the file name"
grep -qF 'grep -viE \"/[^/]*(mono|cond|hans|hant|jp|kr|arab|thai|hebr|deva|beng|mya)[^/]*$\"' "$H" || fail "the CJK/variant exclusion is not anchored to the file name"
grep -qF 'grep -viE \"/[^/]*(emoji|mono|symbol)[^/]*$\"' "$H" || fail "the /data branch exclusion is not anchored to the file name"
grep -qF 'grep -iE \"syssans|' "$H" && fail "the unanchored family match is back"
grep -qF 'kr-mono-hans-cond-arab' "$ROOT/tests/asb_ui.sh" || fail "the token-dir reproduction is gone from the runtime test"
# Same class of noise in the telemetry script: `read ... < file 2>/dev/null` lets the shell
# report the missing input file on the ORIGINAL stderr (redirections apply left to right),
# which is where the CI log's "cannot open .../cpu/online" lines came from. The stderr
# redirect comes first now; the reads still answer empty on a missing file.
grep -qF 'read -r _on 2>/dev/null < "$SYS/devices/system/cpu/online"' "$TEL" || fail "the cpu/online read reports a missing file again"
grep -qF 'read -r _up _x 2>/dev/null < "$PROC/uptime"' "$TEL" || fail "the uptime read lost its redirect order"
grep -qF 'read -r _md 2>/dev/null < "$CACHE"' "$TEL" || fail "the settings-cache read lost its redirect order"
# ...and the settings-wrapper contract answers with awk's exit code, not a grep|grep pipe
# whose upstream dies with "write error: Broken pipe" three times per CI run.
grep -qF 'END { exit(1-f) }' "$ROOT/tests/asb_system.sh" || fail "the settings-wrapper scan is a SIGPIPE pipe again"
echo "PASS: fix216 contract"
) || exit 1
# ---- fix217 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL fix217: $*" >&2; exit 1; }
# Cosmetic: enabled tweak cards wear the hub-tile look. The row carries its cat-*
# class (single render site, cfgRenderRow), the category hue map feeds the icon AND
# the row, and the enabled card takes the tile's category gradient, border tint and
# glow - in both themes. The classless teal .cfg-row.is-on rules stay as the fallback
# for rows without a category.
grep -qF "row.className = 'cfg-row ' + cfgCatClass(it.key) + (isOn ? ' is-on' : '');" "$H" || fail "tweak rows lost their category class"
grep -qF ':is(.cfg-icon,.cfg-row).cat-audio' "$H" || fail "the hue map no longer feeds tweak rows"
grep -qF '.cfg-row.is-on[class*="cat-"] {' "$H" || fail "enabled cards lost the category rule"
grep -qF 'color-mix(in srgb, var(--cat, var(--accent)) 17%, transparent) 0%' "$H" || fail "enabled cards lost the hub-tile gradient"
grep -qF '0 4px 16px -8px color-mix(in srgb, var(--cat, var(--accent)) 55%, transparent)' "$H" || fail "enabled cards lost the category glow"
grep -qF 'html[data-asb-theme="light"] .cfg-row.is-on[class*="cat-"] {' "$H" || fail "the light enabled-card rule is gone"
grep -qF 'html[data-asb-theme="light"] .cfg-row.cat-audio   { --cat:#c0362c; }' "$H" || fail "light rows lost the deepened hues"
grep -qF 'color-mix(in srgb, var(--cat) 13%, #ffffff) 0%' "$H" || fail "light enabled cards lost the hub-tile tint"
echo "PASS: fix217 contract"
) || exit 1
# ---- fix218 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
fail() { echo "FAIL fix218: $*" >&2; exit 1; }
# A field capture's report named "Recording gap" the hottest phase of the day: a
# sub-two-minute screen-off pause happened to hold the peak reading and the heat block
# attributed the peak to it. The peak now goes to the hottest NAMED phase (gap minutes
# still count in the durations), the Hottest-phase row shows that phase's own peak
# temperature, and the phase table can no longer wrap the %/h unit onto its own line.
grep -qF 'if ($1 != "gap" && c > mcn) { mcn = c; mp = $1 }' "$D" || fail "a gap can be named the hottest phase again"
grep -qF 'peak_c=%d' "$D" || fail "the heat line lost the named phase's peak"
grep -qF "((+heat.peak_c || 0) > 0 ? ' · ' + String(+heat.peak_c) + '°' : '')" "$H" || fail "the hottest-phase row lost its peak temperature"
grep -qF ".replace(/\//g, '/\u2060');" "$H" || fail "the phase drain cell can orphan its unit again"
echo "PASS: fix218 contract"
) || exit 1
# ---- fix219 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
T="$ROOT/tests/asb_ui.sh"
fail() { echo "FAIL fix219: $*" >&2; exit 1; }
# A field capture's report said "Throttling periods: 16 (asb)" - for a day where the
# trace shows 3 ASB periods, 6 vendor, 6 shell and 1 unknown. The digest had counted
# the periods correctly but kept only the LAST period's owner, so whoever clamped last
# took the blame for the whole day. The throttle line now reports the dominant owner
# (the one with the most periods; the more recent wins a tie) and carries the full
# per-owner split as by=owner:n,...; the sheet names every owner in the clamp note.
# The runtime behaviour (the majority-owner fixture, the parser) is exercised in
# tests/asb_ui.sh:t_webui_log_report_runtime; here the structural pins.
sh -n "$D" || fail "digest script has a syntax error"
grep -qF 'cnt[o]++; last[o] = t' "$D" || fail "the digest no longer counts periods per owner"
grep -qF 'printf "throttle\tclamps=%d\towner=%s\tby=%s\n"' "$D" || fail "the throttle line lost the per-owner split"
grep -qF "const names = { asb: 'ASB', asb_governor: 'ASB', vendor: 'ROM', shell: 'profile', thermal: 'ROM thermal', unknown: '?' };" "$H" || fail "the sheet no longer names every throttle owner"
grep -qF "by.indexOf(',') > 0" "$H" || fail "the sheet ignores the per-owner split"
grep -qF 'by=asb_governor:1,thermal:1' "$T" || fail "the runtime fixture lost the per-owner split"
grep -qF 'clamps=3	owner=vendor	by=vendor:2,asb:1' "$T" || fail "the majority-owner fixture is gone"
echo "PASS: fix219 contract"
) || exit 1
# ---- fix220 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
T="$ROOT/tests/asb_ui.sh"
S="$ROOT/tests/asb_smart.sh"
fail() { echo "FAIL fix220: $*" >&2; exit 1; }
# ColorOS 17 / Android 17 on the OP15: animations at app open/close and at lock/unlock
# visibly janked on Smart and Battery. The app-switch arm (fix212) is seen on the next
# metrics tick - up to 2 s after the tap, past the animation's first frames - and the
# lock press had no arm at all. Two earlier signals now arm the same 3 s ceilings-only
# lift: the first touch after a calm spell (the tap that starts the open/close) and the
# power key with the screen on (the lock press; the wake keys stay in epoll with the
# screen on, except the touch panel's gesture node). The day report grew the wake-jank
# line, per-phase and per-state jank tables and the current-sensor gauge note, and its
# red verdicts learned the duration guards (a 40-minute "night" and 6 loud minutes are
# noise, not findings). The runtime behaviour (the lift arms, the digest lines, the
# parser, the tips) is exercised in tests/asb_smart.sh:t_unlock_lift_runtime and
# tests/asb_ui.sh:t_webui_log_report_runtime; here the structural pins.
sh -n "$D" || fail "digest script has a syntax error"
grep -qF 'int lock_kick, int launch_kick,' "$G" || fail "the update does not take the lock kick"
grep -qF 'g_unlock_arm_why = touch_kick ? "touch" : (lock_kick ? "lock key" : "app switch");' "$G" || fail "the arm no longer names its source"
grep -qF 'g_lock_key_kick = 1;' "$G" || fail "the power key with the screen on raises no kick"
grep -qF 'if (g_wake_key_touch[i])' "$G" || fail "wake_keys_park parks the power key with the screen on again"
grep -qF 'jwake\twakes=%s\tpct=%s\tord=%s\tframes=%s\ttop=%s\ttop_pct=%s' "$D" || fail "the digest emits no wake-jank line"
grep -qF 'jphase\tphase=%s\tintv=%s\tframes=%s\tpct=%s\tjps=%s' "$D" || fail "the digest emits no per-phase jank"
grep -qF 'jstate\tstate=%s\tintv=%s\tframes=%s\tpct=%s\tjps=%s' "$D" || fail "the digest emits no per-state jank"
grep -qF "gauge\tfactor=%s\twindows=%s\tmult=%s" "$D" || fail "the digest emits no gauge line"
grep -qF "tag === 'jphase'" "$H" || fail "the parser drops the per-phase rows"
grep -qF "tag === 'jstate'" "$H" || fail "the parser drops the per-state rows"
grep -qF "lr_tip_jank_wake" "$H" || fail "the wake-jank advice is gone"
grep -qF "lr_gauge_note" "$H" || fail "the gauge note is gone"
grep -qF "(+night.dur_min || 0) >= 120" "$H" || fail "the night verdict lost its duration guard"
grep -qF "(+audio.pctph || 0) >= 8 && (+audio.spk_min || 0) >= 30" "$H" || fail "the speaker row colours noise red again"
grep -qF "lr_nd_verdict_short" "$H" || fail "a short night still gets a red verdict"
grep -qF 'jwake\twakes=23\tpct=7.3\tord=5.1' "$T" || fail "the wake-jank fixture is gone"
grep -qF 'a 40-minute night stretch draws no night tip' "$T" || fail "the night duration-guard assertion is gone"
grep -qF 'the tap that opens an app did not lift' "$S" || fail "the touch-arm assertion is gone"
grep -qF 'the lock press did not lift' "$S" || fail "the lock-arm assertion is gone"
grep -qF 'wakes, first touches, app opens/closes, lock presses' "$ROOT/tools/asb_diag.sh" || fail "asbdiag still says wakes + first touches"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag is stale"
echo "PASS: fix220 contract"
) || exit 1
# ---- fix221 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/runtime/asb_apply_ledger.sh"
D="$ROOT/tools/asb_diag.sh"
T="$ROOT/tests/asb_features.sh"
U="$ROOT/tests/asb_ui.sh"
fail() { echo "FAIL fix221: $*"; exit 1; }
# Other users' diag reports (ColorOS 16: CPH2747, CPH2769, CPH2691) listed
# network_recommendations_enabled and cloud_dns_happy_eyeballs_priority_enabled as
# "refused, not in effect ... the ROM blocks this write" - but the read-back was empty
# before and after the write: these keys simply do not exist on those ROMs. A refusal is
# a permission problem; an absent key is not, and naming it one sent people chasing a
# ghost. The ledger now files the empty-before-and-after signature as "unsupported" (its
# own class for "the key or node does not exist on this device"), remembers it in the
# same rejected list so it is still not retried, and asbdiag lists such keys apart under
# a calm "not on this ROM" line instead of the refusal list.
sh -n "$L" || fail "asb_apply_ledger.sh does not parse"
grep -qF '_ls_absent=0' "$L" || fail "no absent-key detection in the ledger"
grep -qF '[ -n "$_ls_v" ] && [ -z "$_ls_prev" ] && [ -z "$_ls_now" ]' "$L" || fail "absent-key signature changed"
grep -qF 'unsupported "key absent on this ROM"' "$L" || fail "absent key not filed as unsupported"
# The silently-ignored write (rc=0, still no key) is remembered too, or every boot and
# every reinforce pass keeps paying three `settings` calls for it.
grep -qF '# Silently ignored write to a key this ROM does not have: remember it too' "$L" || fail "rc=0 absent-key write not remembered"
[ "$(grep -c '>> "$ASB_SETTINGS_REJECTED"' "$L")" -ge 2 ] || fail "the absent key is not remembered in the rejected list on both paths"
sh -n "$D" || fail "asb_diag.sh does not parse"
grep -qF 'else if (last[k] == "unsupported" && k ~ /^settings\//) { u++; printf "U|%s|%s\n", k, req[k] }' "$D" || fail "diag does not split absent settings keys out of the refusal list"
grep -qF '· not on this ROM ' "$D" || fail "diag summary does not name the absent-key count"
grep -qF 'not on this ROM: $_uk (wanted ${_ur:-?}) - this ROM has no such setting; nothing is wrong' "$D" || fail "diag absent-key line gone"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag is stale"
grep -qF 'unsupported|key absent on this ROM' "$T" || fail "the runtime absent-key assertion is gone"
grep -qF 'existing-key refusal no longer filed as not_writable' "$T" || fail "the existing-key refusal assertion is gone"
grep -qF 'not on this ROM: settings/cloud_dns_happy_eyeballs_priority_enabled (wanted off)' "$U" || fail "the diag fixture lost the absent-key line"
grep -qF 'an unsupported sysfs node leaked into the settings list' "$U" || fail "the sysfs-leak assertion is gone"
echo "PASS: fix221 contract"
) || exit 1
# ---- fix222 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
U="$ROOT/tests/asb_ui.sh"
fail() { echo "FAIL fix222: $*"; exit 1; }
# The owner's debug13 screenshots (CPH2745, ColorOS 17, a running Smart capture): the
# report called a 40-minute daytime stretch "the night" - red 1.5 %/h rows, a verdict and
# a night advice card, at 19:57, before any night had happened; the awake tip blamed
# com.android.systemui while the red AOD line (14 of 67 screen-off checks) sat a card
# away with no connection drawn; 214.7 MiB of background mobile data glowed red with no
# advice; and the profile table printed "0.0 %/h" for a profile whose counted idle
# minutes had nearly all sat on the charger. All four are report-honesty repairs; no
# governor or profile numbers moved.
grep -qF "const shortNight = (+night.dur_min || 0) < 120;" "$H" || fail "the short-stretch night detector is gone"
grep -qF "T('lr_sec_nightd_short', '🌙 Longest idle stretch in detail')" "$H" || fail "the short stretch is still titled a night"
grep -qF "T('lr_nd_spent_short', 'Spent over the stretch')" "$H" || fail "the spent row still says overnight on a short stretch"
grep -qF 'pctph > 0.8 && !shortNight' "$H" || fail "a short stretch still paints the spent row red"
grep -qF 'awake > 15 && !shortNight' "$H" || fail "a short stretch still paints the awake row red"
grep -qF 'if (holder && !shortNight)' "$H" || fail "a capture-wide holder is still named the night's holder on a short stretch"
grep -qF "(+idle.awake || 0) > 15 && (+idle.dur_min || 0) >= 20" "$H" || fail "the awake verdict lost its duration floor"
grep -qF "key: 'lr_tip_awake_aod'" "$H" || fail "the AOD awake tip is gone"
grep -qF "(+_aodt.lit || 0) * 100 >= 10 * (+_aodt.of || 0)" "$H" || fail "the AOD pattern threshold changed"
grep -qF "key: 'lr_tip_sradio'" "$H" || fail "the background-traffic tip is gone"
grep -qF "(cfg.net_screen_off_lte || '0') === '0'" "$H" || fail "the traffic tip must treat a missing cfg snapshot as the shipped default"
grep -qF "p.offMin >= 20 ? { txt: String(p.offP.toFixed(1))" "$H" || fail "the profile table lost its too-few-minutes dash"
for k in lr_sec_nightd_short lr_nd_spent_short lr_tip_awake_aod lr_tip_sradio; do
  grep -qF "\"$k\"" "$ROOT/webroot/i18n/en.json" || fail "en.json lost $k"
done
grep -qF 'SystemUI + AOD names the display' "$U" || fail "the AOD tip assertion is gone"
grep -qF 'a ten-minute stretch draws no awake tip' "$U" || fail "the awake duration-floor assertion is gone"
grep -qF 'the traffic tip names its setting' "$U" || fail "the sradio tip assertion is gone"
grep -qF "const _smRan = d.profs.some(function (p) { return p.name === 'smart' && (p.onMin + p.offMin) >= 30; });" "$H" || fail "the Smart-ran check is gone - the not-a-Smart-day note fires on a mid-day switch again"
echo "PASS: fix222 contract"
) || exit 1
# ---- fix223 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
F="$ROOT/src/asb_fsm.h"
W="$ROOT/src/asb_writer.h"
S="$ROOT/tests/asb_smart.sh"
fail() { echo "FAIL fix223: $*"; exit 1; }
# Re-review of the post-fix219 screenshots and captures found a real responsiveness
# asymmetry, not a reason to move static profile caps. CPH2745 Battery touch intervals had
# 9.7% janky frames in LIGHT_IDLE versus 7.1% in MODERATE; same-device CPH2747 Battery ->
# Smart showed Telegram 8.1% versus 3.7%, TikTok 15.6% versus 6.8%. Manual Battery ceilings
# are shell-owned, so merely removing its FSM touch exclusion would not fix the scroll.
# Instead, continuous touch extends an ALREADY ARMED unlock-lift window on Battery only.
# The writer borrows ceilings above the shell caps and hands them back on expiry. Quiet
# reading, the FSM's Battery exclusions, static profile frequencies and all other profiles
# stay unchanged. No absolute frequency, new setting or Android/ColorOS API is introduced.
grep -qF 'int touch_active,' "$G" || fail "continuous touch is absent from the lift update"
grep -qF 'if (touch_active && profile_idx == PROFILE_BATTERY && g_unlock_until_ms > 0 &&' "$G" \
  || fail "the hold is not Battery-only and already-armed-only"
grep -qF '_touch_active, g_lock_key_kick, _launch_kick,' "$G" || fail "the main loop does not pass continuous touch"
grep -qF 'metrics.misc.screen_on && !metrics.misc.camera_active &&' "$G" || fail "the touch-active signal lost its screen/camera gates"
grep -qF 'time(NULL) - g_touch_last_ts <= ASB_TOUCH_RECENT_S;' "$G" || fail "the hold is not bounded by the sampled touch clock"
# fix240: the touch floor and the first-touch lift now include Battery (its LIGHT_IDLE GPU
# ceiling is the governor's own lowest step); only the CPU pin escalation keeps it out.
[ "$(grep -cF '!fsm_profile_is_battery && !m->misc.camera_active' "$F")" -eq 1 ] \
  || fail "Battery's quiet-screen FSM exclusions changed"
grep -qF 'const int manual_lift     = manual_profile && g_unlock_lift_now && !thermal_cap &&' "$W" \
  || fail "the writer does not borrow the manual-profile ceilings"
grep -qF 'int manual_cap_skip = manual_profile && !manual_override && !manual_lift;' "$W" \
  || fail "manual_cap_skip does not yield to the lift"
grep -qF 'writer_manual_handback' "$W" || fail "manual-profile ceiling handback is missing"
grep -q '^unlock_lift_s=3$' "$ROOT/config/governor.conf" || fail "the lift duration changed"
grep -q '^unlock_lift_pct=80$' "$ROOT/config/governor.conf" || fail "the hardware-relative lift share changed"
for pin in 'continuous Battery scrolling expired after the original 3 s' \
           'touch-active alone started a Battery lift without an arm event' \
           'touch hold restarted a thermally cancelled Battery lift' \
           'touch hold bypassed the warm-start veto' \
           'Smart gained the Battery continuous-touch hold' \
           'Balanced gained the Battery continuous-touch hold'; do
  grep -qF "$pin" "$S" || fail "missing runtime assertion: $pin"
done
echo "PASS: fix223 contract"
) || exit 1
# ---- fix209 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/src/asb_smart.h"
G="$ROOT/src/asb_governor.c"
R="$ROOT/src/asb_record.h"
T="$ROOT/tests/asb_smart.sh"
fail() { echo "FAIL fix209: $*"; exit 1; }
# Smart teaches heat against THIS device, not an OP15's numbers. The session-feedback
# thresholds (hot / very hot / clean-cool) were absolute 70/80/55 C - right for the
# reference phone, wrong everywhere the sensors run warmer or cooler. They now sit at a
# fixed offset over the device's own learned temperature median (the same median the
# warm/cool boundaries already use), clamped to a sane band, with the absolute values kept
# for any caller that has no store yet. The governor hands the median in at the one call
# site. The night-check learner got its own repair: a capture showed twenty checks banked
# with nights=0 - a night whose morning never confirmed (an irregular wake, a rejected
# sample) never received night_end, so tonight kept counting across days and the slot
# weights never faded; the first confirming morning would have folded it all into one
# "night" of twenty checks. A note that lands ten or more hours after the previous one now
# closes the pending night first (capped at four checks - an unbounded accumulation is not
# one night's habit), exactly as the confirmed path does.
grep -qF 'static int asb_smart_therm_median_x10(const asb_smart_store_t *st)' "$S" || fail "the device-median helper is gone"
grep -qF 'asb_smart_bucket_update_from_session_ex(' "$S" || fail "the median-aware session update is gone"
grep -qF 'asb_clamp_int(device_median_c + 25, 60, 80)' "$S" || fail "the hot threshold is not median-relative any more"
grep -qF 'asb_smart_bucket_update_from_session_ex(b, s, now, 0);' "$S" || fail "the no-median fallback lost the absolute thresholds"
grep -qF 'asb_smart_therm_median_x10(&g_smart_store) / 10' "$G" || fail "the governor does not hand the device median to the learner"
grep -qF '#define ASB_MW_FOLD_GAP_S   (10L * 3600)' "$R" || fail "the unconfirmed-night gap is gone"
grep -qF '#define ASB_MW_FOLD_MAX     4' "$R" || fail "an unbounded tonight is folded as one night again"
grep -qF 'start_wall - (long)w->last_ts >= ASB_MW_FOLD_GAP_S' "$R" || fail "the lazy night fold is gone"
grep -qF 'test_bucket_learn_relative_thresholds();' "$T" || fail "the median-relative threshold test is not registered"
grep -qF 'the unconfirmed night did not close' "$T" || fail "the lazy-fold assertions are gone"
echo "PASS: fix209 contract"
) || exit 1
# ---- fix208 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
fail() { echo "FAIL fix208: $*"; exit 1; }
# The night deserves its own sheet: a day capture holds the one stretch where the phone
# should cost almost nothing, and the report only had a two-line hero for it. The digest
# now walks the same longest deep-sleep chain the hero reports and tallies it in detail -
# weighted average current, rmnet radio traffic, peak CPU/skin temperatures - as a nightd
# line emitted only when that chain ran at least 15 minutes. The sheet renders a "Night in
# detail" section right after the drain hero: what the night cost and at what pace, the
# deep-sleep share, the awake share, the average current, the radio traffic (a modem that
# talks all night is THE classic night drain), the peak temperatures (charging on a
# wireless pad warms the phone and keeps it shallow), the loudest live holder, and AOD
# time - closed by a three-tier verdict so a good night says so plainly.
# The same capture answers "which profile is cheaper on THIS phone": when two or more
# profiles each held the screen for half an hour, a tip quotes the measured cheapest vs
# the measured priciest screen-on figure (a tester day: battery 1.6 %/h against
# performance 6.1 %/h) instead of generic advice.
sh -n "$D" || fail "digest script has a syntax error"
grep -qF 'printf "nightd\tma=%d\tradio_mib=%.1f\tcpu_t=%d\tskin_t=%d\twake_pk=%d\n"' "$D" || fail "the digest lost the night-detail line"
grep -qF 'bd >= 900' "$D" || fail "the night detail must not fire on a sub-15-minute chain"
grep -qF 'd.sections.nightd' "$H" || fail "the report parser dropped the night-detail line"
grep -qF "lr_sec_nightd" "$H" || fail "the night-detail section is not rendered"
grep -qF "lr_nd_verdict_bad" "$H" || fail "the night verdict lost its bad tier"
grep -qF "lr_tip_prof_save" "$H" || fail "the measured cheapest-profile tip is gone"
grep -qF "busy.onP >= cheap.onP * 2" "$H" || fail "the profile tip fires without a real (2x) gap"
echo "PASS: fix208 contract"
) || exit 1
# ---- fix207 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
fail() { echo "FAIL fix207: $*"; exit 1; }
# Owner's report sheet: "В простое телефон бодрствовал 30% времени - что-то мешает
# глубокому сну" right above "Блокировок сна от приложений не записано - отлично", and
# "Самый долгий простой 0.7 %/ч" against Monitor's "Экран выкл 1.3 %/ч". Two fixes.
# 1) The contradiction: batterystats had recorded nothing (flat per-uid delta), so the
#    sheet claimed excellence under a restless idle. The wake section now never prints
#    "excellent" when the awake share is high and nothing was recorded - it says the
#    counters stayed flat and points at the full report. Kernel wakelock holders on the
#    charger (the only named holders on a charging day) are listed too.
# 2) The figure mismatch: three windows, three right answers. The night hero is ONE
#    deep-sleep-heavy chain; Monitor's meter averages clean hour-plus stretches without
#    music; the digest now also emits the whole-ledger screen on/off split (the report
#    writer's own classification) and the sheet shows all three side by side, plus a
#    deep-sleep share in the night hero. More detail: a per-phase breakdown table (time,
#    signed drop, %/h) aggregated from the ledger.
sh -n "$D" || fail "digest script has a syntax error"
grep -qF 'printf "scr\ton_pctph=%.1f\toff_pctph=%.1f\ton_min=%d\toff_min=%d\tidle_pctph=%.1f\tidle_min=%d\tmusic_min=%d\n"' "$D" || fail "the digest lost the screen on/off split"
grep -qF 'printf "phase\tname=%s\tmin=%d\tdrop=%d\tpctph=%.1f\n"' "$D" || fail "the digest lost the phase rows"
grep -qF 'printf "kwk\ttag=%s\tmin=%d\n"' "$D" || fail "the digest lost the kernel charger holders"
grep -qF 'ph ~ /_scr$/ || ph == "active" || ph == "gaming" || ph == "post_wake"' "$D" || fail "the split no longer uses the report writer's classification"
grep -qF 'd.phases.push' "$H" || fail "the report parser dropped the phase table"
grep -qF 'd.kwk.push' "$H" || fail "the report parser dropped the kernel holders"
grep -qF "lr_sec_phases" "$H" || fail "the phase breakdown section is not rendered"
grep -qF "lr_drain_off" "$H" || fail "the screen-off drain row is gone"
grep -qF "lr_wake_gap" "$H" || fail "a restless idle with flat counters still prints 'excellent'"
grep -qF "lr_deep_sleep" "$H" || fail "the night hero lost its deep-sleep share"
echo "PASS: fix207 contract"
) || exit 1
# ---- fix206 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
fail() { echo "FAIL fix206: $*"; exit 1; }
# Two user reports drove this fix.
# 1) "Монитор листается, Профили не листаются" - a KernelSU-family WebView host that
#    gesture-scrolls overflowing ELEMENTS but not the document (Monitor, a live-page with
#    element scroll, worked; Home, the last document-scrolled page, did not). Home is now
#    a self-scrolling fixed overlay exactly like .live-page, centered with left/right:0 +
#    margin:auto - NOT translateX(-50%), because the prefers-reduced-motion block forces
#    transform:none on .page:not(.live-page). asbFitPages measures it through the overlay
#    path (unclamped bottom/height) and sizeCards reads the overlay's own scrollTop.
# 2) Log analysis (three full-day captures): the report hid the real wake story whenever
#    batterystats counted nothing (the owner's MountServiceIdler at 23% of samples over a
#    flat per-uid delta printed "no wakelocks - excellent"), said nothing about a day on
#    the charger (5W wireless, +62% over ~400 min), and could not compare profiles on the
#    day a tester ran them all. The digest now emits wlive (power-manager-sampled live
#    holders), prof (per-profile drain from the battery trace's profile field, only when
#    two or more profiles ran), chg (charging sessions from the ledger), ltpo and aod;
#    the sheet renders a profiles table, a charging row, an AOD row, live holders in the
#    wake section, an LTPO row, a Smart-only learning note when the capture ran under
#    another profile, and the awake tip names its top holder. The runtime behaviour is
#    exercised in tests/asb_ui.sh (t_webui_page_scroll, t_webui_fill_pages_runtime,
#    t_webui_log_report_runtime); here the structural pins.
sh -n "$D" || fail "digest script has a syntax error"
grep -qF 'printf "wlive\ttag=%s\tpct=%d\tmin=%d\tpkg=%s\n"' "$D" || fail "the digest lost the live-holder rows"
grep -qF 'printf "prof\tname=%s\ton_min=%d\toff_min=%d\ton_pctph=%.1f\toff_pctph=%.1f\n"' "$D" || fail "the digest lost the per-profile rows"
grep -qF 'printf "chg\tmin=%d\tgain=%d\tsess=%d\n"' "$D" || fail "the digest lost the charging line"
grep -qF "printf 'ltpo\tn=%s\tmin=%s\n'" "$D" || fail "the digest lost the ltpo line"
grep -qF "printf 'aod\tlit=%s\tof=%s\n'" "$D" || fail "the digest lost the aod line"
grep -qF 'if (np >= 2)' "$D" || fail "a one-profile day must not emit a comparison"
grep -qF ".page:not(.live-page) {" "$H" || fail "home page rule missing"
grep -qF 'else el = document.querySelector('"'"'.page:not(.live-page)'"'"');' "$H" || fail "asbFitPages no longer measures home through the overlay path"
grep -qF 'const home = document.querySelector('"'"'.page:not(.live-page)'"'"');' "$H" || fail "sizeCards no longer reads the home overlay's scrollTop"
grep -qF 'd.wlive.push' "$H" || fail "the report parser dropped live holders"
grep -qF 'd.profs.push' "$H" || fail "the report parser dropped per-profile rows"
grep -qF "lr_sec_profiles" "$H" || fail "the profiles comparison section is not rendered"
grep -qF "lr_tip_awake_who" "$H" || fail "the awake tip does not name its holder"
grep -qF "if (smart && _smDay) {" "$H" || fail "the Smart learner card is shown on a day Smart never ran"
grep -qF "lr_wlive_fmt" "$H" || fail "the live-holder row format is gone"
echo "PASS: fix206 contract"
) || exit 1
# ---- fix205 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL fix205: $*"; exit 1; }
# Owner's OP15 after fix204: every page back to normal except the log report - "look at
# the header". The report is a long list BY DESIGN and scrolls; its content sections are
# not tier-styled at all, so the compaction tiers there compressed only the shared header
# (logo, title, capsules) and bought zero room. The tiers now apply only where their
# styled content lives (Profiles, Monitor, the Settings hub): Device, the report and an open
# tweak category always keep the chrome as drawn and scroll. The runtime behaviour (the
# report never compacts, a carried-over tier comes off, an open category is exempt, the
# hub still compacts) is exercised in node by t_webui_fill_pages_runtime.
grep -qF "const fittable = !document.body.classList.contains('device-active') &&" "$H" || fail "the Device page can still take a compaction tier"
grep -qF "!document.body.classList.contains('report-active') &&" "$H" || fail "the report page can still take a compaction tier"
grep -qF "!(document.body.classList.contains('config-active') && _cfgGroup)" "$H" || fail "an open tweak category can still take a compaction tier"
grep -qF 'if (fittable && over > need && tier < 2)' "$H" || fail "escalation is not gated on the page having tier-styled content"
grep -qF 'let reportOpen = false, reportBase = 3000;' "$ROOT/tests/asb_ui.sh" || fail "the fit test lost its report-page mock"
echo "PASS: fix205 contract"
) || exit 1
# ---- fix204 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
fail() { echo "FAIL fix204: $*"; exit 1; }
# Owner's live capture: at "0 min of 24 h" the report sheet counted four native crashes
# (latest com.oplus.screenshot - from screenshots taken BEFORE the recording); a few
# minutes later the same section read "no crashes". Cause: a capture that just started
# has neither the phase ledger nor the interim report (the first snapshot lands after
# fifteen minutes), so the crash window fell back to "the last 24h" and counted
# pre-capture tombstones - which then fell out of the window the moment the first ledger
# row landed. The window of a RUNNING capture with no ledger yet now opens at the
# capture's own launch, stamped on the WebUI lock's pid file; the ledger's leading "#"
# comment is skipped when the first data row is read. And the sheet names the time of
# the latest crash ("latest: proc, HH:MM"), so the user can place it instead of
# wondering who crashed and why. The behaviour (fixture captures, incl. the fresh one
# with a live lock) is exercised in tests/asb_ui.sh:t_webui_log_report_runtime.
sh -n "$D" || fail "digest script has a syntax error"
grep -qF '_start="$(stat -c %Y "$_LOCK/pid"' "$D" || fail "a fresh running capture still opens its crash window 24h back"
grep -qF "awk -F'\\t' '!/^#/ { print \$2; exit }' \"\$_LEDGER\"" "$D" || fail "the crash window still reads the ledger's comment header as its first row"
grep -qF 'crash\tcount=%d\tasb=%d\tlatest=%s\tltime=%s\n' "$D" || fail "the digest does not report when the latest crash happened"
grep -qF 'crash.ltime' "$H" || fail "the sheet does not show the latest crash's time"
echo "PASS: fix204 contract"
) || exit 1
# ---- fix203 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL fix203: $*"; exit 1; }
# Owner's OP15 screenshots a day after fix202: Config, Monitor and Profiles sat compacted
# into the top of the screen with a void above the bar - "first paint is fine, a second
# later it looks like this". Four causes: the overflow reading counted the floating bar's
# reserved bottom padding (a perfectly fit page read a full bar's height too tall), the
# overlays were measured through scrollHeight, which never reads below the box's own
# clientHeight (every fixed page reported the bar's height of overflow even when its
# content was short), the measurement ran AFTER the cards grew into the freed space
# (every tier read "just fits", so the hysteresis trial latched it), and the cards can
# only shrink to their natural height (min-height only), so the compaction freed space
# nothing re-absorbed. The tier decision now measures the page as it asks to be: the
# fitted heights are zeroed for the measurement and restored after, the reading excludes
# the bar's reserved padding, a fixed overlay is unclamped (bottom/height auto for one
# layout), and an overflow within a fifth of the screen - at least 56 px - keeps the look
# and just scrolls (the fix201 fallback). A tier comes off only with real room (need - 8
# px of hysteresis). The runtime behaviour (escalation, the allowance, the hysteresis) is
# exercised in node by t_webui_fill_pages_runtime; here the structural pins.
grep -qF 'const need = Math.max(56, Math.round(' "$H" || fail "a small overflow must keep the look and scroll, not compact"
grep -qF "root.style.setProperty('--pbtn-h', '0px');" "$H" || fail "the tier is not decided from the page's natural height"
grep -qF "root.style.setProperty('--cfg-tile-h', '0px');" "$H" || fail "the Settings tiles' fitted height is not neutralized for the measurement"
grep -qF "st.bottom = 'auto'; st.height = 'auto';" "$H" || fail "a fixed overlay is still measured through its clamped scrollHeight"
grep -qF 'over2 > need - 8' "$H" || fail "a tier comes off without hysteresis"
grep -qF 'getComputedStyle(el).paddingBottom' "$H" || fail "the bar's reserved padding is still counted as overflow"
grep -qF "let homeBase = 1022, cfgBase = 1100, clientH = 1900, barTop = 1700;" "$ROOT/tests/asb_ui.sh" || fail "the fit test lost its natural-measurement mock"
echo "PASS: fix203 contract"
) || exit 1
# ---- fix202 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL fix202: $*"; exit 1; }
# Owner's design intent, restated after the fix201 scroll repair: the pages were meant to
# FIT one screen at any DPI/height, with no need to scroll; the users' screens clipped and
# they asked for scrolling. The logic is reconsidered: asbFitPages (fix168) only GREW the
# cards into free space - on a short screen it hit its floors and the page scrolled. It now
# measures the visible page's overflow and compacts in two tiers (asb-fit-c1/c2 on <html>:
# top gap, logo, wordmark, capsules, cards, Monitor cells, support rail), with the card
# and tile floors stepping down (68/58/48, 104/92/80). fix203 reworked the measurement -
# it is taken from the page's natural height against the bar's fit line, with the bar's
# reserved padding excluded and a small overflow left to scroll; a tier comes off only
# when the lighter tier fits within the allowance minus a margin, so the layout cannot
# flip-flop. If even tier 2 overflows, the fix201 scroll remains as the fallback - nothing
# is clipped. The runtime behaviour (escalation, hysteresis, per-page measurement) is
# exercised in node by t_webui_fill_pages_runtime; here the structural pins.
grep -q 't_webui_fill_pages_runtime' "$ROOT/tests/asb_ui.sh" || fail "the fit runtime test is missing"
grep -qF "let homeBase = 1022, cfgBase = 1100, clientH = 1900, barTop = 1700;" "$ROOT/tests/asb_ui.sh" || fail "the fit test lost its measured-overflow mock"
for t in asb-fit-c1 asb-fit-c2; do
  grep -qF "html.$t { --page-top:" "$H" || fail "$t does not tighten the top gap"
  grep -qF "html.$t .logo-c {" "$H" || fail "$t does not shrink the logo"
  grep -qF "html.$t .live-cell {" "$H" || fail "$t does not compact the Monitor cells"
done
grep -qF "classList.toggle('asb-fit-c1', t >= 1)" "$H" || fail "tier classes are not raised from the measurement"
grep -qF 'Math.max([68, 58, 48][tier]' "$H" || fail "the profile-card floor does not step down"
grep -qF 'Math.max([104, 92, 80][tier]' "$H" || fail "the tile floor does not step down"
grep -qF 'else if (document.body.classList.contains('"'"'live-active'"'"')) el = _el('"'"'livePage'"'"');' "$H" || fail "the Monitor page is not the thing measured while it is open"
# The fix201 fallback must survive intact: overlays still scroll themselves.
grep -q 't_webui_page_scroll' "$ROOT/tests/asb_ui.sh" || fail "the scroll regression test is missing"
echo "PASS: fix202 contract"
) || exit 1
# ---- fix201 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix201: $*"; exit 1; }
# The fix192-era audit's P0 was real: common/install.sh failed bash -n. The cause sits at
# line 259's default string ("...module's WebUI..."): an apostrophe inside ${var:-...}
# inside double quotes is literal text for POSIX sh/mksh but OPENS a single quote for bash,
# so bash's parse error surfaced pages later, at line 551. mksh on device always parsed it
# right - this is a CI/maintainability landmine, not a device bug - but the installer is
# the most sensitive script we ship, and lint now gates the whole installer family under
# BOTH shells so the class cannot come back.
bash -n "$ROOT/common/install.sh" 2>/dev/null || fail "install.sh fails bash -n again"
sh -n "$ROOT/common/install.sh" 2>/dev/null || fail "install.sh fails sh -n"
for _s in customize.sh service.sh post-fs-data.sh uninstall.sh action.sh apply_profile.sh; do
  bash -n "$ROOT/$_s" 2>/dev/null || fail "$_s fails bash -n"
  sh -n "$ROOT/$_s" 2>/dev/null || fail "$_s fails sh -n"
done
grep -q 'bash -n "$_f"' "$ROOT/tools/asb_lint.sh" || fail "lint does not gate the bash parse"
grep -q 'common/install.sh' "$ROOT/tools/asb_lint.sh" || fail "lint does not check the installer"
# The scroll regression pins live in tests/asb_ui.sh:t_webui_page_scroll.
grep -q 't_webui_page_scroll' "$ROOT/tests/asb_ui.sh" || fail "the scroll regression test is missing"
# Locale key parity (a fix192-era drift: t_cfg_video existed in 12 locales but not en) is
# asserted inside t_webui_log_report_runtime's locale pass.
grep -q 'key set differs from en' "$ROOT/tests/asb_ui.sh" || fail "the locale key-parity check is missing"
echo "PASS: fix201 contract"
) || exit 1
# ---- fix200 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
fail() { echo "FAIL fix200: $*"; exit 1; }
# The log report grew from a drain summary into the full "what kind of day was it" sheet:
# saved captures are named (start time + profile), smoothness comes with the real per-app
# frame table, the display-refresh split, Smart learner progress, ASB's own cost, speaker
# playback and charge types - and advice can name the exact Settings switch. The digest
# mines the recorder's own interim report (no dumpsys), so it works on running AND saved
# captures alike, under every profile.
sh -n "$D" || fail "digest script has a syntax error"
grep -qF 'started=%s\tprofile=%s' "$D" || fail "the digest must name when a saved capture started and under which profile"
grep -q 'current_profile:' "$D" || fail "the digest must read the capture profile from env.txt"
grep -qF 'japp\tpkg=' "$D" || fail "the digest must emit per-app jank rows"
grep -qF 'hz\tmode=' "$D" || fail "the digest must emit the display refresh split"
grep -qF 'asbcost\tcpu_msh=' "$D" || fail "the digest must emit ASB's own cost"
grep -qF 'audio\tspk_min=' "$D" || fail "the digest must emit speaker playback cost"
grep -qF 'charge\ttypes=' "$D" || fail "the digest must emit charge types"
grep -qF 'smart\twatching=' "$D" || fail "the digest must emit Smart learner progress"
grep -q 'wakelock_action ltpo_video night_modem_idle' "$D" || fail "the digest must snapshot the settings the advice points at"
# No quotes may break the shell: the awk programs are single-quoted, an apostrophe inside
# them once broke the whole script (dash sh -n caught it - keep it caught).
grep -q "nobody's" "$D" && fail "apostrophe inside a single-quoted awk program"
# WebUI side.
grep -q 'd.japps' "$H" || fail "the parser must collect per-app jank rows"
grep -q 'd.hzs' "$H" || fail "the parser must collect the refresh split"
grep -q 'd.cfg' "$H" || fail "the parser must collect the settings snapshot"
grep -q 'function logReportTable(' "$H" || fail "the table builder is missing"
grep -q "lr_saved" "$H" || fail "a saved capture must be named as such"
grep -q 'tips.slice(0, 6)' "$H" || fail "advice stays readable: at most six cards"
grep -q 'td.textContent' "$H" || fail "table cells must be textContent - device data never becomes markup"
# The full behaviour (digest over a fixture capture, parser+tips in node, all 13 locales)
# lives in tests/asb_ui.sh:t_webui_log_report_runtime.
grep -q 'lr_tip_jank_bad' "$ROOT/tests/asb_ui.sh" || fail "the runtime test must cover the fix200 advice"
echo "PASS: fix200 contract"
) || exit 1
# ---- fix198 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/src/asb_record.h"
fail() { echo "FAIL fix198: $*"; exit 1; }
# The smoothness check's entry bar is 5 % of 3000+ frames (was 8 %): two full-day flagship
# captures showed 8 % above anything a healthy phone's apps reach, so no test ever ran.
grep -Fq '#define ASB_SMOOTH_TRIGGER_JANK    0.05' "$R" || fail "the test trigger is not 5 %"
grep -Fq 'The trigger was 8 % until fix198' "$R" || fail "the design comment lost the field evidence"
# A test is bounded: six windows per arm always end it, even on thin frames - the verdict
# is kept-headroom only with the full evidence, otherwise the app is left as it was.
grep -Fq 'if (!enough && !full) return 0;' "$R" || fail "the frames floor still gates the verdict"
grep -Fq 'if (enough && j1 <= j0 * (1.0 - ASB_SMOOTH_GAIN_REL)' "$R" || fail "thin frames could keep the headroom"
grep -Fq 'a full test without enough frames for a verdict: left as it was' "$R" || fail "no thin-frames verdict"
grep -Fq 'a->t_frames[0] ? (double)a->t_janky[0] / a->t_frames[0] : 0.0' "$R" || fail "a thin arm would divide by zero"
asb_has_test test_smart_smoothness_runtime.sh || fail "smoothness runtime test missing"
echo "PASS: fix198 contract"
) || exit 1
# ---- fix197 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL fix197: $*"; exit 1; }
# The segment control and the switch wear the navigation bar's capsule material.
sed -n '/^\.cfg-seg {$/,/^}/p' "$H" | grep -q 'background: var(--cap-wash), var(--tabbar-bg, #000000);' || fail "the segment is not the bar's capsule"
sed -n '/^\.cfg-seg {$/,/^}/p' "$H" | grep -q 'border: 1px solid var(--cap-edge);' || fail "the segment lost the teal edge"
sed -n '/^\.cfg-seg {$/,/^}/p' "$H" | grep -q 'box-shadow: var(--cap-shadow);' || fail "the segment lost the lit edge"
sed -n '/^\.cfg-seg {$/,/^}/p' "$H" | grep -Eq '^[[:space:]]*overflow: hidden;' && fail "the clip is back - it cuts the floating pill's ring"
sed -n '/^\.cfg-seg button {$/,/^}/p' "$H" | grep -q 'border-radius: 11px;' || fail "the segment buttons are not pills"
sed -n '/^\.cfg-seg button\.on {$/,/^}/p' "$H" | grep -q 'background: var(--pill-wash);' || fail "the selected option lost the tonal pill"
sed -n '/^\.cfg-switch {$/,/^}/p' "$H" | grep -q 'background: var(--cap-wash), var(--tabbar-bg, #000000);' || fail "the switch track is not the bar's capsule"
sed -n '/^\.cfg-switch {$/,/^}/p' "$H" | grep -q 'box-shadow: var(--cap-shadow);' || fail "the switch lost the lit edge"
sed -n '/^\.cfg-switch\.on {$/,/^}/p' "$H" | grep -q 'rgba(0,240,180,0.5)' || fail "the on state lost the accent wash"
grep -q 'html\[data-asb-theme="light"\] \.cfg-seg {' "$H" || fail "no light-theme segment capsule"
grep -q 'html\[data-asb-theme="light"\] \.cfg-switch {' "$H" || fail "no light-theme switch capsule"
# The log report is a page in the back-gesture history, like the others.
[ "$(grep -c '^let _rpOpen = false;' "$H")" -eq 1 ] || fail "_rpOpen declared twice or never"
[ "$(grep -n '^let _rpOpen = false;' "$H" | cut -d: -f1)" -lt "$(grep -n '^function navUiDepth()' "$H" | cut -d: -f1)" ] || fail "_rpOpen is declared after the nav code that reads it"
grep -q 'if (_rpOpen) d++;' "$H" || fail "the report page owns no history entry"
grep -q "if (_rpOpen) { uiSound('nav'); closeReportPage(); return; }" "$H" || fail "back does not close the report page"
grep -q "if (e.key === 'Escape' && _rpOpen)" "$H" || fail "Escape does not close the report page"
# The LSPosed card keeps the modules log clean: apply empties it once, the service loop
# sweeps it every ten minutes while the card says off, and the setting is still never
# written at boot.
grep -q '^_sweep_logs() {' "$ROOT/runtime/asb_lsposed.sh" || fail "no sweep helper"
grep -q '^  sweep)' "$ROOT/runtime/asb_lsposed.sh" || fail "no sweep command"
grep -q 'log/modules_\*\.log' "$ROOT/runtime/asb_lsposed.sh" || fail "the sweep does not touch the modules log"
grep -q 'status|apply|sweep|restore|open' "$ROOT/runtime/asb_lsposed.sh" || fail "usage line not updated"
grep -q 'asb_lsposed.sh" sweep' "$ROOT/service.sh" || fail "no sweep loop in service.sh"
grep -qE 'asb_lsposed\.sh"?\s+apply\b' "$ROOT/service.sh" && fail "the LSPosed setting is written at boot"
asb_has_test test_lsposed_verbose_runtime.sh || fail "lsposed runtime test missing"
# The card tells the user about the modules-log cleaning in every shipped language.
grep -q 'The modules log - what the LSPosed modules themselves write - has no switch' "$H" || fail "the English card text is silent about the modules log"
for _l in ru:лога\ модулей uk:логу\ модулів de:Modulprotokoll es:registro\ de\ módulos fr:journal\ des\ modules it:log\ dei\ moduli pt:log\ de\ módulos tr:Modül\ günlüğünün id:Log\ modul ar:سجل\ الوحدات hy:Մոդուլների\ լոգը zh:模块日志; do
  _f="$_l"; _lang="${_f%%:*}"; _word="${_f#*:}"
  grep -q "$_word" "$ROOT/webroot/i18n/$_lang.json" || fail "$_lang.json: the card text is silent about the modules log"
done
echo "PASS: fix197 contract"
) || exit 1
echo "PASS: field-fix contracts"
)

t_boot_override_noop_runtime() (
# Runtime (fix188): the boot pass leaves governor.conf alone when the override flag already
# says what it would write. It used to replace the file on every boot a few seconds after the
# governor read it - an extra reload, "governor.conf changed after the governor started" in
# every boot asbdiag, and this write as the "last config transaction" over the user's own.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL boot override noop: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mod/config" "$T/mod/runtime"
awk '/^asb_thermal_mode_apply\(\) \{$/ { b = 1 } b { print } b && /^}$/ { exit }' "$ROOT/service.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || fail "function not found"
printf 'echo "$*" >> "%s/calls"\n' "$T" > "$T/mod/runtime/asb_config_safe.sh"
run() { ( MODDIR="$T/mod"; asb_log() { :; }; . "$T/fn.sh"; asb_thermal_mode_apply ) }
printf 'sustained_temp_mode=manual\nsustained_temp_user_override=1\n' > "$T/mod/config/governor.conf"
run; [ ! -s "$T/calls" ] || fail "an unchanged flag was written again: $(cat "$T/calls")"
printf 'sustained_temp_mode=manual\nsustained_temp_user_override=0\n' > "$T/mod/config/governor.conf"
run; grep -qx 'set sustained_temp_user_override 1' "$T/calls" || fail "a changed flag was not written: $(cat "$T/calls" 2>/dev/null)"
: > "$T/calls"
printf 'sustained_temp_mode=smart\nsustained_temp_user_override=1\n' > "$T/mod/config/governor.conf"
run; grep -qx 'set sustained_temp_user_override 0' "$T/calls" || fail "leaving manual does not clear the flag"
echo "PASS boot override noop: governor.conf is rewritten at boot only when the flag changes"
)

t_offdrain_by_profile_runtime() (
# Runtime (fix189): a screen-off window counts for the profile it ran in. The phone-wide
# figure went onto whichever card was running: an OP15 switched from Smart to Balanced showed
# Smart's 0.70 %/h on Balanced's card a minute later. The REAL governor code runs: a Smart
# night counts for Smart, a window with a switch in it counts only phone-wide, both survive a
# restart through their files.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL offdrain by profile: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP offdrain by profile: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
G="$ROOT/src/asb_governor.c"
awk '/^#define ASB_OFFDRAIN_FILE /{ b = 1 } b { print } b && /^static void asb_offdrain_track\(/ { t = 1 } t && /^}$/ { exit }' "$G" \
  | sed "s#/data/adb/asb/offdrain_pctph_x100#$T/od#; s#/data/adb/asb/offdrain_profiles#$T/odp#" > "$T/od.inc"
grep -q 'g_offdrain_p_x100\[wp\]' "$T/od.inc" || fail "per-profile accounting not found"
cat > "$T/m.c" <<C
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static long g_now;
static long asb_clock_ms(clockid_t w) { (void)w; return g_now; }
static int metrics_pcm_playing(void) { return -1; }
#include "$T/od.inc"
#define MIN 60000L
int main(void) {
    /* Smart (3): off 2 h, 3 % down, on for 3 min */
    g_now = 1000; asb_offdrain_track(0, 80, 0, 3);
    g_now += 120 * MIN; asb_offdrain_track(1, 77, 0, 3);
    g_now += 3 * MIN; asb_offdrain_track(1, 77, 0, 3);
    /* off in Smart, switched to Balanced (1) during the night */
    g_now += 1 * MIN; asb_offdrain_track(0, 77, 0, 3);
    g_now += 60 * MIN; asb_offdrain_track(0, 76, 0, 1);
    g_now += 60 * MIN; asb_offdrain_track(1, 74, 0, 1);
    g_now += 3 * MIN; asb_offdrain_track(1, 74, 0, 1);
    printf("%d %d %d %d %d %d\n", g_offdrain_x100, g_offdrain_n, g_offdrain_p_x100[3], g_offdrain_p_n[3], g_offdrain_p_x100[1], g_offdrain_p_n[1]);
    return 0;
}
C
"$CC" -std=gnu11 -Wall -Werror -o "$T/m" "$T/m.c" || fail "does not compile"
out="$("$T/m")"
set -- $out
[ "$2" = 2 ] || fail "both windows count phone-wide: $out"
[ "$3" = 150 ] && [ "$4" = 1 ] || fail "the Smart night is not Smart's: $out"
[ "$5" = -1 ] && [ "$6" = 0 ] || fail "a night with a switch in it was given to Balanced: $out"
grep -qx 'smart 150 1' "$T/odp" || fail "per-profile figure not kept on disk: $(cat "$T/odp" 2>/dev/null)"
grep -q '"offdrain_by_profile="' "$G" || fail "not published in the state"
echo "PASS offdrain by profile: a window counts for the profile that held it from screen-off to screen-on"
)

t_action_idle_per_profile_runtime() (
# Runtime (fix196): the action page's idle figure is the CURRENT profile's own measurement -
# the number the WebUI shows on the profile's card - not the phone-wide one. An OP15 on
# Smart printed "idle measured 0.63 %/h (6 windows)" in the action sheet while the Smart card
# and the Monitor tile said 0.42 %/h (1 window): same minute, two figures, one phone. The
# REAL block from action.sh runs against a state file that carries both scopes.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL action idle per-profile: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
A="$ROOT/action.sh"
awk '/^_offx="\$\(grep -m1/{f=1} f{print} f && /^_idle_measured=0/{g=1} g && /^fi$/{exit}' "$A" \
  | sed "s#/dev/.asb/state#$T/state#g" > "$T/blk.sh"
grep -q 'offdrain_by_profile' "$T/blk.sh" || fail "the block does not read the per-profile figure"
grep -q '^fi$' "$T/blk.sh" || fail "extraction stopped before the ETA branch"
run_blk() { # $1=profile -> "offx offn measured toff_min"
  PROFILE="$1" _lvl=53 _remain_mah=0 _off_ma=0 sh -c ". '$T/blk.sh'; printf '%s %s %s %s\n' \"\$_offx\" \"\$_offn\" \"\$_idle_measured\" \"\$_toff_min\""
}
cat > "$T/state" <<'S'
offdrain_pctph_x100=63
offdrain_windows=6
offdrain_by_profile=battery:37:1,balanced:-1:0,performance:-1:0,smart:42:1
S
out="$(run_blk smart)"
[ "$out" = "42 1 1 7571" ] || fail "Smart must see its own 0.42 %/h (1 window): $out"
out="$(run_blk balanced)"
[ "$out" = "63 6 1 5047" ] || fail "a profile with no clean window falls back to phone-wide: $out"
# No per-profile key at all: the phone-wide figure stands, as before fix189 existed.
cat > "$T/state" <<'S'
offdrain_pctph_x100=63
offdrain_windows=6
S
out="$(run_blk smart)"
[ "$out" = "63 6 1 5047" ] || fail "missing per-profile key must keep the phone-wide figure: $out"
echo "PASS action idle per-profile: the action sheet shows the same idle figure as the profile's card"
)


t_profile_net_reassert_runtime() (
# Runtime (fix168): a profile switch never leaves the network on the profile's rails.
#
# Owner's capture switched Smart <-> Stock several times. Afterwards asbdiag said "queue (other
# networks): requested fq_codel, running pfifo_fast" and the Wi-Fi transmit queue sat at the
# profile's 1024 instead of the user's 256. Stock restores the profile baseline, and that
# baseline also held default_qdisc because boot captured it; on the way back profile_core
# wrote its WIFI_TXQLEN over net_txqueue. Neither path ran the WebUI network appliers again.
# The worker is run here with stub appliers and a stub profile core.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL profile net reassert: $*" >&2; exit 1; }
AP="$ROOT/apply_profile.sh"
SP="$ROOT/runtime/asb_stock_policy.sh"
python3 - "$AP" "$SP" "$ROOT/action.sh" <<'P' || fail "order"
import sys
ap = open(sys.argv[1], encoding='utf-8').read()
w = ap[ap.index('_passes=4'):ap.index('asb_log "worker done profile=$PROFILE rc=$_rc"')]
blk = w[w.index('  done\n'):]
assert 'if [ "$PROFILE" != "stock" ] && profile_epoch_current; then' in blk, "no guarded re-assert after the profile passes"
assert blk.index('asb_net_offload.sh') < blk.index('asb_net_apply.sh'), "transmit queue and qdisc appliers out of order"
sp = open(sys.argv[2], encoding='utf-8').read()
e = sp[sp.index('asb_stock_enter() {'):sp.index('asb_stock_leave() {')]
assert e.index('asb_stock_restore_profile_runtime') < e.index('runtime/asb_net_apply.sh'), "Stock re-applies the network before the baseline restore"
assert '>/dev/null 2>&1 & )' in e, "Stock waits for the network applier"
act = open(sys.argv[3], encoding='utf-8').read()
assert """[ "$PROFILE" = "stock" ] || pgrep -f 'asb_governor|/asb$' >/dev/null 2>&1 || _add_bad "$T_B_GOV\"""" in act, "the action screen still calls a stopped governor a problem on Stock"
P
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/runtime"
printf 'echo offload >> "%s/order"\n' "$T" > "$T/runtime/asb_net_offload.sh"
printf 'echo apply >> "%s/order"\n' "$T" > "$T/runtime/asb_net_apply.sh"
for prof in balanced stock; do
  rm -f "$T/order"
  cat > "$T/w.sh" <<EOF
MODDIR="$T"; PROFILE="$prof"; _rc=0; _i=1
asb_log() { :; }
asb_apply_profile_once() { echo pass >> "$T/order"; }
profile_epoch_current() { return 0; }
sleep() { :; }
EOF
  sed -n '/^  _passes=4$/,/^  asb_log "worker done profile=\$PROFILE rc=\$_rc"$/p' "$AP" | sed 's/^  //' >> "$T/w.sh"
  sh "$T/w.sh"
  got="$(tr '\n' ' ' < "$T/order")"
  if [ "$prof" = stock ]; then
    [ "$got" = "pass " ] || fail "Stock ran the user network appliers inside the release pass: $got"
  else
    [ "$got" = "pass pass pass pass offload apply " ] || fail "balanced: $got"
  fi
done
echo "PASS profile net reassert: the WebUI network settings are applied again after every profile switch and after the Stock baseline restore"
)

t_asbdiag_stock_governor_runtime() (
# Runtime (fix169): asbdiag finds the governor itself, and on Stock expects it stopped.
#
# Owner's Stock asbdiag: "[PASS] ASB governor process alive" ten minutes after the governor
# stopped. The fallback pattern '/asb' matched any process with that in its command line - the
# running /system/bin/asbdiag included - so the check could not fail, on Stock or after a crash.
# Its Smart learning and thermal source sections then read an absent state file as "expected a
# session by now" and "uninitialized". The REAL lines run with a fake pgrep that answers '/asb'
# the way the phone did.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL asbdiag stock governor: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/mod"
cat > "$T/bin/pgrep" <<'S'
#!/bin/sh
shift
case "$1" in
  '/bin/asb$') [ "${FAKE_GOV:-0}" = 1 ] && echo 4242 ;;
  *asb*) echo 777 ;;
esac
exit 0
S
chmod +x "$T/bin/pgrep"
for prof in stock smart; do
  for gov in 0 1; do
    printf '%s\n' "$prof" > "$T/mod/current_profile"
    {
      echo "MODDIR='$T/mod'; OUT1=''; OUT2=''; PASS=0; FAIL=0; NA=0; INFO=0; CHK_LIST=''"
      echo "gp() { :; }"
      sed -n '/^P()  { printf/p; /^V() {/,/^}/p; /^NOTE(){ /p' "$D"
      sed -n '/^_gov_pid="\$(pgrep/,/^fi$/p' "$D"
    } > "$T/run.sh"
    out="$(FAKE_GOV=$gov PATH="$T/bin:$PATH" sh "$T/run.sh" 2>&1)"
    case "$prof/$gov" in
      stock/0) printf '%s\n' "$out" | grep -q '^  \[PASS\] ASB governor stopped (Stock profile)$' || fail "Stock, stopped: $out" ;;
      stock/1) printf '%s\n' "$out" | grep -q '^  \[FAIL\] ASB governor stopped (Stock profile)$' || fail "Stock with a governor running must fail: $out" ;;
      smart/0) printf '%s\n' "$out" | grep -q '^  \[FAIL\] ASB governor process alive$' || fail "a dead governor passed because asbdiag itself matched: $out" ;;
      smart/1) printf '%s\n' "$out" | grep -q '^  \[PASS\] ASB governor process alive$' || fail "running governor: $out" ;;
    esac
  done
done
grep -q "pgrep -f '/asb' " "$D" && fail "the loose '/asb' pattern is back"
grep -q 'NOTE "Stock profile: the governor is stopped, so Smart neither learns nor decides' "$D" || fail "Smart learning section reads an absent state on Stock"
grep -q 'NOTE "control source: none - Stock profile' "$D" || fail "thermal source section reads an absent state on Stock"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag is stale"
echo "PASS asbdiag stock governor: the governor is looked up by its own binary, expected stopped on Stock, and the learning sections say why they are empty"
)

t_intent_backup() (
# intent_backup — intent transaction and backup preview regression.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_intent.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
mkdir -p "$MOD/runtime" "$MOD/tools"
cp -a "$ROOT_DIR/config" "$MOD/config"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
chmod 0755 "$MOD/runtime/asb_config_safe.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
get() { awk -F= -v k="$1" '$1==k {print $2; exit}' "$MOD/config/governor.conf"; }
export MODDIR="$MOD"
export ASB_CONFIG_STATE="$TMP/state"
export ASB_INTENT_STATE="$TMP/intent"

sh "$ROOT_DIR/tools/asb_intent.sh" apply travel >/dev/null
[ "$(get perf_ceiling_pct)" = "75" ] || fail 'travel ceiling'
[ "$(get smart_battery_bias)" = "400" ] || fail 'travel battery bias'
sh "$ROOT_DIR/tools/asb_intent.sh" apply daily >/dev/null
[ "$(get perf_ceiling_pct)" = "90" ] || fail 'daily ceiling'
[ "$(get smart_battery_bias)" = "0" ] || fail 'daily resets travel bias'

BACKUP="$TMP/asb.backup"
sh "$ROOT_DIR/tools/asb_config_backup.sh" create "$BACKUP" >/dev/null
if ! [ -s "$BACKUP" ] || ! [ -s "$BACKUP.sha256" ]; then fail 'backup/checksum missing'; fi
sh "$ROOT_DIR/tools/asb_config_backup.sh" preview "$BACKUP" >/dev/null
printf 'thermal_overlay_pct=999\n' >> "$BACKUP"
if sh "$ROOT_DIR/tools/asb_config_backup.sh" preview "$BACKUP" >/dev/null 2>&1; then
  fail 'tampered checksum accepted'
fi

echo 'PASS intent backup'
)

t_named_config_profiles() (
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT_DIR/tools/asb_config_backup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"; STATE="$TMP/state"; SMART="$TMP/smart"; EXPORT_ROOT="$TMP/external"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE" "$SMART"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
run() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_SMART_STATE="$SMART" ASB_SMART_RESTORE_SKIP_DAEMON=1 ASB_PROFILE_EXPORT_ROOT="$EXPORT_ROOT" sh "$HELPER" "$@"; }
need() { grep -Fqx "$2" "$1" >/dev/null || { echo "FAIL: missing [$2]" >&2; exit 1; }; }
KEYS='gnss_trim night_modem_idle doze_level wifi_country'
# Minimal non-empty artifacts: helper hashes and bounds bytes while native validates its own
# binary magic/version at boot. The complete portable state includes compact Smart model,
# bounded session history and all aggregate persistent stats read by startup feedback.
printf 'bucket-learning-fixture\n' > "$SMART/buckets.bin"
printf 'bucket-fallback-fixture\n' > "$SMART/buckets.bin.bak"
printf 'appheat-learning-fixture\n' > "$SMART/smart_appheat.bin"
printf 'sleep_min=1380\nwake_min=420\nsamples=12\n' > "$SMART/night_window.conf"
printf '1\n' > "$SMART/smart_mode_enabled"
printf 'balanced\n' > "$SMART/smart_prev_profile"
printf '{"v":9,"profile":"battery","dur":360,"bat_ttd":75,"bat_deep":120,"bat_light":80,"bat_mod":100}\n' > "$SMART/session_history.jsonl"
printf '{"count":5,"t2s":30}\n' > "$MOD/runtime/session_stats.json"
printf '{"count":4,"t2s":20}\n' > "$MOD/runtime/pstats_battery.json"
printf '{"count":5,"t2s":30}\n' > "$MOD/runtime/pstats_balanced.json"
printf '{"count":3,"t2s":10}\n' > "$MOD/runtime/pstats_performance.json"

_create_out="$(run create battery-test $KEYS)"
printf '%s\n' "$_create_out" | grep -q '^smart_learning=saved$' || { echo 'FAIL: Smart learning was not saved' >&2; exit 1; }
printf '%s\n' "$_create_out" | grep -q '^smart_learning_files=11$' || { echo 'FAIL: complete Smart payload count missing' >&2; exit 1; }
printf '%s\n' "$_create_out" | grep -q '^smart_learning_bytes=[1-9][0-9]*$' || { echo 'FAIL: Smart payload byte count missing' >&2; exit 1; }
run list | grep -q '^battery-test|.*|ok|saved$' || { echo 'FAIL: profile not listed with saved Smart learning' >&2; exit 1; }
[ -f "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: profile missing' >&2; exit 1; }
[ -f "$STATE/config_profiles/battery-test.smart/manifest" ] || { echo 'FAIL: Smart learning manifest missing' >&2; exit 1; }
grep -Fqx '# ASB_SMART_PROFILE_SCHEMA=3' "$STATE/config_profiles/battery-test.smart/manifest" || { echo 'FAIL: Smart schema 3 manifest missing' >&2; exit 1; }
grep -q '^session_history.jsonl|' "$STATE/config_profiles/battery-test.smart/manifest" || { echo 'FAIL: session history missing from Smart payload' >&2; exit 1; }
grep -q '^session_stats.json|' "$STATE/config_profiles/battery-test.smart/manifest" || { echo 'FAIL: session aggregate missing from Smart payload' >&2; exit 1; }
grep -q '^pstats_battery.json|' "$STATE/config_profiles/battery-test.smart/manifest" || { echo 'FAIL: battery persistent stats missing from Smart payload' >&2; exit 1; }
run preview battery-test $KEYS | grep -q 'Smart learning' || { echo 'FAIL: preview did not disclose Smart learning payload' >&2; exit 1; }

# Restore must be one writer transaction and restore every learning artifact atomically.
sed -i 's/^gnss_trim=.*/gnss_trim=1/' "$MOD/config/governor.conf"
rm -f "$SMART/buckets.bin" "$SMART/buckets.bin.bak" "$SMART/smart_appheat.bin" "$SMART/night_window.conf" "$SMART/smart_mode_enabled" "$SMART/smart_prev_profile" "$SMART/session_history.jsonl"
rm -f "$MOD/runtime/session_stats.json" "$MOD/runtime/pstats_battery.json" "$MOD/runtime/pstats_balanced.json" "$MOD/runtime/pstats_performance.json"
_restore_out="$(run restore battery-test $KEYS)"
printf '%s\n' "$_restore_out" | grep -q '^smart_learning=restored$' || { echo 'FAIL: Smart learning did not restore' >&2; exit 1; }
printf '%s\n' "$_restore_out" | grep -q '^smart_learning_files=11$' || { echo 'FAIL: Smart restore count missing' >&2; exit 1; }
printf '%s\n' "$_restore_out" | grep -q '^smart_learning_bytes=[1-9][0-9]*$' || { echo 'FAIL: Smart restore byte count missing' >&2; exit 1; }
need "$MOD/config/governor.conf" 'gnss_trim=0'
[ -s "$SMART/buckets.bin" ] && [ -s "$SMART/buckets.bin.bak" ] && [ -s "$SMART/smart_appheat.bin" ] && [ -s "$SMART/night_window.conf" ] && [ "$(cat "$SMART/smart_mode_enabled")" = 1 ] && [ "$(cat "$SMART/smart_prev_profile")" = balanced ] || { echo 'FAIL: restored compact learner state missing' >&2; exit 1; }
grep -Fq '"bat_ttd":75' "$SMART/session_history.jsonl" || { echo 'FAIL: session history was not restored' >&2; exit 1; }
grep -Fq '"count":5' "$MOD/runtime/session_stats.json" || { echo 'FAIL: aggregate session stats were not restored' >&2; exit 1; }
grep -Fq '"count":4' "$MOD/runtime/pstats_battery.json" || { echo 'FAIL: battery persistent stats were not restored' >&2; exit 1; }
grep -Fq '"count":5' "$MOD/runtime/pstats_balanced.json" || { echo 'FAIL: balanced persistent stats were not restored' >&2; exit 1; }
grep -Fq '"count":3' "$MOD/runtime/pstats_performance.json" || { echo 'FAIL: performance persistent stats were not restored' >&2; exit 1; }

# External copies are atomic and carry the full Smart sidecar. Arbitrary paths remain forbidden.
run export battery-test downloads >/dev/null
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.conf" ] || { echo 'FAIL: Downloads export missing' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.smart/manifest" ] || { echo 'FAIL: Downloads Smart learning copy missing' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.smart/buckets.bin.bak" ] || { echo 'FAIL: Downloads Smart fallback copy missing' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.smart/smart_mode_enabled" ] || { echo 'FAIL: Downloads Smart mode state missing' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.smart/session_history.jsonl" ] || { echo 'FAIL: Downloads session history missing' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.smart/pstats_battery.json" ] || { echo 'FAIL: Downloads battery persistent stats missing' >&2; exit 1; }
run list-external downloads | grep -q '^battery-test|.*|ok|saved$' || { echo 'FAIL: exported profile not listed with Smart learning' >&2; exit 1; }
if run export battery-test ../../escape >/dev/null 2>&1; then echo 'FAIL: arbitrary export destination accepted' >&2; exit 1; fi
run delete battery-test >/dev/null
run import-external downloads battery-test >/dev/null
[ -f "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: exported profile did not re-import' >&2; exit 1; }
[ -f "$STATE/config_profiles/battery-test.smart/manifest" ] || { echo 'FAIL: exported Smart learning did not re-import' >&2; exit 1; }
# A corrupt sidecar is skipped, while the independently checksummed settings profile remains restorable.
printf 'tamper' >> "$STATE/config_profiles/battery-test.smart/buckets.bin"
rm -f "$SMART/buckets.bin"
run restore battery-test $KEYS | grep -q 'smart_learning=skipped_invalid' || { echo 'FAIL: corrupt Smart learning was not rejected' >&2; exit 1; }
[ ! -e "$SMART/buckets.bin" ] || { echo 'FAIL: corrupt Smart learning reached live state' >&2; exit 1; }

# Invalid names cannot escape the profile store and checksum corruption blocks restore.
if run create '../escape' $KEYS >/dev/null 2>&1; then echo 'FAIL: traversal profile name accepted' >&2; exit 1; fi
printf '%s\n' '# tamper' >> "$STATE/config_profiles/battery-test.conf"
if run restore battery-test $KEYS >/dev/null 2>&1; then echo 'FAIL: checksum mismatch accepted' >&2; exit 1; fi
run delete battery-test >/dev/null
[ ! -e "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: profile not deleted' >&2; exit 1; }

# Screenshot path compatibility: the manager recognises only the exact legacy backup name,
# validates its ASB header, computes a checksum and exposes it as a bounded profile row.
mkdir -p "$EXPORT_ROOT/Documents"
printf '# ASB_BACKUP_SCHEMA=2\ngnss_trim=1\n' > "$EXPORT_ROOT/Documents/asb_settings_backup.conf"
run list-external documents | grep -q '^asb-settings-backup|1|ok|empty$' || { echo 'FAIL: legacy Documents backup was not migrated' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Documents/ASB-Profiles/asb-settings-backup.conf.sha256" ] || { echo 'FAIL: migrated backup lacks checksum' >&2; exit 1; }
run import-external documents asb-settings-backup >/dev/null
run restore asb-settings-backup $KEYS >/dev/null
need "$MOD/config/governor.conf" 'gnss_trim=1'

echo 'PASS named config profiles contract'
)

t_p0_provenance_contract() (
# P0 provenance contract: all fixtures stay under mktemp; do not create /data/adb.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
WRITER="$ROOT_DIR/runtime/asb_config_safe.sh"
POLICY="$ROOT_DIR/tools/asb_effective_policy.sh"
STATE_SRC="$ROOT_DIR/src/asb_governor.c"
METRICS_SRC="$ROOT_DIR/src/asb_metrics.h"
SCREENOFF="$ROOT_DIR/runtime/asb_screenoff_class.sh"
LOGKIT="$ROOT_DIR/tools/logkit/_asb_logkit_common.sh"
WEBUI="$ROOT_DIR/webroot/index.html"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_p0_contract.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
need_line() { grep -qx "$2" "$1" || fail "missing '$2' in $1"; }
need_text() { grep -Fq "$2" "$1" || fail "missing text '$2' in $1"; }

# Native producer: consumers must never invent these fields independently.
need_text "$STATE_SRC" 'startup_quarantined=%lu'
need_text "$STATE_SRC" 'thermal_control_source=\"%s\"'
need_text "$STATE_SRC" 'thermal_source_confidence=%d'
need_text "$STATE_SRC" 'thermal_rejected_type=\"%s\"'
need_text "$STATE_SRC" 'thermal_rejected_raw=%d'
need_text "$STATE_SRC" 'if (m->bat.charging)'
need_text "$METRICS_SRC" 'ASB_SOCD_MAX_ABOVE_PEERS_C 25'
need_text "$METRICS_SRC" 'g_thermal_cpu_zone = fallback_zone'
need_text "$METRICS_SRC" 'g_thermal_cpu_fallback_zone = -1'
need_text "$METRICS_SRC" 'strcmp(g_thermal_cpu_type, "socd") == 0'

# The classifier may record its own observation but must not write a system node or setting.
if grep -nE '>[[:space:]]*/sys/|settings[[:space:]]+put|setprop[[:space:]]' "$SCREENOFF" >/dev/null; then
  fail "screen-off classifier contains a system-policy write"
fi

# Thermal slider transaction must keep its linked ceiling coherent when the user
# selects 69–70°C above the previous Smart ceiling. The writer validates the staged
# file as a whole, so WebUI must publish the matching value in the same set-many call.
need_text "$WEBUI" "shQuote('sustained_temp_ceiling') + ' ' + shQuote(val)"

# Transaction writer must use the injected state path, not a hard-coded production location.
need_text "$WRITER" 'ASB_TXN="${ASB_CONFIG_TXN:-$STATE/config_last_txn}"'
if grep -Fq 'ASB_TXN="/data/adb/asb/config_last_txn"' "$WRITER"; then
  fail "writer hard-codes production transaction path"
fi

MOD="$TMP/module"
CFG_STATE="$TMP/config-state"
RUNTIME_STATE="$TMP/runtime.state"
mkdir -p "$MOD/config" "$CFG_STATE"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"

MODDIR="$MOD" ASB_CONFIG_STATE="$CFG_STATE" sh "$WRITER" set sustained_temp_enter 60 >/dev/null
TXN="$CFG_STATE/config_last_txn"
[ -f "$TXN" ] || fail "isolated writer did not create transaction record"
need_line "$TXN" 'result_class=success'
need_line "$TXN" 'reason=applied'
need_line "$TXN" 'key=sustained_temp_enter'
need_line "$TXN" 'reload_accepted=not_requested'
grep -Eq '^pre_epoch=[0-9]+$' "$TXN" || fail "transaction missing numeric pre_epoch"
grep -Eq '^post_epoch=[0-9]+$' "$TXN" || fail "transaction missing numeric post_epoch"

printf '%s\n' \
  'thermal_control_source="cpu-1-1-0"' \
  'thermal_control_zone=7' \
  'thermal_source_confidence=1' \
  'thermal_rejected_type="socd"' \
  'thermal_rejected_raw=92000' \
  'startup_quarantined=4' > "$RUNTIME_STATE"
MODDIR="$MOD" ASB_CONFIG_STATE="$CFG_STATE" ASB_RUNTIME_STATE="$RUNTIME_STATE" \
  sh "$POLICY" > "$TMP/effective_policy.json"
# jq is installed in the release/debug workflows. Keep portable writer/source assertions above
# meaningful locally, and do not paint a false failure when only the optional JSON validator is absent.
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP P0 provenance JSON semantic assertions: jq not installed (CI installs jq)"
  exit 0
fi
jq -e '.thermal_provenance == {"control_source":"cpu-1-1-0","control_zone":7,"confidence":1,"rejected_type":"socd","rejected_raw":92000,"startup_quarantined":4}' "$TMP/effective_policy.json" >/dev/null \
  || fail "thermal provenance JSON object is invalid or incomplete"
jq -e '.config_last_txn.result_class == "success" and .config_last_txn.reason == "applied" and .config_last_txn.reload_accepted == "not_requested" and .config_last_txn.recovery == ""' "$TMP/effective_policy.json" >/dev/null \
  || fail "config transaction JSON object is invalid or incomplete"

# logkit must retain thermal confidence/rejection in its transition trace and snapshots.
need_text "$LOGKIT" '"thermal_src_conf"'
need_text "$LOGKIT" '"thermal_rejected_type"'
need_text "$LOGKIT" 'config_last_txn (writer provenance)'

echo "PASS P0 provenance contract"
)

t_package_functional_parity_contract() (
# Contract: release and testN share one complete diagnostic feature set and package definition.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REL="$ROOT/.github/workflows/build-release.yml"
TEST="$ROOT/.github/workflows/build-test.yml"

need() { grep -Fq -- "$2" "$1" || { echo "FAIL package parity: missing [$2] in ${1##*/}" >&2; exit 1; }; }
not_need() { ! grep -Fq -- "$2" "$1" || { echo "FAIL package parity: forbidden [$2] in ${1##*/}" >&2; exit 1; }; }

for wf in "$REL" "$TEST"; do
  [ -f "$wf" ] || { echo "FAIL package parity: missing workflow $wf" >&2; exit 1; }
  need "$wf" 'bin/asb_dsp_attach'
  need "$wf" 'system/bin/asbdiag'
  need "$wf" 'runtime/asb_debug_support.sh'
  need "$wf" 'runtime/asb_wifi_fallback.sh'
  need "$wf" 'runtime/asb_stock_policy.sh'
done

# Support actions are unified: no version suffix may disable them on a public release.
not_need "$ROOT/runtime/asb_debug_support.sh" 'debug_only'
need "$ROOT/src/build_ndk_release.sh" '-DASB_DEBUG_BUILD=1'
need "$REL" 'ASB_BUILD_MODE=release'
need "$TEST" 'ASB_BUILD_MODE=test'
need "$ROOT/runtime/asb_wifi_fallback.sh" 'asb_wifi_fallback'
need "$ROOT/runtime/asb_stock_policy.sh" 'asb_stock_enter'

# Release must retain every normal on-device capture and support script. They are POSIX shell,
# are used by users to collect support evidence, and must remain available in both release and testN.
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

# Compare the actual staging definitions, not merely a list of names. Only package identity
# may differ: testN must not silently lose a diagnostic helper or gain a dev-only payload.
python3 - "$REL" "$TEST" <<'PY_PARITY'
import sys
from pathlib import Path
r, t = (Path(p).read_text(encoding='utf-8') for p in sys.argv[1:])
def block(s, start, end):
    i = s.index(start)
    return s[i:s.index(end, i)]
rb = block(r, '          rsync -a ./ "$PKG_REL"/', '          ASB_COMMIT=')
tb = block(t, '          rsync -a ./ "$PKG_TEST"/', '          BASE_VER=')
tb = tb.replace('PKG_TEST', 'PKG_REL').replace('pkg-test', 'pkg-release')
assert rb == tb, 'release/test staging definitions diverged'
PY_PARITY

echo 'PASS release/test functional package parity contract'
)

t_profile_uv_webui_package_contract() (
# Contract: named profiles must remain installed and user-visible. External kernel/UV evidence
# remains diagnostics-only (asbdiag/helper); it must not occupy a WebUI card or infer a result
# from ambiguous vendor properties.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UI="$ROOT/webroot/index.html"
REL="$ROOT/.github/workflows/build-release.yml"
TEST="$ROOT/.github/workflows/build-test.yml"
HELPER="$ROOT/tools/asb_config_backup.sh"
UV="$ROOT/tools/asb_kernel_uv_coexist.sh"
INSTALL="$ROOT/common/install.sh"
fail() { echo "FAIL profile/UV package contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
absent() { ! grep -Fq "$2" "$1" || fail "unexpected [$2] in $1"; }
[ -f "$HELPER" ] || fail 'backup helper source missing'
[ -f "$UV" ] || fail 'UV helper source missing'
[ -f "$INSTALL" ] || fail 'installer source missing'

# Installer prune must retain both user-visible profile helper and diagnostics-only UV helper.
# The whitelist now lives in tools/release_tools.list (the manifest the release workflow also
# ships from). Instead of duplicating the prune expression here - the copy is how the old test
# passed while the installer deleted shipped tools - the REAL block is extracted from
# install.sh between its markers and executed against a scratch module dir.
MF="$ROOT/tools/release_tools.list"
[ -f "$MF" ] || fail 'release tools manifest missing'
need "$INSTALL" '_rt_list="$MODPATH/tools/release_tools.list"'
need "$INSTALL" '# asb_tools_prune_begin'
need "$INSTALL" '# asb_tools_prune_end'
need "$MF" 'asb_config_backup.sh'
need "$MF" 'asb_kernel_uv_coexist.sh'
need "$INSTALL" 'chmod 0755 "$MODPATH/tools/asb_config_backup.sh"'
need "$INSTALL" 'chmod 0755 "$MODPATH/tools/asb_kernel_uv_coexist.sh"'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/tools"
cp "$HELPER" "$TMP/tools/asb_config_backup.sh"
cp "$UV" "$TMP/tools/asb_kernel_uv_coexist.sh"
cp "$MF" "$TMP/tools/release_tools.list"
printf '%s\n' '#!/system/bin/sh' > "$TMP/tools/unrelated_dev_tool.sh"
sed -n '/^# asb_tools_prune_begin$/,/^# asb_tools_prune_end$/p' "$INSTALL" > "$TMP/prune.sh"
[ -s "$TMP/prune.sh" ] || fail 'no asb_tools_prune block in install.sh'
MODPATH="$TMP" sh "$TMP/prune.sh" || fail 'extracted installer prune block did not run'
[ -f "$TMP/tools/asb_config_backup.sh" ] || fail 'installer prune deletes profile helper'
[ -f "$TMP/tools/asb_kernel_uv_coexist.sh" ] || fail 'installer prune deletes UV helper'
[ ! -e "$TMP/tools/unrelated_dev_tool.sh" ] || fail 'installer prune no longer removes unrelated tool'
# The CI-ships-it / install-keeps-it contract, executed for real: with every manifest tool
# present, the prune must keep ALL of them and still remove a dev-only file.
for _n in $(sed 's/#.*//; s/[ \t\r]//g; /^$/d' "$MF"); do
  [ -f "$TMP/tools/$_n" ] || printf '%s\n' '#!/system/bin/sh' > "$TMP/tools/$_n"
done
printf '%s\n' '# dev only' > "$TMP/tools/zz_dev_only.py"
MODPATH="$TMP" sh "$TMP/prune.sh" || fail 'second prune run did not run'
for _n in $(sed 's/#.*//; s/[ \t\r]//g; /^$/d' "$MF"); do
  [ -f "$TMP/tools/$_n" ] || fail "installer prune deletes CI-shipped tool: $_n"
done
[ ! -e "$TMP/tools/zz_dev_only.py" ] || fail 'installer prune keeps a dev-only tool'

# Both workflows must preserve and verify the exact helpers in their flashable packages.
for WF in "$REL" "$TEST"; do
  need "$WF" 'tools/asb_config_backup.sh'
  need "$WF" 'tools/asb_kernel_uv_coexist.sh'
done

# Profile controls are explicit, readable and remain the only storage UI. There is no arbitrary
# filesystem picker: closed profile names/checksums and transactional restore remain mandatory.
need "$UI" "const CFG_PROFILE_HELPER = MD + '/tools/asb_config_backup.sh';"
need "$UI" 'data-i18n="cfg_profile_save_short"'
need "$UI" 'data-i18n="cfg_profile_load_short"'
absent "$UI" 'data-i18n="cfg_profile_storage_hint"'
need "$UI" 'grid-template-columns: repeat(3, minmax(0, 1fr))'
need "$UI" '#cfgActionsRow .cfg-backup { min-width: 0; min-height: 40px; padding: 8px 5px; font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }'
need "$UI" 'onclick="cfgResetDialogOpen()" data-i18n="cfg_smart_reset"'
absent "$UI" 'id="cfgResetRow"'
need "$UI" 'id="cfgResetModal"'
need "$UI" '.cfg-reset-modal { position:fixed; z-index:1410; inset:0; display:flex; align-items:center; justify-content:center; padding:20px; background:rgba(0,0,0,.91); backdrop-filter:none; -webkit-backdrop-filter:none; }'
need "$UI" 'background:#000 padding-box'
need "$UI" '.cfg-reset-choice { width:100%; display:block; margin:0 0 9px; padding:13px 12px; text-align:left; border:1px solid rgba(255,255,255,.14); border-radius:14px; color:#eef5f3; background:#050505; }'
need "$UI" 'function cfgResetDialogOpen()'
need "$UI" "cfgResetDialogRun('settings')"
need "$UI" "cfgResetDialogRun('smart')"
need "$UI" "MD + '/config/governor.conf.shipped'"
need "$UI" "MD + '/runtime/asb_config_safe.sh'"
need "$UI" "MD + '/runtime/asb_smart_reset.sh'"
# Pin the requirement, not the declaration.
#
# This held the padding shorthand verbatim, so adjusting the bottom gap failed a contract
# that exists to check packaging. Second time in two visual changes - the same fragile
# pattern the work log warns about.
#
# What matters is that the sheet respects the safe area at all; the exact values are a
# layout decision.
need "$UI" 'env(safe-area-inset-bottom'
need "$UI" 'env(safe-area-inset-left'
need "$UI" 'min-height: min(36vh, 500px); max-height: min(88vh, 780px);'
# Pin what the sheet must HAVE, not one exact declaration string.
#
# This pinned the whole style verbatim, so any visual change to the sheet failed the
# contract even when nothing about the package changed - which is what this test is
# actually for. The work log already flags this class of check as fragile.
#
# The properties below are the ones that matter: the sheet is opaque, rounded, and
# outlined. How the outline is painted is a design decision, not a contract.
need "$UI" 'border-radius:26px'
need "$UI" '.cfg-profile-sheet'
need "$UI" 'cfg-profile-actions button.cfg-profile-apply.is-running'
need "$UI" '@keyframes cfgProfileApplyPulse'
need "$UI" 'cfg-profile-progress'
absent "$UI" 'background-image: linear-gradient(160deg, #0c1415, #070a0b 72%)'
absent "$UI" 'rgba(73,224,187,.82)'
absent "$UI" 'box-shadow: inset 0 -1px 0'
need "$UI" 'function cfgProfileNameOK(name)'
need "$UI" 'id="cfgProfileModal"'
need "$UI" 'function cfgProfileOpen(mode)'
need "$UI" 'function cfgProfileSuggestedName()'
need "$UI" "return 'asb-' + (p || 'settings');"
need "$UI" 'function cfgProfileSelect(name)'
need "$UI" 'cfg-profile-row'
need "$UI" "'list-external '"
# Any-folder flow: the WebUI browser exports and imports through the validated path commands.
need "$UI" "' export-path '"
need "$UI" "' import-path '"
need "$UI" 'id="cfgFm"'
need "$UI" 'function cfgFmPathOK(p)'

need "$UI" "' restore '"
need "$UI" 'function cfgProfilePaintYield()'
need "$UI" "_cfgProfile.busy = true;"
need "$UI" "await cfgProfilePaintYield();"
need "$UI" "T('cfg_profile_apply_active','Applying saved configuration…')"
need "$UI" "T('cfg_profile_apply_wait','Please wait while ASB restores every saved setting. Do not close this window.')"
absent "$UI" 'cfgProfilePreview'
absent "$UI" 'cfg_profile_prepare_apply'
absent "$UI" "prompt(T('cfg_profile_name'"
absent "$UI" "confirm(T('cfg_profile_replace_q'"
absent "$UI" "confirm(T('cfg_profile_preview'"
need "$HELPER" 'EXPORT_ROOT="${ASB_PROFILE_EXPORT_ROOT:-/sdcard}"'
need "$HELPER" '_export_dir()'
need "$HELPER" 'downloads)'
need "$HELPER" 'documents)'
need "$HELPER" 'list-external)'
need "$HELPER" 'import-external)'
need "$HELPER" 'export-path)'
need "$HELPER" 'import-path)'
need "$HELPER" '_path_ok()'
need "$HELPER" '_migrate_legacy_external()'
need "$HELPER" 'asb_settings_backup.conf'

# Audio remains one top-level category. DSP is its first labelled subsection and Outputs its
# first card, not a second destination or duplicate renderer; locales keep their compact labels.
need "$UI" "const CFG_GROUP_SECTIONS = {"
need "$UI" "audio: ["
need "$UI" "titleKey:'cfg_audio_section_dsp'"
need "$UI" "keys:['dsp_outputs','dsp_loudness','dsp_bass','dsp_voice','dsp_width','dsp_clarity','dsp_rumble','dsp_compressor','dsp_headroom']"
need "$UI" 'function cfgRenderGroup(list, groupId)'
need "$UI" 'cfgRenderGroup(list, _cfgGroup);'
need "$UI" '.cfg-section-hint'

# Every profile/category/section/tweak now uses a deterministic inline SVG glyph instead of
# Android-dependent emoji. The map must cover all registered config keys, while the fallback
# remains semantic (`generic`) rather than a gear emoji.
need "$UI" 'const TECH_ICON_PATHS = {'
need "$UI" 'function techIcon(kind) {'
need "$UI" 'function renderStaticTechIcons() {'
need "$UI" 'data-tech-icon="smart"'
need "$UI" 'data-tech-icon="performance"'
need "$UI" 'data-tech-icon="stock"'
need "$UI" "ic.innerHTML = techIcon(g.icon);"
need "$UI" "ico.innerHTML = techIcon(section.icon);"
need "$UI" "ic.innerHTML = techIcon(CFG_ICONS[it.key] || 'generic');"
need "$UI" 'data-tech-icon="telegram"'
need "$UI" "const vendorPeriodActive = capSrc === 'vendor_clamp' || String(kv.cap_owner || '') === 'vendor';"
need "$UI" "const ownerSince = parseInt(kv.cap_owner_since || '0', 10);"
need "$UI" "T('lv_vendor_clamps', 'Vendor clamps')"
need "$UI" "fmt('cap_clamps_val', '{h}/h · {t} total', {h: c1h, t: cTot})"
absent "$UI" 'Кепы vendor: 1ч / всего'
need "$UI" "CAMERA_AGGRESSIVE:'camera_aggressive'"
need "$UI" "net_wifi_leave:'wifileave'"
need "$UI" 'grid-template-areas: "ico title" ". hint";'
need "$UI" '.cfg-section-title {'
need "$UI" 'min-height: 22px;'
need "$UI" '.tg-link-ico .tech-icon { width: 18px; height: 18px; }'

# Contextual sonic feedback is local WebAudio with the old click asset only as fallback. DSP
# gain/bass stay silent because they reconfigure the path through which a cue would play.
need "$UI" 'const UI_SONIC = {'
need "$UI" 'function uiSound(kind) {'
need "$UI" "uiSound('profile');"
need "$UI" "uiSound('capture');"
need "$UI" "tile.onclick = () => { uiSound('nav');"
need "$UI" "if (CFG_SILENT_KEYS.indexOf(key) < 0) uiSound(cfgSoundKind(key, val));"
need "$UI" "const CFG_SILENT_KEYS = ['dsp_loudness','dsp_bass','dsp_voice','dsp_width','dsp_clarity','dsp_rumble'];"

python3 - "$UI" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
audio = re.search(r'\n  audio: \[(.*?)\n  \],\n  battery:', text, re.S)
assert audio, 'audio section model missing'
section_order = re.findall(r"\{ id:'([^']+)'", audio.group(1))
assert section_order == ['dsp', 'playback', 'safety'], f'audio priority/order drifted: {section_order}'
dsp = re.search(r"\{ id:'dsp'.*?keys:\[([^]]+)\]", audio.group(1), re.S)
assert dsp, 'DSP section keys missing'
dsp_keys = re.findall(r"'([^']+)'", dsp.group(1))
assert dsp_keys == ['dsp_outputs','dsp_loudness','dsp_bass','dsp_voice','dsp_width','dsp_clarity','dsp_rumble','dsp_compressor','dsp_headroom'], f'DSP order drifted: {dsp_keys}'
items = set(re.findall(r"\{ key:'([^']+)'", text))
block = re.search(r'const CFG_ICONS = \{(.*?)\n\};', text, re.S)
assert block, 'CFG_ICONS block missing'
icons = re.findall(r"(?:^|,)\s*([A-Za-z0-9_]+):'([a-z_]+)'", block.group(1), re.M)
icon_keys = {k for k, _ in icons}
missing = sorted(items - icon_keys)
assert not missing, f'config keys without hi-tech icon kind: {missing}'
used_kinds = [kind for key, kind in icons if key in items]
assert len(used_kinds) == len(items), 'registered item map count drifted'
duplicates = sorted({kind for kind in used_kinds if used_kinds.count(kind) > 1})
assert not duplicates, f'visible tweak cards reuse glyph kinds: {duplicates}'
paths = re.search(r'const TECH_ICON_PATHS = \{(.*?)\n\};', text, re.S)
assert paths, 'TECH_ICON_PATHS block missing'
path_kinds = set(re.findall(r'^\s*([a-z_]+):', paths.group(1), re.M))
unknown = sorted(set(used_kinds) - path_kinds)
assert not unknown, f'visible tweak mappings miss SVG paths: {unknown}'
assert not re.search(r"CFG_ICONS = \{[^}]*\\uD83|CFG_ICONS = \{[^}]*\\u26", block.group(0), re.S), 'emoji literal remains in CFG_ICONS'
print(f'PASS unique SVG icon coverage: {len(items)} config keys')
PY

# UV collector remains available to asbdiag but must not display ambiguous properties in WebUI.
need "$UV" 'asb_action" "diagnostics_only'
need "$UV" 'ASB does not own, write, validate, disable or revert external voltage policy'
absent "$UI" 'cfgUvCard'
absent "$UI" 'cfgLoadUvStatus'
absent "$UI" 'CFG_UV_HELPER'
absent "$UI" 'cfg_uv_'

# Profile labels remain localized in all supported UI locales. Removed UV card strings must not
# linger as dead UI surface translations.
python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'webroot' / 'i18n'
keys = {'cfg_profile_save_short','cfg_profile_load_short','cfg_audio_section_playback','cfg_audio_section_playback_hint','cfg_audio_section_dsp','cfg_audio_section_dsp_hint','cfg_audio_section_safety','cfg_audio_section_safety_hint','lv_vendor_period','cap_period_active','cap_period_none','cap_period_none_tip','cap_period_just_now','cap_period_minutes','cap_period_hours_minutes','cap_period_tip'}
manager_keys = {'cfg_profile_manager_title','cfg_profile_save_copy','cfg_profile_open_copy','cfg_profile_location','cfg_profile_store_asb','cfg_profile_store_downloads','cfg_profile_store_documents','cfg_profile_save_action','cfg_profile_replace','cfg_profile_name_hint','cfg_profile_replace_ready','cfg_profile_keys','cfg_profile_apply','cfg_profile_apply_active','cfg_profile_apply_wait','cfg_profile_delete','cfg_profile_delete_confirm','cfg_profile_apply_hint','cfg_profile_export_err'}
reset_keys = {'cfg_reset_dialog_title','cfg_reset_dialog_copy','cfg_reset_all_title','cfg_reset_all_copy','cfg_reset_smart_title','cfg_reset_smart_copy','cfg_reset_confirm','cfg_reset_all_done','cfg_reset_all_fail'}
files = sorted(root.glob('*.json'))
assert len(files) == 13, f'expected 13 locale files, got {len(files)}'
for p in files:
    data = json.loads(p.read_text(encoding='utf-8'))
    missing = sorted(k for k in keys if not isinstance(data.get(k), str) or not data[k].strip())
    assert not missing, f'{p.name}: missing {missing}'
    stale = sorted(k for k in data if k.startswith('cfg_uv_'))
    assert not stale, f'{p.name}: stale UV card keys {stale}'
    missing_manager = sorted(k for k in manager_keys if not isinstance(data.get(k), str) or not data[k].strip())
    assert not missing_manager, f'{p.name}: missing manager keys {missing_manager}'
    if p.stem in {'en', 'ru'}:
        missing_reset = sorted(k for k in reset_keys if not isinstance(data.get(k), str) or not data[k].strip())
        assert not missing_reset, f'{p.name}: missing reset keys {missing_reset}'
print('PASS profile, Audio/DSP subsection locale keys and diagnostics-only UV boundary: 13 locales')
PY

echo 'PASS profile/UV package contract'
)

t_project_safety_hardening_contract() (
# Contract: cross-directory hardening must not regress into silent broad boot mutations.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL project safety hardening: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden [$2] in $1" || true; }

UTILS="$ROOT/runtime/asb_utils.sh"
CORE="$ROOT/runtime/profile_core.sh"
POSTFS="$ROOT/post-fs-data.sh"
TWEAKS="$ROOT/runtime/asb_tweaks.sh"
SERVICE="$ROOT/service.sh"
AUDIO="$ROOT/runtime/asb_audio_apply.sh"
GUARD="$ROOT/runtime/asb_overlay_guard.sh"
ATTACH="$ROOT/src/DSP_AIDL/asb_dsp_attach.cpp"
NATIVE_BUILD="$ROOT/src/build_ndk_release.sh"
REL="$ROOT/.github/workflows/build-release.yml"
TEST="$ROOT/.github/workflows/build-test.yml"
ATTWF="$ROOT/.github/workflows/build-dsp-attach.yml"
WEB="$ROOT/webroot/index.html"
for f in "$UTILS" "$CORE" "$POSTFS" "$TWEAKS" "$SERVICE" "$AUDIO" "$GUARD" "$ATTACH" "$NATIVE_BUILD" "$REL" "$TEST" "$ATTWF" "$WEB"; do
  [ -f "$f" ] || fail "missing $f"
done
for f in "$UTILS" "$CORE" "$POSTFS" "$TWEAKS" "$SERVICE" "$AUDIO" "$GUARD"; do
  sh -n "$f" || fail "shell syntax $f"
done

# All independent feature readers fail closed for missing/unknown state.
need "$UTILS" '[ -r "$MODDIR/features.conf" ] || return 1'
need "$CORE" '[ -r "$MODDIR/features.conf" ] || return 1'
need "$POSTFS" '[ -r "$MODDIR/features.conf" ] || return 1'
need "$TWEAKS" '[ -r "$_ftf" ] || return 1'
need "$UTILS" 'asb_bt_policy_enabled()'
need "$UTILS" 'asb_audio_boot_policy_enabled()'
need "$POSTFS" 'asb_bt_policy_enabled()'

# Every early/framework automatic Bluetooth policy path is behind the same explicit opt-in.
need "$POSTFS" 'if asb_bt_policy_enabled && command -v asb_device_pack_allows'
need "$SERVICE" 'asb_bt_policy_enabled && apply_bt_runtime'
need "$SERVICE" 'if asb_bt_policy_enabled; then'

# AUDIO=1 exposes manual controls, but no longer triggers broad boot-time HAL policy/deletes.
need "$SERVICE" 'audio runtime: default ROM policy retained'
need "$SERVICE" 'asb_audio_boot_policy_enabled && [ -f "$MODDIR/runtime/asb_audio_apply.sh" ]'
need "$AUDIO" '/data/adb/asb/audio_user_policy_enabled'
need "$AUDIO" 'if [ "$_mode" = "boot" ]; then'
need "$AUDIO" 'boot restore, no audioserver restart'
absent "$SERVICE" 'resetprop -p --delete audio.hal.output.suspend.supported'

# A malformed ODM bind manifest blocks its own overlay instead of falling through to mount.
need "$POSTFS" 'runtime/asb_overlay_guard.sh'
need "$GUARD" 'vendor_overlay_blocked'
need "$GUARD" 'forbidden_target'
need "$GUARD" 'missing_payload'
need "$GUARD" 'invalid_xml_payload'
need "$GUARD" 'invalid_json_payload'

# The dedicated attacher workflow compiles current source and publishes auditable SHA-256
# provenance. Release/test keep the compatible prebuilt guard on functional source literals;
# an observability-only source marker must not make normal module builds unbuildable.
need "$ATTWF" 'SOURCE_SHA256='
need "$ATTWF" 'source_sha256=$SOURCE_SHA256'
need "$ATTWF" 'binary_sha256='
need "$ATTWF" 'asb_dsp_attach.provenance'
need "$NATIVE_BUILD" 'pushed gain_mb'
need "$NATIVE_BUILD" 'settings change'
need "$NATIVE_BUILD" 'attached to session'
absent "$ATTACH" 'kAsbAttachBuildId'
absent "$REL" 'ATT is stale for source marker'
absent "$TEST" 'ATT is stale for source marker'
for w in "$REL" "$TEST"; do
  need "$w" 'tests/asb_smart.sh'
  need "$w" 'tests/asb_features.sh'
  need "$w" 'tests/asb_ui.sh'
  need "$w" 'tests/asb_system.sh'
done

# Post-boot connectivity must be bounded and single-owner; Stock read-only telemetry must not
# create a three-second shell wakeup loop while a comparison page is open.
need "$SERVICE" 'wifi_reassert.lock'
need "$SERVICE" 'wait_path /sys/class/net/wlan0 10'
need "$SERVICE" 'while [ "$t" -lt 30 ]'
absent "$SERVICE" '[ $t -lt 120 ]'
need "$WEB" 'STOCK_TELEMETRY_MIN_INTERVAL_MS = 10000'
need "$WEB" 'if (!force && (now - _stockTelemetryLastMs) < STOCK_TELEMETRY_MIN_INTERVAL_MS) {'
need "$WEB" 'if (Object.keys(_stockTelemetryKv).length) paintStockLive(_stockTelemetryKv);'

echo 'PASS project safety hardening contract'
)

t_quick_restart_contract() (
# Contract: ASB never pretends to accelerate a full reboot. Quick restart must choose only
# a ROM-supported userspace reboot; it must not kill processes directly, persist boot
# properties, restart Zygote as an unsupported shortcut, or turn a refused request into a generic reboot.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_quick_restart.sh"
UI="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
SERVICE="$ROOT/service.sh"
fail() { echo "FAIL quick restart contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
absent() { ! grep -Fq "$2" "$1" || fail "unexpected [$2] in $1"; }
[ -f "$HELPER" ] || fail 'quick restart helper missing'

need "$HELPER" 'init.userspace_reboot.is_supported'
need "$HELPER" 'svc power reboot userspace'
need "$HELPER" 'sys.boot_completed'
absent "$HELPER" 'killall'
absent "$HELPER" 'ctl.restart zygote'
absent "$HELPER" 'sys.powerctl'
absent "$HELPER" 'persist.'
need "$UI" "const ASB_QUICK_RESTART = MD + '/runtime/asb_quick_restart.sh';"
need "$UI" "sh ' + shQuote(ASB_QUICK_RESTART) + ' status'"
need "$UI" "sh ' + shQuote(ASB_QUICK_RESTART) + ' restart'"
absent "$UI" 'setprop ctl.restart zygote 2>/dev/null || killall zygote'
need "$UI" 't_quick_explain'
need "$UI" 't_quick_unavailable'
need "$INSTALL" 'asb_quick_restart.sh'

# Applied user tweaks may use PackageManager/framework or cmd -w networking. They must not
# synchronously occupy the userspace-reboot startup path: service returns first, then a bounded
# post-boot worker reapplies them after boot_complete plus a settle window.
need "$SERVICE" 'post_boot_tweaks: begin'
need "$SERVICE" 'post_boot_tweaks: complete'
need "$SERVICE" 'post_boot_tweaks: skipped (boot completion timeout)'
need "$SERVICE" 'sleep 2'
_pb_line="$(grep -nF 'post_boot_tweaks: begin' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_pb_line" ] || fail 'post-boot stage marker missing'
for _helper in asb_gms_freeze.sh asb_gms_trim.sh asb_system_tweaks.sh asb_athena_apply.sh asb_net_offload.sh asb_doze_apply.sh asb_net_apply.sh; do
  _call_line="$(grep -nF "sh \"\$MODDIR/runtime/$_helper\"" "$SERVICE" | head -1 | cut -d: -f1)"
  [ -n "$_call_line" ] && [ "$_call_line" -gt "$_pb_line" ] || fail "$_helper is not deferred after boot completion"
done

# Aggressive BG_TRIM reaches PackageManager, app-standby buckets, cgroup UID lookups and
# vendor services. It previously ran before boot-completed and is therefore a plausible
# contributor to the measured 48-second OP15 service interval. Preserve its policy but run it
# only from the detached worker, after the same lifecycle gate as other framework work.
absent "$SERVICE" 'asb_feature_enabled BG_TRIM && apply_bg_trim_runtime'
_bg_line="$(grep -nF '    apply_bg_trim_runtime' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_bg_line" ] && [ "$_bg_line" -gt "$_pb_line" ] || fail 'BG_TRIM is not deferred after boot completion'
need "$SERVICE" 'asb_timeline_mark service_maintenance_complete'
need "$SERVICE" 'asb_timeline_mark service_cpu_deferred'
need "$SERVICE" 'asb_timeline_mark service_vm_deferred'
need "$SERVICE" 'asb_timeline_mark service_network_complete'
need "$SERVICE" 'asb_timeline_mark service_connectivity_complete'
need "$SERVICE" 'asb_timeline_mark service_media_kernel_deferred'
need "$SERVICE" 'asb_timeline_mark service_runtime_kernel_memory_deferred'
need "$SERVICE" 'asb_timeline_mark service_runtime_core_deferred'
need "$SERVICE" 'asb_timeline_mark service_dispatched'
# The first UI must not wait for cgroup readiness/retries, direct profile caps,
# VM/kernel/DSP/ZRAM writes or WALT delayed reassertion. Stock/vendor policy is
# retained until the lifecycle-gated core worker applies the same ASB policy.
absent "$SERVICE" 'wait_path /dev/cpuset/background/cpus 8'
absent "$SERVICE" 'wait_path /dev/cpuctl/top-app 8'
absent "$SERVICE" '( sleep 5; asb_load_profile; apply_walt_boost; apply_walt_live )'
need "$SERVICE" 'asb_timeline_mark post_boot_core_policy_begin'
need "$SERVICE" 'asb_timeline_mark post_boot_core_policy_complete'
need "$SERVICE" 'asb_apply_deferred_core_boot() {'
_core_def_line="$(grep -nF 'asb_apply_deferred_core_boot() {' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_core_def_line" ] || fail 'deferred core definition missing'
# `apply_runtime_profile_now` remains a callable manual profile-switch helper and is
# intentionally defined before this function. Its body is not an initial boot call.
# Guard actual initial-path scheduling by requiring the explicit deferred markers and
# forbidding the previous direct early invocations/settle task below.
absent "$SERVICE" 'asb_feature_enabled CPU && apply_cpugov_hints'
absent "$SERVICE" 'asb_timeline_mark service_cpu_complete'
absent "$SERVICE" 'asb_timeline_mark service_vm_complete'
absent "$SERVICE" 'asb_timeline_mark service_media_kernel_complete'
absent "$SERVICE" 'asb_timeline_mark service_runtime_kernel_memory_complete'
_core_line="$(grep -nF 'asb_timeline_mark post_boot_core_policy_begin' "$SERVICE" | head -1 | cut -d: -f1)"
_core_call_line="$(grep -nF '  asb_apply_deferred_core_boot' "$SERVICE" | tail -1 | cut -d: -f1)"
[ -n "$_core_line" ] && [ -n "$_core_call_line" ] && [ "$_core_call_line" -gt "$_core_line" ] && [ "$_core_line" -gt "$_pb_line" ] || fail 'deferred core policy is not boot-complete gated'
need "$SERVICE" 'asb_timeline_mark post_boot_bgtrim_begin'
need "$SERVICE" 'asb_timeline_mark post_boot_bgtrim_complete'
need "$SERVICE" 'ASB_TIMELINE_ENABLED=1'
absent "$SERVICE" 'ASB_TIMELINE_DEBUG'
absent "$SERVICE" '_asb_timeline_seq'

# Wi-Fi readiness can wait for wlan0/operstate (10 + 15 seconds), with a separate link
# reassertion that can wait longer. The OP15 timeline measured 19 seconds in that stage before
# boot completion, so all initial Wi-Fi/GPS/qdisc actions must be owned by post-boot worker.
need "$SERVICE" 'asb_timeline_mark post_boot_connectivity_begin'
need "$SERVICE" 'asb_timeline_mark post_boot_connectivity_complete'
_conn_line="$(grep -nF 'asb_timeline_mark post_boot_connectivity_begin' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_conn_line" ] && [ "$_conn_line" -gt "$_pb_line" ] || fail 'post-boot connectivity marker is not lifecycle-gated'
for _connect_call in \
  '    asb_wifi_cc_heal' \
  '    apply_wifi_settings' \
  '    apply_wifi_country' \
  '    apply_wlan0_txqlen' \
  '    apply_wlan0_qdisc' \
  '    apply_wifi_pm' \
  '    apply_wifi_dtim' \
  '    apply_mobile_qdisc' \
  '    apply_net_steering' \
  '  asb_feature_enabled GPS && apply_gps_hygiene' \
  '    ( asb_wifi_link_reassert ) >/dev/null 2>&1 &'; do
  _connect_line="$(grep -nF "$_connect_call" "$SERVICE" | head -1 | cut -d: -f1)"
  [ -n "$_connect_line" ] && [ "$_connect_line" -gt "$_conn_line" ] || fail "connectivity call not deferred: $_connect_call"
done
need "$SERVICE" 'asb_wifi_link_reassert() {'
need "$SERVICE" 'never launched during the init/service startup path'

# Runtime framework operations are distinct from early kernel/ZRAM writes. On the OP15 they
# occupied the residual 11-second runtime segment, so settings, DeviceIdle, tracking and
# nonessential-service operations must execute only in the post-boot worker.
need "$SERVICE" 'asb_timeline_mark service_runtime_kernel_memory_deferred'
need "$SERVICE" 'asb_timeline_mark service_runtime_framework_deferred'
need "$SERVICE" 'asb_timeline_mark post_boot_runtime_framework_begin'
need "$SERVICE" 'asb_timeline_mark post_boot_runtime_framework_complete'
_runtime_line="$(grep -nF 'asb_timeline_mark post_boot_runtime_framework_begin' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_runtime_line" ] && [ "$_runtime_line" -gt "$_conn_line" ] || fail 'runtime framework marker is not post-boot'
for _runtime_call in \
  '    apply_bt_settings' \
  '    apply_bt_codec_policy' \
  '    apply_bt_volume_behavior' \
  '    apply_bt_audio_hygiene' \
  '  asb_feature_enabled LOG && apply_tracking_block' \
  '  asb_feature_enabled VM && apply_doze' \
  '  asb_feature_enabled VM && apply_network_stats_poll' \
  '  apply_extra_settings' \
  '  asb_stop_nonessential_services'; do
  # `apply_runtime_profile_now` deliberately retains a callable runtime Doze apply for
  # manual profile changes after boot. Select the last occurrence, which is the boot worker
  # invocation guarded by post_boot_runtime_framework_begin.
  _runtime_call_line="$(grep -nF "$_runtime_call" "$SERVICE" | tail -1 | cut -d: -f1)"
  [ -n "$_runtime_call_line" ] && [ "$_runtime_call_line" -gt "$_runtime_line" ] || fail "runtime framework call not deferred: $_runtime_call"
done
absent "$SERVICE" 'asb_feature_enabled BT && apply_bt_settings'
absent "$SERVICE" 'asb_feature_enabled BT && apply_bt_codec_policy'
absent "$SERVICE" 'asb_feature_enabled BT && apply_bt_volume_behavior'
absent "$SERVICE" 'asb_feature_enabled BT && apply_bt_audio_hygiene'
need "$SERVICE" 'asb_stop_nonessential_services() {'

python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
keys = {'t_quick_explain','t_quick_confirm','t_quick_going','t_quick_unavailable'}
root = Path(sys.argv[1]) / 'webroot' / 'i18n'
files = sorted(root.glob('*.json'))
assert len(files) == 13, f'expected 13 locale files, got {len(files)}'
for path in files:
    data = json.loads(path.read_text(encoding='utf-8'))
    missing = sorted(k for k in keys if not isinstance(data.get(k), str) or not data[k].strip())
    assert not missing, f'{path.name}: missing {missing}'
print('PASS quick restart locale keys: 13 locales')
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"
cat > "$TMP/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  sys.boot_completed) printf '%s\n' "${ASB_TEST_BOOT:-1}" ;;
  init.userspace_reboot.is_supported) printf '%s\n' "${ASB_TEST_USERSPACE:-0}" ;;
  *) printf '\n' ;;
esac
EOF
cat > "$TMP/bin/svc" <<'EOF'
#!/bin/sh
printf 'svc:%s\n' "$*" >> "$ASB_TEST_LOG"
exit "${ASB_TEST_SVC_RC:-0}"
EOF
cat > "$TMP/bin/setprop" <<'EOF'
#!/bin/sh
printf 'setprop:%s\n' "$*" >> "$ASB_TEST_LOG"
exit "${ASB_TEST_SETPROP_RC:-0}"
EOF
chmod 0755 "$TMP/bin/getprop" "$TMP/bin/svc" "$TMP/bin/setprop"

run_helper() {
  PATH="$TMP/bin:$PATH" \
  ASB_TEST_LOG="$TMP/calls.log" \
  ASB_TEST_BOOT="${1:-1}" \
  ASB_TEST_USERSPACE="${2:-0}" \
  sh "$HELPER" "${3:-status}"
}

out="$(run_helper 1 1 status)"
[ "$out" = 'mode=userspace reason=init_supported' ] || fail "userspace status: $out"
: > "$TMP/calls.log"
out="$(run_helper 1 1 restart)"
[ "$out" = $'mode=userspace reason=init_supported\nrequested=userspace' ] || fail "userspace restart: $out"
grep -qx 'svc:power reboot userspace' "$TMP/calls.log" || fail 'userspace request not issued exactly once'
! grep -q '^setprop:' "$TMP/calls.log" || fail 'userspace path must not restart zygote'

: > "$TMP/calls.log"
if run_helper 1 0 status >/tmp/asb_quick_restart_nosupport.out 2>&1; then
  fail 'quick restart accepted without init userspace capability'
else
  rc=$?
  [ "$rc" -eq 3 ] || fail "userspace-not-supported exit=$rc"
fi
grep -qx 'mode=unavailable reason=userspace_not_supported' /tmp/asb_quick_restart_nosupport.out || fail 'userspace-not-supported verdict missing'
[ ! -s "$TMP/calls.log" ] || fail 'unsupported path issued a restart command'

: > "$TMP/calls.log"
if run_helper 0 1 status >/tmp/asb_quick_restart_unavailable.out 2>&1; then
  fail 'quick restart accepted before boot complete'
else
  rc=$?
  [ "$rc" -eq 3 ] || fail "boot-not-complete exit=$rc"
fi
grep -qx 'mode=unavailable reason=boot_not_completed' /tmp/asb_quick_restart_unavailable.out || fail 'boot-not-complete verdict missing'
[ ! -s "$TMP/calls.log" ] || fail 'unavailable path issued a restart command'

rm -f /tmp/asb_quick_restart_unavailable.out /tmp/asb_quick_restart_nosupport.out

echo 'PASS quick restart capability and no-destructive-fallback contract'
)

t_release_package_tool_contract() (
# Release ZIP contract: tools/ is intentionally excluded from the module package,
# then the tools named in tools/release_tools.list are copied back. That manifest is
# the single source of truth for BOTH sides: the workflow ships from it and the
# installer's whitelist prune keeps exactly what it names. Every tool required by
# the ZIP validator must therefore be in the manifest, the manifest may name only
# files that exist, and the installer's inline fallback must match the manifest.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/build-release.yml"
MF="$ROOT/tools/release_tools.list"
INSTALL="$ROOT/common/install.sh"

[ -f "$WF" ] || { echo "FAIL: release workflow missing: $WF" >&2; exit 1; }
[ -f "$MF" ] || { echo "FAIL: release tools manifest missing: $MF" >&2; exit 1; }
grep -Fq -- "--exclude 'tools'" "$WF" || {
  echo "FAIL: test assumes wholesale tools exclusion is present" >&2
  exit 1
}

# The manifest is the package step's list: names only, no comments, no paths.
MANIFEST_NAMES="$(sed 's/#.*//; s/[ \t\r]//g; /^$/d' "$MF" | sort -u)"
[ -n "$MANIFEST_NAMES" ] || { echo "FAIL: release_tools.list is empty" >&2; exit 1; }
printf '%s\n' "$MANIFEST_NAMES" | grep -q '/' && {
  echo "FAIL: release_tools.list must hold bare top-level names, no paths" >&2
  exit 1
}
for name in $MANIFEST_NAMES; do
  [ -f "$ROOT/tools/$name" ] || {
    echo "FAIL: release_tools.list names missing source: tools/$name" >&2
    exit 1
  }
done

# The workflow copy-back must read the manifest (not its own inline list).
grep -Fq 'done < tools/release_tools.list' "$WF" || {
  echo "FAIL: Package RELEASE zip does not copy tools back from tools/release_tools.list" >&2
  exit 1
}
# And the manifest itself must be in the package, so the on-device installer reads
# the real list instead of its inline fallback.
grep -Fq 'install -m 0644 tools/release_tools.list' "$WF" || {
  echo "FAIL: Package RELEASE zip does not ship tools/release_tools.list" >&2
  exit 1
}

# Every tools/... entry in Validate RELEASE zip must be covered: top-level names by
# the manifest, logkit names by the logkit copy-back loop.
REQUIRED_TOOLS="$(sed -n '/for required in \\/,/webroot\/index.html"; do/p' "$WF" \
  | grep -oE '"tools/[A-Za-z0-9_./-]+"' \
  | tr -d '"' \
  | sort -u)"
[ -n "$REQUIRED_TOOLS" ] || {
  echo "FAIL: no tools paths found in release ZIP required-file contract" >&2
  exit 1
}
for path in $REQUIRED_TOOLS; do
  name="${path#tools/}"
  case "$name" in
    logkit/*)
      base="${name#logkit/}"
      grep -Fq -- 'tools/logkit/$_t' "$WF" || {
        echo "FAIL: release ZIP requires $path but the logkit copy-back loop is gone" >&2
        exit 1
      }
      [ -f "$ROOT/$path" ] || {
        echo "FAIL: release ZIP requires missing source file: $path" >&2
        exit 1
      }
      ;;
    release_tools.list)
      : # shipped by the manifest loop itself, checked above
      ;;
    *)
      printf '%s\n' "$MANIFEST_NAMES" | grep -qxF "$name" || {
        echo "FAIL: release ZIP requires $path but release_tools.list does not name it" >&2
        exit 1
      }
      ;;
  esac
done

# Installer side: the prune must read the manifest, and the inline fallback heredoc
# must list exactly the manifest's names - a stale fallback is the drift this whole
# contract exists to prevent.
grep -Fq '_rt_list="$MODPATH/tools/release_tools.list"' "$INSTALL" || {
  echo "FAIL: install.sh tools prune does not read tools/release_tools.list" >&2
  exit 1
}
FALLBACK="$(sed -n "/<<'EOF'/,/^EOF\$/p" "$INSTALL" | sed '1d; $d' | sed 's/[ \t\r]//g; /^$/d' | sort -u)"
[ -n "$FALLBACK" ] || {
  echo "FAIL: install.sh has no inline fallback list for the tools prune" >&2
  exit 1
}
if [ "$FALLBACK" != "$MANIFEST_NAMES" ]; then
  echo "FAIL: install.sh fallback whitelist and tools/release_tools.list disagree:" >&2
  diff <(printf '%s\n' "$MANIFEST_NAMES") <(printf '%s\n' "$FALLBACK") >&2 || true
  exit 1
fi

printf 'PASS: %s manifest tools shipped and kept; %s release-required tools covered; installer fallback matches\n' \
  "$(printf '%s\n' "$MANIFEST_NAMES" | wc -l | tr -d ' ')" \
  "$(printf '%s\n' "$REQUIRED_TOOLS" | wc -l | tr -d ' ')"
)

t_reversible_settings_contract() (
# Contract: user-visible framework settings written by ASB must retain their original namespace/value.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE="$ROOT/runtime/asb_baseline.sh"
AUDIO="$ROOT/runtime/asb_audio_apply.sh"
BLUR="$ROOT/runtime/asb_blur_apply.sh"
HAPTICS="$ROOT/runtime/asb_haptics_apply.sh"
NET="$ROOT/runtime/asb_net_apply.sh"
INSTALL="$ROOT/common/install.sh"
UNINSTALL="$ROOT/uninstall.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL reversible settings: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/settings" <<'EOF_SETTINGS'
#!/bin/sh
DB="${ASB_FAKE_SETTINGS_DB:?}"
case "${1:-}" in
  get)
    awk -F'|' -v ns="$2" -v key="$3" '$1==ns && $2==key {print $3; found=1; exit} END{if(!found) print "null"}' "$DB"
    ;;
  put)
    tmp="$DB.tmp.$$"
    awk -F'|' -v ns="$2" -v key="$3" '!($1==ns && $2==key)' "$DB" > "$tmp"
    printf '%s|%s|%s\n' "$2" "$3" "$4" >> "$tmp"
    mv -f "$tmp" "$DB"
    ;;
  delete)
    tmp="$DB.tmp.$$"
    awk -F'|' -v ns="$2" -v key="$3" '!($1==ns && $2==key)' "$DB" > "$tmp"
    mv -f "$tmp" "$DB"
    ;;
  *) exit 2 ;;
esac
EOF_SETTINGS
chmod 0755 "$TMP/bin/settings"
cat > "$TMP/settings.db" <<'EOF_DB'
global|bluetooth_a2dp_offload_enabled|before-offload
global|bluetooth_disable_absolute_volume|before-absvol-global
secure|bluetooth_disable_absolute_volume|before-absvol-secure
global|disable_window_blurs|before-blur
system|haptic_feedback_enabled|before-haptic-enabled
system|haptic_feedback_intensity|before-haptic-intensity
global|wifi_scan_throttle_enabled|before-scan
EOF_DB
cp "$TMP/settings.db" "$TMP/original-settings.db"

PATH="$TMP/bin:$PATH"
export PATH ASB_FAKE_SETTINGS_DB="$TMP/settings.db" ASB_BASELINE="$TMP/baseline.txt" MODDIR="$ROOT"
. "$BASE"

# These are the seven audit keys and namespaces. A later ASB write must not replace the first
# captured original, then targeted and complete restore must replay that original exactly.
while IFS='|' read -r ns key before; do
  asb_settings_put "$ns" "$key" "asb-${key}"
  grep -Fqx "settings|$ns|$key|$before" "$ASB_BASELINE" || fail "baseline did not capture $ns/$key"
  asb_settings_put "$ns" "$key" "asb-second-${key}"
  [ "$(grep -Fxc "settings|$ns|$key|$before" "$ASB_BASELINE")" = 1 ] || fail "baseline duplicated $ns/$key"
done < "$TMP/original-settings.db"

asb_baseline_restore_setting global disable_window_blurs || fail 'targeted blur baseline restore failed'
[ "$(settings get global disable_window_blurs)" = before-blur ] || fail 'targeted blur baseline restored wrong value'
asb_baseline_replay
while IFS='|' read -r ns key before; do
  [ "$(settings get "$ns" "$key")" = "$before" ] || fail "full baseline replay restored wrong $ns/$key"
done <<'EOF_EXPECTED'
global|bluetooth_a2dp_offload_enabled|before-offload
global|bluetooth_disable_absolute_volume|before-absvol-global
secure|bluetooth_disable_absolute_volume|before-absvol-secure
global|disable_window_blurs|before-blur
system|haptic_feedback_enabled|before-haptic-enabled
system|haptic_feedback_intensity|before-haptic-intensity
global|wifi_scan_throttle_enabled|before-scan
EOF_EXPECTED

need "$AUDIO" 'runtime/asb_baseline.sh'
need "$AUDIO" '_asb_setting_put global bluetooth_a2dp_offload_enabled'
need "$AUDIO" '_asb_setting_put global bluetooth_disable_absolute_volume'
need "$AUDIO" '_asb_setting_put secure bluetooth_disable_absolute_volume'
need "$BLUR" 'runtime/asb_baseline.sh'
need "$BLUR" 'asb_baseline_restore_setting global disable_window_blurs'
need "$NET" 'runtime/asb_baseline.sh'
# The scan-throttle rungs write the boolean and the interval together; rung 2 must write
# 1/300000, never the rung number itself into the boolean key.
need "$NET" '_wt_write 1 300000'
need "$NET" '_asb_setting_put global wifi_scan_throttle_enabled "$1"'
need "$HAPTICS" 'runtime/asb_baseline.sh'
need "$HAPTICS" '_asb_setting_put system haptic_feedback_enabled 1'
need "$HAPTICS" '_asb_setting_put system haptic_feedback_intensity'
need "$INSTALL" '_asb_install_setting_put global disable_window_blurs 1'
! grep -Fq 'settings put global disable_window_blurs' "$INSTALL" || fail 'installer still writes blur stock without baseline-aware helper'
need "$UNINSTALL" '*/haptics_baseline.conf) _restore_ns=system'

echo 'PASS reversible settings baseline contract (7 audited keys and haptics namespace)'
)

t_stock_switch_fast_runtime() (
# Runtime (fix177): choosing Stock returns at once; the settings part of the profile ledger is
# put back by a background pass that a newer profile stops between keys.
#
# Owner (fix176, Smart -> Stock): "Stock selected - restoring ROM baseline..." for about 30 s
# with the phone frozen and the Smart and Stock cards both half lit. apply_profile.sh ran the
# whole ledger in the WebUI's root call, and every setting in it is a `settings` process. The
# REAL asb_profile_baseline_restore runs here on a stub `settings`; the direct path and the
# background pass are pinned in apply_profile.sh and asb_stock_policy.sh.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL stock switch fast: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/mod/runtime"
cp "$ROOT/runtime/asb_baseline.sh" "$T/mod/runtime/"
printf '#!/bin/sh\necho "$*" >> "$SLOG"\n' > "$T/bin/settings"; chmod +x "$T/bin/settings"
echo 1996800 > "$T/cpu_max"; echo 100 > "$T/swappiness"
mk() {
  printf 'path|%s|3628800\npath|%s|60\nsetting|global:a|1\nsetting|global:b|\nsetting|system:c|x\n' \
    "$T/cpu_max" "$T/swappiness" > "$T/pb"
  : > "$T/slog"
}
cat > "$T/run.sh" <<EOF
MODDIR="$T/mod"; ASB_PROFILE_BASELINE="$T/pb"; ASB_BASELINE="$T/b.txt"; PATH="$T/bin:\$PATH"; SLOG="$T/slog"
export SLOG
. "$T/mod/runtime/asb_baseline.sh"
EOF
mk
sh -c ". '$T/run.sh'; asb_profile_baseline_restore path" || fail "path pass failed"
[ "$(cat "$T/cpu_max")" = 3628800 ] && [ "$(cat "$T/swappiness")" = 60 ] || fail "sysfs values not restored by the immediate pass"
[ -s "$T/slog" ] && fail "the immediate pass started settings: $(cat "$T/slog")"
[ -f "$T/pb" ] || fail "the immediate pass dropped the ledger the background pass needs"
[ "$(sh -c ". '$T/run.sh'; asb_profile_baseline_pending_settings")" = 3 ] || fail "pending count"
# Superseded after the first key: stops, keeps the ledger with the original values.
cat >> "$T/run.sh" <<'EOF'
_n=0; guard() { _n=$((_n + 1)); [ "$_n" -le 1 ]; }
EOF
rc=0; sh -c ". '$T/run.sh'; ASB_PB_GUARD=guard asb_profile_baseline_restore setting" || rc=$?
[ "$rc" = 2 ] || fail "a superseded pass did not say so (rc=$rc)"
[ "$(wc -l < "$T/slog")" = 1 ] || fail "a superseded pass went on: $(cat "$T/slog")"
grep -q '^setting|global:b|$' "$T/pb" || fail "the ledger lost the original values"
# Completed: every setting back, an unset one deleted, the ledger gone.
: > "$T/slog"
sh -c ". '$T/run.sh'; asb_profile_baseline_restore setting" || fail "settings pass failed"
[ "$(tr '\n' ';' < "$T/slog")" = 'put global a 1;delete global b;put system c x;' ] || fail "settings restored: $(cat "$T/slog")"
[ -f "$T/pb" ] && fail "ledger kept after a complete pass"
# The full transaction (boot, worker) is unchanged: everything, in one pass.
mk
sh -c ". '$T/run.sh'; asb_profile_baseline_restore" || fail "full pass"
[ "$(wc -l < "$T/slog")" = 3 ] && [ ! -f "$T/pb" ] || fail "full restore"

python3 - "$ROOT/apply_profile.sh" "$ROOT/runtime/asb_stock_policy.sh" "$ROOT/webroot/index.html" <<'P' || fail "wiring"
import sys
ap, sp, ui = (open(p, encoding='utf-8').read() for p in sys.argv[1:4])
q = ap[ap.index('quick_return_or_spawn() {'):ap.index('run_worker() {')]
st = q[q.index('if [ "$PROFILE" = "stock" ]; then'):q.index('exit 0')]
assert 'asb_stock_enter_fast' in st and 'spawn_stock_finish' in st, 'direct Stock path not split'
assert st.index('asb_stock_enter_fast') < st.index('spawn_stock_finish'), 'background pass scheduled before the immediate part'
assert 'spawn_worker' not in st, 'Stock spawns the ordinary worker'
f = sp[sp.index('asb_stock_enter_fast() {'):sp.index('asb_stock_finish() {')]
assert 'asb_profile_baseline_restore path' in f, 'immediate part does not restore sysfs'
assert 'settings' not in f.replace('settings follow', ''), 'immediate part starts settings'
assert 'asb_net_apply' not in f, 'immediate part runs the network applier'
g = sp[sp.index('asb_stock_finish() {'):sp.index('asb_stock_leave() {')]
assert 'asb_profile_baseline_restore setting || return $?' in g, 'background pass ignores supersede'
assert g.index('asb_profile_baseline_restore setting') < g.index('asb_net_apply.sh'), 'network re-applied before the restore'
r = ap[ap.index('run_stock_finish() {'):ap.index('quick_return_or_spawn() {')]
assert 'ASB_PB_GUARD=profile_epoch_current' in r, 'background pass not epoch-guarded'
assert "trap 'profile_worker_unlock; exit 0' HUP INT TERM" in r, 'a killed pass would go on restoring'
assert 'profile_worker_lock' in r, 'background pass does not hold the apply lock'
assert '[ "$MODE" = "stock_finish" ] && run_stock_finish' in ap
assert 'nohup /system/bin/sh "$MODDIR/apply_profile.sh" --stock-finish' in ap and '</dev/null >/dev/null 2>&1 &' in ap, 'background pass not detached'
P
echo "PASS stock switch fast: Stock returns after the sysfs restore, the settings follow in an epoch-guarded background pass"
)

t_stock_profile_contract() (
# Contract: Stock is an explicit, persistent no-intervention profile. It must never silently
# become Balanced, restart the native governor, or move the three-button debug support rail.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UI="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
SERVICE="$ROOT/service.sh"
APPLY="$ROOT/apply_profile.sh"
CORE="$ROOT/runtime/profile_core.sh"
UTILS="$ROOT/runtime/asb_utils.sh"
STOCK="$ROOT/runtime/asb_stock_policy.sh"
BASELINE="$ROOT/runtime/asb_baseline.sh"
WATCHDOG="$ROOT/runtime/asb_watchdog.sh"
RECONCILE="$ROOT/runtime/asb_reconcile.sh"
EFFECTIVE="$ROOT/tools/asb_effective_policy.sh"
fail() { echo "FAIL stock profile contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
need_count() { _n="$(grep -Fc "$2" "$1" || true)"; [ "$_n" = "$3" ] || fail "expected $3 occurrences of [$2] in $1, got $_n"; }

for f in "$UI" "$INSTALL" "$SERVICE" "$APPLY" "$CORE" "$UTILS" "$STOCK" "$BASELINE" "$WATCHDOG" "$RECONCILE" "$EFFECTIVE"; do
  [ -f "$f" ] || fail "missing source $f"
done
for f in "$INSTALL" "$SERVICE" "$APPLY" "$CORE" "$UTILS" "$STOCK" "$BASELINE" "$WATCHDOG" "$RECONCILE" "$EFFECTIVE"; do
  sh -n "$f" || fail "shell syntax $f"
done

# Backend: Stock stops/refrains from starting only ASB profile policy, releases ASB leases and
# does not ask the native daemon to interpret an unsupported profile:stock command.
need "$STOCK" 'asb_stock_enter()'
need "$STOCK" 'asb_stock_stop_governor'
need "$STOCK" 'asb_stock_release_profile_leases'
need "$STOCK" 'cpu_cap gpu_cap uclamp_max cpuset_fg'
need "$STOCK" 'asb_stock_restore_profile_runtime'
need "$STOCK" 'asb_profile_baseline_restore'
need "$STOCK" 'profile-owned baseline restored'
need "$BASELINE" 'ASB_PROFILE_BASELINE='
need "$BASELINE" 'asb_profile_baseline_capture_path()'
need "$BASELINE" 'asb_profile_baseline_capture_setting()'
need "$BASELINE" 'asb_profile_baseline_restore()'
need "$BASELINE" 'manual audio'
need "$APPLY" 'stock|performance|balanced|battery)'
need "$APPLY" 'if [ "$PROFILE" = "stock" ]; then'
need "$APPLY" 'asb_stock_enter'
need "$APPLY" 'description=status: Stock 👶🏻 | active ✅'
need "$CORE" 'description=status: Stock 👶🏻 | active ✅'
! grep -Fq 'Stock ◻️ | ASB performance policy stopped' "$APPLY" || fail 'legacy Stock status remains in apply fallback'
! grep -Fq 'Stock ◻️ | ASB performance policy stopped' "$CORE" || fail 'legacy Stock status remains in profile core'
need "$APPLY" 'asb_stock_start_governor'
need "$APPLY" '[ "$PROFILE" = "stock" ] && _passes=1'
need "$APPLY" 'stock_cancel_pending_worker()'
need "$APPLY" 'profile_next_epoch 0.05 4'
need "$APPLY" 'stock applied immediately; no duplicate profile worker spawned'
# Stock is fully restored by notify_governor in the direct path. Do not queue a second worker
# behind the outgoing Smart worker lock after that real Stock restore has completed.
_stock_direct="$(sed -n '/^quick_return_or_spawn()/,/^run_worker()/p' "$APPLY" | sed -n '/if \[ "$PROFILE" = "stock" \]; then/,/^[[:space:]]*fi/p')"
printf '%s\n' "$_stock_direct" | grep -Fq 'spawn_worker' && fail 'Stock direct path still spawns a duplicate worker'
! grep -Fq '"profile:$PROFILE"' "$APPLY" || true
need "$CORE" 'stock)'
need "$CORE" 'ASB_STOCK_PROFILE=1'
need "$CORE" '[ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0'
need "$CORE" 'asb_stock_enter'
need "$CORE" 'ASB_PROFILE_BASELINE_CAPTURE=1'
need "$CORE" 'asb_profile_baseline_capture_path'
need "$UTILS" 'asb_stock_profile_active'
need "$UTILS" 'return 2'
need "$UTILS" 'ASB_DEFER_GOVERNOR_START'
need "$SERVICE" 'ASB_DEFER_GOVERNOR_START=1'
need "$SERVICE" 'post_boot_governor_start_begin'
need "$SERVICE" 'post_boot_governor_stock_off'
need "$SERVICE" 'asb_governor_start || asb_log "post_boot: governor start deferred to watchdog"'
need "$SERVICE" 'stock|battery|balanced|performance|smart)'
need "$SERVICE" 'asb_stock_enter'
need "$SERVICE" '[ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0'
need "$SERVICE" 'Stock is an explicit terminal boundary for this runtime pass'
need "$SERVICE" 'ASB_PROFILE_BASELINE_CAPTURE=1'
need "$WATCHDOG" 'current_profile'
need "$WATCHDOG" '"stock" ] && exit 0'
need "$RECONCILE" '"stock" ]; then'
need "$EFFECTIVE" '_owner="rom_stock"'
need "$EFFECTIVE" '_cpu_min_strategy="not_managed"'

# Fresh install explicitly persists Stock, while upgrade migration preserves an already selected
# profile including Stock.
need "$INSTALL" "printf '%s\\n' stock > \"\$MODPATH/current_profile\""
need "$INSTALL" 'stock|performance|battery|balanced|smart|none)'
need "$INSTALL" 'Stock profile active; ASB CPU/GPU/governor policy is off'
need "$INSTALL" 'asb_stock_policy.sh'

# WebUI: one fifth Stock card starts selected in shipped markup; live load replaces it with the
# actual stored profile. The compact spacing retains the support rail's three equal controls.
need "$UI" "class=\"pbtn pbtn-stock on\" data-p=\"stock\" onclick=\"go('stock')\""
need "$UI" '<div class="pico" data-tech-icon="stock"></div>'
need "$UI" 'data-i18n="prof_stock"'
need "$UI" 'data-i18n="prof_stock_sub"'
need "$UI" '.pbtn[data-p="stock"]'
# Stock inherits the shared inactive pbtn surface. Silver is applied only through
# its --c token when selected; a dedicated .pbtn-stock surface would visibly split
# its border from Performance, Balanced and Battery.
if grep -Fq '.pbtn-stock {' "$UI"; then
  fail 'Stock has a dedicated inactive surface instead of the shared pbtn border'
fi
_profile_order="$(grep -E 'class=\"pbtn[^\"]*\" data-p=\"(smart|performance|balanced|battery|stock)\"' "$UI" | sed -n 's/.*data-p="\([^"]*\)".*/\1/p' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[ "$_profile_order" = 'smart performance balanced battery stock' ] || \
  fail "unexpected profile card order: $_profile_order"
need "$UI" "['stock','performance','balanced','battery','smart'].includes(p)"
need "$UI" "T('t_stock_applied', 'Stock active · ASB policy stopped')"
! grep -Fq 'reboot recommended' "$UI" || fail 'Stock WebUI fallback still recommends a reboot'
need "$UI" "let _selectedProfile = 'none';"
need "$UI" 'function paintStockLive(stockKv = null) {'
need "$UI" 'let _stockTelemetryKv = {};'
need "$UI" 'function parseStockTelemetry(text) {'
need "$UI" "const colon = line.indexOf(':');"
need "$UI" 'const cut = eq > 0 ? eq : colon;'
need "$UI" 'function fmtStockLoad(raw) {'
need "$UI" "T('stock_load_now', '1 min')"
need "$UI" "setLiveLabel('bnStockDrainLabel', 'stock_battery_current', 'Battery current');"
need "$UI" 'Each Stock tile opens the Monitor sheet like Smart'"'"'s (fix177)'
need "$UI" 'id="stockTelemetry"'
need "$UI" '.stock-telemetry { display:none !important;'
need "$UI" 'async function pollStockTelemetry(visible, force = false)'
# fix177: the ROM reads live in a script of builtin reads the page runs.
need "$UI" "'/runtime/asb_rom_telemetry.sh'"
need "$ROOT/runtime/asb_rom_telemetry.sh" '/class/power_supply/battery'
need "$ROOT/runtime/asb_rom_telemetry.sh" '/devices/system/cpu/cpufreq/policy'
need "$UI" 'const freshKv = parseStockTelemetry(text);'
need "$UI" '_stockTelemetryKv = freshKv;'
need "$UI" 'paintStockLive(_stockTelemetryKv);'
need "$UI" "set('liveCpu'"
need "$UI" "set('liveGpu'"
need "$UI" "set('liveHeadroom'"
need "$UI" 'id="liveStockRomBanner"'
need "$UI" 'id="bnStockDrain"'
need "$UI" 'id="bnStockTrend"'
need "$UI" 'id="bnStockLpm"'
need "$UI" 'id="bnStockCpuClock"'
need "$UI" 'id="bnStockLoad"'
need "$UI" 'id="bnStockBattery"'
need "$UI" 'id="bnStockUptime"'
need "$ROOT/runtime/asb_rom_telemetry.sh" 'settings get global mobile_data_always_on'
need "$UI" 'let _stockRomHistory = { ts: 0, cpuT: 0 };'
! grep -A130 'async function pollStockTelemetry' "$UI" | grep -Eq 'settings put|resetprop|tee .*\/sys|echo .*\/sys' || fail 'Stock telemetry contains a write operation'
! grep -Eq 'settings put|resetprop|tee .*/sys|> *"?\$(_|SYS|_d|_b|_g|_z)' "$ROOT/runtime/asb_rom_telemetry.sh" || fail 'the ROM snapshot script writes somewhere'
need "$UI" "if (_selectedProfile === 'stock') {"
need "$UI" "if (visible) await pollStockTelemetry(true);"
need "$UI" 'Terminal boundary: never read /dev/.asb/state, learner_state.json, native status or'
need "$UI" "const off = T('prof_stock_sub', 'ASB policy off');"
need "$UI" 'function stockMonitorReset() {'
need "$UI" 'function restoreManagedLiveLabels() {'
need "$UI" "setLiveLabel('liveStateLabel', 'stock_cpu_ceiling', 'CPU ceiling');"
grep -q "set('liveEtaOn'" "$UI" && fail 'Stock writes battery current into the time-to-empty line of the drain tiles'
need "$UI" "setLiveLabel('liveCapSrcLabel', 'stock_bat_temp', 'Battery temp');"
need "$UI" "setLiveLabel('liveLearnerLabel', 'stock_smart_learn', 'Smart learning');"
need "$UI" 'stockProfileCommit'
need "$UI" 'function profilePaintFrame() {'
need "$UI" "T('t_stock_switching', 'Stock selected · restoring ROM baseline…')"
# UI must acknowledge a profile tap before waiting for the root-side lifecycle. In particular,
# Smart → Stock can safely take longer while the governor stops and the profile baseline restores.
# A failed root transition must return the highlight to the confirmed previous profile.
python3 - "$UI" <<'PY'
import sys
from pathlib import Path
s = Path(sys.argv[1]).read_text(encoding='utf-8')
start = s.index('async function go(p) {')
end = s.index('\nfunction openTelegram', start)
go = s[start:end]
def require(fragment):
    if fragment not in go:
        raise SystemExit('FAIL Stock UI switch contract: missing ' + fragment)
def before(left, right):
    if go.index(left) >= go.index(right):
        raise SystemExit('FAIL Stock UI switch contract: expected ' + left + ' before ' + right)
require("const previousProfile = _selectedProfile;")
require('ui(p);')
require('stockMonitorReset();')
require('await profilePaintFrame();')
require("const r = await run('sh ' + MD + '/apply_profile.sh ' + p);")
require('ui(previousProfile);')
before('ui(p);', 'await profilePaintFrame();')
before('await profilePaintFrame();', "const r = await run('sh ' + MD + '/apply_profile.sh ' + p);")
before("const r = await run('sh ' + MD + '/apply_profile.sh ' + p);", 'ui(previousProfile);')
# Stock must return from pollLive before it can parse stale governor state or learner data.
poll = s[s.index('async function pollLive(visible) {'):s.index('\nfunction fmtStock', s.index('async function pollLive(visible) {')) if '\nfunction fmtStock' in s[s.index('async function pollLive(visible) {'):] else len(s)]
terminal = poll.index("if (_selectedProfile === 'stock') {")
state_read = poll.index("const r = await run('cat /dev/.asb/state 2>/dev/null');")
assert terminal < state_read, 'Stock terminal boundary occurs after stale state read'
stock_branch = poll[terminal:state_read]
assert 'return;' in stock_branch, 'Stock terminal branch does not return before stale state read'
print('PASS Stock immediate paint and ROM-only terminal monitor contract')
PY
need "$UI" 'gap: 8px;'
need_count "$UI" '<button class="debug-support-btn" data-debug-action="diag"' 3
need_count "$UI" '<button class="debug-support-btn" data-debug-action="full-day"' 3
need "$UI" 'debugActionPulse'
need "$UI" "T(action === 'diag' ? 'dbg_diag_wait' : 'dbg_log_wait'"
need "$UI" "b.classList.add('is-running')"
need "$UI" "b.classList.remove('is-running')"
need "$UI" 'footer-support-row'
need "$UI" 'flex-wrap: nowrap;'

# All 13 locales must expose the new profile and immediate action status to the user.
python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'webroot' / 'i18n'
files = sorted(root.glob('*.json'))
assert len(files) == 13, f'expected 13 locales, got {len(files)}'
for p in files:
    data = json.loads(p.read_text(encoding='utf-8'))
    for key in ('prof_stock', 'prof_stock_sub', 't_stock_applied', 't_stock_switching', 'stock_cpu_clock', 'stock_load', 'stock_load_now', 'stock_battery', 'stock_uptime', 'stock_battery_current', 'stock_thermal_trend', 'stock_lpm_state', 'stock_ram_available', 'stock_cpu_ceiling', 'stock_gpu_clock', 'stock_bat_temp', 'stock_zram', 'stock_smart_learn', 'stock_learn_paused', 'stock_gpu_load', 'dbg_diag_wait', 'dbg_log_wait'):
        assert isinstance(data.get(key), str) and data[key].strip(), f'{p.name}: missing {key}'
    stale = ('reboot', 'перезаг', 'neustart', 'reiniciar', 'redémarrage', 'վերագործարկ', 'mulai ulang', 'riavvio', 'yeniden başlat', '重启')
    assert not any(word in data['t_stock_applied'].lower() for word in stale), f'{p.name}: stale reboot recommendation'
print('PASS Stock profile, live ROM metric and immediate action locale coverage: 13 locales')
PY

# Behavioural fixture: profile runtime baseline must preserve the first pre-ASB value,
# restore it without reboot, and disappear afterwards so the next non-Stock session captures
# a fresh ROM state. It uses a temporary ordinary file; no Android setting or sysfs is touched.
_tmp="$(mktemp -d)"; trap 'rm -rf "$_tmp"' EXIT HUP INT TERM
_node="$_tmp/node"; _snap="$_tmp/profile_runtime_baseline.v1"
printf '111\n' > "$_node"
ASB_PROFILE_BASELINE="$_snap"
. "$BASELINE"
asb_profile_baseline_capture_path "$_node"
printf '222\n' > "$_node"
asb_profile_baseline_capture_path "$_node"
[ "$(cat "$_node")" = "222" ] || fail 'fixture setup changed node unexpectedly'
asb_profile_baseline_restore
[ "$(cat "$_node")" = "111" ] || fail 'immediate profile baseline restore did not restore first value'
[ ! -e "$_snap" ] || fail 'restored profile baseline was not cleared'

need "$ROOT/src/asb_writer.h" 'writer_profile_baseline_record_path'
need "$ROOT/src/asb_writer.h" 'profile_runtime_baseline.v1'

echo 'PASS stock profile contract'
)

_c_config_shipped_load() {
  cat <<'ASB_C_EOF'
#include <stdio.h>
#include <stdlib.h>
#include "asb_config.h"

static int load(const char *path, asb_runtime_config_t *c) {
    asb_config_defaults(c);
    return asb_config_load_file(path, c);
}

int main(int argc, char **argv) {
    (void)g_asb_appheat_hot;
    if (argc < 3) return 90;
    asb_runtime_config_t c;
    int rc = load(argv[1], &c);
    printf("shipped rc=%d gaming_gpu_enter=%d sustained_temp_enter=%d thermal_skin_c=%d device_bounds_override=%d\n",
           rc, c.gaming_gpu_enter, c.sustained_temp_enter, c.thermal_skin_c, c.device_bounds_override);
    if (rc != 0) return 1;
    char path[512];
    for (int n = 300; n <= 600; n += 300) {
        snprintf(path, sizeof(path), "%s/many_%d.conf", argv[2], n);
        FILE *f = fopen(path, "w");
        if (!f) return 91;
        fputs("gaming_gpu_enter=58\n", f);
        for (int i = 1; i < n; i++) fprintf(f, "asb_future_key_%d=1\n", i);
        fclose(f);
        rc = load(path, &c);
        printf("keys=%d rc=%d gaming_gpu_enter=%d\n", n, rc, c.gaming_gpu_enter);
        if (n == 300 && (rc != 0 || c.gaming_gpu_enter != 58)) return 2;
        if (n == 600 && rc != ASB_CFG_RC_TOO_MANY_KEYS) return 3;
    }
    snprintf(path, sizeof(path), "%s/dup.conf", argv[2]);
    FILE *f = fopen(path, "w");
    if (!f) return 92;
    fputs("gaming_gpu_enter=58\ngaming_gpu_enter=60\n", f);
    fclose(f);
    if (load(path, &c) != -3) return 4;
    return 0;
}
ASB_C_EOF
}

t_config_shipped_load_runtime() (
# Runtime (fix165): the shipped governor.conf loads in the governor's own reader.
#
# The fix163 capture: "config: auto-reload refused rc=-4; keeping last-known-good" at every
# WebUI save, and the governor running gaming_gpu=65, sustained 65/55 and highload default
# against a governor.conf of 55, 64/52 and stable. The reader stopped at 192 keys and the
# file had 193 since fix160 added dsp_width - so from then on the governor ignored the
# user's settings and ran its built-in defaults. The REAL asb_config_load_file reads the
# shipped file, a file with 300 keys, one past the new bound and one with a duplicate.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CCX="${HOST_CC:-${CC:-}}"
[ -n "$CCX" ] || for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && { CCX="$c"; break; }; done
[ -n "$CCX" ] || { echo "FAIL config shipped load: no host C compiler" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_c_config_shipped_load > "$T/t.c"
"$CCX" -O1 -I "$ROOT/src" "$T/t.c" -lm -o "$T/t" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; echo "FAIL config shipped load: fixture did not build" >&2; exit 1; }
out="$("$T/t" "$ROOT/config/governor.conf" "$T")" || { printf '%s\n' "$out" >&2; echo "FAIL config shipped load: the governor's reader refuses its own governor.conf (or the key bound is wrong)" >&2; exit 1; }
want="$(sed -n 's/^gaming_gpu_enter=//p' "$ROOT/config/governor.conf" | head -1)"
printf '%s\n' "$out" | grep -q "^shipped rc=0 gaming_gpu_enter=$want " || { printf '%s\n' "$out" >&2; echo "FAIL config shipped load: the file's value did not reach the governor" >&2; exit 1; }
n="$(grep -v '^[[:space:]]*#' "$ROOT/config/governor.conf" | grep -c '=')"
lim="$(sed -n 's/^#define ASB_CFG_MAX_KEYS \([0-9]*\)$/\1/p' "$ROOT/src/asb_config.h")"
[ "$n" -lt $((lim / 2)) ] || { echo "FAIL config shipped load: governor.conf has $n keys, the reader stops at $lim - raise it before it bites again" >&2; exit 1; }
grep -q 'fprintf(f, "cfg_load_rc=%d' "$ROOT/src/asb_governor.c" || { echo "FAIL config shipped load: the governor does not publish whether it accepted governor.conf" >&2; exit 1; }
echo "PASS config shipped load: the governor reads its own governor.conf ($n keys, bound $lim), 300 keys load, overflow and duplicates are refused with their own codes"
)

t_suite_runner_runtime() (
# Runtime (fix164): the host tests are four suites, not 161 files.
#
# Asked for: as few files in tests/ as possible. Every former script is a function t_<name> whose
# body runs in its own subshell - its exit, trap, set -e and variables stay its own - and every C
# fixture is a function _c_<name>. The real dispatcher, cut from a suite, runs a made-up suite:
# a pass, a failure that does not stop the next test, set -e still ending a test, an EXIT trap,
# --list and --source; then the real suites are checked for the same dispatcher and that the
# regression, lint and CI use them.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL suite runner: $*" >&2; exit 1; }
[ "$(find "$ROOT/tests" -type f -name 'asb_*.sh' | wc -l)" -eq 4 ] || fail "want four suites"
d0=""
for s in "$ROOT"/tests/asb_*.sh; do
  bash -n "$s" || fail "$(basename "$s") does not parse"
  d="$(sed -n '/^_asb_tests() {/,/^esac$/p' "$s")"
  [ -n "$d" ] || fail "$(basename "$s") has no dispatcher"
  [ -z "$d0" ] || [ "$d" = "$d0" ] || fail "$(basename "$s") dispatcher differs from the others"
  d0="$d"
done
total=0
for s in "$ROOT"/tests/asb_*.sh; do total=$((total + $(bash "$s" --list | wc -l))); done
[ "$total" -ge 158 ] || fail "only $total tests in the suites"
{
  echo 't_pass() ( echo pass-ran; )'
  echo 't_fail() ( echo fail-ran; exit 3; )'
  echo 't_errexit() ( set -e; false; echo errexit-leaked; )'
  echo "t_trap() ( trap 'echo trap-ran' EXIT; echo trap-body; )"
  echo "_c_fx() { cat <<'ASB_C_EOF'"
  echo 'int main(void) { return 0; }'
  echo 'ASB_C_EOF'
  echo '}'
  printf '%s\n' "$d0"
} > "$T/asb_fake.sh"
[ "$(bash "$T/asb_fake.sh" --list | tr '\n' ' ')" = "errexit fail pass trap " ] || fail "--list: $(bash "$T/asb_fake.sh" --list | tr '\n' ' ')"
[ "$(bash "$T/asb_fake.sh" --source fx)" = 'int main(void) { return 0; }' ] || fail "--source"
bash "$T/asb_fake.sh" pass >/dev/null 2>&1 || fail "a passing test failed the suite"
out="$(bash "$T/asb_fake.sh" 2>&1)" && fail "a failing test passed the suite"
printf '%s\n' "$out" | grep -qx 'FAILED: fail' || fail "the failure is not named: $out"
printf '%s\n' "$out" | grep -qx 'FAILED: errexit' || fail "set -e no longer ends a test: $out"
printf '%s\n' "$out" | grep -q 'errexit-leaked' && fail "a test kept running past set -e"
printf '%s\n' "$out" | grep -qx 'pass-ran' || fail "a failure stopped the next test"
printf '%s\n' "$out" | grep -qx 'trap-ran' || fail "an EXIT trap did not run"
bash "$T/asb_fake.sh" nosuch >/dev/null 2>&1 && fail "an unknown test name passed"
R="$ROOT/tools/asb_full_regression.sh"
grep -q 'for suite in tests/asb_\*.sh; do' "$R" || fail "the regression does not run the suites"
grep -q 'queue "$area: $name" bash "$suite" "$name"' "$R" || fail "suite tests are not queued one by one"
grep -q 'tests/test_' "$R" && fail "the regression still names a test file"
grep -q 'bash "$MODDIR/tests/asb_smart.sh" --source "$_t"' "$ROOT/tools/asb_lint.sh" || fail "lint does not build the Smart fixtures from the suite"
for w in build-test build-release; do
  grep -q 'tests/test_' "$ROOT/.github/workflows/$w.yml" && fail "$w.yml still requires a test file"
  for s in asb_smart asb_features asb_ui asb_system; do
    grep -q "tests/$s.sh" "$ROOT/.github/workflows/$w.yml" || fail "$w.yml does not require tests/$s.sh"
  done
done
echo "PASS suite runner: four suites, each test isolated in its own subshell, run one by one in parallel by the regression"
)

t_tree_check_runtime() (
# Runtime (fix161): CI names every file that differs from the delivered tree.
#
# The fix160 debug build failed with "FAIL dsp stereo width: legacy effect does not apply the
# width". The test was right: src/DSP/asb_dsp.c in the repository was still the fix159 file - it
# had not been uploaded with the rest of the delivery (CHANGELOG.md neither, which back then
# drew the lint warning "no section heading for V65"; fix199 later dropped that warning - the
# build must not depend on the changelog). The real tools/asb_tree_check.sh is run on a made-up
# tree: unchanged, one file edited, one missing, the files it must ignore, CI annotations and
# the --strict exit. fix164: a file left over from an older delivery (the tests that became
# four suites) is named as extra, so the owner knows what to delete.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/asb_tree_check.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL tree check: $*" >&2; fail=1; }
# fix177: a local tool. The CI step annotated every build with the owner's own repository
# differences ("Tree differs from the delivered archive"), which told him nothing to act on.
for w in build-test build-release; do
  grep -q 'asb_tree_check' "$ROOT/.github/workflows/$w.yml" && f "$w.yml still runs the tree check"
done
mkdir -p "$T/r/src/DSP" "$T/r/tools" "$T/r/.github/workflows" "$T/r/src/DSP_AIDL/prebuilt"
echo a > "$T/r/src/DSP/asb_dsp.c"; echo b > "$T/r/CHANGELOG.md"; echo c > "$T/r/service.sh"
echo v > "$T/r/module.prop"; echo u > "$T/r/update.json"; echo w > "$T/r/.github/workflows/x.yml"; echo p > "$T/r/src/DSP_AIDL/prebuilt/lib.so"
export ASB_TREE_ROOT="$T/r"
out="$(sh "$C" write)"; printf '%s\n' "$out" | grep -q 'tree manifest: 3 files' || f "manifest should hold the 3 source files: $out"
grep -q 'module.prop\|update.json\|\.github\|prebuilt' "$T/r/tools/asb_tree.sha256" && f "manifest lists files the owner edits or CI builds"
out="$(sh "$C" check)"; printf '%s\n' "$out" | grep -q 'every delivered file is here and unchanged (3 files)' || f "clean tree not recognised: $out"
echo v2 > "$T/r/module.prop"; echo w2 > "$T/r/.github/workflows/x.yml"
out="$(sh "$C" check)"; printf '%s\n' "$out" | grep -q 'unchanged' || f "edits to module.prop or a workflow were reported: $out"
echo old > "$T/r/src/DSP/asb_dsp.c"; rm "$T/r/CHANGELOG.md"
out="$(sh "$C" check)"; rc=$?
[ "$rc" = 0 ] || f "a differing tree failed the step without --strict"
printf '%s\n' "$out" | grep -q 'this tree is NOT the delivered one - 1 file(s) differ, 1 missing, 0 extra' || f "summary line: $out"
printf '%s\n' "$out" | grep -qx '    differs: src/DSP/asb_dsp.c' || f "the stale file is not named: $out"
printf '%s\n' "$out" | grep -qx '    missing: CHANGELOG.md' || f "the missing file is not named: $out"
mkdir -p "$T/r/tests"; echo old > "$T/r/tests/test_old_runtime.sh"
out="$(sh "$C" check)"
printf '%s\n' "$out" | grep -q 'this tree is NOT the delivered one - 1 file(s) differ, 1 missing, 1 extra' || f "summary with a leftover: $out"
printf '%s\n' "$out" | grep -qx '    extra: tests/test_old_runtime.sh' || f "the leftover file is not named: $out"
out="$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$T/sum" sh "$C" check)"
printf '%s\n' "$out" | grep -q '^::warning' && f "CI annotations are back: $out"
[ -s "$T/sum" ] && f "a job summary was written: $(cat "$T/sum")"
sh "$C" check --strict >/dev/null 2>&1 && f "--strict passed a differing tree"
rm -f "$T/r/tools/asb_tree.sha256"
out="$(sh "$C" check)"; printf '%s\n' "$out" | grep -q 'none in this tree' || f "no manifest should be said, not failed: $out"
[ "$fail" = 0 ] && echo "PASS tree check: files that differ from the delivered tree, are missing or are left over are named on request - never as CI annotations"
exit "$fail"
)

t_update_handover_theme_contract() (
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }
absent() { ! grep -Fq -- "$2" "$1" || fail "unexpected $2 in ${1#$ROOT/}"; }

INSTALL="$ROOT/common/install.sh"
SERVICE="$ROOT/service.sh"
WEB="$ROOT/webroot/index.html"

# A manager that removes the old modules/<id> directory before customize.sh must still
# accept ASB's durable, module-specific snapshot. A true uninstall clears that state.
need "$INSTALL" 'if [ -z "$_src" ] && [ -f "$_snap_src" ]; then'
# The migration strips device_bounds_override from COPIES: editing the running module's
# live governor.conf made the governor drop device bounds until the next reboot.
need "$INSTALL" 'sed -i '"'"'/^[[:space:]]*device_bounds_override=/d'"'"' "$_mig_tmp/old.conf"'
grep -q 'sed -i .*device_bounds_override=/d.*"\$_stale_conf"' "$INSTALL" && fail 'installer edits the live config in place again'
need "$INSTALL" 'Root managers do not agree on update ordering'
need "$INSTALL" 'update_snapshot_state'
need "$INSTALL" 'named_profiles=$(find /data/adb/asb/config_profiles'
need "$INSTALL" "-name '*.conf'"
need "$INSTALL" 'smart_learning='
need "$SERVICE" 'local _expected_schema=20'
need "$INSTALL" '"schema_version": 20'
need "$INSTALL" 'radio_policy_enable net_wifi_leave'

# Watcher lifecycle is late-boot, exact-process scoped and restored at uninstall.
need "$SERVICE" 'asb_wifi_fallback.sh" reconcile'
need "$ROOT/uninstall.sh" 'asb_wifi_fallback.sh" stop'
# fix134: the leave watcher runs on weak/unusable/aggressive, cellular master or not - the
# master (and LPM) only decide whether mobile data is kept warm in advance.
need "$ROOT/action.sh" 'T_N_FB_ACTIVE="Wi-Fi leave watch: %s"'
need "$ROOT/tools/asb_diag.sh" 'Wi-Fi leave watch ($_nwl_d, below'
need "$ROOT/runtime/asb_lpm.sh" 'if ! _feat_on LPM || ! _radio_policy_enabled; then'
need "$ROOT/runtime/asb_wifi_fallback.sh" '_enabled() { case "$(_cfg net_wifi_leave)" in weak|unusable|aggressive) return 0 ;; esac; return 1; }'
absent "$ROOT/runtime/asb_wifi_fallback.sh" '_radio_policy_enabled && [ "$(_cfg net_wifi_leave)" = aggressive ]'

# Palette and Glass material are restored before first paint; the same compact pair appears
# beside the version badge on all three surfaces.
need "$WEB" "var t=localStorage.getItem('asb_theme'),b=localStorage.getItem('asb_glass_base');if(t==='light'||(t==='glass'&&b==='light'))"
need "$WEB" 'asbPaintThemeControls()'
need "$WEB" 'data-theme-toggle="verBadge"'
need "$WEB" 'data-theme-toggle="liveVerBadge"'
need "$WEB" 'data-theme-toggle="cfgVerBadge"'
need "$WEB" 'data-theme-choice="dark"'
need "$WEB" 'data-theme-choice="light"'
need "$WEB" 'data-theme-choice="glass"'
need "$WEB" 'data-tech-icon="theme_moon"'
need "$WEB" 'data-tech-icon="theme_glass"'
need "$WEB" 'theme_glass:'
absent "$WEB" 'data-tech-icon="quiet_moon"></span></button><button class="theme-choice"'
need "$WEB" 'theme_moon:'
# CSS matches literal value selectors, so palette and material updates must be immediate.
need "$WEB" "setAttribute('data-asb-theme', 'light')"
need "$WEB" "removeAttribute('data-asb-theme')"
need "$WEB" "setAttribute('data-asb-glass', '1')"
need "$WEB" "removeAttribute('data-asb-glass')"
absent "$WEB" "toggleAttribute('data-asb-theme'"
absent "$WEB" "toggleAttribute('data-asb-glass'"
# fix192: the pair is one segmented capsule in the bottom bar's material; the selected icon
# sits on the bar's tonal pill (which follows html[data-asb-theme]) - never a full green fill.
need "$WEB" '.theme-choice { position:relative; z-index:1; display:grid; place-items:center; width:38px; height:24px;'
need "$WEB" '<div class="badge badge-a" id="verBadge">V65</div>'
need "$WEB" '<div class="badge badge-a" id="liveVerBadge">V65</div>'
need "$WEB" '<div class="badge badge-a" id="cfgVerBadge">V65</div>'
need "$WEB" '.theme-choice.active { color:var(--accent); }'
need "$WEB" 'html[data-asb-theme="light"] .theme-toggle::before { transform: translateX(38px); }'
need "$WEB" 'html[data-asb-glass="1"] .theme-toggle::before { transform: translateX(76px); }'
need "$WEB" 'html[dir="rtl"][data-asb-glass="1"] .theme-toggle::before { transform: translateX(-76px); }'
need "$WEB" 'html[data-asb-glass="1"] .theme-toggle::before'
absent "$WEB" '.theme-choice.active { color:#04120f; background:linear-gradient'
absent "$WEB" ':is(.cfg-reset-choice.armed,.theme-choice.active) { color:#04120f !important; }'
# These cover readable dialog/title copy, Smart monitor telemetry and small configuration text.
need "$WEB" '--text-secondary:#365048; --text-tertiary:#526b62;'
need "$WEB" ':is(.cfg-profile-title,.cfg-reset-title,.debug-action-wait-title) { color:var(--text) !important; }'
need "$WEB" '.smart-banner-value { color:#006c56; }'
need "$WEB" '.cfg-desc { color:var(--text-secondary); opacity:1; }'
# Android WebView light controls: every control that had retained translucent light text has an explicit override.
# fix192: chip and version are text segments inside one paper capsule in light mode, not
# two tinted chips of their own.
need "$WEB" 'html[data-asb-theme="light"] .hdr-cap .badge { background:transparent !important;'
absent "$WEB" 'html[data-asb-theme="light"] .badge-a {'
need "$WEB" 'html[data-asb-theme="light"] .cfg-sel-btn { color:var(--text) !important; background:#fff !important;'
need "$WEB" 'html[data-asb-theme="light"] .cfg-sel-pop button { color:var(--text-secondary) !important;'
need "$WEB" 'html[data-asb-theme="light"] .cfg-range input[type="range"] { height:6px; background:linear-gradient(90deg,#adc2bb,#e4eeeb) !important;'
need "$WEB" 'html[data-asb-theme="light"] .cfg-seg button.on { color:#063d32; background:linear-gradient(135deg,#b7f4e6,#b8edf2);'
# Only outer cards may receive the paper surface; broad substring selectors paint transparent
# children into the rectangular white seams reported in the light-theme screenshots.
need "$WEB" 'Only outer material surfaces'
# The light-theme override list is checked by membership, not as one literal line:
# adding a selector to it is a normal change, and pinning the whole line makes every
# such addition look like a regression.
need "$WEB" '.cfg-reset-dialog,.debug-action-wait-sheet,'
need "$WEB" '.asb-tabbar) {'
absent "$WEB" '[class*="cfg-row"]'
absent "$WEB" '[class*="live-cell"]'
need "$WEB" '.cfg-search::placeholder { color:#61776f; opacity:1; }'
need "$WEB" '.cfg-switch.on { background:linear-gradient(135deg,#57d9cc,#53cce8);'
# The page-ending support caption and every profile glyph must remain readable while
# inheriting the exact same accent token as the corresponding selected profile card.
need "$WEB" '.tg-link-sub {'
need "$WEB" 'color: var(--text-secondary);'
need "$WEB" 'font-weight: 600;'
need "$WEB" 'html[data-asb-theme="light"] .tg-link-sub { color:#315a4f !important; }'
need "$WEB" '.pbtn[data-p] { --tech-icon: var(--c); }'
need "$WEB" '.pbtn-smart.on .pico-smart .tech-icon { color:var(--c);'
need "$WEB" 'html[data-asb-theme="light"] .pbtn-smart.on .pico-smart .tech-icon { color:var(--c);'
absent "$WEB" '.pbtn[data-p="balanced"]    { --tech-icon: #aab8cb; }'
need "$WEB" 'stroke-width: 1.95;'
need "$WEB" "key:'radio_policy_enable'"
# Radio master must be the first actual card after the Network heading, ahead of every dependent setting.
first_net_card=$(awk '/\/\/ ---- Network/{in_network=1; next} in_network && /\{ key:/{print; exit}' "$WEB")
[ "$first_net_card" = "  { key:'radio_policy_enable', type:'bool', def:'0', stock:'0', name:'Cellular / radio controls'," ] || fail 'radio policy master is not the first Network card'
need "$WEB" 'radio_policy_enable:APPLY_LIVE'
need "$WEB" '--bg:#edf4f1'
need "$WEB" 'ASB_UI_BUILD=light-surface-contract-1'

echo 'PASS: update continuity, active fallback and theme contract'
)

t_update_snapshot_only_migration() (
# Contract: some root managers remove modules/<id> before customize.sh runs. The ASB-owned
# durable snapshot must then preserve user governor settings without touching learner/profile data.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL snapshot-only update: $*" >&2; exit 1; }
need_line() { grep -Fqx -- "$2" "$1" >/dev/null || fail "missing [$2] in ${1##*/}"; }

MODID=AutoSystemBoost
NVBASE="$TMP/nv"
MODPATH="$TMP/new_module"
STATE="$TMP/state"
mkdir -p "$NVBASE/modules_update" "$MODPATH/config" "$STATE/config_profiles/user.smart"
cp "$ROOT/config/governor.conf.shipped" "$MODPATH/config/governor.conf"

# This represents ASB's prior atomic snapshot. There is deliberately no NVBASE/modules/<id>.
cat > "$STATE/governor.conf.snapshot" <<'EOF'
# ASB WebUI settings snapshot — survives module update/reinstall
radio_policy_enable=1
net_wifi_leave=1
net_wifi_leave=1
audio_profile=eq_friendly
sustained_temp_enter=63
EOF
printf 'smart\n' > "$STATE/current_profile.bak"
printf 'smart-session-payload\n' > "$STATE/config_profiles/user.smart/manifest"
printf 'smart-history\n' > "$STATE/session_history.jsonl"
printf 'module_id=AutoSystemBoost\n' > "$STATE/update_snapshot_state"
printf '3\n' > "$STATE/config_schema"

# Extract the exact production function and redirect only its durable path for test isolation.
sed -n '/^asb_preserve_user_config() {/,/^}/p' "$ROOT/common/install.sh" | \
  sed "s|/data/adb/asb|$STATE|g" > "$TMP/preserve_fn.sh"
[ -s "$TMP/preserve_fn.sh" ] || fail 'could not extract production preserve function'
ui_print() { :; }
asb_neutralise_fresh_install() { fail 'snapshot-only update was incorrectly treated as fresh'; }
# shellcheck disable=SC1090
source "$TMP/preserve_fn.sh"
# The installer itself does not set errexit: grep returning 1 for an untouched optional key is
# normal inside its migration loop. Retain strict assertions before/after, but invoke the exact
# production function under the same semantics.
set +e
asb_preserve_user_config
_preserve_rc=$?
set -e
[ "$_preserve_rc" -eq 0 ] || fail "preserve function returned $_preserve_rc"

[ "$ASB_CONFIG_MIGRATION_MODE" = preserved ] || fail "migration mode is $ASB_CONFIG_MIGRATION_MODE"
[ "$ASB_CONFIG_MIGRATION_SOURCE" = snapshot ] || fail "migration source is $ASB_CONFIG_MIGRATION_SOURCE"
[ "$ASB_CONFIG_MIGRATED_COUNT" -ge 5 ] || fail 'snapshot values were not migrated'
need_line "$MODPATH/config/governor.conf" 'radio_policy_enable=1'
need_line "$MODPATH/config/governor.conf" 'net_wifi_leave=1'
need_line "$MODPATH/config/governor.conf" 'net_wifi_leave=1'
need_line "$MODPATH/config/governor.conf" 'audio_profile=eq_friendly'
need_line "$MODPATH/config/governor.conf" 'sustained_temp_enter=63'
need_line "$MODPATH/current_profile" 'smart'
need_line "$STATE/config_profiles/user.smart/manifest" 'smart-session-payload'
need_line "$STATE/session_history.jsonl" 'smart-history'
[ -f "$STATE/governor.conf.snapshot" ] || fail 'migration removed its own durable snapshot'

echo 'PASS snapshot-only update migration contract'
)

t_v62_to_v64_migration() (
# Public-release migration contract. V62 schema 17 lacked the keys below; the
# remaining V62 defaults matched the V64 shipped config. Keep this list explicit:
# a future schema change must update its own migration rather than accidentally making
# the V62 upgrade path untestable.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_v62_v63_migration.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
need_line() { grep -qx "$2" "$1" || fail "missing '$2' in $1"; }

MODDIR="$TMP/module"
STATE="$TMP/state"
mkdir -p "$MODDIR/config" "$STATE"
cp "$ROOT_DIR/config/governor.conf" "$MODDIR/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MODDIR/config/governor.conf.shipped"

# Reconstruct the shipped V62 config shape from the exact V62→V64 schema delta.
# Do not create /data/adb: this is an isolated host contract.
V62_ONLY_MISSING=(
  gnss_trim net_rps net_txqueue night_modem_idle perf_ceiling_pct shadow_mode
  thermal_budget_dwell_s thermal_budget_enable thermal_budget_light_headroom_pct
  thermal_budget_light_trim_pct thermal_budget_moderate_headroom_pct
  thermal_budget_moderate_trim_pct thermal_budget_severe_headroom_pct
  thermal_budget_severe_trim_pct wakelock_action radio_policy_enable net_wifi_leave
)
for key in "${V62_ONLY_MISSING[@]}"; do
  sed -i "/^[[:space:]]*${key}=/d" "$MODDIR/config/governor.conf"
done

# Representative persisted V62 user values must survive the update unchanged.
sed -i \
  -e 's/^sustained_temp_enter=.*/sustained_temp_enter=64/' \
  -e 's/^sustained_temp_ceiling=.*/sustained_temp_ceiling=66/' \
  -e 's/^sustained_temp_mode=.*/sustained_temp_mode=manual/' \
  -e 's/^smart_battery_bias=.*/smart_battery_bias=420/' \
  "$MODDIR/config/governor.conf"
printf '%s\n' 17 > "$MODDIR/config/.schema_version"
cp "$MODDIR/config/governor.conf" "$TMP/v62_before.conf"

# Extract and run the exact production migration function under test-local paths.
sed -n '/^asb_migrate_governor_conf() {/,/^}/p' "$ROOT_DIR/service.sh" > "$TMP/migrate_fn.sh"
[ -s "$TMP/migrate_fn.sh" ] || fail "cannot extract production migration function"
asb_log() { printf '%s\n' "$*" >> "$TMP/migrate.log"; }
# shellcheck disable=SC1090
source "$TMP/migrate_fn.sh"
asb_migrate_governor_conf

need_line "$MODDIR/config/.schema_version" '20'
find "$MODDIR/config" -maxdepth 1 -name 'governor.conf.bak.schema17.*' | grep -q . || fail "V62 backup missing"
for line in \
  'sustained_temp_enter=64' \
  'sustained_temp_ceiling=66' \
  'sustained_temp_mode=manual' \
  'smart_battery_bias=420'; do
  need_line "$MODDIR/config/governor.conf" "$line"
done
for key in "${V62_ONLY_MISSING[@]}"; do
  expected=$(grep -m1 "^[[:space:]]*${key}=" "$MODDIR/config/governor.conf.shipped")
  [ -n "$expected" ] || fail "missing shipped V64 default for $key"
  need_line "$MODDIR/config/governor.conf" "$expected"
done
if ! awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {p=index($0,"="); if(!p)next; k=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); if(++seen[k]>1)bad=1} END{exit bad}' "$MODDIR/config/governor.conf"; then
  fail "migration left duplicate keys"
fi

# Re-running migration must be a no-op once marker 20 is committed.
first_sum=$(sha256sum "$MODDIR/config/governor.conf" | awk '{print $1}')
asb_migrate_governor_conf
second_sum=$(sha256sum "$MODDIR/config/governor.conf" | awk '{print $1}')
[ "$first_sum" = "$second_sum" ] || fail "migration is not idempotent at schema 20"

# The V64 safe writer must accept and atomically update an added V64 key afterwards.
MODDIR="$MODDIR" ASB_CONFIG_STATE="$STATE" sh "$ROOT_DIR/runtime/asb_config_safe.sh" set gnss_trim 1 >/dev/null
need_line "$MODDIR/config/governor.conf" 'gnss_trim=1'
need_line "$STATE/config_last_txn" 'result_class=success'

echo "PASS V62-to-V64 migration contract"
)

t_v64_hardening_contract() (
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WRITER="$ROOT_DIR/runtime/asb_config_safe.sh"
BACKUP="$ROOT_DIR/tools/asb_config_backup.sh"
WEBUI="$ROOT_DIR/webroot/index.html"
TEST_WF="$ROOT_DIR/.github/workflows/build-test.yml"
RELEASE_WF="$ROOT_DIR/.github/workflows/build-release.yml"
MODULE_PROP="$ROOT_DIR/module.prop"
INSTALL="$ROOT_DIR/common/install.sh"
DIAG="$ROOT_DIR/tools/asb_diag.sh"
LINT="$ROOT_DIR/tools/asb_lint.sh"
REFERENCE_MODEL="$ROOT_DIR/docs/reference_models/asb_allocator_reference_model.py"
REFERENCE_DOC="$ROOT_DIR/docs/reference_models.md"
PROFILE_CORE="$ROOT_DIR/runtime/profile_core.sh"
BLUR_APPLY="$ROOT_DIR/runtime/asb_blur_apply.sh"
SERVICE="$ROOT_DIR/service.sh"
need() { grep -Fq -- "$2" "$1" || { echo "FAIL: $1 missing [$2]" >&2; exit 1; }; }
absent() { ! grep -Fq -- "$2" "$1" || { echo "FAIL: $1 still contains [$2]" >&2; exit 1; }; }

# Lock evidence and recovery must use the same canonical directory the writer acquires.
need "$WRITER" 'LOCK="$STATE/config.lock"'
need "$WRITER" 'LOCK_WAIT_TICKS="${ASB_CONFIG_LOCK_WAIT_TICKS:-100}"'
need "$WRITER" 'LOCK_STALE_S="${ASB_CONFIG_LOCK_STALE_S:-30}"'
need "$WRITER" '_lock_reclaim_stale()'
need "$WRITER" 'mv "$LOCK" "$_old"'
need "$WRITER" 'lock_path=config.lock'
need "$WRITER" 'lock_recovered=$_LOCK_RECOVERED'
absent "$WRITER" '$STATE/lock/pid'

# Profile manager is closed-name, checksum-protected and always restores through writer import.
need "$BACKUP" '_profile_ok()'
need "$BACKUP" 'config_profiles'
need "$BACKUP" 'profile checksum mismatch or absent'
# Exact writer call prevents a future direct sed/echo restore implementation.
need "$BACKUP" 'sh "$WRITER" import "$_in" "$SNAPSHOT" "$@"'
need "$BACKUP" 'list|create|replace|preview|restore|delete'
need "$BACKUP" 'ASB_SMART_PROFILE_SCHEMA=3'
need "$BACKUP" "'# ASB_SMART_PROFILE_SCHEMA=1'|'# ASB_SMART_PROFILE_SCHEMA=2'|'# ASB_SMART_PROFILE_SCHEMA=3'"
need "$BACKUP" '_smart_file_ok()'
need "$BACKUP" 'buckets.bin.bak'
need "$BACKUP" 'smart_mode_enabled'
need "$BACKUP" 'session_history.jsonl'
need "$BACKUP" 'session_stats.json'
need "$BACKUP" 'pstats_battery.json'
need "$BACKUP" '_smart_max_bytes()'
need "$BACKUP" 'smart_restore()'
need "$BACKUP" '.smart_restore.stage.$$'
need "$BACKUP" 'smart_learning=restored'
need "$BACKUP" 'smart_learning_files=$_n'
need "$BACKUP" 'smart_learning_bytes=$_total'
need "$BACKUP" '_migrate_legacy_external()'
need "$BACKUP" 'asb_settings_backup.conf'

# UI must use the helper and object result handling; the former one-file /sdcard flow is gone.
need "$WEBUI" "const CFG_PROFILE_HELPER = MD + '/tools/asb_config_backup.sh';"
need "$WEBUI" 'data-i18n="cfg_profile_save_short"'
need "$WEBUI" 'data-i18n="cfg_profile_load_short"'
absent "$WEBUI" 'data-i18n="cfg_profile_storage_hint"'
need "$WEBUI" 'function cfgProfileNameOK(name)'
need "$WEBUI" ' cfgProfileArgs()'
need "$WEBUI" "' restore '"
need "$WEBUI" 'function cfgProfilePaintYield()'
need "$WEBUI" '_cfgProfile.busy = true;'
need "$WEBUI" 'await cfgProfilePaintYield();'
need "$WEBUI" "T('cfg_profile_apply_wait','Please wait while ASB restores every saved setting. Do not close this window.')"
absent "$WEBUI" 'cfgProfilePreview'
absent "$WEBUI" 'cfg_profile_prepare_apply'
need "$WEBUI" 'r.errno !== 0'
absent "$WEBUI" 'CFG_BACKUP_PATH'
need "$WEBUI" 'cfg_profile_smart_saved'
# fix142: the apply outcome reads smart_learning=<state> by key and names each state.
need "$WEBUI" "cfgProfileKV(detail, 'smart_learning')"
need "$WEBUI" "restored: T('cfg_res_smart_restored'"
# night_modem_idle is read after governor config reload, so it must never fall through to
# the generic reboot-only metadata path.
need "$WEBUI" 'night_modem_idle:APPLY_LIVE'
need "$WEBUI" "'night_quiet_enable','night_modem_idle'"
need "$LINT" 'cards missing APPLY_MODE'
need "$LINT" 'locales missing global WebUI strings'

# `disable_blur=0` is a true user-owned stock/no-touch display state.  In particular, no
# post-boot WindowManager transaction may re-resolve a vendor screen-scale/density override.
# Explicit blur-off and an explicit WebUI return-to-stock action remain supported.
need "$PROFILE_CORE" '0) : ;;  # stock mode does not touch WindowManager or display configuration'
absent "$PROFILE_CORE" '0) asb_settings_put global disable_window_blurs 0'
need "$BLUR_APPLY" 'ASB_BLUR_BOOT_SYNC=0'
need "$BLUR_APPLY" '[ "${1:-}" = "--boot" ] && ASB_BLUR_BOOT_SYNC=1'
need "$BLUR_APPLY" 'elif [ "$ASB_BLUR_BOOT_SYNC" != "1" ]; then'
need "$BLUR_APPLY" 'wm disable-blur false >/dev/null 2>&1 || true'
need "$SERVICE" 'sh "$MODDIR/runtime/asb_blur_apply.sh" --boot >/dev/null 2>&1'
need "$SERVICE" 'elif [ "$_asb_blur_want" = "1" ]; then'
absent "$SERVICE" 'Re-assert BOTH directions, not just "off".'

# The former pytest file was a standalone reference implementation, not coverage of ASB C
# code. Keep it explicitly documented outside tests rather than pretending an unused Python
# dependency validates governor behaviour.
[ -f "$REFERENCE_MODEL" ] || { echo "FAIL: missing allocator reference model" >&2; exit 1; }
[ -f "$REFERENCE_DOC" ] || { echo "FAIL: missing reference-model boundary documentation" >&2; exit 1; }
need "$REFERENCE_DOC" '**not** executable tests of the AutoSystemBoost production implementation'
need "$REFERENCE_DOC" 'must be a host C harness'
if find "$ROOT_DIR/tests" -maxdepth 1 -type f -name '*invariant_asb_governor*' | grep -q .; then
  echo "FAIL: pytest reference model remains under tests" >&2; exit 1
fi
if grep -RIlE '^[[:space:]]*import[[:space:]]+pytest([[:space:]]|$)' "$ROOT_DIR/tests" 2>/dev/null | grep -q .; then
  echo "FAIL: pytest-dependent reference material remains under tests" >&2; exit 1
fi

# Test identity changes only after rsync in package staging. It keeps the public
# versionCode so V65-test1 can be manually flashed over V65; public source/OTA stay unchanged.
need "$TEST_WF" 'test_sequence:'
need "$TEST_WF" 'Positive test sequence after this public release'
need "$TEST_WF" 'TEST_SEQ_INPUT: ${{ inputs.test_sequence }}'
need "$TEST_WF" 'TEST_SEQ="${TEST_SEQ_INPUT:-}"'
need "$TEST_WF" 'TEST_CODE="$BASE_CODE"'
need "$TEST_WF" 'ASB_VER="${BASE_VER}-test${TEST_SEQ}"'
need "$TEST_WF" 'sed -i "s/^version=.*/version=${ASB_VER}/" "$PKG_TEST/module.prop"'
need "$TEST_WF" 'grep -qx "versionCode=${BASE_CODE}" "$PKG_TEST/module.prop"'
absent "$TEST_WF" 'TEST_CODE=$((BASE_CODE + TEST_SEQ))'
absent "$TEST_WF" 'one integer from 1 to 9'
need "$TEST_WF" 'name: ASB-${{ env.ASB_VER }}'
[ ! -e "$ROOT_DIR/.github/workflows/build-debug.yml" ] || { echo 'FAIL: separate debug workflow remains' >&2; exit 1; }

# Execute the workflow's real validation fragment: every positive decimal testN identifier
# is valid, but ambiguous/unsafe spellings must never become filenames or shell input.
TMP_TEST_GATE="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST_GATE"' EXIT HUP INT TERM
sed -n '/^          TEST_SEQ="${TEST_SEQ_INPUT:-}"$/,/^          TEST_CODE="$BASE_CODE"$/p' "$TEST_WF" > "$TMP_TEST_GATE/gate.sh"
[ -s "$TMP_TEST_GATE/gate.sh" ] || { echo 'FAIL: test workflow validation fragment missing' >&2; exit 1; }
test_sequence_valid() (
  BASE_CODE=640 TEST_SEQ_INPUT="$1"
  . "$TMP_TEST_GATE/gate.sh"
  [ "$TEST_SEQ" = "$1" ]
)
for _valid_seq in 1 9 10 42 999999999; do
  test_sequence_valid "$_valid_seq" || { echo "FAIL: valid test sequence rejected: $_valid_seq" >&2; exit 1; }
done
for _invalid_seq in '' 0 00 01 -1 +1 1.0 test10 '10 '; do
  if test_sequence_valid "$_invalid_seq" >"$TMP_TEST_GATE/invalid.out" 2>&1; then
    echo "FAIL: invalid test sequence accepted: $_invalid_seq" >&2
    exit 1
  fi
done
if ( BASE_CODE=64x TEST_SEQ_INPUT=10 . "$TMP_TEST_GATE/gate.sh" ) >"$TMP_TEST_GATE/invalid-base-code.out" 2>&1; then
  echo 'FAIL: non-decimal module versionCode accepted by test gate' >&2
  exit 1
fi

# Public module identity: only the FORMAT is pinned here (fix215). The exact version and
# versionCode are metadata the owner edits on his own schedule - a hard pin on the values
# (V65/65214) failed CI builds whose checkout simply had not merged the bump yet, which is
# precisely "module.prop must not influence the build". The update.json agreement moved to
# the release workflow for the same reason (see the fix213 block and build-release.yml).
grep -qE '^version=V[0-9]+(-[A-Za-z0-9.]+)?$' "$MODULE_PROP" || { echo 'FAIL: module.prop version is not V<number>' >&2; exit 1; }
grep -qE '^versionCode=[0-9]+$' "$MODULE_PROP" || { echo 'FAIL: module.prop versionCode is not decimal' >&2; exit 1; }

# Release publication must validate the immutable public identity rather than patching it from
# an arbitrary GitHub tag. Exercise the literal workflow fragment under safe subshell fixtures.
need "$RELEASE_WF" '- name: Validate release tag'
need "$RELEASE_WF" 'GITHUB_EVENT_NAME'
need "$RELEASE_WF" 'GITHUB_REF_TYPE'
need "$RELEASE_WF" 'does not match module version'
absent "$RELEASE_WF" 'sed -i "s/^version=.*/version=${TAG}/" module.prop'
TMP_RELEASE_GATE="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST_GATE" "$TMP_RELEASE_GATE"' EXIT HUP INT TERM
sed -n '/^          TAG="${GITHUB_REF_NAME:-}"$/,/^          fi$/p' "$RELEASE_WF" | sed 's/^          //' > "$TMP_RELEASE_GATE/gate.sh"
[ -s "$TMP_RELEASE_GATE/gate.sh" ] || { echo 'FAIL: release workflow identity gate missing' >&2; exit 1; }
release_identity_valid() (
  cd "$ROOT_DIR"
  GITHUB_REF_NAME="$1" GITHUB_EVENT_NAME="$2" GITHUB_REF_TYPE="$3"
  . "$TMP_RELEASE_GATE/gate.sh"
)
# workflow_dispatch uses the selected branch as ref name; it must not be treated as a
# release tag and therefore must pass for main or any other branch.
for _manual_ref in '' main develop maintenance/V64; do
  release_identity_valid "$_manual_ref" workflow_dispatch branch || { echo "FAIL: manual branch build rejected: $_manual_ref" >&2; exit 1; }
done
# GitHub Release and tag-ref runs may publish an asset, so only spellings for V64 are valid.
for _valid_tag in V65 v65 65; do
  release_identity_valid "$_valid_tag" release tag || { echo "FAIL: accepted release tag rejected: $_valid_tag" >&2; exit 1; }
  release_identity_valid "$_valid_tag" push tag || { echo "FAIL: accepted tag ref rejected: $_valid_tag" >&2; exit 1; }
done
for _invalid_tag in '' main V64 v64 64 V66 v66 66 debug10 'V65 '; do
  if release_identity_valid "$_invalid_tag" release tag >"$TMP_RELEASE_GATE/invalid-tag.out" 2>&1; then
    echo "FAIL: mismatched release tag accepted: $_invalid_tag" >&2
    exit 1
  fi
done

# Installer and diagnostics expose, but do not alter, the actual config migration result.
need "$INSTALL" 'ASB_CONFIG_MIGRATION_MODE=unknown'
need "$INSTALL" 'ASB_CONFIG_MIGRATION_MODE=fresh'
need "$INSTALL" 'ASB_CONFIG_MIGRATION_MODE=preserved'
need "$INSTALL" 'last_install_state'
need "$INSTALL" 'asb_prepare_webui_first_install()'
need "$INSTALL" 'Full component set prepared; optional tweaks remain at stock.'
absent "$INSTALL" 'All components are prepared. Optional tweaks stay stock until you choose them in WebUI.'
need "$INSTALL" 'ASB_DSP_REGISTRATION_DONE'
need "$INSTALL" 'ui_print "      + DSP: $(printf "${ASB_L_DSP_REG_N'
need "$INSTALL" 'ASB_AUDIO_CLONE_DEFER=1'
need "$INSTALL" 'ASB_L_MIRROR_AUDIO_TOTAL'
need "$INSTALL" 'asb_neutralise_fresh_install'
absent "$INSTALL" 'asb_choose_cat AUDIO'
need "$DIAG" 'last install: config='

for f in "$ROOT_DIR"/webroot/i18n/*.json; do
  need "$f" '"cfg_profile_name"'
  need "$f" '"cfg_profile_restored"'
  need "$f" '"cfg_profile_save"'
  need "$f" '"cfg_profile_load"'
  need "$f" '"cfg_profile_save_short"'
  need "$f" '"cfg_profile_load_short"'
  # EN/RU carry the dedicated Smart strings; other locales fall back to English through T().
done
cmp -s "$ROOT_DIR/tools/asb_diag.sh" "$ROOT_DIR/system/bin/asbdiag" || { echo 'FAIL: asbdiag copies differ' >&2; exit 1; }
echo 'PASS V64 hardening contract'
)

t_v64_p0_contract() (
# V64 P0 regression contract: actual Trial transaction + thermal producer/consumer safety.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_v64_p0_contract.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- Thermal consensus/state/asbdiag contract --------------------------------------------
MET="$ROOT/src/asb_metrics.h"
GOV="$ROOT/src/asb_governor.c"
DIAG="$ROOT/tools/asb_diag.sh"
BIN_DIAG="$ROOT/system/bin/asbdiag"

cmp -s "$DIAG" "$BIN_DIAG" || fail "asbdiag copies differ"
grep -Fq 'thermal_control_source=' "$GOV" || fail "state misses thermal_control_source"
grep -Fq 'thermal_source_confidence=' "$GOV" || fail "state misses thermal_source_confidence"
grep -Fq 'thermal_peer_hi=' "$GOV" || fail "state misses thermal_peer_hi"
grep -Fq 'thermal_peer_lo=' "$GOV" || fail "state misses thermal_peer_lo"
grep -Fq 'thermal_peer_n=' "$GOV" || fail "state misses thermal_peer_n"
grep -Fq 'thermal_consensus=' "$GOV" || fail "state misses thermal_consensus"
grep -Fq "^thermal_control_source=" "$DIAG" || fail "diag reads stale thermal_cpu_type key"
grep -Fq "^thermal_source_confidence=" "$DIAG" || fail "diag reads stale thermal_src_conf key"
grep -Fq "^thermal_peer_hi=" "$DIAG" || fail "diag misses peer high"
grep -Fq "^thermal_peer_lo=" "$DIAG" || fail "diag misses peer low"
! grep -Fq 't->cpu_max_c = hi' "$MET" || fail "non-CPU peer still replaces CPU control"
# Board read must precede consensus; peer telemetry must reset for a no-peer tick.
board_line=$(grep -n 'Board must be read before consensus' "$MET" | head -1 | cut -d: -f1)
cons_line=$(grep -n 'Thermal consensus v2:' "$MET" | head -1 | cut -d: -f1)
[ -n "$board_line" ] && [ -n "$cons_line" ] && [ "$board_line" -lt "$cons_line" ] || fail "board read order is stale"
grep -Fq 'g_thermal_peer_n  = 0;' "$MET" || fail "peer count is not reset"
grep -Fq "g_thermal_consensus_note[0] = '\\0';" "$MET" || fail "consensus note is not reset"
pass "thermal state/diagnostic and non-CPU control contract"

# --- Trial transaction contract ------------------------------------------------------------
MOD="$TMP/mod"
STATE="$TMP/state"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE"
cp "$ROOT/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
cp "$ROOT/runtime/asb_trial.sh" "$MOD/runtime/asb_trial.sh"
cp "$ROOT/runtime/asb_apply_ledger.sh" "$MOD/runtime/asb_apply_ledger.sh"
chmod 0755 "$MOD/runtime/asb_config_safe.sh" "$MOD/runtime/asb_trial.sh"
TRIAL="sh $MOD/runtime/asb_trial.sh"
get_conf() { awk -F= -v k="$1" '$1 ~ /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*$/ {x=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); if(x==k){v=$2; sub(/#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/, "",v); print v; exit}}' "$MOD/config/governor.conf"; }

old_doze=$(get_conf doze_level)
case "$old_doze" in moderate) new_doze=stock ;; *) new_doze=moderate ;; esac
ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL start doze_level "$new_doze" 1 >/dev/null || fail "trial start rejected valid setting"
[ "$(get_conf doze_level)" = "$new_doze" ] || fail "trial start did not apply config"
[ -f "$STATE/trial/doze_level.trial" ] || fail "trial record absent after apply"
ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL confirm doze_level >/dev/null || fail "trial confirm failed"
[ -f "$STATE/trial/doze_level.kept" ] || fail "kept record absent after confirm"
[ "$(get_conf doze_level)" = "$new_doze" ] || fail "confirm changed accepted value"

old_gnss=$(get_conf gnss_trim)
case "$old_gnss" in 0) new_gnss=1 ;; *) new_gnss=0 ;; esac
ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL start gnss_trim "$new_gnss" 1 >/dev/null || fail "second trial start failed"
[ "$(get_conf gnss_trim)" = "$new_gnss" ] || fail "second trial did not apply"
ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL revert gnss_trim >/dev/null || fail "trial revert failed"
[ "$(get_conf gnss_trim)" = "$old_gnss" ] || fail "trial revert did not restore exact previous value"
[ ! -f "$STATE/trial/gnss_trim.trial" ] || fail "trial record removed only after failed/unfinished revert"

# Malformed/path-like keys are rejected before any state path is created.
if ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL start '../escaped' 1 1 >/dev/null 2>&1; then
  fail "path-like trial key accepted"
fi
[ ! -e "$STATE/escaped.trial" ] && [ ! -e "$STATE/escaped.before" ] || fail "path-like trial key escaped trial directory"
# Allowlisted key with invalid config scalar must not become an active trial.
if ASB_CONFIG_STATE="$STATE" MODDIR="$MOD" $TRIAL start doze_level invalid 1 >/dev/null 2>&1; then
  fail "invalid config value accepted by trial"
fi
[ ! -f "$STATE/trial/doze_level.trial" ] || fail "failed start created active trial"
pass "Trial allowlist, apply/read-back, confirm, revert and path protection contract"

echo "ALL V64 P0 CONTRACTS PASSED"
)

t_v64_webui_trial_ledger_contract() (
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
python3 - "$ROOT" <<'ASB_PY_EOF'
"""Host contract for the V64 Trial/Ledger WebUI safety surface."""
from pathlib import Path
import json
import re
import sys

ROOT = Path(sys.argv[1])
HTML = (ROOT / 'webroot/index.html').read_text(encoding='utf-8')
TRIAL = (ROOT / 'runtime/asb_trial.sh').read_text(encoding='utf-8')
errors = []

def require(needle: str, message: str) -> None:
    if needle not in HTML:
        errors.append(message)

def before(first: str, second: str, message: str) -> None:
    a, b = HTML.find(first), HTML.find(second)
    if a < 0 or b < 0 or a >= b:
        errors.append(message)

# WebUI bridge contract: ksu.exec resolves {errno, stdout, stderr}; a shell failure does not
# reject the Promise. Trial/Ledger must therefore never treat a result object as a string.
require("ok({errno:e, stdout:o||'', stderr:r||''})", 'run() result object contract missing')
require("function runText(result)", 'missing safe bridge output helper')
require("function runOk(result)", 'missing bridge errno helper')
require("const raw = (result && result.stdout) || '';", 'ledger/trial loader does not use run().stdout')
require("if (!runOk(pv))", 'preview failure is not checked before confirmation')
require("if (!runOk(out))", 'trial start/action does not check run().errno')
require("const text = runText(out);", 'trial command output is not normalized from stdout/stderr')

# UI Trial keys must exactly match the runtime allowlist. A button without backend support is a
# release blocker because it promises a transaction that the device will always reject.
ui_match = re.search(r"const TRIAL_KEYS\s*=\s*\[([^]]*)\]", HTML, re.S)
ui_keys = set(re.findall(r"'([A-Za-z][A-Za-z0-9_]*)'", ui_match.group(1) if ui_match else ''))
backend_match = re.search(r"_trial_key_allowed\(\) \{.*?case .*? in\s*(.*?)\)\s*return 0", TRIAL, re.S)
backend_text = (backend_match.group(1) if backend_match else '').replace('\\\n', ' ')
backend_keys = set(re.findall(r"[A-Za-z][A-Za-z0-9_]*", backend_text))
if ui_keys != backend_keys:
    errors.append(f'Trial key mismatch: UI-only={sorted(ui_keys-backend_keys)}, backend-only={sorted(backend_keys-ui_keys)}')
if 'perf_ceiling_pct' in ui_keys:
    errors.append('perf_ceiling_pct shown as Trial without backend semantic contract')

# Device rejection is factual outcome and must outrank an informational active-trial badge.
before('const _lb = ledgerBadge(it.key);', 'const _tl = trialHoursLeft(it.key);',
       'ledger rejection must outrank active trial in cfgStatus')
require("if (trialExpired(it.key)) return { cls:'warn', text: T('trial_expired_wait'", 'missing expired Trial status')
before('} else if (trialExpired(it.key)) {', "b.textContent = T('trial_try'", 
       'expired record can still expose a second Trial start button')

# First render must wait for safety evidence, preventing a false successful-looking card.
require('await cfgLoadV64State();\n  cfgRender();', 'V64 evidence is not awaited before first cfgRender')

# All user-facing V64 Trial/Ledger terms need every shipped locale and valid JSON.
keys = sorted(set(re.findall(r"T\('(trial_[A-Za-z0-9_]+|st_[A-Za-z0-9_]+|ledger_[A-Za-z0-9_]+)'", HTML)))
locales = sorted((ROOT / 'webroot/i18n').glob('*.json'))
if len(locales) != 13:
    errors.append(f'expected 13 locale files, found {len(locales)}')
for locale in locales:
    try:
        data = json.loads(locale.read_text(encoding='utf-8'))
    except Exception as exc:
        errors.append(f'{locale.name}: invalid JSON: {exc}')
        continue
    missing = [key for key in keys if key not in data]
    if missing:
        errors.append(f'{locale.name}: missing V64 keys {missing}')

if errors:
    print('FAIL V64 WebUI Trial/Ledger contract')
    for error in errors:
        print(' -', error)
    sys.exit(1)
print('PASS V64 WebUI Trial/Ledger contract')
print('trial keys:', ', '.join(sorted(ui_keys)))
print('locale files:', len(locales))
ASB_PY_EOF
)

t_workflow_executable_modes_contract() (
# Contract: uploaded source archives may lose executable bits, but CI must restore modes before
# contracts execute runtime helpers. This prevents a GitHub-only failure after a valid host run.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

need() { grep -Fqx "$2" "$1" >/dev/null || { echo "FAIL workflow executable modes: missing [$2] in $1" >&2; exit 1; }; }
for WF in "$ROOT/.github/workflows/build-test.yml" "$ROOT/.github/workflows/build-release.yml"; do
  [ -f "$WF" ] || { echo "FAIL workflow executable modes: missing $WF" >&2; exit 1; }
  _norm=$(grep -n 'name: Normalize executable diagnostic script modes' "$WF" | head -1 | cut -d: -f1)
  _tests=$(grep -n 'name: Run canonical host regression' "$WF" | head -1 | cut -d: -f1)
  case "$_norm:$_tests" in *[!0-9:]*|:) echo "FAIL workflow executable modes: expected steps missing in $WF" >&2; exit 1 ;; esac
  [ "$_norm" -lt "$_tests" ] || { echo "FAIL workflow executable modes: normalize step must precede tests in $WF" >&2; exit 1; }
  grep -Fq 'for tool in zip unzip curl file rsync jq; do' "$WF" || {
    echo "FAIL workflow executable modes: jq must be a verified runner dependency in $WF" >&2; exit 1;
  }
  sed -n "${_norm},$(( _norm + 6 ))p" "$WF" | grep -Fq 'chmod 0755 runtime/asb_active_efficiency_envelope.sh runtime/asb_boot_timeline.sh runtime/asb_debug_support.sh runtime/asb_stock_policy.sh runtime/asb_overlay_guard.sh runtime/asb_wifi_fallback.sh tools/asb_kernel_uv_coexist.sh' || {
    echo "FAIL workflow executable modes: required chmod command missing in $WF" >&2; exit 1;
  }
done

# Simulate browser/ZIP mode loss. The exact chmod used in CI must restore every helper.
for p in runtime/asb_active_efficiency_envelope.sh runtime/asb_boot_timeline.sh runtime/asb_debug_support.sh runtime/asb_stock_policy.sh runtime/asb_overlay_guard.sh runtime/asb_wifi_fallback.sh tools/asb_kernel_uv_coexist.sh; do
  mkdir -p "$TMP/$(dirname "$p")"
  cp "$ROOT/$p" "$TMP/$p"
  chmod 0644 "$TMP/$p"
done
(
  cd "$TMP"
  chmod 0755 runtime/asb_active_efficiency_envelope.sh runtime/asb_boot_timeline.sh runtime/asb_debug_support.sh runtime/asb_stock_policy.sh runtime/asb_overlay_guard.sh runtime/asb_wifi_fallback.sh tools/asb_kernel_uv_coexist.sh
)
[ -x "$TMP/runtime/asb_active_efficiency_envelope.sh" ] || { echo 'FAIL workflow executable modes: generator mode not restored' >&2; exit 1; }
[ -x "$TMP/runtime/asb_boot_timeline.sh" ] || { echo 'FAIL workflow executable modes: boot timeline mode not restored' >&2; exit 1; }
[ -x "$TMP/runtime/asb_debug_support.sh" ] || { echo 'FAIL workflow executable modes: debug support mode not restored' >&2; exit 1; }
[ -x "$TMP/runtime/asb_wifi_fallback.sh" ] || { echo 'FAIL workflow executable modes: Wi-Fi fallback mode not restored' >&2; exit 1; }
[ -x "$TMP/runtime/asb_stock_policy.sh" ] || { echo 'FAIL workflow executable modes: Stock policy mode not restored' >&2; exit 1; }
[ -x "$TMP/runtime/asb_overlay_guard.sh" ] || { echo 'FAIL workflow executable modes: overlay guard mode not restored' >&2; exit 1; }
[ -x "$TMP/tools/asb_kernel_uv_coexist.sh" ] || { echo 'FAIL workflow executable modes: probe mode not restored' >&2; exit 1; }

echo 'PASS workflow executable-mode contract'
)

t_workflow_required_files_shell() (
# Contract: the required-source-files blocks are executable shell, not merely YAML text.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL workflow required-files shell: $*" >&2; exit 1; }
extract_step() {
  _wf="$1" _out="$2"
  awk '
    /- name: Validate required source files/ { capture=1; next }
    capture && /^      - name:/ { exit }
    capture && /^          / {
      line=$0; sub(/^          /, "", line)
      if (line != "run: |") print line
    }
  ' "$_wf" > "$_out"
  [ -s "$_out" ] || fail "could not extract required-files step from $(basename "$_wf")"
}

for name in build-test.yml build-release.yml; do
  wf="$ROOT/.github/workflows/$name"
  out="$TMP/${name%.yml}.sh"
  [ -f "$wf" ] || fail "missing $wf"
  extract_step "$wf" "$out"
  sh -n "$out" || fail "$name extracted shell has syntax error"
  (cd "$ROOT" && sh "$out") || fail "$name required-files step fails"
done

echo "PASS workflow required-files shell contract"
)

t_session_lifecycle_runtime() (
# Runtime (fix167): the boot session exists, a screen-off does not end it, shutdown banks once.
#
# The fix163 capture booted at 01:49 and Smart banked nothing until the capture ended at 08:49:
# smart_sessions_total 726 and smart_quality_last -1 in every snapshot. fsm_init clears the
# FSM and nothing gave the boot session a start time, so every gate on the session age - the
# 20-minute Smart bank, the deep-idle boundary, intent, the history line, the bank on shutdown -
# read 0 until a profile change. The REAL fsm_init and fsm_session_reset, compiled from
# asb_fsm.h, show the dead clock and the sentinels the reset gives (efficiency -1, headroom
# minimum 100 - a 0 there read as a vendor clamp); then the governor is checked to reset at
# startup, to keep the per-profile learning out of the two screen-off paths, and to bank one
# shutdown session, not two.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL session lifecycle: $*" >&2; exit 1; }
awk '/^    fsm_init\(&fsm, profile_idx\);$/{i=NR} /^    fsm_session_reset\(&fsm\);$/{if(i && !r) r=NR}
     /^    while \(g_running\) \{$/{if(!w) w=NR} END{exit !(i && r > i && r < i + 20 && w > r)}' "$G" \
  || fail "the governor starts without a session (fsm_session_reset must follow fsm_init in main)"
for p in '} else if (!metrics.misc.screen_on && _ts == 1) {' '                            disarm_timerfd(tfd_active);'; do
  _blk="$(awk -v p="$p" 'index($0, p) == 1 || index($0, p) {f=1} f{print; n++} n > 30 {exit}' "$G")"
  printf '%s\n' "$_blk" | grep -q 'persistent_stats_screen_off(&fsm);' || fail "a screen-off path does not keep the next-session context"
  printf '%s\n' "$_blk" | grep -q 'persistent_stats_save(&fsm);' && fail "a screen-off path still folds the session into the per-profile learning"
done
awk '/^static void persistent_stats_save_ex\(const asb_fsm_t \*fsm, int learn\) \{$/{f=1}
     f && /g_last_session_env = classify_environment\(fsm\);/{e=NR}
     f && /if \(!learn\) return;/{l=NR}
     f && /asb_persistent_stats_t \*ps = &g_pstats_per\[pidx\];/{p=NR; exit}
     END{exit !(e && l == e + 1 && p > l)}' "$G" || fail "the context-only save does not stop before the learning"
[ "$(grep -c 'session_history_append_ex(&fsm, "shutdown");' "$G")" = 1 ] || fail "shutdown appends (and banks) the session more than once"
grep -q 'int _ses_long = fsm.ses_start_ts > 0 && (long)(time(NULL) - fsm.ses_start_ts) >= 1200;' "$G" || fail "a Smart session under 20 minutes is banked on shutdown"
CC=""; for c in ${HOST_CC:-} gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS session lifecycle (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'X'
#include <stdio.h>
int g_qn_skip_this_tick = 0;
#include "asb_fsm.h"
asb_runtime_config_t g_asb_cfg;
int main(void) {
    int bad = 0;
    asb_fsm_t f;
    fsm_init(&f, 3);
    if (f.ses_start_ts != 0) { printf("fsm_init now starts the session itself - update this test\n"); bad = 1; }
    if (f.ses_headroom_min != 0 || f.ses_sustained_efficiency != 0) { printf("fsm_init sentinels changed\n"); bad = 1; }
    time_t t0 = time(NULL);
    fsm_session_reset(&f);
    if (f.ses_start_ts < t0 || f.ses_start_ts > t0 + 2) { printf("reset: no session start\n"); bad = 1; }
    if (f.ses_sustained_efficiency != -1) { printf("reset: efficiency sentinel %d\n", f.ses_sustained_efficiency); bad = 1; }
    if (f.ses_headroom_min != 100) { printf("reset: headroom minimum %d (0 reads as a vendor clamp)\n", f.ses_headroom_min); bad = 1; }
    if (f.profile_idx != 3 || f.state != ASB_STATE_LIGHT_IDLE) { printf("reset touched profile or state\n"); bad = 1; }
    f.ses_start_ts = t0 - 1200;
    long age = (f.ses_start_ts > 0) ? (long)(time(NULL) - f.ses_start_ts) : 0;
    if (age < 1200) { printf("a 20-minute session does not read as 20 minutes\n"); bad = 1; }
    if (!bad) printf("ok\n");
    return bad;
}
X
"$CC" -O1 -I"$ROOT/src" -o "$T/t" "$T/t.c" -lm 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "harness did not compile"; }
out="$("$T/t")" || { printf '%s\n' "$out" >&2; fail "session reset wrong"; }
echo "PASS session lifecycle: the boot session has a start and its sentinels, screen-offs keep context without re-learning, shutdown banks once"
)

t_device_bounds_long_fingerprint_runtime() (
# Runtime (fix240): the governor reads a fingerprint longer than 91 characters whole.
#
# Owner's OP15 asbdiag: "bounds status: stale/fingerprint" and the governor log
# "device_bounds: stale/fingerprint ... compiled reference rails in force" on every start,
# minutes after the synthesis wrote the current fingerprint. The OP15 fingerprint is 92
# characters; __system_property_get() answers a read-only property that long with bionic's
# fixed "Must use __system_property_read_callback() to read", so the comparison could never
# match, while the shell's getprop accepted the same file. The REAL loader is compiled as for
# Android against a fake property area with bionic's semantics: the callback reader is found
# at run time and the file applies; with no callback reader the short reader still sees only
# the legacy text, which is the old behaviour.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL device bounds long fingerprint: $*" >&2; exit 1; }
CC=""; for c in ${HOST_CC:-} gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "SKIP device bounds long fingerprint: no host C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/inc/sys"
cat > "$T/inc/sys/system_properties.h" <<'X'
#pragma once
#define PROP_VALUE_MAX 92
typedef struct prop_info prop_info;
const prop_info *__system_property_find(const char *name);
int __system_property_get(const char *name, char *value);
X
sed "s#\"/data/adb/asb/device_bounds.env\"#\"$T/device_bounds.env\"#" "$ROOT/src/asb_fsm.h" > "$T/asb_fsm_test.h"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <sys/system_properties.h>
#define FP "OnePlus/CPH2745IN/OP611FL1:16/BP2A.250605.015/B.R4T3.1abf132_aeee51_aea830:user/release-keys"
struct prop_info { int dummy; };
static struct prop_info g_fp_info;
const prop_info *__system_property_find(const char *name) {
    return strcmp(name, "ro.build.fingerprint") == 0 ? &g_fp_info : NULL;
}
int __system_property_get(const char *name, char *value) {
    if (strcmp(name, "ro.build.fingerprint") != 0) { value[0] = '\0'; return 0; }
    if (strlen(FP) >= PROP_VALUE_MAX) { strcpy(value, "Must use __system_property_read_callback() to read"); return (int)strlen(value); }
    strcpy(value, FP); return (int)strlen(value);
}
#ifdef WITH_CALLBACK
void __system_property_read_callback(const prop_info *pi,
        void (*cb)(void *, const char *, const char *, uint32_t), void *cookie) {
    if (pi == &g_fp_info) cb(cookie, "ro.build.fingerprint", FP, 1);
}
#endif
#include "asb_fsm_test.h"
asb_runtime_config_t g_asb_cfg;
static asb_profile_bounds_t defs[3];
int main(void) {
    memcpy(defs, g_profile_bounds, sizeof(defs));
    g_cpu_policy_count = 2; g_cpu_all_count = 2;
    g_cpu_policy_ids[0] = 0; g_cpu_policy_ids[1] = 6; g_cpu_policy_ids[2] = -1;
    g_cpu_slot_hwmax[0] = 3628800; g_cpu_slot_hwmax[1] = 4608000; g_cpu_slot_hwmax[2] = 0;
    FILE *f = fopen(ASB_DEVICE_BOUNDS_FILE, "w");
    if (!f) return 90;
    fputs("schema=2\nconfidence=high\nsource=measured\npolicy_count=2\n"
          "cluster_signature=0:3628800>none:0>6:4608000\nfingerprint=" FP "\n"
          "BALANCED_CPU_MAX_LITTLE=2611200\n", f);
    fclose(f);
    int n = asb_load_device_bounds_override(1, defs);
    printf("%s/%s %d\n", g_device_bounds_status, g_device_bounds_reason, n);
    return 0;
}
X
[ "$(printf %s 'OnePlus/CPH2745IN/OP611FL1:16/BP2A.250605.015/B.R4T3.1abf132_aeee51_aea830:user/release-keys' | wc -c)" -gt 91 ] || fail "fixture fingerprint is not long"
"$CC" -O1 -D__ANDROID__ -DWITH_CALLBACK -I"$T/inc" -I"$ROOT/src" -rdynamic -o "$T/cb" "$T/t.c" -lm -ldl 2>"$T/cc1.log" || { cat "$T/cc1.log" >&2; fail "callback build"; }
"$CC" -O1 -D__ANDROID__ -I"$T/inc" -I"$ROOT/src" -o "$T/nocb" "$T/t.c" -lm -ldl 2>"$T/cc2.log" || { cat "$T/cc2.log" >&2; fail "fallback build"; }
out="$("$T/cb")"
[ "$out" = "applied/ok 1" ] || fail "a 92-character fingerprint is still not read whole: $out"
out="$("$T/nocb")"
[ "$out" = "stale/fingerprint 0" ] || fail "without the callback reader the short reader must behave as bionic does: $out"
grep -q 'dlsym(RTLD_DEFAULT, "__system_property_read_callback")' "$ROOT/src/asb_fsm.h" || fail "the long-property reader is not looked up"
echo "PASS device bounds long fingerprint: a 92-character fingerprint is read whole and the measured bounds apply in the governor, as they already did in the shell"
)

t_device_bounds_confidence_runtime() (
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL device bounds validation: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Exercise the real native loader with persistent state and Android property access redirected.
CC=""; for c in ${HOST_CC:-} gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || fail "no host C compiler"
sed "s#\"/data/adb/asb/device_bounds.env\"#\"$T/device_bounds.env\"#" \
  "$ROOT/src/asb_fsm.h" > "$T/asb_fsm_test.h"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
static int test_bounds_getprop(const char *key, char *value) {
    if (strcmp(key, "ro.build.fingerprint") != 0) { value[0] = '\0'; return 0; }
    strcpy(value, "OnePlus/test/user");
    return (int)strlen(value);
}
#define ASB_DEVICE_BOUNDS_PROPERTY_GET test_bounds_getprop
#include "asb_fsm_test.h"
asb_runtime_config_t g_asb_cfg;
static asb_profile_bounds_t defs[3];
static int run_case(const char *text, int enabled, int expect_n, int expect_value,
                    const char *expect_status, const char *expect_reason) {
    FILE *f = fopen(ASB_DEVICE_BOUNDS_FILE, "w");
    if (!f) return 90;
    fputs(text, f); fclose(f);
    memcpy(g_profile_bounds, defs, sizeof(defs));
    int before = g_profile_bounds[PROFILE_BALANCED].ceil.cpu_max[0];
    int n = asb_load_device_bounds_override(enabled, defs);
    int got = g_profile_bounds[PROFILE_BALANCED].ceil.cpu_max[0];
    if (n != expect_n) { printf("applied=%d want=%d\n", n, expect_n); return 1; }
    if (got != expect_value) { printf("value=%d want=%d (before=%d)\n", got, expect_value, before); return 2; }
    if (strcmp(g_device_bounds_status, expect_status) || strcmp(g_device_bounds_reason, expect_reason)) {
        printf("result=%s/%s want=%s/%s\n", g_device_bounds_status, g_device_bounds_reason,
               expect_status, expect_reason); return 3;
    }
    return 0;
}
#define VALID_META "schema=2\nconfidence=high\nsource=measured\npolicy_count=2\n" \
    "cluster_signature=0:3000000>none:0>6:4000000\nfingerprint=OnePlus/test/user\n"
int main(void) {
    memcpy(defs, g_profile_bounds, sizeof(defs));
    g_cpu_policy_count = 2;
    g_cpu_all_count = 2;
    g_cpu_policy_ids[0] = 0; g_cpu_policy_ids[1] = 6; g_cpu_policy_ids[2] = -1;
    g_cpu_slot_hwmax[0] = 3000000; g_cpu_slot_hwmax[1] = 4000000; g_cpu_slot_hwmax[2] = 0;
    int stock = defs[PROFILE_BALANCED].ceil.cpu_max[0];
    int rc = 0;
    rc |= run_case(VALID_META "BALANCED_CPU_MAX_LITTLE=2340000\n", 1, 1, 2340000, "applied", "ok");
    rc |= run_case("schema=2\nconfidence=low\nsource=measured\nBALANCED_CPU_MAX_LITTLE=2340000\n", 1, 0, stock, "skipped", "confidence");
    rc |= run_case("schema=2\nBALANCED_CPU_MAX_LITTLE=2340000\n", 1, 0, stock, "skipped", "confidence");
    rc |= run_case("# confidence=high  topology=2c\nBALANCED_CPU_MAX_LITTLE=2340000\n", 1, 0, stock, "skipped", "schema");
    rc |= run_case(VALID_META "BALANCED_CPU_MAX_LITTLE=2340000\n", 0, 0, stock, "disabled", "off");
    rc |= run_case("schema=2\nconfidence=high\nsource=measured\nBALANCED_CPU_MAX_LITTLE=2340000\npolicy_count=2\ncluster_signature=0:3000000>none:0>6:4000000\nfingerprint=OnePlus/old/user\n", 1, 0, stock, "stale", "fingerprint");
    rc |= run_case("schema=2\nconfidence=high\nsource=measured\npolicy_count=3\ncluster_signature=0:3000000>none:0>6:4000000\nfingerprint=OnePlus/test/user\nBALANCED_CPU_MAX_LITTLE=2340000\n", 1, 0, stock, "stale", "policy_count");
    rc |= run_case("schema=2\nconfidence=high\nsource=measured\npolicy_count=2\ncluster_signature=0:2995200>none:0>6:4000000\nfingerprint=OnePlus/test/user\nBALANCED_CPU_MAX_LITTLE=2340000\n", 1, 0, stock, "stale", "cluster_signature");
    rc |= run_case("schema=2\nconfidence=high\npolicy_count=2\ncluster_signature=0:3000000>none:0>6:4000000\nfingerprint=OnePlus/test/user\nBALANCED_CPU_MAX_LITTLE=2340000\n", 1, 0, stock, "skipped", "source");
    return rc;
}
X
"$CC" -O1 -I"$T" -I"$ROOT/src" -o "$T/t" "$T/t.c" -lm 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "native harness did not compile"; }
"$T/t" || fail "native provenance/fingerprint/policy/signature behavior diverged"

# Exercise the actual shell validator/importer against a live-looking sysfs fixture.
mkdir -p "$T/bin" "$T/sys/cpufreq/policy0" "$T/sys/cpufreq/policy6"
printf '3000000\n' > "$T/sys/cpufreq/policy0/cpuinfo_max_freq"
printf '4000000\n' > "$T/sys/cpufreq/policy6/cpuinfo_max_freq"
cat > "$T/bin/getprop" <<'X'
#!/bin/sh
[ "${1:-}" = ro.build.fingerprint ] && printf '%s\n' 'OnePlus/test/user'
X
chmod +x "$T/bin/getprop"
shell_value() {
  printf '%s' "$2" > "$T/shell_bounds.env"
  ( PATH="$T/bin:$PATH" ASB_CPU_SYSFS="$T/sys"
    . "$ROOT/runtime/asb_device_bounds.sh"
    asb_device_bounds_import "$T/shell_bounds.env" >/dev/null 2>&1 || true
    printf '%s' "${BALANCED_CPU_MAX_LITTLE:-stock}" )
}
shell_meta='schema=2
confidence=high
source=measured
policy_count=2
cluster_signature=0:3000000>none:0>6:4000000
fingerprint=OnePlus/test/user
'
[ "$(shell_value high "$shell_meta"'BALANCED_CPU_MAX_LITTLE=2340000
')" = 2340000 ] || fail "shell rejected current valid bounds"
[ "$(shell_value low 'schema=2
confidence=low
BALANCED_CPU_MAX_LITTLE=2340000
')" = stock ] || fail "shell accepted low confidence"
[ "$(shell_value unknown 'schema=2
BALANCED_CPU_MAX_LITTLE=2340000
')" = stock ] || fail "shell accepted unknown confidence"
[ "$(shell_value legacy '# confidence=high  topology=2c
BALANCED_CPU_MAX_LITTLE=2340000
')" = stock ] || fail "shell accepted legacy file without provenance"
[ "$(shell_value stale_fp 'schema=2
confidence=high
source=measured
policy_count=2
cluster_signature=0:3000000>none:0>6:4000000
fingerprint=OnePlus/old/user
BALANCED_CPU_MAX_LITTLE=2340000
')" = stock ] || fail "shell accepted stale fingerprint"
[ "$(shell_value stale_count 'schema=2
confidence=high
source=measured
policy_count=3
cluster_signature=0:3000000>none:0>6:4000000
fingerprint=OnePlus/test/user
BALANCED_CPU_MAX_LITTLE=2340000
')" = stock ] || fail "shell accepted changed policy count"
[ "$(shell_value stale_hw 'schema=2
confidence=high
source=measured
policy_count=2
cluster_signature=0:2995200>none:0>6:4000000
fingerprint=OnePlus/test/user
BALANCED_CPU_MAX_LITTLE=2340000
')" = stock ] || fail "shell accepted changed hw_max"
! grep -qE '(^|[[:space:];])eval([[:space:]]|$)' "$ROOT/runtime/asb_device_bounds.sh" || fail "shell importer still uses eval"

# Synthesis emits useful provenance, but frequencies only for resolved 2/3/4-policy topologies.
sed -e "s#^CAPS=.*#CAPS=\"$T/device_caps.env\"#" \
    -e "s#^OUT=.*#OUT=\"$T/synthesized.env\"#" \
    -e "s#^ASB_DIR=.*#ASB_DIR=\"$T\"#" \
    "$ROOT/tools/asb_synthesize_bounds.sh" > "$T/synthesize.sh"
cat > "$T/device_caps.env" <<'X'
cpu_policy_count=2
cpu_policy_list=6 0
cpu_policy0_hwmax=3000000
cpu_policy6_hwmax=4000000
fingerprint=OnePlus/test/user
X
sh "$T/synthesize.sh" >/dev/null
grep -q '^schema=2$' "$T/synthesized.env" || fail "schema metadata missing"
grep -q '^confidence=high$' "$T/synthesized.env" || fail "resolved topology is not high confidence"
grep -q '^source=measured$' "$T/synthesized.env" || fail "measured source missing"
grep -q '^fingerprint=OnePlus/test/user$' "$T/synthesized.env" || fail "fingerprint missing"
grep -q '^cluster_signature=0:3000000>none:0>6:4000000$' "$T/synthesized.env" || fail "signature did not use hardware ordering"
grep -q '^BALANCED_CPU_MAX_LITTLE=[0-9]' "$T/synthesized.env" || fail "high synthesis emitted no bounds"
cat > "$T/device_caps.env" <<'X'
cpu_policy_count=4
cpu_policy_list=0 2 5 7
cpu_policy0_hwmax=2000000
cpu_policy2_hwmax=2800000
cpu_policy5_hwmax=3000000
cpu_policy7_hwmax=3300000
fingerprint=OnePlus/test/user
X
sh "$T/synthesize.sh" >/dev/null
grep -q '^confidence=high$' "$T/synthesized.env" || fail "4-policy topology was rejected"
grep -q '^cluster_signature=0:2000000>5:3000000>7:3300000$' "$T/synthesized.env" || fail "4-policy strongest-middle signature wrong"
grep -q '^BALANCED_CPU_MAX_MID=[0-9]' "$T/synthesized.env" || fail "4-policy mid bounds missing"
grep -q '^BATTERY_CPU_MAX_PRIME=[0-9]' "$T/synthesized.env" || fail "4-policy prime bound missing"
cat > "$T/device_caps.env" <<'X'
cpu_policy_count=1
cpu_policy_list=0
cpu_policy0_hwmax=3000000
fingerprint=OnePlus/test/user
X
sh "$T/synthesize.sh" >/dev/null
grep -q '^confidence=low$' "$T/synthesized.env" || fail "1-policy topology is not low confidence"
! grep -q '^BALANCED_CPU_MAX_LITTLE=' "$T/synthesized.env" || fail "1-policy synthesis emitted an override"
cat > "$T/device_caps.env" <<'X'
cpu_policy_count=5
cpu_policy_list=0 2 4 5 7
cpu_policy0_hwmax=1800000
cpu_policy2_hwmax=2400000
cpu_policy4_hwmax=2800000
cpu_policy5_hwmax=3000000
cpu_policy7_hwmax=3300000
fingerprint=OnePlus/test/user
X
sh "$T/synthesize.sh" >/dev/null
grep -q '^confidence=low$' "$T/synthesized.env" || fail "5-policy topology is not low confidence"
grep -q '^policy_count=5$' "$T/synthesized.env" || fail "5-policy provenance missing"
grep -q '^# confidence=low  topology=unsupported' "$T/synthesized.env" || fail "5-policy topology is not marked unsupported"
! grep -qE '^(BATTERY|BALANCED|PERFORMANCE)_CPU_(MAX|CAP|MIN)_' "$T/synthesized.env" || fail "5-policy synthesis emitted an override"
grep -q 'bounds status.*applied/stale/skipped' "$ROOT/tools/asb_diag.sh" || fail "diag lacks explicit bounds status"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "diag copies diverged"
echo "PASS device bounds validation: current identity/topology required; stale and 5-policy files fail closed; no eval"
)

t_net_route_watch_dormant_runtime() (
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
R="$ROOT/runtime/asb_net_routes.sh"
fail() { echo "FAIL net route watcher dormant: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/mod/config"
printf 'net_route_tune=auto\nnet_congestion_wifi=auto\nnet_congestion_mobile=auto\n' > "$T/mod/config/governor.conf"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
case "$*" in
  *"monitor route"*) echo 'netlink unavailable' >&2; exit 1 ;;
  *"route show table all"*) [ ! -f "$ASB_TEST_ROUTE_FILE" ] || cat "$ASB_TEST_ROUTE_FILE" ;;
esac
exit 0
X
cat > "$T/bin/sleep" <<'X'
#!/bin/sh
if [ "$1" = 60 ]; then
  echo poll >> "$ASB_TEST_POLLS"
  [ "${ASB_TEST_LOSE_ROUTE:-0}" != 1 ] || rm -f "$ASB_TEST_ROUTE_FILE"
fi
exit 0
X
chmod +x "$T/bin/ip" "$T/bin/sleep"
mkdir -p "$T/no-route"
ASB_TEST_POLLS="$T/no-route/polls"; export ASB_TEST_POLLS
ASB_TEST_ROUTE_FILE="$T/no-route/default"; export ASB_TEST_ROUTE_FILE
ASB_IP="$T/bin/ip" ASB_NET_STATE_DIR="$T/no-route" PATH="$T/bin:$PATH" MODDIR="$T/mod" sh "$R" watch >/dev/null 2>&1
[ ! -e "$T/no-route/polls" ] || fail "no-active-route branch entered fallback polling"
[ "$(cat "$T/no-route/net_routes_watch.mode")" = dormant ] || fail "no-route mode is not dormant"
grep -q 'no active default route' "$T/no-route/net_routes_watch.exit" || fail "no-route reason missing"
mkdir -p "$T/lost"
echo 'default via 10.0.0.1 dev wlan0 table wlan0 proto static' > "$T/lost/default"
ASB_TEST_POLLS="$T/lost/polls"; export ASB_TEST_POLLS
ASB_TEST_ROUTE_FILE="$T/lost/default"; export ASB_TEST_ROUTE_FILE
ASB_TEST_LOSE_ROUTE=1; export ASB_TEST_LOSE_ROUTE
ASB_IP="$T/bin/ip" ASB_NET_STATE_DIR="$T/lost" PATH="$T/bin:$PATH" MODDIR="$T/mod" sh "$R" watch >/dev/null 2>&1
[ "$(wc -l < "$T/lost/polls")" = 1 ] || fail "route loss did not stop on the first poll"
[ "$(cat "$T/lost/net_routes_watch.mode")" = dormant ] || fail "route-lost mode is not dormant"
grep -q 'active route lost' "$T/lost/net_routes_watch.exit" || fail "route-lost reason missing"
echo "PASS net route watcher dormant: no route skips fallback; route loss stops it immediately"
)

t_net_route_watch_ttl_runtime() (
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
R="$ROOT/runtime/asb_net_routes.sh"
fail() { echo "FAIL net route watcher TTL: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/mod/config" "$T/state"
printf 'net_route_tune=auto\nnet_congestion_wifi=auto\nnet_congestion_mobile=auto\n' > "$T/mod/config/governor.conf"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
case "$*" in
  *"monitor route"*) echo 'netlink unavailable' >&2; exit 1 ;;
  *"route show table all"*) echo 'default via 10.0.0.1 dev wlan0 table wlan0 proto static' ;;
esac
exit 0
X
cat > "$T/bin/sleep" <<'X'
#!/bin/sh
[ "$1" = 60 ] && echo poll >> "$ASB_TEST_POLLS"
exit 0
X
chmod +x "$T/bin/ip" "$T/bin/sleep"
ASB_TEST_POLLS="$T/polls"; export ASB_TEST_POLLS
ASB_IP="$T/bin/ip" ASB_NET_STATE_DIR="$T/state" PATH="$T/bin:$PATH" MODDIR="$T/mod" sh "$R" watch >/dev/null 2>&1
[ "$(wc -l < "$T/polls")" = 15 ] || fail "fallback did not stop after 15 polls: $(wc -l < "$T/polls")"
[ "$(cat "$T/state/net_routes_watch.mode")" = dormant ] || fail "dormant mode not recorded"
grep -q 'fallback TTL exhausted after 15 polls' "$T/state/net_routes_watch.exit" || fail "dormant reason missing"
grep -q 'route link watcher: dormant' "$ROOT/tools/asb_diag.sh" || fail "diag does not explain dormant state"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "diag copies diverged"
echo "PASS net route watcher TTL: broken netlink gets 15 polls, then a diagnosable dormant state"
)


t_battery_jank_guard_runtime() (
# Battery insurance must react to measured frame windows, never learn like Smart.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL Battery jank guard: $*" >&2; exit 1; }
for pin in \
  'g_asb_cfg.battery_jank_guard && fsm->profile_idx == PROFILE_BATTERY' \
  'm->misc.screen_on && !m->misc.camera_active && !fsm->thermal_cap' \
  'asb_bjank_capture_live(now)' \
  'df >= ASB_BJANK_MIN_FRAMES && dj >= ASB_BJANK_MIN_JANKY' \
  'dj * 100L >= df * ASB_BJANK_MIN_PCT' \
  'df >= ASB_BJANK_SHORT_FRAMES' \
  'dj * 100L >= df * ASB_BJANK_SHORT_PCT' \
  'g_unlock_until_ms = now_ms + ASB_BJANK_TTL_MS' \
  'g_unlock_lift_now = 1' \
  'g_unlock_edge = 1'; do
  grep -Fq "$pin" "$G" || fail "missing safety/runtime pin: $pin"
done
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS Battery jank guard (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^\/\* Battery jank insurance (fix236)/,/^static int g_rec_on_applied/p' "$G" | sed '$d' \
  | sed "s#\"/data/adb/asb/logkit/full_day_webui.lock\"#\"$T/lock\"#" > "$T/b.c"
grep -q 'asb_battery_jank_guard_tick' "$T/b.c" || fail 'runtime block extraction failed'
mkdir -p "$T/lock"
cp /proc/sys/kernel/random/boot_id "$T/lock/boot_id"
printf '%s\n' "$$" > "$T/lock/pid"
: > "$T/gfx"
cat > "$T/t.c" <<X
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <stdarg.h>
#define ASB_GFX_FILE "$T/gfx"
#define ASB_APP_GAMING 3
enum { PROFILE_BATTERY, PROFILE_BALANCED, PROFILE_PERFORMANCE, PROFILE_SMART };
typedef struct { int profile_idx, thermal_cap; } asb_fsm_t;
typedef struct { struct { int screen_on, camera_active; } misc; } asb_metrics_t;
static struct { int battery_jank_guard, unlock_lift_pct; } g_asb_cfg = { 1, 80 };
static struct { uint64_t app_hash; int app_hint; char app_pkg_cached[64]; } g_smart_rt = { 7, 0, "com.example.launcher" };
static int g_pkg_detect_ok = 1;
static long g_unlock_until_ms = 0, test_now_ms = 10000;
static int g_unlock_lift_now = 0, g_unlock_edge = 0, probe_calls = 0;
static const char *g_unlock_arm_why = "";
static long gfx_frames = 1000, gfx_janky = 10;
static long sys_frames = 500, sys_janky = 5;
static long asb_clock_ms(clockid_t which) { (void)which; return test_now_ms; }
static int asb_gfx_read_pkg(const char *pkg, long *fr, long *jk) {
    if (!strcmp(pkg, "com.example.launcher")) { *fr = gfx_frames; *jk = gfx_janky; return 0; }
    if (!strcmp(pkg, "com.android.systemui")) { *fr = sys_frames; *jk = sys_janky; return 0; }
    return -1;
}
static void asb_run_modscript(const char *script, const char *pkg) {
    (void)script; (void)pkg; probe_calls++;
}
static void asb_log(const char *fmt, ...) { (void)fmt; }
static int asb_unlock_lift_share(int profile_idx) { return profile_idx == PROFILE_BATTERY ? g_asb_cfg.unlock_lift_pct * 4 / 5 : g_asb_cfg.unlock_lift_pct; }
#include "b.c"
static int bad = 0;
#define CHK(c, what) do { if (!(c)) { printf("%s\\n", what); bad = 1; } } while (0)
static void advance_file(void) {
    static int seq = 0;
    struct timespec ts[2];
    ts[0].tv_sec = time(NULL) + 2 + ++seq; ts[0].tv_nsec = 0; ts[1] = ts[0];
    utimensat(AT_FDCWD, ASB_GFX_FILE, ts, 0);
}
int main(void) {
    asb_fsm_t f = { PROFILE_BATTERY, 0 };
    asb_metrics_t m = { { 1, 0 } };
    asb_battery_jank_guard_tick(&f, &m);
    CHK(probe_calls == 1 && !g_unlock_lift_now, "initial probe triggered a lift");
    advance_file(); asb_battery_jank_guard_tick(&f, &m);
    CHK(g_bjank_frames == 1000 && g_bjank_janky == 10, "baseline not captured");
    CHK(probe_calls == 1 && !g_unlock_lift_now, "baseline triggered a lift");
    advance_file(); gfx_frames = 1400; gfx_janky = 50; test_now_ms += 1000;
    asb_battery_jank_guard_tick(&f, &m);
    CHK(g_bjank_windows == 2 && g_bjank_triggers == 1, "foreground/SystemUI windows not measured independently");
    CHK(g_unlock_lift_now && g_bjank_armed && g_unlock_until_ms == test_now_ms + 10000,
        "bounded lift not armed");
    CHK(!strcmp(g_unlock_arm_why, "battery jank guard"), "ownership reason missing");
    f.profile_idx = PROFILE_BALANCED; asb_battery_jank_guard_tick(&f, &m);
    CHK(!g_unlock_lift_now && g_unlock_until_ms == 0, "non-Battery profile kept the lift");
    f.profile_idx = PROFILE_BATTERY; g_smart_rt.app_hash = 8;
    advance_file(); asb_battery_jank_guard_tick(&f, &m);
    advance_file(); gfx_frames = 1800; gfx_janky = 90;
    asb_battery_jank_guard_tick(&f, &m);
    CHK(g_bjank_armed && g_unlock_lift_now, "second measured window not armed");
    test_now_ms += 11000; asb_battery_jank_guard_tick(&f, &m);
    CHK(!g_bjank_armed, "TTL did not expire");
    g_unlock_lift_now = 0; g_unlock_until_ms = 0; /* ordinary unlock owner sees the same expiry */
    m.misc.camera_active = 1;
    asb_battery_jank_guard_tick(&f, &m);
    CHK(g_bjank_frames == -1 && probe_calls == 1, "camera gate failed or polled");
    m.misc.camera_active = 0; f.thermal_cap = 1;
    asb_battery_jank_guard_tick(&f, &m);
    CHK(probe_calls == 1, "thermal gate failed");
    f.thermal_cap = 0; g_smart_rt.app_hint = ASB_APP_GAMING;
    asb_battery_jank_guard_tick(&f, &m);
    CHK(probe_calls == 1, "game entered Battery insurance");
    g_smart_rt.app_hint = 0; g_bjank_log_ts = 0;
    unlink("$T/lock/pid"); asb_battery_jank_guard_tick(&f, &m);
    CHK(probe_calls == 1 && g_bjank_frames == -1, "missing live recorder was ignored");
    /* A smooth foreground must not hide a janky launcher/shade/recents SystemUI window. */
    FILE *pf = fopen("$T/lock/pid", "w"); fprintf(pf, "%d\n", getpid()); fclose(pf);
    g_bjank_log_ts = 0; g_smart_rt.app_hash = 9;
    gfx_frames = 2000; gfx_janky = 20; sys_frames = 500; sys_janky = 5;
    advance_file(); asb_battery_jank_guard_tick(&f, &m);
    advance_file(); gfx_frames = 2400; gfx_janky = 30; sys_frames = 900; sys_janky = 45;
    unsigned long before = g_bjank_triggers;
    asb_battery_jank_guard_tick(&f, &m);
    CHK(g_bjank_triggers == before + 1 && g_bjank_armed,
        "SystemUI jank was hidden by a smooth foreground package");
    /* A short but visibly rough 150-frame window must not wait for 300 frames. */
    f.profile_idx = PROFILE_BALANCED; asb_battery_jank_guard_tick(&f, &m);
    f.profile_idx = PROFILE_BATTERY; g_smart_rt.app_hash = 10;
    gfx_frames = 3000; gfx_janky = 30; sys_frames = 1000; sys_janky = 10;
    advance_file(); asb_battery_jank_guard_tick(&f, &m);
    advance_file(); gfx_frames = 3150; gfx_janky = 50;
    before = g_bjank_triggers;
    asb_battery_jank_guard_tick(&f, &m);
    CHK(g_bjank_triggers == before + 1 && g_bjank_armed,
        "short 150-frame high-jank window did not arm the bounded guard");
    return bad;
}
X
"$CC" -std=c11 -Wall -Wextra -Werror -D_GNU_SOURCE -I"$T" "$T/t.c" -o "$T/t" || fail 'runtime fixture did not compile'
"$T/t" || fail 'runtime behavior mismatch'
echo "PASS Battery jank guard: live capture gate, long/short windows, SystemUI and bounded handback"
)

_asb_tests() { declare -F | awk '$3 ~ /^t_/ { print substr($3, 3) }'; }
case "${1:-}" in
  --list) _asb_tests ;;
  --source) "_c_${2:?fixture name}" ;;
  *)
    _asb_failed=0
    for _asb_t in ${*:-$(_asb_tests)}; do
      "t_$_asb_t"
      [ $? -eq 0 ] || { printf 'FAILED: %s\n' "$_asb_t" >&2; _asb_failed=$((_asb_failed + 1)); }
    done
    [ "$_asb_failed" -eq 0 ]
    ;;
esac
