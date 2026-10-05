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
# Commands: arm | apply | restore | status

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE_DIR=/data/adb/asb
SAVE="$STATE_DIR/lte_screenoff.saved"          # subid|decimal_mask
PIDF="$STATE_DIR/lte_screenoff.pid"
UNSUP="$STATE_DIR/lte_screenoff.unsupported"
LOGF="$STATE_DIR/lte_screenoff.log"
DELAY="${ASB_LTE_DELAY_S:-90}"
NR_BIT=524288                                   # 1 << (NETWORK_TYPE_NR - 1)

mkdir -p "$STATE_DIR" 2>/dev/null

_log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$LOGF" 2>/dev/null; }
_cfg() { grep -m1 "^$1=" "$MODDIR/config/governor.conf" 2>/dev/null | cut -d= -f2 | tr -d '\r '; }

_cmd_phone() {
  if command -v cmd >/dev/null 2>&1; then cmd phone "$@"
  elif [ -x /system/bin/cmd ]; then /system/bin/cmd phone "$@"
  else return 1; fi
}

# The SIM that carries data. -1 or empty means none: nothing to do.
_data_sub() {
  _s="$(settings get global multi_sim_data_call 2>/dev/null | tr -dc '0-9-')"
  case "$_s" in ''|-*) return 1 ;; esac
  printf '%s' "$_s"
}

# Type name -> bit, AOSP TelephonyManager.NETWORK_TYPE_* (bit = 1 << (id-1)).
_name_bit() {
  case "$1" in
    GPRS) echo 1 ;; EDGE) echo 2 ;; UMTS) echo 4 ;; CDMA) echo 8 ;;
    EVDO_0) echo 16 ;; EVDO_A) echo 32 ;; 1xRTT|1XRTT) echo 64 ;; HSDPA) echo 128 ;;
    HSUPA) echo 256 ;; HSPA) echo 512 ;; IDEN) echo 1024 ;; EVDO_B) echo 2048 ;;
    LTE) echo 4096 ;; EHRPD) echo 8192 ;; HSPAP) echo 16384 ;; GSM) echo 32768 ;;
    TD_SCDMA) echo 65536 ;; IWLAN) echo 131072 ;; LTE_CA) echo 262144 ;; NR) echo 524288 ;;
    *) echo -1 ;;
  esac
}

# Read the allowed mask as a decimal number. Accepts the three shapes ROMs print:
# a "GSM|LTE|NR" name list, a binary string, or a plain decimal. Anything else fails.
_get_mask() {
  _o="$(_cmd_phone get-allowed-network-types-for-users -s "$1" 2>/dev/null | tr -d '\r' | tail -n 1)"
  _o="$(printf '%s' "$_o" | sed 's/^[^:]*: *//; s/ //g')"
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

_set_mask() { _cmd_phone set-allowed-network-types-for-users -s "$1" "$(_to_binary "$2")" >/dev/null 2>&1; }

_screen_off_now() {
  _st="$(grep -m1 '^screen=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  [ "$_st" = "0" ]
}

_in_call() {
  _cs="$(dumpsys telephony.registry 2>/dev/null | grep -m1 -oE 'mCallState=[0-9]+' | cut -d= -f2)"
  [ -n "$_cs" ] && [ "$_cs" != "0" ]
}

do_restore() {
  [ -f "$SAVE" ] || return 0
  _line="$(cat "$SAVE" 2>/dev/null)"
  _sub="${_line%%|*}"; _orig="${_line#*|}"
  case "$_sub$_orig" in *[!0-9]*|'') rm -f "$SAVE"; _log "restore: bad save file dropped"; return 0 ;; esac
  _set_mask "$_sub" "$_orig"
  _now="$(_get_mask "$_sub")"
  if [ "$_now" = "$_orig" ]; then
    rm -f "$SAVE"
    _log "restore: sub=$_sub mask=$_orig (5G allowed again)"
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
  _in_call && { _log "apply: skipped, call in progress"; return 0; }
  _sub="$(_data_sub)" || return 0
  _orig="$(_get_mask "$_sub")" || { _log "apply: cannot read allowed types, marking unsupported"; : > "$UNSUP"; return 0; }
  [ $(( _orig & NR_BIT )) -ne 0 ] || return 0    # 5G not allowed anyway
  _want=$(( _orig & ~NR_BIT ))
  printf '%s|%s\n' "$_sub" "$_orig" > "$SAVE" 2>/dev/null && sync
  _set_mask "$_sub" "$_want"
  _now="$(_get_mask "$_sub")"
  if [ "$_now" = "$_want" ]; then
    _log "apply: sub=$_sub $_orig -> $_want (LTE preferred, screen off)"
  else
    _log "apply: readback $_now != $_want, restoring and marking unsupported"
    do_restore
    : > "$UNSUP"
  fi
}

do_arm() {
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
    sleep "$DELAY"
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

case "$1" in
  arm)     do_arm ;;
  apply)   do_apply ;;
  restore) do_disarm; do_restore ;;
  status)
    printf 'enabled=%s\n' "$(_cfg net_screen_off_lte)"
    printf 'applied=%s\n' "$([ -f "$SAVE" ] && echo 1 || echo 0)"
    printf 'pending=%s\n' "$([ -f "$PIDF" ] && echo 1 || echo 0)"
    printf 'unsupported=%s\n' "$([ -f "$UNSUP" ] && echo 1 || echo 0)"
    ;;
  *) echo "usage: $0 arm|apply|restore|status" >&2; exit 2 ;;
esac
exit 0
