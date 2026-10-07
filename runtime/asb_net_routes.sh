#!/system/bin/sh
# asb_net_routes.sh - initial congestion / receive window, chosen per link.
#
# WHY THIS IS NOT THE USUAL initcwnd SCRIPT
#
# The common approach writes `initcwnd 10 initrwnd <rmem/mtu, capped at 20>` onto every
# route, re-runs itself from a `while true; sleep` loop, and drops every open TCP
# connection when the congestion algorithm changes. Each of those three is a real problem:
#
# * initcwnd 10 is RFC 6928's value for the general internet.
# One number cannot be right for both.
#
# So: the window is derived from the link actually in front of us, the re-apply is
# event-driven with no loop, and nothing is ever disconnected.
#
#   net_route_tune   auto | off | conservative | aggressive
#
# auto classify the link and pick (default) conservative RFC value everywhere - the safe floor
# aggressive one class higher than measured, for people who know their link off restore what
# the routes had before ASB touched them
#
# Usage: asb_net_routes.sh [apply|restore|watch]

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE="/data/adb/asb/net_routes_orig"
MODE="${1:-apply}"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}
_has() { command -v "$1" >/dev/null 2>&1; }
# iproute2, never the root manager's BusyBox applet. KernelSU and Magisk put their BusyBox
# first on PATH, and its `ip` has no `monitor`, `initcwnd` or `congctl`: a fix44 diag shows
# "ip_monitor_ended after 0s: BusyBox v1.36.1.1 ... Usage: ip [OPTIONS]", every window
# change refused, and per-route congctl reported "not in use". Android's own binary is
# /system/bin/ip; PATH is only the fallback.
ASB_IP=""
for _ipb in /system/bin/ip /system/xbin/ip /vendor/bin/ip; do
  [ -x "$_ipb" ] && { ASB_IP="$_ipb"; break; }
done
[ -n "$ASB_IP" ] || ASB_IP="$(command -v ip 2>/dev/null)"
[ -n "$ASB_IP" ] || ASB_IP=ip
[ -x "$ASB_IP" ] || _has "$ASB_IP" || { echo "net_routes: no ip(8), nothing to do"; exit 0; }

# --- link classification --------------------------------------------------------------
#
# Returns a class name on stdout. The inputs are all cheap reads of what the kernel
# already knows - no probing, no traffic generated.
#
#   fast    WiFi 5/6 or 5G-class: high rate, low loss, deep buffers upstream
#   normal  ordinary 4G / 2.4 GHz WiFi
#   weak    anything reporting a low negotiated rate, or a link we cannot measure
#
# Unmeasurable links deliberately fall to "weak", not to "normal". Being wrong upwards
# costs retransmits on someone's metered connection; being wrong downwards costs a few
# milliseconds on the first round trip.
_classify_link() {
  _cl_if="$1"
  _cl_rate=""

  # Wired/tethered links report negotiated speed directly, in Mbit/s.
  [ -r "/sys/class/net/$_cl_if/speed" ] && \
    _cl_rate="$(cat "/sys/class/net/$_cl_if/speed" 2>/dev/null)"

  # WiFi: the negotiated bitrate is the honest number, not the band. A 6 GHz link
  # sitting at 60 Mbit/s behind a wall is not a fast link, whatever its name suggests.
  if [ -z "$_cl_rate" ] && _has iw; then
    _cl_rate="$(iw dev "$_cl_if" link 2>/dev/null \
                | grep -m1 -oE 'tx bitrate: [0-9]+' | grep -oE '[0-9]+')"
  fi

  case "$_cl_rate" in
    ''|*[!0-9]*) : ;;
    *)
      [ "$_cl_rate" -ge 300 ] 2>/dev/null && { echo fast;   return; }
      [ "$_cl_rate" -ge 50  ] 2>/dev/null && { echo normal; return; }
      [ "$_cl_rate" -gt 0   ] 2>/dev/null && { echo weak;   return; }
      ;;
  esac

  # Mobile with no rate exposed: use the radio technology as a coarse stand-in.
  case "$_cl_if" in
    rmnet*|ccmni*|wwan*)
      _cl_rat="$(getprop gsm.network.type 2>/dev/null)"
      case "$_cl_rat" in
        # Most specific first. *LTE_CA* after *LTE* was unreachable - carrier aggregation
        # was being classed as plain LTE, which happened to give the same answer here but
        # is the kind of dead branch that becomes a real bug the moment the two need to
        # differ. CA aggregates carriers and behaves closer to 5G than to single-carrier
        # LTE, so it gets the faster window.
        *NR*|*5G*)          echo fast;   return ;;
        *LTE_CA*|*LTE-CA*)  echo fast;   return ;;
        *LTE*)              echo normal; return ;;
        *)                  echo weak;   return ;;
      esac
      ;;
  esac
  echo weak
}

# --- window sizing ---------------------------------------------------------------------
#
# initcwnd: how many segments may go out before the first ACK.
#
# initrwnd: how much the receiver advertises up front. Sized from the bandwidth-delay
# product rather than a flat cap, because the flat cap is what makes the setting useless
# on a fast link and harmful on a slow one:
#
#   BDP_bytes = rate_bits/8 * rtt_s      -> segments = BDP / MSS
#
# with rtt taken as a conservative 60 ms (typical mobile RTT to a nearby CDN edge) and the
# result bounded by what the receive buffer can actually hold. Advertising more than the
# buffer can store is a promise the kernel cannot keep.
_window_for() {
  _wf_class="$1"; _wf_mtu="$2"; _wf_rate="$3"
  _wf_mss=$(( _wf_mtu - 40 ))
  [ "$_wf_mss" -lt 536 ] 2>/dev/null && _wf_mss=536

  case "$_wf_class" in
    fast)   _wf_cwnd=24 ;;
    normal) _wf_cwnd=16 ;;
    *)      _wf_cwnd=10 ;;
  esac

  # Ceiling from the receive buffer the kernel is actually willing to give us.
  _wf_rmax="$(awk '{print $3}' /proc/sys/net/ipv4/tcp_rmem 2>/dev/null)"
  case "$_wf_rmax" in ''|*[!0-9]*) _wf_rmax=6291456 ;; esac
  _wf_buf_seg=$(( _wf_rmax / _wf_mss ))

  # BDP ceiling, when we have a rate to work from.
  _wf_bdp_seg=0
  case "$_wf_rate" in
    ''|*[!0-9]*) : ;;
    *) [ "$_wf_rate" -gt 0 ] 2>/dev/null && \
         _wf_bdp_seg=$(( _wf_rate * 125000 * 60 / 1000 / _wf_mss )) ;;
  esac

  _wf_rwnd="$_wf_buf_seg"
  [ "$_wf_bdp_seg" -gt 0 ] 2>/dev/null && [ "$_wf_bdp_seg" -lt "$_wf_rwnd" ] && \
    _wf_rwnd="$_wf_bdp_seg"

  # Never below the cwnd (pointless), never absurd.
  [ "$_wf_rwnd" -lt "$_wf_cwnd" ] 2>/dev/null && _wf_rwnd="$_wf_cwnd"
  [ "$_wf_rwnd" -gt 64 ] 2>/dev/null && _wf_rwnd=64

  echo "$_wf_cwnd $_wf_rwnd"
}

# --- record originals once, so "off" and uninstall can put them back --------------------
# Default routes from EVERY table.
#
# Android keeps no default route in the main table: each network gets its own table
# ("default via 10.46.26.44 dev rmnet_data2 table rmnet_data2 proto static"), and ip rules
# pick the table per uid and mark. `ip route show` reads only main, so on every Android
# phone this tuning found no route, applied nothing, and the report said "waiting for a
# link" forever. The lines from `table all` carry their "table X" token, so passing one
# back to `ip route change` addresses exactly the route it came from.
_defaults() {
  if [ "$1" = 6 ]; then "$ASB_IP" -6 route show table all 2>/dev/null
  else "$ASB_IP" route show table all 2>/dev/null; fi | grep '^default'
}

_save_orig() {
  [ -f "$STATE" ] && grep -q ' table ' "$STATE" 2>/dev/null && return 0
  mkdir -p /data/adb/asb 2>/dev/null
  { _defaults 4; _defaults 6; } > "$STATE" 2>/dev/null
}

_restore() {
  [ -f "$STATE" ] || { echo "net_routes: nothing recorded, nothing to restore"; return 0; }
  _rn=0
  while IFS= read -r _rl; do
    [ -n "$_rl" ] || continue
    case "$_rl" in *initcwnd*|*initrwnd*) : ;; *) : ;; esac
    case "$_rl" in
      *:*) "$ASB_IP" -6 route change $_rl >/dev/null 2>&1 && _rn=$((_rn+1)) ;;
      *)   "$ASB_IP" route change $_rl    >/dev/null 2>&1 && _rn=$((_rn+1)) ;;
    esac
  done < "$STATE"
  rm -f "$STATE" 2>/dev/null
  echo "net_routes: restored $_rn route(s)"
}

# --- apply -------------------------------------------------------------------------------
_apply() {
  _mode="$(_cfg net_route_tune)"
  case "$_mode" in
    ''|auto) _mode=auto ;;
    off) _restore
         # "off" is a successful application of the stock state, not an absence of one -
         # the badge needs a token either way or it cannot tell "restored" from "never ran".
         printf 'net_route_tune=ok\n' >> /data/adb/asb/net_apply_result 2>/dev/null
         return 0 ;;
    conservative|aggressive) : ;;
    *) _mode=auto ;;
  esac

  _save_orig
  _done=0; _report=""

  # Only default routes: those are the ones carrying traffic off-device. Rewriting every
  # on-link subnet route achieves nothing and multiplies the chances of mangling one.
  for _fam in 4 6; do
    if [ "$_fam" = "4" ]; then _ipc="$ASB_IP"; else _ipc="$ASB_IP -6"; fi
    _defaults "$_fam" | while IFS= read -r _rt; do
      _if="$(printf '%s' "$_rt" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
      [ -n "$_if" ] || continue
      # Placeholder and loopback tables carry a default too; none of them moves traffic.
      case "$_if" in lo|dummy*|ifb*|sit*|ip6tnl*|tun*|vgate*) continue ;; esac
      _tbl="$(printf '%s' "$_rt" | sed -n 's/.* table \([^ ]*\).*/\1/p')"
      # The interface came FROM a default route, so it is carrying traffic by definition.
      # rmnet reports operstate "unknown" even then (virtual link over the modem IPA
      # path), so requiring "up" skipped every mobile route and net_route_tune silently
      # never touched them. Accept "unknown" when IFF_UP is set; "down" stays excluded.
      _ost="$(cat "/sys/class/net/$_if/operstate" 2>/dev/null)"
      case "$_ost" in
        up) : ;;
        unknown)
          _fl="$(cat "/sys/class/net/$_if/flags" 2>/dev/null)"
          case "$_fl" in ''|*[!0-9a-fAxX]*) continue ;; esac
          [ $(( _fl & 1 )) -eq 1 ] 2>/dev/null || continue
          ;;
        *) continue ;;
      esac

      _mtu="$(cat "/sys/class/net/$_if/mtu" 2>/dev/null)"
      case "$_mtu" in ''|*[!0-9]*) _mtu=1500 ;; esac

      _rate=""
      [ -r "/sys/class/net/$_if/speed" ] && _rate="$(cat "/sys/class/net/$_if/speed" 2>/dev/null)"
      _class="$(_classify_link "$_if")"

      case "$_mode" in
        conservative) _class=weak ;;
        aggressive)
          case "$_class" in weak) _class=normal ;; normal) _class=fast ;; esac
          ;;
      esac

      set -- $(_window_for "$_class" "$_mtu" "$_rate")
      _cwnd="$1"; _rwnd="$2"

      # Strip any window options already on the route before re-adding, or `ip` refuses
      # the change on some kernels with "RTNETLINK answers: File exists".
      _clean="$(printf '%s' "$_rt" | sed -e 's/ initcwnd [0-9]*//' -e 's/ initrwnd [0-9]*//')"

      if $_ipc route change $_clean initcwnd "$_cwnd" initrwnd "$_rwnd" >/dev/null 2>&1; then
        # Read it back. A route change can be accepted and silently not stick when the
        # route is replaced by the connectivity stack a moment later, and a tuning that
        # reports success without checking is how "it does nothing" reports start.
        if $_ipc route show table "${_tbl:-main}" 2>/dev/null | grep '^default' \
             | grep -E " dev $_if( |\$)" | grep -q "initcwnd $_cwnd"; then
          echo "net_routes: $_if ipv$_fam $_class mtu=$_mtu cwnd=$_cwnd rwnd=$_rwnd"
        else
          echo "net_routes: $_if ipv$_fam applied but did not stick (route replaced?)"
        fi
      fi
    done
  done

  # Deliberately absent: dropping established connections to "apply" the change. These
  # values are read when a connection is created, so existing ones were never going to
  # pick them up, and killing them to pretend otherwise costs the user real transfers.
  return 0
}

# --- watch: re-apply on link change, without a polling loop -------------------------------
#
# `ip monitor` blocks on a netlink socket and wakes only when a route actually changes.
# That is a few events a day instead of a wakeup every N seconds forever - the reason this
# does not need the sleep loop the usual implementations run.
# Default routes with the tokens ASB itself writes removed, as one checksum.
_route_fp() {
  { _defaults 4; _defaults 6; } \
    | sed -e 's/ initcwnd [0-9]*//' -e 's/ initrwnd [0-9]*//' -e 's/ congctl [a-z_]*//' \
    | cksum 2>/dev/null
}
# Windows, then the per-route congestion algorithm: a re-created route has lost both.
_reapply() {
  # Route windows only when they are on: the watcher also runs for per-link congctl alone,
  # and "off" would otherwise replay the restore on every reconnect.
  case "$(_cfg net_route_tune)" in auto|conservative|aggressive) _apply >/dev/null 2>&1 ;; esac
  [ -f "$MODDIR/runtime/asb_net_apply.sh" ] && \
    MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_net_apply.sh" routes >/dev/null 2>&1
}

_watch() {
  # Record why this stops, so a later diag can say more than "NOT running".
  #
  # ip monitor either blocks forever or dies for a reason - no ip binary, a netlink socket
  # SELinux will not open, or a kernel that refuses the subscription. All three look
  # identical from outside once the process is gone, and the six possible causes need
  # different fixes. One line on the way out turns a guess into an answer.
  _nrw_note() {
    mkdir -p /data/adb/asb 2>/dev/null
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" \
      > /data/adb/asb/net_routes_watch.exit 2>/dev/null || true
  }
  [ -x "$ASB_IP" ] || _has "$ASB_IP" || { _nrw_note "missing_ip"; exit 0; }
  rm -f /data/adb/asb/net_routes_watch.exit 2>/dev/null
  mkdir -p /data/adb/asb 2>/dev/null
  echo monitor > /data/adb/asb/net_routes_watch.mode 2>/dev/null
  _w0="$(date +%s 2>/dev/null || echo 0)"
  _fp="$(_route_fp)"
  # stderr kept: "rc=0" alone said nothing about why the monitor stopped (the pipeline's
  # status is the while loop's, not ip's), and the cause decides the fix.
  "$ASB_IP" monitor route 2>/data/adb/asb/net_routes_watch.err | while IFS= read -r _ev; do
    case "$_ev" in
      # A route change is the one event that can change a qdisc verdict.
      #
      # asb_net_apply marks a refused qdisc so it stops retrying something the kernel or
      # the vendor stack will refuse identically forever. That marker has to be cleared
      # by whatever could make the answer different - a new default route means a new or
      # re-created interface, which is exactly that case. Clearing it here rather than on
      # a timer keeps the retry event-driven, which is the point of this watcher.
      # Only when the set of default routes really changed. Our own `ip route change`
      # is itself a route event, so reacting to every *default* line re-applied, which
      # raised another event, which re-applied - a loop every two seconds for as long
      # as the monitor lived. The fingerprint strips the tokens we write.
      *default*)
        _nfp="$(_route_fp)"
        [ "$_nfp" = "$_fp" ] && continue
        rm -rf /data/adb/asb/qdisc_cool 2>/dev/null
        sleep 2; _reapply
        _fp="$(_route_fp)" ;;
    esac
  done
  _w1="$(date +%s 2>/dev/null || echo 0)"
  _werr="$(head -c 120 /data/adb/asb/net_routes_watch.err 2>/dev/null | tr '\n' ' ')"
  # Reached only if ip monitor terminated: a healthy watcher never gets here.
  _nrw_note "ip_monitor_ended after $((_w1 - _w0))s${_werr:+: $_werr}"

  # A monitor that dies within a minute will die the same way when the half-hour pass
  # restarts it (a field diag shows it ending 7 s after boot), leaving routes untuned
  # after every reconnect in between. Fall back to a slow poll of the default routes:
  # one ip call a minute, on a sleep that does not wake a suspended phone, and work only
  # when the fingerprint changes. The window and congctl tokens are stripped so our own
  # tuning does not register as a change.
  [ $((_w1 - _w0)) -lt 60 ] 2>/dev/null || exit 0
  echo poll > /data/adb/asb/net_routes_watch.mode 2>/dev/null
  _fp="$(_route_fp)"
  while :; do
    sleep 60
    _nfp="$(_route_fp)"
    [ "$_nfp" = "$_fp" ] && continue
    rm -rf /data/adb/asb/qdisc_cool 2>/dev/null
    sleep 2; _reapply
    _fp="$(_route_fp)"
  done
}

case "$MODE" in
  apply)   _apply ;;
  restore) _restore ;;
  watch)   _watch ;;
  *)       _apply ;;
esac
exit 0
