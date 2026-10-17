#!/bin/sh
# Runtime: lowering gms_trim undoes what strict did.
# strict removes GMS from the (persisted) Doze exemption list and denies RUN_ANY_IN_BACKGROUND;
# stock and lite used to leave both in place.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL gms trim levels: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
W="$WLFILE"
case "$3" in
  '') cat "$W" 2>/dev/null ;;
  -*) grep -v ",${3#-}," "$W" > "$W.n"; mv "$W.n" "$W" ;;
  +*) echo "system,${3#+},10147" >> "$W" ;;
esac
S
printf '#!/bin/sh\necho "$*" >> "$OPLOG"\n' > "$T/bin/cmd"
printf '#!/bin/sh\n:\n' > "$T/bin/am"
printf '#!/bin/sh\necho package:com.google.android.gms\n' > "$T/bin/pm"
chmod +x "$T/bin/"*
run() {
  echo "gms_trim=$1" > "$T/mod/config/governor.conf"
  WLFILE="$T/wl" OPLOG="$T/ops" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_GMS_MARK="$T/mark" \
    sh "$ROOT/runtime/asb_gms_trim.sh" >/dev/null 2>&1
}
echo "system,com.google.android.gms,10147" > "$T/wl"
run strict
grep -q 'com.google.android.gms' "$T/wl" && f "strict did not remove GMS from the exemption list"
[ -f "$T/mark" ] || f "strict did not mark the removal"
: > "$T/ops"; run lite
grep -q ',com.google.android.gms,' "$T/wl" || f "lite left GMS outside the exemption list"
grep -q 'RUN_ANY_IN_BACKGROUND allow' "$T/ops" || f "lite kept strict's RUN_ANY_IN_BACKGROUND deny"
run strict; run stock
grep -q ',com.google.android.gms,' "$T/wl" || f "stock left GMS outside the exemption list"
[ "$(grep -c gms "$T/wl")" = 1 ] || f "GMS added twice"
# Old install: no marker, GMS missing at stock -> put back.
: > "$T/wl"; rm -f "$T/mark"; run stock
grep -q ',com.google.android.gms,' "$T/wl" || f "pre-marker install not healed at stock"
[ "$fail" = 0 ] && echo "PASS gms trim levels"
exit "$fail"
