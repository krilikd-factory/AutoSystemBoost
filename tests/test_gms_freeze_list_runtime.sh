#!/bin/sh
# Runtime: gms_freeze touches GMS component names only - never words from a comment that
# slipped into a list - and cleans junk rows an older build left in its state file.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL gms freeze list: $*" >&2; exit 1; }
mkdir -p "$T/mod/config" "$T/bin"
printf 'gms_freeze=safe\n' > "$T/mod/config/governor.conf"
cat > "$T/bin/pm" <<'X'
#!/bin/sh
echo "$*" >> "$PM_LOG"
exit 0
X
chmod +x "$T/bin/pm"
printf '%s\n' 'no|enabled' 'needed|enabled' 'com.google.android.gms/.feedback.FeedbackAsyncService|enabled' > "$T/state"
PATH="$T/bin:$PATH" PM_LOG="$T/pm.log" MODDIR="$T/mod" ASB_GMS_STATE="$T/state" \
  sh "$ROOT/runtime/asb_gms_freeze.sh" > "$T/out" </dev/null
grep -q 'safe - 9 component' "$T/out" || { cat "$T/out"; fail "safe level must process exactly 9 components"; }
grep 'disable' "$T/pm.log" | grep -v 'com.google.android.gms/\.' && fail "pm disable called on a non-component"
grep -q '^enable no$\|^enable needed$' "$T/pm.log" && fail "junk rows were re-enabled instead of dropped"
grep -v '^com.google.android.gms/' "$T/state" && fail "junk rows survived in the state file"
[ "$(grep -c . "$T/state")" -eq 9 ] || fail "state must hold the 9 safe components"
echo "PASS gms freeze acts on component names only"
