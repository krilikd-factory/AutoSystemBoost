#!/bin/sh
# Contract: route readers use every table, and the route watcher cannot feed itself.
#
# Android keeps each network's default route in its own table ("... table rmnet_data2"),
# never in main. Reading `ip route show` found no route on any phone: initcwnd/initrwnd
# were never applied, per-route congctl was "not supported" without the kernel being
# asked, and the report waited for a link forever.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; f() { echo "FAIL route tables: $*" >&2; fail=1; }
for file in runtime/asb_net_routes.sh runtime/asb_net_apply.sh action.sh tools/asb_diag.sh; do
  sh -n "$ROOT/$file" || f "$file syntax"
  # Any `ip [-6] route show` that is not followed by a table selector reads main only.
  if grep -nE 'ip( -6)? route show( |$)' "$ROOT/$file" | grep -v '^[0-9]*:[[:space:]]*#' \
       | grep -vE 'route show table' >/dev/null; then
    f "$file reads the main table only: $(grep -nE 'ip( -6)? route show( |$)' "$ROOT/$file" | grep -vE 'route show table|^[0-9]*:[[:space:]]*#' | head -1)"
  fi
done
R="$ROOT/runtime/asb_net_routes.sh"
grep -q 'route show table all' "$R" || f "net_routes does not read table all"
# Our own route change is a route event: the watcher must compare a fingerprint that
# strips the tokens it writes, or it re-applies forever.
grep -q '_route_fp()' "$R" || f "no route fingerprint"
grep -q '\[ "$_nfp" = "$_fp" \] && continue' "$R" || f "monitor loop does not skip unchanged routes"
for tok in initcwnd initrwnd congctl; do
  sed -n '/^_route_fp()/,/^}/p' "$R" | grep -q "s/ $tok " || f "fingerprint keeps $tok"
done
# A re-created route lost its congctl too; the watcher restores it through the routes mode.
grep -q 'asb_net_apply.sh" routes' "$R" || f "watcher does not re-apply per-route congctl"
grep -q '\[ "$ASB_NET_MODE" = routes \] && exit 0' "$ROOT/runtime/asb_net_apply.sh" || f "net_apply has no routes mode"
grep -q 'route get 1.1.1.1' "$ROOT/runtime/asb_net_apply.sh" || f "active link not taken from the kernel's own route choice"
# Per-link congestion alone must still run the boot apply and keep the watcher alive.
grep -q 'net_congestion_wifi net_congestion_mobile net_qdisc_wifi net_qdisc_mobile; do' "$ROOT/service.sh" \
  || f "boot apply ignores per-link network keys"
[ "$(grep -c "_rw_mode=cc_only\|_asb_rt=cc_only" "$ROOT/service.sh")" -ge 2 ] || f "watcher not started for per-link congctl alone"
grep -q 'in auto|conservative|aggressive) _apply' "$R" || f "watcher replays route windows while they are off"
# iproute2, not BusyBox: the root manager's applet has no monitor/initcwnd/congctl.
for file in runtime/asb_net_routes.sh runtime/asb_net_apply.sh; do
  grep -q 'for _ipb in /system/bin/ip' "$ROOT/$file" || f "$file does not prefer /system/bin/ip"
  if grep -vE '^[[:space:]]*#' "$ROOT/$file" | grep -qE '(^|[;|&(]|then|else|do)[[:space:]]*ip (route|-6|monitor)'; then
    f "$file still calls a bare ip"
  fi
done
[ "$fail" = 0 ] && echo "PASS route table contract"
exit "$fail"
