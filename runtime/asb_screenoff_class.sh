#!/system/bin/sh
# asb_screenoff_class.sh - say WHAT a screen-off stretch was, before anyone acts on it.
#
# P1-1 and P1-2 from the cross-device plan, in observe-only mode.
#
# Five full-day captures showed the same trap from different angles: the same phase label
# in the report can mean completely different physical work. An "idle" hour can be genuine
# deep sleep, or it can be Bluetooth playback, a VPN tunnel moving data, GNSS held by a
# cached app, or a phone on a charger. Treating those alike is how a night reference gets
# built from a media session, and how "the CPU policy failed" gets concluded from a current
# reading that was really the radio.
#
# This classifies and records. It changes no policy, restricts no app and writes no system
# node - deliberately, for a first release cycle. What it produces is evidence with a name
# on it, so the next decision has something honest to stand on.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
OUT=/dev/.asb/screenoff_class
STATE=/data/adb/asb/screenoff_history
_has() { command -v "$1" >/dev/null 2>&1; }

_st() { grep -m1 "^$1=" /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d '"'; }

# --- inputs ----------------------------------------------------------------------------
_screen="$(dumpsys deviceidle get screen 2>/dev/null)"
case "$_screen" in *true*|*on*) exit 0 ;; esac   # screen on: nothing to classify

_awake="$(_st awake_pct_screenoff)"
case "$_awake" in ''|*[!0-9-]*) _awake=-1 ;; esac
_win="$(_st awake_window_min)"
case "$_win" in ''|*[!0-9]*) _win=0 ;; esac
_bconf="$(_st battery_window_confidence)"
case "$_bconf" in ''|*[!0-9]*) _bconf=0 ;; esac

# Charging first: it invalidates drain reasoning entirely, so nothing else matters.
_charging=0
for _p in /sys/class/power_supply/*/online; do
  [ -r "$_p" ] || continue
  case "$(cat "$_p" 2>/dev/null)" in 1) _charging=1; break ;; esac
done

# Media: an audio session with the screen off is not idle, whatever the CPU is doing.
_media=0
if _has dumpsys; then
  dumpsys audio 2>/dev/null | grep -qiE 'state:started|playing' && _media=1
fi

# Network: a tunnel or an active mobile route means current tells you about the radio,
# not about CPU policy. Checked by interface presence rather than by traffic volume -
# volume needs two samples and this runs once.
_net=0
for _i in tun0 ppp0 ipsec0; do
  [ -d "/sys/class/net/$_i" ] && _net=1
done
if [ "$_net" = "0" ]; then
  _rx1=0
  for _r in /sys/class/net/rmnet_data*/statistics/rx_bytes; do
    [ -r "$_r" ] && _rx1=$(( _rx1 + $(cat "$_r" 2>/dev/null || echo 0) ))
  done
  _prev="$(cat /dev/.asb/screenoff_rx 2>/dev/null || echo 0)"
  case "$_prev" in ''|*[!0-9]*) _prev=0 ;; esac
  echo "$_rx1" > /dev/.asb/screenoff_rx 2>/dev/null
  # A megabyte between samples is transfer, not keepalive chatter.
  [ "$_prev" -gt 0 ] && [ $(( _rx1 - _prev )) -gt 1048576 ] && _net=1
fi

# Noisy: something is holding the CPU awake and it is not one of the above.
_noisy=0
[ "$_awake" -ge 25 ] 2>/dev/null && _noisy=1

# --- classify --------------------------------------------------------------------------
#
# Order matters and is not arbitrary. Charging invalidates drain reasoning, so it wins.
# Media and network explain a high current that would otherwise look like a policy
# failure, so they outrank "noisy". Only when nothing explains the wakefulness is it
# genuinely unexplained - which is the one case worth investigating.
if   [ "$_charging" = "1" ]; then _class=charging; _why="on charger - excluded from drain adaptation"
elif [ "$_media" = "1" ];    then _class=media;    _why="audio session active - not idle, not a night reference"
elif [ "$_net" = "1" ];      then _class=network;  _why="tunnel or active mobile transfer - current reflects the radio"
elif [ "$_awake" -lt 0 ] 2>/dev/null || [ "$_win" -lt 10 ] 2>/dev/null; then
  _class=unknown; _why="no measured screen-off window yet"
elif [ "$_noisy" = "1" ];    then _class=noisy;    _why="awake ${_awake}% with nothing explaining it"
else                              _class=quiet;    _why="low awake, no media or network - valid night reference"
fi

mkdir -p /dev/.asb /data/adb/asb 2>/dev/null
{
  echo "class=$_class"
  echo "reason=$_why"
  echo "awake_pct=$_awake"
  echo "window_min=$_win"
  echo "battery_conf=$_bconf"
  echo "charging=$_charging"
  echo "media=$_media"
  echo "network=$_net"
  echo "ts=$(date +%s 2>/dev/null || echo 0)"
} > "$OUT.tmp" 2>/dev/null && mv -f "$OUT.tmp" "$OUT" 2>/dev/null

# A short rolling history, so a pattern is visible without a full-day capture. Trimmed
# rather than appended forever: this is a hint for the next diagnosis, not an archive.
{
  echo "$(date +%s 2>/dev/null || echo 0)|$_class|$_awake|$_win"
  [ -f "$STATE" ] && head -47 "$STATE"
} > "$STATE.tmp" 2>/dev/null && mv -f "$STATE.tmp" "$STATE" 2>/dev/null

echo "screen-off: $_class - $_why"
exit 0
