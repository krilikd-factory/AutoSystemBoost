#!/system/bin/sh
# asb_camera_grade.sh - camera grading by RATIO, not by matching known values.
#
# Why this exists, and why the previous approach could not work.
#
# The old grading was a stack of sed rules matching literal numbers: find 0.35, write
# 0.55. That only fires on a device whose tuning file happens to contain 0.35. A OnePlus
# 15 ships values already at or above what "level 4" was reaching for, so every rule
# missed and the setting did nothing at all - users moved the slider to 4, enabled
# Extended, and correctly reported no difference. There was none.
#
# Scaling instead of substituting removes the dependency entirely: whatever the device
# ships, level N multiplies it. A phone tuned conservatively gets a bigger absolute push
# than one tuned aggressively, which is also the behaviour you want.
#
# Three parameters, chosen because they are the three a person actually sees:
#
#   saturation  Rgb2YuvParamsSet.*_Rgb2YuvParams - the RGB->YUV matrix. Elements 4..9 are
#               the two chroma rows; scaling them scales colour saturation directly and
#               leaves luma (elements 1..3) alone, so brightness does not shift.
#   ai detail   EnhanceNetParamsSet.*.BlendWeight - how much of the neural detail pass is
#               blended in. Clamped at 1.0: it is a blend weight, and above 1 the result
#               is undefined rather than more detailed.
#   sharpness   GanSRUsmSharpParamsSet.*.BnScale / QbcScale - unsharp mask strength.
#
# Everything else in the file is left alone on purpose. Noise, tone mapping and black
# level interact with each other and with the sensor, and a ratio applied blind to those
# produces artefacts rather than a nicer picture.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"

# Level from the environment first, config second.
#
# At install time $MODDIR/config/governor.conf is still the pristine shipped file - the
# carry-over that copies the user's answers into it runs about 1300 lines after the camera
# overlay is built. Reading the config here therefore always saw CAMERA_LEVEL=0 and graded
# nothing, no matter what the slider said. The exact same mistake cost dsp_effect_abi a
# release; the installer already has the resolved value in hand, so it passes it in.
_lvl="${ASB_CAMERA_LEVEL_IN:-}"
if [ -z "$_lvl" ]; then
  _lvl="$(grep -E '^[[:space:]]*CAMERA_LEVEL=' "$CONF" 2>/dev/null \
          | head -1 | sed 's/.*=//' | tr -d ' \r')"
fi
case "$_lvl" in ''|*[!0-9]*) _lvl=0 ;; esac
[ "$_lvl" -gt 4 ] 2>/dev/null && _lvl=4

# Per-level ratios, in percent to keep the shell in integers.
#
# These are deliberately modest. A tuning file is a manufacturer's calibration, not a
# starting point that happens to be too low - the aim is a visible nudge, not a different
# camera. Saturation moves least because it is the one people notice going wrong.
case "$_lvl" in
  1) _sat=104; _ai=112; _sharp=108 ;;
  2) _sat=108; _ai=124; _sharp=116 ;;
  3) _sat=113; _ai=136; _sharp=126 ;;
  4) _sat=118; _ai=150; _sharp=138 ;;
  *) _sat=100; _ai=100; _sharp=100 ;;
esac

asb_camera_grade_file() {
  _src="$1"; _dst="$2"
  [ -f "$_src" ] || return 1
  [ "$_lvl" -gt 0 ] 2>/dev/null || { cp -f "$_src" "$_dst" 2>/dev/null; return 0; }

  awk -v SAT="$_sat" -v AI="$_ai" -v SHARP="$_sharp" '
    # Multiply every number inside the bracketed list that follows key, in place.
    # from/to are 1-based element positions; 0 means "all of them".
    function scale_list(line, key, pct, from, to,    head, body, tail, n, a, i, out, v) {
      if (index(line, "\"" key "\"") == 0) return line
      head = substr(line, 1, index(line, "\"" key "\"") + length(key) + 1)
      body = substr(line, length(head) + 1)
      if (index(body, "[") == 0) return line
      head = head substr(body, 1, index(body, "["))
      body = substr(body, index(body, "[") + 1)
      if (index(body, "]") == 0) return line
      tail = substr(body, index(body, "]"))
      body = substr(body, 1, index(body, "]") - 1)
      n = split(body, a, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        v = a[i] + 0
        if ((from == 0) || (i >= from && i <= to)) {
          v = v * pct / 100.0
          if (key ~ /BlendWeight/ && v > 1.0) v = 1.0
          if (v > 64.0) v = 64.0
          if (v < -64.0) v = -64.0
        }
        out = out (i > 1 ? ", " : "") sprintf("%.6g", v)
      }
      return head out tail
    }
    {
      line = $0
      # Chroma rows only: elements 4..9 of the 3x3 RGB->YUV matrix. Touching 1..3 would
      # shift luma, i.e. change exposure, which is not what a saturation control does.
      if (line ~ /_Rgb2YuvParams/) {
        for (k = 1; k <= NK; k++) { }
        n = split(line, dummy, "")
        if (line ~ /"Main1x_Rgb2YuvParams"/) line = scale_list(line, "Main1x_Rgb2YuvParams", SAT, 4, 9)
        if (line ~ /"Main2x_Rgb2YuvParams"/) line = scale_list(line, "Main2x_Rgb2YuvParams", SAT, 4, 9)
        if (line ~ /"UW_Rgb2YuvParams"/)     line = scale_list(line, "UW_Rgb2YuvParams",     SAT, 4, 9)
        if (line ~ /"Tele1_Rgb2YuvParams"/)  line = scale_list(line, "Tele1_Rgb2YuvParams",  SAT, 4, 9)
        if (line ~ /"Tele2_Rgb2YuvParams"/)  line = scale_list(line, "Tele2_Rgb2YuvParams",  SAT, 4, 9)
        if (line ~ /"Front_Rgb2YuvParams"/)  line = scale_list(line, "Front_Rgb2YuvParams",  SAT, 4, 9)
      }
      if (line ~ /BlendWeight/) {
        line = scale_list(line, "BlendWeight",       AI, 0, 0)
        line = scale_list(line, "PersonBlendWeight", AI, 0, 0)
        line = scale_list(line, "SkinBlendWeight",   AI, 0, 0)
        line = scale_list(line, "FaceBlendWeight",   AI, 0, 0)
        line = scale_list(line, "SkyBlendWeight",    AI, 0, 0)
        line = scale_list(line, "HairBlendWeight",   AI, 0, 0)
      }
      if (line ~ /Scale/) {
        line = scale_list(line, "BnScale",  SHARP, 0, 0)
        line = scale_list(line, "QbcScale", SHARP, 0, 0)
      }
      print line
    }
  ' "$_src" > "$_dst.tmp" 2>/dev/null

  # Only accept the result if it is still a plausible file. An awk that fell over on an
  # unexpected line would otherwise hand the camera HAL a truncated config, and a camera
  # that will not open is a far worse outcome than one that is not graded.
  if [ -s "$_dst.tmp" ]; then
    _n_src=$(wc -l < "$_src" 2>/dev/null)
    _n_dst=$(wc -l < "$_dst.tmp" 2>/dev/null)
    if [ "$_n_src" = "$_n_dst" ] && grep -q 'EnhanceNetParamsSet' "$_dst.tmp" 2>/dev/null; then
      mv -f "$_dst.tmp" "$_dst" 2>/dev/null
      return 0
    fi
  fi
  rm -f "$_dst.tmp" 2>/dev/null
  cp -f "$_src" "$_dst" 2>/dev/null
  return 1
}

# Standalone use: asb_camera_grade.sh <src> <dst>
if [ -n "$1" ] && [ -n "$2" ]; then
  asb_camera_grade_file "$1" "$2" \
    && echo "camera grade: level $_lvl (sat ${_sat}% ai ${_ai}% sharp ${_sharp}%)" \
    || echo "camera grade: FAILED, copied source unchanged"
fi
