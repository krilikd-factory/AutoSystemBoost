#!/bin/sh
# Contract: keys the WebUI sends to "governor reload" are keys the governor reads.
# BG_TRIM_LEVEL, UX_MANAGE_* and sustained_temp_mode were in that list; the binary parses
# none of them, so the toast said "applied" and nothing changed until a reboot.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail=0; f() { echo "FAIL webui apply truth: $*" >&2; fail=1; }
keys="$(sed -n "/var GOV_KEYS = \[/,/\];/p" "$H" | grep -oE "'[A-Za-z_]+'" | tr -d "'")"
for k in $keys; do
  # Keys handled by their own branch before the generic reload are fine.
  case "$k" in BG_TRIM_LEVEL|UX_MANAGE_OEM_TOGGLES|UX_MANAGE_TIMEOUTS|sustained_temp_mode)
    grep -q "key === '$k'" "$H" || f "$k has no dedicated apply branch"; continue ;;
  esac
  grep -q "\"$k\"" "$ROOT/src/asb_config.h" "$ROOT/src/asb_governor.c" || f "$k is reload-applied but the governor never parses it"
done
grep -q "shQuote('sustained_temp_user_override') + ' ' + shQuote('1')" "$H" || f "slider move does not publish the override flag"
grep -q 'off) asb_bg_bucket_restore >/dev/null 2>&1; break ;;' "$ROOT/service.sh" || f "six-hour bucket loop ignores BG_TRIM_LEVEL=off"
[ "$fail" = 0 ] && echo "PASS webui apply truth"
exit "$fail"
