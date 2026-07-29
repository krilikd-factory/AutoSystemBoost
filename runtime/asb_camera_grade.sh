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
[ "$_lvl" -gt 8 ] 2>/dev/null && _lvl=8

# Per-level ratios, in percent to keep the shell in integers.
#
# These are deliberately modest. A tuning file is a manufacturer's calibration, not a
# starting point that happens to be too low - the aim is a visible nudge, not a different
# camera. Saturation moves least because it is the one people notice going wrong.
# Levels 1-4 stay conservative; 5-8 go past what a manufacturer would ship.
#
# The top of the range is deliberately further than "tasteful". Someone asking for level
# 8 is not being talked out of it by a cap, and the values below are still bounded by the
# clamps in the awk - a blend weight cannot exceed 1.0, and nothing may exceed 64. What
# 7-8 buy is a look, not an improvement: heavy saturation and sharpening produce halos
# and posterised skies, which is a legitimate thing to want and a terrible default.
case "$_lvl" in
  1) _sat=104; _ai=112; _sharp=108 ;;
  2) _sat=110; _ai=126; _sharp=118 ;;
  3) _sat=118; _ai=142; _sharp=132 ;;
  4) _sat=128; _ai=160; _sharp=150 ;;
  5) _sat=140; _ai=180; _sharp=172 ;;
  6) _sat=155; _ai=200; _sharp=198 ;;
  7) _sat=175; _ai=230; _sharp=230 ;;
  8) _sat=200; _ai=260; _sharp=270 ;;
  *) _sat=100; _ai=100; _sharp=100 ;;
esac

# ── the four independent controls ─────────────────────────────────────────────
_cfg_num() {
  _v="${2:-}"
  [ -n "$_v" ] || _v="$(grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
                        | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_v" in ''|*[!0-9]*) echo "" ;; *) echo "$_v" ;; esac
}

# Grain. addNoiseWeight* is deliberately ADDED noise - the camera puts grain back after
# denoising, because a perfectly smooth image reads as plastic. Scaling it down gives a
# cleaner look, up gives more texture. 0 turns the grain off entirely, which is what
# someone chasing maximum smoothness wants.
_grain="$(_cfg_num CAMERA_GRAIN "$ASB_CAM_GRAIN_IN")"
case "$_grain" in ''|*[!0-9]*) _grain=3 ;; esac
[ "$_grain" -gt 8 ] 2>/dev/null && _grain=8
# 3 is stock; 8 is roughly 2.7x the shipped grain, which is a strong film look.
_grain_pct=$(( _grain * 100 / 3 ))

# Contrast and colour depth, from the tone-mapping block: the *contrastScale and
# SatuColorScale knobs. Separate from the saturation above, which works on the colour
# matrix - this one shapes the curve rather than the gamut.
_contrast="$(_cfg_num CAMERA_CONTRAST "$ASB_CAM_CONTRAST_IN")"
case "$_contrast" in ''|*[!0-9]*) _contrast=3 ;; esac
[ "$_contrast" -gt 8 ] 2>/dev/null && _contrast=8
# 3 = stock, exactly 100%. The old formula was 70 + n*15, which gives 115 at n=3 -
# so the documented "neutral" setting quietly pushed contrast and saturation 15% every
# install, and compounded on every reinstall. 3*10+70 = 100 makes neutral actually
# neutral; 0 flattens to 70%, 6 (the UI maximum) reaches 130%.
_contrast_pct=$(( 70 + _contrast * 10 ))

# Portrait AI. PersonBlendWeight, SkinBlendWeight and FaceBlendWeight ship at 0.0 - the
# neural pass is simply off for faces. A ratio cannot move zero, so this one writes
# ABSOLUTE values. That is the whole reason it needs its own code path rather than
# joining the AI detail scaling above.
_portrait="$(_cfg_num CAMERA_PORTRAIT "$ASB_CAM_PORTRAIT_IN")"
case "$_portrait" in ''|*[!0-9]*) _portrait=0 ;; esac
[ "$_portrait" -gt 6 ] 2>/dev/null && _portrait=6
case "$_portrait" in
  1) _p1="0.15"; _p2="0.2";  _p3="0.25" ;;
  2) _p1="0.25"; _p2="0.35"; _p3="0.4"  ;;
  3) _p1="0.4";  _p2="0.5";  _p3="0.55" ;;
  4) _p1="0.55"; _p2="0.65"; _p3="0.7"  ;;
  5) _p1="0.7";  _p2="0.8";  _p3="0.85" ;;
  6) _p1="0.85"; _p2="0.92"; _p3="1.0"  ;;
  *) _p1=""; _p2=""; _p3="" ;;
esac

# Macro and low-light sharpening. MacroParams and LivehouseParams have their own
# BnScale/QbcScale, and they are the modes where over-sharpening shows up worst - close
# subjects and high ISO both amplify halos. Their own control, defaulting to following
# the main sharpening rather than exceeding it.
_lowlight="$(_cfg_num CAMERA_LOWLIGHT "$ASB_CAM_LOWLIGHT_IN")"
case "$_lowlight" in ''|*[!0-9]*) _lowlight=0 ;; esac
[ "$_lowlight" -gt 8 ] 2>/dev/null && _lowlight=8
if [ "$_lowlight" -gt 0 ] 2>/dev/null; then
  _low_pct=$(( 100 + _lowlight * 22 ))
else
  _low_pct="$_sharp"
fi

# Fingerprint: the structural guarantee that a file is never graded twice.
#
# The chroma check that guards the baseline is a heuristic - it works because stock
# happens to be the exact BT.601 matrix, and it would stop working the day a device ships
# something else. Compounding cost three rounds of debugging (x1.28 -> x1.51 -> x1.93 ->
# x2.47 on one user's phone), so it is worth closing structurally rather than probably.
#
# The marker records the hash of the SOURCE plus the settings that produced the output. A
# file carrying a marker is already a result, never an input; a file whose marker does not
# match the current settings is a result of DIFFERENT settings, and regrading it from
# there would compound just as badly. Either way the answer is to go back to the source,
# which is what the baseline is for.
ASB_GRADE_MARK="ASBGRADE"

# The marker lives in a SIDECAR, never inside the file.
#
# The obvious place was a trailing comment - and a trailing "// ..." makes the file
# invalid JSON, which the camera HAL parses at every open. Tested rather than assumed: a
# marker line appended to the real tuning file fails json.load outright. A tuning file
# the camera cannot read is a far worse outcome than the compounding this is meant to
# prevent, so the marker goes beside the file instead of in it.
ASB_GRADE_DIR="/data/adb/asb/grade_marks"

asb_grade_mark_path() {
  # One marker per destination, named after the path so two destinations cannot collide.
  printf '%s/%s.mark' "$ASB_GRADE_DIR" \
    "$(printf '%s' "$1" | sed 's|^/||; s|/|_|g')"
}

asb_camera_grade_file() {
  _src="$1"; _dst="$2"
  [ -f "$_src" ] || return 1

  # Refuse a source that is itself a graded result.
  if [ -f "$(asb_grade_mark_path "$_src")" ]; then
    echo "camera grade: source is a previous result - refusing to compound"
    return 2
  fi

  [ "$_lvl" -gt 0 ] 2>/dev/null || { cp -f "$_src" "$_dst" 2>/dev/null; return 0; }

  awk -v SAT="$_sat" -v AI="$_ai" -v SHARP="$_sharp" \
      -v GRAIN="$_grain_pct" -v CONTR="$_contrast_pct" -v LOW="$_low_pct" \
      -v P1="$_p1" -v P2="$_p2" -v P3="$_p3" -v INBLK="" '
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
    # Scale a bare "key": number, as opposed to a bracketed list.
    function scale_num(line, key, pct,    head, body, tail, v, i, c) {
      if (index(line, "\"" key "\"") == 0) return line
      head = substr(line, 1, index(line, "\"" key "\"") + length(key) + 1)
      body = substr(line, length(head) + 1)
      i = index(body, ":")
      if (i == 0) return line
      head = head substr(body, 1, i)
      body = substr(body, i + 1)
      tail = ""
      for (i = 1; i <= length(body); i++) {
        c = substr(body, i, 1)
        if (c !~ /[0-9.eE+ -]/) { tail = substr(body, i); body = substr(body, 1, i - 1); break }
      }
      v = body + 0
      v = v * pct / 100.0
      if (v > 64.0) v = 64.0
      if (v < 0) v = 0
      return head " " sprintf("%.6g", v) tail
    }
    # Replace a bracketed list with three fixed values. Needed where the stock value is
    # zero and no ratio can lift it.
    # Raise a bracketed triple to at least (a,b,c). Needed where the stock value is
    # zero and no ratio can lift it - but it must never pull a value DOWN. The old
    # version wrote the targets unconditionally, so "Portrait AI = 1" turned a stock
    # SnapPortrait PersonBlendWeight of [0.7,0.7,0.7] into [0.15,0.2,0.25]: a control
    # advertised as adding AI was removing three quarters of it.
    function set_list3(line, key, a, b, c,    head, body, tail, n, arr, i, out, v, t) {
      if (index(line, "\"" key "\"") == 0) return line
      head = substr(line, 1, index(line, "\"" key "\"") + length(key) + 1)
      body = substr(line, length(head) + 1)
      if (index(body, "[") == 0) return line
      head = head substr(body, 1, index(body, "["))
      body = substr(body, index(body, "[") + 1)
      if (index(body, "]") == 0) return line
      tail = substr(body, index(body, "]"))
      body = substr(body, 1, index(body, "]") - 1)
      n = split(body, arr, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        v = arr[i] + 0
        t = (i == 1) ? a + 0 : ((i == 2) ? b + 0 : c + 0)
        if (i <= 3 && t > v) v = t          # only ever upwards
        if (v > 1.0) v = 1.0                # blend weight ceiling
        out = out (i > 1 ? ", " : "") sprintf("%.6g", v)
      }
      return head out tail
    }
    # Which EnhanceNet sub-block are we inside? Portrait weights are only meaningful in
    # the portrait ones; setting them in the pet or concert blocks would be noise.
    /"EnhanceNet[A-Za-z]*Params"[[:space:]]*:/ {
      if ($0 ~ /Portrait/) INBLK = "portrait"; else INBLK = "other"
    }
    /"(Macro|Livehouse)Params"[[:space:]]*:/ { INBLK = "lowlight" }
    /"NormalParams"[[:space:]]*:/            { INBLK = "normal" }
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
        # No Front_Rgb2YuvParams exists - the colour matrix block covers the rear
        # cameras only (Main1x, Main2x, UW, Tele1, Tele2). The front camera is tuned
        # through the *Front keys in TMCParamsSet instead, which the contrast control
        # below reaches.
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
        # Macro and Livehouse get their own factor; everything else follows the main one.
        _sf = (INBLK == "lowlight") ? LOW : SHARP
        line = scale_list(line, "BnScale",  _sf, 0, 0)
        line = scale_list(line, "QbcScale", _sf, 0, 0)
      }
      # Added grain.
      if (line ~ /addNoiseWeight/) {
        line = scale_num(line, "addNoiseWeightSuperNightWide",       GRAIN)
        line = scale_num(line, "addNoiseWeightPeopleSuperNightWide", GRAIN)
        line = scale_num(line, "addNoiseWeightNightSuperNightWide",  GRAIN)
        line = scale_num(line, "addNoiseWeightWide",                 GRAIN)
        line = scale_num(line, "addNoiseWeightPeopleWide",           GRAIN)
        line = scale_num(line, "addNoiseWeightNightWide",            GRAIN)
        line = scale_num(line, "addNoiseWeightMain1X",               GRAIN)
        line = scale_num(line, "addNoiseWeightPeopleMain1X",         GRAIN)
        line = scale_num(line, "addNoiseWeightNightMain1X",          GRAIN)
        line = scale_num(line, "addNoiseWeightMain2X",               GRAIN)
        line = scale_num(line, "addNoiseWeightPeopleMain2X",         GRAIN)
        line = scale_num(line, "addNoiseWeightNightMain2X",          GRAIN)
        line = scale_num(line, "addNoiseWeightTele1",                GRAIN)
        line = scale_num(line, "addNoiseWeightPeopleTele1",          GRAIN)
        line = scale_num(line, "addNoiseWeightNightTele1",           GRAIN)
        line = scale_num(line, "addNoiseWeightTele2",                GRAIN)
        line = scale_num(line, "addNoiseWeightPeopleTele2",          GRAIN)
        line = scale_num(line, "addNoiseWeightNightTele2",           GRAIN)
      }
      # Tone curve: contrast and colour depth.
      if (line ~ /[Cc]ontrastScale|SatuColorScale|sunsetSatScale/) {
        line = scale_num(line, "low20XcontrastScale",  CONTR)
        line = scale_num(line, "high20XcontrastScale", CONTR)
        line = scale_num(line, "faceBackContrastScale", CONTR)
        line = scale_num(line, "SatuColorScale",       CONTR)
        line = scale_num(line, "sunsetSatScale",       CONTR)
      }
      # Portrait AI - absolute, and only inside the portrait sub-blocks.
      if (P1 != "" && INBLK == "portrait") {
        line = set_list3(line, "PersonBlendWeight", P1, P2, P3)
        line = set_list3(line, "SkinBlendWeight",   P1, P2, P3)
        line = set_list3(line, "FaceBlendWeight",   P1, P2, P3)
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
      # Stamp the result. The hash is of the SOURCE, so a later run can tell "this came
      # from the file I am about to use" from "this came from something else".
      mv -f "$_dst.tmp" "$_dst" 2>/dev/null
      _src_h="$(sha256sum "$_src" 2>/dev/null | cut -c1-16)"
      [ -n "$_src_h" ] || _src_h="nohash"
      mkdir -p "$ASB_GRADE_DIR" 2>/dev/null
      printf '%s=%s:%s:%s:%s:%s:%s\n' "$ASB_GRADE_MARK" "$_src_h" \
        "$_lvl" "$_grain" "$_contrast" "$_portrait" "$_lowlight" \
        > "$(asb_grade_mark_path "$_dst")" 2>/dev/null
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
