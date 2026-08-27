#!/system/bin/sh
# asb_lpm.sh - modem low-power mode, driven by what the device is actually doing.
#
# LPM was declared in features.conf, offered at install and printed on the action
# screen, and had no code behind it at all. This is that code.
#
# The idea is that a modem power policy should not be one setting.
# During an online match you want the data call hot and the radio in a connected state, because
# the cost of coming back up from idle is exactly the latency spike that loses the round.
#
# What this deliberately does NOT touch: preferred_network_mode. Dropping someone from
# 5G to LTE would save real power and is a favourite trick, but a restore that fails
# once leaves the user stuck on a slower network with no idea why. Not worth it.
#
# Modes: fast screen on, heavy/gaming - keep the data call up, short keepalive normal screen
# on, ordinary use - the profile's own values save screen off / idle - let the radio idle,
# stretch keepalives
#
# Everything is read once into a baseline before it is first changed, so turning the
# LPM feature off or uninstalling puts back what the user had.

# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service. On a OnePlus 15R every call returned "Failure calling
# service settings" while exiting 0, so writes looked successful and reads returned the
# error text as a value - this makes those calls work without changing any of them.
[ -f "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh" ] && \
  . "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh"

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
MODE="${1:-normal}"
BASE="/data/adb/asb/lpm_baseline.conf"
STATE="/dev/.asb/lpm_mode"

# A WebUI change must refresh the policy in the CURRENT governor-selected mode. Calling
# normal unconditionally would wake the mobile data context during save/night and defeat
# standby policy, so `refresh` decodes the persisted mode and never invents one.
if [ "$MODE" = "refresh" ]; then
  _saved_mode="$(cat "$STATE" 2>/dev/null | cut -d'|' -f1)"
  case "$_saved_mode" in fast|normal|save|night) MODE="$_saved_mode" ;; *) MODE="normal" ;; esac
fi

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r'
}

_feat_on() {
  _fv="$(grep -E "^[[:space:]]*$1=" "$MODDIR/features.conf" 2>/dev/null \
         | head -1 | sed 's/#.*$//' | sed 's/.*=//' | tr -d ' \r')"
  [ "$_fv" = "1" ]
}

_sset() { settings put global "$1" "$2" >/dev/null 2>&1 || true; }
_sysc() { [ -w "/proc/sys/$(echo "$1" | tr . /)" ] && echo "$2" > "/proc/sys/$(echo "$1" | tr . /)" 2>/dev/null || true; }

# The power profile must not silently become an antenna/radio preference. The radio master is
# off by default, so a no-SIM device (or a user who simply wants stock telephony behaviour)
# cannot get mobile-data context or TCP keepalive changes merely by selecting Balanced/Smart.
_radio_policy_enabled() { [ "$(_cfg radio_policy_enable)" = "1" ]; }

# Feature or explicit radio policy off: restore whatever we saved, once, then stay out of the way.
if ! _feat_on LPM || ! _radio_policy_enabled; then
  if [ -f "$BASE" ]; then
    . "$BASE" 2>/dev/null
    [ -n "${BASE_MDAO:-}" ] && [ "$BASE_MDAO" != "null" ] && _sset mobile_data_always_on "$BASE_MDAO"
    rm -f "$BASE" "$STATE" 2>/dev/null
  fi
  exit 0
fi

# Baseline, captured once before the first change.
if [ ! -f "$BASE" ]; then
  mkdir -p /data/adb/asb 2>/dev/null
  {
    echo "BASE_MDAO=$(settings get global mobile_data_always_on 2>/dev/null)"
    echo "BASE_KEEPIDLE=$(cat /proc/sys/net/ipv4/tcp_keepalive_time 2>/dev/null)"
    # The probe pair too, because night mode changes it. Anything this script writes and
    # never records is a setting the user cannot get back - these two would otherwise
    # stay at their 3am values for the whole following day.
    echo "BASE_KEEPINTVL=$(cat /proc/sys/net/ipv4/tcp_keepalive_intvl 2>/dev/null)"
    echo "BASE_KEEPPROBES=$(cat /proc/sys/net/ipv4/tcp_keepalive_probes 2>/dev/null)"
  } > "$BASE" 2>/dev/null
fi
. "$BASE" 2>/dev/null
case "${BASE_KEEPIDLE:-}" in ''|*[!0-9]*) BASE_KEEPIDLE=300 ;; esac
case "${BASE_KEEPINTVL:-}" in ''|*[!0-9]*) BASE_KEEPINTVL=75 ;; esac
case "${BASE_KEEPPROBES:-}" in ''|*[!0-9]*) BASE_KEEPPROBES=9 ;; esac

# The profile owns the keepalive baseline; LPM scales it.
# A fixed "600 for sleep" would have been SHORTER than balanced's own 3600 and caused more
# radio wakeups overnight, not fewer, which is the exact opposite of what this mode is for.
_prof="$(cat /data/adb/asb/active_profile 2>/dev/null)"
[ -n "$_prof" ] || _prof="$(cat "$MODDIR/current_profile" 2>/dev/null)"
case "$_prof" in performance|battery) : ;; *) _prof="balanced" ;; esac
_ka="$(grep -E '^NET_TCP_KEEPIDLE=' "$MODDIR/profiles/${_prof}.sh" 2>/dev/null \
       | head -1 | sed 's/.*=//' | tr -d ' \r"')"
case "$_ka" in ''|*[!0-9]*) _ka="$BASE_KEEPIDLE" ;; esac

# Fast handover is deliberately limited to an awake/normal or fast LPM state.  The
# framework still decides when WiFi is unusable; we only avoid waiting for the modem's data
# context to wake after that decision.  The save/night cases below remain authoritative.
HANDOVER_FAST=0
HANDOVER_ACTIVE=0
case "$(_cfg net_handover_fast)" in
  1) HANDOVER_FAST=1 ;;
esac
case "$(_cfg net_handover_active)" in
  1) HANDOVER_ACTIVE=1; HANDOVER_FAST=1 ;;
esac
STATE_TAG="${MODE}|handover=${HANDOVER_FAST}|active=${HANDOVER_ACTIVE}"

# Re-apply when either LPM or the user-facing handover choice changed. Older state files
# contain only MODE, so the first run after an update safely refreshes them once.
[ -r "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$STATE_TAG" ] && exit 0

case "$MODE" in
  fast)
    # Data call stays up: coming back from an idle RRC state is the latency spike that matters
    # in an online match, and it costs far more than the power saved.
    _sset mobile_data_always_on 1
    # Undo the night probe pair: leaving it set would carry a 3am setting into daytime.
    _sysc net.ipv4.tcp_keepalive_intvl "$BASE_KEEPINTVL"
    _sysc net.ipv4.tcp_keepalive_probes "$BASE_KEEPPROBES"
    _kaf=$((_ka / 4)); [ "$_kaf" -lt 120 ] && _kaf=120
    _sysc net.ipv4.tcp_keepalive_time "$_kaf"
    ;;
  night)
    # Inside the learner's own sleep window: the same idea as "save", taken further.
    #
    # save halves the radio's reasons to wake; night removes most of them. Keepalives go
    # to six times the profile value rather than two - at 3am a socket that checks in
    # every twelve minutes instead of every two costs nothing anyone will notice, and one
    # night capture showed the modem path waking the SoC about a thousand times.
    #
    # Deliberately NOT touched: airplane mode, the radio power state, or anything that
    # could stop a call arriving. Every change here is timing - the phone still rings,
    # high-priority push still lands, and the window came from the user's own nights.
    _sset mobile_data_always_on 0
    _kan=$((_ka * 6)); [ "$_kan" -gt 43200 ] && _kan=43200
    _sysc net.ipv4.tcp_keepalive_time "$_kan"
    # Fewer, later probes once a socket does go quiet: nine retries two seconds apart is
    # a burst of wakeups for a connection that is already idle.
    _sysc net.ipv4.tcp_keepalive_intvl 75
    _sysc net.ipv4.tcp_keepalive_probes 5
    ;;
  save)
    # Screen off. Let the framework drop the always-on data call so the radio can sit
    # idle, and stretch keepalives so fewer sockets drag it back up - that traffic is
    # the biggest single modem drain overnight.
    _sset mobile_data_always_on 0
    # Undo the night probe pair: leaving it set would carry a 3am setting into daytime.
    _sysc net.ipv4.tcp_keepalive_intvl "$BASE_KEEPINTVL"
    _sysc net.ipv4.tcp_keepalive_probes "$BASE_KEEPPROBES"
    _kas=$((_ka * 2)); [ "$_kas" -gt 43200 ] && _kas=43200
    _sysc net.ipv4.tcp_keepalive_time "$_kas"
    ;;
  *)
    MODE="normal"
    STATE_TAG="${MODE}|handover=${HANDOVER_FAST}|active=${HANDOVER_ACTIVE}"
    if [ "$HANDOVER_FAST" = "1" ]; then
      # Keep only the cellular context warm while Android is awake. This does not force a
      # route, toggle WiFi or change OEM signal/roam thresholds; it only removes the modem
      # wake-up delay once ConnectivityService itself leaves weak WiFi.
      _sset mobile_data_always_on 1
    else
      _sset mobile_data_always_on "${BASE_MDAO:-1}"
    fi
    # Hand keepalive straight back to the PROFILE. Restoring the boot-time baseline
    # here would quietly override whatever the active profile asked for the moment the
    # screen came on - the same shape of conflict the Smart tuner had with swappiness.
    _sysc net.ipv4.tcp_keepalive_intvl "$BASE_KEEPINTVL"
    _sysc net.ipv4.tcp_keepalive_probes "$BASE_KEEPPROBES"
    _sysc net.ipv4.tcp_keepalive_time "$_ka"
    ;;
esac

mkdir -p /dev/.asb 2>/dev/null
echo "$STATE_TAG" > "$STATE" 2>/dev/null
exit 0
