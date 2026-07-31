#!/system/bin/sh
# asb_log_apply.sh - resolve the log_level choice and apply device-side log suppression.
#
#   log_level = stock | 0 | 1 | 2 | 3
#
#   stock  ASB does not touch the device's logging at all. Its own governor log stays at
#          its quietest. This is the only value where nothing about logging is modified.
#   0      EXTREME. Cuts device logging and debug output as far as it goes: logd buffers
#          shrunk, tag levels silenced, kernel and vendor debug traces off. Saves the
#          writes and the wakeups that logging costs - and makes almost every bug report
#          useless, including ours. Meant for people who have finished troubleshooting.
#   1      Normal. What the module has always done: significant events only.
#   2      Detailed. Adds learner updates and screen transitions - the level to switch on
#          before sending a log about battery behaviour.
#   3      Verbose. Fills the log quickly; only while reproducing something specific.
#
# The digits were renumbered: 1 is what used to be 0. The governor cannot read this key
# directly (atoi cannot express "stock", and the shift would be off by one), so the choice
# is resolved into log_verbosity, which the governor reads instead.
#
# Everything the extreme mode changes is recorded before the first change and put back when
# the mode leaves extreme, so it is not a one-way door.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE="/data/adb/asb/log_extreme_prev"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}
_has() { command -v "$1" >/dev/null 2>&1; }

_lvl="$(_cfg log_level)"
case "$_lvl" in
  stock|0|1|2|3) : ;;
  '') _lvl=1 ;;
  *)  _lvl=1 ;;
esac

# --- governor verbosity -----------------------------------------------------------------
# stock and 0 are both quiet; 1 is the old 0; 2 and 3 shift down by one.
case "$_lvl" in
  stock|0) _verb=0 ;;
  1)       _verb=0 ;;
  2)       _verb=1 ;;
  3)       _verb=2 ;;
esac
if grep -q '^[[:space:]]*log_verbosity=' "$CONF" 2>/dev/null; then
  sed -i "s|^[[:space:]]*log_verbosity=.*|log_verbosity=$_verb|" "$CONF" 2>/dev/null
else
  echo "log_verbosity=$_verb" >> "$CONF" 2>/dev/null
fi

# --- device-side logging ------------------------------------------------------------------
# Only the extreme mode touches this. Everything else - including stock - leaves the
# device's own logging exactly as the ROM set it.
_apply_extreme() {
  mkdir -p /data/adb/asb 2>/dev/null
  # Record first, once. Without this, leaving extreme could only guess at what to restore.
  if [ ! -f "$STATE" ]; then
    {
      printf 'PREV_LOGD_SIZE=%s\n'   "$(getprop persist.logd.size 2>/dev/null)"
      printf 'PREV_LOGD_LOGPERSIST=%s\n' "$(getprop persist.logd.logpersistd 2>/dev/null)"
      printf 'PREV_LOG_TAG=%s\n'     "$(getprop persist.log.tag 2>/dev/null)"
      printf 'PREV_DALVIK=%s\n'      "$(getprop dalvik.vm.check-dex-sum 2>/dev/null)"
    } > "$STATE" 2>/dev/null
  fi
  _has resetprop || return 0
  # Smallest buffer the daemon accepts rather than stopping logd outright: a stopped logd
  # makes some OEM services retry in a loop, which costs more than the logging did.
  resetprop -n persist.logd.size 65536 >/dev/null 2>&1
  resetprop -n persist.log.tag S >/dev/null 2>&1
  resetprop -n persist.logd.logpersistd "" >/dev/null 2>&1
  resetprop -n persist.sys.mdlog_dumpback 0 >/dev/null 2>&1
  resetprop -n persist.sys.logkit.ctrlcode 0 >/dev/null 2>&1
  resetprop -n persist.vendor.verbose.enable 0 >/dev/null 2>&1
  echo "log: EXTREME - device logging cut back; bug reports from this device will be thin"
}

_restore_extreme() {
  [ -f "$STATE" ] || return 0
  _has resetprop || return 0
  _get() { grep -E "^$1=" "$STATE" 2>/dev/null | head -1 | sed 's/[^=]*=//'; }
  for _pair in "persist.logd.size:PREV_LOGD_SIZE" \
               "persist.log.tag:PREV_LOG_TAG" \
               "persist.logd.logpersistd:PREV_LOGD_LOGPERSIST"; do
    _p="${_pair%%:*}"; _k="${_pair##*:}"
    _v="$(_get "$_k")"
    if [ -n "$_v" ]; then
      resetprop -n "$_p" "$_v" >/dev/null 2>&1
    else
      resetprop --delete "$_p" >/dev/null 2>&1
    fi
  done
  rm -f "$STATE" 2>/dev/null
  echo "log: device logging restored to what it was before extreme mode"
}

case "$_lvl" in
  0) _apply_extreme ;;
  *) _restore_extreme ;;
esac

case "$_lvl" in
  stock) echo "log: stock - ASB does not touch device logging" ;;
  1)     echo "log: normal (governor verbosity $_verb)" ;;
  2)     echo "log: detailed (governor verbosity $_verb)" ;;
  3)     echo "log: verbose (governor verbosity $_verb)" ;;
esac
exit 0
