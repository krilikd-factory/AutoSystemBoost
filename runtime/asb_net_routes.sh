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
_has ip || { echo "net_routes: no ip(8), nothing to do"; exit 0; }

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
_save_orig() {
  [ -f "$STATE" ] && return 0
  mkdir -p /data/adb/asb 2>/dev/null
  { ip route show 2>/dev/null; ip -6 route show 2>/dev/null; } > "$STATE" 2>/dev/null
}

_restore() {
  [ -f "$STATE" ] || { echo "net_routes: nothing recorded, nothing to restore"; return 0; }
  _rn=0
  while IFS= read -r _rl; do
    [ -n "$_rl" ] || continue
    case "$_rl" in *initcwnd*|*initrwnd*) : ;; *) : ;; esac
    case "$_rl" in
      *:*) ip -6 route change $_rl >/dev/null 2>&1 && _rn=$((_rn+1)) ;;
      *)   ip route change $_rl    >/dev/null 2>&1 && _rn=$((_rn+1)) ;;
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
    if [ "$_fam" = "4" ]; then _ipc="ip"; else _ipc="ip -6"; fi
    $_ipc route show 2>/dev/null | grep '^default' | while IFS= read -r _rt; do
      _if="$(printf '%s' "$_rt" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
      [ -n "$_if" ] || continue
      [ "$(cat "/sys/class/net/$_if/operstate" 2>/dev/null)" = "up" ] || continue

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
        if $_ipc route show 2>/dev/null | grep -q "initcwnd $_cwnd"; then
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
_watch() {
  _has ip || exit 0
  ip monitor route 2>/dev/null | while IFS= read -r _ev; do
    case "$_ev" in
      *default*) sleep 2; _apply >/dev/null 2>&1 ;;
    esac
  done
}

case "$MODE" in
  apply)   _apply ;;
  restore) _restore ;;
  watch)   _watch ;;
  *)       _apply ;;
esac
exit 0
