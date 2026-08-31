#!/system/bin/sh
# asb_net_apply.sh - user-facing network settings.
#
# ASB already tuned congestion control, the queue discipline and the TCP buffers, but only as a
# side effect of the power profile: nothing was exposed and nothing could be overridden.
# These four keys sit ON TOP of that - "auto" means "leave the profile's choice alone",
# anything else pins a value the profile will not undo.
#
# net_congestion auto | bbr | cubic net_qdisc auto | fq | fq_codel | cake wifi_country auto |
# CR | US | DE | JP ...
#
# Everything here is applied live and re-asserted at boot. Nothing needs a reboot,
# because none of it goes through the overlay - it is all sysctl and `cmd wifi`.

# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service. On a OnePlus 15R every call returned "Failure calling
# service settings" while exiting 0, so writes looked successful and reads returned the
# error text as a value - this makes those calls work without changing any of them.
[ -f "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh" ] && \
  . "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh"
# `wifi_scan_throttle_enabled` is a user-visible framework setting. Record its pre-ASB value
# once so uninstall restores the user's own scanning preference.
[ -f "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_baseline.sh" ] && \
  . "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_baseline.sh"

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r'
}

_has() { command -v "$1" >/dev/null 2>&1; }
_asb_setting_put() {
  if command -v asb_settings_put >/dev/null 2>&1; then asb_settings_put "$@"; else settings put "$@" >/dev/null 2>&1; fi
}

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

# --- queue discipline ----------------------------------------------------------------- This
# one IS per-interface in the kernel, so WiFi and mobile get their own without any tricks.
#
# net.core.default_qdisc accepts any name - it is just stored for interfaces that come up later
# - so writing "cake" on a kernel with no cake module succeeds and means nothing.
# Reporting that as ok while every interface reported "not applied" is a contradiction the user
# has to resolve themselves.
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

# --- WiFi regulatory domain ------------------------------------------------------------ `cmd
# wifi force-country-code` is the supported way in.
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
    # Report the failure too, not just the success.
    #
    # The && meant a rejected write produced no token at all, and no token reads as "this
    # setting was never touched" - so the badge stayed green on a device where the write
    # had been refused. Read back rather than trusting the exit code: `settings put`
    # returns 0 on some ROMs even when the value does not stick.
    _asb_setting_put global wifi_scan_throttle_enabled "$_wt" || true
    if [ "$(settings get global wifi_scan_throttle_enabled 2>/dev/null)" = "$_wt" ]; then
      _out="$_out scan_throttle=$_wt"
    else
      _out="$_out scan_throttle=FAILED"
    fi
    ;;
esac

# Route windows live in their own script: they need link measurement and a netlink
# watcher, which has nothing to do with the sysctl writes above.
if [ -x "$MODDIR/runtime/asb_net_routes.sh" ] || [ -f "$MODDIR/runtime/asb_net_routes.sh" ]; then
  _rt_out="$(sh "$MODDIR/runtime/asb_net_routes.sh" apply 2>/dev/null)"
  [ -n "$_rt_out" ] && printf '%s\n' "$_rt_out"
fi

# Active fallback is separate from route-window tuning. It owns no radio setting; the
# watcher only starts/stops after config has committed, while LPM remains the sole
# mobile_data_always_on writer.
if [ -f "$MODDIR/runtime/asb_wifi_fallback.sh" ]; then
  _rp="$(grep -E '^[[:space:]]*radio_policy_enable=' "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  _wf="$(grep -E '^[[:space:]]*net_handover_active=' "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_wifi_fallback.sh" reconcile >/dev/null 2>&1 || true

  # Hand the decision to Android instead of pulling the radio down.
  #
  # net_handover_active works by disabling Wi-Fi outright, because that is the only way a
  # shell script can force the default route to move. It works, and it is also visible and
  # blunt: a user reported the phone leaving a good network and rejoining a minute later,
  # which is exactly what that mechanism looks like from the outside.
  #
  # network_avoid_bad_wifi is the platform's own switch for the same intent - when Wi-Fi
  # stops passing validation, move the default route to mobile - except the system does the
  # switching, the radio stays associated, and it moves back on its own when the link
  # recovers. That is the Pixel quick-settings behaviour people ask for, and choosing the
  # active network directly needs a system API no module can reach.
  #
  # Only written when the user asked for it, and only ever restored to the value the device
  # had: this is a system setting other things may care about.
  _abw="$(grep -E '^[[:space:]]*net_avoid_bad_wifi=' "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "${_abw:-0}" in
    1)
      # Capture the device's own value before the first write, so uninstall puts back what
      # was there rather than a guess. The recorder is idempotent - a second capture of an
      # already-recorded key is ignored - so calling it on every apply is safe.
      command -v asb_profile_baseline_capture_setting >/dev/null 2>&1 && \
        asb_profile_baseline_capture_setting global network_avoid_bad_wifi || true
      if command -v asb_ledger_settings >/dev/null 2>&1; then
        asb_ledger_settings global network_avoid_bad_wifi 1 "user opted in" || true
      else
        settings put global network_avoid_bad_wifi 1 >/dev/null 2>&1 || true
      fi
      _out="$_out avoid_bad_wifi=on" ;;
    *)
      # Off means "leave it as the device had it", not "force 0" - the baseline restore on
      # uninstall owns the original value.
      _out="$_out avoid_bad_wifi=off" ;;
  esac
  case "$_rp" in
    1) _out="$_out radio_policy=on wifi_fallback=${_wf:-0}" ;;
    *) _out="$_out radio_policy=off wifi_fallback=master_off" ;;
  esac
fi

# Machine-readable result for the WebUI.
#
# Without this the UI can only show what the user picked, not what the kernel accepted - so
# asking for bbr on a stock kernel left the button lit as though it had worked.
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
      scan_throttle=FAILED)         printf 'wifi_scan_throttle=failed\n' ;;
      scan_throttle=*)              printf 'wifi_scan_throttle=ok\n' ;;
      route_tune=FAILED)          printf 'net_route_tune=failed\n' ;;
      route_tune=*)               printf 'net_route_tune=ok\n' ;;
      radio_policy=on)            printf 'radio_policy_enable=ok\n' ;;
      radio_policy=*)             printf 'radio_policy_enable=off\n' ;;
      wifi_fallback=1)            printf 'net_handover_active=ok\n' ;;
      wifi_fallback=*)            printf 'net_handover_active=off\n' ;;

    esac
  done
} > "$_res" 2>/dev/null

[ -n "$_out" ] && echo "net:$_out" || echo "net: nothing to apply (all auto)"
exit 0
