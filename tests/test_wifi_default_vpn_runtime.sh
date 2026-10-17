#!/bin/sh
# Runtime (fix148): "leave bad Wi-Fi" sees Wi-Fi under a VPN.
#
# CPH2769 capture 13290: a proxy app held the default route all day ("1.1.1.1 dev tun0 table
# tun0"), Wi-Fi was up beneath it, and the watcher reported "waiting_for_wifi_default_route"
# the whole time - it never looked at the Wi-Fi it was meant to judge. The tunnel rides on the
# system default network, which netd names in its rule for unmarked local traffic with no uid
# range. The REAL function runs here against a stubbed ip(8).
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wifi default vpn: $*" >&2; fail=1; }
awk '/^_wifi_default\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$ROOT/runtime/asb_wifi_fallback.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || { echo "FAIL wifi default vpn: _wifi_default not found" >&2; exit 1; }
mkdir -p "$T/bin"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
case "$1 $2" in
  "route get") cat "$T/route" ;;
  "rule show") cat "$T/rules" ;;
esac
X
chmod 0755 "$T/bin/ip"
case_() {   # route rules-file-content -> 0/1
  printf '%s\n' "$1" > "$T/route"; printf '%s\n' "$2" > "$T/rules"
  T="$T" PATH="$T/bin:$PATH" sh -c '. "$1"; _wifi_default' x "$T/fn.sh" && echo yes || echo no
}
RULES_WIFI='0:	from all lookup local
13000:	from all fwmark 0x0/0x20000 iif lo uidrange 0-99999 lookup tun0
16000:	from all fwmark 0x10064/0x1ffff iif lo lookup wlan0
22000:	from all fwmark 0x0/0x10000 lookup legacy_system
25000:	from all fwmark 0x0/0xffff iif lo uidrange 10500-10500 lookup rmnet_data2
31000:	from all fwmark 0x0/0xffff iif lo lookup wlan0
32000:	from all unreachable'
RULES_MOBILE="$(printf '%s\n' "$RULES_WIFI" | sed 's/^31000:.*/31000:	from all fwmark 0x0\/0xffff iif lo lookup rmnet_data2/')"
[ "$(case_ '1.1.1.1 via 192.168.1.1 dev wlan0 table wlan0 src 192.168.1.9' "$RULES_MOBILE")" = yes ] || f "plain Wi-Fi route"
[ "$(case_ '1.1.1.1 dev tun0 table tun0 src 26.26.26.1 uid 0' "$RULES_WIFI")" = yes ] || f "VPN over Wi-Fi not seen as Wi-Fi"
[ "$(case_ '1.1.1.1 dev tun0 table tun0 src 26.26.26.1 uid 0' "$RULES_MOBILE")" = no ] || f "VPN over mobile data taken for Wi-Fi"
[ "$(case_ '1.1.1.1 via 10.0.0.1 dev rmnet_data2 table rmnet_data2' "$RULES_WIFI")" = no ] || f "mobile route taken for Wi-Fi (the rule is only asked behind a tunnel)"
# A per-app default (uidrange) pointing at Wi-Fi is not the system default.
RULES_APP="$(printf '%s\n' "$RULES_MOBILE" | sed 's/uidrange 10500-10500 lookup rmnet_data2/uidrange 10500-10500 lookup wlan0/')"
[ "$(case_ '1.1.1.1 dev tun0 table tun0' "$RULES_APP")" = no ] || f "a per-app Wi-Fi default read as the system default"
# The 5G-only-when-needed / screen-off LTE check asks the same rule behind a tunnel: a Wi-Fi
# that is connected but not the default keeps a default route in its own table.
awk '/^_on_mobile\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$ROOT/runtime/asb_lte_screenoff.sh" > "$T/om.sh"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
case "$1 $2" in
  "route get") cat "$T/route" ;;
  "rule show") cat "$T/rules" ;;
  "route show") printf '%s\n' 'default via 192.168.1.1 dev wlan0 table wlan0 proto static' 'default via 10.0.0.1 dev rmnet_data2 table rmnet_data2 proto static' ;;
esac
X
chmod 0755 "$T/bin/ip"
om() { printf '%s\n' "$1" > "$T/route"; printf '%s\n' "$2" > "$T/rules"
  T="$T" PATH="$T/bin:$PATH" sh -c '_IPB=ip; . "$1"; _on_mobile' x "$T/om.sh" && echo yes || echo no; }
[ "$(om '1.1.1.1 dev tun0 table tun0' "$RULES_MOBILE")" = yes ] || f "LTE check: VPN over mobile with Wi-Fi connected read as Wi-Fi"
[ "$(om '1.1.1.1 dev tun0 table tun0' "$RULES_WIFI")" = no ] || f "LTE check: VPN over Wi-Fi read as mobile"
[ "$fail" = 0 ] && echo "PASS wifi default vpn: Wi-Fi under a tunnel recognised from netd's default-network rule"
exit "$fail"
