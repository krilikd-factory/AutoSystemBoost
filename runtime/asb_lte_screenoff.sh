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
DELAY="${ASB_LTE_DELAY_S:-90}"
NR_BIT=524288                                   # 1 << (NETWORK_TYPE_NR - 1)

mkdir -p "$STATE_DIR" 2>/dev/null

# Two lines per screen cycle is a few hundred a day, forever. Keep the tail only.
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

_screen_off_now() {
  _st="$(grep -m1 '^screen=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  [ "$_st" = "0" ]
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

do_restore() {
  [ -f "$SAVE" ] || return 0
  _line="$(cat "$SAVE" 2>/dev/null)"
  _sub="${_line%%|*}"; _orig="${_line#*|}"
  case "$_sub" in d|[0-9]|[0-9][0-9]) : ;; *) rm -f "$SAVE"; _log "restore: bad save file dropped"; return 0 ;; esac
  case "$_orig" in ''|*[!0-9]*) rm -f "$SAVE"; _log "restore: bad save file dropped"; return 0 ;; esac
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
  _tethering && { _log "apply: skipped, tethering active"; return 0; }
  _sub="$(_data_slot)" || return 0
  _orig="$(_get_mask "$_sub")" || {
    _raw="$(_cmd_phone get-allowed-network-types-for-users $(_slot_args "$_sub") 2>&1 | tr -d '\r' | tail -n 1 | cut -c1-120)"
    _log "apply: cannot read allowed types (slot=$_sub, got: ${_raw:-nothing}), marking unsupported"
    : > "$UNSUP"; return 0; }
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
    printf 'last=%s\n' "$(tail -n 1 "$LOGF" 2>/dev/null | cut -d' ' -f3-)"
    ;;
  *) echo "usage: $0 arm|apply|restore|status" >&2; exit 2 ;;
esac
exit 0
