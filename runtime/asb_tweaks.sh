#!/system/bin/sh
# ASB dynamic aggressive-tweak engine (shared by install.sh and post-fs-data.sh)
#
# AUDIO_AGGRESSIVE / CAMERA_AGGRESSIVE(_INJECT) are applied on top of a saved
# baseline, so a plain reboot toggles them without reinstalling. install.sh saves
# each affected file's clean baseline (always-on tweaks included, aggressive layer
# NOT) under /data/adb/asb/tweak_base/ — outside system/ on purpose, since system/
# is magic-mounted into /vendor and a stray .asbbase there would leak into the
# live partition. Each boot, post-fs-data restores from baseline then re-applies
# the aggressive layer only if the toggle is ON, editing the module's system/
# source before the manager mounts it. Net: toggle + reboot = reversible change.

ASB_TWEAK_BASE_DIR="/data/adb/asb/tweak_base"

# Portable in-place sed (no temp-file races, busybox-safe).
asb_tw_sedi() {
  _e="$1"; shift
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    _t="${_f}.asbtw$$"
    # Write to a temp file, copy over the original's mode/owner/SELinux context,
    # then atomically rename into place. An in-place "cat > file" leaves a window
    # where a reader (e.g. the camera HAL) can see a truncated/half-written file
    # and the file can lose its SELinux label — on devices whose camera HAL reads
    # the config early at boot that surfaced as "storage loading / camera
    # unavailable" on first launch. mv is atomic on the same filesystem.
    if sed "$_e" "$_f" > "$_t" 2>/dev/null; then
      chmod --reference="$_f" "$_t" 2>/dev/null || chmod 0644 "$_t" 2>/dev/null
      chown --reference="$_f" "$_t" 2>/dev/null
      _ctx="$(ls -Z "$_f" 2>/dev/null | awk '{print $1}')"
      case "$_ctx" in u:object_r:*) chcon "$_ctx" "$_t" 2>/dev/null ;; esac
      mv -f "$_t" "$_f" 2>/dev/null || { cat "$_t" > "$_f" 2>/dev/null; rm -f "$_t" 2>/dev/null; }
    else
      rm -f "$_t" 2>/dev/null
    fi
  done
}

# Map a module file path to its baseline store path (flatten / -> _).
asb_tw_base_path() {
  _rel="${1#*/system/}"
  printf '%s/%s.asbbase' "$ASB_TWEAK_BASE_DIR" "$(echo "$_rel" | tr '/' '_')"
}

# Read a key's value from governor.conf (default 0). $1=key $2=conf-path
asb_tw_flag() {
  _k="$1"; _conf="$2"
  [ -f "$_conf" ] || { echo 0; return; }
  _v="$(grep -E "^[[:space:]]*${_k}=" "$_conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  # Accept both the bool form (1) and the segmented form (aggressive/on) that
  # the WebUI now writes for some toggles, e.g. CAMERA_AGGRESSIVE_INJECT which
  # stores safe|aggressive. "aggressive" and "on" both mean enabled.
  case "$_v" in 1|on|aggressive) echo 1 ;; *) echo 0 ;; esac
}

# Read an integer-valued key (used by the graded camera strength slider).
# Returns the integer, or the supplied default when absent/non-numeric.
asb_tw_int() {
  _k="$1"; _conf="$2"; _def="$3"
  [ -f "$_conf" ] || { echo "$_def"; return; }
  _v="$(grep -E "^[[:space:]]*${_k}=" "$_conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_v" in
    ''|*[!0-9]*) echo "$_def" ;;
    *) echo "$_v" ;;
  esac
}

# Resolve the effective camera strength LEVEL (0..4) from config, with back-compat
# for the old CAMERA_AGGRESSIVE bool:
#   CAMERA_LEVEL present  -> use it (0 stock .. 4 max)
#   else CAMERA_AGGRESSIVE=1 -> level 3 (the old "aggressive" grade)
#   else                  -> 0 (stock / off)
asb_tw_camera_level() {
  _conf="$1"
  _lv="$(asb_tw_int CAMERA_LEVEL "$_conf" -1)"
  if [ "$_lv" = "-1" ]; then
    if [ "$(asb_tw_flag CAMERA_AGGRESSIVE "$_conf")" = "1" ]; then _lv=3; else _lv=0; fi
  fi
  # clamp 0..4
  [ "$_lv" -lt 0 ] 2>/dev/null && _lv=0
  [ "$_lv" -gt 4 ] 2>/dev/null && _lv=4
  echo "$_lv"
}

# --- aggressive AUDIO layer (one mixer file) ---
asb_tw_aggr_audio() {
  _f="$1"; [ -f "$_f" ] || return 0
  # Headphone companders OFF: cleaner, more dynamic HPHL/HPHR signal.
  asb_tw_sedi 's/\(name="HPH[LR] Compander" value="\)1"/\10"/g' "$_f"
  # Headphone DAC class CLS_H_ULP -> CLS_H_HIFI (higher fidelity, small power).
  asb_tw_sedi 's/\(name="RX HPH Mode" value="\)CLS_H_ULP"/\1CLS_H_HIFI"/g' "$_f"
}

# --- aggressive CAMERA tone layer (one conf_tuning_params.json) ---
asb_tw_aggr_camera() {
  _f="$1"; [ -f "$_f" ] || return 0
  _lvl="$2"; [ -z "$_lvl" ] && _lvl=3
  [ "$_lvl" = "0" ] && return 0          # level 0 = stock, change nothing

  # GRADED camera grade (levels 1..4) applied to BOTH photo and video paths of
  # conf_tuning_params.json. The grade scales a coherent set of tone/colour/
  # contrast/noise keys so each step is visibly stronger than the last, from a
  # gentle "safe" lift up to a punchy "max". Per the OP13 owner's request the
  # higher levels intentionally push saturation/contrast hard (shadow banding at
  # max is accepted). Device-aware: OP15 (canoe) is the reference; OP13 (sun) is
  # offset one notch softer at matched levels (it banded earlier in testing);
  # OP12 (pineapple) has no overlay so this is a no-op there.
  _atc_soc="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_atc_soc" ] && _atc_soc="$(getprop ro.hardware.chipname 2>/dev/null)"
  _soft=0
  case "$_atc_soc" in sun|sm8750*) _soft=1 ;; esac

  # Per-level value tables (index = level 1..4). Columns:
  #   SSS  sunsetSatScale            (sunset saturation; base 1.6/1.7)
  #   BSAT blueSatParam              (blue/sky saturation; base 0.95)
  #   NDG  nightDownGainParam*       (night detail lift; base 0.3)
  #   DDB  dayDownGainDarkBoostParam (shadow/contrast boost; base 1.3)
  #   SCS  SatuColorScale            (global colour, PHOTO+VIDEO; base 1)
  #   CON  low20XcontrastScale       (local contrast, PHOTO+VIDEO; base 1)
  #   SKD  skyDarkenScale            (sky depth; base 0.1)
  # canoe (reference) tables:
  set -- \
    "1.45 0.99 0.34 1.30 1.05 1.05 0.12" \
    "1.40 1.02 0.38 1.40 1.12 1.12 0.16" \
    "1.30 1.05 0.42 1.50 1.20 1.20 0.20" \
    "1.20 1.10 0.48 1.65 1.30 1.30 0.26"
  # if this SoC bands earlier (sun), shift one level softer (clamp at 1)
  _row="$_lvl"
  if [ "$_soft" = "1" ]; then _row=$((_lvl - 1)); [ "$_row" -lt 1 ] && _row=1; fi
  eval "_vals=\${$_row}"
  set -- $_vals
  _SSS="$1"; _BSAT="$2"; _NDG="$3"; _DDB="$4"; _SCS="$5"; _CON="$6"; _SKD="$7"

  # --- tone / colour (affects photo + video) ---
  asb_tw_sedi "s/\\(\"sunsetSatScale\": *\\)1\\.6/\\1${_SSS}/g"            "$_f"
  asb_tw_sedi "s/\\(\"sunsetSatScale\": *\\)1\\.7/\\1${_SSS}/g"            "$_f"
  asb_tw_sedi "s/\\(\"blueSatParam\": *\\)0\\.95/\\1${_BSAT}/g"            "$_f"
  asb_tw_sedi "s/\\(\"nightDownGainParam\": *\\)0\\.3/\\1${_NDG}/g"        "$_f"
  asb_tw_sedi "s/\\(\"nightDownGainParamHizoom\": *\\)0\\.3/\\1${_NDG}/g"  "$_f"
  asb_tw_sedi "s/\\(\"nightDownGainParamFront\": *\\)0\\.3/\\1${_NDG}/g"   "$_f"
  asb_tw_sedi "s/\\(\"dayDownGainDarkBoostParam\": *\\)1\\.3/\\1${_DDB}/g" "$_f"
  # global colour + local contrast — these live in TMCParamsSet and are honoured
  # by both the photo and video pipelines, so they are what makes the grade show
  # up in stills, not just video.
  asb_tw_sedi "s/\\(\"SatuColorScale\": *\\)1\\([,}]\\)/\\1${_SCS}\\2/g"        "$_f"
  asb_tw_sedi "s/\\(\"SatuColorScale\": *\\)1\\.0\\([,}]\\)/\\1${_SCS}\\2/g"    "$_f"
  asb_tw_sedi "s/\\(\"low20XcontrastScale\": *\\)1\\([,}]\\)/\\1${_CON}\\2/g"     "$_f"
  asb_tw_sedi "s/\\(\"low20XcontrastScale\": *\\)1\\.0\\([,}]\\)/\\1${_CON}\\2/g" "$_f"
  asb_tw_sedi "s/\\(\"skyDarkenScale\": *\\)0\\.1\\([,}]\\)/\\1${_SKD}\\2/g"      "$_f"
}

# --- inject the aggressive tone keys a trimmed stock conf_tuning lacks ---
# (CAMERA_AGGRESSIVE_INJECT). Adds only absent keys, after the always-present
# "sunsetBrightScale" anchor, preserving JSON validity.
asb_tw_inject_camera() {
  _f="$1"; [ -f "$_f" ] || return 0
  grep -q '"sunsetBrightScale"' "$_f" || return 0
  _ind="$(sed -n 's/\([[:space:]]*\)"sunsetBrightScale".*/\1/p' "$_f" | head -1)"
  for _kv in "blueSatParam:1.05" "nightDownGainParam:0.4" \
             "nightDownGainParamHizoom:0.4" "nightDownGainParamFront:0.4" \
             "dayDownGainDarkBoostParam:1.4"; do
    _k="${_kv%%:*}"; _val="${_kv#*:}"
    grep -q "\"$_k\"" "$_f" && continue
    asb_tw_sedi "/\"sunsetBrightScale\"/a\\
${_ind}\"${_k}\": ${_val}," "$_f"
  done
}

# Save a baseline copy. $1 = module file, $2 = "force" to overwrite an existing
# baseline (used at install so a reinstall re-captures the fresh base tweaks).
asb_tw_save_base() {
  _f="$1"; _force="$2"
  [ -f "$_f" ] || return 0
  mkdir -p "$ASB_TWEAK_BASE_DIR" 2>/dev/null
  _bp="$(asb_tw_base_path "$_f")"
  [ "$_force" != "force" ] && [ -f "$_bp" ] && return 0
  cp -f "$_f" "$_bp" 2>/dev/null || true
}

# Restore a file from its baseline if one exists. $1 = module file
asb_tw_restore_base() {
  _f="$1"
  _bp="$(asb_tw_base_path "$_f")"
  [ -f "$_bp" ] || return 1
  # If the live file already equals the baseline, do NOT rewrite it. Rewriting
  # an unchanged file on every boot needlessly churns the camera conf on a
  # separate /odm partition (OP13/OP12), and the camera HAL reading /odm early
  # at boot can catch that write and report "storage loading / camera
  # unavailable" on first launch. cmp is a cheap byte compare; skip on match.
  if cmp -s "$_bp" "$_f" 2>/dev/null; then
    return 0
  fi
  _t="${_f}.asbrb$$"
  if cat "$_bp" > "$_t" 2>/dev/null; then
    chmod --reference="$_f" "$_t" 2>/dev/null || chmod 0644 "$_t" 2>/dev/null
    chown --reference="$_f" "$_t" 2>/dev/null
    _ctx="$(ls -Z "$_f" 2>/dev/null | awk '{print $1}')"
    case "$_ctx" in u:object_r:*) chcon "$_ctx" "$_t" 2>/dev/null ;; esac
    mv -f "$_t" "$_f" 2>/dev/null || { cp -f "$_bp" "$_f" 2>/dev/null; rm -f "$_t" 2>/dev/null; }
  else
    rm -f "$_t" 2>/dev/null; cp -f "$_bp" "$_f" 2>/dev/null || true
  fi
  return 0
}

# Main boot-time entry: restore baselines, then apply aggressive layers per
# the current toggle state. $1 = MODDIR
asb_apply_dynamic_tweaks() {
  _md="$1"
  [ -n "$_md" ] && [ -d "$_md" ] || return 0
  _conf="$_md/config/governor.conf"

  # Detect OP12 (pineapple/SM8650) and whether we're on APatch. The camera-conf
  # churn only crashes the multicamera HAL on OP12 + APatch (APatch's /odm is a
  # real separate mount). On OP12 + KernelSU (/odm is a symlink to /vendor/odm)
  # the camera tolerates the engine, and OP13/OP15 are unaffected — so only the
  # OP12+APatch combination must skip the camera path. The audio layer is safe on
  # all of them. Filesystem markers are reliable at boot; getprop is fine here too.
  _tw_plat="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_tw_plat" ] && _tw_plat="$(getprop ro.hardware.chipname 2>/dev/null)"
  _is_op12=false
  case "$_tw_plat" in pineapple|sm8650*) _is_op12=true ;; esac
  _is_apatch=false
  if [ "${APATCH:-}" = "true" ] || [ -d /data/adb/ap ] || [ -f /data/adb/apd ]; then
    if [ "${KSU:-}" = "true" ] || [ -f /data/adb/ksud ]; then
      [ "${APATCH:-}" = "true" ] && _is_apatch=true
    else
      _is_apatch=true
    fi
  fi
  _skip_cam=false
  [ "$_is_op12" = "true" ] && [ "$_is_apatch" = "true" ] && _skip_cam=true

  _audio_aggr="$(asb_tw_flag AUDIO_AGGRESSIVE "$_conf")"
  _cam_aggr="$(asb_tw_flag CAMERA_AGGRESSIVE "$_conf")"
  _cam_inject="$(asb_tw_flag CAMERA_AGGRESSIVE_INJECT "$_conf")"
  _cam_level="$(asb_tw_camera_level "$_conf")"

  # --- AUDIO mixer files ---
  for _mx in $(find "$_md/system/vendor/etc/audio" "$_md/system/vendor/odm/etc/audio" \
                    -type f -name "mixer_paths*.xml" 2>/dev/null); do
    # Capture a baseline of the current (pre-aggressive) file if we have none
    # yet — this is the clean base-tweaked mixer. Then restore from baseline so
    # toggling OFF reverts cleanly. Crucially we no longer SKIP the file when no
    # baseline exists (the old "|| continue" meant AUDIO_AGGRESSIVE silently did
    # nothing on APatch, where the install-time save hadn't populated the store).
    asb_tw_save_base "$_mx"          # no-op if a baseline already exists
    asb_tw_restore_base "$_mx"       # revert to clean base before re-applying
    if [ "$_audio_aggr" = "1" ]; then
      asb_tw_aggr_audio "$_mx"
    fi
  done

  # --- CAMERA conf_tuning --- patch BOTH the /vendor/odm and the direct /odm
  # copy (OP13 ships both; the HAL may read either partition). Skipped entirely
  # on OP12 + APatch (_skip_cam) — that combination crashes the multicamera HAL
  # on any camera-conf churn. OP12 + KernelSU and OP13/OP15 patch normally.
  if [ "$_skip_cam" != "true" ]; then
  for _cf in "$_md/system/vendor/odm/etc/camera/conf_tuning_params.json" \
             "$_md/system/odm/etc/camera/conf_tuning_params.json"; do
    [ -f "$_cf" ] || continue
    asb_tw_save_base "$_cf"          # no-op if a baseline already exists
    _bp="$(asb_tw_base_path "$_cf")"
    [ -f "$_bp" ] || continue
    # Build the DESIRED final conf in a temp from the clean baseline, apply the
    # aggressive/inject layers there, then swap it in ONLY if it differs from the
    # live file. This makes the whole step idempotent: when nothing changed
    # (e.g. a normal reboot with the same toggles) the /odm conf is not rewritten
    # at all. Rewriting it every boot — restore-to-baseline then re-apply — is
    # what raced the OP13 camera HAL reading /odm early and flashed
    # "storage loading / camera unavailable" on first launch.
    _des="${_cf}.asbdes$$"
    cp -f "$_bp" "$_des" 2>/dev/null || { rm -f "$_des"; continue; }
    if [ "$_cam_level" -gt 0 ] 2>/dev/null; then
      [ "$_cam_inject" = "1" ] && asb_tw_inject_camera "$_des"
      asb_tw_aggr_camera "$_des" "$_cam_level"
      # structural safety net: unbalanced braces -> fall back to the baseline.
      _ob="$(tr -cd '{' < "$_des" 2>/dev/null | wc -c)"
      _cb="$(tr -cd '}' < "$_des" 2>/dev/null | wc -c)"
      if [ "$_ob" != "$_cb" ] || [ "${_ob:-0}" = "0" ]; then
        cp -f "$_bp" "$_des" 2>/dev/null
      fi
    fi
    # swap in only on a real difference, preserving mode/owner/SELinux context.
    if ! cmp -s "$_des" "$_cf" 2>/dev/null; then
      chmod --reference="$_cf" "$_des" 2>/dev/null || chmod 0644 "$_des" 2>/dev/null
      chown --reference="$_cf" "$_des" 2>/dev/null
      _ctx="$(ls -Z "$_cf" 2>/dev/null | awk '{print $1}')"
      case "$_ctx" in u:object_r:*) chcon "$_ctx" "$_des" 2>/dev/null ;; esac
      mv -f "$_des" "$_cf" 2>/dev/null || { cat "$_des" > "$_cf" 2>/dev/null; rm -f "$_des"; }
    else
      rm -f "$_des" 2>/dev/null
    fi
  done
  fi
}

# Install-time entry: (re)save baselines for every affected file. Forces an
# overwrite so a reinstall captures the fresh base tweaks, not a stale baseline.
asb_save_dynamic_baselines() {
  _md="$1"
  [ -n "$_md" ] && [ -d "$_md" ] || return 0
  # Build the set of baseline names that SHOULD exist for this install, saving
  # each as we go. We collect the valid names so we can prune orphans afterwards.
  _valid_bases=""
  for _mx in $(find "$_md/system/vendor/etc/audio" "$_md/system/vendor/odm/etc/audio" \
                    -type f -name "mixer_paths*.xml" 2>/dev/null); do
    asb_tw_save_base "$_mx" force
    _valid_bases="$_valid_bases $(basename "$(asb_tw_base_path "$_mx")")"
  done
  for _cam in "$_md/system/vendor/odm/etc/camera/conf_tuning_params.json" \
              "$_md/system/odm/etc/camera/conf_tuning_params.json"; do
    [ -f "$_cam" ] || continue
    asb_tw_save_base "$_cam" force
    _valid_bases="$_valid_bases $(basename "$(asb_tw_base_path "$_cam")")"
  done
  # Orphan prune: remove any .asbbase whose source file is no longer shipped by
  # this build (e.g. a device that previously had OP15 canoe/alor SKUs and now
  # ships device-specific ones, or a build that dropped a SKU). This keeps
  # /data/adb/asb/tweak_base from accumulating stale baselines across reinstalls.
  # Only baselines NOT in the freshly-built valid set are touched, so every
  # active baseline is preserved.
  if [ -d "$ASB_TWEAK_BASE_DIR" ]; then
    for _bf in "$ASB_TWEAK_BASE_DIR"/*.asbbase; do
      [ -e "$_bf" ] || continue
      _bn="$(basename "$_bf")"
      case " $_valid_bases " in
        *" $_bn "*) : ;;                      # still valid — keep
        *) rm -f "$_bf" 2>/dev/null || true ;;  # orphan — remove
      esac
    done
  fi
}
