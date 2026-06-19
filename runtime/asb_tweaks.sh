#!/system/bin/sh
# ASB dynamic aggressive-tweak engine (shared by install.sh and post-fs-data.sh)
#
# The "aggressive" audio (AUDIO_AGGRESSIVE) and camera (CAMERA_AGGRESSIVE /
# CAMERA_AGGRESSIVE_INJECT) layers are applied ON TOP of a saved baseline so a
# plain reboot can turn them on or off without reinstalling the module.
#
# Model:
#   * install.sh saves the baseline copy of each affected file (that baseline
#     already contains the always-on tweaks — volume, flat EQ, Class-H RDAC,
#     stock camera tone — but NOT the aggressive layer) under
#     /data/adb/asb/tweak_base/. Baselines live OUTSIDE the module's system/
#     tree on purpose: anything under system/ is magic-mounted into /vendor,
#     so a .asbbase there would leak a stray file into the live partition.
#   * On every boot post-fs-data.sh calls asb_apply_dynamic_tweaks: it restores
#     each module file from its baseline (clean) and then, only if the WebUI
#     toggle is ON, re-applies the aggressive layer on top. This edits the
#     module's own system/ source BEFORE KSU/Magisk mounts it, so the change is
#     live on that boot.
# Net effect: toggle + reboot = state change, fully reversible, no reinstall.

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
  asb_tw_sedi 's/\("sunsetSatScale": *\)1\.6/\11.4/g'            "$_f"
  asb_tw_sedi 's/\("sunsetSatScale": *\)1\.7/\11.4/g'            "$_f"
  asb_tw_sedi 's/\("blueSatParam": *\)0\.95/\11.05/g'            "$_f"
  asb_tw_sedi 's/\("nightDownGainParam": *\)0\.3/\10.4/g'        "$_f"
  asb_tw_sedi 's/\("nightDownGainParamHizoom": *\)0\.3/\10.4/g'  "$_f"
  asb_tw_sedi 's/\("nightDownGainParamFront": *\)0\.3/\10.4/g'   "$_f"
  asb_tw_sedi 's/\("dayDownGainDarkBoostParam": *\)1\.3/\11.4/g' "$_f"
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

  _audio_aggr="$(asb_tw_flag AUDIO_AGGRESSIVE "$_conf")"
  _cam_aggr="$(asb_tw_flag CAMERA_AGGRESSIVE "$_conf")"
  _cam_inject="$(asb_tw_flag CAMERA_AGGRESSIVE_INJECT "$_conf")"

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
  # copy (OP12/OP13 ship both; the HAL may read either partition).
  for _cf in "$_md/system/vendor/odm/etc/camera/conf_tuning_params.json" \
             "$_md/system/odm/etc/camera/conf_tuning_params.json"; do
    [ -f "$_cf" ] || continue
    asb_tw_save_base "$_cf"          # no-op if a baseline already exists
    asb_tw_restore_base "$_cf"       # revert to clean base before re-applying
    if [ "$_cam_aggr" = "1" ]; then
      [ "$_cam_inject" = "1" ] && asb_tw_inject_camera "$_cf"
      asb_tw_aggr_camera "$_cf"
      # Safety net: if the patched conf is no longer well-formed (unbalanced
      # braces — a cheap structural check that needs no JSON parser on device),
      # revert to the baseline so the camera HAL never sees a broken file.
      if [ -f "$_cf" ]; then
        _ob="$(tr -cd '{' < "$_cf" 2>/dev/null | wc -c)"
        _cb="$(tr -cd '}' < "$_cf" 2>/dev/null | wc -c)"
        if [ "$_ob" != "$_cb" ] || [ "${_ob:-0}" = "0" ]; then
          asb_tw_restore_base "$_cf"
        fi
      fi
    fi
  done
}

# Install-time entry: (re)save baselines for every affected file. Forces an
# overwrite so a reinstall captures the fresh base tweaks, not a stale baseline.
asb_save_dynamic_baselines() {
  _md="$1"
  [ -n "$_md" ] && [ -d "$_md" ] || return 0
  for _mx in $(find "$_md/system/vendor/etc/audio" "$_md/system/vendor/odm/etc/audio" \
                    -type f -name "mixer_paths*.xml" 2>/dev/null); do
    asb_tw_save_base "$_mx" force
  done
  asb_tw_save_base "$_md/system/vendor/odm/etc/camera/conf_tuning_params.json" force
  asb_tw_save_base "$_md/system/odm/etc/camera/conf_tuning_params.json" force
}
