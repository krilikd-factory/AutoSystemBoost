#!/bin/sh
# Runtime (fix128): ASB gives the animation scales back once, then leaves them alone.
#
# Field report (OP15, V64): animations removed in Android, ASB's animation options tried and
# switched off again - and the scale returned to 1.0x again and again, through reboots. With
# "UI speed" off, asb_apply_ux restored its saved baseline on EVERY call whenever the live
# value differed from it, and a baseline holding a profile scale (0.8/0.9) was rewritten as
# 1.0 - so the user's own 0 was "corrected" back to 1.0 forever. The OP15 diag of the author
# shows the other half: anim_speed=3 (0.85x) chosen in the WebUI, live scale 0.9 - the
# profile's - because the profile pass overwrote the explicit choice.
# The REAL asb_apply_ux is cut out of profile_core.sh and run against a fake settings store.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL anim ownership: $*" >&2; exit 1; }
MD="$T/mod"; DD="$T/data"; ST="$T/settings"
mkdir -p "$MD/config" "$MD/runtime" "$DD" "$ST" "$T/bin"
cp "$ROOT/runtime/asb_anim_apply.sh" "$MD/runtime/"
cat > "$T/bin/settings" <<'X'
#!/bin/sh
d="$ASB_FAKE_SETTINGS"
case "$1" in
  get) cat "$d/$2.$3" 2>/dev/null || echo null ;;
  put) printf '%s\n' "$4" > "$d/$2.$3"; echo "$2.$3=$4" >> "$d/writes.log" ;;
  delete) rm -f "$d/$2.$3" ;;
esac
X
chmod +x "$T/bin/settings"
export PATH="$T/bin:$PATH" ASB_FAKE_SETTINGS="$ST"
sed -n '/^asb_apply_ux() {/,/^}/p' "$ROOT/runtime/profile_core.sh" > "$T/ux.sh"
[ -s "$T/ux.sh" ] || fail "asb_apply_ux not found"

conf() {   # $1 UX_MANAGE_TIMEOUTS  $2 anim_speed
  printf 'UX_MANAGE_TIMEOUTS=%s\nUX_MANAGE_OEM_TOGGLES=0\nanim_speed=%s\ndisable_blur=0\n' "$1" "$2" > "$MD/config/governor.conf"
}
scale() { printf '%s\n' "$1" > "$ST/global.window_animation_scale"; printf '%s\n' "$1" > "$ST/global.transition_animation_scale"; printf '%s\n' "$1" > "$ST/global.animator_duration_scale"; }
live() { cat "$ST/global.window_animation_scale"; }
apply() {
  ( MODDIR="$MD" ASB_DATA_DIR="$DD" UX_ANIM_SCALE=0.9 sh -c '
      asb_feature_enabled() { return 0; }; has() { command -v "$1" >/dev/null 2>&1; }
      asb_settings_put() { settings put "$1" "$2" "$3"; }
      asb_ram_expand_apply() { :; }
      . "$1"; asb_apply_ux' x "$T/ux.sh" ) >/dev/null 2>&1
}

# 1. UI speed on: the profile scale is applied, the user's own value saved first.
scale 0; conf 1 -1; apply
[ "$(live)" = 0.9 ] || fail "managed scale not applied: $(live)"
grep -q '^BASE_WIN_ANIM=0$' "$MD/config/ux_baseline.conf" || fail "user's own scale not saved"
# 2. Switched off: given back once, then the baseline is gone.
conf 0 -1; apply
[ "$(live)" = 0 ] || fail "user's scale not restored: $(live)"
[ -f "$MD/config/ux_baseline.conf" ] && fail "baseline kept after the restore"
# 3. Afterwards ASB never touches it - whatever the user picks.
scale 1.5; : > "$ST/writes.log"
apply; apply; apply
[ "$(live)" = 1.5 ] || fail "ASB changed a scale it no longer manages: $(live)"
[ -s "$ST/writes.log" ] && fail "settings written while unmanaged: $(cat "$ST/writes.log")"
# 4. The field case: a baseline from an older build (a profile 0.8, read as 1.0), no record of
#    what ASB wrote, and the user's "remove animations" (0). Hands off, every time.
rm -rf "$DD"; mkdir -p "$DD"
printf 'BASE_WIN_ANIM=0.8\nBASE_TRANS_ANIM=0.8\nBASE_DUR_ANIM=0.8\n' > "$MD/config/ux_baseline.conf"
scale 0; conf 0 -1
apply; apply; apply
[ "$(live)" = 0 ] || fail "user's 0 overwritten (the 1.0x every few seconds report): $(live)"
[ -f "$MD/config/ux_baseline.conf" ] && fail "stale baseline kept"
# 5. ...but a scale an older build left behind (0.9) is still given back to stock, once.
rm -rf "$DD"; mkdir -p "$DD"
printf 'BASE_WIN_ANIM=1\nBASE_TRANS_ANIM=1\nBASE_DUR_ANIM=1\n' > "$MD/config/ux_baseline.conf"
scale 0.9; apply
[ "$(live)" = 1 ] || fail "older build's 0.9 not restored: $(live)"
# 6. No baseline at all: the legacy 0.8/0.9 cleanup runs once, then a user's own 0.8 stays.
rm -rf "$DD"; mkdir -p "$DD"; rm -f "$MD/config/ux_baseline.conf"
scale 0.8; apply
[ "$(live)" = 1.0 ] || fail "legacy cleanup did not run: $(live)"
scale 0.8; apply
[ "$(live)" = 0.8 ] || fail "user's own 0.8 reset by the legacy cleanup: $(live)"
# 7. An explicit Animation Speed wins over the profile (anim_speed=3 is 0.85x).
rm -rf "$DD"; mkdir -p "$DD"; rm -f "$MD/config/ux_baseline.conf"
scale 1; conf 1 3; apply
[ "$(live)" = 0.85 ] || fail "profile overwrote the explicit speed: $(live)"
: > "$ST/writes.log"; apply
[ -s "$ST/writes.log" ] && fail "explicit speed rewritten although already set"

echo "PASS anim ownership: given back once, never fought afterwards, explicit speed wins"
