#!/system/bin/sh

MODDIR="${MODDIR:-${0%/*}}"

PROFILE="$(cat "$MODDIR/current_profile" 2>/dev/null || echo balanced)"

_lvl=$(dumpsys battery 2>/dev/null | grep -m1 ' level:' | awk '{print $2}')
_btemp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
_cap_uah=$(cat /sys/class/power_supply/battery/charge_full 2>/dev/null)

_cputemp=0
for z in /sys/class/thermal/thermal_zone*/; do
  tp=$(cat "${z}type" 2>/dev/null)
  case "$tp" in
    cpu-1-1-0|cpu0-silver-usr|cpuss-2-usr|cpu-0-0-0)
      tv=$(cat "${z}temp" 2>/dev/null)
      [ -n "$tv" ] && [ "$tv" -gt 1000 ] 2>/dev/null && _cputemp=$((tv / 1000)) && break
      ;;
  esac
done
if [ "$_cputemp" -eq 0 ]; then
  for z in /sys/class/thermal/thermal_zone*/; do
    tp=$(cat "${z}type" 2>/dev/null)
    case "$tp" in
      *cpu*)
        tv=$(cat "${z}temp" 2>/dev/null)
        if [ -n "$tv" ] && [ "$tv" -gt 1000 ] 2>/dev/null; then
          dc=$((tv / 1000))
          [ "$dc" -gt "$_cputemp" ] && _cputemp=$dc
        fi
        ;;
    esac
  done
fi

if [ -n "$_btemp" ] && [ "$_btemp" -gt 0 ] 2>/dev/null; then
  _btempC=$((_btemp / 10))
  _btempCx=$((_btemp % 10))
else
  _btempC=0
  _btempCx=0
fi

_ewma_x10=$(grep "^smart_drain_ewma_x10=" /dev/.asb/state 2>/dev/null | head -1 | cut -d= -f2)
_on_ma=0
if [ -n "$_ewma_x10" ] && [ "$_ewma_x10" -gt 0 ] 2>/dev/null && \
   [ -n "$_cap_uah" ] && [ "$_cap_uah" -gt 0 ] 2>/dev/null; then
  _on_ma=$(( (_cap_uah / 1000) * _ewma_x10 / 1000 ))
  _eta_note="(measured)"
fi
if [ "$_on_ma" -lt 50 ] 2>/dev/null; then
  case "$PROFILE" in
    performance) _on_ma=650 ;;
    battery)     _on_ma=400 ;;
    *)           _on_ma=500 ;;
  esac
  _eta_note="(heuristic)"
fi
_off_ma=$(( _on_ma / 10 ))
[ "$_off_ma" -lt 40 ] && _off_ma=40
[ "$_off_ma" -gt 90 ] && _off_ma=90

_remain_mah=0
if [ -n "$_cap_uah" ] && [ "$_cap_uah" -gt 0 ] 2>/dev/null && [ -n "$_lvl" ]; then
  _remain_mah=$(( (_cap_uah / 1000) * _lvl / 100 ))
fi

_ton_h=0
_ton_m=0
_toff_h=0
_toff_m=0
if [ "$_remain_mah" -gt 0 ] 2>/dev/null && [ "$_on_ma" -gt 0 ] 2>/dev/null; then
  _ton_min=$(( _remain_mah * 60 / _on_ma ))
  _ton_h=$(( _ton_min / 60 ))
  _ton_m=$(( _ton_min % 60 ))
fi
if [ "$_remain_mah" -gt 0 ] 2>/dev/null && [ "$_off_ma" -gt 0 ] 2>/dev/null; then
  _toff_min=$(( _remain_mah * 60 / _off_ma ))
  _toff_h=$(( _toff_min / 60 ))
  _toff_m=$(( _toff_min % 60 ))
fi

_auto_bat=$(grep -oE '"auto_bat":[01]' /dev/.asb/state 2>/dev/null | head -1 | cut -d: -f2)
_qn_active=$(grep -oE '"qn_active":[01]' /dev/.asb/state 2>/dev/null | head -1 | cut -d: -f2)

_rec_count=0
_rec_disabled=0
_rec_reason=""
if [ -r /dev/.asb/recovery.json ]; then
  _rec_line=$(cat /dev/.asb/recovery.json 2>/dev/null)
  _rec_count=$(echo "$_rec_line" | sed -n 's/.*"recovery_count":\([0-9]*\).*/\1/p')
  _rec_disabled=$(echo "$_rec_line" | sed -n 's/.*"gov_disabled":\([0-9]*\).*/\1/p')
  _rec_reason=$(echo "$_rec_line" | sed -n 's/.*"last_recovery_reason":"\([^"]*\)".*/\1/p')
  case "$_rec_count" in ''|*[!0-9]*) _rec_count=0 ;; esac
  case "$_rec_disabled" in ''|*[!0-9]*) _rec_disabled=0 ;; esac
fi

# Smart Mode status
_smart_enabled=0
_smart_bucket=0
_smart_daypart=0
_smart_we=0
_smart_conf=0
_smart_alpha=500
_smart_fb=4
_smart_app=0
_smart_sleep=0
_smart_veto=0
if [ -r /data/adb/asb/smart_mode_enabled ]; then
  _smart_enabled=$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)
  case "$_smart_enabled" in ''|*[!0-9]*) _smart_enabled=0 ;; esac
fi
if [ "$_smart_enabled" = "1" ] && [ -r /dev/.asb/state ]; then
  _smart_bucket=$(grep -m1 '^smart_bucket_id=' /dev/.asb/state | cut -d= -f2)
  _smart_daypart=$(grep -m1 '^smart_daypart=' /dev/.asb/state | cut -d= -f2)
  _smart_we=$(grep -m1 '^smart_is_weekend=' /dev/.asb/state | cut -d= -f2)
  _smart_conf=$(grep -m1 '^smart_confidence=' /dev/.asb/state | cut -d= -f2)
  _smart_alpha=$(grep -m1 '^smart_alpha_battery=' /dev/.asb/state | cut -d= -f2)
  _smart_fb=$(grep -m1 '^smart_fallback_level=' /dev/.asb/state | cut -d= -f2)
  _smart_app=$(grep -m1 '^smart_app_hint=' /dev/.asb/state | cut -d= -f2)
  _smart_sleep=$(grep -m1 '^smart_sleep_override=' /dev/.asb/state | cut -d= -f2)
  _smart_veto=$(grep -m1 '^smart_thermal_veto=' /dev/.asb/state | cut -d= -f2)
  for _v in _smart_bucket _smart_daypart _smart_we _smart_conf _smart_alpha _smart_fb _smart_app _smart_sleep _smart_veto; do
    eval _val="\$$_v"
    case "$_val" in ''|*[!0-9]*) eval "$_v=0" ;; esac
  done
fi
_daypart_name=""
case "$_smart_daypart" in
  0) _daypart_name="sleep" ;;
  1) _daypart_name="wake" ;;
  2) _daypart_name="morn" ;;
  3) _daypart_name="day" ;;
  4) _daypart_name="evening" ;;
  5) _daypart_name="late" ;;
esac
_we_name=""
[ "$_smart_we" = "1" ] && _we_name=" (weekend)" || _we_name=" (weekday)"

# Everything below is rendered in a PROPORTIONAL font dialog, not a terminal. Box
# frames and space-padded columns cannot line up there (an emoji is two cells wide but
# one character), which is why the old ╭──╮ frame came out ragged. Structure comes from
# blank lines and indentation instead - those survive any font.
echo ""
echo "  🚀  AutoSystemBoost V60"
if [ "$_smart_enabled" = "1" ]; then
  _conf_pct=$((_smart_conf / 10))
  echo "  🤖  Smart · bucket ${_smart_bucket} · ${_daypart_name}${_we_name} · conf ${_conf_pct}%"
  # The profile still matters under Smart: it is the rail the learner moves within, so
  # "Smart" alone does not tell you what the caps are anchored to.
  echo "  🎚  Profile: ${PROFILE} (Smart picks caps within it)"
else
  echo "  🎚  Profile: ${PROFILE} (manual — Smart off)"
fi
_bias="$(grep -E '^[[:space:]]*smart_battery_bias=' "$MODDIR/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ')"
[ -n "$_bias" ] && [ "$_bias" != "0" ] && echo "  ⚖️  Battery lean: $((_bias / 10))%"
if [ "$_rec_disabled" = "1" ]; then
  echo "  ⚠️  SAFE MODE  : governor disabled (${_rec_reason:-recovery})"
elif [ "$_rec_count" -gt 0 ] 2>/dev/null; then
  echo "  ⚠️  Recovery  : ${_rec_count} restart(s) — ${_rec_reason:-unknown}"
fi
echo ""
_cpu_note=""
[ "${_cputemp:-0}" -ge 80 ] 2>/dev/null && _cpu_note="  🔥 hot"
if [ "$_btempC" -gt 0 ]; then
  echo "  🌡  ${_cputemp}°C CPU  ·  ${_btempC}.${_btempCx}°C battery${_cpu_note}"
else
  echo "  🌡  ${_cputemp}°C CPU${_cpu_note}"
fi
echo "  🔋  ${_lvl:-?}%"
[ "$_auto_bat" = "1" ] && echo "  🔻 Auto-battery active"
[ "$_qn_active" = "1" ] && echo "  🌙 Night-quiet active"

if [ "$_smart_enabled" = "1" ]; then
  _alpha_pct=$((_smart_alpha / 10))
  # bucket/daypart/confidence are already on the header line - only print the things
  # that are NOT always true, so the screen stays short and every line carries news.
  [ "$_alpha_pct" != "100" ] && echo "  ⚖️  Battery bias: ${_alpha_pct}%"
  if [ "$_smart_fb" != "0" ]; then
    _fb_name=""
    case "$_smart_fb" in
      1) _fb_name="daypart fallback" ;;
      2) _fb_name="class fallback" ;;
      3) _fb_name="global fallback" ;;
      4) _fb_name="cold start (safe default)" ;;
    esac
    echo "  ↩️  Learning: ${_fb_name}"
  fi
  [ "$_smart_sleep" = "1" ] && echo "  🌙  Night-safe override active"
  [ "$_smart_veto" = "1" ] && echo "  🔥  Thermal veto active"
fi
echo ""
echo "  ⏳  Time to 0% ${_eta_note}"
echo "       ~${_ton_h}h ${_ton_m}m screen on  ·  ~${_toff_h}h ${_toff_m}m idle"

# ── Live state ──────────────────────────────────────────────────────────────────
# Read from the config the daemon reads, not from whatever the WebUI last drew.
_cfg() {
  grep -E "^[[:space:]]*$1=" "$MODDIR/config/governor.conf" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r'
}
_feat() {
  grep -E "^$1=" "$MODDIR/features.conf" 2>/dev/null | tail -1 | sed 's/.*=//' | tr -d ' \r'
}

_a_prof="$(_cfg audio_profile)";  [ -n "$_a_prof" ] || _a_prof="stock"
_a_dac="$(_cfg audio_dac_hifi)"
_a_loud="$(_cfg media_loudness)"; [ -n "$_a_loud" ] || _a_loud="stock"
_a_dsp="$(_cfg dsp_loudness)";    [ -n "$_a_dsp" ]  || _a_dsp="off"
_a_bt="$(_cfg bt_absvol_mode)";   [ -n "$_a_bt" ]   || _a_bt="stock"
_c_lvl="$(_cfg CAMERA_LEVEL)";    [ -n "$_c_lvl" ]  || _c_lvl="0"
_blur="$(_cfg disable_blur)"
_cool="$(_cfg cool_gaming)"
_dsp_so=0
{ [ -f /vendor/lib64/soundfx/libasbdsp.so ] || [ -f /vendor/lib/soundfx/libasbdsp.so ]; } && _dsp_so=1

_st() { grep -m1 "^$1=" /dev/.asb/state 2>/dev/null | cut -d= -f2; }

# Append "$2" to the accumulator "$1", inserting the separator only between real items.
_join() {
  [ -n "$2" ] || { printf '%s' "$1"; return; }
  if [ -n "$1" ]; then printf '%s  ·  %s' "$1" "$2"; else printf '%s' "$2"; fi
}

_g_state="$(_st state)"
_g_owner="$(_st cap_owner)"
_g_cpumax="$(_st cpu_max)"
_g_dwell="$(_st dwell_sec)"
_g_iq="$(_st iq)"
_g_thermal="$(_st thermal)"
_g_head="$(_st headroom_pct)"
if [ -n "$_g_state" ]; then
  echo ""
  echo "  ⚡  GOVERNOR"
  # cap_owner is empty until the governor has taken ownership; saying "unknown" is
  # noise, so just omit it and let the state speak.
  _gl="$_g_state"
  case "$_g_owner" in ''|unknown|none) : ;; *) _gl="$(_join "$_gl" "caps by ${_g_owner}")" ;; esac
  echo "       ${_gl}"

  _gl=""
  [ "${_g_cpumax:-0}" -gt 0 ] 2>/dev/null && _gl="$(_join "$_gl" "CPU max ${_g_cpumax} MHz")"
  [ -n "$_g_dwell" ] && _gl="$(_join "$_gl" "dwell ${_g_dwell}s")"
  [ -n "$_gl" ] && echo "       ${_gl}"

  _gl=""
  [ -n "$_g_iq" ] && _gl="$(_join "$_gl" "environment iq ${_g_iq}")"
  [ -n "$_g_head" ] && _gl="$(_join "$_gl" "headroom ${_g_head}%")"
  [ "${_g_thermal:-0}" != "0" ] && _gl="$(_join "$_gl" "🔥 thermal ${_g_thermal}")"
  [ -n "$_gl" ] && echo "       ${_gl}"
fi

# What the learner has actually accumulated. Worth surfacing: "conf 100%" means little
# on its own - it is the session count behind it that says whether to trust the number.
_l_sess="$(_st hist_sessions)"
_l_q="$(_st smart_quality_last)"
_l_pkg="$(_st smart_pkg)"
_l_drain="$(_st smart_drain_ewma_x10)"
if [ "$_smart_enabled" = "1" ] && [ -n "${_l_sess}${_l_pkg}" ]; then
  echo ""
  echo "  🧠  LEARNING"
  _ll=""
  if [ -n "$_l_sess" ]; then
    # "1 sessions" reads like a bug report. It also matters: one session is not a
    # learned profile, so say so instead of implying confidence.
    [ "$_l_sess" = "1" ] && _ll="1 session learned (still cold)" \
                         || _ll="${_l_sess} sessions learned"
  fi
  [ "${_l_q:-0}" -gt 0 ] 2>/dev/null && _ll="$(_join "$_ll" "last quality ${_l_q}")"
  [ -n "$_ll" ] && echo "       ${_ll}"
  if [ -n "$_l_drain" ] && [ "$_l_drain" -gt 0 ] 2>/dev/null; then
    echo "       drain now: $((_l_drain / 10)).$((_l_drain % 10))%/h"
  fi
  [ -n "$_l_pkg" ] && echo "       foreground: ${_l_pkg}"
fi

echo ""
echo "  🎵  AUDIO"
_audio_l="       ${_a_prof} profile"
[ "$_a_dac" = "1" ] && _audio_l="${_audio_l}  ·  hi-fi DAC"
echo "$_audio_l"
_loud_l="       loudness: ${_a_loud}"
[ "$_a_dsp" != "off" ] && _loud_l="${_loud_l}  ·  DSP +${_a_dsp} dB"
echo "$_loud_l"
[ "$_a_bt" = "disabled" ] && echo "       BT absolute volume: off (phone drives gain)"
if [ "$_a_dsp" != "off" ]; then
  _l64="✗"; _l32="✗"
  [ -f /vendor/lib64/soundfx/libasbdsp.so ] && _l64="✓"
  [ -f /vendor/lib/soundfx/libasbdsp.so ] && _l32="✓"
  echo "       libasbdsp: 64-bit ${_l64}  ·  32-bit ${_l32}"
fi

echo ""
echo "  📷  CAMERA"
_vb_n="$(grep -c '"packageName"' /odm/etc/camera/config/video_beauty_default_config 2>/dev/null)"
_cam_l="processing level ${_c_lvl}"
[ "${_vb_n:-0}" -gt 0 ] 2>/dev/null && _cam_l="$(_join "$_cam_l" "${_vb_n} retouch apps")"
echo "       ${_cam_l}"
_cam_ag="$(_cfg CAMERA_AGGRESSIVE)"
_cam_in="$(_cfg CAMERA_AGGRESSIVE_INJECT)"
_cam_l=""
[ "$_cam_ag" = "1" ] && _cam_l="$(_join "$_cam_l" "aggressive tone")"
case "$_cam_in" in
  full) _cam_l="$(_join "$_cam_l" "inject: full")" ;;
  ''|standard) : ;;
  *) _cam_l="$(_join "$_cam_l" "inject: ${_cam_in}")" ;;
esac
[ -n "$_cam_l" ] && echo "       ${_cam_l}"


echo ""
echo "  🧠  MEMORY"
_bgl="$(_cfg BG_TRIM_LEVEL)"
_ml=""
[ -n "$_bgl" ] && _ml="$(_join "$_ml" "bg trim: level ${_bgl}")"
_swp="$(cat /proc/sys/vm/swappiness 2>/dev/null)"
[ -n "$_swp" ] && _ml="$(_join "$_ml" "swappiness ${_swp}")"
[ -n "$_ml" ] && echo "       ${_ml}"
_mfree="$(grep -m1 MemAvailable /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}')"
_zram="$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{if(t>0) print int((t-f)/1024)}' /proc/meminfo 2>/dev/null)"
_ml=""
[ -n "$_mfree" ] && _ml="$(_join "$_ml" "${_mfree} MB free")"
[ -n "$_zram" ] && _ml="$(_join "$_ml" "zram ${_zram} MB used")"
[ -n "$_ml" ] && echo "       ${_ml}"

if [ "$(_feat NET)" = "1" ]; then
  echo ""
  echo "  🌐  NETWORK"
  _nl=""
  _cc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
  [ -n "$_cc" ] && _nl="$(_join "$_nl" "$_cc")"
  _qd="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
  [ -n "$_qd" ] && _nl="$(_join "$_nl" "$_qd")"
  _nb="$(cat /proc/sys/net/core/netdev_budget 2>/dev/null)"
  [ -n "$_nb" ] && _nl="$(_join "$_nl" "budget ${_nb}")"
  [ -n "$_nl" ] && echo "       TCP: ${_nl}"
  # Which interface is actually carrying traffic - not always rmnet_data0.
  _if="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'dev [a-z0-9_]+' | head -1 | cut -d' ' -f2)"
  if [ -n "$_if" ]; then
    _rx="$(cat "/sys/class/net/$_if/statistics/rx_bytes" 2>/dev/null)"
    _nl="route via ${_if}"
    [ -n "$_rx" ] && _nl="${_nl}  ·  $((_rx / 1048576)) MB rx"
    echo "       ${_nl}"
  fi
fi

if [ "$(_feat WIFI)" = "1" ]; then
  echo ""
  echo "  📶  WI-FI"
# Read what the DRIVER actually ended up with, not `settings get global
# wifi_country_code`. That settings key is telephony-derived and the framework keeps
# rewriting it from the SIM, so it reported the SIM's country (IT) while the module's
# override was live - which looked exactly like the tweak had failed.
# The override lives in WifiService (force-country-code), and WifiCountryCode's dump is
# where you can see both it and what the driver took.
_wifi_dump="$(dumpsys wifi 2>/dev/null)"
_cc_drv="$(echo "$_wifi_dump" | grep -iE 'mDriverCountryCode' | head -1 | grep -oE '[A-Z]{2}[[:space:]]*$' | tr -d ' ')"
_cc_ovr="$(echo "$_wifi_dump" | grep -iE 'mOverrideCountryCode' | head -1 | grep -oE '[A-Z]{2}[[:space:]]*$' | tr -d ' ')"
_cc_tel="$(echo "$_wifi_dump" | grep -iE 'mTelephonyCountryCode' | head -1 | grep -oE '[A-Z]{2}[[:space:]]*$' | tr -d ' ')"
[ -n "$_cc_drv" ] || _cc_drv="$(cmd -w wifi get-country-code 2>/dev/null | grep -oE '[A-Z]{2}' | head -1)"
_cc_forced=0
[ -f /data/adb/asb/wifi_cc_forced ] && _cc_forced=1

if [ -n "$_cc_drv" ]; then
  _wl="       region: ${_cc_drv}"
  [ "$_cc_forced" = "1" ] && _wl="${_wl} (forced)"
  [ -n "$_cc_tel" ] && [ "$_cc_tel" != "$_cc_drv" ] && _wl="${_wl}  ·  SIM says ${_cc_tel}"
  echo "$_wl"
elif [ "$_cc_forced" = "1" ]; then
  echo "       region: forced${_cc_ovr:+ ${_cc_ovr}} (radio off?)"
fi
  _txq="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
  _lnk="$(echo "$_wifi_dump" | grep -m1 -iE 'mWifiInfo|SSID' | grep -oE '[0-9]+Mbps' | head -1)"
  _wl2=""
  [ -n "$_txq" ] && _wl2="$(_join "$_wl2" "txqueue ${_txq}")"
  [ -n "$_lnk" ] && _wl2="$(_join "$_wl2" "link ${_lnk}")"
  [ -n "$_wl2" ] && echo "       ${_wl2}"
fi

if [ "$(_feat GPS)" = "1" ]; then
  echo ""
  echo "  🛰  GPS"
  _agps="$(settings get global assisted_gps_enabled 2>/dev/null)"
  _gl=""
  case "$_agps" in 1) _gl="$(_join "$_gl" "A-GPS on")" ;; 0) _gl="$(_join "$_gl" "A-GPS off")" ;; esac
  _xtra="$(settings get global gps_xtra_server 2>/dev/null)"
  case "$_xtra" in *gpsonextra*) _gl="$(_join "$_gl" "XTRA servers set")" ;; esac
  [ -n "$_gl" ] && echo "       ${_gl}"
fi

echo ""
echo "  ⚙️  SYSTEM"
_sys_l="       blur: $([ "$_blur" = "1" ] && echo off || echo stock)"
_sys_l="${_sys_l}  ·  cool games: $([ "$_cool" = "1" ] && echo on || echo off)"
echo "$_sys_l"

# Every category, not the six that happened to be hard-coded here. Wrapped by hand
# because a single 20-item line is unreadable on a phone.
_cats=""; _catn=0; _catline=""
for _c in CPU VM AUDIO BT NFC CAMERA MEDIA NET WIFI GPS KERNEL LOG LPM \
          RADIO_IMS DISPLAY FPS SECURITY BG_TRIM VENDOR_OVERLAY SOTER_REPAIR; do
  [ "$(_feat "$_c")" = "1" ] || continue
  _catline="$(_join "$_catline" "$_c")"
  _catn=$((_catn + 1))
  if [ "$_catn" -ge 5 ]; then
    echo "       ${_catline}"
    _catline=""; _catn=0
  fi
done
[ -n "$_catline" ] && echo "       ${_catline}"
_mnt="$(grep -c 'AutoSystemBoost' /proc/mounts 2>/dev/null)"
_krn="$(uname -r 2>/dev/null | cut -d- -f1)"
_sysl="       overlay: ${_mnt:-0} mount$([ "${_mnt:-0}" = "1" ] || echo s)"
[ -n "$_krn" ] && _sysl="${_sysl}  ·  kernel ${_krn}"
_up="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
if [ -n "$_up" ]; then
  _sysl="${_sysl}  ·  up $((_up / 3600))h $(((_up % 3600) / 60))m"
fi
echo "$_sysl"


# ── Anything that is set but not actually working ───────────────────────────────
# This is the part worth having on screen: a setting that silently does nothing is
# invisible everywhere else, and "DSP +9 dB" next to a missing library is exactly the
# kind of thing a user reports as "the module does nothing".
_warn=0
if [ "$_a_dsp" != "off" ] && [ "$_dsp_so" = "0" ]; then
  [ "$_warn" = "0" ] && echo ""
  _warn=1
  echo "  ⚠️  DSP is set to +${_a_dsp} dB but libasbdsp.so is not installed."
  echo "       Reinstall the module to activate it."
fi
if [ "$_a_dsp" = "off" ] && [ "$_a_loud" = "stock" ] && [ "$_a_prof" = "stock" ]; then
  [ "$_warn" = "0" ] && echo ""
  _warn=1
  echo "  💡  All audio tweaks are at stock — nothing is being changed."
fi

echo ""
echo "  ─────────────────────────────"
echo "  💬  Opening Telegram…"
echo ""

am start -a android.intent.action.VIEW -d "tg://resolve?domain=AutoSystemBoost" >/dev/null 2>&1 \
  || am start -a android.intent.action.VIEW -d "https://t.me/AutoSystemBoost" >/dev/null 2>&1

exit 0
