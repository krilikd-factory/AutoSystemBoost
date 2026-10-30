#!/usr/bin/env bash
# Canonical regression entry point for source-only archives.
# DSP reference binaries are optional here; every source, native, UI and runtime gate remains mandatory.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export ASB_DSP_REFERENCE_OPTIONAL=1
exec bash "$ROOT/tools/asb_full_regression.sh" "$@"
