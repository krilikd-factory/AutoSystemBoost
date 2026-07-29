#!/system/bin/sh
# asb_net_apply.sh - user-facing network settings.
#
# ASB already tuned congestion control, the queue discipline and the TCP buffers, but
# only as a side effect of the power profile: nothing was exposed and nothing could be
# overridden. These four keys sit ON TOP of that - "auto" means "leave the profile's
# choice alone", anything else pins a value the profile will not undo.
#
#   net_congestion     auto | bbr | cubic
#   net_qdisc          auto | fq | fq_codel | cake
#   wifi_country       auto | CR | US | DE | JP ...
#   wifi_scan_throttle auto | 0 | 1
#
# Everything here is applied live and re-asserted at boot. Nothing needs a reboot,
# because none of it goes through the overlay - it is all sysctl and `cmd wifi`.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r'
}

_has() { command -v "$1" >/dev/null 2>&1; }

# Write a sysctl only if the value is one the kernel actually offers. Writing an
# unsupported congestion algorithm returns EINVAL and leaves the previous one in place,
# which looks like "the setting did nothing" rather than "your kernel lacks it".
_sysctl_w() {
  _k="$1"; _v="$2"
  _p="/proc/sys/$(printf '%s' "$_k" | tr '.' '/')"
  [ -w "$_p" ] || return 1
  echo "$_v" > "$_p" 2>/dev/null || return 1
  return 0
}

_out=""

# --- link type -------------------------------------------------------------------------
# wifi | mobile | other. Names are the reliable signal here: Android is consistent about
# wlan* for WiFi and rmnet*/ccmni*/wwan* for the modem across every OEM that matters.
_iface_kind() {
  case "$1" in
    wlan*|p2p*|ap*)          echo wifi ;;
    rmnet*|ccmni*|wwan*|ppp*) echo mobile ;;
    *)                        echo other ;;
  esac
}

# Resolve a per-link key against the global one: "auto" on the specific key means
# "whatever the global says", the same way the touch haptics follow the master level.
_resolve_for() {
  _rk_base="$1"; _rk_kind="$2"
  _rk_v=""
  case "$_rk_kind" in
    wifi)   _rk_v="$(_cfg "${_rk_base}_wifi")" ;;
    mobile) _rk_v="$(_cfg "${_rk_base}_mobile")" ;;
  esac
  case "$_rk_v" in
    ''|auto) _cfg "$_rk_base" ;;   # per-interface auto defers to the global key
    *)       printf '%s' "$_rk_v" ;;
  esac
}

# Does this kernel take a per-route congestion algorithm? Probe once against the real
# default route: `ip route change ... congctl X` either works or errors out, and knowing
# which decides between genuinely simultaneous per-link algorithms and the global switch.
_congctl_ok=""
_probe_congctl() {
  [ -n "$_congctl_ok" ] && return 0
  _congctl_ok=0
  _pr="$(ip route show 2>/dev/null | grep -m1 '^default')"
  [ -n "$_pr" ] || return 0
  _pc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
  [ -n "$_pc" ] || return 0
  _pclean="$(printf '%s' "$_pr" | sed -e 's/ congctl [a-z_]*//')"
  ip route change $_pclean congctl "$_pc" >/dev/null 2>&1 && _congctl_ok=1
  return 0
}

# --- congestion control --------------------------------------------------------------
_cc_any=0
_probe_congctl
_avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"

if [ "$_congctl_ok" = "1" ]; then
  # Per-route: WiFi and mobile each carry their own algorithm at the same time. No
  # switching, so nothing has to notice when the active link changes.
  for _cif in $(ls /sys/class/net 2>/dev/null); do
    case "$_cif" in lo|dummy*|sit*|ip6tnl*) continue ;; esac
    [ "$(cat "/sys/class/net/$_cif/operstate" 2>/dev/null)" = "up" ] || continue
    _kind="$(_iface_kind "$_cif")"
    [ "$_kind" = "other" ] && continue
    _want="$(_resolve_for net_congestion "$_kind")"
    # auto resolves to the captured stock value rather than being skipped. Skipping meant
    # whatever ASB set at boot stayed put and got reported as "auto", which is how a stock
    # kernel with no bbr ended up showing bbr on the auto setting.
    case "$_want" in
      ''|auto)
        _want="$(grep -E '^STOCK_TCP_CC=' /data/adb/asb/net_stock.env 2>/dev/null \
                 | head -1 | sed 's/.*=//' | tr -d ' \r')"
        [ -n "$_want" ] || continue ;;
    esac
    case " $_avail " in
      *" $_want "*) : ;;
      *) _out="$_out cc[$_kind]=$_want-unavailable"; continue ;;
    esac
    ip route show 2>/dev/null | grep "^default.* dev $_cif" | while IFS= read -r _crt; do
      _cclean="$(printf '%s' "$_crt" | sed -e 's/ congctl [a-z_]*//')"
      ip route change $_cclean congctl "$_want" >/dev/null 2>&1
    done
    _out="$_out cc[$_kind:$_cif]=$_want"
    _cc_any=1
  done
fi

# Global setting: the only option when the kernel has no congctl, and still the right
# thing to write when the user set one value for everything.
_cc="$(_cfg net_congestion)"
case "$_cc" in
  ''|auto)
    # No global choice, but a per-link one may still need the global switch as fallback.
    if [ "$_congctl_ok" != "1" ]; then
      _act="$(ip route show 2>/dev/null | grep -m1 '^default' | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
      if [ -n "$_act" ]; then
        _want="$(_resolve_for net_congestion "$(_iface_kind "$_act")")"
        case "$_want" in
          ''|auto) : ;;
          *) case " $_avail " in
               *" $_want "*)
                 _sysctl_w net.ipv4.tcp_congestion_control "$_want" && \
                   _out="$_out cc[active:$_act]=$_want(global-fallback)" ;;
             esac ;;
        esac
      fi
    fi
    ;;
  *)
    case " $_avail " in
      *" $_cc "*)
        if _sysctl_w net.ipv4.tcp_congestion_control "$_cc"; then
          [ -e /proc/sys/net/ipv6/tcp_congestion_control ] && \
            _sysctl_w net.ipv6.tcp_congestion_control "$_cc"
          _out="$_out congestion=$_cc"
        else
          _out="$_out congestion=FAILED"
        fi
        ;;
      *) _out="$_out congestion=$_cc-unavailable(have:${_avail:-none})" ;;
    esac
    ;;
esac

# --- queue discipline -----------------------------------------------------------------
# This one IS per-interface in the kernel, so WiFi and mobile get their own without any
# tricks. default_qdisc still gets the global value for interfaces that come up later.
# The global verdict is decided by what the INTERFACES did, not by whether the sysctl
# swallowed the string.
#
# net.core.default_qdisc accepts any name - it is just stored for interfaces that come up
# later - so writing "cake" on a kernel with no cake module succeeds and means nothing.
# Reporting that as ok while every interface reported "not applied" is a contradiction the
# user has to resolve themselves. Count the real applications below and let them decide.
_qd="$(_cfg net_qdisc)"
_qd_tried=0
_qd_ok=0
case "$_qd" in
  ''|auto) : ;;
  *) _sysctl_w net.core.default_qdisc "$_qd" ;;
esac

if _has tc; then
  for _if in $(ls /sys/class/net 2>/dev/null); do
    case "$_if" in lo|dummy*|sit*|ip6tnl*) continue ;; esac
    [ "$(cat "/sys/class/net/$_if/operstate" 2>/dev/null)" = "up" ] || continue
    _kind="$(_iface_kind "$_if")"
    [ "$_kind" = "other" ] && continue
    _want="$(_resolve_for net_qdisc "$_kind")"
    case "$_want" in ''|auto) continue ;; esac
    # Arguments matter as much as the name: fq_codel with default target is not the same
    # tuning as fq_codel at 5 ms, and cake without an isolation mode is barely cake.
    case "$_want" in
      fq)       tc qdisc replace dev "$_if" root fq pacing >/dev/null 2>&1 ;;
      fq_codel) tc qdisc replace dev "$_if" root fq_codel target 5ms interval 100ms ecn >/dev/null 2>&1 ;;
      cake)     tc qdisc replace dev "$_if" root cake besteffort triple-isolate >/dev/null 2>&1 ;;
      *)        continue ;;
    esac
    # Read back: tc accepts a qdisc the kernel has no module for and silently keeps the
    # old one, which is indistinguishable from success unless you look.
    _qd_tried=$(( _qd_tried + 1 ))
    if tc qdisc show dev "$_if" 2>/dev/null | grep -q "$_want"; then
      _qd_ok=$(( _qd_ok + 1 ))
      _out="$_out qdisc[$_kind:$_if]=$_want"
    else
      _out="$_out qdisc[$_kind:$_if]=$_want-not-applied"
    fi
  done
fi

# One verdict for the global key, derived from the interfaces.
case "$_qd" in
  ''|auto) : ;;
  *)
    if [ "$_qd_tried" = "0" ]; then
      # Nothing to apply it to yet (no tc, or no link up). The value is stored and will be
      # used by the next interface that appears - that is "pending", not "working".
      _out="$_out qdisc=$_qd-pending"
    elif [ "$_qd_ok" = "0" ]; then
      _out="$_out qdisc=$_qd-not-applied"
    else
      _out="$_out qdisc=$_qd"
    fi
    ;;
esac

# --- WiFi regulatory domain ------------------------------------------------------------
# `cmd wifi force-country-code` is the supported way in. It survives until explicitly
# disabled, so "auto" has to actively release it - simply not setting it would leave a
# previous choice pinned and make the setting look one-way.
_wc="$(_cfg wifi_country)"
if _has cmd; then
  case "$_wc" in
    ''|auto)
      if [ -f /data/adb/asb/wifi_cc_set ]; then
        cmd -w wifi force-country-code disabled >/dev/null 2>&1
        rm -f /data/adb/asb/wifi_cc_set 2>/dev/null
        _out="$_out wifi_country=released"
      fi
      ;;
    [A-Z][A-Z])
      if cmd -w wifi force-country-code enabled "$_wc" >/dev/null 2>&1; then
        mkdir -p /data/adb/asb 2>/dev/null
        echo "$_wc" > /data/adb/asb/wifi_cc_set 2>/dev/null
        _out="$_out wifi_country=$_wc"
      else
        _out="$_out wifi_country=FAILED"
      fi
      ;;
  esac
fi

# --- WiFi scan throttle -----------------------------------------------------------------
_wt="$(_cfg wifi_scan_throttle)"
case "$_wt" in
  0|1)
    settings put global wifi_scan_throttle_enabled "$_wt" >/dev/null 2>&1 \
      && _out="$_out scan_throttle=$_wt"
    ;;
esac

# Route windows live in their own script: they need link measurement and a netlink
# watcher, which has nothing to do with the sysctl writes above.
if [ -x "$MODDIR/runtime/asb_net_routes.sh" ] || [ -f "$MODDIR/runtime/asb_net_routes.sh" ]; then
  _rt_out="$(sh "$MODDIR/runtime/asb_net_routes.sh" apply 2>/dev/null)"
  [ -n "$_rt_out" ] && printf '%s\n' "$_rt_out"
fi

# Machine-readable result for the WebUI.
#
# Without this the UI can only show what the user picked, not what the kernel accepted -
# so asking for bbr on a stock kernel left the button lit as though it had worked. Each
# line is "key=state", state being ok | unavailable | failed, and the card reads it to
# label itself honestly.
_res="/data/adb/asb/net_apply_result"
mkdir -p /data/adb/asb 2>/dev/null
{
  for _tok in $_out; do
    case "$_tok" in
      congestion=*-unavailable*)    printf 'net_congestion=unavailable\n' ;;
      congestion=FAILED)            printf 'net_congestion=failed\n' ;;
      congestion=*)                 printf 'net_congestion=ok\n' ;;
      cc\[wifi*-unavailable*)       printf 'net_congestion_wifi=unavailable\n' ;;
      cc\[wifi*)                    printf 'net_congestion_wifi=ok\n' ;;
      cc\[mobile*-unavailable*)     printf 'net_congestion_mobile=unavailable\n' ;;
      cc\[mobile*)                  printf 'net_congestion_mobile=ok\n' ;;
      qdisc=*-pending)              printf 'net_qdisc=pending\n' ;;
      qdisc=*-not-applied)          printf 'net_qdisc=failed\n' ;;
      qdisc=FAILED)                 printf 'net_qdisc=failed\n' ;;
      qdisc=*)                      printf 'net_qdisc=ok\n' ;;
      qdisc\[wifi*not-applied*)     printf 'net_qdisc_wifi=failed\n' ;;
      qdisc\[wifi*)                 printf 'net_qdisc_wifi=ok\n' ;;
      qdisc\[mobile*not-applied*)   printf 'net_qdisc_mobile=failed\n' ;;
      qdisc\[mobile*)               printf 'net_qdisc_mobile=ok\n' ;;
      wifi_country=FAILED)          printf 'wifi_country=failed\n' ;;
      wifi_country=*)               printf 'wifi_country=ok\n' ;;
      scan_throttle=*)              printf 'wifi_scan_throttle=ok\n' ;;
    esac
  done
} > "$_res" 2>/dev/null

[ -n "$_out" ] && echo "net:$_out" || echo "net: nothing to apply (all auto)"
exit 0
