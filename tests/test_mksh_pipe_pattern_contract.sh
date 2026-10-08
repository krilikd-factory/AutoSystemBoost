#!/bin/sh
# Contract: no unescaped | inside a ${var#pat} / ${var%pat} pattern.
#
# Android's /system/bin/sh is mksh, and mksh reads a bare | in those patterns as an
# alternation: "${l%%|*}" on "0|916479" yields "" and "${l#*|}" yields the whole string.
# Every host shell (dash, bash, BusyBox ash) does the expected split, so host tests passed
# while the device failed: the screen-off LTE restore dropped every record as "bad" and
# never gave 5G back, and the GNSS, phantom-process and Wi-Fi fallback restores parsed
# their records the same way. Write \| (works in every shell) or split with IFS/read.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bad="$(cd "$ROOT" && grep -rnoE '\$\{[A-Za-z_][A-Za-z0-9_]*(%%?|##?)[^}]*\}' \
        --include=*.sh common runtime tools system/bin service.sh post-fs-data.sh uninstall.sh action.sh customize.sh 2>/dev/null \
      | grep -E '[^\\]\|' | grep -vE '"[^"]*\|[^"]*"' )"
if [ -n "$bad" ]; then
  echo "FAIL mksh pipe patterns: unescaped | in a parameter pattern:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
echo "PASS mksh pipe-pattern contract"
