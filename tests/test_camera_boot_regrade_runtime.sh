#!/bin/sh
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
