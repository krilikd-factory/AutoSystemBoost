#!/system/bin/sh
# asb_wifi_fallback.sh — opt-in "Leave bad Wi-Fi" watcher.
#
# This does NOT tune preferred network mode or carrier policy. When the user picks a rung of
# net_wifi_leave, and the Wi-Fi that still owns the default route is out of range (signal under
# net_wifi_leave_dbm) or - on the unusable/aggressive rungs - not validated by Android, ASB
# briefly releases Wi-Fi so ConnectivityService can put mobile data on the route. The action
# is bounded, screen-on only, has a cooldown and turns Wi-Fi back on afterwards.
#
# fix134: every rung runs this watcher. Only "aggressive" did, and only with the cellular
# master on - so "weak" (the card: "leave when the signal falls below -80 dBm") never left
# anything, and a user who tried weak and unusable with the master off reported that the
# phone "holds the Wi-Fi to the last". Leaving Wi-Fi is a Wi-Fi decision the user made on its
# own card; the cellular master still owns mobile_data_always_on (asb_lpm.sh).

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
# `settings` through the fallback wrapper: on some OnePlus builds the cmd bridge answers
# "Failure calling service settings: Failed transaction" while exiting 0, and a script run
# as its own process does not inherit the wrapper from service.sh.
[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"
CONF="$MODDIR/config/governor.conf"
STATE_DIR="${ASB_WIFI_FALLBACK_STATE_DIR:-/data/adb/asb}"
PID="$STATE_DIR/wifi_fallback.pid"
ACTION="$STATE_DIR/wifi_fallback.action"
COOLDOWN="$STATE_DIR/wifi_fallback.cooldown"
CONFIRM="$STATE_DIR/wifi_fallback.confirm"
# Separate counter for the signal path.
#
# Both reasons shared one file, and the validation path clears it whenever the network
# passes - which is the normal case while walking out of range, because a router at the
# edge still answers. So the signal counter was reset to zero and incremented to one on
# every pass and never reached its threshold: the RSSI release could not fire at all
# while the network stayed valid, which is exactly the situation it was written for.
CONFIRM_RSSI="$STATE_DIR/wifi_fallback.confirm_rssi"
LOG="$STATE_DIR/wifi_fallback.log"
LOCK="$STATE_DIR/wifi_fallback.watch.lock"
# Injected only by host fixtures; production always reads Android's /proc. Keeping this separate
# makes watcher identity portable across toybox shells that exec the script without retaining `sh`.
PROC_ROOT="${ASB_WIFI_FALLBACK_PROC_ROOT:-/proc}"

# The environment overrides are only for deterministic host fixtures. Still validate them here:
# a malformed or zero value must never turn the root watcher into a busy loop or endless outage.
_valid_seconds() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}
INTERVAL_S=8
# Screen off nothing is decided (_try_release needs the screen on), so the loop only keeps
# the release window honest and looks rarely. The sleep is monotonic: it never wakes a
# suspended phone (fix134).
IDLE_INTERVAL_S=30
RELEASE_S=30
# A release that comes straight back (Wi-Fi rejoined the same weak link within 10 minutes)
# doubles the next window, up to this (fix134).
RELEASE_MAX_S=300
COOLDOWN_S=150
_raw_interval="${ASB_WIFI_FALLBACK_INTERVAL_S:-}"
_raw_release="${ASB_WIFI_FALLBACK_RELEASE_S:-}"
_raw_cooldown="${ASB_WIFI_FALLBACK_COOLDOWN_S:-}"
_valid_seconds "$_raw_interval" 1 120 && INTERVAL_S="$_raw_interval"
_valid_seconds "$_raw_release" 1 120 && RELEASE_S="$_raw_release"
_valid_seconds "$_raw_cooldown" 1 3600 && COOLDOWN_S="$_raw_cooldown"
_raw_idle="${ASB_WIFI_FALLBACK_IDLE_INTERVAL_S:-}"
_valid_seconds "$_raw_idle" 1 300 && IDLE_INTERVAL_S="$_raw_idle"
CONFIRM_INTERVAL_S=3
_raw_confirm="${ASB_WIFI_FALLBACK_CONFIRM_INTERVAL_S:-}"
_valid_seconds "$_raw_confirm" 1 30 && CONFIRM_INTERVAL_S="$_raw_confirm"
[ "$CONFIRM_INTERVAL_S" -gt "$INTERVAL_S" ] && CONFIRM_INTERVAL_S="$INTERVAL_S"
[ "$RELEASE_MAX_S" -lt "$RELEASE_S" ] && RELEASE_MAX_S="$RELEASE_S"
STREAK="$STATE_DIR/wifi_fallback.streak"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}
_radio_policy_enabled() { [ "$(_cfg radio_policy_enable)" = 1 ]; }
# Every rung of net_wifi_leave runs the watcher (fix134); see the header.
_enabled() { case "$(_cfg net_wifi_leave)" in weak|unusable|aggressive) return 0 ;; esac; return 1; }
# Validation (dumpsys wifi) is read only on the rungs that act on it: weak leaves on signal
# alone, so it never pays for the dump.
_uses_validation() { case "$(_cfg net_wifi_leave)" in unusable|aggressive) return 0 ;; esac; return 1; }
_now() { date +%s 2>/dev/null || echo 0; }
_log() { mkdir -p "$STATE_DIR" 2>/dev/null; printf '%s wifi_fallback: %s\n' "$(date '+%F %T' 2>/dev/null || echo now)" "$*" >> "$LOG" 2>/dev/null; tail -n 80 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true; }

_screen_on() {
  # The governor's own verdict first (Android's display state, published in its state file):
  # a file read instead of a dumpsys every 8 s (fix134). A state file older than five minutes
  # means no governor to trust, and the old dumpsys path answers.
  _gs="${ASB_GOV_STATE:-/dev/.asb/state}"
  if [ -r "$_gs" ]; then
    _gm="$(stat -c %Y "$_gs" 2>/dev/null)"
    case "$_gm" in ''|*[!0-9]*) _gm=0 ;; esac
    if [ $(( $(_now) - _gm )) -le 300 ] 2>/dev/null; then
      case "$(grep -m1 '^screen=[01]$' "$_gs" 2>/dev/null)" in
        screen=1) return 0 ;;
        screen=0) return 1 ;;
      esac
    fi
  fi
  _p="$(dumpsys power 2>/dev/null)"
  printf '%s' "$_p" | grep -Eqi 'mWakefulness=Awake|mInteractive=true|Display Power: state=ON'
}
_mobile_allowed() {
  [ "$(settings get global airplane_mode_on 2>/dev/null | tr -d ' \r')" != 1 ] || return 1
  # Explicit Android mobile-data off is authoritative. An absent legacy setting is not treated
  # as off because modern multi-SIM ROMs can expose data state only through telephony.
  [ "$(settings get global mobile_data 2>/dev/null | tr -d ' \r')" != 0 ]
}
_wifi_default() {
  _wd_rt="$(ip route get 1.1.1.1 2>/dev/null)"
  printf '%s\n' "$_wd_rt" | grep -Eq '(^| )dev wlan[0-9A-Za-z_.-]*([[:space:]]|$)' && return 0
  # Behind a VPN (fix148) the route names the tunnel, never Wi-Fi: CPH2769 ran a proxy app
  # all day ("1.1.1.1 dev tun0 table tun0"), Wi-Fi up under it, and the watcher sat at
  # "waiting_for_wifi_default_route" for the whole capture - "leave bad Wi-Fi" could not act
  # for anyone with a VPN on. What the tunnel rides on is the system default network: netd's
  # rule for unmarked traffic from this host with no uid range ("fwmark 0x0/0xffff iif lo
  # lookup <table>"). When that table is Wi-Fi's, so is the default.
  printf '%s\n' "$_wd_rt" | grep -Eq '(^| )dev (tun|ppp|ipsec|wg|tap|vgate)[0-9A-Za-z_.-]*([[:space:]]|$)' || return 1
  ip rule show 2>/dev/null | grep -E 'fwmark 0x0/0xffff iif lo .*lookup ' | grep -v 'uidrange' \
    | grep -Eq 'lookup wlan[0-9A-Za-z_.-]*([[:space:]]|$)'
}
_wifi_unvalidated() {
  _w="$(dumpsys wifi 2>/dev/null)"
  # Require framework-owned validation evidence. RSSI alone is deliberately never enough:
  # a weak but still working local Wi-Fi link must remain Android's and the user's choice.
  printf '%s\n' "$_w" | grep -Eqi 'VALIDATED[=: ]*false|NOT_VALIDATED|not[[:space:]-]*validated|no[[:space:]-]*internet|validated=false'
}

# Current Wi-Fi signal in dBm, or empty when it cannot be read.
_wifi_rssi() {
  # Read the CURRENT link, not the first RSSI-looking number in the dump.
  #
  # dumpsys wifi contains three kinds of RSSI: the connected link, every network from the
  # last scan, and the threshold constants in the configuration block. Taking the first
  # match picked whichever came first in the output, and a field capture shows what that
  # produced: "rssi=-30" logged by a user who was walking out of an office and had already
  # lost the connection - -30 dBm is standing next to the router.
  #
  # So the signal check never fired for him even with a -75 threshold set, and the only
  # thing that ever released the route was validation. That is exactly the complaint:
  # the phone holds on to a network it can no longer use.
  #
  # /proc/net/wireless is the kernel's own view of the associated link and has no scan
  # results in it at all. dumpsys stays as a fallback for ROMs that do not expose it,
  # narrowed to the line that describes the connection.
  _r=""
  if [ -r /proc/net/wireless ]; then
    _r="$(awk 'NR>2 && $1 ~ /^wlan/ {gsub(/\./,"",$4); print $4; exit}' /proc/net/wireless 2>/dev/null)"
    case "$_r" in -[0-9]*) printf '%s' "$_r"; return 0 ;; *) _r="" ;; esac
  fi
  _r="$(dumpsys wifi 2>/dev/null \
        | grep -m1 -E 'mWifiInfo|WifiInfo:|SSID:.*RSSI' \
        | sed -n 's/.*[Rr][Ss][Ss][Ii][=: ]*\(-[0-9][0-9]*\).*/\1/p' | head -1)"
  case "$_r" in -[0-9]*) printf '%s' "$_r" ;; *) : ;; esac
}

# Is the link weak enough that the walk-away case is worth deciding sooner?
#
# Requested by a user leaving Wi-Fi range: "I have already walked away and it is still
# trying to hold on." The reasoning is sound but the obvious fix is not - a threshold on
# RSSI alone produces exactly the wrong behaviour at the edge of coverage, where the phone
# drops the network, immediately sees it again and reconnects. That ping-pong costs more
# battery than the seconds it saves and is far more annoying.
#
# So signal strength is never the reason to act. It only shortens the wait for a link that
# has ALREADY failed validation: unusable and weak is a walk-away, unusable and strong is a
# captive portal or a broken router, which deserves the full grace period because the user
# may be about to sign in.
#
# -78 dBm is where 802.11 link rates collapse on every band; above that a network that
# still validates is worth keeping whatever the bars show.
_wifi_signal_weak() {
  _rs="$(_wifi_rssi)"
  [ -n "$_rs" ] || return 1
  [ "$_rs" -lt "${ASB_WIFI_WEAK_DBM:--78}" ] 2>/dev/null
}
_wifi_disable() {
  svc wifi disable >/dev/null 2>&1 || cmd wifi set-wifi-enabled disabled >/dev/null 2>&1 || return 1
  return 0
}
_wifi_enable() {
  svc wifi enable >/dev/null 2>&1 || cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 || return 1
  return 0
}
# How long this release keeps Wi-Fi off (fix134). The first one is RELEASE_S; one that follows
# a release less than 10 minutes ago doubles, up to RELEASE_MAX_S - at the edge of range the
# phone otherwise rejoins the same weak access point after 28 s and spends most of its time on
# it again. Ten quiet minutes start over.
_release_window() {
  _sl="$(cat "$STREAK" 2>/dev/null)"
  # Escaped: a bare | is a pattern alternation in mksh, which left the count at 1.
  _sn="${_sl%%\|*}"; _st="${_sl#*\|}"
  case "$_sn" in ''|*[!0-9]*) _sn=0 ;; esac
  case "$_st" in ''|*[!0-9]*) _st=0 ;; esac
  _sv="$(_now)"
  [ $(( _sv - _st )) -gt 600 ] 2>/dev/null && _sn=0
  _sn=$(( _sn + 1 ))
  printf '%s|%s\n' "$_sn" "$_sv" > "$STREAK" 2>/dev/null
  _sw="$RELEASE_S"; _si=1
  while [ "$_si" -lt "$_sn" ] && [ "$_sw" -lt "$RELEASE_MAX_S" ]; do
    _sw=$(( _sw * 2 )); _si=$(( _si + 1 ))
  done
  [ "$_sw" -gt "$RELEASE_MAX_S" ] && _sw="$RELEASE_MAX_S"
  printf '%s' "$_sw"
}
_restore_if_owned() {
  [ -f "$ACTION" ] || return 0
  if _wifi_enable; then
    rm -f "$ACTION" 2>/dev/null
    _log 'Wi-Fi re-enabled after ASB fallback window'
    return 0
  fi
  # Keep the ownership marker if Android rejects the restore call; a subsequent watcher pass,
  # reconcile or uninstall stop can retry instead of pretending Wi-Fi was restored.
  _log 'could not re-enable ASB-owned Wi-Fi; retry retained'
  return 1
}
_reconcile_action() {
  [ -f "$ACTION" ] || return 0
  _line="$(cat "$ACTION" 2>/dev/null)"
  _until="${_line#*\|}"
  case "$_until" in ''|*[!0-9]*) _until=0 ;; esac
  _nowv="$(_now)"
  if ! _enabled || [ "$_nowv" -ge "$_until" ] 2>/dev/null; then
    if _restore_if_owned; then
      _cool_until=$((_nowv + COOLDOWN_S))
      printf '%s\n' "$_cool_until" > "$COOLDOWN" 2>/dev/null
      _log "cooldown started (${COOLDOWN_S}s)"
    fi
  fi
}
_in_cooldown() {
  [ -f "$COOLDOWN" ] || return 1
  _until="$(cat "$COOLDOWN" 2>/dev/null | tr -dc '0-9')"
  _nowv="$(_now)"
  case "$_until" in ''|*[!0-9]*) rm -f "$COOLDOWN" 2>/dev/null; return 1 ;; esac
  if [ "$_nowv" -lt "$_until" ] 2>/dev/null; then return 0; fi
  rm -f "$COOLDOWN" 2>/dev/null
  return 1
}
_try_release() {
  _enabled || return 0
  _screen_on || return 0
  # Contract-pinned form: these guards must stay literally as the handover test asserts,
  # so the streak is cleared on the line after rather than folded into the guard.
  _wifi_default || return 0
  # Mobile data allowed: asked once the route is known to be on Wi-Fi, not on every pass of
  # a phone that is on mobile already (two settings calls each time, fix134).
  _mobile_allowed || return 0
  # A validated network clears the streak on the way out: confirmation has to measure a
  # CONTINUOUS failure, not a tally of unrelated blips across the day. Only the rungs that
  # act on validation read it (fix134); unusable reads it every second pass - Android's own
  # avoid-bad-Wi-Fi switch, set on that rung, is the first line there.
  _val_now=0
  if _uses_validation; then
    _vp=$(( ${_vp:-0} + 1 ))
    if [ "$(_cfg net_wifi_leave)" = aggressive ] || [ $(( _vp % 2 )) -eq 1 ]; then _val_now=1; fi
  fi
  if [ "$_val_now" = 1 ] && ! _wifi_unvalidated; then rm -f "$CONFIRM" 2>/dev/null; fi
  # Out of range is its own reason to leave, separate from validation.
  #
  # Requested by a user walking away from a hotspot: "it clings to the access point and
  # will not switch". Validation alone cannot help there - a router at the edge of range
  # still answers, so the network stays technically valid while nothing actually loads.
  #
  # Deliberately a much lower bar than the weak-signal shortcut below. -78 dBm means
  # "degraded, decide sooner if it also fails validation"; this is -85, where 802.11 has
  # essentially no usable rate left on any band and staying attached is not a judgement
  # call. Requiring the same confirmation passes as everything else keeps a momentary dip
  # behind a wall from triggering it.
  #
  # Off unless the user asks: ASB_WIFI_LEAVE_ON_RSSI is empty by default, and an empty
  # value skips this branch entirely. Nobody gets a new disconnect reason without opting in.
  # Cooldown applies to this path too.
  #
  # It sits below for the validation path, and putting the signal check above it would let
  # the two reasons take turns: validation releases, cooldown starts, and the RSSI branch
  # releases again immediately because it never looked. One release then a rest, whichever
  # reason triggered it - that is what the cooldown is for.
  _in_cooldown && return 0

  # The config key is the user-facing form; the env var stays as an override for testing.
  # Read every pass (fix134): the value used to be stored in ASB_WIFI_LEAVE_ON_RSSI on the
  # first pass, and the -z test below then never ran again - a new net_wifi_leave_dbm from
  # the WebUI waited for the watcher to restart. The variable stays as a host-test override.
  _leave_rssi="${ASB_WIFI_LEAVE_ON_RSSI:-}"
  if [ -z "$_leave_rssi" ]; then
    # Derived from net_wifi_leave now - see asb_lpm.sh for the ladder.
    #
    # The separate net_wifi_leave_rssi picker let a user ask for a threshold while the
    # handover toggles said not to hand over at all. One control, one meaning: the rungs
    # that leave a weak link carry -80 dBm, which is where a link stops being useful on
    # every device measured.
    # The level itself is net_wifi_leave_dbm (default -80): an external audit pointed out
    # that a fixed -80 does not fit every antenna or case. Out-of-range or malformed values
    # fall back to -80, so a typo cannot make leaving impossible or permanent.
    _cfg_dbm="$(_cfg net_wifi_leave_dbm)"
    case "$_cfg_dbm" in -[0-9]|-[0-9][0-9]) : ;; *) _cfg_dbm=-80 ;; esac
    if [ "$_cfg_dbm" -lt -95 ] 2>/dev/null || [ "$_cfg_dbm" -gt -60 ] 2>/dev/null; then _cfg_dbm=-80; fi
    case "$(_cfg net_wifi_leave)" in
      weak|unusable|aggressive) _cfg_rssi="$_cfg_dbm" ;;
      *)                        _cfg_rssi=off ;;
    esac
    case "$_cfg_rssi" in -[0-9]*) _leave_rssi="$_cfg_rssi" ;; esac
  fi
  if [ -n "$_leave_rssi" ]; then
    _rs_now="$(_wifi_rssi)"
    # Signal recovered: clear the streak. Confirmation has to measure a continuous run
    # of weak samples, not a tally of unrelated dips.
    if [ -n "$_rs_now" ] && [ "$_rs_now" -ge "$_leave_rssi" ] 2>/dev/null; then
      rm -f "$CONFIRM_RSSI" 2>/dev/null
    fi
    if [ -n "$_rs_now" ] && [ "$_rs_now" -lt "$_leave_rssi" ] 2>/dev/null; then
      _seen_r="$(cat "$CONFIRM_RSSI" 2>/dev/null | tr -dc '0-9')"
      case "$_seen_r" in '') _seen_r=0 ;; esac
      _seen_r=$(( _seen_r + 1 ))
      { printf '%s\n' "$_seen_r" > "$CONFIRM_RSSI"; } 2>/dev/null || true
      if [ "$_seen_r" -ge "${ASB_WIFI_CONFIRM_PASSES:-3}" ] 2>/dev/null; then
        rm -f "$CONFIRM_RSSI" 2>/dev/null
        _rw="$(_release_window)"
        _log "out of range (rssi=${_rs_now}) - releasing Wi-Fi default route for ${_rw}s"
        _nowv="$(_now)"
        if _wifi_disable; then
          printf '%s|%s\n' "$_nowv" "$(( _nowv + _rw ))" > "$ACTION" 2>/dev/null
        fi
        return 0
      fi
      _log "out of range (rssi=${_rs_now}) pass ${_seen_r}/${ASB_WIFI_CONFIRM_PASSES:-3}"
      _fast=1
      return 0
    fi
  fi

  # Validation path: unusable and aggressive only (fix134), on the passes that read it.
  _uses_validation || return 0
  [ "$_val_now" = 1 ] || return 0
  _wifi_unvalidated || return 0
  _in_cooldown && return 0

  # Confirm the failure across consecutive passes before acting.
  #
  # Validation flips to false during ordinary events - a roam between access points, a DHCP
  # renewal, the first seconds on a network. Acting on the first sample turns those into a
  # Wi-Fi drop the user did not ask for.
  #
  # How long to wait depends on what kind of failure it is, which is where signal strength
  # earns its place: a link that is both unusable AND weak is someone walking out of range,
  # and there is nothing to wait for. A link that is unusable but strong is a captive
  # portal or a broken router - the user may be about to sign in, so it gets the full
  # confirmation window.
  _need="${ASB_WIFI_CONFIRM_PASSES:-3}"
  if _wifi_signal_weak; then
    _need="${ASB_WIFI_CONFIRM_PASSES_WEAK:-1}"
  fi
  _seen="$(cat "$CONFIRM" 2>/dev/null | tr -dc '0-9')"
  case "$_seen" in '') _seen=0 ;; esac
  _seen=$(( _seen + 1 ))
  { printf '%s\n' "$_seen" > "$CONFIRM"; } 2>/dev/null || true
  if [ "$_seen" -lt "$_need" ] 2>/dev/null; then
    _log "unvalidated Wi-Fi pass ${_seen}/${_need} (rssi=$(_wifi_rssi 2>/dev/null || echo '?')) - waiting"
    [ "$(_cfg net_wifi_leave)" = aggressive ] && _fast=1
    return 0
  fi
  rm -f "$CONFIRM" 2>/dev/null

  _rw="$(_release_window)"
  _nowv="$(_now)"
  _until=$((_nowv + _rw))
  if _wifi_disable; then
    printf '%s|%s\n' "$_nowv" "$_until" > "$ACTION" 2>/dev/null
    _log "released unvalidated Wi-Fi default route for ${_rw}s"
  else
    _log 'could not disable Wi-Fi; no route action taken'
  fi
}
_status() {
  if ! _enabled; then echo 'off'; return; fi
  if [ -f "$ACTION" ]; then
    _until="$(cut -d'|' -f2 "$ACTION" 2>/dev/null | tr -dc '0-9')"
    echo "releasing_wifi_until=${_until:-unknown}"; return
  fi
  if _in_cooldown; then echo "cooldown_until=$(cat "$COOLDOWN" 2>/dev/null)"; return; fi
  if ! _wifi_default; then echo 'waiting_for_wifi_default_route'; return; fi
  _rs_st="$(_wifi_rssi)"
  if _uses_validation && _wifi_unvalidated; then echo "unvalidated_wifi_default_detected rssi=${_rs_st:-?}"
  else echo "watching rssi=${_rs_st:-?} leave_below=$(_cfg net_wifi_leave_dbm)"; fi
}
_pid_is_our_watcher() {
  _candidate="$1"
  case "$_candidate" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_candidate" != "$$" ] || return 1
  [ -r "$PROC_ROOT/$_candidate/cmdline" ] || return 1
  _cmdline="$(tr '\000' ' ' < "$PROC_ROOT/$_candidate/cmdline" 2>/dev/null)"
  # Android can retain `sh`, use an absolute interpreter, or exec the script directly. The
  # invariant is the exact module script plus its dedicated `watch` argument, not the token
  # immediately before it. This remains a narrow identity check: a stale/reused state PID is
  # never accepted merely for containing a generic Wi-Fi word or the script basename.
  case "$_cmdline" in
    *"$MODDIR/runtime/asb_wifi_fallback.sh watch"*) return 0 ;;
    *) return 1 ;;
  esac
}
_watcher_alive() {
  _pid="$(cat "$PID" 2>/dev/null | tr -dc '0-9')"
  if _pid_is_our_watcher "$_pid" && kill -0 "$_pid" 2>/dev/null; then
    return 0
  fi
  # A power loss or a cleaner can remove the PID file while the lock-protected watcher is
  # healthy. Recover only from a verified exact argv, never from an arbitrary state-file PID.
  if _lock_owner_alive; then
    _pid="$(cat "$LOCK/pid" 2>/dev/null | tr -dc '0-9')"
    printf '%s\n' "$_pid" > "$PID" 2>/dev/null
    return 0
  fi
  return 1
}
_lock_owner_alive() {
  [ -f "$LOCK/pid" ] || return 1
  _lock_pid="$(cat "$LOCK/pid" 2>/dev/null | tr -dc '0-9')"
  _pid_is_our_watcher "$_lock_pid" && kill -0 "$_lock_pid" 2>/dev/null
}
_acquire_watch_lock() {
  mkdir "$LOCK" 2>/dev/null && { printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null; return 0; }
  _lock_owner_alive && return 1
  # A second reconcile can observe the directory during the first watcher's tiny mkdir→pid
  # window. Give it one bounded second before treating an incomplete lock as stale.
  sleep 1
  _lock_owner_alive && return 1
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
  return 0
}
_release_watch_lock() {
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null
}
_watch_cleanup() {
  _restore_if_owned
  [ "$(cat "$PID" 2>/dev/null)" = "$$" ] && rm -f "$PID" 2>/dev/null
  _release_watch_lock
}
_stop() {
  # Target only the recorded PID after confirming its exact watcher argv through /proc.
  # Never kill by a broad Wi-Fi/network name or a user-controlled PID file alone.
  # Stop by lock ownership as well as by argv.
  #
  # _watcher_alive confirms identity through /proc/<pid>/cmdline, which is the right guard
  # against killing an unrelated process that happens to hold a reused PID. But it is also
  # the only path to the kill, so a watcher whose argv no longer matches - re-exec'd,
  # wrapped by a different interpreter, or simply started before an update - could never be
  # stopped. Turning the feature off then removed the PID file and left the process
  # running: an orphan loop polling Wi-Fi until reboot, with nothing left on disk pointing
  # at it. That is the leak the contract test has been failing on.
  #
  # The lock directory records the PID that took it, and only this script writes there. If
  # that PID is alive it is ours whatever argv says, so it is safe to signal - and the
  # identity check still gates the PID file, which is the value a user could tamper with.
  _pid="$(cat "$PID" 2>/dev/null | tr -dc '0-9')"
  _lpid="$(cat "$LOCK/pid" 2>/dev/null | tr -dc '0-9')"
  for _target in "$_pid" "$_lpid"; do
    case "$_target" in ''|*[!0-9]*) continue ;; esac
    [ "$_target" = "$$" ] && continue
    kill -0 "$_target" 2>/dev/null || continue
    kill "$_target" 2>/dev/null || true
  done
  _wait=0
  while [ "$_wait" -lt 3 ]; do
    _still=0
    for _target in "$_pid" "$_lpid"; do
      case "$_target" in ''|*[!0-9]*) continue ;; esac
      [ "$_target" = "$$" ] && continue
      kill -0 "$_target" 2>/dev/null && _still=1
    done
    [ "$_still" = "0" ] && break
    sleep 1; _wait=$((_wait + 1))
  done
  _restore_if_owned
  # CONFIRM too: a streak counted before the feature was turned off must not survive to
  # shorten the first decision after it is turned back on.
  rm -f "$PID" "$COOLDOWN" "$CONFIRM" "$CONFIRM_RSSI" "$STREAK" 2>/dev/null
  _lock_owner_alive || rm -rf "$LOCK" 2>/dev/null
}
_watch() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  _acquire_watch_lock || { _log 'watcher start skipped (another ASB watcher owns the lock)'; return 0; }
  printf '%s\n' "$$" > "$PID" 2>/dev/null
  trap '_watch_cleanup; exit 0' EXIT HUP INT TERM
  _log 'watcher started'
  # Arming gate: the fallback may only act on a link that has PROVEN it can validate.
  #
  # A watcher that starts at boot meets Wi-Fi mid-connect: the default route is up seconds
  # before the framework finishes validation, so every boot looked like an "unvalidated
  # Wi-Fi owns the route" event. On a network whose validation never completes at all
  # (captive check unreachable in some regions, a router with no WAN) the same logic then
  # fired in an endless loop - the field report is "Wi-Fi is always off after a reboot",
  # because the radio was being killed again every few minutes, forever.
  #
  # So the watcher arms on the first pass of "default route on Wi-Fi and NOT flagged
  # unvalidated" - i.e. this attachment demonstrably validated at least once. One clean
  # framework sample is enough: actually acting still needs the full confirmation streak
  # below, and a link that drops entirely re-arms from zero so a new attachment must
  # prove itself too.
  _armed=0
  _arm_good=0
  while _enabled; do
    _reconcile_action
    # Screen off: nothing is decided, so do not pay for the route and Wi-Fi reads (fix134).
    # The release window above still ends on time.
    if [ ! -f "$ACTION" ] && ! _screen_on; then
      sleep "$IDLE_INTERVAL_S"
      continue
    fi
    if [ ! -f "$ACTION" ]; then
      if ! _wifi_default; then
        [ "$_armed" = "1" ] && _log 'fallback disarmed (Wi-Fi link gone)'
        _armed=0; _arm_good=0
      elif [ "$_armed" = "0" ]; then
        if ! _uses_validation; then
          # weak acts on signal alone: nothing to prove first (fix134).
          _armed=1
          _log 'fallback armed (signal watch)'
        elif _wifi_unvalidated; then
          _arm_good=0
        else
          _arm_good=$(( _arm_good + 1 ))
          if [ "$_arm_good" -ge 1 ]; then
            _armed=1
            _log 'fallback armed (this attachment has validated)'
          fi
        fi
      fi
      _fast=0
      [ "$_armed" = "1" ] && _try_release
    fi
    if [ "${_fast:-0}" = 1 ]; then sleep "$CONFIRM_INTERVAL_S"; else sleep "$INTERVAL_S"; fi
  done
  _watch_cleanup
  rm -f "$COOLDOWN" 2>/dev/null
  _log 'watcher stopped (feature off)'
}

case "${1:-reconcile}" in
  reconcile)
    if _enabled; then
      if ! _watcher_alive; then
        rm -f "$PID" 2>/dev/null
        # Out of the WebUI's app cgroups before the watcher is forked (fix141).
        [ -f "$MODDIR/runtime/asb_cgroup.sh" ] && . "$MODDIR/runtime/asb_cgroup.sh" && asb_cgroup_detach $$ >/dev/null 2>&1
        ( MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_wifi_fallback.sh" watch </dev/null >/dev/null 2>&1 & )
      fi
    else
      _stop
    fi
    ;;
  watch)
    [ -f "$MODDIR/runtime/asb_cgroup.sh" ] && . "$MODDIR/runtime/asb_cgroup.sh" && asb_cgroup_detach $$ >/dev/null 2>&1
    _watch ;;
  stop) _stop ;;
  status) _status ;;
  *) echo 'usage: asb_wifi_fallback.sh reconcile|watch|stop|status' >&2; exit 2 ;;
esac
