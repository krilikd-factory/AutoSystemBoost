#!/system/bin/sh
# Prefer LTE while the screen is off.  Opt-in (net_screen_off_lte=1), default OFF.
#
# Why: captures show this phone on LTE + 5G NSA most of the time (4 of 6 snapshots), and
# the costly screen-off case is listening to a stream - 47 MiB in 11 minutes with the
# display dark. NSA runs two radios at once; a screen-off audio stream needs nowhere near
# what an LTE link alone carries. Dropping the NR leg while nobody is looking is the
# saving.
#
# Why opt-in and careful: this changes the modem's allowed network types, and the switch
# re-registers the data connection. Done at the wrong moment it can drop a call or stall
# a download for a few seconds. So:
#   - only after the screen has been off for DELAY seconds (brief glances never trigger);
#   - never during a call;
#   - only the default-data SIM, only if NR is currently allowed;
#   - the exact previous mask is saved and put back on screen-on, on toggle-off, at boot
#     and on uninstall - the allowed-types setting survives a reboot, so a phone restarted
#     while this was applied would otherwise stay off 5G for good;
#   - every write is read back. If the readback does not show the expected result the
#     original is restored and the device is marked unsupported, after which this does
#     nothing until the marker is removed.
#
# Uses the platform's own interface, `cmd phone set/get-allowed-network-types-for-users`,
# the same one the Settings 5G switch drives. No properties, no modem files.
#
# Second mode, net_lte_light (fix114): "5G only when it is needed" with the screen ON.
#   An OP15 capture (24817) spent 80 min on BT audio + feeds with the screen on at 12 %/h,
#   moving 512 MiB over mobile data - about 0.9 Mbit/s on average - on LTE + 5G NSA. NSA
#   keeps the LTE anchor AND the NR leg up for that trickle, and its tail timers keep both
#   awake between bursts. A watcher samples the mobile interfaces every 30 s while the
#   screen is on: after 3 minutes under 4 Mbit/s it drops the NR leg (same save/verify/
#   restore path as the screen-off mode, recorded as reason "light"); any 30 s window over
#   12 Mbit/s gives 5G back at once and holds it for 10 minutes. Never during a call,
#   tethering, a game in front, or on Wi-Fi. Opt-in, off by default.
#
# Commands: arm | apply | restore | screen_on | status | nr

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
# `settings` through the fallback wrapper: on some OnePlus builds the cmd bridge answers
# "Failure calling service settings: Failed transaction" while exiting 0, and a script run
# as its own process does not inherit the wrapper from service.sh.
[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"
# Overridable only so the uninstaller can run a deferred restore from a staged copy after
# /data/adb/asb is gone (see uninstall.sh). Normal callers never set it.
STATE_DIR="${ASB_LTE_STATE_DIR:-/data/adb/asb}"
SAVE="$STATE_DIR/lte_screenoff.saved"          # subid|decimal_mask
PIDF="$STATE_DIR/lte_screenoff.pid"
UNSUP="$STATE_DIR/lte_screenoff.unsupported"
LOGF="$STATE_DIR/lte_screenoff.log"
# applies|restores|seconds_on_lte - what an A/B needs: how often it engaged and for how long.
STATS="$STATE_DIR/lte_screenoff.stats"
SINCE="$STATE_DIR/lte_screenoff.since"
DELAY="${ASB_LTE_DELAY_S:-90}"
RETRYF="$STATE_DIR/lte_screenoff.retry"
RETRY_S="${ASB_LTE_RETRY_S:-300}"
RETRY_MAX=24
NR_BIT=524288                                   # 1 << (NETWORK_TYPE_NR - 1)
LPIDF="$STATE_DIR/lte_light.pid"                 # light-traffic watcher (screen on)
LHOLD="$STATE_DIR/lte_light.hold"               # epoch before which light must not re-apply
LIGHT_LOW_KBPS="${ASB_LTE_LIGHT_LOW_KBPS:-4000}"
LIGHT_HIGH_KBPS="${ASB_LTE_LIGHT_HIGH_KBPS:-12000}"
LIGHT_TICK_S="${ASB_LTE_LIGHT_TICK_S:-30}"
LIGHT_LOW_TICKS="${ASB_LTE_LIGHT_LOW_TICKS:-6}"
LIGHT_HOLD_S="${ASB_LTE_LIGHT_HOLD_S:-600}"

mkdir -p "$STATE_DIR" 2>/dev/null

# Two lines per screen cycle is a few hundred a day, forever. Keep the tail only.
_stats_add() {   # <applies> <restores> <seconds>
  _sa=0; _sr=0; _ss=0
  [ -f "$STATS" ] && IFS='|' read -r _sa _sr _ss < "$STATS"
  case "$_sa$_sr$_ss" in *[!0-9]*|'') _sa=0; _sr=0; _ss=0 ;; esac
  printf '%s|%s|%s\n' $((_sa + $1)) $((_sr + $2)) $((_ss + $3)) > "$STATS" 2>/dev/null
}
_log() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$LOGF" 2>/dev/null
  _ls="$(wc -c < "$LOGF" 2>/dev/null)"
  if [ "${_ls:-0}" -gt 65536 ] 2>/dev/null; then
    tail -n 300 "$LOGF" > "$LOGF.tmp" 2>/dev/null && mv -f "$LOGF.tmp" "$LOGF" 2>/dev/null
  fi
}
_cfg() { grep -m1 "^$1=" "$MODDIR/config/governor.conf" 2>/dev/null | cut -d= -f2 | tr -d '\r '; }

_cmd_phone() {
  if command -v cmd >/dev/null 2>&1; then cmd phone "$@"
  elif [ -x /system/bin/cmd ]; then /system/bin/cmd phone "$@"
  else return 1; fi
}

# The SLOT of the SIM that carries data, or "d" for the platform default.
#
# `cmd phone ... -s N` takes a SIM slot index (0, 1), not a subscription id - the shell
# command maps the slot to its subscription itself. The first version passed the data
# subscription id from multi_sim_data_call (1, 2, ... on most phones), which addresses the
# wrong slot or an empty one; the readback then failed and the feature marked itself
# "unsupported" on a ROM that supports it fine.
#
# The slot comes from the subscription service's own dump, which prints each active
# subscription with its id and simSlotIndex. When that cannot be read, "d" leaves -s off
# and the command uses the default subscription - right on every single-SIM phone.
_data_slot() {
  _s="$(settings get global multi_sim_data_call 2>/dev/null | tr -dc '0-9-')"
  case "$_s" in ''|-*) return 1 ;; esac
  _sl="$(dumpsys isub 2>/dev/null | tr -d '\r' \
         | grep -E "(^|[^A-Za-z])id=${_s}([^0-9]|$)" | grep -m1 -oE 'simSlotIndex=[0-9]+' | cut -d= -f2)"
  case "$_sl" in ''|*[!0-9]*) _sl=d ;; esac
  printf '%s' "$_sl"
}

# Slot argument for cmd phone: none for "d".
_slot_args() { [ "$1" = "d" ] || printf -- '-s %s' "$1"; }

# Type name -> bit, AOSP TelephonyManager.NETWORK_TYPE_* (bit = 1 << (id-1)).
#
# The shell prints TelephonyManager.getNetworkTypeName(), and several of those names have
# spaces and lower case in them - "CDMA - EvDo rev. 0", "iDEN", "HSPA+". The name arrives
# here upper-cased with spaces removed, so both spellings are listed. An unknown name still
# fails: rebuilding a mask with a guessed bit could take away a network on restore.
_name_bit() {
  case "$1" in
    GPRS) echo 1 ;; EDGE) echo 2 ;; UMTS) echo 4 ;; CDMA) echo 8 ;;
    EVDO_0|CDMA-EVDOREV.0) echo 16 ;; EVDO_A|CDMA-EVDOREV.A) echo 32 ;;
    1XRTT|CDMA-1XRTT) echo 64 ;; HSDPA) echo 128 ;;
    HSUPA) echo 256 ;; HSPA) echo 512 ;; IDEN) echo 1024 ;; EVDO_B|CDMA-EVDOREV.B) echo 2048 ;;
    LTE) echo 4096 ;; EHRPD|CDMA-EHRPD) echo 8192 ;; HSPAP|HSPA+) echo 16384 ;; GSM) echo 32768 ;;
    TD_SCDMA|TD-SCDMA) echo 65536 ;; IWLAN) echo 131072 ;; LTE_CA|LTE-CA) echo 262144 ;; NR) echo 524288 ;;
    UNKNOWN) echo 0 ;;
    *) echo -1 ;;
  esac
}

# Read the allowed mask as a decimal number. Accepts the three shapes ROMs print:
# a "GSM|LTE|NR" name list, a binary string, or a plain decimal. Anything else fails.
_get_mask() {
  # shellcheck disable=SC2046
  _o="$(_cmd_phone get-allowed-network-types-for-users $(_slot_args "$1") 2>/dev/null | tr -d '\r' | tail -n 1)"
  _o="$(printf '%s' "$_o" | sed 's/^[^:]*: *//; s/ //g' | tr '[:lower:]' '[:upper:]')"
  case "$_o" in
    '') return 1 ;;
    *[!01]*) : ;;
    *) # Base-2 by hand: "$((2#...))" exists in mksh but is a parse error elsewhere, and
       # an arithmetic error can abort the whole script mid-change.
       _v=0; _r="$_o"
       while [ -n "$_r" ]; do _c="${_r%"${_r#?}"}"; _r="${_r#?}"; _v=$(( _v * 2 + _c )); done
       printf '%s' "$_v"; return 0 ;;
  esac
  case "$_o" in
    *[!0-9]*) : ;;
    *) printf '%s' "$_o"; return 0 ;;
  esac
  _v=0
  _old_ifs="$IFS"; IFS='|'
  for _n in $_o; do
    _b="$(_name_bit "$_n")"
    [ "$_b" = "-1" ] && { IFS="$_old_ifs"; return 1; }
    _v=$(( _v | _b ))
  done
  IFS="$_old_ifs"
  [ "$_v" -gt 0 ] || return 1
  printf '%s' "$_v"
}

_to_binary() {
  _n="$1"; _b=""
  [ "$_n" -eq 0 ] && { printf '0'; return; }
  while [ "$_n" -gt 0 ]; do _b="$(( _n % 2 ))$_b"; _n=$(( _n / 2 )); done
  printf '%s' "$_b"
}

# shellcheck disable=SC2046
_set_mask() { _cmd_phone set-allowed-network-types-for-users $(_slot_args "$1") "$(_to_binary "$2")" >/dev/null 2>&1; }

# The governor's state file first (cheap). If it still says "on", ask the power manager
# before giving up: older governors only refreshed the file when they wrote caps, so 90 s
# after a screen-off it could still read screen=1 and the apply silently never happened.
_screen_off_now() {
  _st="$(grep -m1 '^screen=' "${ASB_STATE_FILE:-/dev/.asb/state}" 2>/dev/null | cut -d= -f2)"
  [ "$_st" = "0" ] && return 0
  _wk="$(dumpsys power 2>/dev/null | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)"
  case "$_wk" in Asleep|Dozing) return 0 ;; esac
  return 1
}

# Any SIM in a call counts. The registry prints one mCallState per phone; taking only the
# first line checked SIM 1 alone, so a call on the second SIM was invisible here.
_in_call() {
  dumpsys telephony.registry 2>/dev/null | grep -oE 'mCallState=[0-9]+' | grep -qv '=0$'
}

# Hotspot / USB / Bluetooth tethering: the phone is someone else's uplink, and with the
# screen off that is the normal way to use it. Dropping 5G there slows every client on the
# hotspot for the length of the session - the opposite of a saving nobody can see.
_tethering() {
  for _ti in /sys/class/net/*; do
    _tn="${_ti##*/}"
    case "$_tn" in
      ap[0-9]*|swlan[0-9]*|softap[0-9]*|rndis[0-9]*|ncm[0-9]*|usb[0-9]*|bt-pan|bnep[0-9]*) : ;;
      *) continue ;;
    esac
    [ "$(cat "$_ti/operstate" 2>/dev/null)" = "up" ] && return 0
  done
  return 1
}

# Why the mask was changed: "off" (screen-off mode) or "light" (light traffic, screen on).
# Old two-field records are screen-off ones.
_saved_reason() {
  _r=""
  [ -f "$SAVE" ] && IFS='|' read -r _x1 _x2 _r < "$SAVE" 2>/dev/null
  _r="$(printf '%s' "$_r" | tr -d ' \r')"
  printf '%s' "${_r:-off}"
}

# KiB moved over the mobile data interfaces so far (rx + tx, every rmnet_data*). Summed in
# awk: the byte counters pass 2^31 within a day, and mksh arithmetic is 32-bit.
_rmnet_kib() {
  for _ri in "${ASB_NET_SYS:-/sys/class/net}"/rmnet_data*; do
    [ -d "$_ri" ] || continue
    cat "$_ri/statistics/rx_bytes" "$_ri/statistics/tx_bytes" 2>/dev/null
  done | awk '/^[0-9]+$/ { s += $1 } END { printf "%d", s / 1024 }'
}

# Default route over mobile data (not Wi-Fi, not a VPN on Wi-Fi).
_on_mobile() {
  _dev="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'dev [a-z0-9_]+' | head -1 | cut -d' ' -f2)"
  case "$_dev" in rmnet*|ccmni*) return 0 ;; esac
  # A VPN tunnel on top: look at what the tunnel itself rides on.
  case "$_dev" in tun*|wg*|ppp*)
    ip route 2>/dev/null | grep -q '^default.*dev rmnet' && return 0 ;;
  esac
  return 1
}

# A game in front: latency matters more than the radio there.
_game_front() {
  _h="$(grep -m1 '^smart_app_hint=' "${ASB_STATE_FILE:-/dev/.asb/state}" 2>/dev/null | cut -d= -f2)"
  case "$_h" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_h" -ge 4 ]
}

# One-time repair for phones hit by the dropped-record bug above: the log says a restore
# dropped its record, so NR may still be missing now. Give it back once, only if it is in
# fact missing, then never again - a user who turns 5G off later keeps that choice.
do_repair_dropped() {
  [ -f "$STATE_DIR/lte_screenoff.repaired" ] && return 0
  grep -q 'restore: bad save file dropped' "$LOGF" 2>/dev/null || { true > "$STATE_DIR/lte_screenoff.repaired"; return 0; }
  _rs="$(_data_slot)" || _rs=d
  _rc="$(_get_mask "$_rs")" || return 0
  if [ $(( _rc & NR_BIT )) -eq 0 ]; then
    _set_mask "$_rs" $(( _rc | NR_BIT ))
    _rn="$(_get_mask "$_rs")"
    if [ -n "$_rn" ] && [ $(( _rn & NR_BIT )) -ne 0 ]; then
      _log "repair: 5G given back (a previous restore had dropped its record; mask $_rc -> $_rn)"
    else
      _log "repair: could not give 5G back (readback ${_rn:-none}) - will try at the next screen-on"
      return 0
    fi
  fi
  true > "$STATE_DIR/lte_screenoff.repaired"
}

do_restore() {
  [ -f "$SAVE" ] || { do_repair_dropped; return 0; }
  # IFS-split, not a parameter-expansion split on "|". Every restore on the OP15 logged "bad save file dropped"
  # right after an apply that wrote a well-formed "0|916479" - four in a row across three
  # days - and since the drop also deleted the file, 5G was never given back: the modem
  # stayed on LTE with the screen on, and after a reboot too, the setting being persistent.
  # The parameter-expansion split is the only part of this that depends on the shell's
  # pattern dialect (a bare | inside the pattern), and the identical record parses fine
  # through read.
  _sub=""; _orig=""; _rsn=""
  # Third field (fix114): the reason, "off" or "light". Reading two fields put
  # "916479|light" into _orig and the record read as corrupt.
  IFS='|' read -r _sub _orig _rsn < "$SAVE" 2>/dev/null
  _sub="$(printf '%s' "$_sub" | tr -d ' \r')"; _orig="$(printf '%s' "$_orig" | tr -d ' \r')"
  _bad=0
  case "$_sub" in d|[0-9]|[0-9][0-9]) : ;; *) _bad=1 ;; esac
  case "$_orig" in ''|*[!0-9]*) _bad=1 ;; esac
  if [ "$_bad" = 1 ]; then
    # Never just drop it: the one thing apply ever removed is the NR bit, so give that
    # back on whatever the modem holds now. Only then is the record gone.
    _fs="$_sub"; case "$_fs" in d|[0-9]|[0-9][0-9]) : ;; *) _fs="$(_data_slot)" || _fs=d ;; esac
    _cur="$(_get_mask "$_fs")"
    if [ -n "$_cur" ] && [ $(( _cur & NR_BIT )) -eq 0 ]; then
      _set_mask "$_fs" $(( _cur | NR_BIT ))
      _log "restore: unreadable save ($(head -c 40 "$SAVE" 2>/dev/null | tr -c '[:print:]' '?')) - NR given back on the current mask $_cur"
    else
      _log "restore: unreadable save, 5G already allowed - record dropped"
    fi
    rm -f "$SAVE" "$SINCE"
    _stats_add 0 1 0
    return 0
  fi
  _set_mask "$_sub" "$_orig"
  _now="$(_get_mask "$_sub")"
  if [ "$_now" = "$_orig" ]; then
    rm -f "$SAVE"
    _t0="$(cat "$SINCE" 2>/dev/null)"; rm -f "$SINCE"
    case "$_t0" in ''|*[!0-9]*) _dt=0 ;; *) _dt=$(( $(date +%s) - _t0 )); [ "$_dt" -lt 0 ] && _dt=0 ;; esac
    _stats_add 0 1 "$_dt"
    _log "restore: sub=$_sub mask=$_orig (5G allowed again after ${_dt}s on LTE)"
  else
    # Keep the save file: the next screen-on, boot or toggle-off tries again.
    _log "restore: readback $_now != $_orig, will retry"
  fi
}

do_apply() {
  [ "$(_cfg net_screen_off_lte)" = "1" ] || return 0
  [ -f "$UNSUP" ] && return 0
  [ -f "$SAVE" ] && return 0                     # already applied
  _screen_off_now || return 0
  _in_call && { _retry_later "call in progress"; return 0; }
  _tethering && { _retry_later "tethering active"; return 0; }
  rm -f "$RETRYF" 2>/dev/null
  _apply_nr_off off "LTE preferred, screen off"
}

# Drop the NR bit, save the original, verify. $1 = reason recorded with the save.
_apply_nr_off() {
  _reason="$1"; _why="$2"
  _sub="$(_data_slot)" || return 0
  _orig="$(_get_mask "$_sub")" || {
    _raw="$(_cmd_phone get-allowed-network-types-for-users $(_slot_args "$_sub") 2>&1 | tr -d '\r' | tail -n 1 | cut -c1-120)"
    _unsup_strike "cannot read allowed types (slot=$_sub, got: ${_raw:-nothing})"; return 0; }
  [ $(( _orig & NR_BIT )) -ne 0 ] || return 0    # 5G not allowed anyway
  _want=$(( _orig & ~NR_BIT ))
  printf '%s|%s|%s\n' "$_sub" "$_orig" "$_reason" > "$SAVE" 2>/dev/null && sync
  _set_mask "$_sub" "$_want"
  _now="$(_get_mask "$_sub")"
  if [ "$_now" = "$_want" ]; then
    date +%s > "$SINCE" 2>/dev/null
    rm -f "$UNSUP.n" 2>/dev/null
    _stats_add 1 0 0
    _log "apply: sub=$_sub $_orig -> $_want ($_why)"
  else
    do_restore
    _unsup_strike "readback $_now != $_want after the write (restored)"
  fi
}

# Three strikes, not one. A single failed read used to switch the feature off until the next
# reinstall: an OP15 logged "cannot read allowed types, marking unsupported" at 01:21 one
# night - the phone service was mid-restart - and the next apply came 18 hours later, after
# a reinstall cleared the flag. Only three failures in a row mean "this device cannot".
_unsup_strike() {
  _sn="$(cat "$UNSUP.n" 2>/dev/null)"; case "$_sn" in ''|*[!0-9]*) _sn=0 ;; esac
  _sn=$(( _sn + 1 ))
  if [ "$_sn" -ge 3 ]; then
    _log "apply: $1 - third time in a row, marking unsupported"
    true > "$UNSUP"; rm -f "$UNSUP.n" 2>/dev/null
  else
    _log "apply: $1 - attempt $_sn of 3, will try again at the next screen-off"
    echo "$_sn" > "$UNSUP.n" 2>/dev/null
  fi
}

# A skipped apply used to be final for the whole screen-off. An OP15 night shows it: at
# 03:12 "apply: skipped, call in progress", then nothing until the screen came on at 11:10 -
# eight hours on 5G with the option on, for a check that is only true for the length of a
# call. The skip now re-arms itself every RETRY_S while the screen stays off, at most
# RETRY_MAX times (two hours), and logs only the first skip of a run.
_retry_later() {
  _rn="$(cat "$RETRYF" 2>/dev/null)"; case "$_rn" in ''|*[!0-9]*) _rn=0 ;; esac
  [ "$_rn" -eq 0 ] && _log "apply: skipped, $1 - will retry every ${RETRY_S}s while the screen is off"
  [ "$_rn" -ge "$RETRY_MAX" ] && { _log "apply: still $1 after $_rn retries, giving up until the next screen-off"; rm -f "$RETRYF"; return 0; }
  echo $(( _rn + 1 )) > "$RETRYF" 2>/dev/null
  do_arm "$RETRY_S"
}

do_arm() {
  _arm_delay="${1:-$DELAY}"
  [ "$(_cfg net_screen_off_lte)" = "1" ] || return 0
  [ -f "$UNSUP" ] && return 0
  [ -f "$SAVE" ] && return 0
  # One pending timer at a time: this script is called on every screen, profile and
  # thermal change, and only the first screen-off should start the clock.
  if [ -f "$PIDF" ]; then
    _p="$(cat "$PIDF" 2>/dev/null)"
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && return 0
  fi
  (
    exec </dev/null >/dev/null 2>&1   # detach here, not with a redirect on the ( ): mksh then waits for a body that uses $(...)
    # The sleep runs as a child the timer can take down with it: a disarm (screen on) kills
    # this subshell, and a plain foreground sleep would be left behind as an orphan.
    trap 'kill "$_sp" 2>/dev/null; exit 0' TERM INT
    sleep "$_arm_delay" & _sp=$!
    wait "$_sp"
    rm -f "$PIDF"
    do_apply
  ) &
  printf '%s\n' "$!" > "$PIDF" 2>/dev/null
}

do_disarm() {
  if [ -f "$PIDF" ]; then
    _p="$(cat "$PIDF" 2>/dev/null)"
    [ -n "$_p" ] && kill "$_p" 2>/dev/null
    rm -f "$PIDF"
  fi
}

# ---- light-traffic mode (screen on) ------------------------------------------------------
do_light_stop() {
  if [ -f "$LPIDF" ]; then
    _lp="$(cat "$LPIDF" 2>/dev/null)"
    [ -n "$_lp" ] && kill "$_lp" 2>/dev/null
    rm -f "$LPIDF"
  fi
}

_light_tick() {   # $1 = kbit/s over the last window; $2 = low-window streak (in/out via _lowN)
  _kb="$1"
  if [ -f "$SAVE" ] && [ "$(_saved_reason)" = "light" ]; then
    if [ "$_kb" -gt "$LIGHT_HIGH_KBPS" ] 2>/dev/null; then
      do_restore
      echo $(( $(date +%s) + LIGHT_HOLD_S )) > "$LHOLD" 2>/dev/null
      _log "light: ${_kb} kbit/s - 5G back for at least ${LIGHT_HOLD_S}s"
    fi
    _lowN=0
    return 0
  fi
  [ -f "$SAVE" ] && { _lowN=0; return 0; }   # a screen-off record is not ours to touch
  if [ "$_kb" -lt "$LIGHT_LOW_KBPS" ] 2>/dev/null; then _lowN=$(( _lowN + 1 )); else _lowN=0; fi
  [ "$_lowN" -ge "$LIGHT_LOW_TICKS" ] || return 0
  _hu="$(cat "$LHOLD" 2>/dev/null)"; case "$_hu" in ''|*[!0-9]*) _hu=0 ;; esac
  [ "$(date +%s)" -ge "$_hu" ] || return 0
  _in_call && return 0
  _tethering && return 0
  _game_front && return 0
  _apply_nr_off light "LTE preferred, light traffic ${_kb} kbit/s with the screen on"
  _lowN=0
}

do_light_loop() {
  _prev="$(_rmnet_kib)"; _lowN=0
  while :; do
    sleep "$LIGHT_TICK_S" & _sp=$!
    wait "$_sp"
    [ "$(_cfg net_lte_light)" = "1" ] || {
      [ -f "$SAVE" ] && [ "$(_saved_reason)" = "light" ] && do_restore
      break; }
    [ -f "$UNSUP" ] && break
    # Screen off: the record (if any) simply stays; the tuner's "arm" stops this loop too.
    # The state file only - no dumpsys power every 30 s with the screen on.
    [ "$(grep -m1 '^screen=' "${ASB_STATE_FILE:-/dev/.asb/state}" 2>/dev/null | cut -d= -f2)" = "0" ] && break
    _cur="$(_rmnet_kib)"
    case "$_cur" in ''|*[!0-9]*) _cur="$_prev" ;; esac
    _d=$(( _cur - _prev )); _prev="$_cur"
    [ "$_d" -lt 0 ] && _d=0           # an interface went away and its counters with it
    if ! _on_mobile; then _lowN=0; continue; fi
    # KiB per window -> kbit/s (x8; the 1.024 is noise next to the 4/12 Mbit/s marks).
    _light_tick $(( _d * 8 / LIGHT_TICK_S ))
  done
  rm -f "$LPIDF"
}

do_light_start() {
  [ "$(_cfg net_lte_light)" = "1" ] || return 0
  [ -f "$UNSUP" ] && return 0
  if [ -f "$LPIDF" ]; then
    _lp="$(cat "$LPIDF" 2>/dev/null)"
    [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null && return 0
  fi
  (
    exec </dev/null >/dev/null 2>&1
    trap 'kill "$_sp" 2>/dev/null; exit 0' TERM INT
    do_light_loop
  ) &
  printf '%s\n' "$!" > "$LPIDF" 2>/dev/null
}

# Screen on: give back what the SCREEN-OFF mode took, keep a light-traffic record (the
# watcher decides about it), and start the watcher when the light mode is on.
do_screen_on() {
  do_disarm; rm -f "$RETRYF" 2>/dev/null
  if [ -f "$SAVE" ]; then
    if [ "$(_saved_reason)" != "light" ] || [ "$(_cfg net_lte_light)" != "1" ]; then
      do_restore
    fi
  else
    do_repair_dropped
  fi
  do_light_start
}

case "$1" in
  screen_on) do_screen_on ;;
  arm)
    do_light_stop
    # Screen off over a light-traffic record: keep it when the screen-off mode wants LTE
    # anyway; otherwise give 5G back - LTE with the screen off is its own toggle, and with
    # the watcher stopped nothing would notice a big download until the next screen-on.
    if [ -f "$SAVE" ] && [ "$(_saved_reason)" = "light" ] && [ "$(_cfg net_screen_off_lte)" != "1" ]; then
      do_restore
    fi
    do_arm ;;
  apply)   do_apply ;;
  restore) do_disarm; do_light_stop; rm -f "$RETRYF" 2>/dev/null; do_restore ;;
  status)
    printf 'enabled=%s\n' "$(_cfg net_screen_off_lte)"
    printf 'applied=%s\n' "$([ -f "$SAVE" ] && echo 1 || echo 0)"
    printf 'reason=%s\n' "$([ -f "$SAVE" ] && _saved_reason || echo none)"
    printf 'light=%s\n' "$(_cfg net_lte_light)"
    printf 'light_watch=%s\n' "$([ -f "$LPIDF" ] && kill -0 "$(cat "$LPIDF" 2>/dev/null)" 2>/dev/null && echo 1 || echo 0)"
    printf 'pending=%s\n' "$([ -f "$PIDF" ] && echo 1 || echo 0)"
    printf 'unsupported=%s\n' "$([ -f "$UNSUP" ] && echo 1 || echo 0)"
    printf 'last=%s\n' "$(tail -n 1 "$LOGF" 2>/dev/null | cut -d' ' -f3-)"
    _sa=0; _sr=0; _ss=0
    [ -f "$STATS" ] && IFS='|' read -r _sa _sr _ss < "$STATS"
    printf 'applies=%s\nrestores=%s\nlte_minutes=%s\n' "${_sa:-0}" "${_sr:-0}" $(( ${_ss:-0} / 60 ))
    ;;
  # Whether the data SIM allows 5G right now: yes | no | unknown. Read with the same parser
  # restore uses, so the answer matches what the script itself would see.
  nr)
    _ns="$(_data_slot)" || _ns=d
    _nm="$(_get_mask "$_ns")" || { echo unknown; exit 0; }
    if [ $(( _nm & NR_BIT )) -ne 0 ]; then echo yes; else echo no; fi
    ;;
  *) echo "usage: $0 arm|apply|restore|screen_on|status|nr" >&2; exit 2 ;;
esac
exit 0
