#!/bin/sh
# Runtime (fix151): "transmit queue" really sets the Wi-Fi queue, and gives it back.
#
# Five asbdiag reports with net_txqueue=short or shorter, one of them on Wi-Fi: wlan0=1024
# every time. The script ran `ip link set dev wlan0 txqueuelen N` with whatever `ip` came
# first on PATH; the root manager's BusyBox applet knows the keyword as "qlen" only, the error
# went to /dev/null and the queue never moved. The REAL script now writes tx_queue_len in
# sysfs (Android's iproute2 as the fallback); here it runs on a fake sysfs with an `ip` that
# refuses the keyword like BusyBox does.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_net_offload.sh"
fail() { echo "FAIL net txqueue: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mod/config" "$T/bin"
for i in wlan0 rmnet_data0 lo; do
  mkdir -p "$T/net/$i/queues/rx-0"
  echo 0 > "$T/net/$i/queues/rx-0/rps_cpus"
done
echo 1024 > "$T/net/wlan0/tx_queue_len"; echo 1000 > "$T/net/rmnet_data0/tx_queue_len"; echo 1000 > "$T/net/lo/tx_queue_len"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
case "$*" in *txqueuelen*) echo "ip: invalid argument 'txqueuelen'" >&2; exit 1 ;; esac
exit 0
X
chmod +x "$T/bin/ip"
run() {
  printf 'net_rps=stock\nnet_txqueue=%s\n' "$1" > "$T/mod/config/governor.conf"
  PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_NET_SYSFS="$T/net" ASB_NET_OFFLOAD_STATE="$T/prev" sh "$SRC" >/dev/null 2>&1 || true
}
run short
[ "$(cat "$T/net/wlan0/tx_queue_len")" = 256 ] || fail "Wi-Fi queue not shortened: $(cat "$T/net/wlan0/tx_queue_len")"
[ "$(cat "$T/net/rmnet_data0/tx_queue_len")" = 1000 ] || fail "a mobile link was touched"
[ "$(cat "$T/net/lo/tx_queue_len")" = 1000 ] || fail "loopback was touched"
grep -qx 'TXQ:wlan0=1024' "$T/prev" || fail "the device's own value was not recorded"
run shorter
[ "$(cat "$T/net/wlan0/tx_queue_len")" = 128 ] || fail "shorter not applied"
run stock
[ "$(cat "$T/net/wlan0/tx_queue_len")" = 1024 ] || fail "stock did not give the queue back: $(cat "$T/net/wlan0/tx_queue_len")"
grep -qF '"$_tb" link set dev "$1" txqueuelen "$2"' "$SRC" || fail "no iproute2 fallback"
grep -q '^  for _tb in /system/bin/ip /system/xbin/ip /vendor/bin/ip; do$' "$SRC" || fail "fallback takes ip from PATH"
echo "PASS net txqueue: Wi-Fi queue set through sysfs whatever ip is on PATH, mobile links untouched, stock restores"
