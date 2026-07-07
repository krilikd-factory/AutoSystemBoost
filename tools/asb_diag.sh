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
    le)      [ -n "$_a" ] && [ "$_a" -le "$_e" ] 2>/dev/null && _st="PASS" ;;
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
# EFFECTIVE STATE — the computed source-of-truth summary.
# This block answers, in one place, the questions that are easy to get
# wrong by reading raw files: is Smart actually on (and from where), who
# owns the CPU caps right now, what the autonomy dial resolves to, and
# which root manager the module is treating as canonical. Everything here
# is DERIVED (read-only) so nobody has to infer it from governor.conf —
# e.g. smart_mode_enabled in the config is only a shipped fallback; the
# real switch is the file-flag, shown explicitly below.
# =====================================================================
SEC "0. EFFECTIVE STATE  (computed source-of-truth — read this first)"
# --- Smart enable: file-flag is truth, config is fallback ---
_sm_flag="$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)"
_sm_cfg="$(cfg smart_mode_enabled)"
if [ -n "$_sm_flag" ]; then
  _sm_eff="$_sm_flag"; _sm_src="file-flag (/data/adb/asb/smart_mode_enabled)"
else
  _sm_eff="${_sm_cfg:-0}"; _sm_src="config-fallback (governor.conf, no file-flag yet)"
fi
[ "$_sm_eff" = "1" ] && _sm_word="ON" || _sm_word="OFF"
P "  smart_mode_effective : $_sm_word  ($_sm_eff)"
P "  smart_mode_source    : $_sm_src"
[ -n "$_sm_cfg" ] && [ -n "$_sm_flag" ] && [ "$_sm_cfg" != "$_sm_flag" ] && \
  NOTE "config says $_sm_cfg but the file-flag ($_sm_flag) wins — config value is just the shipped default."
# --- active profile + who owns the CPU caps right now ---
_prof="$(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
_prof="${_prof:-<unknown>}"
P "  active_profile       : $_prof"
if [ "$_sm_eff" = "1" ] || [ "$_prof" = "smart" ]; then
  _cap_owner="smart (governor/FSM synthesises caps from profile_bounds rails)"
  _fsm_active=1; _manual_active=0; _mode="smart"
else
  case "$_prof" in
    performance) _cap_owner="manual (service.sh — performance leaves clusters uncapped)" ;;
    *)           _cap_owner="manual (service.sh per-device % of cpuinfo_max — _P_CPUCAP_*)" ;;
  esac
  _fsm_active=0; _manual_active=1; _mode="manual"
fi
P "  cpu_cap_owner        : $_cap_owner"
P "  effective_profile_mode: $_mode    (fsm_bounds_active=$_fsm_active manual_caps_active=$_manual_active)"
NOTE "thermal override (writer/governor) can clamp on top of EITHER owner when the SoC runs hot."
# --- autonomy dial: smart_battery_bias resolves to an alpha lean ---
_bias="$(cfg smart_battery_bias)"; _bias="${_bias:-0}"
if [ "$_mode" = "smart" ] && [ "$_bias" -gt 0 ] 2>/dev/null; then
  P "  smart_battery_bias   : $_bias  (battery-lean nudge; scaled by learner confidence, hard-capped at pure-battery)"
  [ "$_bias" -ge 400 ] 2>/dev/null && NOTE "bias >= 400 can pin active-use alpha into battery-like behaviour — Smart then rides the BATTERY rail in profile_bounds.conf."
else
  P "  smart_battery_bias   : $_bias  (0 = no extra lean)"
fi
# --- canonical root manager (single detection, mirrors the module's own logic) ---
_rm="other"
[ -d /data/adb/ap ] && _rm="apatch"
[ -d /data/adb/ksu ] && _rm="ksu"
[ -f /data/adb/magisk/magisk ] && _rm="magisk-like"
P "  root_manager         : $_rm"
[ "$_rm" = "apatch" ] && NOTE "APatch path: OP12 camera handling is scoped specifically for APatch (real /odm mount)."

# =====================================================================
SEC "0a. DEVICE CAPABILITIES  (discovered facts — from device_caps.env)"
_caps="/data/adb/asb/device_caps.env"
if [ -f "$_caps" ]; then
  _cget() { grep -E "^$1=" "$_caps" 2>/dev/null | head -1 | sed 's/^[^=]*=//'; }
  P "  soc / codename       : $(_cget soc_platform) / $(_cget codename)  ($(_cget model))"
  P "  android api / kernel : $(_cget android_api) / $(_cget kernel)"
  P "  cpu policies         : $(_cget cpu_policy_count) clusters [$(_cget cpu_policy_list)]"
  for _pid in $(_cget cpu_policy_list); do
    _hm="$(_cget cpu_policy${_pid}_hwmax)"; _nf="$(_cget cpu_policy${_pid}_nfreq)"
    P "    - policy${_pid}: hw_max=${_hm} kHz, ${_nf} freq steps"
  done
  P "  gpu backend          : $(_cget gpu_backend)"
  P "  thermal zones        : $(_cget thermal_zone_count)"
  P "  paths: odm_camera=$(_cget has_odm_camera_dir) vendor_audio=$(_cget has_vendor_audio_dir) wlan_txqlen=$(_cget has_wlan_txqlen)"
  NOTE "Raw discovered facts. These feed the per-device bounds synthesis below."
else
  P "  (device_caps.env not present yet — run a reinstall, or it writes on next boot)"
fi

# =====================================================================
SEC "0a1. STOCK-FILE INVENTORY  (what was patchable at install — install_probe.txt)"
_probe="/data/adb/asb/install_probe.txt"
if [ -f "$_probe" ]; then
  # Echo the install-time per-subsystem summary (audio/wifi/perf/gps/camera/cpu)
  # plus the declared audio SKU, so a field report shows exactly what ASB found
  # it could tune on this specific model.
  _pl="$(grep -E '^[[:space:]]*declared_sku=' "$_probe" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//')"
  [ -n "$_pl" ] && P "  $_pl"
  # Per-subsystem summary of what ASB actually tuned on THIS model (key-level).
  sed -n '/SUMMARY (what ASB/,/Inventory only/p' "$_probe" 2>/dev/null \
    | grep -E '^[[:space:]]+(audio|wifi|perf|gps|camera|cpu)[[:space:]]+:' \
    | while IFS= read -r _ln; do P "  $_ln"; done
  # Key-level tunability detail (which exact keys exist on this device's stock).
  _ct="$(grep -E '^[[:space:]]*camera_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _at="$(grep -E '^[[:space:]]*audio_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _wt="$(grep -E '^[[:space:]]*wifi_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _mt="$(grep -E '^[[:space:]]*media_codecs_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _pt="$(grep -E '^[[:space:]]*perf_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _gt="$(grep -E '^[[:space:]]*gps_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  if [ -n "$_ct$_at$_wt$_mt$_pt$_gt" ]; then
    P "  tunable: camera=${_ct:-?} audio=${_at:-?} wifi=${_wt:-?} media=${_mt:-?} perf=${_pt:-?} gps=${_gt:-?}"
  fi
  NOTE "Captured at install. Full inventory + key lists: $_probe"
else
  P "  (install_probe.txt not present — written on next install)"
fi

# =====================================================================
SEC "0a2. DEVICE-ADAPTIVE BOUNDS  (OP15-ratio synthesis — device_bounds.env)"
_dbounds="/data/adb/asb/device_bounds.env"
_ovr_flag="$(cfg device_bounds_override)"
P "  override active       : ${_ovr_flag:-0}  (governor consumes device_bounds.env only when =1)"
if [ -f "$_dbounds" ]; then
  _dconf="$(grep -E '^# confidence=' "$_dbounds" 2>/dev/null | head -1 | sed 's/^# confidence=//')"
  P "  synthesis confidence  : ${_dconf:-unknown}"
  _nvals="$(grep -cE '^[A-Z].*=' "$_dbounds" 2>/dev/null)"
  if [ "${_nvals:-0}" -gt 0 ] 2>/dev/null; then
    P "  synthesised bounds (scaled from OP15 ratios, snapped to this device):"
    grep -E '^[A-Z].*=' "$_dbounds" 2>/dev/null | while IFS= read -r _l; do P "    $_l"; done
    if [ "${_ovr_flag:-0}" != "1" ]; then
      NOTE "These are a PREVIEW — not applied (override flag is off). The governor is using its compiled defaults. On OP15 the synthesised values equal those defaults anyway."
    else
      NOTE "ACTIVE: the governor loaded these over its compiled defaults at boot."
    fi
  else
    P "  (no overrides emitted — see confidence note above; compiled defaults stand)"
  fi
else
  P "  (device_bounds.env not present yet — writes at install or next boot)"
fi

# =====================================================================
SEC "0b. MODULE STATE  (running, mounts, governor)"
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
  _vpeak=$(grep -oE '(RX_RX[012]|WSA_RX[01]) Digital Volume" value="[0-9]+"' "$MIX" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
  _vclip=$(grep -c '\(RX_RX[012]\|WSA_RX[01]\) Digital Volume" value="\(9[0-9]\|1[0-9][0-9]\)"' "$MIX" 2>/dev/null)
  _iir=$(grep -c 'IIR0 Enable Band[1-5]" value="1"' "$MIX" 2>/dev/null)
  _rdac=$(grep -c 'HPH[LR]_RDAC Switch" value="1"' "$MIX" 2>/dev/null)
  NOTE "RX/WSA Digital Volume peak: ${_vpeak:-n/a}  (84=0dB unity; SM8650/pineapple caps at 84, sun/canoe accept 88)"
  V "No out-of-range Digital Volume (>88 would break the speaker path)" "0" "$_vclip" eq
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
for _p in persist.audio.hifi persist.audio.uhqa vendor.audio.hifi.dac \
          vendor.audio.feature.hifi_audio.enable \
          persist.vendor.audio.hifi.dac.enable \
          ro.vendor.audio.sdk.fluencetype \
          vendor.audio.offload.buffer.size.kb \
          persist.vendor.audio.ull.period.size; do
  P "    $_p = $(gp $_p)"
done
# AUDIO_EQ_COMPAT toggle state
NOTE "AUDIO_EQ_COMPAT = $(cfg AUDIO_EQ_COMPAT)"

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
  # CAPABILITIES is a hardware capability bitmask that legitimately differs per
  # SoC (OP15 canoe=0x3F, OP12 pineapple=0x17). It must NOT be forced to a fixed
  # value — doing so could advertise GNSS features the chip lacks. Report it as
  # info, not a pass/fail against another device's mask.
  [ -n "$_cap" ] && NOTE "GNSS $_cap (device-native bitmask; not forced)"
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
  # Device-safe clamp semantics: the patch only LOWERS these toward a ceiling and
  # never raises a device that already ships a better (lower) value. So a value
  # at-or-below the ceiling is correct — checking '== ceiling' would wrongly FAIL
  # OP12/OP13 (stock gRuntimePMDelay=500, which is better than the 2000 ceiling).
  [ -n "$_pmd" ] && V "  gRuntimePMDelay<=2000 (lower=quicker idle)" "2000" "$_pmd" le
  [ -n "$_amc" ] && V "  gActiveMaxChannelTime<=40 (lower=shorter dwell)" "40" "$_amc" le
  [ -n "$_bbw" ] && V "  gBusBandwidthVeryHighThreshold<=12000" "12000" "$_bbw" le
done
[ "$_wfound" = 0 ] && { NA=$((NA+1)); P "  [N/A ] no WCNSS_qcom_cfg.ini found"; }
# supplicant safety
SUP="$(firstf '/vendor/etc/wifi/wpa_supplicant_overlay.conf' '/odm/etc/wifi/wpa_supplicant_overlay.conf')"
[ -n "$SUP" ] && V "supplicant keeps p2p_disabled=1 (Wi-Fi-safe)" "1" "$(grep -c 'p2p_disabled=1' "$SUP" 2>/dev/null)" ge
P "  live wifi link: $(dumpsys wifi 2>/dev/null | grep -m1 -iE 'mWifiInfo|SSID' | sed 's/^[[:space:]]*//' | cut -c1-70)"

# =====================================================================
SEC "5. NETWORK / TCP"
P "  net.tcp buffer sizes (live props):"
for _p in net.tcp.buffersize.wifi net.tcp.buffersize.lte net.tcp.buffersize.5g \
          net.tcp.buffersize.default; do
  P "    $_p = $(gp $_p)"
done
P "  kernel tcp:"
P "    rmem_max = $(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
P "    wmem_max = $(cat /proc/sys/net/core/wmem_max 2>/dev/null)"
P "    rmem_default = $(cat /proc/sys/net/core/rmem_default 2>/dev/null)"
P "    congestion = $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
P "    available_congestion = $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
P "    tcp_fastopen = $(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null)"
P "    default_qdisc = $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
# DNS / connectivity props ASB may touch
P "  connectivity props:"
for _p in net.dns1 net.dns2 persist.sys.use_dingtalk_dns ro.ril.disable.power.collapse; do
  P "    $_p = $(gp $_p)"
done

# =====================================================================
SEC "6. CAMERA"
_cam_plat="$(gp ro.board.platform)"
[ -z "$_cam_plat" ] && _cam_plat="$(gp ro.hardware.chipname)"
_is_pineapple=0
case "$_cam_plat" in pineapple|sm8650*) _is_pineapple=1 ;; esac

# --- 6a. Multicamera HAL props (the crash is in ChiMcxRoiTranslator) ---
P "  multicamera / HAL props:"
for _p in \
    ro.vendor.oplus.camera.isHasselbladCamera \
    ro.vendor.oplus.camera.isSupportExplorer \
    persist.vendor.camera.video.4k60.eis.enable \
    persist.vendor.camera.mfnr.enable \
    persist.vendor.camera.multiframe.nr.enable \
    persist.vendor.camera.dual_camera_sat \
    persist.vendor.camera.sat.fallback.dist \
    vendor.camera.aux.packagelist \
    ro.vendor.oplus.camera.backCamSize; do
  P "    $_p = $(gp $_p)"
done
# camera provider service health (the process that SIGABRTs on OP12)
P "  camera provider service: init.svc=$(gp init.svc.vendor.camera-provider) cameraserver=$(gp init.svc.cameraserver)"

# --- 6b. OP12 camera env: must MATCH the proven-working module, and /odm must
#     stay in sync with /vendor/odm (a desync between the two is the prime
#     multicamera-HAL crash suspect on APatch). ---
if [ "$_is_pineapple" = "1" ]; then
  NOTE "platform=$_cam_plat -> OP12: camera overlay should match the known-good module; /odm and /vendor/odm must agree"
  # CRITICAL: compare media_profiles on the real /odm partition vs /vendor/odm.
  # The OP12 HAL reads /odm directly; if the module patched /vendor/odm but not
  # /odm (or vice-versa), the two disagree and multicamera configure_streams can
  # SIGABRT. This is the single most useful camera check on OP12/APatch.
  _mp_odm="/odm/etc/camera/media_profiles.xml"
  _mp_vodm="/vendor/odm/etc/camera/media_profiles.xml"
  _sz_odm="$( [ -f "$_mp_odm" ] && wc -c < "$_mp_odm" 2>/dev/null | tr -d ' ' )"
  _sz_vodm="$( [ -f "$_mp_vodm" ] && wc -c < "$_mp_vodm" 2>/dev/null | tr -d ' ' )"
  P "  media_profiles sizes: /odm=${_sz_odm:-absent}  /vendor/odm=${_sz_vodm:-absent}"
  if [ -n "$_sz_odm" ] && [ -n "$_sz_vodm" ]; then
    if [ "$_sz_odm" = "$_sz_vodm" ]; then
      P "  [PASS] /odm and /vendor/odm media_profiles agree (no desync)"; PASS=$((PASS+1))
    else
      V "  /odm vs /vendor/odm media_profiles DESYNC (HAL crash suspect)" "in-sync" "odm=${_sz_odm}/vodm=${_sz_vodm}" eq
    fi
  fi
  # Owner/timestamp tell us whether the module wrote /vendor/odm directly (group
  # shell + recent date) vs a clean magic-mount. Informational, helps debugging.
  if [ -f "$_mp_vodm" ]; then
    _own="$(ls -l "$_mp_vodm" 2>/dev/null | awk '{print $3":"$4}')"
    P "  /vendor/odm media_profiles owner = ${_own:-?} (root:root = stock/mount, *:shell = module wrote it)"
  fi
  # conf_tuning / video_beauty presence (these SHOULD be present now — we apply
  # the same overlay as the working module, no longer a camera-off).
  for VB in /odm/etc/camera/config/video_beauty_default_config \
            /vendor/odm/etc/camera/config/video_beauty_default_config; do
    [ -f "$VB" ] || continue
    _cm=$(grep -c '//' "$VB" 2>/dev/null)
    if [ "${_cm:-0}" = "0" ]; then
      P "  [PASS] $VB present, strict JSON (no // comments)"; PASS=$((PASS+1))
    else
      V "  $VB has // comments (HAL JSON parser may reject)" "0" "$_cm" eq
    fi
  done
  # multicamera/HAL props that must be live for configure_streams to succeed.
  P "  multicamera props live:"
  for _p in persist.vendor.camera.mfnr.enable ro.vendor.oplus.camera.isSupportExplorer \
            persist.camera.dual_camera_sat persist.vendor.camera.sat.fallback.dist; do
    P "    $_p = $(gp $_p)"
  done
else
  # --- 6c. OP13/OP15: camera overlays SHOULD be applied ---
  for VB in /odm/etc/camera/config/video_beauty_default_config /vendor/odm/etc/camera/config/video_beauty_default_config; do
    [ -f "$VB" ] || continue
    P "  file: $VB"
    _ct_present="$(firstf '/odm/etc/camera/conf_tuning_params.json' '/vendor/odm/etc/camera/conf_tuning_params.json')"
    if [ -n "$_ct_present" ]; then
      V "  retouch app count >= 7" "7" "$(grep -c packageName "$VB" 2>/dev/null)" ge
      V "  Telegram present" "1" "$(grep -c org.telegram.messenger "$VB" 2>/dev/null)" ge
    else
      NA=$((NA+2))
      P "  [N/A ] retouch/Telegram content is OP15 camera-tone specific (no conf_tuning on this model)"
    fi
    V "  strict JSON (no // comments)" "0" "$(grep -c '//' "$VB" 2>/dev/null)" eq
  done
  CT="$(firstf '/odm/etc/camera/conf_tuning_params.json' '/vendor/odm/etc/camera/conf_tuning_params.json')"
  if [ -n "$CT" ]; then
    P "  file: $CT"
    V "  tone-fix sunsetBrightScale=0.9" "0.9" "$(grep -o '"sunsetBrightScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
    # Camera grade is driven by CAMERA_LEVEL (0..4 slider). Legacy CAMERA_AGGRESSIVE=1
    # maps to level 3. Mirror the runtime value table (runtime/asb_tweaks.sh) so the
    # expected sunsetSatScale/blueSatParam match the user's actual level instead of
    # false-FAILing against the old fixed aggressive numbers. The sun SoC bands one
    # level softer, same as runtime.
    _clvl="$(cfg CAMERA_LEVEL)"
    _caggr="$(cfg CAMERA_AGGRESSIVE)"
    if [ -z "$_clvl" ] || [ "$_clvl" = "0" ]; then
      [ "${_caggr:-0}" = "1" ] && _clvl=3 || _clvl=0
    fi
    NOTE "CAMERA_LEVEL = ${_clvl} (legacy CAMERA_AGGRESSIVE=${_caggr:-0} maps to level 3)"
    if [ "${_clvl:-0}" -ge 1 ] 2>/dev/null; then
      _cam_soc="$(getprop ro.board.platform 2>/dev/null)"
      [ -z "$_cam_soc" ] && _cam_soc="$(getprop ro.hardware.chipname 2>/dev/null)"
      _row="$_clvl"
      case "$_cam_soc" in sun|sm8750*) _row=$((_clvl - 1)); [ "$_row" -lt 1 ] && _row=1 ;; esac
      case "$_row" in
        1) _exp_sss="1.45"; _exp_bsat="0.99" ;;
        2) _exp_sss="1.40"; _exp_bsat="1.02" ;;
        3) _exp_sss="1.30"; _exp_bsat="1.05" ;;
        4) _exp_sss="1.20"; _exp_bsat="1.10" ;;
        *) _exp_sss=""; _exp_bsat="" ;;
      esac
      if [ -n "$_exp_sss" ]; then
        V "  grade(lvl$_clvl) sunsetSatScale=$_exp_sss" "$_exp_sss" "$(grep -o '"sunsetSatScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
        _inj="$(cfg CAMERA_AGGRESSIVE_INJECT)"; NOTE "inject mode = ${_inj:-safe}"
        if [ "${_inj:-safe}" = "aggressive" ]; then
          V "  grade(lvl$_clvl) blueSatParam=$_exp_bsat" "$_exp_bsat" "$(grep -o '"blueSatParam": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
        fi
      fi
    fi
  else
    NOTE "conf_tuning_params.json absent"
  fi
  # Read the bitrate from the file the recording pipeline actually uses AND that
  # the module can overlay. On OP15 the camera's own /odm/etc/camera/media_profiles
  # sits on a read-only opex partition the module can't touch, so checking it
  # reports stock and falsely fails — the media framework reads the bitrate from
  # /vendor/etc/media_profiles*.xml, which ASB DOES overlay and lift. Prefer those;
  # fall back to the camera-path copies only if the framework ones are absent.
  CMP="$(firstf '/vendor/etc/media_profiles.xml' '/vendor/etc/media_profiles_V1_0.xml' '/odm/etc/camera/media_profiles.xml' '/vendor/odm/etc/camera/media_profiles.xml')"
  if [ -n "$CMP" ]; then
    _br=$(awk '/quality="1080p"/{f=1} f&&/bitRate=/{match($0,/bitRate="[0-9]+"/);print substr($0,RSTART+9,RLENGTH-10);exit}' "$CMP" 2>/dev/null)
    case "$_cam_plat" in canoe|sm8850*) _bexp=40000000 ;; *) _bexp=37300000 ;; esac
    V "  1080p video bitrate raised" "$_bexp" "$_br" eq
  fi
fi

# =====================================================================
SEC "7. PERFORMANCE / CPU / GPU"
P "  CPU policies (scaling max vs hardware max — shows how hard each cluster is capped):"
# Work out the topology so we can label little / mid / prime, matching the
# governor's own classification (first policy = little, last = prime, anything
# between on a 3+ cluster part = mid workhorse).
_pol_dirs="$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | sort -t'y' -k2 -n)"
_npol="$(echo "$_pol_dirs" | grep -c .)"
_first_pol="$(echo "$_pol_dirs" | head -1)"
_last_pol="$(echo "$_pol_dirs" | tail -1)"
for _pol in $_pol_dirs; do
  [ -d "$_pol" ] || continue
  _cl=$(basename "$_pol")
  _smax=$(cat "$_pol/scaling_max_freq" 2>/dev/null)
  _hmax=$(cat "$_pol/cpuinfo_max_freq" 2>/dev/null)
  _gov=$(cat "$_pol/scaling_governor" 2>/dev/null)
  _pctmax="?"
  if [ -n "$_smax" ] && [ -n "$_hmax" ] && [ "$_hmax" -gt 0 ] 2>/dev/null; then
    _pctmax=$(( _smax * 100 / _hmax ))
  fi
  _tier="big/prime"
  if [ "$_pol" = "$_first_pol" ]; then
    _tier="little"
  elif [ "$_pol" = "$_last_pol" ]; then
    _tier="prime"
  elif [ "$_npol" -ge 3 ]; then
    _tier="mid"
  fi
  P "    $_cl ($_tier): max=${_smax}/${_hmax} kHz (${_pctmax}% of hw) gov=$_gov"
done
_gpu_gov="$(cat /sys/class/kgsl/kgsl-3d0/devfreq/governor 2>/dev/null)"
_gpu_pwr="$(cat /sys/class/kgsl/kgsl-3d0/max_pwrlevel 2>/dev/null)"
_gpu_floor="$(cat /data/adb/asb/gpu_pwrlevel_floor 2>/dev/null)"
if [ -n "$_gpu_gov" ]; then
  P "  GPU: $_gpu_gov  max_pwrlevel=$_gpu_pwr (devfreq-capped)"
else
  # devfreq freq nodes empty (e.g. OP15 Adreno 840) -> ASB caps via pwrlevel.
  P "  GPU: pwrlevel-controlled  max_pwrlevel=$_gpu_pwr${_gpu_floor:+ (vendor floor=$_gpu_floor)}"
fi
NOTE "tier shows the governor's cluster role; %-of-hw shows the active cap. In"
NOTE "performance every cluster should read ~100%; in battery the prime cluster"
NOTE "is capped low while little/mid keep enough headroom to stay smooth."
# Profile-aware sanity. IMPORTANT: scaling_max_freq is managed live by the OEM
# scaling governor (walt/uag), which lowers it under light load even when ASB
# set no cap. So a momentary readout below 90% on performance does NOT mean ASB
# capped it — reading it as a hard FAIL was misleading. We report the live % as
# info, and only flag a REAL problem: on performance, the ceiling shouldn't be
# pinned far below the hardware in a way that persists (we use a generous bar and
# treat it as a soft NOTE); on battery we confirm ASB's cap is taking effect.
_prof_now="$(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
_prime_smax=$(cat "$_last_pol/scaling_max_freq" 2>/dev/null)
_prime_hmax=$(cat "$_last_pol/cpuinfo_max_freq" 2>/dev/null)
_prime_pct="?"
if [ -n "$_prime_smax" ] && [ -n "$_prime_hmax" ] && [ "$_prime_hmax" -gt 0 ] 2>/dev/null; then
  _prime_pct=$(( _prime_smax * 100 / _prime_hmax ))
fi
case "$_prof_now" in
  performance)
    NOTE "performance: prime live scaling_max=${_prime_pct}% of hw (the OEM governor varies this under load; ASB applies NO cap in performance)"
    ;;
  battery)
    # battery SHOULD cap prime. If the live value is already <=70% that confirms
    # ASB's cap; if higher, it may just be the governor sitting high momentarily,
    # so this is a soft check rather than a hard fail.
    if [ "$_prime_pct" != "?" ] && [ "$_prime_pct" -le 70 ] 2>/dev/null; then
      P "  [PASS] battery: prime cluster capped (${_prime_pct}% of hw)"; PASS=$((PASS+1))
    else
      NOTE "battery: prime live scaling_max=${_prime_pct}% of hw (expected <=70%; if this persists under idle, ASB's cap may not be sticking — check the write-test above)"
    fi ;;
  *)
    NOTE "profile=$_prof_now -> prime cluster at ${_prime_pct}% of hw (balanced/smart vary by load)" ;;
esac
# cool gaming
_cool="$(cfg cool_gaming)"; NOTE "cool_gaming toggle = ${_cool:-0}"
QAPE="$(firstf '/vendor/etc/perf/qapegameconfig.txt' '/odm/etc/perf/qapegameconfig.txt')"
[ -n "$QAPE" ] && NOTE "qapegameconfig present: $QAPE" || NOTE "qapegameconfig absent (normal on OP12)"
# thermal
P "  thermal: $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) (zone0 raw)"

# =====================================================================
SEC "7b. MEMORY / LMKD / ZRAM"
# RAM overview
if [ -r /proc/meminfo ]; then
  _memtot=$(grep -m1 MemTotal /proc/meminfo | awk '{print $2}')
  _memfree=$(grep -m1 MemAvailable /proc/meminfo | awk '{print $2}')
  P "  RAM: total=$((${_memtot:-0}/1024))MB available=$((${_memfree:-0}/1024))MB"
  # Detailed breakdown so we can see WHAT occupies RAM (the headline "available"
  # number swings with whatever apps are open at snapshot time, which makes
  # cross-profile comparisons misleading). Cached+Buffers+SReclaimable is
  # reclaimable cache (counts as "used" in some UIs but is free on demand);
  # Active(anon)/Inactive(anon) is real app memory; Shmem is shared/ashmem.
  _mi() { grep -m1 "^$1:" /proc/meminfo 2>/dev/null | awk '{print $2}'; }
  _mb() { echo "$(( ${1:-0} / 1024 ))MB"; }
  _free=$(_mi MemFree); _cached=$(_mi Cached); _buffers=$(_mi Buffers)
  _srecl=$(_mi SReclaimable); _sunrecl=$(_mi SUnreclaim); _shmem=$(_mi Shmem)
  _aanon=$(_mi 'Active(anon)'); _ianon=$(_mi 'Inactive(anon)')
  _afile=$(_mi 'Active(file)'); _ifile=$(_mi 'Inactive(file)')
  _swcached=$(_mi SwapCached); _mapped=$(_mi Mapped); _kreclaim=$(_mi KReclaimable)
  P "    MemFree=$(_mb $_free)  Cached=$(_mb $_cached)  Buffers=$(_mb $_buffers)  SwapCached=$(_mb $_swcached)"
  P "    Active(anon)=$(_mb $_aanon)  Inactive(anon)=$(_mb $_ianon)   <- real app (anon) memory"
  P "    Active(file)=$(_mb $_afile)  Inactive(file)=$(_mb $_ifile)   <- file cache (reclaimable)"
  P "    SReclaimable=$(_mb $_srecl)  SUnreclaim=$(_mb $_sunrecl)  KReclaimable=$(_mb $_kreclaim)  Shmem=$(_mb $_shmem)  Mapped=$(_mb $_mapped)"
  # Derived: reclaimable cache that the kernel can hand back under pressure, vs
  # genuinely committed memory. This is the apples-to-apples figure to compare
  # across profiles, not the raw "available".
  _reclaimable=$(( ${_cached:-0} + ${_buffers:-0} + ${_srecl:-0} ))
  _anon=$(( ${_aanon:-0} + ${_ianon:-0} ))
  P "    => reclaimable cache ~$(_mb $_reclaimable), committed app(anon) ~$(_mb $_anon)"
  NOTE "compare app(anon) across profiles, NOT 'available' — 'available' swings with whatever is open at snapshot time"
fi
# swap / zram
if [ -r /proc/swaps ]; then
  P "  swap devices:"
  tail -n +2 /proc/swaps 2>/dev/null | while read _sn _st _ssz _su _sp; do
    P "    $_sn ($_st) size=$((${_ssz:-0}/1024))MB used=$((${_su:-0}/1024))MB"
  done
fi
for _zr in /sys/block/zram0/comp_algorithm /sys/block/zram0/disksize; do
  [ -r "$_zr" ] && P "    zram $(basename $_zr): $(cat $_zr 2>/dev/null)"
done
# LMKD tunables ASB may touch
P "  LMKD / vmpressure props:"
# OEM system toggles ASB can optionally manage (only when UX_MANAGE_OEM_TOGGLES=1).
# Shown here so we can confirm whether RAM expansion is actually OFF and whether
# the "off" value the OEM uses is really 0 (some builds use a byte/GB size). If
# the user disabled RAM expansion but it reads non-zero after a reboot, OxygenOS
# re-enabled it and they need to turn ON "Manage OEM Toggles" so ASB enforces it.
P "  OEM toggles (managed only if UX_MANAGE_OEM_TOGGLES=1):"
for _ot in ram_expand_size adaptive_battery_management_enabled sem_low_heat_mode; do
  P "    settings global $_ot = $(settings get global $_ot 2>/dev/null)"
done
for _p in ro.lmk.use_psi ro.lmk.thrashing_limit ro.lmk.swap_util_max \
          persist.device_config.lmkd_native.thrashing_limit \
          persist.sys.lmkd.camera_adaptive_lmk.enable; do
  P "    $_p = $(gp $_p)"
done
# kernel VM tunables
P "  kernel VM:"
for _vm in swappiness vfs_cache_pressure watermark_scale_factor; do
  [ -r "/proc/sys/vm/$_vm" ] && P "    vm.$_vm = $(cat /proc/sys/vm/$_vm 2>/dev/null)"
done
# memory cgroup presence (ASB BG_TRIM depends on memcg)
_memcg="$(firstf '/dev/memcg' '/sys/fs/cgroup/memory')"
[ -n "$_memcg" ] && NOTE "memcg present: $_memcg (BG_TRIM can act)" || NOTE "no memcg path (BG_TRIM limited)"
_bgtrim="$(cfg BG_TRIM_LEVEL)"; NOTE "BG_TRIM_LEVEL = ${_bgtrim:-safe}"

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
SEC "10. HARDWARE PROFILE  (for per-SoC governor / profile tuning)"
P "  This section captures the full CPU/GPU/thermal topology so the governor,"
P "  profiles and Smart mode can be tuned individually per SoC (canoe/sun/"
P "  pineapple). The clusters and frequency tables differ per chip, which is why"
P "  one set of battery caps can feel sluggish on OP12 but fine on OP15."
P ""

# --- 10a. CPU cluster topology + full frequency tables ---
P "  CPU CLUSTERS (policy = a cluster; lists every available frequency):"
for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_pol" ] || continue
  _pn=$(basename "$_pol")
  _cpus=$(cat "$_pol/affected_cpus" 2>/dev/null)
  _cmin=$(cat "$_pol/cpuinfo_min_freq" 2>/dev/null)
  _cmax=$(cat "$_pol/cpuinfo_max_freq" 2>/dev/null)
  _smin=$(cat "$_pol/scaling_min_freq" 2>/dev/null)
  _smax=$(cat "$_pol/scaling_max_freq" 2>/dev/null)
  _cur=$(cat "$_pol/scaling_cur_freq" 2>/dev/null)
  _gov=$(cat "$_pol/scaling_governor" 2>/dev/null)
  # Writability of scaling_max_freq: if ASB can't write it, the per-device caps
  # never take effect and the values above are whatever the kernel/OEM set. This
  # is the decisive check when live caps don't match ASB's intended percentages.
  if [ -w "$_pol/scaling_max_freq" ]; then _wf="writable"; else _wf="NOT-writable"; fi
  P "  [$_pn] cpus={$_cpus} gov=$_gov scaling_max=$_wf"
  P "        hw_range : $_cmin .. $_cmax"
  P "        scaling  : min=$_smin max=$_smax cur=$_cur"
  P "        available: $(cat "$_pol/scaling_available_frequencies" 2>/dev/null)"
  # governor tunables that shape responsiveness (schedutil / walt)
  for _t in schedutil/rate_limit_us schedutil/up_rate_limit_us \
            schedutil/down_rate_limit_us schedutil/hispeed_freq \
            walt/target_loads walt/up_rate_limit_us walt/down_rate_limit_us; do
    [ -r "$_pol/$_t" ] && P "        tunable $_t = $(cat "$_pol/$_t" 2>/dev/null)"
  done
  # boost / scaling driver
  [ -r "$_pol/scaling_driver" ] && P "        driver   = $(cat "$_pol/scaling_driver" 2>/dev/null)"
done
P ""
# how many distinct clusters -> tells us the topology class
_ncl=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | wc -l)
NOTE "cluster count = $_ncl  (canoe/sun usually 2 policies for a 6+2; pineapple 4: 1+3+2+1)"
# Show how ASB's governor maps physical policies -> logical slots (little/big/
# prime). On a 4-cluster OP12 the governor now assigns first->little, last->
# prime, all middles->big, and applies the big cap to BOTH middle clusters.
_pol_ids=""
for _pp in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_pp" ] && _pol_ids="$_pol_ids $(basename "$_pp" | sed 's/policy//')"
done
_pol_ids="$(echo $_pol_ids | tr ' ' '\n' | sort -n | tr '\n' ' ')"
P "  governor slot mapping (physical policy -> slot):"
_first=""; _last=""
for _id in $_pol_ids; do [ -z "$_first" ] && _first="$_id"; _last="$_id"; done
for _id in $_pol_ids; do
  if [ "$_id" = "$_first" ]; then P "    policy$_id -> slot0 (little)"
  elif [ "$_id" = "$_last" ]; then P "    policy$_id -> slot2 (prime)"
  else P "    policy$_id -> slot1 (big) [gets BATTERY/BALANCED_CPU_MAX_BIG cap]"; fi
done
# per-core: which cluster + online state
P "  PER-CORE map:"
for _c in /sys/devices/system/cpu/cpu[0-9]*; do
  _cn=$(basename "$_c")
  [ -r "$_c/cpufreq/scaling_cur_freq" ] || continue
  P "    $_cn: online=$(cat "$_c/online" 2>/dev/null || echo 1) cur=$(cat "$_c/cpufreq/scaling_cur_freq" 2>/dev/null)"
done

# --- 10b. CPU capacity / EAS energy model (key for Smart scheduling) ---
P ""
P "  CPU CAPACITY (EAS energy model — relative core strength):"
for _c in /sys/devices/system/cpu/cpu[0-9]*; do
  _cn=$(basename "$_c")
  [ -r "$_c/cpu_capacity" ] && P "    $_cn capacity = $(cat "$_c/cpu_capacity" 2>/dev/null)"
done

# --- 10c. sched / walt knobs ASB's governor reasons about ---
P ""
P "  SCHED / WALT globals:"
for _s in /proc/sys/kernel/sched_util_clamp_min /proc/sys/kernel/sched_util_clamp_max \
          /proc/sys/kernel/sched_schedstats; do
  [ -r "$_s" ] && P "    $(basename $_s) = $(cat $_s 2>/dev/null)"
done
for _wp in /sys/devices/system/cpu/walt/sched_boost \
           /proc/sys/walt/sched_boost; do
  [ -r "$_wp" ] && P "    $(echo $_wp|sed 's#.*/##') = $(cat $_wp 2>/dev/null)"
done
# msm_performance (governor writes cpu_max_freq here)
[ -r /sys/kernel/msm_performance/parameters/cpu_max_freq ] && \
  P "    msm_performance cpu_max_freq = $(cat /sys/kernel/msm_performance/parameters/cpu_max_freq 2>/dev/null)"

# --- 10d. GPU full profile ---
P ""
P "  GPU (Adreno):"
_kg=/sys/class/kgsl/kgsl-3d0
if [ -d "$_kg" ]; then
  P "    model          = $(cat $_kg/gpu_model 2>/dev/null)"
  P "    governor       = $(cat $_kg/devfreq/governor 2>/dev/null)"
  P "    cur_freq       = $(cat $_kg/devfreq/cur_freq 2>/dev/null)"
  P "    min/max_freq   = $(cat $_kg/devfreq/min_freq 2>/dev/null) / $(cat $_kg/devfreq/max_freq 2>/dev/null)"
  P "    available_freq = $(cat $_kg/devfreq/available_frequencies 2>/dev/null)"
  P "    max_pwrlevel   = $(cat $_kg/max_pwrlevel 2>/dev/null)  (num_pwrlevels=$(cat $_kg/num_pwrlevels 2>/dev/null))"
  P "    min_pwrlevel   = $(cat $_kg/min_pwrlevel 2>/dev/null)"
  P "    default_pwr    = $(cat $_kg/default_pwrlevel 2>/dev/null)"
  P "    busy_pct       = $(cat $_kg/gpubusy 2>/dev/null)"
  P "    throttling     = $(cat $_kg/throttling 2>/dev/null)"
  # GPU write-test: does ASB actually control the GPU ceiling, or does the vendor
  # governor (msm-adreno-tz) override it like walt does for CPU? Mirrors the CPU
  # write-test: pick a mid available freq, write devfreq/max_freq, read back,
  # then restore. On devices where devfreq is empty (OP15 Adreno 840) we instead
  # test max_pwrlevel.
  _gdv="$_kg/devfreq"
  if [ -w "$_gdv/max_freq" ] && [ -s "$_gdv/available_frequencies" ]; then
    _g_orig="$(cat "$_gdv/max_freq" 2>/dev/null)"
    _g_try="$(tr ' ' '\n' < "$_gdv/available_frequencies" 2>/dev/null | grep -v '^$' | sort -n | awk 'NR==3{print}')"
    if [ -n "$_g_try" ] && [ "$_g_try" != "$_g_orig" ]; then
      echo "$_g_try" > "$_gdv/max_freq" 2>/dev/null
      _g_read="$(cat "$_gdv/max_freq" 2>/dev/null)"
      if [ "$_g_read" = "$_g_try" ]; then
        P "    [PASS] GPU max_freq write-test: wrote $_g_try, read back $_g_read (ASB CAN cap the GPU)"
      else
        P "    [FAIL] GPU max_freq write-test: wrote $_g_try but read back $_g_read (vendor governor OVERRIDES the GPU cap)"
      fi
      [ -n "$_g_orig" ] && echo "$_g_orig" > "$_gdv/max_freq" 2>/dev/null
    else
      P "    GPU write-test skipped (no distinct available freq)"
    fi
  elif [ -w "$_kg/max_pwrlevel" ]; then
    _p_orig="$(cat "$_kg/max_pwrlevel" 2>/dev/null)"
    _p_try=$(( ${_p_orig:-0} + 1 ))
    echo "$_p_try" > "$_kg/max_pwrlevel" 2>/dev/null
    _p_read="$(cat "$_kg/max_pwrlevel" 2>/dev/null)"
    if [ "$_p_read" = "$_p_try" ]; then
      P "    [PASS] GPU max_pwrlevel write-test: wrote $_p_try, read back $_p_read (ASB CAN cap via pwrlevel)"
    else
      P "    [FAIL] GPU max_pwrlevel write-test: wrote $_p_try but read back $_p_read (vendor OVERRIDES pwrlevel)"
    fi
    [ -n "$_p_orig" ] && echo "$_p_orig" > "$_kg/max_pwrlevel" 2>/dev/null
  fi
else
  NOTE "kgsl-3d0 not found"
fi

# --- 10e. Thermal zones + cooling (why OP12 throttles differently) ---
P ""
P "  THERMAL zones (live temps; governor reads these to back off):"
for _tz in /sys/class/thermal/thermal_zone*; do
  [ -d "$_tz" ] || continue
  _ty=$(cat "$_tz/type" 2>/dev/null)
  _tp=$(cat "$_tz/temp" 2>/dev/null)
  case "$_ty" in
    *cpu*|*gpu*|*skin*|*shell*|*soc*|*battery*|*modem*|*ddr*)
      P "    $(basename $_tz) [$_ty] = $_tp" ;;
  esac
done
# thermal config / mitigation
[ -d /sys/class/thermal/cooling_device0 ] && \
  P "  cooling devices present: $(ls -d /sys/class/thermal/cooling_device* 2>/dev/null | wc -l)"

# --- 10f. Battery state (affects what the battery profile should target) ---
P ""
P "  BATTERY:"
_bp=/sys/class/power_supply/battery
if [ -d "$_bp" ]; then
  P "    capacity   = $(cat $_bp/capacity 2>/dev/null)%"
  P "    status     = $(cat $_bp/status 2>/dev/null)"
  P "    temp       = $(cat $_bp/temp 2>/dev/null)"
  P "    current_now= $(cat $_bp/current_now 2>/dev/null)"
  P "    health     = $(cat $_bp/health 2>/dev/null)"
fi

# --- 10g. ASB governor live state (what it actually decided) ---
P ""
P "  ASB GOVERNOR live state:"
# WRITE-TEST: prove whether ASB can actually set scaling_max_freq on this device.
# We read the current max, write a known available frequency, read it back, then
# restore the original. If readback != what we wrote, the OEM/kernel is rejecting
# or overriding ASB's caps — which fully explains caps that never match ASB's
# intended per-device percentages (and battery-mode jank if caps don't apply).
_wt_pol="/sys/devices/system/cpu/cpufreq/policy0"
if [ -w "$_wt_pol/scaling_max_freq" ]; then
  _wt_orig="$(cat "$_wt_pol/scaling_max_freq" 2>/dev/null)"
  # pick a mid available freq distinct from current
  _wt_try="$(tr ' ' '\n' < "$_wt_pol/scaling_available_frequencies" 2>/dev/null | grep -v '^$' | sort -n | awk 'NR==3{print}')"
  if [ -n "$_wt_try" ] && [ "$_wt_try" != "$_wt_orig" ]; then
    echo "$_wt_try" > "$_wt_pol/scaling_max_freq" 2>/dev/null
    sleep 1
    _wt_read="$(cat "$_wt_pol/scaling_max_freq" 2>/dev/null)"
    if [ "$_wt_read" = "$_wt_try" ]; then
      P "    [PASS] scaling_max write-test: wrote $_wt_try, read back $_wt_read (ASB CAN control caps)"
    else
      P "    [FAIL] scaling_max write-test: wrote $_wt_try but read back $_wt_read (OEM/kernel OVERRIDES ASB caps!)"
    fi
    # restore
    echo "$_wt_orig" > "$_wt_pol/scaling_max_freq" 2>/dev/null
  else
    P "    write-test skipped (no distinct available freq)"
  fi
else
  P "    [FAIL] scaling_max_freq is NOT writable on policy0 (ASB cannot cap CPU here!)"
fi
P "    current_profile = $(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
# smart_mode flag decides whether the governor owns caps (smart) or the shell
# does (manual). If this is 1 while a manual profile is selected, the governor
# may be fighting apply_screen_aware_caps for the cap — the #1 thing to check
# when the live caps don't match the per-device percentages.
_smf="$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)"
P "    smart_mode_enabled flag = ${_smf:-<absent>}"
P "    smart_prev_profile = $(cat /data/adb/asb/smart_prev_profile 2>/dev/null || echo '<absent>')"
for _gp in persist.asb.profile persist.asb.smart.alpha persist.asb.last_plan \
           persist.asb.battery.session persist.asb.smart.state; do
  _gv="$(gp $_gp)"; [ -n "$_gv" ] && P "    $_gp = $_gv"
done
# governor's own log tail (decisions, throttle events). The persistent log is
# the authoritative one; check it plus the volatile copies.
for _lg in /data/adb/asb/governor_persist.log "$MODDIR/asb.log" \
           /data/adb/asb/asb.log /data/local/tmp/asb.log; do
  [ -f "$_lg" ] && { P "    log tail ($_lg):"; tail -12 "$_lg" 2>/dev/null | while IFS= read -r _l; do P "      $_l"; done; break; }
done
# Pull the most recent screen_aware_caps decision (what the shell INTENDED to
# write) so it can be compared against the live %-of-hw readout above. A
# mismatch means something overwrote the shell caps after they were applied.
for _lg in /data/adb/asb/governor_persist.log "$MODDIR/asb.log" /data/adb/asb/asb.log; do
  [ -f "$_lg" ] || continue
  _sac="$(grep "screen_aware_caps:" "$_lg" 2>/dev/null | tail -1)"
  [ -n "$_sac" ] && P "    last screen_aware_caps: $_sac"
  break
done

# --- 10h. profile_bounds the module shipped (compare vs hardware above) ---
P ""
P "  SHIPPED battery rails (compare against hw freqs above):"
# The source profile_bounds.conf is intentionally NOT shipped in the installed
# module (it's a dev/source artifact); what ships is the generated .sh (and the
# values baked into the governor binary). Read whichever is present so this is
# accurate on a real install, not just in the source tree.
_pb=""
for _cand in "$MODDIR/config/profile_bounds.generated.sh" "$MODDIR/config/profile_bounds.conf"; do
  [ -f "$_cand" ] && { _pb="$_cand"; break; }
done
if [ -n "$_pb" ]; then
  P "    (source: $(basename "$_pb"))"
  grep -E '^(BATTERY|BALANCED|PERFORMANCE)_CPU_(MIN|MAX|CAP)_' "$_pb" 2>/dev/null | while IFS= read -r _l; do P "    $_l"; done
else
  NOTE "no shipped bounds file found (generated.sh expected in module/config)"
fi
P ""
P "  >>> TUNING HINT: compare BATTERY_CPU_MAX_* above with each cluster's real"
P "      'available' table. If a battery cap doesn't line up with an actual"
P "      frequency step for THIS SoC's clusters, the governor may be pinning the"
P "      wrong cluster low (the likely cause of OP12 battery-mode sluggishness)."

P "  PASS=$PASS   FAIL=$FAIL   N/A=$NA   info=$INFO"
# Normalized score so devices are comparable. Raw PASS counts mislead (a device
# with more applicable checks, e.g. bt_absvol=on + aggressive toggles, racks up
# more PASS without being "better optimized"). pass_ratio = PASS / applicable.
_applicable=$((PASS + FAIL))
if [ "$_applicable" -gt 0 ]; then
  _ratio=$(( PASS * 100 / _applicable ))
  P "  applicable=$_applicable   pass_ratio=${_ratio}%   (PASS/(PASS+FAIL); N/A & info excluded)"
  P "  >>> Compare devices by pass_ratio, NOT raw PASS — a higher PASS count"
  P "      usually just means more checks applied on that model."
fi
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
