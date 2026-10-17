#!/bin/sh
# Runtime (fix136): the wakelock watcher never restricts a messenger or an app the user has
# exempted from battery optimisation, and gives back one an earlier pass restricted.
#
# The OP15 capture of this round carries org.thoughtcrime.securesms in wakelock_restricted:
# Signal, moved to the restricted standby bucket by ASB - its package id has no "signal" in
# it, so the protected-name list never matched, and a messenger lost timely delivery.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock messenger guard: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1:${2:-}" in
  batterystats:*) cat <<'B'
  All partial wake locks:
  Wake lock u0a291 WebSocket: 40m 1s 2ms (12 times) realtime
  Wake lock u0a700 SyncLoop: 1h 2m 0s 1ms (40 times) realtime
  Wake lock u0a750 Keepalive: 35m 0s 1ms (9 times) realtime
  Wake lock u0a760 ImapIdle: 20m 0s 1ms (9 times) realtime
B
  ;;
  power:*) : ;;
  activity:*) cat <<'A'
  #20: cch+ 5 CEM  ----    ---- 5678:com.example.sync/u0a700
  #19: cch+ 5 CEM  ----    ---- 5679:org.thoughtcrime.securesms/u0a291
  #18: cch+ 5 CEM  ----    ---- 5680:com.user.exempt/u0a750
  #17: cch+ 5 CEM  ----    ---- 5681:com.google.android.gm/u0a760
A
  ;;
  deviceidle:whitelist) cat <<'W'
system-excidle,com.android.providers.downloads,10035
system,com.google.android.gms,10146
user,com.user.exempt,10750
W
  ;;
  deviceidle:*) echo false ;;
  wifi:*) : ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
cat <<'L'
package:org.thoughtcrime.securesms uid:10291
package:com.example.sync uid:10700
package:com.user.exempt uid:10750
package:com.google.android.gm uid:10760
L
S
cat > "$T/bin/am" <<'S'
#!/bin/sh
echo "$*" >> "$AM_LOG"
S
cat > "$T/bin/appops" <<'S'
#!/bin/sh
echo "No operations."
S
chmod +x "$T/bin/"*
echo "wakelock_action=1" > "$T/mod/config/governor.conf"
printf 'awake_pct_screenoff=40\nawake_window_min=90\n' > "$T/state"
# What an earlier build left behind: Signal restricted.
echo org.thoughtcrime.securesms > "$T/d/wakelock_restricted"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$SRC" > "$T/out" 2>&1

grep -qx 'set-standby-bucket org.thoughtcrime.securesms active' "$T/am.log" || f "Signal not given back"
grep -q 'set-standby-bucket org.thoughtcrime.securesms restricted' "$T/am.log" && f "Signal restricted again"
grep -q 'set-standby-bucket com.user.exempt restricted' "$T/am.log" && f "an app the user exempted from battery optimisation was restricted"
grep -q 'set-standby-bucket com.google.android.gm restricted' "$T/am.log" && f "Gmail restricted"
grep -qx 'set-standby-bucket com.example.sync restricted' "$T/am.log" || f "an ordinary cached holder was no longer restricted"
grep -qxF org.thoughtcrime.securesms "$T/d/wakelock_restricted" && f "Signal still on the restricted record"
grep -qxF com.example.sync "$T/d/wakelock_restricted" || f "the ordinary holder was not recorded for uninstall"
grep -q '^org.thoughtcrime.securesms|.*|protected$' "$T/d/wakelock_apps" || f "Signal not reported as protected"
grep -q '^com.user.exempt|.*|protected$' "$T/d/wakelock_apps" || f "exempt app not reported as protected"

# A pass that does not act (awake share under the bar) still releases a wrong restriction.
echo org.thoughtcrime.securesms > "$T/d/wakelock_restricted"; : > "$T/am.log"
printf 'awake_pct_screenoff=10\nawake_window_min=90\n' > "$T/state"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$SRC" >/dev/null 2>&1
grep -qx 'set-standby-bucket org.thoughtcrime.securesms active' "$T/am.log" || f "not released on a quiet pass"
[ -e "$T/d/wakelock_restricted" ] && f "empty record left behind"

# fix137: restrictions made under the earlier, looser rule are handed back once - an ordinary
# app included - and the marker keeps it to once.
rm -f "$T/d/wakelock_rules_v137"; echo com.example.other > "$T/d/wakelock_restricted"; : > "$T/am.log"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$SRC" >/dev/null 2>&1
grep -qx 'set-standby-bucket com.example.other active' "$T/am.log" || f "old-rule restriction not handed back"
[ -f "$T/d/wakelock_rules_v137" ] || f "migration marker not written"
echo com.example.other > "$T/d/wakelock_restricted"; : > "$T/am.log"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$SRC" >/dev/null 2>&1
grep -q 'com.example.other active' "$T/am.log" && f "migration ran twice"

# fix141: apps installed on the OP15 of capture 2830 that the list missed, and Telegram
# clients without "telegram" in their id. A game or a shop stays restrictable.
sed -n '/^_wl_protected() {$/,/^}$/p' "$SRC" > "$T/prot.sh"
. "$T/prot.sh"
for p in com.mywickr.wickr2 com.truecaller com.exteragram.messenger com.radolyn.ayugram tw.nekomimi.nekogram \
         com.samsung.accessory.paranmgr com.sony.songpal.mdr com.tranzmate org.thoughtcrime.securesms; do
  _wl_protected "$p" || f "$p not protected"
done
for p in com.activision.callofduty.shooter com.alibaba.aliexpresshd com.anthropic.claude; do
  _wl_protected "$p" && f "$p protected (it is not a messenger, call, mail, map or wearable app)"
done

[ "$fail" = 0 ] || exit 1
echo "PASS wakelock messenger guard: Signal & co. and battery-exempt apps are never restricted, old restrictions released"
