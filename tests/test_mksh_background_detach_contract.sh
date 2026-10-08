#!/bin/sh
# Contract: runtime helpers detach background bodies with an exec inside the subshell,
# never with a redirect on the closing ")".
#
# Under mksh (Android's /system/bin/sh) "( ...; x=$(cmd); ... ) >/dev/null 2>&1 &" does not
# release the caller's stdout: a caller capturing the output - the WebUI's exec bridge -
# waits for the whole background body. Measured: the async asbdiag start returned only
# after the export finished (1066 ms for a 1 s fake export, 19 ms under dash). The
# working form is "( exec </dev/null >/dev/null 2>&1; ... ) &".
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bad="$(grep -nE '^[[:space:]]*\)[[:space:]]*(</dev/null[[:space:]]*)?>[[:space:]]*/dev/null[[:space:]]+2>&1[[:space:]]*(</dev/null[[:space:]]*)?&[[:space:]]*$' \
        "$ROOT"/runtime/*.sh "$ROOT"/uninstall.sh 2>/dev/null)"
if [ -n "$bad" ]; then
  echo "FAIL mksh background detach: redirect on a closing ) - use exec inside the subshell:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
if command -v mksh >/dev/null 2>&1; then
  _a="$(date +%s%N 2>/dev/null || echo 0)"
  _x="$(mksh -c '( exec </dev/null >/dev/null 2>&1; y="$(echo z)"; sleep 1 ) & echo p')"
  _b="$(date +%s%N 2>/dev/null || echo 0)"
  [ "$_a" != 0 ] && [ $(( (_b - _a) / 1000000 )) -lt 500 ] || { echo "FAIL mksh background detach: the exec form still blocks on this mksh" >&2; exit 1; }
fi
echo "PASS mksh background-detach contract"
