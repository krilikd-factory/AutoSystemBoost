#!/bin/sh
# Contract: camera controls must reach the real grader, be visibly stronger at level 10,
# and never claim an independent slider applied when CAMERA_LEVEL remains stock.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GRADE="$ROOT/runtime/asb_camera_grade.sh"
TWEAKS="$ROOT/runtime/asb_tweaks.sh"
WRITER="$ROOT/runtime/asb_config_safe.sh"
UI="$ROOT/webroot/index.html"
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
need "$GRADE" '[ "$_lvl" -gt 10 ] 2>/dev/null && _lvl=10'
need "$GRADE" '[ "$_grain" -gt 10 ] 2>/dev/null && _grain=10'
need "$GRADE" '[ "$_contrast" -gt 10 ] 2>/dev/null && _contrast=10'
need "$GRADE" '[ "$_lowlight" -gt 10 ] 2>/dev/null && _lowlight=10'
need "$TWEAKS" '[ "$_lv" -gt 10 ] 2>/dev/null && _lv=10'
need "$TWEAKS" 'asb_tw_camera_grade_needed()'
need "$TWEAKS" '_cam_grade_needed=0'

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
need "$OUT" '"addNoiseWeightMain1X": 3.33'
need "$OUT" '"low20XcontrastScale": 1.7'

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
