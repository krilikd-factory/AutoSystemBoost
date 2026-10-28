#!/system/bin/sh
# asb_net_mtu.sh - opt-in TCP PMTUD black-hole recovery with exact handback.
#
# Linux tcp_mtu_probing values: 0=disabled, 1=probe only after a suspected
# black hole, 2=always probe. ASB's "on" deliberately selects 1: it does not
# lower the MSS of healthy connections and is not a universal speed tweak.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE="${ASB_NET_MTU_STATE:-/data/adb/asb/net_mtu_probing.prev}"
NODE="${ASB_NET_MTU_SYSCTL:-/proc/sys/net/ipv4/tcp_mtu_probing}"
MODE="${1:-apply}"

_cfg() {
  grep -E '^[[:space:]]*net_mtu_probing=' "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r'
}

_read() {
  _v="$(cat "$NODE" 2>/dev/null | tr -d ' \r')"
  case "$_v" in 0|1|2) printf '%s\n' "$_v" ;; *) return 1 ;; esac
}

_write() {
  [ -w "$NODE" ] || return 1
  printf '%s\n' "$1" > "$NODE" 2>/dev/null || return 1
  [ "$(_read)" = "$1" ]
}

_restore() {
  [ -f "$STATE" ] || { echo 'mtu_probing=stock'; return 0; }
  _old="$(head -1 "$STATE" 2>/dev/null | tr -d ' \r')"
  case "$_old" in 0|1|2) ;; *) echo 'mtu_probing=restore-FAILED'; return 1 ;; esac
  if _write "$_old"; then
    rm -f "$STATE" 2>/dev/null
    echo 'mtu_probing=restored'
    return 0
  fi
  # Keep the original: a later stock/uninstall pass must still be able to recover.
  echo 'mtu_probing=restore-FAILED'
  return 1
}

case "$MODE" in
  restore) _restore; exit $? ;;
  apply) : ;;
  *) echo 'usage: asb_net_mtu.sh [apply|restore]' >&2; exit 2 ;;
esac

_want="$(_cfg)"
case "$_want" in
  ''|stock) _restore; exit $? ;;
  on) : ;;
  *) echo 'mtu_probing=FAILED'; exit 1 ;;
esac

_live="$(_read)" || { echo 'mtu_probing=unavailable'; exit 1; }

# Capture the device's own value once, before the first ASB write. noclobber makes
# concurrent apply passes unable to replace an already-captured baseline.
if [ ! -f "$STATE" ]; then
  _dir="${STATE%/*}"
  [ "$_dir" = "$STATE" ] && _dir=.
  mkdir -p "$_dir" 2>/dev/null || { echo 'mtu_probing=FAILED'; exit 1; }
  if ! ( set -C; printf '%s\n' "$_live" > "$STATE" ) 2>/dev/null; then
    [ -f "$STATE" ] || { echo 'mtu_probing=FAILED'; exit 1; }
  fi
fi
_saved="$(head -1 "$STATE" 2>/dev/null | tr -d ' \r')"
case "$_saved" in 0|1|2) ;; *) echo 'mtu_probing=FAILED'; exit 1 ;; esac

if _write 1; then
  echo 'mtu_probing=on'
  exit 0
fi
# A failed write/readback must never discard the value needed for handback.
echo 'mtu_probing=FAILED'
exit 1
