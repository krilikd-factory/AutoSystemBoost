#!/bin/sh
# Runtime (fix141): builds and runs tests/test_camera_pcm_native.c against the production
# asb_metrics.h - the camera guard drops with the screen off, and the PCM playback probe the
# screen-off drain tracker uses tells playback from capture and from "cannot read".
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CCX="${HOST_CC:-${CC:-}}"
[ -n "$CCX" ] || for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && { CCX="$c"; break; }; done
[ -n "$CCX" ] || { echo "FAIL camera/pcm native: no host C compiler" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
"$CCX" -D_GNU_SOURCE -std=c11 -O1 -Wno-unused-function -I "$ROOT/src" "$ROOT/tests/test_camera_pcm_native.c" -lm -o "$T/fx" \
  || { echo "FAIL camera/pcm native: build failed" >&2; exit 1; }
"$T/fx"
