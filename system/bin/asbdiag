#!/system/bin/sh
# =====================================================================
#  ASB GLOBAL DIAGNOSTIC  —  AutoSystemBoost full system audit
# =====================================================================
#  Easiest way to run (module installs a launcher on PATH):
#       su -c asbdiag
#
#  Or run the script directly:
#       su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_diag.sh'
#
#  It inspects the LIVE system — the real mounted files and the real
#  runtime properties/settings the OS is using right now — across every
#  area ASB touches: module status, mounts, audio, bluetooth, GPS,
#  Wi-Fi, network/TCP, camera, performance, display, props and the
#  WebUI config. For each item it prints what is LIVE vs what ASB
#  intends, and a verdict.
#
#  The full report is printed AND saved to:
#       /sdcard/asb_diag_report.txt           (storage root)
#       /data/local/tmp/asb_diag_report.txt   (fallback)
#  The real filesystem root (/) is read-only, so "корень телефона"
#  in practice means /sdcard — that's where the file lands.
# =====================================================================

OUT1="/sdcard/asb_diag_report.txt"
OUT2="/data/local/tmp/asb_diag_report.txt"
: > "$OUT1" 2>/dev/null || OUT1=""
: > "$OUT2" 2>/dev/null || OUT2=""

P()  { printf '%s\n' "$1"; [ -n "$OUT1" ] && printf '%s\n' "$1" >> "$OUT1"; [ -n "$OUT2" ] && printf '%s\n' "$1" >> "$OUT2"; }
HR() { P "----------------------------------------------------------------"; }
SEC(){ P ""; P "================================================================"; P " $1"; P "================================================================"; }

PASS=0; FAIL=0; NA=0; INFO=0
# verdict: $1 label  $2 expected  $3 actual  $4 mode(eq|has|ge|present)
V() {
  _l="$1"; _e="$2"; _a="$3"; _m="${4:-eq}"; _st="FAIL"
  case "$_m" in
    eq)      [ "$_a" = "$_e" ] && _st="PASS" ;;
    has)     printf '%s' "$_a" | grep -q -- "$_e" && _st="PASS" ;;
    ge)      [ -n "$_a" ] && [ "$_a" -ge "$_e" ] 2>/dev/null && _st="PASS" ;;
    present) [ -n "$_a" ] && _st="PASS" ;;
  esac
  if [ -z "$_a" ] && [ "$_m" != "eq" ]; then _st="N/A "; NA=$((NA+1));
  elif [ "$_st" = "PASS" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); fi
  P "  [$_st] $_l"
  [ "$_m" != "info" ] && P "         want: $_e   live: ${_a:-<none>}"
}
NOTE(){ P "  (i) $1"; INFO=$((INFO+1)); }

gp() { getprop "$1" 2>/dev/null; }
firstf() { for _g in $@; do for _f in $_g; do [ -f "$_f" ] && { printf '%s' "$_f"; return 0; }; done; done; return 1; }

# ---- module discovery (KSU / APatch / Magisk) ----
MODDIR=""
for _root in /data/adb/modules /data/adb/ap/modules /data/adb/ksu/modules; do
  [ -d "$_root" ] || continue
  for _m in "$_root"/*; do
    [ -f "$_m/module.prop" ] || continue
    grep -q '^id=AutoSystemBoost$' "$_m/module.prop" 2>/dev/null && { MODDIR="$_m"; break; }
  done
  [ -n "$MODDIR" ] && break
done
[ -z "$MODDIR" ] && [ -d /data/adb/modules/AutoSystemBoost ] && MODDIR=/data/adb/modules/AutoSystemBoost
CONF="$MODDIR/config/governor.conf"
cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }

# =====================================================================
P "################################################################"
P "#         AutoSystemBoost — GLOBAL SYSTEM DIAGNOSTIC            #"
P "################################################################"
P " date    : $(date 2>/dev/null)"
P " device  : $(gp ro.product.manufacturer) $(gp ro.product.model)  ($(gp ro.product.device))"
P " android : $(gp ro.build.version.release)  | build $(gp ro.build.id)"
P " platform: $(gp ro.board.platform)  | soc $(gp ro.soc.model)$(gp ro.hardware.chipname)"
P " kernel  : $(uname -r 2>/dev/null)"
_root_mgr="unknown"
[ -d /data/adb/ap ] && _root_mgr="APatch"
[ -d /data/adb/ksu ] && _root_mgr="KernelSU"
[ -f /data/adb/magisk/magisk ] && _root_mgr="Magisk"
P " root    : $_root_mgr"
P " module  : ${MODDIR:-NOT FOUND}"
[ -n "$MODDIR" ] && P " version : $(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)  ($(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2))"

if [ -z "$MODDIR" ]; then
  P ""; P "  !! AutoSystemBoost module not found — is it installed & enabled?"
  P ""; exit 0
fi

# =====================================================================
SEC "0. MODULE STATE  (running, mounts, governor)"
P "  module flags:"
for _fl in disable remove update skip_mount; do
  [ -f "$MODDIR/$_fl" ] && P "    - $_fl present (!!)" || P "    - $_fl absent (ok)"
done
# governor process
_gov_pid="$(pgrep -f 'asb_governor' 2>/dev/null | head -1)"
[ -z "$_gov_pid" ] && _gov_pid="$(pgrep -f '/asb' 2>/dev/null | head -1)"
V "ASB governor process alive" "running" "$([ -n "$_gov_pid" ] && echo running)" present
P "  current profile : $(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
# is module's system actually mounted?
_mounted="$(grep -c "AutoSystemBoost" /proc/mounts 2>/dev/null)"
NOTE "mount entries mentioning the module: ${_mounted:-0}"
# how the overlay arrived
P "  partitions handled by root mgr (from mounts):"
for _pp in vendor odm product system_ext; do
  grep -q " /$_pp " /proc/mounts 2>/dev/null && P "    - /$_pp is a mount point" || P "    - /$_pp not separately mounted"
done

# =====================================================================
SEC "1. AUDIO  (mixer files + runtime props)"
MIX="$(firstf '/vendor/etc/audio/sku_*/mixer_paths_*_cdp.xml' '/odm/etc/audio/sku_*/mixer_paths_*_cdp.xml' '/vendor/etc/audio/mixer_paths*.xml' '/odm/etc/audio/mixer_paths*.xml')"
if [ -n "$MIX" ]; then
  P "  mixer file: $MIX"
  _v88=$(grep -c '\(RX_RX[012]\|WSA_RX[01]\) Digital Volume" value="88"' "$MIX" 2>/dev/null)
  _vlo=$(grep -c '\(RX_RX[012]\|WSA_RX[01]\) Digital Volume" value="8[0-7]"' "$MIX" 2>/dev/null)
  _iir=$(grep -c 'IIR0 Enable Band[1-5]" value="1"' "$MIX" 2>/dev/null)
  _rdac=$(grep -c 'HPH[LR]_RDAC Switch" value="1"' "$MIX" 2>/dev/null)
  NOTE "Digital Volume entries ==88: ${_v88:-0}"
  V "No stock 80-87 Digital Volume left (all raised)" "0" "$_vlo" eq
  V "IIR0 EQ bands flattened (engaged=0)" "0" "$_iir" eq
  V "Class-H headphone DAC armed (RDAC=1 present)" "1" "$_rdac" ge
  # aggressive (toggle)
  _aud_aggr="$(cfg AUDIO_AGGRESSIVE)"
  NOTE "AUDIO_AGGRESSIVE toggle = ${_aud_aggr:-0}"
  if [ "${_aud_aggr:-0}" = "1" ]; then
    _comp=$(grep -c 'HPH[LR] Compander" value="1"' "$MIX" 2>/dev/null)
    _hifi=$(grep -c 'RX HPH Mode" value="CLS_H_HIFI"' "$MIX" 2>/dev/null)
    V "Aggressive: HPH companders OFF (engaged=0)" "0" "$_comp" eq
    V "Aggressive: RX HPH Mode = CLS_H_HIFI" "1" "$_hifi" ge
  fi
else
  NA=$((NA+1)); P "  [N/A ] no mixer_paths*.xml found on /vendor or /odm"
fi
# hi-res
APOL="$(firstf '/vendor/etc/audio_policy_configuration*.xml' '/odm/etc/audio_policy_configuration*.xml' '/vendor/etc/audio/audio_policy_configuration*.xml')"
[ -n "$APOL" ] && V "Hi-res 384000 present in audio policy" "1" "$(grep -c '384000' "$APOL" 2>/dev/null)" ge || NOTE "audio_policy_configuration not found"
# runtime audio props
P "  runtime audio props:"
for _p in persist.audio.hifi persist.audio.uhqa vendor.audio.hifi.dac; do
  P "    $_p = $(gp $_p)"
done

# =====================================================================
SEC "2. BLUETOOTH"
_btmode="$(cfg bt_absvol_mode)"
NOTE "bt_absvol_mode toggle = ${_btmode:-auto}"
P "  live bluetooth props:"
for _p in persist.bluetooth.disableabsvol persist.bluetooth.leaudio.enabled \
          persist.bluetooth.spatial_audio_support persist.bluetooth.enablenewavrcp \
          persist.bluetooth.a2dp_offload.cap; do
  P "    $_p = $(gp $_p)"
done
# global absolute-volume setting
_absvol="$(settings get global bluetooth_disable_absolute_volume 2>/dev/null)"
NOTE "settings global bluetooth_disable_absolute_volume = ${_absvol:-<unset>}"
case "${_btmode:-auto}" in
  on)  V "BT absolute volume disabled (mode=on)" "1" "$_absvol" eq ;;
  off) V "BT absolute volume kept (mode=off)" "0" "$_absvol" eq ;;
  *)   NOTE "BT mode auto — no forced expectation" ;;
esac

# =====================================================================
SEC "3. GPS / LOCATION"
_gfound=0
for GP in /vendor/etc/gps.conf /odm/etc/gps.conf /vendor/odm/etc/gps.conf /system/etc/gps.conf; do
  [ -f "$GP" ] || continue
  _gfound=1
  _cap=$(grep -E '^CAPABILITIES=' "$GP" 2>/dev/null | head -1 | tr -d ' \r')
  _ntp=$(grep -E '^(NTP_SERVER|XTRA_SERVER_1)=' "$GP" 2>/dev/null | head -1 | tr -d ' \r')
  P "  file: $GP"
  V "  CAPABILITIES=0x3F" "CAPABILITIES=0x3F" "$_cap" eq
  [ -n "$_ntp" ] && NOTE "NTP/XTRA: $_ntp"
done
[ "$_gfound" = 0 ] && { NA=$((NA+1)); P "  [N/A ] no gps.conf found in live system"; }

# =====================================================================
SEC "4. WI-FI"
_wfound=0
for WF in /vendor/etc/wifi/*/WCNSS_qcom_cfg.ini /vendor/etc/wifi/WCNSS_qcom_cfg.ini /odm/etc/wifi/*/WCNSS_qcom_cfg.ini; do
  [ -f "$WF" ] || continue
  _wfound=1
  P "  file: $WF"
  _pmd=$(grep -E '^gRuntimePMDelay=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  _amc=$(grep -E '^gActiveMaxChannelTime=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  _bbw=$(grep -E '^gBusBandwidthVeryHighThreshold=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  [ -n "$_pmd" ] && V "  gRuntimePMDelay=2000" "2000" "$_pmd" eq
  [ -n "$_amc" ] && V "  gActiveMaxChannelTime=40" "40" "$_amc" eq
  [ -n "$_bbw" ] && V "  gBusBandwidthVeryHighThreshold=12000" "12000" "$_bbw" eq
done
[ "$_wfound" = 0 ] && { NA=$((NA+1)); P "  [N/A ] no WCNSS_qcom_cfg.ini found"; }
# supplicant safety
SUP="$(firstf '/vendor/etc/wifi/wpa_supplicant_overlay.conf' '/odm/etc/wifi/wpa_supplicant_overlay.conf')"
[ -n "$SUP" ] && V "supplicant keeps p2p_disabled=1 (Wi-Fi-safe)" "1" "$(grep -c 'p2p_disabled=1' "$SUP" 2>/dev/null)" ge
P "  live wifi link: $(dumpsys wifi 2>/dev/null | grep -m1 -iE 'mWifiInfo|SSID' | sed 's/^[[:space:]]*//' | cut -c1-70)"

# =====================================================================
SEC "5. NETWORK / TCP"
P "  net.tcp buffer sizes (live props):"
for _p in net.tcp.buffersize.wifi net.tcp.buffersize.lte net.tcp.buffersize.5g; do
  P "    $_p = $(gp $_p)"
done
P "  kernel tcp:"
P "    rmem_max = $(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
P "    wmem_max = $(cat /proc/sys/net/core/wmem_max 2>/dev/null)"
P "    congestion = $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"

# =====================================================================
SEC "6. CAMERA"
_cam_plat="$(gp ro.board.platform)"
case "$_cam_plat" in
  pineapple|sm8650*) NOTE "platform=$_cam_plat -> ASB intentionally applies NO camera props (OP12 HAL-safe diet)";;
esac
# video_beauty list (read paths the HAL may use)
for VB in /odm/etc/camera/config/video_beauty_default_config /vendor/odm/etc/camera/config/video_beauty_default_config; do
  [ -f "$VB" ] || continue
  P "  file: $VB"
  V "  retouch app count >= 7" "7" "$(grep -c packageName "$VB" 2>/dev/null)" ge
  V "  Telegram present" "1" "$(grep -c org.telegram.messenger "$VB" 2>/dev/null)" ge
  V "  strict JSON (no // comments)" "0" "$(grep -c '//' "$VB" 2>/dev/null)" eq
done
# tone fix + aggressive
CT="$(firstf '/odm/etc/camera/conf_tuning_params.json' '/vendor/odm/etc/camera/conf_tuning_params.json')"
if [ -n "$CT" ]; then
  P "  file: $CT"
  V "  tone-fix sunsetBrightScale=0.9" "0.9" "$(grep -o '"sunsetBrightScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
  _caggr="$(cfg CAMERA_AGGRESSIVE)"; NOTE "CAMERA_AGGRESSIVE toggle = ${_caggr:-0}"
  if [ "${_caggr:-0}" = "1" ]; then
    V "  aggressive sunsetSatScale=1.4" "1.4" "$(grep -o '"sunsetSatScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
    _inj="$(cfg CAMERA_AGGRESSIVE_INJECT)"; NOTE "tone-key mode = ${_inj:-safe}"
    if [ "${_inj:-safe}" = "aggressive" ]; then
      V "  injected blueSatParam=1.05" "1.05" "$(grep -o '"blueSatParam": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
    fi
  fi
else
  NOTE "conf_tuning_params.json absent (normal on OP12/Gen3)"
fi
# media_profiles bitrate
CMP="$(firstf '/odm/etc/camera/media_profiles.xml' '/vendor/odm/etc/camera/media_profiles.xml')"
if [ -n "$CMP" ]; then
  _br=$(awk '/quality="1080p"/{f=1} f&&/bitRate=/{match($0,/bitRate="[0-9]+"/);print substr($0,RSTART+9,RLENGTH-10);exit}' "$CMP" 2>/dev/null)
  case "$_cam_plat" in canoe|sm8850*) _bexp=40000000 ;; *) _bexp=37300000 ;; esac
  V "  1080p video bitrate raised" "$_bexp" "$_br" eq
fi
# any forced camera props live? (should be none on pineapple)
P "  live camera props sample:"
for _p in persist.vendor.camera.mfnr.enable ro.vendor.oplus.camera.isHasselbladCamera persist.vendor.camera.video.4k60.eis.enable; do
  P "    $_p = $(gp $_p)"
done

# =====================================================================
SEC "7. PERFORMANCE / CPU / GPU"
P "  CPU policies (max freq):"
for _pol in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do
  [ -f "$_pol" ] || continue
  _cl=$(echo "$_pol" | grep -oE 'policy[0-9]+')
  P "    $_cl: $(cat "$_pol" 2>/dev/null) (gov $(cat $(dirname "$_pol")/scaling_governor 2>/dev/null))"
done
P "  GPU: $(cat /sys/class/kgsl/kgsl-3d0/devfreq/governor 2>/dev/null || echo n/a)  max_pwrlevel=$(cat /sys/class/kgsl/kgsl-3d0/max_pwrlevel 2>/dev/null)"
# cool gaming
_cool="$(cfg cool_gaming)"; NOTE "cool_gaming toggle = ${_cool:-0}"
QAPE="$(firstf '/vendor/etc/perf/qapegameconfig.txt' '/odm/etc/perf/qapegameconfig.txt')"
[ -n "$QAPE" ] && NOTE "qapegameconfig present: $QAPE" || NOTE "qapegameconfig absent (normal on OP12)"
# thermal
P "  thermal: $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) (zone0 raw)"

# =====================================================================
SEC "8. DISPLAY / UX"
for _p in vendor.display.enable_dpps_dynamic_fps debug.hwui.use_partial_updates persist.sys.hwui.enable_texture_optimize; do
  P "    $_p = $(gp $_p)"
done
P "  animation scales (settings):"
for _s in window_animation_scale transition_animation_scale animator_duration_scale; do
  P "    $_s = $(settings get global $_s 2>/dev/null)"
done

# =====================================================================
SEC "9. WEBUI CONFIG  (governor.conf — what the user selected)"
if [ -f "$CONF" ]; then
  P "  $CONF :"
  grep -vE '^\s*#|^\s*$' "$CONF" 2>/dev/null | while IFS= read -r _line; do P "    $_line"; done
else
  P "  governor.conf not found"
fi

# =====================================================================
SEC "SUMMARY"
P "  PASS=$PASS   FAIL=$FAIL   N/A=$NA   info=$INFO"
P ""
P "  How to read this:"
P "   - PASS  = ASB's change is live in the system."
P "   - FAIL  = a file exists but the value isn't what ASB intended"
P "             (or the camera reads a partition ASB can't overlay, e.g."
P "              /odm on OP12 — see notes by each item)."
P "   - N/A   = that file/feature doesn't exist on this model (often"
P "             expected: conf_tuning/qape are absent on OP12/Gen3)."
P "   - (i)   = informational (toggle states, live props, link info)."
P ""
P "  Report saved to:"
[ -n "$OUT1" ] && P "    $OUT1"
[ -n "$OUT2" ] && P "    $OUT2"
P "################################################################"
