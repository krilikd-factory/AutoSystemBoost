#!/system/bin/sh
# asb_bt_link_watch.sh - notice a phone that keeps dropping its Bluetooth audio link, and
# apply the mitigation only there.
#
# Bluetooth dropouts are not a module defect and not a common one: most phones never see
# them. So the fix cannot be a default, and asking every user to diagnose their own radio
# and tick a box is not much better - the person who has this problem is exactly the person
# who does not know it is a 2.4 GHz coexistence issue.
#
# The evidence is already there, and it is unambiguous. A working headset connects once and
# stays connected for the length of the session. A phone with this fault drops the audio
# link and picks it straight back up - the user hears a gap, not a disconnection they then
# have to fix.
#
# The affected capture shows what "straight back up" actually means: 29 reconnects with a
# median gap of 51 seconds and a minimum of 2, thirteen of them inside half a minute. That
# is the signature. A headset carried out of range disconnects and stays disconnected; a
# user putting it down does not reconnect seconds later. A healthy log from the same build
# has no disconnects at all.
#
# So the count is what matters, not any particular gap length - a phone that drops its link
# this often has the fault whether it recovers in two seconds or in ninety.
#
# So: count the pattern, and when it is unmistakable, throttle Wi-Fi scanning. That is the
# standard remedy - the two radios share an antenna and a scan sweeps the whole band, so a
# stream that misses its slot disconnects rather than degrading.
#
# What this deliberately does NOT do:
#   - force an audio codec. LDAC on a marginal link is a real cause, but the codec is the
#     user's and the headset's choice and changing it alters how music sounds.
#   - touch anything when bt_link_stability is set explicitly. A user who chose stock or
#     stable has answered this question themselves.
#   - stay on forever. The mitigation is re-evaluated, so a phone that was fine after a
#     firmware update stops paying for it.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE_DIR="${ASB_CONFIG_STATE:-/data/adb/asb}"
CONF="$MODDIR/config/governor.conf"
EVIDENCE="$STATE_DIR/bt_link_evidence"
APPLIED="$STATE_DIR/bt_link_auto"
LOG="$STATE_DIR/bt_link_watch.log"

_has() { command -v "$1" >/dev/null 2>&1; }
_cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'; }
_now() { date +%s 2>/dev/null || echo 0; }
_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s bt_link: %s\n' "$(date '+%F %T' 2>/dev/null || echo now)" "$*" >> "$LOG" 2>/dev/null
  tail -n 40 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true
}

# An explicit choice is final. Auto-detection exists for people who have not made one.
case "$(_cfg bt_link_stability)" in
  stable|stock) exit 0 ;;
esac

_has dumpsys || exit 0

# Is a headset even connected? Nothing to measure otherwise, and polling costs nothing when
# the answer is no.
dumpsys bluetooth_manager 2>/dev/null | grep -qiE 'STATE_CONNECTED|isConnected: *true' || exit 0

# Count audio-link drops seen since the last pass.
#
# HeadsetService disconnectAudio is the same line the logkit lifecycle tracker keys on, so
# the runtime signal and the diagnostic agree by construction rather than by coincidence.
_drops=0
if _has logcat; then
  _drops="$(logcat -d -t 2000 2>/dev/null \
            | grep -cE 'HeadsetService:.*disconnectAudio|BluetoothHeadset:.*disconnectAudio')"
fi
case "$_drops" in ''|*[!0-9]*) _drops=0 ;; esac
[ "$_drops" -gt 0 ] || exit 0

_prev="$(cat "$EVIDENCE" 2>/dev/null | tr -dc '0-9')"
case "$_prev" in '') _prev=0 ;; esac
_total=$(( _prev + _drops ))
printf '%s\n' "$_total" > "$EVIDENCE" 2>/dev/null

# Eight drops is well past coincidence and still reachable within a single listening
# session on an affected phone. A healthy device does not get here at all.
if [ "$_total" -lt 8 ] 2>/dev/null; then
  exit 0
fi

# Already mitigating: nothing more to do.
[ -f "$APPLIED" ] && exit 0

if _has settings; then
  settings put global wifi_scan_throttle_enabled 1 >/dev/null 2>&1 || true
  printf '%s\n' "$(_now)" > "$APPLIED" 2>/dev/null
  _log "detected $_total audio-link drops - throttling Wi-Fi scans (2.4 GHz coexistence)"
  echo "bt_link: repeated Bluetooth audio drops detected - Wi-Fi scanning throttled"
fi
exit 0
