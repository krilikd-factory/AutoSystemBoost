#!/bin/sh
# Runtime (fix136): per-route congctl is decided on evidence, not on one probe.
#
# OP15 asbdiag on the fix133 build: "[N/A] net_congestion_wifi (no per-route congctl on this
# kernel)" above "link rmnet_data2: ... congctl=bbr" and "per-route congctl: SUPPORTED". The
# probe tried `ip route change ... congctl` on ONE default route; when that one route refused
# (being torn down, an attribute change will not take back), the whole kernel was filed as
# unsupported and the Wi-Fi choice was reported as impossible.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/runtime/asb_net_apply.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL net congctl probe: $*" >&2; exit 1; }
{ sed -n '/^_defaults() {/p' "$SRC"
  sed -n '/^_active_dev() {/,/^}/p' "$SRC"
  sed -n '/^_congctl_ok=""$/,/^}$/p' "$SRC"; } > "$TMP/probe.sh"
grep -q '_probe_congctl()' "$TMP/probe.sh" || fail "probe not extracted"
cat > "$TMP/ip" <<'S'
#!/bin/sh
case "$*" in
  "route show table all") cat "$ROUTES" ;;
  "route get 1.1.1.1") echo "1.1.1.1 via 100.65.185.32 dev rmnet_data2 table rmnet_data2 src 100.65.185.31 uid 0" ;;
  "route change "*) echo "$*" >> "$CHG"
                    case "$*" in *"table good"*) exit 0 ;; *) exit 2 ;; esac ;;
esac
S
chmod +x "$TMP/ip"
echo bbr > "$TMP/cc"
probe() {   # prints the verdict
  ( set +e; ASB_IP="$TMP/ip"; ROUTES="$TMP/routes"; CHG="$TMP/chg"; export ROUTES CHG
    . "$TMP/probe.sh"
    # the probe reads the global algorithm from /proc; point it at a fixture
    cat() { if [ "$1" = /proc/sys/net/ipv4/tcp_congestion_control ]; then command cat "$TMP/cc"; else command cat "$@"; fi; }
    _probe_congctl; printf '%s\n' "$_congctl_ok" )
}

# 1. A default route already carrying congctl: supported, nothing rewritten.
printf '%s\n' 'default via 100.65.185.32 dev rmnet_data2 table rmnet_data2 proto static congctl bbr' \
  'default via 192.168.1.1 dev wlan0 table wlan0 proto static' > "$TMP/routes"
: > "$TMP/chg"
[ "$(probe)" = 1 ] || fail "existing congctl not taken as evidence"
[ -s "$TMP/chg" ] && fail "routes rewritten although the evidence was there"

# 2. The active link's route refuses, another one takes it: supported.
printf '%s\n' 'default via 100.65.185.32 dev rmnet_data2 table bad proto static' \
  'default via 192.168.1.1 dev wlan0 table good proto static' > "$TMP/routes"
: > "$TMP/chg"
[ "$(probe)" = 1 ] || fail "one refusing route filed the kernel as unsupported"
head -1 "$TMP/chg" | grep -q 'dev rmnet_data2' || fail "active link not tried first"

# 3. Every candidate refuses: unsupported, after at most three tries.
printf '%s\n' 'default via 1.1.1.1 dev rmnet_data2 table bad1' 'default via 1.1.1.2 dev rmnet_data1 table bad2' \
  'default via 1.1.1.3 dev wlan0 table bad3' 'default via 1.1.1.4 dev rmnet_data3 table bad4' > "$TMP/routes"
: > "$TMP/chg"
[ "$(probe)" = 0 ] || fail "all refusing routes not filed as unsupported"
[ "$(grep -c '' "$TMP/chg")" -le 3 ] || fail "more than three routes rewritten by the probe"

# 4. No route at all: unknown (fix131), never unsupported.
: > "$TMP/routes"
[ "$(probe)" = unknown ] || fail "no route was not unknown"

# 5. A stale "unsupported" on a link that is down becomes pending once per-route works.
grep -q "case \"\$_pv\" in ''|\*=unsupported) _out=\"\$_out cc\[\$_pk\]=\$_pw-pending\" ;; esac" "$SRC" || fail "stale unsupported verdict never cleared"
grep -qF 'cc\[wifi*-pending*)' "$SRC" || fail "mapper has no pending for Wi-Fi congestion"
w="$(grep -nF 'cc\[wifi*-pending*)' "$SRC" | cut -d: -f1)"; g="$(grep -nF 'cc\[wifi*)' "$SRC" | head -1 | cut -d: -f1)"
[ "$w" -lt "$g" ] || fail "pending line after the generic ok line"
grep -q 'filed as unsupported by an apply whose probe failed' "$ROOT/tools/asb_diag.sh" || fail "asbdiag still calls it N/A against the evidence"
echo "PASS net congctl probe: evidence first, three candidates, unknown without a route, stale verdict cleared"
