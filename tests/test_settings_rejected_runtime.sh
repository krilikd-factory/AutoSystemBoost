#!/bin/sh
# Runtime (fix129): a settings key the ROM refuses is not asked again on every boot.
#
# OP15 asbdiag: network_recommendations_enabled "not_writable (write rejected)" 16 times and
# cloud_dns_happy_eyeballs_priority_enabled 7 times - three `settings` calls each, every boot
# and every reinforce pass, for a write Android 16 will never take. The ledger now remembers
# the refusal per ROM build: the next attempt is recorded and skipped; a new install or an
# OTA tries again.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL settings rejected: $*" >&2; exit 1; }
mkdir -p "$T/bin" "$T/state" "$T/s"
cat > "$T/bin/settings" <<'X'
#!/bin/sh
echo "$*" >> "$FAKE/calls"
case "$1" in
  get) cat "$FAKE/s/$2.$3" 2>/dev/null || echo null ;;
  put) case "$3" in network_recommendations_enabled) echo "java.lang.IllegalArgumentException: write rejected" >&2; exit 1 ;; esac
       printf '%s\n' "$4" > "$FAKE/s/$2.$3" ;;
esac
X
printf '#!/bin/sh\ncat "$FAKE/fp" 2>/dev/null\n' > "$T/bin/getprop"
chmod +x "$T/bin/settings" "$T/bin/getprop"
echo "OnePlus/CPH2745/OP611FL1:16/A" > "$T/fp"
export PATH="$T/bin:$PATH" FAKE="$T" ASB_CONFIG_STATE="$T/state"
run() { sh -c '. "$1"; asb_ledger_settings "$2" "$3" "$4"; echo "rc=$?"' x "$ROOT/runtime/asb_apply_ledger.sh" "$@"; }

r="$(run global network_recommendations_enabled 0)"
[ "$r" = rc=1 ] || fail "rejected write reported as success: $r"
grep -qx 'global|network_recommendations_enabled|0|OnePlus/CPH2745/OP611FL1:16/A' "$T/state/settings_rejected" || fail "refusal not remembered"
: > "$T/calls"
r="$(run global network_recommendations_enabled 0)"
[ "$r" = rc=1 ] || fail "skipped write reported as success: $r"
[ -s "$T/calls" ] && fail "settings called again for a known refusal: $(cat "$T/calls")"
tail -1 "$T/state/apply_ledger" | grep -q 'not_writable|rejected before on this ROM build - not retried' || fail "skip not in the ledger"
# Other keys are unaffected.
r="$(run global wifi_scan_throttle_enabled 1)"
[ "$r" = rc=0 ] || fail "accepted write broken: $r"
# A different value, or a different ROM build, is tried again.
: > "$T/calls"; run global network_recommendations_enabled 1 >/dev/null
grep -q '^put global network_recommendations_enabled 1' "$T/calls" || fail "another value not tried"
echo "OnePlus/CPH2745/OP611FL1:16/B" > "$T/fp"
: > "$T/calls"; run global network_recommendations_enabled 0 >/dev/null
grep -q '^put global network_recommendations_enabled 0' "$T/calls" || fail "not retried after an OTA"
# A value the ROM stored in another form did take: not remembered as a refusal.
cat > "$T/bin/settings" <<'X'
#!/bin/sh
echo "$*" >> "$FAKE/calls"
case "$1" in
  get) cat "$FAKE/s/$2.$3" 2>/dev/null || echo null ;;
  put) printf '%s\n' "${4%.0}" > "$FAKE/s/$2.$3"; [ "${4%.0}" = "$4" ] || exit 1 ;;
esac
X
chmod +x "$T/bin/settings"
run global some_scale 1.0 >/dev/null
grep -q '|some_scale|' "$T/state/settings_rejected" && fail "a normalised value was remembered as refused"
# A new install forgets the list.
grep -q '^rm -f /data/adb/asb/settings_rejected' "$ROOT/common/install.sh" || fail "install keeps old refusals"
echo "PASS settings rejected: a refused key is asked once per ROM build"
