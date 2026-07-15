#!/system/bin/sh
# ASB dynamic aggressive-tweak engine (shared by install.sh and post-fs-data.sh)

ASB_TWEAK_BASE_DIR="/data/adb/asb/tweak_base"

# Portable in-place sed (no temp-file races, busybox-safe).
asb_tw_sedi() {
  _e="$1"; shift
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    _t="${_f}.asbtw$$"
    # Write to a temp file, copy over the original's mode/owner/SELinux context,
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
# features.conf reader, local to this file: asb_tweaks.sh is sourced from several
# places (post-fs-data.sh, install.sh) that do not all define asb_feature_enabled.
asb_tw_feature_on() {
  _ftf="${MODDIR:-${MODPATH:-/data/adb/modules/AutoSystemBoost}}/features.conf"
  [ -r "$_ftf" ] || return 0
  _ftl="$(grep -E "^$1=" "$_ftf" 2>/dev/null | tail -n 1)"
  [ -z "$_ftl" ] && return 0
  _ftv="${_ftl#*=}"
  _ftv="${_ftv%%[!01]*}"
  [ "$_ftv" = "1" ]
}

asb_tw_aggr_audio() {
  _f="$1"; [ -f "$_f" ] || return 0
  # Headphone companders OFF: cleaner, more dynamic HPHL/HPHR signal.
  asb_tw_sedi 's/\(name="HPH[LR] Compander" value="\)1"/\10"/g' "$_f"
  # Headphone DAC class CLS_H_ULP/LOHIFI -> CLS_H_HIFI (higher fidelity, small power).
  asb_tw_sedi 's/\(name="RX HPH Mode" value="\)CLS_H_ULP"/\1CLS_H_HIFI"/g' "$_f"
  asb_tw_sedi 's/\(name="RX HPH Mode" value="\)CLS_H_LOHIFI"/\1CLS_H_HIFI"/g' "$_f"
}

# --- aggressive CAMERA tone layer (one conf_tuning_params.json) ---
asb_tw_aggr_camera() {
  _f="$1"; [ -f "$_f" ] || return 0
  _lvl="$2"; [ -z "$_lvl" ] && _lvl=3
  [ "$_lvl" = "0" ] && return 0          # level 0 = stock, change nothing

  # GRADED camera grade (levels 1..4) applied to BOTH photo and video paths of
  _atc_soc="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_atc_soc" ] && _atc_soc="$(getprop ro.hardware.chipname 2>/dev/null)"
  _soft=0
  case "$_atc_soc" in sun|sm8750*) _soft=1 ;; esac

  # Per-level value tables (index = level 1..4). Columns:
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
  asb_tw_sedi "s/\\(\"SatuColorScale\": *\\)1\\([,}]\\)/\\1${_SCS}\\2/g"        "$_f"
  asb_tw_sedi "s/\\(\"SatuColorScale\": *\\)1\\.0\\([,}]\\)/\\1${_SCS}\\2/g"    "$_f"
  asb_tw_sedi "s/\\(\"low20XcontrastScale\": *\\)1\\([,}]\\)/\\1${_CON}\\2/g"     "$_f"
  asb_tw_sedi "s/\\(\"low20XcontrastScale\": *\\)1\\.0\\([,}]\\)/\\1${_CON}\\2/g" "$_f"
  asb_tw_sedi "s/\\(\"skyDarkenScale\": *\\)0\\.1\\([,}]\\)/\\1${_SKD}\\2/g"      "$_f"
}

# --- inject the aggressive tone keys a trimmed stock conf_tuning lacks ---
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

  # Mixer/DAC half: its own axis now (audio_dac_hifi), separate from audio_profile.
  # Legacy AUDIO_AGGRESSIVE is honoured so an un-migrated config keeps working.
  _audio_aggr="$(asb_tw_flag audio_dac_hifi "$_conf")"
  [ "$_audio_aggr" = "1" ] || _audio_aggr="$(asb_tw_flag AUDIO_AGGRESSIVE "$_conf")"
  _cam_inject="$(asb_tw_flag CAMERA_AGGRESSIVE_INJECT "$_conf")"
  _cam_level="$(asb_tw_camera_level "$_conf")"

  # --- AUDIO mixer files ---
  # Respect the installer categories individually. The caller only checks
  # "AUDIO or CAMERA", so without this a user who kept CAMERA but dropped AUDIO would
  # still get their mixer files rewritten every boot - which is exactly the kind of
  # "I skipped it but something still applies" breakage that fights external DSPs.
  if asb_tw_feature_on AUDIO; then
  for _mx in $(find "$_md/system/vendor/etc/audio" "$_md/system/vendor/odm/etc/audio" \
                    -type f -name "mixer_paths*.xml" 2>/dev/null); do
    # Capture a baseline of the current (pre-aggressive) file if we have none
    asb_tw_save_base "$_mx"          # no-op if a baseline already exists
    asb_tw_restore_base "$_mx"       # revert to clean base before re-applying
    if [ "$_audio_aggr" = "1" ]; then
      asb_tw_aggr_audio "$_mx"
    fi
  done
  fi

  # --- CAMERA conf_tuning --- patch BOTH the /vendor/odm and the direct /odm
  asb_tw_feature_on CAMERA || _skip_cam=true
  if [ "$_skip_cam" != "true" ]; then
  for _cf in "$_md/system/vendor/odm/etc/camera/conf_tuning_params.json" \
             "$_md/system/odm/etc/camera/conf_tuning_params.json"; do
    [ -f "$_cf" ] || continue
    asb_tw_save_base "$_cf"          # no-op if a baseline already exists
    _bp="$(asb_tw_base_path "$_cf")"
    [ -f "$_bp" ] || continue
    # Build the DESIRED final conf in a temp from the clean baseline, apply the
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
