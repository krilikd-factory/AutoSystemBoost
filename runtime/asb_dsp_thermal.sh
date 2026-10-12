#!/system/bin/sh
# asb_dsp_thermal.sh - sourced, not run. The DSP gain's heat back-off (fix135).
#
# Field report: "loudness, gain and voice only work after I open the WebUI; when I change the
# volume the sound sinks and goes flat; open the WebUI again and it is all back."
#
# The back-off was decided from cpu_max_c - the hottest CPU core at that instant - and only
# when the Smart tuner happened to run: on an app-tier change, a screen change or a CPU heat
# band crossing 50/60 C. The core sensor is the spikiest number on the phone; the volume panel
# animating, the WebView starting or the module's own boot work push it past 55-60 C for a
# second. Whatever it read at that moment was kept until the next tuner run, so +25 dB became
# +12 or +8 dB on a phone whose shell was at 27 C (an OP15 asbdiag: "1200mB (requested 2500) -
# thermal back-off" with skin 27 C and battery 27 C), and only the next app switch - opening
# the WebUI - rolled the dice again. asbdiag had already counted seven captures with the gain
# held down on a die that was back under 55 C.
#
# Now:
# - the battery temperature decides: it follows the heat of the body of the phone, which is
#   what the back-off is for, and it does not jump with a burst of UI work;
# - with hysteresis - one step at 42 C, two at 45 C; back to one step under 43 C and to full
#   gain under 40 C - so a reading near a threshold cannot flip the gain back and forth;
# - only on the loudspeaker. The gain is a number in a multiplication: on Bluetooth the
#   amplifier is in the headphones, on a wired output it drives milliwatts, and the effect
#   costs the same CPU at +8 dB as at +25 dB. Only the speaker's amplifier turns more gain
#   into more heat inside the phone;
# - re-checked once a minute by the DSP route watcher in service.sh, not at random UI moments,
#   and a change is handed to the attach daemon at once (SIGUSR1).
#
# Every writer of the gain (the WebUI apply, the slider fast path, the Smart tuner's mirror and
# the watcher) goes through asb_dsp_thermal_decide, so they cannot disagree.

ASB_DSP_TH_STATE="${ASB_DSP_TH_STATE:-/dev/.asb/dsp_thermal}"
ASB_DSP_TH_BAT="${ASB_DSP_TH_BAT:-/sys/class/power_supply/battery/temp}"

# Battery temperature in tenths of a degree (the power_supply unit), or empty when unreadable or
# implausible. A shell builtin read: no process is started for it.
asb_dsp_th_bat_dc() {
  _tb=""
  [ -r "$ASB_DSP_TH_BAT" ] && read -r _tb < "$ASB_DSP_TH_BAT" 2>/dev/null
  case "$_tb" in ''|*[!0-9-]*|-) echo ""; return 0 ;; esac
  if [ "$_tb" -lt -200 ] 2>/dev/null || [ "$_tb" -gt 800 ] 2>/dev/null; then echo ""; return 0; fi
  echo "$_tb"
}

# asb_dsp_th_step <bat_dC> <previous step> -> 0, 1 or 2. An unknown temperature never reduces.
asb_dsp_th_step() {
  _ts_t="$1"; _ts_p="$2"
  case "$_ts_p" in 1|2) : ;; *) _ts_p=0 ;; esac
  case "$_ts_t" in ''|*[!0-9-]*|-) echo 0; return 0 ;; esac
  case "$_ts_p" in
    0) if [ "$_ts_t" -ge 450 ]; then echo 2; elif [ "$_ts_t" -ge 420 ]; then echo 1; else echo 0; fi ;;
    1) if [ "$_ts_t" -ge 450 ]; then echo 2; elif [ "$_ts_t" -lt 400 ]; then echo 0; else echo 1; fi ;;
    2) if [ "$_ts_t" -lt 400 ]; then echo 0; elif [ "$_ts_t" -lt 430 ]; then echo 1; else echo 2; fi ;;
  esac
}

# asb_dsp_th_cap <requested mB> <step> <route> -> applied mB. Bluetooth, wired and the call
# link are never reduced; an unknown route is treated as the speaker (the cautious side).
asb_dsp_th_cap() {
  _tc_g="$1"; _tc_s="$2"; _tc_r="$3"
  case "$_tc_g" in ''|*[!0-9]*) _tc_g=0 ;; esac
  [ "$_tc_g" -gt 2500 ] && _tc_g=2500
  case "$_tc_r" in bt|wired|call) echo "$_tc_g"; return 0 ;; esac
  case "$_tc_s" in
    2) [ "$_tc_g" -gt 800 ] && _tc_g=800 ;;
    1) [ "$_tc_g" -gt 1200 ] && _tc_g=1200 ;;
  esac
  echo "$_tc_g"
}

# Where media is playing now. The route watcher keeps persist.asb.dsp.route fresh while a
# dsp_outputs filter is set; with "all" nothing does, so the audio service is asked - only
# when the phone is hot enough for the answer to matter.
asb_dsp_th_route() {
  _tr_o="$(getprop persist.asb.dsp.outputs 2>/dev/null)"
  _tr_r="$(getprop persist.asb.dsp.route 2>/dev/null)"
  case "$_tr_o" in
    ''|all) : ;;
    *) [ -n "$_tr_r" ] && { echo "$_tr_r"; return 0; } ;;
  esac
  if command -v dumpsys >/dev/null 2>&1; then
    _tr_d="$(dumpsys audio 2>/dev/null | awk '/^[[:space:]]*- STREAM_MUSIC:/ { m = 1; next }
             m && /^[[:space:]]*- STREAM_/ { exit }
             m && /Devices:/ { print; exit }')"
    case "$_tr_d" in
      *bt_sco*|*BLUETOOTH_SCO*) echo call; return 0 ;;
      *ble_*|*le_audio*|*BLE_*|*bt_a2dp*|*BLUETOOTH_A2DP*|*bt_le*) echo bt; return 0 ;;
      *usb*|*USB*|*wired*|*HEADSET*|*HEADPHONE*|*headset*|*headphone*) echo wired; return 0 ;;
      *speaker*|*SPEAKER*) echo speaker; return 0 ;;
    esac
  fi
  echo "${_tr_r:-unknown}"
}

# Previous step from the state file (tmpfs: every boot starts from full gain).
asb_dsp_th_prev_step() {
  _tp=""
  [ -r "$ASB_DSP_TH_STATE" ] && _tp="$(sed -n 's/^step=//p' "$ASB_DSP_TH_STATE" 2>/dev/null | head -1)"
  echo "$_tp"
}

# asb_dsp_thermal_decide <requested mB> [route] -> applied mB on stdout; records the decision.
asb_dsp_thermal_decide() {
  _td_req="$1"; _td_route="${2:-}"
  case "$_td_req" in ''|*[!0-9]*) _td_req=0 ;; esac
  _td_t="$(asb_dsp_th_bat_dc)"
  _td_step="$(asb_dsp_th_step "$_td_t" "$(asb_dsp_th_prev_step)")"
  if [ "$_td_step" != 0 ] && [ -z "$_td_route" ]; then _td_route="$(asb_dsp_th_route)"; fi
  _td_app="$(asb_dsp_th_cap "$_td_req" "$_td_step" "${_td_route:-unknown}")"
  _td_cap="$_td_req"; [ "$_td_cap" -gt 2500 ] && _td_cap=2500
  if [ "$_td_step" = 0 ]; then
    _td_why=cool
  elif [ "$_td_app" -lt "$_td_cap" ]; then
    _td_why=hot_speaker
  else
    _td_why=hot_not_speaker
  fi
  _td_new="step=$_td_step
bat_dC=${_td_t:-unknown}
route=${_td_route:-not_needed}
requested_mb=$_td_req
applied_mb=$_td_app
reason=$_td_why"
  if [ "$(cat "$ASB_DSP_TH_STATE" 2>/dev/null)" != "$_td_new" ]; then
    mkdir -p "${ASB_DSP_TH_STATE%/*}" 2>/dev/null
    printf '%s\n' "$_td_new" > "$ASB_DSP_TH_STATE.tmp" 2>/dev/null \
      && mv -f "$ASB_DSP_TH_STATE.tmp" "$ASB_DSP_TH_STATE" 2>/dev/null
  fi
  echo "$_td_app"
}

_asb_dsp_th_put() {
  [ "$(getprop "$1" 2>/dev/null)" = "$2" ] && return 1
  if command -v resetprop >/dev/null 2>&1 && resetprop -n "$1" "$2" >/dev/null 2>&1; then return 0; fi
  setprop "$1" "$2" 2>/dev/null
  return 0
}
_asb_dsp_th_put_ctx() {
  [ "$(getprop "$1" 2>/dev/null)" = "$2" ] && return 1
  if command -v resetprop >/dev/null 2>&1 && resetprop "$1" "$2" >/dev/null 2>&1; then return 0; fi
  setprop "$1" "$2" 2>/dev/null
  return 0
}

# Publish an applied gain; wake the attach daemon only when something actually moved.
# Returns 0 when the gain changed.
asb_dsp_thermal_publish() {
  _tpub_ch=1
  _asb_dsp_th_put persist.asb.dsp.gain_applied_mb "$1" || :
  _asb_dsp_th_put persist.asb.dsp.gain_mb "$1" && _tpub_ch=0
  _asb_dsp_th_put_ctx persist.vendor.asb.dsp.gain_mb "$1" && _tpub_ch=0
  if [ "$_tpub_ch" = 0 ]; then
    pkill -USR1 -f asb_dsp_attach 2>/dev/null || killall -USR1 asb_dsp_attach 2>/dev/null || :
  fi
  return "$_tpub_ch"
}

# Once a minute from the route watcher. Cool now and cool at the last check costs one sysfs
# read and one file read - no process, no binder call. The first check after boot always
# looks at the published gain, so a value held down by an older build is released.
asb_dsp_thermal_tick() {
  [ "$(getprop persist.asb.dsp.enable 2>/dev/null)" = "1" ] || return 0
  _tt_prev="$(asb_dsp_th_prev_step)"
  _tt_step="$(asb_dsp_th_step "$(asb_dsp_th_bat_dc)" "$_tt_prev")"
  [ "$_tt_step" = 0 ] && [ "$_tt_prev" = 0 ] && return 0
  _tt_req="$(getprop persist.asb.dsp.gain_requested_mb 2>/dev/null)"
  case "$_tt_req" in
    ''|*[!0-9]*)
      _tt_req="$(grep -E '^[[:space:]]*dsp_loudness=' "${MODDIR:-/data/adb/modules/AutoSystemBoost}/config/governor.conf" 2>/dev/null \
                 | head -1 | sed 's/.*=//' | tr -dc '0-9')"
      case "$_tt_req" in ''|0) return 0 ;; esac
      _tt_req=$((_tt_req * 100)) ;;
  esac
  _tt_app="$(asb_dsp_thermal_decide "$_tt_req")"
  if asb_dsp_thermal_publish "$_tt_app"; then
    command -v asb_log >/dev/null 2>&1 && \
      asb_log "dsp gain ${_tt_app}mB (requested ${_tt_req}) - $(sed -n 's/^reason=//p' "$ASB_DSP_TH_STATE" 2>/dev/null), battery $(sed -n 's/^bat_dC=//p' "$ASB_DSP_TH_STATE" 2>/dev/null) dC"
  fi
  return 0
}
