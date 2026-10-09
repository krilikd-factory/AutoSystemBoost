#!/bin/sh
# fix77: off the selected outputs the attach daemon RELEASES the effect instead of keeping
# it attached at gain 0. An enabled effect on the global mix is non-offloadable for the
# audio policy even as a pass-through, so the stream stayed off the offload path and the
# CPU awake (dsp_outputs=speaker/bt is set on field phones). The daemon is a prebuilt, so
# the freshness gate must refuse an older binary.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/src/DSP_AIDL/asb_dsp_attach.cpp"
fail() { echo "FAIL dsp route release: $*" >&2; exit 1; }
grep -q 'int route_ok = route_allows_dsp();' "$A" || fail "daemon does not check the route before attaching"
grep -q 'if (want_on && !route_ok) {' "$A" || fail "no release branch"
grep -q 'logline("released (route not selected)");' "$A" || fail "release not logged (freshness marker)"
# the release branch must come before the attach code, or it never runs while attached
_rel="$(grep -n 'if (want_on && !route_ok) {' "$A" | cut -d: -f1)"
_att="$(grep -n 'next->set(&kAsbTypeUuid' "$A" | cut -d: -f1)"
[ "$_rel" -lt "$_att" ] || fail "release branch after the attach path"
grep -q '"released (route not selected)"; do' "$ROOT/src/build_ndk_release.sh" || fail "freshness gate misses the release marker"
grep -q 'persist.asb.dsp.voice' "$A" || fail "voice edits do not trigger a push"
grep -q 'DSP released on purpose' "$ROOT/tools/asb_diag.sh" || fail "asbdiag reports the intended release as a failure"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
# fix79: with the screen off the route watcher still reacts to a PCM change (one pass)
grep -q '_sig_off="$(grep -l RUNNING /proc/asound/card\*/pcm\*p/sub\*/status' "$ROOT/service.sh" || fail "screen-off route change is never noticed"
grep -q '\[ "$_sig_off" != "${_prev_sig:-}" \] || continue' "$ROOT/service.sh" || fail "screen-off pass is not gated on a PCM change"
echo "PASS DSP released off the selected outputs"
