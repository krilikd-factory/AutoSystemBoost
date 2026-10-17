#!/bin/sh
# fix73: the DSP is registered in the effects config a HIDL audio HAL reads
# (/odm/etc/audio_effects.xml on SM8650 - field OP12: library staged, never mapped), and a
# crash fuse removes every effects-config bind if audioserver/the HAL then keeps restarting.
# Runtime: the REAL asb_odm_rebind.sh effects-guard against fake pidof/umount/setprop.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/runtime/asb_odm_rebind.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL dsp effects guard: $*" >&2; fail=1; }

# --- installer and boot wiring ------------------------------------------------------------
I="$ROOT/common/install.sh"
grep -q '/odm/etc/audio_effects.xml \\' "$I" || f "installer does not register the HIDL-name odm config"
grep -q 'ro.boot.product.vendor.sku' "$I" || f "installer ignores the vendor SKU dirs"
grep -q 'dsp_effects_blocked' "$I" || f "installer ignores a tripped fuse"
grep -q 'asb_odm_rebind.sh" effects-guard' "$ROOT/service.sh" || f "boot does not start the fuse"
grep -q 'dsp_effects_blocked' "$ROOT/uninstall.sh" || f "uninstall leaves the fuse flag"
grep -q 'first $_dn in lookup order' "$ROOT/tools/asb_diag.sh" || f "asbdiag does not name the config the HAL reads"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

# --- runtime ---------------------------------------------------------------------------
SH="${ASB_TEST_SH:-sh}"
[ -x "$ROOT/../mksh_bin" ] && SH="$ROOT/../mksh_bin"
mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/pidof" <<'X'
#!/bin/sh
# audioserver pid comes from a counter file advanced on every call when CRASHING=1
case "$1" in
  audioserver)
    n="$(cat "$PIDF" 2>/dev/null || echo 100)"
    [ "${CRASHING:-0}" = 1 ] && { n=$((n + 1)); echo "$n" > "$PIDF"; }
    echo "$n" ;;
  android.hardware.audio.service_64) echo 900 ;;
  *) exit 1 ;;
esac
X
printf '#!/bin/sh\necho "$@" >> "$UMLOG"\nexit 0\n' > "$T/bin/umount"
printf '#!/bin/sh\necho "$@" >> "$SPLOG"\n' > "$T/bin/setprop"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*

run_guard() {   # $1 = CRASHING
  printf '/odm/etc/audio_effects.xml|%s/p1\n/odm/etc/camera/x.json|%s/p2\n' "$T" "$T" > "$T/man"
  true > "$T/p1"; true > "$T/p2"
  printf '1 2 0:1 / /odm/etc/audio_effects.xml rw - f2fs /dev/x rw\n' > "$T/mi"
  rm -f "$T/state/dsp_effects_blocked" "$T/um" "$T/sp" "$T/pid"
  ( PATH="$T/bin:$PATH" CRASHING="$1" PIDF="$T/pid" UMLOG="$T/um" SPLOG="$T/sp" \
    ASB_ODM_MAN="$T/man" ASB_ODM_LOG="$T/log" ASB_ODM_MOUNTINFO="$T/mi" ASB_ODM_NS=none \
    ASB_ODM_STATE="$T/state" ASB_ODM_GUARD_POLLS=6 ASB_ODM_GUARD_SLEEP=0 \
    "$SH" "$R" effects-guard )
}

run_guard 0
[ ! -f "$T/state/dsp_effects_blocked" ] || f "stable audio tripped the fuse"
grep -q '/odm/etc/audio_effects.xml' "$T/man" || f "stable audio lost the effects bind"
grep -q 'result=stable restarts=0' "$T/log" || f "stable verdict not logged"

run_guard 1
[ -f "$T/state/dsp_effects_blocked" ] || f "crash loop did not trip the fuse"
grep -q 'audio_effects' "$T/man" && f "effects bind still in the manifest after tripping"
grep -q '/odm/etc/camera/x.json' "$T/man" || f "tripping removed an unrelated (camera) bind"
grep -q '/odm/etc/audio_effects.xml' "$T/um" 2>/dev/null || f "effects config not unmounted"
[ ! -f "$T/p1" ] || f "effects payload left behind"
grep -q 'ctl.restart audioserver' "$T/sp" 2>/dev/null || f "audioserver not restarted on stock configs"

# No effects bind at all: the guard does nothing (no polling, no log line).
printf '/odm/etc/camera/x.json|%s/p2\n' "$T" > "$T/man"; true > "$T/log"
( PATH="$T/bin:$PATH" ASB_ODM_MAN="$T/man" ASB_ODM_LOG="$T/log" ASB_ODM_STATE="$T/state" "$SH" "$R" effects-guard )
[ -s "$T/log" ] && f "guard ran without an effects bind"

[ "$fail" = 0 ] && echo "PASS dsp effects guard runtime"
exit "$fail"
