#!/bin/sh
# Contract: every standalone script that calls `settings` loads the fallback wrapper.
#
# On some OnePlus builds `settings` answers "cmd: Failure calling service settings: Failed
# transaction" and exits 0. The wrapper falls back to the content provider and never
# returns that text as a value; a script started with `sh` does not inherit it from
# service.sh. action.sh took the error string as the locale and printed in English.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for f in "$ROOT"/runtime/*.sh "$ROOT/action.sh" "$ROOT/service.sh" "$ROOT"/tools/logkit/_asb_logkit_common.sh; do
  case "${f##*/}" in
    asb_settings.sh|asb_apply_ledger.sh) continue ;;   # the wrapper itself / a sourced library
  esac
  grep -vE '^[[:space:]]*#' "$f" | grep -qE '(^|[^_a-zA-Z.])settings (get|put|delete) ' || continue
  grep -q 'asb_settings.sh' "$f" || { echo "FAIL settings wrapper: ${f#$ROOT/} calls settings without the wrapper" >&2; fail=1; }
done
grep -q "case \"\$_asb_loc\" in \*\[Ff\]ailure\*" "$ROOT/action.sh" || { echo "FAIL settings wrapper: action.sh may take an error string as the locale" >&2; fail=1; }
[ "$fail" = 0 ] && echo "PASS settings wrapper coverage"
exit "$fail"
