#!/bin/sh
# Runtime (fix154): an app ticked in the Doze picker is kept awake by every ASB tweak.
#
# The picker says "ticked apps stay exempt from Doze". Two other battery tweaks could still
# hold such an app back: the wakelock watcher (restricted standby bucket) when the Doze
# trim is off, and background trimming (the "rare" bucket and memory trims for heavy apps
# such as Facebook or Instagram). The REAL functions run on mocked am/dumpsys.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL keep list guards: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/am" <<'S'
#!/bin/sh
case "$1" in
  get-standby-bucket) echo 40 ;;
  *) echo "$*" >> "$AM_LOG" ;;
esac
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1:${2:-}" in
  batterystats:*) printf '  All partial wake locks:\n  Wake lock u0a750 Sync: 55m 0s 1ms (9 times) realtime\n' ;;
  activity:*) echo '  #18: cch+ 5 CEM  ----    ---- 5680:com.facebook.katana/u0a750' ;;
  deviceidle:whitelist) echo 'system,com.google.android.gms,10146' ;;
  deviceidle:*) echo false ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
echo 'package:com.facebook.katana uid:10750'
S
printf '#!/bin/sh\necho "No operations."\n' > "$T/bin/appops"
printf '#!/bin/sh\necho 4242\n' > "$T/bin/pidof"
chmod +x "$T/bin/"*
echo com.facebook.katana > "$T/d/doze_whitelist_keep"
echo "wakelock_action=1" > "$T/mod/config/governor.conf"
printf 'awake_pct_screenoff=40\nawake_window_min=90\n' > "$T/state"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$ROOT/runtime/asb_wakelock_watch.sh" > "$T/out" 2>&1
grep -q 'com.facebook.katana restricted' "$T/am.log" 2>/dev/null && f "the wakelock watcher restricted an app ticked to stay awake"
rm -f "$T/d/doze_whitelist_keep"; : > "$T/am.log"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$ROOT/runtime/asb_wakelock_watch.sh" > "$T/out" 2>&1
grep -q 'com.facebook.katana restricted' "$T/am.log" || f "without the tick the holder is not restricted - the test no longer tells the two apart"
S="$ROOT/service.sh"
{ sed -n '/^asb_bg_bucket_set() {/,/^}/p' "$S"; sed -n '/^asb_bg_bucket_demote_idle() {/,/^}/p' "$S"; sed -n '/^asb_bg_trim_pkg() {/,/^}/p' "$S"; } > "$T/bg.sh"
grep -q 'ASB_DOZE_KEEP' "$T/bg.sh" || f "background trim functions not found"
echo com.facebook.katana > "$T/keep"; : > "$T/am.log"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" ASB_DOZE_KEEP="$T/keep" ASB_BG_BUCKETS_ORIG="$T/orig" sh -c '
  ASB_BG_BUCKETS_ORIG="$ASB_BG_BUCKETS_ORIG"; asb_bg_trim_is_top() { return 1; }; . "$1"
  asb_bg_bucket_demote_idle com.facebook.katana rare
  asb_bg_bucket_demote_idle com.instagram.android rare
  asb_bg_trim_pkg com.facebook.katana 40
  asb_bg_trim_pkg com.instagram.android 40' x "$T/bg.sh"
grep -q 'set-standby-bucket com.facebook.katana' "$T/am.log" && f "background trim demoted a ticked app"
grep -q 'send-trim-memory.*4242' "$T/am.log" || f "background trim stopped trimming other apps"
grep -q 'set-standby-bucket com.instagram.android rare' "$T/am.log" || f "background trim stopped demoting other apps"
[ "$(grep -c 'send-trim-memory' "$T/am.log")" = 1 ] || f "a ticked app got a memory trim: $(cat "$T/am.log")"
[ "$fail" = 0 ] && echo "PASS keep list guards: ticked apps are never restricted by the wakelock watcher nor trimmed in the background"
exit "$fail"
