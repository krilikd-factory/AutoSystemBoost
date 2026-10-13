#!/bin/sh
# Runtime (fix141): asbdiag and the full-day report name the processes behind native crashes
# and say when ASB code is in one - the crashed process or the crashing thread's backtrace,
# not the memory map (every audio HAL maps libasbdsp, whatever crashed it).
#
# The 22:45 OP15 asbdiag: "dropbox SYSTEM_TOMBSTONE : 18 (latest 22:45:25)" and nothing else.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL native crash names: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
D="$T/tomb"; mkdir -p "$D"
tomb() {   # $1 file  $2 cmdline  $3 frame library
  cat > "$D/$1" <<X
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
Build fingerprint: 'OnePlus/CPH2745IN/OP611FL1:16/x:user/release-keys'
Timestamp: 2026-10-12 22:45:25.123456789+0200
Process uptime: 3s
Cmdline: $2
pid: 1234, tid: 1240, name: HwBinder:1234_2  >>> $2 <<<
uid: 1041
signal 6 (SIGABRT), code -1 (SI_QUEUE), fault addr --------
Abort message: 'FORTIFY: pthread_mutex_lock called on a destroyed mutex'

backtrace:
      #00 pc 0000000000061f0c  /apex/com.android.runtime/lib64/bionic/libc.so (abort+164)
      #01 pc 0000000000012345  $3

memory map (2 entries):
    7a00000000-7a00010000 r-xp  /vendor/lib64/soundfx/libasbdsp.so
    7b00000000-7b00010000 r-xp  /apex/com.android.runtime/lib64/bionic/libc.so
X
}
tomb tombstone_00 /vendor/bin/hw/audiohalservice.qti /vendor/lib64/libaudioroute.so
tomb tombstone_01 /vendor/bin/hw/audiohalservice.qti '/vendor/lib64/soundfx/libasbdsp.so (asb_core_process_f32+88)'
tomb tombstone_02 /data/adb/asb/asb_dsp_attach /system/lib64/libaudioclient.so
true > "$D/tombstone_00.pb"
touch -d '2026-10-12 22:40:00' "$D/tombstone_00"; touch -d '2026-10-12 22:41:00' "$D/tombstone_01"; touch -d '2026-10-12 22:42:00' "$D/tombstone_02"

# asbdiag: the real function, with its print helpers stubbed.
sed -n '/^_asb_tombstones() {$/,/^}$/p' "$ROOT/tools/asb_diag.sh" > "$T/fn.sh"
grep -q '_asb_tombstones' "$T/fn.sh" || fail "function not found in asbdiag"
out="$(P() { echo "$*"; }; NOTE() { echo "NOTE $*"; }; . "$T/fn.sh"; ASB_TOMBSTONE_DIR="$D" _asb_tombstones)"
printf '%s\n' "$out" | grep -q 'audiohalservice.qti  signal 6 (SIGABRT)$' || fail "unrelated audio HAL crash not listed plainly: $out"
[ "$(printf '%s\n' "$out" | grep -c '<< ASB code in this crash')" = 2 ] || fail "ASB crashes not told apart from the memory map: $out"
printf '%s\n' "$out" | grep -q 'asb_dsp_attach .*<< ASB code' || fail "a crash of the attach daemon not flagged: $out"
printf '%s\n' "$out" | grep -q "Abort message: 'FORTIFY" || fail "abort message missing"
printf '%s\n' "$out" | grep -q '^NOTE 2 of these crashes have ASB code' || fail "summary missing: $out"
printf '%s\n' "$out" | grep -q 'pb' && fail "a .pb tombstone listed"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"

# Full-day report: only tombstones newer than the capture start.
out="$( (set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$ROOT/tools/logkit/_asb_logkit_common.sh" >/dev/null 2>&1
         LK_START_EPOCH="$(date -d '2026-10-12 22:40:30' +%s)" ASB_TOMBSTONE_DIR="$D" lk_emit_native_crashes) )"
printf '%s\n' "$out" | grep -q 'libasbdsp' && fail "memory-map library leaked into the report"
[ "$(printf '%s\n' "$out" | grep -c '^  [0-9]')" = 2 ] || fail "capture window not applied: $out"
printf '%s\n' "$out" | grep -q '^2 of them with ASB code in the crash' || fail "report summary missing: $out"
grep -q '^    lk_emit_native_crashes$' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "report does not include the section"
echo "PASS native crash names: crashed processes named, ASB code told apart from the memory map"
