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
  # DEVICE-AWARE strength. The full-aggressive tone is tuned for OP15 (canoe);
  # on OP13 (sun) users reported visible low-light banding / saturation jumps,
  # so sun gets a softer grade (blueSat 1.02 instead of 1.05, nightDownGain 0.35
  # instead of 0.4, dayDarkBoost 1.3 instead of 1.4). OP12 has no camera overlay.
  _atc_soc="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_atc_soc" ] && _atc_soc="$(getprop ro.hardware.chipname 2>/dev/null)"
  case "$_atc_soc" in
    sun|sm8750*)
      _BSAT="1.02"; _NDG="0.35"; _DDB="1.3"; _SSS="1.3" ;;
    *)
      _BSAT="1.05"; _NDG="0.4";  _DDB="1.4"; _SSS="1.4" ;;
  esac
  asb_tw_sedi "s/\\(\"sunsetSatScale\": *\\)1\\.6/\\1${_SSS}/g"            "$_f"
  asb_tw_sedi "s/\\(\"sunsetSatScale\": *\\)1\\.7/\\1${_SSS}/g"            "$_f"
  asb_tw_sedi "s/\\(\"blueSatParam\": *\\)0\\.95/\\1${_BSAT}/g"            "$_f"
  asb_tw_sedi "s/\\(\"nightDownGainParam\": *\\)0\\.3/\\1${_NDG}/g"        "$_f"
  asb_tw_sedi "s/\\(\"nightDownGainParamHizoom\": *\\)0\\.3/\\1${_NDG}/g"  "$_f"
  asb_tw_sedi "s/\\(\"nightDownGainParamFront\": *\\)0\\.3/\\1${_NDG}/g"   "$_f"
  asb_tw_sedi "s/\\(\"dayDownGainDarkBoostParam\": *\\)1\\.3/\\1${_DDB}/g" "$_f"
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
  # OP12 (pineapple/SM8650): camera category is fully disabled (the vendor
  # multicamera HAL crashes on any non-stock camera env), so never touch camera
  # config here — no baseline, no restore, no aggressive, no inject.
  _tw_plat="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_tw_plat" ] && _tw_plat="$(getprop ro.hardware.chipname 2>/dev/null)"
  case "$_tw_plat" in
    pineapple|sm8650*)
      return 0 ;;
  esac
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
    if [ "$_cam_aggr" = "1" ]; then
      [ "$_cam_inject" = "1" ] && asb_tw_inject_camera "$_des"
      asb_tw_aggr_camera "$_des"
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
