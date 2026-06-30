#!/system/bin/sh
# =============================================================================
# asb_install_probe.sh - INSTALL-TIME STOCK-FILE INVENTORY & ANALYSIS
# =============================================================================
# Runs during install (after device detection, before/around the in-place
# patches) to inventory the *specific* stock files this device actually ships -
# audio SKU dirs, mixer/policy/effects, camera configs, media codecs/profiles,
# Wi-Fi SKU + WCNSS, GPS, perf, Bluetooth/A2DP - and record the device's real
# topology and SKU. The point: make the per-device patching INFORMED and
# AUDITABLE instead of blind. The installer (and asbdiag, and a returned bundle)
# can read this to see exactly what was found and therefore what is patchable on
# THIS model.
#
# This is pure OBSERVATION - it reads, classifies, and writes a report. It does
# NOT modify any stock file, does NOT touch sysfs, does NOT lay down overlays.
# That keeps it safe to run at every install on any device.
#
# Output:
#   $1 (or /data/adb/asb/install_probe.txt) - human-readable analysis report
#   also emits a flat key=value facts block the installer can grep for the few
#   decisions it needs (audio SKU, mixer count, whether camera/media exist).
# =============================================================================

OUT="${1:-/data/adb/asb/install_probe.txt}"
mkdir -p "$(dirname "$OUT")" 2>/dev/null

_gp() { getprop "$1" 2>/dev/null; }
_count_glob() {  # $1=dir $2=pattern  -> count of matching files (0 if none)
  _d="$1"; _pat="$2"; [ -d "$_d" ] || { echo 0; return; }
  # grep -c already prints 0 on no match, but it EXITS non-zero then, so a
  # "|| echo 0" would append a SECOND 0 and yield a two-line value that breaks
  # the caller's $((...)) with "Illegal number". Count with wc -l instead (always
  # one clean integer, exit 0) and strip whitespace.
  find "$_d" -type f -name "$_pat" 2>/dev/null | wc -l | tr -d ' \n'
}

# Roots to scan, in the order Android's HALs resolve them. /vendor and
# /system/vendor usually alias, but we list both so an unusual layout is still
# covered; the inventory dedups by reporting per-root presence.
_ROOTS="/vendor /system/vendor /odm /vendor/odm /system/vendor/odm /system/odm"

{
  echo "==================================================================="
  echo " ASB INSTALL PROBE - stock-file inventory & analysis"
  echo " $(date '+%Y-%m-%d %H:%M:%S')"
  echo "==================================================================="
  echo ""

  # ---- device identity --------------------------------------------------
  echo "----- DEVICE -----"
  for _k in ro.product.model ro.product.name ro.product.device \
            ro.board.platform ro.soc.model ro.hardware \
            ro.boot.product.hardware.sku persist.vendor.audio.sku \
            ro.build.version.release ro.vendor.build.fingerprint; do
    echo "  $_k = $(_gp "$_k")"
  done
  echo ""

  # ---- CPU cluster topology (drives profile cap percentages) -----------
  echo "----- CPU CLUSTERS -----"
  _pc=0; _plist=""
  for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol" ] || continue
    _pid="${_pol##*policy}"; _pc=$((_pc+1)); _plist="$_plist $_pid"
    _hx="$(cat "$_pol/cpuinfo_max_freq" 2>/dev/null)"
    _hn="$(cat "$_pol/cpuinfo_min_freq" 2>/dev/null)"
    _rel="$(cat "$_pol/related_cpus" 2>/dev/null)"
    _nf=0
    [ -r "$_pol/scaling_available_frequencies" ] && \
      _nf=$(wc -w < "$_pol/scaling_available_frequencies" 2>/dev/null | tr -d ' ')
    echo "  policy${_pid}: cpus=[$_rel] hwmax=${_hx} hwmin=${_hn} steps=${_nf}"
  done
  echo "  cluster_count=$_pc list=$(echo "$_plist" | sed 's/^ *//')"
  # topology class hint for the installer (2=big.LITTLE, 3+=has MID workhorse)
  if [ "$_pc" -ge 3 ]; then echo "  topology_class=multi_mid"; else echo "  topology_class=two_cluster"; fi
  echo ""

  # ---- GPU back-end (devfreq vs pwrlevel decides how GPU cap is applied) -
  echo "----- GPU -----"
  if [ -d /sys/class/kgsl/kgsl-3d0/devfreq ]; then
    echo "  backend=devfreq max=$(cat /sys/class/kgsl/kgsl-3d0/devfreq/max_freq 2>/dev/null) min=$(cat /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 2>/dev/null)"
  elif [ -r /sys/class/kgsl/kgsl-3d0/max_pwrlevel ]; then
    echo "  backend=pwrlevel max_pwrlevel=$(cat /sys/class/kgsl/kgsl-3d0/max_pwrlevel 2>/dev/null) num=$(cat /sys/class/kgsl/kgsl-3d0/num_pwrlevels 2>/dev/null)"
  else
    echo "  backend=none"
  fi
  echo ""

  # ---- AUDIO: the SKU dir + the files the mixer pass targets -------------
  # mixer_paths*.xml is what the volume/EQ/DAC sed patches edit; the SKU dir is
  # what the HAL actually loads. Knowing which SKU + how many mixer files exist
  # tells the installer the audio patch will land (and on what).
  echo "----- AUDIO -----"
  _audio_sku="$(_gp persist.vendor.audio.sku)"
  [ -n "$_audio_sku" ] || _audio_sku="$(_gp ro.boot.product.hardware.sku)"
  echo "  declared_sku=${_audio_sku:-<none>}"
  _mix_total=0; _eff_total=0; _pol_total=0
  for _r in $_ROOTS; do
    _ad="$_r/etc/audio"
    [ -d "$_ad" ] || continue
    # list any per-SKU subdirs so we can see the real variant names
    _skud="$(find "$_ad" -maxdepth 1 -type d -name 'sku_*' 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
    _mx=$(_count_glob "$_ad" 'mixer_paths*.xml')
    _ef=$(_count_glob "$_ad" 'audio_effects*.xml')
    _ap=$(_count_glob "$_ad" 'audio_policy*.xml')
    _mix_total=$((_mix_total + _mx)); _eff_total=$((_eff_total + _ef)); _pol_total=$((_pol_total + _ap))
    echo "  [$_r/etc/audio] mixer=$_mx effects=$_ef policy=$_ap sku_dirs: ${_skud:-none}"
  done
  echo "  audio_mixer_files_total=$_mix_total"
  echo "  audio_effects_files_total=$_eff_total"
  echo "  audio_patch_targetable=$([ "$_mix_total" -gt 0 ] && echo 1 || echo 0)"
  echo ""

  # ---- CAMERA: presence only (ASB never blind-patches camera; this just
  #      documents whether a camera overlay/clone has anything to act on) ---
  echo "----- CAMERA -----"
  _cam_total=0
  for _r in $_ROOTS; do
    _cd="$_r/etc/camera"
    [ -d "$_cd" ] || continue
    _cn=$(find "$_cd" -type f 2>/dev/null | wc -l | tr -d ' \n')
    _cam_total=$((_cam_total + _cn))
    echo "  [$_r/etc/camera] files=$_cn"
  done
  echo "  camera_files_total=$_cam_total"
  echo "  camera_present=$([ "$_cam_total" -gt 0 ] && echo 1 || echo 0)"
  echo ""

  # ---- MEDIA codecs/profiles (informational;affects video/codec tuning scope) -
  echo "----- MEDIA -----"
  _mc=0; _mp=0
  for _r in $_ROOTS /system /system_ext /product; do
    [ -d "$_r/etc" ] || continue
    _mc=$((_mc + $(_count_glob "$_r/etc" 'media_codecs*.xml')))
    _mp=$((_mp + $(_count_glob "$_r/etc" 'media_profiles*.xml')))
  done
  echo "  media_codecs_files=$_mc"
  echo "  media_profiles_files=$_mp"
  echo ""

  # ---- WIFI: SKU + WCNSS (the wifi patch edits WCNSS_*.ini) --------------
  echo "----- WIFI -----"
  _wcnss=0; _supp=0
  for _r in $_ROOTS; do
    for _wd in "$_r/etc/wifi" "$_r/vendor/etc/wifi"; do
      [ -d "$_wd" ] || continue
      _wc=$(_count_glob "$_wd" 'WCNSS_qcom_cfg*.ini')
      _sp=$(_count_glob "$_wd" 'wpa_supplicant*.conf')
      _wcnss=$((_wcnss + _wc)); _supp=$((_supp + _sp))
      _wsku="$(find "$_wd" -maxdepth 1 -type d -name 'sku_*' 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
      [ "$_wc" -gt 0 ] || [ "$_sp" -gt 0 ] && echo "  [$_wd] wcnss=$_wc supplicant=$_sp sku_dirs: ${_wsku:-none}"
    done
  done
  echo "  wcnss_files_total=$_wcnss"
  echo "  wifi_patch_targetable=$([ "$_wcnss" -gt 0 ] && echo 1 || echo 0)"
  echo ""

  # ---- GPS / PERF / BLUETOOTH presence ----------------------------------
  echo "----- GPS / PERF / BLUETOOTH -----"
  _gps=0; _perf=0; _bt=0
  for _r in $_ROOTS; do
    [ -d "$_r/etc" ] || continue
    _gps=$((_gps + $(_count_glob "$_r/etc" '*gps*.conf')))
    _perf=$((_perf + $(_count_glob "$_r/etc/perf" 'perfconfigstore.xml') + $(_count_glob "$_r/etc/perf" 'qape*config*')))
    _bt=$((_bt + $(_count_glob "$_r/etc" '*bluetooth*.xml') + $(_count_glob "$_r/etc" '*a2dp*.xml')))
  done
  echo "  gps_conf_files=$_gps  (gps_patch_targetable=$([ "$_gps" -gt 0 ] && echo 1 || echo 0))"
  echo "  perf_config_files=$_perf  (perf_patch_targetable=$([ "$_perf" -gt 0 ] && echo 1 || echo 0))"
  echo "  bluetooth_files=$_bt"
  echo ""

  # ---- KEY-LEVEL TUNABILITY -------------------------------------------------
  # The sections above count FILES. This one checks whether the device's own
  # stock files actually contain the specific KEYS each ASB engine patches, so
  # the report reflects what can really be tuned here — not just "a file exists".
  # Every check is a read-only grep of the live stock; nothing is modified. The
  # flat key=value lines let the installer/asbdiag show a precise per-device
  # "ASB tuned: X" manifest instead of a blind attempt.
  echo "----- KEY-LEVEL TUNABILITY (what ASB can actually patch here) -----"

  # camera tone: conf_tuning_params.json with the tonemap keys the grade engine edits
  _cam_conf=""
  for _r in $_ROOTS; do
    for _cc in "$_r/etc/camera/conf_tuning_params.json" "$_r/odm/etc/camera/conf_tuning_params.json"; do
      [ -f "$_cc" ] && { _cam_conf="$_cc"; break; }
    done
    [ -n "$_cam_conf" ] && break
  done
  _cam_keys=0; _cam_keylist=""
  if [ -n "$_cam_conf" ]; then
    for _k in sunsetSatScale blueSatParam nightDownGainParam SatuColorScale low20XcontrastScale skyDarkenScale; do
      if grep -q "\"$_k\"" "$_cam_conf" 2>/dev/null; then _cam_keys=$((_cam_keys+1)); _cam_keylist="$_cam_keylist $_k"; fi
    done
  fi
  echo "  camera_conf_file=${_cam_conf:-<none>}"
  echo "  camera_tonemap_keys_found=$_cam_keys (${_cam_keylist# })"
  echo "  camera_tunable=$([ "$_cam_keys" -gt 0 ] && echo 1 || echo 0)"

  # video_beauty: the retouch-app config the engine edits (telegram entry etc.)
  _vbeauty=""
  for _r in $_ROOTS; do
    for _vb in "$_r/etc/camera/config/video_beauty_default_config" "$_r/odm/etc/camera/config/video_beauty_default_config"; do
      [ -f "$_vb" ] && { _vbeauty="$_vb"; break; }
    done
    [ -n "$_vbeauty" ] && break
  done
  echo "  video_beauty_file=${_vbeauty:-<none>} (tunable=$([ -n "$_vbeauty" ] && echo 1 || echo 0))"

  # audio mixer: the exact control names the mixer patch flips
  _mx_file=""
  for _r in $_ROOTS; do
    _mx_file="$(find "$_r/etc/audio" -type f -name 'mixer_paths*.xml' 2>/dev/null | head -1)"
    [ -n "$_mx_file" ] && break
  done
  _aud_keys=0; _aud_keylist=""
  if [ -n "$_mx_file" ]; then
    grep -q 'Digital Volume' "$_mx_file" 2>/dev/null && { _aud_keys=$((_aud_keys+1)); _aud_keylist="$_aud_keylist digital_volume"; }
    grep -q 'IIR0 Enable Band' "$_mx_file" 2>/dev/null && { _aud_keys=$((_aud_keys+1)); _aud_keylist="$_aud_keylist iir0_eq"; }
    grep -q 'RDAC Switch' "$_mx_file" 2>/dev/null && { _aud_keys=$((_aud_keys+1)); _aud_keylist="$_aud_keylist classh_dac"; }
  fi
  echo "  audio_mixer_file=${_mx_file:-<none>}"
  echo "  audio_patch_keys_found=$_aud_keys (${_aud_keylist# })"
  echo "  audio_tunable=$([ "$_aud_keys" -gt 0 ] && echo 1 || echo 0)"

  # wifi: WCNSS with the power keys the clamp patch lowers
  _wf_file=""
  for _r in $_ROOTS; do
    for _wd in "$_r/etc/wifi" "$_r/vendor/etc/wifi"; do
      _wf_file="$(find "$_wd" -type f -name 'WCNSS_qcom_cfg*.ini' 2>/dev/null | grep -v '/odm/' | head -1)"
      [ -n "$_wf_file" ] && break
    done
    [ -n "$_wf_file" ] && break
  done
  _wf_keys=0
  if [ -n "$_wf_file" ]; then
    for _k in gRuntimePMDelay gActiveMaxChannelTime gBusBandwidthVeryHighThreshold; do
      grep -q "^$_k=" "$_wf_file" 2>/dev/null && _wf_keys=$((_wf_keys+1))
    done
  fi
  echo "  wifi_wcnss_file=${_wf_file:-<none>}"
  echo "  wifi_clamp_keys_found=$_wf_keys"
  echo "  wifi_tunable=$([ "$_wf_keys" -gt 0 ] && echo 1 || echo 0)"

  # media codecs: the audio-unlock patch widens sample-rate/bitrate ranges in the
  # device's own live media_codecs*audio.xml (clone-from-stock, never a shipped
  # file). Detect whether such a file with a constrained range exists to widen.
  _medc=0; _medc_file=""
  for _r in /system /vendor /system_ext /product /odm; do
    _mf="$(find "$_r" -type f -iname 'media_codecs*audio.xml' ! -path '*/vintf/*' ! -path '*/lib*/*' 2>/dev/null | head -1)"
    [ -n "$_mf" ] && { _medc_file="$_mf"; break; }
  done
  if [ -n "$_medc_file" ]; then
    grep -Eq 'name="sample-rate" ranges=|name="bitrate" range=' "$_medc_file" 2>/dev/null && _medc=1
  fi
  echo "  media_codecs_file=${_medc_file:-<none>}"
  echo "  media_codecs_tunable=$_medc"

  # perf: the perf tune clones the device's own stock perf dir and edits it. Just
  # needs a stock perfconfigstore.xml / qapegameconfig.txt to act on.
  _perf_src=""
  for _d in /vendor/etc/perf /odm/etc/perf /system/vendor/etc/perf /system_ext/etc/perf; do
    if [ -f "$_d/perfconfigstore.xml" ] || [ -f "$_d/qapegameconfig.txt" ]; then _perf_src="$_d"; break; fi
  done
  echo "  perf_dir=${_perf_src:-<none>}"
  echo "  perf_tunable=$([ -n "$_perf_src" ] && echo 1 || echo 0)"

  # gps: the location patch edits the device's own gps.conf / izat.conf in place.
  _gps_file=""
  for _r in $_ROOTS; do
    [ -f "$_r/etc/gps.conf" ] && { _gps_file="$_r/etc/gps.conf"; break; }
  done
  echo "  gps_conf=${_gps_file:-<none>}"
  echo "  gps_tunable=$([ -n "$_gps_file" ] && echo 1 || echo 0)"
  echo ""

  echo "----- SUMMARY (what ASB will actually tune on THIS device) -----"
  echo "  audio  : $([ "$_aud_keys" -gt 0 ] && echo "YES ($_aud_keys key group(s):${_aud_keylist# })" || echo "no patchable mixer keys")"
  echo "  wifi   : $([ "$_wf_keys" -gt 0 ] && echo "YES ($_wf_keys clamp key(s))" || echo "no WCNSS keys")"
  echo "  camera : $([ "$_cam_keys" -gt 0 ] && echo "YES ($_cam_keys tone key(s):${_cam_keylist# })" || echo "no conf_tuning tone keys — camera stays stock")"
  echo "  media  : $([ "$_medc" = "1" ] && echo "YES (audio codec ranges widened in device's own file)" || echo "no media_codecs to widen")"
  echo "  perf   : $([ -n "$_perf_src" ] && echo "YES ($_perf_src)" || echo "no stock perf dir")"
  echo "  gps    : $([ -n "$_gps_file" ] && echo "YES" || echo "no gps.conf")"
  echo "  cpu    : $_pc cluster(s) - caps applied as % of each cluster's own hwmax"
  echo ""
  echo "(Inventory only. No stock file was modified by this probe.)"
} > "$OUT" 2>/dev/null

chmod 0644 "$OUT" 2>/dev/null
[ -f "$OUT" ] && echo "asb_install_probe: wrote $OUT" || echo "asb_install_probe: FAILED to write $OUT"
