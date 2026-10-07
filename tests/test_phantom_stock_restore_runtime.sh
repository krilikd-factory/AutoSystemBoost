#!/bin/sh
# Runtime: phantom_procs strict/relaxed -> stock puts the original value back.
# The stock branch read profile_runtime_baseline.v1, but asb_settings_put records in
# baseline.txt, so the value was never found and the change was one-way.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL phantom restore: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime"
cp "$ROOT/runtime/asb_baseline.sh" "$T/mod/runtime/"
cat > "$T/bin/settings" <<'S'
#!/bin/sh
F="$SETF"
case "$1" in
  get) v="$(grep -m1 "^$2|$3|" "$F" 2>/dev/null | cut -d'|' -f3)"; echo "${v:-null}" ;;
  put) grep -v "^$2|$3|" "$F" > "$F.n" 2>/dev/null; echo "$2|$3|$4" >> "$F.n"; mv "$F.n" "$F" ;;
  delete) grep -v "^$2|$3|" "$F" > "$F.n" 2>/dev/null; mv "$F.n" "$F" ;;
esac
S
chmod +x "$T/bin/settings"
run() {
  echo "phantom_procs=$1" > "$T/mod/config/governor.conf"
  SETF="$T/set" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_BASELINE="$T/baseline.txt" \
    ASB_PROFILE_BASELINE="$T/pb" ASB_LEDGER="$T/ledger" sh "$ROOT/runtime/asb_system_tweaks.sh" >/dev/null 2>&1
}
echo "global|settings_enable_monitor_phantom_procs|true" > "$T/set"
run relaxed
grep -q '^global|settings_enable_monitor_phantom_procs|false$' "$T/set" || f "relaxed did not write false"
run stock
grep -q '^global|settings_enable_monitor_phantom_procs|true$' "$T/set" || f "stock did not restore the original value: $(cat "$T/set")"
# Unset before ASB -> stock deletes it again.
: > "$T/set"; rm -f "$T/baseline.txt"
run strict; run stock
grep -q 'settings_enable_monitor_phantom_procs' "$T/set" && f "stock left a key that was unset before ASB"
[ "$fail" = 0 ] && echo "PASS phantom stock restore"
exit "$fail"
