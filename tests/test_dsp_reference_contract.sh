#!/usr/bin/env sh
# Regression: the V63-315-compatible DSP path must not depend on a device-pack
# marker. It stages the exact shipped AIDL library selected by the ABI helper.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
mkdir -p "$MOD/bin" "$MOD/config" "$MOD/runtime"
cp "$ROOT/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT/runtime/asb_dsp_abi_apply.sh" "$MOD/runtime/asb_dsp_abi_apply.sh"
cp "$ROOT/src/DSP_AIDL/prebuilt/arm64-v8a/libasbdsp_v3.so" "$MOD/bin/libasbdsp_v3.so"
cp "$ROOT/src/DSP_AIDL/prebuilt/armeabi-v7a/libasbdsp_v3.so" "$MOD/bin/libasbdsp_v3_32.so"

# The feature remains enabled; user-level dsp_loudness defaults to off, so this
# does not enable any gain by itself.
grep -qx 'AUDIO=1' "$ROOT/features.conf"
if grep -q 'asb_device_pack_allows audio' "$ROOT/runtime/asb_dsp_abi_apply.sh" \
   || grep -q 'asb_device_pack_allows audio' "$ROOT/runtime/asb_audio_apply.sh"; then
  echo 'FAIL: DSP runtime still has a fingerprint-only audio gate' >&2
  exit 1
fi

MODDIR="$MOD" sh "$MOD/runtime/asb_dsp_abi_apply.sh" aidl_v3 >/dev/null
cmp -s "$MOD/bin/libasbdsp_v3.so" "$MOD/system/vendor/lib64/soundfx/libasbdsp.so"
cmp -s "$MOD/bin/libasbdsp_v3_32.so" "$MOD/system/vendor/lib/soundfx/libasbdsp.so"
test -s "$ROOT/src/DSP_AIDL/prebuilt/arm64-v8a/asb_dsp_attach"
test -s "$ROOT/src/DSP_AIDL/prebuilt/arm64-v8a/libasbdsp_v2.so"
test -s "$ROOT/src/DSP_AIDL/prebuilt/armeabi-v7a/libasbdsp_v2.so"

printf '%s\n' 'PASS DSP reference contract'
