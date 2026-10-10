#!/bin/sh
# Contract: CPU/GPU portability must be capability-driven and fail closed outside known sysfs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
METRICS="$ROOT/src/asb_metrics.h"
WRITER="$ROOT/src/asb_writer.h"
GOV="$ROOT/src/asb_governor.c"
WEB="$ROOT/webroot/index.html"
CAPS="$ROOT/runtime/asb_capabilities.sh"
DIAG="$ROOT/tools/asb_diag.sh"

fail() { echo "FAIL cpu/gpu portability: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }

# CPU policies are classified by actual OPP ceiling, never directory/CPU number alone.
need "$METRICS" 'Policy IDs are CPU-number based implementation details'
need "$METRICS" 'found_hwmax[16]'
need "$METRICS" 'cpuinfo_max_freq'
need "$METRICS" 'policy directory numbers are not ordered by OPP'
need "$METRICS" 'g_cpu_all_ids'
need "$WRITER" 'EXTRA CLUSTERS'
need "$WRITER" 'cpu_snap_freq(j, (long)target)'

# GPU discovery supports standard graphics-named devfreq backends, but never guesses a
# generic max_freq node that could belong to memory/ISP/NPU.
need "$METRICS" 'metrics_discover_generic_gpu_devfreq'
need "$METRICS" 'metrics_gpu_devfreq_name_is_graphics'
need "$WRITER" 'writer_discover_generic_gpu_devfreq'
need "$WRITER" 'writer_gpu_devfreq_name_is_graphics'
need "$METRICS" 'Never guess from an arbitrary devfreq node'
need "$METRICS" 'strstr(lower, "mali")'
need "$WRITER" 'strstr(lower, "powervr")'
need "$CAPS" '*mali*/max_freq'
need "$CAPS" '*xclipse*/max_freq'

# No readable utilisation node must remain an honest unavailable signal, not a fabricated 0%.
need "$METRICS" 'int     load_valid'
need "$METRICS" 'g->load_valid = (load >= 0 && load <= 100) ? 1 : 0;'
need "$GOV" 'gpu_valid=%d'
need "$GOV" 'g_device_caps.has_gpu_load = (uint8_t)(metrics.gpu.load_valid ? 1 : 0);'
need "$WEB" 'Object.prototype.hasOwnProperty.call(st, '\''gpu_valid'\'')'
need "$WEB" 'GPU utilisation node is unavailable on this driver'
need "$DIAG" 'generic devfreq'
need "$DIAG" 'no recognised GPU devfreq backend'

# Native source must compile with its direct headers on the host; this catches missing POSIX
# includes from directory discovery before Android NDK release compilation.
CC_BIN="${CC:-cc}"
command -v "$CC_BIN" >/dev/null 2>&1 || fail 'C compiler unavailable'
"$CC_BIN" -std=gnu11 -fsyntax-only -I"$ROOT/src" "$ROOT/src/asb_governor.c" || fail 'native portability source does not compile'
sh -n "$CAPS" || fail 'capability script syntax'
sh -n "$DIAG" || fail 'diagnostic script syntax'

echo 'PASS: CPU/GPU portability contract'
