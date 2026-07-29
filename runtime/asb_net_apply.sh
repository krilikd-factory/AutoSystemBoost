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

# --- congestion control --------------------------------------------------------------
_cc="$(_cfg net_congestion)"
case "$_cc" in
  ''|auto) : ;;
  *)
    _avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
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
      *)
        # Say which ones exist rather than just failing: on a kernel without BBR this is
        # the difference between "ASB is broken" and "this kernel does not have it".
        _out="$_out congestion=$_cc-unavailable(have:${_avail:-none})"
        ;;
    esac
    ;;
esac

# --- queue discipline -----------------------------------------------------------------
# default_qdisc only affects interfaces brought up AFTER it is set, so also push it onto
# the live interfaces with tc when that is available. Without the second step the setting
# appears to do nothing until the next time WiFi or data is toggled.
_qd="$(_cfg net_qdisc)"
case "$_qd" in
  ''|auto) : ;;
  *)
    if _sysctl_w net.core.default_qdisc "$_qd"; then
      _out="$_out qdisc=$_qd"
      if _has tc; then
        for _if in $(ls /sys/class/net 2>/dev/null); do
          case "$_if" in lo|dummy*|sit*|ip6tnl*) continue ;; esac
          [ "$(cat "/sys/class/net/$_if/operstate" 2>/dev/null)" = "up" ] || continue
          case "$_qd" in
            fq)       tc qdisc replace dev "$_if" root fq pacing 2>/dev/null ;;
            fq_codel) tc qdisc replace dev "$_if" root fq_codel target 5ms interval 100ms ecn 2>/dev/null ;;
            cake)     tc qdisc replace dev "$_if" root cake besteffort triple-isolate 2>/dev/null ;;
          esac
        done
      fi
    else
      _out="$_out qdisc=FAILED"
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

[ -n "$_out" ] && echo "net:$_out" || echo "net: nothing to apply (all auto)"
exit 0
