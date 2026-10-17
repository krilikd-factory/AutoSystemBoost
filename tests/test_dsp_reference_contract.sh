#!/usr/bin/env sh
# Regression: the known-good DSP path must not depend on a device-pack
# marker. It stages the exact shipped AIDL library selected by the ABI helper.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
mkdir -p "$MOD/bin" "$MOD/config" "$MOD/runtime"
cp "$ROOT/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT/runtime/asb_dsp_abi_apply.sh" "$MOD/runtime/asb_dsp_abi_apply.sh"
# A source-only archive carries no prebuilt libraries (fix133). The static gates below still
# run; only the staging half needs the .so files. It is skipped ONLY when the caller says so
# explicitly - a release build never sets this, so a package that lost its libraries still
# fails here instead of quietly falling back to the legacy effect.
PB="$ROOT/src/DSP_AIDL/prebuilt"
_pb_missing=0
for _pb in arm64-v8a/libasbdsp_v3.so armeabi-v7a/libasbdsp_v3.so arm64-v8a/asb_dsp_attach \
           arm64-v8a/libasbdsp_v2.so armeabi-v7a/libasbdsp_v2.so; do
  [ -s "$PB/$_pb" ] || _pb_missing=1
done
if [ "$_pb_missing" = 1 ] && [ "${ASB_DSP_REFERENCE_OPTIONAL:-0}" != 1 ]; then
  echo "FAIL: DSP prebuilt libraries missing under src/DSP_AIDL/prebuilt (set ASB_DSP_REFERENCE_OPTIONAL=1 only for a source-only archive)" >&2
  exit 1
fi
if [ "$_pb_missing" = 0 ]; then
  cp "$PB/arm64-v8a/libasbdsp_v3.so" "$MOD/bin/libasbdsp_v3.so"
  cp "$PB/armeabi-v7a/libasbdsp_v3.so" "$MOD/bin/libasbdsp_v3_32.so"
fi

# The feature remains enabled; user-level dsp_loudness defaults to off, so this
# does not enable any gain by itself.
grep -qx 'AUDIO=1' "$ROOT/features.conf"
if grep -q 'asb_device_pack_allows audio' "$ROOT/runtime/asb_dsp_abi_apply.sh" \
   || grep -q 'asb_device_pack_allows audio' "$ROOT/runtime/asb_audio_apply.sh"; then
  echo 'FAIL: direct DSP runtime still has a fingerprint-only audio gate' >&2
  exit 1
fi
# service.sh owns the boot-time overlay bind and attacher. It may retain separate
# gates for non-DSP vendor tweaks later in the file, but never around this block.
if sed -n '/^(/,/^) >\/dev\/null 2>\&1 \&/p' "$ROOT/service.sh" | grep -q 'asb_device_pack_allows audio'; then
  echo 'FAIL: boot-time DSP attacher still has a fingerprint-only audio gate' >&2
  exit 1
fi
if sed -n '/_abi_conf=/,/^fi$/p' "$ROOT/post-fs-data.sh" | grep -q 'asb_device_pack_allows audio'; then
  echo 'FAIL: early DSP ABI staging still has a fingerprint-only audio gate' >&2
  exit 1
fi
grep -q 'DSP status: requested' "$ROOT/action.sh" || {
  echo 'FAIL: action UI lacks DSP runtime status' >&2
  exit 1
}
# WebUI already permits 25 dB; every runtime/core/diagnostic path must now deliver that
# same ceiling rather than silently reporting requested +25 but applying legacy +18.
# fix74: the legacy effect runs the shared core, so its cap IS the core's cap.
grep -Fq '#include "asb_dsp_core.h"' "$ROOT/src/DSP/asb_dsp.c" || { echo 'FAIL: legacy DSP does not use the shared core (+25 dB cap)' >&2; exit 1; }
grep -Fq '#define ASB_GAIN_MB_MAX    2500' "$ROOT/src/DSP_AIDL/asb_dsp_core.h" || { echo 'FAIL: AIDL DSP cap is not +25 dB' >&2; exit 1; }
grep -Fq '[ "$_dsp_applied_mb" -gt 2500 ] && _dsp_applied_mb=2500' "$ROOT/runtime/asb_audio_apply.sh" || { echo 'FAIL: runtime DSP cap is not +25 dB' >&2; exit 1; }
grep -Fq '[ "$_dsp_expected_mb" -gt 2500 ] && _dsp_expected_mb=2500' "$ROOT/tools/asb_diag.sh" || { echo 'FAIL: diagnostic DSP cap is not +25 dB' >&2; exit 1; }

if [ "$_pb_missing" = 1 ]; then
  printf '%s\n' 'SKIP DSP reference staging: prebuilt libraries absent, ASB_DSP_REFERENCE_OPTIONAL=1 (static gates passed)'
  exit 0
fi
MODDIR="$MOD" sh "$MOD/runtime/asb_dsp_abi_apply.sh" aidl_v3 >/dev/null
cmp -s "$MOD/bin/libasbdsp_v3.so" "$MOD/system/vendor/lib64/soundfx/libasbdsp.so"
cmp -s "$MOD/bin/libasbdsp_v3_32.so" "$MOD/system/vendor/lib/soundfx/libasbdsp.so"

printf '%s\n' 'PASS DSP reference contract'
