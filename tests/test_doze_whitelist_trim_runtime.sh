#!/bin/sh
# Runtime (fix88): doze exemption trimming matches whole package names, keeps wearable /
# caller-ID / authenticator apps, and gives back what an earlier run took wrongly.
# OP15 /data/adb/asb: the system Gboard was trimmed because a third-party fork is called
# dev.jason.com.google.android.inputmethod.latin; the Galaxy Watch plugin and Truecaller too.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL doze trim: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
printf 'doze_level=aggressive\ndoze_trim_whitelist=1\n' > "$T/mod/config/governor.conf"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:%s\n' dev.jason.com.google.android.inputmethod.latin com.samsung.wearable.watch7plugin com.truecaller com.facebook.katana com.example.chat
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = deviceidle ] || exit 0
case "$3" in
  +*|-*) echo "$3" >> "$WL_LOG"; exit 0 ;;
esac
printf 'user,%s,10001\n' com.google.android.inputmethod.latin dev.jason.com.google.android.inputmethod.latin com.samsung.wearable.watch7plugin com.truecaller com.facebook.katana com.example.chat
S
chmod +x "$T/bin/"*
printf '%s\n' com.google.android.inputmethod.latin com.samsung.wearable.watch7plugin com.facebook.katana > "$T/st/doze_whitelist_removed"
PATH="$T/bin:$PATH" WL_LOG="$T/wl.log" MODDIR="$T/mod" ASB_DOZE_STATE_DIR="$T/st" \
  sh "$ROOT/runtime/asb_doze_apply.sh" >/dev/null 2>&1 </dev/null
grep -qx '+com.google.android.inputmethod.latin' "$T/wl.log" || f "system Gboard not given back"
grep -qx '+com.samsung.wearable.watch7plugin' "$T/wl.log" || f "watch plugin not given back"
grep -qx -- '-com.google.android.inputmethod.latin' "$T/wl.log" && f "system Gboard trimmed (substring match)"
grep -qx -- '-com.truecaller' "$T/wl.log" && f "caller ID trimmed"
grep -qx -- '-com.samsung.wearable.watch7plugin' "$T/wl.log" && f "watch plugin trimmed"
grep -qx -- '-com.example.chat' "$T/wl.log" || f "an ordinary user app was not trimmed"
grep -qx 'com.facebook.katana' "$T/st/doze_whitelist_removed" || f "a still-valid record was dropped"
grep -qx 'com.google.android.inputmethod.latin' "$T/st/doze_whitelist_removed" && f "returned app still recorded as removed"
[ "$fail" = 0 ] && echo "PASS doze whitelist trim is exact and keeps companions"
exit "$fail"
