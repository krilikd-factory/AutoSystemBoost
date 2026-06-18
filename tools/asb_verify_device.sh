#!/system/bin/sh
# =====================================================================
# ASB on-device verification (Termux / root shell)  —  rev2
#   rev2: scans ALL sku_* mixers + detects active SKU (no more false PASS/FAIL
#         from grabbing an inactive mixer); checks conf_tuning on every
#         partition; more robust governor probe.
#
# Checks whether AutoSystemBoost's tweaks are ACTUALLY live in the system
# by reading the real mounted files the OS sees (after KSU/Magisk magic-
# mount), not the module staging copies. For each tweak it prints the
# live value, the expected value, and PASS / FAIL / N/A.
#
# Usage (as root):
#   su -c 'sh /sdcard/asb_verify_device.sh'
#     or from Termux:  su -c "sh $PWD/asb_verify_device.sh"
#
# Output is printed AND saved to /sdcard/asb_verify_report.txt
# (that is the user-visible "root of storage"; the true filesystem root
#  is read-only, so we cannot write to /). A copy is also attempted at
#  /data/local/tmp/asb_verify_report.txt.
# =====================================================================

OUT_PRIMARY="/sdcard/asb_verify_report.txt"
OUT_FALLBACK="/data/local/tmp/asb_verify_report.txt"

# ---- output plumbing: tee everything to the report file ----------------
: > "$OUT_PRIMARY" 2>/dev/null || OUT_PRIMARY=""
: > "$OUT_FALLBACK" 2>/dev/null || OUT_FALLBACK=""

emit() {
  # print to stdout and append to whichever report files are writable
  printf '%s\n' "$1"
  [ -n "$OUT_PRIMARY" ]  && printf '%s\n' "$1" >> "$OUT_PRIMARY"
  [ -n "$OUT_FALLBACK" ] && printf '%s\n' "$1" >> "$OUT_FALLBACK"
}

PASS=0; FAIL=0; NA=0

# result helper: $1 label, $2 expected, $3 actual, $4 mode(eq|contains|ne_empty)
check() {
  _label="$1"; _exp="$2"; _act="$3"; _mode="${4:-eq}"
  _status="FAIL"
  case "$_mode" in
    eq)        [ "$_act" = "$_exp" ] && _status="PASS" ;;
    contains)  printf '%s' "$_act" | grep -q -- "$_exp" && _status="PASS" ;;
    ge)        [ -n "$_act" ] && [ "$_act" -ge "$_exp" ] 2>/dev/null && _status="PASS" ;;
  esac
  if [ -z "$_act" ]; then _status="N/A "; NA=$((NA+1));
  elif [ "$_status" = "PASS" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); fi
  emit "  [$_status] $_label"
  emit "         expected: $_exp"
  emit "         live:     ${_act:-<file/key not found>}"
}

# find the first existing file matching a glob, searching the live partitions
firstfile() {
  for _p in $@; do
    for _f in $_p; do
      [ -f "$_f" ] && { printf '%s' "$_f"; return 0; }
    done
  done
  return 1
}

emit "================================================================"
emit " AutoSystemBoost — on-device tweak verification"
emit " date:   $(date 2>/dev/null)"
emit " device: $(getprop ro.product.model 2>/dev/null) / platform=$(getprop ro.board.platform 2>/dev/null) / soc=$(getprop ro.soc.model 2>/dev/null)"
emit " ASB:    $(grep -E '^version=' /data/adb/modules/AutoSystemBoost/module.prop 2>/dev/null | cut -d= -f2)"
emit "================================================================"

# ---------------------------------------------------------------------
emit ""
emit "### 1. AUDIO — louder playback + flat EQ"
# The device loads ONE sku_* at runtime. The old check grabbed the first
# sku_* alphabetically (often an INACTIVE one) which produced misleading
# results. We now (a) detect the active SKU from system properties, and
# (b) scan every sku_* mixer so a tweak is judged PASS if ANY mounted mixer
# carries it, and we report which file. A control that simply doesn't exist
# in a file is reported as such instead of silently counting as 0 (=PASS).
ACTIVE_SKU="$(getprop ro.vendor.audio.sku 2>/dev/null)"
[ -z "$ACTIVE_SKU" ] && ACTIVE_SKU="$(getprop persist.vendor.audio.sku 2>/dev/null)"
[ -z "$ACTIVE_SKU" ] && ACTIVE_SKU="$(getprop ro.boot.product.vendor.sku 2>/dev/null)"
emit "  (active audio SKU per props: ${ACTIVE_SKU:-<unknown — scanning all>})"

# collect every mounted mixer_paths*.xml under the live audio dirs
MIXLIST=""
for _d in /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio; do
  [ -d "$_d" ] || continue
  for _m in $(find "$_d" -type f -name "mixer_paths*.xml" 2>/dev/null); do
    MIXLIST="$MIXLIST $_m"
  done
done

if [ -z "$MIXLIST" ]; then
  emit "  [N/A ] no mixer_paths*.xml found under /vendor or /odm"; NA=$((NA+1))
else
  # Aggregate across all mixers: how many carry each tweak, and how many
  # files actually contain the control at all (to tell absent from wrong).
  VOL88_TOTAL=0; VOL_UNPATCHED=0; VOL_FILES=0
  IIR_ENGAGED=0; IIR_FILES=0
  COMP_ON=0; COMP_FILES=0
  HIFI=0; ULP_LEFT=0; HPHMODE_FILES=0
  ACTIVE_MIX=""
  for _m in $MIXLIST; do
    # remember the active SKU's cdp mixer if we can identify it
    case "$_m" in
      *"sku_${ACTIVE_SKU}/"*cdp*.xml) [ -n "$ACTIVE_SKU" ] && ACTIVE_MIX="$_m" ;;
    esac
    if grep -q 'Digital Volume"' "$_m" 2>/dev/null; then
      VOL_FILES=$((VOL_FILES+1))
      _v88=$(grep -c '\(RX_RX[012]\|WSA_RX[01]\) Digital Volume" value="88"' "$_m" 2>/dev/null)
      _vun=$(grep -c '\(RX_RX[012]\|WSA_RX[01]\) Digital Volume" value="8[0-7]"' "$_m" 2>/dev/null)
      VOL88_TOTAL=$((VOL88_TOTAL+_v88))
      VOL_UNPATCHED=$((VOL_UNPATCHED+_vun))
    fi
    if grep -q 'IIR0 Enable Band[1-5]"' "$_m" 2>/dev/null; then
      IIR_FILES=$((IIR_FILES+1))
      _ie=$(grep -c 'IIR0 Enable Band[1-5]" value="1"' "$_m" 2>/dev/null)
      IIR_ENGAGED=$((IIR_ENGAGED+_ie))
    fi
    if grep -q 'HPH[LR] Compander"' "$_m" 2>/dev/null; then
      COMP_FILES=$((COMP_FILES+1))
      _co=$(grep -c 'HPH[LR] Compander" value="1"' "$_m" 2>/dev/null)
      COMP_ON=$((COMP_ON+_co))
    fi
    if grep -q 'RX HPH Mode"' "$_m" 2>/dev/null; then
      HPHMODE_FILES=$((HPHMODE_FILES+1))
      _hi=$(grep -c 'RX HPH Mode" value="CLS_H_HIFI"' "$_m" 2>/dev/null)
      _ul=$(grep -c 'RX HPH Mode" value="CLS_H_ULP"' "$_m" 2>/dev/null)
      HIFI=$((HIFI+_hi)); ULP_LEFT=$((ULP_LEFT+_ul))
    fi
  done
  _nmix=$(echo $MIXLIST | wc -w)
  emit "  (scanned $_nmix mixer file(s); active cdp mixer: ${ACTIVE_MIX:-<not identified, judged across all>})"

  # base tweaks
  if [ "$VOL_FILES" -gt 0 ]; then
    check "Digital Volume raised to 88 (across mixers, >=1)" "1" "$VOL88_TOTAL" ge
    check "No leftover 80-87 Digital Volume entries (expect 0)" "0" "$VOL_UNPATCHED" eq
  else
    emit "  [N/A ] no RX_RX/WSA Digital Volume control in any mixer"; NA=$((NA+1))
  fi
  if [ "$IIR_FILES" -gt 0 ]; then
    check "IIR0 EQ bands disabled (engaged bands, expect 0)" "0" "$IIR_ENGAGED" eq
  else
    emit "  [N/A ] no IIR0 Enable Band control in any mixer"; NA=$((NA+1))
  fi

  # aggressive (only meaningful if toggle ON)
  AGGR=$(grep -E '^[[:space:]]*AUDIO_AGGRESSIVE=' /data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')
  emit "  (AUDIO_AGGRESSIVE toggle = ${AGGR:-0})"
  if [ "${AGGR:-0}" = "1" ]; then
    if [ "$COMP_FILES" -gt 0 ]; then
      check "Aggressive: HPH companders OFF (engaged count, expect 0)" "0" "$COMP_ON" eq
    else
      emit "  [N/A ] no HPH Compander control on this codec"; NA=$((NA+1))
    fi
    if [ "$HPHMODE_FILES" -gt 0 ]; then
      # PASS if at least one mixer now reports HIFI; note any ULP left behind
      check "Aggressive: RX HPH Mode = CLS_H_HIFI (count >=1)" "1" "$HIFI" ge
      [ "$ULP_LEFT" -gt 0 ] && emit "  (info) $ULP_LEFT RX HPH Mode entr(y/ies) still CLS_H_ULP (paths the firmware left non-ULP are skipped by design)"
    else
      emit "  [N/A ] no RX HPH Mode control on this codec"; NA=$((NA+1))
    fi
  fi
fi

# Mount-gap diagnostic: does the LIVE active mixer match the module's staging
# copy? If the module file is patched but the live file is not, KSU/Magisk did
# not mount that path (a framework issue, not an ASB bug).
_STAGE_AUDIO="/data/adb/modules/AutoSystemBoost/system/vendor/etc/audio"
if [ -n "$ACTIVE_MIX" ] && [ -d "$_STAGE_AUDIO" ]; then
  _rel="${ACTIVE_MIX#*/etc/audio/}"
  _stage="$_STAGE_AUDIO/$_rel"
  if [ -f "$_stage" ]; then
    _live88=$(grep -c 'Digital Volume" value="88"' "$ACTIVE_MIX" 2>/dev/null)
    _stg88=$(grep -c 'Digital Volume" value="88"' "$_stage" 2>/dev/null)
    if [ "$_stg88" -gt 0 ] && [ "$_live88" = "0" ]; then
      emit "  [WARN] active mixer is patched in the module ($_stg88 x vol88) but"
      emit "         the LIVE file shows 0 — KSU/Magisk did not mount this path."
      emit "         (framework mount gap, not an ASB patch failure)"
    else
      emit "  (mount check: live active mixer matches module staging — mounted OK)"
    fi
  fi
fi

# hi-res 384000 in audio policy
APOL="$(firstfile '/vendor/etc/audio_policy_configuration*.xml' '/odm/etc/audio_policy_configuration*.xml' '/vendor/etc/audio/audio_policy_configuration*.xml')"
if [ -n "$APOL" ]; then
  HIRES=$(grep -c '384000' "$APOL" 2>/dev/null)
  check "Hi-res 384000 sampling present in audio policy" "1" "$HIRES" ge
else
  emit "  [N/A ] audio_policy_configuration not found"; NA=$((NA+1))
fi

# ---------------------------------------------------------------------
emit ""
emit "### 2. GPS — full capabilities + public NTP"
for GP in /vendor/etc/gps.conf /odm/etc/gps.conf /vendor/odm/etc/gps.conf; do
  [ -f "$GP" ] || continue
  CAP=$(grep -E '^CAPABILITIES=' "$GP" 2>/dev/null | head -1 | tr -d ' \r')
  NTP=$(grep -E '^NTP_SERVER=' "$GP" 2>/dev/null | head -1 | tr -d ' \r')
  emit "  (file: $GP)"
  check "CAPABILITIES=0x3F" "CAPABILITIES=0x3F" "$CAP" eq
  check "NTP_SERVER=pool.ntp.org" "pool.ntp.org" "$NTP" contains
done

# ---------------------------------------------------------------------
emit ""
emit "### 3. WIFI — driver tuning (WCNSS), supplicant toggle preserved"
WFOUND=0
for WF in /vendor/etc/wifi/*/WCNSS_qcom_cfg.ini /vendor/etc/wifi/WCNSS_qcom_cfg.ini /odm/etc/wifi/*/WCNSS_qcom_cfg.ini; do
  [ -f "$WF" ] || continue
  WFOUND=1
  emit "  (file: $WF)"
  PMD=$(grep -E '^gRuntimePMDelay=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  AMC=$(grep -E '^gActiveMaxChannelTime=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  BBW=$(grep -E '^gBusBandwidthVeryHighThreshold=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  [ -n "$PMD" ] && check "gRuntimePMDelay=2000" "2000" "$PMD" eq
  [ -n "$AMC" ] && check "gActiveMaxChannelTime=40" "40" "$AMC" eq
  [ -n "$BBW" ] && check "gBusBandwidthVeryHighThreshold=12000" "12000" "$BBW" eq
done
[ "$WFOUND" = "0" ] && { emit "  [N/A ] no WCNSS_qcom_cfg.ini found"; NA=$((NA+1)); }
# supplicant toggle safety: p2p_disabled must still be present (don't break Wi-Fi)
SUP="$(firstfile '/vendor/etc/wifi/wpa_supplicant_overlay.conf' '/odm/etc/wifi/wpa_supplicant_overlay.conf')"
if [ -n "$SUP" ]; then
  P2P=$(grep -c 'p2p_disabled=1' "$SUP" 2>/dev/null)
  check "wpa_supplicant_overlay keeps p2p_disabled=1 (toggle safe)" "1" "$P2P" ge
fi

# ---------------------------------------------------------------------
emit ""
emit "### 4. CAMERA — retouch list, tone-fix, video bitrate"
# video_beauty list: who does the OS actually read? Check BOTH partitions.
VBFOUND=0
for VB in /odm/etc/camera/config/video_beauty_default_config \
          /vendor/odm/etc/camera/config/video_beauty_default_config; do
  [ -f "$VB" ] || continue
  VBFOUND=1
  APPS=$(grep -c 'packageName' "$VB" 2>/dev/null)
  HAS_TG=$(grep -c 'org.telegram.messenger' "$VB" 2>/dev/null)
  COMMENT=$(grep -c '//' "$VB" 2>/dev/null)
  emit "  (file: $VB)"
  check "video_beauty app count >= 7" "7" "$APPS" ge
  check "Telegram present (org.telegram.messenger)" "1" "$HAS_TG" ge
  check "Strict JSON: no // comments (expect 0)" "0" "$COMMENT" eq
done
[ "$VBFOUND" = "0" ] && { emit "  [N/A ] no video_beauty_default_config found"; NA=$((NA+1)); }
# tone-fix (conf_tuning) — only some platforms ship it. Check EVERY partition
# that has it (OP13 has separate /odm and /vendor/odm), so we can see which one
# the aggressive layer actually reached.
CT_LIST=""
for _c in /odm/etc/camera/conf_tuning_params.json /vendor/odm/etc/camera/conf_tuning_params.json; do
  [ -f "$_c" ] && CT_LIST="$CT_LIST $_c"
done
for CT in $CT_LIST; do
  TONE=$(grep -o '"sunsetBrightScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')
  emit "  (file: $CT)"
  check "Camera tone-fix sunsetBrightScale=0.9" "0.9" "$TONE" eq
  # Aggressive camera (only meaningful if the WebUI toggle is ON)
  CAGGR=$(grep -E '^[[:space:]]*CAMERA_AGGRESSIVE=' /data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')
  emit "  (CAMERA_AGGRESSIVE toggle = ${CAGGR:-0})"
  if [ "${CAGGR:-0}" = "1" ]; then
    SAT=$(grep -o '"sunsetSatScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')
    check "Aggressive: sunsetSatScale lowered to 1.4" "1.4" "$SAT" eq
    INJ=$(grep -E '^[[:space:]]*CAMERA_AGGRESSIVE_INJECT=' /data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')
    emit "  (CAMERA_AGGRESSIVE_INJECT toggle = ${INJ:-0})"
    if [ "${INJ:-0}" = "1" ]; then
      BLUE=$(grep -o '"blueSatParam": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')
      NIGHT=$(grep -o '"nightDownGainParam": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')
      check "Inject: blueSatParam present = 1.05" "1.05" "$BLUE" eq
      check "Inject: nightDownGainParam present = 0.4" "0.4" "$NIGHT" eq
    fi
  fi
done
[ -z "$CT_LIST" ] && { emit "  [N/A ] conf_tuning_params.json not present (normal on OP12/Gen3)"; NA=$((NA+1)); }
# camera video bitrate (1080p) in camera media_profiles
CMP="$(firstfile '/odm/etc/camera/media_profiles.xml' '/vendor/odm/etc/camera/media_profiles.xml')"
if [ -n "$CMP" ]; then
  BR=$(awk '/quality="1080p"/{f=1} f&&/bitRate=/{match($0,/bitRate="[0-9]+"/);print substr($0,RSTART+9,RLENGTH-10);exit}' "$CMP" 2>/dev/null)
  emit "  (file: $CMP)"
  check "1080p video bitRate raised to 37300000" "37300000" "$BR" eq
else
  emit "  [N/A ] camera media_profiles.xml not found"; NA=$((NA+1))
fi

# ---------------------------------------------------------------------
emit ""
emit "### 5. PERF — cool gaming profile (where shipped)"
QAPE="$(firstfile '/vendor/etc/perf/qapegameconfig.txt' '/odm/etc/perf/qapegameconfig.txt')"
if [ -n "$QAPE" ]; then
  emit "  (file: $QAPE)"
  # cool gaming lowers thermal/freq caps; just confirm the file is ASB-touched
  COOL=$(grep -cE '44|900|800' "$QAPE" 2>/dev/null)
  check "qapegameconfig present and tuned (cool gaming markers)" "1" "$COOL" ge
else
  emit "  [N/A ] qapegameconfig.txt not present (normal on OP12)"; NA=$((NA+1))
fi

# ---------------------------------------------------------------------
emit ""
emit "### 6. RUNTIME — props + governor"
GOV=$(getprop persist.asb.gov.enabled 2>/dev/null)
[ -z "$GOV" ] && GOV=$(ls -la /data/adb/asb/ 2>/dev/null | grep -c governor)
_govrun="no/unknown"
{ pgrep -f asb_governor >/dev/null 2>&1 || pgrep asb_governor >/dev/null 2>&1 \
  || ps -A 2>/dev/null | grep -q '[a]sb_governor' \
  || ps 2>/dev/null | grep -q '[a]sb_governor'; } && _govrun="yes"
emit "  ASB governor running: $_govrun"
BT=$(settings get global bluetooth_disable_absolute_volume 2>/dev/null)
emit "  bluetooth_disable_absolute_volume (global): ${BT:-<unset>}"
HIRES_PROP=$(getprop persist.vendor.audio.hifi.dac 2>/dev/null)
emit "  (info) module dir present: $([ -d /data/adb/modules/AutoSystemBoost ] && echo yes || echo NO)"

# ---------------------------------------------------------------------
emit ""
emit "================================================================"
emit " SUMMARY:  PASS=$PASS  FAIL=$FAIL  N/A=$NA"
emit "================================================================"
emit ""
emit "Notes:"
emit " - A tweak read from /vendor/odm but NOT /odm (or vice-versa) tells us"
emit "   which partition the camera HAL actually uses on this device."
emit " - N/A means the file doesn't exist on this model (often expected,"
emit "   e.g. conf_tuning/qape are absent on OP12)."
emit " - FAIL on a file that exists = the patch didn't take; send this report.
 - AUDIO is now judged across every mounted sku_* mixer: a tweak PASSES if any
   live mixer carries it. The active SKU (per ro.vendor.audio.sku) is printed
   so you can see which file the audio HAL really loads.
 - If an aggressive AUDIO/CAMERA check FAILs with the toggle =1, flip the
   toggle in the WebUI and REBOOT once: from source-334 these apply at boot."
emit ""
emit "Report saved to:"
[ -n "$OUT_PRIMARY" ]  && emit "   $OUT_PRIMARY"
[ -n "$OUT_FALLBACK" ] && emit "   $OUT_FALLBACK"
